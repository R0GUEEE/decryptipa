import Foundation
import Combine

/// Persisted app configuration. Decrypt options used to live in `@State`, so
/// every relaunch silently threw the user's choices away.
@MainActor
final class Preferences: ObservableObject {
    @Published var options: DecryptOptions {
        didSet { persist() }
    }

    /// Last source chosen in step 3, restored on launch.
    @Published var preferredSource: String {
        didSet { persist() }
    }

    /// Remembers where the user was in the three-step flow.
    @Published var lastStep: Int {
        didSet { persist() }
    }

    @Published var idleTimerDisabledDuringJobs: Bool {
        didSet { persist() }
    }

    private let defaults = UserDefaults.standard
    private static let optionsKey = "prefs.decrypt.options"
    private static let sourceKey = "prefs.source"
    private static let stepKey = "prefs.step"

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.optionsKey),
           let decoded = try? JSONDecoder().decode(DecryptOptions.self, from: data) {
            options = decoded
        } else {
            options = DecryptOptions()
        }
        preferredSource = UserDefaults.standard.string(forKey: Self.sourceKey) ?? AppSection.Source.appStore.rawValue
        lastStep = UserDefaults.standard.integer(forKey: Self.stepKey)
        idleTimerDisabledDuringJobs = true
    }

    func resetOptions() {
        options = DecryptOptions()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(options) {
            defaults.set(data, forKey: Self.optionsKey)
        }
        defaults.set(preferredSource, forKey: Self.sourceKey)
        defaults.set(lastStep, forKey: Self.stepKey)
    }
}
