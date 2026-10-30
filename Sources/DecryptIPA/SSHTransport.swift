import Foundation
import NIOCore
import Citadel
import Crypto
import Logging

struct CommandResult {
    var stdout: String = ""
    var stderr: String = ""
    var exitCode: Int32 = 0

    var ok: Bool { exitCode == 0 }
    var combined: String {
        [stdout, stderr].filter { !$0.isEmpty }.joined(separator: "\n")
    }
}

/// POSIX single-quote escaping, matching ipadecrypt's shellQuote().
func shellQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

/// One SSH+SFTP session against a jailed/extracted device.
/// Mirrors ipadecrypt's internal/device.Client.
final class SSHTransport: @unchecked Sendable {
    static let remoteRoot = "/var/mobile/Media/ipadecrypt"
    static let helpersDir = remoteRoot + "/helpers"
    static let stagingDir = remoteRoot + "/staging"

    let profile: DeviceProfile
    let isRoot: Bool
    let usesSudo: Bool

    private let client: SSHClient
    private let sudoPasswordPath: String?
    private static let log = Logger(label: "decryptipa.ssh")

    private init(client: SSHClient, profile: DeviceProfile, sudoPasswordPath: String?) {
        self.client = client
        self.profile = profile
        self.isRoot = profile.username == "root"
        self.usesSudo = profile.effectiveUsesSudo && profile.username != "root"
        self.sudoPasswordPath = sudoPasswordPath
    }

    // MARK: Connect

    static func connect(profile: DeviceProfile, secrets: DeviceSecrets) async throws -> SSHTransport {
        let auth: SSHAuthenticationMethod

        switch profile.auth {
        case .password:
            guard !secrets.password.isEmpty else {
                throw appFailure("Enter the SSH password for \(profile.endpoint).")
            }
            auth = .passwordBased(username: profile.username, password: secrets.password)

        case .ed25519:
            guard !secrets.privateKey.isEmpty else {
                throw appFailure("Paste an unencrypted or passphrase-protected OpenSSH ed25519 private key.")
            }
            let key: Curve25519.Signing.PrivateKey
            do {
                let passphrase = secrets.keyPassphrase.isEmpty ? nil : Data(secrets.keyPassphrase.utf8)
                key = try Curve25519.Signing.PrivateKey(sshEd25519: secrets.privateKey, decryptionKey: passphrase)
            } catch {
                throw appFailure("The private key could not be parsed (only OpenSSH ed25519 keys are supported): \(error)")
            }
            auth = .ed25519(username: profile.username, privateKey: key)
        }

        Diagnostics.breadcrumb("ssh: connect \(profile.endpoint) auth=\(profile.auth.rawValue) sudo=\(profile.effectiveUsesSudo)")

        let client: SSHClient
        do {
            client = try await SSHClient.connect(
                host: profile.host,
                port: profile.port,
                authenticationMethod: auth,
                hostKeyValidator: .acceptAnything(),
                reconnect: .never,
                connectTimeout: .seconds(25)
            )
        } catch {
            throw appFailure("SSH connect to \(profile.endpoint) failed: \(error)")
        }

        Diagnostics.breadcrumb("ssh: connected \(profile.endpoint)")

        var sudoPath: String?
        let transport = SSHTransport(client: client, profile: profile, sudoPasswordPath: nil)

        if profile.effectiveUsesSudo && profile.username != "root" {
            let remote = "\(remoteRoot)/.sudo-\(UUID().uuidString.prefix(8))"
            do {
                try await transport.createDirectories(remoteRoot)
                try await transport.uploadData(Data((secrets.sudoPassword + "\n").utf8), to: remote, mode: 0o600)
                sudoPath = remote
            } catch {
                try? await client.close()
                throw appFailure("Could not stage the sudo password on the device: \(error)")
            }
        }

        let ready = SSHTransport(client: client, profile: profile, sudoPasswordPath: sudoPath)
        return ready
    }

    func close() async {
        if let sudoPasswordPath {
            try? await remove(sudoPasswordPath)
        }
        try? await client.close()
    }

