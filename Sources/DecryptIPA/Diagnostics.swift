import Foundation
import UIKit

// MARK: - File-scope state
//
// The signal and exception handlers must be plain C function pointers, so they
// cannot capture anything: all state they touch lives at file scope.

private let diagnosticsLock = NSLock()
private var diagnosticsBreadcrumbs: [String] = []
private let diagnosticsMaxBreadcrumbs = 240
private var diagnosticsSignalFD: Int32 = -1

private let diagnosticsSigAbrt: StaticString = "fatal signal SIGABRT — see last-run.txt\n"
private let diagnosticsSigSegv: StaticString = "fatal signal SIGSEGV — see last-run.txt\n"
private let diagnosticsSigBus: StaticString = "fatal signal SIGBUS — see last-run.txt\n"
private let diagnosticsSigIll: StaticString = "fatal signal SIGILL — see last-run.txt\n"
private let diagnosticsSigFpe: StaticString = "fatal signal SIGFPE — see last-run.txt\n"
private let diagnosticsSigTrap: StaticString = "fatal signal SIGTRAP — see last-run.txt\n"
private let diagnosticsSigOther: StaticString = "fatal signal — see last-run.txt\n"

private func diagnosticsLogDirectory() -> URL {
    let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    let directory = documents.appendingPathComponent("Logs", isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func diagnosticsBreadcrumbText() -> String {
    diagnosticsLock.lock()
    defer { diagnosticsLock.unlock() }
    return diagnosticsBreadcrumbs.joined(separator: "\n")
}

private func diagnosticsWriteReport(prefix: String, contents: String) {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyyMMdd-HHmmss"
    let name = "\(prefix)-\(formatter.string(from: Date())).txt"
    let url = diagnosticsLogDirectory().appendingPathComponent(name)
    try? Data(contents.utf8).write(to: url, options: .atomic)
}

/// Appends the fatal signal to `crash-signal.txt` with only `write(2)` on a
/// descriptor opened at launch, then restores the default action and re-raises
/// so the system still produces its own report.
private func diagnosticsSignalHandler(_ received: Int32) {
    let message: StaticString
    switch received {
    case SIGABRT: message = diagnosticsSigAbrt
    case SIGSEGV: message = diagnosticsSigSegv
    case SIGBUS: message = diagnosticsSigBus
    case SIGILL: message = diagnosticsSigIll
    case SIGFPE: message = diagnosticsSigFpe
    case SIGTRAP: message = diagnosticsSigTrap
    default: message = diagnosticsSigOther
    }

    if diagnosticsSignalFD >= 0 {
        _ = write(diagnosticsSignalFD, message.utf8Start, message.utf8CodeUnitCount)
    }

    signal(received, SIG_DFL)
    raise(received)
}

private func diagnosticsExceptionHandler(_ exception: NSException) {
    var report = "Uncaught exception\n"
    report += "name: \(exception.name.rawValue)\n"
    report += "reason: \(exception.reason ?? "-")\n"
    report += "userInfo: \(exception.userInfo ?? [:])\n\n"
    report += "call stack symbols:\n"
    report += Thread.callStackSymbols.joined(separator: "\n")
    report += "\n\nbreadcrumbs:\n"
    report += diagnosticsBreadcrumbText()

    diagnosticsWriteReport(prefix: "crash-exception", contents: report)
}

// MARK: - Public API

/// Crash + breadcrumb capture for a field build that cannot be debugged live.
///
///  * every phase change and transport step appends a timestamped breadcrumb and
///    rewrites `Documents/Logs/last-run.txt`, so the file always shows the last
///    thing the app did;
///  * uncaught exceptions write name, reason and call-stack symbols to
///    `Documents/Logs/crash-exception-*.txt`;
///  * fatal signals append one line to `crash-signal.txt`.
///
/// Both are visible in Library → ⋯ → Diagnostics & crash logs.
enum Diagnostics {
    static var logDirectory: URL { diagnosticsLogDirectory() }

    static func install() {
        archivePreviousRun()

        let path = diagnosticsLogDirectory().appendingPathComponent("crash-signal.txt").path
        diagnosticsSignalFD = open(path, O_WRONLY | O_CREAT | O_APPEND, 0o644)

        NSSetUncaughtExceptionHandler(diagnosticsExceptionHandler)

        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { _ in
            Diagnostics.breadcrumb(String(format: "memory warning · footprint %.1f MB", Diagnostics.memoryFootprintMB))
        }

        for value in [SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGFPE, SIGTRAP] as [Int32] {
            signal(value, diagnosticsSignalHandler)
        }

        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        breadcrumb(String(
            format: "launch %@ (%@) · iOS %@ · %@ · footprint %.1f MB",
            version, build, UIDevice.current.systemVersion, UIDevice.current.model, memoryFootprintMB
        ))
        startMemoryWatch()
        flush()
    }

    /// Moves the last run's breadcrumbs into `Logs/runs/` so a relaunch after a
    /// crash cannot destroy the trail that explains it. Keeps the ten newest.
    private static func archivePreviousRun() {
        let fileManager = FileManager.default
        let runs = diagnosticsLogDirectory().appendingPathComponent("runs", isDirectory: true)
        try? fileManager.createDirectory(at: runs, withIntermediateDirectories: true)

        let current = diagnosticsLogDirectory().appendingPathComponent("last-run.txt")
        guard fileManager.fileExists(atPath: current.path) else { return }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let destination = runs.appendingPathComponent("run-\(formatter.string(from: Date())).txt")
        try? fileManager.moveItem(at: current, to: destination)

        let existing = (try? fileManager.contentsOfDirectory(
            at: runs,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        let sorted = existing.sorted { left, right in
            let l = (try? left.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let r = (try? right.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return l > r
        }

        for url in sorted.dropFirst(10) {
            try? fileManager.removeItem(at: url)
        }

        flagUnexpectedEnd(of: destination)
    }

    /// A run that never logged a background transition and never reached a crash
    /// handler is the interesting case: the process vanished while foregrounded
    /// (watchdog kill, jetsam, or a signal our handler could not write). Record
    /// it next to the run file so it cannot be missed.
    private static func flagUnexpectedEnd(of runURL: URL) {
        let tail = lastStep(of: runURL)
        guard !tail.isEmpty else { return }
        guard !tail.contains("scenePhase: background") else { return }
        guard !tail.contains("clean exit") else { return }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let report = """
        Run ended without a shutdown transition
        run file: \(runURL.lastPathComponent)
        last recorded step: \(tail)

        The foregrounded process disappeared without a signal or exception our
        handlers could catch, which usually means a watchdog kill (main thread
        blocked) or a jetsam eviction.

        full run:
        \(text(of: runURL))
        """

        diagnosticsWriteReport(prefix: "crash-suspected", contents: report)
    }

    /// Breadcrumb files from earlier launches, newest first.
    static func previousRuns() -> [URL] {
        let runs = diagnosticsLogDirectory().appendingPathComponent("runs", isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(
            at: runs,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        return files.sorted { left, right in
            let l = (try? left.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let r = (try? right.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return l > r
        }
    }

    /// Last line of a run file — the step that run stopped at.
    static func lastStep(of url: URL) -> String {
        let text = text(of: url)
        return text
            .split(separator: "\n")
            .last
            .map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""
    }

    /// Resident footprint in MB — jetsam kills correlate with this, watchdog
    /// kills do not, so recording it separates the two.
    static var memoryFootprintMB: Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), rebound, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return Double(info.resident_size) / 1_048_576
    }

    /// Set by the visible screen so memory samples say where the app was.
    static var currentScreen: String = "launch"

    /// One sample per second, written every five. If the footprint runs away the
    /// app writes a report and exits cleanly instead of being jetsam'd, so the
    /// evidence survives the death.
    static func startMemoryWatch() {
        Task {
            var ticks = 0
            var last: Double = 0
            while true {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                ticks += 1

                let footprint = memoryFootprintMB
                if ticks % 5 == 0 {
                    breadcrumb(String(format: "mem: %.1f MB (Δ%+.1f) · screen=%@", footprint, footprint - last, currentScreen))
                    last = footprint
                }

                if footprint > 1100 {
                    writeMemoryReport(footprint)
                    exit(0)
                }
            }
        }
    }

    private static func writeMemoryReport(_ footprint: Double) {
        var report = String(format: "Footprint %.1f MB on screen %@\n\n", footprint, currentScreen)
        report += diagnosticsBreadcrumbText()
        diagnosticsWriteReport(prefix: "memory-runaway", contents: report)
        flush()
    }

    static func breadcrumb(_ text: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        let line = "\(formatter.string(from: Date()))  \(text)"

        diagnosticsLock.lock()
        diagnosticsBreadcrumbs.append(line)
        if diagnosticsBreadcrumbs.count > diagnosticsMaxBreadcrumbs {
            diagnosticsBreadcrumbs.removeFirst(diagnosticsBreadcrumbs.count - diagnosticsMaxBreadcrumbs)
        }
        diagnosticsLock.unlock()

        flush()
    }

    static func currentBreadcrumbs() -> String {
        diagnosticsBreadcrumbText()
    }

    /// Rewrites the breadcrumb file so it is current even if the process dies in
    /// the next instruction.
    static func flush() {
        let contents = "DecryptIPA last run\n\n" + diagnosticsBreadcrumbText() + "\n"
        let url = diagnosticsLogDirectory().appendingPathComponent("last-run.txt")
        try? Data(contents.utf8).write(to: url, options: .atomic)
    }

    static func reports() -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: diagnosticsLogDirectory(),
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        return files
            .filter { $0.lastPathComponent.hasPrefix("crash") || $0.lastPathComponent == "last-run.txt" }
            .sorted { left, right in
                let l = (try? left.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let r = (try? right.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return l > r
            }
    }

    static func text(of url: URL) -> String {
        (try? String(contentsOf: url, encoding: .utf8)) ?? "<unreadable>"
    }

    static func delete(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    /// Everything in one paste, for a support message.
    static func summary() -> String {
        var lines = ["DecryptIPA diagnostics", "logs: \(logDirectory.path)", ""]
        for url in reports() + previousRuns() {
            lines.append("=== \(url.lastPathComponent) ===")
            lines.append(text(of: url))
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }
}
