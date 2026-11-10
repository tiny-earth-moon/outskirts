# Contributing

outskirts (formerly Periphery; `periphery` stays an alias) keeps the Periphery 3.x line building and working with current Xcode/Swift toolchains. There is no functional roadmap: bug reports (with a minimal project) and pull requests are welcome, feature requests should come as a PR.

## Build

```
swift build -c release --product outskirts
.build/release/outskirts version
```

## Test

The full suite is long. Run the tests relevant to your change:

```
swift test --filter <TestCaseName>
```

## Adding an option

An option of `scan` that can also be set in the configuration file touches every item below; `ConfigurationSchemaTest` fails when one is missing.

- The `@Setting` property in `Sources/Configuration/Configuration.swift`, and its entry in the `settings` array of the same file.
- A one-line description of the key in `Sources/Configuration/SettingDescriptions.swift`.
- The `@Option` or `@Flag` in `Sources/Frontend/Commands/ScanCommand.swift`, and its line in `apply(to:)`.
- Its section in `CATEGORIES` of `site/scripts/sync.mjs`, then `npm run sync` in `site/`, which regenerates `docs/options.md` from the schema.
- If it helps a common scenario, a commented use in a file under `examples/`.
- The regenerated schema: `swift run outskirts config schema > outskirts.schema.json` (before `npm run sync`).
- Where it fits, a mention in the page of `docs/` that explains the scenario: the options reference links back to it.
- `swift test --filter ConfigurationSchemaTest`, which compares the settings with the `scan` options, `docs/` and `examples/`, `docs/options.md` with the schema and the `scan` help, and the committed schema with the generated one.

## Documentation

The Markdown files of `docs/` are the documentation: they are published as https://outskirts.dev/docs/ and read as they are on GitHub. Edit `docs/`, never the generated copies:

- `docs/options.md` is generated from `outskirts.schema.json`, and the README sections between `<!-- docs:begin page#anchor -->` and `<!-- docs:end -->` are extracts of `docs/`. After editing `docs/` or the schema, run `npm install` once, then `npm run sync` in `site/`, and commit the result.
- `npm run check` in `site/` builds the site into `site/public/` (not committed), then checks that the generated Markdown is up to date, that every page is in the navigation of `docs/README.md`, and that every link and anchor resolves; the CI runs it.
- The docs follow `master`, so mark what is not in a release yet: every new option gets its version in `SINCE` of `site/scripts/sync.mjs` (keys missing from both `SINCE` and `site/scripts/options-baseline.txt` fail `npm run check`), and every new doc section starts with a paragraph that is exactly `Since X.Y.Z.`, the next version. The site shows "not yet released" next to it while X.Y.Z is above the version in `Sources/Shared/Version.swift`.
- The changelog page is generated from `CHANGELOG.md` at build time.
- Images live under `assets/` and are referenced as `../assets/...`. Keep code lines within 64 characters so that they never wrap on a laptop.
- A link to a page of the site is written `https://outskirts.dev/docs/<page>/#<anchor>`; `SarifFormatterTest` checks the links of the SARIF rules against the headings of `docs/`.

## Commits

Conventional Commits with a scope, in English: `fix(indexer): ...`, `build: ...`, `docs: ...`, `chore(fork): ...`. One logical change per commit.

## Pull requests

- One issue, one pull request. The PR body contains `Closes #N` so that the issue closes on merge.
- Never edit `CHANGELOG.md` in a pull request: the release commit fills it.
- CI (`.github/workflows/test.yml`) must be green before merging: build, strict self-scan with `.outskirts.yml`, tests, swiftformat and swiftlint on macOS, the Linux jobs, the release scripts and the site (`npm run check`).
- External contributions keep their original author, with a `Co-authored-by` trailer when changes are made on top.

## Importing changes from other forks

- Use `git merge` or `git cherry-pick -x` so the original author and commit stay in the history; never rewrite an author.
- Add a row to [docs/credits.md](docs/credits.md): fix, author, original commit.
- The MIT license applies: keep the original copyright notice ([LICENSE.md](LICENSE.md)) on imported code.

## Reporting issues

Use the [bug report template](.github/ISSUE_TEMPLATE/bug.md). Labels: `imported` (copied from another tracker, original reference and reporter kept), `needs-repro` (waiting for a minimal project), `P1` to `P3` (priority, P1 first).
