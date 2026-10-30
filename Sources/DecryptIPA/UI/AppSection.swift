import SwiftUI
import UniformTypeIdentifiers

/// STEP 3 — choose what to decrypt. App Store search, a local IPA, or an app
/// that is already installed on the device.
struct AppSection: View {
    enum Source: String, CaseIterable, Identifiable {
        case appStore, file, installed

        var id: String { rawValue }
        var label: String {
            switch self {
            case .appStore: "App Store"
            case .file: "IPA file"
            case .installed: "Installed"
            }
        }
    }

    @EnvironmentObject private var library: LibraryStore
    @ObservedObject var engine: DecryptEngine
    @ObservedObject var session: AppStoreSession

    @Binding var source: Source
    @Binding var inputURL: URL?
    @Binding var inputMetadata: IPAMetadata?
    @Binding var bundleIDText: String

    let canDecrypt: Bool
    let onDecrypt: () -> Void
    let onCancel: () -> Void

    @State private var searchText = ""
    @State private var showingImporter = false
    @State private var importError: String?

    var body: some View {
        Card {
            SectionHeader(
                step: 3,
                title: "Choose the app",
                subtitle: "Search the App Store, pick an IPA, or target an installed app",
                icon: "square.stack.3d.up",
                state: canDecrypt ? .ready : .idle
            )

            Picker("Source", selection: $source) {
                ForEach(Source.allCases) { item in Text(item.label).tag(item) }
            }
            .pickerStyle(.segmented)

            switch source {
            case .appStore: appStoreBody
            case .file: fileBody
            case .installed: installedBody
            }

            DividerLine()
            runBody
        }
        .fileImporter(
            isPresented: $showingImporter,
            allowedContentTypes: [UTType(filenameExtension: "ipa") ?? .data, .zip],
            allowsMultipleSelection: false,
            onCompletion: handleImport
        )
        .onChange(of: session.downloadedIPA) { _, url in
            guard let url else { return }
            inputURL = url
            inputMetadata = try? IPATool.metadata(for: url)
            importError = nil
        }
    }

    // MARK: App Store

