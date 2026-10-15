import Foundation
@preconcurrency import Network

public enum ConnectionError: Error, LocalizedError {
    case closed
    case failed(String)
    case timeout

    public var errorDescription: String? {
        switch self {
        case .closed: "Spojenie bolo ukončené serverom."
        case .failed(let reason): "Spojenie zlyhalo: \(reason)"
        case .timeout: "Server neodpovedal včas."
        }
    }
}

/// How a connection is encrypted.
public enum ConnectionSecurity: String, Codable, Sendable, CaseIterable {
    /// TLS from the first byte (IMAP 993, SMTP 465).
    case tls
    /// Plain connection upgraded with STARTTLS before logging in (IMAP 143, SMTP 587).
    case startTLS

    /// The usual security for a port.
    public static func forPort(_ port: UInt16) -> ConnectionSecurity {
        [143, 587, 25, 2525].contains(port) ? .startTLS : .tls
    }
}

/// Connection with a buffered, line-oriented reader, used by both the IMAP and the SMTP client.
/// Implicit TLS goes over Network.framework; STARTTLS over a URLSession stream task,
/// which can switch an open connection to TLS.
public actor LineConnection {
    private enum Transport {
        case network(NWConnection)
        case stream(URLSessionStreamTask, URLSession)
    }

    private let transport: Transport
    private var buffer = Data()
    private var isClosed = false
    public private(set) var isSecure: Bool

    public init(host: String, port: UInt16, security: ConnectionSecurity = .tls) {
        switch security {
        case .tls:
            let tls = NWProtocolTLS.Options()
            let tcp = NWProtocolTCP.Options()
            tcp.connectionTimeout = 20
            let params = NWParameters(tls: tls, tcp: tcp)
            transport = .network(NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: params))
            isSecure = true
        case .startTLS:
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 20
            let session = URLSession(configuration: configuration)
            transport = .stream(session.streamTask(withHostName: host, port: Int(port)), session)
            isSecure = false
        }
    }

    public func open() async throws {
        switch transport {
        case .stream(let task, _):
            task.resume()
        case .network(let connection):
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                let resumed = ResumeOnce()
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        if resumed.claim() { cont.resume() }
                    case .failed(let error):
                        if resumed.claim() { cont.resume(throwing: ConnectionError.failed(error.localizedDescription)) }
                    case .waiting(let error):
                        if resumed.claim() {
                            connection.cancel()
                            cont.resume(throwing: ConnectionError.failed(error.localizedDescription))
                        }
                    case .cancelled:
                        if resumed.claim() { cont.resume(throwing: ConnectionError.closed) }
                    default:
                        break
                    }
                }
                connection.start(queue: .global(qos: .userInitiated))
            }
        }
    }

    /// Switches a STARTTLS connection to TLS (after the server agreed to it).
    public func startTLS() {
        guard case .stream(let task, _) = transport, !isSecure else { return }
        buffer.removeAll()
        task.startSecureConnection()
        isSecure = true
    }

    public func close() {
        isClosed = true
        switch transport {
        case .network(let connection):
            connection.cancel()
        case .stream(let task, let session):
            task.cancel()
            session.invalidateAndCancel()
        }
    }

    public func send(_ data: Data) async throws {
        switch transport {
        case .network(let connection):
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                connection.send(content: data, completion: .contentProcessed { error in
                    if let error {
                        cont.resume(throwing: ConnectionError.failed(error.localizedDescription))
                    } else {
                        cont.resume()
                    }
                })
            }
        case .stream(let task, _):
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                task.write(data, timeout: 120) { error in
                    if let error {
                        cont.resume(throwing: ConnectionError.failed(error.localizedDescription))
                    } else {
                        cont.resume()
                    }
                }
            }
        }
    }

    public func send(_ string: String) async throws {
        try await send(Data(string.utf8))
    }

    /// Reads one line including the trailing CRLF.
    public func readLine() async throws -> Data {
        while true {
            if let range = buffer.firstRange(of: Data([0x0D, 0x0A])) {
                let line = buffer[buffer.startIndex..<range.upperBound]
                buffer.removeSubrange(buffer.startIndex..<range.upperBound)
                return Data(line)
            }
            try await fill()
        }
    }

    public func readBytes(_ count: Int) async throws -> Data {
        while buffer.count < count {
            try await fill()
        }
        let chunk = buffer.prefix(count)
        buffer.removeFirst(count)
        return Data(chunk)
    }

    private func fill() async throws {
        if isClosed { throw ConnectionError.closed }
        let chunk: Data
        switch transport {
        case .network(let connection):
            chunk = try await withCheckedThrowingContinuation { cont in
                connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { data, _, isComplete, error in
                    if let error {
                        cont.resume(throwing: ConnectionError.failed(error.localizedDescription))
                    } else if let data, !data.isEmpty {
                        cont.resume(returning: data)
                    } else if isComplete {
                        cont.resume(throwing: ConnectionError.closed)
                    } else {
                        cont.resume(returning: Data())
                    }
                }
            }
        case .stream(let task, _):
            // Long timeout: IMAP IDLE waits for many minutes without data.
            chunk = try await withCheckedThrowingContinuation { cont in
                task.readData(ofMinLength: 1, maxLength: 256 * 1024, timeout: 3600) { data, atEOF, error in
                    if let error {
                        cont.resume(throwing: ConnectionError.failed(error.localizedDescription))
                    } else if let data, !data.isEmpty {
                        cont.resume(returning: data)
                    } else if atEOF {
                        cont.resume(throwing: ConnectionError.closed)
                    } else {
                        cont.resume(returning: Data())
                    }
                }
            }
        }
        buffer.append(chunk)
    }
}

/// Guards a continuation against being resumed twice from NWConnection state callbacks.
final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}
