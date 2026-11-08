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
outskirts fix --rule unused --apply --iterate
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

A declaration used only in the `#if` clauses of another platform or configuration looks unused to a scan that did not build it, so the rule needs a scan of every variant that ships: [`variants`](configuration.md) set to `auto` or to a list of variants. The variants are scanned together, so a declaration is reported only when it is unused in every one of them. The rule is refused with `variants: default`, when a variant could not be built (its SDK is not installed, or `auto` has no build for a declared platform such as Mac Catalyst or DriverKit), and when this run did not build the variants itself (`--skip-build`, `--index-store-path`, `--generic-project-config`). `--allow-partial-scan` lifts the refusal; the removals can then break the variants that were not scanned.

The variants only cover the platforms: each is built in the debug configuration, with the build arguments of the scan. The code of an `#if` clause that no scanned build compiled, such as `#if !DEBUG`, a custom flag, `swift()`, `compiler()`, `canImport()`, or the `os()`, `arch()` or `targetEnvironment()` of a platform that was not built, is invisible to the index, so the rule reads it broadly instead of resolving it:

- Every identifier and operator written in such a clause, whether it refers to a declaration, declares one or names a parameter, keeps every declaration of that name, and every type with a member of that name: an override, an extension or a call written there keeps its target.
- A type declared, extended, inherited from, used as a generic constraint or as an attribute in such a clause keeps all its members, and so do the classes and protocols of the scan it inherits from: a conformance added there (`extension Model: CustomStringConvertible {}`) can use a member it never names.
- While any such clause holds code, every subscript, operator (`~=` included), `callAsFunction`, `appendInterpolation` and `dynamicallyCall` is kept, as code calls them without writing their name (`grid[1]`, `parser()`, `case Even():`, `"\(hex: value)"`).

The clauses are read in every scanned file; a block that only checks `os()`, `arch()` and `targetEnvironment()` is narrowed to the clauses no build of its file compiled, any other block is read whole.

An Xcode project is only built for the schemes of `--schemes`, in the Debug configuration: targets outside these schemes, other configurations and per-configuration build settings such as `EXCLUDED_SOURCE_FILE_NAMES` compile code the scan never sees. The rule is therefore refused on Xcode projects unless `--allow-partial-scan` is given.

For a Swift package, only the root package is built: a local dependency inside the project root (`.package(path:)`) is scanned, but its own test targets are not, so its files are never edited and its declarations are kept with the reason `dependency package`.

A file left out of the scan may use the declarations it removes, so the rule is also refused when `index_exclude` (beyond its default globs), `exclude_tests` or `exclude_targets` is set. `--allow-partial-scan` lifts this refusal too: it is the single flag that lifts every coverage refusal of the rule, and each refusal names its reason. `report_exclude`, `report_include`, the baseline and `--changed-since` only narrow the results: the files they hide are still scanned, so their references still count.

A `public` or `open` declaration, or a case or requirement of a public enum or protocol, may be used by a module outside the scan, so it is kept unless `--include-public` is given. Even then, the declarations that `retain_public`, `retain_public_modules` or an override retains are kept.

A declaration is removed when all of these hold:

- Its kind is a function, method, subscript, computed property, type, typealias, enum case or associated type, or it is a stored property:
  - for a stored instance property, only with `--include-stored-properties`, and never in a `@frozen` type: removing it changes the memory layout of its type, which padding or reserved fields, unsafe pointers and `withUnsafeBytes` depend on without the build noticing;
  - without an attribute, so without a property wrapper;
  - with no initializer, or a literal one (number, string without interpolation, boolean, `nil`, array or dictionary of literals);
  - without an initializer if it is `static` or `class`;
  - not in a struct whose memberwise initializer is used, nor in a type that may synthesize `Equatable`, `Hashable` or `Codable` from its stored properties.
- It is not `override`, `dynamic`, `@objc` (or exposed to Objective-C), `@main`, `@_cdecl`, `@_silgen_name`, an Interface Builder or `@NSManaged` member, and it carries no attribute of `retain_attributes`. A type that contains such a member, or a member ignored by a comment command, is kept too.
- It is not a case of a `CaseIterable` or `Codable` enum, nor a case whose removal would change the raw value of a later case. A raw type that is not `String` and cannot be read from the syntax, such as a typealias or `CInt`, counts as numeric. When every case of an enum that is kept would go, all its cases are kept: a `switch` over it would be left with only `default`.
- It is not public API (see above), and no `#if` clause that no scanned build compiled may reach it (see above).
- It is not in a local dependency package (see above).
- Nothing kept references it or one of its members: a declaration that only removed code references goes in the same run.
- No kept declaration overrides it or implements it, and it does not implement a kept protocol requirement.
- It is not a requirement of a protocol that declares an associated type, nor the implementation of one: the compiler may infer the associated type from it, so removing it could change the type silently or break the conformance.
- Every extension of the type, and of the types nested in it, is in the results and is removed with it, in the same edit set.

Members of a removed type go with it. Each declaration is removed with its doc comment, the comment commands right above it (an `ignore:parameters` comment left behind would apply to the next declaration; `ignore:all` stays), its attributes and one trailing newline. A declaration that shares its line with others (`case a, b`, `var a = 1, b = 2`) is kept. When a removal is skipped, for example because its file has uncommitted changes, the declarations that depend on it are kept as well.

The summary lists each removal, and each kept result with its reason, with its [output v2 id](output-formats.md):

```
Would apply 3 fixes in 1 file, skipped 1.
  unused: 3, skipped 1 ('dynamic' declaration 1)
  would remove unused 'Dead' at A.swift:1:8 [p2_...]
```

