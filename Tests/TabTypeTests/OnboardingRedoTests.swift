import XCTest
@testable import TabType

final class OnboardingRedoTests: XCTestCase {
    func testRedoReplacesChoicesSummaryAndPairsButKeepsRealAccepts() throws {
        let first = completedOnboardingProfile(types: [.email], profession: .engineering, tone: .concise)
        let firstOutcome = try XCTUnwrap(OnboardingPersonalization.outcome(for: first))
        var set = AcceptPairSet()
        set.replaceOnboarding(with: firstOutcome.pairs)
        set.recordAccept(prefixTail: "see you", accepted: "tomorrow at ten")

        let redo = completedOnboardingProfile(types: [.socialPost], profession: .marketing, tone: .warm) { _ in 2 }
        let redoOutcome = try XCTUnwrap(OnboardingPersonalization.outcome(for: redo, currentLevel: 0.25))
        set.replaceOnboarding(with: redoOutcome.pairs)

        XCTAssertNotEqual(redo, first)
        XCTAssertNotEqual(redoOutcome.writingStyle, firstOutcome.writingStyle)
        XCTAssertEqual(set.onboarding.map(\.accepted), redo.completionPicks.map(\.ending))
        XCTAssertTrue(set.onboarding.allSatisfy { $0.source == .onboarding })
        XCTAssertEqual(set.real.map(\.accepted), ["tomorrow at ten"])
    }

    func testRedoKeepsTheUsersLevelIncludingOff() throws {
        let profile = completedOnboardingProfile()
        XCTAssertEqual(OnboardingPersonalization.outcome(for: profile)?.personalizationLevel, 0.25)
        XCTAssertEqual(OnboardingPersonalization.outcome(for: profile, currentLevel: 0.6)?.personalizationLevel, 0.6)
        XCTAssertEqual(OnboardingPersonalization.outcome(for: profile, currentLevel: 0)?.personalizationLevel, 0)
    }
}
