import SwiftUI

/// Shared visual language for the rebuilt workflow.
enum Palette {
    static let canvas = Color(red: 0.055, green: 0.065, blue: 0.085)
    static let card = Color(red: 0.098, green: 0.113, blue: 0.145)
    static let cardRaised = Color(red: 0.125, green: 0.143, blue: 0.180)
    static let ink = Color(red: 0.93, green: 0.95, blue: 0.98)
    static let muted = Color(red: 0.60, green: 0.65, blue: 0.74)
    static let accent = Color(red: 0.38, green: 0.58, blue: 1.0)
    static let success = Color(red: 0.30, green: 0.82, blue: 0.52)
    static let warning = Color(red: 0.98, green: 0.70, blue: 0.30)
    static let danger = Color(red: 0.96, green: 0.38, blue: 0.38)
}

struct Card<Content: View>: View {
    var padding: CGFloat
    private let content: Content

    init(padding: CGFloat = 16, @ViewBuilder content: () -> Content) {
        self.padding = padding
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            content
        }
        .padding(padding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Color.white.opacity(0.06), lineWidth: 1)
        }
    }
}

/// Numbered heading that makes the four stages of the workflow obvious.
struct SectionHeader: View {
    let step: Int
    let title: String
    let subtitle: String
    let icon: String
    var state: SectionState = .idle

    enum SectionState {
        case idle, ready, warning

        var color: Color {
            switch self {
            case .idle: Palette.muted
            case .ready: Palette.success
            case .warning: Palette.warning
            }
        }

        var symbol: String {
            switch self {
            case .idle: "circle"
            case .ready: "checkmark.circle.fill"
            case .warning: "exclamationmark.circle.fill"
            }
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Palette.accent.opacity(0.16))
                    .frame(width: 40, height: 40)
                Image(systemName: icon)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Palette.accent)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text("STEP " + String(step))
                    .font(.caption2.weight(.bold))
                    .tracking(1.1)
                    .foregroundStyle(Palette.muted)
                Text(title)
                    .font(.headline)
                    .foregroundStyle(Palette.ink)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 4)

            Image(systemName: state.symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(state.color)
                .padding(.top, 2)
        }
    }
}

struct StatusPill: View {
    let text: String
    var tint: Color = Palette.muted
    var symbol: String? = nil

    var body: some View {
        HStack(spacing: 5) {
            if let symbol {
                Image(systemName: symbol).font(.system(size: 10, weight: .bold))
            }
            Text(text)
                .font(.caption2.weight(.semibold))
                .lineLimit(1)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(tint.opacity(0.14), in: Capsule())
        .foregroundStyle(tint)
    }
}

struct InfoRow: View {
    let label: String
    let value: String
    var mono: Bool = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .font(.caption)
                .foregroundStyle(Palette.muted)
            Spacer(minLength: 8)
            Text(value)
                .font(mono ? .caption.monospaced() : .caption.weight(.medium))
                .foregroundStyle(Palette.ink)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
    }
}

struct FieldShell<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .background(Palette.cardRaised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

struct PrimaryButton: View {
    let title: String
    var icon: String? = nil
    var tint: Color = Palette.accent
    var busy: Bool = false
    var enabled: Bool = true
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if busy {
                    ProgressView().controlSize(.small).tint(.white)
                } else if let icon {
                    Image(systemName: icon).font(.system(size: 14, weight: .semibold))
                }
                Text(title).font(.subheadline.weight(.semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
        }
        .buttonStyle(.borderedProminent)
        .tint(tint)
        .opacity(enabled && !busy ? 1 : 0.45)
        .disabled(!enabled || busy)
    }
}

struct QuietButton: View {
    let title: String
    var icon: String? = nil
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let icon { Image(systemName: icon).font(.system(size: 13, weight: .semibold)) }
                Text(title).font(.caption.weight(.semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
        }
        .buttonStyle(.bordered)
        .tint(Palette.muted)
    }
}

struct DividerLine: View {
    var body: some View {
        Rectangle()
            .fill(Color.white.opacity(0.07))
            .frame(height: 1)
    }
}

struct EmptyNote: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(Palette.muted)
            .fixedSize(horizontal: false, vertical: true)
    }
}
