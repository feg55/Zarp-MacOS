import AppKit
import SwiftUI
import ZarpCore

/// Settings window: strategies table on top, options below — same two-section layout as Windows
/// Zarp's `SettingsForm` (`UI/SettingsForm.cs`), sized close to its 800×720 default with the same
/// 760×700 minimum.
///
/// UNVERIFIED: not rendered on a real display (see `Theme.swift`'s note).
struct SettingsView: View {
    @ObservedObject var vm: AppViewModel
    /// TODO(real Mac): replace with `SMAppService.mainApp.status == .enabled` read on appear, and
    /// `try SMAppService.mainApp.register()/.unregister()` on toggle — matching Windows
    /// `Autostart.cs` / `SettingsForm`'s async re-check after toggling.
    @State private var autostartEnabled = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                StrategiesView(vm: vm)

                Divider().overlay(Theme.border)

                optionsSection
            }
            .padding(.bottom, 20)
        }
        .background(Theme.back)
        .frame(minWidth: 760, minHeight: 700)
    }

    private var optionsSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(vm.localization.string("settings.options"))
                .font(Theme.font(15, weight: .bold))
                .foregroundColor(Theme.text)

            HStack(alignment: .top, spacing: 32) {
                VStack(alignment: .leading, spacing: 10) {
                    ToggleSwitchView(title: vm.localization.string("opt.autoConnect"),
                                     isOn: Binding(get: { vm.settings.autoConnectOnStart },
                                                    set: { v in vm.updateSettings { $0.autoConnectOnStart = v } }))
                    ToggleSwitchView(title: vm.localization.string("opt.autostart"),
                                     isOn: Binding(get: { autostartEnabled },
                                                    set: { setAutostart($0) }))
                        // TODO(real Mac): back this with SMAppService.mainApp, mirroring Windows
                        // Autostart.cs / SettingsForm's async re-check after toggling.

                    HStack(spacing: 10) {
                        Text(vm.localization.string("opt.onClose"))
                            .font(Theme.font(12.5))
                            .foregroundColor(Theme.text)
                        Picker("", selection: closeActionBinding) {
                            Text(vm.localization.string("opt.closeAsk")).tag(0)
                            Text(vm.localization.string("opt.closeTray")).tag(1)
                            Text(vm.localization.string("opt.closeExit")).tag(2)
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .accessibilityLabel(vm.localization.string("opt.closeAccessible"))
                        .frame(width: 200)
                    }

                    ToggleSwitchView(title: vm.localization.string("opt.disconnectOnExit"),
                                     isOn: Binding(get: { vm.settings.disconnectOnExit },
                                                    set: { v in vm.updateSettings { $0.disconnectOnExit = v } }))
                    ToggleSwitchView(title: vm.localization.string("opt.restrict"),
                                     isOn: Binding(get: { vm.settings.restrictToWarpAddresses },
                                                    set: { v in vm.updateSettings { $0.restrictToWarpAddresses = v } }))
                    ToggleSwitchView(title: vm.localization.string("opt.isolate"),
                                     isOn: Binding(get: { vm.settings.isolateTests },
                                                    set: { v in vm.updateSettings { $0.isolateTests = v } }))
                }
                .frame(maxWidth: 340, alignment: .leading)

                VStack(alignment: .leading, spacing: 14) {
                    labeledStepper(vm.localization.string("opt.timeout"),
                                   value: Binding(get: { vm.settings.testTimeoutSec },
                                                  set: { v in vm.updateSettings { $0.testTimeoutSec = v } }),
                                   range: 5...60)
                    // Localization already turns the file's literal "\n" into a real newline
                    // (Localization.parseTable); flatten it back to a space for this single-line label.
                    labeledStepper(vm.localization.string("opt.stopAfter").replacingOccurrences(of: "\n", with: " "),
                                   value: Binding(get: { vm.settings.stopAfterWorking },
                                                  set: { v in vm.updateSettings { $0.stopAfterWorking = v } }),
                                   range: 1...100)

                    HStack(spacing: 8) {
                        actionButton(vm.localization.string("btn.dataFolder")) { openDataFolder() }
                        actionButton(vm.localization.string("btn.licenses")) { openLicenses() }
                    }

                    Text("Zarp \(appVersion)")
                        .font(Theme.font(11))
                        .foregroundColor(Theme.textDim)
                }
                .frame(maxWidth: 280, alignment: .leading)

                Spacer(minLength: 0)
            }

            if vm.isReady {
                Text(vm.localization.string("mac.notImplemented"))
                    .font(Theme.font(11))
                    .foregroundColor(Theme.bad)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Theme.panel))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.bad.opacity(0.4), lineWidth: 1))
            }
        }
        .padding(.horizontal, 20)
    }

    private func labeledStepper(_ title: String, value: Binding<Int>, range: ClosedRange<Int>) -> some View {
        HStack(spacing: 10) {
            Text(title)
                .font(Theme.font(12.5))
                .foregroundColor(Theme.text)
                .frame(maxWidth: 170, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            NumberStepperView(value: value, range: range)
        }
    }

    private var closeActionBinding: Binding<Int> {
        Binding(
            get: {
                if vm.settings.askBeforeClose { return 0 }
                return vm.settings.minimizeToMenuBar ? 1 : 2
            },
            set: { newValue in
                vm.updateSettings { s in
                    s.askBeforeClose = newValue == 0
                    if !s.askBeforeClose { s.minimizeToMenuBar = newValue == 1 }
                }
            }
        )
    }

    // MARK: - Actions with a real, if unverified, platform implementation

    private func setAutostart(_ enabled: Bool) {
        autostartEnabled = enabled
    }

    private func openDataFolder() {
        NSWorkspace.shared.activateFileViewerSelecting([dataDirectory()])
    }

    private func openLicenses() {
        // TODO(real Mac): write THIRD_PARTY_NOTICES equivalent into the data folder like Windows
        // Zarp's Licenses.Extract, then reveal it. For now just opens the data folder.
        openDataFolder()
    }

    private func dataDirectory() -> URL {
        (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))?
            .appendingPathComponent("Zarp", isDirectory: true)
            ?? FileManager.default.temporaryDirectory
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }
}
