import Foundation

/// A curated list of MLX-community models suitable for local autocomplete.
struct CatalogModel: Identifiable, Hashable {
    var id: String            // Hugging Face repo id
    var name: String          // display name
    var approxSize: String    // download size hint
    var note: String          // speed/quality hint
    /// Pure text continuer (no chat tuning) — best for autocomplete. Instruct models
    /// are included for breadth but may occasionally reply instead of continuing text.
    var isBase: Bool = true
}

enum ModelCatalog {
    /// Small, fast — recommended tier. Instruct-tuned models, prompted via a real
    /// system/user chat template (see `Predictor.swift`/`CompletionInstructions.swift`)
    /// — this matches how Cotypist itself actually completes text (verified by
    /// inspecting its installed binary: it runs instruct-tuned llama.cpp models with a
    /// real chat-template prompt, not raw base-model continuation). All ids below were
    /// verified live against the mlx-community Hugging Face repos and confirmed to ship
    /// a usable `chat_template` (either embedded in `tokenizer_config.json` or as a
    /// separate `chat_template.jinja`, both of which `swift-transformers` loads).
    static let recommended: [CatalogModel] = [
        CatalogModel(id: "mlx-community/gemma-4-e4b-it-4bit", name: "Gemma 4 E4B (instruct)",
                     approxSize: "~5.2 GB", note: "Best quality of the recommended tier.", isBase: false),
        CatalogModel(id: "mlx-community/gemma-4-e2b-it-4bit", name: "Gemma 4 E2B (instruct)",
                     approxSize: "~3.6 GB", note: "Great balance of quality and speed.", isBase: false),
        CatalogModel(id: "mlx-community/Qwen2.5-3B-Instruct-4bit", name: "Qwen2.5 3B (instruct)",
                     approxSize: "~1.7 GB", note: "Good quality, low latency. TabType default.", isBase: false),
        CatalogModel(id: "mlx-community/Qwen2.5-1.5B-Instruct-4bit", name: "Qwen2.5 1.5B (instruct)",
                     approxSize: "~0.9 GB", note: "Light and quick.", isBase: false),
        CatalogModel(id: "mlx-community/Qwen2.5-0.5B-Instruct-4bit", name: "Qwen2.5 0.5B (instruct)",
                     approxSize: "~0.3 GB", note: "Fastest, lowest quality. Low-RAM Macs.", isBase: false),
    ]

    /// Larger instruct models, and legacy base/pure-continuation models (still fully
    /// supported via raw token continuation — see `Predictor.swift`'s `isBase` branch —
    /// for anyone who already downloaded one before this catalog switched to instruct
    /// models by default).
    static let other: [CatalogModel] = [
        CatalogModel(id: "mlx-community/gemma-4-26b-a4b-it-4bit", name: "Gemma 4 26B-A4B (instruct, MoE)",
                     approxSize: "~15.7 GB", note: "Mixture-of-experts; strong quality for its active size.", isBase: false),
        CatalogModel(id: "mlx-community/Qwen2.5-7B-Instruct-4bit", name: "Qwen2.5 7B (instruct)",
                     approxSize: "~4.2 GB", note: "Best local quality. 16 GB+ Apple Silicon.", isBase: false),
        CatalogModel(id: "mlx-community/gemma-4-12B-it-4bit", name: "Gemma 4 12B (instruct)",
                     approxSize: "~7.1 GB", note: "High quality; needs 16 GB+ RAM.", isBase: false),
        CatalogModel(id: "mlx-community/Qwen3-1.7B-4bit", name: "Qwen3 1.7B (instruct)",
                     approxSize: "~1.0 GB", note: "Newer Qwen generation.", isBase: false),
        CatalogModel(id: "mlx-community/Qwen3-4B-4bit", name: "Qwen3 4B (instruct)",
                     approxSize: "~2.3 GB", note: "Newer Qwen generation.", isBase: false),
        CatalogModel(id: "mlx-community/Qwen3-8B-4bit", name: "Qwen3 8B (instruct)",
                     approxSize: "~4.7 GB", note: "Newer Qwen generation.", isBase: false),
        CatalogModel(id: "mlx-community/Qwen3-30B-A3B-4bit", name: "Qwen3 30B-A3B (instruct, MoE)",
                     approxSize: "~13.7 GB", note: "Mixture-of-experts; fast for its size.", isBase: false),
        CatalogModel(id: "mlx-community/gemma-4-e4b-4bit", name: "Gemma 4 E4B (base, legacy)",
                     approxSize: "~6.2 GB", note: "Raw continuation, no instructions. Prefer the instruct version above."),
        CatalogModel(id: "mlx-community/gemma-4-e2b-4bit", name: "Gemma 4 E2B (base, legacy)",
                     approxSize: "~3.2 GB", note: "Raw continuation, no instructions. Prefer the instruct version above."),
        CatalogModel(id: "mlx-community/Qwen2.5-3B-4bit", name: "Qwen2.5 3B (base, legacy)",
                     approxSize: "~1.7 GB", note: "Raw continuation, no instructions. Prefer the instruct version above."),
        CatalogModel(id: "mlx-community/gemma-3-1b-pt-4bit", name: "Gemma 3 1B (base, legacy)",
                     approxSize: "~0.8 GB", note: "Raw continuation, no instructions."),
        CatalogModel(id: "mlx-community/Qwen2.5-1.5B-4bit", name: "Qwen2.5 1.5B (base, legacy)",
                     approxSize: "~0.9 GB", note: "Raw continuation, no instructions."),
        CatalogModel(id: "mlx-community/Qwen2.5-0.5B-4bit", name: "Qwen2.5 0.5B (base, legacy)",
                     approxSize: "~0.3 GB", note: "Raw continuation, no instructions."),
        CatalogModel(id: "mlx-community/gemma-4-31b-4bit", name: "Gemma 4 31B (base, legacy)",
                     approxSize: "~18 GB", note: "Google's largest Gemma 4 dense model; needs 32 GB+ RAM."),
    ]

    static var all: [CatalogModel] { recommended + other }

    /// The model recommended for this Mac's hardware.
    static var recommendedId: String { HardwareInfo.recommendedModelId }

    static func isRecommended(_ id: String) -> Bool { id == recommendedId }
}
