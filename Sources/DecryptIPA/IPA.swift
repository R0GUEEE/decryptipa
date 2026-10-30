import Foundation
import ZIPFoundation

// MARK: - Metadata

enum IPATool {
    /// Reads the app bundle metadata out of an IPA without unpacking it.
    static func metadata(for url: URL) throws -> IPAMetadata {
        guard let archive = Archive(url: url, accessMode: .read) else {
            throw appFailure("\(url.lastPathComponent) is not a readable .ipa / zip archive.")
        }

        var infoEntry: Entry?
        var bundleEntries = 0

        for entry in archive {
            let parts = entry.path.split(separator: "/")
            guard parts.count >= 2, parts[0] == "Payload" else { continue }
            bundleEntries += 1
            if parts.count == 3, parts[2] == "Info.plist", entry.path.hasSuffix(".app/Info.plist") {
                infoEntry = entry
                break
            }
        }

        guard bundleEntries > 0 else {
            throw appFailure("\(url.lastPathComponent) has no Payload/ directory — it is not an app IPA.")
        }
        guard let infoEntry else {
            throw appFailure("\(url.lastPathComponent) has no Payload/*.app/Info.plist.")
        }

        var payload = Data()
        _ = try archive.extract(infoEntry) { chunk in payload.append(chunk) }

        guard let plist = try? PropertyListSerialization.propertyList(from: payload, options: [], format: nil),
              let info = plist as? [String: Any] else {
            throw appFailure("Info.plist inside \(url.lastPathComponent) is not a valid property list.")
        }

        let bundleID = (info["CFBundleIdentifier"] as? String) ?? ""
        guard !bundleID.isEmpty else {
            throw appFailure("Info.plist has no CFBundleIdentifier — cannot decrypt this bundle.")
        }

        let appDirectory = infoEntry.path.replacingOccurrences(of: "/Info.plist", with: "")
        let families = (info["UIDeviceFamily"] as? [Int]) ?? (info["UIDeviceFamily"] as? [NSNumber])?.map { $0.intValue } ?? []

        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0

        return IPAMetadata(
            bundleID: bundleID,
            version: (info["CFBundleShortVersionString"] as? String) ?? "?",
            build: (info["CFBundleVersion"] as? String) ?? "?",
            displayName: (info["CFBundleDisplayName"] as? String) ?? (info["CFBundleName"] as? String) ?? bundleID,
            executable: (info["CFBundleExecutable"] as? String) ?? "?",
            minimumOS: (info["MinimumOSVersion"] as? String) ?? "?",
            deviceFamily: families,
            appDirectoryPath: appDirectory,
            infoPlistPath: infoEntry.path,
            fileSize: size
        )
    }

    // MARK: Patch for install

    struct PatchReport {
        var changed: Bool
        var notes: [String] = []
        var outputURL: URL?
    }

