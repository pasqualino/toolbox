# Agent guide

Native macOS app (SwiftUI, macOS 26+, Swift 6 language mode). README.md covers features, the CLI and the test commands. This file covers where things live and how to change them safely.

## Map

| Path | What |
|---|---|
| `Sources/ToolboxCore` | UI-free engine. No SwiftUI or AppKit views here. |
| `Sources/ToolboxCore/Model` | `Tool`, `OptionSpec`/`Options`, `ToolGroup` (holds `ToolRegistry.layout`). |
| `Sources/ToolboxCore/Tools` | Tool definitions, one file per area, each with `static let all`. |
| `Sources/ToolboxCore/Support` | The work behind tools (PDF, media, OCR, QR, text transforms). |
| `Sources/Toolbox/App` | `AppModel` (routing, groups, favorites, search), `ToolSession` (one tool's state and runs), `ToolFlow` (tools with custom views), Services, hot key. |
| `Sources/Toolbox/Views` | `ToolView` (file tools), `TextToolView` (live text tools), `RunBar`, `OptionsPanel`, sidebar in `MainView`. |
| `Sources/Toolbox/Palette` | The ⌃⌥Space palette, `ToolSearch`, and `Presets` (format and size shortcuts like "png", built from tools' options). |
| `Support/Info.plist` | Copied into the app by `make-app.sh`: Services, usage descriptions. |
| `Fixtures` | Inputs and zsh check scripts. |

## Adding or changing a tool

1. Define it in the matching `Tools/*.swift` file and add it to that file's `all`. A new file also goes in `ToolRegistry.all`.
2. Place it in `ToolRegistry.layout` (`Model/ToolGroup.swift`). The layout sets its category, order and group. `toolbox-cli layout` must print no `UNPLACED` or `MISSING`.
3. Describe options with `OptionSpec`; the Options panel draws them. Use `visibleWhen` for dependent options. Secrets use `.secureText`, which is never persisted.
4. Add checks to the matching `Fixtures` script and run it against the release CLI.

Live text tools are `Tool.text(…)` with a pure `transform`. Tools that need a custom screen get a `ToolFlow` case and their own view.

## Shortcuts actions

`App/ShortcutsIntents.swift` holds the App Intents. Each one runs a registry tool through `ShortcutsRunner` in a scratch folder and returns the result as data. To add one: write the intent there, add it to `ToolboxShortcuts` (at most 10 entries), and add it to `runIntents` in `App/Snapshot.swift`.

Shortcuts only finds actions through `Contents/Resources/Metadata.appintents`. Xcode normally generates it; here `Package.swift` makes the compiler emit const values for the app target, and `make-app.sh` runs `xcrun appintentsmetadataprocessor` on them before signing. Check `extract.actionsdata` in that bundle lists the new action. To test every action without Shortcuts, use a `--debug-hooks` build with `TOOLBOX_INTENTS=<image>:<image with text>`.

## Build and verify

- `./make-app.sh` builds, signs and registers `Toolbox.app`. Relaunch with `pkill -x Toolbox; open Toolbox.app`.
- `./test.sh` builds the release CLI and runs every check script; it must pass before a commit. `./test.sh <word>` runs only the scripts whose path matches. Test release builds only. New checks go in the matching `Fixtures/**/check-*.sh`, ending with the `N passed, M failed` line test.sh reads.
- For UI changes, build with `./make-app.sh --debug-hooks` and take snapshots with `TOOLBOX_SNAPSHOT=<dir>` plus the `TOOLBOX_*` variables in `App/Snapshot.swift`. Run snapshots from a copy of the app with its own bundle id, and with `NSLocationWhenInUseUsageDescription` and `NSServices` removed from its Info.plist. That keeps tests out of the user's settings and stops permission prompts from appearing on screen. Rebuild without the hooks afterwards.
- A run in a snapshot saves real files. Point `outputFolder` (in the copy's defaults) at a scratch folder.

## Code style

The code is formatted by swift-format with `.swift-format` (4-space indent, 120 columns). `./lint.sh` must pass before a commit; `./lint.sh --fix` reformats in place and leaves only what needs a hand fix. Write code in this shape from the start so the formatter has little to change:

- One statement per line. No `;`, so no `{ a(); b() }` closures or `case "x": a; case "y": b` on one line.
- A single-statement body may stay on one line: `if done { return }`, `Button("Copy") { copy() }`. An `if` with `else` takes the multi-line form.
- Wrapped arguments use a hanging indent: break after `(`, indent 4, close on the last argument's line. Don't align under the opening parenthesis.
- Multi-line collection literals end with a trailing comma.
- One `var`/`let` per line, one enum `case` per line.
- `for x in xs { … }`, not `xs.forEach { … }`.
- lowerCamelCase names. Map snake_case JSON keys with `CodingKeys`.
- `//` and `///` comments only, no `/* */`.

Periphery (`brew install periphery`, then `periphery scan`) finds unused code. It builds without `--debug-hooks`, so code used only by `App/Snapshot.swift` shows up as unused; check before deleting.

## Conventions

- Comments: short, say why, match the surrounding density.
- Concurrency: UI state is `@MainActor`. Shared mutable state off the main actor goes in a `Mutex` or `Atomic`, not `@unchecked Sendable` or `nonisolated(unsafe)`. The code has none of either; keep it that way.
- User-facing text: short sentences, no em dashes.
- `make-app.sh` signs with the "Toolbox Dev" identity when it exists, and ad hoc otherwise. Ad hoc builds lose Screen Recording and Location on every rebuild. Creating the identity changes the user's keychain, so the user runs `Support/make-signing-identity.sh` themselves.
- Commit when asked. Push to `origin` (github.com/pasqualino/toolbox, public) only when asked.
