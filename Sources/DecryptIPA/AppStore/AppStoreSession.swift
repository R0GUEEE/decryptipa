import Foundation
import Combine

/// Account + download state for the App Store flow. Everything that survives a
/// relaunch lives in the keychain (session token, optional password) or
/// UserDefaults (device GUID, storefront country).
@MainActor
final class AppStoreSession: ObservableObject {
    @Published private(set) var account: AppStoreAccount?
    @Published private(set) var app: AppStoreApp?
    @Published private(set) var downloadedIPA: URL?
    @Published private(set) var ticket: AppStoreTicket?
    @Published private(set) var busy = false
    @Published private(set) var status: String = ""
    @Published private(set) var error: String?
    @Published private(set) var downloadProgress: Double = 0
    @Published private(set) var log: [LogEntry] = []

    @Published var country: String {
        didSet { defaults.set(country, forKey: Self.countryKey) }
    }

    private static let accountKey = "appstore.account"
    private static let passwordKey = "appstore.password"
    private static let guidKey = "appstore.guid"
    private static let countryKey = "appstore.country"

    private let guid: String
    private let defaults = UserDefaults.standard
    private let client: AppStoreClient
    private let outputDirectory: URL

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
        self.client = AppStoreClient(guid: guid)

        if let data = Keychain.load(account: Self.accountKey),
           let saved = try? JSONDecoder().decode(AppStoreAccount.self, from: data) {
            account = saved
            client.adopt(saved)
        }
    }

    var deviceGUID: String { guid }

    var isSignedIn: Bool { account != nil }

    var savedPassword: String {
        guard let data = Keychain.load(account: Self.passwordKey),
              let text = String(data: data, encoding: .utf8) else { return "" }
        return text
    }

    // MARK: Account

    func signIn(email: String, password: String, authCode: String, rememberPassword: Bool) async {
        busy = true
        error = nil
        status = "Signing in to the App Store…"
        defer { busy = false }

        do {
            let account = try await client.signIn(
                email: email.trimmingCharacters(in: .whitespacesAndNewlines),
                password: password,
                authCode: authCode.trimmingCharacters(in: .whitespaces),
                country: country
            )
            self.account = account
            persist(account)

            if rememberPassword {
                Keychain.save(Data(password.utf8), account: Self.passwordKey)
            } else {
                Keychain.delete(account: Self.passwordKey)
            }

            status = "Signed in as \(account.summary)"
            append(status, .success)
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            status = ""
            append(self.error ?? "sign-in failed", .error)
        }
    }

    func signOut() {
        account = nil
        app = nil
        ticket = nil
        downloadedIPA = nil
        Keychain.delete(account: Self.accountKey)
        status = "Signed out"
    }

    func reauthenticate() async {
        let email = account?.email ?? ""
        let password = savedPassword
        guard !email.isEmpty, !password.isEmpty else {
            error = "Sign in again — the App Store session expired."
            return
        }
        await signIn(email: email, password: password, authCode: "", rememberPassword: true)
    }

    private func persist(_ account: AppStoreAccount) {
        guard let data = try? JSONEncoder().encode(account) else { return }
        Keychain.save(data, account: Self.accountKey)
    }

    // MARK: Lookup

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

            if let account, !account.storeFront.isEmpty {
                append("Account storefront header: \(account.storeFront)", .debug)
            }
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            status = ""
        }
    }

    // MARK: Download

    /// Full path for an identifier: resolve → licence (free apps) → ticket →
    /// bytes. Writes into Documents/Imports so the existing pipeline can install
    /// and decrypt it.
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
            append("Ticket: \(ticket.bundleID) \(ticket.version) · \(ticket.sinfs) sinf(s) · \(ticket.url.host ?? "?")", .info)

            let safeName = "\(app.bundleID)_\(ticket.version.isEmpty ? app.version : ticket.version).ipa"
                .replacingOccurrences(of: "/", with: "-")
            let destination = outputDirectory.appendingPathComponent(safeName)

            status = "Downloading \(ticket.fileSize > 0 ? ByteCountFormatter.string(fromByteCount: ticket.fileSize, countStyle: .file) : "IPA")…"
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

            // Sanity check: the download must actually be an IPA with a Payload.
            if let metadata = try? IPATool.metadata(for: destination) {
                append("IPA contains \(metadata.bundleID) \(metadata.version) (minOS \(metadata.minimumOS)).", .info)
            } else {
                append("Warning: the download does not look like a standard IPA.", .warn)
            }
        } catch let appError as AppStoreError {
            self.error = appError.errorDescription
            status = ""
            append(self.error ?? "download failed", .error)
            if case .signIn(let message) = appError, message.contains("session expired") {
                append("Use \"Sign in again\" to refresh the password token.", .warn)
            }
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            status = ""
            append(self.error ?? "download failed", .error)
        }
    }

    func forgetDownload() {
        downloadedIPA = nil
        ticket = nil
        downloadProgress = 0
    }

    private func append(_ text: String, _ level: LogLevel = .info) {
        log.append(LogEntry(level: level, text: text))
        if log.count > 400 { log.removeFirst(log.count - 400) }
    }
}
