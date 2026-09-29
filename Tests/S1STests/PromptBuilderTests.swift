import XCTest
@testable import S1S

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

    func testSectionOrderIsByVolatilityForKVReuse() {
        // Stable → volatile: clipboard → afterCursor → screen, so a screen-context
        // change invalidates the smallest possible KV-cache suffix.
        let req = makeRequest(before: "Hello wor", after: "AFTERTEXT",
                              screen: "SCREENTEXT", clipboard: "CLIPTEXT")
        let body = PromptBuilder.body(req, cap: 1500)
        guard let a = body.range(of: "<text_after_cursor>"),
              let c = body.range(of: "<clipboard>"),
              let s = body.range(of: "<on_screen>") else {
            return XCTFail("missing context sections in: \(body)")
        }
        XCTAssertLessThan(c.lowerBound, a.lowerBound)
        XCTAssertLessThan(a.lowerBound, s.lowerBound)
    }

    func testScreenChangeKeepsSharedPromptPrefix() {
        // Two builds where ONLY the screen context differs must share an identical
        // character prefix right up to <on_screen> — the KV-cache reuse guarantee.
        var req1 = makeRequest(before: "Hello wor", after: "AFTERTEXT",
                               screen: "SCREEN ONE", clipboard: "CLIPTEXT")
        req1.recentMessages = ["earlier message"]
        var req2 = req1
        req2.screenContext = "SCREEN TWO ENTIRELY DIFFERENT"
        let b1 = PromptBuilder.body(req1, cap: 1500)
        let b2 = PromptBuilder.body(req2, cap: 1500)
        guard let cut1 = b1.range(of: "<on_screen>"),
              let cut2 = b2.range(of: "<on_screen>") else {
            return XCTFail("missing on_screen section")
        }
        XCTAssertEqual(String(b1[..<cut1.lowerBound]), String(b2[..<cut2.lowerBound]),
                       "everything before <on_screen> must be byte-identical for KV reuse")
    }

    func testPrefixAlwaysWinsBudget() {
        // A huge prefix must survive (truncated), even if context gets dropped.
        let req = makeRequest(before: String(repeating: "x", count: 5000) + " ending here",
                              screen: String(repeating: "s", count: 900))
        let body = PromptBuilder.body(req, cap: 1500)
        XCTAssertTrue(body.contains("ending here"), "most recent prefix chars must survive")
    }

    func testChatScreenBudgetActuallyFlowsThroughDefaultCap() {
        // At the default cap, a chat app's full screen-context budget (1400 chars,
        // AppPolicyStore.chatContextCap) must survive alongside a full-size typed
        // prefix — at the old 2600 cap it silently starved to ~1100 for ALL
        // sections combined.
        var req = makeRequest(before: String(repeating: "p", count: 1195) + " tail",
                              screen: String(repeating: "s", count: 1395) + " scrn")
        req.screenContextBudget = 1400
        let body = PromptBuilder.body(req, cap: PromptBuilder.defaultCap)
        guard let open = body.range(of: "<on_screen"),
              let close = body.range(of: "</on_screen>") else {
            return XCTFail("missing on_screen section in: \(body.suffix(300))")
        }
        let screenLen = body.distance(from: open.upperBound, to: close.lowerBound)
        XCTAssertGreaterThanOrEqual(screenLen, 1400,
            "chat screen context got \(screenLen) chars — budget starved by the cap")
        XCTAssertTrue(body.contains(" tail"), "typed prefix must survive untruncated")
    }

    func testChatFormatScaffolding() {
        let req = makeRequest(before: "Hello wor")
        let chat = PromptBuilder.body(req, cap: 1500, chatFormat: true)
        XCTAssertTrue(chat.hasSuffix("Input: Hello wor\nOutput:"))
    }

    func testContinuationReminderPresentOnlyWithContext() {
        let reminder = "Do NOT reply, answer, or react"
        // No context → no reminder (keeps bare prompts minimal).
        let bare = PromptBuilder.body(makeRequest(before: "Hello wor"), cap: 1500)
        XCTAssertFalse(bare.contains(reminder))
        // With context → reminder sits between </context> and Input:.
        let withCtx = PromptBuilder.body(
            makeRequest(before: "Hello wor", screen: "a: hi there friend"), cap: 1500)
        XCTAssertTrue(withCtx.contains(reminder))
        guard let end = withCtx.range(of: "</context>"),
              let rem = withCtx.range(of: reminder),
              let input = withCtx.range(of: "Input:") else {
            return XCTFail("missing pieces in: \(withCtx)")
        }
        XCTAssertLessThan(end.lowerBound, rem.lowerBound)
        XCTAssertLessThan(rem.lowerBound, input.lowerBound)
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

    func testDocumentStartRendersFirstInContext() {
        var req = makeRequest(before: "deep in the document I write", after: "",
                              screen: "SCREENTEXT", clipboard: "CLIPTEXT")
        req.documentStart = "Quarterly Planning 2026 — Draft\nThis document lays out our goals"
        req.previousWriting = ["some earlier writing sample"]
        let body = PromptBuilder.body(req, cap: PromptBuilder.defaultCap)
        guard let d = body.range(of: "<document_start>"),
              let w = body.range(of: "<recently_written_by_author>"),
              let s = body.range(of: "<on_screen>") else {
            return XCTFail("missing sections in: \(body)")
        }
        XCTAssertLessThan(d.lowerBound, w.lowerBound)
        XCTAssertLessThan(w.lowerBound, s.lowerBound)
        XCTAssertTrue(body.contains("Quarterly Planning 2026"))
    }

    func testPreviousAppContextIsLabeledAndPlacedBeforeRecentMessages() {
        var req = makeRequest(before: "writing something new here", screen: "CURRENT SCREEN")
        req.previousAppName = "Slack"
        req.previousAppContext = "earlier slack discussion about the launch"
        req.recentMessages = ["my last sent message"]
        let body = PromptBuilder.body(req, cap: PromptBuilder.defaultCap)
        guard let prev = body.range(of: "<from_previous_app name=\"Slack\">"),
              let msgs = body.range(of: "<your_previous_messages>"),
              let scr = body.range(of: "<on_screen") else {
            return XCTFail("missing sections in: \(body)")
        }
        XCTAssertLessThan(prev.lowerBound, msgs.lowerBound)
        XCTAssertLessThan(msgs.lowerBound, scr.lowerBound)
        XCTAssertTrue(body.contains("earlier slack discussion"))
    }

    func testScreenDropsLinesDuplicatingOwnMessages() {
        var req = makeRequest(before: "and following up, I think",
                              screen: "someone else: sounds good\nthe deploy finished and all services are green")
        req.recentMessages = ["the deploy finished and all services are green"]
        let body = PromptBuilder.body(req, cap: PromptBuilder.defaultCap)
        let screenPart = body.components(separatedBy: "<on_screen").last ?? ""
        XCTAssertTrue(screenPart.contains("sounds good"))
        XCTAssertEqual(screenPart.components(separatedBy: "deploy finished").count - 1, 0,
                       "own message must not be duplicated inside <on_screen>")
    }

    func testConversationHintOnTranscripts() {
        var req = makeRequest(before: "hey, about that", screen: "a: hi\nb: hello there friend")
        req.screenIsConversation = true
        let body = PromptBuilder.body(req, cap: PromptBuilder.defaultCap)
        XCTAssertTrue(body.contains("<on_screen note=\"conversation, newest last\">"))
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
