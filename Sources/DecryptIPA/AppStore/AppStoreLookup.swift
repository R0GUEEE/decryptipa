import Foundation

/// Anything the user can type to point at an App Store app: a numeric track id,
/// a bundle identifier, or an apps.apple.com link.
enum AppStoreIdentifier: Equatable {
    case trackID(Int64)
    case bundleID(String)
    case url(URL, trackID: Int64?)

    var display: String {
        switch self {
        case .trackID(let id): return "id\(id)"
        case .bundleID(let id): return id
        case .url(let url, _): return url.absoluteString
        }
    }

    /// Parses, in this order: apps.apple.com / itunes.apple.com URLs (with an
    /// `id<digits>` path component), pure digits, then reverse-DNS bundle ids.
    static func parse(_ raw: String) -> AppStoreIdentifier? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        if let url = URL(string: text), let host = url.host?.lowercased(),
           host.hasSuffix("apple.com") {
            return .url(url, trackID: trackID(inPath: url.path))
        }

        if text.allSatisfy({ $0.isNumber }), let id = Int64(text), id > 0 {
            return .trackID(id)
        }

        let bundle = text.lowercased()
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789.-_")
        guard bundle.rangeOfCharacter(from: allowed.inverted) == nil,
              bundle.contains("."),
              !bundle.hasPrefix("."),
              !bundle.hasSuffix(".") else {
            return nil
        }

        return .bundleID(text)
    }

    /// `https://apps.apple.com/us/app/name/id123456789` → 123456789
    static func trackID(inPath path: String) -> Int64? {
        for component in path.split(separator: "/") where component.hasPrefix("id") {
            let digits = component.dropFirst(2)
            if !digits.isEmpty, digits.allSatisfy({ $0.isNumber }) {
                return Int64(digits)
            }
        }
        return nil
    }
}

struct AppStoreApp: Identifiable, Hashable {
    var trackID: Int64
    var bundleID: String
    var name: String
    var seller: String
    var version: String
    var price: Double
    var minimumOS: String
    var artworkURL: URL?
    var storeURL: URL?
    var fileSizeBytes: Int64?

    var id: Int64 { trackID }

    var isFree: Bool { price <= 0 }

    var sizeText: String? {
        guard let fileSizeBytes, fileSizeBytes > 0 else { return nil }
        return ByteCountFormatter.string(fromByteCount: fileSizeBytes, countStyle: .file)
    }
}

struct AppStoreSearchResult: Identifiable, Hashable {
    var id: Int64 { app.trackID }
    let app: AppStoreApp
}
enum AppStoreLookup {
    static func search(_ term: String, country: String, limit: Int = 30) async throws -> [AppStoreApp] {
        var components = URLComponents(string: "https://itunes.apple.com/search")!
        components.queryItems = [
            URLQueryItem(name: "term", value: term),
            URLQueryItem(name: "country", value: country.lowercased()),
            URLQueryItem(name: "entity", value: "software"),
            URLQueryItem(name: "limit", value: String(min(max(limit, 1), 50)))
        ]
        guard let url = components.url else { throw appFailure("Could not build App Store search URL.") }
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw appFailure("App Store search failed (HTTP " + String((response as? HTTPURLResponse)?.statusCode ?? -1) + ").")
        }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = root["results"] as? [[String: Any]] else {
            throw appFailure("App Store search returned an unreadable response.")
        }
        return results.compactMap(parseApp).filter { !$0.bundleID.isEmpty && $0.trackID > 0 }
    }

    private static func parseApp(_ first: [String: Any]) -> AppStoreApp? {
        guard let trackID = (first["trackId"] as? NSNumber)?.int64Value else { return nil }
        return AppStoreApp(
            trackID: trackID,
            bundleID: (first["bundleId"] as? String) ?? "",
            name: (first["trackName"] as? String) ?? (first["bundleId"] as? String) ?? "Unknown",
            seller: (first["sellerName"] as? String) ?? (first["artistName"] as? String) ?? "",
            version: (first["version"] as? String) ?? "?",
            price: (first["price"] as? NSNumber)?.doubleValue ?? 0,
            minimumOS: (first["minimumOsVersion"] as? String) ?? "?",
            artworkURL: (first["artworkUrl100"] as? String).flatMap(URL.init(string:)),
            storeURL: (first["trackViewUrl"] as? String).flatMap(URL.init(string:)),
            fileSizeBytes: (first["fileSizeBytes"] as? NSNumber)?.int64Value
                ?? (first["fileSizeBytes"] as? String).flatMap { Int64($0) }
        )
    }

    /// `GET https://itunes.apple.com/lookup` — the same public endpoint the web
    /// store uses. Gives us the track id for a bundle id (and vice versa) plus
    /// the current version, price and artwork, without any Apple ID.
    static func lookup(_ identifier: AppStoreIdentifier, country: String) async throws -> AppStoreApp {
        var components = URLComponents(string: "https://itunes.apple.com/lookup")!
        var items = [URLQueryItem(name: "country", value: country.lowercased())]

        switch identifier {
        case .trackID(let id):
            items.append(URLQueryItem(name: "id", value: String(id)))
        case .bundleID(let bundle):
            items.append(URLQueryItem(name: "bundleId", value: bundle))
        case .url(let url, let trackID):
            if let trackID {
                items.append(URLQueryItem(name: "id", value: String(trackID)))
            } else {
                guard url.path.contains("/app/"),
                      let last = url.path.split(separator: "/").last else {
                    throw appFailure("That link does not contain an App Store app id.")
                }
                items.append(URLQueryItem(name: "id", value: String(last)))
            }
        }

        components.queryItems = items

        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw appFailure("iTunes lookup failed (HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)).")
        }

        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = root["results"] as? [[String: Any]] else {
            throw appFailure("iTunes lookup returned an unreadable response.")
        }

        guard let first = results.first else {
            throw appFailure("No App Store result for \(identifier.display) in the \(country.uppercased()) storefront.")
        }

        return AppStoreApp(
            trackID: (first["trackId"] as? NSNumber)?.int64Value ?? 0,
            bundleID: (first["bundleId"] as? String) ?? "",
            name: (first["trackName"] as? String) ?? (first["bundleId"] as? String) ?? "Unknown",
            seller: (first["sellerName"] as? String) ?? (first["artistName"] as? String) ?? "",
            version: (first["version"] as? String) ?? "?",
            price: (first["price"] as? NSNumber)?.doubleValue ?? 0,
            minimumOS: (first["minimumOsVersion"] as? String) ?? "?",
            artworkURL: (first["artworkUrl100"] as? String).flatMap(URL.init(string:)),
            storeURL: (first["trackViewUrl"] as? String).flatMap(URL.init(string:)),
            fileSizeBytes: (first["fileSizeBytes"] as? NSNumber)?.int64Value
                ?? (first["fileSizeBytes"] as? String).flatMap { Int64($0) }
        )
    }
}