    private var appStoreBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let app = session.app {
                selectedApp(app)
            } else {
                HStack(spacing: 8) {
                    FieldShell {
                        HStack(spacing: 8) {
                            Image(systemName: "magnifyingglass")
                                .font(.system(size: 13))
                                .foregroundStyle(Palette.muted)
                            TextField("App name, bundle ID or App Store link", text: $searchText)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .submitLabel(.search)
                                .foregroundStyle(Palette.ink)
                                .onSubmit(runSearch)
                            if !searchText.isEmpty {
                                Button {
                                    searchText = ""
                                    session.clearSearch()
                                } label: {
                                    Image(systemName: "xmark.circle.fill").foregroundStyle(Palette.muted)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }

                    Button(action: runSearch) {
                        if session.busy {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "arrow.right.circle.fill")
                                .font(.system(size: 22))
                                .foregroundStyle(Palette.accent)
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(searchText.trimmingCharacters(in: .whitespaces).isEmpty || session.busy)
                }

                if session.account == nil {
                    Text("Sign in above for downloads. Search and lookups work without an account.")
                        .font(.caption2)
                        .foregroundStyle(Palette.muted)
                }

                if !session.searchResults.isEmpty {
                    VStack(spacing: 6) {
                        ForEach(session.searchResults) { app in
                            resultRow(app)
                        }
                    }
                } else if !searchText.isEmpty, !session.busy {
                    EmptyNote(text: "No results yet. Adjust the search, or paste a bundle ID / App Store link for an exact match.")
                }
            }
        }
    }

    private func resultRow(_ app: AppStoreApp) -> some View {
        Button {
            session.selectApp(app)
        } label: {
            HStack(spacing: 10) {
                artwork(app, size: 42)
                VStack(alignment: .leading, spacing: 2) {
                    Text(app.name)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Palette.ink)
                        .lineLimit(1)
                    Text(app.seller)
                        .font(.caption2)
                        .foregroundStyle(Palette.muted)
                        .lineLimit(1)
                    Text(app.bundleID)
                        .font(.caption2.monospaced())
                        .foregroundStyle(Palette.muted.opacity(0.8))
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Text(app.isFree ? "Free" : String(format: "%.2f", app.price))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(app.isFree ? Palette.success : Palette.warning)
            }
            .padding(9)
            .background(Palette.cardRaised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func selectedApp(_ app: AppStoreApp) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                artwork(app, size: 52)
                VStack(alignment: .leading, spacing: 3) {
                    Text(app.name).font(.subheadline.weight(.semibold)).foregroundStyle(Palette.ink).lineLimit(2)
                    Text(app.bundleID).font(.caption2.monospaced()).foregroundStyle(Palette.muted)
                }
                Spacer(minLength: 0)
                Button {
                    session.deselectApp()
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Palette.muted)
                }
                .buttonStyle(.plain)
            }

            HStack(spacing: 14) {
                miniFact("version", app.version)
                miniFact("min iOS", app.minimumOS)
                if let size = app.sizeText { miniFact("size", size) }
            }

            if let ipa = session.downloadedIPA {
                HStack(spacing: 7) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.success).font(.system(size: 12))
                    Text(ipa.lastPathComponent)
                        .font(.caption2.monospaced())
                        .foregroundStyle(Palette.ink)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Text(ByteCountFormatter.string(fromByteCount: Int64((try? ipa.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0), countStyle: .file))
                        .font(.caption2)
                        .foregroundStyle(Palette.muted)
                }
                .padding(9)
                .background(Palette.cardRaised, in: RoundedRectangle(cornerRadius: 11, style: .continuous))

                QuietButton(title: "Download again", icon: "arrow.down.circle") {
                    Task { await session.download() }
                }
            } else {
                if session.downloadProgress > 0, session.downloadProgress < 1 {
                    ProgressView(value: session.downloadProgress).tint(Palette.accent)
                }
                PrimaryButton(
                    title: session.busy ? "Downloading…" : "Download encrypted IPA",
                    icon: "arrow.down.circle",
                    busy: session.busy,
                    enabled: session.account != nil
                ) {
                    Task { await session.download() }
                }
                if session.account == nil {
                    EmptyNote(text: "Sign in to the Apple account above to download this app.")
                }
            }

            if session.downloadedIPA != nil {
                EmptyNote(text: "The downloaded IPA is selected automatically; it still needs to be installed on the jailbroken device and decrypted there.")
            }
        }
    }

