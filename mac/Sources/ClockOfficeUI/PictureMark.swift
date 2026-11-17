import SwiftUI

/// A session's mark drawn from a private look's pictures (`mark.png` and a sheet of it turning, `spin.png`)
/// instead of the built-in dial. Its motion is the status: turning = working, still with a soft shine in the
/// accent colour = a question for you, still and faded = done, still under a red shine = stopped by the plan's
/// limit until it resets.
struct PictureMark: View {
    typealias Mode = DialView.Mode
    let mode: Mode
    let size: CGFloat
    /// Fixes the animation at one moment (for widgets, which cannot animate, and for test renders).
    let frozenAt: Double?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dialsPaused) private var paused

    init(_ mode: Mode, size: CGFloat = 44, frozenAt: Double? = nil) {
        self.mode = mode; self.size = size; self.frozenAt = frozenAt
    }

    var body: some View {
        Group {
            if let t = frozenAt ?? (reduceMotion ? 0.8 : nil) {
                frame(at: t)
            } else if mode == .turning || mode == .asking || mode == .blocked {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: paused)) { ctx in
                    frame(at: ctx.date.timeIntervalSinceReferenceDate)
                }
            } else {
                frame(at: 0)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    @ViewBuilder private func frame(at t: Double) -> some View {
        ZStack {
            if mode == .asking { halo(at: t) }
            if mode == .blocked { halo(at: t, core: Theme.limitCore, edge: Theme.limitEdge) }
            picture(at: t)
            if mode == .turning && frozenAt == nil && !reduceMotion { twinkles(at: t) }
        }
    }

    /// While it turns, the mark catches the light now and then: small sparkles that swell and fade at a few fixed
    /// spots, never two at their brightest together. Only on a working mark, so sparkle still means "busy".
    private func twinkles(at t: Double) -> some View {
        // x, y on the mark (0…1), size as a share of it, how often, and when in the cycle.
        let spots: [(x: CGFloat, y: CGFloat, s: CGFloat, period: Double, phase: Double)] = [
            (0.74, 0.22, 0.30, 2.6, 0.0), (0.20, 0.38, 0.20, 3.4, 1.1), (0.60, 0.78, 0.24, 4.2, 2.3),
        ]
        return ZStack {
            ForEach(0..<spots.count, id: \.self) { i in
                let spot = spots[i]
                // Bright for 0.7 s of each period, dark for the rest.
                let local = (t + spot.phase).truncatingRemainder(dividingBy: spot.period) / 0.7
                let pulse = local < 1 ? sin(local * .pi) : 0
                Sparkle().fill(Color.white)
                    .frame(width: size * spot.s, height: size * spot.s)
                    .scaleEffect(0.4 + 0.6 * pulse)
                    .opacity(pulse)
                    .position(x: size * spot.x, y: size * spot.y)
            }
        }
        .frame(width: size, height: size)
    }

    @ViewBuilder private func picture(at t: Double) -> some View {
        let image: CGImage? = {
            if mode == .turning, !Assets.spin.isEmpty {
                // 30 frames a second, 108 frames: the loop the mock used.
                return Assets.spin[Int((t * 30).rounded(.down)).quotientAndRemainder(dividingBy: Assets.spin.count).remainder]
            }
            return Assets.mark
        }()
        if let image {
            Image(decorative: image, scale: 1)
                .resizable()
                .interpolation(.high)
                .frame(width: size * 1.1, height: size * 1.1) // the artwork's soft rim is cropped, as in the mock
                .frame(width: size, height: size)
                .clipShape(Circle())
                .saturation(mode == .faded ? 0 : 1)
                .brightness(mode == .faded ? 0.05 : 0)
                // On a light panel a half-faded grey mark all but disappears.
                .opacity(mode == .faded ? (scheme == .light ? 0.8 : 0.5) : 1)
        } else {
            Circle().fill(Color.gray.opacity(0.3))
        }
    }

    /// A soft blurred shine in the accent colour hugging the edge, slowly brightening and dimming (3.2 s). No line, no bounce.
    private func halo(at t: Double, core: Color = Theme.haloCore, edge: Color = Theme.haloEdge) -> some View {
        let phase = 0.5 - 0.5 * cos(2 * .pi * t / 3.2) // 0…1, eased at both ends
        let d = size + 16
        return Circle()
            .fill(RadialGradient(stops: [
                .init(color: core.opacity(0), location: 0.62),
                .init(color: core.opacity(0.75), location: 0.74),
                .init(color: edge.opacity(0.35), location: 0.86),
                .init(color: edge.opacity(0), location: 1.0),
            ], center: .center, startRadius: 0, endRadius: d / 2))
            .frame(width: d, height: d)
            .blur(radius: 3)
            .opacity(0.5 + 0.5 * phase)
            .scaleEffect(0.98 + 0.05 * phase)
    }
}
