import Foundation
import Combine

/// Account + download state for the App Store flow, including the Apple ID
/// sign-in / two-factor state machine.
///
/// Two 2FA modes exist and both end in the same place:
///  * `.session` — native auth handed back an `appleauth` session, so the user
///    can pick a trusted phone number and have Apple text it.
///  * `.legacy`  — the MZFinance endpoint only says "code required"; Apple
///    already texted the trusted phone, and the code is submitted with the
///    password.
@MainActor
final class AppStoreSession: ObservableObject {
    // Account / app
    @Published private(set) var account: AppStoreAccount?
    @Published private(set) var app: AppStoreApp?
    @Published private(set) var downloadedIPA: URL?
    @Published private(set) var ticket: AppStoreTicket?

    // Sign-in state
    @Published private(set) var challenge: TwoFactorChallenge?
    @Published private(set) var selectedOptionID: String?
    @Published private(set) var codeRequestedAt: Date?
    @Published private(set) var waitingForCode = false

    // Job state
    @Published private(set) var busy = false
    @Published private(set) var status: String = ""
    @Published private(set) var error: String?
    @Published private(set) var downloadProgress: Double = 0
    @Published private(set) var log: [LogEntry] = []

    // Settings
    @Published var country: String { didSet { defaults.set(country, forKey: Self.countryKey) } }
    @Published var anisetteURL: String { didSet { defaults.set(anisetteURL, forKey: Self.anisetteKey) } }
    @Published var anisetteUser: String { didSet { defaults.set(anisetteUser, forKey: Self.anisetteUserKey) } }
    @Published var widgetKey: String { didSet { defaults.set(widgetKey, forKey: Self.widgetKeyKey) } }
    @Published var anisettePassword: String {
        didSet { Keychain.save(Data(anisettePassword.utf8), account: Self.anisettePasswordKey) }
    }

    private static let accountKey = "appstore.account"
    private static let passwordKey = "appstore.password"
    private static let guidKey = "appstore.guid"
    private static let countryKey = "appstore.country"
    private static let anisetteKey = "appstore.anisette.url"
    private static let anisetteUserKey = "appstore.anisette.user"
    private static let anisettePasswordKey = "appstore.anisette.password"
    private static let widgetKeyKey = "appstore.widgetkey"

    private let guid: String
    private let defaults = UserDefaults.standard
    private let client: AppStoreClient
    private let outputDirectory: URL

    // Pending credentials for the 2FA round trip (memory only).
    private var pendingEmail = ""
    private var pendingPassword = ""
    private var pendingRemember = false

    static let countries: [(code: String, name: String)] = [
        ("us", "United States"), ("gb", "United Kingdom"), ("ca", "Canada"),
        ("au", "Australia"), ("de", "Germany"), ("fr", "France"),
        ("nl", "Netherlands"), ("es", "Spain"), ("it", "Italy"),
        ("se", "Sweden"), ("pl", "Poland"), ("br", "Brazil"),
        ("mx", "Mexico"), ("jp", "Japan"), ("kr", "South Korea"),
        ("tw", "Taiwan"), ("hk", "Hong Kong"), ("sg", "Singapore"),
        ("in", "India"), ("id", "Indonesia"), ("th", "Thailand"),
        ("vn", "Vietnam"), ("tr", "Turkey"), ("ae", "UAE"),
        ("za", "South Africa")
    ]

    init(outputDirectory: URL) {
        self.outputDirectory = outputDirectory

        let guid: String
        if let stored = UserDefaults.standard.string(forKey: Self.guidKey), stored.count == 12 {
            guid = stored
        } else {
            guid = (0..<12).map { _ in String(format: "%X", Int.random(in: 0...15)) }.joined()
            UserDefaults.standard.set(guid, forKey: Self.guidKey)
        }
        self.guid = guid

        self.country = defaults.string(forKey: Self.countryKey) ?? "us"
        self.anisetteURL = defaults.string(forKey: Self.anisetteKey) ?? ""
        self.anisetteUser = defaults.string(forKey: Self.anisetteUserKey) ?? ""
        self.widgetKey = defaults.string(forKey: Self.widgetKeyKey) ?? ""
        self.anisettePassword = Keychain.load(account: Self.anisettePasswordKey)
            .flatMap { String(data: $0, encoding: .utf8) } ?? ""

        self.client = AppStoreClient(guid: guid)

        if let data = Keychain.load(account: Self.accountKey),
           let saved = try? JSONDecoder().decode(AppStoreAccount.self, from: data) {
            account = saved
            client.adopt(saved)
        }
    }

    var deviceGUID: String { guid }
    var isSignedIn: Bool { account != nil }
    var usesAnisette: Bool { !anisetteURL.trimmingCharacters(in: .whitespaces).isEmpty }

    var savedPassword: String {
        guard let data = Keychain.load(account: Self.passwordKey),
              let text = String(data: data, encoding: .utf8) else { return "" }
        return text
    }

    var selectedOption: TwoFactorOption? {
        guard let challenge else { return nil }
        if let selectedOptionID, let match = challenge.options.first(where: { $0.id == selectedOptionID }) {
            return match
        }
        return challenge.preferredOption
    }

