import Foundation
import CryptoKit

/// Device-side operations, ported from ipadecrypt's internal/device package.
final class DeviceService {
    let transport: SSHTransport

    init(transport: SSHTransport) {
        self.transport = transport
    }

    // MARK: Probe

    func probe() async throws -> ProbeResult {
        let script = """
        sw_vers -productVersion 2>/dev/null || /usr/libexec/PlistBuddy -c 'Print :ProductVersion' /System/Library/CoreServices/SystemVersion.plist 2>/dev/null
        (sysctl -n hw.machine 2>/dev/null || /usr/sbin/sysctl -n hw.machine 2>/dev/null || /var/jb/usr/sbin/sysctl -n hw.machine 2>/dev/null || true)
        od -An -tx1 -j8 -N1 /sbin/launchd 2>/dev/null | tr -d ' \\n'; echo
        VJB=0; [ -e /var/jb ] && VJB=1
        LINK=$(readlink /var/jb 2>/dev/null)
        printf 'JB link=%s vjb=%s\\n' "$LINK" "$VJB"
        """

        let result = try await transport.run(script)
        guard result.ok else {
            throw err("Device probe failed (exit \(result.exitCode)): \(result.stderr)")
        }

        let lines = result.stdout.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var probe = ProbeResult()

        if lines.count > 0 {
            probe.iosVersion = lines[0].trimmingCharacters(in: .whitespaces)
        }
        if lines.count > 1 {
            probe.model = lines[1].trimmingCharacters(in: .whitespaces)
        }
        if lines.count > 2 {
            probe.arch = lines[2].trimmingCharacters(in: .whitespaces) == "02" ? "arm64e" : "arm64"
        }
        probe.deviceFamily = Self.deviceFamily(for: probe.model)

        for line in lines where line.contains("JB ") {
            probe.jailbreak = Self.classifyJailbreak(signature: line)
            break
        }

        return probe
    }

    static func deviceFamily(for model: String) -> Int {
        if model.hasPrefix("iPhone") || model.hasPrefix("iPod") { return 1 }
        if model.hasPrefix("iPad") { return 2 }
        return 0
    }

    static func classifyJailbreak(signature: String) -> String {
        var fields: [String: String] = [:]
        for token in signature.split(separator: " ") {
            let parts = token.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            if parts.count == 2 {
                fields[String(parts[0])] = String(parts[1])
            }
        }

        let link = (fields["link"] ?? "").lowercased()
        if link.contains("dopamine") || link.contains(".jbroot") { return "Dopamine" }
        if link.contains("palera1n") || link.contains("/jb-") { return "palera1n" }
        if fields["vjb"] == "1" { return "rootless?" }
        if link.isEmpty && fields["vjb"] == "0" { return "rootful/none" }
        return "unknown"
    }

    // MARK: Capabilities

    func locateAppinst() async throws -> String? {
        let result = try await transport.run("command -v appinst 2>/dev/null || true")
        let path = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if !path.isEmpty { return path }

        for candidate in ["/usr/local/bin/appinst", "/var/jb/usr/bin/appinst", "/var/jb/usr/local/bin/appinst"] {
            if await transport.exists(candidate) { return candidate }
        }
        return nil
    }

    func locateAppSync() async throws -> String? {
        let candidates = [
            "/var/jb/Library/MobileSubstrate/DynamicLibraries/AppSyncUnified-installd.dylib",
            "/Library/MobileSubstrate/DynamicLibraries/AppSyncUnified-installd.dylib",
            "/var/jb/Library/MobileSubstrate/DynamicLibraries/AppSyncUnified.dylib",
            "/Library/MobileSubstrate/DynamicLibraries/AppSyncUnified.dylib"
        ]
        for candidate in candidates {
            if await transport.exists(candidate) { return candidate }
        }

        let result = try await transport.run(
            "ls /Library/MobileSubstrate/DynamicLibraries/AppSyncUnified*.dylib " +
            "/var/jb/Library/MobileSubstrate/DynamicLibraries/AppSyncUnified*.dylib 2>/dev/null | head -1"
        )
        let path = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }

    /// Uploads the embedded helper when the content-addressed copy is absent.
    /// The remote filename carries the first 12 hex chars of the SHA-256, so a
    /// new app build never reuses a stale helper.
    func ensureHelper() async throws -> String {
        let data = try HelperBinary.load()
        let digest = SHA256.hash(data: data)
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        let remote = "\(SSHTransport.helpersDir)/ipadecrypt-helper-arm64-\(hex.prefix(12)).bin"

        if await transport.exists(remote) { return remote }

        try await transport.createDirectories(SSHTransport.helpersDir)
        try await transport.uploadData(data, to: remote, mode: 0o755)
        guard await transport.exists(remote) else {
            throw err("Helper upload failed: \(remote) is not present after upload.")
        }
        return remote
    }

    func verifyHelper(_ helperPath: String) async -> Bool {
        let result = try? await transport.runPrivileged("\(shellQuote(helperPath)) version 2>&1 | head -3")
        guard let result else { return false }
        let text = result.combined
        return !text.isEmpty
    }

    func capabilities(appinst: String?, appSync: String?, helper: String?) -> Capabilities {
        Capabilities(appinstPath: appinst, appSyncPath: appSync, helperPath: helper, remoteRootWritable: true)
    }

    // MARK: Installed app lookup

    struct InstalledApp {
        var bundlePath: String
        var bundleID: String
        var version: String
    }

