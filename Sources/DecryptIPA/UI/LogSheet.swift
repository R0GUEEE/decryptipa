import SwiftUI

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
        .preferredColorScheme(.dark)
    }
}
