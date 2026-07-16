import Foundation

enum InsertionStrategy {
    case auto        // keystroke, upgrading to paste for long/multiline text
    case keystroke
    case paste
}

/// Per-app behavior overrides. Mirrors the per-app compatibility policies used by
/// cotabby/KeyType so TabType behaves well (and safely) across very different apps.
struct AppPolicy {
    var isEnabled: Bool = true
    /// Never show/insert in password fields.
    var excludesSecureField: Bool = true
    /// Whether to feed remembered on-screen context to the model for this app.
    var includesScreenContext: Bool = true
    /// When true, screen-memory context is used for this app even if the user hasn't
    /// globally turned on `useScreenContext` — for chat/messaging apps where reading
    /// recent conversation is the whole point, matching Cotypist-style behavior.
    var forceScreenContext: Bool = false
    /// Electron/web apps report caret bounds that lag ~0.3-0.5s behind the real
    /// caret during typing. Presentation there must wait for a typing pause (the
    /// Cotypist strategy — observed live): by idle time the bounds have caught up
    /// and inline ghosts place correctly.
    var laggyCaret: Bool = false
    /// Code editors: suggest only in short chat inputs (sidebar panels), never the
    /// main editor surface — prose autocomplete there fights code completion.
    var chatPanelsOnly: Bool = false
    /// Prefer extracting the conversation from the AX tree (chat apps) instead of
    /// OCR; falls back to OCR when the tree yields too little.
    var transcriptViaAX: Bool = false
    /// Overrides the default screen-context character budget for this app (nil = use
    /// the global default). Chat apps get a larger budget so more transcript survives.
    var screenContextCap: Int?
    var insertionStrategy: InsertionStrategy = .auto
    /// Ghost-text font size multiplier (some apps render at different metrics).
    var fontFactor: Double = 1.0
    /// Ghost-text vertical nudge in points.
    var verticalOffset: Double = 0
    /// Font-size-from-caret-height ratio, used only when the field's real AX font
    /// can't be read (common for web/Electron content). Web/Electron caret rects are
    /// padded CSS line boxes, so a tight-line-box ratio (0.72) undersizes the ghost;
    /// 0.83 matches the field text size observed in Claude Desktop (Cotypist's
    /// ghost renders at exactly the field size there).
    var fontSizeRatio: Double = 0.83
    /// Whether to show completions when there's text after the cursor on the same line.
    var allowsMidLine: Bool = true
    /// When true, Tab does not accept suggestions in this app (e.g. IDEs where Tab
    /// indents or switches fields).
    var disableTabKey: Bool = false
    /// Per-app autocorrect override; nil defers to the global setting.
    var autocorrectOverride: Bool?
    /// Extra instructions appended to the model persona for this app.
    var customInstructions: String = ""
}

/// A user-editable per-app behavior override. `nil` fields defer to TabType's
/// built-in default (or the global setting, for autocorrect).
struct AppOverride: Codable, Equatable {
    var enabled: Bool?
    var midLineEnabled: Bool?
    var autocorrectEnabled: Bool?
    var disableTabKey: Bool?
    var improveCompatibility: Bool = false
    var customInstructions: String = ""

    var isDefault: Bool {
        enabled == nil && midLineEnabled == nil && autocorrectEnabled == nil
            && disableTabKey == nil && !improveCompatibility && customInstructions.isEmpty
    }
}

@MainActor
enum AppPolicyStore {
    /// User-configured per-app overrides, keyed by bundle id. Set by `AppSettings`.
    static var userOverrides: [String: AppOverride] = [:]
    /// Password managers — completions fully disabled (safety).
    private static let passwordManagers: Set<String> = [
        "com.1password.1password", "com.1password.1password7",
        "com.agilebits.onepassword7", "com.apple.Passwords",
        "com.bitwarden.desktop", "com.dashlane.Dashlane",
        "com.callpod.keepermac", "com.lastpass.LastPass",
    ]

    /// Terminals — autocomplete is disruptive; disabled by default.
    private static let terminals: Set<String> = [
        "com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable",
        "com.mitchellh.ghostty", "io.alacritty", "net.kovidgoyal.kitty",
        "com.github.wez.wezterm",
    ]

    /// Apps that need clipboard paste for reliable insertion.
    private static let pasteApps: Set<String> = [
        "com.tinyspeck.slackmacgap", "com.google.Chrome", "com.microsoft.VSCode",
        "notion.id", "md.obsidian",
    ]

