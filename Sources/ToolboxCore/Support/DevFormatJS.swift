import Foundation
import JavaScriptCore

/// Runs a snippet in a fresh JavaScriptCore context with a `console` that records what it prints.
enum DevFormatJS {
    static let timeLimit = 1.0

    private typealias SetLimit = @convention(c) (JSContextGroupRef, Double, OpaquePointer?, UnsafeMutableRawPointer?) -> Void

    /// JSContextGroupSetExecutionTimeLimit is exported by JavaScriptCore but not in the public headers.
    /// Without it an endless loop would pin a worker thread for good, so it's looked up at runtime.
    private static let setLimit: SetLimit? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "JSContextGroupSetExecutionTimeLimit") else { return nil }
        return unsafeBitCast(symbol, to: SetLimit.self)
    }()

    private static let prelude = """
    var __out = [];
    function __fmt(v, top) {
      if (typeof v === 'string') return top ? v : JSON.stringify(v);
      if (v === undefined) return 'undefined';
      if (typeof v === 'function') return v.toString().split('\\n')[0].replace(/\\s*\\{.*$/, '') + ' { ... }';
      if (typeof v === 'symbol' || typeof v === 'bigint') return v.toString() + (typeof v === 'bigint' ? 'n' : '');
      if (v instanceof Error) return v.name + ': ' + v.message;
      if (typeof v === 'number' && !isFinite(v)) return String(v);
      if (v instanceof Map) return 'Map ' + __fmt(Object.fromEntries(v));
      if (v instanceof Set) return 'Set ' + __fmt(Array.from(v));
      try {
        var seen = [];
        var s = JSON.stringify(v, function (k, x) {
          if (typeof x === 'bigint') return x.toString();
          if (typeof x === 'object' && x !== null) { if (seen.indexOf(x) >= 0) return '[Circular]'; seen.push(x); }
          if (typeof x === 'function') return '[Function]';
          return x === undefined ? null : x;
        }, 2);
        return s === undefined ? String(v) : s;
      } catch (e) { return String(v); }
    }
    function __log() { __out.push(Array.prototype.map.call(arguments, function (a) { return __fmt(a, true); }).join(' ')); }
    var console = { log: __log, info: __log, warn: __log, error: __log, debug: __log, trace: __log,
      table: function (x) { __log(x); }, dir: function (x) { __log(x); } };
    """

    static func evaluate(_ source: String) throws -> String {
        if source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "" }
        let group = JSContextGroupCreate()!
        defer { JSContextGroupRelease(group) }
        setLimit?(group, timeLimit, nil, nil)
        let globalRef = JSGlobalContextCreateInGroup(group, nil)!
        defer { JSGlobalContextRelease(globalRef) }
        guard let context = JSContext(jsGlobalContextRef: globalRef) else { throw ToolError.message("Couldn't start JavaScript.") }
        context.evaluateScript(prelude)
        var thrown: JSValue?
        context.exceptionHandler = { _, exception in thrown = exception }
        let started = Date()
        let result = context.evaluateScript(source, withSourceURL: URL(string: "input.js"))
        let logs = context.objectForKeyedSubscript("__out")?.toArray()?.compactMap { $0 as? String } ?? []
        if let exception = thrown {
            let message = exception.toString() ?? "Error"
            if Date().timeIntervalSince(started) >= timeLimit * 0.9 || message.contains("terminated") {
                throw ToolError.message("Stopped after 1 second. Is there an endless loop?")
            }
            let line = exception.objectForKeyedSubscript("line")?.toInt32() ?? 0
            throw ToolError.message(line > 0 ? "\(message) (line \(line))" : message)
        }
        var text = ""
        if let result, !(result.isUndefined && !logs.isEmpty) {
            let fmt = context.objectForKeyedSubscript("__fmt")
            text = fmt?.call(withArguments: [result, true])?.toString() ?? ""
        }
        return (logs + (text.isEmpty ? [] : [text])).joined(separator: "\n")
    }
}
