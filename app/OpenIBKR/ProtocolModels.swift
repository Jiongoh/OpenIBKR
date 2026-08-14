import Foundation

enum GatewayState: String, Codable {
    case disconnected, connecting, connected, recovering, stopped

    var displayName: String {
        switch self {
        case .connected: "Connected"
        case .connecting: "Connecting"
        case .recovering: "Recovering"
        case .disconnected: "Disconnected"
        case .stopped: "Stopped"
        }
    }
}

enum MarketDataKind: String, Codable {
    case realTime = "real_time"
    case frozen
    case delayed
    case delayedFrozen = "delayed_frozen"
    case overnightIndicative = "overnight_indicative"
    case unknown

    var displayName: String {
        switch self {
        case .realTime: "Real-Time"
        case .frozen: "Frozen"
        case .delayed: "Delayed"
        case .delayedFrozen: "Delayed Frozen"
        case .overnightIndicative: "Overnight Indicative"
        case .unknown: "Unknown"
        }
    }
}

struct DecimalString: Codable, Hashable {
    let value: Decimal

    init(_ value: Decimal) {
        self.value = value
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let text = try? container.decode(String.self), let decimal = Decimal(string: text) {
            value = decimal
        } else if let number = try? container.decode(Double.self) {
            value = Decimal(number)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Expected decimal string")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(NSDecimalNumber(decimal: value).stringValue)
    }
}

struct ConnectionStatus: Codable {
    var state: GatewayState
    var changedAt: Date
    var lastErrorCode: Int?

    static let disconnected = ConnectionStatus(state: .disconnected, changedAt: .now, lastErrorCode: nil)
}

struct AccountSnapshot: Codable {
    var accountMasked: String?
    var currency: String?
    var netLiquidation: DecimalString?
    var receivedAt: Date?
    var stale: Bool

    static let empty = AccountSnapshot(accountMasked: nil, currency: nil, netLiquidation: nil, receivedAt: nil, stale: true)
}

struct PnLSnapshot: Codable {
    var daily: DecimalString?
    var unrealized: DecimalString?
    var realized: DecimalString?
    var receivedAt: Date?
    var stale: Bool

    static let empty = PnLSnapshot(daily: nil, unrealized: nil, realized: nil, receivedAt: nil, stale: true)
}

struct Instrument: Codable, Identifiable, Hashable {
    var conId: Int
    var symbol: String
    var secType: String
    var exchange: String
    var currency: String
    var primaryExchange: String?
    var localSymbol: String?

    var id: Int { conId }
}

struct QuoteTrendPoint: Codable, Equatable {
    let sampledAt: Date
    let price: DecimalString
}

struct QuoteSnapshot: Codable, Identifiable {
    var instrument: Instrument
    var bid: DecimalString?
    var ask: DecimalString?
    var last: DecimalString?
    var close: DecimalString?
    var marketDataKind: MarketDataKind
    var receivedAt: Date?
    var stale: Bool
    var trend: [QuoteTrendPoint]? = nil

    var id: Int { instrument.conId }

    var validLast: DecimalString? {
        guard let last, last.value > 0 else { return nil }
        return last
    }

    var validClose: DecimalString? {
        guard let close, close.value > 0 else { return nil }
        return close
    }

    var displayPrice: DecimalString? {
        validLast ?? validClose
    }

    var priceChange: (absolute: Decimal, percent: Decimal)? {
        guard let last = validLast?.value, let close = validClose?.value else { return nil }
        let absolute = last - close
        return (absolute, absolute / close * 100)
    }
}

struct MarketDataStatus: Codable, Equatable {
    var provider: String
    var configured: Bool
    var active: Bool
    var lastUpdateAt: Date?
    var error: String?

    static let ibkr = MarketDataStatus(
        provider: "ibkr",
        configured: false,
        active: false,
        lastUpdateAt: nil,
        error: nil
    )

    var displayName: String {
        switch provider {
        case "alpaca_overnight": active ? "Alpaca Overnight · Active" : "Alpaca Overnight · Standby"
        default: "IB Gateway"
        }
    }
}

struct AppSnapshot: Codable {
    var protocolVersion: Int
    var sequence: Int
    var generatedAt: Date
    var connection: ConnectionStatus
    var account: AccountSnapshot
    var pnl: PnLSnapshot
    var quotes: [QuoteSnapshot]
    var marketData: MarketDataStatus? = nil

    var dailyPnLPercent: Decimal? {
        guard
            !account.stale,
            !pnl.stale,
            let dailyPnL = pnl.daily?.value,
            let netLiquidation = account.netLiquidation?.value,
            netLiquidation > 0
        else { return nil }
        return dailyPnL / netLiquidation * 100
    }

    var currentMarketData: MarketDataStatus { marketData ?? .ibkr }

    static let empty = AppSnapshot(
        protocolVersion: 1,
        sequence: 0,
        generatedAt: .now,
        connection: .disconnected,
        account: .empty,
        pnl: .empty,
        quotes: []
    )
}

struct StreamEnvelope: Codable {
    struct Payload: Codable {
        var snapshot: AppSnapshot?
        var kind: String?
    }

    var type: String
    var protocolVersion: Int
    var sequence: Int
    var sentAt: Date
    var payload: Payload
}

struct ContractQuery: Encodable {
    let symbol: String
    let secType = "STK"
    let exchange = "SMART"
    let currency = "USD"
}

enum ProtocolCoding {
    static let supportedVersion = 1

    static func requireSupported(_ version: Int) throws {
        guard version == supportedVersion else {
            throw HelperClientError.incompatibleProtocol(version)
        }
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractional.date(from: text) { return date }
            let standard = ISO8601DateFormatter()
            if let date = standard.date(from: text) { return date }
            throw DecodingError.dataCorruptedError(
                in: try decoder.singleValueContainer(),
                debugDescription: "Invalid ISO-8601 date"
            )
        }
        return decoder
    }

    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return encoder
    }
}
