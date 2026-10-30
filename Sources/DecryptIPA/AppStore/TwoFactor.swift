import Foundation

// MARK: - Challenge model

struct TwoFactorOption: Identifiable, Hashable {
    enum Kind: String, Codable {
        case sms
        case voice
        case email
        case trustedDevice
    }

    let id: String
    let kind: Kind
    let title: String
    let detail: String
    let phoneID: Int?
    let emailID: Int?

    /// The `mode` Apple's `/verify/phone` expects for this option.
    var phoneMode: String {
        kind == .voice ? "voice" : "sms"
    }

    static func phone(id: Int, number: String, mode: Kind) -> TwoFactorOption {
        TwoFactorOption(
            id: mode.rawValue + ":phone:" + String(id),
            kind: mode,
            title: number,
            detail: mode == .voice ? "Voice call" : "Text message",
            phoneID: id,
            emailID: nil
        )
    }

    static func email(id: Int, address: String) -> TwoFactorOption {
        TwoFactorOption(
            id: "email:" + String(id),
            kind: .email,
            title: address,
            detail: "Email code",
            phoneID: nil,
            emailID: id
        )
    }

    static let device = TwoFactorOption(
        id: "device",
        kind: .trustedDevice,
        title: "Trusted device",
        detail: "Show the code on a device signed in to this Apple ID",
        phoneID: nil,
        emailID: nil
    )
}

enum TwoFactorMode: String {
    /// Session-based (idmsa): Apple hands back a session, so a delivery method
    /// can be chosen and the code verified against that exact destination.
    case session
    /// Legacy MZFinance: Apple texts the trusted phone and the code is submitted
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
        options.first(where: { $0.kind == .sms })
            ?? options.first(where: { $0.kind == .email })
            ?? options.first
    }

    var supportsNumberChoice: Bool {
        mode == .session && options.contains { $0.kind == .sms || $0.kind == .voice }
    }

    var offersEmail: Bool {
        options.contains { $0.kind == .email }
    }

    static func allCasesForMenu(_ options: [TwoFactorOption]) -> [TwoFactorOption.Kind] {
        let order: [TwoFactorOption.Kind] = [.sms, .voice, .email, .trustedDevice]
        return order.filter { kind in options.contains { $0.kind == kind } }
    }

    /// Group label used by the picker.
    static func groupTitle(for kind: TwoFactorOption.Kind) -> String {
        switch kind {
        case .sms: "Text message"
        case .voice: "Voice call"
        case .email: "Email code"
        case .trustedDevice: "Trusted device"
        }
    }
}

// MARK: - Response parsing

