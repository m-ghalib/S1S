# Onboarding Personalization: Remaining Work

| Item | Value |
|---|---|
| Date | 2026-09-26 17:56 |
| Source seed | `seed_8c1665c03c37` (Ouroboros), goal: a mandatory first-run onboarding flow that personalizes suggestions from quick choices and completion picks within three minutes, with a redo option in Settings |
| Source run | `orch_62401b6851ae` / `exec_16a0c13e4f46`. The run failed: AC 1 failed on evidence form (`EVIDENCE_FORM_MISMATCH`), and ACs 2–7 were blocked and never started. |
| Landed in | `a9bdb86` feat: require first-run writing profile before starting the engine |

## What is implemented

- A first-run window with chips for writing types (6), profession (8), and tone (3). The flow does not ask about apps.
- 12 pick-the-completion rounds from a static bank (`OnboardingCatalog`). Six rounds come from the selected writing types and six from the selected profession. Each round has 3 endings that vary in length, formality, and punctuation or emoji.
- Back navigation to revise a pick.
- `OnboardingProfile` (writing types, profession, tone, picks) is saved as JSON in `UserDefaults` under `onboardingProfile`.
- The engine starts only when Accessibility is granted and onboarding is complete. The menu shows "Finish Setup…" until then.
- `OnboardingFlowTests` (4 tests) covers the catalog shape, persona-specific rounds, required choices and picks, and back navigation.

## What remains

The saved profile is not used anywhere yet. Onboarding therefore has no effect on suggestions.

### 1. Derive and save the writing-style summary

- Build a style summary from the profession, tone, and picks. For example, the average ending length, formality, and use of emoji or exclamation marks.
- Write the summary to `AppSettings.writingStyle` in `completeOnboarding(_:)`.
- Keep the summary until onboarding is redone.

### 2. Set the personalization level

- Set `personalizeWordChoice` to `0.25` in `completeOnboarding(_:)`.
- Change the meaning of the slider so that its effect scales with the amount of personalization data. Today, `personaPreface` uses `Int(slider * 12)` top words with at least 3 recurrences, and it requires `collectTypingHistory`. At 0.25 this produces nothing right after onboarding. The exact mapping at other values is an implementation choice.

### 3. Store onboarding picks as accept pairs

- Save each pick as a local `TypingHistoryStore.AcceptPair` (`prefixTail` = round prefix, `accepted` = chosen ending). There must be at least 10 pairs.
- Store the pairs even when "Collect typing history" is off. Completing the rounds is consent. The toggle governs passive capture only.
- Mark onboarding pairs as separate from real accepts, so that step 4 and step 5 can tell them apart. `AcceptPair` has no source field today.

### 4. Use onboarding data in the prompt

- At 0.25, include the style summary and up to two onboarding pairs as few-shot examples.
- Remove the gate that blocks this today: `Engine.swift` uses personal examples only when `collectTypingHistory && acceptCount >= 5` (three call sites near lines 323, 418 and 1254).
- As real accepts accumulate, let each one replace an onboarding pair in the prompt. The style summary stays.
- Higher slider values can allow more pairs or words.

### 5. Redo onboarding from Settings

- Add a "Redo onboarding" control in Settings > Personalization (`UI/Panes/ExtraPanes.swift`).
- Redo must replace the previous choices, the style summary, and the onboarding pairs.
- Redo must keep real accepts from regular use. `TypingHistoryStore.deleteAll()` clears everything, so redo needs its own method that removes only onboarding pairs.
- "Clear all history" remains a separate control.

### 6. Add the missing tests

The seed names these test classes. None exist yet.

| Test class | Must prove |
|---|---|
| `OnboardingPersistenceTests` | After onboarding: `personalizeWordChoice == 0.25`, `writingStyle` is not empty, profession and writing types are saved, at least 10 onboarding pairs are stored. |
| `OnboardingPromptTests` | The first prompt after onboarding has the persona preface and up to two onboarding pairs, also with collection off. Real accepts replace the pairs; the summary stays. |
| `OnboardingRedoTests` | Redo replaces choices, summary, and onboarding pairs, and keeps real accepts. |

Put the logic in static helpers so these tests can run under `swift test`.

### 7. Verify in the running app

These checks have not been done:

1. Build with `./Scripts/build.sh app` and launch with a fresh `onboardingProfile` (`defaults delete app.tabtype.TabType onboardingProfile`).
2. Complete the flow through computer use and time it. The median completion time must be 3 minutes or less.
3. With verbose logging on, confirm that the first prompt after onboarding contains the persona preface and the onboarding few-shot pairs.
4. Redo onboarding from Settings and confirm the prompt changes.

## Differences from the seed

These are not necessarily defects, but they need a decision.

| Topic | Seed | Implemented |
|---|---|---|
| Writing types | email, chat, docs, notes, social, support replies | Emails, Messages, Reports, Presentations, Social posts, Notes |
| Professions | engineer, PM, sales, support, student, writer, founder, other | Product manager, Engineer, Designer, Data analyst, Marketer, Sales professional, Educator, Other role |
| Synonym-pick rounds | 2–3 rounds may be mixed in (optional) | None |
| Endings per round | 3–4 | 3 |

## Known risk

Existing users have no saved `onboardingProfile`. After updating, the engine does not start until they complete onboarding. The seed puts existing-user migration out of scope. Decide before the next release whether existing users must also complete the flow.
