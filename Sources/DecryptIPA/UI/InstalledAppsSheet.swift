import SwiftUI

/// Searchable list of the apps already installed on the device.
struct InstalledAppsSheet: View {
    let apps: [DeviceService.InstalledSummary]
    let loading: Bool
    let error: String?
    let onPick: (DeviceService.InstalledSummary) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var filtered: [DeviceService.InstalledSummary] {
        let term = query.trimmingCharacters(in: .whitespaces)
        guard !term.isEmpty else { return apps }
        return apps.filter {
            $0.name.localizedCaseInsensitiveContains(term) || $0.bundleID.localizedCaseInsensitiveContains(term)
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if loading && apps.isEmpty {
                    VStack(spacing: 10) {
                        ProgressView()
                        Text("Reading installed apps from the device…")
                            .font(.caption)
                            .foregroundStyle(Palette.muted)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let error, apps.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(Palette.warning)
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(Palette.muted)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        ForEach(filtered) { app in
                            Button {
                                onPick(app)
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(app.name)
                                        .font(.subheadline.weight(.semibold))
                                    HStack(spacing: 6) {
                                        Text(app.bundleID)
                                            .font(.caption2.monospaced())
                                        if !app.version.isEmpty {
                                            Text(app.version).font(.caption2)
                                        }
                                    }
                                    .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .searchable(text: $query, prompt: "Filter apps")
                }
            }
            .navigationTitle("Installed apps")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}