enum TwoFactorParsing {
    /// Builds a challenge from `GET /appleauth/auth` or from the JSON body that
    /// accompanies a 2FA refusal. Apple is inconsistent about nesting, so the
    /// top level plus a few known wrappers are accepted.
    ///
    /// Phone entries produce both a text and a call option: Apple's
    /// `/verify/phone` takes `mode: "sms" | "voice"`, and letting the user pick
    /// is the whole point of this screen.
    static func challenge(
        json: [String: Any],
        headers: [String: String],
        email: String,
        mode: TwoFactorMode,
        note: String
    ) -> TwoFactorChallenge {
        let payload = unwrap(json)

        var options: [TwoFactorOption] = []
        var seenPhones = Set<Int>()
        var seenEmails = Set<Int>()

        for entry in phoneList(payload["trustedPhoneNumbers"]) {
            guard let phoneID = intValue(entry["id"]), seenPhones.insert(phoneID).inserted else { continue }
            let number = stringValue(entry["numberWithDialCode"])
                ?? stringValue(entry["obfuscatedNumber"])
                ?? stringValue(entry["number"])
                ?? "Trusted phone number"
            let pushMode = (stringValue(entry["pushMode"]) ?? "sms").lowercased()

            if pushMode.contains("voice") {
                options.append(.phone(id: phoneID, number: number, mode: .voice))
            } else {
                options.append(.phone(id: phoneID, number: number, mode: .sms))
                options.append(.phone(id: phoneID, number: number, mode: .voice))
            }
        }

        for entry in phoneList(payload["trustedEmailAddresses"]) {
            guard let addressID = intValue(entry["id"]), seenEmails.insert(addressID).inserted else { continue }
            let address = stringValue(entry["email"])
                ?? stringValue(entry["obfuscatedEmail"])
                ?? stringValue(entry["hiddenEmail"])
                ?? "Trusted email address"
            options.append(.email(id: addressID, address: address))
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
            note: note.isEmpty ? "Apple requires two-factor authentication for " + email + " (authType: " + authType + ")." : note
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
        return payload["trustedPhoneNumbers"] != nil || payload["trustedEmailAddresses"] != nil
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

/// Talks to Apple's `appleauth` endpoints, which own delivery and verification
/// of two-factor codes. The session id + `scnt` come from the refused sign-in
/// attempt; everything here needs anisette attestation to be accepted.
struct AppleIDTwoFactor {
    static let base = "https://idmsa.apple.com/appleauth/auth"

    let anisette: AnisetteHeaders
    /// Some Apple endpoints also want a widget key; left empty unless the user
    /// sets one in Advanced settings.
    let widgetKey: String
    let clientID: String

    func sessionState(email: String, sessionID: String, scnt: String) async throws -> TwoFactorChallenge {
        guard let url = URL(string: Self.base) else { throw appFailure("Bad auth URL.") }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        applySession(to: &request, sessionID: sessionID, scnt: scnt)
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await send(request)
        guard let http = response, (200..<300).contains(http.statusCode) else {
            throw appFailure("Apple rejected the 2FA session lookup (HTTP " + String(response?.statusCode ?? -1) + "): " + snippet(data))
        }

        return TwoFactorParsing.challenge(
            json: TwoFactorParsing.jsonDictionary(data),
            headers: headerDictionary(http),
            email: email,
            mode: .session,
            note: ""
        )
    }

    /// Delivers a code for the chosen option.
    ///  * phone → `PUT /verify/phone` with mode `sms` or `voice`
    ///  * email → `PUT /verify/email`
    ///  * device → `PUT /verify/trusteddevice`
    func requestCode(for option: TwoFactorOption, sessionID: String, scnt: String) async throws {
        switch option.kind {
        case .sms, .voice:
            guard let phoneID = option.phoneID else { throw appFailure("Apple did not return an id for that phone number.") }
            try await verifyPhone(phoneID: phoneID, mode: option.phoneMode, sessionID: sessionID, scnt: scnt)

        case .email:
            guard let emailID = option.emailID else { throw appFailure("Apple did not return an id for that email address.") }
            try await verifyEmail(emailID: emailID, sessionID: sessionID, scnt: scnt)

        case .trustedDevice:
            try await promptTrustedDevice(sessionID: sessionID, scnt: scnt)
        }
    }

    /// Verifies a code against the chosen destination.
    func verify(code: String, option: TwoFactorOption, sessionID: String, scnt: String) async throws {
        switch option.kind {
        case .sms, .voice:
            guard let phoneID = option.phoneID else { throw appFailure("Apple did not return an id for that phone number.") }
            try await verifyPhoneCode(code: code, phoneID: phoneID, mode: option.phoneMode, sessionID: sessionID, scnt: scnt)

        case .email:
            guard let emailID = option.emailID else { throw appFailure("Apple did not return an id for that email address.") }
            try await verifyEmailCode(code: code, emailID: emailID, sessionID: sessionID, scnt: scnt)

        case .trustedDevice:
            try await verifyTrustedDeviceCode(code: code, sessionID: sessionID, scnt: scnt)
        }
    }

    // MARK: Phone

    func verifyPhone(phoneID: Int, mode: String, sessionID: String, scnt: String) async throws {
        guard let url = URL(string: Self.base + "/verify/phone") else { throw appFailure("Bad auth URL.") }
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        applySession(to: &request, sessionID: sessionID, scnt: scnt)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "phoneNumber": ["id": phoneID],
            "mode": mode
        ])

        let (data, response) = try await send(request)
        guard let http = response, (200..<300).contains(http.statusCode) else {
            let channel = mode == "voice" ? "call" : "text"
            throw appFailure("Apple refused to send a " + channel + " to that number (HTTP " + String(response?.statusCode ?? -1) + "): " + snippet(data))
        }
    }

    func verifyPhoneCode(code: String, phoneID: Int, mode: String, sessionID: String, scnt: String) async throws {
        guard let url = URL(string: Self.base + "/verify/phone/securitycode") else { throw appFailure("Bad auth URL.") }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        applySession(to: &request, sessionID: sessionID, scnt: scnt)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "securityCode": ["code": code],
            "phoneNumber": ["id": phoneID],
            "mode": mode
        ])

