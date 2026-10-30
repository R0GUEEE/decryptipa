import SwiftUI
import UIKit

struct AppStoreView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var session: AppStoreSession

    var onUseIPA: (URL, AppStoreApp) -> Void
    var onUseInstalled: (String) -> Void

    @State private var identifier = ""
    @State private var showingSignIn = false
    @State private var showingLog = false

    var body: some View {
        NavigationStack {
            Form {
                lookupSection
                if let app = session.app { appSection(app) }
                accountSection
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
                if identifier.isEmpty, let app = session.app {
                    identifier = app.bundleID
                }
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
            }
        } header: {
            Text("Account")
        } footer: {
            Text("The password is only used to obtain an App Store token and is stored in the keychain when you ask for it. Two-factor codes are appended to the same sign-in request, exactly like the desktop tool.")
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
        Section("Problem") {
            Text(message)
                .font(.callout)
                .foregroundStyle(.red)

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
            }

            Button {
                showingLog = true
            } label: {
                Label("Show full log", systemImage: "text.alignleft")
            }
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
    @State private var authCode = ""
    @State private var remember = true
    @State private var needsCode = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Apple ID", text: $email)
                        .textContentType(.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.emailAddress)
                    SecureField("Password", text: $password)
                        .textContentType(.password)
                    TextField("6-digit 2FA code (if prompted)", text: $authCode)
                        .keyboardType(.numberPad)
                    Toggle("Remember password in the keychain", isOn: $remember)
                } footer: {
                    Text("If Apple asks for two-factor verification, the first attempt returns a code prompt. Enter the code here and submit again — the code is appended to the password just like ipadecrypt's desktop flow.")
                }

                if let error = session.error, needsCode {
                    Section {
                        Text(error).font(.caption).foregroundStyle(.orange)
                    }
                }

                Section {
                    if session.busy {
                        HStack {
                            ProgressView().controlSize(.small)
                            Text("Signing in…").font(.caption)
                        }
                    } else {
                        Button("Sign in") { submit() }
                            .disabled(email.isEmpty || password.isEmpty)
                    }
                }
            }
            .navigationTitle("Apple ID")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onAppear {
                if email.isEmpty { email = session.account?.email ?? "" }
                if password.isEmpty { password = session.savedPassword }
            }
            .onChange(of: session.error) { _, error in
                if let error, error.contains("two-factor") {
                    needsCode = true
                }
            }
        }
    }

    private func submit() {
        Task {
            await session.signIn(email: email, password: password, authCode: authCode, rememberPassword: remember)
            if session.error == nil {
                dismiss()
            } else if session.error?.contains("two-factor") == true {
                needsCode = true
            }
        }
    }
}
