---
description: Where outskirts stands and where it is heading: what shipped recently, what is in progress, and what comes next on the way to 4.0.
---

# Roadmap

outskirts keeps the Periphery 3.x line working with current Xcode and Swift toolchains, and explores further from there. This page is updated by hand when a release ships or a priority changes; the [changelog](../CHANGELOG.md) lists every change, and each item links to its issue.

Issues carry a priority label, from `P1` (first) to `P3`.

## Published

Recent releases, newest first:

- **3.24.0** (2026-11-13): scan on the index of a build that just ran instead of building again, with a coverage check per target and platform and a freshness check against a git revision.
- **3.23.0** (2026-11-11): `outskirts fix` removes unused String Catalog keys, dry run by default; `--format agent` for coding agents.
- **3.22.0** (2026-11-10): `scan --explain`; build provenance attestations for the bottles and the archive; file patterns follow the volume's case sensitivity.
- **3.21.4** (2026-11-10): `Void` properties initialized for their side effect retained; unreadable index units reported; safer output, baseline, shell and cache handling.
- **3.21.3** (2026-11-10): Metal functions looked up through SwiftUI `ShaderLibrary` retained; redundant public no longer reports declarations used by `@inlinable` accessors.
- **3.21.2** (2026-11-09): retention fixes (property wrappers, generic `allCases`, preview helpers, protocol extension `main()`, First Responder actions); stable redundant public results; unused system imports on Linux.
- **3.21.1** (2026-11-09): platform conditional retention off by default, as in Periphery 3.8; two false positives fixed (parameters of requirements under `#if`, catalog keys looked up at runtime).
- **3.21.0** (2026-11-06): `retain_public` per module; warning (and `--strict-index`) when the index is older than the sources; `--version`, grouped help and shell completions; `appendInterpolation` workaround limited to Swift < 6.4.
- **3.20.0** (2026-11-05): prebuilt archive and bottles for macOS 15, 26 and 27; assign-only analysis without type annotations; platform `#if` retention limited to uncompiled clauses.
- **3.19.1** (2026-11-05): stale index units no longer cause random false positives when an index store is reused; the Swift package is named outskirts.
- **3.19.0** (2026-11-05): bounded build cache, orphaned folders evicted and `cache_max_size_gb`; types of `where Self ==` protocol extensions reported when unused.
- **3.18.1** (2026-11-04): documentation site at outskirts.dev/docs; job pool data race fixed and Swift 6 language mode; blocking strict self-scan in CI.
- **3.18.0** (2026-11-04): JSON Schema of the configuration file and `outskirts config check`; `--changed-since` and `--changed-lines` for pull request checks; `--quiet` prints nothing when there is no result ([#296](https://github.com/tiny-earth-moon/outskirts/issues/296)).
- **3.17.0** (2026-11-04): Metal functions analysis (`--detect-unused-metal-functions`); the build cache is keyed by the build arguments.
- **3.16.0** (2026-11-03): the project is renamed outskirts, with `periphery` kept as an alias; Linux is built and tested in CI.
- **3.15.0** (2026-11-03): `--relative-to`, baselines that only shrink (`--prune-baseline`, `--strict-baseline`), and the `sarif` format for GitHub code scanning.
- **3.14.0** (2026-11-02): unused generic parameters of types are opt-in (`--report-unused-type-parameters`).
- **3.13.0** (2026-11-01): Bazel mode removed.

## Compatibility

- 3.x releases only add: every new behaviour is opt-in, and defaults change in 4.0 only.
- The Periphery 3.8 command line, configuration keys, comment commands, output formats and exit codes keep working throughout 3.x.
- A deprecated option warns for at least one minor release before it is removed, and removal waits for a major release.
- 4.0 ships with a migration command for the configuration and baselines. After it, 3.x gets toolchain and crash fixes for at least three months, longer if usage calls for it.

## Next

In order, each one opt-in:

- **Act on results**: `fix` covers unused String Catalog keys since 3.23.0; unused imports and redundant `public` follow once every variant is scanned.
- **Every variant**: scan the union of platform and configuration variants as an opt-in, the prerequisite for removing unused imports and declarations with `fix`.
- Opt-in analysis of enum cases only matched in patterns and never constructed.
- Prebuilt binaries beyond macOS 27.

## Toward 4.0

The 4.0 theme: what ships on any platform or configuration is used; everything else is reported with a stable id and can be removed safely. These changes are breaking and ship together:

- Scanning every variant becomes the default and replaces name-based retention.
- Configuration v2: schema, strict validation and per-module overrides.
- Output v2: stable rule-aware ids, relative paths and baseline v2.
- Distinct, documented exit codes for findings and failures.
- Cleanup: drop the hidden `--no-color` flag and the Bazel shims, and a quieter `--index-store-path` mode.
- A support policy for Xcode, Swift and Linux, enforced by CI.
- `fix` removes unused declarations once every variant is scanned.

Ideas and requests are welcome as [issues](https://github.com/tiny-earth-moon/outskirts/issues).
