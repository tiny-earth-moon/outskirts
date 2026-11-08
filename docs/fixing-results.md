---
description: Apply the mechanical results of outskirts with the fix command: redundant access levels, empty extensions, unused imports, superfluous ignore comments, unused parameter names, with --aggressive missing final and, opt-in after a scan of every variant, unused declarations.
---

# Fixing results

`outskirts fix` scans the project like `outskirts scan`, then applies the results that a syntax-only edit can fix. By default it changes nothing and prints a unified diff on stdout; `--apply` writes the files. A short summary goes to stderr: the total, one line per rule with its applied count and its skipped count by reason, then one line per skipped result with its location and reason. For example:

```
Would apply 219 fixes in 212 files, skipped 2.
  unused-import: 219, skipped 2 (testable import 2)
  skipped unused-import 'Kit' at A.swift:3:1: testable import
  skipped unused-import 'Kit' at B.swift:2:1: testable import
```

```sh
outskirts fix                  # print the diff
outskirts fix --apply          # write the files
outskirts fix --apply --verify # rebuild, restore on failure
outskirts fix --rule unused-import --include 'Sources/App/**'
outskirts fix --rule unused --variants auto
```

The command takes every option of `scan` and reads the same configuration file, so the baseline, `report_exclude`, `report_include` and `--changed-since` limit what it fixes too. `--setup`, `--write-baseline`, `--prune-baseline` and `--write-results` are refused.

## Rules

| Rule | Result | Fix | Analysis |
|------|--------|-----|----------|
| `redundant-public` | `redundantPublicAccessibility` | Delete `public` and the space after it. | On by default. |
| `redundant-open` | `redundantOpenAccessibility` | Replace `open` with `public`. | `--enable-open-final-analysis` |
| `redundant-access-level` | `redundantAccessLevel` | Delete the access modifier and the space after it. | `--enable-redundant-access-level-analysis` |
| `empty-extension` | `emptyExtension` | Remove the extension with its doc comment, its attributes and one trailing newline. | `--enable-empty-extension-analysis` |
| `unused-import` | `unused` (import) | Remove the import with its doc comment, its trailing comment and one trailing newline. | On by default. |
| `superfluous-ignore` | `superfluousIgnoreCommand` | Remove the `periphery:ignore` or `outskirts:ignore` comment, and an `ignore:parameters` comment once every parameter it lists is reported. | `--superfluous-ignore-comments` |
| `unused-parameter` | `unused` (parameter) | Rename the internal name to `_` and keep the argument label: `f(a: Int)` becomes `f(a _: Int)`, `f(_ a: Int)` becomes `f(_: Int)`. A subscript or operator parameter has no label, so `subscript(i: Int)` becomes `subscript(_: Int)`. | On by default. |

A rule whose analysis is opt-in only applies when the analysis is enabled, on the command line or in the configuration file.

### Tier 2: `--aggressive`

Tier-2 rules change behavior, so they only apply with `--aggressive`, and `--rule` refuses them without it.

| Rule | Result | Fix | Analysis |
|------|--------|-----|----------|
| `missing-final` | `missingFinal` (class) | Insert `final` after the attributes and the access modifier: `public class` becomes `public final class`, `@MainActor class` becomes `@MainActor final class`. `open` and already `final` classes are never changed. | `--enable-open-final-analysis` |

A class made `final` can no longer be subclassed, including by a module the scan did not see, so use `--aggressive` with `--verify` and review the diff. Members reported as missing `final` in a class that is not reported are left to edit by hand.

### Opt-in: `unused`

`--rule unused` removes the declarations reported as `unused`. It never applies by default: `fix` without `--rule` leaves them alone.

A declaration used only in the `#if` clauses of another platform or configuration looks unused to a scan that did not build it, so the rule needs a scan of every variant that ships: [`variants`](configuration.md) set to `auto` or to a list of variants. The variants are scanned together, so a declaration is reported only when it is unused in every one of them. The rule is refused with `variants: default`, when a variant could not be built (its SDK is not installed), and when the scan did not build the variants itself (`--skip-build`, `--index-store-path`, `--generic-project-config`). `--allow-partial-variants` lifts the refusal; the removals can then break the variants that were not scanned.

A declaration is removed when all of these hold:

- Its kind is a function, method, subscript, computed property, type, typealias, enum case or associated type, or it is a stored property:
  - without an attribute, so without a property wrapper;
  - with no initializer, or a literal one (number, string without interpolation, boolean, `nil`, array or dictionary of literals);
  - without an initializer if it is `static` or `class`;
  - not in a struct whose memberwise initializer is used, nor in a type that may synthesize `Equatable`, `Hashable` or `Codable` from its stored properties.
