import SwiftUI

/// Large circular power button with a status ring and a busy-spin animation. Port of Windows
/// Zarp's `PowerButton` (`UI/PowerButton.cs`), which draws the same three states with GDI+; this
/// draws them with SwiftUI `Canvas`, at the same proportions (ring width, glow, icon size as a
/// fraction of the control size) so both look the same at any size, including the 200×200pt the
/// Windows main window uses.
///
/// The spinner is driven by a `TimelineView` that is *paused* whenever the button isn't busy. (A
/// `repeatForever` animation on a `@State` angle never stops once started: the canvas kept being
/// redrawn 60 times a second for as long as the app ran, long after the last scan.)
struct PowerButton: View {
    enum Look { case off, busy, on }

    let look: Look
    let action: () -> Void

    @State private var isHovering = false
    @State private var isPressed = false

    private static let size: CGFloat = 200
    /// One full turn of the busy arc, in seconds.
    private static let spinPeriod: Double = 1.1

    private var ringColor: Color {
        switch look {
        case .on: return Theme.accent
        case .busy: return Theme.busy
        case .off: return Theme.off
        }
    }

    private var iconColor: Color {
        switch look {
        case .on: return Theme.accent
        case .busy: return Theme.busy
        case .off: return Theme.textDim
        }
    }

    var body: some View {
        TimelineView(.animation(paused: !isBusy)) { timeline in
            canvas(angle: spinAngle(at: timeline.date))
        }
        .frame(width: Self.size, height: Self.size)
        .contentShape(Circle())
        .onHover { isHovering = $0 }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in isPressed = true }
                .onEnded { value in
                    isPressed = false
                    // Like a real button: releasing the pointer outside the circle cancels the
                    // press instead of firing it.
                    if Self.contains(value.location) { action() }
                }
        )
        .accessibilityAddTraits(.isButton)
        // The DragGesture above only responds to real pointer events, so VoiceOver's "activate"
        // and any AXPress-based automation (Accessibility Inspector, UI tests) would otherwise
        // silently do nothing despite `.isButton` making this look activatable — this is what
        // actually wires that up, same as a plain `Button` gets for free.
        .accessibilityAction(.default) { action() }
    }

    /// Whether a point in the view's own coordinates is inside the button's circle.
    static func contains(_ point: CGPoint) -> Bool {
        let center = size / 2
        return hypot(point.x - center, point.y - center) <= center
    }

    private func spinAngle(at date: Date) -> Double {
        let phase = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: Self.spinPeriod) / Self.spinPeriod
        return phase * 360
    }

    private func canvas(angle: Double) -> some View {
        Canvas { context, size in
            let side = min(size.width, size.height) - 8
            let rect = CGRect(x: (size.width - side) / 2, y: (size.height - side) / 2, width: side, height: side)
            let ring = side * 0.055

            if case .on = look {
                for i in stride(from: 6, through: 1, by: -1) {
                    let inset = -ring + CGFloat(i) * 1.5
                    let glowRect = rect.insetBy(dx: inset, dy: inset)
                    context.stroke(Path(ellipseIn: glowRect), with: .color(Theme.accent.opacity(0.055 * Double(i))), lineWidth: CGFloat(i) * 2)
                }
            }

            let ringRect = rect.insetBy(dx: ring / 2, dy: ring / 2)
            let ringOpacity: Double = { if case .busy = look { return 60.0 / 255.0 }; return 1 }()
            context.stroke(Path(ellipseIn: ringRect), with: .color(ringColor.opacity(ringOpacity)), lineWidth: ring)
            if case .busy = look {
                var arc = Path()
                arc.addArc(center: CGPoint(x: ringRect.midX, y: ringRect.midY), radius: ringRect.width / 2,
                           startAngle: .degrees(angle), endAngle: .degrees(angle + 90), clockwise: false)
                context.stroke(arc, with: .color(Theme.busy), style: StrokeStyle(lineWidth: ring, lineCap: .round))
            }

            let discRect = rect.insetBy(dx: ring * 2.2, dy: ring * 2.2)
            let discColor: Color = isPressed ? Theme.border : (isHovering ? Theme.panelHover : Theme.panel)
            context.fill(Path(ellipseIn: discRect), with: .color(discColor))

            let iconSize = discRect.width * 0.36
            let iconRect = CGRect(x: discRect.midX - iconSize / 2, y: discRect.midY - iconSize / 2 + iconSize * 0.04,
                                   width: iconSize, height: iconSize)
            var powerArc = Path()
            powerArc.addArc(center: CGPoint(x: iconRect.midX, y: iconRect.midY), radius: iconRect.width / 2,
                             startAngle: .degrees(-60), endAngle: .degrees(240), clockwise: false)
            context.stroke(powerArc, with: .color(iconColor), style: StrokeStyle(lineWidth: iconSize * 0.11, lineCap: .round))
            var stem = Path()
            stem.move(to: CGPoint(x: iconRect.midX, y: iconRect.minY - iconSize * 0.12))
            stem.addLine(to: CGPoint(x: iconRect.midX, y: iconRect.minY + iconRect.height * 0.42))
            context.stroke(stem, with: .color(iconColor), style: StrokeStyle(lineWidth: iconSize * 0.11, lineCap: .round))
        }
    }

    private var isBusy: Bool { if case .busy = look { return true }; return false }
}
