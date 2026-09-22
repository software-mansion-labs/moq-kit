import Foundation
import Network
import os

extension DVR {
    final class HTTPServer: @unchecked Sendable {
        struct Request: Sendable, Equatable {
            let method: String
            let path: String
        }

        struct Response: Sendable {
            let status: Int
            let contentType: String
            let body: Data
            let cacheControl: String

            static func ok(
                contentType: String,
                body: Data,
                cacheControl: String = "no-store"
            ) -> Self {
                Self(status: 200, contentType: contentType, body: body, cacheControl: cacheControl)
            }

            static let notFound = Self(
                status: 404,
                contentType: "text/plain; charset=utf-8",
                body: Data("Not Found\n".utf8),
                cacheControl: "no-store"
            )

            static let methodNotAllowed = Self(
                status: 405,
                contentType: "text/plain; charset=utf-8",
                body: Data("Method Not Allowed\n".utf8),
                cacheControl: "no-store"
            )

            static let serverError = Self(
                status: 500,
                contentType: "text/plain; charset=utf-8",
                body: Data("Media segment unavailable\n".utf8),
                cacheControl: "no-store"
            )
        }

        typealias Handler = @Sendable (Request) async -> Response

        private let listener: NWListener
        private let queue = DispatchQueue(label: "\(KitLogger.subsystem).DVRHTTPServer")
        private let handler: Handler
        private let lock = NSLock()
        private var connections: [ObjectIdentifier: NWConnection] = [:]
        private var pendingHeaders: Set<ObjectIdentifier> = []
        private var requestTasks: [ObjectIdentifier: Task<Void, Never>] = [:]
        private var stopped = false

        private static let maximumConnectionCount = 32
        private static let requestHeaderTimeout: DispatchTimeInterval = .seconds(5)

        init(handler: @escaping Handler) throws {
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
            self.listener = try NWListener(using: parameters)
            self.handler = handler
        }

        func start() async throws -> UInt16 {
            try await withCheckedThrowingContinuation { continuation in
                let gate = HTTPServerStartGate(continuation)

                listener.stateUpdateHandler = { [weak self] state in
                    switch state {
                    case .ready:
                        guard let port = self?.listener.port?.rawValue else {
                            gate.resume(.failure(HTTPServerError.missingPort))
                            return
                        }
                        KitLogger.dvr.debug("DVR HLS server listening host=127.0.0.1 port=\(port)")
                        gate.resume(.success(port))
                    case .failed(let error):
                        gate.resume(.failure(error))
                    case .cancelled:
                        gate.resume(.failure(CancellationError()))
                    default:
                        break
                    }
                }
                listener.newConnectionHandler = { [weak self] connection in
                    self?.accept(connection)
                }
                listener.start(queue: queue)
            }
        }

        func stop() {
            let (activeConnections, activeTasks) = lock.withLock {
                guard !stopped else { return ([NWConnection](), [Task<Void, Never>]()) }
                stopped = true
                let activeConnections = Array(connections.values)
                let activeTasks = Array(requestTasks.values)
                connections.removeAll()
                pendingHeaders.removeAll()
                requestTasks.removeAll()
                return (activeConnections, activeTasks)
            }
            listener.cancel()
            activeTasks.forEach { $0.cancel() }
            activeConnections.forEach { $0.cancel() }
        }

        deinit {
            stop()
        }

