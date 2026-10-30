import SwiftUI
import UIKit

struct AppStoreView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var session: AppStoreSession

    var onUseIPA: (URL, AppStoreApp) -> Void
    var onUseInstalled: (String) -> Void

    @State private var identifier = ""
    @State private var showingSignIn = false
    @State private var showingImport = false
    @State private var showingLog = false

    var body: some View {
        NavigationStack {
            Form {
                accountSection
                lookupSection
                if let app = session.app { appSection(app) }
                downloadSection
                if let error = session.error { errorSection(error) }
                logSection
            }
            .navigationTitle("App Store")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Picker("Storefront", selection: $session.country) {
                            ForEach(AppStoreSession.countries, id: \.code) { entry in
                                Text(entry.name).tag(entry.code)
                            }
                        }
                    } label: {
                        Label(session.country.uppercased(), systemImage: "globe")
                    }
                }
            }
            .sheet(isPresented: $showingSignIn) {
                SignInView(session: session)
            }
            .sheet(isPresented: $showingImport) {
                ImportSessionView(session: session)
            }
            .sheet(isPresented: $showingLog) {
                NavigationStack {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 4) {
                            ForEach(session.log) { entry in LogRowView(entry: entry) }
                        }
                        .padding()
                    }
                    .navigationTitle("App Store log")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showingLog = false }
                        }
                    }
                }
            }
            .onAppear {
                Diagnostics.setScreen("appstore")
                if identifier.isEmpty, let app = session.app {
                    identifier = app.bundleID
                }
            }
            .onChange(of: session.error) { _, error in
                if error != nil { Diagnostics.breadcrumb("appstore error displayed") }
            }
        }
    }

    // MARK: Sections

    private var lookupSection: some View {
        Section {
            HStack {
                TextField("com.example.app · 123456789 · link", text: $identifier)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .onSubmit { Task { await session.lookUp(identifier) } }

                Button {
                    Task { await session.lookUp(identifier) }
                } label: {
                    Image(systemName: "magnifyingglass")
                }
                .disabled(identifier.trimmingCharacters(in: .whitespaces).isEmpty || session.busy)
            }

            Text("Bundle identifier, numeric App Store id, or an apps.apple.com link. The lookup uses the public iTunes API, so it works without an account.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } header: {
            Text("Find an app")
        }
    }

    private func appSection(_ app: AppStoreApp) -> some View {
        Section("App") {
            HStack(spacing: 12) {
                if let artwork = app.artworkURL {
                    AsyncImage(url: artwork) { image in
                        image.resizable().aspectRatio(contentMode: .fit)
                    } placeholder: {
                        RoundedRectangle(cornerRadius: 12).fill(Color(.tertiarySystemFill))
                    }
                    .frame(width: 56, height: 56)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(app.name).font(.headline)
                    if !app.seller.isEmpty {
                        Text(app.seller).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            LabeledValue(label: "Bundle id", value: app.bundleID)
            LabeledValue(label: "Track id", value: String(app.trackID))
            LabeledValue(label: "Current version", value: app.version)
            LabeledValue(label: "Price", value: app.isFree ? "Free" : String(format: "%.2f", app.price))
            LabeledValue(label: "MinimumOS", value: app.minimumOS)
            if let size = app.sizeText {
                LabeledValue(label: "Download size", value: size)
            }
        }
    }

    private var accountSection: some View {
        Section {
            if let account = session.account {
                LabeledValue(label: "Apple ID", value: account.email)
                if !account.name.isEmpty {
                    LabeledValue(label: "Name", value: account.name)
                }
                LabeledValue(label: "Storefront", value: account.storeFront.isEmpty ? "—" : account.storeFront)
                Button("Sign in again (refresh token)") {
                    showingSignIn = true
                }
                Button("Sign out", role: .destructive) {
                    session.signOut()
                }
            } else {
                Button {
                    showingSignIn = true
                } label: {
                    Label("Sign in with Apple ID", systemImage: "person.crop.circle.badge.checkmark")
                }
                Button {
                    showingImport = true
                } label: {
                    Label("Use an existing session", systemImage: "square.and.arrow.down")
                }
            }
        } header: {
            Text("Account")
        } footer: {
            Text("Apple’s modern sign-in and selectable SMS delivery need a working anisette-v3 provider configured under the gear. Without attestation, Apple may reject direct sign-in before checking the password (HTTP 403); use an existing signed session from ipatool/ipadecrypt instead. Session tokens are stored in the iOS Keychain.")
        }
    }

    private var downloadSection: some View {
        Section {
            if session.busy {
                VStack(alignment: .leading, spacing: 6) {
                    Text(session.status).font(.caption)
                    if session.downloadProgress > 0 {
                        ProgressView(value: session.downloadProgress)
                    } else {
                        ProgressView().progressViewStyle(.linear)
                    }
                }
            } else if let ipa = session.downloadedIPA {
                VStack(alignment: .leading, spacing: 4) {
                    Text(ipa.lastPathComponent).font(.subheadline.weight(.medium))
                    Text("Stored in Documents/Imports").font(.caption).foregroundStyle(.secondary)
                }
                Button {
                    if let app = session.app {
                        onUseIPA(ipa, app)
                        dismiss()
                    }
                } label: {
                    Label("Use this IPA and decrypt", systemImage: "lock.open.rotation")
                }
                .buttonStyle(.borderedProminent)

                Button("Download again") {
                    Task { await session.download() }
                }
            } else {
                Button {
                    Task { await session.download() }
                } label: {
                    Label("Download encrypted IPA", systemImage: "arrow.down.circle")
                }
                .disabled(session.app == nil || session.account == nil)
            }

            if let ticket = session.ticket {
                LabeledValue(label: "Ticket version", value: ticket.version)
                LabeledValue(label: "sinf entries", value: String(ticket.sinfs))
                LabeledValue(label: "CDN host", value: ticket.url.host ?? "?")
            }
        } header: {
            Text("Download")
        } footer: {
            Text("Free apps get a licence first (buyProduct); paid apps must already be owned. The IPA that comes back is still FairPlay-encrypted — it is installed on the device and decrypted there.")
        }
    }

    private func errorSection(_ message: String) -> some View {
        Section {
            Text(message)
                .font(.callout)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)

            if !session.log.isEmpty {
                LogConsole(entries: Array(session.log.suffix(6)), maxHeight: 120)
                    .background(Color(.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            ShareLink(item: session.diagnosticsText) {
                Label("Copy diagnostics", systemImage: "doc.on.doc")
            }

            if let app = session.app {
                Button {
                    onUseInstalled(app.bundleID)
                    dismiss()
                } label: {
                    Label("Decrypt the copy installed on the device", systemImage: "iphone.gen3")
                }
                Button {
                    if let storeURL = app.storeURL {
                        UIApplication.shared.open(storeURL)
                    }
                } label: {
                    Label("Open in the App Store", systemImage: "arrow.up.forward.app")
                }
                Button {
                    Task { await session.download() }
                } label: {
                    Label("Try the download again", systemImage: "arrow.clockwise")
                }
            }

            Button {
                showingLog = true
            } label: {
                Label("Show full log", systemImage: "text.alignleft")
            }
        } header: {
            Text("Problem")
        }
    }

    private var logSection: some View {
        Section {
            if session.log.isEmpty {
                Text("Nothing logged yet.").font(.caption).foregroundStyle(.secondary)
            } else {
                LogConsole(entries: Array(session.log.suffix(8)), maxHeight: 140)
                    .background(Color(.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        } header: {
            Text("Log")
        }
    }
}

struct SignInView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var session: AppStoreSession

    @State private var email = ""
    @State private var password = ""
    @State private var remember = true
    @State private var code = ""
    @State private var showingAdvanced = false

    var body: some View {
        NavigationStack {
            Form {
                if let challenge = session.challenge {
                    challengeHeaderSection(challenge)
                    challengeDeliverySection(challenge)
                    challengeCodeSection(challenge, code: $code)
                } else {
                    credentialSection
                }

                if let error = session.error {
                    Section {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)

                        if session.errorNeedsAttestation {
                            Button {
                                showingAdvanced = true
                            } label: {
                                Label("Set up an anisette provider", systemImage: "key.horizontal")
                            }
                            Text("Anisette servers are small HTTP services (anisette-v3 compatible). Without one, Apple refuses the request before it ever looks at the password.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }

                        ShareLink(item: session.diagnosticsText) {
                            Label("Copy diagnostics", systemImage: "doc.on.doc")
                                .font(.caption)
                        }
                    } header: {
                        Text("Sign-in problem")
                    }
                }

                actionSection
            }
            .navigationTitle(session.challenge == nil ? "Apple ID" : "Two-factor")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        session.cancelChallenge()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingAdvanced = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                }
            }
            .sheet(isPresented: $showingAdvanced) {
                AnisetteSettingsView(session: session)
            }
            .onAppear {
                Diagnostics.setScreen(session.challenge == nil ? "appstore.signin" : "appstore.twofactor")
                if email.isEmpty { email = session.account?.email ?? "" }
                if password.isEmpty { password = session.savedPassword }
            }
            .onChange(of: session.challenge != nil) { _, isTwoFactor in
                Diagnostics.setScreen(isTwoFactor ? "appstore.twofactor" : "appstore.signin")
            }
        }
    }

    // MARK: Credentials

    private var credentialSection: some View {
        Section {
            TextField("Apple ID", text: $email)
                .textContentType(.username)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.emailAddress)
            SecureField("Password", text: $password)
                .textContentType(.password)
            Toggle("Remember password in the keychain", isOn: $remember)
        } footer: {
            Text(session.usesAnisette
                 ? "Native sign-in with anisette: if Apple requires two-factor, you can choose which trusted number gets the text."
                 : "Without an anisette provider the app uses Apple's classic App Store sign-in. When a code is required, Apple texts it to your trusted phone and you type it here.")
        }
    }

    // MARK: Two-factor

    private func challengeHeaderSection(_ challenge: TwoFactorChallenge) -> some View {
        Section {
            Text(challenge.note)
                .font(.caption)
                .foregroundStyle(.secondary)
            if !challenge.supportsNumberChoice {
                Text("Apple delivers this code to the trusted devices and phone number on the account.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Verification required")
        }
    }

    private func challengeDeliverySection(_ challenge: TwoFactorChallenge) -> some View {
        Section {
            ForEach(challenge.options) { option in
                Button {
                    session.selectOption(option.id)
                    Task { await session.sendCode(option: option) }
                } label: {
                    HStack {
                        Image(systemName: option.kind == .sms ? "message.fill" : "iphone")
                            .frame(width: 22)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(option.title).foregroundStyle(.primary)
                            Text(option.detail).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if session.selectedOptionID == option.id {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint)
                        }
                    }
                }
            }
        } header: {
            Text("Receive the code")
        } footer: {
            Text("Tap a number to have Apple send a text message.")
        }
    }

    private func challengeCodeSection(_ challenge: TwoFactorChallenge, code: Binding<String>) -> some View {
        Section {
            TextField(String(repeating: "\u{2022}", count: challenge.codeLength), text: code)
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
                .font(.system(.title3, design: .monospaced))
            if let requested = session.codeRequestedAt {
                Text("Requested \(requested.formatted(date: .omitted, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button("Resend code") {
                Task { await session.sendCode(option: session.selectedOption) }
            }
            .disabled(!session.canResend || session.busy)
        } header: {
            Text("Code")
        }
    }

    // MARK: Actions

    private var actionSection: some View {
        Section {
            if session.busy {
                HStack {
                    ProgressView().controlSize(.small)
                    Text(session.status.isEmpty ? "Working…" : session.status)
                        .font(.caption)
                }
            } else if session.challenge != nil {
                Button("Verify and sign in") {
                    Task {
                        await session.verifyCode(code)
                        if session.account != nil { dismiss() }
                    }
                }
                .disabled(code.trimmingCharacters(in: .whitespaces).count < 4)

                Button("Start over") {
                    code = ""
                    session.cancelChallenge()
                }
            } else {
                Button("Sign in") {
                    Diagnostics.breadcrumb("Apple ID sign-in form submitted")
                    Task {
                        await session.beginSignIn(email: email, password: password, rememberPassword: remember)
                        if session.account != nil { dismiss() }
                    }
                }
                .disabled(email.isEmpty || password.isEmpty)
            }
        }
    }
}

struct AnisetteSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var session: AppStoreSession

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("https://ani.example.com", text: $session.anisetteURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    TextField("Basic auth user (optional)", text: $session.anisetteUser)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Basic auth password (optional)", text: $session.anisettePassword)
                } header: {
                    Text("Anisette server")
                } footer: {
                    Text("Any anisette-v3 compatible server works: GET returns a JSON object with X-Apple-I-MD, X-Apple-I-MD-M and friends. With a provider configured the app uses Apple's native sign-in, which is what allows choosing a trusted phone number for the text message. Leave empty to use the classic App Store sign-in.")
                }

                Section {
                    TextField("X-Apple-Widget-Key (optional)", text: $session.widgetKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Advanced")
                } footer: {
                    Text("Some Apple ID endpoints ask for a widget key. Only set this if Apple rejects the 2FA session lookup.")
                }

                Section("Device") {
                    LabeledValue(label: "GUID", value: session.deviceGUID)
                    LabeledValue(label: "Mode", value: session.usesAnisette ? "Native + session 2FA" : "Classic App Store sign-in")
                }
            }
            .navigationTitle("Sign-in settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}


struct ImportSessionView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var session: AppStoreSession

    @State private var dsid = ""
    @State private var token = ""
    @State private var storefront = "143441"
    @State private var pod = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("dsPersonId / DSID (e.g. 1234567890)", text: $dsid)
                        .keyboardType(.numberPad)
                    TextField("passwordToken", text: $token)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Storefront (e.g. 143441)", text: $storefront)
                        .keyboardType(.numberPad)
                    TextField("Pod (optional, e.g. 25)", text: $pod)
                        .keyboardType(.numberPad)
                } footer: {
                    Text("Apple refuses unsigned sign-in from this app, but a token minted on a machine that can sign (ipatool, ipadecrypt) is accepted for licences and downloads. ipadecrypt keeps it in ~/.ipadecrypt/config.json, ipatool in the login keychain item.")
                }

                Section {
                    Button("Use this session") {
                        if session.importSession(dsid: dsid, token: token, storefront: storefront, pod: pod) {
                            dismiss()
                        }
                    }
                    .disabled(dsid.isEmpty || token.isEmpty || storefront.isEmpty)
                }
            }
            .navigationTitle("Existing session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}
