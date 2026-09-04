import Combine
import Foundation
import MurmurSharedBase

/// The slice of `UITextDocumentProxy` the keyboard's logic needs, so every test can type
/// without a host app.
public protocol TextProxy {
    func insertText(_ s: String)
    func deleteBackward()
    /// `documentContextBeforeInput` — `nil` or empty at the start of a field.
    var contextBefore: String? { get }
}

/// Opening a URL from inside an app extension. The extension's implementation walks the
/// responder chain to `UIApplication`; tests record the URLs instead.
public protocol URLOpening {
    func open(_ url: URL) -> Bool
}

/// What the status strip above the keys is showing.
public enum KeyboardPhase: Equatable {
    /// "Tap the mic to dictate".
    case idle
    /// Full Access is off, so the mic cannot open Murmur. The strip offers Settings.
    case needsFullAccess
    /// "Listening in Murmur…" — the round trip is out, `since` is when it left.
    case waiting(session: UUID, since: Date)
    /// A result has been claimed and is waiting to be typed.
    case preview(DictationResult)
    /// Just typed. Falls back to ``idle`` on its own.
    case inserted
}

/// Everything the Murmur keyboard does that is not drawing: typing, shift, the page toggles,
/// and the App Group round trip that turns a mic tap into inserted text.
///
/// Deliberately free of UIKit, of the audio and speech frameworks, and of the Rust core
/// bindings — see the link-graph rule in `Package.swift`. Guideline 4.4.1 wants a keyboard
/// that types, and the extension is not allowed to record: it writes a pending request, opens
/// `murmur://dictate?session=…`, and waits for the app to write the result back
/// (design spec §6.1, §8).
///
/// Nothing here logs. Dictated text passes through this object and is never printed.
@MainActor
public final class KeyboardController: ObservableObject {
    /// How long the freshly-typed confirmation stays up before the strip returns to idle.
    private static let insertedDisplay: TimeInterval = 2

    @Published public private(set) var phase: KeyboardPhase = .idle
    @Published public var state = KeyboardState()

    /// The claimed result waiting to be typed, if any. The view controller drains it through
    /// ``insertPreview(proxy:)`` — immediately, unless the user has started typing again.
    public var pendingInsert: DictationResult? {
        guard case let .preview(result) = phase else { return nil }
        return result
    }

    private let defaults: UserDefaults
    private let urlOpener: URLOpening
    private let hasFullAccess: () -> Bool
    private let clock: () -> Date
    private let pollInterval: TimeInterval
    private let waitTimeout: TimeInterval
    private let sleeper: (TimeInterval) async -> Void

    private var pollTask: Task<Void, Never>?
    private var resetTask: Task<Void, Never>?

    public init(
        defaults: UserDefaults = AppGroup.defaults,
        urlOpener: URLOpening,
        hasFullAccess: @escaping () -> Bool,
        clock: @escaping () -> Date = Date.init,
        pollInterval: TimeInterval = 0.5,
        waitTimeout: TimeInterval = 60,
        sleeper: @escaping (TimeInterval) async -> Void = KeyboardController.liveSleep
    ) {
        self.defaults = defaults
        self.urlOpener = urlOpener
        self.hasFullAccess = hasFullAccess
        self.clock = clock
        self.pollInterval = pollInterval
        self.waitTimeout = waitTimeout
        self.sleeper = sleeper
    }

    // MARK: - Lifecycle

    /// Called from `UIInputViewController.viewWillAppear`. Leaves the Full Access heartbeat,
    /// then looks for a result the app wrote while the keyboard was away.
    ///
    /// The heartbeat is the containing app's only way to answer "is Full Access on?" — iOS
    /// gives it no way to ask — so the keys belong to the reader, ``KeyboardStatus``, and the
    /// keyboard just leaves the note.
    public func viewWillAppear() {
        defaults.set(hasFullAccess(), forKey: KeyboardStatus.fullAccessKey)
        defaults.set(clock(), forKey: KeyboardStatus.lastSeenKey)
        checkForResult()
    }

