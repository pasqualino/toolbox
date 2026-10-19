import AppKit
import SwiftUI
import ToolboxCore
import UniformTypeIdentifiers

struct OptionsPanel: View {
    let session: ToolSession

    var body: some View {
        Panel {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Options")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    if session.options != Options.defaults(for: session.tool) {
                        Button("Reset") { session.resetOptions() }
                            .buttonStyle(.borderless)
                            .font(.callout)
                    }
                }
                .padding(.horizontal, 14)
                .frame(height: 36)
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(session.tool.options) { spec in
                            if session.options.isVisible(spec, among: session.tool.options), spec.id != session.primaryEditor?.id {
                                OptionRow(spec: spec, session: session)
                                    .transition(.opacity)
                            }
                        }
                    }
                    .padding(14)
                    .animation(.snappy(duration: 0.18), value: session.options)
                }
            }
        }
        .disabled(session.phase == .running)
    }
}

private struct OptionRow: View {
    let spec: OptionSpec
    let session: ToolSession

    private var value: Binding<String> { session.binding(for: spec.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !isToggle {
                Text(spec.label)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            control
            if let help = spec.help {
                Text(help)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var isToggle: Bool {
        if case .toggle = spec.kind { return true }
        return false
    }

    @ViewBuilder
    private var control: some View {
        switch spec.kind {
        case .choice(let choices, _):
            if choices.count <= 3 && choices.allSatisfy({ $0.label.count <= 9 }) {
                Picker(spec.label, selection: value) {
                    ForEach(choices, id: \.value) { Text($0.label).tag($0.value) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            } else {
                Picker(spec.label, selection: value) {
                    ForEach(choices, id: \.value) { Text($0.label).tag($0.value) }
                }
                .labelsHidden()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .toggle:
            Toggle(spec.label, isOn: session.boolBinding(for: spec.id))
                .toggleStyle(.switch)
                .controlSize(.small)
        case .slider(let range, let step, _, let format):
            SliderOption(value: value, range: range, step: step, format: format)
        case .number(let range, _, let unit):
            HStack {
                TextField("", value: session.numberBinding(for: spec.id, range: range), format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 90)
                Text(unit).foregroundStyle(.secondary)
            }
        case .text(_, let placeholder):
            TextField(placeholder, text: value)
                .textFieldStyle(.roundedBorder)
        case .secureText(let placeholder):
            SecureField(placeholder, text: value)
                .textFieldStyle(.roundedBorder)
        case .language(_, let allowsDetect):
            LanguagePicker(value: value, allowsDetect: allowsDetect)
        case .file(let types, let placeholder):
            FileOption(value: value, types: types, placeholder: placeholder)
        case .timeRange:
            if let url = session.items.first?.url {
                TimeRangeEditor(url: url, value: value)
                    .id(url)
            } else {
                hint("Add a file to pick a range.")
            }
        case .pageSelection:
            if let url = session.items.first?.url {
                PageSelectionEditor(url: url, value: value)
                    .id(url)
            } else {
                hint("Add a PDF to pick pages.")
            }
        case .regions:
            hint("Draw boxes on the preview.")
        case .pageArrangement:
            if let url = session.items.first?.url {
                PageArrangementEditor(url: url, value: value)
                    .id(url)
            } else {
                hint("Add a PDF to arrange its pages.")
            }
        }
    }

    private func hint(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.tertiary)
    }
}

enum OptionSpecFormat {
    static func number(_ d: Double) -> String {
        d == d.rounded() ? String(Int(d)) : String(d)
    }
}

private struct SliderOption: View {
    @Binding var value: String
    let range: ClosedRange<Double>
    let step: Double
    let format: String

    var body: some View {
        let number = Binding(get: { Double(value) ?? range.lowerBound },
                             set: { value = OptionSpecFormat.number(($0 / step).rounded() * step) })
        HStack(spacing: 10) {
            Slider(value: number, in: range)
                .controlSize(.small)
            Text(label(number.wrappedValue))
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 44, alignment: .trailing)
        }
    }

    /// "%.0f%%" on a 0...1 range shows a percentage.
    private func label(_ v: Double) -> String {
        if format.contains("%%") && range.upperBound <= 1 { return String(format: format, v * 100) }
        return String(format: format, v)
    }
}

private struct FileOption: View {
    @Binding var value: String
    let types: [UTType]
    let placeholder: String
    @State private var targeted = false

    var body: some View {
        HStack(spacing: 8) {
            if value.isEmpty {
                Image(systemName: "doc.badge.plus").foregroundStyle(.secondary)
                Text(placeholder).foregroundStyle(.secondary).lineLimit(1)
            } else {
                Image(nsImage: FileIcons.icon(for: value))
                    .resizable().frame(width: 18, height: 18)
                Text(URL(fileURLWithPath: value).lastPathComponent).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 4)
            Button(value.isEmpty ? "Choose…" : "Change…") { choose() }
                .controlSize(.small)
        }
        .padding(8)
        .background(targeted ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.04),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            value = url.path
            return true
        } isTargeted: { targeted = $0 }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = types
        if panel.runModal() == .OK, let url = panel.url { value = url.path }
    }
}

private struct LanguagePicker: View {
    @Binding var value: String
    let allowsDetect: Bool

    static let languages: [(code: String, name: String)] = {
        let codes = ["en", "es", "fr", "de", "it", "pt", "nl", "pl", "ru", "uk", "tr", "ar", "hi",
                     "id", "vi", "th", "ja", "ko", "zh-Hans", "zh-Hant"]
        let current = Locale.current
        return codes.map { ($0, current.localizedString(forIdentifier: $0) ?? $0) }
            .sorted { $0.name < $1.name }
    }()

    var body: some View {
        Picker("Language", selection: $value) {
            if allowsDetect { Text("Detect automatically").tag("") }
            ForEach(Self.languages, id: \.code) { Text($0.name).tag($0.code) }
            if !value.isEmpty, !Self.languages.contains(where: { $0.code == value }) {
                Text(Locale.current.localizedString(forIdentifier: value) ?? value).tag(value)
            }
        }
        .labelsHidden()
    }
}
