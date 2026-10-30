import Foundation

// MARK: - Device

enum AuthKind: String, Codable, CaseIterable, Identifiable {
    case password
    case ed25519

    var id: String { rawValue }

    var label: String {
        switch self {
        case .password: return "Password"
        case .ed25519: return "Ed25519 key"
        }
    }
}

struct DeviceProfile: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String = "Jailbroken iPhone"
    var host: String = "192.168.1.50"
    var port: Int = 22
    var username: String = "root"
    var auth: AuthKind = .password
    /// Whether privileged commands need `sudo -S`. Detected from the username by default.
    var usesSudo: Bool? = nil
    var keyPassphraseIncluded: Bool = false

    var effectiveUsesSudo: Bool {
        if let usesSudo { return usesSudo }
        return username != "root"
    }

    var endpoint: String { "\(username)@\(host):\(port)" }
}

struct DeviceSecrets: Codable, Equatable {
    var password: String = ""
    var privateKey: String = ""
    var keyPassphrase: String = ""
    var sudoPassword: String = ""

    var isEmpty: Bool {
        password.isEmpty && privateKey.isEmpty && sudoPassword.isEmpty
    }
}

// MARK: - Probe

struct ProbeResult: Codable, Hashable {
    var iosVersion: String = "?"
    var model: String = "?"
    var arch: String = "arm64"
    var jailbreak: String = "unknown"
    var deviceFamily: Int = 0

    var summary: String {
        "iOS \(iosVersion) · \(arch) · \(model) · \(jailbreak)"
    }

    var deviceFamilyName: String {
        switch deviceFamily {
        case 1: return "iPhone"
        case 2: return "iPad"
        default: return "unknown"
        }
    }
}

struct Capabilities: Codable, Hashable {
    var appinstPath: String?
    var appSyncPath: String?
    var helperPath: String?
    var remoteRootWritable: Bool = false

    var canInstall: Bool { appinstPath != nil }
    var summary: String {
        var parts: [String] = []
        parts.append(appinstPath == nil ? "appinst: missing" : "appinst: ok")
        parts.append(appSyncPath == nil ? "AppSync: missing" : "AppSync: ok")
        parts.append(helperPath == nil ? "helper: not uploaded" : "helper: ready")
        return parts.joined(separator: " · ")
    }
}

// MARK: - IPA metadata

struct IPAMetadata: Hashable {
    var bundleID: String
    var version: String
    var build: String
    var displayName: String
    var executable: String
    var minimumOS: String
    var deviceFamily: [Int]
    /// Zip-relative path of the .app directory, e.g. `Payload/Foo.app`
    var appDirectoryPath: String
    var infoPlistPath: String
    var fileSize: Int64
}

// MARK: - Options

struct DecryptOptions: Codable, Hashable {
    var skipAppex: Bool = false
    var patchForInstall: Bool = true
    var expandDeviceFamily: Bool = false
    var reinstallIfDifferent: Bool = true
    var uninstallAfter: Bool = false
    var verboseHelper: Bool = true
    var verifyOutput: Bool = true
}

// MARK: - Log / status

enum LogLevel: String, Codable {
    case info, warn, error, success, command, debug

    var symbol: String {
        switch self {
        case .info: return "•"
        case .warn: return "!"
        case .error: return "×"
        case .success: return "✓"
        case .command: return "$"
        case .debug: return "·"
        }
    }
}

struct LogEntry: Identifiable, Hashable {
    let id = UUID()
    let date: Date = Date()
    let level: LogLevel
    let text: String
}

enum JobPhase: Equatable {
    case idle
    case connecting
    case probing
    case inspecting
    case preparing
    case uploading
    case installing
    case decrypting
    case verifying
    case finishing
    case done
    case failed(String)

    var title: String {
        switch self {
        case .idle: return "Idle"
        case .connecting: return "Connecting"
        case .probing: return "Probing device"
        case .inspecting: return "Reading IPA"
        case .preparing: return "Preparing staging area"
        case .uploading: return "Uploading to device"
        case .installing: return "Installing with appinst"
        case .decrypting: return "Decrypting on device"
        case .verifying: return "Verifying output"
        case .finishing: return "Saving IPA"
        case .done: return "Done"
        case .failed(let reason): return "Failed: \(reason)"
        }
    }

    var isBusy: Bool {
        switch self {
        case .idle, .done, .failed: return false
        default: return true
        }
    }
}

// MARK: - Errors

enum AppError: LocalizedError {
    case message(String)
    case unsupported(String)

    var errorDescription: String? {
        switch self {
        case .message(let m): return m
        case .unsupported(let m): return m
        }
    }
}

func appFailure(_ text: String) -> AppError { .message(text) }
