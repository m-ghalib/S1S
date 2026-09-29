import XCTest
@testable import TabType

/// Guards the plain-language model picker: chip bandwidth lookup, the latency
/// estimate's calibration point, memory fit, and the per-Mac recommendation.
final class ModelAdvisorTests: XCTestCase {

    func testBandwidthByChip() {
        XCTAssertEqual(ModelAdvisor.memoryBandwidthGBs(chip: "Apple M1"), 68)
        XCTAssertEqual(ModelAdvisor.memoryBandwidthGBs(chip: "Apple M1 Max"), 400)
        XCTAssertEqual(ModelAdvisor.memoryBandwidthGBs(chip: "Apple M3 Pro"), 150)
        XCTAssertEqual(ModelAdvisor.memoryBandwidthGBs(chip: "Apple M4 Pro"), 273)
        XCTAssertEqual(ModelAdvisor.memoryBandwidthGBs(chip: "Apple A18 Pro"), 60)
    }

    func testUnknownChipsFallBackSensibly() {
        // A future generation uses the newest known generation of the same tier.
        XCTAssertEqual(ModelAdvisor.memoryBandwidthGBs(chip: "Apple M9 Max"),
                       ModelAdvisor.memoryBandwidthGBs(chip: "Apple M5 Max"))
        XCTAssertEqual(ModelAdvisor.memoryBandwidthGBs(chip: "Apple Silicon"), 100)
    }

    func testLatencyMatchesCalibrationMac() {
        // Measured on an M1 Max: Qwen3.5 2B prefills the whole prompt in ~1.1 s.
        let ms = ModelAdvisor.estimatedLatencyMs(.fastest, bandwidthGBs: 400)
        XCTAssertEqual(Double(ms), 1130, accuracy: 100)
        // Slower chips take proportionally longer.
        XCTAssertGreaterThan(ModelAdvisor.estimatedLatencyMs(.fastest, bandwidthGBs: 68), 5000)
    }

    func testSmallerModelsAreFaster() {
        for bandwidth in [60.0, 120, 400] {
            let fast = ModelAdvisor.estimatedLatencyMs(.fastest, bandwidthGBs: bandwidth)
            let balanced = ModelAdvisor.estimatedLatencyMs(.balanced, bandwidthGBs: bandwidth)
            let accurate = ModelAdvisor.estimatedLatencyMs(.accurate, bandwidthGBs: bandwidth)
            XCTAssertLessThan(fast, balanced)
            XCTAssertLessThan(balanced, accurate)
        }
    }

    func testMemoryFit() {
        XCTAssertEqual(ModelAdvisor.fit(.fastest, ramGB: 8), .comfortable)
        XCTAssertEqual(ModelAdvisor.fit(.balanced, ramGB: 8), .tooLarge)
        XCTAssertEqual(ModelAdvisor.fit(.balanced, ramGB: 16), .comfortable)
        XCTAssertEqual(ModelAdvisor.fit(.accurate, ramGB: 16), .tooLarge)
        XCTAssertEqual(ModelAdvisor.fit(.accurate, ramGB: 18), .tight)
        XCTAssertEqual(ModelAdvisor.fit(.accurate, ramGB: 32), .comfortable)
    }

    func testRecommendationPerMac() {
        // No Qwen3.5 model meets the latency budget without prompt caching, so every
        // Mac gets Fastest, the only choice under budget-or-fallback.
        for (chip, ram) in [("Apple A18 Pro", 8), ("Apple M1", 16), ("Apple M4 Pro", 24), ("Apple M5 Max", 64)] {
            XCTAssertEqual(ModelAdvisor.recommended(chip: chip, ramGB: ram), .fastest, "\(chip) \(ram) GB")
        }
    }

    func testCatalogOffersOnlyCurrentModelsUnder15GB() {
        for model in ModelCatalog.all {
            XCTAssertTrue(model.id.contains("Qwen3.5") || model.id.contains("gemma-4"), model.id)
            XCTAssertFalse(model.isBase, model.id)
        }
        // Retired models still resolve, so their prompt format and name survive.
        XCTAssertEqual(ModelCatalog.known("mlx-community/Qwen3-4B-Instruct-2507-8bit")?.isBase, false)
        XCTAssertEqual(ModelCatalog.known("mlx-community/Qwen2.5-3B-4bit")?.isBase, true)
        XCTAssertNil(ModelCatalog.known("someone/Custom-Model"))
    }

    func testChoicesAreInCatalog() {
        for choice in ModelAdvisor.Choice.allCases {
            XCTAssertTrue(ModelCatalog.all.contains { $0.id == choice.modelId }, choice.modelId)
            XCTAssertEqual(ModelAdvisor.Choice.matching(modelId: choice.modelId), choice)
        }
    }

    func testLabels() {
        XCTAssertEqual(ModelAdvisor.latencyText(ms: 270), "about 0.3 seconds")
        XCTAssertEqual(ModelAdvisor.latencyText(ms: 40), "about 0.1 seconds")
        XCTAssertEqual(ModelAdvisor.speedScore(ms: 600), 5)
        XCTAssertEqual(ModelAdvisor.speedScore(ms: 4500), 1)
        XCTAssertEqual(ModelAdvisor.accuracyText(4), "Very good")
        XCTAssertEqual(ModelAdvisor.displayName(for: "mlx-community/Qwen3.5-4B-4bit"), "Balanced model")
        XCTAssertEqual(ModelAdvisor.displayName(for: "mlx-community/Qwen2.5-7B-Instruct-4bit"), "Qwen2.5 7B (instruct)")
        XCTAssertEqual(ModelAdvisor.displayName(for: "someone/Custom-Model"), "Custom-Model")
    }
}
