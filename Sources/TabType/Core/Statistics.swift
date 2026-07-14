import Foundation

/// Local, on-device usage counters — words completed and suggestion acceptance rate.
/// Never leaves the Mac; purely for the user's own Statistics pane.
@MainActor
final class Statistics: ObservableObject {
    static let shared = Statistics()

    @Published private(set) var suggestionsShown: Int
    @Published private(set) var suggestionsAccepted: Int
    @Published private(set) var wordsCompleted: Int

    private let defaults = UserDefaults.standard
    private enum Keys {
        static let shown = "stat_suggestionsShown"
        static let accepted = "stat_suggestionsAccepted"
        static let words = "stat_wordsCompleted"
    }

    private init() {
        suggestionsShown = defaults.integer(forKey: Keys.shown)
        suggestionsAccepted = defaults.integer(forKey: Keys.accepted)
        wordsCompleted = defaults.integer(forKey: Keys.words)
    }

    var acceptanceRate: Double {
        suggestionsShown == 0 ? 0 : Double(suggestionsAccepted) / Double(suggestionsShown)
    }

    func recordShown() {
        suggestionsShown += 1
        persist()
    }

    func recordAccepted(wordCount: Int) {
        suggestionsAccepted += 1
        wordsCompleted += wordCount
        persist()
    }

    func reset() {
        suggestionsShown = 0
        suggestionsAccepted = 0
        wordsCompleted = 0
        persist()
    }

    private func persist() {
        defaults.set(suggestionsShown, forKey: Keys.shown)
        defaults.set(suggestionsAccepted, forKey: Keys.accepted)
        defaults.set(wordsCompleted, forKey: Keys.words)
    }
}
