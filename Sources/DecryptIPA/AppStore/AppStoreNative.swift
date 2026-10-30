import Foundation

enum SignInOutcome {
    case signedIn(AppStoreAccount)
    case challenge(TwoFactorChallenge)
}

/// Native App Store authentication (`auth/v1/native/fast`), used when an
/// anisette provider is configured. It is the only path that can ask Apple to
/// text a *specific* trusted number, because it hands back an `appleauth`
/// session (`X-Apple-ID-Session-Id` + `scnt`) when 2FA is required.
extension AppStoreClient {
    static let nativeAuthURL = "https://auth.itunes.apple.com/auth/v1/native/fast"

    /// Tries every sign-in shape this app can produce, in order of strength, and
    /// reports the collected failures when all of them are refused.
    ///
    /// Apple now answers HTTP 403 with an empty body to unsigned authenticate
    /// requests, so "did it fail because of the password?" is no longer a safe
    /// assumption — the error text says which stage refused.
    func beginSignIn(
        email: String,
        password: String,
        country: String,
        anisette: AnisetteHeaders?,
        widgetKey: String
    ) async throws -> SignInOutcome {
        var notes: [String] = []
        var lastStatus = 403

        // 1. Native auth, when a provider can attest the device.
        if let anisette {
            do {
                return try await nativeSignInWithFallback(
                    email: email,
                    password: password,
                    country: country,
                    anisette: anisette,
                    widgetKey: widgetKey
                )
            } catch let error as AppStoreError {
                if case .rateLimited = error { throw error }
                lastStatus = error.statusCode ?? lastStatus
                lastNativeFailure = Self.summary(of: error)
                notes.append("Native auth · " + Self.summary(of: error))
            } catch {
                notes.append("Native auth · " + String(describing: error))
            }
        }

        // 2. Classic MZFinance, with anisette headers when we have them.
        do {
            let account = try await signIn(
                email: email,
                password: password,
                authCode: "",
                country: country,
                anisette: anisette
            )
            return .signedIn(account)
        } catch AppStoreError.authCodeRequired {
            return .challenge(Self.legacyChallenge(email: email))
        } catch let error as AppStoreError {
            lastStatus = error.statusCode ?? lastStatus
            if case .rateLimited = error { throw error }
            notes.append("Classic sign-in · " + Self.summary(of: error))
        } catch {
            notes.append("legacy: \(error)")
        }

        // 3. Native auth with local identity headers only. Some accounts and
        //    regions still accept it, and it costs one request to find out.
        if anisette == nil {
            do {
                let outcome = try await nativeSignIn(
                    email: email,
                    password: password,
                    country: country,
                    anisette: AnisetteHeaders.local(guid: guid),
                    widgetKey: widgetKey
                )
                notes.append("native (unattested): accepted")
                return outcome
            } catch let error as AppStoreError {
                lastStatus = error.statusCode ?? lastStatus
                notes.append("Unattested native auth · " + Self.summary(of: error))
            } catch {
                notes.append("Unattested native auth · " + String(describing: error))
            }
        }

        throw AppStoreError.blocked(lastStatus, notes.joined(separator: "\n"))
    }

    /// One line per attempt: Apple's status plus the first line of its body, so
    /// the panel stays readable instead of repeating the full explanation.
    static func summary(of error: AppStoreError) -> String {
        switch error {
        case .blocked(let status, let detail):
            let first = detail.split(separator: "\n").first.map(String.init) ?? ""
            let trimmed = first.trimmingCharacters(in: .whitespaces)
            let body = trimmed.isEmpty ? "no body" : String(trimmed.prefix(90))
            return "HTTP " + String(status) + " · " + body
        case .rateLimited(let status):
            return "HTTP " + String(status) + " · rate limited"
        case .signIn(let message):
            return "failed · " + String(message.prefix(120))
        default:
            return error.errorDescription ?? "failed"
        }
    }