    // MARK: Command execution

    /// Wraps a command so it runs as root, using the staged sudo password.
    private func privileged(_ command: String) -> String {
        guard usesSudo else { return command }
        guard let sudoPasswordPath else { return "sudo -n -p '' /bin/sh -c \(shellQuote(command))" }
        return "sudo -S -p '' /bin/sh -c \(shellQuote(command)) < \(shellQuote(sudoPasswordPath))"
    }

    func run(_ command: String) async throws -> CommandResult {
        try await collect(command, privileged: false)
    }

    /// Raw bytes for commands that emit binary data (property lists, for
    /// example). `run` decodes as UTF-8 and would corrupt them.
    func runData(_ command: String, privileged isPrivileged: Bool = false) async throws -> (data: Data, stderr: String, exitCode: Int32) {
        let line = isPrivileged ? privileged(command) : command
        var stdout = Data()
        var stderr = Data()
        let cap = 8 << 20

        let stream = try await client.executeCommandStream(line)
        do {
            for try await chunk in stream {
                switch chunk {
                case .stdout(let buffer):
                    if stdout.count < cap { stdout.append(contentsOf: buffer.readableBytesView) }
                case .stderr(let buffer):
                    if stderr.count < cap { stderr.append(contentsOf: buffer.readableBytesView) }
                }
            }
            return (stdout, String(decoding: stderr, as: UTF8.self), 0)
        } catch let failure as SSHClient.CommandFailed {
            return (stdout, String(decoding: stderr, as: UTF8.self), Int32(failure.exitCode))
        } catch {
            throw appFailure("Command failed: \(error)")
        }
    }

    func runPrivileged(_ command: String) async throws -> CommandResult {
        try await collect(command, privileged: true)
    }

    private func collect(_ command: String, privileged isPrivileged: Bool) async throws -> CommandResult {
        let line = isPrivileged ? privileged(command) : command
        var stdout = Data()
        var stderr = Data()
        let cap = 4 << 20

        let stream = try await client.executeCommandStream(line)
        do {
            for try await chunk in stream {
                switch chunk {
                case .stdout(let buffer):
                    if stdout.count < cap { stdout.append(contentsOf: buffer.readableBytesView) }
                case .stderr(let buffer):
                    if stderr.count < cap { stderr.append(contentsOf: buffer.readableBytesView) }
                }
            }
            return CommandResult(
                stdout: String(decoding: stdout, as: UTF8.self),
                stderr: String(decoding: stderr, as: UTF8.self),
                exitCode: 0
            )
        } catch let failure as SSHClient.CommandFailed {
            return CommandResult(
                stdout: String(decoding: stdout, as: UTF8.self),
                stderr: String(decoding: stderr, as: UTF8.self),
                exitCode: Int32(failure.exitCode)
            )
        } catch {
            throw appFailure("Command failed: \(error)")
        }
    }

    /// Runs a privileged command and streams stdout in chunks while splitting
    /// stderr into lines (the helper writes `@evt …` records there when the IPA
    /// goes to stdout).
    func streamPrivileged(
        _ command: String,
        onStdout: @escaping @Sendable (Data) throws -> Void,
        onStderrLine: @escaping @Sendable (String) -> Void
    ) async throws {
        let line = privileged(command)
        let stream = try await client.executeCommandStream(line)

        var carry = Data()

        do {
            for try await chunk in stream {
                switch chunk {
                case .stdout(let buffer):
                    try onStdout(Data(buffer.readableBytesView))
                case .stderr(let buffer):
                    carry.append(contentsOf: buffer.readableBytesView)
                    while let newline = carry.firstIndex(of: 0x0A) {
                        let lineData = carry[carry.startIndex..<newline]
                        carry = Data(carry[carry.index(after: newline)...])
                        if let text = String(data: lineData, encoding: .utf8) {
                            onStderrLine(text)
                        }
                    }
                }
            }
        } catch let failure as SSHClient.CommandFailed {
            flushCarry(&carry, onStderrLine)
            throw appFailure("The on-device helper exited with status \(failure.exitCode).")
        } catch {
            flushCarry(&carry, onStderrLine)
            throw appFailure("Decrypt stream failed: \(error)")
        }

        flushCarry(&carry, onStderrLine)
    }

