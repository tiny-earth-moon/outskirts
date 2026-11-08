---
description: Keep scan options in .outskirts.yml: file lookup, command line precedence, the JSON Schema for editor completion and outskirts config check.
---

# Configuration

Once you have settled on the options your project needs, keep them in a YAML configuration file so that `outskirts scan` alone runs the same scan, in a terminal, in Xcode and in CI.

## The configuration file

outskirts reads `.outskirts.yml` at the project root (`--project-root`, the current directory by default). `.outskirts.yaml`, `.periphery.yml` and `.periphery.yaml` are read too, so existing projects keep working unchanged. `--config <file>` points to another file; a relative path is resolved from `--project-root`.

Every key is the name of a scan option in `snake_case`, e.g. `--retain-public` is `retain_public`. The [options reference](options.md) lists every key with its type and default.

```yaml
project: MyApp.xcodeproj
schemes:
  - MyApp
exclude_tests: true
retain_public: false
report_exclude:
  - "**/Generated/**"
```

### Writing the file from a scan

The simplest way to write the file is to run a scan with the options you want and `--verbose`. Near the beginning of the output, the `[configuration:begin]` section shows your configuration formatted as YAML. Copy it into `.outskirts.yml` at the root of your project. The guided setup (`outskirts scan --setup`) offers to write the file for you.

### Examples

