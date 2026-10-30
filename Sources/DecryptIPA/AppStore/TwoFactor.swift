import Foundation

// MARK: - Challenge model

struct TwoFactorOption: Identifiable, Hashable {
    enum Kind: String, Codable {
        case sms
        case trustedDevice
    }

    let id: String
    let kind: Kind
    let title: String
    let detail: String
    let phoneID: Int?

    static func phone(id: Int, number: String, pushMode: String?) -> TwoFactorOption {
        TwoFactorOption(
            id: "phone:\(id)",
            kind: .sms,
            title: number,
            detail: pushMode == "sms" ? "Text message" : "Verification code",
            phoneID: id
        )
    }

    static let device = TwoFactorOption(
        id: "device",
        kind: .trustedDevice,
        title: "Trusted device",
        detail: "Show the code on a device signed in to this Apple ID",
        phoneID: nil
    )
}

enum TwoFactorMode: String {
    /// Session-based (idmsa): the app can ask Apple to text a specific number and
    /// verify the code against that number.
    case session
    /// Legacy MZFinance: Apple texts the trusted phone, and the code is submitted
    /// together with the password.
    case legacy
}

struct TwoFactorChallenge: Identifiable {
    let id = UUID()
    let mode: TwoFactorMode
    let email: String
    let sessionID: String?
    let scnt: String?
    let options: [TwoFactorOption]
    let codeLength: Int
    let note: String

    var preferredOption: TwoFactorOption? {
        options.first(where: { $0.kind == .sms }) ?? options.first
    }

    var supportsNumberChoice: Bool {
        mode == .session && options.contains { $0.kind == .sms }
    }
}

// MARK: - Response parsing

enum TwoFactorParsing {
    /// Builds a challenge from `GET /appleauth/auth` (or from the JSON body that
    /// accompanies a 2FA refusal). Apple is not consistent about nesting, so the
    /// lookup accepts the top level plus a few known wrappers.
    static func challenge(
        json: [String: Any],
        headers: [String: String],
        email: String,
        mode: TwoFactorMode,
        note: String
    ) -> TwoFactorChallenge {
        let payload = unwrap(json)

        var options: [TwoFactorOption] = []

        for entry in phoneList(payload["trustedPhoneNumbers"]) {
            let phoneID = intValue(entry["id"])
            let number = stringValue(entry["numberWithDialCode"])
                ?? stringValue(entry["obfuscatedNumber"])
                ?? stringValue(entry["number"])
                ?? "Trusted phone number"
            let pushMode = stringValue(entry["pushMode"])

            if let phoneID {
                options.append(.phone(id: phoneID, number: number, pushMode: pushMode))
            } else {
                options.append(TwoFactorOption(
                    id: "phone:\(number)",
                    kind: .sms,
                    title: number,
                    detail: pushMode == "sms" ? "Text message" : "Verification code",
                    phoneID: nil
                ))
            }
        }

        let hasTrustedDevices = intValue(payload["noTrustedDevices"]) != 1
        if hasTrustedDevices || options.isEmpty {
            options.append(.device)
        }

        let securityCode = payload["securityCode"] as? [String: Any]
        let codeLength = intValue(securityCode?["length"]) ?? 6

        let authType = stringValue(payload["authType"]) ?? stringValue(payload["failureType"]) ?? ""

        return TwoFactorChallenge(
            mode: mode,
            email: email,
            sessionID: headers["X-Apple-ID-Session-Id"] ?? headers["x-apple-id-session-id"],
            scnt: headers["scnt"] ?? headers["X-Apple-Session-Id"],
            options: options,
            codeLength: codeLength,
            note: note.isEmpty ? "Apple requires two-factor authentication for \(email). authType: \(authType)" : note
        )
    }

