# Agent guide

Native macOS app (SwiftUI, macOS 26+, Swift 5 language mode). README.md covers features, the CLI and the test commands. This file covers where things live and how to change them safely.

## Map

| Path | What |
|---|---|
| `Sources/ToolboxCore` | UI-free engine. No SwiftUI or AppKit views here. |
| `Sources/ToolboxCore/Model` | `Tool`, `OptionSpec`/`Options`, `ToolGroup` (holds `ToolRegistry.layout`). |
| `Sources/ToolboxCore/Tools` | Tool definitions, one file per area, each with `static let all`. |
| `Sources/ToolboxCore/Support` | The work behind tools (PDF, media, OCR, QR, text transforms). |
| `Sources/Toolbox/App` | `AppModel` (routing, groups, favorites, search), `ToolSession` (one tool's state and runs), `ToolFlow` (tools with custom views), Services, hot key. |
| `Sources/Toolbox/Views` | `ToolView` (file tools), `TextToolView` (live text tools), `RunBar`, `OptionsPanel`, sidebar in `MainView`. |
| `Sources/Toolbox/Palette` | The ⌃⌥Space palette and `ToolSearch`. |
| `Support/Info.plist` | Copied into the app by `make-app.sh`: Services, usage descriptions. |
| `Fixtures` | Inputs and zsh check scripts. |

## Adding or changing a tool

1. Define it in the matching `Tools/*.swift` file and add it to that file's `all`. A new file also goes in `ToolRegistry.all`.
2. Place it in `ToolRegistry.layout` (`Model/ToolGroup.swift`). The layout sets its category, order and group. `toolbox-cli layout` must print no `UNPLACED` or `MISSING`.
3. Describe options with `OptionSpec`; the Options panel draws them. Use `visibleWhen` for dependent options. Secrets use `.secureText`, which is never persisted.
4. Add checks to the matching `Fixtures` script and run it against the release CLI.

Live text tools are `Tool.text(…)` with a pure `transform`. Tools that need a custom screen get a `ToolFlow` case and their own view.

## Build and verify

- `./make-app.sh` builds, signs and registers `Toolbox.app`. Relaunch with `pkill -x Toolbox; open Toolbox.app`.
- Test release builds only: `swift build -c release --product toolbox-cli`, then the scripts in README.md. They're zsh scripts; run them with `zsh`, and `check-txt.sh` with `TZ=Europe/Berlin`.
- For UI changes, build with `./make-app.sh --debug-hooks` and take snapshots with `TOOLBOX_SNAPSHOT=<dir>` plus the `TOOLBOX_*` variables in `App/Snapshot.swift`. Run snapshots from a copy of the app with its own bundle id, and with `NSLocationWhenInUseUsageDescription` and `NSServices` removed from its Info.plist. That keeps tests out of the user's settings and stops permission prompts from appearing on screen. Rebuild without the hooks afterwards.
- A run in a snapshot saves real files. Point `outputFolder` (in the copy's defaults) at a scratch folder.

## Conventions

- Comments: short, say why, match the surrounding density.
- User-facing text: short sentences, no em dashes.
- Ad hoc signing means Screen Recording and Location may need re-granting after a rebuild.
- No git remote: commit when asked, never push.
