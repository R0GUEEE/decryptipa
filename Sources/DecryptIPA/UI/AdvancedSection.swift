import SwiftUI

/// STEP 4 — everything that does not need to be in the way of the main flow.
struct AdvancedSection: View {
    @EnvironmentObject private var library: LibraryStore
    @ObservedObject var engine: DecryptEngine
    @Binding var options: DecryptOptions

    let onShowLog: () -> Void
    let onShowDiagnostics: () -> Void
    let onShowLibrary: () -> Void

    @State private var expanded = false

    var body: some View {
        Card {
            SectionHeader(
                step: 4,
                title: "Advanced settings",
                subtitle: "Install behaviour, verification, logs and diagnostics",
                icon: "slider.horizontal.3",
                state: .idle
            )

            Button {
                expanded.toggle()
            } label: {
                HStack {
                    Text(expanded ? "Hide options" : "Show options")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Palette.accent)
                    Spacer()
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Palette.accent)
                }
            }
            .buttonStyle(.plain)

            if expanded {
                VStack(spacing: 2) {
                    optionToggle("Patch Info.plist for this device", isOn: $options.patchForInstall)
                    optionToggle("Expand device family if needed", isOn: $options.expandDeviceFamily)
                    optionToggle("Reinstall when the version differs", isOn: $options.reinstallIfDifferent)
                    optionToggle("Skip app extensions (appex)", isOn: $options.skipAppex)
                    optionToggle("Uninstall afterwards if this run installed it", isOn: $options.uninstallAfter)
                    optionToggle("Verify cryptid in the output", isOn: $options.verifyOutput)
                    optionToggle("Verbose helper logging", isOn: $options.verboseHelper)
                }
            }

            DividerLine()

            VStack(spacing: 8) {
                toolRow("Job log", detail: engine.log.isEmpty ? "no entries yet" : String(engine.log.count) + " entries", icon: "text.alignleft", action: onShowLog)
                toolRow("Diagnostics & crash logs", detail: "memory samples and reports", icon: "stethoscope", action: onShowDiagnostics)
                toolRow("Decrypted library", detail: String(library.items.count) + " IPA(s)", icon: "folder", action: onShowLibrary)
            }

            DividerLine()

            HStack {
                Text("DecryptIPA")
                    .font(.caption2)
                    .foregroundStyle(Palette.muted)
                Spacer()
                Text(appVersion)
                    .font(.caption2.monospaced())
                    .foregroundStyle(Palette.muted)
            }
        }
    }

    private var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return version + " (" + build + ")"
    }

    private func optionToggle(_ title: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            Text(title)
                .font(.caption)
                .foregroundStyle(Palette.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
        .tint(Palette.accent)
        .padding(.vertical, 3)
    }

    private func toolRow(_ title: String, detail: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Palette.accent)
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.caption.weight(.semibold)).foregroundStyle(Palette.ink)
                    Text(detail).font(.caption2).foregroundStyle(Palette.muted)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Palette.muted)
            }
            .padding(9)
            .background(Palette.cardRaised, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}
