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
    /// Models offered in Settings: the newest generation of each family (Qwen3.5,
    /// Gemma 4) that needs at most 15 GB of memory. Instruct-tuned models, prompted
    /// via a real system/user chat template (see `Predictor.swift`/
    /// `CompletionInstructions.swift`). Every id was checked against the mlx-community
    /// Hugging Face repos and ships a usable `chat_template`.
    ///
    /// Qwen3.5 mixes attention with recurrent layers whose state can't be trimmed, so
    /// the KV prefix cache is rebuilt on every suggestion and the whole prompt is
    /// prefilled each time. That makes it slower than the Qwen3 models it replaces.
    static let all: [CatalogModel] = [
        CatalogModel(id: "mlx-community/Qwen3.5-2B-4bit", name: "Qwen3.5 2B",
                     approxSize: "~1.8 GB", note: "Quickest current model. Good for everyday writing.", isBase: false),
        CatalogModel(id: "mlx-community/Qwen3.5-4B-4bit", name: "Qwen3.5 4B",
                     approxSize: "~3.1 GB", note: "More accurate, about twice as slow as 2B.", isBase: false),
        CatalogModel(id: "mlx-community/Qwen3.5-9B-4bit", name: "Qwen3.5 9B",
                     approxSize: "~6.0 GB", note: "Most accurate Qwen that fits in memory. Slowest.", isBase: false),
        CatalogModel(id: "mlx-community/gemma-4-e2b-it-4bit", name: "Gemma 4 E2B",
                     approxSize: "~3.6 GB", note: "Google's small model.", isBase: false),
        CatalogModel(id: "mlx-community/gemma-4-e4b-it-4bit", name: "Gemma 4 E4B",
                     approxSize: "~5.2 GB", note: "Google's mid-size model.", isBase: false),
        CatalogModel(id: "mlx-community/gemma-4-12B-it-4bit", name: "Gemma 4 12B",
                     approxSize: "~6.7 GB", note: "Google's largest model under 15 GB. Needs 32 GB+ memory.", isBase: false),
    ]

    /// Models no longer offered: previous generations, and models needing more than
    /// 15 GB of memory. A saved choice from this list is replaced with the
    /// recommended model at launch (see `startupModelId`).
    static let retired: [CatalogModel] = [
        CatalogModel(id: "mlx-community/Qwen3-4B-Instruct-2507-4bit", name: "Qwen3 4B Instruct 2507", approxSize: "~2.3 GB", note: "", isBase: false),
        CatalogModel(id: "mlx-community/Qwen3-4B-Instruct-2507-6bit", name: "Qwen3 4B Instruct 2507 (6-bit)", approxSize: "~3.3 GB", note: "", isBase: false),
        CatalogModel(id: "mlx-community/Qwen3-4B-Instruct-2507-8bit", name: "Qwen3 4B Instruct 2507 (8-bit)", approxSize: "~4.3 GB", note: "", isBase: false),
        CatalogModel(id: "mlx-community/Qwen3-1.7B-4bit", name: "Qwen3 1.7B (hybrid thinking)", approxSize: "~1.0 GB", note: "", isBase: false),
        CatalogModel(id: "mlx-community/Qwen3-4B-4bit", name: "Qwen3 4B (hybrid thinking)", approxSize: "~2.3 GB", note: "", isBase: false),
        CatalogModel(id: "mlx-community/Qwen3-8B-4bit", name: "Qwen3 8B (hybrid thinking)", approxSize: "~4.7 GB", note: "", isBase: false),
        CatalogModel(id: "mlx-community/Qwen3-30B-A3B-4bit", name: "Qwen3 30B-A3B (instruct, MoE)", approxSize: "~13.7 GB", note: "", isBase: false),
        CatalogModel(id: "mlx-community/Qwen2.5-7B-Instruct-4bit", name: "Qwen2.5 7B (instruct)", approxSize: "~4.2 GB", note: "", isBase: false),
        CatalogModel(id: "mlx-community/Qwen2.5-3B-Instruct-4bit", name: "Qwen2.5 3B (instruct)", approxSize: "~1.7 GB", note: "", isBase: false),
        CatalogModel(id: "mlx-community/Qwen2.5-1.5B-Instruct-4bit", name: "Qwen2.5 1.5B (instruct)", approxSize: "~0.9 GB", note: "", isBase: false),
        CatalogModel(id: "mlx-community/Qwen2.5-0.5B-Instruct-4bit", name: "Qwen2.5 0.5B (instruct)", approxSize: "~0.3 GB", note: "", isBase: false),
        CatalogModel(id: "mlx-community/gemma-4-26b-a4b-it-4bit", name: "Gemma 4 26B-A4B (instruct, MoE)", approxSize: "~15.7 GB", note: "", isBase: false),
        CatalogModel(id: "mlx-community/gemma-4-e4b-4bit", name: "Gemma 4 E4B (base, legacy)", approxSize: "~6.2 GB", note: ""),
        CatalogModel(id: "mlx-community/gemma-4-e2b-4bit", name: "Gemma 4 E2B (base, legacy)", approxSize: "~3.2 GB", note: ""),
        CatalogModel(id: "mlx-community/gemma-4-31b-4bit", name: "Gemma 4 31B (base, legacy)", approxSize: "~18 GB", note: ""),
        CatalogModel(id: "mlx-community/Qwen2.5-3B-4bit", name: "Qwen2.5 3B (base, legacy)", approxSize: "~1.7 GB", note: ""),
        CatalogModel(id: "mlx-community/Qwen2.5-1.5B-4bit", name: "Qwen2.5 1.5B (base, legacy)", approxSize: "~0.9 GB", note: ""),
        CatalogModel(id: "mlx-community/Qwen2.5-0.5B-4bit", name: "Qwen2.5 0.5B (base, legacy)", approxSize: "~0.3 GB", note: ""),
        CatalogModel(id: "mlx-community/gemma-3-1b-pt-4bit", name: "Gemma 3 1B (base, legacy)", approxSize: "~0.8 GB", note: ""),
    ]

    /// Offered and retired models, for looking up a model already in use.
    static func known(_ id: String) -> CatalogModel? {
        all.first { $0.id == id } ?? retired.first { $0.id == id }
    }

    /// The model to load at launch: the saved choice, unless it is missing or
    /// retired, in which case the recommended model. Custom ids are kept.
    static func startupModelId(saved: String?, recommended: String) -> String {
        guard let saved, !retired.contains(where: { $0.id == saved }) else { return recommended }
        return saved
    }

    /// The model recommended for this Mac's hardware.
    static var recommendedId: String { HardwareInfo.recommendedModelId }

    static func isRecommended(_ id: String) -> Bool { id == recommendedId }
}
