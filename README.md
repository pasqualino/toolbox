# Toolbox

A native macOS toolbox: 114 tools for text, code, screenshots, images, PDFs, audio, video, the network and the Mac. SwiftUI, macOS 26+. Everything runs on device.

Press **⌃⌥Space** from any app, type what you need, drop files, press Return. With files selected in Finder, the shortcut opens straight to the tools that take them. Change the shortcut in Settings.

## Tools

| Category | Examples |
|---|---|
| Writing | Rewrite, Summarize, Translate (on-device AI), Change Case, Lines, Text Diff |
| Developer | Base64, URL encoding, hashes, JSON/GraphQL/SQL/XML formatting, JSON ⇄ YAML/CSV, JWT, epoch, cron, IDs |
| Screen & Scan | Capture Text, Extract Text, Beautify Screenshot, Redact Image, QR Code |
| Images | Convert, Compress, Resize, Rotate, Remove Background, Remove Metadata |
| PDF | Merge, Split, Organize, Delete or Extract Pages, PDF Password, PDF ⇄ Images |
| Audio & Video | Trim, Crop, Speed, Merge, Compress, Convert, GIF, Download, Transcribe, Media Info |
| Network | Speed Test (history per network), Network Health |
| Mac | Keep Awake, Fix "App Is Damaged", Batch Rename |

Related tools share one row with pills to switch between them (Change Case: camelCase | snake_case | …). Text and dropped files carry over when you switch. `ToolRegistry.layout` in `ToolGroup.swift` decides the categories, sections and groups.

The 68 text tools update as you type. From the palette, **Return** opens one with the clipboard loaded, and **⌥Return** runs it on the clipboard in place.

## Results

Each run saves to `~/Downloads/Toolbox/<date> <tool>/`; change the folder in Settings. Originals are never changed, except by Batch Rename in "Rename originals" mode. Tools that only produce text show it instead of saving a file.

**Run and Copy** puts the result on the clipboard without saving it to the output folder: files as files, a single image also as a picture, text as text. ⌥-click the run button (it reads "Make & Copy" while ⌥ is held), press ⌥⌘Return, or use Tool › Run and Copy. After a normal run, Copy sits next to Show in Finder.

## Keyboard

| Keys | Action |
|---|---|
| ⌃⌥Space | Palette, from any app |
| ⌘K | Palette, inside Toolbox |
| ⌘F | Search tools in the sidebar; ↓ moves into the results |
| ⌥⌘S | Focus the sidebar; arrows move, ←/→ collapse and expand, Return opens |
| ⌘1…⌘8, ⌘9, ⌘0 | Categories, Favorites, Recent |
| ⌘O | Choose files |
| ⌘Return / ⌥⌘Return | Run / Run and Copy |
| ⌘. | Stop |
| ⇧⌘R | Show results in Finder |
| ⌃Tab, ⌃⇧Tab | Next or previous pill in a group |
| ⌘D | Add to Favorites, or remove |
| ⇧⌘N | Open the tool in a new window |
| ⇧⌘⌫ | Clear files |

## Services

Select text or files in any app, then right-click › Services:

| Service | Does |
|---|---|
| Toolbox: Rewrite / Fix Grammar | Replaces the selection with the rewritten text |
| Toolbox: Format JSON | Replaces the selection with formatted JSON |
| Toolbox: Decode JWT | Opens Decode JWT with the token |
| Toolbox: Open Text in Toolbox | Opens the palette with the text loaded |
| Toolbox: Open in Toolbox | Opens the palette with the tools for the selected files |

Give any of them a shortcut in System Settings › Keyboard › Keyboard Shortcuts › Services.

## Shortcuts

Six actions appear under Toolbox in the Shortcuts app, and work in automations and Spotlight:

| Action | Takes | Gives |
|---|---|---|
| Convert Images | Images, format, quality | Images |
| Compress Images | Images, format, quality | Images |
| Extract Text | An image or PDF | Text |
| Rewrite Text | Text, mode, tone, length (needs Apple Intelligence) | Text |
| Make QR Code | A link or text | PNG |
| Format JSON | JSON, sort keys | Text |

Results go back to Shortcuts; nothing is saved to the output folder. Toolbox runs them in the background without opening its window.

## Build and run

```bash
./make-app.sh --open
```

This builds `Toolbox.app` in release mode, signs it, registers it and launches it. Video, audio and download tools need Homebrew's `ffmpeg` and `yt-dlp`; WebP output needs `webp`. The app offers to install them.

Run `Support/make-signing-identity.sh` once. It creates a self-signed "Toolbox Dev" code-signing certificate in your login keychain, and asks for your password to trust it. `make-app.sh` then signs with it, so macOS keeps Screen Recording, Location and other permissions across rebuilds. Without it, builds are signed ad hoc and those permissions reset each time. To remove it, delete "Toolbox Dev" in Keychain Access.

## Development

| Path | What |
|---|---|
| `Sources/ToolboxCore` | UI-free engine. Each tool is a `Tool` with declarative options and a runner. |
| `Sources/ToolboxCore/Tools` | Tool definitions, by area. `ToolRegistry.swift` collects them. |
| `Sources/Toolbox` | The app: palette, main window, editors, settings. |
| `Sources/toolbox-cli` | Headless runner for tests. |
| `Fixtures` | Test inputs and check scripts. |

The CLI runs any tool without the app:

```bash
toolbox-cli list                                # every tool and its options
toolbox-cli layout                              # categories and groups; flags tools missing from the layout
toolbox-cli <tool-id> key=value… files…         # file tools
toolbox-cli <tool-id> --text "…"                # text tools; or pipe stdin
```

### Tests

526 checks, run against the release CLI. Optimizations once exposed an engine bug that debug builds hid, so always test release.

```bash
./test.sh              # builds the release CLI, runs every Fixtures/**/check-*.sh, prints a total
./test.sh dev media    # only scripts whose path contains one of the words
```

It exits non-zero if any check fails, and prints each failure with what it wanted and got.

| Script | Checks | Covers |
|---|---|---|
| `Fixtures/dev/check-{enc,fmt,txt}.sh` | 284 | Text tools |
| `Fixtures/media/check-media.sh` | 48 | Audio and video |
| `Fixtures/check-other.sh` | 27 | Image, PDF, AI, download |
| `Fixtures/batch1/check-*.sh` | 167 | Image edits, Mac, media extras, network |

`check-mac.sh`, `check-net.sh` and `check-other.sh` need a network connection. To run one script by hand: `CLI=$PWD/.build/release/toolbox-cli zsh Fixtures/dev/check-txt.sh`.

### Lint

`./lint.sh` checks the Swift sources with swift-format (`.swift-format`: 4 spaces, 120 columns). `./lint.sh --fix` reformats in place first. AGENTS.md lists the style rules.

`./make-app.sh --debug-hooks` adds the `TOOLBOX_SNAPSHOT` screenshot and `TOOLBOX_DEBUG` logging hooks (`Sources/Toolbox/App/Snapshot.swift`). Normal builds leave them out.
