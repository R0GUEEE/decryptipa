import SwiftUI

/// STEP 2 — Apple ID, two-factor and the Anisette provider that makes native
/// App Store authentication possible.
struct AccountSection: View {
    @ObservedObject var session: AppStoreSession
    /// Switches step 3 to the installed-app source when Apple blocks sign-in.
    var onUseInstalled: () -> Void = {}

    @State private var email = ""
    @State private var password = ""
    @State private var remember = true
    @State private var code = ""
    @State private var showingSecret = false
    @State private var confirmProvision = false
    @State private var showingImport = false
    @State private var showingAuthorize = false
    @State private var methodID = ""

    var body: some View {
        Card {
            SectionHeader(
                step: 2,
                title: "Apple account",
                subtitle: "Sign in once; the token is kept in the Keychain",
                icon: "person.crop.circle.badge.checkmark",
                state: session.account == nil ? (session.challenge == nil ? .idle : .warning) : .ready
            )

            accountBody
            DividerLine()
            anisetteBody
        }
        .onAppear {
            if email.isEmpty { email = session.account?.email ?? "" }
            if password.isEmpty { password = session.savedPassword }
            Task { await session.refreshPublicAnisetteServers() }
        }
        .confirmationDialog(
            "Provision Anisette with this server?",
            isPresented: $confirmProvision,
            titleVisibility: .visible
        ) {
            Button("Agree & set up") {
                Task { await session.configureAutomaticAnisette() }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            let host = URL(string: session.automaticAnisetteServer)?.host ?? session.automaticAnisetteServer
            Text("The server at " + host + " participates in Apple's Anisette provisioning exchange and can observe the device identity and protocol traffic. Continue only if you trust it.")
        }
        .sheet(isPresented: $showingImport) {
            ImportSessionSheet(session: session)
        }
        .sheet(isPresented: $showingAuthorize) {
            TwoFactorSheet(session: session)
        }
        .onChange(of: session.challenge != nil) { _, needsCode in
            if needsCode { showingAuthorize = true }
        }
    }

    // MARK: Account

    @ViewBuilder
    private var accountBody: some View {
        if let account = session.account {
            VStack(spacing: 8) {
                InfoRow(label: "Apple ID", value: account.email)
                if !account.name.isEmpty { InfoRow(label: "Name", value: account.name) }
                InfoRow(label: "Storefront", value: account.storeFront)
                InfoRow(label: "Mode", value: session.usesAnisette ? "Native + 2FA" : "Classic sign-in")
            }

            HStack(spacing: 8) {
                Button {
                    Task { await session.beginSignIn(email: account.email, password: session.savedPassword, rememberPassword: true) }
                } label: {
                    Label("Refresh token", systemImage: "arrow.clockwise")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .tint(Palette.accent)
                .disabled(session.busy || session.savedPassword.isEmpty)

                Button(role: .destructive) {
                    session.signOut()
                } label: {
                    Label("Sign out", systemImage: "rectangle.portrait.and.arrow.right")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.bordered)
            }

        } else if let challenge = session.challenge {
            challengeBody(challenge)
        } else {
            credentialsBody
        }
    }

    private var credentialsBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            FieldShell {
                TextField("", text: $email, prompt: Text("Apple ID").foregroundColor(Palette.muted))
                    .textContentType(.username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.emailAddress)
                    .foregroundStyle(Palette.ink)
            }

            FieldShell {
                HStack(spacing: 8) {
                    Group {
                        if showingSecret {
                            TextField("", text: $password, prompt: Text("Password").foregroundColor(Palette.muted))
                        } else {
                            SecureField("", text: $password, prompt: Text("Password").foregroundColor(Palette.muted))
                        }
                    }
                    .textContentType(.password)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .foregroundStyle(Palette.ink)

                    Button {
                        showingSecret.toggle()
                    } label: {
                        Image(systemName: showingSecret ? "eye.slash" : "eye")
                            .font(.system(size: 13))
                            .foregroundStyle(Palette.muted)
                    }
                    .buttonStyle(.plain)
                }
            }

            Toggle(isOn: $remember) {
                Text("Remember password in Keychain")
                    .font(.caption)
                    .foregroundStyle(Palette.muted)
            }
            .tint(Palette.accent)

            PrimaryButton(
                title: session.cooldownActive ? "Rate limited by Apple" : (session.usesAnisette ? "Sign in with 2FA support" : "Sign in"),
                icon: session.cooldownActive ? "hourglass" : "person.badge.key",
                busy: session.busy,
                enabled: !email.isEmpty && !password.isEmpty && !session.cooldownActive
            ) {
                Diagnostics.breadcrumb("Apple ID sign-in form submitted")
                Task { await session.beginSignIn(email: email, password: password, rememberPassword: remember) }
            }

            if session.cooldownActive {
                HStack(spacing: 6) {
                    Image(systemName: "hourglass").font(.system(size: 10))
                    Text("Apple answered 429. Attempts resume after " + session.cooldownText + ".")
                        .font(.caption2)
                }
                .foregroundStyle(Palette.warning)
            }

            HStack {
                Button("Use an existing session") { showingImport = true }
                    .font(.caption2.weight(.semibold))
                    .buttonStyle(.plain)
                    .foregroundStyle(Palette.accent)
                Spacer()
                if session.busy, !session.status.isEmpty {
                    Text(session.status).font(.caption2).foregroundStyle(Palette.muted).lineLimit(1)
                }
            }
        }
    }

