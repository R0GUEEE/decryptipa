import Foundation
import Combine
import UIKit

/// Mutable file sink shared with the SSH streaming closure.
final class FileSink: @unchecked Sendable {
    private let handle: FileHandle
    private(set) var bytes: Int64 = 0
    private(set) var failure: Error?

    init?(url: URL) {
        let manager = FileManager.default
        manager.createFile(atPath: url.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: url) else { return nil }
        self.handle = handle
    }

    func write(_ data: Data) throws {
        if let failure { throw failure }
        do {
            try handle.write(contentsOf: data)
            bytes += Int64(data.count)
        } catch {
            failure = error
            throw error
        }
    }

    func finish() {
        try? handle.synchronize()
        try? handle.close()
    }
}

@MainActor
final class DecryptEngine: ObservableObject {
    struct Request {
        var device: DeviceProfile
        var secrets: DeviceSecrets
        var options: DecryptOptions
        var inputIPA: URL?
        var bundleIDOverride: String?
        var outputDirectory: URL
    }

    @Published private(set) var phase: JobPhase = .idle {
        didSet { Diagnostics.breadcrumb("phase: \(phase.title)") }
    }
    @Published private(set) var log: [LogEntry] = []
    @Published private(set) var receivedBytes: Int64 = 0
    @Published private(set) var imagesDone: Int = 0
    @Published private(set) var imagesFailed: Int = 0
    @Published private(set) var installProgress: Double = 0
    @Published private(set) var probe: ProbeResult?
    @Published private(set) var capabilities: Capabilities?
    @Published private(set) var outputURL: URL?
    @Published private(set) var verification: IPATool.VerifyReport?
    @Published private(set) var metadata: IPAMetadata?
    @Published private(set) var elapsed: TimeInterval = 0

    private var task: Task<Void, Never>?
    private var transport: SSHTransport?
    private var startedAt: Date?
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var pendingLog: [LogEntry] = []
    /// Remote files to delete before the SSH session closes.
    private var remoteCleanup: [String] = []
    private var cleanupService: DeviceService?
    private var flushScheduled = false
    private var heartbeat: Task<Void, Never>?

    var isRunning: Bool { task != nil }

    // MARK: Controls

    func start(_ request: Request) {
        guard task == nil else { return }
        reset()
        startedAt = Date()
        beginBackgroundTask()
        startHeartbeat()
        task = Task { [weak self] in
            guard let self else { return }
            await self.perform(request)
        }
    }

    func cancel() {
        task?.cancel()
        let transport = self.transport
        Task { await transport?.close() }
    }

    func clearLog() {
        log.removeAll()
    }

