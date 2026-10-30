import Foundation
import UIKit
import Security
import CoreFoundation
import HopCore

struct Peer {
    let id: String, name: String, platform: String, host: String; let port: Int
    var seen = Date()
    var json: [String: Any] { ["id": id, "name": name, "platform": platform, "address": host, "port": port] }
}
struct TransferItem { let path: String, size: Int64, directory: Bool; let url: URL? }
private final class IncomingSession {
    let id: String, sender: [String: Any], remote: String, token: String, items: [TransferItem], paths: [URL], total: Int64
    var received: Int64 = 0, completed = Set<Int>(), active = false, touched = Date()
    init(id: String, sender: [String: Any], remote: String, items: [TransferItem], paths: [URL], total: Int64) throws {
        self.id = id; self.sender = sender; self.remote = remote; self.items = items; self.paths = paths; self.total = total
        var random = [UInt8](repeating: 0, count: 24); guard SecRandomCopyBytes(kSecRandomDefault, random.count, &random) == errSecSuccess else { throw HopError.invalid("Unable to create transfer token") }; token = random.map { String(format: "%02x", $0) }.joined()
    }
    var count: Int { items.filter { !$0.directory }.count }
    func event(_ type: String) -> [String: Any] { ["type": type, "id": id, "from": sender, "fileCount": count, "totalBytes": total, "total": total, "sent": received, "paths": paths.map(\.path)] }
}
final class HopEngine {
    let queue = DispatchQueue(label: "app.hop.network")
    let defaults = UserDefaults.standard
    let files = FileManager.default
    let root: URL, staging: URL
    private(set) var port: UInt16 = 0
    private(set) var peers = [String: Peer]()
    private var server: HTTPServer!
    lazy var client = HTTPClient(queue: queue)
    private var bonjour: BonjourDiscovery?
    private var udp: UDPDiscovery?
    private var readyCallbacks = [() -> Void](), timer: DispatchSourceTimer?
    private var offers = [String: (offer: [String: Any], decide: (Bool) -> Void)]()
    private var sessions = [String: IncomingSession](), reserved = Set<String>()
    private var selections = [String: [TransferItem]]()
    private var sendID: String?, sendTask: URLSessionTask?, cancelled = Set<String>()
    var event: (([String: Any]) -> Void)?
    var id: String { defaults.string(forKey: "deviceID")! }
    var name: String { defaults.string(forKey: "deviceName") ?? "iPhone" }
    var trusted: [String: String] { get { defaults.dictionary(forKey: "trusted") as? [String: String] ?? [:] } set { defaults.set(newValue, forKey: "trusted") } }
    var identity: [String: Any] { ["id": id, "name": name, "platform": "ios", "port": Int(port)] }
    init() throws {
        let manager = FileManager.default
        root = manager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        staging = manager.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("HopStaging", isDirectory: true)
        try files.createDirectory(at: root, withIntermediateDirectories: true); try files.createDirectory(at: staging, withIntermediateDirectories: true)
        if defaults.string(forKey: "deviceID") == nil { defaults.set(UUID().uuidString.lowercased(), forKey: "deviceID") }
        server = HTTPServer(queue: queue)
        server.request = { [weak self] request, reply in self?.handle(request, reply: reply) }
        server.upload = { [weak self] head, remote in guard let self else { throw HopError.invalid("Receiver stopped") }; return try self.beginUpload(head, remote: remote) }
        server.ready = { [weak self] port in guard let self else { return }; self.port = port; self.startDiscovery(); self.readyCallbacks.forEach { $0() }; self.readyCallbacks.removeAll()
            #if DEBUG
            if ProcessInfo.processInfo.environment["HOP_PROTOCOL_TEST"] == "1", let data = try? JSONSerialization.data(withJSONObject: self.identity) { try? data.write(to: self.root.appendingPathComponent(".hop-ready.json"), options: .atomic) }
            if ProcessInfo.processInfo.environment["HOP_PROTOCOL_TEST"] == "1", let number = ProcessInfo.processInfo.environment["HOP_TEST_RECEIVER_PORT"].flatMap(Int.init) {
                let url = self.root.appendingPathComponent(".hop-send-test.txt")
                let bytes = Data("Hop iOS outbound test".utf8)
                do {
                    try bytes.write(to: url)
                    try self.learn(["id":"hop-ci-receiver","name":"CI receiver","platform":"win32","port":number],host:"127.0.0.1")
                    let handle = self.registerSelection([TransferItem(path:"outgoing.txt",size:Int64(bytes.count),directory:false,url:url)])
                    _ = try self.send(to:"hop-ci-receiver",handles:[handle])
                } catch { NSLog("CI outbound test failed: %@",error.localizedDescription) }
            }
            #endif
        }
        try server.start()
        let timer = DispatchSource.makeTimerSource(queue: queue); self.timer = timer
        timer.schedule(deadline: .now() + 2, repeating: 3); timer.setEventHandler { [weak self] in self?.tick() }; timer.resume()
    }
    func whenReady(_ completion: @escaping () -> Void) { if port > 0 { completion() } else { readyCallbacks.append(completion) } }
    func state() -> [String: Any] { ["self": identity, "peers": peers.values.map(\.json), "downloadDir": "Файлы/Hop", "trustedCount": trusted.count, "theme": defaults.string(forKey: "theme") ?? "system"] }
    func rename(_ value: String) { defaults.set(String(value.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40)), forKey: "deviceName"); DispatchQueue.main.async { [weak self] in self?.bonjour?.rename() } }
    private func handle(_ request: InboundRequest, reply: @escaping (Int, [String: Any]) -> Void) {
        do {
            let h = request.head
            if h.method == "GET" && h.path == "/health" { reply(200, ["ok": true, "from": identity]); return }
            let value = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any] ?? [:]
            if h.method == "POST" && h.path == "/hello" {
                guard let from = value["from"] as? [String: Any] else { throw HopError.invalid("Bad presence") }
                try learn(from, host: request.remote); reply(200, ["ok": true, "from": identity]); return
            }
            if h.method == "POST" && h.path == "/offer" { try receiveOffer(value, remote: request.remote, reply: reply); return }
            if h.method == "POST" && h.path == "/cancel" {
                let session = try authenticated(h, remote: request.remote); event?(session.event("receive-failed").merging(["error": "Отменено отправителем"]) { _, b in b }); remove(session); reply(200, ["ok": true]); return
            }
            reply(404, ["error": "Not found"])
        } catch { reply(400, ["error": error.localizedDescription]) }
    }
    func learn(_ from: [String: Any], host: String) throws {
        guard let id = from["id"] as? String, HopValidation.validID(id), let port = from["port"] as? Int, (1...65535).contains(port), HopValidation.localAddress(host) else { throw HopError.invalid("Bad identity") }
        guard id != self.id else { return }; guard peers.count < 100 || peers[id] != nil else { return }
        peers[id] = Peer(id: id, name: String((from["name"] as? String ?? "Device").prefix(64)), platform: from["platform"] as? String ?? "other", host: host, port: port)
        emitPeers()
    }
    private func receiveOffer(_ value: [String: Any], remote: String, reply: @escaping (Int, [String: Any]) -> Void) throws {
        guard offers.count + sessions.count < 4 else { throw HopError.invalid("Receiver busy") }
        guard let transfer = value["transferId"] as? String, HopValidation.validID(transfer), offers[transfer] == nil, sessions[transfer] == nil, let from = value["from"] as? [String: Any], let senderID = from["id"] as? String, HopValidation.validID(senderID), let array = value["items"] as? [[String: Any]], !array.isEmpty, array.count <= 10000 else { throw HopError.invalid("Bad offer") }
        let sender: [String: Any] = ["id": senderID, "name": String((from["name"] as? String ?? "Device").prefix(64)), "platform": from["platform"] as? String ?? peers[senderID]?.platform ?? "other"]
        var items = [TransferItem](), seen = Set<String>(), total: Int64 = 0
        for item in array {
            guard let path = item["path"] as? String, let size = item["size"] as? NSNumber, CFGetTypeID(size) != CFBooleanGetTypeID(), size.doubleValue >= 0, size.doubleValue <= 9007199254740991, size.doubleValue == Double(size.int64Value) else { throw HopError.invalid("Bad item size") }
            let parts = try SafePath.components(path); guard parts.first != ".Incoming", seen.insert(path).inserted else { throw HopError.invalid("Duplicate/reserved path") }
            let directory = item["dir"] as? Bool ?? false; guard !directory || size.int64Value == 0 else { throw HopError.invalid("Bad directory size") }
            let sum = total.addingReportingOverflow(size.int64Value); guard !sum.overflow, sum.partialValue <= 9007199254740991 else { throw HopError.invalid("Offer too large") }; total = sum.partialValue
            items.append(TransferItem(path: path, size: size.int64Value, directory: directory, url: nil))
        }
        let filePaths = Set(items.filter { !$0.directory }.map(\.path))
        for item in items { let p = try SafePath.components(item.path); for end in 1..<p.count { guard !filePaths.contains(p.prefix(end).joined(separator: "/")) else { throw HopError.invalid("File/folder conflict") } } }
        let available = (try? root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage) ?? 0
        guard available > total + 16 * 1024 * 1024 else { throw HopError.invalid("Недостаточно места на iPhone") }
        let tops = Array(Set(items.map { String($0.path.split(separator: "/")[0]) })).sorted()
        let offer: [String: Any] = ["id": transfer, "from": sender, "names": Array(tops.prefix(20)), "fileCount": items.filter { !$0.directory }.count, "totalBytes": total]
        offers[transfer] = (offer, { [weak self] accepted in
            guard let self else { return }; self.offers.removeValue(forKey: transfer)
            guard accepted else { reply(403, ["accepted": false]); return }
            do {
                var renamed = [String: String]()
                for top in tops { renamed[top] = self.reserve(top) }
                let destinations = try items.map { item -> TransferItem in var parts = try SafePath.components(item.path); parts[0] = renamed[parts[0]]!; let url = try SafePath.destination(parts, in: self.root); if item.directory { try self.files.createDirectory(at: url, withIntermediateDirectories: true) }; return TransferItem(path: item.path, size: item.size, directory: item.directory, url: url) }
                let paths = tops.compactMap { renamed[$0] }.map { self.root.appendingPathComponent($0) }
                let session = try IncomingSession(id: transfer, sender: sender, remote: remote, items: destinations, paths: paths, total: total); self.sessions[transfer] = session
                self.event?(session.event("receive-start")); reply(200, ["accepted": true, "token": session.token])
                if session.count == 0 { self.event?(session.event("receive-done")); self.remove(session) }
            } catch { reply(400, ["error": error.localizedDescription]) }
        })
        #if DEBUG
        if ProcessInfo.processInfo.environment["HOP_PROTOCOL_TEST"] == "1" && senderID == "hop-ci-sender" { offers[transfer]?.decide(true); return }
        #endif
        if trusted[senderID] != nil { offers[transfer]?.decide(true) } else { event?(["type": "offer", "offer": offer]) }
        queue.asyncAfter(deadline: .now() + 60) { [weak self] in guard let self, let pending = self.offers[transfer] else { return }; pending.decide(false); self.event?(["type": "offer-expired", "id": transfer]) }
    }
    func decide(_ transfer: String, accepted: Bool, remember: Bool) { guard let pending = offers[transfer] else { return }; if accepted && remember, let from = pending.offer["from"] as? [String: Any], let id = from["id"] as? String { var trust = trusted; trust[id] = from["name"] as? String ?? "Device"; trusted = trust }; pending.decide(accepted) }
    private func reserve(_ top: String) -> String { var n = 0, name = top; let value = top as NSString
        while reserved.contains(name) || files.fileExists(atPath: root.appendingPathComponent(name).path) { n += 1; name = value.pathExtension.isEmpty ? "\(top) (\(n))" : "\(value.deletingPathExtension) (\(n)).\(value.pathExtension)" }; reserved.insert(name); return name
    }
    private func authenticated(_ head: HTTPHead, remote: String) throws -> IncomingSession {
        guard let id = head.query("t"), let session = sessions[id], session.remote == remote, let token = head.headers["x-hop-token"], token.utf8.count == session.token.utf8.count else { throw HopError.invalid("Unknown transfer") }
        var different: UInt8 = 0; for (a, b) in zip(token.utf8, session.token.utf8) { different |= a ^ b }; guard different == 0 else { throw HopError.invalid("Unknown transfer") }; return session
    }
    private func beginUpload(_ head: HTTPHead, remote: String) throws -> UploadSink {
        let session = try authenticated(head, remote: remote)
        guard !session.active, let index = head.query("i").flatMap(Int.init), session.items.indices.contains(index), !session.completed.contains(index), !session.items[index].directory, session.items[index].size == head.length, let destination = session.items[index].url else { throw HopError.invalid("Bad file index/length") }
        let temporary = staging.appendingPathComponent(UUID().uuidString); files.createFile(atPath: temporary.path, contents: nil); let output = try FileHandle(forWritingTo: temporary); session.active = true
        var done = false, count: Int64 = 0
        return UploadSink(write: { [weak self] bytes in guard !done, self?.sessions[session.id] === session else { throw HopError.invalid("Transfer cancelled") }; try output.write(contentsOf: bytes); count += Int64(bytes.count); session.received += Int64(bytes.count); session.touched = Date(); self?.event?(session.event("receive-progress")) }, finish: { [weak self] in
            guard let self, !done, count == head.length, self.sessions[session.id] === session else { throw HopError.invalid("Incomplete file") }; try output.close()
            try self.files.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true); try self.files.moveItem(at: temporary, to: destination); done = true; session.completed.insert(index); session.active = false
            if session.completed.count == session.count { self.event?(session.event("receive-done")); self.remove(session) }; return ["ok": true]
        }, abort: { [weak self] in guard !done else { return }; done = true; try? output.close(); try? self?.files.removeItem(at: temporary); if let self, self.sessions[session.id] === session { self.event?(session.event("receive-failed").merging(["error": "Передача прервана"]) { _, b in b }); self.remove(session) } })
    }
    private func remove(_ session: IncomingSession) { sessions.removeValue(forKey: session.id); for path in session.paths { reserved.remove(path.lastPathComponent) } }
    private func emitPeers() { event?(["type": "peers", "peers": peers.values.map(\.json)]) }
    private func tick() {
        let before = peers.count; peers = peers.filter { Date().timeIntervalSince($0.value.seen) < 15 }; if peers.count != before { emitPeers() }
        for peer in peers.values { client.request(peer, path: "/hello", method: "POST", json: ["from": identity]) { [weak self] result in guard let self, case .success(let ack) = result, let from = ack["from"] as? [String: Any], from["id"] as? String == peer.id else { return }; try? self.learn(from, host: peer.host) } }
        for session in Array(sessions.values) where !session.active && Date().timeIntervalSince(session.touched) > 120 { event?(session.event("receive-failed").merging(["error": "Отправитель не отвечает"]) { _, b in b }); remove(session) }
    }
    private func startDiscovery() { udp = UDPDiscovery(engine: self); udp?.start(); DispatchQueue.main.async { [weak self] in guard let self else { return }; self.bonjour = BonjourDiscovery(engine: self); self.bonjour?.start() } }
}

