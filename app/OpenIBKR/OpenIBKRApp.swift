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
            SettingsLink { Text("Settings…") }
            Divider()
            Button("Quit OpenIBKR") { NSApp.terminate(nil) }
        }
        Settings {
            SettingsView(model: appDelegate.model)
                .frame(width: 500, height: 520)
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
    @State private var alpacaKeyID = ""
    @State private var alpacaSecret = ""
    @State private var alpacaSettingsError: String?
    @State private var isSavingAlpaca = false

    var body: some View {
        Form {
            Section("IB Gateway") {
                LabeledContent("Helper") {
                    Text(model.endpointDescription)
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Connection") {
                    Text(model.snapshot.connection.state.displayName)
                }
                Picker("Account Data Source", selection: $helperAdapter) {
                    Text("IB Gateway (Read-Only)").tag("ibkr")
                    Text("Fake (Development)").tag("fake")
                }
                TextField("Gateway Port", value: $gatewayPort, format: .number.grouping(.never))
            }

            Section("Alpaca Overnight Market Data") {
                LabeledContent("Status") {
                    Text(model.snapshot.currentMarketData.displayName)
                        .foregroundStyle(
                            model.snapshot.currentMarketData.error == nil
                                ? Color.secondary
                                : Color.orange
                        )
                }
                if model.hasAlpacaCredentials {
                    Label("Paper API credentials are stored in macOS Keychain", systemImage: "lock.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                TextField(
                    model.hasAlpacaCredentials ? "New API Key ID (leave blank to keep)" : "API Key ID",
                    text: $alpacaKeyID
                )
                SecureField(
                    model.hasAlpacaCredentials ? "New Secret Key (leave blank to keep)" : "Secret Key",
                    text: $alpacaSecret
                )
                HStack {
                    Button("Save & Connect") {
                        saveAlpacaCredentials()
                    }
                    .disabled(
                        isSavingAlpaca || alpacaKeyID.isEmpty || alpacaSecret.isEmpty
                    )
                    if model.hasAlpacaCredentials {
                        Button("Remove", role: .destructive) {
                            removeAlpacaCredentials()
                        }
                    }
                    if isSavingAlpaca { ProgressView().controlSize(.small) }
                }
                if let error = alpacaSettingsError ?? model.snapshot.currentMarketData.error {
                    Text(error).font(.caption).foregroundStyle(.orange)
                } else if let message = model.alpacaCredentialMessage {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }
                Text("Uses Alpaca only for U.S. overnight quotes and charts. No Alpaca trading or account endpoint exists in OpenIBKR.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Application") {
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
                Text("Restart the app after changing the account data source or port. Credentials and the one-time local Helper token are never written to project files.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
    }

    private func saveAlpacaCredentials() {
        let keyID = alpacaKeyID.trimmingCharacters(in: .whitespacesAndNewlines)
        let secret = alpacaSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        isSavingAlpaca = true
        alpacaSettingsError = nil
        Task {
            do {
                try await model.saveAlpacaCredentials(keyID: keyID, secretKey: secret)
                alpacaKeyID = ""
                alpacaSecret = ""
            } catch {
                alpacaSettingsError = error.localizedDescription
            }
            isSavingAlpaca = false
        }
    }

    private func removeAlpacaCredentials() {
        isSavingAlpaca = true
        alpacaSettingsError = nil
        Task {
            do {
                try await model.removeAlpacaCredentials()
                alpacaKeyID = ""
                alpacaSecret = ""
            } catch {
                alpacaSettingsError = error.localizedDescription
            }
            isSavingAlpaca = false
        }
    }
}