    /// Apple serves the same native-auth path from two hosts. The primary one
    /// answers 400 to shapes we can build; the second host is worth exactly one
    /// attempt, and never after a 429 (that would deepen the rate limit).
    func nativeSignInWithFallback(
        email: String,
        password: String,
        country: String,
        anisette: AnisetteHeaders,
        widgetKey: String
    ) async throws -> SignInOutcome {
        do {
            return try await nativeSignIn(
                email: email,
                password: password,
                country: country,
                anisette: anisette,
                widgetKey: widgetKey
            )
        } catch let error as AppStoreError {
            switch error {
            case .rateLimited, .signIn:
                throw error
            default:
                Diagnostics.breadcrumb("native auth primary host refused; trying buy.itunes.apple.com")
                return try await nativeSignIn(
                    email: email,
                    password: password,
                    country: country,
                    anisette: anisette,
                    widgetKey: widgetKey,
                    endpoint: "https://buy.itunes.apple.com/auth/v1/native/fast"
                )
            }
        }
    }

    static func legacyChallenge(email: String) -> TwoFactorChallenge {
        TwoFactorChallenge(
            mode: .legacy,
            email: email,
            sessionID: nil,
            scnt: nil,
            options: [.device],
            codeLength: 6,
            note: "Apple requires two-factor authentication. A 6-digit code was sent to the trusted phone number and devices on this account — enter it below."
        )
    }

    func nativeSignIn(
        email: String,
        password: String,
        country: String,
        anisette: AnisetteHeaders,
        widgetKey: String,
        endpoint: String = AppStoreClient.nativeAuthURL
    ) async throws -> SignInOutcome {
        guard let authURL = URL(string: endpoint) else {
            throw AppStoreError.signIn("Bad native auth URL.")
        }
        var request = URLRequest(url: authURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue(AnisetteProvider.userAgent, forHTTPHeaderField: "User-Agent")
        anisette.apply(to: &request)
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "appleId": email,
            "password": password,
            "attempt": "1",
            "createSession": "true",
            "guid": guid,
            "rmp": "0",
            "why": "signIn"
        ])

        let (data, response) = try await perform(request)
        let json = TwoFactorParsing.jsonDictionary(data)
        let headers = Self.headerDictionary(response)

        let failureType = TwoFactorParsing.stringValue(json["failureType"]) ?? ""
        let message = TwoFactorParsing.stringValue(json["customerMessage"]) ?? ""

        // 2FA required: Apple returns a session and (usually) the trusted phone
        // numbers we can pick from.
        if response.statusCode == 401 || response.statusCode == 403 || !failureType.isEmpty || TwoFactorParsing.isTwoFactor(json) {
            if TwoFactorParsing.isTwoFactor(json) || headers["X-Apple-ID-Session-Id"] != nil {
                var challenge = TwoFactorParsing.challenge(
                    json: json,
                    headers: headers,
                    email: email,
                    mode: .session,
                    note: ""
                )

                if let sessionID = challenge.sessionID, let scnt = challenge.scnt {
                    let client = AppleIDTwoFactor(
                        anisette: anisette,
                        widgetKey: widgetKey,
                        clientID: Self.widgetClientID
                    )
                    if let richer = try? await client.sessionState(email: email, sessionID: sessionID, scnt: scnt),
                       !richer.options.isEmpty {
                        challenge = TwoFactorChallenge(
                            mode: .session,
                            email: email,
                            sessionID: sessionID,
                            scnt: scnt,
                            options: richer.options,
                            codeLength: richer.codeLength,
                            note: challenge.note
                        )
                    }
                }

                return .challenge(challenge)
            }

            throw AppStoreError.signIn(message.isEmpty
                ? "Apple rejected the native sign-in (HTTP \(response.statusCode)): \(AppStorePlist.snippet(data))"
                : message)
        }

        if response.statusCode == 429 {
            throw AppStoreError.rateLimited(response.statusCode)
        }

        guard response.statusCode == 200 else {
            if response.statusCode == 401 || response.statusCode == 403 {
                throw AppStoreError.blocked(response.statusCode, AppStorePlist.snippet(data))
            }
            throw AppStoreError.signIn("Native sign-in failed (HTTP \(response.statusCode)): \(AppStorePlist.snippet(data))")
        }

