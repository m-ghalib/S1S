import XCTest
@testable import TabType

final class PromptBuilderTests: XCTestCase {

    private func makeRequest(before: String, after: String = "", screen: String = "",
                             clipboard: String = "") -> CompletionRequest {
        CompletionRequest(beforeCursor: before, afterCursor: after, screenContext: screen,
                          clipboard: clipboard, persona: "", screenContextBudget: 500,
                          maxWords: 6, maxTokens: 24, temperature: 0.1)
    }

    func testBodyNeverExceedsCap() {
        for prefixLen in [0, 800, 1600, 5000] {
            let req = makeRequest(
                before: String(repeating: "a", count: prefixLen) + " tail",
                after: String(repeating: "b", count: 400),
                screen: String(repeating: "c", count: 900),
                clipboard: String(repeating: "d", count: 400))
            let body = PromptBuilder.body(req, cap: 1500)
            XCTAssertLessThanOrEqual(body.count, 1500 + 100,
                "prefixLen \(prefixLen): body \(body.count) chars blows the cap")
        }
    }

    func testSectionOrderAfterThenClipboardThenScreen() {
        let req = makeRequest(before: "Hello wor", after: "AFTERTEXT",
                              screen: "SCREENTEXT", clipboard: "CLIPTEXT")
        let body = PromptBuilder.body(req, cap: 1500)
        guard let a = body.range(of: "<text_after_cursor>"),
              let c = body.range(of: "<clipboard>"),
              let s = body.range(of: "<on_screen>") else {
            return XCTFail("missing context sections in: \(body)")
        }
        XCTAssertLessThan(a.lowerBound, c.lowerBound)
        XCTAssertLessThan(c.lowerBound, s.lowerBound)
    }

    func testPrefixAlwaysWinsBudget() {
        // A huge prefix must survive (truncated), even if context gets dropped.
        let req = makeRequest(before: String(repeating: "x", count: 5000) + " ending here",
                              screen: String(repeating: "s", count: 900))
        let body = PromptBuilder.body(req, cap: 1500)
        XCTAssertTrue(body.contains("ending here"), "most recent prefix chars must survive")
    }

    func testChatFormatScaffolding() {
        let req = makeRequest(before: "Hello wor")
        let chat = PromptBuilder.body(req, cap: 1500, chatFormat: true)
        XCTAssertTrue(chat.hasSuffix("Input: Hello wor\nOutput:"))
    }

    func testBaseFormatIsPlainContinuation() {
        let req = makeRequest(before: "Hello wor", after: "AFTERTEXT")
        let base = PromptBuilder.body(req, cap: 1500, chatFormat: false)
        XCTAssertTrue(base.hasSuffix("Hello wor"), "base prompt must end with the raw prefix")
        XCTAssertFalse(base.contains("Input:"))
        XCTAssertFalse(base.contains("Output:"))
    }

    func testBaseFormatPreservesTrailingSpace() {
        let req = makeRequest(before: "Hello world ")
        let base = PromptBuilder.body(req, cap: 1500, chatFormat: false)
        XCTAssertTrue(base.hasSuffix("Hello world "), "trailing space is signal for raw continuation")
        let chat = PromptBuilder.body(req, cap: 1500, chatFormat: true)
        XCTAssertTrue(chat.hasSuffix("Input: Hello world\nOutput:"), "chat format trims it")
    }

    func testScreenContextRespectsItsOwnBudget() {
        var req = makeRequest(before: "short prefix", screen: String(repeating: "s", count: 2000))
        req.screenContextBudget = 100
        let body = PromptBuilder.body(req, cap: 1500)
        let screenPart = body.components(separatedBy: "<on_screen>").last ?? ""
        let screenLen = screenPart.components(separatedBy: "</on_screen>").first?.count ?? 0
        XCTAssertLessThanOrEqual(screenLen, 110)
    }
}

final class CleanOCRTests: XCTestCase {

    func testChromeIsDroppedProseSurvives() {
        let lines = [
            "File", "Edit", "View", "Window", "Help",          // menu bar
            "12:34", "9:05 AM",                                  // clock
            "Send", "Reply", "Archive",                          // buttons
            "•••", "100%", "⌘N",                                 // symbols
            "The quarterly report shows revenue grew by twelve percent",
            "and the team expects continued growth next quarter.",
            "The quarterly report shows revenue grew by twelve percent", // dup
        ]
        let out = OCRCleaner.clean(lines)
        XCTAssertTrue(out.contains("quarterly report"))
        XCTAssertTrue(out.contains("continued growth"))
        XCTAssertFalse(out.contains("File"))
        XCTAssertFalse(out.contains("12:34"))
        XCTAssertFalse(out.contains("Send"))
        // Global dedup: the duplicated prose line appears once.
        XCTAssertEqual(out.components(separatedBy: "quarterly report").count - 1, 1)
    }

    func testChromeResidueAloneReturnsEmpty() {
        let lines = ["File", "Edit", "Compose", "just a few words"]
        XCTAssertEqual(OCRCleaner.clean(lines), "")
    }
}
