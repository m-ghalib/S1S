// Dump the accessibility facts TabType depends on for one app's focused text field.
// Usage: swift ax-probe.swift <bundle-id> [--no-activate]
// Put the caret in the target field first. Run it ~3 times to confirm values are stable.
import AppKit
import ApplicationServices

let args = CommandLine.arguments
guard args.count > 1 else { print("usage: swift ax-probe.swift <bundle-id> [--no-activate]"); exit(2) }
let bid = args[1]
guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bid).first else {
    print("not running: \(bid)"); exit(1)
}
guard AXIsProcessTrusted() else {
    print("this process lacks Accessibility access; grant it to the terminal running Claude Code"); exit(1)
}
// A background app reports no focused element.
if !args.contains("--no-activate") {
    app.activate()
    Thread.sleep(forTimeInterval: 1.2)
}
let axApp = AXUIElementCreateApplication(app.processIdentifier)
// Chromium/Electron expose their web AX tree only after a client asks (as TabType does).
AXUIElementSetAttributeValue(axApp, "AXManualAccessibility" as CFString, kCFBooleanTrue)
AXUIElementSetAttributeValue(axApp, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
Thread.sleep(forTimeInterval: 0.3)

func attr(_ e: AXUIElement, _ name: String) -> CFTypeRef? {
    var v: CFTypeRef?
    return AXUIElementCopyAttributeValue(e, name as CFString, &v) == .success ? v : nil
}

func describe(_ v: CFTypeRef?) -> String {
    guard let v else { return "-" }
    if CFGetTypeID(v) == AXValueGetTypeID() {
        let av = v as! AXValue
        switch AXValueGetType(av) {
        case .cgPoint: var p = CGPoint.zero; AXValueGetValue(av, .cgPoint, &p); return "(\(p.x), \(p.y))"
        case .cgSize: var s = CGSize.zero; AXValueGetValue(av, .cgSize, &s); return "\(s.width) x \(s.height)"
        case .cgRect: var r = CGRect.zero; AXValueGetValue(av, .cgRect, &r); return "\(r)"
        case .cfRange: var r = CFRange(); AXValueGetValue(av, .cfRange, &r); return "loc=\(r.location) len=\(r.length)"
        default: return "\(av)"
        }
    }
    if let s = v as? String {
        let flat = s.replacingOccurrences(of: "\n", with: "⏎")
        return flat.count > 120 ? "\"\(flat.prefix(50))…\(flat.suffix(50))\" (\(s.count) chars)" : "\"\(flat)\""
    }
    if let u = v as? URL { return u.absoluteString }
    return "\(v)"
}

func bounds(_ e: AXUIElement, _ loc: Int, _ len: Int) -> String {
    var range = CFRange(location: loc, length: len)
    guard let param = AXValueCreate(.cfRange, &range) else { return "-" }
    var out: CFTypeRef?
    let err = AXUIElementCopyParameterizedAttributeValue(e, kAXBoundsForRangeParameterizedAttribute as CFString, param, &out)
    return err == .success ? describe(out) : "error \(err.rawValue)"
}

print("app: \(app.localizedName ?? "?") (\(bid)) pid=\(app.processIdentifier)")
if let win = attr(axApp, kAXFocusedWindowAttribute) {
    let w = win as! AXUIElement
    print("window: title=\(describe(attr(w, kAXTitleAttribute))) pos=\(describe(attr(w, kAXPositionAttribute))) size=\(describe(attr(w, kAXSizeAttribute)))")
}
guard let focusedRef = attr(axApp, kAXFocusedUIElementAttribute) else {
    print("focused element: NONE (click into the text field, keep the app frontmost, retry)"); exit(1)
}
let el = focusedRef as! AXUIElement
for name in ["AXRole", "AXSubrole", "AXRoleDescription", "AXPlaceholderValue", "AXValue",
             "AXNumberOfCharacters", "AXSelectedTextRange", "AXPosition", "AXSize", "AXURL"] {
    print("  \(name): \(describe(attr(el, name)))")
}
if (attr(el, "AXSubrole") as? String) == "AXSecureTextField" { print("  SECURE FIELD: TabType never reads or suggests here") }

var sel = CFRange()
if let s = attr(el, kAXSelectedTextRangeAttribute), CFGetTypeID(s) == AXValueGetTypeID() {
    AXValueGetValue(s as! AXValue, .cfRange, &sel)
    print("  caret bounds (len 0): \(bounds(el, sel.location, 0))")
    if sel.location > 0 { print("  prev-char bounds (len 1): \(bounds(el, sel.location - 1, 1))") }
    if sel.location == 0, ((attr(el, "AXNumberOfCharacters") as? Int) ?? 0) > 0 {
        print("  WARNING: caret reported at 0 in a non-empty field (Ghostty-style blocker; policy cannot fix)")
    }
} else {
    print("  WARNING: no AXSelectedTextRange; TabType cannot place a caret here")
}

// Walk up for web content: AXWebArea + AXURL drive website (domain) policies.
var cur: AXUIElement? = el
var chain: [String] = []
for _ in 0..<40 {
    guard let c = cur else { break }
    let role = (attr(c, "AXRole") as? String) ?? "?"
    chain.append(role)
    if role == "AXWebArea" { print("web area: AXURL=\(describe(attr(c, "AXURL")))") }
    cur = attr(c, kAXParentAttribute).map { $0 as! AXUIElement }
}
print("parent roles: \(chain.joined(separator: " < "))")
