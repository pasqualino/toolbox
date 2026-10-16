import SwiftUI

/// Renders "Label  value" report text (Media Info, Fix "App Is Damaged", Read QR Code) as a two-column table
/// with section headings, instead of space-aligned text that only lines up in a monospaced font.
struct ReportView: View {
    let text: String

    var body: some View {
        let blocks = ReportParser.parse(text)
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                    switch block {
                    case .heading(let title):
                        Text(title)
                            .font(.headline)
                            .padding(.top, 4)
                    case .paragraph(let line):
                        Text(line)
                            .foregroundStyle(.secondary)
                    case .rows(let rows):
                        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                                GridRow(alignment: .firstTextBaseline) {
                                    Text(row.label)
                                        .foregroundStyle(.secondary)
                                        .gridColumnAlignment(.trailing)
                                    Text(row.value)
                                        .monospacedDigit()
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }
                }
            }
            .font(.system(size: 13.5))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
        }
    }

    /// True when the text is mostly label/value rows, so the table reads better than plain text.
    static func looksLikeReport(_ text: String) -> Bool {
        let lines = text.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard lines.count >= 3 else { return false }
        let rows = lines.filter { ReportParser.split(String($0)) != nil }.count
        return Double(rows) / Double(lines.count) >= 0.5
    }
}

enum ReportParser {
    struct Row {
        let label: String
        var value: String
    }

    enum Block {
        case heading(String)
        case paragraph(String)
        case rows([Row])
    }

    /// "Download       293 Mbps" → ("Download", "293 Mbps"). A label is followed by two or more spaces.
    static func split(_ line: String) -> (String, String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let range = trimmed.range(of: #"\s{2,}"#, options: .regularExpression) else { return nil }
        let label = String(trimmed[..<range.lowerBound])
        let value = String(trimmed[range.upperBound...])
        guard !label.isEmpty, !value.isEmpty, label.count <= 40 else { return nil }
        return (label, value)
    }

    static func parse(_ text: String) -> [Block] {
        var blocks: [Block] = []
        var rows: [Row] = []
        func flush() {
            if !rows.isEmpty { blocks.append(.rows(rows)) }
            rows = []
        }
        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                flush()
                continue
            }
            if let (label, value) = split(raw) {
                rows.append(Row(label: label, value: value))
            } else if raw.hasPrefix("  "), !rows.isEmpty {
                // Indented continuation of the previous value (wrapped lists, second date line).
                rows[rows.count - 1].value += "\n" + line
            } else if line.count <= 48, !line.hasSuffix("."), rows.isEmpty || line.first?.isUppercase == true {
                flush()
                blocks.append(.heading(line.trimmingCharacters(in: CharacterSet(charactersIn: ":"))))
            } else {
                flush()
                blocks.append(.paragraph(line))
            }
        }
        flush()
        return blocks
    }
}
