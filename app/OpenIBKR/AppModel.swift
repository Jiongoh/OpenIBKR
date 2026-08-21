import Combine
import Foundation

enum QuoteTrendDirection: Equatable {
    case rising
    case falling
    case flat

    static func from(_ points: [QuoteTrendPoint]) -> QuoteTrendDirection {
        guard let first = points.first?.price.value,
              let last = points.last?.price.value
        else { return .flat }
        if last > first { return .rising }
        if last < first { return .falling }
        return .flat
    }
}

enum QuoteTrendHistory {
    static let sampleInterval: TimeInterval = 60
    static let retentionInterval: TimeInterval = 24 * 60 * 60

    static func recording(
        price: Decimal,
        at date: Date,
        in points: [QuoteTrendPoint]
    ) -> [QuoteTrendPoint] {
        guard price > 0 else { return pruned(points, relativeTo: date) }
        let bucket = Date(
            timeIntervalSince1970:
                floor(date.timeIntervalSince1970 / sampleInterval) * sampleInterval
        )
        var result = pruned(points, relativeTo: date)
        let point = QuoteTrendPoint(sampledAt: bucket, price: DecimalString(price))

        if let last = result.last, last.sampledAt == bucket {
            if last.price != point.price {
                result[result.count - 1] = point
            }
        } else if result.last?.price != point.price,
                  result.last?.sampledAt ?? .distantPast < bucket
        {
            result.append(point)
        }
        return pruned(result, relativeTo: date)
    }

