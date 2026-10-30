import Foundation

// Self-checks for the logic that cannot be exercised without a device:
// Mach-O cryptid parsing (LC_ENCRYPTION_INFO / LC_ENCRYPTION_INFO_64, thin and
// fat), the helper's @evt parser, and the version comparator used to decide
// between "already installed" and "install this IPA".

var failures = 0

func check(_ condition: Bool, _ label: String) {
    if condition {
        print("  ok   \(label)")
    } else {
        print("  FAIL \(label)")
        failures += 1
    }
}

// MARK: - Mach-O fixtures

func be32(_ value: UInt32) -> [UInt8] {
    [UInt8(value >> 24 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)]
}

func le32(_ value: UInt32) -> [UInt8] {
    Array(be32(value).reversed())
}

func le64(_ value: UInt64) -> [UInt8] {
    (0..<8).map { UInt8((value >> (8 * UInt64($0))) & 0xFF) }
}

/// Builds a thin 64-bit Mach-O with a single LC_ENCRYPTION_INFO_64 command.
func thin64(cryptid: UInt32, extraCommands: [(UInt32, [UInt8])] = []) -> Data {
    var body: [UInt8] = []
    var commandCount: UInt32 = 0

    for (kind, payload) in extraCommands {
        let size = UInt32(8 + payload.count)
        body += le32(kind) + le32(size) + payload
        commandCount += 1
    }

    body += le32(0x2C) + le32(24) + le32(0x4000) + le32(0x8000) + le32(cryptid) + le32(0)
    commandCount += 1

    var header: [UInt8] = []
    header += le32(0xFEEDFACF)      // magic
    header += le32(0x0100000C)      // cputype arm64
    header += le32(0x00000002)      // cpusubtype
    header += le32(0x00000006)      // filetype MH_DYLIB
    header += le32(commandCount)
    header += le32(UInt32(body.count))
    header += le32(0x00200085)      // flags
    header += le32(0)               // reserved

    let total = UInt32(header.count + body.count)
    var padded = header + body
    while padded.count < 512 { padded.append(0) }
    check(total <= 512, "fixture header size fits")
    return Data(padded)
}

/// Builds a 32-bit (LE) Mach-O with LC_ENCRYPTION_INFO.
func thin32(cryptid: UInt32) -> Data {
    var body: [UInt8] = []
    body += le32(0x21) + le32(20) + le32(0x4000) + le32(0x8000) + le32(cryptid)

    var header: [UInt8] = []
    header += le32(0xFEEDFACE)
    header += le32(0x0000000C)
    header += le32(0x00000000)
    header += le32(0x00000002)
    header += le32(1)
    header += le32(UInt32(body.count))
    header += le32(0)

    var padded = header + body
    while padded.count < 512 { padded.append(0) }
    return Data(padded)
}

/// FAT header wrapping the two thin images above.
func fat(_ slices: [Data]) -> Data {
    var header: [UInt8] = []
    header += be32(0xCAFEBABE)
    header += be32(UInt32(slices.count))

    var dataOffset = 4096
    var offsets: [Int] = []
    for _ in slices {
        offsets.append(dataOffset)
        dataOffset += 4096
    }

    for (index, slice) in slices.enumerated() {
        header += be32(0x0100000C)
        header += be32(0x00000002)
        header += be32(UInt32(offsets[index]))
        header += be32(UInt32(slice.count))
        header += be32(12)
    }

    var out = header
    for (index, slice) in slices.enumerated() {
        while out.count < offsets[index] { out.append(0) }
        out += [UInt8](slice)
    }
    return Data(out)
}

print("Mach-O cryptid parsing")
check(MachOAnalyzer.cryptStatus(firstBytes: thin64(cryptid: 1)) == .encrypted, "thin arm64 cryptid=1 → encrypted")
check(MachOAnalyzer.cryptStatus(firstBytes: thin64(cryptid: 0)) == .plaintext, "thin arm64 cryptid=0 → plaintext")
check(MachOAnalyzer.cryptStatus(firstBytes: thin32(cryptid: 1)) == .encrypted, "thin armv7 cryptid=1 → encrypted")
check(MachOAnalyzer.cryptStatus(firstBytes: thin32(cryptid: 0)) == .plaintext, "thin armv7 cryptid=0 → plaintext")
check(MachOAnalyzer.cryptStatus(firstBytes: fat([thin32(cryptid: 1), thin64(cryptid: 1)])) == .encrypted,
      "fat with one encrypted slice → encrypted")
check(MachOAnalyzer.cryptStatus(firstBytes: fat([thin32(cryptid: 0), thin64(cryptid: 0)])) == .plaintext,
      "fat with plaintext slices → plaintext")
