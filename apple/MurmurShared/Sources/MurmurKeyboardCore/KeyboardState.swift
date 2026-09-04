import Foundation

/// Which page is showing and what shift is doing — the whole of the keyboard's typing state.
///
/// A value type on purpose: the controller owns one and publishes it, the tests drive it
/// directly, and nothing here touches `UIKit`, a clock, or the App Group.
public struct KeyboardState: Equatable {
    /// Two shift taps closer together than this are a double tap, i.e. caps lock. The system
    /// keyboard's window is not public; 0.3 s is the design spec's number.
    public static let doubleTapWindow: TimeInterval = 0.3

    public var page: KeyboardPage = .letters
    public var shift: ShiftState = .off

    /// When the previous shift tap happened, on whatever timeline the caller passes to
    /// ``tapShift(now:)``. Not part of `Equatable`'s idea of the state the UI draws, but kept
    /// synthesised so two states that disagree about it are not silently equal.
    private var lastShiftTap: TimeInterval?

    public init(page: KeyboardPage = .letters, shift: ShiftState = .off) {
        self.page = page
        self.shift = shift
    }

    /// Handle a tap on the shift key at `now` (seconds, any monotonic-ish timeline).
    ///
    /// Precedence matters: a tap while caps lock is on always turns it off, even when it lands
    /// inside the double-tap window, because otherwise a fast third tap would leave the user
    /// locked in capitals with no way out but waiting.
    public mutating func tapShift(now: TimeInterval) {
        let previous = lastShiftTap
        lastShiftTap = now

        if shift == .capsLock {
            shift = .off
            return
        }
        if let previous, now >= previous, now - previous <= Self.doubleTapWindow {
            shift = .capsLock
            return
        }
        shift = (shift == .on) ? .off : .on
    }

    /// Called after `text` has been handed to the text proxy. One-shot shift falls away;
    /// caps lock stays until the user taps shift again.
    public mutating func didInsert(_ text: String) {
        guard !text.isEmpty else { return }
        if shift == .on { shift = .off }
    }

    /// The shift state a fresh field (or a fresh sentence) should start in.
    ///
    /// `contextBefore` is `documentContextBeforeInput`: `nil` or empty means the caret is at the
    /// start of the document.
    public static func autoShift(contextBefore: String?) -> ShiftState {
        guard let contextBefore, !contextBefore.isEmpty else { return .on }
        let starters = [". ", "! ", "? ", "\n"]
        return starters.contains(where: contextBefore.hasSuffix) ? .on : .off
    }
}