        private func accept(_ connection: NWConnection) {
            let identifier = ObjectIdentifier(connection)
            let shouldStart = lock.withLock {
                guard !stopped, connections.count < Self.maximumConnectionCount else { return false }
                connections[identifier] = connection
                pendingHeaders.insert(identifier)
                return true
            }
            guard shouldStart else {
                connection.cancel()
                return
            }
            connection.stateUpdateHandler = { [weak self, weak connection] state in
                switch state {
                case .failed, .cancelled:
                    if let connection { self?.remove(connection) }
                default:
                    break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + Self.requestHeaderTimeout) { [weak self, weak connection] in
                guard let self, let connection else { return }
                let expired = self.lock.withLock {
                    self.pendingHeaders.remove(ObjectIdentifier(connection)) != nil
                }
                if expired {
                    KitLogger.dvr.debug("DVR HLS HTTP request header timed out")
                    self.remove(connection)
                    connection.cancel()
                }
            }
            receive(on: connection, buffer: Data())
        }

        private func receive(on connection: NWConnection, buffer: Data) {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) {
                [weak self, weak connection] data, _, complete, error in
                guard let self, let connection else { return }
                if error != nil || complete {
                    connection.cancel()
                    return
                }
                var buffer = buffer
                if let data { buffer.append(data) }
                guard buffer.count <= 64 * 1_024 else {
                    self.send(.notFound, method: "GET", on: connection)
                    return
                }
                guard buffer.range(of: Data("\r\n\r\n".utf8)) != nil else {
                    self.receive(on: connection, buffer: buffer)
                    return
                }
                guard let request = Self.parse(buffer) else {
                    self.send(.notFound, method: "GET", on: connection)
                    return
                }
                _ = self.lock.withLock {
                    self.pendingHeaders.remove(ObjectIdentifier(connection))
                }
                guard request.method == "GET" || request.method == "HEAD" else {
                    self.send(.methodNotAllowed, method: request.method, on: connection)
                    return
                }
                let resource = request.path.split(separator: "/").last.map(String.init) ?? "root"
                KitLogger.dvr.debug(
                    "DVR HLS HTTP request method=\(request.method, privacy: .public) resource=\(resource, privacy: .public)"
                )
                let task = Task { [weak self, weak connection] in
                    guard let self, let connection else { return }
                    let response = await self.handler(request)
                    guard !Task.isCancelled else { return }
                    self.send(response, method: request.method, on: connection)
                }
                let retained = self.lock.withLock {
                    guard !self.stopped, self.connections[ObjectIdentifier(connection)] != nil else {
                        return false
                    }
                    self.requestTasks[ObjectIdentifier(connection)] = task
                    return true
                }
                if !retained {
                    task.cancel()
                    connection.cancel()
                }
            }
        }

        private func send(_ response: Response, method: String, on connection: NWConnection) {
            let reason: String
            switch response.status {
            case 200: reason = "OK"
            case 404: reason = "Not Found"
            case 405: reason = "Method Not Allowed"
            default: reason = "Internal Server Error"
            }
            let header = """
                HTTP/1.1 \(response.status) \(reason)\r
                Content-Type: \(response.contentType)\r
                Content-Length: \(response.body.count)\r
                Cache-Control: \(response.cacheControl)\r
                Connection: close\r
                \r

                """
            var payload = Data(header.utf8)
            if method != "HEAD" { payload.append(response.body) }
            connection.send(
                content: payload,
                contentContext: .finalMessage,
                isComplete: true,
                completion: .contentProcessed { [weak self, weak connection] _ in
                    connection?.cancel()
                    if let connection { self?.remove(connection) }
                }
            )
        }

        private func remove(_ connection: NWConnection) {
            let task = lock.withLock {
                pendingHeaders.remove(ObjectIdentifier(connection))
                connections.removeValue(forKey: ObjectIdentifier(connection))
                return requestTasks.removeValue(forKey: ObjectIdentifier(connection))
            }
            task?.cancel()
        }

        static func parse(_ data: Data) -> Request? {
            guard let text = String(data: data, encoding: .utf8),
                let firstLine = text.components(separatedBy: "\r\n").first
            else { return nil }
            let fields = firstLine.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count == 3, fields[2].hasPrefix("HTTP/1.") else { return nil }
            let target = String(fields[1])
            guard target.hasPrefix("/"),
                let components = URLComponents(string: "http://127.0.0.1\(target)")
            else { return nil }
            return Request(method: String(fields[0]).uppercased(), path: components.percentEncodedPath)
        }
    }
}

private enum HTTPServerError: Error {
    case missingPort
}

private final class HTTPServerStartGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<UInt16, Error>?

    init(_ continuation: CheckedContinuation<UInt16, Error>) {
        self.continuation = continuation
    }

    func resume(_ result: Result<UInt16, Error>) {
        let continuation = lock.withLock {
            defer { self.continuation = nil }
            return self.continuation
        }
        continuation?.resume(with: result)
    }
}
