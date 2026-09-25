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

    func testChatGPTDesktopGetsChatTreatment() {
        let p = AppPolicyStore.policy(forBundleId: "com.openai.chat")
        XCTAssertTrue(p.forceScreenContext)
        XCTAssertTrue(p.transcriptViaAX)
        XCTAssertEqual(p.screenContextCap, AppPolicyStore.chatContextCap)
        XCTAssertEqual(p.profile, .chat)
    }

    func testXAndLinkedInGetChatTreatmentInChrome() {
        for host in ["x.com", "www.linkedin.com"] {
            let p = AppPolicyStore.policy(forBundleId: "com.google.Chrome", host: host)
            XCTAssertTrue(p.forceScreenContext, host)
            XCTAssertTrue(p.transcriptViaAX, host)
            XCTAssertEqual(p.screenContextCap, AppPolicyStore.chatContextCap, host)
        }
        // Suffix match needs a dot boundary: box.com is not x.com.
        XCTAssertFalse(AppPolicyStore.policy(forBundleId: "com.google.Chrome", host: "box.com").transcriptViaAX)
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

    // MARK: - Chromium browsers

    func testChromiumBrowsersMatchChromeInsertionAndFontFactor() {
        let chrome = AppPolicyStore.policy(forBundleId: "com.google.Chrome")
        XCTAssertEqual(chrome.insertionStrategy, .paste)
        XCTAssertEqual(chrome.fontFactor, 1.0)

        let bundleIDs = [
            "company.thebrowser.Browser", "com.microsoft.edgemac",
            "com.brave.Browser", "company.thebrowser.dia",
            "com.vivaldi.Vivaldi", "org.chromium.Chromium",
        ]
        for id in bundleIDs {
            let policy = AppPolicyStore.policy(forBundleId: id)
            XCTAssertEqual(policy.insertionStrategy, .paste, id)
            XCTAssertEqual(policy.fontFactor, 1.0, id)
        }
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

    // MARK: - Password managers

    func testPasswordManagersStayDisabledDespiteEnableOverride() {
        let bundleIDs = [
            "me.proton.pass.electron",
            "org.keepassxc.keepassxc",
            "com.markmcguill.strongbox", "com.markmcguill.strongbox.pro",
            "com.markmcguill.strongbox.mac", "com.markmcguill.strongbox.mac.pro",
            "in.sinew.Enpass-Desktop.App", "in.sinew.Enpass-Desktop",
            "com.nordsec.nordpass",
            "com.sibersystems.RoboFormMac",
        ]
        for id in bundleIDs {
            XCTAssertFalse(AppPolicyStore.policy(forBundleId: id).isEnabled, id)
            var override = AppOverride()
            override.enabled = true
            AppPolicyStore.userOverrides[id] = override
            XCTAssertFalse(AppPolicyStore.policy(forBundleId: id).isEnabled, id)
            AppPolicyStore.userOverrides.removeValue(forKey: id)
        }
    }

    // MARK: - Terminals

    func testAdditionalTerminalsAreDisabledUnlessEnabledByUser() {
        let bundleIDs = [
            "co.zeit.hyper", "org.tabby", "com.raphaelamorim.rio",
            "com.termius-dmg.mac", "com.termius.mac",
            "dev.commandline.waveterm", "dev.warp.Warp-Preview",
        ]
        for id in bundleIDs {
            let defaultPolicy = AppPolicyStore.policy(forBundleId: id)
            XCTAssertFalse(defaultPolicy.isEnabled, id)
            XCTAssertEqual(defaultPolicy.profile, .disabled, id)
            var override = AppOverride()
            override.enabled = true
            AppPolicyStore.userOverrides[id] = override
            let enabledPolicy = AppPolicyStore.policy(forBundleId: id)
            XCTAssertTrue(enabledPolicy.isEnabled, id)
            XCTAssertNotEqual(enabledPolicy.profile, .disabled, id)
            AppPolicyStore.userOverrides.removeValue(forKey: id)
            XCTAssertFalse(AppPolicyStore.policy(forBundleId: id).isEnabled, id)
        }
    }

    // MARK: - Zed

    func testZedMarkdownOnlyPolicy() {
        let p = AppPolicyStore.policy(forBundleId: "dev.zed.Zed")
        // Enabled — file-type gating is runtime (window title), not a policy disable.
        XCTAssertTrue(p.isEnabled, "Zed must not be disabled")
        // Main editor receives suggestions (not chat-panels-only).
        XCTAssertFalse(p.chatPanelsOnly, "Zed should not be chat-panels-only")
        // markdownFilesOnly gates to .md files via runtime window-title check.
        XCTAssertTrue(p.markdownFilesOnly, "Zed must restrict suggestions to .md files")
        // Document profile: large context window for long-form markdown notes.
        XCTAssertTrue(p.documentProfile, "Zed should use the document profile for .md")
        XCTAssertEqual(p.inputContextChars, 2000)
        // Tab key must accept suggestions (not disabled).
        XCTAssertFalse(p.disableTabKey, "Tab key must accept suggestions in Zed")
        // Profile badge.
        XCTAssertEqual(p.profile, .document)
    }

    // MARK: - Claude Desktop

    func testClaudeDesktopPolicy() {
        let p = AppPolicyStore.policy(forBundleId: "com.anthropic.claudefordesktop")
        // Completions must be enabled.
        XCTAssertTrue(p.isEnabled, "Claude Desktop must not be disabled")
        // Electron caret bounds lag — suggestions render as a bubble above the caret.
        XCTAssertTrue(p.laggyCaret, "Claude Desktop is Electron: caret bounds lag during typing")
        // Mid-line suppressed because caret-bound accuracy can't be trusted there.
        XCTAssertFalse(p.allowsMidLine, "Claude Desktop must not suggest mid-line")
        // Paste insertion is required for reliable text entry in Electron renderers.
        XCTAssertEqual(p.insertionStrategy, .paste, "Claude Desktop requires paste insertion")
        // Tab key must accept suggestions (no Tab override active).
        XCTAssertFalse(p.disableTabKey, "Tab key must accept suggestions in Claude Desktop")
        // Chat profile: conversation is read from the AX tree, always-on context.
        XCTAssertTrue(p.forceScreenContext, "Claude Desktop must force screen context")
        XCTAssertTrue(p.transcriptViaAX, "Claude Desktop must use AX transcript")
        XCTAssertEqual(p.screenContextCap, AppPolicyStore.chatContextCap)
        // Profile badge.
        XCTAssertEqual(p.profile, .chat)
    }

    // MARK: - Obsidian

    func testObsidianPolicy() {
        let p = AppPolicyStore.policy(forBundleId: "md.obsidian")
        // Ghost-text must be enabled in the main editor.
        XCTAssertTrue(p.isEnabled, "Obsidian must not be disabled")
        XCTAssertFalse(p.chatPanelsOnly, "Obsidian main editor must receive suggestions")
        // Electron caret bounds lag — suggestions settle before presenting.
        XCTAssertTrue(p.laggyCaret, "Obsidian is Electron: caret bounds lag during typing")
        XCTAssertFalse(p.allowsMidLine, "Obsidian must not suggest mid-line")
        // Document profile: large context window for long-form notes.
        XCTAssertTrue(p.documentProfile, "Obsidian should use the document profile")
        XCTAssertEqual(p.inputContextChars, 2000)
        // Tab acceptance: paste insertion is required for Obsidian's Electron renderer.
        XCTAssertEqual(p.insertionStrategy, .paste, "Obsidian requires paste insertion")
        XCTAssertFalse(p.disableTabKey, "Tab key must accept suggestions in Obsidian")
        // Profile badge.
        XCTAssertEqual(p.profile, .document)
    }

    // MARK: - Superhuman

    func testSuperhumanPolicy() {
        let p = AppPolicyStore.policy(forBundleId: "com.superhuman.electron")
        XCTAssertTrue(p.documentProfile)
        XCTAssertTrue(p.laggyCaret)
        XCTAssertFalse(p.allowsMidLine)
        XCTAssertEqual(p.insertionStrategy, .paste)
    }
}
