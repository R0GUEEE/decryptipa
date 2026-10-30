import Foundation

/// Property-list decoding that never round-trips bytes through a `String`.
///
/// iOS ships binary plists (`bplist00`); decoding a command's stdout as UTF-8
/// replaces every non-text byte with U+FFFD, which destroys the plist. Anything
/// that reads a plist over SSH must come through here with raw `Data`.
enum PlistSupport {
    static func dictionary(from data: Data) -> [String: Any]? {
        guard !data.isEmpty else { return nil }

        // Binary plists start with "bplist00"; XML ones with "<?xml" or "<plist".
        let header = data.prefix(8)
        let isBinary = header.starts(with: Array("bplist00".utf8))
        let isXML = data.starts(with: Array("<?xml".utf8)) || data.starts(with: Array("<plist".utf8))
        guard isBinary || isXML else { return nil }

        guard let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) else {
            return nil
        }
        return plist as? [String: Any]
    }

    /// Reads `CFBundleShortVersionString`, falling back to `CFBundleVersion`.
    static func version(from data: Data) -> String? {
        guard let info = dictionary(from: data) else { return nil }
        if let version = info["CFBundleShortVersionString"] as? String, !version.isEmpty {
            return version
        }
        if let build = info["CFBundleVersion"] as? String, !build.isEmpty {
            return build
        }
        return nil
    }

    static func bundleIdentifier(from data: Data) -> String? {
        dictionary(from: data)?["CFBundleIdentifier"] as? String
    }
}
