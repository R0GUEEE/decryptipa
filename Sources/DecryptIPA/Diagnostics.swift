import Foundation
import UIKit

/// Crash + breadcrumb capture.
///
/// The app cannot be debugged from a desk, so the two things that make a field
/// crash actionable are recorded here:
///
///  * **breadcrumbs** — a ring of timestamped lines (job start, phase changes,
///    SSH connect, upload, install, stream, verify) rewritten to
///    `Documents/Logs/last-run.txt` whenever one is added. After a crash this
///    file shows exactly how far the job got.
///  * **crash reports** — an uncaught-exception handler writes name, reason and
///    the call stack symbols to `Documents/Logs/crash-<date>.txt`, and the fatal
///    signal handlers append a one-line marker (they only use `write(2)` on a
///    file descriptor opened at launch, so they stay safe inside a handler).
enum Diagnostics {
    private static let lock = NSLock()
    private static var breadcrumbs: [String] = []
    private static let maximumBreadcrumbs = 240

    /// Opened once at launch so the signal handler never has to resolve a path.
    private static var signalFD: Int32 = -1

    static var logDirectory: URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let directory = documents.appendingPathComponent("Logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    // MARK: Install

    static func install() {
        openSignalFile()
        installExceptionHandler()
        installSignalHandlers()

        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        breadcrumb("launch \(version) (\(build)) · iOS \(UIDevice.current.systemVersion) · \(UIDevice.current.model)")
        flush()
    }

    private static func openSignalFile() {
        let path = logDirectory.appendingPathComponent("crash-signal.txt").path
        signalFD = open(path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
    }

    private static func installExceptionHandler() {
        NSSetUncaughtExceptionHandler { exception in
            var report = "Uncaught exception\n"
            report += "name: \(exception.name.rawValue)\n"
            report += "reason: \(exception.reason ?? "-")\n"
            report += "userInfo: \(exception.userInfo ?? [:])\n\n"
            report += "call stack symbols:\n"
            report += Thread.callStackSymbols.joined(separator: "\n")
            report += "\n\nbreadcrumbs:\n"
            report += currentBreadcrumbs()

            writeReport(named: "crash-exception") { report }
        }
    }

    private static func installSignalHandlers() {
        let signals: [Int32] = [SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGFPE, SIGTRAP]

        for value in signals {
            signal(value, { received in
                let message = signalMessage(for: received)
                if Diagnostics.signalFD >= 0 {
                    message.withCString { pointer in
                        _ = write(Diagnostics.signalFD, pointer, strlen(pointer))
                    }
                }
                signal(received, SIG_DFL)
                raise(received)
            })
        }
    }

    private static func signalMessage(for signalNumber: Int32) -> String {
        switch signalNumber {
        case SIGABRT: return "fatal signal SIGABRT — see last-run.txt\n"
        case SIGSEGV: return "fatal signal SIGSEGV — see last-run.txt\n"
        case SIGBUS: return "fatal signal SIGBUS — see last-run.txt\n"
        case SIGILL: return "fatal signal SIGILL — see last-run.txt\n"
        case SIGFPE: return "fatal signal SIGFPE — see last-run.txt\n"
        case SIGTRAP: return "fatal signal SIGTRAP — see last-run.txt\n"
        default: return "fatal signal — see last-run.txt\n"
        }
    }

    // MARK: Breadcrumbs

    static func breadcrumb(_ text: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"

        lock.lock()
        breadcrumbs.append("\(formatter.string(from: Date()))  \(text)")
        if breadcrumbs.count > maximumBreadcrumbs {
            breadcrumbs.removeFirst(breadcrumbs.count - maximumBreadcrumbs)
        }
        lock.unlock()

        flush()
    }

    static func currentBreadcrumbs() -> String {
        lock.lock()
        defer { lock.unlock() }
        return breadcrumbs.joined(separator: "\n")
    }

    /// Rewrites the breadcrumb file so it is always current, even if the process
    /// dies in the next instruction.
    static func flush() {
        let contents = "DecryptIPA last run\n\n" + currentBreadcrumbs() + "\n"
        let url = logDirectory.appendingPathComponent("last-run.txt")
        try? Data(contents.utf8).write(to: url, options: .atomic)
    }

    // MARK: Reports

    private static func writeReport(named prefix: String, body: () -> String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let name = "\(prefix)-\(formatter.string(from: Date())).txt"
        let url = logDirectory.appendingPathComponent(name)
        try? Data(body().utf8).write(to: url, options: .atomic)
    }

    static func reports() -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: logDirectory,
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
