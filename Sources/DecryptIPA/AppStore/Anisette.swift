import Foundation
import RemoteAnisette

/// Headers Apple's modern endpoints (auth/v1/native/fast, idmsa) require on top
/// of the classic Configurator ones. The `X-Apple-I-MD*` family is device
/// attestation and can only come from an anisette provider — either a server the
/// user runs, or (on a jailbroken device) a native implementation. Without it
/// Apple answers 401/-20101, which is exactly why the legacy MZFinance path is
/// kept as the default.
struct AnisetteHeaders {
    var values: [String: String]

    func apply(to request: inout URLRequest) {
        for (key, value) in values {
            request.setValue(value, forHTTPHeaderField: key)
        }
    }

    /// Headers that need no attestation: a stable per-install identity plus the
    /// clock/timezone Apple validates every request against.
    static func local(guid: String, locale: String = "en_US", timeZone: String = TimeZone.current.identifier) -> AnisetteHeaders {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(identifier: "UTC")

        return AnisetteHeaders(values: [
            "X-Apple-I-Client-Time": formatter.string(from: Date()),
            "X-Apple-I-TimeZone": timeZone,
            "X-Apple-Locale": locale,
            "X-Mme-Device-Id": guid,
            "X-Apple-I-SRL-NO": "0",
            "X-Apple-I-MD-RINFO": "17106176"
        ])
    }

    /// Validates and normalizes headers from RemoteAnisette or a user server.
    /// RemoteAnisette emits `X-Apple-Client-Time`; native App Store auth may also
    /// require `X-Apple-I-Client-Time`, so provide both aliases when available.
    static func validated(_ source: [String: String]) throws -> AnisetteHeaders {
        var values = source
        if values["X-Apple-I-Client-Time"] == nil,
           let clientTime = values["X-Apple-Client-Time"] {
            values["X-Apple-I-Client-Time"] = clientTime
        }
        guard values["X-Apple-I-MD"]?.isEmpty == false,
              values["X-Apple-I-MD-M"]?.isEmpty == false else {
            throw appFailure("Anisette headers are missing X-Apple-I-MD or X-Apple-I-MD-M.")
        }
        return AnisetteHeaders(values: values)
    }

    /// Parses the JSON an anisette server returns. Both shapes in the wild are
    /// accepted: a flat header dictionary, and a wrapper object that carries the
    /// headers under `result`/`data`.
    static func fromServer(_ data: Data) throws -> AnisetteHeaders {
        guard let root = try? JSONSerialization.jsonObject(with: data) else {
            throw appFailure("The anisette server returned something that is not JSON.")
        }

        var dictionary: [String: Any] = [:]
        if let flat = root as? [String: Any] {
            dictionary = flat
            for wrapper in ["result", "data"] {
                if let nested = flat[wrapper] as? [String: Any] {
                    dictionary.merge(nested) { current, _ in current }
                }
            }
        }

        var values: [String: String] = [:]
        let known = [
            "X-Apple-I-MD", "X-Apple-I-MD-M", "X-Apple-I-MD-LU",
            "X-Apple-I-MD-RINFO", "X-Mme-Device-Id", "X-Apple-I-SRL-NO",
            "X-Apple-I-Client-Time", "X-Apple-I-TimeZone", "X-Apple-Locale"
        ]

        for key in known {
            guard let raw = dictionary[key] else { continue }
            if let string = raw as? String {
                values[key] = string
            } else if let number = raw as? NSNumber {
                values[key] = number.stringValue
            } else {
                values[key] = "\(raw)"
            }
        }

        guard values["X-Apple-I-MD"] != nil, values["X-Apple-I-MD-M"] != nil else {
            throw appFailure("The anisette server response is missing X-Apple-I-MD / X-Apple-I-MD-M.")
        }

        return try AnisetteHeaders.validated(values)
    }
}

/// Fetches anisette data from a user-configured HTTP endpoint.
///
/// Compatible with `anisette-v3-server` and the SideStore/AltStore servers:
/// `GET <url>` returns a JSON object whose keys are the `X-Apple-I-*` headers.
/// An optional basic-auth credential is supported for private deployments.
struct AnisetteProvider {
    let endpoint: String
    let username: String
    let password: String
    let guid: String

    var isConfigured: Bool { !endpoint.trimmingCharacters(in: .whitespaces).isEmpty }

    func headers() async throws -> AnisetteHeaders {
        guard isConfigured, let url = URL(string: endpoint.trimmingCharacters(in: .whitespaces)) else {
            return .local(guid: guid)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 20

        if !username.isEmpty {
            let token = Data("\(username):\(password)".utf8).base64EncodedString()
            request.setValue("Basic \(token)", forHTTPHeaderField: "Authorization")
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw appFailure("The anisette server answered HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1).")
            }
            return try AnisetteHeaders.fromServer(data)
        } catch let error as AppError {
            throw error
        } catch {
            throw appFailure("Anisette request failed: \(error.localizedDescription)")
        }
    }
}

/// HTTPS Anisette-v3 endpoints published by the SideStore anisette-servers
/// project. Keep the list explicit, reviewed and HTTPS-only; do not fetch a
/// provider list at runtime and trust arbitrary server-supplied URLs.
struct AnisetteServerOption: Identifiable, Hashable {
    let name: String
    let url: String
    var id: String { url }

    static let publicOptions: [AnisetteServerOption] = [
        .init(name: "SideStore", url: "https://ani.sidestore.io"),
        .init(name: "SideStore · app", url: "https://ani.sidestore.app"),
        .init(name: "SideStore · zip", url: "https://ani.sidestore.zip"),
        .init(name: "SideStore · xyz", url: "https://ani.846969.xyz"),
        .init(name: "SideStore · new", url: "https://new.ani.sidestore.io"),
        .init(name: "jkcoxson · macOS", url: "https://mac-ani.jkcoxson.com"),
        .init(name: "nythepegasus", url: "https://ani.npeg.us"),
        .init(name: "WE. Studio", url: "https://anisette.wedotstud.io"),
        .init(name: "SteX", url: "https://ani.xu30.top"),
        .init(name: "owoellen", url: "https://ani.owoellen.rocks"),
        .init(name: "iDeviceHacked", url: "https://ani.idevicehacked.com"),
        .init(name: "neoarz", url: "https://ani.neoarz.com"),
        .init(name: "pythonplayer123", url: "https://ani3server.fly.dev"),
        .init(name: "Jayden", url: "https://ani.jaydenha.uk"),
        .init(name: "crystall1ne", url: "https://anisette.crystall1ne.dev"),
        .init(name: "ethxn", url: "https://omni.ethxn.xyz"),
        .init(name: "koremi", url: "https://ani.sjwon0368.dpdns.org"),
        .init(name: "uwucloud", url: "https://ani.uwucloud.fun"),
        .init(name: "Lill q", url: "https://anisette.lillq.me")
    ]

    static func isPublic(_ url: String) -> Bool {
        publicOptions.contains(where: { $0.url == url })
    }
}