extension HopEngine {
    func registerSelection(_ items: [TransferItem]) -> String {
        let handle = "picked:" + UUID().uuidString + "/" + (items.count == 1 ? items[0].path : "Выбранные файлы")
        selections[handle] = items; return handle
    }
    func send(to peerID: String, handles: [String]) throws -> String {
        guard sendID == nil else { throw HopError.invalid("Дождитесь завершения текущей передачи") }
        guard let peer = peers[peerID] else { throw HopError.invalid("Устройство больше не в сети") }
        guard !handles.isEmpty, handles.count <= 1000 else { throw HopError.invalid("Файлы не выбраны") }
        var items = [TransferItem]()
        for handle in handles { guard let selected = selections[handle] else { throw HopError.invalid("Выберите файлы заново") }; items.append(contentsOf: selected) }
        guard !items.isEmpty, items.count <= 10000 else { throw HopError.invalid("Слишком много файлов") }
        let transfer = UUID().uuidString.lowercased(); sendID = transfer
        let total = items.reduce(Int64(0)) { $0 + $1.size }
        let metadata: [[String: Any]] = items.map { ["path": $0.path, "size": $0.size, "dir": $0.directory] }
        event?(["type": "send-progress", "peerId": peerID, "id": transfer, "stage": "waiting", "sent": 0, "total": total])
        sendTask = client.request(peer, path: "/offer", method: "POST", json: ["transferId": transfer, "from": identity, "items": metadata]) { [weak self] result in
            guard let self, self.sendID == transfer else { return }
            do {
                let response = try result.get(); guard response["accepted"] as? Bool == true, let token = response["token"] as? String, token.count <= 128 else { throw HopError.invalid("Получатель отклонил передачу") }
                self.upload(items, index: 0, peer: peer, transfer: transfer, token: token, sent: 0, total: total)
            } catch { self.finishSend(transfer, peer: peer, error: error) }
        }
        return transfer
    }
    private func upload(_ items: [TransferItem], index: Int, peer: Peer, transfer: String, token: String, sent: Int64, total: Int64) {
        guard sendID == transfer else { return }
        if cancelled.contains(transfer) { finishSend(transfer, peer: peer, error: HopError.invalid("Передача отменена")); return }
        if index == items.count { sendID = nil; sendTask = nil; event?(["type": "send-done", "id": transfer, "peerId": peer.id, "fileCount": items.filter { !$0.directory }.count, "total": total]); return }
        let item = items[index]
        if item.directory { upload(items, index: index + 1, peer: peer, transfer: transfer, token: token, sent: sent, total: total); return }
        guard let file = item.url else { finishSend(transfer, peer: peer, error: HopError.invalid("Файл недоступен")); return }
        event?(["type": "send-progress", "id": transfer, "peerId": peer.id, "stage": "sending", "sent": sent, "total": total])
        sendTask = client.request(peer, path: "/file?t=\(transfer)&i=\(index)", method: "PUT", file: file, token: token, progress: { [weak self] bytes in self?.event?(["type": "send-progress", "id": transfer, "peerId": peer.id, "stage": "sending", "sent": sent + min(bytes, item.size), "total": total]) }) { [weak self] result in
            guard let self, self.sendID == transfer else { return }
            switch result {
            case .success: self.upload(items, index: index + 1, peer: peer, transfer: transfer, token: token, sent: sent + item.size, total: total)
            case .failure(let error): self.client.request(peer, path: "/cancel?t=\(transfer)", method: "POST", json: [:], token: token) { _ in }; self.finishSend(transfer, peer: peer, error: error)
            }
        }
    }
    private func finishSend(_ transfer: String, peer: Peer, error: Error) {
        guard sendID == transfer else { return }; sendID = nil; sendTask = nil
        let wasCancelled = cancelled.remove(transfer) != nil
        event?(["type": "send-failed", "id": transfer, "peerId": peer.id, "cancelled": wasCancelled, "declined": error.localizedDescription.contains("отклонил"), "error": error.localizedDescription])
    }
    func cancel(_ transfer: String) { guard sendID == transfer else { return }; cancelled.insert(transfer); sendTask?.cancel() }
}
