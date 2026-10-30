import Foundation

// Self-checks for the logic that cannot be exercised without a device:
// Mach-O cryptid parsing (LC_ENCRYPTION_INFO / LC_ENCRYPTION_INFO_64, thin and
// fat), the helper's @evt parser, and the version comparator used to decide
// between "already installed" and "install this IPA".

var failures = 0

func check(_ condition: Bool, _ label: String) {
    if condition {
        print("  ok   \(label)")
    } else {
        print("  FAIL \(label)")
        failures += 1
    }
}

// MARK: - Mach-O fixtures

func be32(_ value: UInt32) -> [UInt8] {
    [UInt8(value >> 24 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)]
}

func le32(_ value: UInt32) -> [UInt8] {
    Array(be32(value).reversed())
}

func le64(_ value: UInt64) -> [UInt8] {
    (0..<8).map { UInt8((value >> (8 * UInt64($0))) & 0xFF) }
}

/// Builds a thin 64-bit Mach-O with a single LC_ENCRYPTION_INFO_64 command.
func thin64(cryptid: UInt32, extraCommands: [(UInt32, [UInt8])] = []) -> Data {
    var body: [UInt8] = []
    var commandCount: UInt32 = 0

    for (kind, payload) in extraCommands {
        let size = UInt32(8 + payload.count)
        body += le32(kind) + le32(size) + payload
        commandCount += 1
    }

    let cryptSize = UInt32(16)
    body += le32(0x2C) + le32(cryptSize) + le32(0x4000) + le32(0x8000) + le32(cryptid) + le32(0)
    commandCount += 1

    var header: [UInt8] = []
    header += le32(0xFEEDFACF)      // magic
    header += le32(0x0100000C)      // cputype arm64
    header += le32(0x00000002)      // cpusubtype
    header += le32(0x00000006)      // filetype MH_DYLIB
    header += le32(commandCount)
    header += le32(UInt32(body.count))
    header += le32(0x00200085)      // flags
    header += le32(0)
    header += le64(0x100000000)

    let total = UInt32(header.count + body.count)
    var padded = header + body
    while padded.count < 512 { padded.append(0) }
    check(total <= 512, "fixture header size fits")
    return Data(padded)
}

/// Builds a 32-bit (LE) Mach-O with LC_ENCRYPTION_INFO.
func thin32(cryptid: UInt32) -> Data {
    var body: [UInt8] = []
    body += le32(0x21) + le32(20) + le32(0x4000) + le32(0x8000) + le32(cryptid)

    var header: [UInt8] = []
    header += le32(0xFEEDFACE)
    header += le32(0x0000000C)
    header += le32(0x00000000)
    header += le32(0x00000002)
    header += le32(1)
    header += le32(UInt32(body.count))
    header += le32(0)

    var padded = header + body
    while padded.count < 512 { padded.append(0) }
    return Data(padded)
}

/// FAT header wrapping the two thin images above.
func fat(_ slices: [Data]) -> Data {
    var header: [UInt8] = []
    header += be32(0xCAFEBABE)
    header += be32(UInt32(slices.count))

    var dataOffset = 4096
    var offsets: [Int] = []
    for _ in slices {
        offsets.append(dataOffset)
        dataOffset += 4096
    }

    for (index, slice) in slices.enumerated() {
        header += be32(0x0100000C)
        header += be32(0x00000002)
        header += be32(UInt32(offsets[index]))
        header += be32(UInt32(slice.count))
        header += be32(12)
    }

    var out = header
    for (index, slice) in slices.enumerated() {
        while out.count < offsets[index] { out.append(0) }
        out += [UInt8](slice)
    }
    return Data(out)
}

print("Mach-O cryptid parsing")
check(MachOAnalyzer.cryptStatus(firstBytes: thin64(cryptid: 1)) == .encrypted, "thin arm64 cryptid=1 → encrypted")
check(MachOAnalyzer.cryptStatus(firstBytes: thin64(cryptid: 0)) == .plaintext, "thin arm64 cryptid=0 → plaintext")
check(MachOAnalyzer.cryptStatus(firstBytes: thin32(cryptid: 1)) == .encrypted, "thin armv7 cryptid=1 → encrypted")
check(MachOAnalyzer.cryptStatus(firstBytes: thin32(cryptid: 0)) == .plaintext, "thin armv7 cryptid=0 → plaintext")
check(MachOAnalyzer.cryptStatus(firstBytes: fat([thin32(cryptid: 1), thin64(cryptid: 1)])) == .encrypted,
      "fat with one encrypted slice → encrypted")
check(MachOAnalyzer.cryptStatus(firstBytes: fat([thin32(cryptid: 0), thin64(cryptid: 0)])) == .plaintext,
      "fat with plaintext slices → plaintext")
check(MachOAnalyzer.cryptStatus(firstBytes: Data("not a mach-o at all".utf8)) == nil, "garbage → not Mach-O")

// A Mach-O with a large LC_SEGMENT before the encryption command must still be
// parsed: the parser walks by cmdsize, not by fixed offset.
let bigSegment = Data(repeating: 0, count: 400)
check(MachOAnalyzer.cryptStatus(firstBytes: thin64(cryptid: 1, extraCommands: [(0x19, [UInt8](bigSegment))])) == .encrypted,
      "encryption command after a large LC_SEGMENT_64 is found")

print("Version comparison")
check(Version("1.2")! < Version("1.10")!, "1.2 < 1.10 (numeric, not lexicographic)")
check(Version("16.7.11")! > Version("16.7.2")!, "16.7.11 > 16.7.2")
check(Version("1.0")! == Version("1.0.0")!, "1.0 == 1.0.0")
check(Version("17")! == Version("17.0.0")!, "17 == 17.0.0")
check(Version("") == nil, "empty version rejected")
check(Version("abc") == nil, "non-numeric version rejected")

print("Helper @evt parsing")
let done = EventParser.parse("@evt event=done level=info msg=\"decrypted 3 images\" count=3")
check(done?["event"] == "done", "event name parsed")
check(done?["msg"] == "decrypted 3 images", "quoted message parsed")
check(done?["count"] == "3", "numeric attribute parsed")

let imageDone = EventParser.parse("@evt event=image.done level=info msg=\"decrypted Frameworks/A.framework/A (2.1 MB)\" name=Frameworks/A.framework/A kind=framework size=2100000")
check(imageDone?["name"] == "Frameworks/A.framework/A", "image path parsed")
check(imageDone?["size"] == "2100000", "image size parsed")

check(EventParser.parse("plain helper output") == nil, "non-event line ignored")
check(EventParser.parse("@evt level=info msg=missing-name") == nil, "event without a name ignored")

print("")
if failures == 0 {
    print("all checks passed")
} else {
    print("\(failures) check(s) failed")
    exit(1)
}
