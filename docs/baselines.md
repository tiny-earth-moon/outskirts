---
description: Adopt outskirts in an existing project with a baseline: record today's results, report only new ones, and let the baseline shrink over time.
---

# Baselines

A baseline records results so that later scans do not report them again: new unused declarations show up, the recorded ones stay quiet. It lets a project adopt outskirts without acting on every result first, and see what appears from now on.

## Options

- **`--write-baseline <path>`** (`write_baseline`): write the results of the scan to `<path>`. The entries of the baseline given to `--baseline` are kept, and the current results are added.
- **`--baseline <path>`** (`baseline`): hide the results recorded in `<path>`. A relative path is resolved from `--project-root`.
- **`--prune-baseline`** (`prune_baseline`): rewrite the file given to `--baseline`, keeping only the entries that still match a result. Requires `--baseline`.
- **`--strict-baseline`** (`strict_baseline`): exit with status 1 if the baseline holds entries that no longer match any result. Requires `--baseline`.

## Formats

Both formats are read. `--write-baseline` writes `v2` when the configuration file declares `version: 2`, and `v1` otherwise.

### v1

The default. An id is the identifier of the declaration in the index store (its USR), which does not depend on its line number, and hides every result of that declaration, whatever its rule. Results without a USR of their own, such as unused imports, empty extensions and localized strings, use ids that outskirts builds for them. The position-based ids and absolute String Catalog paths written by earlier versions still match.

The file is sorted, pretty-printed, newline-terminated JSON that gives each entry an `id` and the `kind`, `name` and `file` (relative to the project root) of the result it was written for, so a review shows what was baselined. Only the `id` is used for matching. Files that list the ids only (`{"v1": {"usrs": […]}}`, as written by Periphery and earlier versions) are still read, and are rewritten with the details by `--write-baseline` and `--prune-baseline`.

### v2

Since 3.22.0, written with a configuration file that declares `version: 2`. It is a 4.0 preview: opt-in in 3.x, 4.0 makes it the default. The file holds the ids of the [`json-v2`](output-formats.md#json-v2) format, sorted:

```json
{
  "ids" : [
    "p2_…"
  ],
  "version" : 2
}
```

These ids include the rule: a declaration baselined as redundant public is reported again once it becomes unused, where a `v1` baseline keeps hiding it. They hold no absolute path and no line number either, so they survive an edit above the declaration and another checkout.

`--write-baseline` with a `version: 2` configuration converts a `v1` baseline given to `--baseline` through the results it hides; its entries that no longer match a result are dropped. The other way round works the same. `--prune-baseline` keeps the format of the file it rewrites.

## Baseline ratchet

A baseline hides the results that exist today so that CI only fails on new ones. Without care it only grows: an entry stays after its code is removed, and hides the declaration if it is added back with the same id. outskirts logs `N baseline entries no longer match any result` on every scan with a baseline, and lists them with `--verbose`.

To let a baseline only shrink:

```sh
# Once: record the current results. Each entry lists
# the kind, name and file, so a review shows what was
# baselined.
outskirts scan --write-baseline baseline.json

# In CI, on every change: fail on new results
# (--strict) and on entries that no longer match
# (--strict-baseline, exit status 1).
outskirts scan --baseline baseline.json \
  --strict --strict-baseline

# On a schedule, e.g. weekly: remove the entries that
# no longer match, and open a pull request with the diff.
outskirts scan --baseline baseline.json \
  --prune-baseline
```

`--prune-baseline` rewrites the file given to `--baseline` and requires it; it cannot be combined with `--write-baseline`, which keeps the entries of the baseline it is given and adds the current results. `--strict-baseline` requires `--baseline` too, and does not fail a run that also passes `--prune-baseline`. Entries are matched before `report_include` and `report_exclude`, so the entries of excluded files are kept.

## Baselines and pull requests

A baseline is not needed to look only at what a branch adds: `--changed-since` reports the results of the files changed since a git ref, see [Pull request checks](ci.md#pull-request-checks). The filter is applied after `--baseline`, so both can be combined.