    /// True when Apple refused the request itself rather than the password.
    var errorNeedsAttestation: Bool {
        guard let error else { return false }
        return error.contains("403") || error.contains("anisette") || error.contains("signed request")
    }

    var canResend: Bool {
        guard let codeRequestedAt else { return true }
        return Date().timeIntervalSince(codeRequestedAt) > 30
    }

    // MARK: - Sign-in

    func beginSignIn(email: String, password: String, rememberPassword: Bool) async {
        busy = true
        error = nil
        challenge = nil
        selectedOptionID = nil
        codeRequestedAt = nil
        waitingForCode = false
        status = "Signing in to the App Store…"
        defer { busy = false }

        pendingEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        pendingPassword = password
        pendingRemember = rememberPassword

        let anisette = await anisetteHeaders()
        append(anisette == nil ? "Using the legacy App Store sign-in path (no anisette provider configured)."
                               : "Using native App Store sign-in with anisette attestation.", .debug)

        do {
            let outcome = try await client.beginSignIn(
                email: pendingEmail,
                password: password,
                country: country,
                anisette: anisette,
                widgetKey: widgetKey
            )

            switch outcome {
            case .signedIn(let account):
                finishSignIn(account)
            case .challenge(let challenge):
                self.challenge = challenge
                self.selectedOptionID = challenge.preferredOption?.id
                status = "Two-factor authentication required"

                if let note = client.lastNativeFailure, !note.isEmpty {
                    append(note, .warn)
                }
                append(challenge.note, .warn)

                if challenge.mode == .legacy {
                    // The refused attempt already made Apple text the trusted
                    // phone; treat it as "code sent".
                    codeRequestedAt = Date()
                    waitingForCode = true
                }
            }
        } catch {
            fail(error)
        }
    }

    /// Asks Apple to deliver a code through the selected channel.
    func sendCode(option: TwoFactorOption? = nil) async {
        guard let challenge else { return }
        let option = option ?? selectedOption ?? challenge.preferredOption
        guard let option else {
            error = "Apple did not offer a delivery method for this code."
            return
        }

        busy = true
        error = nil
        defer { busy = false }

        selectedOptionID = option.id

        do {
            if challenge.mode == .session {
                guard let anisette = await anisetteHeaders() else {
                    throw AppError.message("Session-based 2FA needs anisette attestation. Configure a provider in Advanced, or use the trusted-device code Apple already sent.")
                }

                try await client.requestCode(
                    challenge,
                    option: option,
                    anisette: anisette,
                    widgetKey: widgetKey
                )
                append("Asked Apple for a \(option.kind == .sms ? "text message" : "trusted-device prompt") → \(option.title)", .command)
            } else {
                // Legacy: re-running the refused sign-in makes Apple re-send the code.
                do {
                    _ = try await client.signIn(
                        email: pendingEmail,
                        password: pendingPassword,
                        authCode: "",
                        country: country
                    )
                } catch AppStoreError.authCodeRequired {
                    append("Apple re-sent the verification code.", .info)
                }
            }

            codeRequestedAt = Date()
            waitingForCode = true
            status = option.kind == .sms
                ? "Code sent by text to \(option.title)"
                : "Code requested from your trusted devices"
        } catch {
            fail(error)
        }
    }

    func verifyCode(_ code: String) async {
        guard let challenge else { return }
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 4 else {
            error = "Enter the \(challenge.codeLength)-digit code Apple sent."
            return
        }

        busy = true
        error = nil
        defer { busy = false }

        do {
            let account: AppStoreAccount

            switch challenge.mode {
            case .legacy:
                account = try await client.signIn(
                    email: pendingEmail,
                    password: pendingPassword,
                    authCode: trimmed,
                    country: country
                )

            case .session:
                guard let anisette = await anisetteHeaders(), let option = selectedOption else {
                    throw AppError.message("The 2FA session expired. Sign in again.")
                }

                account = try await client.completeSessionChallenge(
                    challenge,
                    option: option,
                    code: trimmed,
                    password: pendingPassword,
                    anisette: anisette,
                    widgetKey: widgetKey
                )
            }

            finishSignIn(account)
        } catch {
            fail(error)
        }
    }

    func selectOption(_ id: String) {
        selectedOptionID = id
    }

    func cancelChallenge() {
        challenge = nil
        selectedOptionID = nil
        codeRequestedAt = nil
        waitingForCode = false
        pendingPassword = ""
        status = ""
    }

    private func finishSignIn(_ account: AppStoreAccount) {
        self.account = account
        challenge = nil
        waitingForCode = false
        pendingPassword = ""

        if let data = try? JSONEncoder().encode(account) {
            Keychain.save(data, account: Self.accountKey)
        }
        if pendingRemember {
            Keychain.save(Data(pendingPassword.utf8), account: Self.passwordKey)
        } else if !savedPassword.isEmpty {
            Keychain.delete(account: Self.passwordKey)
        }

        status = "Signed in as \(account.summary)"
        append(status, .success)
    }

