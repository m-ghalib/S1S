# TabType

On-device AI autocomplete for macOS (Swift 6, SwiftPM, MLX). Menu-bar app that shows ghost-text suggestions in other apps. Bundle ID: `app.tabtype.TabType`.

## Commands

```sh
./Scripts/build.sh app            # build + bundle dist/TabType.app (Debug; CONFIG=Release for release)
./Scripts/build.sh gencli         # build tabtype-gencli (model/prompt harness, no GUI)
./Scripts/release.sh <version>    # Release build + DMG; needs a CHANGELOG section (or use /release)
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

- `swift build` compiles but cannot run the app. MLX Metal kernels need `xcodebuild`, which `build.sh` wraps (derived data in `.build-xcode/`).
- `swift test` covers pure logic only (trimming, prompt budgeting, policies, caret math). It does not prove that UI or overlay behavior works.

## Architecture

```
KeystrokeMonitor → Engine → ContextReader / ScreenContextProvider / TranscriptExtractor
  → PromptBuilder → Predictor (MLX, KV-prefix cache, speculative parking) → SuggestionOverlay
```

- `Sources/TabType/Core/` — engine pipeline. `Engine.swift` is the orchestrator.
- `Core/AppPolicy.swift` — per-app behavior (context recipe, font factor, offsets, enable rules).
- `Core/SuggestionOverlay.swift` — ghost/mirror rendering, wrap logic.
- `Resources/CHANGELOG.md` — bundled release notes, shown in Settings ▸ About ▸ What's New.
- `Model/` — catalog, download, storage. `UI/` — Settings panes. `Settings/AppSettings.swift` — `UserDefaults.standard` keys.
- `Sources/GenCLI/` — standalone inference harness (`--ai "prompt"` tests the Apple Intelligence path).
- `Tests/TabTypeTests/` — put new pure logic in static helpers and add a test here.

## Testing: use computer use

Verify every behavior change in the running app through computer use (`mcp__computer-use__*`). Unit tests alone are not enough, because most bugs are placement, rendering, and focus issues that only appear in real apps.

1. Build: `./Scripts/build.sh app`. Check the output says `Signing with "TabType Dev"`. If it says ad-hoc, the Accessibility grant resets (see Gotchas).
2. Turn on verbose logging: `defaults write app.tabtype.TabType verboseLog -bool true`.
3. Quit any running copy (`pkill -x TabType`), then `open dist/TabType.app`.
4. Confirm the launch line in `~/Library/Logs/TabType/tabtype.log` shows `ax=true`. Wait for `model warm-up finished`.
5. Load computer-use tools in one call (`ToolSearch` query `computer-use`), then `request_access` for the target apps (for example TextEdit and Notes). Do not request TabType: it is a menu-bar accessory, and the request returns `notInstalled`.
6. In the target app, type a phrase, then pause about 1 s. Capture the screen with `screencapture` (or `.claude/skills/add-app/scripts/shot.sh`), because computer-use `screenshot` and `zoom` hide the TabType overlay. Check the ghost text: position, baseline, wrap, clipping.
7. Exercise keys: Tab (accept word), Shift+Tab (accept all), Esc (dismiss), type-through (suggestion shrinks).
8. Cross-check engine decisions with `tail -f ~/Library/Logs/TabType/tabtype.log` (`placement app=…` lines show caret/field rects).

Notes:
- Default test apps: TextEdit and Notes (native), plus the app named in the bug. Browsers are read-only in computer use, so ghost text there can be observed but not driven.
- `screencapture` does not dismiss the ghost.
- Automated typing can drop or merge keys (see TT-004). Retry once before reporting a keystroke bug.
- Record findings in `docs/ISSUES.md` using its TT-### format (severity, status, steps, evidence).

## Gotchas

- **Signing identity.** macOS ties Accessibility/Screen Recording grants to the code identity. Without the `TabType Dev` cert (`./Scripts/setup-signing.sh`, one time), `build.sh` signs ad-hoc and each rebuild launches with `ax=false`. Never re-run `setup-signing.sh` on a machine that already has the cert used for releases; see `RELEASING.md`.
- **Bundle layout.** `build.sh` copies `default.metallib` to `Contents/MacOS/mlx.metallib` and resource bundles to `Contents/Resources`. Moving either breaks GPU inference or `Bundle.module`.
- `swift-jinja` is pinned `<2.4.0` in `Package.swift` for swift-transformers compatibility. Do not bump it without checking.
- Code editors get suggestions only in chat panels (`chat-panels-only` log line). Password fields are never read.
- Keep everything on-device. The only allowed network call is the model download from Hugging Face.
- Ignore `.ouroboros_eval_artifact.md` and `default.profraw`; they are tool artifacts, not project files.
