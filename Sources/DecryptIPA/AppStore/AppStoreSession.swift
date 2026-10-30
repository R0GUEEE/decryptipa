import Foundation
import Combine
import RemoteAnisette

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
    @Published private(set) var searchResults: [AppStoreApp] = []
    @Published private(set) var downloadedIPA: URL?
    @Published private(set) var ticket: AppStoreTicket?

    // Sign-in state
    @Published private(set) var challenge: TwoFactorChallenge?
    @Published private(set) var selectedOptionID: String?
    @Published private(set) var codeRequestedAt: Date?
    @Published private(set) var waitingForCode = false
    /// Set when Apple answers 429. Sign-in stays disabled until it passes.
    @Published private(set) var retryAfter: Date?

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
    @Published var automaticAnisetteServer: String {
        didSet {
            defaults.set(automaticAnisetteServer, forKey: Self.automaticAnisetteServerKey)
            let selectedHost = URL(string: automaticAnisetteServer)?.host
            if automaticAnisetteUser != nil, selectedHost != automaticAnisetteUser?.url.host {
                automaticAnisetteUser = nil
                automaticAnisetteReady = false
                Keychain.delete(account: Self.automaticAnisetteUserKey)
                Diagnostics.breadcrumb("anisette server changed; clearing server-bound provision")
            }
        }
    }
    @Published private(set) var automaticAnisetteReady = false
    @Published private(set) var anisetteServerOptions = AnisetteServerOption.publicOptions
    @Published private(set) var anisetteCatalogRefreshing = false

    private var automaticAnisetteUser: AnisetteUser? = nil
    private var anisetteCatalogFetchedAt: Date? = nil
    private static let accountKey = "appstore.account"
    private static let passwordKey = "appstore.password"
    private static let guidKey = "appstore.guid"
    private static let countryKey = "appstore.country"
    private static let anisetteKey = "appstore.anisette.url"
    private static let anisetteUserKey = "appstore.anisette.user"
    private static let anisettePasswordKey = "appstore.anisette.password"
    private static let automaticAnisetteServerKey = "appstore.anisette.auto.server"
    private static let automaticAnisetteUserKey = "appstore.anisette.auto.user"
    private static let anisetteServerListKey = "appstore.anisette.server.list"
    private static let anisetteServerListDateKey = "appstore.anisette.server.list.date"
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
        Diagnostics.breadcrumb("appstore session: init started")
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
        self.automaticAnisetteServer = defaults.string(forKey: Self.automaticAnisetteServerKey)
            ?? "https://ani.sidestore.io"
        if let cached = defaults.data(forKey: Self.anisetteServerListKey),
           let options = try? JSONDecoder().decode([AnisetteServerOption].self, from: cached),
           !options.isEmpty {
            self.anisetteServerOptions = options
        }
        self.anisetteCatalogFetchedAt = defaults.object(forKey: Self.anisetteServerListDateKey) as? Date
        self.automaticAnisetteUser = nil

        self.client = AppStoreClient(guid: guid)

        if let stored = Keychain.load(account: Self.automaticAnisetteUserKey),
           let user = try? JSONDecoder().decode(AnisetteUser.self, from: stored) {
            self.automaticAnisetteUser = user
            self.automaticAnisetteReady = true
        }

        Diagnostics.breadcrumb("appstore session initialised · automatic anisette=" + String(automaticAnisetteReady))
        if let data = Keychain.load(account: Self.accountKey),
           let saved = try? JSONDecoder().decode(AppStoreAccount.self, from: data) {
            account = saved
            client.adopt(saved)
        }
    }

    var deviceGUID: String { guid }
    var isSignedIn: Bool { account != nil }
    var usesAnisette: Bool {
        !anisetteURL.trimmingCharacters(in: .whitespaces).isEmpty || automaticAnisetteReady
    }

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

    var cooldownActive: Bool {
        guard let retryAfter else { return false }
        return retryAfter > Date()
    }

    var cooldownText: String {
        guard let retryAfter, retryAfter > Date() else { return "" }
        return retryAfter.formatted(date: .omitted, time: .shortened)
    }

    func beginSignIn(email: String, password: String, rememberPassword: Bool) async {
        if cooldownActive {
            error = "Apple rate limited sign-in. Try again after " + cooldownText + "."
            return
        }

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
        Diagnostics.breadcrumb("apple sign-in started · anisette=\(usesAnisette) · storefront=\(country)")

        if !automaticAnisetteReady {
            do {
                let address = automaticAnisetteServer.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let url = URL(string: address), url.scheme?.lowercased() == "https", url.host != nil else {
                    throw appFailure("Select a valid HTTPS Anisette-v3 server in Advanced sign-in settings.")
                }
                status = "Automatically setting up Anisette…"
                try await provisionAutomaticAnisette(at: url)
            } catch {
                fail(error)
                return
            }
        }

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
        } catch let error as AppStoreError {
            if case .rateLimited(_, let wait) = error {
                retryAfter = Date().addingTimeInterval(TimeInterval(wait ?? 90))
                append("Apple rate limited sign-in; pausing attempts until " + cooldownText + ".", .warn)
            }
            fail(error)
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
        Diagnostics.breadcrumb("apple 2FA delivery requested · mode=\(challenge.mode.rawValue) · method=\(option.kind.rawValue)")

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
                append("Requested " + option.detail.lowercased() + " → " + option.title, .command)
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
            switch option.kind {
            case .sms: status = "Code texted to " + option.title
            case .voice: status = "Apple will call " + option.title
            case .email: status = "Code emailed to " + option.title
            case .trustedDevice: status = "Code requested from your trusted devices"
            }
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
        Diagnostics.breadcrumb("apple 2FA code submitted · mode=\(challenge.mode.rawValue)")

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
        let passwordToRemember = pendingPassword
        self.account = account
        challenge = nil
        waitingForCode = false
        pendingPassword = ""

        if let data = try? JSONEncoder().encode(account) {
            Keychain.save(data, account: Self.accountKey)
        }
        if let savedPassword = AppStoreCredentialPolicy.rememberedPassword(passwordToRemember, remember: pendingRemember) {
            Keychain.save(Data(savedPassword.utf8), account: Self.passwordKey)
        } else if !savedPassword.isEmpty {
            Keychain.delete(account: Self.passwordKey)
        }

        status = "Signed in as \(account.summary)"
        append(status, .success)
    }

    /// Adopts a session produced elsewhere (ipatool, ipadecrypt, a script).
    /// Apple only requires the token from this point on, so a session harvested
    /// on a machine that can sign is still usable for licences and downloads.
    func importSession(dsid: String, token: String, storefront: String, pod: String) -> Bool {
        let dsid = dsid.trimmingCharacters(in: .whitespacesAndNewlines)
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        var storefront = storefront.trimmingCharacters(in: .whitespacesAndNewlines)
        let pod = pod.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !dsid.isEmpty, !token.isEmpty, !storefront.isEmpty else {
            error = "DSID, token and storefront are all required."
            return false
        }

        // Apple accepts "143441" and returns "143441-1,29"; add the suffix when
        // only the bare storefront id was pasted.
        if !storefront.contains("-") {
            storefront += "-1,29"
        }

        let account = AppStoreAccount(
            email: account?.email ?? "imported session",
            passwordToken: token,
            directoryServicesID: dsid,
            storeFront: storefront,
            pod: pod,
            name: "",
            country: country
        )

        self.account = account
        client.adopt(account)
        if let data = try? JSONEncoder().encode(account) {
            Keychain.save(data, account: Self.accountKey)
        }

        append("Imported App Store session for DSID \(dsid) (storefront \(storefront)).", .success)
        status = "Session imported"
        error = nil
        return true
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

    /// Refreshes the SideStore public catalog, retaining the last good copy if
    /// offline. The list endpoint is fixed to servers.sidestore.io and candidate
    /// URLs are HTTPS-validated by AnisetteServerOption.
    func refreshPublicAnisetteServers(force: Bool = false) async {
        if anisetteCatalogRefreshing { return }
        if !force, let anisetteCatalogFetchedAt,
           Date().timeIntervalSince(anisetteCatalogFetchedAt) < 6 * 60 * 60 {
            return
        }

        anisetteCatalogRefreshing = true
        defer { anisetteCatalogRefreshing = false }
        do {
            let options = try await AnisetteServerOption.fetchPublicOptions()
            anisetteServerOptions = options
            anisetteCatalogFetchedAt = Date()
            if let data = try? JSONEncoder().encode(options) {
                defaults.set(data, forKey: Self.anisetteServerListKey)
            }
            defaults.set(anisetteCatalogFetchedAt, forKey: Self.anisetteServerListDateKey)
            append("Updated public Anisette server list (" + String(options.count) + " HTTPS servers).", .info)
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            append("Could not refresh SideStore server list; using cached public options. " + message, .warn)
            if anisetteServerOptions.isEmpty { anisetteServerOptions = AnisetteServerOption.publicOptions }
        }
    }

    /// Explicitly tests/configures the selected server from Advanced settings.
    /// First sign-in also invokes this automatically if no session is saved.
    func configureAutomaticAnisette() async {
        let address = automaticAnisetteServer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: address), url.scheme?.lowercased() == "https", url.host != nil else {
            error = "Enter a valid HTTPS Anisette-v3 server URL."
            return
        }

        busy = true
        error = nil
        status = "Provisioning Anisette with " + (url.host ?? address) + "…"
        defer { busy = false }

        do {
            try await provisionAutomaticAnisette(at: url)
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            self.error = "Anisette setup failed: " + message
            status = ""
            append(self.error ?? "Anisette setup failed", .error)
            Diagnostics.breadcrumb("anisette provisioning failed · " + message)
        }
    }

    private func provisionAutomaticAnisette(at preferredURL: URL) async throws -> AnisetteHeaders {
        await refreshPublicAnisetteServers()

        let selectedServer = automaticAnisetteServer
        let customOption: AnisetteServerOption?
        if !anisetteServerOptions.contains(where: { $0.url == selectedServer }),
           let url = URL(string: selectedServer), url.scheme?.lowercased() == "https", url.host != nil {
            customOption = AnisetteServerOption(name: "Selected", url: selectedServer)
        } else {
            customOption = nil
        }
        let source = anisetteServerOptions + (customOption.map { [$0] } ?? [])
        var candidates = AnisetteServerOption.rotated(source, startingAt: selectedServer)
        if candidates.isEmpty { candidates = AnisetteServerOption.rotated(AnisetteServerOption.publicOptions, startingAt: selectedServer) }

        var failures: [String] = []
        for (index, option) in candidates.enumerated() {
            guard let url = URL(string: option.url), url.scheme?.lowercased() == "https", url.host != nil else {
                continue
            }
            let host = url.host ?? option.url
            status = "Setting up Anisette · server " + String(index + 1) + " of " + String(candidates.count)
            Diagnostics.breadcrumb("anisette provision attempt " + String(index + 1) + "/" + String(candidates.count) + " · " + host)

            do {
                let user = try await AnisetteUser.provision(url: url)
                let headers = try AnisetteHeaders.validated(await user.fetchHeaders())
                guard let data = try? JSONEncoder().encode(user) else {
                    throw appFailure("Could not store the Anisette device state.")
                }

                // Remember the first server that successfully provisions and
                // returns usable rotating headers. didSet clears any old server-
                // bound identity before the new one is stored.
                if automaticAnisetteServer != option.url {
                    automaticAnisetteServer = option.url
                }
                Keychain.save(data, account: Self.automaticAnisetteUserKey)
                automaticAnisetteUser = user
                automaticAnisetteReady = true
                status = "Anisette is ready · " + option.name
                append("Anisette ready from " + host + "; rotating headers validated.", .success)
                Diagnostics.breadcrumb("anisette server selected · " + host)
                return headers
            } catch {
                let reason = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
                failures.append(host + ": " + reason)
                append("Anisette server failed; trying next provider. " + host, .warn)
                Diagnostics.breadcrumb("anisette server failed · " + host + " · " + reason)
            }
        }

        let details = failures.suffix(4).joined(separator: " | ")
        throw appFailure("All " + String(candidates.count) + " public Anisette servers failed." + (details.isEmpty ? "" : " " + details))
    }

    func removeAutomaticAnisette() {
        automaticAnisetteUser = nil
        automaticAnisetteReady = false
        Keychain.delete(account: Self.automaticAnisetteUserKey)
        status = "Automatic Anisette setup removed"
        append(status, .info)
    }

    private func anisetteHeaders() async -> AnisetteHeaders? {
        if let automaticAnisetteUser {
            do {
                return mergeLocalHeaders(try AnisetteHeaders.validated(await automaticAnisetteUser.fetchHeaders()))
            } catch {
                let host = automaticAnisetteUser.url.host ?? "unknown"
                let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
                append("Anisette server failed; rotating through SideStore's public list. " + host, .warn)
                Diagnostics.breadcrumb("anisette fetch failed · rotating from " + host + " · " + message)
                do {
                    let preferred = URL(string: automaticAnisetteServer) ?? AnisetteServerOption.catalogURL
                    return mergeLocalHeaders(try await provisionAutomaticAnisette(at: preferred))
                } catch {
                    append((error as? LocalizedError)?.errorDescription ?? String(describing: error), .error)
                }
            }
        } else {
            do {
                let preferred = URL(string: automaticAnisetteServer) ?? AnisetteServerOption.catalogURL
                return mergeLocalHeaders(try await provisionAutomaticAnisette(at: preferred))
            } catch {
                append((error as? LocalizedError)?.errorDescription ?? String(describing: error), .error)
            }
        }

        // Backward compatibility only: migrate users who had a manually entered
        // single endpoint in earlier builds. New setups always prefer the public
        // SideStore catalog and rotate through its providers.
        let manualEndpoint = anisetteURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !manualEndpoint.isEmpty {
            do {
                let provider = AnisetteProvider(
                    endpoint: manualEndpoint,
                    username: anisetteUser,
                    password: anisettePassword,
                    guid: guid
                )
                return mergeLocalHeaders(try await provider.headers())
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
                append("Legacy Anisette endpoint also failed: " + message, .error)
            }
        }
        return nil
    }

    private func mergeLocalHeaders(_ headers: AnisetteHeaders) -> AnisetteHeaders {
        var values = headers.values
        for (key, value) in AnisetteHeaders.local(guid: guid).values where values[key] == nil {
            values[key] = value
        }
        append("Anisette: X-Apple-I-MD " + String(values["X-Apple-I-MD"]?.count ?? 0) + " chars.", .debug)
        return AnisetteHeaders(values: values)
    }

    // MARK: - Lookup

    func searchApps(_ query: String) async {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else {
            searchResults = []
            return
        }
        busy = true
        error = nil
        status = "Searching the " + country.uppercased() + " App Store…"
        defer { busy = false }
        do {
            if let identifier = AppStoreIdentifier.parse(term) {
                do {
                    let exact = try await AppStoreLookup.lookup(identifier, country: country)
                    searchResults = [exact]
                    status = "Found exact match: " + exact.name
                    append(status, .success)
                    return
                } catch {
                    // A reverse-DNS string may be a search phrase, so fall back
                    // to the public term endpoint if exact lookup found nothing.
                    if case .bundleID = identifier { }
                    else { throw error }
                }
            }
            searchResults = try await AppStoreLookup.search(term, country: country)
            status = searchResults.isEmpty ? "No results" : "Found " + String(searchResults.count) + " apps"
            append(status, searchResults.isEmpty ? .warn : .success)
        } catch {
            fail(error, keepStatus: false)
        }
    }

    func selectApp(_ app: AppStoreApp) {
        self.app = app
        searchResults = []
        ticket = nil
        downloadedIPA = nil
        error = nil
        status = app.name + " · " + app.bundleID + " · " + app.version
        append("Selected " + app.name + " (" + app.bundleID + ").", .success)
    }

    func clearSearch() {
        searchResults = []
    }

    func deselectApp() {
        app = nil
        downloadedIPA = nil
        ticket = nil
        status = ""
    }

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
        lines.append("anisette manual endpoint: " + (anisetteURL.isEmpty ? "none" : anisetteURL))
        lines.append("anisette automatic: " + (automaticAnisetteReady ? automaticAnisetteServer : "not configured"))
        lines.append("mode: " + (usesAnisette ? "native" : "legacy"))
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
