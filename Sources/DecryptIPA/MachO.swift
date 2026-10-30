import Foundation

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
