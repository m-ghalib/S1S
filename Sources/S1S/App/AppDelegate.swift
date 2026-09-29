import AppKit
import Carbon.HIToolbox
import Combine
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {
    private let settings = AppSettings.shared
    private let provider = ModelProvider.shared
    private lazy var engine = Engine(settings: settings, provider: provider)

    private var statusItem: NSStatusItem!
    private let statusMenu = NSMenu()
    private var settingsWindow: NSWindow?
    private var onboardingWindow: NSWindow?
    private var trustTimer: Timer?
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        startSecureInputWatch()

        // Rebuild the menu whenever model state or enablement changes.
        provider.$state
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.rebuildMenu() }
            .store(in: &cancellables)
        settings.$isEnabled
            .receive(on: RunLoop.main)
            .sink { [weak self] enabled in
                self?.rebuildMenu()
                // Visibly dim the menu-bar glyph while disabled — a silently-off
                // engine has repeatedly read as "the app is broken".
                self?.statusItem.button?.appearsDisabled = !enabled
            }
            .store(in: &cancellables)
        settings.$showMenuBarIcon
            .receive(on: RunLoop.main)
            .sink { [weak self] show in self?.statusItem.isVisible = show }
            .store(in: &cancellables)

        // Accessory button → open Settings.
        NotificationCenter.default.addObserver(
            forName: .s1sOpenSettings, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.openSettings() }
        }
        // Settings > Personalization → redo onboarding.
        NotificationCenter.default.addObserver(
            forName: .s1sRedoOnboarding, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.presentOnboarding(requiresProfile: true) }
        }

        // Apply the "disable macOS predictive text" preference.
        applyMacOSPredictiveText()
        settings.$disableMacOSPredictiveText
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.applyMacOSPredictiveText() }
            .store(in: &cancellables)

        Log.shared.info("S1S launched. version=\(ReleaseNotes.currentVersion) model=\(settings.modelId) ax=\(AccessibilityBridge.isTrusted()) screen=\(ScreenContextProvider.shared.hasPermission()) emoji=\(EmojiMatcher.shared.all.count)")

        // Persist the model id only once it actually finishes loading, so a failed
        // switch to a different model never leaves settings pointing at a model that
        // isn't actually loaded (the previous working model stays active meanwhile).
        provider.onReady = { [weak self] modelId in
            self?.settings.modelId = modelId
            // Warm the KV cache with the static prompt prefix so the FIRST real
            // suggestion skips its system-prompt prefill (1-4s on big models).
            self?.engine.warmUpModel()
        }

        // Start loading the model + spell dictionary right away.
        provider.load(modelId: settings.modelId)
        if settings.autocorrectEnabled {
            SpellChecker.shared.loadIfNeeded(language: settings.autocorrectLanguage)
        }

        // Ask for Screen Recording up front if screen memory is on (non-blocking).
        if settings.useScreenContext && !ScreenContextProvider.shared.hasPermission() {
            ScreenContextProvider.shared.requestPermission()
        }

        // Confirm the capture+OCR pipeline works on this machine (logs the result).
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            ScreenContextProvider.shared.selfTest()
        }

        // First-run choices and Accessibility are both required before the engine starts.
        if AccessibilityBridge.isTrusted() && settings.hasCompletedOnboarding {
            _ = engine.start()
            announceUpdateIfNeeded(isSetUp: true)
        } else {
            announceUpdateIfNeeded(isSetUp: false)
            showOnboarding()
            if !AccessibilityBridge.isTrusted() { waitForTrustThenStart() }
        }
    }

    // MARK: - Status bar

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            // "Ghost tail" glyph drawn by Scripts/generate-app-icon.swift.
            let image = Bundle.module.image(forResource: "MenuBarIcon")
                ?? NSImage(systemSymbolName: "text.cursor", accessibilityDescription: nil)
            image?.isTemplate = true
            image?.accessibilityDescription = "S1S"
            button.image = image
        }
        statusItem.isVisible = settings.showMenuBarIcon
        statusMenu.delegate = self
        // Honor the isEnabled we set in item(...) — with auto-enable on, AppKit
        // grays out action-less items like the "Pause For…" submenu parent.
        statusMenu.autoenablesItems = false
        statusItem.menu = statusMenu
        rebuildMenu()
    }

    /// Rebuild right before the menu is shown, so a time-limited pause that expired
    /// while the menu was closed is reflected immediately.
    func menuWillOpen(_ menu: NSMenu) {
        rebuildMenu()
    }

    private func rebuildMenu() {
        let menu = statusMenu
        menu.removeAllItems()

        menu.addItem(item(statusLine(), icon: engineIconName(), enabled: false))
        if secureInputActive {
            menu.addItem(item("Secure Input is on — suggestions paused",
                              icon: "lock.fill", enabled: false))
        }
        if let pause = engine.frontmostAppPause() {
            let mins = max(1, Int(pause.until.timeIntervalSinceNow / 60))
            menu.addItem(item("Paused in this app (\(mins)m left) — Resume",
                              icon: "pause.circle", action: #selector(resumeAppPause)))
        }
        menu.addItem(.separator())

        if engine.isPaused {
            let resumeTitle = settings.isEnabled ? "Resume S1S" : "Enable S1S"
            menu.addItem(item(resumeTitle, icon: "play.circle", action: #selector(resumeNow)))
        } else {
            let toggle = item(settings.isEnabled ? "Pause S1S" : "Enable S1S",
                              icon: settings.isEnabled ? "pause.circle" : "power",
                              action: #selector(toggleEnabled))
            menu.addItem(toggle)

            let pauseMenu = NSMenu()
            pauseMenu.autoenablesItems = false
            pauseMenu.addItem(item("For 15 Minutes", icon: "timer", action: #selector(pause15)))
            pauseMenu.addItem(item("For 1 Hour", icon: "timer", action: #selector(pause60)))
            pauseMenu.addItem(item("Until I Turn It Back On", icon: "moon.zzz", action: #selector(pauseIndefinitely)))
            let pauseItem = item("Pause For…", icon: "pause.circle")
            pauseItem.submenu = pauseMenu
            menu.addItem(pauseItem)
        }

        menu.addItem(.separator())

        menu.addItem(item("Settings…", icon: "gearshape", action: #selector(openSettings), key: ","))
        menu.addItem(item("Statistics", icon: "chart.bar", action: #selector(openStatistics)))

        if !AccessibilityBridge.isTrusted() || !settings.hasCompletedOnboarding {
            let setupTitle = settings.hasCompletedOnboarding ? "Grant Accessibility Permission…" : "Finish Setup…"
            menu.addItem(item(setupTitle, icon: "exclamationmark.triangle", action: #selector(showOnboarding)))
        }

        menu.addItem(.separator())
        menu.addItem(item("Open Log", icon: "doc.text.magnifyingglass", action: #selector(openLog)))
        menu.addItem(item("What's New", icon: "sparkles.rectangle.stack", action: #selector(openWhatsNew)))
        menu.addItem(item("About S1S", icon: "info.circle", action: #selector(openAbout)))

        menu.addItem(.separator())
        menu.addItem(item("Quit S1S", icon: "power", action: #selector(quit), key: "q"))
    }

    /// Build an `NSMenuItem` with an SF Symbol icon.
    private func item(_ title: String, icon: String, action: Selector? = nil,
                      key: String = "", enabled: Bool = true) -> NSMenuItem {
        let menuItem = NSMenuItem(title: title, action: action, keyEquivalent: key)
        menuItem.image = NSImage(systemSymbolName: icon, accessibilityDescription: nil)
        if action != nil { menuItem.target = self }
        // Submenu parents legitimately have no action — don't disable them.
        menuItem.isEnabled = enabled
        return menuItem
    }

    private func engineIconName() -> String {
        switch provider.state {
        case .ready: return settings.engineChoice == .local ? "cpu" : "sparkles"
        case .downloading: return "arrow.down.circle"
        case .finalizing: return "gearshape.2"
        case .failed: return "exclamationmark.triangle"
        case .idle: return "circle.dashed"
        }
    }

    /// Another app holding macOS Secure Input silently blinds the keystroke tap —
    /// surface it instead of looking broken (Cotypist ships the same warning).
    private var secureInputActive = false
    private var secureInputTimer: Timer?

    func startSecureInputWatch() {
        secureInputTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let active = IsSecureEventInputEnabled()
                guard active != self.secureInputActive else { return }
                self.secureInputActive = active
                self.statusItem.button?.toolTip = active
                    ? "Another app has Secure Input on — S1S can't see keystrokes until it releases it."
                    : nil
                self.rebuildMenu()
                if active {
                    Log.shared.info("Secure Input active (another app) — keystroke tap is blind")
                }
            }
        }
    }

    private func statusLine() -> String {
        switch provider.state {
        case .idle: return "Starting…"
        case .downloading(let modelId, let p):
            return "Downloading \(shortModelName(modelId))… \(Int(p * 100))%"
        case .finalizing(let modelId):
            return "Loading \(shortModelName(modelId)) into memory…"
        case .ready(let id): return "Model: \(shortModelName(id))"
        case .failed(let modelId, let msg): return "Model error (\(shortModelName(modelId))): \(msg)"
        }
    }

    private func shortModelName(_ id: String) -> String { ModelAdvisor.displayName(for: id) }

    // MARK: - Actions

    @objc private func toggleEnabled() {
        settings.isEnabled.toggle()
        rebuildMenu()
    }

    @objc private func pause15() { engine.pause(minutes: 15); rebuildMenu() }
    @objc private func pause60() { engine.pause(minutes: 60); rebuildMenu() }
    @objc private func pauseIndefinitely() { engine.pause(minutes: nil); rebuildMenu() }
    @objc private func resumeNow() { engine.resume(); rebuildMenu() }
    @objc private func resumeAppPause() { engine.resumeFrontmostAppPause(); rebuildMenu() }

    @objc private func openStatistics() { openSettingsWindow(for: .statistics) }
    @objc private func openAbout() { openSettingsWindow(for: .about) }
    @objc private func openWhatsNew() { openSettingsWindow(for: .whatsNew) }

    /// Opens What's New once after an update, then records this version so
    /// rebuilds and relaunches of the same version stay quiet.
    private func announceUpdateIfNeeded(isSetUp: Bool) {
        let current = ReleaseNotes.currentVersion
        let announce = ReleaseNotes.shouldAnnounce(
            current: current, lastSeen: settings.lastSeenVersion, isSetUp: isSetUp,
            hasNotes: ReleaseNotes.bundled.contains { $0.version == current })
        settings.lastSeenVersion = current
        guard announce else { return }
        Log.shared.info("announcing release notes for \(current)")
        openSettingsWindow(for: .whatsNew)
    }

    /// The plain Settings action opens where setup state says (see `defaultDestination`).
    @objc private func openSettings() { openSettingsWindow(for: .settings) }

    private func openSettingsWindow(for entry: SettingsEntry) {
        SettingsNavigator.shared.pending = SettingsNavigator.destination(
            for: entry, axGranted: AccessibilityBridge.isTrusted(), modelReady: provider.isModelReady)
        showSettingsWindow()
    }

    private func showSettingsWindow() {
        // Read before creating the window: its SwiftUI content can consume `pending`.
        let item = SettingsNavigator.shared.pending?.item
        if settingsWindow == nil {
            let view = SettingsView().environmentObject(settings).environmentObject(provider)
            let hosting = NSHostingController(rootView: view)
            let window = NSWindow(contentViewController: hosting)
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.setContentSize(NSSize(width: SettingsNavigator.shared.desiredContentWidth, height: 620))
            window.minSize = NSSize(width: 760, height: 460)
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            settingsWindow = window
            // SwiftUI can't drive an AppKit-hosted window's size, so the settings
            // content publishes the width each section wants and we animate to it.
            SettingsNavigator.shared.$desiredContentWidth
                .removeDuplicates()
                .sink { [weak self] width in self?.resizeSettings(toContentWidth: width) }
                .store(in: &cancellables)
        }
        // SwiftUI's navigationTitle only reaches the window on a selection change,
        // so set it to the item this open lands on (also when the window is reused).
        if let item { settingsWindow?.title = item.rawValue }
        // Give S1S a Dock icon + Cmd-Tab entry while Settings is open — as a
        // menu-bar-only (.accessory) app, clicking another app would otherwise send
        // this window behind it with no way back except reopening from the menu bar.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
        // Honor the current item's width now that the window is visible (the
        // sink's initial value arrived while it was still hidden).
        resizeSettings(toContentWidth: SettingsNavigator.shared.desiredContentWidth)
    }

    /// Animate the settings window to a section's desired content width, keeping it
    /// on screen. Height is preserved (respects any manual vertical resize). A
    /// hidden window (S1S hidden, or not shown yet) is resized without
    /// animation, so a width change made while it was hidden isn't lost.
    private func resizeSettings(toContentWidth width: CGFloat) {
        guard let window = settingsWindow else { return }
        let currentContent = window.contentRect(forFrameRect: window.frame).size
        Log.shared.debug("resizeSettings: \(currentContent.width) -> \(width)")
        guard abs(currentContent.width - width) > 1 else { return }
        var frame = window.frame
        let target = window.frameRect(forContentRect:
            NSRect(x: 0, y: 0, width: width, height: currentContent.height)).size
        // Grow/shrink around the current center, then nudge back on screen.
        frame.origin.x -= (target.width - frame.width) / 2
        frame.size.width = target.width
        if let vis = window.screen?.visibleFrame {
            frame.origin.x = min(max(frame.origin.x, vis.minX), vis.maxX - frame.width)
        }
        // `setFrame(_:display:animate:)` is the reliable AppKit API — `animator()`
        // outside an explicit animation context can silently no-op.
        window.setFrame(frame, display: window.isVisible, animate: window.isVisible)
    }

    @objc private func showOnboarding() {
        presentOnboarding(requiresProfile: !settings.hasCompletedOnboarding)
    }

    /// `requiresProfile` forces the personalization flow, as redo needs. A redo
    /// starts from a fresh window so no earlier picks carry over.
    private func presentOnboarding(requiresProfile: Bool) {
        if requiresProfile && settings.hasCompletedOnboarding {
            onboardingWindow?.close()
            onboardingWindow = nil
        }
        if onboardingWindow == nil {
            let view = OnboardingView(
                requiresProfile: requiresProfile,
                onGrant: { AccessibilityBridge.requestTrust() },
                onGrantScreen: { _ = ScreenContextProvider.shared.requestPermission() },
                onDone: { [weak self] profile in
                    guard let self else { return }
                    if let profile {
                        self.settings.completeOnboarding(profile)
                        // The persona and examples changed; re-cache the prompt head.
                        if self.provider.isReady { self.engine.warmUpModel() }
                    }
                    guard self.settings.hasCompletedOnboarding else { return }
                    self.rebuildMenu()
                    self.finishOnboardingIfReady()
                }
            )
            let hosting = NSHostingController(rootView: view)
            let window = NSWindow(contentViewController: hosting)
            window.title = "Welcome to S1S"
            window.styleMask = [.titled, .closable]
            window.setContentSize(NSSize(width: 612, height: 562))
            window.isReleasedWhenClosed = false
            window.center()
            onboardingWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        onboardingWindow?.makeKeyAndOrderFront(nil)
    }

    /// Closes onboarding and starts the engine once first-run choices and
    /// Accessibility are both done.
    private func finishOnboardingIfReady() {
        guard settings.hasCompletedOnboarding, AccessibilityBridge.isTrusted() else { return }
        onboardingWindow?.close()
        onboardingWindow = nil
        _ = engine.start()
    }

    @objc private func openLog() {
        NSWorkspace.shared.open(Log.fileURL)
    }

    /// Best-effort: write the global default that controls macOS inline predictive
    /// text so it doesn't conflict with S1S. Fully applies after log out/in.
    private func applyMacOSPredictiveText() {
        let key = "NSAutomaticInlinePredictionEnabled" as CFString
        let value = settings.disableMacOSPredictiveText ? kCFBooleanFalse : nil
        CFPreferencesSetValue(key, value, kCFPreferencesAnyApplication,
                              kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)
        CFPreferencesSynchronize(kCFPreferencesAnyApplication,
                                 kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        guard notification.object as? NSWindow === settingsWindow else { return }
        // Revert to menu-bar-only now that Settings is closed.
        NSApp.setActivationPolicy(.accessory)
    }

    // MARK: - Permission polling

    private func waitForTrustThenStart() {
        trustTimer?.invalidate()
        trustTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if AccessibilityBridge.isTrusted() {
                    self.trustTimer?.invalidate()
                    self.trustTimer = nil
                    self.rebuildMenu()
                    self.finishOnboardingIfReady()
                }
            }
        }
    }
}