        let (data, response) = try await send(request)
        try validateVerification(data: data, response: response, method: mode == "voice" ? "voice call" : "text message")
    }

    // MARK: Email

    func verifyEmail(emailID: Int, sessionID: String, scnt: String) async throws {
        guard let url = URL(string: Self.base + "/verify/email") else { throw appFailure("Bad auth URL.") }
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        applySession(to: &request, sessionID: sessionID, scnt: scnt)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["email": ["id": emailID]])

        let (data, response) = try await send(request)
        guard let http = response, (200..<300).contains(http.statusCode) else {
            throw appFailure("Apple refused to email that address (HTTP " + String(response?.statusCode ?? -1) + "): " + snippet(data))
        }
    }

    func verifyEmailCode(code: String, emailID: Int, sessionID: String, scnt: String) async throws {
        guard let url = URL(string: Self.base + "/verify/email/securitycode") else { throw appFailure("Bad auth URL.") }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        applySession(to: &request, sessionID: sessionID, scnt: scnt)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "securityCode": ["code": code],
            "email": ["id": emailID]
        ])

        let (data, response) = try await send(request)
        try validateVerification(data: data, response: response, method: "email")
    }

    // MARK: Trusted device

    func promptTrustedDevice(sessionID: String, scnt: String) async throws {
        guard let url = URL(string: Self.base + "/verify/trusteddevice") else { throw appFailure("Bad auth URL.") }
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        applySession(to: &request, sessionID: sessionID, scnt: scnt)
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await send(request)
        guard let http = response, (200..<300).contains(http.statusCode) else {
            throw appFailure("Apple refused to notify the trusted devices (HTTP " + String(response?.statusCode ?? -1) + "): " + snippet(data))
        }
    }

    func verifyTrustedDeviceCode(code: String, sessionID: String, scnt: String) async throws {
        guard let url = URL(string: Self.base + "/verify/trusteddevice/securitycode") else { throw appFailure("Bad auth URL.") }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        applySession(to: &request, sessionID: sessionID, scnt: scnt)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["securityCode": ["code": code]])

        let (data, response) = try await send(request)
        try validateVerification(data: data, response: response, method: "trusted device")
    }

    // MARK: Plumbing

    private func validateVerification(data: Data, response: HTTPURLResponse?, method: String) throws {
        guard let http = response else {
            throw appFailure("No response from Apple while verifying the " + method + " code.")
        }

        let json = TwoFactorParsing.jsonDictionary(data)
        if (200..<300).contains(http.statusCode), !TwoFactorParsing.isTwoFactor(json) { return }

        let serviceErrors = (json["serviceErrors"] as? [[String: Any]]) ?? []
        let message = serviceErrors
            .compactMap { TwoFactorParsing.stringValue($0["message"]) }
            .first
            ?? TwoFactorParsing.stringValue(json["customerMessage"])
            ?? snippet(data)

        throw appFailure("Apple did not accept the " + method + " code (HTTP " + String(http.statusCode) + "): " + message)
    }

    private func applySession(to request: inout URLRequest, sessionID: String, scnt: String) {
        anisette.apply(to: &request)
        request.setValue(sessionID, forHTTPHeaderField: "X-Apple-ID-Session-Id")
        request.setValue(scnt, forHTTPHeaderField: "scnt")
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
            throw appFailure("Network error talking to Apple ID: " + error.localizedDescription)
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
