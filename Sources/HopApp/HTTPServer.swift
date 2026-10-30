import Foundation
import Network
import HopCore

struct InboundRequest { let head: HTTPHead; let remote: String; let body: Data }
final class UploadSink {
    let write: (Data) throws -> Void
    let finish: () throws -> [String: Any]
    let abort: () -> Void
    init(write: @escaping (Data) throws -> Void, finish: @escaping () throws -> [String: Any], abort: @escaping () -> Void) { self.write = write; self.finish = finish; self.abort = abort }
}
final class HTTPServer {
    let queue: DispatchQueue
    private var listener: NWListener?
    private var connections = [UUID: HTTPIncoming]()
    var request: ((InboundRequest, @escaping (Int, [String: Any]) -> Void) -> Void)?
    var upload: ((HTTPHead, String) throws -> UploadSink)?
    var ready: ((UInt16) -> Void)?
    init(queue: DispatchQueue) { self.queue = queue }
    func start() throws {
        let parameters = NWParameters.tcp; parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters, on: .any); self.listener = listener
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            if case .ready = state, let port = listener?.port?.rawValue { self?.ready?(port) }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            guard self.connections.count < 16 else { connection.cancel(); return }
            let id = UUID(), incoming = HTTPIncoming(connection, server: self)
            self.connections[id] = incoming; incoming.closed = { [weak self] in self?.connections.removeValue(forKey: id) }; incoming.start()
        }
        listener.start(queue: queue)
    }
    func stop() { listener?.cancel(); for connection in Array(connections.values) { connection.close() }; connections.removeAll() }
}
private final class HTTPIncoming {
    private let connection: NWConnection
    private unowned let server: HTTPServer
    private var buffer = Data(), head: HTTPHead?, remaining: Int64 = 0, body = Data()
    private var sink: UploadSink?, timer: DispatchSourceTimer?, responding = false, finished = false
    var closed: (() -> Void)?
    init(_ connection: NWConnection, server: HTTPServer) { self.connection = connection; self.server = server }
    private var remote: String { if case .hostPort(let host, _) = connection.endpoint { return host.debugDescription }; return "unknown" }
    func start() {
        let timer = DispatchSource.makeTimerSource(queue: server.queue); self.timer = timer
        timer.setEventHandler { [weak self] in self?.close() }; timer.schedule(deadline: .now() + 30); timer.resume()
        connection.stateUpdateHandler = { [weak self] state in if case .failed = state { self?.close() }; if case .cancelled = state { self?.close() } }
        connection.start(queue: server.queue); receive()
    }
    private func receive() {
        guard !finished, !responding else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, complete, error in
            guard let self, !self.finished else { return }
            do {
                self.timer?.schedule(deadline: .now() + 30)
                if let data, !data.isEmpty { try self.consume(data) }
                if let error { throw error }
                if complete && !self.responding { throw HopError.invalid("Файл получен не полностью") }
                self.receive()
            } catch { self.sink?.abort(); self.sink = nil; self.reply(400, ["error": error.localizedDescription]) }
        }
    }
    private func consume(_ data: Data) throws {
        if head == nil {
            buffer.append(data)
            guard let boundary = buffer.range(of: Data("\r\n\r\n".utf8)) else { if buffer.count > 32768 { throw HopError.invalid("HTTP header too large") }; return }
            let parsed = try HTTPHead.parse(buffer.subdata(in: 0..<boundary.upperBound)); head = parsed; remaining = parsed.length
            let rest = buffer.subdata(in: boundary.upperBound..<buffer.count); buffer.removeAll(keepingCapacity: false)
            if parsed.method == "PUT" && parsed.path == "/file" { guard let upload = server.upload else { throw HopError.invalid("Receiver unavailable") }; sink = try upload(parsed, remote) }
            else if parsed.length > (parsed.path == "/offer" ? 2 * 1024 * 1024 : 4096) { throw HopError.invalid("HTTP body too large") }
            try consumeBody(rest)
        } else { try consumeBody(data) }
    }
    private func consumeBody(_ data: Data) throws {
        guard !responding else { return }
        guard Int64(data.count) <= remaining else { throw HopError.invalid("Unexpected HTTP body") }
        if let sink { try sink.write(data) } else { body.append(data) }
        remaining -= Int64(data.count)
        guard remaining == 0, let head else { return }
        responding = true; timer?.schedule(deadline: .now() + 75)
        if let sink { let result = try sink.finish(); self.sink = nil; reply(200, result) }
        else if let handler = server.request { handler(InboundRequest(head: head, remote: remote, body: body)) { [weak self] code, result in self?.reply(code, result) } }
        else { reply(404, ["error": "Not found"]) }
    }
    private func reply(_ status: Int, _ json: [String: Any]) {
        guard !finished else { return }; responding = true
        let payload = (try? JSONSerialization.data(withJSONObject: json)) ?? Data("{}".utf8)
        var bytes = Data("HTTP/1.1 \(status) \(status == 200 ? "OK" : "Error")\r\nContent-Type: application/json\r\nContent-Length: \(payload.count)\r\nConnection: close\r\n\r\n".utf8); bytes.append(payload)
        connection.send(content: bytes, completion: .contentProcessed { [weak self] _ in self?.close() })
    }
    func close() {
        guard !finished else { return }; finished = true; timer?.cancel(); timer = nil
        sink?.abort(); sink = nil; connection.cancel(); closed?(); closed = nil
    }
}
