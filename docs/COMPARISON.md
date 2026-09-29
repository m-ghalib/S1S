# S1S vs the alternatives

An honest, detailed comparison. S1S's goal is Cotypist-grade quality as a free, open-source, on-device app. This page is kept truthful — including where others still lead.

## S1S vs Cotypist

[Cotypist](https://cotypist.app/) is the closest product and our reference point. It is closed-source and freemium; S1S is open-source (MIT) and free with no account.

| Capability | S1S | Cotypist |
|---|:---:|:---:|
| On-device local LLM | ✅ Qwen3.5 / Gemma 4 (MLX) | ✅ |
| Apple Intelligence engine | ✅ (macOS 26) | ✅ |
| Ghost-text, word-by-word accept | ✅ | ✅ |
| Type-through (updates as you type) | ✅ | ✅ |
| Word alternatives | ✅ ⌃⌥Space | ✅ |
| Screen context (OCR) | ✅ | ✅ |
| Accessibility-tree transcript for chat apps | ✅ | ✅ |
| Your recent messages / previous writing as context | ✅ | ✅ |
| Personal phrase memory & few-shot | ✅ | ✅ |
| Speculative "parked" generation + KV cache | ✅ | ✅ |
| Text mirroring (pixel-perfect ghost) | ✅ | ✅ |
| Per-app & per-domain policies | ✅ | ✅ |
| Emoji / autocorrect | ✅ (+ Indian languages) | partial |
| Notarized, App Store-smooth install | ❌ (alpha, unnotarized) | ✅ |
| Breadth of tested apps & polish | ⚠️ growing | ✅ mature |
| In-app auto-update | ❌ (manual for now) | ✅ |

**Where Cotypist still leads:** it's notarized (no Gatekeeper dance), more polished, tested across more apps, and has auto-update. S1S is an alpha closing that gap in the open.

## S1S vs other open-source / indie tools

- **[Sombra](https://github.com/andlsac/Sombra)** — llama.cpp + macOS dictionary completions. Great lightweight approach; S1S adds richer context (AX transcripts, recent messages), speculative parking, and mirror rendering.
- **[KeyType](https://github.com/johnbean393/KeyType)** — explores constrained/grammar decoding. Impressive technique; S1S prioritizes context quality and per-app UX parity instead.
- **cotabby** — focused-window OCR context. S1S extends this with accessibility-tree extraction (cleaner than OCR) and per-app extraction policies.

## S1S vs GitHub Copilot / macOS predictive text

- **Copilot & code assistants** — optimized for code in editors, often cloud-backed. S1S is for **prose, everywhere, fully private**, and deliberately stays out of the main code editor.
- **macOS inline predictive text** — single-word, OS-limited. S1S predicts multi-word continuations with real context.

*Have a correction? This comparison should stay honest — open an issue.*
