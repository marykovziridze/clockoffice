import SwiftUI

/// The dial. Its ring colour and its motion are the status:
/// yellow ring with the hand going round = working, orange ring with a soft shine that breathes = needs you
/// (a question or a permission prompt), green ring and still = finished, red ring and still = stopped by the
/// plan's usage limit until it resets.
/// Drawn in code from the Clockwork dial's proportions (30 ticks, 5 batons, one hand, one hub), so it is sharp at
/// every size.
public struct DialView: View {
    public enum Mode: Sendable { case turning, asking, faded, still, blocked }
    let mode: Mode
    let size: CGFloat
    /// Fixes the animation at one moment (for widgets, which cannot animate, and for test renders).
    let frozenAt: Double?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dialsPaused) private var paused

    public init(_ mode: Mode, size: CGFloat = 44, frozenAt: Double? = nil) {
        self.mode = mode; self.size = size; self.frozenAt = frozenAt
    }

    /// The state colours. Orange is the only one that asks for you.
    public enum Palette {
        public static let working = Color(red: 242 / 255, green: 183 / 255, blue: 5 / 255)
        public static let needsYou = Color(red: 242 / 255, green: 122 / 255, blue: 26 / 255)
        public static let ready = Color(red: 46 / 255, green: 158 / 255, blue: 91 / 255)
        /// Red, for one thing only: the plan's limit is used up.
        public static let limit = Color(red: 217 / 255, green: 45 / 255, blue: 32 / 255)
        static let ink = Color(red: 17 / 255, green: 18 / 255, blue: 20 / 255)
        static let tick = Color(red: 180 / 255, green: 184 / 255, blue: 189 / 255)
    }

    /// Where the hand rests, as on the Clockwork dial.
    static let rest = 66.0
    /// One turn of the hand while working, in seconds.
    static let turn = 3.6

    private var ring: Color {
        switch mode {
        case .turning, .still: return Palette.working
        case .asking: return Palette.needsYou
        case .faded: return Palette.ready
        case .blocked: return Palette.limit
        }
    }

    /// The hand takes the state's colour, except while working: yellow on a white face is too faint to follow.
    private var hand: Color {
        switch mode {
        case .turning, .still: return Palette.ink
        case .asking: return Palette.needsYou
        case .faded: return Palette.ready
        case .blocked: return Palette.limit
        }
    }

    public var body: some View {
        // A build with a private look draws its own picture; everything around the mark is the same.
        if Assets.mark != nil {
            PictureMark(mode, size: size, frozenAt: frozenAt)
        } else {
            dial
        }
    }

    private var dial: some View {
        Group {
            if let t = frozenAt ?? (reduceMotion ? 0.8 : nil) {
                frame(at: t)
            } else if mode == .turning || mode == .asking {
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

    private func frame(at t: Double) -> some View {
        ZStack {
            if mode == .asking { shine(at: t) }
            face(angle: mode == .turning && frozenAt == nil && !reduceMotion
                 ? Self.rest + t.truncatingRemainder(dividingBy: Self.turn) / Self.turn * 360
                 : Self.rest)
        }
    }

    private func face(angle: Double) -> some View {
        let ring = ring, hand = hand
        let coloured = mode == .asking || mode == .faded || mode == .blocked
        return Canvas { ctx, box in
            let c = CGPoint(x: box.width / 2, y: box.height / 2)
            let outer = min(box.width, box.height) / 2
            let white = outer * 0.80          // the face inside the ring
            let k = white * 0.86 / 400        // the Clockwork icon's units (outer tick radius 400) to points
            ctx.fill(Path(ellipseIn: CGRect(x: c.x - outer, y: c.y - outer, width: outer * 2, height: outer * 2)),
                     with: .color(ring))
            ctx.fill(Path(ellipseIn: CGRect(x: c.x - white, y: c.y - white, width: white * 2, height: white * 2)),
                     with: .color(.white))
            // A straight bar along a radius, from r0 to r1 from the centre, at `degrees` clockwise from 12 o'clock.
            func bar(_ r0: CGFloat, _ r1: CGFloat, _ width: CGFloat, _ degrees: Double, _ colour: Color) {
                var g = ctx
                g.translateBy(x: c.x, y: c.y)
                g.rotate(by: .degrees(degrees))
                g.fill(Path(CGRect(x: -width / 2, y: -r1, width: width, height: r1 - r0)), with: .color(colour))
            }
            for degrees in stride(from: 0, to: 360, by: 12) {
                if degrees % 72 == 0 {
                    bar(280 * k, 400 * k, 42 * k, Double(degrees), Palette.ink)
                } else {
                    bar(356 * k, 400 * k, 15 * k, Double(degrees), Palette.tick)
                }
            }
            bar(-75 * k, 250 * k, (coloured ? 46 : 32) * k, angle, hand)
            let hub = (coloured ? 52 : 42) * k
            ctx.fill(Path(ellipseIn: CGRect(x: c.x - hub, y: c.y - hub, width: hub * 2, height: hub * 2)),
                     with: .color(hand))
        }
        .frame(width: size, height: size)
    }

    /// A soft shine around the ring that slowly brightens and dims (3.2 s). It is the only thing that pulses,
    /// so a moving shine always means: your turn. A gradient, not a blur: it is brightest where it meets the ring
    /// and gone at its own edge, and it looks the same on screen, in a widget and in a render.
    private func shine(at t: Double) -> some View {
        let phase = 0.5 - 0.5 * cos(2 * .pi * t / 3.2) // 0…1, eased at both ends
        let reach = max(7, size * 0.24)                 // how far the shine reaches beyond the ring
        let d = size + reach * 2
        let edge = size / d                             // where the ring ends, as a share of the shine's radius
        return Circle()
            .fill(RadialGradient(stops: [
                .init(color: Palette.needsYou.opacity(0), location: max(0, edge - 0.10)),
                .init(color: Palette.needsYou.opacity(0.70), location: edge),
                .init(color: Palette.needsYou.opacity(0.26), location: edge + (1 - edge) * 0.42),
                .init(color: Palette.needsYou.opacity(0), location: 1.0),
            ], center: .center, startRadius: 0, endRadius: d / 2))
            .frame(width: d, height: d)
            .opacity(0.30 + 0.70 * phase)
            .scaleEffect(0.98 + 0.04 * phase)
    }
}

/// A four-point sparkle. The dial does not sparkle, so with the built-in look it draws nothing; a private look's
/// picture does (hover, answer sent, the widget's working row), and the views that place it are the same for both.
public struct Sparkle: Shape {
    public init() {}
    public func path(in r: CGRect) -> Path {
        guard Assets.mark != nil else { return Path() }
        var p = Path()
        let c = CGPoint(x: r.midX, y: r.midY), w = r.width / 2, h = r.height / 2, k: CGFloat = 0.14
        p.move(to: CGPoint(x: c.x, y: c.y - h))
        p.addQuadCurve(to: CGPoint(x: c.x + w, y: c.y), control: CGPoint(x: c.x + w * k, y: c.y - h * k))
        p.addQuadCurve(to: CGPoint(x: c.x, y: c.y + h), control: CGPoint(x: c.x + w * k, y: c.y + h * k))
        p.addQuadCurve(to: CGPoint(x: c.x - w, y: c.y), control: CGPoint(x: c.x - w * k, y: c.y + h * k))
        p.addQuadCurve(to: CGPoint(x: c.x, y: c.y - h), control: CGPoint(x: c.x - w * k, y: c.y - h * k))
        return p
    }
}

private struct DialsPausedKey: EnvironmentKey { static let defaultValue = false }
public extension EnvironmentValues {
    /// Set where a surface is not visible (a covered or minimised window): every dial in it stops its clock.
    var dialsPaused: Bool {
        get { self[DialsPausedKey.self] }
        set { self[DialsPausedKey.self] = newValue }
    }
}
