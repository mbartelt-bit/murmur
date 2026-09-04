import MurmurKeyboardCore
import UIKit

/// ``TextProxy`` over the real `UITextDocumentProxy`.
///
/// The proxy object is fetched fresh from the input view controller on every tap — iOS swaps
/// it when the host app moves the caret to another field — so this wrapper is created per use
/// and holds nothing.
struct DocumentTextProxy: TextProxy {
    let proxy: UITextDocumentProxy

    func insertText(_ s: String) { proxy.insertText(s) }

    func deleteBackward() { proxy.deleteBackward() }

    var contextBefore: String? { proxy.documentContextBeforeInput }
}

/// The only way an app extension can ask for a URL to be opened: walk up the responder chain
/// until something answers to `UIApplication`'s `openURL:options:completionHandler:`, and
/// call it.
///
/// This is the pattern every shipping dictation keyboard uses (design spec §6.1) and it is
/// deliberately the *only* opener in this target. It is reached from exactly two places, both
/// in ``KeyboardController``: `murmur://dictate?session=…` when the mic is tapped, and
/// `app-settings:` when Full Access is off — the two destinations App Review guideline 4.4.1
/// leaves open to a keyboard.
///
/// `perform(_:with:with:)` cannot be used here: the selector takes three arguments and
/// `perform` only passes two, so the completion-handler register would be garbage. Calling
/// through the method's IMP passes all three, with a null completion handler.
final class ResponderChainOpener: URLOpening {
    private typealias OpenURL = @convention(c) (NSObject, Selector, NSURL, NSDictionary, AnyObject?) -> Void

    private static let selector = NSSelectorFromString("openURL:options:completionHandler:")

    /// Weak: the chain starts at the view controller that owns this opener.
    private weak var start: UIResponder?

    init(_ start: UIResponder) {
        self.start = start
    }

    /// - Returns: `false` when nothing in the chain could open a URL. The caller does not act
    ///   on that — the keyboard cannot tell whether Murmur actually came up either way, so
    ///   the status strip's timeout is the way back.
    func open(_ url: URL) -> Bool {
        var responder: UIResponder? = start
        while let current = responder {
            if current.responds(to: Self.selector), let imp = current.method(for: Self.selector) {
                let openURL = unsafeBitCast(imp, to: OpenURL.self)
                openURL(current, Self.selector, url as NSURL, NSDictionary(), nil)
                return true
            }
            responder = current.next
        }
        return false
    }
}
