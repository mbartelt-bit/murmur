import SwiftUI

extension Color {
    /// Indigo `#6366f1` — the accent the desktop settings window uses.
    static let murmurIndigo = Color(red: 0.388, green: 0.4, blue: 0.945)
    /// The HUD's recording red, `#ff5d5d`.
    static let murmurRecording = Color(red: 1.0, green: 0.365, blue: 0.365)
}

/// The recording dot from the Mac HUD (`src/components/Hud.tsx`), scaled up for a phone.
///
/// Two circles, exactly as on the desktop: a glow ring that expands and fades on a loop, and
/// the dot itself, which breathes on the same loop and is scaled 1.0…1.6 by the live level so
/// the user can see the microphone is hearing them and not just that it is on.
struct RecordingIndicator: View {
    /// RMS 0...1 from the current ``AudioChunk``.
    var level: Float

    @State private var animating = false

    /// The HUD's 1.4 s beat.
    private static let period: Double = 1.4

    private var levelScale: CGFloat {
        1.0 + CGFloat(min(1, max(0, level))) * 0.6
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.murmurRecording)
                .frame(width: 64, height: 64)
                .scaleEffect(animating ? 2.4 : 1)
                .opacity(animating ? 0 : 0.55)
                .animation(
                    .easeOut(duration: Self.period).repeatForever(autoreverses: false),
                    value: animating
                )

            Circle()
                .fill(Color.murmurRecording)
                .frame(width: 64, height: 64)
                .scaleEffect(animating ? 0.72 : 1)
                .opacity(animating ? 0.55 : 1)
                .animation(
                    .easeInOut(duration: Self.period / 2).repeatForever(autoreverses: true),
                    value: animating
                )
                // Applied outside the pulse so the two do not fight: the breath is a loop,
                // the level is a spring that chases whatever the microphone just heard.
                .scaleEffect(levelScale)
                .animation(.spring(response: 0.25, dampingFraction: 0.6), value: level)
        }
        .frame(width: 160, height: 160)
        .onAppear { animating = true }
        .accessibilityElement()
        .accessibilityLabel("Recording")
    }
}

/// The HUD's translucent squiggle, shown while the engine is still working.
///
/// The Mac draws seven bouncing EQ bars; on a phone-sized screen a single travelling wave
/// reads better at the same weight, so this is one sine path scrolling under a taper.
struct TranscribingSquiggle: View {
    @State private var phase: CGFloat = 0

    var body: some View {
        SineWave(phase: phase)
            .stroke(
                Color.secondary.opacity(0.6),
                style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round)
            )
            .frame(width: 180, height: 48)
            .onAppear {
                withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) {
                    phase = 2 * .pi
                }
            }
            .accessibilityElement()
            .accessibilityLabel("Transcribing")
    }
}

/// A sine wave whose horizontal phase is animatable, tapered to zero at both ends so it fades
/// into the background instead of stopping dead at the edge of its frame.
struct SineWave: Shape {
    var phase: CGFloat
    /// How many full waves fit across the frame.
    var cycles: CGFloat = 2.5

    var animatableData: CGFloat {
        get { phase }
        set { phase = newValue }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        // Enough segments that the curve is smooth at this size without costing a redraw.
        let steps = 72
        let amplitude = rect.height / 2 - 3

        for step in 0...steps {
            let t = CGFloat(step) / CGFloat(steps)
            let taper = sin(.pi * t)
            let y = rect.midY + sin(cycles * 2 * .pi * t - phase) * amplitude * taper
            let point = CGPoint(x: rect.minX + rect.width * t, y: y)
            if step == 0 {
                path.move(to: point)
            } else {
                path.addLine(to: point)
            }
        }
        return path
    }
}