    /// A watchdog kill or a jetsam eviction leaves no signal and no exception.
    /// A breadcrumb every few seconds at least bounds where the run died.
    private func startHeartbeat() {
        heartbeat?.cancel()
        heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard let self, !Task.isCancelled else { return }
                Diagnostics.breadcrumb("heartbeat \(self.phase.title) · \(self.receivedBytes) B · \(self.imagesDone) images")
            }
        }
    }

    private func beginBackgroundTask() {
        UIApplication.shared.isIdleTimerDisabled = true
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "decryptipa-job") { [weak self] in
            Task { @MainActor in self?.endBackgroundTask() }
        }
    }

    private func endBackgroundTask() {
        UIApplication.shared.isIdleTimerDisabled = false
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    private func reset() {
        log.removeAll()
        pendingLog.removeAll()
        flushScheduled = false
        phase = .connecting
        receivedBytes = 0
        imagesDone = 0
        imagesFailed = 0
        installProgress = 0
        outputURL = nil
        verification = nil
        metadata = nil
        elapsed = 0
    }

    // MARK: Logging

    /// Coalesces bursts of helper events into ~8 publishes per second. The
    /// decrypt stream can emit hundreds of lines; publishing each one re-lays
    /// out the Form while the engine is still writing bytes.
    /// Records how much memory a step left behind. A site that jumps by hundreds
    /// of MB is where a runaway allocation lives; a flat number next to a hang is
    /// a watchdog problem instead.
    private func mark(_ step: String) {
        Diagnostics.breadcrumb(String(format: "step: %@ · footprint %.1f MB", step, Diagnostics.memoryFootprintMB))
    }

    private func guardMemory(_ stage: String) throws {
        let footprint = Diagnostics.memoryFootprintMB
        if footprint > 900 {
            throw appFailure("Stopped before \(stage): the app is already holding \(Int(footprint)) MB and iOS would kill it. Report this with the diagnostics bundle.")
        }
    }

    private func append(_ text: String, _ level: LogLevel = .info) {
        pendingLog.append(LogEntry(level: level, text: text))

        if pendingLog.count >= 120 {
            flushLog()
            return
        }
        if !flushScheduled {
            flushScheduled = true
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 120_000_000)
                self?.flushLog()
            }
        }
    }

    private func flushLog() {
        flushScheduled = false
        guard !pendingLog.isEmpty else { return }
        log.append(contentsOf: pendingLog)
        pendingLog.removeAll(keepingCapacity: true)
        if log.count > 800 { log.removeFirst(log.count - 800) }
    }

    private func refreshElapsed() {
        if let startedAt { elapsed = Date().timeIntervalSince(startedAt) }
    }

    // MARK: Pipeline

    private func perform(_ request: Request) async {
        defer {
            flushLog()
            refreshElapsed()
            let transport = self.transport
            self.transport = nil
            let cleanup = self.remoteCleanup
            let service = self.cleanupService
            self.remoteCleanup = []
            self.cleanupService = nil
            Task {
                if let service {
                    for path in cleanup { await service.removeRemote(path) }
                }
                await transport?.close()
            }
            task = nil
            heartbeat?.cancel()
            heartbeat = nil
            endBackgroundTask()
        }

        do {
            try await run(request)
        } catch is CancellationError {
            phase = .failed("cancelled")
            append("Cancelled.", .warn)
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            phase = .failed(message)
            append(message, .error)
        }
    }

    private func run(_ request: Request) async throws {
        let device = request.device

        phase = .connecting
        append("Connecting to \(device.endpoint)…", .command)
        let transport = try await SSHTransport.connect(profile: device, secrets: request.secrets)
        self.transport = transport
        let service = DeviceService(transport: transport)
        cleanupService = service
        append("SSH session established.", .success)
        mark("ssh connected")

        try Task.checkCancellation()

        // ---- probe
        phase = .probing
        let probe = try await service.probe()
        self.probe = probe
        mark("probe done")
        append("Device: \(probe.summary)", .success)

        let appinst = try await service.locateAppinst()
        let appSync = try await service.locateAppSync()
        mark("tooling located")
        append(appinst == nil ? "appinst not found — installing a bundle will fail." : "appinst: \(appinst!)",
               appinst == nil ? .warn : .info)
        append(appSync == nil ? "AppSync Unified not detected — appinst installs will likely be rejected." : "AppSync: \(appSync!)",
               appSync == nil ? .warn : .info)

        try Task.checkCancellation()

        // ---- inspect input
        var metadata: IPAMetadata? = nil
        phase = .inspecting

        if metadata == nil, let ipa = request.inputIPA {
            append("Reading \(ipa.lastPathComponent)…", .command)
            metadata = try IPATool.metadata(for: ipa)
        }
        self.metadata = metadata
        mark("ipa inspected")
        try guardMemory("uploading")

        if let metadata {
            append("Bundle \(metadata.bundleID) \(metadata.version) (\(metadata.build)) · minOS \(metadata.minimumOS) · \(ByteCountFormatter.string(fromByteCount: metadata.fileSize, countStyle: .file))", .info)
        }

        let bundleID = metadata?.bundleID ?? request.bundleIDOverride ?? ""
        guard !bundleID.isEmpty else {
            throw appFailure("No bundle identifier available — pick an IPA or type the installed app's bundle id.")
        }

        try Task.checkCancellation()

        // ---- prepare staging + helper
        phase = .preparing
        append("Uploading helper if needed…", .command)
        let helper = try await service.ensureHelper()
        capabilities = service.capabilities(appinst: appinst, appSync: appSync, helper: helper)
        mark("helper ready")
        append("Helper ready at \(helper)", .success)

        try await transport.createDirectories(SSHTransport.stagingDir)
        let remoteIPA = "\(SSHTransport.stagingDir)/\(safeFileName(bundleID))-\(UUID().uuidString.prefix(6)).ipa"

        remoteCleanup.append(remoteIPA)

        // ---- resolve installed copy
        var installed = try await service.findInstalled(bundleID: bundleID)
        mark("install scan")
        if let installed {
            append("Installed on device: \(installed.bundlePath) (v\(installed.version))", .info)
        }

        var weInstalled = false

        if metadata != nil {
            let mustInstall = installed == nil
                || (request.options.reinstallIfDifferent && installed?.version != metadata?.version)

            if mustInstall {
                guard let appinst, let ipa = request.inputIPA ?? metadataSourceURL(request) else {
                    throw appFailure("appinst is required to install the bundle: install AppSync Unified + appinst on the device.")
                }

                var uploadURL = ipa
                if request.options.patchForInstall {
                    phase = .preparing
                    let patched = FileManager.default.temporaryDirectory
                        .appendingPathComponent("decryptipa-\(UUID().uuidString).ipa")
                    let report = try IPATool.patchForInstall(
                        source: ipa,
                        destination: patched,
                        deviceVersion: probe.iosVersion,
                        deviceFamily: probe.deviceFamily,
                        expandDeviceFamily: request.options.expandDeviceFamily
                    )
                    if report.changed {
                        for note in report.notes { append(note, .info) }
                        uploadURL = patched
                        append("Patched IPA staged for install.", .success)
                    } else {
                        try? FileManager.default.removeItem(at: patched)
                        append("IPA needs no install patching.", .info)
                    }
                }

                phase = .uploading
                append("Uploading \(uploadURL.lastPathComponent) → \(remoteIPA)", .command)
                installProgress = 0
                try await transport.upload(fileURL: uploadURL, to: remoteIPA, mode: 0o644) { [weak self] sent, total in
                    Task { @MainActor in
                        guard let self else { return }
                        self.installProgress = total > 0 ? Double(sent) / Double(total) : 0
                    }
                }
                installProgress = 1

                if uploadURL != ipa {
                    try? FileManager.default.removeItem(at: uploadURL)
                }

                try Task.checkCancellation()

                phase = .installing
                append("Running \(appinst) — this can take a minute…", .command)
                try await service.install(appinst: appinst, ipaRemote: remoteIPA)
                mark("appinst finished")
                append("appinst finished.", .success)
                weInstalled = true

                installed = try await service.findInstalled(bundleID: bundleID)
                guard let installed else {
                    throw appFailure("Bundle \(bundleID) is not present after appinst succeeded.")
                }
                append("Installed bundle: \(installed.bundlePath)", .success)
            } else {
                append("Already installed with the same version — decrypting in place.", .info)
            }
        }

        guard let bundlePath = installed?.bundlePath else {
            throw appFailure("Bundle \(bundleID) is not installed on the device and no IPA was supplied to install it.")
        }

        try Task.checkCancellation()

        // ---- decrypt
        phase = .decrypting
        append("Decrypting \(bundleID)…", .command)
        mark("before decrypt")
        try guardMemory("decrypting")

        let outputName = outputFileName(metadata: metadata, bundleID: bundleID, version: installed?.version ?? "?")
        let finalURL = request.outputDirectory.appendingPathComponent(outputName)
        let partialURL = request.outputDirectory.appendingPathComponent(".partial-\(UUID().uuidString).ipa")

        guard let sink = FileSink(url: partialURL) else {
            throw appFailure("Could not open \(partialURL.lastPathComponent) for writing.")
        }

        var lastReported: Int64 = 0

        do {
            try await service.decrypt(
                helper: helper,
                bundleID: bundleID,
                bundlePath: bundlePath,
                skipAppex: request.options.skipAppex,
                verbose: request.options.verboseHelper,
                write: { data in
                    try sink.write(data)
                    if sink.bytes / (256 << 20) != (sink.bytes - Int64(data.count)) / (256 << 20) {
                        Diagnostics.breadcrumb(String(format: "stream: %lld B · footprint %.1f MB", sink.bytes, Diagnostics.memoryFootprintMB))
                    }
                },
                onEvent: { [weak self] event in
                    Task { @MainActor in
                        self?.handle(event: event)
                    }
                },
                onRawLine: { [weak self] line in
                    Task { @MainActor in
                        self?.append(line, .debug)
                    }
                }
            )
        } catch {
            sink.finish()
            try? FileManager.default.removeItem(at: partialURL)
            throw error
        }

        sink.finish()
        receivedBytes = sink.bytes

        if let failure = sink.failure {
            try? FileManager.default.removeItem(at: partialURL)
            throw appFailure("Writing the IPA failed: \(failure)")
        }

        guard sink.bytes > 0 else {
            try? FileManager.default.removeItem(at: partialURL)
            throw appFailure("The helper produced no IPA bytes — check the device log above.")
        }

        append("Received \(ByteCountFormatter.string(fromByteCount: sink.bytes, countStyle: .file)) · \(imagesDone) image(s) decrypted\(imagesFailed > 0 ? ", \(imagesFailed) failed" : "")", .success)

        // ---- verify
        if request.options.verifyOutput {
            phase = .verifying
            append("Verifying cryptid on every Mach-O…", .command)
            let report = try IPATool.verify(partialURL)
            verification = report
            if report.ok {
                append("Verified: \(report.plaintext)/\(report.checked) Mach-O images are plaintext.", .success)
            } else {
                append("Verification: \(report.stillEncrypted.count) still encrypted, \(report.unreadable.count) unreadable.", .warn)
                for name in report.stillEncrypted.prefix(6) {
                    append("  encrypted: \(name)", .warn)
                }
            }
        }

        // ---- finish
        phase = .finishing
        try? FileManager.default.removeItem(at: finalURL)
        try FileManager.default.moveItem(at: partialURL, to: finalURL)
        outputURL = finalURL
        append("Saved \(finalURL.lastPathComponent)", .success)

        if weInstalled, request.options.uninstallAfter {
            append("Removing the installed bundle…", .command)
            do {
                try await service.uninstall(bundlePath: bundlePath)
                append("Uninstalled \(bundleID).", .success)
            } catch {
                append("Uninstall failed: \((error as? LocalizedError)?.errorDescription ?? "\(error)")", .warn)
            }
        }

        phase = .done
        startedAt = startedAt ?? Date()
        refreshElapsed()
    }

    private func metadataSourceURL(_ request: Request) -> URL? {
        request.inputIPA
    }

    private func handle(event: [String: String]) {
        guard let name = event["event"] else { return }
        let message = event["msg"] ?? ""

        switch name {
        case "image.done":
            imagesDone += 1
            if let name = event["name"] { append("decrypted \(name)", .info) }
        case "image.failed":
            imagesFailed += 1
            append("failed \(event["name"] ?? "image") — \(event["reason"] ?? "unknown")", .warn)
        case "done":
            append(message.isEmpty ? "helper finished" : message, .success)
        case "stream.begin", "staging.begin", "bundle.begin", "pack.begin", "pack.done":
            if !message.isEmpty { append(message, .debug) }
        default:
            if !message.isEmpty { append(message, .debug) }
        }
    }

    private func safeFileName(_ text: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_"))
        return String(text.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }.prefix(80))
    }

    private func outputFileName(metadata: IPAMetadata?, bundleID: String, version: String) -> String {
        let base = safeFileName(metadata?.displayName ?? bundleID)
        return "\(base)_\(version)_\(safeFileName(bundleID))_decrypted.ipa"
    }
}
