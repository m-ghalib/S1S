import XCTest
@testable import TabType

@MainActor
final class AppPolicyTests: XCTestCase {

    override func setUp() {
        super.setUp()
        AppPolicyStore.userOverrides = [:]
    }

    func testChatAppGetsFullChatTreatment() {
        let p = AppPolicyStore.policy(forBundleId: "net.whatsapp.WhatsApp")
        XCTAssertTrue(p.forceScreenContext)
        XCTAssertTrue(p.transcriptViaAX)
        XCTAssertEqual(p.screenContextCap, AppPolicyStore.chatContextCap)
        XCTAssertEqual(p.profile, .chat)
    }

    func testChatDomainInBrowserGetsChatTreatment() {
        let p = AppPolicyStore.policy(forBundleId: "com.apple.Safari", host: "claude.ai")
        XCTAssertTrue(p.transcriptViaAX)
        XCTAssertTrue(p.forceScreenContext)
        XCTAssertEqual(p.screenContextCap, AppPolicyStore.chatContextCap)
        // Subdomains match by suffix too.
        let sub = AppPolicyStore.policy(forBundleId: "com.google.Chrome", host: "www.chatgpt.com")
        XCTAssertTrue(sub.transcriptViaAX)
        // Non-chat host stays standard.
        let plain = AppPolicyStore.policy(forBundleId: "com.apple.Safari", host: "example.com")
        XCTAssertFalse(plain.transcriptViaAX)
    }

    func testDocumentAppProfile() {
        let p = AppPolicyStore.policy(forBundleId: "com.apple.iWork.Pages")
        XCTAssertTrue(p.documentProfile)
        XCTAssertEqual(p.inputContextChars, 2000)
        XCTAssertEqual(p.profile, .document)
    }

    func testReadConversationOverridePromotesAnyApp() {
        var o = AppOverride()
        o.readConversation = true
        AppPolicyStore.userOverrides = ["com.example.someapp": o]
        let p = AppPolicyStore.policy(forBundleId: "com.example.someapp")
        XCTAssertTrue(p.transcriptViaAX)
        XCTAssertTrue(p.forceScreenContext)
        XCTAssertEqual(p.screenContextCap, AppPolicyStore.chatContextCap)
        XCTAssertEqual(p.profile, .chat)
    }

    func testContextSizeOverride() {
        var o = AppOverride()
        o.contextSize = "small"
        AppPolicyStore.userOverrides = ["net.whatsapp.WhatsApp": o]
        XCTAssertEqual(AppPolicyStore.policy(forBundleId: "net.whatsapp.WhatsApp").screenContextCap, 300)
        o.contextSize = "large"
        AppPolicyStore.userOverrides = ["com.example.plain": o]
        XCTAssertEqual(AppPolicyStore.policy(forBundleId: "com.example.plain").screenContextCap,
                       AppPolicyStore.chatContextCap)
    }

    func testSummaryLinesReflectResolvedPolicy() {
        let chat = AppPolicyStore.policy(forBundleId: "com.tinyspeck.slackmacgap")
        XCTAssertTrue(chat.summaryLines.contains { $0.contains("accessibility tree") })
        var o = AppOverride()
        o.enabled = false
        AppPolicyStore.userOverrides = ["com.tinyspeck.slackmacgap": o]
        let disabled = AppPolicyStore.policy(forBundleId: "com.tinyspeck.slackmacgap")
        XCTAssertEqual(disabled.summaryLines, ["Completions are turned off for this app."])
    }

    func testBuiltinContextCapIgnoresUserContextOverrides() {
        var o = AppOverride()
        o.contextSize = "small"
        AppPolicyStore.userOverrides = ["net.whatsapp.WhatsApp": o, "com.example.plain": o]
        // Resolved policy honors the override…
        XCTAssertEqual(AppPolicyStore.policy(forBundleId: "net.whatsapp.WhatsApp").screenContextCap, 300)
        // …but the built-in default label stays truthful.
        XCTAssertEqual(AppPolicyStore.builtinContextCap(forBundleId: "net.whatsapp.WhatsApp"),
                       AppPolicyStore.chatContextCap)
        XCTAssertEqual(AppPolicyStore.builtinContextCap(forBundleId: "com.example.plain"),
                       AppPolicyStore.defaultContextCap)
        // And the store is restored afterwards.
        XCTAssertEqual(AppPolicyStore.policy(forBundleId: "net.whatsapp.WhatsApp").screenContextCap, 300)
    }

    func testOldOverridesDecodeWithoutNewFields() throws {
        // Backward compatibility: overrides saved before readConversation/contextSize.
        let legacy = #"{"improveCompatibility":true,"customInstructions":"be brief"}"#
        let o = try JSONDecoder().decode(AppOverride.self, from: Data(legacy.utf8))
        XCTAssertNil(o.readConversation)
        XCTAssertNil(o.contextSize)
        XCTAssertTrue(o.improveCompatibility)
    }
}
