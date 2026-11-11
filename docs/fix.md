---
description: Remove the unused keys of your String Catalogs with outskirts fix: review a unified diff, then write the catalogs, with the safety rules that keep a key in use from being removed.
---

# Fixing unused String Catalog keys

`outskirts fix` scans the project, then removes the unused String Catalog (`.xcstrings`) keys that the scan reports. These are the `unused` results of kind `localized_string`, see [Analysis: Unused localized strings](analysis.md#unused-localized-strings). It removes nothing else: no declaration, import or asset.

Available from 3.23.0. By default it only prints a unified diff of the changes it would make; nothing is written until you pass `--apply`.

## What it does

`fix` takes every option of `outskirts scan` (`--project`, `--schemes`, `--baseline`, `-- <args>`, the configuration file...), and runs the same scan. It then keeps the unused localized string results that remain after the [baseline](baselines.md), `report_exclude`, `report_include` and the [comment commands](comment-commands.md), and removes exactly those keys from their catalogs.

The catalogs are edited in place: the members of the removed keys are cut out of the file, and every other byte is kept, so the catalog keeps the layout Xcode gave it. The result is read back and compared with the original before anything is written; a catalog that cannot be edited this way (for example one that is not valid JSON) is skipped, not rewritten.

## Options

- **`--apply`**: write the changes, to every catalog or to none, instead of printing a unified diff.
- **`--include <glob>`**: only fix the catalogs that match the glob; repeat the option to give several. Keys of other catalogs are left alone. Example: `--include '**/Localizable.xcstrings'`.
- **`--allow-dirty`**: also fix the catalogs that have uncommitted changes, or that are not in a git repository, see [Which catalogs are written](#which-catalogs-are-written).
- **`--allow-partial-scan`**: fix although the scan leaves code out, see [Partial scans](#partial-scans).
- **`--allow-runtime-keys`**: apply although keys built at runtime may look up the removed keys, see [Keys built at runtime](#keys-built-at-runtime).

Some `scan` options make no sense for `fix` and are refused: `--setup`, `--write-baseline`, `--prune-baseline` and `--write-results`. Run `scan` for those. `fix` also refuses to run when the unused localized string analysis is disabled (`disable_unused_localized_string_analysis`), since there would be nothing to fix. Each option is listed in [Options](options.md#the-fix-command).

## Reviewing the diff

Without `--apply`, the diff of every catalog goes to stdout, with paths relative to the project root, and a summary goes to stderr. Nothing is written, so a dry run is safe to repeat and to redirect, e.g. `outskirts fix > unused-keys.diff`.

```text
--- a/Sources/Kit/Localizable.xcstrings
+++ b/Sources/Kit/Localizable.xcstrings
@@ -1,9 +1,6 @@
 {
   "sourceLanguage" : "en",
   "strings" : {
-    "unused_key" : {
-
-    },
     "used_key" : {

     }
```

The summary on stderr reads `Would remove 1 unused String Catalog key in 1 file, skipped 0 keys.`

With `--apply`, the catalogs are written, stdout stays empty, and the summary starts with `Removed` instead of `Would remove`. The summary also lists each skipped catalog with its reason.

## Which catalogs are written

A key removed from a catalog is only recoverable if git can restore it, so by default `fix` only writes a catalog that git tracks and that has no uncommitted changes. A catalog that does not meet these rules is skipped, with the reason on the summary, and the other catalogs are still fixed. The skip reasons are:

- the file has uncommitted changes (`--allow-dirty` accepts them);
- the project is not in a git repository (`--allow-dirty` accepts it);
- the file is not tracked by git: ignored, or in a submodule or a nested repository;
- the file is outside the git repository of the project, or outside the project root;
- the file is a symbolic link;
- the file changed since the scan started: it may no longer match the results, so run `fix` again;
- the file is unreadable, or is not a catalog that can be edited without altering anything but the removed keys.

With `--allow-dirty`, the git checks are skipped, but the file must still be inside the project root, and not a symbolic link.

`--apply` writes every planned catalog or none. All the files are checked against the bytes they were planned on before the first write, and a file that changed in between stops the run with an error. Each file is written to a temporary file next to it, then renamed over it, keeping its permissions, so it holds its old content or the new one, never a mix. If a write fails, the files already written get their original bytes back; if one of them changed in the meantime, the error names the files that kept their fix.

## Partial scans

A key is only unused if every code that may use it was scanned. `fix` therefore refuses to run when the scan leaves code out, because a key used only by that code would be removed:

- an Xcode project, which is only built for the schemes you list, in the Debug configuration: a target outside these schemes, or code that another configuration compiles, is not scanned. List every scheme that builds code using the catalogs in `--schemes`;
- `index_exclude` (beyond its default), `exclude_tests` and `exclude_targets`.

`report_exclude` and `report_include` do not count: they only narrow the results, and the uses stay. Remove the option, or pass `--allow-partial-scan` to accept the risk. The error names the option that caused the refusal. The refusal comes before the build.

## Keys built at runtime

A key built at runtime without a literal prefix (e.g. `String(localized: String.LocalizationValue(key))`) may look up any key, see [Analysis: Keys built at runtime](analysis.md#keys-built-at-runtime). `fix` then cannot tell whether a removed key is in use. If `fix` has keys to remove and such a lookup exists:

- without `--apply`, it prints the diff and a warning that lists each call site;
- with `--apply`, it refuses and lists them.

The refusal does not apply when `localized_string_key_patterns` declares the keys these lookups build, or when `retain_runtime_localized_keys` is enabled, since the keys they may reach are then declared used or retained. Declaring the patterns is the better fix. `--allow-runtime-keys` applies anyway, once you have checked the removed keys by hand.

## Baselines, exclusions and comments

`fix` removes what `scan` reports, after filtering. A key hidden by a [baseline](baselines.md), by `report_exclude`, or kept without `report_include`, is not removed. The same holds for the [comment commands](comment-commands.md) that keep a result. To keep a key on purpose, add it to the baseline (`outskirts scan --write-baseline`), or exclude its catalog with `localized_string_catalog_exclude`. By default, `InfoPlist.xcstrings` and `AppShortcuts.xcstrings` are excluded from the analysis, so `fix` leaves them alone.

## Exit status

`fix` exits with status 0 when the run completes, whether or not catalogs were skipped. It exits with status 1 when it fails or refuses to run: an invalid configuration, a scan failure, a partial scan, keys built at runtime with `--apply`, or a failed write. A command line that cannot be parsed, or options that `fix` does not accept (`--setup`, `--write-baseline`, `--prune-baseline`, `--write-results`), exit with 64. See [Getting started: Exit status](getting-started.md#exit-status).

## Recommended workflow

1. Commit or stash your changes, so that the catalogs are clean.
2. Run `outskirts fix` and read the diff: each removed key should really be dead. Check the warnings about keys built at runtime.
3. Run `outskirts fix --apply`.
4. Build and run your tests, then review the catalogs with `git diff`. `git restore` brings back any key you want to keep; add it to a baseline, or declare it with `localized_string_key_patterns`, so that it is not reported again.

Because keys are matched to the code that uses them, run `fix` with the same options as your CI scan, and list every scheme or target whose code uses the catalogs.
