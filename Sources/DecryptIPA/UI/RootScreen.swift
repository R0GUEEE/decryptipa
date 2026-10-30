import SwiftUI

/// The rebuilt workflow: four explicit stages, top to bottom.
struct RootScreen: View {
    @EnvironmentObject private var store: DeviceStore
    @EnvironmentObject private var library: LibraryStore

    @StateObject private var engine = DecryptEngine()
    @State private var appStore: AppStoreSession?

    @State private var source: AppSection.Source = .appStore
    @State private var inputURL: URL?
    @State private var inputMetadata: IPAMetadata?
    @State private var bundleIDText = ""
    @State private var options = DecryptOptions()

    @State private var showingLog = false
    @State private var showingDiagnostics = false
    @State private var showingLibrary = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    summaryBar
                    ConnectionSection(engine: engine)
                    if let appStore {
                        AccountSection(session: appStore)
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
                        Card {
                            HStack(spacing: 10) {
                                ProgressView().controlSize(.small)
                                Text("Preparing Apple account module…")
                                    .font(.caption)
                                    .foregroundStyle(Palette.muted)
                            }
                        }
                    }
                    AdvancedSection(
                        engine: engine,
                        options: $options,
                        onShowLog: { showingLog = true },
                        onShowDiagnostics: { showingDiagnostics = true },
                        onShowLibrary: { showingLibrary = true }
                    )
                    footer
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 26)
                .frame(maxWidth: 700)
                .frame(maxWidth: .infinity)
            }
            .background(Palette.canvas.ignoresSafeArea())
            .scrollIndicators(.hidden)
            .navigationTitle("DecryptIPA")
            .navigationBarTitleDisplayMode(.inline)
            .tint(Palette.accent)
            .toolbarBackground(Palette.canvas, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button { showingLog = true } label: {
                            Label("Job log", systemImage: "text.alignleft")
                        }
                        .disabled(engine.log.isEmpty)
                        Button { showingDiagnostics = true } label: {
                            Label("Diagnostics & crash logs", systemImage: "stethoscope")
                        }
                        Button { showingLibrary = true } label: {
                            Label("Decrypted library", systemImage: "folder")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .font(.system(size: 20, weight: .medium))
                            .foregroundStyle(Palette.accent)
                    }
                    .accessibilityLabel("More")
                }
            }
            .sheet(isPresented: $showingLog) { LogSheet(engine: engine) }
            .sheet(isPresented: $showingDiagnostics) { DiagnosticsView() }
            .sheet(isPresented: $showingLibrary) { LibraryView() }
            .onAppear {
                Diagnostics.setScreen("root")
                if appStore == nil {
                    appStore = AppStoreSession(outputDirectory: LibraryStore.defaultImportsRoot)
                }
                library.refresh()
                Diagnostics.breadcrumb(String(
                    format: "root appeared · %d device(s) · %d output(s) · footprint %.1f MB",
                    store.devices.count, library.items.count, Diagnostics.memoryFootprintMB
                ))
            }
            .onChange(of: engine.phase) { _, phase in
                if phase == .done { library.refresh() }
            }
        }
        .preferredColorScheme(.dark)
    }

    private var summaryBar: some View {
        HStack(spacing: 8) {
            StatusPill(
                text: store.selected?.name ?? "No device",
                tint: store.selected == nil ? Palette.warning : Palette.success,
                symbol: store.selected == nil ? "iphone.slash" : "iphone.gen3"
            )
            if let probe = engine.probe {
                StatusPill(text: "iOS " + probe.iosVersion, tint: Palette.muted, symbol: "checkmark.circle")
            }
            if let appStore, let account = appStore.account {
                StatusPill(text: account.email, tint: Palette.accent, symbol: "person.fill")
            }
            Spacer(minLength: 0)
        }
    }

    private var footer: some View {
        HStack(spacing: 5) {
            Image(systemName: "lock.shield")
            Text("Credentials stay in the iOS Keychain · output IPAs are unsigned")
        }
        .font(.caption2)
        .foregroundStyle(Palette.muted)
        .padding(.top, 2)
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
            return
        }

        let storeIPA = source == .appStore ? appStore?.downloadedIPA : nil
        let ipa = source == .file ? inputURL : storeIPA
        Diagnostics.breadcrumb("job: start source=" + source.rawValue + " device=" + device.endpoint)

        engine.start(DecryptEngine.Request(
            device: device,
            secrets: store.secrets(for: device),
            options: options,
            inputIPA: ipa,
            bundleIDOverride: source == .installed ? bundleIDText.trimmingCharacters(in: .whitespaces) : nil,
            outputDirectory: library.root
        ))
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
            .background(Palette.canvas.ignoresSafeArea())
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
