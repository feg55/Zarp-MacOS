import SwiftUI
import ZarpCore

/// "What should closing the window do?" sheet — matches Windows Zarp's `CloseActionForm`
/// (`UI/CloseActionForm.cs`): two buttons (hide to menu bar / exit) plus a "remember my choice"
/// toggle. Shown only while `AppSettings.askBeforeClose` is true; once the user checks "remember",
/// the choice is written straight to `AppSettings.minimizeToMenuBar` and this sheet stops
/// appearing (Windows' exact rule).
///
/// UNVERIFIED: not rendered on a real display (see `Theme.swift`'s note). Also unverified: the
/// wiring that is supposed to *trigger* this sheet. Windows intercepts the titlebar close button
/// via `Form.OnFormClosing`; the AppKit equivalent is an `NSWindow` delegate's
/// `windowShouldClose(_:)`, which SwiftUI's `Window`/`WindowGroup` scenes don't expose directly.
/// `ZarpApp.swift` currently only reaches this sheet from the menu bar's Quit item — hooking the
/// real titlebar close button needs an `NSWindowDelegate` obtained via an `NSViewRepresentable`
/// or similar, on a real Mac, which is out of scope until the app actually runs somewhere.
struct CloseConfirmationView: View {
    let localization: Localization
    let disconnectOnExit: Bool
    let onChoice: (_ minimizeToMenuBar: Bool, _ remember: Bool) -> Void
    let onCancel: () -> Void

    @State private var remember = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(localization.string("close.caption"))
                .font(Theme.font(14, weight: .bold))
                .foregroundColor(Theme.text)
            Text(localization.string("close.question"))
                .font(Theme.font(12.5))
                .foregroundColor(Theme.text)

            VStack(alignment: .leading, spacing: 4) {
                Text(localization.string("close.trayInfo"))
                Text(localization.string(disconnectOnExit ? "close.exitDisconnects" : "close.exitKeeps"))
            }
            .font(Theme.font(11.5))
            .foregroundColor(Theme.textDim)

            Toggle(isOn: $remember) {
                Text(localization.string("close.remember")).font(Theme.font(12)).foregroundColor(Theme.text)
            }
            .toggleStyle(.checkbox)

            Text(localization.string("close.hint"))
                .font(Theme.font(10.5))
                .foregroundColor(Theme.textDim)

            HStack {
                Spacer()
                actionButton(localization.string("close.toTray")) { onChoice(true, remember) }
                actionButton(localization.string("close.exit"), primary: true) { onChoice(false, remember) }
            }
        }
        .padding(20)
        .background(Theme.back)
        .frame(width: 380)
        .onExitCommand(perform: onCancel) // Escape cancels, matches Windows' Escape handling
    }
}
