import Combine
import MurmurKeyboardCore
import MurmurKeyboardUI
import SwiftUI
import UIKit

/// The Murmur keyboard.
///
/// It is a real keyboard first — every character on three pages types with Full Access off,
/// there is a next-keyboard globe, and the only apps it can open are Murmur itself and
/// Settings (App Store guideline 4.4.1, design spec §2 constraint 6). The mic key is the
/// headline feature and the documented review risk: an extension may not record (constraint
/// 1), so it hands off to the containing app and picks the text up when it comes back.
///
/// Nothing in this target touches AVFoundation, Speech, GRDB, or the Rust core — see the
/// link-graph rule in `MurmurShared/Package.swift`. Nothing here logs; dictated text passes
/// through and is never printed.
final class KeyboardViewController: UIInputViewController {
    /// The system keyboard's heights. iOS gives an extension no default, so the input view
    /// carries its own constraint.
    private static let portraitHeight: CGFloat = 216
    private static let landscapeHeight: CGFloat = 162

    private lazy var controller = KeyboardController(
        urlOpener: ResponderChainOpener(self),
        hasFullAccess: { [weak self] in self?.hasFullAccess ?? false }
    )

    private var host: UIHostingController<KeyboardView>?
    private var heightConstraint: NSLayoutConstraint?
    private var phaseObserver: AnyCancellable?

    /// Whether the user has touched a typing key since the last mic tap. A finished dictation
    /// is typed the moment it arrives — there is no confirm setting in v1 — but not if the
    /// user gave up waiting and started typing, in which case the strip's **Insert** and
    /// **Discard** buttons hand the decision back to them.
    private var typedSinceMicTap = false

    /// Haptics need Full Access, so the generator is only ever fired behind that check.
    private let haptics = UIImpactFeedbackGenerator(style: .light)

    /// Always read fresh: iOS replaces the proxy when the host app changes fields.
    private var proxy: DocumentTextProxy { DocumentTextProxy(proxy: textDocumentProxy) }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear

        let host = UIHostingController(rootView: makeView())
        host.view.backgroundColor = .clear
        host.view.translatesAutoresizingMaskIntoConstraints = false
        addChild(host)
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        host.didMove(toParent: self)
        self.host = host

        // 999 rather than required: iOS installs its own encapsulated-height constraint on the
        // input view and two required constraints would break the layout instead of resizing it.
        let height = view.heightAnchor.constraint(equalToConstant: Self.portraitHeight)
        height.priority = UILayoutPriority(999)
        height.isActive = true
        heightConstraint = height

        // The result can also land while the keyboard is on screen — the user came back early
        // and `KeyboardController`'s poll loop claimed it. `Task { @MainActor }` because
        // `@Published` fires on `willSet`, so the new phase is only readable a hop later.
        phaseObserver = controller.$phase.sink { [weak self] _ in
            Task { @MainActor in self?.drainPendingInsert() }
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        updateHeight()
        // `needsInputModeSwitchKey` can change between appearances (the user enables a second
        // keyboard), so the globe decision is remade every time rather than at load.
        refreshView()
        if hasFullAccess { haptics.prepare() }
        controller.viewWillAppear()
        drainPendingInsert()
    }

    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        updateHeight()
    }

    /// Fires when the host app's text changes for any reason, including our own insertions.
    override func textDidChange(_ textInput: UITextInput?) {
        super.textDidChange(textInput)
        controller.checkForResult()
        // Auto-capitalise at the start of a document and after a sentence, the way the system
        // keyboard does — but never fight a shift the user set themselves.
        if controller.state.shift == .off {
            controller.state.shift = KeyboardState.autoShift(
                contextBefore: textDocumentProxy.documentContextBeforeInput
            )
        }
    }

    // MARK: - Keys

    private func makeView() -> KeyboardView {
        KeyboardView(
            controller: controller,
            showsGlobe: needsInputModeSwitchKey,
            onKey: { [weak self] key in self?.handle(key) },
            onInsert: { [weak self] in
                guard let self else { return }
                self.typedSinceMicTap = false
                self.controller.insertPreview(proxy: self.proxy)
            }
        )
    }

    private func refreshView() {
        host?.rootView = makeView()
    }

    private func handle(_ key: Key) {
        impact()
        switch key {
        case .globe:
            // The one thing only the input view controller can do.
            advanceToNextInputMode()
        case .mic:
            typedSinceMicTap = false
            controller.tapMic()
        case .char, .space, .return, .delete:
            typedSinceMicTap = true
            controller.tap(key, proxy: proxy)
        case .shift, .numbers, .symbols, .letters:
            controller.tap(key, proxy: proxy)
        }
    }

    private func impact() {
        guard hasFullAccess else { return }
        haptics.impactOccurred()
    }

    // MARK: - Insertion

    /// Type a claimed result, unless the user has started typing again since the mic tap.
    private func drainPendingInsert() {
        guard controller.pendingInsert != nil, !typedSinceMicTap else { return }
        controller.insertPreview(proxy: proxy)
    }

    // MARK: - Height

    private func updateHeight() {
        let target = isLandscape ? Self.landscapeHeight : Self.portraitHeight
        guard let heightConstraint, heightConstraint.constant != target else { return }
        heightConstraint.constant = target
    }

    private var isLandscape: Bool {
        if let scene = view.window?.windowScene { return scene.interfaceOrientation.isLandscape }
        return traitCollection.verticalSizeClass == .compact
    }
}
