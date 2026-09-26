import Foundation

enum WritingType: String, CaseIterable, Codable, Identifiable {
    case email = "Emails"
    case message = "Messages"
    case report = "Reports"
    case presentation = "Presentations"
    case socialPost = "Social posts"
    case note = "Notes"

    var id: String { rawValue }
}

enum Profession: String, CaseIterable, Codable, Identifiable {
    case product = "Product manager"
    case engineering = "Engineer"
    case design = "Designer"
    case data = "Data analyst"
    case marketing = "Marketer"
    case sales = "Sales professional"
    case education = "Educator"
    case other = "Other role"

    var id: String { rawValue }
}

enum WritingTone: String, CaseIterable, Codable, Identifiable {
    case concise = "Concise"
    case warm = "Warm"
    case formal = "Formal"

    var id: String { rawValue }
}

struct CompletionRound: Equatable, Identifiable {
    let id: String
    let prefix: String
    let endings: [String]
}

struct CompletionPick: Codable, Equatable {
    let roundID: String
    let prefix: String
    let ending: String
}

struct OnboardingProfile: Codable, Equatable {
    let writingTypes: [WritingType]
    let profession: Profession
    let tone: WritingTone
    let completionPicks: [CompletionPick]
}

/// Fixed copy only. Six rounds come from selected writing types and six from the
/// selected role. No model or network service creates onboarding candidates.
enum OnboardingCatalog {
    static let roundsPerSource = 6
    static let roundCount = roundsPerSource * 2

    private typealias Copy = (String, [String])

    private static let writingCopy: [WritingType: [Copy]] = [
        .email: [
            ("Thanks for reaching out", ["— I'll take a look.", "! I'll review this and send you my thoughts by tomorrow.", ". I appreciate you getting in touch."]),
            ("I wanted to follow up", ["on the note below.", "regarding our conversation and the next steps we discussed.", "— any thoughts? 🙂"]),
            ("Could you please", ["send the details?", "share the relevant details when you have a moment?", "forward the information at your earliest convenience."]),
            ("I've attached", ["the file for review.", "the latest version, with the changes we discussed.", "a copy — let me know what you think!"]),
            ("Looking forward to", ["your reply.", "hearing your perspective when you have time.", "the opportunity to discuss this further."]),
            ("One last thing", [": please confirm receipt.", "— could you let me know if this timing works for you?", "! Happy to answer questions."]),
        ],
        .message: [
            ("Quick update", [": it's done.", "— I made the changes we talked about.", "! All set on my end 🙌"]),
            ("Can we", ["talk later?", "find a few minutes to compare notes this afternoon?", "schedule a time to discuss this further?"]),
            ("That sounds", ["good to me.", "like a sensible way forward.", "great — let's do it! 🎉"]),
            ("Just checking", ["in on this.", "whether you had a chance to look at my last message.", "— no rush, but let me know!"]),
            ("I'll send", ["it shortly.", "the revised version once I've checked the details.", "it over now! 📩"]),
            ("Thanks for", ["the heads-up.", "taking the time to walk me through it.", "flagging this — super helpful!"]),
        ],
        .report: [
            ("The main finding", ["is clear.", "suggests a meaningful change from the previous period.", "warrants further review before a decision is made."]),
            ("Compared with last period", [", results improved.", ", the available results point to a modest shift.", ", the pattern appears broadly consistent."]),
            ("The evidence suggests", ["a change is needed.", "that the team should examine the remaining uncertainty.", "a promising direction, though more data would help."]),
            ("A key limitation", ["is sample size.", "is that the available data covers only part of the period.", "should be considered when interpreting this result."]),
            ("The next step", ["is to validate this.", "is to compare the result with an independent source.", "should be a more detailed assessment."]),
            ("In summary", [", progress is steady.", ", the findings support a cautious next step.", ", we recommend monitoring the trend before expanding the work."]),
        ],
        .presentation: [
            ("Today I'll cover", ["the key points.", "what changed, why it matters, and what comes next.", "three decisions we need to make together."]),
            ("The takeaway here", ["is simple.", "is that the current approach has room to improve.", "is a practical path forward."]),
            ("Let's start with", ["the problem.", "the question behind this work.", "a quick look at what we learned."]),
            ("This chart shows", ["the trend.", "how the pattern changed over the last few periods.", "the difference we should focus on."]),
            ("Before we move on", [", any questions?", ", I want to clarify one important assumption.", ", let's pause on the implication of this result."]),
            ("I'll close with", ["next steps.", "the decisions and owners for the next phase.", "one thing I'd like you to remember."]),
        ],
        .socialPost: [
            ("I learned something", ["new today.", "worth sharing from a recent project.", "surprising today — here's the short version 👇"]),
            ("Here's what changed", ["this week.", "and what I'm taking away from it.", "— and why it matters to me."]),
            ("A small reminder", [": keep going.", "that steady progress adds up over time.", "for anyone working through a tough week 💛"]),
            ("One question I keep asking", ["is why.", "is whether we're solving the right problem.", "is: what would we try if we started fresh?"]),
            ("I'm excited to share", ["an update.", "a few lessons from the work our team has done.", "what we've been building! 🚀"]),
            ("What do you think", ["about this?", "would make this approach more useful?", "— have you seen something similar?"]),
        ],
        .note: [
            ("Remember to", ["follow up.", "check the open questions before the next meeting.", "review this when there's more context."]),
            ("The main idea", ["is straightforward.", "connects the problem to a possible next step.", "needs another pass before I share it."]),
            ("Things to check", [": dates and owners.", "include the assumptions, timing, and source of the figures.", "before moving forward: scope, effort, and risk."]),
            ("A useful example", ["would help.", "could make this point easier to explain later.", "is the case we discussed this morning."]),
            ("Open question", [": who owns this?", "is whether the earlier decision still applies.", ": do we have enough evidence yet?"]),
            ("Next time", [", ask for details.", "start with the decision and work backward.", "bring a shorter version of this note."]),
        ],
    ]

