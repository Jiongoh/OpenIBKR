import Foundation

struct HelperEndpoint {
    let baseURL: URL
    let token: String

    static func fromEnvironment() -> HelperEndpoint? {
        let environment = ProcessInfo.processInfo.environment
        guard
            let portText = environment["OPENIBKR_HELPER_PORT"],
            let port = Int(portText),
            (1...65535).contains(port),
            let token = environment["OPENIBKR_SESSION_TOKEN"],
            token.count >= 32,
            let url = URL(string: "http://127.0.0.1:\(port)")
        else { return nil }
        return HelperEndpoint(baseURL: url, token: token)
    }
}

enum HelperClientError: LocalizedError {
    case invalidResponse
    case http(Int, String?)
    case incompatibleProtocol(Int)

    var errorDescription: String? {
        switch self {
        case .invalidResponse: "The Helper returned an invalid response"
        case let .http(code, detail):
            switch code {
            case 401: "Local Helper authentication failed. Please restart OpenIBKR"
            case 409: "The watchlist has reached its maximum size"
            case 422: "The stock symbol or selected contract is invalid. Please check it and try again"
            case 503: "IB Gateway is unavailable. Make sure it is logged in and API access is enabled"
            case 504: "The IB Gateway contract lookup timed out. Please try again"
            default: detail ?? "Helper HTTP error \(code)"
            }
        case let .incompatibleProtocol(version): "Helper protocol version \(version) is not supported"
        }
    }
}

struct HelperClient {
    let endpoint: HelperEndpoint
    private let session = URLSession(configuration: .ephemeral)

    func snapshot() async throws -> AppSnapshot {
        let data = try await request(path: "/v1/snapshot")
        let snapshot = try ProtocolCoding.decoder().decode(AppSnapshot.self, from: data)
        try ProtocolCoding.requireSupported(snapshot.protocolVersion)
        return snapshot
    }

    func add(symbol: String) async throws {
        let body = try ProtocolCoding.encoder().encode(ContractQuery(symbol: symbol))
        _ = try await request(path: "/v1/watchlist", method: "POST", body: body)
    }

    func search(symbol: String) async throws -> [Instrument] {
        let body = try ProtocolCoding.encoder().encode(ContractQuery(symbol: symbol))
        let data = try await request(path: "/v1/contracts/search", method: "POST", body: body)
        return try ProtocolCoding.decoder().decode([Instrument].self, from: data)
    }

    func add(instrument: Instrument) async throws {
        let body = try ProtocolCoding.encoder().encode(instrument)
        _ = try await request(path: "/v1/watchlist/instrument", method: "POST", body: body)
    }

    func remove(conId: Int) async throws {
        _ = try await request(path: "/v1/watchlist/\(conId)", method: "DELETE")
    }

    func stream() -> AsyncThrowingStream<StreamEnvelope, Error> {
        var request = URLRequest(url: endpoint.baseURL.appending(path: "/v1/stream"))
        request.setValue("Bearer \(endpoint.token)", forHTTPHeaderField: "Authorization")
        let task = session.webSocketTask(with: request)
        task.resume()
        return AsyncThrowingStream { continuation in
            let receiver = Task {
                do {
                    while !Task.isCancelled {
                        let message = try await task.receive()
                        let data: Data
                        switch message {
                        case let .data(value): data = value
                        case let .string(value): data = Data(value.utf8)
                        @unknown default: continue
                        }
                        let envelope = try ProtocolCoding.decoder().decode(StreamEnvelope.self, from: data)
                        try ProtocolCoding.requireSupported(envelope.protocolVersion)
                        continuation.yield(envelope)
                    }
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                receiver.cancel()
                task.cancel(with: .goingAway, reason: nil)
            }
        }
    }

    private func request(path: String, method: String = "GET", body: Data? = nil) async throws -> Data {
        var request = URLRequest(url: endpoint.baseURL.appending(path: path))
        request.httpMethod = method
        request.httpBody = body
        request.setValue("Bearer \(endpoint.token)", forHTTPHeaderField: "Authorization")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw HelperClientError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw HelperClientError.http(http.statusCode, Self.errorDetail(from: data))
        }
        return data
    }

    private static func errorDetail(from data: Data) -> String? {
        guard
            let object = try? JSONSerialization.jsonObject(with: data),
            let dictionary = object as? [String: Any],
            let detail = dictionary["detail"]
        else { return nil }

        if let message = detail as? String, !message.isEmpty {
            return message
        }
        if let validationIssues = detail as? [[String: Any]] {
            let messages = validationIssues.compactMap { $0["msg"] as? String }
            return messages.isEmpty ? nil : messages.joined(separator: "；")
        }
        return nil
    }
}