    func findInstalled(bundleID: String) async throws -> InstalledApp? {
        let command = "grep -laFi \(shellQuote(bundleID)) /var/containers/Bundle/Application/*/*.app/Info.plist 2>/dev/null || true"
        let result = try await transport.runPrivileged(command)
        let hits = result.stdout.split(separator: "\n").map(String.init).filter { !$0.isEmpty }

        if hits.isEmpty { return nil }

        for infoPath in hits {
            let bundlePath = infoPath.replacingOccurrences(of: "/Info.plist", with: "")
            guard let info = try? await readPlist(infoPath) else { continue }
            let foundID = (info["CFBundleIdentifier"] as? String) ?? ""
            if foundID.caseInsensitiveCompare(bundleID) == .orderedSame {
                let version = (info["CFBundleShortVersionString"] as? String)
                    ?? (info["CFBundleVersion"] as? String) ?? "?"
                return InstalledApp(bundlePath: bundlePath, bundleID: foundID, version: version)
            }
        }
        return nil
    }

    func installedVersion(bundlePath: String) async throws -> String {
        let info = try await readPlist(bundlePath + "/Info.plist")
        return (info["CFBundleShortVersionString"] as? String)
            ?? (info["CFBundleVersion"] as? String) ?? "?"
    }

    func readPlist(_ path: String) async throws -> [String: Any] {
        let result = try await transport.runPrivileged("cat \(shellQuote(path))")
        guard result.ok, let payload = result.stdout.data(using: .utf8) else {
            throw err("Could not read \(path) (exit \(result.exitCode))")
        }
        guard let plist = try? PropertyListSerialization.propertyList(from: payload, options: [], format: nil),
              let dictionary = plist as? [String: Any] else {
            throw err("Could not parse \(path) as a property list.")
        }
        return dictionary
    }

    // MARK: Install / uninstall

    func install(appinst: String, ipaRemote: String) async throws {
        let result = try await transport.runPrivileged("\(shellQuote(appinst)) \(shellQuote(ipaRemote))")
        guard result.ok else {
            throw err("appinst failed (exit \(result.exitCode)): \(result.combined.suffix(800))")
        }
    }

    func uninstall(bundlePath: String) async throws {
        let root = "/var/containers/Bundle/Application/"
        guard bundlePath.hasPrefix(root) else {
            throw err("Refusing to uninstall a bundle outside \(root): \(bundlePath)")
        }
        let uuidDirectory = (bundlePath as NSString).deletingLastPathComponent
        let script = "uicache -u \(shellQuote(bundlePath)) && rm -rf \(shellQuote(uuidDirectory))"
        let result = try await transport.runPrivileged(script)
        guard result.ok else {
            throw err("Uninstall failed (exit \(result.exitCode)): \(result.combined.suffix(400))")
        }
    }

    func removeRemote(_ path: String) async {
        try? await transport.remove(path)
    }

    // MARK: Decrypt

    /// Runs `helper decrypt <bundle-id> <bundle-path> -`, streaming the IPA to
    /// `write`, and forwarding every `@evt` record to `onEvent`.
    func decrypt(
        helper: String,
        bundleID: String,
        bundlePath: String,
        skipAppex: Bool,
        verbose: Bool,
        write: @escaping @Sendable (Data) throws -> Void,
        onEvent: @escaping @Sendable ([String: String]) -> Void,
        onRawLine: @escaping @Sendable (String) -> Void
    ) async throws {
        var flags = "decrypt "
        if verbose { flags = "-v " + flags }
        if skipAppex { flags += "--skip-appex " }

        let command = "\(shellQuote(helper)) \(flags)\(shellQuote(bundleID)) \(shellQuote(bundlePath)) -"

        try await transport.streamPrivileged(
            command,
            onStdout: write,
            onStderrLine: { line in
                if let event = EventParser.parse(line) {
                    onEvent(event)
                } else if !line.isEmpty {
                    onRawLine(line)
                }
            }
        )
    }
}

// MARK: - Helper events

enum EventParser {
    /// Parses `@evt event=NAME level=LVL msg="text" k=v …` records.
    static func parse(_ line: String) -> [String: String]? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("@evt ") else { return nil }

        var attributes: [String: String] = [:]
        for token in splitTokens(String(trimmed.dropFirst(5))) {
            guard let eq = token.firstIndex(of: "="), eq != token.startIndex else { continue }
            let key = String(token[token.startIndex..<eq])
            var value = String(token[token.index(after: eq)...])
            if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
                value = String(value.dropFirst().dropLast())
            }
            attributes[key] = value
        }
        return attributes["event"] == nil ? nil : attributes
    }

    private static func splitTokens(_ text: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inQuotes = false

        for character in text {
            if character == "\"" {
                inQuotes.toggle()
                current.append(character)
            } else if character == " " && !inQuotes {
                if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }
}

// MARK: - Embedded helper

enum HelperBinary {
    static func load() throws -> Data {
        let candidates = [
            Bundle.main.url(forResource: "ipadecrypt-helper-arm64", withExtension: nil),
            Bundle.main.url(forResource: "ipadecrypt-helper-arm64", withExtension: "bin"),
            Bundle.main.url(forResource: "ipadecrypt-helper-arm64", withExtension: nil, subdirectory: "Resources")
        ]
        guard let url = candidates.compactMap({ $0 }).first else {
            throw err("The bundled ipadecrypt helper is missing from the app.")
        }
        return try Data(contentsOf: url)
    }

    static var sha256Prefix: String {
        guard let data = try? load() else { return "unavailable" }
        let digest = SHA256.hash(data: data)
        return String(digest.map { String(format: "%02x", $0) }.joined().prefix(12))
    }

    static var byteCount: Int {
        (try? load().count) ?? 0
    }
}