Removing a declaration can make others unused, such as a helper called only in an `#if` clause of a removed type: scan again to remove them, or pass `--iterate` with `--apply`.

With `--iterate`, the command scans again after each pass and fixes what the pass left, until a pass fixes nothing, at most 5 passes. Every pass is a full scan and build, so the refusals and the rules above apply again to what the earlier passes left. A file written by an earlier pass now has uncommitted changes, but a later pass may still edit it as long as it holds the bytes that pass wrote, since version control can still restore its committed content.

`--iterate` implies `--verify`: each pass is rebuilt before the next one starts, so no pass leaves the project broken. When the build fails, only the files of that pass get back the content they had before it; the fixes of the earlier passes, which built, stay, and the command exits with a non-zero status. `--iterate` is therefore refused when `--verify` would be.

Each pass starts with `Pass N of at most M:` and its summary, and the last line gives the total:

```
Pass 3 of at most 5:
Applied 0 fixes in 0 files, skipped 1.
  unused: 0, skipped 1 (public API, use --include-public 1)
Nothing left to fix after 3 passes: 3 fixes in 1 file.
```

When the fifth pass still fixed something, the command stops with `Stopped at the limit of 5 passes`: run it again to fix what it left.

Some uses are invisible to every scan, so the declarations they reach can be reported as unused and removed:

- Reflection: a type created with `NSClassFromString`, a property read through `Mirror` or key-value coding (`value(forKey:)`, `#keyPath`), or a symbol looked up with `dlsym`. The build still succeeds, so only the tests or the running app show the break.
- Code outside the scanned project, such as a package that is not part of the scan and reaches the declarations through `@testable import`: its uses are not indexed, so its build breaks.
- A freestanding macro whose expansion drops its arguments: the index only holds the expansion, but the compiler still type-checks the arguments, so the build fails.
- Removing a case of an enum switched over with `default` can make the `default` unreachable, which is a warning.

Use `--verify`, run the tests, and review the diff before committing.

## Options

- **`--apply`**: write the fixes. Each file is written atomically, and only if it still holds the content the edits were made on. Every file is written or none: each one is checked before the first write, and when a write fails, the files already written get their original content back.
- **`--verify`**: with `--apply`, rebuild the project with the same build as the scan (the Xcode schemes or `swift build`, with `--build-arguments`) once the fixes are written. The build covers test targets too: for an Xcode project, each scheme of `--schemes` runs `xcodebuild build-for-testing`, which builds the targets of the scheme's Build and Test actions (test targets included), without running the tests; for a Swift package, `swift build --build-tests` builds every target of the package, test targets included. Targets outside the listed schemes, and tests themselves, are not checked. If the build fails, every fixed file gets back its original bytes, the restored files are listed, and the command exits with a non-zero status. A file edited again during the build is not restored and is listed as such. `--iterate` implies it: each pass is verified on its own, and a failure only restores the files of that pass. `--verify` is refused when the build is skipped (`--skip-build`, `--index-store-path`) and for `--generic-project-config` projects, since outskirts does not build them.
- **`--aggressive`**: also apply the tier-2 rules.
- **`--rule <rule>`**: only apply this rule; repeat the option to apply several.
- **`--include <glob>`**: only fix the files that match the glob, relative to `--project-root`; repeat the option to give several.
- **`--allow-dirty`**: also fix files with uncommitted changes, and projects outside a git repository.
- **`--allow-partial-scan`**: allow `--rule unused` after a scan that did not cover all the code: `variants: default`, a variant that was not built, an Xcode project (only the listed schemes in Debug), or `index_exclude`, `exclude_tests` or `exclude_targets`.
- **`--include-public`**: with `--rule unused`, also remove `public` and `open` declarations, unless `retain_public`, `retain_public_modules` or an override retains them.
- **`--include-stored-properties`**: with `--rule unused`, also remove stored instance properties, which changes the memory layout of their type; never those of a `@frozen` type.
- **`--iterate`**: with `--rule unused` and `--apply`, verify each pass as `--verify` does, then scan again and fix what it left, until a pass fixes nothing, a build fails or 5 passes are done.

## Safety

- Each result is re-located by parsing its file with SwiftParser at the reported line and column and walking up to the declaration, import or parameter. When the name or the kind does not match the result, the result is skipped as a location mismatch.
- Edits are byte ranges of the original file, which is never re-printed: comments, blank lines and formatting outside the edited ranges stay as they are. A comment separated from a removed declaration by a blank line, and a comment that is neither a doc comment nor a comment command other than `ignore:all`, stay.
- An edit nested in another collapses into it, for example a redundant `public` on an empty extension that is removed. Overlapping deletions merge into one; other edits that overlap without nesting are refused.
- Always skipped: files excluded from indexing, generated files (build folders, `GeneratedAssetSymbols.swift`, `GeneratedStringSymbols_*`, macro expansion buffers, or a header comment that says the file is generated), results with an `override location=` comment, and `@_exported`, `public`, `@testable` and conditional (`#if`) imports.
- Files modified after their index store unit was written, or after the scan started, are refused, since they may no longer match the results; with `--skip-build` or `--index-store-path`, rebuild first.
- Only the files that version control can restore are edited. Files with uncommitted changes, untracked files included, are refused unless `--allow-dirty` is given, and so are symbolic links, files outside the repository of the project and files of a submodule or nested repository. git is run with an argument array, never through a shell.
- The file is parsed as the bytes on disk, so a byte order mark does not shift the edits.

The analyses have known false positives, for example a redundant `public` that a client module outside the scan needs, so build (or pass `--verify`) and review the changes before committing them. Removing unused declarations is opt-in, with `--rule unused`.
