import Foundation
import ZIPFoundation

// MARK: - Metadata

enum IPATool {
    /// Reads the app bundle metadata out of an IPA without unpacking it.
    static func metadata(for url: URL) throws -> IPAMetadata {
        guard let archive = Archive(url: url, accessMode: .read) else {
            throw err("\(url.lastPathComponent) is not a readable .ipa / zip archive.")
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
            throw err("\(url.lastPathComponent) has no Payload/ directory — it is not an app IPA.")
        }
        guard let infoEntry else {
            throw err("\(url.lastPathComponent) has no Payload/*.app/Info.plist.")
        }

        var payload = Data()
        _ = try archive.extract(infoEntry) { chunk in payload.append(chunk) }

        guard let plist = try? PropertyListSerialization.propertyList(from: payload, options: [], format: nil),
              let info = plist as? [String: Any] else {
            throw err("Info.plist inside \(url.lastPathComponent) is not a valid property list.")
        }

        let bundleID = (info["CFBundleIdentifier"] as? String) ?? ""
        guard !bundleID.isEmpty else {
            throw err("Info.plist has no CFBundleIdentifier — cannot decrypt this bundle.")
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
            throw err("Cannot reopen \(source.lastPathComponent) for patching.")
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
            throw err("Staged Info.plist could not be parsed.")
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
            throw err("Could not create \(destination.lastPathComponent).")
        }

        let rootPath = staging.standardizedFileURL.path
        guard let enumerator = fileManager.enumerator(atPath: rootPath) else {
            throw err("Could not enumerate the staging directory.")
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

    struct VerifyReport {
        var checked = 0
        var plaintext = 0
        var stillEncrypted: [String] = []
        var unreadable: [String] = []

        var ok: Bool { checked > 0 && stillEncrypted.isEmpty }
    }

    /// Confirms cryptid == 0 on every Mach-O in the produced IPA.
    static func verify(_ url: URL) throws -> VerifyReport {
        guard let archive = Archive(url: url, accessMode: .read) else {
            throw err("Cannot open \(url.lastPathComponent) for verification.")
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
                report.plaintext += 1
            case .encrypted:
                report.stillEncrypted.append(entry.path)
            }
        }

        return report
    }

    private enum VerificationStop: Error {
        case done
    }
}

// MARK: - Mach-O

enum MachOCryptStatus {
    case plaintext
    case encrypted
}

enum MachOAnalyzer {
    static func cryptStatus(firstBytes data: Data) -> MachOCryptStatus? {
        guard data.count >= 28 else { return nil }
        let bytes = [UInt8](data.prefix(64 * 1024))

        let magicLE = readUInt32(bytes, 0, littleEndian: true)
        let magicBE = readUInt32(bytes, 0, littleEndian: false)

        // Thin Mach-O
        if magicLE == 0xFEEDFACF {
            return thinStatus(bytes, offset: 0, is64: true)
        }
        if magicLE == 0xFEEDFACE {
            return thinStatus(bytes, offset: 0, is64: false)
        }
        if magicBE == 0xFEEDFACF {
            return thinStatusBE(bytes, offset: 0, is64: true)
        }
        if magicBE == 0xFEEDFACE {
            return thinStatusBE(bytes, offset: 0, is64: false)
        }

        // FAT (big-endian header, 0xCAFEBABE)
        if magicBE == 0xCAFEBABE, bytes.count >= 8 {
            let count = Int(readUInt32(bytes, 4, littleEndian: false))
            var encrypted = false
            var parsedAny = false
            for index in 0..<max(0, min(count, 32)) {
                let base = 8 + index * 20
                guard base + 20 <= bytes.count else { break }
                let offset = Int(readUInt32(bytes, base + 8, littleEndian: false))
                guard offset > 0, offset + 32 <= bytes.count else { continue }
                let magic = readUInt32(bytes, offset, littleEndian: true)
                if magic == 0xFEEDFACF {
                    if let status = thinStatus(bytes, offset: offset, is64: true) {
                        parsedAny = true
                        if case .encrypted = status { encrypted = true }
                    }
                } else if magic == 0xFEEDFACE {
                    if let status = thinStatus(bytes, offset: offset, is64: false) {
                        parsedAny = true
                        if case .encrypted = status { encrypted = true }
                    }
                }
            }
            guard parsedAny else { return nil }
            return encrypted ? .encrypted : .plaintext
        }

        return nil
    }

