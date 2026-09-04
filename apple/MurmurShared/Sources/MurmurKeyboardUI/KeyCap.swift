import MurmurKeyboardCore
import SwiftUI

/// One key, drawn the way iOS draws one: a rounded rectangle with a single point of shadow
/// under it, a fill that flips with the colour scheme, and the label centred.
///
/// It fires on key *down*, like the system keyboard, so a fast typist gets the character
/// under their finger rather than under the finger they lifted. ``repeats`` turns that into
/// the delete key's hold-to-repeat.
public struct KeyCap: View {
    /// A cap shows a string ("Q", "123", "space") or an SF Symbol (shift, delete, globe, mic).
    public enum Content: Equatable {
        case text(String)
        case symbol(String)
    }

    /// What the fill says about the key. `primary` is a character key (and an engaged shift),
    /// `modifier` is everything grey, `accent` is the mic.
    public enum Role: Equatable {
        case primary, modifier, accent
    }

    /// How long delete waits before it starts repeating, and how fast it repeats after that.
    public static let repeatDelay: TimeInterval = 0.4
    public static let repeatInterval: TimeInterval = 0.1

    private let content: Content
    private let role: Role
    private let fontSize: CGFloat
    private let repeats: Bool
    private let action: () -> Void

    @Environment(\.colorScheme) private var scheme
    @State private var pressed = false
    @State private var repeatTimer: Timer?

    public init(
        content: Content,
        role: Role = .primary,
        fontSize: CGFloat = 22,
        repeats: Bool = false,
        action: @escaping () -> Void
    ) {
        self.content = content
        self.role = role
        self.fontSize = fontSize
        self.repeats = repeats
        self.action = action
    }

    public var body: some View {
        label
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(fill)
                    .shadow(color: shadow, radius: 0, x: 0, y: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            // minimumDistance 0 makes this fire the moment the finger lands, which is what a
            // keyboard has to do; a plain Button would wait for the lift.
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in keyDown() }
                    .onEnded { _ in keyUp() }
            )
            .accessibilityAddTraits(.isKeyboardKey)
            .accessibilityLabel(accessibilityText)
    }

    @ViewBuilder
    private var label: some View {
        switch content {
        case let .text(text):
            Text(text)
                .font(.system(size: fontSize, weight: .regular))
                .foregroundStyle(foreground)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        case let .symbol(name):
            Image(systemName: name)
                .font(.system(size: fontSize, weight: .regular))
                .foregroundStyle(foreground)
        }
    }

    private var accessibilityText: String {
        switch content {
        case let .text(text): return text
        case let .symbol(name): return name
        }
    }

    // MARK: - Press handling

    private func keyDown() {
        guard !pressed else { return }
        pressed = true
        action()
        guard repeats else { return }
        schedule(after: Self.repeatDelay) {
            action()
            schedule(after: Self.repeatInterval, repeating: true, action)
        }
    }

    private func keyUp() {
        pressed = false
        repeatTimer?.invalidate()
        repeatTimer = nil
    }

    private func schedule(after delay: TimeInterval, repeating: Bool = false, _ body: @escaping () -> Void) {
        repeatTimer?.invalidate()
        let timer = Timer(timeInterval: delay, repeats: repeating) { _ in body() }
        // .common so a hold keeps repeating even while something else is tracking touches.
        RunLoop.main.add(timer, forMode: .common)
        repeatTimer = timer
    }

    // MARK: - Palette

    /// Light mode is the system's: white character keys, grey modifiers, on a grey deck.
    /// Dark mode inverts the order — the deck is darkest, modifiers sit above it, character
    /// keys are the lightest thing on screen — which is why the two sides are not one
    /// dynamic colour.
    private var fill: Color {
        switch (role, scheme) {
        case (.accent, _): return KeyboardPalette.indigo
        case (.primary, .dark): return Color(.systemGray2)
        case (.primary, _): return Color(.systemBackground)
        case (.modifier, .dark): return Color(.systemGray4)
        case (.modifier, _): return Color(.systemGray3)
        }
    }

    private var foreground: Color {
        role == .accent ? .white : Color(.label)
    }

    private var shadow: Color {
        Color.black.opacity(scheme == .dark ? 0.6 : 0.28)
    }
}

/// The keyboard's two non-system colours: the deck behind the keys and Murmur's indigo.
public enum KeyboardPalette {
    /// `#6366f1`, the same indigo the app and the Mac HUD use.
    public static let indigo = Color(red: 0.388, green: 0.4, blue: 0.945)

    /// The deck the keys sit on. Deliberately darker than a modifier key in light mode and
    /// darker than everything in dark mode, so the caps read as raised.
    public static func deck(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(.systemGray6) : Color(.systemGray4)
    }
}
