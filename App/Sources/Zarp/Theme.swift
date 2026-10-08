import SwiftUI

/// Dark theme, ported color-for-color from Windows Zarp's `Theme.cs` (`UI/Theme.cs`) so the two
/// apps read as the same product. sRGB values, same as the Windows `Color.FromArgb` constants.
enum Theme {
    static let back = Color(red: 18 / 255, green: 20 / 255, blue: 25 / 255)
    static let panel = Color(red: 27 / 255, green: 30 / 255, blue: 37 / 255)
    static let panelHover = Color(red: 37 / 255, green: 41 / 255, blue: 50 / 255)
    static let border = Color(red: 46 / 255, green: 50 / 255, blue: 60 / 255)
    static let borderHover = Color(red: 64 / 255, green: 69 / 255, blue: 81 / 255)
    /// Not pure white — on a dark background that reads too harsh (Windows Zarp's own comment).
    static let text = Color(red: 196 / 255, green: 200 / 255, blue: 208 / 255)
    static let textDim = Color(red: 128 / 255, green: 134 / 255, blue: 146 / 255)
    static let textDisabled = Color(red: 78 / 255, green: 83 / 255, blue: 94 / 255)
    /// Dark text/knob color for content drawn on top of `accent`.
    static let onAccent = Color(red: 30 / 255, green: 20 / 255, blue: 12 / 255)
    static let onAccentKnob = Color(red: 250 / 255, green: 246 / 255, blue: 242 / 255)
    /// Cloudflare orange.
    static let accent = Color(red: 244 / 255, green: 129 / 255, blue: 32 / 255)
    static let busy = Color(red: 80 / 255, green: 150 / 255, blue: 255 / 255)
    static let ok = Color(red: 64 / 255, green: 196 / 255, blue: 120 / 255)
    static let bad = Color(red: 232 / 255, green: 84 / 255, blue: 84 / 255)
    static let off = Color(red: 70 / 255, green: 75 / 255, blue: 88 / 255)

    // MARK: - Type

    static func font(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }

    static func monospaced(_ size: CGFloat) -> Font {
        .system(size: size, weight: .regular, design: .monospaced)
    }
}