    private static func thinStatus(_ bytes: [UInt8], offset: Int, is64: Bool) -> MachOCryptStatus? {
        let headerSize = is64 ? 32 : 28
        guard offset + headerSize <= bytes.count else { return nil }
        let ncmds = Int(readUInt32(bytes, offset + 16, littleEndian: true))
        var cursor = offset + headerSize
        var foundCryptCommand = false
        var encrypted = false

        for _ in 0..<max(0, min(ncmds, 4096)) {
            guard cursor + 8 <= bytes.count else { break }
            let cmd = readUInt32(bytes, cursor, littleEndian: true)
            let size = Int(readUInt32(bytes, cursor + 4, littleEndian: true))
            guard size >= 8 else { break }
            if cmd == 0x2C || cmd == 0x21 { // LC_ENCRYPTION_INFO_64 / LC_ENCRYPTION_INFO
                guard cursor + 20 <= bytes.count else { return foundCryptCommand ? (encrypted ? .encrypted : .plaintext) : nil }
                let cryptid = readUInt32(bytes, cursor + 16, littleEndian: true)
                foundCryptCommand = true
                if cryptid != 0 { encrypted = true }
            }
            cursor += size
        }

        guard foundCryptCommand else { return .plaintext }
        return encrypted ? .encrypted : .plaintext
    }

    private static func thinStatusBE(_ bytes: [UInt8], offset: Int, is64: Bool) -> MachOCryptStatus? {
        let headerSize = is64 ? 32 : 28
        guard offset + headerSize <= bytes.count else { return nil }
        let ncmds = Int(readUInt32(bytes, offset + 16, littleEndian: false))
        var cursor = offset + headerSize
        var foundCryptCommand = false
        var encrypted = false

        for _ in 0..<max(0, min(ncmds, 4096)) {
            guard cursor + 8 <= bytes.count else { break }
            let cmd = readUInt32(bytes, cursor, littleEndian: false)
            let size = Int(readUInt32(bytes, cursor + 4, littleEndian: false))
            guard size >= 8 else { break }
            if cmd == 0x2C || cmd == 0x21 {
                guard cursor + 20 <= bytes.count else { return foundCryptCommand ? (encrypted ? .encrypted : .plaintext) : nil }
                let cryptid = readUInt32(bytes, cursor + 16, littleEndian: false)
                foundCryptCommand = true
                if cryptid != 0 { encrypted = true }
            }
            cursor += size
        }

        guard foundCryptCommand else { return .plaintext }
        return encrypted ? .encrypted : .plaintext
    }

    private static func readUInt32(_ bytes: [UInt8], _ offset: Int, littleEndian: Bool) -> UInt32 {
        guard offset + 4 <= bytes.count else { return 0 }
        let b0 = UInt32(bytes[offset])
        let b1 = UInt32(bytes[offset + 1]) << 8
        let b2 = UInt32(bytes[offset + 2]) << 16
        let b3 = UInt32(bytes[offset + 3]) << 24
        let value = b0 | b1 | b2 | b3
        return littleEndian ? value : value.byteSwapped
    }
}

// MARK: - Version

struct Version: Comparable, CustomStringConvertible {
    let parts: [Int]
    let text: String

    init?(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let numeric = trimmed.split(separator: ".").map { component -> Int in
            Int(component.prefix(while: { $0.isNumber })) ?? 0
        }
        guard !numeric.isEmpty else { return nil }
        self.parts = numeric
        self.text = trimmed
    }

    var description: String { text }

    static func < (lhs: Version, rhs: Version) -> Bool {
        let count = max(lhs.parts.count, rhs.parts.count)
        for index in 0..<count {
            let left = index < lhs.parts.count ? lhs.parts[index] : 0
            let right = index < rhs.parts.count ? rhs.parts[index] : 0
            if left != right { return left < right }
        }
        return false
    }

    static func == (lhs: Version, rhs: Version) -> Bool {
        !(lhs < rhs) && !(rhs < lhs)
    }
}
