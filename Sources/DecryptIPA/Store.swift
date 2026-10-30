import Foundation
import Combine

/// Persisted device list (JSON in Application Support) + keychain secrets.
@MainActor
final class DeviceStore: ObservableObject {
    @Published private(set) var devices: [DeviceProfile] = []
    @Published var selectedID: UUID?

    private let fileURL: URL

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        fileURL = support.appendingPathComponent("devices.json")
        load()
        Diagnostics.breadcrumb("device store: \(devices.count) profile(s)")
    }

    var selected: DeviceProfile? {
        if let selectedID, let match = devices.first(where: { $0.id == selectedID }) { return match }
        return devices.first
    }

    func secrets(for device: DeviceProfile) -> DeviceSecrets {
        Keychain.loadSecrets(for: device.id)
    }

    func saveSecrets(_ secrets: DeviceSecrets, for device: DeviceProfile) {
        Keychain.saveSecrets(secrets, for: device.id)
    }

    func upsert(_ device: DeviceProfile, secrets: DeviceSecrets?) {
        if let index = devices.firstIndex(where: { $0.id == device.id }) {
            devices[index] = device
        } else {
            devices.append(device)
        }
        if let secrets {
            Keychain.saveSecrets(secrets, for: device.id)
        }
        if selectedID == nil { selectedID = device.id }
        persist()
    }

    func delete(_ device: DeviceProfile) {
        devices.removeAll { $0.id == device.id }
        Keychain.deleteSecrets(for: device.id)
        if selectedID == device.id { selectedID = devices.first?.id }
        persist()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([DeviceProfile].self, from: data) else {
            return
        }
        devices = decoded
        selectedID = decoded.first?.id
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(devices) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

/// Decrypted output files, kept in Documents/Decrypted.
@MainActor
final class LibraryStore: ObservableObject {
    struct Item: Identifiable, Hashable {
        var id: String { url.path }
        let url: URL
        let size: Int64
        let modified: Date
        let bundleID: String

        var name: String { url.lastPathComponent }
        var sizeText: String { ByteCountFormatter.string(fromByteCount: size, countStyle: .file) }
    }

    @Published private(set) var items: [Item] = []

    var root: URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let directory = documents.appendingPathComponent("Decrypted")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    var importsRoot: URL { Self.defaultImportsRoot }

    static var defaultImportsRoot: URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let directory = documents.appendingPathComponent("Imports")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    func refresh() {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        )) ?? []

        items = contents
            .filter { $0.pathExtension.lowercased() == "ipa" }
            .compactMap { url in
                let values = try? url.resourceValues(forKeys: Set(keys))
                if values?.isRegularFile == false { return nil }
                let size = Int64(values?.fileSize ?? 0)
                let modified = values?.contentModificationDate ?? Date.distantPast
                return Item(url: url, size: size, modified: modified, bundleID: Self.bundleIDHint(for: url))
            }
            .sorted { $0.modified > $1.modified }
    }

    private static func bundleIDHint(for url: URL) -> String {
        let name = url.deletingPathExtension().lastPathComponent
        let parts = name.split(separator: "_")
        return parts.count > 1 ? String(parts[0]) : name
    }

    func delete(_ item: Item) {
        try? FileManager.default.removeItem(at: item.url)
        refresh()
    }

    func importCopy(from source: URL) throws -> URL {
        let destination = importsRoot.appendingPathComponent(source.lastPathComponent)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.copyItem(at: source, to: destination)
        return destination
    }
}
