import CoreGraphics
import AppKit

/// A rebindable keyboard shortcut: a key code plus modifier flags.
struct KeyBinding: Codable, Equatable {
    var keyCode: Int
    /// Raw bits of the relevant `CGEventFlags` (cmd/shift/opt/ctrl only).
    var modifiers: UInt64

    static let unset = KeyBinding(keyCode: -1, modifiers: 0)
    var isSet: Bool { keyCode >= 0 }

    static let relevantMask: CGEventFlags = [.maskCommand, .maskShift, .maskAlternate, .maskControl]

    init(keyCode: Int, modifiers: UInt64) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    init(keyCode: Int, flags: CGEventFlags) {
        self.keyCode = keyCode
        self.modifiers = flags.intersection(KeyBinding.relevantMask).rawValue
    }

    func matches(keyCode kc: Int64, flags: CGEventFlags) -> Bool {
        guard isSet, Int(kc) == keyCode else { return false }
        return flags.intersection(KeyBinding.relevantMask).rawValue == modifiers
    }

    // Common defaults.
    static let tab = KeyBinding(keyCode: 48, modifiers: 0)
    static let shiftTab = KeyBinding(keyCode: 48, flags: .maskShift)
    static let escape = KeyBinding(keyCode: 53, modifiers: 0)
    static let controlBacktick = KeyBinding(keyCode: 50, flags: .maskControl)
    static let controlOptionSpace = KeyBinding(keyCode: 49, flags: [.maskControl, .maskAlternate])
    static let controlOptionCommandP = KeyBinding(
        keyCode: 35, flags: [.maskControl, .maskAlternate, .maskCommand])

    /// Human-readable, e.g. "⇧⇥" or "⌃Space".
    var displayString: String {
        guard isSet else { return "None" }
        var s = ""
        let f = CGEventFlags(rawValue: modifiers)
        if f.contains(.maskControl) { s += "⌃" }
        if f.contains(.maskAlternate) { s += "⌥" }
        if f.contains(.maskShift) { s += "⇧" }
        if f.contains(.maskCommand) { s += "⌘" }
        s += KeyBinding.keyName(keyCode)
        return s
    }

    static func keyName(_ code: Int) -> String {
        switch code {
        case 48: return "⇥"
        case 53: return "esc"
        case 36: return "return"
        case 49: return "space"
        case 51: return "delete"
        case 117: return "⌦"
        case 122: return "F1"; case 120: return "F2"; case 99: return "F3"; case 118: return "F4"
        case 96: return "F5"; case 97: return "F6"; case 98: return "F7"; case 100: return "F8"
        case 101: return "F9"; case 109: return "F10"; case 103: return "F11"; case 111: return "F12"
        case 123: return "←"; case 124: return "→"; case 125: return "↓"; case 126: return "↑"
        default:
            // Fall back to the character for the key (best effort).
            return Self.character(for: code)?.uppercased() ?? "key\(code)"
        }
    }

    /// ANSI layout: letters, digits, and punctuation.
    private static func character(for keyCode: Int) -> String? {
        let map: [Int: String] = [
            0:"a",1:"s",2:"d",3:"f",4:"h",5:"g",6:"z",7:"x",8:"c",9:"v",11:"b",
            12:"q",13:"w",14:"e",15:"r",16:"y",17:"t",31:"o",32:"u",34:"i",35:"p",
            37:"l",38:"j",40:"k",45:"n",46:"m",
            18:"1",19:"2",20:"3",21:"4",23:"5",22:"6",26:"7",28:"8",25:"9",29:"0",
            50:"`",27:"-",24:"=",33:"[",30:"]",42:"\\",41:";",39:"'",43:",",47:".",44:"/",
        ]
        return map[keyCode]
    }
}
