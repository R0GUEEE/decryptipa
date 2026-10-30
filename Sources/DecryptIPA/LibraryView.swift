import SwiftUI

struct LibraryView: View {
    @EnvironmentObject private var library: LibraryStore
    @State private var pendingDelete: LibraryStore.Item?
    @State private var showingDiagnostics = false

    var body: some View {
        NavigationStack {
            List {
                if library.items.isEmpty {
                    Section {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("No decrypted IPAs yet").font(.headline)
                            Text("Finished jobs land in Documents/Decrypted. They are also visible in the Files app under On My iPhone → DecryptIPA.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 6)
                    }
                }

                ForEach(library.items) { item in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(item.name)
                            .font(.subheadline.weight(.medium))
                            .lineLimit(2)
                        HStack(spacing: 10) {
                            Text(item.sizeText)
                            Text(item.modified.formatted(date: .abbreviated, time: .shortened))
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)

                        HStack(spacing: 16) {
                            ShareLink(item: item.url) {
                                Label("Share", systemImage: "square.and.arrow.up")
                                    .font(.caption)
                            }
                            Button(role: .destructive) {
                                pendingDelete = item
                            } label: {
                                Label("Delete", systemImage: "trash")
                                    .font(.caption)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            .navigationTitle("Library")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            library.refresh()
                        } label: {
                            Label("Refresh", systemImage: "arrow.clockwise")
                        }
                        Button {
                            showingDiagnostics = true
                        } label: {
                            Label("Diagnostics & crash logs", systemImage: "stethoscope")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .sheet(isPresented: $showingDiagnostics) {
                DiagnosticsView()
            }
            .onAppear { library.refresh() }
            .confirmationDialog(
                "Delete \(pendingDelete?.name ?? "file")?",
                isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    if let item = pendingDelete { library.delete(item) }
                    pendingDelete = nil
                }
                Button("Cancel", role: .cancel) { pendingDelete = nil }
            }
        }
    }
}
