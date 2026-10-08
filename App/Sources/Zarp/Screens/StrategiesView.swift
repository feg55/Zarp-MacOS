import SwiftUI
import ZarpCore

/// One table row: a `Strategy` plus everything about to be displayed, pre-computed so the
/// `Table` column closures stay pure formatting.
private struct StrategyRow: Identifiable {
    let strategy: Strategy
    let isCurrent: Bool
    let resultText: String
    let resultColor: Color
    let connectText: String
    let pingText: String
    let tooltip: String
    var id: String { strategy.id }
}

/// The Strategies table: `Strategy | Protocol | Result | Connect, ms | Ping, ms`, with a narrow
/// leading column marking the saved strategy. Visual source of truth: Windows Zarp's
/// `SettingsForm` (`UI/SettingsForm.cs`'s column setup and `FillList`) and the attached screenshot
/// of that window — same column order and widths, same ✔ / ✔✔ convention, same row density.
///
/// Backed by real networking through `zarpd`/`ZarpdClient` (docs/ARCHITECTURE.md §5) — rows read
/// "not tested" until a Test/Use/scan runs. Strategies this port cannot perform (raw-socket tricks,
/// WireGuard) read "not available on macOS" with the reason as a tooltip, and are never attempted.
struct StrategiesView: View {
    @ObservedObject var vm: AppViewModel
    @State private var selection = Set<String>()
    @State private var showingCustomStrategiesSheet = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(vm.localization.string("settings.strategy"))
                .font(Theme.font(15, weight: .bold))
                .foregroundColor(Theme.text)
            Text(vm.localization.string("settings.explain"))
                .font(Theme.font(11.5))
                .foregroundColor(Theme.textDim)
                .fixedSize(horizontal: false, vertical: true)

            table

            HStack(spacing: 8) {
                actionButton(vm.localization.string("btn.use"), primary: true,
                             enabled: selection.count == 1 && !vm.isBusy && !selectionIsUnsupported, action: useSelected)
                actionButton(vm.localization.string("btn.testSelected"),
                             enabled: !selection.isEmpty && !vm.isBusy, action: testSelected)
                if vm.isBusy {
                    actionButton(vm.localization.string("btn.cancel")) { vm.cancel() }
                } else {
                    actionButton(vm.localization.string("btn.quickScan")) { vm.quickScan() }
                        .help(vm.localization.string("tip.quickScan", [String(max(1, vm.settings.stopAfterWorking))]))
                    actionButton(vm.localization.string("btn.fullScan")) { vm.fullScan() }
                        .help(vm.localization.string("tip.fullScan", [String(vm.strategies.count)]))
                }
                actionButton(vm.localization.string("btn.custom"), enabled: !vm.isBusy) {
                    showingCustomStrategiesSheet = true
                }
            }

