import SwiftUI

/// Three-step flow: connect, authorize, decrypt. One job per screen, a fixed
/// action bar, and all configuration in Settings.
struct RootScreen: View {
    @EnvironmentObject private var store: DeviceStore
    @EnvironmentObject private var library: LibraryStore

    @StateObject private var engine = DecryptEngine()
    @StateObject private var preferences = Preferences()
    @State private var appStore: AppStoreSession?

    @State private var step = 1
    @State private var source: AppSection.Source = .appStore
    @State private var inputURL: URL?
    @State private var inputMetadata: IPAMetadata?
    @State private var bundleIDText = ""

    @State private var showingSettings = false
    @State private var showingLog = false
    @State private var showingDiagnostics = false
    @State private var showingLibrary = false

    private let titles = ["Connect", "Apple ID", "Decrypt"]

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                stepBar
                ScrollView {
                    VStack(spacing: 14) {
                        activeStep
                        footer
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 18)
                    .frame(maxWidth: 700)
                    .frame(maxWidth: .infinity)
                }
                .scrollIndicators(.hidden)
                actionBar
            }
            .background(Palette.canvas.ignoresSafeArea())
            .navigationTitle("DecryptIPA")
            .navigationBarTitleDisplayMode(.inline)
            .tint(Palette.accent)
            .toolbarBackground(Palette.canvas, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showingLibrary = true } label: {
                        Image(systemName: "folder")
                    }
                    .accessibilityLabel("Decrypted library")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showingSettings = true } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("Settings")
                }
            }
            .sheet(isPresented: $showingSettings) { settingsSheet }
            .sheet(isPresented: $showingLog) { LogSheet(engine: engine) }
            .sheet(isPresented: $showingDiagnostics) { DiagnosticsView() }
            .sheet(isPresented: $showingLibrary) { LibraryView() }
            .onAppear(perform: prepare)
            .onChange(of: step) { _, value in preferences.lastStep = value }
            .onChange(of: source) { _, value in preferences.preferredSource = value.rawValue }
            .onChange(of: engine.phase) { _, phase in
                if phase == .done { library.refresh() }
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: Steps

    private var stepBar: some View {
        HStack(spacing: 6) {
            ForEach(1...3, id: \.self) { index in
                Button {
                    step = index
                } label: {
                    VStack(spacing: 5) {
                        HStack(spacing: 5) {
                            ZStack {
                                Circle()
                                    .fill(step >= index ? Palette.accent : Palette.cardRaised)
                                    .frame(width: 20, height: 20)
                                if step > index {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 9, weight: .black))
                                        .foregroundStyle(.white)
                                } else {
                                    Text(String(index))
                                        .font(.system(size: 10, weight: .bold))
                                        .foregroundStyle(step == index ? .white : Palette.muted)
                                }
                            }
                            Text(titles[index - 1])
                                .font(.caption2.weight(step == index ? .bold : .medium))
                                .foregroundStyle(step == index ? Palette.ink : Palette.muted)
                                .lineLimit(1)
                        }
                        Rectangle()
                            .fill(step == index ? Palette.accent : Color.white.opacity(0.06))
                            .frame(height: 2)
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 2)
    }

    @ViewBuilder
    private var activeStep: some View {
        switch step {
        case 1:
            ConnectionSection(engine: engine)
            stepNote(
                "DecryptIPA connects to this device over SSH, installs the app there with appinst, and runs the ipadecrypt helper on it."
            )
        case 2:
            if let appStore {
                AccountSection(session: appStore, onUseInstalled: { source = .installed; step = 3 })
                stepNote(
                    "The Apple ID is only needed to download an app from the App Store. Decrypting an IPA you already have, or an app already installed on the device, needs no account."
                )
            } else {
                loadingCard
            }
        default:
            if let appStore {
                AppSection(
                    engine: engine,
                    session: appStore,
                    source: $source,
                    inputURL: $inputURL,
                    inputMetadata: $inputMetadata,
                    bundleIDText: $bundleIDText,
                    canDecrypt: canDecrypt,
                    onDecrypt: startJob,
                    onCancel: { engine.cancel() }
                )
            } else {
                loadingCard
            }
        }
    }

    private func stepNote(_ text: String) -> some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(Palette.muted)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 12)
    }

    private var loadingCard: some View {
        Card {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Preparing Apple account module…")
                    .font(.caption)
                    .foregroundStyle(Palette.muted)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 5) {
            Image(systemName: "lock.shield")
            Text("Credentials stay in the iOS Keychain · output IPAs are unsigned")
        }
        .font(.caption2)
        .foregroundStyle(Palette.muted)
        .padding(.top, 4)
    }

    // MARK: Bottom action

    @ViewBuilder
    private var actionBar: some View {
        if step < 3 {
            HStack(spacing: 10) {
                if step == 2 {
                    QuietButton(title: "Skip", icon: "arrow.right") { step = 3 }
                        .frame(maxWidth: 110)
                }
                PrimaryButton(
                    title: step == 1 ? "Continue to Apple ID" : "Continue to decrypt",
                    icon: "arrow.right",
                    enabled: step == 1 ? store.selected != nil : true
                ) {
                    step += 1
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 8)
            .background(Palette.canvas)
        } else {
            HStack(spacing: 10) {
                Button {
                    step = 2
                } label: {
                    Label("Account", systemImage: "chevron.left")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .tint(Palette.muted)

                Button {
                    showingSettings = true
                } label: {
                    Label("Settings", systemImage: "gearshape")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .tint(Palette.muted)
                Spacer(minLength: 0)
                if engine.isRunning {
                    StatusPill(text: engine.phase.title, tint: Palette.accent, symbol: "waveform")
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 6)
            .background(Palette.canvas)
        }
    }

    private var settingsSheet: some View {
        SettingsScreen(
            preferences: preferences,
            engine: engine,
            session: appStore,
            onManageAccount: {
                showingSettings = false
                step = 2
            },
            onShowDiagnostics: {
                showingSettings = false
                showingDiagnostics = true
            },
            onShowLog: {
                showingSettings = false
                showingLog = true
            },
            onShowLibrary: {
                showingSettings = false
                showingLibrary = true
            }
        )
        .environmentObject(store)
        .environmentObject(library)
    }

    // MARK: Lifecycle

    private func prepare() {
        Diagnostics.setScreen("root")
        if appStore == nil {
            appStore = AppStoreSession(outputDirectory: LibraryStore.defaultImportsRoot)
        }
        library.refresh()

        if let restored = AppSection.Source(rawValue: preferences.preferredSource) {
            source = restored
        }
        if preferences.lastStep >= 1, preferences.lastStep <= 3 {
            step = preferences.lastStep
        } else {
            step = store.devices.isEmpty ? 1 : 2
        }

        Diagnostics.breadcrumb(String(
            format: "root appeared · step=%d · %d device(s) · %d output(s) · footprint %.1f MB",
            step, store.devices.count, library.items.count, Diagnostics.memoryFootprintMB
        ))
    }

    // MARK: Job

    private var canDecrypt: Bool {
        guard store.selected != nil else { return false }
        switch source {
        case .appStore: return appStore?.downloadedIPA != nil
        case .file: return inputURL != nil
        case .installed: return !bundleIDText.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    private func startJob() {
        Diagnostics.breadcrumb("decrypt button tapped · source=" + source.rawValue)
        guard let device = store.selected else {
            Diagnostics.breadcrumb("decrypt button: no device configured")
            step = 1
            return
        }

        let storeIPA = source == .appStore ? appStore?.downloadedIPA : nil
        let ipa = source == .file ? inputURL : storeIPA
        Diagnostics.breadcrumb("job: start source=" + source.rawValue + " device=" + device.endpoint)

        engine.start(DecryptEngine.Request(
            device: device,
            secrets: store.secrets(for: device),
            options: preferences.options,
            inputIPA: ipa,
            bundleIDOverride: source == .installed ? bundleIDText.trimmingCharacters(in: .whitespaces) : nil,
            outputDirectory: library.root
        ))
    }
}
