# Contributing to S1S

Thanks for helping! S1S is an **alpha** open-source project and contributions of every size are welcome — bug reports especially.

## Ways to help right now

- **Report app-specific bugs.** "Ghost text is misplaced in _X_" or "no suggestions in _Y_" reports are gold. Include the app, macOS version, and (if you can) a screenshot. Screenshots don't dismiss the ghost.
- **Per-app extraction recipes.** Some apps expose text cleanly, others don't. If an app misbehaves, `AppPolicy.swift` is where per-app behavior lives — small, self-contained additions.
- **More autocorrect languages** (`Sources/S1S/Core/Spelling/`, dictionaries in `Resources/`).
- **UI/UX polish** across the settings panes.
- **Notarization** — if you have an Apple Developer ID and want to help ship notarized builds, please reach out on an issue.

## Building & testing

```sh
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
xcodebuild -downloadComponent MetalToolchain          # one-time
./Scripts/setup-signing.sh                            # one-time, stable local identity
./Scripts/build.sh app && open dist/S1S.app
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

`swift build` compiles but can't run the app (MLX Metal kernels need `xcodebuild`). Use `Scripts/build.sh app`.

## Where things live

| Area | File(s) |
|---|---|
| Keystroke capture + orchestration | `Core/Engine.swift`, `Core/KeystrokeMonitor.swift` |
| Context gathering | `Core/ContextReader.swift`, `Core/ScreenContextProvider.swift`, `Core/TranscriptExtractor.swift` |
| Prompt assembly | `Core/PromptBuilder.swift`, `Core/CompletionInstructions.swift` |
| Local inference | `Core/Predictor.swift`, `Core/Engines/`, `Model/` |
| Rendering | `Core/SuggestionOverlay.swift`, `Core/GhostAppearanceProbe.swift` |
| Personalization | `Core/PhraseMemory.swift`, `Core/TypingHistoryStore.swift` |
| Per-app rules | `Core/AppPolicy.swift` |
| Settings UI | `UI/SettingsView.swift`, `UI/Panes/ExtraPanes.swift` |

The [README architecture section](README.md#-architecture) shows how they connect.

## Conventions

- Match the surrounding style; keep comments about *why*, not *what*.
- Pure logic (trimming, filtering, budgeting, candidate assembly) belongs in testable static helpers — see `Tests/S1STests/`. Add a test when you add such logic.
- Keep everything on-device. No network calls except model download.

## PRs

Small, focused PRs with a clear description. Note which apps/macOS versions you tested on. Run `swift test` before submitting.
