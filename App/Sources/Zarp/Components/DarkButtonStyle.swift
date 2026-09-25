import SwiftUI

/// Flat, rounded dark button — matches Windows Zarp's `DarkButton` (`UI/Controls.cs`): panel-color
/// background, accent-color background for the primary action, disabled state fades text and
/// border instead of hiding them.
///
/// UNVERIFIED: not rendered on a real display (see `Theme.swift`'s note).
struct DarkButtonStyle: ButtonStyle {
    var primary: Bool = false
    var isEnabled: Bool = true

    func makeBody(configuration: Configuration) -> some View {
        let bg: Color = {
            if !isEnabled { return Theme.back }
            if primary { return configuration.isPressed ? Theme.accent.opacity(0.85) : Theme.accent }
            return configuration.isPressed ? Theme.border : Theme.panel
        }()
        let fg: Color = !isEnabled ? Theme.textDisabled : (primary ? Theme.onAccent : Theme.text)
        let border: Color = !isEnabled ? Theme.border : (primary ? bg : Theme.border)

        configuration.label
            .font(Theme.font(12))
            .foregroundColor(fg)
            .padding(.horizontal, 14)
            .frame(minWidth: 96, minHeight: 30)
            .background(RoundedRectangle(cornerRadius: 8).fill(bg))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(border, lineWidth: 1))
    }
}

/// Small helper so call sites read like Windows' `Theme.FlatButton(text, primary:)`.
func actionButton(_ title: String, primary: Bool = false, enabled: Bool = true, action: @escaping () -> Void) -> some View {
    Button(action: action) { Text(title) }
        .buttonStyle(DarkButtonStyle(primary: primary, isEnabled: enabled))
        .disabled(!enabled)
}
