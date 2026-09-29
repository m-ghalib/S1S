---
name: add-app
description: |
  Adds S1S support for a new macOS app or website, then verifies it live in
  the running app through computer use. Covers bundle-ID lookup, AX probing, the
  AppPolicy change and its XCTest, build and relaunch, the ghost-text test matrix,
  and recording defects in docs/ISSUES.md.
  USE WHEN the user says "add <app> to s1s", "support <app>", "add <site> as a
  chat domain", "s1s never works in <app>", "/add-app", or asks to extend app
  or website coverage and test it. Not for regressions in an app that already
  worked; debug those from the log instead.
argument-hint: "<app name | bundle id | website host>"
---

# Add an app or website to S1S

Scripts live in `.claude/skills/add-app/scripts/`. Run everything from the repo root. `$S` below is the session scratchpad directory.

A change counts as done only after it is seen working in the target app. Past policy commits (8622b99, bf40ecb) shipped with `swift test` only and needed follow-up fixes.

## 1. Pin down the target and the pass bar

1. Identify each target: an app (bundle ID) or a website (host).
2. If the request names a category ("Electron apps", "chat apps"), ask which apps to cover. Past scope answers were narrower than the offer ("Superhuman only for now").
3. Before coding, state the pass bar for each target:
   - The text surface: for example, the main editor or the sidebar chat panel.
   - The ghost form: inline ghost, or a bubble above the caret (Electron apps with `laggyCaret` may show a bubble).
   - Tab success: the inserted text is exactly the text that was shown.
   - The surfaces that must stay silent: for example, code files in an editor, or password fields.

## 2. Find the bundle ID or host

- Installed app:
  ```sh
  osascript -e 'id of app "<App>"'
  plutil -extract CFBundleIdentifier raw -o - "/Applications/<App>.app/Contents/Info.plist"   # cross-check
  ```
