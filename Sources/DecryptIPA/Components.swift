import SwiftUI

struct LogRowView: View {
    let entry: LogEntry

    var color: Color {
        switch entry.level {
        case .info: return .primary
        case .warn: return .orange
        case .error: return .red
        case .success: return .green
        case .command: return .accentColor
        case .debug: return .secondary
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Text(entry.level.symbol)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(color)
                .frame(width: 10, alignment: .leading)
            Text(entry.text)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(color)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct LogConsole: View {
    let entries: [LogEntry]
    let maxHeight: CGFloat

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 3) {
                    ForEach(entries) { entry in
                        LogRowView(entry: entry).id(entry.id)
                    }
                }
                .padding(10)
            }
            .frame(maxHeight: maxHeight)
            .onChange(of: entries.count) { _, _ in
                if let last = entries.last {
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }
}

struct LabeledValue: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
        .font(.subheadline)
    }
}

struct BytesText: View {
    let bytes: Int64

    var body: some View {
        Text(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
            .font(.system(.caption, design: .monospaced))
            .monospacedDigit()
    }
}

func elapsedText(_ interval: TimeInterval) -> String {
    let total = Int(interval.rounded())
    let minutes = total / 60
    let seconds = total % 60
    return String(format: "%02d:%02d", minutes, seconds)
}
