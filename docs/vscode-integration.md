---
description: Run outskirts from VS Code without an extension: a tasks.json with a problem matcher that lists unused code in the Problems tab.
---

# VS Code integration

Results of the `xcode` format are lines of the form `path:line:column: warning: message`, which VS Code can read with a [problem matcher](https://code.visualstudio.com/docs/editor/tasks#_defining-a-problem-matcher). No extension is needed: a task runs `outskirts scan` and each result shows up in the Problems tab, with a squiggle in the editor and a click to jump to the declaration.

Before setting up a task, get outskirts working in a terminal, as the task runs the same command. Install it as described in [Getting started](getting-started.md), e.g. with `brew install tiny-earth-moon/tap/outskirts`, and run a first scan there.

## The task

Create `.vscode/tasks.json` at the root of your workspace, next to your `.xcodeproj` or `Package.swift`:

```json
{
  "version": "2.0.0",
  "tasks": [
    {
      "label": "outskirts: scan",
      "type": "shell",
      "command": "outskirts",
      "args": ["scan", "--format", "xcode", "--color", "never"],
      "options": { "cwd": "${workspaceFolder}" },
      "problemMatcher": {
        "owner": "outskirts",
        "source": "outskirts",
        "fileLocation": ["autoDetect", "${workspaceFolder}"],
        "pattern": {
          "regexp": "^(.+):(\\d+):(\\d+): (\\w+): (.*)$",
          "file": 1,
          "line": 2,
          "column": 3,
          "severity": 4,
          "message": 5
        }
      },
      "presentation": { "reveal": "silent", "clear": true }
    }
  ]
}
```

- `--format xcode` prints one result per line. `--color never` keeps escape codes out of the lines the matcher reads; colors are only used when the output is a terminal, but the task makes it explicit.
- The other lines outskirts prints, such as the progress messages and the [summary](output-formats.md), do not match the pattern and are ignored.
- `fileLocation` is `autoDetect` because the `xcode` format prints absolute paths, or paths relative to the project root with `--relative-results` (see [Output formats](output-formats.md#paths)); both resolve against the workspace folder.
- If VS Code cannot find `outskirts` because it does not start from a shell, use the absolute path in `command`, e.g. `/opt/homebrew/bin/outskirts`.

## Run it

Open the Command Palette and choose **Tasks: Run Task**, then **outskirts: scan**. The scan builds your project and lists the results in the Problems tab (View, Problems), grouped by file. Each result is a warning, and a new run replaces the results of the previous one.

> [!NOTE]
> A scan builds the project to get its index store, so it takes as long as a build. Run it when you want to look for unused code, not on every save: a task like this one is not bound to file saves, and should stay that way.

## Xcode project or Swift package

Keep what your project needs in `.outskirts.yml` at the workspace root, which outskirts reads like in a terminal, so that the task stays the same for every project. See [Configuration](configuration.md) and [Getting started](getting-started.md#quick-start).

- **Swift package**: nothing more is needed; `outskirts scan` detects `Package.swift`.
- **Xcode project**: set the project and schemes in the configuration file, or add them to `args`, e.g. `"--project", "MyApp.xcodeproj", "--schemes", "MyApp"`. If the build needs a destination, pass it after `--`, as in [Xcode integration](xcode-integration.md). `outskirts scan --setup` writes these choices for you.
- Every option is in the [options reference](options.md).

To report from a build you already made, add `--skip-build` to `args`: the scan then takes seconds and shows the results of that build, see [Finding the index store](getting-started.md#finding-the-index-store).
