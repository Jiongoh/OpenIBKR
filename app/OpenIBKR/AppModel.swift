import Combine
import Foundation

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var snapshot = AppSnapshot.empty
    @Published private(set) var errorMessage: String?
    @Published var isCollapsed = false
    @Published var symbolInput = ""
    @Published private(set) var contractCandidates: [Instrument] = []

    private var endpoint = HelperEndpoint.fromEnvironment()
    private var connectionTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?

    var endpointDescription: String {
        endpoint.map { $0.baseURL.absoluteString } ?? "等待 App 托管 Helper"
    }

    func start() { reconnect() }

    func configure(endpoint: HelperEndpoint) {
        self.endpoint = endpoint
        reconnect()
    }

    func reportRuntimeError(_ error: Error) {
        errorMessage = error.localizedDescription
        snapshot.connection.state = .recovering
    }

    func beginHelperStartup() {
        errorMessage = nil
        snapshot.connection.state = .connecting
    }

    func stop() {
        connectionTask?.cancel()
        refreshTask?.cancel()
    }

    func prepareForSleep() {
        connectionTask?.cancel()
        refreshTask?.cancel()
        snapshot.connection.state = .recovering
        snapshot.account.stale = true
        snapshot.pnl.stale = true
        for index in snapshot.quotes.indices { snapshot.quotes[index].stale = true }
    }

    func reconnect() {
        connectionTask?.cancel()
        guard let endpoint else {
            errorMessage = "尚未收到 Helper 的端口和一次性 Token"
            return
        }
        connectionTask = Task { [weak self] in
            guard let self else { return }
            let client = HelperClient(endpoint: endpoint)
            var delay: UInt64 = 1
            while !Task.isCancelled {
                do {
                    snapshot = try await client.snapshot()
                    errorMessage = nil
                    for try await envelope in client.stream() {
                        if let full = envelope.payload.snapshot {
                            snapshot = full
                        } else {
                            scheduleRefresh(client: client)
                        }
                    }
                } catch {
                    errorMessage = error.localizedDescription
                    snapshot.connection.state = .recovering
                }
                try? await Task.sleep(for: .seconds(delay))
                delay = min(delay * 2, 30)
            }
        }
    }

    func addSymbol() {
        let symbol = symbolInput.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !symbol.isEmpty, let endpoint else { return }
        Task {
            do {
                let client = HelperClient(endpoint: endpoint)
                let candidates = try await client.search(symbol: symbol)
                switch candidates.count {
                case 0:
                    errorMessage = "没有找到 \(symbol) 的股票合约"
                case 1:
                    try await client.add(instrument: candidates[0])
                    symbolInput = ""
                    contractCandidates = []
                default:
                    contractCandidates = candidates
                    errorMessage = nil
                }
            } catch { errorMessage = error.localizedDescription }
        }
    }

    func selectCandidate(_ instrument: Instrument) {
        guard let endpoint else { return }
        Task {
            do {
                try await HelperClient(endpoint: endpoint).add(instrument: instrument)
                symbolInput = ""
                contractCandidates = []
                errorMessage = nil
            } catch { errorMessage = error.localizedDescription }
        }
    }

    func cancelCandidateSelection() {
        contractCandidates = []
    }

    func remove(conId: Int) {
        guard let endpoint else { return }
        Task {
            do { try await HelperClient(endpoint: endpoint).remove(conId: conId) }
            catch { errorMessage = error.localizedDescription }
        }
    }

    private func scheduleRefresh(client: HelperClient) {
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard let self, !Task.isCancelled else { return }
            defer { refreshTask = nil }
            if let value = try? await client.snapshot() { snapshot = value }
        }
    }
}
