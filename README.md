# TabType

**Free, open-source, 100% local autocomplete for macOS.** As you type in almost any
app, TabType shows a dimmed "ghost text" prediction of your next words. Press **Tab** to
accept. Everything runs on your Mac using a local language model — no cloud, no account,
no subscription, no ads, no telemetry.

TabType is a free clone of the (paid, closed-source) [Cotypist](https://cotypist.app/).

## Status

Early development. Built and driven phase-by-phase:

- **P0** — project scaffold, MLX inference validated, `.app` bundling. ← in progress
- **P1** — core loop: keystrokes → local model → ghost-text overlay → Tab accepts.
- **P2** — Accessibility-based context + precise caret positioning; broader app coverage.
- **P3** — settings UI, model manager, per-app toggles, launch-at-login, polish.

## Requirements

- Apple Silicon Mac (M1 or later). Developed/tested on M4 Pro.
- macOS 14 or later.
- **Full Xcode** (not just Command Line Tools) — MLX compiles Metal shaders at build
  time. On Xcode 26+, also install the Metal toolchain component (see below).
- ~1 GB free disk for the default model.

## How it works

- **Inference — two engines** (Settings ▸ Model):
  - **Apple Intelligence** (default on macOS 26 Macs that support it) — Apple's
    on-device model via the FoundationModels framework. Best quality, no download.
  - **Local model** — a quantized Qwen2.5 **base** model (pure text continuer) run
    in-process via [MLX Swift](https://github.com/ml-explore/mlx-swift-lm), chosen from
    your RAM (≥32 GB → 7B, ≥16 GB → 3B, ≥8 GB → 1.5B, else 0.5B).
  Both run fully on-device.
- **Per-app behavior:** password fields are never autocompleted; terminals and password
  managers are off by default; some apps use clipboard paste for reliable insertion.
- **Inline text tools** (type, then Tab):
  - **Emoji** — `:rocket` → 🚀 (fuzzy match + recents), full ~1,870-emoji set.
  - **Macros** — `/date`, `/time`, `/now`, `/uuid`, `/dice`, `/random 100`,
    `10km->mi`, `2+2*3`. All offline.
  - **Autocorrect** — clear typos fixed in place on word boundaries (`teh` → `the`),
    via a local 82k-word SymSpell index. Never in password fields.
- **Rebindable shortcuts** — accept-word, accept-whole, dismiss, and a global
  enable/disable toggle, all remappable in Settings ▸ Shortcuts.
- **Personalization** — set your name, writing style, and custom instructions so
  suggestions sound like you; optionally feed clipboard contents as context (off by
  default).
- **Per-site control** — disable suggestions on specific website domains in browsers.
- **Model manager** — download/switch models, see installed size + total disk, delete
  downloaded files (Settings ▸ Engine & Model).
- **Battery-aware** — on Low Power Mode, TabType lengthens its debounce and pauses
  screen capture to conserve energy.
- **Per-app overrides** — searchable app editor (Settings ▸ Apps): enable/mid-line/
  autocorrect/disable-Tab per app, a compatibility switch, and per-app custom
  instructions — plus the per-domain disable list.
- **Statistics** — local-only counters: words completed, suggestions shown/accepted,
  acceptance rate. Never leaves your Mac.
- **TabType Labs** — opt-in experimental toggles (mid-word guard, ultra-fast debounce).
- **Settings** — a sleek sidebar UI (General, Engine & Model, Personalization, Text
  Tools, Emoji, Shortcuts, Battery, Apps, Advanced, TabType Labs, Statistics, About).
- **Reading your text:** the macOS **Accessibility API** reads the focused text field's
  content and caret position (with a keystroke-buffer fallback).
- **On-screen memory:** with Screen Recording permission, TabType periodically captures
  the focused window and reads it with on-device **Vision OCR**, keeping a short rolling
  memory of what you've seen (e.g. a product page in a browser) so suggestions reflect
  it. All local; nothing is uploaded.
- **Blended ghost text:** samples the caret area to match the suggestion's colour to the
  field's real text, so it looks native (toggle in Personalization ▸ Context sources).
- **Showing suggestions:** a borderless overlay window draws ghost text at the caret.
- **Accepting:** a `CGEventTap` intercepts **Tab** only when a suggestion is visible.

Nothing you type leaves your machine.

## Building

```sh
# One-time: point at full Xcode and install the Metal toolchain
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer   # or use DEVELOPER_DIR
xcodebuild -downloadComponent MetalToolchain

# One-time (recommended): stable code-signing identity so macOS keeps your
# Accessibility & Screen Recording grants across rebuilds. Follow the printed
# instruction to trust the cert for Code Signing in Keychain Access.
./Scripts/setup-signing.sh

# Build and bundle the app:
./Scripts/build.sh app
open dist/TabType.app
```

Grant **Accessibility** (required) and **Screen Recording** (recommended — enables the
on-screen memory) when prompted.

> `swift build` alone will **not** work — MLX's Metal kernels require `xcodebuild`.

## Privacy

100% local. No network calls except the one-time model download from Hugging Face.

## License

MIT — see [LICENSE](LICENSE).