    private static let roleCopy: [Profession: [Copy]] = [
        .product: [
            ("The user problem", ["is clear.", "needs a sharper definition before we pick a solution.", "is worth validating with a few more conversations."]),
            ("Our next priority", ["is the launch.", "should reflect the trade-offs we heard from customers.", "is to align on the decision and its owner."]),
            ("This feature would", ["save time.", "address the main friction in the current workflow.", "need a smaller first version to test the idea."]),
            ("The roadmap depends on", ["capacity.", "what we learn from the next release.", "a shared view of impact and effort."]),
            ("I'd like to understand", ["the trade-off.", "which user need this request serves first.", "how we'll know this change helped."]),
            ("For the release", [", let's stay focused.", "we should confirm the scope, owner, and success measure.", "I'd suggest a narrow rollout first."]),
        ],
        .engineering: [
            ("The implementation", ["is ready.", "needs one more review before we merge it.", "depends on the interface contract staying stable."]),
            ("I found the issue", ["in the parser.", "and have a small fix ready for review.", "but need a reliable reproduction to confirm the cause."]),
            ("The test results", ["look good.", "cover the main path and the failure case.", "suggest we should check one edge case."]),
            ("This change should", ["be safe.", "reduce repeated work in the request path.", "be rolled out gradually so we can watch for regressions."]),
            ("One trade-off", ["is latency.", "is the extra complexity in the fallback path.", "is worth documenting before we proceed."]),
            ("Before merging", [", I'll rerun tests.", "I'd like another review of the error handling.", "let's confirm the migration path."]),
        ],
        .design: [
            ("The current layout", ["feels crowded.", "makes the primary action hard to spot.", "could use a clearer visual hierarchy."]),
            ("In the prototype", [", the flow is shorter.", "I simplified the step that caused confusion.", "the empty state still needs attention."]),
            ("The research showed", ["a clear pattern.", "that participants missed the next action.", "several competing mental models."]),
            ("I'd like feedback on", ["the navigation.", "whether the labels match what people expect.", "the contrast and focus states."]),
            ("This interaction", ["needs polish.", "should make the result visible immediately.", "may be easier to understand with fewer choices."]),
            ("For the next version", [", I'll simplify it.", "I'll test the revised flow with a few people.", "I'd keep the visual system consistent."]),
        ],
        .data: [
            ("The data indicates", ["a shift.", "a difference that needs a closer look.", "an association, though not necessarily a cause."]),
            ("Before drawing conclusions", [", check the sample.", "we should validate the source and time window.", "I'd compare against a baseline."]),
            ("The metric changed", ["this week.", "after the definition was updated.", "but the uncertainty is still substantial."]),
            ("A useful comparison", ["is last month.", "would control for the difference in group size.", "might reveal whether this is seasonal."]),
            ("The analysis suggests", ["a follow-up.", "we should segment the result before acting.", "a promising signal that needs replication."]),
            ("I'll share the results", ["soon.", "with the assumptions and caveats attached.", "once the quality checks are complete."]),
        ],
        .marketing: [
            ("The campaign message", ["is ready.", "should lead with the customer benefit.", "needs a clearer call to action."]),
            ("Our audience responds to", ["clear examples.", "a specific problem they recognize.", "a simpler explanation of the value."]),
            ("For this launch", [", let's keep it simple.", "I'd focus on one main promise across channels.", "we should test a few different headlines."]),
            ("The headline could", ["be shorter.", "say more clearly what changes for the reader.", "make the benefit easier to remember."]),
            ("Early feedback", ["looks promising.", "suggests the message needs more specificity.", "points to a different audience segment."]),
            ("Next, I'll review", ["the copy.", "the results by channel and audience.", "the landing page against the campaign promise."]),
        ],
        .sales: [
            ("Thanks for the conversation", ["today.", "— I enjoyed learning about your team's goals.", ". I'll send the recap we discussed."]),
            ("Your team mentioned", ["a timing concern.", "that the current process takes too much manual effort.", "a few criteria for choosing a solution."]),
            ("I can share", ["more details.", "a brief example relevant to your use case.", "the information you need for your review."]),
            ("The next step", ["is a follow-up.", "could be a short discussion with the wider team.", "is to confirm whether this fits your timeline."]),
            ("Would it help if", ["we talked?", "I outlined the options and trade-offs in writing?", "I sent a short recap of the key points?"]),
            ("I'll follow up", ["next week.", "after you've had time to review the material.", "with answers to the open questions."]),
        ],
        .education: [
            ("The learning goal", ["is clear.", "is to explain the idea in your own words.", "will guide the next activity."]),
            ("A helpful example", ["comes next.", "connects the concept to a familiar situation.", "shows where this rule applies."]),
            ("Let's try", ["one more question.", "a simpler version before moving to the next step.", "working through the problem together."]),
            ("The feedback suggests", ["steady progress.", "this part needs another explanation.", "a few learners would benefit from extra practice."]),
            ("For the next lesson", [", I'll adjust the pace.", "I'd like to start with a quick review.", "we can build on today's example."]),
            ("One thing to remember", [": ask why.", "is how the two ideas connect.", "is that a mistake can reveal the next step."]),
        ],
        .other: [
            ("My main goal", ["is to be clear.", "is to help the reader understand the next step.", "is to explain the situation without extra detail."]),
            ("For this work", [", timing matters.", "I'll focus on the most useful information first.", "we should agree on the next action."]),
            ("A useful detail", ["is missing.", "would make the request easier to answer.", "could clarify what happened."]),
            ("I want to make sure", ["we agree.", "I understand the context before responding.", "the decision is clear to everyone involved."]),
            ("The next step", ["is simple.", "is to confirm the plan and timing.", "depends on one open question."]),
            ("I'll share", ["an update soon.", "a concise summary once I've checked the details.", "what I learn after the next conversation."]),
        ],
    ]

