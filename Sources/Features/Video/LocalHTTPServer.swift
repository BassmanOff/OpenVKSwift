import Foundation
import Network

/// Крошечный HTTP/1.1-сервер на 127.0.0.1 для виртуального HLS-стрима.
///
/// Нужен потому, что AVPlayer НЕ принимает медиасегменты HLS через
/// AVAssetResourceLoader (CoreMedia -12881: этот механизм — только для плейлистов
/// и ключей). Сегменты обязаны приходить по HTTP — поднимаем свой на loopback:
/// снаружи устройства он не виден, живёт только пока открыт экран видео.
final class LocalHTTPServer {
    /// Обработчик: путь запроса → (Content-Type, тело) или nil (404).
    typealias Handler = @Sendable (String) async -> (contentType: String, data: Data)?

    private let listener: NWListener
    private let handler: Handler
    private let queue = DispatchQueue(label: "ovk.hls.http")
    private(set) var port: UInt16 = 0

    init(handler: @escaping Handler) throws {
        self.handler = handler
        let params = NWParameters.tcp
        // Слушаем ТОЛЬКО loopback — наружу сервер не торчит.
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)
        self.listener = try NWListener(using: params)
    }

    /// Запускает сервер; возвращает порт, выданный системой.
    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<UInt16, Error>) in
            var resumed = false
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    guard !resumed else { return }
                    resumed = true
                    self.port = self.listener.port?.rawValue ?? 0
                    cont.resume(returning: self.port)
                case .failed(let error):
                    guard !resumed else { return }
                    resumed = true
                    cont.resume(throwing: error)
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.handle(connection)
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        listener.cancel()
    }

    deinit {
        listener.cancel()
    }

    // MARK: - Обслуживание соединения

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveRequest(connection, buffer: Data())
    }

    /// Читаем до конца заголовков (\r\n\r\n) — тела у GET нет.
    private func receiveRequest(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }
            var buffer = buffer
            if let data { buffer.append(data) }
            if error != nil || isComplete || buffer.count > 32 * 1024 {
                if let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) {
                    let head = String(data: buffer[..<headerEnd.lowerBound], encoding: .utf8) ?? ""
                    self.respond(connection, requestHead: head)
                } else {
                    connection.cancel()
                }
                return
            }
            if let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(data: buffer[..<headerEnd.lowerBound], encoding: .utf8) ?? ""
                self.respond(connection, requestHead: head)
            } else {
                self.receiveRequest(connection, buffer: buffer)
            }
        }
    }

    private func respond(_ connection: NWConnection, requestHead: String) {
        // Первая строка: "GET /path HTTP/1.1".
        let firstLine = requestHead.components(separatedBy: "\r\n").first ?? ""
        let parts = firstLine.components(separatedBy: " ")
        guard parts.count >= 2, parts[0] == "GET" else {
            send(connection, status: "405 Method Not Allowed", contentType: "text/plain", body: Data())
            return
        }
        let path = parts[1]
        let handler = self.handler
        Task {
            if let (contentType, body) = await handler(path) {
                self.send(connection, status: "200 OK", contentType: contentType, body: body)
            } else {
                self.send(connection, status: "404 Not Found", contentType: "text/plain", body: Data())
            }
        }
    }

    private func send(_ connection: NWConnection, status: String, contentType: String, body: Data) {
        let head = "HTTP/1.1 \(status)\r\n"
            + "Content-Type: \(contentType)\r\n"
            + "Content-Length: \(body.count)\r\n"
            + "Cache-Control: no-cache\r\n"
            + "Connection: close\r\n\r\n"
        var response = Data(head.utf8)
        response.append(body)
        connection.send(content: response, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}