    /// Claim a finished dictation, if one is waiting for us.
    ///
    /// An outstanding request wins: while a `pending` session is on the books only *that*
    /// session's result may be claimed, so a stale round trip can never be typed into the wrong
    /// field. With no request outstanding the fixed ``Handoff/intentSession`` is tried instead,
    /// which is how an Action Button or Control Center dictation reaches the keyboard.
    ///
    /// A hit parks in ``KeyboardPhase/preview(_:)``; the view controller types it right away
    /// through ``insertPreview(proxy:)`` unless the user has started typing again, in which case
    /// the strip's **Insert** / **Discard** buttons decide.
    public func checkForResult() {
        let now = clock()
        let claimed: DictationResult?
        if let pending = Handoff.readPending(now: now, defaults: defaults) {
            claimed = Handoff.takeResult(for: pending.session, now: now, defaults: defaults)
        } else {
            claimed = Handoff.takeResult(for: Handoff.intentSession, now: now, defaults: defaults)
        }
        guard let claimed else { return }

        pollTask?.cancel()
        pollTask = nil
        resetTask?.cancel()
        resetTask = nil
        phase = .preview(claimed)
    }

    // MARK: - The mic round trip

    /// The one place the keyboard opens another app, and the documented 4.4.1 risk: it opens
    /// Murmur's own containing app, because the extension is not allowed a microphone.
    public func tapMic() {
        guard hasFullAccess() else {
            phase = .needsFullAccess
            return
        }

        let session = UUID()
        let now = clock()
        Handoff.writePending(PendingDictation(session: session, requestedAt: now), defaults: defaults)
        // The responder-chain opener cannot report reliably whether the app came up, so the
        // strip goes to "Listening in Murmur…" either way; the timeout below is the way back.
        _ = urlOpener.open(URL(string: "murmur://dictate?session=\(session.uuidString)")!)
        phase = .waiting(session: session, since: now)
        startPolling()
    }

    /// The other allowed destination: Settings, when Full Access is off.
    public func openSettings() {
        _ = urlOpener.open(URL(string: "app-settings:")!)
    }

    // MARK: - Typing

    /// Apply a key tap.
    ///
    /// `.globe` and `.mic` are no-ops here on purpose: the view controller owns them, because
    /// only it can call `advanceToNextInputMode()`. It routes the mic cap to ``tapMic()``.
    public func tap(_ key: Key, proxy: TextProxy) {
        switch key {
        case .char, .space, .return:
            guard let text = KeyboardLayout.text(for: key, shift: state.shift) else { return }
            proxy.insertText(text)
            state.didInsert(text)
        case .delete:
            proxy.deleteBackward()
        case .shift:
            state.tapShift(now: clock().timeIntervalSinceReferenceDate)
        case .numbers:
            state.page = .numbers
        case .symbols:
            state.page = .symbols
        case .letters:
            state.page = .letters
        case .globe, .mic:
            break
        }
    }

    /// Type the claimed result. Safe to call twice — the second call has nothing to type.
    public func insertPreview(proxy: TextProxy) {
        guard case let .preview(result) = phase else { return }
        proxy.insertText(result.clean)
        state.didInsert(result.clean)
        Handoff.clearResult(defaults: defaults)
        phase = .inserted

        let sleeper = self.sleeper
        let delay = Self.insertedDisplay
        resetTask?.cancel()
        resetTask = Task { [weak self] in
            await sleeper(delay)
            guard !Task.isCancelled, let self, self.phase == .inserted else { return }
            self.phase = .idle
        }
    }

    /// Throw the claimed result away without typing it.
    public func discardPreview() {
        guard case .preview = phase else { return }
        Handoff.clearResult(defaults: defaults)
        Handoff.clearPending(defaults: defaults)
        phase = .idle
    }

    // MARK: - Polling

    /// Poll the App Group while the user is back in the host app early, up to ``waitTimeout``
    /// (design spec §6.1 step 3). Elapsed time is counted in poll intervals rather than off the
    /// clock so an injected clock that does not move still times out.
    private func startPolling() {
        pollTask?.cancel()
        let interval = max(pollInterval, 0.01)
        let timeout = waitTimeout
        let sleeper = self.sleeper
        pollTask = Task { [weak self] in
            var waited: TimeInterval = 0
            while !Task.isCancelled {
                await sleeper(interval)
                guard !Task.isCancelled, let self else { return }
                waited += interval

                self.checkForResult()
                guard case .waiting = self.phase else { return }

                if waited >= timeout {
                    Handoff.clearPending(defaults: self.defaults)
                    self.phase = .idle
                    return
                }
            }
        }
    }

    /// The default for `sleeper`. Tests replace it so the poll loop runs at once.
    public static func liveSleep(_ seconds: TimeInterval) async {
        try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
    }
}
