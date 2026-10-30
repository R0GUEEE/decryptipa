import Foundation

// MARK: - Models

struct AppStoreAccount: Codable, Equatable {
    var email: String
    var passwordToken: String
    var directoryServicesID: String
    var storeFront: String
    var pod: String
    var name: String
    var country: String

    var summary: String {
        name.isEmpty ? email : "\(name) · \(email)"
    }
}

struct AppStoreTicket {
    var url: URL
    var version: String
    var bundleID: String
    var fileSize: Int64
    var sinfs: Int
    /// Raw metadata dictionary from Apple, kept for diagnostics.
    var metadata: [String: String]
}

enum AppStoreError: LocalizedError {
    case authCodeRequired
    case signIn(String)
    case notOwned
    case subscriptionRequired
    case temporarilyUnavailable
    case needsAttestation
    case licenseRequired

    var errorDescription: String? {
        switch self {
        case .authCodeRequired:
            return "Apple sent a two-factor code prompt. Enter the 6-digit code and sign in again."
        case .signIn(let message):
            return message
        case .notOwned:
            return "This account does not own the app and it is not free — buy it in the App Store first."
        case .subscriptionRequired:
            return "This app requires an active subscription on this Apple ID."
        case .temporarilyUnavailable:
            return "Apple answered \"temporarily unavailable\". Try again in a few minutes."
        case .needsAttestation:
            return "Apple will only serve this build to an attested device (HTTP 403 from downloaddispatch). "
                + "Install the app from the App Store on the jailbroken device and decrypt the installed copy instead."
        case .licenseRequired:
            return "No licence for this account yet — the app must be acquired (purchased or downloaded once) before it can be decrypted."
        }
    }
}

struct AppStoreBag {
    var authEndpoint: String?
    var volumeStoreEndpoint: String?
    var redownloadEndpoint: String?
    var updateEndpoint: String?
}

// MARK: - Client

/// Port of ipadecrypt's internal/appstore client for the paths a phone can
/// actually run: bag lookup, password + 2FA sign-in, licence acquisition for
/// free apps, and the download-product endpoints.
///
/// It deliberately does not do the SAP action signature or the FairPlay
/// `kbsync` blob — both come from Apple frameworks ipadecrypt emulates on the
/// desktop. Without them the attested `ent/download` endpoint answers 403,
/// which is surfaced as `AppStoreError.needsAttestation` rather than as a
/// generic failure.
final class AppStoreClient {
    static let defaultAuthURL = "https://buy.itunes.apple.com/WebObjects/MZFinance.woa/wa/authenticate/"
    static let bagURL = "https://init.itunes.apple.com/bag.xml"
    static let purchasePath = "/WebObjects/MZFinance.woa/wa/buyProduct"
    static let downloadPath = "/WebObjects/MZFinance.woa/wa/volumeStoreDownloadProduct"
    static let redownloadPath = "/r/redownload"
    static let updatePath = "/up/updateProduct"

    let http: AppStoreHTTP
    let guid: String
    private var bag: AppStoreBag?
    private(set) var account: AppStoreAccount?
    /// Why native auth was skipped or failed, for the UI to surface.
    var lastNativeFailure: String?

    init(guid: String) {
        self.guid = guid
        self.http = AppStoreHTTP()
    }

    // MARK: Bag

    func fetchBag(forceRefresh: Bool = false) async throws -> AppStoreBag {
        if let bag, !forceRefresh { return bag }

        guard var components = URLComponents(string: Self.bagURL) else {
            throw AppStoreError.signIn("Malformed bag URL.")
        }
        components.queryItems = [URLQueryItem(name: "guid", value: guid)]

        var request = URLRequest(url: components.url!)
        request.setValue("application/xml", forHTTPHeaderField: "Accept")
        request.setValue(Self.configuratorUA, forHTTPHeaderField: "User-Agent")

        let (data, response) = try await http.send(request)
        guard response.statusCode == 200 else {
            throw AppStoreError.signIn("App Store bag request failed (HTTP \(response.statusCode)).")
        }

        let root = try AppStorePlist.parse(data)
        let urlBag = (root["urlBag"] as? [String: Any]) ?? root

        let bag = AppStoreBag(
            authEndpoint: urlBag["authenticateAccount"] as? String,
            volumeStoreEndpoint: urlBag["volumeStoreDownloadProduct"] as? String,
            redownloadEndpoint: urlBag["redownloadProduct"] as? String,
            updateEndpoint: urlBag["updateProduct"] as? String
        )
        self.bag = bag
        return bag
    }

