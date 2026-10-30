import Foundation
import HopCore

final class HTTPClient: NSObject, URLSessionDataDelegate, URLSessionTaskDelegate {
    private struct Pending { var data = Data(); let complete: (Result<[String: Any], Error>) -> Void; let progress: ((Int64) -> Void)? }
    private var pending = [Int: Pending]()
    private let operations: OperationQueue
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral; configuration.urlCache = nil; configuration.httpCookieStorage = nil
        configuration.timeoutIntervalForResource = 3600; configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration, delegate: self, delegateQueue: operations)
    }()
    init(queue: DispatchQueue) { operations = OperationQueue(); operations.maxConcurrentOperationCount = 1; operations.underlyingQueue = queue; super.init() }
    @discardableResult func request(_ peer: Peer, path: String, method: String, json: [String: Any]? = nil, file: URL? = nil, token: String? = nil, progress: ((Int64) -> Void)? = nil, complete: @escaping (Result<[String: Any], Error>) -> Void) -> URLSessionTask? {
        do {
            guard HopValidation.localAddress(peer.host) else { throw HopError.invalid("Устройство вне локальной сети") }
            var components = URLComponents(); components.scheme = "http"; components.host = peer.host; components.port = peer.port
            guard let base = components.url, let url = URL(string: path, relativeTo: base) else { throw HopError.invalid("Неверный адрес устройства") }
            var request = URLRequest(url: url); request.httpMethod = method; request.timeoutInterval = path == "/offer" ? 70 : 30; request.httpShouldHandleCookies = false
            request.setValue("application/json", forHTTPHeaderField: "Content-Type"); request.setValue("close", forHTTPHeaderField: "Connection")
            if let token { request.setValue(token, forHTTPHeaderField: "x-hop-token") }
            let task: URLSessionTask
            if let file {
                let size = (try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.int64Value ?? 0
                request.setValue(String(size), forHTTPHeaderField: "Content-Length"); request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
                task = session.uploadTask(with: request, fromFile: file)
            } else { if let json { request.httpBody = try JSONSerialization.data(withJSONObject: json) }; task = session.dataTask(with: request) }
            pending[task.taskIdentifier] = Pending(complete: complete, progress: progress); task.resume(); return task
        } catch { complete(.failure(error)); return nil }
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard var state = pending[dataTask.taskIdentifier] else { return }
        guard state.data.count + data.count <= 65536 else { dataTask.cancel(); return }; state.data.append(data); pending[dataTask.taskIdentifier] = state
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let state = pending.removeValue(forKey: task.taskIdentifier) else { return }
        if let error { state.complete(.failure(error)); return }
        do {
            let value = try JSONSerialization.jsonObject(with: state.data) as? [String: Any] ?? [:]
            guard (task.response as? HTTPURLResponse)?.statusCode == 200 else { throw HopError.invalid(value["error"] as? String ?? "Получатель отклонил передачу") }
            state.complete(.success(value))
        } catch { state.complete(.failure(error)) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) { pending[task.taskIdentifier]?.progress?(totalBytesSent) }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
