import Foundation
import XCTest
@testable import TabType

final class OnboardingPersistenceTests: XCTestCase {
    func testOutcomeSetsLevelStyleAndAtLeastTenOnboardingPairs() throws {
        let profile = completedOnboardingProfile(types: [.email, .report], profession: .product)
        let outcome = try XCTUnwrap(OnboardingPersonalization.outcome(for: profile))

        XCTAssertEqual(outcome.personalizationLevel, 0.25)
        XCTAssertFalse(outcome.writingStyle.isEmpty)
        XCTAssertTrue(outcome.writingStyle.contains("product manager"))
        XCTAssertTrue(outcome.writingStyle.contains("emails and reports"))
        XCTAssertGreaterThanOrEqual(outcome.pairs.count, 10)
        XCTAssertTrue(outcome.pairs.allSatisfy { $0.source == .onboarding })
        XCTAssertEqual(outcome.pairs.map(\.prefixTail), profile.completionPicks.map(\.prefix))
        XCTAssertEqual(outcome.pairs.map(\.accepted), profile.completionPicks.map(\.ending))
    }

    func testProfileKeepsProfessionAndWritingTypesThroughJSON() throws {
        let profile = completedOnboardingProfile(types: [.message, .note], profession: .design, tone: .warm)
        let data = try JSONEncoder().encode(profile)
        let decoded = try JSONDecoder().decode(OnboardingProfile.self, from: data)
        XCTAssertEqual(decoded, profile)
        XCTAssertEqual(decoded.profession, .design)
        XCTAssertEqual(decoded.writingTypes, [.message, .note])
    }

    func testIncompleteProfileIsRejected() {
        let full = completedOnboardingProfile()
        let partial = OnboardingProfile(writingTypes: full.writingTypes, profession: full.profession,
                                        tone: full.tone, completionPicks: Array(full.completionPicks.prefix(5)))
        XCTAssertNil(OnboardingPersonalization.outcome(for: partial))
    }

    func testStyleSummaryReflectsPicks() {
        // Ending 0 is the shortest in every round; ending 2 carries most emoji/"!".
        let short = OnboardingPersonalization.styleSummary(for: completedOnboardingProfile { _ in 0 })
        let long = OnboardingPersonalization.styleSummary(for: completedOnboardingProfile { _ in 1 })
        XCTAssertTrue(short.hasPrefix("concise tone"))
        XCTAssertTrue(short.contains("short endings"), short)
        XCTAssertFalse(long.contains("short endings"), long)

        let chatty = OnboardingPersonalization.styleSummary(
            for: completedOnboardingProfile(types: [.message, .socialPost], profession: .marketing) { _ in 2 })
        XCTAssertTrue(chatty.contains("uses emoji"), chatty)
    }

    func testPairsSurviveSnapshotEncodingWithSource() throws {
        var set = AcceptPairSet()
        set.replaceOnboarding(with: OnboardingPersonalization.pairs(for: completedOnboardingProfile()))
        set.recordAccept(prefixTail: "see you", accepted: "tomorrow")
        let data = try JSONEncoder().encode(set.all)
        let decoded = AcceptPairSet(try JSONDecoder().decode([TypingHistoryStore.AcceptPair].self, from: data))
        XCTAssertEqual(decoded, set)

        // Pairs saved before `source` existed decode as real accepts.
        let legacy = Data(#"[{"prefixTail":"a","accepted":"b"}]"#.utf8)
        let old = try JSONDecoder().decode([TypingHistoryStore.AcceptPair].self, from: legacy)
        XCTAssertEqual(old.first?.source, .accepted)
    }
}