    /// Code editors: prose autocomplete in the MAIN EDITOR collides with actual
    /// code completion — activate only in sidebar chat inputs (the Cotypist
    /// behavior documented on its compatibility page).
    private static let codeEditorApps: Set<String> = [
        "com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92" /* Cursor */,
        "com.exafunction.windsurf", "com.apple.dt.Xcode",
    ]
    private static let codeEditorBundlePrefixes = ["com.jetbrains."]

    /// Electron/Chromium apps whose AX caret bounds lag the real caret while
    /// typing (observed ~0.5s in Claude Desktop) — inline ghost placement can't be
    /// trusted there; suggestions render as a bubble above the caret instead.
    private static let electronApps: Set<String> = [
        "com.anthropic.claudefordesktop", "com.tinyspeck.slackmacgap",
        "com.hnc.Discord", "net.whatsapp.WhatsApp", "notion.id", "md.obsidian",
        "com.microsoft.VSCode", "com.spotify.client", "com.figma.Desktop",
        "com.microsoft.teams2", "us.zoom.xos",
    ]

    /// Chat/messaging apps where recent conversation IS the context that matters —
    /// screen memory is force-enabled here regardless of the global toggle, with a
    /// larger character budget so more transcript survives into the prompt.
    private static let chatApps: Set<String> = [
        "com.anthropic.claudefordesktop", "com.tinyspeck.slackmacgap",
        "com.hnc.Discord", "com.apple.MobileSMS", "net.whatsapp.WhatsApp",
    ]

    static func policy(forBundleId id: String?) -> AppPolicy {
        guard let id else { return AppPolicy() }
        if passwordManagers.contains(id) || terminals.contains(id) {
            return AppPolicy(isEnabled: false)
        }
        var policy = AppPolicy()
        if pasteApps.contains(id) { policy.insertionStrategy = .paste }
        if chatApps.contains(id) {
            policy.forceScreenContext = true
            policy.screenContextCap = 700
            // Chat transcripts read far cleaner from the AX tree than from OCR.
            policy.transcriptViaAX = true
        }
        // Electron/web apps: AX caret bounds lag behind the real caret while
        // typing — present only after a typing pause, and never mid-line (the
        // after-text position can't be trusted enough to avoid overlap there).
        if electronApps.contains(id) {
            policy.laggyCaret = true
            policy.allowsMidLine = false
        }
        if codeEditorApps.contains(id)
            || codeEditorBundlePrefixes.contains(where: { id.hasPrefix($0) }) {
            policy.chatPanelsOnly = true
        }
        switch id {
        case "com.apple.Safari": policy.fontFactor = 0.98
        case "com.google.Chrome": policy.fontFactor = 1.0
        default: break
        }

        if let o = userOverrides[id] {
            if let e = o.enabled { policy.isEnabled = e }
            if let m = o.midLineEnabled { policy.allowsMidLine = m }
            if let d = o.disableTabKey { policy.disableTabKey = d }
            policy.autocorrectOverride = o.autocorrectEnabled
            if o.improveCompatibility { policy.insertionStrategy = .paste }
            policy.customInstructions = o.customInstructions
        }
        return policy
    }

    /// Overrides keyed by website host use a `domain:` prefix in the same store.
    static func domainKey(_ host: String) -> String { "domain:" + host.lowercased() }

    /// Policy for a bundle id AND the current website — the domain override is
    /// applied last (most specific wins). `host` matches exactly or by suffix
    /// ("mail.google.com" matches an override for "google.com").
    static func policy(forBundleId id: String?, host: String?) -> AppPolicy {
        var policy = policy(forBundleId: id)
        guard let host = host?.lowercased() else { return policy }
        let match = userOverrides.first { key, _ in
            guard key.hasPrefix("domain:") else { return false }
            let domain = String(key.dropFirst("domain:".count))
            return host == domain || host.hasSuffix("." + domain)
        }
        if let (_, o) = match {
            if let e = o.enabled { policy.isEnabled = e }
            if let m = o.midLineEnabled { policy.allowsMidLine = m }
            if !o.customInstructions.isEmpty {
                policy.customInstructions = policy.customInstructions.isEmpty
                    ? o.customInstructions
                    : policy.customInstructions + " " + o.customInstructions
            }
        }
        return policy
    }
}
