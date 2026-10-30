import SwiftUI

/// STEP 1 — the jailbroken device this app drives over SSH.
struct ConnectionSection: View {
    @EnvironmentObject private var store: DeviceStore
    @ObservedObject var engine: DecryptEngine

    @State private var editing: DeviceProfile?
    @State private var creating = false
    @State private var testing = false
    @State private var testSummary: String?
    @State private var testFailed = false

    var body: some View {
        Card {
            SectionHeader(
                step: 1,
                title: "Jailbreak connection",
                subtitle: "OpenSSH on the device; appinst + AppSync for installs",
                icon: "iphone.gen3",
                state: store.selected == nil ? .warning : (engine.probe == nil ? .idle : .ready)
            )

            if store.devices.isEmpty {
                EmptyNote(text: "No device configured yet. Add the jailbroken iPhone that will run the ipadecrypt helper.")
                PrimaryButton(title: "Add device", icon: "plus") { creating = true }
            } else {
                VStack(spacing: 8) {
                    ForEach(store.devices) { device in
                        deviceRow(device)
                    }
                }

                HStack(spacing: 8) {
                    Button {
                        creating = true
                    } label: {
                        Label("Add", systemImage: "plus")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                    .tint(Palette.accent)

                    Button {
                        Task { await testConnection() }
                    } label: {
                        HStack(spacing: 6) {
                            if testing { ProgressView().controlSize(.small) }
                            Text(testing ? "Testing…" : "Test connection")
                                .font(.caption.weight(.semibold))
                        }
                    }
                    .buttonStyle(.bordered)
                    .tint(Palette.muted)
                    .disabled(testing || store.selected == nil)

                    Spacer(minLength: 0)
                }

                if let summary = testSummary {
                    HStack(alignment: .top, spacing: 7) {
                        Image(systemName: testFailed ? "exclamationmark.triangle.fill" : "checkmark.seal.fill")
                            .font(.system(size: 12))
                        Text(summary)
                            .font(.caption)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .foregroundStyle(testFailed ? Palette.warning : Palette.success)
                }
            }
        }
        .sheet(isPresented: $creating) {
            DeviceEditor(device: DeviceProfile()) { saved in
                store.upsert(saved.device, secrets: saved.secrets)
                store.selectedID = saved.device.id
                testSummary = nil
            }
        }
        .sheet(item: $editing) { device in
            DeviceEditor(device: device) { saved in
                store.upsert(saved.device, secrets: saved.secrets)
            } onSelect: {
                store.selectedID = device.id
                testSummary = nil
            }
        }
    }

    private func deviceRow(_ device: DeviceProfile) -> some View {
        let isSelected = store.selected?.id == device.id
        return Button {
            store.selectedID = device.id
            testSummary = nil
            editing = device
        } label: {
            HStack(spacing: 11) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(isSelected ? Palette.accent : Palette.muted)

                VStack(alignment: .leading, spacing: 2) {
                    Text(device.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Palette.ink)
                    Text(device.endpoint + " · " + device.auth.label)
                        .font(.caption2)
                        .foregroundStyle(Palette.muted)
                }

                Spacer(minLength: 0)

                if isSelected {
                    StatusPill(text: "active", tint: Palette.accent)
                }
            }
            .padding(11)
            .background(Palette.cardRaised, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func testConnection() async {
        guard let device = store.selected else { return }
        testing = true
        testSummary = nil
        testFailed = false
        Diagnostics.breadcrumb("device test: start " + device.endpoint)

        do {
            let transport = try await SSHTransport.connect(profile: device, secrets: store.secrets(for: device))
            defer { Task { await transport.close() } }
            let service = DeviceService(transport: transport)
            let probe = try await service.probe()
            let appinst = try await service.locateAppinst()
            let appSync = try await service.locateAppSync()

            var parts = [probe.summary]
            parts.append(appinst == nil ? "appinst missing" : "appinst ready")
            parts.append(appSync == nil ? "AppSync missing" : "AppSync ready")
            testSummary = parts.joined(separator: " · ")
            testFailed = appinst == nil || appSync == nil
        } catch {
            testSummary = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            testFailed = true
        }

        testing = false
    }
}
