import SwiftUI
import UniformTypeIdentifiers

/// The main workflow. A plain ScrollView + small cards deliberately replaces
/// Form/Section composition: the app's idle crash traces showed a runaway
/// allocation while this screen was merely visible. Keeping this tree explicit
/// makes it easy to bisect and cheap to lay out.
struct DecryptView: View {
    enum InputMode: String, CaseIterable, Identifiable {
        case ipa, installed
        var id: String { rawValue }
        var label: String {
            switch self {
            case .ipa: "IPA file"
            case .installed: "Installed"
            }
        }
    }

    @EnvironmentObject private var store: DeviceStore
    @EnvironmentObject private var library: LibraryStore
    @StateObject private var engine = DecryptEngine()

    // Keep account/keychain/URLSession work out of the launch path.
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
    @State private var showingDiagnostics = false

    private let ink = Color(red: 0.92, green: 0.94, blue: 0.98)
    private let canvas = Color(red: 0.055, green: 0.065, blue: 0.085)
    private let accent = Color(red: 0.38, green: 0.58, blue: 1.0)

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    headerCard
                    deviceCard
                    inputCard
                    appStoreCard
                    if engine.isRunning || !engine.log.isEmpty { progressCard }
                    if let url = engine.outputURL { resultCard(url) }
                    optionsCard
                    actionCard
                    footer
                }
                .padding(.horizontal, 16)
                .padding(.top, 10)
                .padding(.bottom, 22)
                .frame(maxWidth: 680)
                .frame(maxWidth: .infinity)
            }
            .background(canvas.ignoresSafeArea())
            .scrollIndicators(.hidden)
            .navigationTitle("DecryptIPA")
            .navigationBarTitleDisplayMode(.inline)
            .tint(accent)
            .toolbarBackground(canvas, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showingDevices = true } label: {
                        Image(systemName: "iphone.gen3")
                    }
                    .accessibilityLabel("Devices")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button { showingDevices = true } label: {
                            Label("Manage devices", systemImage: "iphone.gen3")
                        }
                        Button { showingLog = true } label: {
                            Label("Job log", systemImage: "text.alignleft")
                        }
                        .disabled(engine.log.isEmpty)
                        Divider()
                        Button { showingDiagnostics = true } label: {
                            Label("Diagnostics & crash logs", systemImage: "stethoscope")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .font(.system(size: 20, weight: .medium))
                            .foregroundStyle(accent)
                    }
                    .accessibilityLabel("More actions")
                }
            }
            .sheet(isPresented: $showingLog) { LogSheet(engine: engine) }
            .sheet(isPresented: $showingDevices) { DevicesView() }
            .sheet(isPresented: $showingDiagnostics) { DiagnosticsView() }
            .sheet(isPresented: $showingAppStore) {
                if let session = appStoreSession {
                    AppStoreView(
                        session: session,
                        onUseIPA: { url, _ in
                            inputURL = url
                            inputMetadata = try? IPATool.metadata(for: url)
                            mode = .ipa
                        },
                        onUseInstalled: { id in
                            bundleIDText = id
                            mode = .installed
                        }
                    )
                }
            }
            .fileImporter(
                isPresented: $showingImporter,
                allowedContentTypes: [UTType(filenameExtension: "ipa") ?? .data, .zip],
                allowsMultipleSelection: false,
                onCompletion: handleImport
            )
            .onAppear {
                Diagnostics.currentScreen = "decrypt"
                library.refresh()
                Diagnostics.breadcrumb(String(
                    format: "decrypt tab appeared · %d device(s) · %d output(s) · footprint %.1f MB",
                    store.devices.count, library.items.count, Diagnostics.memoryFootprintMB
                ))
            }
            .onDisappear { Diagnostics.breadcrumb("decrypt tab disappeared") }
            .onChange(of: engine.phase) { _, phase in
                if phase == .done { library.refresh() }
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: Header

    private var headerCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "lock.open.rotation")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 48, height: 48)
                    .background(accent, in: RoundedRectangle(cornerRadius: 15))
                VStack(alignment: .leading, spacing: 4) {
                    Text("Decrypt an app")
                        .font(.title3.weight(.bold))
                        .foregroundStyle(ink)
                    Text("Run ipadecrypt on your connected device")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: 8) {
                StatusPill(
                    title: store.selected?.name ?? "No device",
                    icon: store.selected == nil ? "iphone.slash" : "iphone.gen3",
                    tint: store.selected == nil ? .orange : .green
                )
                if let probe = engine.probe {
                    StatusPill(title: probe.iosVersion, icon: "checkmark.circle.fill", tint: .green)
                }
                Spacer(minLength: 0)
                Button { showingDevices = true } label: {
                    Text(store.selected == nil ? "Set up" : "Change")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .tint(accent)
                .controlSize(.small)
            }
        }
        .padding(16)
        .cardSurface()
        .onAppear { Diagnostics.currentScreen = "decrypt.header" }
    }

    // MARK: Device

    private var deviceCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            CardHeading(title: "DEVICE", subtitle: "Remote jailbroken iPhone", icon: "iphone.gen3")
            if store.devices.isEmpty {
                EmptyHint(text: "Add a device with OpenSSH enabled.", button: "Add device") {
                    showingDevices = true
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
                .tint(accent)
                if let device = store.selected {
                    Divider()
                    InfoLine(label: "Endpoint", value: device.endpoint)
                    InfoLine(label: "Authentication", value: device.auth.label)
                    if let probe = engine.probe { InfoLine(label: "Device", value: probe.summary) }
                    if let caps = engine.capabilities { InfoLine(label: "Tools", value: caps.summary) }
                }
            }
        }
        .padding(16)
        .cardSurface()
        .onAppear { Diagnostics.currentScreen = "decrypt.device" }
    }

    // MARK: Input

    private var inputCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            CardHeading(title: "SOURCE", subtitle: "Choose what to decrypt", icon: "doc.zipper")
            Picker("Source", selection: $mode) {
                ForEach(InputMode.allCases) { item in Text(item.label).tag(item) }
            }
            .pickerStyle(.segmented)

            switch mode {
            case .ipa: ipaInput
            case .installed: installedInput
            }
        }
        .padding(16)
        .cardSurface()
        .onAppear { Diagnostics.currentScreen = "decrypt.input" }
    }

    private var ipaInput: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button { showingImporter = true } label: {
                Label(inputURL == nil ? "Choose an IPA file" : "Choose a different IPA", systemImage: "folder.badge.plus")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.bordered)
            .tint(accent)

            if let metadata = inputMetadata {
                VStack(spacing: 7) {
                    InfoLine(label: "App", value: metadata.displayName)
                    InfoLine(label: "Bundle ID", value: metadata.bundleID)
                    InfoLine(label: "Version", value: "\(metadata.version) (\(metadata.build))")
                    InfoLine(label: "Minimum iOS", value: metadata.minimumOS)
                    InfoLine(label: "IPA size", value: ByteCountFormatter.string(fromByteCount: metadata.fileSize, countStyle: .file))
                }
                .padding(12)
                .background(canvas, in: RoundedRectangle(cornerRadius: 12))
            } else if let inputError {
                Label(inputError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            } else {
                Text("The encrypted IPA is installed on the device, decrypted there, then saved back here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Apple account login/download lives in its own card and sheet, not as an
    /// input mode. The IPA only enters the decrypt flow after the user taps the
    /// explicit "Use downloaded IPA" action in AppStoreView.
    private var appStoreCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            CardHeading(
                title: "APP STORE",
                subtitle: "Apple account & downloads",
                icon: "bag"
            )

            if let account = appStoreSession?.account {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Signed in").font(.subheadline.weight(.semibold))
                        Text(account.email).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(account.country.uppercased())
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("Sign in and browse by App Store ID or bundle ID. Downloads stay separate until you choose to send one to decryption.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let ipa = appStoreSession?.downloadedIPA {
                HStack(spacing: 8) {
                    Image(systemName: "doc.zipper").foregroundStyle(accent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Encrypted IPA ready").font(.subheadline.weight(.semibold))
                        Text(ipa.lastPathComponent).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .padding(10)
                .background(canvas, in: RoundedRectangle(cornerRadius: 12))
            }

            Button {
                if appStoreSession == nil {
                    Diagnostics.breadcrumb("appstore session: init started from dedicated card")
                    appStoreSession = AppStoreSession(outputDirectory: LibraryStore.defaultImportsRoot)
                }
                showingAppStore = true
            } label: {
                Label(appStoreSession?.account == nil ? "Sign in or browse App Store" : "Manage Apple account & apps",
                      systemImage: "arrow.up.forward.square")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.bordered)
            .tint(accent)
        }
        .padding(16)
        .cardSurface()
        .onAppear { Diagnostics.currentScreen = "decrypt.appstore" }
    }

    private var installedInput: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("com.example.app", text: $bundleIDText)
                .font(.body.monospaced())
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .padding(12)
                .background(canvas, in: RoundedRectangle(cornerRadius: 12))
            Text("Decrypts an app that is already installed. Nothing is uploaded.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Progress

    private var progressCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                CardHeading(title: engine.isRunning ? "WORKING" : "LAST JOB", subtitle: nil, icon: "waveform.path")
                Spacer()
                Text(elapsedText(engine.elapsed))
                    .font(.system(.caption, design: .monospaced).weight(.medium))
                    .foregroundStyle(.secondary)
            }
            Text(engine.phase.title)
                .font(.headline)
                .foregroundStyle(ink)

            if engine.isRunning {
                if engine.phase == .uploading {
                    ProgressView(value: min(1, max(0, engine.installProgress)))
                        .tint(accent)
                } else {
                    ProgressView().tint(accent)
                }
            }

            HStack(spacing: 14) {
                MetricPill(value: ByteCountFormatter.string(fromByteCount: engine.receivedBytes, countStyle: .file), label: "received")
                MetricPill(value: "\(engine.imagesDone)", label: "images")
                if engine.imagesFailed > 0 { MetricPill(value: "\(engine.imagesFailed)", label: "failed", tint: .orange) }
            }

            if let report = engine.verification {
                Label(
                    report.ok ? "\(report.plaintext)/\(report.checked) images are plaintext" : "\(report.stillEncrypted.count) images still encrypted",
                    systemImage: report.ok ? "checkmark.seal.fill" : "exclamationmark.triangle.fill"
                )
                .font(.caption.weight(.medium))
                .foregroundStyle(report.ok ? .green : .orange)
            }

            if !engine.log.isEmpty {
                LogConsole(entries: Array(engine.log.suffix(6)), maxHeight: 130)
                    .background(canvas, in: RoundedRectangle(cornerRadius: 12))
            }
            Button("View full log") { showingLog = true }
                .font(.caption.weight(.semibold))
                .buttonStyle(.plain)
                .foregroundStyle(accent)
        }
        .padding(16)
        .cardSurface()
        .onAppear { Diagnostics.currentScreen = "decrypt.progress" }
    }

    // MARK: Result / options / action

    private func resultCard(_ url: URL) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            CardHeading(title: "READY", subtitle: "Decrypted output", icon: "checkmark.seal.fill", tint: .green)
            Text(url.lastPathComponent)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(ink)
                .textSelection(.enabled)
            HStack {
                ShareLink(item: url) { Label("Share IPA", systemImage: "square.and.arrow.up") }
                Spacer()
                Button("Library") { library.refresh() }
            }
            .font(.subheadline.weight(.medium))
            .tint(accent)
        }
        .padding(16)
        .cardSurface()
    }

    private var optionsCard: some View {
        DisclosureGroup {
            Toggle("Patch for this device", isOn: $options.patchForInstall)
            Toggle("Expand device family", isOn: $options.expandDeviceFamily)
            Toggle("Reinstall if version differs", isOn: $options.reinstallIfDifferent)
            Toggle("Skip app extensions", isOn: $options.skipAppex)
            Toggle("Uninstall if this job installed it", isOn: $options.uninstallAfter)
            Toggle("Verify output", isOn: $options.verifyOutput)
            Toggle("Verbose helper log", isOn: $options.verboseHelper)
        } label: {
            CardHeading(title: "OPTIONS", subtitle: "Advanced settings", icon: "slider.horizontal.3")
        }
        .tint(accent)
        .padding(16)
        .cardSurface()
        .onAppear { Diagnostics.currentScreen = "decrypt.options" }
    }

    private var actionCard: some View {
        VStack(spacing: 8) {
            if engine.isRunning {
                Button(role: .destructive) { engine.cancel() } label: {
                    Label("Cancel job", systemImage: "stop.circle.fill")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                }
                .buttonStyle(.borderedProminent)
            } else {
                Button(action: startJob) {
                    Label("Decrypt IPA", systemImage: "lock.open.rotation")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                }
                .buttonStyle(.borderedProminent)
                .tint(accent)
                .disabled(!canStart)
            }
            if !canStart && !engine.isRunning {
                Text(actionHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .cardSurface()
        .onAppear { Diagnostics.currentScreen = "decrypt.action" }
    }

    private var footer: some View {
        HStack(spacing: 5) {
            Image(systemName: "lock.shield")
            Text("SSH credentials stay in the iOS Keychain · Output is unsigned")
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .padding(.vertical, 2)
    }

    private var actionHint: String {
        if store.selected == nil { return "Add a jailbroken device to get started." }
        switch mode {
        case .ipa: return inputURL == nil ? "Choose an encrypted IPA." : "Ready to decrypt on \(store.selected?.name ?? "device")."
        case .installed: return bundleIDText.isEmpty ? "Enter the bundle ID of an installed app." : "Ready to decrypt the installed app."
        }
    }

    private var canStart: Bool {
        guard store.selected != nil else { return false }
        switch mode {
        case .ipa: return inputURL != nil
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
        Diagnostics.breadcrumb("job: start mode=\(mode.rawValue) device=\(device.endpoint) bundle=\(inputMetadata?.bundleID ?? bundleIDText) ipa=\(inputURL?.lastPathComponent ?? "-")")

        let request = DecryptEngine.Request(
            device: device,
            secrets: secrets,
            options: options,
            inputIPA: mode == .ipa ? inputURL : nil,
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
        case .failure(let error): inputError = error.localizedDescription
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

// MARK: - Small visual components

private struct CardHeading: View {
    var title: String
    var subtitle: String?
    var icon: String
    var tint: Color = Color(red: 0.21, green: 0.42, blue: 0.85)

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 30, height: 30)
                .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.caption.weight(.bold)).tracking(0.7).foregroundStyle(.secondary)
                if let subtitle { Text(subtitle).font(.subheadline.weight(.medium)).foregroundStyle(.primary) }
            }
            Spacer(minLength: 0)
        }
    }
}

private struct StatusPill: View {
    var title: String
    var icon: String
    var tint: Color

    var body: some View {
        Label(title, systemImage: icon)
            .font(.caption2.weight(.semibold))
            .lineLimit(1)
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(tint.opacity(0.10), in: Capsule())
            .foregroundStyle(tint)
    }
}

private struct InfoLine: View {
    var label: String
    var value: String
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value)
                .font(.caption.weight(.medium))
                .foregroundStyle(.primary)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
    }
}

private struct MetricPill: View {
    var value: String
    var label: String
    var tint: Color = .secondary
    var body: some View {
        HStack(spacing: 4) {
            Text(value).font(.caption.weight(.bold)).monospacedDigit().foregroundStyle(.primary)
            Text(label).font(.caption2).foregroundStyle(tint)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(Color(uiColor: .secondarySystemBackground), in: Capsule())
    }
}

private struct EmptyHint: View {
    var text: String
    var button: String
    var action: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(text).font(.subheadline).foregroundStyle(.secondary)
            Button(button, action: action).buttonStyle(.bordered).controlSize(.small)
        }
    }
}

private extension View {
    func cardSurface() -> some View {
        self
            .background(Color(red: 0.105, green: 0.12, blue: 0.15), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.06), lineWidth: 1)
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
                    ForEach(engine.log) { LogRowView(entry: $0) }
                }
                .padding()
            }
            .navigationTitle("Job log")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .topBarLeading) {
                    ShareLink(item: engine.log.map { "\($0.level.rawValue.uppercased())\t\($0.text)" }.joined(separator: "\n")) {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
            }
        }
    }
}