    static func rounds(writingTypes: [WritingType], profession: Profession) -> [CompletionRound] {
        guard !writingTypes.isEmpty, let role = roleCopy[profession] else { return [] }
        let typeRounds = (0..<roundsPerSource).compactMap { index -> CompletionRound? in
            let type = writingTypes[index % writingTypes.count]
            guard let copy = writingCopy[type]?[index] else { return nil }
            return CompletionRound(id: "type-\(type.id)-\(index)", prefix: copy.0, endings: copy.1)
        }
        let roleRounds = role.enumerated().map { index, copy in
            CompletionRound(id: "role-\(profession.id)-\(index)", prefix: copy.0, endings: copy.1)
        }
        return typeRounds + roleRounds
    }
}

/// The flow permits completion only after all three choices and every pick.
struct OnboardingFlow {
    var writingTypes: [WritingType] = []
    var profession: Profession?
    var tone: WritingTone?
    private(set) var picks: [CompletionPick] = []
    private(set) var roundIndex = 0
    private(set) var isPicking = false

    var canBegin: Bool { !writingTypes.isEmpty && profession != nil && tone != nil }
    var rounds: [CompletionRound] {
        guard let profession else { return [] }
        return OnboardingCatalog.rounds(writingTypes: writingTypes, profession: profession)
    }
    var currentRound: CompletionRound? {
        let rounds = rounds
        guard isPicking, rounds.indices.contains(roundIndex) else { return nil }
        return rounds[roundIndex]
    }

    mutating func toggle(_ type: WritingType) {
        if let index = writingTypes.firstIndex(of: type) { writingTypes.remove(at: index) }
        else { writingTypes.append(type) }
    }

    mutating func begin() {
        guard canBegin, rounds.count == OnboardingCatalog.roundCount else { return }
        picks = []
        roundIndex = 0
        isPicking = true
    }

    mutating func back() {
        guard isPicking else { return }
        if roundIndex == 0 { isPicking = false }
        else { roundIndex -= 1 }
    }