    // MARK: Sign in

    /// Mirrors appstore.Login: POST an XML plist to the authenticate endpoint,
    /// follow the pod redirect by re-posting, retry once on `-5000`, and treat
    /// "BadLogin.Configurator_message" as the 2FA gate.
    func signIn(email: String, password: String, authCode: String, country: String) async throws -> AppStoreAccount {
        var endpoint = Self.defaultAuthURL
        if let bagEndpoint = try? await fetchBag().authEndpoint, !bagEndpoint.isEmpty {
            endpoint = bagEndpoint
            if !endpoint.hasSuffix("/") { endpoint += "/" }
        }

        var url = endpoint
        var redirect = false
        var lastMessage = "sign-in failed"

        for attempt in 1...4 {
            let requestAttempt = redirect ? 1 : attempt

            var request = URLRequest(url: URL(string: url) ?? URL(string: Self.defaultAuthURL)!)
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.setValue("application/xml", forHTTPHeaderField: "Accept")
            request.setValue(Self.configuratorUA, forHTTPHeaderField: "User-Agent")
            request.httpBody = AppStorePlist.body([
                "appleId": email,
                "attempt": "\(requestAttempt)",
                "guid": guid,
                "password": password + authCode.replacingOccurrences(of: " ", with: ""),
                "rmp": "0",
                "why": "signIn"
            ])

            let (data, response) = try await http.send(request)

            if response.statusCode == 301 || response.statusCode == 302 || response.statusCode == 307 {
                guard let location = response.value(forHTTPHeaderField: "Location"),
                      Self.isAllowedAuthEndpoint(location) else {
                    throw AppStoreError.signIn("Apple redirected sign-in to an unexpected host.")
                }
                url = location
                redirect = true
                continue
            }

            let payload = (try? AppStorePlist.parse(data)) ?? [:]
            let failureType = (payload["failureType"] as? String) ?? ""
            let customerMessage = (payload["customerMessage"] as? String) ?? ""
            let dsid = (payload["dsPersonId"] as? String) ?? ""
            let token = (payload["passwordToken"] as? String) ?? ""

            if attempt == 1 && failureType == "-5000" {
                lastMessage = customerMessage.isEmpty ? "invalid credentials" : customerMessage
                continue
            }

            if failureType.isEmpty, authCode.isEmpty,
               customerMessage == "MZFinance.BadLogin.Configurator_message" {
                throw AppStoreError.authCodeRequired
            }

            if customerMessage == "Your account is disabled." {
                throw AppStoreError.signIn("This Apple ID is disabled.")
            }

            if !failureType.isEmpty {
                throw AppStoreError.signIn(customerMessage.isEmpty ? "Sign-in failed (failureType \(failureType))." : customerMessage)
            }

            guard response.statusCode == 200, !token.isEmpty, !dsid.isEmpty else {
                throw AppStoreError.signIn("Sign-in failed (HTTP \(response.statusCode)). Apple said: \(AppStorePlist.snippet(data))")
            }

            let accountInfo = payload["accountInfo"] as? [String: Any] ?? [:]
            let address = accountInfo["address"] as? [String: Any] ?? [:]
            let first = (address["firstName"] as? String) ?? ""
            let last = (address["lastName"] as? String) ?? ""

            let account = AppStoreAccount(
                email: (accountInfo["appleId"] as? String) ?? email,
                passwordToken: token,
                directoryServicesID: dsid,
                storeFront: response.value(forHTTPHeaderField: "X-Set-Apple-Store-Front") ?? "",
                pod: response.value(forHTTPHeaderField: "pod") ?? "",
                name: "\(first) \(last)".trimmingCharacters(in: .whitespaces),
                country: country.lowercased()
            )

            guard !account.storeFront.isEmpty else {
                throw AppStoreError.signIn("Signed in, but Apple returned no storefront header (X-Set-Apple-Store-Front).")
            }

            self.account = account
            return account
        }

        throw AppStoreError.signIn("Sign-in failed: \(lastMessage).")
    }

    func adopt(_ account: AppStoreAccount) {
        self.account = account
    }

    // MARK: Purchase