- App that is not installed: find the ID in a public source (the app's source repository, appcatalog.cloud, `apple/password-manager-resources`). Put the source URL in the commit body, because the code carries no provenance comments. If no source confirms the ID, report it as unverified. Never guess an ID.
- Website: use the registrable host (`claude.ai`, not `https://claude.ai/new`). Host matching is exact or dot-suffix, so `linkedin.com` covers all of LinkedIn.

## 3. Probe accessibility before touching code

1. Ask the user to open the app and put the caret in the target field, or do it through computer use.
2. Run the probe 2–3 times:
   ```sh
   DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift .claude/skills/add-app/scripts/ax-probe.swift <bundle-id>
   ```
3. Read the output:

| Probe result | Meaning |
|---|---|
| `focused element: NONE` | App not frontmost, or the field is not focused. Retry. |
| Role `AXTextArea`/`AXTextField`, a valid `AXSelectedTextRange`, caret bounds present | Supportable. Continue. |
| Caret `loc=0` in a non-empty field | Blocker (Ghostty case). A policy cannot fix it. Report it and stop. |
| No `AXSelectedTextRange`, or caret bounds show an error | Blocker for inline placement. Report it and ask how to proceed. |
| `AXSecureTextField` | S1S stays silent by design. |
| `web area: AXURL=…` for a site | Domain policies can apply. If AXURL is missing, the host is nil and no domain policy fires. |

## 4. Choose the policy

Edit `Sources/S1S/Core/AppPolicy.swift`. Most apps need only membership in existing sets in `AppPolicyStore`:

| App kind | Sets to join | Resulting traits |
|---|---|---|
| Chat or messaging | `chatApps` | `forceScreenContext`, `transcriptViaAX`, `screenContextCap = 1400` |
| Long-form writing | `documentApps` | `documentProfile`, `inputContextChars = 2000` |
| Electron or Chromium-based app | `electronApps` (+ `pasteApps`) | `laggyCaret`, no mid-line, `splitWrap` if also a document app; paste insertion |
| Electron chat composer that must wrap | `wrappingComposerApps` | `splitWrap` + `wrapBelowField` |
| Chromium browser | `chromiumBrowsers` | Paste insertion |
| Code editor | `codeEditorApps` or `codeEditorBundlePrefixes` | `chatPanelsOnly` (log: `chat-panels-only:`) |
| Editor that should suggest only in `.md` files | `markdownEditorApps` | `markdownFilesOnly` (checks the window title) |
| Terminal | `terminals` | Off by default; the user can re-enable it |
| Password manager | `passwordManagers` | Always off; user overrides are ignored |
| Chat website | `chatDomains` | Full chat treatment for that host in any browser |

- An app can join several sets (Obsidian is document + Electron + paste).
- Font metrics: `fontFactor`, `verticalOffset`, and `fontSizeRatio` exist. Only Safari sets one (`fontFactor = 0.98`). Change them only after a capture shows a size or baseline mismatch.
- New behavior needs a new `AppPolicy` flag. The flag must be read in `Engine.swift` or `SuggestionOverlay.swift`, and it must be reflected in `summaryLines` if users should see it. Put pure logic in a static helper so it can be tested.

## 5. Add the unit test

1. Add `test<App>Policy` to `Tests/S1STests/AppPolicyTests.swift` under a `// MARK: - <App>` header. Follow `testObsidianPolicy` and `testClaudeDesktopPolicy`. For a website, follow `testXAndLinkedInGetChatTreatmentInChrome`, including a negative host.
2. Run the tests:
   ```sh
   DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
   ```
3. If `swift test` fails on a stale Metal toolchain mount, run `swift package clean` and retry outside the sandbox.

## 6. Build and relaunch

1. Build and check the signature:
   ```sh
   ./Scripts/build.sh app > "$S/build.log" 2>&1; echo exit=$?
   grep -E "error:|Signing" "$S/build.log"
   ```
   Apply the signing check from CLAUDE.md's testing step 1. If the build is ad-hoc, stop and tell the user. Never run `setup-signing.sh` yourself (see `RELEASING.md`).
2. Note the current logging setting, because `relaunch.sh` turns verbose logging on and verbose logs store screen text: `defaults read app.s1s.S1S verboseLog`.
3. Relaunch and wait for warm-up:
   ```sh
   .claude/skills/add-app/scripts/relaunch.sh ADD-<app>
   ```
   The script prints the launch line, the warm-up line, and the running binary path. The path must be the repo's `dist/S1S.app`, not a copy in `~/Applications`.
4. If the script reports `ax=false`, ask the user to grant Accessibility (and Screen Recording if `screen=false`). Do not click the grant dialogs yourself. After the user grants access, run `relaunch.sh` again, because a running instance does not pick up a new grant.

## 7. Verify live with computer use

### Setup

1. Load the tools with one call: `ToolSearch` query `computer-use`, `max_results` 30.
2. Call `request_access` for the target app, plus TextEdit and Notes if you changed shared code. Follow CLAUDE.md's testing step 5: never request S1S itself.
3. Start a log watch for this app:
   ```sh
   grep -E "placement app=<bundle-id>|predict app=<bundle-id>|predict -> |chat-panels-only|skipped" ~/Library/Logs/S1S/s1s.log | tail -20
   ```

### Capture the ghost with `shot.sh`, not `screenshot`

CLAUDE.md's testing step 6 explains why computer-use `screenshot` cannot show the ghost. Capture with:
```sh
.claude/skills/add-app/scripts/shot.sh "$S/a1.png" window "<Process Name>"
.claude/skills/add-app/scripts/shot.sh "$S/a1c.png" rect <x> <y> <w> <h>   # e.g. fieldRect from the placement line
```
Then `Read` the PNG. `rect` takes global screen points, either as four numbers or as the `fieldRect=(x, y, w, h)` tuple copied from a `placement` log line, quoted as one argument.

### Test matrix

Type with `computer_batch`: `[{type: "<phrase>"}, {wait: 3}]`. Then capture with `shot.sh` and check the log. Use a phrase that fits the app: chat `Thanks for sending this over, I will`; document `We discussed the launch timeline and agreed that the team`; email `Hi Sarah, thanks for the quarterly report. I had a chance to`.

| # | Check | Pass when |
|---|---|---|
| 1 | Ghost appears | A `predict -> "…"` line appears and the capture shows the ghost within about 1 s of the pause |
| 2 | Placement | The ghost starts at the caret, on the text baseline, and does not overlap typed text. A bubble is acceptable only if the pass bar allows it |
| 3 | Wrap | After you type near the right edge, continuation lines stay inside the window and are not clipped (`wrap=true` in the placement line) |
| 4 | Type-through | Typing the next letters of the ghost shrinks it in place |
| 5 | Tab | Exactly one word is inserted, with no stray tab character |
| 6 | Shift+Tab | The whole remaining suggestion is inserted exactly |
| 7 | Esc | The ghost disappears and no text changes |
| 8 | Silent surfaces | No ghost appears, and Tab behaves natively on each surface that must stay silent |
| 9 | Regression (only if `Engine.swift` or `SuggestionOverlay.swift` changed) | Rows 1–7 pass in TextEdit and Notes |

- Verify the inserted text, not the look of it:
  - Scriptable apps: `osascript -e 'tell application "TextEdit" to get text of front document'`.
  - Other apps: read the `AXValue` line from `ax-probe.swift <bundle-id> --no-activate`.
- To reset a field: `cmd+a`, then `Delete`.
- If a capture looks stale, type one more character and capture again.
- If the screen is black, ask the user whether the display is locked. With several displays, move the target window to a known position first.

### Websites and browsers

Computer use grants browsers read-only access. Do not work around this with `osascript` keystrokes or synthetic CGEvent clicks.

S1S sees keys through a CGEventTap. Playwright and other DOM or CDP typing never reach it. Use this order:
1. Open the page with the Safari MCP (`safari_navigate`) and focus the field with `safari_click`. If the site needs a login, ask the user to log in.
2. Type with `safari_native_type` and press keys with `safari_native_keyboard`. Confirm that `predict app=com.apple.Safari` appears in the log. If it does not appear, these tools do not post OS-level keys; go to step 3.
3. Otherwise, hand off to the user: ask them to type the test phrase, pause, and then press Tab, Shift+Tab, or Esc. Capture each state with `shot.sh` and read the log after each one.

Chromium browsers read the same way. Check that the `predict app=` line shows the browser's bundle ID and that the probe reports the expected `AXURL` host.

## 8. Record and report

1. Record each defect in `docs/ISSUES.md` as the next `TT-###`. Copy the existing layout:
   - Add a row to the Summary table.
   - Give each entry a bold title, **Severity** (with a reason), **Status**, **Area** (file and function), numbered **Steps to reproduce** with the exact typed text, **Expected**, **Actual**, and **Evidence** (log lines in a code block).
   - After a fix, add **Fix** and **Retest** lines.
2. Tell the user about test residue: typed notes, open documents, and messages in chat drafts. Never send a message, email, or post in the target app.
3. Report to the user:
   - A pass or fail for each row of the matrix, with the capture path and the log line that shows it.
   - Any unverified bundle IDs, and any blockers.
   - Anything you could not drive yourself (for example, browser typing that was handed off).
4. Restore `verboseLog` to the value noted in step 6. If it was unset, run `defaults delete app.s1s.S1S verboseLog`.
5. Commit only when the user asks. Use this format:
   - Subject: `feat: add <App> support` or `fix: <symptom> in <App>`.
   - Body: bullets of the form "<App> gets <traits>", plus bundle-ID sources.
   - Trailer: the Co-Authored-By line.
   - If the user also asks for a cleanup, run `/simplify-jj` after the feature commit. It makes a separate `tidy: simplify …` commit.
