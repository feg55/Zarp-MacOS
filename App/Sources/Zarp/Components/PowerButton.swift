import SwiftUI

/// Large circular power button with a status ring and a busy-spin animation. Port of Windows
/// Zarp's `PowerButton` (`UI/PowerButton.cs`), which draws the same three states with GDI+; this
/// draws them with SwiftUI `Canvas`, at the same proportions (ring width, glow, icon size as a
/// fraction of the control size) so both look the same at any size, including the 200×200pt the
/// Windows main window uses.
///
/// UNVERIFIED: not rendered on a real display (see `Theme.swift`'s note).
struct PowerButton: View {
    enum Look { case off, busy, on }

    let look: Look
    let action: () -> Void

    @State private var angle: Double = 0
    @State private var isHovering = false
    @State private var isPressed = false

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
        .frame(width: 200, height: 200)
        .contentShape(Circle())
        .onHover { isHovering = $0 }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in isPressed = true }
                .onEnded { _ in
                    isPressed = false
                    action()
                }
        )
        .onAppear { startSpinIfNeeded() }
        .onChange(of: isBusy) { _, _ in startSpinIfNeeded() } // macOS 14+ two-param onChange
        .accessibilityAddTraits(.isButton)
    }

    private var isBusy: Bool { if case .busy = look { return true }; return false }

    private func startSpinIfNeeded() {
        guard isBusy else { return }
        withAnimation(.linear(duration: 1.1).repeatForever(autoreverses: false)) {
            angle += 360
        }
    }
}