        let dsid = TwoFactorParsing.stringValue(json["dsPersonId"]) ?? ""
        let token = TwoFactorParsing.stringValue(json["passwordToken"]) ?? ""
        guard !dsid.isEmpty, !token.isEmpty else {
            throw AppStoreError.signIn("Apple answered without a token — the account may need to accept new terms in the App Store.")
        }

        let accountInfo = json["accountInfo"] as? [String: Any] ?? [:]
        let address = accountInfo["address"] as? [String: Any] ?? [:]

        let account = AppStoreAccount(
            email: TwoFactorParsing.stringValue(accountInfo["appleId"]) ?? email,
            passwordToken: token,
            directoryServicesID: dsid,
            storeFront: headers["X-Set-Apple-Store-Front"]
                ?? TwoFactorParsing.stringValue(json["storefront"])
                ?? "",
            pod: headers["pod"] ?? "",
            name: "\(TwoFactorParsing.stringValue(address["firstName"]) ?? "") \(TwoFactorParsing.stringValue(address["lastName"]) ?? "")"
                .trimmingCharacters(in: .whitespaces),
            country: country.lowercased()
        )

        guard !account.storeFront.isEmpty else {
            throw AppStoreError.signIn("Signed in, but Apple returned no storefront header.")
        }

        adopt(account)
        return .signedIn(account)
    }

    /// Completes a session-mode challenge: verify the code against the chosen
    /// delivery option, then re-run native auth to collect the token.
    func completeSessionChallenge(
        _ challenge: TwoFactorChallenge,
        option: TwoFactorOption,
        code: String,
        password: String,
        anisette: AnisetteHeaders,
        widgetKey: String
    ) async throws -> AppStoreAccount {
        guard let sessionID = challenge.sessionID, let scnt = challenge.scnt else {
            throw AppStoreError.signIn("Apple did not return a 2FA session identifier; sign in again.")
        }

        let client = AppleIDTwoFactor(anisette: anisette, widgetKey: widgetKey, clientID: Self.widgetClientID)

        switch option.kind {
        case .sms:
            guard let phoneID = option.phoneID else {
                throw AppStoreError.signIn("Apple did not give an id for that phone number; pick another option.")
            }
            try await client.verifyText(code: code, phoneID: phoneID, sessionID: sessionID, scnt: scnt)
        case .trustedDevice:
            try await client.verifyTrustedDevice(code: code, sessionID: sessionID, scnt: scnt)
        }

        // The 2FA cookie is now in the shared cookie store; native auth should
        // return the token instead of another challenge.
        let outcome = try await nativeSignIn(
            email: challenge.email,
            password: password,
            country: account?.country ?? "us",
            anisette: anisette,
            widgetKey: widgetKey
        )

        switch outcome {
        case .signedIn(let account):
            return account
        case .challenge:
            throw AppStoreError.signIn("Apple asked for a code again after verification. Try signing in once more.")
        }
    }

    /// Asks Apple to deliver a code for the selected option.
    func requestCode(
        _ challenge: TwoFactorChallenge,
        option: TwoFactorOption,
        anisette: AnisetteHeaders,
        widgetKey: String
    ) async throws {
        guard challenge.mode == .session, let sessionID = challenge.sessionID, let scnt = challenge.scnt else {
            throw AppStoreError.signIn("This sign-in needs a code typed from the device Apple notified.")
        }

        let client = AppleIDTwoFactor(anisette: anisette, widgetKey: widgetKey, clientID: Self.widgetClientID)

        switch option.kind {
        case .sms:
            guard let phoneID = option.phoneID else {
                throw AppStoreError.signIn("Apple did not give an id for that phone number.")
            }
            try await client.sendText(to: phoneID, sessionID: sessionID, scnt: scnt)
        case .trustedDevice:
            try await client.promptTrustedDevice(sessionID: sessionID, scnt: scnt)
        }
    }

    static func headerDictionary(_ response: HTTPURLResponse) -> [String: String] {
        var headers: [String: String] = [:]
        for (key, value) in response.allHeaderFields {
            headers["\(key)"] = "\(value)"
        }
        return headers
    }

    static let widgetClientID = ""
}