    func signOut() {
        account = nil
        app = nil
        ticket = nil
        downloadedIPA = nil
        cancelChallenge()
        Keychain.delete(account: Self.accountKey)
        status = "Signed out"
    }

    // MARK: - Anisette

    private func anisetteHeaders() async -> AnisetteHeaders? {
        guard usesAnisette else { return nil }
        let provider = AnisetteProvider(
            endpoint: anisetteURL,
            username: anisetteUser,
            password: anisettePassword,
            guid: guid
        )
        do {
            let headers = try await provider.headers()
            var values = headers.values
            for (key, value) in AnisetteHeaders.local(guid: guid).values where values[key] == nil {
                values[key] = value
            }
            append("Anisette: X-Apple-I-MD \(values["X-Apple-I-MD"]?.count ?? 0) chars.", .debug)
            return AnisetteHeaders(values: values)
        } catch {
            append((error as? LocalizedError)?.errorDescription ?? "\(error)", .error)
            return nil
        }
    }

    // MARK: - Lookup

    func lookUp(_ identifier: String) async {
        busy = true
        error = nil
        app = nil
        ticket = nil
        downloadedIPA = nil
        downloadProgress = 0
        defer { busy = false }

        guard let parsed = AppStoreIdentifier.parse(identifier) else {
            error = "That is not an App Store id, bundle id or apps.apple.com link."
            return
        }

        status = "Looking up \(parsed.display) in the \(country.uppercased()) storefront…"
        do {
            let app = try await AppStoreLookup.lookup(parsed, country: country)
            self.app = app
            status = "\(app.name) · \(app.bundleID) · \(app.version)"
            append(status, .success)
        } catch {
            fail(error, keepStatus: false)
        }
    }

    // MARK: - Download

    func download() async {
        guard let app else {
            error = "Look up an app first."
            return
        }
        guard account != nil else {
            error = "Sign in with the Apple ID that owns the app."
            return
        }

        busy = true
        error = nil
        downloadProgress = 0
        defer { busy = false }

        do {
            status = "Requesting a licence for \(app.name)…"
            append(status, .command)
            try await client.purchase(app)

            status = "Requesting a download ticket…"
            append(status, .command)
            let ticket = try await client.ticket(for: app, externalVersionID: nil) { [weak self] note in
                Task { @MainActor in self?.append(note, .warn) }
            }
            self.ticket = ticket
            append("Ticket: \(ticket.bundleID) \(ticket.version) · \(ticket.sinfs) sinf(s)", .info)

            let safeName = "\(app.bundleID)_\(ticket.version.isEmpty ? app.version : ticket.version).ipa"
                .replacingOccurrences(of: "/", with: "-")
            let destination = outputDirectory.appendingPathComponent(safeName)

            status = "Downloading…"
            append(status, .command)

            try await client.download(ticket, to: destination) { [weak self] written, total in
                Task { @MainActor in
                    guard let self else { return }
                    self.downloadProgress = total > 0 ? Double(written) / Double(total) : 0
                    self.status = "Downloading \(ByteCountFormatter.string(fromByteCount: written, countStyle: .file))"
                        + (total > 0 ? " / \(ByteCountFormatter.string(fromByteCount: total, countStyle: .file))" : "")
                }
            }

            downloadProgress = 1
            downloadedIPA = destination
            status = "Downloaded \(destination.lastPathComponent)"
            append(status, .success)

            if let metadata = try? IPATool.metadata(for: destination) {
                append("IPA contains \(metadata.bundleID) \(metadata.version) (minOS \(metadata.minimumOS)).", .info)
            } else {
                append("Warning: the download does not look like a standard IPA.", .warn)
            }
        } catch AppStoreError.signIn(let message) where message.contains("session expired") {
            fail(AppStoreError.signIn(message))
        } catch {
            fail(error)
        }
    }

    func forgetDownload() {
        downloadedIPA = nil
        ticket = nil
        downloadProgress = 0
    }

    // MARK: - Helpers

    /// Everything a support conversation needs: the app log plus the exact
    /// request/response pairs Apple answered.
    var diagnosticsText: String {
        var lines = ["DecryptIPA App Store diagnostics"]
        lines.append("device GUID: \(guid)")
        lines.append("storefront: \(country)")
        lines.append("anisette: \(usesAnisette ? anisetteURL : "none")")
        lines.append("mode: \(usesAnisette ? "native" : "legacy")")
        lines.append("")
        lines.append("— requests —")
        for exchange in client.exchanges {
            lines.append(exchange.summary)
        }
        lines.append("")
        lines.append("— log —")
        for entry in log {
            lines.append("[\(entry.level.rawValue)] \(entry.text)")
        }
        return lines.joined(separator: "\n")
    }

    private func fail(_ error: Error, keepStatus: Bool = false) {
        let message = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        self.error = message
        if !keepStatus { status = "" }
        append(message, .error)
    }

    private func append(_ text: String, _ level: LogLevel = .info) {
        log.append(LogEntry(level: level, text: text))
        if log.count > 400 { log.removeFirst(log.count - 400) }
    }
}
