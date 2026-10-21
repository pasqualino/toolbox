# Toolbox

Native macOS all-in-one file toolbox. SwiftUI, macOS 26+, runs fully on device.

Press **⌃⌥Space** from any app, type what you need, drop files, press Return. With files selected in Finder, the shortcut opens straight to the tools that take them.

## Developer tools

68 live text tools (case, lines, encoding and formatting, plus workflow ones: JWT, epoch, cron, GraphQL, JSON to Go/TS, IDs, diff). Input on the left, output updates as you type. From the palette:

- **Return** opens the tool with your clipboard already loaded.
- **⌥Return** runs it on the clipboard in place and shows a "Copied" toast.

From the CLI: `toolbox-cli <tool-id> --text "..."` or pipe stdin.

## In every app

Select text or files anywhere, right-click → **Services**:

| Service | Does |
|---|---|
| Toolbox: Rewrite / Fix Grammar | Replaces the selection with the rewritten text (on-device model) |
| Toolbox: Format JSON | Replaces the selection with formatted JSON |
| Toolbox: Decode JWT | Opens Decode JWT with the token |
| Toolbox: Open Text in Toolbox | Palette with text tools, text preloaded |
| Toolbox: Open in Toolbox (files) | Palette filtered to tools for the selected files |

Give any of them a shortcut in System Settings → Keyboard → Keyboard Shortcuts → Services.

## Navigation

Favorites (right-click a tool, or ⌘D), Recent, 8 task-based categories (Writing, Developer, Screen & Scan, Images, PDF, Audio & Video, Network, Mac; arranged in `ToolRegistry.layout`), toolbar search (⌘F), the Jobs button for runs in progress, and Open in New Window (⌘⇧N) to keep a tool beside the main window.

## Build and run

```bash
./make-app.sh --open
```

That builds `Toolbox.app` (release), signs it ad hoc, and launches it. Video, audio and download tools need Homebrew's `ffmpeg` and `yt-dlp`; WebP output needs `webp`. The app offers to install them.

## Layout

| Path | What |
|---|---|
| `Sources/ToolboxCore` | UI-free tool engine. Every tool is a `Tool` with declarative options and a runner. |
| `Sources/ToolboxCore/Tools` | Tool definitions per group. `ToolRegistry.swift` lists them. |
| `Sources/Toolbox` | The app: palette, main window, editors, settings. |
| `Sources/toolbox-cli` | Headless runner: `toolbox-cli list`, `toolbox-cli <tool-id> key=value… files…` |
| `Fixtures` | Test inputs and check scripts. |

## Tests

```bash
swift build -c release --product toolbox-cli
zsh Fixtures/media/check-media.sh && zsh Fixtures/check-other.sh
for s in Fixtures/dev/check-*.sh; do TZ=Europe/Berlin zsh $s </dev/null; done
```

526 checks: 284 developer tools, 48 media (ffprobe), 27 image/PDF/AI/download, and 167 more in `Fixtures/batch1` (`for s in Fixtures/batch1/check-*.sh; do zsh $s </dev/null; done`; the Mac and network ones need a connection). Always test release builds: one engine bug only showed up with optimizations on.

`./make-app.sh --debug-hooks` builds an app with the `TOOLBOX_SNAPSHOT` screenshot and `TOOLBOX_DEBUG` logging hooks (`Sources/Toolbox/App/Snapshot.swift`); normal builds leave them out.

## Output

Each run writes to `~/Downloads/Toolbox/<date> <tool>/` (changeable in Settings). Originals are never changed, except by Batch Rename in "Rename originals" mode.
