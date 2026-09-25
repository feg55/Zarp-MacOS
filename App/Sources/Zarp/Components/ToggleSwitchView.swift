import SwiftUI

/// Track-and-knob switch instead of a system checkbox, matching Windows Zarp's `ToggleSwitch`
/// (`UI/Controls.cs`): the track fills with `Theme.accent` when on, `Theme.off` when off, with a
/// lighter hover tint.
///
/// UNVERIFIED: not rendered on a real display (see `Theme.swift`'s note).
struct ToggleSwitchView: View {
    let title: String
    @Binding var isOn: Bool
    var isEnabled: Bool = true

    @State private var isHovering = false

    private let trackHeight: CGFloat = 18
    private var trackWidth: CGFloat { trackHeight * 1.8 }

    var body: some View {
        Button {
            if isEnabled { isOn.toggle() }
        } label: {
            HStack(spacing: 10) {
                ZStack(alignment: isOn ? .trailing : .leading) {
                    Capsule()
                        .fill(trackColor)
                        .frame(width: trackWidth, height: trackHeight)
                    Circle()
                        .fill(isOn ? Theme.onAccentKnob : Theme.text)
                        .frame(width: trackHeight - 6, height: trackHeight - 6)
                        .padding(3)
                }
                Text(title)
                    .font(Theme.font(12.5))
                    .foregroundColor(isEnabled ? Theme.text : Theme.textDisabled)
                Spacer(minLength: 0)
            }
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .onHover { isHovering = $0 }
        .animation(.easeInOut(duration: 0.12), value: isOn)
    }

    private var trackColor: Color {
        guard isEnabled else { return Theme.border }
        if isOn { return isHovering ? Theme.accent.opacity(0.85) : Theme.accent }
        return isHovering ? Theme.borderHover : Theme.off
    }
}
