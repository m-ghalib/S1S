# TabType Issue Tracker

Issues found during a manual test pass of a fresh local build. Each issue has an ID, a severity, a status, reproduction steps, and the evidence collected.

## Test session

| Item | Value |
|---|---|
| Date | 2026-09-25 |
| Commit | `c719409` (feat: extend app coverage for chat, Superhuman, Chromium, and safety gaps) |
| Version | 0.1.2 (build 9) |
| Build | `./Scripts/build.sh app` (Debug). Build succeeded. Signed ad-hoc. |
| Tests | `swift test`: 97 tests, 0 failures |
| Model | `mlx-community/Qwen3-4B-Instruct-2507-8bit` (already downloaded) |
| Apps tested | TextEdit, Notes, TabType Settings, menu bar menu |
| Method | Typing through computer use. The ghost overlay was checked with `screencapture`. Engine behavior was checked with `~/Library/Logs/TabType/tabtype.log` (verbose logging on during the test). |

### What worked

- The model loaded and warmed up in about 2.1 s.
- Ghost text appeared in TextEdit about 0.7–1.0 s after typing paused.
- Type-through shrank the suggestion in place.
- Tab accepted one word. Shift+Tab accepted the whole suggestion. Esc dismissed it.
- The `/date` macro showed a preview and inserted the date on Tab.
- `:rock` opened the emoji picker, and Tab inserted 🪨.
- All 13 Settings panes opened without errors. The menu bar menu listed all expected items.

### Fix pass

| Item | Value |
|---|---|
| Date | 2026-09-25 |
| Base commit | `68095eb` |
| Build | `./Scripts/build.sh app` (Debug), signed with "TabType Dev" |
| Tests | `swift test`: 105 tests, 0 failures (8 new) |
| Warnings | One left in project sources: the deprecated MLX `generate(input:context:iterator:didGenerate:)` call at `Predictor.swift:322`. It needs a migration to the AsyncStream API. |
| Method | Typing through computer use in Notes and TextEdit. Ghost text was checked with `screencapture`, because computer-use screenshots hide the TabType overlay. Settings panes were driven with System Events and CGEvent clicks. |

## Summary

