import SwiftUI
import UniformTypeIdentifiers

struct DecryptView: View {
    enum InputMode: String, CaseIterable, Identifiable {
        case ipa
        case appStore
        case installed

        var id: String { rawValue }
        var label: String {
            switch self {
            case .ipa: return "IPA file"
            case .appStore: return "App Store"
            case .installed: return "Installed"
            }
        }
    }

    @EnvironmentObject private var store: DeviceStore
    @EnvironmentObject private var library: LibraryStore

    @StateObject private var engine = DecryptEngine()
    // Created only when the App Store sheet is first opened: keeping keychain,
    // UserDefaults and the URLSession out of the launch path.
    @State private var appStoreSession: AppStoreSession?

    @State private var options = DecryptOptions()
    @State private var mode: InputMode = .ipa
    @State private var inputURL: URL?
    @State private var inputMetadata: IPAMetadata?
    @State private var inputError: String?
    @State private var bundleIDText = ""
    @State private var showingImporter = false
    @State private var showingLog = false
    @State private var showingDevices = false
    @State private var showingAppStore = false

    var body: some View {
        NavigationStack {
            Form {
                deviceSection
                inputSection
                optionsSection

                if engine.isRunning || !engine.log.isEmpty {
                    progressSection
                }

                if let url = engine.outputURL {
                    resultSection(url: url)
                }

                actionSection
            }
            .navigationTitle("DecryptIPA")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingLog = true
                    } label: {
                        Image(systemName: "text.alignleft")
                    }
                    .disabled(engine.log.isEmpty)
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showingDevices = true
                    } label: {
                        Image(systemName: "iphone.gen3")
                    }
                }
            }

            .sheet(isPresented: $showingLog) {
                LogSheet(engine: engine)
            }
            .sheet(isPresented: $showingDevices) {
                DevicesView()
            }
            .sheet(isPresented: $showingAppStore) {
                if let session = appStoreSession {
                    AppStoreView(
                        session: session,
                    onUseIPA: { url, _ in
                        inputURL = url
                        inputMetadata = try? IPATool.metadata(for: url)
                    },
                        onUseInstalled: { bundleID in
                            mode = .installed
                            bundleIDText = bundleID
                        }
                    )
                }
            }
            .fileImporter(
                isPresented: $showingImporter,
                allowedContentTypes: [UTType(filenameExtension: "ipa") ?? .data, .zip],
                allowsMultipleSelection: false
            ) { result in
                handleImport(result)
            }
            .onAppear {
                Diagnostics.currentScreen = "decrypt"
                library.refresh()
                Diagnostics.breadcrumb(String(
                    format: "decrypt tab appeared · %d device(s) · %d output(s) · footprint %.1f MB",
                    store.devices.count, library.items.count, Diagnostics.memoryFootprintMB
                ))
            }
            .onDisappear {
                Diagnostics.breadcrumb("decrypt tab disappeared")
            }
            .onChange(of: engine.phase) { _, phase in
                if case .done = phase { library.refresh() }
            }
        }
    }

    // MARK: Sections

    private var deviceSection: some View {
        Section {
            if store.devices.isEmpty {
                Button {
                    showingDevices = true
                } label: {
                    Label("Add a jailbroken device", systemImage: "plus.circle")
                }
            } else {
                Picker("Device", selection: Binding(
                    get: { store.selectedID ?? store.devices.first?.id ?? UUID() },
                    set: { store.selectedID = $0 }
                )) {
                    ForEach(store.devices) { device in
                        Text(device.name).tag(device.id)
                    }
                }
                if let device = store.selected {
                    LabeledValue(label: "Endpoint", value: device.endpoint)
                    LabeledValue(label: "Auth", value: device.auth.label)
                    if device.effectiveUsesSudo {
                        LabeledValue(label: "Privileges", value: "sudo")
                    }
                    if let probe = engine.probe {
                        LabeledValue(label: "Device", value: probe.summary)
                    }
                    if let caps = engine.capabilities {
                        LabeledValue(label: "Tooling", value: caps.summary)
                    }
                }
            }
        } header: {
            Text("Device")
        }
    }

    private var inputSection: some View {
        Section {
            Picker("Source", selection: $mode) {
                ForEach(InputMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            switch mode {
            case .ipa:
                Button {
                    showingImporter = true
                } label: {
                    Label(inputURL == nil ? "Choose .ipa" : "Change .ipa", systemImage: "doc.badge.plus")
                }

                if let url = inputURL {
                    LabeledValue(label: "File", value: url.lastPathComponent)
                    LabeledValue(label: "Size", value: ByteCountFormatter.string(fromByteCount: Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0), countStyle: .file))
                }
                if let metadata = inputMetadata {
                    LabeledValue(label: "Bundle", value: metadata.bundleID)
                    LabeledValue(label: "Version", value: "\(metadata.version) (\(metadata.build))")
                    LabeledValue(label: "MinimumOS", value: metadata.minimumOS)
                    LabeledValue(label: "Families", value: metadata.deviceFamily.isEmpty ? "?" : metadata.deviceFamily.map(String.init).joined(separator: ", "))
                }
                if let inputError {
                    Text(inputError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }

            case .appStore:
                Button {
                    if appStoreSession == nil {
                        appStoreSession = AppStoreSession(outputDirectory: LibraryStore.defaultImportsRoot)
                    }
                    showingAppStore = true
                } label: {
                    Label((appStoreSession?.app == nil) ? "Browse the App Store" : "Open App Store browser",
                          systemImage: "bag")
                }

                if let app = appStoreSession?.app {
                    LabeledValue(label: "App", value: app.name)
                    LabeledValue(label: "Bundle id", value: app.bundleID)
                    LabeledValue(label: "Store version", value: app.version)
                }

                if let ticket = appStoreSession?.ticket {
                    LabeledValue(label: "Ticket", value: "\(ticket.version) · \(ticket.sinfs) sinf")
                }

                if let ipa = appStoreSession?.downloadedIPA {
                    LabeledValue(label: "Downloaded", value: ipa.lastPathComponent)
                    LabeledValue(label: "Size", value: ByteCountFormatter.string(fromByteCount: Int64((try? ipa.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0), countStyle: .file))
                } else {
                    Text("Look up an app by bundle id or App Store id, sign in, and download the encrypted IPA. It is decrypted on the device afterwards.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if appStoreSession?.account == nil {
                    Label("Not signed in — the App Store tab handles sign-in and 2FA.", systemImage: "person.crop.circle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

            case .installed:
                LabeledContent("Bundle id") {
                    TextField("com.example.app", text: $bundleIDText)
                        .multilineTextAlignment(.trailing)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                Text("The app must already be installed on the device. Nothing is uploaded or patched; the helper decrypts the bundle in place.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Input")
        } footer: {
            if mode == .ipa {
                Text("The IPA is installed with appinst so the helper can spawn it and read the decrypted pages. appinst + AppSync Unified are required on the device.")
            }
        }
    }

    private var optionsSection: some View {
        Section("Options") {
            Toggle("Patch Info.plist for this device", isOn: $options.patchForInstall)
            Toggle("Expand UIDeviceFamily if needed", isOn: $options.expandDeviceFamily)
            Toggle("Reinstall when the version differs", isOn: $options.reinstallIfDifferent)
            Toggle("Skip app extensions (appex)", isOn: $options.skipAppex)
            Toggle("Uninstall afterwards (only if this run installed it)", isOn: $options.uninstallAfter)
            Toggle("Verify cryptid in the output", isOn: $options.verifyOutput)
            Toggle("Verbose helper logging", isOn: $options.verboseHelper)
        }
    }

    private var progressSection: some View {
        Section {
            HStack {
                Text(engine.phase.title)
                    .font(.subheadline.weight(.medium))
                Spacer()
                Text(elapsedText(engine.elapsed))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            if engine.isRunning {
                if engine.phase == .uploading {
                    ProgressView(value: min(1, max(0, engine.installProgress)))
                } else {
                    ProgressView()
                        .progressViewStyle(.linear)
                }
            }

            HStack(spacing: 16) {
                Label(ByteCountFormatter.string(fromByteCount: engine.receivedBytes, countStyle: .file), systemImage: "arrow.down.circle")
                Label("\(engine.imagesDone)", systemImage: "lock.open")
                if engine.imagesFailed > 0 {
                    Label("\(engine.imagesFailed)", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
                Spacer()
            }
            .font(.caption)
            .monospacedDigit()

            if let verification = engine.verification {
                if verification.ok {
                    Label("\(verification.plaintext)/\(verification.checked) Mach-O plaintext", systemImage: "checkmark.seal")
                        .font(.caption)
                        .foregroundStyle(.green)
                } else {
                    Label("\(verification.stillEncrypted.count) image(s) still encrypted", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            LogConsole(entries: Array(engine.log.suffix(14)), maxHeight: 180)
                .background(Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 8))
        } header: {
            HStack {
                Text("Progress")
                Spacer()
                Button("Full log") { showingLog = true }
                    .font(.caption)
                    .disabled(engine.log.isEmpty)
            }
        }
    }

    private func resultSection(url: URL) -> some View {
        Section("Result") {
            VStack(alignment: .leading, spacing: 6) {
                Text(url.lastPathComponent)
                    .font(.subheadline.weight(.medium))
                Text("Saved to Documents/Decrypted — visible in the Files app and the Library tab.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ShareLink(item: url) {
                Label("Share / export IPA", systemImage: "square.and.arrow.up")
            }
            Button {
                library.refresh()
            } label: {
                Label("Show in Library", systemImage: "folder")
            }
        }
    }

    private var actionSection: some View {
        Section {
            if engine.isRunning {
                Button(role: .destructive) {
                    engine.cancel()
                } label: {
                    Label("Cancel job", systemImage: "stop.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            } else {
                Button {
                    startJob()
                } label: {
                    Label("Decrypt", systemImage: "lock.open.rotation")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canStart)
            }
        }
    }

    private var canStart: Bool {
        guard store.selected != nil else { return false }
        switch mode {
        case .ipa: return inputURL != nil
        case .appStore: return appStoreSession?.downloadedIPA != nil
        case .installed: return !bundleIDText.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    // MARK: Actions

    private func startJob() {
        Diagnostics.breadcrumb("decrypt button tapped · mode=\(mode.rawValue)")

        guard let device = store.selected else {
            Diagnostics.breadcrumb("decrypt button: no device configured")
            return
        }
        let secrets = store.secrets(for: device)

        // An App Store IPA is FairPlay-encrypted exactly like a local one, so the
        // install-time Info.plist patching applies unchanged.
        let storeIPA = mode == .appStore ? appStoreSession?.downloadedIPA : nil

        Diagnostics.breadcrumb("job: start mode=\(mode.rawValue) device=\(device.endpoint) bundle=\(inputMetadata?.bundleID ?? bundleIDText) ipa=\(inputURL?.lastPathComponent ?? storeIPA?.lastPathComponent ?? "-")")

        let request = DecryptEngine.Request(
            device: device,
            secrets: secrets,
            options: options,
            inputIPA: mode == .ipa ? inputURL : storeIPA,
            bundleIDOverride: mode == .installed ? bundleIDText.trimmingCharacters(in: .whitespaces) : nil,
            outputDirectory: library.root
        )

        Diagnostics.breadcrumb("engine.start returning")
        engine.start(request)
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        inputError = nil
        inputMetadata = nil

        switch result {
        case .failure(let error):
            inputError = error.localizedDescription

        case .success(let urls):
            guard let url = urls.first else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }

            do {
                let copy = try library.importCopy(from: url)
                inputURL = copy
                inputMetadata = try IPATool.metadata(for: copy)
            } catch {
                inputError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                inputURL = nil
            }
        }
    }
}

struct LogSheet: View {
    @ObservedObject var engine: DecryptEngine
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(engine.log) { entry in
                        LogRowView(entry: entry)
                    }
                }
                .padding()
            }
            .navigationTitle("Job log")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .topBarLeading) {
                    ShareLink(item: engine.log.map { "\($0.level.rawValue.uppercased())\t\($0.text)" }.joined(separator: "\n")) {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
            }
        }
    }
}
