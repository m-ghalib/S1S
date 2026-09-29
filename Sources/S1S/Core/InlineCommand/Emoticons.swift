import Foundation

/// Maps common text emoticons to emoji, e.g. ":-)" → 🙂, "<3" → ❤️.
enum Emoticons {
    static let map: [String: String] = [
        ":-)": "🙂", ":)": "🙂", ":-(": "😞", ":(": "😞",
        ";-)": "😉", ";)": "😉", ":-D": "😀", ":D": "😀",
        ":-P": "😛", ":P": "😛", ":-p": "😛", ":p": "😛",
        "<3": "❤️", "</3": "💔", ":'(": "😢", ":’(": "😢",
        ":-o": "😮", ":o": "😮", ":-O": "😮", ":O": "😮",
        ":-|": "😐", ":|": "😐", ":-/": "😕", ":/": "😕",
        "XD": "😆", "xD": "😆", ":3": "😊", "^^": "😄", "^_^": "😄",
        ":*": "😘", ":-*": "😘", "8)": "😎", "B)": "😎",
    ]

    /// If `token` is a known emoticon, its emoji; else nil.
    static func emoji(for token: String) -> String? { map[token] }
}