    private func flushCarry(_ carry: inout Data, _ emit: @Sendable (String) -> Void) {
        if !carry.isEmpty, let text = String(data: carry, encoding: .utf8) {
            emit(text)
        }
        carry = Data()
    }

    // MARK: Files

    func createDirectories(_ path: String) async throws {
        _ = try await client.withSFTP { sftp in
            try? await sftp.createDirectory(atPath: path)
        }
    }

    /// Existence check through the shell instead of SFTP: each `withSFTP` opens
    /// a fresh SSH channel, and a job used to open half a dozen of them before
    /// touching a byte. One exec is cheaper and far easier to reason about.
    func pathExists(_ path: String) async -> Bool {
        let result = try? await run("[ -e \(shellQuote(path)) ] && echo yes || echo no")
        return (result?.stdout.contains("yes")).map { $0 } ?? false
    }

    func makeDirectories(_ path: String) async throws {
        let result = try await runPrivileged("mkdir -p \(shellQuote(path))")
        guard result.ok else {
            throw appFailure("mkdir -p \(path) failed: \(result.combined.suffix(200))")
        }
    }

    func exists(_ path: String) async -> Bool {
        do {
            _ = try await client.withSFTP { sftp in
                try await sftp.getAttributes(at: path)
            }
            return true
        } catch {
            return false
        }
    }

    func remove(_ path: String) async throws {
        _ = try await client.withSFTP { sftp in
            try? await sftp.remove(at: path)
        }
    }

    func uploadData(_ data: Data, to remote: String, mode: UInt32 = 0o644) async throws {
        try await client.withSFTP { sftp in
            try await sftp.withFile(filePath: remote, flags: [.write, .create, .truncate]) { file in
                var offset: UInt64 = 0
                let chunkSize = 256 * 1024
                var index = data.startIndex

                while index < data.endIndex {
                    let end = data.index(index, offsetBy: min(chunkSize, data.distance(from: index, to: data.endIndex)))
                    let slice = data[index..<end]
                    try await file.write(ByteBuffer(bytes: slice), at: offset)
                    offset += UInt64(slice.count)
                    index = end
                }
            }

            var attributes = SFTPFileAttributes()
            attributes.permissions = mode
            try? await sftp.setAttributes(at: remote, to: attributes)
        }
    }

    /// Uploads a file in 512 KB SFTP writes with a byte-progress callback.
    func upload(
        fileURL: URL,
        to remote: String,
        mode: UInt32 = 0o644,
        onProgress: @escaping @Sendable (Int64, Int64) -> Void
    ) async throws {
        let state = UploadState(fileURL: fileURL)
        defer { try? state.handle.close() }

        try await client.withSFTP { sftp in
            try await sftp.withFile(filePath: remote, flags: [.write, .create, .truncate]) { file in
                while true {
                    let chunk = try state.handle.read(upToCount: 512 * 1024) ?? Data()
                    if chunk.isEmpty { break }
                    try await file.write(ByteBuffer(bytes: chunk), at: UInt64(state.sent))
                    state.sent += Int64(chunk.count)
                    onProgress(state.sent, state.total)
                }
            }

            var attributes = SFTPFileAttributes()
            attributes.permissions = mode
            try? await sftp.setAttributes(at: remote, to: attributes)
        }
    }
}

/// Mutable upload bookkeeping shared with SFTP's @Sendable closure.
final class UploadState: @unchecked Sendable {
    let handle: FileHandle
    let total: Int64
    var sent: Int64 = 0

    init(fileURL: URL) {
        self.handle = (try? FileHandle(forReadingFrom: fileURL)) ?? FileHandle.nullDevice
        let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
        self.total = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
    }
}
