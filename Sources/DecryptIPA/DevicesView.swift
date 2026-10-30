import SwiftUI

struct DevicesView: View {
    @EnvironmentObject private var store: DeviceStore

    @State private var editing: DeviceProfile?
    @State private var creating = false

    var body: some View {
        NavigationStack {
            List {
                if store.devices.isEmpty {
                    Section {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("No devices yet").font(.headline)
                            Text("Add the jailbroken iPhone you want to decrypt on. It needs OpenSSH (root login), AppSync Unified and appinst.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 6)
                    }
                }

                ForEach(store.devices) { device in
                    Button {
                        editing = device
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(device.name).font(.body.weight(.medium))
                                if store.selected?.id == device.id {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.tint)
                                }
                            }
                            Text("\(device.endpoint) · \(device.auth.label)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .swipeActions {
                        Button(role: .destructive) {
                            store.delete(device)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            }
            .navigationTitle("Devices")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        creating = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $creating) {
                DeviceEditor(device: DeviceProfile()) { saved in
                    store.upsert(saved.device, secrets: saved.secrets)
                    store.selectedID = saved.device.id
                }
            }
            .sheet(item: $editing) { device in
                DeviceEditor(device: device) { saved in
                    store.upsert(saved.device, secrets: saved.secrets)
                } onSelect: {
                    store.selectedID = device.id
                }
            }
        }
    }
}

struct DeviceEditor: View {
    struct Saved {
        var device: DeviceProfile
        var secrets: DeviceSecrets
    }

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: DeviceStore

    @State private var device: DeviceProfile
    @State private var secrets: DeviceSecrets = DeviceSecrets()
    @State private var testing = false
    @State private var testLines: [String] = []
    @State private var showingKey = false

    let onSave: (Saved) -> Void
    var onSelect: (() -> Void)? = nil

    init(device: DeviceProfile, onSave: @escaping (Saved) -> Void, onSelect: (() -> Void)? = nil) {
        _device = State(initialValue: device)
        self.onSave = onSave
        self.onSelect = onSelect
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Identity") {
                    TextField("Name", text: $device.name)
                    LabeledContent("Bundle-safe host") {
                        TextField("192.168.1.50", text: $device.host)
                            .multilineTextAlignment(.trailing)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                    }
                    LabeledContent("Port") {
                        TextField("22", value: $device.port, format: .number)
                            .multilineTextAlignment(.trailing)
                            .keyboardType(.numberPad)
                    }
                    LabeledContent("User") {
                        TextField("root", text: $device.username)
                            .multilineTextAlignment(.trailing)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                }

                Section("Authentication") {
                    Picker("Method", selection: $device.auth) {
                        ForEach(AuthKind.allCases) { kind in
                            Text(kind.label).tag(kind)
                        }
                    }
                    .pickerStyle(.segmented)

                    switch device.auth {
                    case .password:
                        SecureField("SSH password", text: $secrets.password)
                            .textContentType(.password)
                    case .ed25519:
                        if showingKey {
                            TextEditor(text: $secrets.privateKey)
                                .frame(minHeight: 120)
                                .font(.system(.caption, design: .monospaced))
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                        } else {
                            Button("Paste private key…") { showingKey = true }
                            if !secrets.privateKey.isEmpty {
                                Text("\(secrets.privateKey.count) characters loaded")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        SecureField("Key passphrase (optional)", text: $secrets.keyPassphrase)
                    }
                }

                if device.username != "root" {
                    Section {
                        Toggle("Run privileged commands with sudo", isOn: Binding(
                            get: { device.usesSudo ?? true },
                            set: { device.usesSudo = $0 }
                        ))
                        if device.usesSudo ?? true {
                            SecureField("sudo password", text: $secrets.sudoPassword)
                            Text("The password is written to a 0600 file on the device for the duration of a job, then removed.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } header: {
                        Text("Privileges")
                    }
                }

                Section {
                    Button {
                        Task { await test() }
                    } label: {
                        HStack {
                            if testing { ProgressView().controlSize(.small) }
                            Text(testing ? "Testing…" : "Test connection")
                        }
                    }
                    .disabled(testing || device.host.isEmpty)

                    ForEach(Array(testLines.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Diagnostics")
                } footer: {
                    Text("The device must expose OpenSSH on the network. Root login with the default alpine password works on most jailbreaks.")
                }
            }
            .navigationTitle(device.name.isEmpty ? "New device" : device.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(Saved(device: device, secrets: secrets))
                        dismiss()
                    }
                    .disabled(device.host.isEmpty)
                }
                if onSelect != nil {
                    ToolbarItem(placement: .bottomBar) {
                        Button("Use this device") {
                            onSelect?()
                            dismiss()
                        }
                    }
                }
            }
            .onAppear {
                secrets = store.secrets(for: device)
                if device.auth == .ed25519 { showingKey = !secrets.privateKey.isEmpty }
            }
        }
    }

    private func test() async {
        Diagnostics.breadcrumb("device test: start \(device.endpoint)")
        testing = true
        testLines = ["Connecting to \(device.endpoint)…"]

        do {
            let transport = try await SSHTransport.connect(profile: device, secrets: secrets)
            let service = DeviceService(transport: transport)

            let probe = try await service.probe()
            testLines.append("Device: \(probe.summary)")

            let appinst = try await service.locateAppinst()
            testLines.append(appinst == nil ? "appinst: not found" : "appinst: \(appinst!)")

            let appSync = try await service.locateAppSync()
            testLines.append(appSync == nil ? "AppSync Unified: not found" : "AppSync: \(appSync!)")

            let helper = try await service.ensureHelper()
            testLines.append("helper: \(helper)")

            testLines.append("Ready for decryption.")

            await transport.close()
        } catch {
            testLines.append((error as? LocalizedError)?.errorDescription ?? "\(error)")
        }

        testing = false
    }
}
