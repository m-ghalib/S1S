import AppKit

@main
struct S1SMain {
    static func main() {
        LegacyMigration.run()
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        // Agent app: no Dock icon, lives in the menu bar.
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
