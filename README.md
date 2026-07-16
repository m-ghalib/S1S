<div align="center">

# ⌨️ TabType

### A free, open-source, 100% on-device AI autocomplete for macOS

**TabType predicts your next words as you type — in almost any app — and runs entirely on your Mac. No cloud. No account. No subscription. No telemetry.** It's an open-source [Cotypist](https://cotypist.app/) alternative that learns your voice and never sends a keystroke off your machine.

![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)
![Platform: macOS 14+](https://img.shields.io/badge/Platform-macOS%2014%2B-black?logo=apple)
![Apple Silicon](https://img.shields.io/badge/Apple%20Silicon-M1%E2%80%93M4-blue)
![Status: Alpha](https://img.shields.io/badge/Status-Alpha-orange)
![Built with MLX](https://img.shields.io/badge/Built%20with-MLX-red)

<em>Keywords: Cotypist alternative · open source macOS autocomplete · local AI text prediction Mac · on-device LLM typing assistant · private ghost-text completion</em>

<!-- TODO: add a demo.gif of ghost text being accepted with Tab -->

</div>

---

> [!WARNING]
> **TabType is an early alpha.** It works and it's genuinely useful day-to-day, but expect rough edges. This is an open-source project that **needs your help** — [try it](#-install), [file issues](../../issues), and [send PRs](CONTRIBUTING.md). Your bug reports on specific apps are the single most valuable contribution right now.

## What it is

As you type, TabType shows a dimmed **ghost-text** prediction of what comes next. Press **Tab** to accept a word, again for the next, or accept the whole thing at once. A local language model ([Qwen3-4B](https://huggingface.co/mlx-community/Qwen3-4B-Instruct-2507-4bit) via Apple's [MLX](https://github.com/ml-explore/mlx)) generates the suggestions, personalized to how *you* write — and it all happens on-device.

## ✨ Features

**Completions**
- Inline ghost text everywhere you type, with pixel-matched placement and a text-mirroring mode for web apps
- Type-through: keep typing and the suggestion shrinks to match, never flickers
- Word-by-word or whole-suggestion accept; **word alternatives** popup (⌃⌥Space) when you want options
- Instant dictionary + learned-phrase completions while the model works (zero latency)

**Context awareness** — suggestions that actually fit what you're doing
- Reads the document/conversation around your cursor — via the **accessibility tree** in chat apps (clean, no screenshots) or on-device screenshot OCR elsewhere
- Remembers **your recent messages** in a conversation and **your previous writing** so it continues your train of thought
- **Phrase memory** learns names, sign-offs, and jargon you type often

**Private by design**
- 100% on-device inference; the only network call is the one-time model download from Hugging Face
- Optional typing history is **encrypted** in your Keychain and never leaves the Mac
- Password fields and password managers are never read

**Models**
- Curated [MLX](https://github.com/ml-explore/mlx) catalog (Qwen3, Gemma) + load any custom Hugging Face model
- Optional **Apple Intelligence** engine on supported macOS 26 Macs (no download)

**Control**
- Per-app and per-website policies (tone, language, enable/disable, mid-line behavior)
- Code editors get suggestions only in chat panels, never the main editor
- Low Power Mode tuning, force-activate & per-app pause shortcuts
- Inline `/macros` (`/date`, `/uuid`, `10km->mi`, `2+2*3`), `:emoji`, and local autocorrect (incl. 6 Indian languages)

## 🆚 How TabType compares

| | **TabType** | **Cotypist** | **Copilot / OS predictive text** |
|---|:---:|:---:|:---:|
| Price | **Free forever** | Freemium (paid tier) | Free / paid |
| Open source | **✅ MIT** | ❌ | ❌ |
| Runs on-device | ✅ | ✅ | ⚠️ mixed |
| Works in any app (prose) | ✅ | ✅ | ❌ code / single-word |
| Learns your voice | ✅ | ✅ | ❌ |
| Screen / conversation context | ✅ AX tree + OCR | ✅ | ❌ |
| Notarized / polished | ⚠️ alpha, unnotarized | ✅ | ✅ |

**vs [Cotypist](https://cotypist.app/)** — the closest comparison and our north star. TabType matches its core: on-device models, screen/accessibility context, personalization, text mirroring, speculative "parked" generation, and word alternatives. Cotypist is more polished, notarized, and has a paid tier; TabType is **free, open-source, and account-free**. We're the open project working toward Cotypist-grade quality — [detailed comparison](docs/COMPARISON.md).

**vs other indie/OSS attempts** — [Sombra](https://github.com/andlsac/Sombra) (llama.cpp + dictionary), [KeyType](https://github.com/johnbean393/KeyType) (constrained decoding), cotabby (focused-window OCR). TabType goes further with accessibility-tree transcript extraction, per-app extraction policies, KV-cache speculative parking, and baseline-probed / mirror rendering. Credit and thanks to all of them for showing what's possible.

## 📦 Install

> [!NOTE]
> TabType has no Apple Developer account behind it (it's free and non-commercial — see below), so it is **not notarized**. macOS will warn you the first time. This is expected for open-source Mac apps; here's the one-time approval.

1. **Download** the latest `TabType-x.y.z.dmg` from [Releases](../../releases).
2. Open the DMG and **drag TabType to Applications**.
3. Launch it. macOS says *"TabType cannot be opened because Apple cannot check it for malicious software."* Click **Done** (not Move to Trash).
4. Open **System Settings ▸ Privacy & Security**, scroll down, and click **"Open Anyway"** next to TabType. Confirm.
   - *Power users, instead of steps 3–4:* `xattr -dr com.apple.quarantine /Applications/TabType.app`
5. Grant **Accessibility** when prompted (required — it's how TabType reads the text field and inserts completions). **Screen Recording** is optional (improves context in non-chat apps).
6. **First launch downloads the model** (~2.3 GB from Hugging Face). The menu-bar icon shows progress; suggestions start once it's ready.

**Requirements:** Apple Silicon Mac (M1 or later), macOS 14+.

## 🔒 Privacy

Nothing you type leaves your machine. Inference is 100% local. The only network request TabType ever makes is downloading the model from Hugging Face on first run. Typing history (opt-in, off by default) is AES-encrypted with a key in your Keychain.

## 🛠 Build from source

```sh
# One-time: point at full Xcode + install the Metal toolchain (MLX compiles Metal shaders)
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
xcodebuild -downloadComponent MetalToolchain

# One-time: stable self-signed identity so macOS keeps your permission grants across builds
./Scripts/setup-signing.sh

# Build + run
./Scripts/build.sh app && open dist/TabType.app

# Run tests
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

> `swift build` alone won't produce a runnable app — MLX's Metal kernels require `xcodebuild`.

## 🏗 Architecture

The pipeline, end to end:

```
KeystrokeMonitor (CGEventTap)
   → ContextReader / ScreenContextProvider / TranscriptExtractor   (what you typed + surrounding context)
   → PromptBuilder                                                 (budgeted prompt assembly)
   → Predictor (MLX) with KV-prefix cache + speculative parking    (local generation)
   → SuggestionOverlay                                             (baseline-probed ghost / mirror render)
```

Personalization (`PhraseMemory`, `TypingHistoryStore`), per-app rules (`AppPolicy`), and the settings UI (`SettingsView`) hang off this core. See [CONTRIBUTING.md](CONTRIBUTING.md) for a fuller tour.

## 🙋 Full disclosure — who built this, and how

TabType is built by a **senior full-stack engineer with 5+ years of experience**, in the open, **with heavy use of AI coding assistance**. Full transparency: AI was a genuine power tool throughout — but this is **not** a thin "AI-generated a wrapper" app. It's a real native macOS application with a hand-tuned local-inference pipeline, reverse-engineering work to reach UX parity with the best in the category, careful accessibility/Gatekeeper/AppKit integration, and 50+ tests. The engineering judgment, debugging, architecture, and the hundreds of small correctness decisions are the author's. AI accelerated the typing; it didn't replace the engineering.

## 🤝 Contributing

This is an alpha that wants collaborators. Great first contributions: per-app extraction recipes for apps that misbehave, more autocorrect languages, UI polish, and — if you have an Apple Developer ID — help with notarization. See [CONTRIBUTING.md](CONTRIBUTING.md).

## 📄 License

[MIT](LICENSE) — free for anyone to use, modify, and distribute. **There is no paid tier and no plan to ever commercialize TabType.** Built for the community.

## 🙏 Credits

[MLX](https://github.com/ml-explore/mlx) & [mlx-swift](https://github.com/ml-explore/mlx-swift-examples) · [Qwen](https://github.com/QwenLM/Qwen) & [Gemma](https://ai.google.dev/gemma) models · [swift-transformers](https://github.com/huggingface/swift-transformers). Inspiration from [Cotypist](https://cotypist.app/), [Sombra](https://github.com/andlsac/Sombra), and [KeyType](https://github.com/johnbean393/KeyType).