check(MachOAnalyzer.cryptStatus(firstBytes: Data("not a mach-o at all".utf8)) == nil, "garbage → not Mach-O")

// A Mach-O with a large LC_SEGMENT before the encryption command must still be
// parsed: the parser walks by cmdsize, not by fixed offset.
let bigSegment = Data(repeating: 0, count: 400)
check(MachOAnalyzer.cryptStatus(firstBytes: thin64(cryptid: 1, extraCommands: [(0x19, [UInt8](bigSegment))])) == .encrypted,
      "encryption command after a large LC_SEGMENT_64 is found")

print("Version comparison")
check(Version("1.2")! < Version("1.10")!, "1.2 < 1.10 (numeric, not lexicographic)")
check(Version("16.7.11")! > Version("16.7.2")!, "16.7.11 > 16.7.2")
check(Version("1.0")! == Version("1.0.0")!, "1.0 == 1.0.0")
check(Version("17")! == Version("17.0.0")!, "17 == 17.0.0")
check(Version("") == nil, "empty version rejected")
check(Version("abc") == nil, "non-numeric version rejected")

print("Helper @evt parsing")
let done = EventParser.parse("@evt event=done level=info msg=\"decrypted 3 images\" count=3")
check(done?["event"] == "done", "event name parsed")
check(done?["msg"] == "decrypted 3 images", "quoted message parsed")
check(done?["count"] == "3", "numeric attribute parsed")

let imageDone = EventParser.parse("@evt event=image.done level=info msg=\"decrypted Frameworks/A.framework/A (2.1 MB)\" name=Frameworks/A.framework/A kind=framework size=2100000")
check(imageDone?["name"] == "Frameworks/A.framework/A", "image path parsed")
check(imageDone?["size"] == "2100000", "image size parsed")

check(EventParser.parse("plain helper output") == nil, "non-event line ignored")
check(EventParser.parse("@evt level=info msg=missing-name") == nil, "event without a name ignored")

print("App Store identifier parsing")
check(AppStoreIdentifier.parse("com.burbn.instagram") == .bundleID("com.burbn.instagram"), "bundle id parsed")
check(AppStoreIdentifier.parse("389801252") == .trackID(389801252), "numeric track id parsed")
if case .url(_, let id)? = AppStoreIdentifier.parse("https://apps.apple.com/us/app/instagram/id389801252") {
    check(id == 389801252, "apps.apple.com link yields the track id")
} else {
    check(false, "apps.apple.com link parsed as a URL")
}
check(AppStoreIdentifier.parse("https://apps.apple.com/app/id123456789?mt=8") != nil, "link with query parsed")
check(AppStoreIdentifier.parse("not a bundle id") == nil, "free text rejected")
check(AppStoreIdentifier.parse("") == nil, "empty input rejected")
check(AppStoreIdentifier.parse("trailing.") == nil, "trailing dot rejected")
check(AppStoreIdentifier.trackID(inPath: "/us/app/name/id555") == 555, "track id found in a path")

print("App Store plist handling")
let bodyData = AppStorePlist.body(["appleId": "a&b<c>", "attempt": "1", "salableAdamId": "42"], integers: ["salableAdamId"])
let bodyText = String(decoding: bodyData, as: UTF8.self)
check(bodyText.contains("<key>appleId</key><string>a&amp;b&lt;c&gt;</string>"), "XML escaped")
check(bodyText.contains("<key>salableAdamId</key><integer>42</integer>"), "declared keys render as integers")
check(bodyText.contains("<key>attempt</key><string>1</string>"), "other numbers stay strings")
check(bodyText.hasPrefix("<?xml"), "plist header present")

let wrapped = Data("<Document><plist version=\"1.0\"><dict><key>failureType</key><string>9610</string></dict></plist></Document>".utf8)
check((try? AppStorePlist.parse(wrapped))?["failureType"] as? String == "9610", "<Document> wrapper normalised")
let bare = Data("<key>dsPersonId</key><string>123</string><key>passwordToken</key><string>tok</string>".utf8)
check((try? AppStorePlist.parse(bare))?["passwordToken"] as? String == "tok", "bare key/value run wrapped in a dict")
let dictOnly = Data("<dict><key>status</key><integer>0</integer></dict>".utf8)
check((try? AppStorePlist.parse(dictOnly))?["status"] as? Int == 0, "dict without a plist envelope parsed")