    /// Acquires a licence for a free app so the download endpoint has something
    /// to authorise against. An existing licence is not an error.
    func purchase(_ app: AppStoreApp) async throws {
        guard let account else { throw AppStoreError.signIn("Sign in to the App Store first.") }
        guard app.isFree else { throw AppStoreError.notOwned }

        let url = "https://\(podPrefix(account))buy.itunes.apple.com\(Self.purchasePath)"
        var request = URLRequest(url: URL(string: url)!)
        request.httpMethod = "POST"
        request.setValue("application/x-apple-plist", forHTTPHeaderField: "Content-Type")
        request.setValue("application/xml", forHTTPHeaderField: "Accept")
        request.setValue(Self.configuratorUA, forHTTPHeaderField: "User-Agent")
        request.setValue(account.directoryServicesID, forHTTPHeaderField: "iCloud-DSID")
        request.setValue(account.directoryServicesID, forHTTPHeaderField: "X-Dsid")
        request.setValue(account.storeFront, forHTTPHeaderField: "X-Apple-Store-Front")
        request.setValue(account.passwordToken, forHTTPHeaderField: "X-Token")
        request.httpBody = AppStorePlist.body([
            "appExtVrsId": "0",
            "hasAskedToFulfillPreorder": "true",
            "buyWithoutAuthorization": "true",
            "hasDoneAgeCheck": "true",
            "guid": guid,
            "needDiv": "0",
            "origPage": "Software-\(app.trackID)",
            "origPageLocation": "Buy",
            "price": "0",
            "pricingParameters": "STDQ",
            "productType": "C",
            "salableAdamId": "\(app.trackID)"
        ], integers: ["salableAdamId"])

        let (data, response) = try await http.send(request)
        let payload = (try? AppStorePlist.parse(data)) ?? [:]
        let failureType = (payload["failureType"] as? String) ?? ""
        let message = (payload["customerMessage"] as? String) ?? ""

        if failureType == "5002" || response.statusCode == 500 { return }

        switch failureType {
        case "2059":
            throw AppStoreError.temporarilyUnavailable
        case "2042", "2034", "1008":
            throw AppStoreError.signIn("The App Store session expired. Sign in again.")
        case "":
            if message == "Subscription Required" { throw AppStoreError.subscriptionRequired }
            return
        default:
            throw AppStoreError.signIn(message.isEmpty ? "Apple refused the licence (failureType \(failureType))." : "Apple refused the licence: \(message)")
        }
    }

    // MARK: Download ticket

    func ticket(
        for app: AppStoreApp,
        externalVersionID: String?,
        onNote: @escaping @Sendable (String) -> Void
    ) async throws -> AppStoreTicket {
        guard let account else { throw AppStoreError.signIn("Sign in to the App Store first.") }

        let legacy = "https://\(podPrefix(account))buy.itunes.apple.com\(Self.downloadPath)"
        let primary = try await postDownloadProduct(
            base: legacy,
            versionKey: "externalVersionId",
            account: account,
            app: app,
            externalVersionID: externalVersionID
        )

        if let ticket = try classify(primary.payload) { return ticket }
        if primary.status == 403 { throw AppStoreError.needsAttestation }

        onNote("Legacy store endpoint returned no items — trying the download-dispatch endpoints.")
        let bag = (try? await fetchBag()) ?? AppStoreBag()
        let versionID = externalVersionID

        if let endpoint = bag.redownloadEndpoint,
           let redownloadURL = Self.dispatchURL(endpoint, Self.redownloadPath, guid: guid) {
            let result = try await postDownloadProduct(
                base: redownloadURL,
                versionKey: "appExtVrsId",
                account: account,
                app: app,
                externalVersionID: versionID
            )

            if result.status == 403 { throw AppStoreError.needsAttestation }
            if let ticket = try classify(result.payload) { return ticket }

            let emptyServer = result.status == 500
            let unavailable = result.status == 200 && Self.isUnavailable(result.payload)

            if (emptyServer || unavailable), let updateEndpoint = bag.updateEndpoint,
               let updateURL = Self.dispatchURL(updateEndpoint, Self.updatePath, guid: guid) {
                let updated = try await postDownloadProduct(
                    base: updateURL,
                    versionKey: "appExtVrsId",
                    account: account,
                    app: app,
                    externalVersionID: versionID
                )

                if updated.status == 403 { throw AppStoreError.needsAttestation }
                if let ticket = try classify(updated.payload) { return ticket }
            }
        }

        throw AppStoreError.signIn("Apple returned no downloadable item for \(app.bundleID).")
    }

    private struct DownloadAttempt {
        let payload: [String: Any]
        let status: Int
    }

