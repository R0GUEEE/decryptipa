import SwiftUI

/// Interactive 2FA authorization. Apple decides which methods exist for the
/// account; this sheet lets the user pick one, request the code, and verify it
/// without leaving the flow.
struct TwoFactorSheet: View {
    @ObservedObject var session: AppStoreSession
    @Environment(\.dismiss) private var dismiss

    @State private var code = ""
    @State private var selected: TwoFactorOption?
    @State private var sending = false
    @State private var verifying = false
    @State private var lastError: String?

    private var challenge: TwoFactorChallenge? { session.challenge }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    header
                    if let challenge {
                        methods(challenge)
                        entry(challenge)
                        actions(challenge)
                    } else {
                        Text("This sign-in no longer needs a code.")
                            .font(.callout)
                            .foregroundStyle(Palette.muted)
                    }
                }
                .padding(16)
            }
            .background(Palette.canvas.ignoresSafeArea())
            .navigationTitle("Authorize sign-in")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        session.cancelChallenge()
                        dismiss()
                    }
                    .foregroundStyle(Palette.muted)
                }
            }
            .onAppear {
                Diagnostics.setScreen("apple.2fa")
                if selected == nil { selected = challenge?.preferredOption }
            }
            .onChange(of: session.challenge?.options.count) { _, _ in
                if selected == nil { selected = challenge?.preferredOption }
            }
            .onChange(of: session.account != nil) { _, signedIn in
                if signedIn { dismiss() }
            }
            .interactiveDismissDisabled(session.busy)
        }
        .preferredColorScheme(.dark)
    }

    // MARK: Header

    private var header: some View {
        Card(padding: 14) {
            HStack(alignment: .top, spacing: 11) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Palette.accent)
                    .frame(width: 38, height: 38)
                    .background(Palette.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text("Two-factor required")
                        .font(.headline)
                        .foregroundStyle(Palette.ink)
                    Text(challenge?.note ?? "Apple sent a code to your trusted devices.")
                        .font(.caption)
                        .foregroundStyle(Palette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            if let challenge, challenge.mode == .legacy {
                Text("Apple's classic flow does not publish the phone list, so the code always goes to the trusted phone and devices on the account.")
                    .font(.caption2)
                    .foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Methods

    private func methods(_ challenge: TwoFactorChallenge) -> some View {
        Card(padding: 14) {
            Text("STEP 1 · CHOOSE A METHOD")
                .font(.caption2.weight(.bold))
                .tracking(1.0)
                .foregroundStyle(Palette.muted)

            VStack(spacing: 8) {
                ForEach(challenge.options) { option in
                    methodRow(option)
                }
            }

            if let selected {
                PrimaryButton(
                    title: requested(for: selected)
                        ? (session.canResend ? "Send another code" : "Code sent")
                        : actionTitle(for: selected),
                    icon: icon(for: selected.kind),
                    busy: sending,
                    enabled: session.canResend
                ) {
                    Task { await request(selected) }
                }

                if let sentAt = session.codeRequestedAt, requested(for: selected) {
                    HStack {
                        Image(systemName: "clock").font(.system(size: 10))
                        Text("Requested at " + sentAt.formatted(date: .omitted, time: .standard))
                            .font(.caption2)
                        Spacer(minLength: 0)
                        if !session.canResend {
                            Text("Wait before resending").font(.caption2)
                        }
                    }
                    .foregroundStyle(Palette.muted)
                }
            }
        }
    }

    private func methodRow(_ option: TwoFactorOption) -> some View {
        let isSelected = selected?.id == option.id
        return Button {
            selected = option
            code = ""
            lastError = nil
        } label: {
            HStack(spacing: 11) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(isSelected ? Palette.accent : Palette.muted)

                Image(systemName: icon(for: option.kind))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Palette.accent)
                    .frame(width: 22)

                VStack(alignment: .leading, spacing: 2) {
                    Text(option.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Palette.ink)
                        .lineLimit(1)
                    Text(option.detail)
                        .font(.caption2)
                        .foregroundStyle(Palette.muted)
                }
                Spacer(minLength: 0)
            }
            .padding(11)
            .background(
                (isSelected ? Palette.accent.opacity(0.10) : Palette.cardRaised),
                in: RoundedRectangle(cornerRadius: 13, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .strokeBorder(isSelected ? Palette.accent.opacity(0.5) : Color.clear, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: Code

    private func entry(_ challenge: TwoFactorChallenge) -> some View {
        Card(padding: 14) {
            Text("STEP 2 · ENTER THE CODE")
                .font(.caption2.weight(.bold))
                .tracking(1.0)
                .foregroundStyle(Palette.muted)

            HStack(spacing: 8) {
                ForEach(0..<challenge.codeLength, id: \.self) { index in
                    codeBox(at: index, text: code, length: challenge.codeLength)
                }
            }
            .frame(maxWidth: .infinity)

            TextField("", text: $code)
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
                .textFieldStyle(.plain)
                .labelsHidden()
                .frame(width: 1, height: 1)
                .opacity(0.01)
                .focused($codeFocused)
                .onChange(of: code) { _, value in
                    let digits = value.filter(\.isNumber)
                    if digits != value { code = String(digits.prefix(challenge.codeLength)) }
                    if code.count > challenge.codeLength { code = String(code.prefix(challenge.codeLength)) }
                }

            Button {
                codeFocused = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "keyboard").font(.system(size: 12))
                    Text(code.isEmpty ? "Enter the code" : "Change code")
                        .font(.caption.weight(.semibold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
            }
            .buttonStyle(.bordered)
            .tint(Palette.muted)

            if let message = lastError ?? session.error {
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(Palette.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @FocusState private var codeFocused: Bool

    private func codeBox(at index: Int, text: String, length: Int) -> some View {
        let characters = Array(text)
        let filled = index < characters.count
        return Text(filled ? String(characters[index]) : "")
            .font(.system(size: 20, weight: .semibold, design: .monospaced))
            .foregroundStyle(Palette.ink)
            .frame(maxWidth: .infinity)
            .frame(height: 46)
            .background(Palette.cardRaised, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(codeFocused && index == min(text.count, length - 1) ? Palette.accent.opacity(0.6) : Color.white.opacity(0.06), lineWidth: 1)
            }
    }

    // MARK: Actions

    private func actions(_ challenge: TwoFactorChallenge) -> some View {
        VStack(spacing: 9) {
            PrimaryButton(
                title: "Verify and sign in",
                icon: "checkmark.shield.fill",
                busy: verifying,
                enabled: code.count >= 4 && !session.busy
            ) {
                Task { await verify() }
            }

            QuietButton(title: "Start over", icon: "arrow.counterclockwise") {
                session.cancelChallenge()
                dismiss()
            }
        }
    }

    private func icon(for kind: TwoFactorOption.Kind) -> String {
        switch kind {
        case .sms: return "message.fill"
        case .voice: return "phone.fill"
        case .email: return "envelope.fill"
        case .trustedDevice: return "iphone"
        }
    }

    private func actionTitle(for option: TwoFactorOption) -> String {
        switch option.kind {
        case .sms: return "Text me a code"
        case .voice: return "Call me with a code"
        case .email: return "Email me a code"
        case .trustedDevice: return "Ask my trusted devices"
        }
    }

    private func requested(for option: TwoFactorOption) -> Bool {
        session.selectedOptionID == option.id && session.codeRequestedAt != nil
    }

    private func request(_ option: TwoFactorOption) async {
        sending = true
        lastError = nil
        session.selectOption(option.id)
        await session.sendCode(option: option)
        if session.error != nil { lastError = session.error }
        sending = false
    }

    private func verify() async {
        verifying = true
        lastError = nil
        await session.verifyCode(code)
        if session.error != nil {
            lastError = session.error
        } else if session.account != nil {
            dismiss()
        }
        verifying = false
    }
}