| ID | Severity | Status | Title |
|---|---|---|---|
| [TT-001](#tt-001) | High | Fixed | Notes: wrapped ghost text draws over the typed text |
| [TT-002](#tt-002) | Medium | Fixed | Continuation ghosts do not wrap and are clipped at the window edge |
| [TT-003](#tt-003) | Medium | Fixed | Model repeats a partly typed word instead of completing it |
| [TT-004](#tt-004) | Medium | Needs repro | Keystrokes possibly dropped while a suggestion is visible |
| [TT-005](#tt-005) | Low | Fixed | Shortcut shows as `⌃key50` instead of ``⌃` `` |
| [TT-006](#tt-006) | Low | Fixed | Personalization: placeholder text renders as the row label |
| [TT-007](#tt-007) | Low | Fixed | Log file stores screen text in plain text and never rotates |
| [TT-008](#tt-008) | Low | Fixed | Model catalog gives conflicting recommendations |
| [TT-009](#tt-009) | Low | Fixed | Setup pane says "Free — no upgrade required" |
| [TT-010](#tt-010) | Low | Fixed | Settings window resizes on the Apps pane and does not resize back |
| [TT-011](#tt-011) | Low | Fixed | Apps list includes TabType itself |
| [TT-012](#tt-012) | Low | Fixed | Six compiler warnings in project sources |
| [TT-013](#tt-013) | Low | Confirmed | Extra gap between accepted word and remaining ghost |
| [TT-014](#tt-014) | Low | Fixed | Ad-hoc signed rebuilds lose the Accessibility grant |
| [TT-015](#tt-015) | Info | Partly fixed | Most generation requests are deferred because the model is busy |

---

## TT-001

**Notes: wrapped ghost text draws over the typed text**

- **Severity:** High. The ghost overlaps real text, so the user cannot read what they typed or what is suggested.
- **Status:** Fixed. Verified in Notes and TextEdit.
- **Area:** `Sources/TabType/Core/SuggestionOverlay.swift` (`showWrapped`)

**Steps to reproduce**

1. Open Notes and create a new note.
2. Type `Meeting notes`, press Return, then type `We discussed the launch timeline and agreed that the team`.
3. Stop typing and wait for the suggestion.

**Expected:** The ghost starts at the caret.

**Actual:** The ghost starts about 105 pt left of the caret. "will focus on phased" draws on top of "agreed that the team". On the first attempt, the overlap made the ghost look missing.

**Evidence**

```
placement app=com.apple.Notes new=true caretRect=(1174.34, 139.0, 1.0, 16.0)
  fieldRect=(789.0, 83.0, 1391.0, 906.0) wrap=true firstLineIndent=386.3
occupancy: strip=(1177.34, 141.0, 120.0, 12.0) contrast=0.000 -> free
```

The same wrap path placed the ghost correctly in TextEdit, where the field is 586 pt wide.

**Notes:** The occupancy check reported "free" because it samples to the right of the caret, not under the ghost's rendered position.

**Cause:** A temporary log after `orderFrontRegardless()` showed that the panel was placed correctly but the label was not. `showWrapped` set the label frame to 700 pt wide, but after layout the label was 240 pt wide (`panel=(793.0, 1284.0, 700.0, 16.0) label=(0.0, 0.0, 240.0, 16.0) indent=383.3`). The label has `translatesAutoresizingMaskIntoConstraints = false`, so Auto Layout sized it to its intrinsic width. A `firstLineHeadIndent` wider than the label cannot place line 1 at the caret. In the 586 pt TextEdit field the indent was small enough to fit, so the bug did not show there.

**Fix:** `showInline` now sends native fields through `showSplitWrapped`, the path already used for Electron editors, and `showWrapped` is deleted. Line 1 is a single-line label at the caret. The remaining words go in a second label at the text column's left edge. `AccessibilityBridge.paragraphStartX` gives that edge from the bounds of the paragraph's first character, because Notes pads its text about 17 pt inside the field frame. The placement log now records `line1X` instead of the unused `firstLineIndent`.

**Retest:** In Notes, the ghost starts at the caret. A wrapped ghost continues on the next line, aligned with the note's text. In TextEdit, the wrap looks the same as before.

## TT-002

**Continuation ghosts do not wrap and are clipped at the window edge**

- **Severity:** Medium
- **Status:** Fixed. Verified in TextEdit.
- **Area:** `Sources/TabType/Core/Engine.swift`

**Steps to reproduce**

1. In TextEdit, type `Hi Sarah, thanks for sending over the quarterly report. I had a chance to` and wait for a suggestion that wraps.
2. Type the first character of the suggestion (type-through), or press Tab to accept one word.

**Expected:** The remaining ghost wraps to the next line, as the first suggestion did.

**Actual:** The remaining ghost is drawn on one line and is cut off at the window's right edge ("…and overall t").

**Evidence:** The first placement logs `wrap=true`. Every later placement logs `wrap=false`.

**Cause:** Only the fresh model result passes `allowWrap` (`Engine.swift:1381`). These calls to `presentWhenSettled` use the default `allowWrap: false`:

- Type-through: `Engine.swift:654`
- Phrase memory: `Engine.swift:710`
- Dictionary completion: `Engine.swift:730`
- Parked suggestion: `Engine.swift:1185`, `Engine.swift:1195`
- Remainder after word accept: `Engine.swift:1744`

**Fix:** `presentWhenSettled` now defaults to `allowWrap: true`. This is safe because `present()` passes a field rect only when `caretConfirmedAtEnd` is true, so wrapped lines never cover text after the caret. The model-result call still passes its own `afterCursor` check.

**Retest:** After a type-through and after a Tab word accept, the log shows `new=false … wrap=true` and the remainder wraps onto the next line.

## TT-003

**Model repeats a partly typed word instead of completing it**

- **Severity:** Medium. Accepting the suggestion produces duplicated text.
- **Status:** Fixed. Covered by unit tests. The restatement did not recur live.
- **Frequency:** 2 of 4 mid-word attempts

**Steps to reproduce**

1. In TextEdit, type `…I had a chance to review and I thin` and wait.

**Expected:** A completion that starts with `k`. The dictionary produced `k` first.

**Actual:** The model result `" I think the key performance indicators are off"` replaced the dictionary suggestion. Accepting it gives "I thin I think the key…".

**Evidence**

```
predict -> "k" [dictionary] (0ms)
predict raw model output (pre-post-processing): "I think the key performance indicators are off"
predict -> " I think the key performance indicators are off" (948ms)
```

A second case: after the text `tolook`, the model returned `" look through it this morning and have a"`.

**Notes:** The existing echo filter (the "Rejected (echo)" counter in Statistics) does not catch a restatement of the partial word.

**Fix:** New `Engine.stripRestatedTail`, called directly after `stripEcho`. It removes a restatement of the last 2–4 typed words from the start of the suggestion. When the caret is mid-word, the last typed word only has to be a prefix of the restated word, and the untyped letters are kept (`I thin` + `" I think the key"` gives `"k the key"`). A single repeated word is kept, because "that that" is normal writing. A suggestion that is only a restatement is rejected and counted as an echo.

**Not handled:** The `tolook` case. It came from the dropped space in TT-004. A suffix-overlap rule would also strip valid text, such as `cat` + `" at home"`.

**Retest:** In six tries with `…review and I thin`, the model did not restate the words. The shown ghosts were `k the data looks solid…` and `k it's solid overall…`. One try gave `the data looks…`, a new word after the partial "thin", which is a separate model-quality problem.

## TT-004

**Keystrokes possibly dropped while a suggestion is visible**

- **Severity:** Medium if confirmed
- **Status:** Needs repro. It may be an artifact of the automated input.

**Observed**

1. A space typed after `to` did not appear, which produced `tolook`. A suggestion was visible at the time.
2. One Cmd+A did not select all, so the next Delete removed only one character. The macOS autocorrect bubble ("to look") was visible at the time.

Later attempts with the same steps worked. `KeystrokeMonitor.handle` and `Engine.handleControlKey` have no path that swallows Space or Cmd+A. The "Fix typos automatically" setting (Text Tools) was on and may interact with the macOS autocorrect bubble.

**Next step:** Try to reproduce with real keyboard input, with "Fix typos automatically" on and then off.

**Fix pass:** Not reproduced. More than 300 characters were typed through computer use in Notes and TextEdit, and all of them arrived.

## TT-005

**Shortcut shows as `⌃key50` instead of ``⌃` ``**

- **Severity:** Low
- **Status:** Fixed
- **Area:** `Sources/TabType/Core/KeyBinding.swift:66`

**Steps to reproduce:** Open Settings ▸ Shortcuts and look at "Force a suggestion".

**Cause:** `character(for:)` maps only letter key codes. Key code 50 (backtick), digits, and punctuation fall back to `"key\(code)"`. Custom bindings that use these keys also display incorrectly.

**Fix:** `character(for:)` now maps the ANSI digit and punctuation key codes. `keyName` adds forward delete (`⌦`) and F1–F12. New tests are in `KeyBindingTests.swift`. Settings ▸ Shortcuts now shows ``⌃` ``.

## TT-006

**Personalization: placeholder text renders as the row label**

- **Severity:** Low
- **Status:** Fixed
- **Area:** `Sources/TabType/UI/Panes/ExtraPanes.swift:269`, `:275`

**Steps to reproduce:** Open Settings ▸ Personalization and scroll to Custom AI Instructions.

**Actual:** "e.g. concise, friendly, British spelling" and "e.g. Avoid exclamation marks. Prefer plain words." appear as left-hand labels. The text fields beside them are empty and narrow, so the rows look already filled in.

**Notes:** Inside a grouped `Form`, the `TextField` title renders as the row label.

**Fix:** The "Writing style", "Custom instructions", and per-app instruction fields now use a real title, a `prompt:` placeholder, and `.labelsHidden()`. The placeholders now appear inside the fields.

## TT-007

**Log file stores screen text in plain text and never rotates**

- **Severity:** Low
- **Status:** Fixed
- **Area:** `Sources/TabType/Core/ScreenContextProvider.swift:213`, `Sources/TabType/Core/Log.swift`

**Observed**

- On every launch, the info-level log (not only verbose) writes the first 60 characters of OCR text from the frontmost window. Example: `screen self-test: OCR 3055 chars from Ghostty — "* Apps not covered in tabtype…"`.
- With verbose logging on, raw model output that contains the user's text is written in plain text. The Advanced pane does not warn about this.
- `Log.swift` only appends. There is no size cap or rotation.

**Why it matters:** The Personalization pane says collected data is encrypted. The log in `~/Library/Logs/TabType/tabtype.log` is not encrypted.

**Suggestion:** Log only the character count at info level. Add a note under the Verbose logging toggle. Cap or rotate the log file.

**Fix:**

- The self-test line logs only the character count and the app name, for example `screen self-test: OCR 152 chars from TextEdit`.
- When the log is over 5 MB, `Log.write` moves it to `tabtype.log.1`, replacing any older copy, and starts a new file. This was verified by padding the log to 5.3 MB.
- Advanced ▸ Diagnostics now says "Writes your typed text and model output to the log file in plain text."

## TT-008

**Model catalog gives conflicting recommendations**

- **Severity:** Low
- **Status:** Fixed
- **Area:** `Sources/TabType/Model/ModelCatalog.swift:30`, `Sources/TabType/Model/HardwareInfo.swift:36`

**Observed** (Settings ▸ Engine & Model)

- The 4-bit entry text says "Recommended." The 8-bit entry shows the "Best for you" badge.
- The 8-bit entry says "Needs 16 GB+ RAM", but `recommendedModelId` recommends it only at 24 GB and above. The README also says 24 GB+.

**Fix:** The hard-coded "Recommended." (4-bit) and "TabType default." (Qwen2.5 3B) notes are removed. The 8-bit note now says "Recommended on 24 GB+ Macs." The "Best for you" badge is now the only recommendation. The README download range is now ~0.3–4.3 GB, which covers the 1.5B and 0.5B tiers.

## TT-009

**Setup pane says "Free — no upgrade required"**

- **Severity:** Low (copy)
- **Status:** Fixed. The parenthetical is removed.
- **Area:** `Sources/TabType/UI/Panes/SetupPane.swift:64`

The clipboard option ends with "(Free — no upgrade required.)". TabType has no paid tier, so the text suggests one exists. Remove the parenthetical.

## TT-010

**Settings window resizes on the Apps pane and does not resize back**

- **Severity:** Low (cosmetic)
- **Status:** Fixed

**Steps to reproduce**

1. Open Settings. The window is 760 × 648 at x = 900.
2. Select Apps. The window becomes 980 × 648 and moves to x = 790.
3. Select General. The window stays 980 pt wide.

Also, the window title is "TabType Settings" on the Setup pane but shows the pane name on every other pane.

**Cause:** `resizeSettings` returned early when the window was not visible. The log showed that resize requests made while TabType was hidden were dropped, so the window stayed 980 pt wide.

**Fix:** A hidden window is now resized without animation instead of being skipped. The hard-coded title is replaced with the name of the pane the window opens on, because SwiftUI's `navigationTitle` reaches the window only after a selection change. The title fallback is now `.setup`.

**Retest:** Apps sets the width to 980. General, Setup, and Statistics set it back to 760, including after TabType was hidden and shown again on the Apps pane. The title matches the selected pane, including Setup.

## TT-011

**Apps list includes TabType itself**

- **Severity:** Low
- **Status:** Fixed. The running-apps list now skips `Bundle.main.bundleIdentifier`.

Settings ▸ Apps lists TabType as an app that can be configured. TabType never shows suggestions in its own windows, so this row has no effect. Filter out the app's own bundle ID.

## TT-012

**Six compiler warnings in project sources**

- **Severity:** Low
- **Status:** Fixed

| File | Warning |
|---|---|
| `Sources/TabType/Core/Engine.swift:1677` | `split` is never mutated; use `let` |
| `Sources/TabType/Model/HardwareInfo.swift:18` | `init(cString:)` is deprecated |
| `Sources/TabType/UI/OnboardingView.swift:10` | `Publishers` / `Autoconnect` used without `import Combine` (2 warnings) |
| `Sources/TabType/UI/Panes/SetupPane.swift:13` | `Publishers` / `Autoconnect` used without `import Combine` (2 warnings) |

**Fix:** All six are fixed. A full recompile also showed four warnings not listed above. Three are fixed: an unused `flags` in `ExtraPanes.swift`, `var logits` in `Predictor.swift`, and the deprecated `GenerationOptions(sampling:)` in `FoundationModelEngine.swift` and `GenCLI/main.swift`. The deprecated MLX `generate` call at `Predictor.swift:322` remains.

## TT-013

**Extra gap between accepted word and remaining ghost**

- **Severity:** Low
- **Status:** Confirmed. Not fixed.

After Tab accepted "review" in TextEdit, the gap before the remaining ghost (" it this morning…") was about 1.5 times a normal space. The document text was correct (`…to review`, no trailing space). The single-line path adds `padding` after the caret and the ghost also starts with a space, which may double the gap.

**Retest:** Reproduced in TextEdit after the overlay change, both after a Tab accept and during a type-through. After typing `r`, the ghost `eview` started about 4.6 pt right of `caret.minX`. A real next glyph would start at `caret.minX`.

**Cause:** Line 1 starts at `caret.maxX + padding`, which is `caret.minX + 2`. The `NSTextField` label then insets its text by about 2 pt more. Together these add about 4 pt, which is more than one space at 12 pt.

**Possible fix:** Start line 1 at `caret.minX` minus the label's text inset. Check the result in Electron apps and in mirror mode, where the caret replica sits between the typed text and the ghost.

## TT-014

**Ad-hoc signed rebuilds lose the Accessibility grant**

- **Severity:** Low (developer experience)
- **Status:** Fixed
- **Area:** `Scripts/build.sh`

When the "TabType Dev" signing identity is missing, `build.sh` signs ad-hoc. The rebuilt app then starts with `ax=false`, and Accessibility must be granted again. The script prints one line about this, which is easy to miss.

**Suggestion:** Print a visible warning after the build, or stop with a prompt to run `Scripts/setup-signing.sh` unless an override variable is set.

**Fix:** After an ad-hoc signature, `build.sh` prints a boxed warning to stderr as its last output. The warning says that Accessibility must be granted again and that `Scripts/setup-signing.sh` keeps the grant. The build does not fail. This was verified with `SIGN_IDENTITY=nonexistent`.

## TT-015

**Most generation requests are deferred because the model is busy**

- **Severity:** Info
- **Status:** Partly fixed

Settings ▸ Statistics after this session:

| Metric | Value |
|---|---|
| Generations requested | 232 |
| Deferred (model busy) | 178 |
| Superseded by newer input | 62 |
| Rejected (echo) | 22 |
| Show rate | 21% |

About 77% of requests were deferred. This may be expected with continuous generation, but it is worth checking whether deferred requests delay suggestions after typing stops.

**Finding:** A high deferral count is expected. In continuous mode, every keystroke requests a generation, and a request that arrives while the model is busy is counted as deferred. A related bug was found in `Predictor.finishGeneration`. The check `pendingGeneration >= myGen` was always true, so a queued request ran even after `cancel()` had marked it stale. Each stale request cost one full generation before the current input could be generated.

**Fix:** The queued request runs only when `pendingGeneration == generation`, which means no `cancel()` has happened since it was queued. `Engine` calls `cancel()` in `clearSuggestion()` before it schedules the next prediction, so the newest request is not dropped. A stale queued request is now cleared.

**Next step:** Compare the Statistics numbers after a similar session.

## TT-016

**Claude Desktop context shows the sidebar instead of the conversation**

- **Severity:** High
- **Status:** Fixed (verified live in Claude Desktop)

**Steps:** Open a Claude Desktop chat with a long reply. Switch to Claude from another app, click the composer, and type a follow-up.

**Evidence:** The `<on_screen>` block held sidebar chat titles ("Research paper search", "LinkedIn PM job digest") mixed with fragments of an older reply and the composer chrome ("Opus 5.5 Medium", "Add folder"). The latest reply was missing. Suggestions drifted to on-screen topics, for example "about the new AI ethics framework rollout?".

**Causes:**

1. On an app switch, the focused element can be the whole web area rather than the composer. The column filter used that element's frame, which spans the sidebar. When the AX walk failed, the OCR fallback ran without a caret and read the whole window, sorted by y. Sidebar rows and conversation rows were interleaved.
2. Claude Desktop clamps the AX frames of scrolled-off rows to the top edge of the scroll view, so many rows share one y. `TranscriptExtractor.assemble` broke ties by x, which scrambled the transcript. The breadth-first walk also stopped at its character budget before it reached the newest reply.
3. An unchanged conversation was never re-stored. After `maxAge` (150 s) its snapshot expired, and each new capture was dropped as a duplicate of the expired entry. The prompt then had no conversation context at all.
4. The mid-burst freeze blocked every capture that a prediction triggered, because predictions run less than 1 s after a keystroke. A reply that streamed in after sending was not captured while the user composed the next message.

**Fix:**

1. Chat apps capture only when a text input has focus. `ScreenContextProvider.columnAnchor` rejects fields that span more than 80% of the window. The OCR fallback filters by that column when no caret is known.
2. The transcript walk is a reverse depth-first walk, so text is collected newest first and the budget drops the oldest rows. Rows with equal y keep document order.
3. A capture that matches the stored snapshot refreshes that snapshot's age.
4. One capture per 15 s is allowed even while the user is typing.

**Verification:** Tested in Claude Desktop on two chats. The prompt contained only conversation text, including the newest reply. The follow-up suggestion used that reply: "consumer doesn't trust AI to make personal decisions".

## TT-017

**GPU memory grows to 20+ GB during a session**

- **Severity:** High
- **Status:** Fixed (verified with `tabtype-gencli --memtest` and the running app)

**Steps:** Run TabType with `mlx-community/Qwen3-4B-Instruct-2507-8bit` on a 64 GB Mac. Type in several apps for about 15 minutes, so the prompt length changes often.

**Evidence:** `footprint` reported 21 GB for TabType after 14 minutes. Of that, 20.7 GB was `IOAccelerator (graphics)`, which holds MLX Metal buffers. The model weights are 4 GB on disk.

**Cause:** MLX keeps freed GPU buffers in a cache for reuse. The cache limit defaults to the memory limit, which is 1.5 times the recommended working set (62 GB on this Mac). Each prefill of a different prompt length frees intermediate buffers of new sizes, so the cache kept growing. TabType never set a cache limit.

`tabtype-gencli --memtest 40` prefills prompts of 100 to 1,500 tokens:

| Cache limit | Cache after 40 rounds | Active | Average latency |
|---|---|---|---|
| Default (62 GB) | 13,218 MB | about 4,100 MB | 2,913 ms |
| 512 MB | 512 MB | about 4,100 MB | 2,334 ms |

Active memory was the same in both runs, so no arrays leaked. Only the cache grew.

**Fix:** `Predictor.init` sets `Memory.cacheLimit` to `Predictor.gpuCacheLimit` (512 MB). With verbose logging on, each generation logs a `gpu mem:` line with active, cache, and peak memory.

**Verification:** After relaunch, the app footprint was 5.0 GB, and every `gpu mem:` line showed the cache at or below 512 MB. The latency test showed no slowdown. Live typing through computer use was not run because another session held the computer-use lock.

## TT-018

**Onboarding chips do not show which choices are selected**

- **Severity:** Medium
- **Status:** Open

**Steps:** Delete `onboardingProfile` and launch TabType. Click "Personalize TabType". Click Emails, Engineer, and Concise.

**Evidence:** The clicks register. A temporary log line in the chip action recorded each tap, and "Start quick picks" became enabled after all three groups had a choice. The chips themselves did not change: selected and unselected chips looked the same in the running app. A user cannot see which writing types are on, and clicking a writing type twice silently turns it off again.

**Cause (likely, not confirmed):** `OnboardingView.chip` shows selection only through `.tint(selected ? .accentColor : .secondary)` on a `.bordered` button. On macOS, a non-prominent bordered button does not apply the tint.

**Suggested fix:** Show selection with a style that macOS renders, for example `.borderedProminent` for selected chips, or a checkmark next to the title. The `.isSelected` accessibility trait is already set.

**Verification note:** Found while verifying onboarding personalization through computer use. Computer use cannot request TabType, because it is a menu-bar (`.accessory`) app. The test used a temporary, uncommitted patch that launched TabType with the `.regular` activation policy.