    private func postDownloadProduct(
        base: String,
        versionKey: String,
        account: AppStoreAccount,
        app: AppStoreApp,
        externalVersionID: String?
    ) async throws -> DownloadAttempt {
        guard var components = URLComponents(string: base) else {
            throw AppStoreError.signIn("Malformed download endpoint.")
        }
        components.queryItems = [URLQueryItem(name: "guid", value: guid)]

        var values: [String: String] = [
            "creditDisplay": "",
            "guid": guid,
            "salableAdamId": "\(app.trackID)",
            "serialNumber": "0"
        ]
        if let externalVersionID, !externalVersionID.isEmpty {
            values[versionKey] = externalVersionID
        }

        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.setValue("application/x-apple-plist", forHTTPHeaderField: "Content-Type")
        request.setValue("application/xml", forHTTPHeaderField: "Accept")
        request.setValue(Self.configuratorUA, forHTTPHeaderField: "User-Agent")
        request.setValue(account.directoryServicesID, forHTTPHeaderField: "iCloud-DSID")
        request.setValue(account.directoryServicesID, forHTTPHeaderField: "X-Dsid")
        request.httpBody = AppStorePlist.body(values)

        let (data, response) = try await http.send(request)
        let payload = (try? AppStorePlist.parse(data)) ?? [:]
        return DownloadAttempt(payload: payload, status: response.statusCode)
    }

    private func classify(_ payload: [String: Any]) throws -> AppStoreTicket? {
        let failureType = (payload["failureType"] as? String) ?? ""
        let message = (payload["customerMessage"] as? String) ?? ""

        switch failureType {
        case "2034", "2042", "1008", "5002":
            throw AppStoreError.signIn("The App Store session expired. Sign in again.")
        case "9610":
            throw AppStoreError.licenseRequired
        case "":
            break
        default:
            throw AppStoreError.signIn(message.isEmpty ? "Download failed (failureType \(failureType))." : message)
        }

        guard let items = payload["songList"] as? [[String: Any]], let first = items.first else {
            return nil
        }

        let metadata = (first["metadata"] as? [String: Any]) ?? [:]
        let assetInfo = (first["asset-info"] as? [String: Any]) ?? [:]
        let sinfs = (first["sinfs"] as? [[String: Any]]) ?? []

        guard let raw = (first["URL"] as? String) ?? (first["url"] as? String),
              let url = URL(string: raw) else {
            throw AppStoreError.signIn("Apple returned a download item without a URL.")
        }

        var flattened: [String: String] = [:]
        for (key, value) in metadata {
            flattened[key] = "\(value)"
        }

        let size = (assetInfo["file-size"] as? NSNumber)?.int64Value
            ?? Int64((assetInfo["file-size"] as? String) ?? "") ?? 0

        return AppStoreTicket(
            url: url,
            version: flattened["bundleShortVersionString"] ?? "?",
            bundleID: flattened["softwareVersionBundleId"] ?? "",
            fileSize: size,
            sinfs: sinfs.count,
            metadata: flattened
        )
    }

    private static func isUnavailable(_ payload: [String: Any]) -> Bool {
        let failure = (payload["failureType"] as? String) ?? ""
        let message = ((payload["customerMessage"] as? String) ?? "").lowercased()
        let items = (payload["songList"] as? [[String: Any]]) ?? []
        return failure.isEmpty && items.isEmpty
            && (message == "no longer available" || message.hasSuffix(" no longer available"))
    }

    // MARK: Bytes

    /// Streams the signed CDN URL into `destination`. No App Store authentication
    /// is needed here — the URL carries its own signature.
    func download(
        _ ticket: AppStoreTicket,
        to destination: URL,
        onProgress: @escaping @Sendable (Int64, Int64) -> Void
    ) async throws {
        var request = URLRequest(url: ticket.url)
        request.setValue(Self.configuratorUA, forHTTPHeaderField: "User-Agent")

        let (bytes, response) = try await http.stream(request)
        guard response.statusCode == 200 else {
            throw AppStoreError.signIn("CDN download failed (HTTP \(response.statusCode)).")
        }

        let total = response.expectedContentLength > 0 ? response.expectedContentLength : ticket.fileSize

        FileManager.default.createFile(atPath: destination.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: destination) else {
            throw AppStoreError.signIn("Could not open \(destination.lastPathComponent) for writing.")
        }

        var written: Int64 = 0
        var buffer = Data()
        buffer.reserveCapacity(1 << 20)

        do {
            for try await byte in bytes {
                buffer.append(byte)
                if buffer.count >= 1 << 20 {
                    try handle.write(contentsOf: buffer)
                    written += Int64(buffer.count)
                    buffer.removeAll(keepingCapacity: true)
                    onProgress(written, total)
                }
            }
            if !buffer.isEmpty {
                try handle.write(contentsOf: buffer)
                written += Int64(buffer.count)
                onProgress(written, total)
            }
        } catch {
            try? handle.close()
            try? FileManager.default.removeItem(at: destination)
            throw error
        }

        try? handle.synchronize()
        try? handle.close()
    }

