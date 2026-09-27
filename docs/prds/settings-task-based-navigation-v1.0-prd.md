# Settings Task-Based Navigation - Product Requirements Document (PRD)

Source: Ouroboros seed `seed_b26aba2cc6a5` (interview `interview_20260927_015106`, ambiguity score 0.1435).

## Requirements Description

### Background
- **Business Problem**: TabType Settings has 13 flat sidebar panes (Setup, General, Engine & Model, Context, Personalization, Text Tools, Emoji, Shortcuts, Battery, Apps, Advanced, Statistics, About). Users must guess which pane holds a control. Some controls are duplicated; for example, the clipboard-context toggle appears in both `SetupPane.swift:64` and `ExtraPanes.swift:30`.
- **Target Users**: TabType users who configure the app from the menu bar, including first-run users who still need to grant permissions or load a model.
- **Value Proposition**: Four task-based items make common tasks reachable within two clicks. Each setting has one owner, and permission fixes are in one predictable place.

### Feature Overview
- **Core Features**:
  1. Replace the 13-pane sidebar with exactly four items: **Suggestions**, **Apps**, **Model & Power**, **About**.
  2. Render each item as one scrolling page that uses `Form` section headers.
  3. Put all permission Grant actions in a **Permissions** section at the top of Suggestions.
  4. Convert deep links into item + section anchors.
  5. Make the default Settings destination conditional on setup state.
- **Feature Boundaries**:
  - In scope: sidebar structure, the pane-to-item mapping, control relocation, removal of the duplicate clipboard toggle, menu-bar entry points, and the default destination.
  - Out of scope: a fifth item, a separate Privacy & Data section, a search field, tabs or any other second navigation level, a global banner, and new settings.
- **User Scenarios**:
  - A first-run user opens Settings, lands at Permissions, and grants Accessibility.
  - A user disables TabType in one app through Apps and the per-app drill-in.
  - A user picks Statistics from the menu bar and lands on the Statistics section inside About.

### Detailed Requirements
- **Item → section mapping**:

| Item | Sections (in order) |
|---|---|
| Suggestions | Permissions (top), General, Emoji, Text Tools, Personalization, Shortcuts |
| Apps | Apps (per-app list with drill-in), Context (includes the only clipboard-context toggle) |
| Model & Power | Engine & Model (includes model load and download actions), Battery, Advanced |
| About | About, Statistics, Setup status (read-only) |

- **Permissions section** (Suggestions, top):
  - Accessibility: required, with a Grant action.
  - Screen Recording: optional, with a Grant action.
  - macOS text suggestions conflict row, with its fix action.
- **Setup status** (About): read-only status rows. It has no Grant, load, or download buttons.
- **Entry points**:

| Entry point | Destination |
|---|---|
| Menu-bar Statistics | About → Statistics section |
| Menu-bar About TabType | About, top |
| Default Settings action, when a required grant or the model is missing | Suggestions → Permissions |
| Default Settings action, otherwise | Suggestions, top |

- **Data Requirements**: No new persisted settings. Existing `AppSettings` / `UserDefaults` keys are unchanged. The navigator state moves from `SettingsNavigator.pendingSection: Pane` to an item plus an optional section anchor.
- **Edge Cases**:
  - A permission is granted while Settings is open: status updates live. The next default open uses the new state.
  - The model is downloading when Settings opens: treat it as missing, so the destination is Permissions.
  - A pending anchor is set while the window is already open: scroll to the anchor (the current `onChange(of: pendingSection)` path).
  - The Apps per-app drill-in is open and the user switches items: the drill-in state may reset. No crash occurs.

## Design Decisions

### Technical Approach
- **Architecture Choice**: Replace the `Pane` enum in `SettingsView.swift` with a four-case item enum plus a section-anchor enum. Each item view composes the existing pane bodies as `Section`s inside one `Form`, wrapped in a `ScrollViewReader` so the view can scroll to an anchor. Reuse the existing pane views where possible so that no setting is dropped.
- **Key Components**:
  - `UI/SettingsView.swift`: sidebar, item enum, and detail routing. Keep the 980px width for the Apps nested split view (`SettingsView.swift:78`).
  - `UI/SettingsNavigator.swift`: item + anchor state.
  - `UI/Panes/SetupPane.swift`: split its content. Grants go to Suggestions/Permissions, model actions go to Model & Power, the clipboard toggle goes to Apps/Context, and status goes to About.
  - `UI/Panes/ExtraPanes.swift`: remove the duplicate clipboard toggle.
  - `AppDelegate.swift`: update `openStatistics` and `openAbout`. Replace the window-title/default seed at lines 260–265 (`pendingSection ?? .setup`) with conditional default logic.
- **Data Storage**: Unchanged.
- **Interface Design**: Add a pure static helper for the default destination, for example `SettingsNavigator.defaultDestination(axGranted:modelReady:) -> (Item, Anchor?)`, so it can be unit-tested.

