---
description: Apply the mechanical results of outskirts with the fix command: redundant access levels, empty extensions, unused imports, superfluous ignore comments, unused parameter names and, with --aggressive, missing final.
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

### Partial scans

`redundant-public`, `redundant-open` and `missing-final` change what other files may do: see the API, override, subclass. A file the scan did not see may do it, so these rules need a scan of all the code:

- every variant that ships: [`variants`](configuration.md) set to `auto` or to a list of variants, each built by this run, so not with `--skip-build`, `--index-store-path` or `--generic-project-config`, nor when a variant could not be built (its SDK is not installed);
- not an Xcode project, which is only built for the schemes of `--schemes` in the Debug configuration: targets outside these schemes, other configurations and per-configuration build settings such as `EXCLUDED_SOURCE_FILE_NAMES` compile code the scan never sees;
- no option that leaves code out of the index: `index_exclude` beyond its default globs, `exclude_tests` (a test mock that subclasses a class) or `exclude_targets`. `report_exclude`, `report_include`, the baseline and `--changed-since` only narrow the results: the files they hide are still scanned, so their references still count.

After a partial scan, a rule named with `--rule` is refused with the reason, and a rule applied by default is skipped with the reason `partial scan`. `--allow-partial-scan` lifts both; the fixes can then break the code the scan did not see. `unused-import` is decided from its own file, so it needs no complete scan.

## Options

- **`--apply`**: write the fixes. Each file is written atomically, and only if it still holds the content the edits were made on. Every file is written or none: each one is checked before the first write, and when a write fails, the files already written get their original content back.
- **`--verify`**: with `--apply`, rebuild the project with the same build as the scan (the Xcode schemes or `swift build`, with `--build-arguments`) once the fixes are written. The build covers test targets too: for an Xcode project, each scheme of `--schemes` runs `xcodebuild build-for-testing`, which builds the targets of the scheme's Build and Test actions (test targets included), without running the tests; for a Swift package, `swift build --build-tests` builds every target of the package, test targets included. Targets outside the listed schemes, and tests themselves, are not checked. If the build fails, every fixed file gets back its original bytes, the restored files are listed, and the command exits with a non-zero status. A file edited again during the build is not restored and is listed as such. `--verify` is refused when the build is skipped (`--skip-build`, `--index-store-path`) and for `--generic-project-config` projects, since outskirts does not build them.
- **`--aggressive`**: also apply the tier-2 rules.
- **`--rule <rule>`**: only apply this rule; repeat the option to apply several.
- **`--include <glob>`**: only fix the files that match the glob, relative to `--project-root`; repeat the option to give several.
- **`--allow-dirty`**: also fix files with uncommitted changes, and projects outside a git repository.
- **`--allow-partial-scan`**: apply `redundant-public`, `redundant-open` and `missing-final` after a scan that did not cover all the code (see [Partial scans](#partial-scans)).

## Safety

- Each result is re-located by parsing its file with SwiftParser at the reported line and column and walking up to the declaration, import or parameter. When the name or the kind does not match the result, the result is skipped as a location mismatch.
- Edits are byte ranges of the original file, which is never re-printed: comments, blank lines and formatting outside the edited ranges stay as they are. A comment separated from a removed declaration by a blank line, and a comment that is neither a doc comment nor a comment command other than `ignore:all`, stay.
- An edit nested in another collapses into it, for example a redundant `public` on an empty extension that is removed. Overlapping deletions merge into one; other edits that overlap without nesting are refused.
- Always skipped: files excluded from indexing, generated files (build folders, `GeneratedAssetSymbols.swift`, `GeneratedStringSymbols_*`, macro expansion buffers, or a header comment that says the file is generated), results with an `override location=` comment, and `@_exported`, `public`, `@testable` and conditional (`#if`) imports.
- The index only holds the code of the `#if` clauses that the scanned builds compiled. Code in another clause, such as `#if !DEBUG`, a custom flag, `swift()`, `compiler()`, `canImport()`, or the `os()`, `arch()` or `targetEnvironment()` of a platform that was not built, may use what a result reports as unused or redundant, so the rules that take something away (`redundant-public`, `redundant-open`, `missing-final` and `unused-import`) read these clauses in every scanned file, broadly, and skip:
  - a declaration whose name, or the name of one of its members, is written in such a clause (a call, an override, a subclass or an extension written there), with the reason `name written in an #if clause that no scanned build compiled`;
  - a member of a type declared, extended, inherited from, used as a generic constraint or as an attribute in such a clause, or of a class or protocol of the scan such a type inherits from: a conformance added there can use a member without naming it;
  - while any such clause holds code, a subscript, an operator, `callAsFunction`, `appendInterpolation` or `dynamicallyCall`, or a type that has one, since code calls them without writing their name;
  - an unused import in a file with code in such a clause.
- Files modified after their index store unit was written, or after the scan started, are refused, since they may no longer match the results; with `--skip-build` or `--index-store-path`, rebuild first.
- Only the files that version control can restore are edited. Files with uncommitted changes, untracked files included, are refused unless `--allow-dirty` is given, and so are symbolic links, files outside the repository of the project and files of a submodule or nested repository. git is run with an argument array, never through a shell.
- For a Swift package, only the root package is built: a local dependency (`.package(path:)`) is scanned, but its own tests and its other clients are not, so its files are never edited and its results are skipped with the reason `dependency package`.
- The file is parsed as the bytes on disk, so a byte order mark does not shift the edits.

The analyses have known false positives, for example a redundant `public` that a client module outside the scan needs, so build (or pass `--verify`) and review the changes before committing them. Removing unused declarations is not part of this command.