The [`examples/`](https://github.com/tiny-earth-moon/outskirts/tree/master/examples) folder holds commented files for common scenarios:

| File | Scenario |
|------|----------|
| `xcode-project.outskirts.yml` | Minimal Xcode project |
| `swiftpm-package.outskirts.yml` | Swift package |
| `types-only.outskirts.yml` | Report only unused types |
| `ci-strict.outskirts.yml` | CI gate with a machine-readable report |
| `library-public-api.outskirts.yml` | Library with a public API |
| `cache-and-skip-build.outskirts.yml` | Reuse an existing build |

Use one with `outskirts scan --config examples/<file>`, or copy it to `.outskirts.yml`.

## Command line and file

The command line takes precedence over the configuration file, which takes precedence over the defaults:

- An option given on the command line wins even when its value is the default: `--format xcode` wins over `format: json` in the file.
- An option that is not given leaves the value of the file untouched.
- Every boolean option has a `--no-` form to switch off, for one run, what the file enables: `--no-strict`, `--no-retain-public`, `--no-quiet`...
- A list given on the command line replaces the list of the file; the default `index_exclude` patterns are always kept.
- `--setup`, `--project-root` and `--config` are command line only, and `xcode_list_arguments` is configuration file only.

## Validation

Values are checked when the file is loaded:

- A value that does not suit its key, such as a number for a boolean (`strict: 1`), a format that does not exist (`format: xml`) or a quoted number for an integer, is reported on stderr as `<file>: 'strict' expects a boolean, got the integer 1`, and the default is kept.
- A key that is not an option is reported too, with the closest option when there is one: `invalid key 'retain_pubic' (did you mean 'retain_public'?)`.
- The file only has to be a mapping, otherwise the scan stops with an error.

Two shapes are accepted in place of the exact one: a single value for an option that takes a list (`exclude_targets: Demo` is `exclude_targets: [Demo]`), and the strings `"true"` and `"false"` for a boolean, which is also reported.

## Schema and editor completion

The keys, their types and their defaults are published as a JSON Schema, [`outskirts.schema.json`](https://github.com/tiny-earth-moon/outskirts/blob/master/outskirts.schema.json), also printed by `outskirts config schema`. Editors that use the YAML language server (the YAML extension of VS Code, among others) offer completion, descriptions and type checks when the first line of the file is:

```yaml
# yaml-language-server: $schema=https://raw.githubusercontent.com/tiny-earth-moon/outskirts/master/outskirts.schema.json
```

The files written by `outskirts scan --setup` and the files under `examples/` start with this line.

## Checking a configuration file

To check a file without scanning, run:

```sh
outskirts config check
outskirts config check --config <file> \
  --project-root <dir>
```

It reports on stderr, in the same words as a scan, unknown keys with the closest option, values of the wrong type, invalid `report_exclude` and `retain_attributes` entries, options missing the option they require (such as `skip_stdout_results` without `write_results`), and baseline and output paths a scan would refuse. It prints `<file>: ok` and exits with status 0 when there is nothing to report, and exits with status 1 when it finds a problem or no configuration file.

## Paths

Relative paths of the file and of the command line are resolved from `--project-root`, not from the directory the command was typed in: `--config`, `--baseline`, `--write-baseline`, `--write-results`, `--index-store-path`, `--json-package-manifest-path`, `--generic-project-config` and `--relative-to`. Globs (`index_exclude`, `report_exclude`, `report_include`, `retain_files`) are relative to the project directory or absolute, see [Excluding files](excluding-files.md).

## Format 2

A file that declares `version: 2` uses the format 2: the options are grouped by section, the rules are turned on and off by their id, and every mistake is an error. A file without `version`, or with `version: 1`, is read as described above, unchanged. Moving to the format 2 is optional; `outskirts config migrate` writes the equivalent file for you.

```yaml
# yaml-language-server: $schema=https://raw.githubusercontent.com/tiny-earth-moon/outskirts/master/schemas/config-v2.json
version: 2
extends: ../outskirts.base.yml
project:
  path: MyApp.xcworkspace
  schemes: [MyApp]
rules:
  unused-import: on
  missing-final: on
  redundant-open: on
retain:
  objc: annotated
  properties_of: [Codable]
exclude:
  index: ["Generated/**"]
  report: ["Legacy/**"]
overrides:
  - modules: ["Kit*"]
    retain: {public: true}
    rules: {redundant-public: off}
  - paths: ["Generated/**"]
    retain: {all: true}
```

The sections are `project`, `build`, `exclude`, `rules`, `retain`, `analysis`, `report` and `baseline`, with `variants` at the top level. The [table below](#v1-keys-and-v2-paths) gives the v2 path of every key of the format 1; the defaults are the same in both formats. Its JSON Schema is [`schemas/config-v2.json`](https://github.com/tiny-earth-moon/outskirts/blob/master/schemas/config-v2.json).

### Rules

`rules` maps a rule id to `on` or `off`. `outskirts list-rules` prints every rule, whether it is checked by default, and its key in each format, also as JSON for a script (see `outskirts help list-rules`). Some rules are always checked and cannot be turned off; `redundant-open` and `missing-final` share one switch, so they must have the same value.

On the command line, `--enable-rule <id>` and `--disable-rule <id>` turn a rule on or off whatever the format of the file, e.g. `--disable-rule unused-import`. They set the option of the rule, so `--disable-rule unused-import` is `--disable-unused-import-analysis`, and repeat to give several rules. Giving a rule both values, also through its own option, is an error.

### Validation of the format 2

An unknown key, a value of the wrong type and an invalid enum value are errors. Every problem is reported at once with its file and line, before anything is built, and the scan stops with the configuration-failure status. `outskirts config check` reports the same problems, as it loads the file the same way.

### Paths and `index_defaults`

Globs (`exclude.index`, `exclude.report`, `exclude.localized_string_catalogs`, `report.include`, `retain.files` and the `paths` of `overrides`) are relative to the directory of the file that declares them, unless they start with `/` or `*`. Other paths are resolved from the project root, as in the format 1.

`exclude.index` keeps the default globs next to the given ones, as `index_exclude` does. `exclude.index_defaults: false` drops them, so the list is used as written.

### `extends`

`extends` names one file or a list of files, relative to the file that declares them, which are read first; each file overrides the values of the files it extends, and a later file of the list wins over an earlier one. An extended file must declare `version: 2` too, and a cycle is an error. A file that does not set `exclude.index_defaults` keeps the choice of the file it extends.

### `overrides`

Each entry of `overrides` applies to the declarations of the modules (target name globs, `modules`) and files (`paths`) it matches; an entry must give at least one of them, and both must match when both are given. An entry sets `retain.public`, `retain.all`, and `rules` to turn rules off for those declarations. A rule that is off at the top level cannot be turned on in an override, and only the rules whose results can be dropped per declaration are accepted (the JSON output of `outskirts list-rules` marks them `overridable`). When several entries match a declaration, the last one wins for each setting, and the entries of the extended files come first.

### Migrating a file

```sh
outskirts config migrate            # prints the v2 file
outskirts config migrate --apply    # writes it over the file
```

`config migrate` reads the file as `outskirts scan` would (with the same `--config`) and writes the format 2 equivalent, which loads into the same configuration. The values are kept as written, `index_exclude` is written with its default globs and `index_defaults: false`, and relative globs are rewritten relative to the directory of the file. Comments are kept: a comment above a key or at the end of its line moves with the option, a comment inside a value moves above its option, the comments that open the file stay at the top and the schema comment points to the v2 schema. A file that the format 1 warns about must be fixed first, and the output is the same for the same file, so it can be checked into version control.

### Printing the configuration in effect

`outskirts config print` prints the configuration that a scan would use, without the command line options: the options that differ from their default, or every option with `--all`, in the format of the file. For the format 2, it names the files read, the extended ones first, merges their values, lists the `overrides`, and shows the globs absolute, as they were resolved.

### v1 keys and v2 paths

<!-- v1-v2-keys:begin -->
| v1 key | v2 path | Note |
|--------|---------|------|
| `project` | `project.path` |  |
| `schemes` | `project.schemes` |  |
| `exclude_targets` | `exclude.targets` |  |
| `exclude_tests` | `exclude.tests` |  |
| `index_exclude` | `exclude.index` | the default globs are kept unless `exclude.index_defaults: false` |
| `report_exclude` | `exclude.report` |  |
| `report_include` | `report.include` |  |
| `format` | `report.format` |  |
| `retain_public` | `retain.public` | a list of modules is `retain.public_modules` |
| `retain_public_modules` | `retain.public_modules` |  |
| `no_retain_spi` | `retain.public_excluded_spis` |  |
| `retain_files` | `retain.files` |  |
| `retain_assign_only_properties` | `rules.assign-only-property` | `true` is `off` |
| `retain_assign_only_property_types` | `retain.assign_only_property_types` |  |
| `enable_unassigned_optional_analysis` | `rules.unassigned-optional` | `true` is `on` |
| `enable_unconstructed_enum_case_analysis` | `analysis.unconstructed_enum_cases` |  |
| `retain_objc_accessible` | `retain.objc` | `accessible` |
| `retain_js_accessible` | `retain.js_accessible` |  |
| `retain_objc_annotated` | `retain.objc` | `annotated` |
| `retain_unused_protocol_func_params` | `retain.unused_protocol_parameters` |  |
| `retain_unused_parameters_without_default` | `retain.unused_parameters_without_default` |  |
| `retain_swift_ui_previews` | `retain.swiftui_previews` |  |
| `disable_redundant_public_analysis` | `rules.redundant-public` | `true` is `off` |
| `enable_redundant_public_members` | `analysis.redundant_public_members` |  |
| `enable_open_final_analysis` | `rules.redundant-open`, `rules.missing-final` | `true` is `on` |
| `enable_empty_extension_analysis` | `rules.empty-extension` | `true` is `on` |
| `enable_redundant_access_level_analysis` | `rules.redundant-access-level` | `true` is `on` |
| `report_unused_type_parameters` | `analysis.unused_type_parameters` |  |
| `disable_platform_conditional_retention` | `retain.platform_conditional` | `true` is `off` |
| `platform_conditional_retention` | `retain.platform_conditional` |  |
| `disable_unused_import_analysis` | `rules.unused-import` | `true` is `off` |
| `enable_unused_system_imports` | `analysis.unused_system_imports` |  |
| `disable_unused_localized_string_analysis` | `rules.unused-localized-string` | `true` is `off` |
| `localized_string_catalog_exclude` | `exclude.localized_string_catalogs` |  |
| `localized_string_key_patterns` | `retain.localized_string_keys` |  |
| `localized_string_key_literal_match` | `retain.localized_string_literals` |  |
| `retain_runtime_localized_keys` | `retain.runtime_localized_keys` |  |
| `superfluous_ignore_comments` | `rules.superfluous-ignore` | `true` is `on` |
| `retain_unused_imported_modules` | `retain.imported_modules` |  |
| `external_encodable_protocols` | `retain.external_encodable_protocols` |  |
| `external_codable_protocols` | `retain.external_codable_protocols` |  |
| `external_test_case_classes` | `retain.external_test_case_classes` |  |
| `verbose` | `report.verbose` |  |
| `quiet` | `report.quiet` |  |
| `color` | `report.color` |  |
| `disable_update_check` | `report.update_check` | `true` is `false` |
| `strict` | `report.strict` |  |
| `exit_codes` | `report.exit_codes` |  |
| `index_store_path` | `build.index_store_paths` |  |
| `skip_build` | `build.skip` |  |
| `skip_schemes_validation` | `project.skip_schemes_validation` |  |
| `clean_build` | `build.clean` |  |
| `strict_index` | `build.strict_index` |  |
| `quiet_index_store` | `build.quiet_index_store` |  |
| `cache_max_age_days` | `build.cache_max_age_days` |  |
| `cache_max_size_gb` | `build.cache_max_size_gb` |  |
| `build_arguments` | `build.arguments` |  |
| `variants` | `variants` |  |
| `xcode_list_arguments` | `project.xcode_list_arguments` |  |
| `relative_results` | `report.relative` |  |
| `relative_results_base` | `report.relative_to` |  |
| `changed_since` | `report.changed_since` |  |
| `changed_lines` | `report.changed_lines` |  |
| `json_package_manifest_path` | `project.package_manifest` |  |
| `retain_codable_properties` | `retain.properties_of` | `Codable` |
| `retain_encodable_properties` | `retain.properties_of` | `Encodable` |
| `retain_equatable_properties` | `retain.properties_of` | `Equatable` |
| `retain_hashable_properties` | `retain.properties_of` | `Hashable` |
| `baseline` | `baseline.path` |  |
| `write_baseline` | `baseline.write` |  |
| `baseline_format` | `baseline.format` |  |
| `prune_baseline` | `baseline.prune` |  |
| `strict_baseline` | `baseline.strict` |  |
| `write_results` | `report.write` |  |
| `skip_stdout_results` | `report.skip_stdout` |  |
| `generic_project_config` | `project.generic_config` |  |
| `retain_synthesized_uses` | `retain.synthesized_uses` |  |
| `retain_attributes` | `retain.attributes` |  |
| `detect_unused_asset_catalog_colors` | `rules.unused-asset-color` | `true` is `on` |
| `detect_unused_asset_catalog_images` | `rules.unused-asset-image` | `true` is `on` |
| `detect_unused_metal_functions` | `analysis.metal_functions` |  |
<!-- v1-v2-keys:end -->