### Constraints
- **Performance Requirements**: Settings opens and scrolls to its anchor without visible delay. Merging panes must not trigger model or AX work on open.
- **Compatibility**: The current macOS target, Swift 6, and SwiftPM. The existing per-app drill-in keeps working.
- **Security**: Password fields and on-device rules are unchanged. There are no new network calls.
- **Scalability**: A new setting is added as a section in an existing item, not as a new sidebar item.

### Risk Assessment
- **Technical Risks**:
  - A setting is lost during the merge. Mitigation: before the change, build a checklist of every control in the 13 panes and tick each one after the change.
  - `ScrollViewReader` anchors inside `Form` can be unreliable on macOS. Mitigation: verify in the running app, and fall back to explicit `.id` on section headers.
- **Dependency Risks**: None external.
- **Schedule Risks**: Computer-use verification can be blocked (see memory note: `request_access` returns `notInstalled` for TabType). Mitigation: use the temporary `.regular` activation-policy workaround. If verification remains blocked, report the blocked task instead of claiming completion.

## Acceptance Criteria

### Functional Acceptance
- [ ] The sidebar shows exactly four items (Suggestions, Apps, Model & Power, About). Each item is one scrolling `Form` with section headers, with no tabs or second navigation level.
- [ ] Every control from the 13 original panes appears exactly once, in the mapped section.
- [ ] Suggestions starts with Permissions, which contains Accessibility (required), Screen Recording (optional), and the macOS text suggestions conflict row, each with its action.
- [ ] About shows Setup status as read-only, with no fix actions.
- [ ] Model load and download actions appear only in Model & Power.
- [ ] Exactly one clipboard-context toggle exists, in Apps/Context.
- [ ] The Apps per-app detail drill-in works, and the Apps pane keeps its 980px width.
- [ ] Menu-bar Statistics opens About scrolled to Statistics. Menu-bar About opens the top of About.
- [ ] The default Settings action opens Suggestions at Permissions when a required grant or the model is missing. Otherwise it opens the top of Suggestions.

### Quality Standards
- [ ] Code Quality: follows existing SwiftUI and `Form` patterns, and no dead pane enum cases remain.
- [ ] Test Coverage: XCTest in `Tests/TabTypeTests/` covers the default-destination helper, the menu entry → destination mapping, and (if expressed as data) the complete item/section mapping. Run with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`.
- [ ] Performance Metrics: no perceptible lag when Settings opens.
- [ ] Security Review: no new data access or network calls.

### User Acceptance
- [ ] Computer-use test in the running app: each task below is reachable within two clicks of opening Settings.
  - Disable TabType in a specific app.
  - Change the model.
  - Grant Accessibility.
  - Toggle emoji suggestions.
  - Change the accept key.
- [ ] Documentation: record the verification result in `docs/ISSUES.md` if any defect is found.
- [ ] Training Materials: none.

## Execution Phases

### Phase 1: Preparation
**Goal**: Inventory and design the mapping.
- [ ] List every control in the 13 panes, and map each one to one item and section.
- [ ] Confirm the conflict-row and Screen Recording controls currently in `SetupPane.swift`.
- **Deliverables**: A control checklist.
- **Time**: 0.5 day.

### Phase 2: Core Development
**Goal**: Build the four-item structure.
- [ ] Add the item and anchor enums. Update `SettingsNavigator`.
- [ ] Build the Suggestions, Apps, Model & Power, and About pages from the existing pane bodies.
- [ ] Split `SetupPane`. Remove the duplicate clipboard toggle.
- [ ] Add `defaultDestination` and wire `AppDelegate` entry points.
- **Deliverables**: The new Settings UI, compiling.
- **Time**: 1–1.5 days.

### Phase 3: Integration & Testing
**Goal**: Prove coverage and navigation.
- [ ] Add XCTest cases for the destination logic and the mapping. Run `swift test`.
- [ ] Build with `./Scripts/build.sh app` and confirm `Signing with "TabType Dev"`.
- [ ] Run the computer-use test of the five tasks and the three entry points. Tick the control checklist.
- **Deliverables**: Passing tests and screenshots of each item.
- **Time**: 0.5–1 day.

### Phase 4: Deployment
**Goal**: Ship.
- [ ] Commit, and include the change in the next release per `RELEASING.md`.
- [ ] Watch for user reports of missing settings.
- **Deliverables**: A release build.
- **Time**: 0.5 day.

## Open Notes
- The seed lists `python3 -m pytest -q` as the verify command for three criteria. This repository is Swift, so this PRD uses `swift test` instead. Confirm the substitution before running automated evaluation.

---

**Document Version**: 1.0
**Created**: 2026-09-26
**Clarification Rounds**: 0 (requirements came from a completed Ouroboros interview)
**Quality Score**: 92/100