    static func isTwoFactor(_ json: [String: Any]) -> Bool {
        let payload = unwrap(json)
        let authType = (stringValue(payload["authType"]) ?? "").lowercased()
        let failure = (stringValue(payload["failureType"]) ?? "").lowercased()
        let message = (stringValue(payload["customerMessage"]) ?? "").lowercased()

        if authType.contains("hsa2") || authType.contains("twostep") || authType.contains("secondaryauth") {
            return true
        }
        if failure == "hsa2" { return true }
        if message.contains("two-factor") || message.contains("two factor") || message.contains("verification code") {
            return true
        }
        return payload["trustedPhoneNumbers"] != nil
    }

    private static func unwrap(_ json: [String: Any]) -> [String: Any] {
        for key in ["authentication", "auth", "data", "result"] {
            if let nested = json[key] as? [String: Any] { return nested }
        }
        return json
    }

    private static func phoneList(_ raw: Any?) -> [[String: Any]] {
        if let list = raw as? [[String: Any]] { return list }
        if let dictionary = raw as? [String: Any] {
            return dictionary.values.compactMap { $0 as? [String: Any] }
        }
        return []
    }

    static func jsonDictionary(_ data: Data) -> [String: Any] {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any] else { return [:] }
        return dictionary
    }

    static func stringValue(_ raw: Any?) -> String? {
        switch raw {
        case let string as String: return string
        case let number as NSNumber: return number.stringValue
        default: return nil
        }
    }

    static func intValue(_ raw: Any?) -> Int? {
        switch raw {
        case let number as NSNumber: return number.intValue
        case let string as String: return Int(string)
        default: return nil
        }
    }
}

// MARK: - Session 2FA client (idmsa)

/// Talks to Apple's `appleauth` endpoints, which own the "which number should
/// the text go to" part of 2FA. The session id + `scnt` come from the refused
/// sign-in attempt; everything here needs anisette attestation to be accepted.
struct AppleIDTwoFactor {
    static let base = "https://idmsa.apple.com/appleauth/auth"

    let anisette: AnisetteHeaders
    /// Some Apple endpoints also want a widget key; left empty unless the user
    /// sets one in Advanced settings.
    let widgetKey: String
    let clientID: String

    struct Session {
        var headers: [String: String]
    }

    func sessionState(email: String, sessionID: String, scnt: String) async throws -> TwoFactorChallenge {
        guard let url = URL(string: Self.base) else { throw appFailure("Bad auth URL.") }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        applySession(to: &request, sessionID: sessionID, scnt: scnt)
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await send(request)
        guard let http = response, (200..<300).contains(http.statusCode) else {
            throw appFailure("Apple rejected the 2FA session lookup (HTTP \(response?.statusCode ?? -1)): \(snippet(data))")
        }

        return TwoFactorParsing.challenge(
            json: TwoFactorParsing.jsonDictionary(data),
            headers: headerDictionary(http),
            email: email,
            mode: .session,
            note: ""
        )
    }

