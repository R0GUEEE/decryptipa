import SwiftUI

/// A calm, grouped settings screen: every configuration value the app owns is
/// reachable in one place, with the destructive actions separated at the bottom.
struct SettingsScreen: View {
    @EnvironmentObject private var store: DeviceStore
    @EnvironmentObject private var library: LibraryStore

    @ObservedObject var preferences: Preferences
    @ObservedObject var engine: DecryptEngine
    let session: AppStoreSession?
    let onManageAccount: () -> Void
    let onShowDiagnostics: () -> Void
    let onShowLog: () -> Void
    let onShowLibrary: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var editingDevice: DeviceProfile?
    @State private var addingDevice = false
    @State private var confirmReset = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    devicesCard
                    accountCard
                    decryptionCard
                    outputCard
                    diagnosticsCard
                    aboutCard
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
            }
            .background(Palette.canvas.ignoresSafeArea())
            .scrollIndicators(.hidden)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .font(.callout.weight(.semibold))
                }
            }
            .sheet(isPresented: $addingDevice) {
                DeviceEditor(device: DeviceProfile()) { saved in
                    store.upsert(saved.device, secrets: saved.secrets)
                    store.selectedID = saved.device.id
                }
            }
            .sheet(item: $editingDevice) { device in
                DeviceEditor(device: device) { saved in
                    store.upsert(saved.device, secrets: saved.secrets)
                } onSelect: {
                    store.selectedID = device.id
                }
            }
            .confirmationDialog("Reset decryption options?", isPresented: $confirmReset, titleVisibility: .visible) {
                Button("Reset", role: .destructive) { preferences.resetOptions() }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("Install patching, reinstall, uninstall and verification go back to their defaults. Device profiles and Apple credentials are not touched.")
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: Devices

    private var devicesCard: some View {
        Card {
            SettingGroup(title: "Jailbreak devices", subtitle: "SSH targets that run the helper")

            if store.devices.isEmpty {
                EmptyNote(text: "No device yet. Add the jailbroken iPhone with OpenSSH installed.")
            } else {
                VStack(spacing: 7) {
                    ForEach(store.devices) { device in
                        Button {
                            editingDevice = device
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: store.selected?.id == device.id ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(store.selected?.id == device.id ? Palette.accent : Palette.muted)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(device.name).font(.caption.weight(.semibold)).foregroundStyle(Palette.ink)
                                    Text(device.endpoint).font(.caption2.monospaced()).foregroundStyle(Palette.muted)
                                }
                                Spacer(minLength: 0)
                                Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold)).foregroundStyle(Palette.muted)
                            }
                            .padding(9)
                            .background(Palette.cardRaised, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }

                Button {
                    addingDevice = true
                } label: {
                    Label("Add another device", systemImage: "plus")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .tint(Palette.accent)
            }
        }
    }

    // MARK: Account

    private var accountCard: some View {
        Card {
            SettingGroup(title: "Apple account", subtitle: "Sign-in, two-factor and Anisette")

            if let account = session?.account {
                InfoRow(label: "Signed in", value: account.email)
                InfoRow(label: "Storefront", value: account.storeFront)
            } else {
                EmptyNote(text: "Not signed in. Apple sign-in and Anisette are configured in step 2.")
            }

            Button(action: onManageAccount) {
                Label("Open Apple account", systemImage: "person.crop.circle")
                    .font(.caption.weight(.semibold))
            }
            .buttonStyle(.bordered)
            .tint(Palette.accent)
        }
    }

    // MARK: Decryption

    private var decryptionCard: some View {
        Card {
            SettingGroup(title: "Decryption defaults", subtitle: "Applied to every job")

            optionRow("Patch Info.plist for this device", isOn: $preferences.options.patchForInstall)
            optionRow("Expand device family if needed", isOn: $preferences.options.expandDeviceFamily)
            optionRow("Reinstall when the version differs", isOn: $preferences.options.reinstallIfDifferent)
            optionRow("Skip app extensions (appex)", isOn: $preferences.options.skipAppex)
            optionRow("Uninstall after decrypting", isOn: $preferences.options.uninstallAfter)
            optionRow("Verify cryptid in the output", isOn: $preferences.options.verifyOutput)
            optionRow("Verbose helper logging", isOn: $preferences.options.verboseHelper)

            Button("Reset to defaults") { confirmReset = true }
                .font(.caption2.weight(.semibold))
                .buttonStyle(.plain)
                .foregroundStyle(Palette.muted)
        }
    }

    private func optionRow(_ title: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            Text(title)
                .font(.caption)
                .foregroundStyle(Palette.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
        .tint(Palette.accent)
        .padding(.vertical, 2)
    }

    // MARK: Output

    private var outputCard: some View {
        Card {
            SettingGroup(title: "Output", subtitle: "Where decrypted IPAs land")
            InfoRow(label: "Folder", value: "Documents/Decrypted", mono: true)
            InfoRow(label: "Saved IPAs", value: String(library.items.count))
            HStack(spacing: 8) {
                Button {
                    onShowLibrary()
                } label: {
                    Label("Open library", systemImage: "folder").font(.caption.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .tint(Palette.accent)

                Button {
                    library.refresh()
                } label: {
                    Label("Rescan", systemImage: "arrow.clockwise").font(.caption.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .tint(Palette.muted)
            }
        }
    }

    // MARK: Diagnostics

    private var diagnosticsCard: some View {
        Card {
            SettingGroup(title: "Diagnostics", subtitle: "Logs, memory samples and crash reports")

            Button {
                onShowLog()
            } label: {
                settingsRow("Job log", detail: engine.log.isEmpty ? "empty" : String(engine.log.count) + " entries", icon: "text.alignleft")
            }
            .buttonStyle(.plain)

            Button {
                onShowDiagnostics()
            } label: {
                settingsRow("Crash & memory reports", detail: "last run, previous runs", icon: "stethoscope")
            }
            .buttonStyle(.plain)
        }
    }

    private func settingsRow(_ title: String, detail: String, icon: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Palette.accent)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.caption.weight(.semibold)).foregroundStyle(Palette.ink)
                Text(detail).font(.caption2).foregroundStyle(Palette.muted)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold)).foregroundStyle(Palette.muted)
        }
        .padding(9)
        .background(Palette.cardRaised, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
    }

    // MARK: About

    private var aboutCard: some View {
        Card {
            SettingGroup(title: "About", subtitle: nil)
            InfoRow(label: "Version", value: appVersion, mono: true)
            InfoRow(label: "ipadecrypt helper", value: HelperBinary.sha256Prefix, mono: true)
            InfoRow(label: "Helper size", value: ByteCountFormatter.string(fromByteCount: Int64(HelperBinary.byteCount), countStyle: .file))
            InfoRow(label: "Decryption", value: "on the remote jailbroken device")
        }
    }

    private var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return version + " (" + build + ")"
    }
}

struct SettingGroup: View {
    let title: String
    var subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title.uppercased())
                .font(.caption2.weight(.bold))
                .tracking(0.9)
                .foregroundStyle(Palette.muted)
            if let subtitle {
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(Palette.muted.opacity(0.85))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
