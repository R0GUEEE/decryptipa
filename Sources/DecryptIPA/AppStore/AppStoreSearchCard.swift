import SwiftUI

struct AppStoreSearchCard: View {
    @ObservedObject var session: AppStoreSession
    @Binding var searchText: String
    @Binding var showingBrowser: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center) {
                HStack(spacing: 9) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color(red: 0.38, green: 0.58, blue: 1.0))
                        .frame(width: 30, height: 30)
                        .background(Color(red: 0.38, green: 0.58, blue: 1.0).opacity(0.14), in: RoundedRectangle(cornerRadius: 9))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("APP PICKER").font(.caption.weight(.bold)).tracking(0.7).foregroundStyle(.secondary)
                        Text("Search the App Store").font(.subheadline.weight(.medium)).foregroundStyle(.primary)
                    }
                    Spacer(minLength: 0)
                }
                Spacer(minLength: 4)
                if session.app != nil {
                    Button("Change") { showingBrowser = true }
                        .font(.caption.weight(.semibold))
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }

            if let app = session.app {
                selectedApp(app)
            } else {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search apps or paste bundle ID / App Store link", text: $searchText)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.search)
                        .onSubmit { runSearch() }
                    if !searchText.isEmpty {
                        Button {
                            searchText = ""
                            session.clearSearch()
                        } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(12)
                .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 13))

                Button(action: runSearch) {
                    HStack {
                        if session.busy { ProgressView().controlSize(.small) }
                        Label("Search apps", systemImage: "magnifyingglass")
                            .font(.subheadline.weight(.semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color(red: 0.38, green: 0.58, blue: 1.0))
                .disabled(searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || session.busy)

                if !session.searchResults.isEmpty {
                    VStack(spacing: 0) {
                        ForEach(session.searchResults) { result in
                            Button {
                                session.selectApp(result)
                            } label: {
                                resultRow(result)
                            }
                            .buttonStyle(.plain)
                            if result.id != session.searchResults.last?.id {
                                Divider().overlay(Color.white.opacity(0.08)).padding(.leading, 62)
                            }
                        }
                    }
                } else if !session.status.isEmpty && !session.busy {
                    Text(session.status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Button {
                    showingBrowser = true
                } label: {
                    Label("Open full App Store browser", systemImage: "arrow.up.forward.square")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color(red: 0.48, green: 0.66, blue: 1.0))
            }
        }
        .padding(16)
        .background(Color(red: 0.105, green: 0.12, blue: 0.15), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.white.opacity(0.06), lineWidth: 1)
        }
    }

    private func runSearch() {
        Task { await session.searchApps(searchText) }
    }

    private func selectedApp(_ app: AppStoreApp) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                artwork(app, size: 54)
                VStack(alignment: .leading, spacing: 3) {
                    Text(app.name).font(.subheadline.weight(.semibold)).foregroundStyle(.primary).lineLimit(1)
                    Text(app.bundleID).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Text("v\(app.version) · " + (app.isFree ? "Free" : String(format: "%.2f", app.price)))
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            }
            Button {
                showingBrowser = true
            } label: {
                Label("Review app, licence and download IPA", systemImage: "arrow.down.app")
                    .font(.caption.weight(.semibold))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color(red: 0.48, green: 0.66, blue: 1.0))
        }
        .padding(10)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
    }

    private func resultRow(_ result: AppStoreApp) -> some View {
        HStack(spacing: 10) {
            artwork(result, size: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(result.name).font(.subheadline.weight(.medium)).foregroundStyle(.primary).lineLimit(1)
                Text(result.bundleID).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                Text("v\(result.version) · " + (result.isFree ? "Free" : String(format: "%.2f", result.price)))
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Image(systemName: "chevron.right").font(.caption2.weight(.bold)).foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func artwork(_ app: AppStoreApp, size: CGFloat) -> some View {
        if let url = app.artworkURL {
            AsyncImage(url: url) { image in
                image.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                RoundedRectangle(cornerRadius: 11).fill(Color.white.opacity(0.08))
            }
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: 11))
        } else {
            Image(systemName: "app.fill")
                .font(.title2)
                .foregroundStyle(.secondary)
                .frame(width: size, height: size)
                .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 11))
        }
    }
}
