import AppKit
import ServiceManagement
import SwiftUI

@main
struct OpenIBKRApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra("OpenIBKR", systemImage: "chart.line.uptrend.xyaxis") {
            Button("Show/Hide Floating Window") { appDelegate.togglePanel() }
            Button("Reconnect") { appDelegate.model.reconnect() }
            Divider()
            Button("Quit OpenIBKR") { NSApp.terminate(nil) }
        }
        Settings {
            SettingsView(model: appDelegate.model)
                .frame(width: 440, height: 320)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    private var panelController: FloatingPanelController?
    private let helperManager = HelperProcessManager()
    private var helperStartTask: Task<Void, Never>?
    private var helperRestartAttempts = 0
    private var instanceLock: SingleInstanceLock?
    private var mayLaunch = true
    private var isUnitTesting: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }
    private var isPreviewing: Bool {
        ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1"
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        guard !isUnitTesting, !isPreviewing else { return }
        do {
            instanceLock = try SingleInstanceLock()
        } catch {
            mayLaunch = false
            NSRunningApplication.runningApplications(
                withBundleIdentifier: Bundle.main.bundleIdentifier ?? "com.openibkr.OpenIBKR"
            ).first(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier })?
                .activate(options: [.activateAllWindows])
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !isUnitTesting, !isPreviewing else { return }
        guard mayLaunch else {
            NSApp.terminate(nil)
            return
        }
        panelController = FloatingPanelController(model: model)
        panelController?.show()
        if HelperEndpoint.fromEnvironment() != nil {
            model.start()
        } else {
            startManagedHelper()
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(systemWillSleep),
            name: NSWorkspace.willSleepNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(systemDidWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.stop()
        helperStartTask?.cancel()
        helperManager.stopSynchronously()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    func togglePanel() {
        panelController?.toggleVisibility()
    }

    @objc private func systemWillSleep() {
        model.prepareForSleep()
    }

    @objc private func systemDidWake() {
        model.reconnect()
    }

    private func startManagedHelper() {
        model.beginHelperStartup()
        helperManager.onUnexpectedExit = { [weak self] error in
            self?.scheduleManagedHelperRestart(after: error)
        }
        helperStartTask = Task { [weak self] in
            guard let self else { return }
            do {
                let defaults = UserDefaults.standard
                let environment = ProcessInfo.processInfo.environment
                let port = Int(environment["OPENIBKR_MANAGED_GATEWAY_PORT"] ?? "")
                    ?? (defaults.object(forKey: "gatewayPort") as? Int ?? 4003)
                let adapter = environment["OPENIBKR_MANAGED_ADAPTER"]
                    ?? defaults.string(forKey: "helperAdapter")
                    ?? "ibkr"
                let endpoint = try await helperManager.start(adapter: adapter, gatewayPort: port)
                helperRestartAttempts = 0
                model.configure(endpoint: endpoint)
            } catch {
                scheduleManagedHelperRestart(after: error)
            }
        }
    }

    private func scheduleManagedHelperRestart(after error: Error) {
        model.reportRuntimeError(error)
        guard helperRestartAttempts < 3 else { return }
        helperRestartAttempts += 1
        let delay = helperRestartAttempts
        helperStartTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.startManagedHelper()
        }
    }
}

private struct SettingsView: View {
    @ObservedObject var model: AppModel
    @AppStorage("gatewayPort") private var gatewayPort = 4003
    @AppStorage("helperAdapter") private var helperAdapter = "ibkr"
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var launchAtLoginError: String?

    var body: some View {
        Form {
            LabeledContent("Helper") {
                Text(model.endpointDescription)
                    .foregroundStyle(.secondary)
            }
            LabeledContent("Connection") {
                Text(model.snapshot.connection.state.displayName)
            }
            Picker("Data Source", selection: $helperAdapter) {
                Text("IB Gateway (Read-Only)").tag("ibkr")
                Text("Fake (Development)").tag("fake")
            }
            TextField("Gateway Port", value: $gatewayPort, format: .number.grouping(.never))
            Toggle("Launch OpenIBKR at Login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, enabled in
                    do {
                        if enabled {
                            try SMAppService.mainApp.register()
                        } else {
                            try SMAppService.mainApp.unregister()
                        }
                        launchAtLoginError = nil
                    } catch {
                        launchAtLoginError = error.localizedDescription
                        launchAtLogin = SMAppService.mainApp.status == .enabled
                    }
                }
            if let launchAtLoginError {
                Text(launchAtLoginError).font(.caption).foregroundStyle(.orange)
            }
            Text("Restart the app after changing the data source or port. The one-time token exists only in memory for the current process and is never written to disk.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
    }
}