    /// `PUT /auth/verify/phone {"phoneNumber":{"id":N},"mode":"sms"}` — Apple
    /// texts the code to that number.
    func sendText(to phoneID: Int, sessionID: String, scnt: String) async throws {
        guard let url = URL(string: Self.base + "/verify/phone") else { throw appFailure("Bad auth URL.") }
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        applySession(to: &request, sessionID: sessionID, scnt: scnt)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "phoneNumber": ["id": phoneID],
            "mode": "sms"
        ])

        let (data, response) = try await send(request)
        guard let http = response, (200..<300).contains(http.statusCode) else {
            throw appFailure("Apple refused to send a text to that number (HTTP \(response?.statusCode ?? -1)): \(snippet(data))")
        }
    }

    /// `PUT /auth/verify/trusteddevice` — ask Apple to push the prompt to the
    /// trusted devices.
    func promptTrustedDevice(sessionID: String, scnt: String) async throws {
        guard let url = URL(string: Self.base + "/verify/trusteddevice") else { throw appFailure("Bad auth URL.") }
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        applySession(to: &request, sessionID: sessionID, scnt: scnt)
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await send(request)
        guard let http = response, (200..<300).contains(http.statusCode) else {
            throw appFailure("Apple refused to notify the trusted devices (HTTP \(response?.statusCode ?? -1)): \(snippet(data))")
        }
    }

    /// `POST /auth/verify/phone/securitycode` — verify an SMS code.
    func verifyText(code: String, phoneID: Int, sessionID: String, scnt: String) async throws {
        guard let url = URL(string: Self.base + "/verify/phone/securitycode") else { throw appFailure("Bad auth URL.") }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        applySession(to: &request, sessionID: sessionID, scnt: scnt)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "securityCode": ["code": code],
            "phoneNumber": ["id": phoneID],
            "mode": "sms"
        ])

        let (data, response) = try await send(request)
        try validateVerification(data: data, response: response, method: "text message")
    }

    /// `POST /auth/verify/trusteddevice/securitycode`.
    func verifyTrustedDevice(code: String, sessionID: String, scnt: String) async throws {
        guard let url = URL(string: Self.base + "/verify/trusteddevice/securitycode") else { throw appFailure("Bad auth URL.") }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        applySession(to: &request, sessionID: sessionID, scnt: scnt)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "securityCode": ["code": code]
        ])

        let (data, response) = try await send(request)
        try validateVerification(data: data, response: response, method: "trusted device")
    }

    private func validateVerification(data: Data, response: HTTPURLResponse?, method: String) throws {
        guard let http = response else {
            throw appFailure("No response from Apple while verifying the \(method) code.")
        }

        let json = TwoFactorParsing.jsonDictionary(data)

        if (200..<300).contains(http.statusCode), !TwoFactorParsing.isTwoFactor(json) {
            return
        }

        // Apple answers with 400/409 and a service error when the code is wrong.
        let serviceErrors = (json["serviceErrors"] as? [[String: Any]]) ?? []
        let message = serviceErrors
            .compactMap { TwoFactorParsing.stringValue($0["message"]) }
            .first
            ?? TwoFactorParsing.stringValue(json["customerMessage"])
            ?? snippet(data)

        throw appFailure("Apple did not accept the \(method) code (HTTP \(http.statusCode)): \(message)")
    }

    private func applySession(to request: inout URLRequest, sessionID: String, scnt: String) {
        anisette.apply(to: &request)
        request.setValue(sessionID, forHTTPHeaderField: "X-Apple-ID-Session-Id")
        request.setValue(scnt, forHTTPHeaderField: "scnt")
        request.setValue("1", forHTTPHeaderField: "X-Apple-I-FD-Client-Info")
        if !widgetKey.isEmpty {
            request.setValue(widgetKey, forHTTPHeaderField: "X-Apple-Widget-Key")
        }
        if !clientID.isEmpty {
            request.setValue(clientID, forHTTPHeaderField: "X-Apple-OAuth-Client-Id")
            request.setValue("true", forHTTPHeaderField: "X-Apple-OAuth-Client-Type")
            request.setValue("true", forHTTPHeaderField: "X-Apple-OAuth-Require-Grant-Code")
            request.setValue("true", forHTTPHeaderField: "X-Apple-OAuth-Require-Password")
            request.setValue("true", forHTTPHeaderField: "X-Apple-OAuth-Require-2FA")
        }
        request.setValue("https://idmsa.apple.com", forHTTPHeaderField: "Origin")
        request.setValue("https://idmsa.apple.com", forHTTPHeaderField: "Referer")
        request.setValue(AnisetteProvider.userAgent, forHTTPHeaderField: "User-Agent")
    }

    private func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse?) {
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            return (data, response as? HTTPURLResponse)
        } catch {
            throw appFailure("Network error talking to Apple ID: \(error.localizedDescription)")
        }
    }

    private func headerDictionary(_ response: HTTPURLResponse) -> [String: String] {
        var headers: [String: String] = [:]
        for (key, value) in response.allHeaderFields {
            headers["\(key)"] = "\(value)"
        }
        return headers
    }

    private func snippet(_ data: Data) -> String {
        let text = String(data: data.prefix(400), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "<\(data.count) bytes>"
        return text.isEmpty ? "empty response" : text
    }
}

extension AnisetteProvider {
    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
}
