import Foundation
import ToolboxCore

// Headless runner for testing tools.
//   toolbox-cli list
//   toolbox-cli <tool-id> [key=value ...] [--text "..."] [--out DIR] file...

let args = Array(CommandLine.arguments.dropFirst())

guard let first = args.first else {
    print("usage: toolbox-cli list | <tool-id> [key=value ...] [--text TEXT] [--out DIR] file...")
    exit(2)
}

if first == "list" {
    for tool in ToolRegistry.all {
        let opts = tool.options.map { "\($0.id)=\($0.defaultValue)" }.joined(separator: " ")
        print("\(tool.id)\n    \(opts)")
    }
    exit(0)
}

if first == "layout" {
    // Prints each category's sections and flags group members that don't exist.
    for cat in ToolCategory.allCases {
        print("\(cat.title) (\(ToolRegistry.entryCount(in: cat)) rows)")
        for section in ToolRegistry.sections(in: cat) {
            print("  [\(section.title ?? "-")]")
            for entry in section.entries {
                if case .group(let g) = entry {
                    let missing = g.members.filter { ToolRegistry.tool(id: $0.toolID) == nil }.map(\.toolID)
                    print("    \(g.name): \(g.members.map(\.label).joined(separator: " | "))\(missing.isEmpty ? "" : "  MISSING \(missing)")")
                } else {
                    print("    \(entry.name)")
                }
            }
        }
    }
    exit(0)
}

guard let tool = ToolRegistry.tool(id: first) else {
    FileHandle.standardError.write("unknown tool \(first)\n".data(using: .utf8)!)
    exit(2)
}

var options = Options.defaults(for: tool)
// TOOLBOX_MEDIAINFO_AVFOUNDATION=1 makes Media Info use its AVFoundation fallback, for testing without uninstalling FFmpeg.
if ProcessInfo.processInfo.environment["TOOLBOX_MEDIAINFO_AVFOUNDATION"] == "1", tool.options.contains(where: { $0.id == "avfoundation" }) {
    options["avfoundation"] = "true"
}
var files: [URL] = []
var text = ""
var text2 = ""
var textGiven = false
var outRoot = ToolEngine.defaultOutputRoot
var i = 1
while i < args.count {
    let arg = args[i]
    if arg == "--text", i + 1 < args.count {
        text = args[i + 1]
        textGiven = true
        i += 2
        continue
    }
    if arg == "--text2", i + 1 < args.count {
        text2 = args[i + 1]
        i += 2
        continue
    }
    if arg == "--out", i + 1 < args.count {
        outRoot = URL(fileURLWithPath: args[i + 1])
        i += 2
        continue
    }
    if let eq = arg.firstIndex(of: "="), !FileManager.default.fileExists(atPath: arg) {
        options[String(arg[..<eq])] = String(arg[arg.index(after: eq)...])
    } else {
        files.append(URL(fileURLWithPath: arg))
    }
    i += 1
}

// Text tools: print the output and exit. Input from --text, or stdin when it's piped.
if tool.isTransform {
    if !textGiven, isatty(STDIN_FILENO) == 0 {
        text = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
    }
    do {
        print(try tool.apply(TextInput(text, secondary: text2), options: options))
        exit(0)
    } catch {
        FileHandle.standardError.write("error: \(error.localizedDescription)\n".data(using: .utf8)!)
        exit(1)
    }
}

// Ctrl-C cancels the run, which terminates any child process (ffmpeg) and cleans up staging.
final class TextFlag: @unchecked Sendable { var seen = false }
let gotText = TextFlag()
let run = Task {
    await ToolEngine.run(tool, inputs: files, text: text, options: options, outputRoot: outRoot) { event in
        switch event {
        case .itemFailed(let i, let message): print("FAIL [\(i)] \(message)")
        case .itemFinished(let i, let outputs):
            print("ok   [\(i)] \(outputs.isEmpty ? "(text)" : outputs.map(\.lastPathComponent).joined(separator: ", "))")
        case .text(_, let t):
            gotText.seen = true
            print("text: \(t)")
        default: break
        }
    }
}
signal(SIGINT, SIG_IGN)
let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
interrupt.setEventHandler { run.cancel() }
interrupt.resume()
let result = await run.value
for url in result.outputs { print("-> \(url.path)") }
exit(result.failures == 0 && (!result.outputs.isEmpty || gotText.seen) ? 0 : 1)
