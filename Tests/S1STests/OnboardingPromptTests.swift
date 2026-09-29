import XCTest
@testable import S1S

final class OnboardingPromptTests: XCTestCase {
    private func onboardedSet() -> (AcceptPairSet, OnboardingPersonalization.Outcome) {
        let outcome = OnboardingPersonalization.outcome(for: completedOnboardingProfile())!
        var set = AcceptPairSet()
        set.replaceOnboarding(with: outcome.pairs)
        return (set, outcome)
    }

    func testFirstPromptHasPersonaAndTwoOnboardingPairsWithCollectionOff() {
        let (set, outcome) = onboardedSet()
        let examples = set.fewShotExamples(level: outcome.personalizationLevel, includeRealAccepts: false)
        XCTAssertEqual(examples.count, 2)
        XCTAssertTrue(examples.allSatisfy { $0.source == .onboarding })

        let persona = AppSettings.personaPreface(name: "", style: outcome.writingStyle, notes: "", topWords: [])
        XCTAssertEqual(persona, "Writing style: \(outcome.writingStyle).")

        let system = CompletionInstructions.system(personalExamples: examples)
        for pair in examples {
            XCTAssertTrue(system.contains("Input: \(pair.prefixTail)\nOutput: \(pair.accepted)"))
        }
        let req = CompletionRequest(beforeCursor: "Thanks for", afterCursor: "", screenContext: "",
                                    persona: persona, personalExamples: examples,
                                    maxWords: 8, maxTokens: 40, temperature: 0)
        XCTAssertTrue(PromptBuilder.body(req, cap: PromptBuilder.defaultCap).hasPrefix(persona))
    }

    func testRealAcceptsReplaceOnboardingPairsOneForOne() {
        var (set, outcome) = onboardedSet()
        let level = outcome.personalizationLevel

        set.recordAccept(prefixTail: "see you", accepted: "tomorrow at ten")
        var examples = set.fewShotExamples(level: level, includeRealAccepts: true)
        XCTAssertEqual(examples.map(\.source), [.onboarding, .accepted])

        set.recordAccept(prefixTail: "thanks for", accepted: "the quick review")
        examples = set.fewShotExamples(level: level, includeRealAccepts: true)
        XCTAssertEqual(examples.map(\.source), [.accepted, .accepted])
        XCTAssertEqual(examples.last?.accepted, "the quick review")

        // Collection off: real accepts are not used, onboarding pairs return.
        examples = set.fewShotExamples(level: level, includeRealAccepts: false)
        XCTAssertEqual(examples.map(\.source), [.onboarding, .onboarding])

        // The style summary is a separate setting and is untouched by accepts.
        XCTAssertFalse(outcome.writingStyle.isEmpty)
    }

    func testLevelScalesExampleCount() {
        XCTAssertEqual(AcceptPairSet.exampleLimit(level: 0), 0)
        XCTAssertEqual(AcceptPairSet.exampleLimit(level: 0.1), 1)
        XCTAssertEqual(AcceptPairSet.exampleLimit(level: 0.25), 2)
        XCTAssertEqual(AcceptPairSet.exampleLimit(level: 0.5), 3)
        XCTAssertEqual(AcceptPairSet.exampleLimit(level: 1), 4)
        let (set, _) = onboardedSet()
        XCTAssertTrue(set.fewShotExamples(level: 0, includeRealAccepts: true).isEmpty)
    }
}
