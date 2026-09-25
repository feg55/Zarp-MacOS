import SwiftUI
import ZarpCore

/// Collapsible log panel at the bottom of the main window — matches Windows Zarp's `_log`
/// TextBox (`UI/MainForm.cs`): monospace, dim text, dark panel background, newest line at the
/// bottom, auto-scrolled.
///
/// UNVERIFIED: not rendered on a real display (see `Theme.swift`'s note).
struct LogView: View {
    let lines: [LogEntry]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(lines) { entry in
                        Text(entry.formatted)
                            .font(Theme.monospaced(10.5))
                            .foregroundColor(Theme.textDim)
                            .textSelection(.enabled)
                            .id(entry.id)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Theme.panel)
            .onChange(of: lines.count) { _, _ in
                if let last = lines.last?.id {
                    withAnimation(.none) { proxy.scrollTo(last, anchor: .bottom) }
                }
            }
        }
    }
}
