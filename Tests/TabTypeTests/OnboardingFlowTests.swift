import XCTest
@testable import TabType

final class OnboardingFlowTests: XCTestCase {
    func testEveryPersonaGetsTwelveFixedRoundsWithThreeDistinctEndings() {
        for type in WritingType.allCases {
            for role in Profession.allCases {
                let rounds = OnboardingCatalog.rounds(writingTypes: [type], profession: role)
                XCTAssertEqual(rounds.count, 12, "\(type.rawValue), \(role.rawValue)")
                XCTAssertEqual(Set(rounds.map(\.id)).count, 12)
                XCTAssertTrue(rounds.allSatisfy { !$0.prefix.isEmpty &&
                    $0.endings.count == 3 && Set($0.endings).count == 3 })
            }
        }
        XCTAssertEqual(OnboardingCatalog.rounds(writingTypes: [], profession: .other), [])
    }

    func testChoicesChangeThePresentedRounds() {
        let emailProduct = OnboardingCatalog.rounds(writingTypes: [.email], profession: .product)
        let noteProduct = OnboardingCatalog.rounds(writingTypes: [.note], profession: .product)
        let emailDesign = OnboardingCatalog.rounds(writingTypes: [.email], profession: .design)
        XCTAssertNotEqual(emailProduct[0].prefix, noteProduct[0].prefix)
        XCTAssertNotEqual(emailProduct[6].prefix, emailDesign[6].prefix)

        let mixed = OnboardingCatalog.rounds(writingTypes: [.email, .note], profession: .product)
        XCTAssertTrue(mixed.prefix(6).contains { $0.id.contains(WritingType.email.id) })
        XCTAssertTrue(mixed.prefix(6).contains { $0.id.contains(WritingType.note.id) })
    }

    func testAllChoicesAndAllPicksAreRequired() {
        var flow = OnboardingFlow()
        flow.begin()
        XCTAssertNil(flow.currentRound)
        flow.toggle(.email)
        flow.profession = .engineering
        XCTAssertFalse(flow.canBegin)
        flow.tone = .warm
        XCTAssertTrue(flow.canBegin)
        flow.begin()
        XCTAssertNotNil(flow.currentRound)

        XCTAssertNil(flow.choose(3))
        for index in 0..<11 {
            XCTAssertNil(flow.choose(index % 3))
        }
        XCTAssertEqual(flow.picks.count, 11)
        let profile = flow.choose(2)
        XCTAssertEqual(profile?.writingTypes, [.email])
        XCTAssertEqual(profile?.profession, .engineering)
        XCTAssertEqual(profile?.tone, .warm)
        XCTAssertEqual(profile?.completionPicks.count, 12)
        XCTAssertEqual(profile?.completionPicks.map(\.prefix), flow.rounds.map(\.prefix))
    }

    func testBackCanReviseAPick() {
        var flow = OnboardingFlow()
        flow.toggle(.message)
        flow.profession = .education
        flow.tone = .concise
        flow.begin()
        _ = flow.choose(0)
        flow.back()
        XCTAssertEqual(flow.roundIndex, 0)
        _ = flow.choose(1)
        XCTAssertEqual(flow.picks.count, 1)
        XCTAssertEqual(flow.picks[0].ending, flow.rounds[0].endings[1])
    }
}