    static func pruned(
        _ points: [QuoteTrendPoint],
        relativeTo date: Date
    ) -> [QuoteTrendPoint] {
        let cutoff = date.addingTimeInterval(-retentionInterval)
        let sorted = points
            .filter { $0.sampledAt >= cutoff && $0.sampledAt <= date }
            .sorted { $0.sampledAt < $1.sampledAt }
        return sorted.reduce(into: []) { result, point in
            if result.last?.price != point.price {
                result.append(point)
            }
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var snapshot = AppSnapshot.empty {
        didSet { recordQuoteTrends(from: snapshot) }
    }
    @Published private(set) var quoteTrends: [Int: [QuoteTrendPoint]]
    @Published private(set) var hasAlpacaCredentials = false
    @Published private(set) var alpacaCredentialMessage: String?
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
    private var trendPersistenceTask: Task<Void, Never>?
    private var trendCleanupTask: Task<Void, Never>?
    private var symbolLookupGeneration = 0
    private var submittedSymbol: String?
    private let trendDefaults: UserDefaults
    private let credentialsStore: AlpacaCredentialsStore
    private let trendDefaultsKey = "openibkr.quote-trends.v1"
    private let legacyKeychainMarker = "openibkr.keychain-access.v1"
    private var didLoadStoredAlpacaCredentials = false
    private var storedAlpacaCredentials: AlpacaCredentials?

    init(
        defaults: UserDefaults = .standard,
        credentialsStore: AlpacaCredentialsStore = AlpacaCredentialsStore()
    ) {
        trendDefaults = defaults
        self.credentialsStore = credentialsStore
        let decoded: [Int: [QuoteTrendPoint]]
        if let data = defaults.data(forKey: trendDefaultsKey),
           let stored = try? JSONDecoder().decode([Int: [QuoteTrendPoint]].self, from: data)
        {
            decoded = stored.mapValues {
                QuoteTrendHistory.pruned($0, relativeTo: .now)
            }
        } else {
            decoded = [:]
        }
        _quoteTrends = Published(initialValue: decoded.filter { !$0.value.isEmpty })
    }

    var endpointDescription: String {
        endpoint.map { $0.baseURL.absoluteString } ?? "Waiting for the app-managed Helper"
    }

    func start() {
        startTrendCleanup()
        reconnect()
        Task { await injectStoredAlpacaCredentials() }
    }

    func configure(endpoint: HelperEndpoint) {
        self.endpoint = endpoint
        startTrendCleanup()
        reconnect()
        Task { await injectStoredAlpacaCredentials() }
    }

    func saveAlpacaCredentials(keyID: String, secretKey: String) async throws {
        let credentials = AlpacaCredentials(keyID: keyID, secretKey: secretKey)
        try credentialsStore.save(credentials)
        trendDefaults.removeObject(forKey: legacyKeychainMarker)
        storedAlpacaCredentials = credentials
        didLoadStoredAlpacaCredentials = true
        hasAlpacaCredentials = true
        alpacaCredentialMessage = "Saved securely in macOS Keychain"
        guard let endpoint else { return }
        let status = try await HelperClient(endpoint: endpoint).configureAlpaca(
            credentials: credentials
        )
        snapshot.marketData = status
    }

    func removeAlpacaCredentials() async throws {
        try credentialsStore.delete()
        storedAlpacaCredentials = nil
        didLoadStoredAlpacaCredentials = true
        hasAlpacaCredentials = false
        alpacaCredentialMessage = "Alpaca credentials removed"
        guard let endpoint else { return }
        let status = try await HelperClient(endpoint: endpoint).clearAlpacaCredentials()
        snapshot.marketData = status
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
        trendPersistenceTask?.cancel()
        trendPersistenceTask = nil
        trendCleanupTask?.cancel()
        trendCleanupTask = nil
        persistQuoteTrends()
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

    private func recordQuoteTrends(from snapshot: AppSnapshot) {
        let now = Date.now
        let cutoff = now.addingTimeInterval(-QuoteTrendHistory.retentionInterval)
        let activeIDs = Set(snapshot.quotes.map(\.id))
        var updated = quoteTrends.reduce(into: [Int: [QuoteTrendPoint]]()) {
            result, item in
            guard activeIDs.contains(item.key) else { return }
            let retained = QuoteTrendHistory.pruned(item.value, relativeTo: now)
            if !retained.isEmpty { result[item.key] = retained }
        }

        for quote in snapshot.quotes {
            // Sample exactly what the row displays. Staleness controls the
            // status presentation, but must not discard an observed price
            // change that is already visible to the user.
            let stored = updated[quote.id] ?? []
            let supplied = QuoteTrendHistory.pruned(quote.trend ?? [], relativeTo: now)
            let current = supplied.isEmpty ? stored : supplied
            var next = current
            if let price = quote.displayPrice?.value {
                let observedAt = quote.receivedAt ?? now
                if observedAt >= cutoff, observedAt <= now {
                    next = QuoteTrendHistory.pruned(
                        QuoteTrendHistory.recording(
                            price: price,
                            at: observedAt,
                            in: current
                        ),
                        relativeTo: now
                    )
                }
            }
            if next.isEmpty {
                updated.removeValue(forKey: quote.id)
            } else {
                updated[quote.id] = next
            }
        }

        guard updated != quoteTrends else { return }
        quoteTrends = updated
        scheduleTrendPersistence()
    }

    private func startTrendCleanup() {
        recordQuoteTrends(from: snapshot)
        guard trendCleanupTask == nil else { return }
        trendCleanupTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard let self, !Task.isCancelled else { return }
                recordQuoteTrends(from: snapshot)
            }
        }
    }

    private func scheduleTrendPersistence() {
        guard trendPersistenceTask == nil else { return }
        trendPersistenceTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard let self, !Task.isCancelled else { return }
            defer { trendPersistenceTask = nil }
            persistQuoteTrends()
        }
    }

    private func persistQuoteTrends() {
        if let data = try? JSONEncoder().encode(quoteTrends) {
            trendDefaults.set(data, forKey: trendDefaultsKey)
        }
    }

    private func injectStoredAlpacaCredentials() async {
        if !didLoadStoredAlpacaCredentials {
            didLoadStoredAlpacaCredentials = true
            let store = credentialsStore
            do {
                storedAlpacaCredentials = try await Task.detached(priority: .utility) {
                    try store.load()
                }.value
                hasAlpacaCredentials = storedAlpacaCredentials != nil
                if storedAlpacaCredentials == nil,
                   trendDefaults.bool(forKey: legacyKeychainMarker)
                {
                    alpacaCredentialMessage =
                        "Keychain storage was upgraded. Re-enter Alpaca credentials once in Settings."
                }
            } catch {
                storedAlpacaCredentials = nil
                hasAlpacaCredentials = false
                alpacaCredentialMessage = error.localizedDescription
                return
            }
        }

        guard let credentials = storedAlpacaCredentials,
              let endpoint
        else { return }

        do {
            let status = try await HelperClient(endpoint: endpoint).configureAlpaca(
                credentials: credentials
            )
            snapshot.marketData = status
            alpacaCredentialMessage = nil
        } catch {
            alpacaCredentialMessage = error.localizedDescription
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
