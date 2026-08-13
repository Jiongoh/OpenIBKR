import Combine
import Foundation

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var snapshot = AppSnapshot.empty
    @Published private(set) var errorMessage: String?
    @Published private(set) var symbolErrorMessage: String?
    @Published private(set) var isSearchingSymbol = false
    @Published var isCollapsed = false
    @Published var symbolInput = "" {
        didSet {
            guard symbolInput != oldValue else { return }
            symbolErrorMessage = nil
            let normalized = Self.normalizedSymbol(symbolInput)
            if let submittedSymbol, normalized != submittedSymbol {
                cancelSymbolLookup(clearError: false)
            }
        }
    }
    @Published private(set) var contractCandidates: [Instrument] = []

    private var endpoint = HelperEndpoint.fromEnvironment()
    private var connectionTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var symbolLookupTask: Task<Void, Never>?
    private var symbolLookupGeneration = 0
    private var submittedSymbol: String?

    var endpointDescription: String {
        endpoint.map { $0.baseURL.absoluteString } ?? "Waiting for the app-managed Helper"
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
        cancelSymbolLookup(clearError: false)
    }

    func prepareForSleep() {
        connectionTask?.cancel()
        refreshTask?.cancel()
        cancelSymbolLookup(clearError: false)
        snapshot.connection.state = .recovering
        snapshot.account.stale = true
        snapshot.pnl.stale = true
        for index in snapshot.quotes.indices { snapshot.quotes[index].stale = true }
    }

    func reconnect() {
        connectionTask?.cancel()
        guard let endpoint else {
            errorMessage = "The Helper port and one-time token have not arrived yet"
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
        let symbol = Self.normalizedSymbol(symbolInput)
        guard !symbol.isEmpty else { return }
        guard symbol.count <= 12 else {
            symbolErrorMessage = "Stock symbols cannot exceed 12 characters"
            return
        }
        guard Self.isValidSymbol(symbol) else {
            symbolErrorMessage = "Stock symbols may contain only letters, numbers, periods, or hyphens"
            return
        }
        guard let endpoint else {
            symbolErrorMessage = "The local Helper is not ready yet. Please try again shortly"
            return
        }

        let generation = beginSymbolLookup(submittedSymbol: symbol)
        symbolLookupTask = Task { [weak self] in
            guard let self else { return }
            defer { finishSymbolLookup(generation: generation) }
            do {
                let client = HelperClient(endpoint: endpoint)
                let candidates = try await client.search(symbol: symbol)
                guard isCurrentSymbolLookup(generation) else { return }
                switch candidates.count {
                case 0:
                    symbolErrorMessage = "No U.S. stock contract was found for \(symbol)"
                case 1:
                    try await client.add(instrument: candidates[0])
                    guard isCurrentSymbolLookup(generation) else { return }
                    submittedSymbol = nil
                    symbolInput = ""
                    contractCandidates = []
                    symbolErrorMessage = nil
                default:
                    contractCandidates = candidates
                    symbolErrorMessage = nil
                }
            } catch {
                guard isCurrentSymbolLookup(generation), !Task.isCancelled else { return }
                symbolErrorMessage = error.localizedDescription
            }
        }
    }

    func selectCandidate(_ instrument: Instrument) {
        guard let endpoint else {
            symbolErrorMessage = "The local Helper is not ready yet. Please try again shortly"
            return
        }
        let generation = beginSymbolLookup(submittedSymbol: nil)
        symbolLookupTask = Task { [weak self] in
            guard let self else { return }
            defer { finishSymbolLookup(generation: generation) }
            do {
                try await HelperClient(endpoint: endpoint).add(instrument: instrument)
                guard isCurrentSymbolLookup(generation) else { return }
                submittedSymbol = nil
                symbolInput = ""
                contractCandidates = []
                symbolErrorMessage = nil
            } catch {
                guard isCurrentSymbolLookup(generation), !Task.isCancelled else { return }
                symbolErrorMessage = error.localizedDescription
            }
        }
    }

    func cancelCandidateSelection() {
        cancelSymbolLookup(clearError: true)
        contractCandidates = []
        symbolInput = ""
    }

    func beginSymbolEntry() {
        cancelSymbolLookup(clearError: true)
        contractCandidates = []
        symbolInput = ""
    }

    func cancelSymbolEntry() {
        cancelSymbolLookup(clearError: true)
        symbolInput = ""
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

    private func beginSymbolLookup(submittedSymbol: String?) -> Int {
        cancelSymbolLookup(clearError: true)
        symbolLookupGeneration += 1
        self.submittedSymbol = submittedSymbol
        isSearchingSymbol = true
        return symbolLookupGeneration
    }

    private func finishSymbolLookup(generation: Int) {
        guard generation == symbolLookupGeneration else { return }
        isSearchingSymbol = false
        submittedSymbol = nil
        symbolLookupTask = nil
    }

    private func isCurrentSymbolLookup(_ generation: Int) -> Bool {
        generation == symbolLookupGeneration
    }

    private func cancelSymbolLookup(clearError: Bool) {
        symbolLookupGeneration += 1
        symbolLookupTask?.cancel()
        symbolLookupTask = nil
        submittedSymbol = nil
        isSearchingSymbol = false
        if clearError { symbolErrorMessage = nil }
    }

    private static func normalizedSymbol(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }

    private static func isValidSymbol(_ value: String) -> Bool {
        !value.isEmpty && value.unicodeScalars.allSatisfy { scalar in
            switch scalar.value {
            case 45, 46, 48...57, 65...90:
                true
            default:
                false
            }
        }
    }
}

#if DEBUG
extension AppModel {
    static var dashboardPreview: AppModel {
        let model = AppModel()
        model.snapshot = AppSnapshot(
            protocolVersion: ProtocolCoding.supportedVersion,
            sequence: 42,
            generatedAt: .now,
            connection: ConnectionStatus(
                state: .connected,
                changedAt: .now,
                lastErrorCode: nil
            ),
            account: AccountSnapshot(
                accountMasked: "DEMO-ACCOUNT",
                currency: "USD",
                netLiquidation: DecimalString(125_000),
                receivedAt: .now,
                stale: false
            ),
            pnl: PnLSnapshot(
                daily: DecimalString(123.12),
                unrealized: DecimalString(-88.73),
                realized: DecimalString(211.85),
                receivedAt: .now,
                stale: false
            ),
            quotes: [
                previewQuote(
                    conId: 90_001,
                    symbol: "AAPL",
                    last: 236.46,
                    close: 234.18,
                    kind: .realTime
                ),
                previewQuote(
                    conId: 90_002,
                    symbol: "NVDA",
                    last: 178.23,
                    close: 181.04,
                    kind: .realTime
                ),
                previewQuote(
                    conId: 90_003,
                    symbol: "QQQ",
                    last: 612.88,
                    close: 610.40,
                    kind: .delayed
                ),
                previewQuote(
                    conId: 90_004,
                    symbol: "TSLA",
                    last: 431.12,
                    close: 431.12,
                    kind: .frozen
                ),
            ]
        )
        return model
    }

    private static func previewQuote(
        conId: Int,
        symbol: String,
        last: Decimal,
        close: Decimal,
        kind: MarketDataKind
    ) -> QuoteSnapshot {
        QuoteSnapshot(
            instrument: Instrument(
                conId: conId,
                symbol: symbol,
                secType: "STK",
                exchange: "SMART",
                currency: "USD",
                primaryExchange: "DEMO",
                localSymbol: symbol
            ),
            bid: DecimalString(last - 0.02),
            ask: DecimalString(last + 0.02),
            last: DecimalString(last),
            close: DecimalString(close),
            marketDataKind: kind,
            receivedAt: .now,
            stale: false
        )
    }
}
#endif