- It is not `override`, `dynamic`, `@objc` (or exposed to Objective-C), `@main`, `@_cdecl`, `@_silgen_name`, an Interface Builder or `@NSManaged` member, and it carries no attribute of `retain_attributes`. A type that contains such a member, or a member ignored by a comment command, is kept too.
- It is not a case of a `CaseIterable` or `Codable` enum, nor a case whose removal would change the raw value of a later case.
- Nothing kept references it or one of its members: a declaration that only removed code references goes in the same run.
- No kept declaration overrides it or implements it, and it does not implement a kept protocol requirement.
- Every extension of the type, and of the types nested in it, is in the results and is removed with it, in the same edit set.

Members of a removed type go with it. Each declaration is removed with its doc comment, its attributes and one trailing newline. A declaration that shares its line with others (`case a, b`, `var a = 1, b = 2`) is kept. When a removal is skipped, for example because its file has uncommitted changes, the declarations that depend on it are kept as well.

The summary lists each removal, and each kept result with its reason, with its [output v2 id](output-formats.md):

```
Would apply 3 fixes in 1 file, skipped 1.
  unused: 3, skipped 1 ('dynamic' declaration 1)
  would remove unused 'Dead' at A.swift:1:8 [p2_...]
```

Removing a declaration can make others unused: scan again to remove them.

Reflection is invisible to every scan: a type created with `NSClassFromString`, a property read through `Mirror` or key-value coding (`value(forKey:)`, `#keyPath`), or a symbol looked up with `dlsym` can be reported as unused and removed. Use `--verify`, run the tests, and review the diff before committing.

## Options

- **`--apply`**: write the fixes. Each file is written atomically, and only if it still holds the content the edits were made on.
- **`--verify`**: with `--apply`, rebuild the project with the same build as the scan (the Xcode schemes or `swift build`, with `--build-arguments`) once the fixes are written. The build covers test targets too: for an Xcode project, each scheme of `--schemes` runs `xcodebuild build-for-testing`, which builds the targets of the scheme's Build and Test actions (test targets included), without running the tests; for a Swift package, `swift build --build-tests` builds every target of the package, test targets included. Targets outside the listed schemes, and tests themselves, are not checked. If the build fails, every fixed file gets back its original bytes, the restored files are listed, and the command exits with a non-zero status. A file edited again during the build is not restored and is listed as such. `--verify` is refused when the build is skipped (`--skip-build`, `--index-store-path`) and for `--generic-project-config` projects, since outskirts does not build them.
- **`--aggressive`**: also apply the tier-2 rules.
- **`--rule <rule>`**: only apply this rule; repeat the option to apply several.
- **`--include <glob>`**: only fix the files that match the glob, relative to `--project-root`; repeat the option to give several.
- **`--allow-dirty`**: also fix files with uncommitted changes, and projects outside a git repository.
- **`--allow-partial-variants`**: allow `--rule unused` after a scan that did not cover every variant.

## Safety

- Each result is re-located by parsing its file with SwiftParser at the reported line and column and walking up to the declaration, import or parameter. When the name or the kind does not match the result, the result is skipped as a location mismatch.
- Edits are byte ranges of the original file, which is never re-printed: comments, blank lines and formatting outside the edited ranges stay as they are. A comment separated from a removed declaration by a blank line, and a comment that is not a doc comment, stay.
- An edit nested in another collapses into it, for example a redundant `public` on an empty extension that is removed. Edits that overlap without nesting are refused.
- Always skipped: files excluded from indexing, generated files (build folders, `GeneratedAssetSymbols.swift`, `GeneratedStringSymbols_*`, macro expansion buffers, or a header comment that says the file is generated), results with an `override location=` comment, and `@_exported`, `public`, `@testable` and conditional (`#if`) imports.
- Files modified after their index store unit was written, or after the scan started, are refused, since they may no longer match the results; with `--skip-build` or `--index-store-path`, rebuild first.
- Only the files that version control can restore are edited. Files with uncommitted changes, untracked files included, are refused unless `--allow-dirty` is given, and so are symbolic links, files outside the repository of the project and files of a submodule or nested repository. git is run with an argument array, never through a shell.
- The file is parsed as the bytes on disk, so a byte order mark does not shift the edits.

The analyses have known false positives, for example a redundant `public` that a client module outside the scan needs, so build (or pass `--verify`) and review the changes before committing them. Removing unused declarations is opt-in, with `--rule unused`.