check(AppStoreClient.isAllowedAuthEndpoint("https://buy.itunes.apple.com/WebObjects/MZFinance.woa/wa/authenticate/"), "pod auth endpoint allowed")
check(AppStoreClient.isAllowedAuthEndpoint("https://p25-buy.itunes.apple.com/WebObjects/MZFinance.woa/wa/authenticate"), "per-pod host allowed")
check(!AppStoreClient.isAllowedAuthEndpoint("https://evil.example.com/WebObjects/MZFinance.woa/wa/authenticate"), "foreign host rejected")
check(AppStoreClient.dispatchURL("https://downloaddispatch.itunes.apple.com/ignored", "/r/redownload", guid: "AABBCCDDEEFF")?
    .hasPrefix("https://downloaddispatch.itunes.apple.com/r/redownload?guid=AABBCCDDEEFF") == true, "dispatch URL rebuilt from the bag")

print("Two-factor challenge parsing")
let idmsaJson: [String: Any] = [
    "authType": "hsa2",
    "noTrustedDevices": 0,
    "trustedPhoneNumbers": [
        ["id": 1, "numberWithDialCode": "+1 (•••) •••-1234", "obfuscatedNumber": "•••-1234", "pushMode": "sms"],
        ["id": 2, "numberWithDialCode": "+49 (•••) •••-5678", "pushMode": "sms"]
    ],
    "trustedDevices": [["id": "dev1", "name": "iPhone"]],
    "securityCode": ["length": 6]
]
check(TwoFactorParsing.isTwoFactor(idmsaJson), "hsa2 payload detected as 2FA")
let challenge = TwoFactorParsing.challenge(
    json: idmsaJson,
    headers: ["X-Apple-ID-Session-Id": "sess", "scnt": "sc"],
    email: "a@b.c",
    mode: .session,
    note: ""
)
check(challenge.options.count == 3, "two phone numbers + trusted device = 3 options")
check(challenge.options.filter { $0.kind == .sms }.count == 2, "both numbers are SMS options")
check(challenge.preferredOption?.kind == .sms, "SMS preferred over trusted device")
check(challenge.preferredOption?.phoneID == 1, "first phone number keeps its id")
check(challenge.codeLength == 6, "code length read from securityCode")
check(challenge.sessionID == "sess" && challenge.scnt == "sc", "session headers captured")
check(challenge.supportsNumberChoice, "session mode reports number choice")

let minimal: [String: Any] = ["authType": "hsa2"]
let minimalChallenge = TwoFactorParsing.challenge(json: minimal, headers: [:], email: "x", mode: .session, note: "")
check(minimalChallenge.options == [.device], "no numbers still offers the trusted device")
check(minimalChallenge.supportsNumberChoice == false, "no number choice without phone data")

let stringIDs: [String: Any] = ["trustedPhoneNumbers": [["id": "7", "numberWithDialCode": "+44 1234"]]]
let stringChallenge = TwoFactorParsing.challenge(json: stringIDs, headers: [:], email: "x", mode: .legacy, note: "")
check(stringChallenge.options.first?.phoneID == 7, "string phone ids coerced")
check(stringChallenge.mode == .legacy, "legacy mode preserved")
check(TwoFactorParsing.isTwoFactor(["failureType": "hsa2"]), "failureType hsa2 detected")
check(TwoFactorParsing.isTwoFactor(["customerMessage": "Enter your two-factor code"]), "message-based detection")
check(!TwoFactorParsing.isTwoFactor(["dsPersonId": "1", "passwordToken": "t"]), "successful payload is not 2FA")

print("Anisette header handling")
let local = AnisetteHeaders.local(guid: "AABBCCDDEEFF")
check(local.values["X-Mme-Device-Id"] == "AABBCCDDEEFF", "local headers carry the device GUID")
check(local.values["X-Apple-I-MD"] == nil, "local headers carry no attestation")
let serverJSON = Data(#"{"X-Apple-I-MD":"abc","X-Apple-I-MD-M":"machine","X-Apple-I-MD-RINFO":17106176}"#.utf8)
if let parsed = try? AnisetteHeaders.fromServer(serverJSON) {
    check(parsed.values["X-Apple-I-MD"] == "abc", "server OTP parsed")
    check(parsed.values["X-Apple-I-MD-RINFO"] == "17106176", "numeric routing info stringified")
} else {
    check(false, "server anisette JSON parsed")
}
check((try? AnisetteHeaders.fromServer(Data("{}".utf8))) == nil, "missing OTP rejected")

print("App Store credential persistence")
check(AppStoreCredentialPolicy.rememberedPassword("correct-horse", remember: true) == "correct-horse", "remembered password preserved")
check(AppStoreCredentialPolicy.rememberedPassword("correct-horse", remember: false) == nil, "unremembered password discarded")
check(AppStoreCredentialPolicy.rememberedPassword("", remember: true) == nil, "empty password not stored")

print("")
if failures == 0 {
    print("all checks passed")
} else {
    print("\(failures) check(s) failed")
    exit(1)
}