    mutating func choose(_ endingIndex: Int) -> OnboardingProfile? {
        guard let round = currentRound, round.endings.indices.contains(endingIndex) else { return nil }
        let pick = CompletionPick(roundID: round.id, prefix: round.prefix,
                                  ending: round.endings[endingIndex])
        if roundIndex < picks.count { picks[roundIndex] = pick }
        else { picks.append(pick) }
        roundIndex += 1
        guard roundIndex == rounds.count, let profession, let tone else { return nil }
        return OnboardingProfile(writingTypes: writingTypes, profession: profession,
                                 tone: tone, completionPicks: picks)
    }
}

/// Turns a finished onboarding profile into the settings and stored pairs that
/// personalize suggestions. Pure, so `swift test` covers it.
enum OnboardingPersonalization {
    /// Personalization level set by first-run onboarding.
    static let initialLevel = 0.25

    struct Outcome: Equatable {
        let writingStyle: String
        let personalizationLevel: Double
        let pairs: [TypingHistoryStore.AcceptPair]
    }

    /// Returns nil for an incomplete profile. `currentLevel` is the slider value
    /// before a redo (nil on first run): a redo keeps the user's level, even Off.
    static func outcome(for profile: OnboardingProfile, currentLevel: Double? = nil) -> Outcome? {
        guard !profile.writingTypes.isEmpty,
              profile.completionPicks.count == OnboardingCatalog.roundCount else { return nil }
        return Outcome(writingStyle: styleSummary(for: profile),
                       personalizationLevel: currentLevel ?? initialLevel,
                       pairs: pairs(for: profile))
    }

    /// Each completion pick becomes one onboarding few-shot pair.
    static func pairs(for profile: OnboardingProfile) -> [TypingHistoryStore.AcceptPair] {
        profile.completionPicks.map {
            .init(prefixTail: $0.prefix, accepted: $0.ending, source: .onboarding)
        }
    }

    /// A short style description for `AppSettings.writingStyle`, e.g. "concise
    /// tone; writes as an engineer, mostly emails; prefers short endings (about 5
    /// words); mostly formal; avoids emoji; avoids exclamation marks".
    static func styleSummary(for profile: OnboardingProfile) -> String {
        let endings = profile.completionPicks.map(\.ending)
        guard !endings.isEmpty else { return "" }
        var parts = ["\(profile.tone.rawValue.lowercased()) tone"]

        let kinds = profile.writingTypes.map { $0.rawValue.lowercased() }
        var who = profile.profession == .other ? "" : "writes as \(article(profile.profession.rawValue))"
        if !kinds.isEmpty {
            let list = kinds.count > 1
                ? kinds.dropLast().joined(separator: ", ") + " and " + kinds.last!
                : kinds[0]
            who += who.isEmpty ? "writes mostly \(list)" : ", mostly \(list)"
        }
        parts.append(who)

        let words = endings.map { $0.split(whereSeparator: \.isWhitespace).count }
        let average = Int((Double(words.reduce(0, +)) / Double(words.count)).rounded())
        let length = switch average {
        case ...4: "short"
        case ...9: "medium-length"
        default: "long"
        }
        parts.append("prefers \(length) endings (about \(average) words)")

        let casual = endings.filter { hasEmoji($0) || $0.contains("!") || hasContraction($0) }.count
        let formalShare = 1 - Double(casual) / Double(endings.count)
        let formality = switch formalShare {
        case 0.75...: "mostly formal"
        case ...0.4: "casual"
        default: "mixes formal and casual"
        }
        parts.append(formality)

        parts.append(frequency(of: endings.filter(hasEmoji).count, total: endings.count, noun: "emoji"))
        parts.append(frequency(of: endings.filter { $0.contains("!") }.count, total: endings.count,
                               noun: "exclamation marks"))
        return parts.joined(separator: "; ")
    }

    private static func frequency(of count: Int, total: Int, noun: String) -> String {
        switch count {
        case 0: return "avoids \(noun)"
        case ...max(1, total / 4): return "rarely uses \(noun)"
        default: return "often uses \(noun)"
        }
    }

    private static func article(_ role: String) -> String {
        let lower = role.lowercased()
        return ("aeiou".contains(lower.first ?? "x") ? "an " : "a ") + lower
    }

    static func hasEmoji(_ text: String) -> Bool {
        text.unicodeScalars.contains { $0.properties.isEmojiPresentation }
    }

    private static func hasContraction(_ text: String) -> Bool {
        text.range(of: #"[A-Za-z]['’](ll|s|re|ve|d|m|t)\b"#, options: .regularExpression) != nil
    }
}
