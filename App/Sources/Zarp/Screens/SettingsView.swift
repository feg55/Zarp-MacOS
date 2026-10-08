import AppKit
import SwiftUI
import ZarpCore
import ZarpdIPC

/// Settings window: strategies table on top, the zarpd daemon's status, and options below — the
/// same sections as Windows Zarp's `SettingsForm` (`UI/SettingsForm.cs`) plus the daemon panel.
/// 880 pt wide at minimum: the six strategy columns need about 825 pt with their cell padding, and
/// anything narrower pushes "Connect, ms" and "Ping, ms" out of sight behind a horizontal scroll bar.
struct SettingsView: View {
    @ObservedObject var vm: AppViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                StrategiesView(vm: vm)

                Divider().overlay(Theme.border)

                daemonSection

                Divider().overlay(Theme.border)

                optionsSection
            }
            .padding(.bottom, 20)
        }
        .background(Theme.back)
        .frame(minWidth: 880, minHeight: 700)
        .onAppear {
            vm.refreshDaemonState()
            vm.refreshAutostart()
        }
    }

    // MARK: - zarpd daemon

    private var daemonSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(vm.localization.string("daemon.title"))
                .font(Theme.font(15, weight: .bold))
                .foregroundColor(Theme.text)

            HStack(spacing: 10) {
                Circle().fill(daemonStatusColor).frame(width: 9, height: 9)
                Text(daemonStatusText)
                    .font(Theme.font(12.5))
                    .foregroundColor(Theme.text)
                Spacer()
                daemonActionButtons
            }

            Text(daemonPingText)
                .font(Theme.font(11.5))
                .foregroundColor(Theme.textDim)

            if vm.daemonStale, let ping = vm.daemonPing {
                Text(vm.localization.string("daemon.stale", [ping.version, AppViewModel.appVersion]))
                    .font(Theme.font(11))
                    .foregroundColor(Theme.busy)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let err = vm.daemonActionError {
                Text(err)
                    .font(Theme.font(11))
                    .foregroundColor(Theme.bad)
            }
        }
        .padding(.horizontal, 20)
    }

    @ViewBuilder
    private var daemonActionButtons: some View {
        switch vm.daemonState {
        case .notInstalled, .notFound, .unknown:
            actionButton(vm.localization.string("daemon.install")) { vm.installDaemon() }
        case .requiresApproval:
            actionButton(vm.localization.string("daemon.openSettings")) { vm.openDaemonApprovalSettings() }
        case .enabled:
            actionButton(vm.localization.string("daemon.restart")) { Task { await vm.restartDaemon() } }
            actionButton(vm.localization.string("daemon.uninstall")) { vm.uninstallDaemon() }
        }
        actionButton(vm.localization.string("daemon.refresh")) {
            vm.refreshDaemonState()
            Task { await vm.pingDaemon() }
        }
    }

    private var daemonStatusColor: Color {
        switch vm.daemonState {
        case .enabled: return (vm.daemonPing != nil) ? Theme.accent : Theme.busy
        case .requiresApproval: return Theme.busy
        case .notInstalled, .notFound, .unknown: return Theme.bad
        }
    }

    private var daemonStatusText: String {
        switch vm.daemonState {
        case .notInstalled: return vm.localization.string("daemon.notInstalled")
        case .requiresApproval: return vm.localization.string("daemon.requiresApproval")
        case .enabled: return vm.localization.string("daemon.enabled")
        case .notFound: return vm.localization.string("daemon.notFound")
        case .unknown(let raw): return vm.localization.string("daemon.unknown", [raw])
        }
    }

    private var daemonPingText: String {
        if let ping = vm.daemonPing {
            return vm.localization.string("daemon.respondingYes", [ping.version, String(ping.pid)])
        }
        if let err = vm.daemonPingError {
            return vm.localization.string("daemon.respondingNo", [err])
        }
        return vm.localization.string("daemon.respondingUnknown")
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
                                     isOn: Binding(get: { vm.autostartEnabled },
                                                    set: { vm.setAutostart($0) }))

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
                    ToggleSwitchView(title: vm.localization.string("opt.routeAll"),
                                     isOn: Binding(get: { vm.settings.routeAllTraffic },
                                                    set: { v in vm.updateSettings { $0.routeAllTraffic = v } }))
                        .help(vm.localization.string("opt.routeAllTip"))
                    ToggleSwitchView(title: vm.localization.string("opt.overrideDNS"),
                                     isOn: Binding(get: { vm.settings.overrideDNS && vm.settings.routeAllTraffic },
                                                    set: { v in vm.updateSettings { $0.overrideDNS = v } }),
                                     isEnabled: vm.settings.routeAllTraffic)
                    ToggleSwitchView(title: vm.localization.string("opt.reconnect"),
                                     isOn: Binding(get: { vm.settings.reconnectOnLoss },
                                                    set: { v in vm.updateSettings { $0.reconnectOnLoss = v } }))
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
                        actionButton(vm.localization.string("btn.licenses")) { vm.revealLicenses() }
                    }

                    Text("Zarp \(appVersion)")
                        .font(Theme.font(11))
                        .foregroundColor(Theme.textDim)
                }
                .frame(maxWidth: 280, alignment: .leading)

                Spacer(minLength: 0)
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

    // MARK: - Actions

    private func openDataFolder() {
        NSWorkspace.shared.activateFileViewerSelecting([AppViewModel.dataDirectory()])
    }

    private var appVersion: String { AppViewModel.appVersion }
}