    private func artwork(_ app: AppStoreApp, size: CGFloat) -> some View {
        AsyncImage(url: app.artworkURL) { image in
            image.resizable().aspectRatio(contentMode: .fit)
        } placeholder: {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Palette.cardRaised)
                .overlay {
                    Image(systemName: "app.dashed").foregroundStyle(Palette.muted)
                }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func miniFact(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.caption2).foregroundStyle(Palette.muted)
            Text(value).font(.caption.weight(.semibold)).foregroundStyle(Palette.ink)
        }
    }

    // MARK: Local IPA

    private var fileBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            QuietButton(title: inputURL == nil ? "Choose an IPA file" : "Choose a different IPA", icon: "folder.badge.plus") {
                showingImporter = true
            }

            if let metadata = inputMetadata {
                VStack(spacing: 6) {
                    InfoRow(label: "App", value: metadata.displayName)
                    InfoRow(label: "Bundle ID", value: metadata.bundleID, mono: true)
                    InfoRow(label: "Version", value: metadata.version + " (" + metadata.build + ")")
                    InfoRow(label: "Size", value: ByteCountFormatter.string(fromByteCount: metadata.fileSize, countStyle: .file))
                }
                .padding(10)
                .background(Palette.cardRaised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            } else if let importError {
                Text(importError).font(.caption).foregroundStyle(Palette.warning)
            } else {
                EmptyNote(text: "The IPA is uploaded, installed with appinst and decrypted on the device.")
            }
        }
    }

    // MARK: Installed

    private var installedBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            FieldShell {
                TextField("com.example.app", text: $bundleIDText)
                    .font(.body.monospaced())
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .foregroundStyle(Palette.ink)
            }
            EmptyNote(text: "No upload and no install: the helper decrypts the existing bundle in place.")
        }
    }

    // MARK: Run

    private var runBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            if engine.isRunning {
                HStack {
                    Text(engine.phase.title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Palette.ink)
                    Spacer()
                    Text(elapsedText(engine.elapsed))
                        .font(.caption2.monospaced())
                        .foregroundStyle(Palette.muted)
                }

                if engine.phase == .uploading {
                    ProgressView(value: min(1, max(0, engine.installProgress))).tint(Palette.accent)
                } else {
                    ProgressView().tint(Palette.accent)
                }

                HStack(spacing: 12) {
                    StatusPill(text: ByteCountFormatter.string(fromByteCount: engine.receivedBytes, countStyle: .file), tint: Palette.muted)
                    StatusPill(text: String(engine.imagesDone) + " images", tint: Palette.success)
                    if engine.imagesFailed > 0 {
                        StatusPill(text: String(engine.imagesFailed) + " failed", tint: Palette.warning)
                    }
                    Spacer(minLength: 0)
                }

                if !engine.log.isEmpty {
                    LogConsole(entries: Array(engine.log.suffix(5)), maxHeight: 110)
                        .background(Palette.cardRaised, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                }

                QuietButton(title: "Cancel job", icon: "stop.circle") { onCancel() }
            } else {
                PrimaryButton(
                    title: "Decrypt on device",
                    icon: "lock.open.rotation",
                    enabled: canDecrypt
                ) { onDecrypt() }

                if !canDecrypt { EmptyNote(text: decryptHint) }

                if let url = engine.outputURL { resultRow(url) }
            }

            if let report = engine.verification {
                HStack(spacing: 6) {
                    Image(systemName: report.ok ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                    Text(report.ok
                         ? String(report.plaintext) + "/" + String(report.checked) + " Mach-O images are plaintext"
                         : String(report.stillEncrypted.count) + " images still encrypted")
                        .font(.caption2)
                }
                .foregroundStyle(report.ok ? Palette.success : Palette.warning)
            }
        }
    }

    private func resultRow(_ url: URL) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.seal.fill").foregroundStyle(Palette.success)
                Text(url.lastPathComponent)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(2)
                Spacer(minLength: 0)
            }
            HStack(spacing: 10) {
                ShareLink(item: url) {
                    Label("Share", systemImage: "square.and.arrow.up").font(.caption.weight(.semibold))
                }
                Button {
                    library.refresh()
                } label: {
                    Label("Library", systemImage: "folder").font(.caption.weight(.semibold))
                }
                Spacer(minLength: 0)
            }
            .tint(Palette.accent)
        }
        .padding(10)
        .background(Palette.cardRaised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var decryptHint: String {
        if session.app == nil && source == .appStore && session.downloadedIPA == nil {
            return "Search for an app and download its encrypted IPA first."
        }
        switch source {
        case .appStore: return "Download an app above, then decrypt it here."
        case .file: return "Choose an IPA file first."
        case .installed: return "Enter the bundle ID of an installed app."
        }
    }

    // MARK: Actions

    private func runSearch() {
        let term = searchText
        Task { await session.searchApps(term) }
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        importError = nil
        inputMetadata = nil
        switch result {
        case .failure(let error):
            importError = error.localizedDescription
        case .success(let urls):
            guard let url = urls.first else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let copy = try library.importCopy(from: url)
                inputURL = copy
                inputMetadata = try IPATool.metadata(for: copy)
            } catch {
                importError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                inputURL = nil
            }
        }
    }
}
