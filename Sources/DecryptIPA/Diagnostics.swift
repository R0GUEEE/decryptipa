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
        let path = diagnosticsLogDirectory().appendingPathComponent("crash-signal.txt").path
        diagnosticsSignalFD = open(path, O_WRONLY | O_CREAT | O_APPEND, 0o644)

        NSSetUncaughtExceptionHandler(diagnosticsExceptionHandler)

        for value in [SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGFPE, SIGTRAP] as [Int32] {
            signal(value, diagnosticsSignalHandler)
        }

        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        breadcrumb("launch \(version) (\(build)) · iOS \(UIDevice.current.systemVersion) · \(UIDevice.current.model)")
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
        for url in reports() {
            lines.append("=== \(url.lastPathComponent) ===")
            lines.append(text(of: url))
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }
}
