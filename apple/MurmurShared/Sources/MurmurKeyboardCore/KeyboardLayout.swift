import Foundation

/// Which of the three key pages the keyboard is showing. There is no emoji page in v1
/// (design spec §6.1) — the system emoji keyboard is one globe tap away.
public enum KeyboardPage: Equatable, CaseIterable {
    case letters, numbers, symbols
}

/// Shift, exactly as the system keyboard models it: off, armed for one character, or locked.
public enum ShiftState: Equatable, CaseIterable {
    case off, on, capsLock
}

/// One key cap.
///
/// `.char` carries what the cap shows on the *lowercase* letters page — `.char("a")` — so the
/// layout tables read like the keyboard looks; ``KeyboardLayout/text(for:shift:)`` is what
/// turns a cap plus a ``ShiftState`` into the text that actually gets typed.
public enum Key: Equatable {
    case char(String)
    case shift, delete, numbers, symbols, letters, globe, mic, space, `return`
}

/// The static key tables and the cap → text mapping. No state, no UI: the extension's SwiftUI
/// layer walks ``rows(for:)`` and asks ``text(for:shift:)`` what a tap types.
public enum KeyboardLayout {
    /// The rows of `page`, top to bottom.
    ///
    /// The bottom row is the same shape on every page — page toggle, globe, mic, space,
    /// return — with the mic immediately left of the space bar, where the system dictation key
    /// sits, so muscle memory carries over (design spec §6.1). The globe cap is always present
    /// here; the view controller hides it when `needsInputModeSwitchKey` is false.
    public static func rows(for page: KeyboardPage) -> [[Key]] {
        switch page {
        case .letters:
            return [
                chars("qwertyuiop"),
                chars("asdfghjkl"),
                [.shift] + chars("zxcvbnm") + [.delete],
                bottom(toggle: .numbers),
            ]
        case .numbers:
            return [
                chars("1234567890"),
                chars("-/:;()$&@\""),
                [.symbols] + chars(".,?!'") + [.delete],
                bottom(toggle: .letters),
            ]
        case .symbols:
            return [
                chars("[]{}#%^*+="),
                chars("_\\|~<>€£¥•"),
                [.numbers] + chars(".,?!'") + [.delete],
                bottom(toggle: .letters),
            ]
        }
    }

    /// What tapping `key` types, or `nil` for the keys that do something other than insert text.
    ///
    /// Shift only ever changes a letter: `"1"`, `"€"` and the rest uppercase to themselves, so
    /// the number and symbol pages need no special case here.
    public static func text(for key: Key, shift: ShiftState) -> String? {
        switch key {
        case let .char(cap):
            switch shift {
            case .off: return cap
            case .on, .capsLock: return cap.uppercased()
            }
        case .space: return " "
        case .return: return "\n"
        case .shift, .delete, .numbers, .symbols, .letters, .globe, .mic: return nil
        }
    }

    private static func chars(_ caps: String) -> [Key] {
        caps.map { .char(String($0)) }
    }

    private static func bottom(toggle: Key) -> [Key] {
        [toggle, .globe, .mic, .space, .return]
    }
}
