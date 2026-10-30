import SwiftUI

/// Browse what the app recorded: the breadcrumb trail of the last run and any
/// crash report the handlers managed to write.
struct DiagnosticsView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var reports: [URL] = []
    @State private var previousRuns: [URL] = []
    @State private var selected: URL?
    @State private var body_: String = ""

    var body: some View {
        NavigationStack {
            List {
                if reports.isEmpty {
                    Section {
                        Text("Nothing recorded yet.")
                            .foregroundStyle(.secondary)
                    }
                }

                if !previousRuns.isEmpty {
                    Section {
                        ForEach(previousRuns, id: \.self) { url in
                            Button {
                                selected = url
                                body_ = Diagnostics.text(of: url)
                            } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(url.deletingPathExtension().lastPathComponent)
                                        .font(.subheadline.weight(.medium))
                                    Text(Diagnostics.lastStep(of: url))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                            }
                        }
                    } header: {
                        Text("Previous runs")
                    } footer: {
                        Text("The line under each run is the last thing the app recorded before it stopped. A run that ends at \"scenePhase: background\" was backgrounded; one that ends mid-job names the failing step.")
                    }
                }

                ForEach(reports, id: \.self) { url in
                    Button {
                        selected = url
                        body_ = Diagnostics.text(of: url)
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(url.lastPathComponent)
                                .font(.subheadline.weight(.medium))
                            Text(url == reports.first ? "most recent" : "")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .onDelete { offsets in
                    for index in offsets {
                        Diagnostics.delete(reports[index])
                    }
                    reload()
                }

                Section {
                    ShareLink(item: Diagnostics.summary()) {
                        Label("Share everything", systemImage: "square.and.arrow.up")
                    }
                    Button(role: .destructive) {
                        for url in reports { Diagnostics.delete(url) }
                        reload()
                    } label: {
                        Label("Delete all reports", systemImage: "trash")
                    }
                } footer: {
                    Text("last-run.txt is rewritten at every step of a job, so after a crash it shows the last thing the app did. crash-*.txt files come from the uncaught-exception handler.")
                }
            }
            .navigationTitle("Diagnostics")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(item: Binding(get: { selected.map(SelectedReport.init) }, set: { selected = $0?.url })) { report in
                NavigationStack {
                    ScrollView {
                        Text(body_)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding()
                    }
                    .navigationTitle(report.url.lastPathComponent)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { selected = nil }
                        }
                        ToolbarItem(placement: .topBarLeading) {
                            ShareLink(item: body_) {
                                Image(systemName: "square.and.arrow.up")
                            }
                        }
                    }
                }
            }
            .onAppear(perform: reload)
        }
    }

    private func reload() {
        reports = Diagnostics.reports()
        previousRuns = Diagnostics.previousRuns()
    }

    struct SelectedReport: Identifiable {
        let url: URL
        var id: String { url.path }
    }
}
