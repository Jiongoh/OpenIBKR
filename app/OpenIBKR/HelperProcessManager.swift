import Foundation
import Security
import Darwin

enum SingleInstanceError: Error { case alreadyRunning }

final class SingleInstanceLock {
    private let descriptor: Int32

    init() throws {
        let directory = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0].appending(path: "OpenIBKR", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let path = directory.appending(path: "instance.lock").path
        descriptor = Darwin.open(path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw POSIXError(.EIO) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(descriptor)
            throw SingleInstanceError.alreadyRunning
        }
    }

    deinit {
        flock(descriptor, LOCK_UN)
        Darwin.close(descriptor)
    }
}

enum HelperProcessError: LocalizedError {
    case executableMissing
    case launchFailed(String)
    case handshakeTimeout
    case invalidHandshake
    case unexpectedExit(Int32)

    var errorDescription: String? {
        switch self {
        case .executableMissing: "The Helper executable is missing from the app"
        case let .launchFailed(message): "Failed to launch Helper: \(message)"
        case .handshakeTimeout: "Timed out waiting for the Helper startup handshake"
        case .invalidHandshake: "The Helper returned an invalid startup handshake"
        case let .unexpectedExit(status): "The Helper exited unexpectedly (status \(status))"
        }
    }
}

private struct HelperReadyHandshake: Decodable {
    let type: String
    let protocolVersion: Int
    let port: Int
    let pid: Int32
}

@MainActor
final class HelperProcessManager {
    private(set) var process: Process?
    private var stdoutPipe: Pipe?
    private var expectedTermination = false
    private var sessionToken: String?
    private var helperServicePID: Int32?
    var onUnexpectedExit: ((HelperProcessError) -> Void)?

    var isRunning: Bool { process?.isRunning == true }

    func start(adapter: String, gatewayPort: Int) async throws -> HelperEndpoint {
        if let process, process.isRunning {
            throw HelperProcessError.launchFailed("Another Helper instance is already running")
        }
        let executable = try helperExecutableURL()
        let token = try Self.makeSessionToken()
        let output = Pipe()
        let child = Process()
        child.executableURL = executable
        child.standardOutput = output
        child.standardError = FileHandle.nullDevice
        child.environment = childEnvironment(
            token: token,
            adapter: adapter,
            gatewayPort: gatewayPort
        )
        expectedTermination = false
        sessionToken = token
        stdoutPipe = output
        process = child
        child.terminationHandler = { [weak self] process in
            Task { @MainActor in
                guard let self, !self.expectedTermination else { return }
                self.onUnexpectedExit?(.unexpectedExit(process.terminationStatus))
            }
        }
        do {
            try child.run()
        } catch {
            clearProcess()
            throw HelperProcessError.launchFailed(error.localizedDescription)
        }

        do {
            let line = try await readHandshakeLine(from: output.fileHandleForReading)
            let handshake = try ProtocolCoding.decoder().decode(
                HelperReadyHandshake.self,
                from: Data(line.utf8)
            )
            guard
                handshake.type == "ready",
                handshake.protocolVersion == ProtocolCoding.supportedVersion,
                handshake.pid > 0,
                (1...65535).contains(handshake.port),
                let url = URL(string: "http://127.0.0.1:\(handshake.port)")
            else { throw HelperProcessError.invalidHandshake }
            helperServicePID = handshake.pid
            return HelperEndpoint(baseURL: url, token: token)
        } catch {
            await stop()
            throw error
        }
    }

    func stop() async {
        stopSynchronously()
    }

    func stopSynchronously() {
        expectedTermination = true
        guard let child = process else {
            clearProcess()
            return
        }
        let pids = Set([child.processIdentifier, helperServicePID].compactMap { $0 })
        for pid in pids { Darwin.kill(pid, SIGTERM) }
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline, pids.contains(where: Self.processExists) {
            usleep(50_000)
        }
        for pid in pids where Self.processExists(pid) { Darwin.kill(pid, SIGKILL) }
        clearProcess()
    }

    private func readHandshakeLine(from handle: FileHandle) async throws -> String {
        try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                var bytes = Data()
                for try await byte in handle.bytes {
                    if byte == 0x0A { break }
                    bytes.append(byte)
                    if bytes.count > 4096 { throw HelperProcessError.invalidHandshake }
                }
                guard
                    !bytes.isEmpty,
                    bytes.count <= 4096,
                    let line = String(data: bytes, encoding: .utf8)
                else { throw HelperProcessError.invalidHandshake }
                return line
            }
            group.addTask {
                try await Task.sleep(for: .seconds(30))
                throw HelperProcessError.handshakeTimeout
            }
            guard let result = try await group.next() else {
                throw HelperProcessError.invalidHandshake
            }
            group.cancelAll()
            return result
        }
    }

    private func helperExecutableURL() throws -> URL {
        if let override = ProcessInfo.processInfo.environment["OPENIBKR_HELPER_EXECUTABLE"] {
            let url = URL(fileURLWithPath: override)
            guard FileManager.default.isExecutableFile(atPath: url.path) else {
                throw HelperProcessError.executableMissing
            }
            return url
        }
        let url = Bundle.main.bundleURL
            .appending(path: "Contents/Helpers/openibkr-helper")
        guard FileManager.default.isExecutableFile(atPath: url.path) else {
            throw HelperProcessError.executableMissing
        }
        return url
    }

    private func childEnvironment(token: String, adapter: String, gatewayPort: Int) -> [String: String] {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0].appending(path: "OpenIBKR", directoryHint: .isDirectory)
        return [
            "OPENIBKR_SESSION_TOKEN": token,
            "OPENIBKR_ADAPTER": adapter,
            "OPENIBKR_GATEWAY_PORT": String(gatewayPort),
            "OPENIBKR_DATABASE_PATH": applicationSupport.appending(path: "openibkr.sqlite3").path,
            "OPENIBKR_PARENT_PID": String(ProcessInfo.processInfo.processIdentifier),
            "LC_ALL": "en_US.UTF-8",
        ]
    }

    private func clearProcess() {
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        stdoutPipe = nil
        process = nil
        sessionToken = nil
        helperServicePID = nil
    }

    private static func makeSessionToken() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw HelperProcessError.launchFailed("Unable to generate a secure session token")
        }
        return Data(bytes).base64EncodedString()
    }

    private static func processExists(_ pid: Int32) -> Bool {
        Darwin.kill(pid, 0) == 0 || errno == EPERM
    }
}
