@testable import S1S

/// Runs the onboarding flow to completion, choosing `ending(round)` each round.
func completedOnboardingProfile(types: [WritingType] = [.email],
                                profession: Profession = .engineering,
                                tone: WritingTone = .concise,
                                ending: (Int) -> Int = { _ in 0 }) -> OnboardingProfile {
    var flow = OnboardingFlow()
    types.forEach { flow.toggle($0) }
    flow.profession = profession
    flow.tone = tone
    flow.begin()
    for round in 0..<(OnboardingCatalog.roundCount - 1) { _ = flow.choose(ending(round)) }
    return flow.choose(ending(OnboardingCatalog.roundCount - 1))!
}