    /// Rewrites MinimumOSVersion / UIDeviceFamily and drops Watch content so the
    /// bundle installs on the target device. Returns changed == false when the
    /// source IPA can be used as-is.
    static func patchForInstall(
        source: URL,
        destination: URL,
        deviceVersion: String,
        deviceFamily: Int,
        expandDeviceFamily: Bool
    ) throws -> PatchReport {
        let metadata = try metadata(for: source)
        var report = PatchReport(changed: false)

        var needsMinimumOS = false
        if let minOS = Version(metadata.minimumOS), let device = Version(deviceVersion), minOS > device {
            needsMinimumOS = true
            report.notes.append("MinimumOSVersion \(minOS.text) → \(deviceVersion)")
        }

        var family = metadata.deviceFamily
        var needsFamily = false
        if expandDeviceFamily, deviceFamily != 0, !family.contains(deviceFamily) {
            if family.isEmpty { family = [deviceFamily] } else { family.append(deviceFamily) }
            needsFamily = true
            report.notes.append("UIDeviceFamily \(metadata.deviceFamily) → \(family)")
        }

        let hasWatch = archiveContains(source, prefix: metadata.appDirectoryPath + "/Watch/")
        if hasWatch {
            report.notes.append("stripped Watch/ payload")
        }

        guard needsMinimumOS || needsFamily || hasWatch else {
            return report
        }

        guard let archive = Archive(url: source, accessMode: .read) else {
            throw appFailure("Cannot reopen \(source.lastPathComponent) for patching.")
        }

        let fileManager = FileManager.default
        let staging = fileManager.temporaryDirectory.appendingPathComponent("decryptipa-patch-\(UUID().uuidString)")
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: staging) }

        for entry in archive {
            if entry.path == metadata.appDirectoryPath + "/Watch" ||
                entry.path.hasPrefix(metadata.appDirectoryPath + "/Watch/") {
                continue
            }
            let target = staging.appendingPathComponent(entry.path)
            try archive.extract(entry, to: target, allowUncontainedSymlinks: true)
        }

        let stagedPlist = staging.appendingPathComponent(metadata.infoPlistPath)
        var plistData = try Data(contentsOf: stagedPlist)
        guard var info = try PropertyListSerialization.propertyList(from: plistData, options: [], format: nil) as? [String: Any] else {
            throw appFailure("Staged Info.plist could not be parsed.")
        }

        if needsMinimumOS {
            info["MinimumOSVersion"] = deviceVersion
        }
        if needsFamily {
            info["UIDeviceFamily"] = family
        }

        plistData = try PropertyListSerialization.data(fromPropertyList: info, format: .binary, options: 0)
        try plistData.write(to: stagedPlist)

        try? fileManager.removeItem(at: destination)
        guard let output = Archive(url: destination, accessMode: .create) else {
            throw appFailure("Could not create \(destination.lastPathComponent).")
        }

        let rootPath = staging.standardizedFileURL.path
        guard let enumerator = fileManager.enumerator(atPath: rootPath) else {
            throw appFailure("Could not enumerate the staging directory.")
        }

        var relativePaths: [String] = []
        for case let item as String in enumerator {
            relativePaths.append(item)
        }
        relativePaths.sort()

        for relative in relativePaths {
            let fileURL = staging.appendingPathComponent(relative)
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: fileURL.path, isDirectory: &isDirectory) else { continue }
            try output.addEntry(with: relative, fileURL: fileURL, compressionMethod: isDirectory.boolValue ? .none : .deflate)
        }

        report.changed = true
        report.outputURL = destination
        return report
    }

    private static func archiveContains(_ url: URL, prefix: String) -> Bool {
        guard let archive = Archive(url: url, accessMode: .read) else { return false }
        for entry in archive where entry.path == prefix || entry.path.hasPrefix(prefix) {
            return true
        }
        return false
    }

    // MARK: Verify

    /// A truncated or aborted stream still produces a non-empty file. Opening it
    /// as a zip and finding a Payload bundle is the cheapest real integrity check.
    static func looksComplete(_ url: URL) -> Bool {
        guard let archive = Archive(url: url, accessMode: .read) else { return false }
        var payloadEntries = 0
        for entry in archive {
            if entry.path.hasPrefix("Payload/") {
                payloadEntries += 1
                if payloadEntries > 1 { return true }
            }
        }
        return payloadEntries > 0
    }

    struct VerifyReport {
        var checked = 0
        var plaintext = 0
        var stillEncrypted: [String] = []
        var zeroFilled: [String] = []
        var unreadable: [String] = []

        var ok: Bool { checked > 0 && stillEncrypted.isEmpty && zeroFilled.isEmpty }
    }

    /// Confirms cryptid == 0 on every Mach-O in the produced IPA.
    static func verify(_ url: URL) throws -> VerifyReport {
        guard let archive = Archive(url: url, accessMode: .read) else {
            throw appFailure("Cannot open \(url.lastPathComponent) for verification.")
        }

        var report = VerifyReport()

        for entry in archive where entry.type == .file {
            guard entry.path.hasPrefix("Payload/") else { continue }
            guard entry.uncompressedSize >= 32 else { continue }

            var head = Data()
            do {
                _ = try archive.extract(entry, bufferSize: 64 * 1024, skipCRC32: true) { chunk in
                    head.append(chunk)
                    if head.count >= 64 * 1024 { throw VerificationStop.done }
                }
            } catch VerificationStop.done {
                // expected: we only needed the first chunk
            } catch {
                report.unreadable.append(entry.path)
                continue
            }

            guard let status = MachOAnalyzer.cryptStatus(firstBytes: head) else { continue }
            report.checked += 1

            switch status {
            case .plaintext:
                // cryptid 0 is not proof of decryption: a dump that never fired
                // decrypt-on-fault leaves cryptid 0 over a zero fill. Read the
                // crypt region (bounded) and look for the tell.
                if isCryptRegionZeroFilled(archive: archive, entry: entry, head: head) {
                    report.zeroFilled.append(entry.path)
                } else {
                    report.plaintext += 1
                }
            case .encrypted:
                report.stillEncrypted.append(entry.path)
            }
        }

        return report
    }

    /// Bounded look at the FairPlay crypt region. Only images whose header we
    /// could parse are considered; anything beyond 32 MB of crypt payload is
    /// sampled from the start rather than read whole.
    private static func isCryptRegionZeroFilled(
        archive: Archive,
        entry: Entry,
        head: Data
    ) -> Bool {
        let bytes = [UInt8](head)
        guard let range = MachOAnalyzer.cryptRange(firstBytes: bytes), range.size > 0 else {
            return false
        }
        guard Int64(range.offset) < entry.uncompressedSize else { return false }

        let limit = min(range.size, 8 << 20)
        var region = Data()
        _ = try? archive.extract(entry, bufferSize: 256 * 1024, skipCRC32: true) { chunk in
            region.append(chunk)
            if region.count >= range.offset + limit { throw VerificationStop.done }
        }

        guard region.count >= range.offset + 4096 else { return false }
        let start = range.offset
        let end = min(region.count, start + limit)
        guard start < end else { return false }

        var index = start
        while index < end {
            if region[index] != 0 { return false }
            index += 1
        }
        return true
    }

    private enum VerificationStop: Error {
        case done
    }
}
