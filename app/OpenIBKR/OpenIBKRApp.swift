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
                .frame(width: 560, height: 470)
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
        TabView {
            gatewayPane
                .tabItem { Label("Gateway", systemImage: "server.rack") }

            marketDataPane
                .tabItem { Label("Market Data", systemImage: "chart.xyaxis.line") }

            generalPane
                .tabItem { Label("General", systemImage: "gearshape") }
        }
        .scenePadding()
    }

    private var gatewayPane: some View {
        Form {
            Section {
                LabeledContent("Connection") {
                    SettingsStatusBadge(
                        title: model.snapshot.connection.state.displayName,
                        color: gatewayStatusColor
                    )
                }
                LabeledContent("Local Helper") {
                    Text(model.endpointDescription)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .foregroundStyle(.secondary)
                }
            } header: {
                SettingsSectionHeader(
                    title: "IB Gateway",
                    subtitle: "Read-only account and market-data connection",
                    systemImage: "server.rack"
                )
            }

            Section {
                Picker("Data Source", selection: $helperAdapter) {
                    Text("IB Gateway (Read-Only)").tag("ibkr")
                    Text("Fake Data (Development)").tag("fake")
                }
                .pickerStyle(.menu)

                TextField(
                    "Gateway Port",
                    value: $gatewayPort,
                    format: .number.grouping(.never)
                )
                .frame(maxWidth: 150)
            } header: {
                Text("Connection")
            } footer: {
                Label(
                    "Changes to the data source or port take effect after OpenIBKR restarts.",
                    systemImage: "arrow.clockwise"
                )
            }
        }
        .formStyle(.grouped)
    }

    private var marketDataPane: some View {
        Form {
            Section {
                LabeledContent("Service") {
                    SettingsStatusBadge(title: alpacaStatusTitle, color: alpacaStatusColor)
                }
                LabeledContent("Credentials") {
                    Label(
                        model.hasAlpacaCredentials ? "Stored in Keychain" : "Not Stored",
                        systemImage: model.hasAlpacaCredentials ? "lock.fill" : "lock.open"
                    )
                    .foregroundStyle(model.hasAlpacaCredentials ? .secondary : .tertiary)
                }
                LabeledContent("Last Update") {
                    if let date = model.snapshot.currentMarketData.lastUpdateAt {
                        Text(date, style: .relative)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("No data received")
                            .foregroundStyle(.tertiary)
                    }
                }
            } header: {
                SettingsSectionHeader(
                    title: "Alpaca Overnight",
                    subtitle: "Indicative U.S. quotes from 20:00–04:00 ET",
                    systemImage: "moon.stars.fill"
                )
            }

            Section {
                LabeledContent("API Key ID") {
                    TextField(
                        model.hasAlpacaCredentials ? "Enter a replacement key" : "Required",
                        text: $alpacaKeyID
                    )
                    .textFieldStyle(.roundedBorder)
                }
                LabeledContent("Secret Key") {
                    SecureField(
                        model.hasAlpacaCredentials ? "Enter a replacement secret" : "Required",
                        text: $alpacaSecret
                    )
                    .textFieldStyle(.roundedBorder)
                }

                HStack(spacing: 8) {
                    if model.hasAlpacaCredentials {
                        Button("Remove Credentials", role: .destructive) {
                            removeAlpacaCredentials()
                        }
                        .disabled(isSavingAlpaca)
                    }
                    Spacer()
                    if isSavingAlpaca {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Button(model.hasAlpacaCredentials ? "Replace & Connect" : "Save & Connect") {
                        saveAlpacaCredentials()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(
                        isSavingAlpaca
                            || alpacaKeyID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || alpacaSecret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    )
                }
            } header: {
                Text("Paper API Credentials")
            } footer: {
                Text(
                    "Credentials stay in this Mac's Keychain. OpenIBKR only calls Alpaca market-data endpoints and has no trading capability."
                )
            }

            if let error = alpacaSettingsError ?? model.snapshot.currentMarketData.error {
                Section {
                    SettingsMessage(text: error, color: .orange, systemImage: "exclamationmark.triangle.fill")
                }
            } else if let message = model.alpacaCredentialMessage {
                Section {
                    SettingsMessage(text: message, color: .secondary, systemImage: "checkmark.circle.fill")
                }
            }
        }
        .formStyle(.grouped)
    }

    private var generalPane: some View {
        Form {
            Section {
                Toggle("Launch OpenIBKR at Login", isOn: $launchAtLogin)
                    .toggleStyle(.switch)
                    .onChange(of: launchAtLogin) { _, enabled in
                        updateLaunchAtLogin(enabled)
                    }
            } header: {
                SettingsSectionHeader(
                    title: "OpenIBKR",
                    subtitle: "Application behavior on this Mac",
                    systemImage: "gearshape.fill"
                )
            } footer: {
                Text("OpenIBKR runs locally and starts its bundled Helper automatically.")
            }

            if let launchAtLoginError {
                Section {
                    SettingsMessage(
                        text: launchAtLoginError,
                        color: .orange,
                        systemImage: "exclamationmark.triangle.fill"
                    )
                }
            }

            Section("Privacy") {
                Label("Credentials are stored in macOS Keychain", systemImage: "key.fill")
                Label("Helper communication stays on 127.0.0.1", systemImage: "network.badge.shield.half.filled")
                Label("IBKR access is permanently read-only", systemImage: "lock.shield.fill")
            }
            .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }

    private var gatewayStatusColor: Color {
        switch model.snapshot.connection.state {
        case .connected: .green
        case .connecting, .recovering: .orange
        case .disconnected, .stopped: .secondary
        }
    }

    private var alpacaStatusTitle: String {
        let status = model.snapshot.currentMarketData
        if status.error != nil { return "Unavailable" }
        if status.active { return "Active" }
        if status.configured || model.hasAlpacaCredentials { return "Standby" }
        return "Not Configured"
    }

    private var alpacaStatusColor: Color {
        let status = model.snapshot.currentMarketData
        if status.error != nil { return .orange }
        if status.active { return .green }
        if status.configured || model.hasAlpacaCredentials { return .blue }
        return .secondary
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

    private func updateLaunchAtLogin(_ enabled: Bool) {
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
}

private struct SettingsSectionHeader: View {
    let title: String
    let subtitle: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .textCase(nil)
        .padding(.bottom, 4)
    }
}

private struct SettingsStatusBadge: View {
    let title: String
    let color: Color

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            Text(title)
                .foregroundStyle(.primary)
        }
        .font(.callout.weight(.medium))
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(.quaternary, in: Capsule())
    }
}

private struct SettingsMessage: View {
    let text: String
    let color: Color
    let systemImage: String

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.callout)
            .foregroundStyle(color)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