            Text(statusLine)
                .font(Theme.font(11.5))
                .foregroundColor(Theme.textDim)
                .lineLimit(1)
        }
        .padding(20)
        .background(Theme.back)
        .sheet(isPresented: $showingCustomStrategiesSheet) {
            CustomStrategiesSheet(vm: vm, isPresented: $showingCustomStrategiesSheet)
        }
    }

    // MARK: - Table

    private var rows: [StrategyRow] {
        vm.strategies.map { s in
            let result = vm.results[s.id]
            if let reason = s.unsupportedReason {
                // Never attempted, so never a result: say plainly that this port can't do it, and
                // why (tooltip) — instead of a "not tested" that suggests pressing Test would help.
                return StrategyRow(
                    strategy: s,
                    isCurrent: false,
                    resultText: vm.localization.string("result.unavailable"),
                    resultColor: Theme.textDisabled,
                    connectText: "",
                    pingText: "",
                    tooltip: reason.text(using: vm.localization)
                )
            }
            let (text, color) = Self.resultCell(result, using: vm.localization)
            return StrategyRow(
                strategy: s,
                isCurrent: s.id == vm.selectedStrategyId,
                resultText: text,
                resultColor: color,
                connectText: (result?.ok ?? false) ? "\(result!.connectMs)" : "",
                pingText: (result?.ok ?? false) ? "\(result!.pingMs)" : "",
                tooltip: s.requiresDesync ? s.args : vm.localization.string("settings.directTip")
            )
        }
    }

    /// The single selected strategy is one this port can't run (so "Use" would only fail).
    private var selectionIsUnsupported: Bool {
        guard selection.count == 1, let id = selection.first, let s = vm.strategies.first(where: { $0.id == id }) else { return false }
        return s.unsupportedReason != nil
    }

    private var table: some View {
        Table(rows, selection: $selection) {
            TableColumn("") { row in
                Text(row.isCurrent ? "✔" : "")
                    .font(Theme.font(12, weight: .bold))
                    .foregroundColor(Theme.accent)
            }
            .width(26)

            TableColumn(vm.localization.string("col.strategy")) { row in
                Text(row.strategy.name(using: vm.localization))
                    .font(Theme.font(12, weight: row.isCurrent ? .bold : .regular))
                    .foregroundColor(Theme.text)
                    .lineLimit(1)
                    .help(row.tooltip)
            }
            .width(min: 160, ideal: 230)

            TableColumn(vm.localization.string("col.protocol")) { row in
                Text(row.strategy.transport.title)
                    .font(Theme.font(11.5))
                    .foregroundColor(Theme.textDim)
            }
            .width(min: 90, ideal: 108)

            TableColumn(vm.localization.string("col.result")) { row in
                Text(row.resultText)
                    .font(Theme.font(11.5))
                    .foregroundColor(row.resultColor)
                    .lineLimit(1)
            }
            .width(min: 140, ideal: 220)

            TableColumn(vm.localization.string("col.connect")) { row in
                Text(row.connectText)
                    .font(Theme.font(11.5))
                    .foregroundColor(Theme.textDim)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 60, ideal: 76)

            TableColumn(vm.localization.string("col.ping")) { row in
                Text(row.pingText)
                    .font(Theme.font(11.5))
                    .foregroundColor(Theme.textDim)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 54, ideal: 68)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: false))
        .background(Theme.panel)
        .scrollContentBackground(.hidden)
        .frame(minHeight: 260, idealHeight: 320)
    }

    /// Same rule as Windows `SettingsForm.FillList`: not tested (dim) · works ✔✔ (ok, confirmed)
    /// · works (1 check) (busy, unconfirmed) · the error text (bad).
    private static func resultCell(_ result: TestResult?, using loc: Localization) -> (text: String, color: Color) {
        guard let result else { return (loc.string("result.notTested"), Theme.textDim) }
        if result.ok {
            return result.confirmed
                ? (loc.string("result.works2"), Theme.ok)
                : (loc.string("result.works1"), Theme.busy)
        }
        return (result.displayError(using: loc), Theme.bad)
    }

    private var statusLine: String {
        guard vm.isBusy else { return vm.detail.text(using: vm.localization) }
        let progress = vm.progressTotal > 0 ? " [\(vm.progressDone)/\(vm.progressTotal)]" : ""
        return "⏳ " + vm.detail.text(using: vm.localization) + progress
    }

    private func useSelected() {
        guard selection.count == 1, let id = selection.first, let s = vm.strategies.first(where: { $0.id == id }) else { return }
        vm.use(s)
    }

    private func testSelected() {
        let items = vm.strategies.filter { selection.contains($0.id) }
        guard !items.isEmpty else { return }
        vm.testSelected(items)
    }
}

/// Windows Zarp opens `strategies.txt` in Notepad (`SettingsForm.OpenCustomFile`) and reloads the
/// catalog when the user closes it. This sheet is the SwiftUI-native equivalent: an editable text
/// view over the real file — loaded when the sheet opens, written back by Save (which also reloads
/// the strategy list), and left untouched by Cancel. Malformed lines are reported right after saving,
/// so a typo isn't discovered later as a strategy that silently isn't there.
private struct CustomStrategiesSheet: View {
    @ObservedObject var vm: AppViewModel
    @Binding var isPresented: Bool
    @State private var text = ""
    @State private var loaded = false
    @State private var skippedLines: [String] = []
    @State private var saveError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(vm.localization.string("btn.custom"))
                .font(Theme.font(14, weight: .bold))
                .foregroundColor(Theme.text)
            TextEditor(text: $text)
                .font(Theme.monospaced(11.5))
                .foregroundColor(Theme.text)
                .scrollContentBackground(.hidden)
                .background(Theme.panel)
                .frame(minWidth: 520, minHeight: 320)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.border, lineWidth: 1))
                .disabled(!loaded)
            if let saveError {
                Text(saveError)
                    .font(Theme.font(11))
                    .foregroundColor(Theme.bad)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !skippedLines.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text(vm.localization.string("custom.skipped", [String(skippedLines.count)]))
                        .font(Theme.font(11))
                        .foregroundColor(Theme.busy)
                    ForEach(skippedLines, id: \.self) { line in
                        Text(line)
                            .font(Theme.monospaced(10.5))
                            .foregroundColor(Theme.textDim)
                            .lineLimit(1)
                    }
                }
            }
            HStack {
                Spacer()
                actionButton(vm.localization.string("btn.cancel")) { isPresented = false }
                actionButton(vm.localization.string("btn.save"), primary: true, enabled: loaded, action: save)
            }
        }
        .padding(20)
        .background(Theme.back)
        .task {
            guard !loaded else { return }
            text = await vm.customStrategiesText()
            loaded = true
        }
    }

    private func save() {
        Task {
            switch await vm.saveCustomStrategies(text) {
            case .success(let skipped):
                if skipped.isEmpty {
                    isPresented = false
                } else {
                    // Saved, but some lines were not understood: keep the sheet open to show which.
                    skippedLines = skipped
                    saveError = nil
                }
            case .failure(let error):
                saveError = vm.localization.string("custom.saveFailed", [CustomStrategyFile.fileName, error.localizedDescription])
            }
        }
    }
}