    private func challengeBody(_ challenge: TwoFactorChallenge) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: "lock.shield.fill").font(.system(size: 12))
                Text("Two-factor authorization required")
                    .font(.caption.weight(.bold))
                Spacer(minLength: 0)
            }
            .foregroundStyle(Palette.warning)

            Text(challenge.note)
                .font(.caption2)
                .foregroundStyle(Palette.muted)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 6) {
                ForEach(challenge.options.prefix(3)) { option in
                    StatusPill(
                        text: methodLabel(option.kind),
                        tint: methodTint(option),
                        symbol: methodIcon(option.kind)
                    )
                }
                Spacer(minLength: 0)
            }

            PrimaryButton(title: "Choose method & authorize", icon: "lock.open") {
                showingAuthorize = true
            }

            Button("Start over") {
                session.cancelChallenge()
            }
            .font(.caption2.weight(.semibold))
            .buttonStyle(.plain)
            .foregroundStyle(Palette.muted)
        }
    }

    private func methodTint(_ option: TwoFactorOption) -> Color {
        option.kind == .trustedDevice ? Palette.muted : Palette.accent
    }

    private func methodLabel(_ kind: TwoFactorOption.Kind) -> String {
        switch kind {
        case .sms: return "text"
        case .voice: return "call"
        case .email: return "email"
        case .trustedDevice: return "device"
        }
    }

    private func methodIcon(_ kind: TwoFactorOption.Kind) -> String {
        switch kind {
        case .sms: return "message.fill"
        case .voice: return "phone.fill"
        case .email: return "envelope.fill"
        case .trustedDevice: return "iphone"
        }
    }

    // MARK: Anisette

    private var anisetteBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("ANISETTE")
                    .font(.caption2.weight(.bold))
                    .tracking(1.0)
                    .foregroundStyle(Palette.muted)
                Spacer()
                StatusPill(
                    text: session.automaticAnisetteReady ? "ready" : "not set up",
                    tint: session.automaticAnisetteReady ? Palette.success : Palette.warning,
                    symbol: session.automaticAnisetteReady ? "checkmark" : "exclamationmark"
                )
            }

            HStack(spacing: 8) {
                Menu {
                    ForEach(session.anisetteServerOptions) { option in
                        Button(option.name) {
                            session.automaticAnisetteServer = option.url
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "server.rack").font(.system(size: 12))
                        Text(currentServerName)
                            .font(.caption.weight(.semibold))
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.up.chevron.down").font(.system(size: 9))
                    }
                    .foregroundStyle(Palette.ink)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(Palette.cardRaised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }

                Button {
                    Task { await session.refreshPublicAnisetteServers(force: true) }
                } label: {
                    if session.anisetteCatalogRefreshing {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise").font(.system(size: 13, weight: .semibold))
                    }
                }
                .buttonStyle(.bordered)
                .tint(Palette.muted)
            }

            Text("Provider list: servers.sidestore.io · automatic failover across the public list")
                .font(.caption2)
                .foregroundStyle(Palette.muted)

            HStack(spacing: 8) {
                QuietButton(
                    title: session.automaticAnisetteReady ? "Re-provision" : "Set up Anisette",
                    icon: "wand.and.stars"
                ) {
                    confirmProvision = true
                }

                if session.automaticAnisetteReady {
                    QuietButton(title: "Forget", icon: "trash") {
                        session.removeAutomaticAnisette()
                    }
                }
            }

            if session.error != nil {
                DividerLine()
                problemPanel
            }
        }
    }

    private var problemPanel: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 7) {
                Image(systemName: "exclamationmark.shield.fill")
                    .font(.system(size: 12))
                Text(session.errorNeedsAttestation ? "Apple blocked this sign-in" : "Sign-in problem")
                    .font(.caption.weight(.bold))
                Spacer(minLength: 0)
            }
            .foregroundStyle(Palette.warning)

            if let error = session.error {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if session.errorNeedsAttestation {
                QuietButton(title: "Import a session token", icon: "square.and.arrow.down") {
                    showingImport = true
                }
                QuietButton(title: "Decrypt the installed copy instead", icon: "iphone.gen3") {
                    onUseInstalled()
                }
                ShareLink(item: session.diagnosticsText) {
                    Label("Copy sign-in diagnostics", systemImage: "doc.on.doc")
                        .font(.caption2.weight(.semibold))
                }
                .foregroundStyle(Palette.accent)
            }
        }
    }

    private var currentServerName: String {
        session.anisetteServerOptions
            .first(where: { $0.url == session.automaticAnisetteServer })?.name
            ?? URL(string: session.automaticAnisetteServer)?.host
            ?? "Choose server"
    }
}

struct ImportSessionSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var session: AppStoreSession

    @State private var dsid = ""
    @State private var token = ""
    @State private var storefront = "143441"
    @State private var pod = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Session") {
                    TextField("dsPersonId / DSID", text: $dsid).keyboardType(.numberPad)
                    TextField("passwordToken", text: $token)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Storefront", text: $storefront).keyboardType(.numberPad)
                    TextField("Pod (optional)", text: $pod).keyboardType(.numberPad)
                }
                Section {
                    Button("Use this session") {
                        if session.importSession(dsid: dsid, token: token, storefront: storefront, pod: pod) {
                            dismiss()
                        }
                    }
                    .disabled(dsid.isEmpty || token.isEmpty || storefront.isEmpty)
                } footer: {
                    Text("A token minted on a machine that can sign (ipatool, ipadecrypt) is accepted by Apple for licences and downloads.")
                }
            }
            .navigationTitle("Existing session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }
}
