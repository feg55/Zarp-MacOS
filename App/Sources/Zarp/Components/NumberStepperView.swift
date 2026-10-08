import SwiftUI

/// "− value +" field instead of a system stepper, matching Windows Zarp's `NumberBox`
/// (`UI/Controls.cs`).
struct NumberStepperView: View {
    @Binding var value: Int
    let range: ClosedRange<Int>

    var body: some View {
        HStack(spacing: 0) {
            stepButton("−", enabled: value > range.lowerBound) { value = max(range.lowerBound, value - 1) }
            Text("\(value)")
                .font(Theme.font(12.5))
                .foregroundColor(Theme.text)
                .frame(minWidth: 36)
            stepButton("+", enabled: value < range.upperBound) { value = min(range.upperBound, value + 1) }
        }
        .padding(.horizontal, 2)
        .frame(height: 32)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border, lineWidth: 1))
    }

    private func stepButton(_ symbol: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(symbol)
                .font(Theme.font(13, weight: .medium))
                .foregroundColor(enabled ? Theme.text : Theme.textDisabled)
                .frame(width: 28, height: 28)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}