    // MARK: Helpers

    static let configuratorUA = "Configurator/2.15 (Macintosh; OS X 10.15.7; 16G29) AppleWebKit/605.1.15 (KHTML, like Gecko)"

    private func podPrefix(_ account: AppStoreAccount) -> String {
        account.pod.isEmpty ? "" : "p\(account.pod)-"
    }

    static func dispatchURL(_ endpoint: String, _ path: String, guid: String) -> String? {
        guard var components = URLComponents(string: endpoint.hasPrefix("http") ? endpoint : "https://\(endpoint)") else {
            return nil
        }
        components.path = path
        components.queryItems = [URLQueryItem(name: "guid", value: guid)]
        return components.url?.absoluteString
    }

    static func isAllowedAuthEndpoint(_ raw: String) -> Bool {
        guard let url = URL(string: raw), let host = url.host?.lowercased() else { return false }
        guard host == "buy.itunes.apple.com" || host.hasSuffix("-buy.itunes.apple.com") else { return false }
        let path = url.path
        let expected = "/WebObjects/MZFinance.woa/wa/authenticate"
        return path == expected || path == expected + "/"
    }
}

// MARK: - XML property lists

enum AppStorePlist {
    static func body(_ values: [String: String], integers: Set<String> = []) -> Data {
        var xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
        """

        for key in values.keys.sorted() {
            let value = values[key] ?? ""
            xml += "\n<key>\(escape(key))</key>"
            if integers.contains(key), let number = Int64(value) {
                xml += "<integer>\(number)</integer>"
            } else {
                xml += "<string>\(escape(value))</string>"
            }
        }

        xml += "\n</dict>\n</plist>\n"
        return Data(xml.utf8)
    }

    /// Apple wraps responses in a `<Document>` element, sometimes omits the
    /// `<plist>` envelope, and sometimes returns a bare `<key>`/`<value>` run.
    /// Normalise all three shapes before handing them to PropertyListSerialization.
    static func normalize(_ data: Data) -> Data {
        guard let text = String(data: data, encoding: .utf8) else { return data }
        var body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if body.isEmpty { return data }

        if let range = body.range(of: "<Document", options: .caseInsensitive),
           let openEnd = body.range(of: ">", range: range.lowerBound..<body.endIndex),
           let close = body.range(of: "</Document>", options: .caseInsensitive) {
            body = String(body[openEnd.upperBound..<close.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if let range = body.range(of: "<plist", options: .caseInsensitive),
           let close = body.range(of: "</plist>", options: .caseInsensitive) {
            body = String(body[range.lowerBound..<close.upperBound])
        } else if body.contains("<key>"), !body.hasPrefix("<dict") {
            body = "<dict>\n\(body)\n</dict>"
        }

        return Data(body.utf8)
    }

    static func parse(_ data: Data) throws -> [String: Any] {
        let normalized = normalize(data)
        if let plist = try? PropertyListSerialization.propertyList(from: normalized, options: [], format: nil) {
            return (plist as? [String: Any]) ?? [:]
        }
        throw AppStoreError.signIn("Apple returned a non-plist response: \(snippet(data))")
    }

    static func snippet(_ data: Data) -> String {
        let text = String(data: data.prefix(300), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "<\(data.count) bytes>"
        return text.isEmpty ? "<empty response>" : text
    }

    static func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}

// MARK: - URLSession plumbing

/// URLSession that never follows redirects (Apple's pod redirect must be
/// re-posted, not chased) and that lets us keep the raw 3xx status.
final class AppStoreHTTP: NSObject, URLSessionTaskDelegate {
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.httpCookieStorage = .shared
        configuration.httpShouldSetCookies = true
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 3600
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw AppStoreError.signIn("Apple returned a non-HTTP response.")
            }
            return (data, http)
        } catch let error as AppStoreError {
            throw error
        } catch {
            throw AppStoreError.signIn("Network error: \(error.localizedDescription)")
        }
    }

    func stream(_ request: URLRequest) async throws -> (URLSession.AsyncBytes, HTTPURLResponse) {
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw AppStoreError.signIn("Apple returned a non-HTTP response.")
            }
            return (bytes, http)
        } catch let error as AppStoreError {
            throw error
        } catch {
            throw AppStoreError.signIn("Network error: \(error.localizedDescription)")
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
