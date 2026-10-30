import Foundation
import Darwin
import HopCore

final class BonjourDiscovery: NSObject, NetServiceBrowserDelegate, NetServiceDelegate {
    private unowned let engine: HopEngine
    private let browser = NetServiceBrowser()
    private var advertised: NetService?, services = [String: NetService]()
    init(engine: HopEngine) { self.engine = engine; super.init() }
    func start() {
        let service = NetService(domain: "local.", type: "_hop._tcp.", name: "Hop-" + engine.id, port: Int32(engine.port))
        advertised = service; rename(); service.publish()
        browser.delegate = self; browser.searchForServices(ofType: "_hop._tcp.", inDomain: "local.")
    }
    func rename() {
        advertised?.setTXTRecord(NetService.data(fromTXTRecord: ["proto": Data("hop/1".utf8), "id": Data(engine.id.utf8), "name": Data(engine.name.utf8), "platform": Data("ios".utf8)]))
    }
    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        guard services.count < 100, service.name != advertised?.name else { return }
        services[service.name] = service; service.delegate = self; service.resolve(withTimeout: 5)
    }
    func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) { services.removeValue(forKey: service.name)?.stop() }
    func netServiceDidResolveAddress(_ sender: NetService) { resolved(sender) }
    func netService(_ sender: NetService, didUpdateTXTRecord data: Data) { resolved(sender) }
    private func resolved(_ service: NetService) {
        guard let data = service.txtRecordData(), (1...65535).contains(service.port) else { return }
        let record = NetService.dictionary(fromTXTRecord: data)
        func text(_ key: String) -> String { record[key].flatMap { String(data: $0, encoding: .utf8) } ?? "" }
        guard text("proto") == "hop/1", HopValidation.validID(text("id")), text("id") != engine.id else { return }
        var hosts = [(Int, String)]()
        for address in service.addresses ?? [] {
            address.withUnsafeBytes { bytes in
                guard let raw = bytes.baseAddress, address.count >= MemoryLayout<sockaddr>.size else { return }
                let sockaddr = raw.assumingMemoryBound(to: Darwin.sockaddr.self); var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(sockaddr, socklen_t(address.count), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                    let value = String(cString: host); if HopValidation.localAddress(value) { hosts.append((Int(sockaddr.pointee.sa_family), value)) }
                }
            }
        }
        guard let host = hosts.sorted(by: { $0.0 == AF_INET && $1.0 != AF_INET }).first?.1 else { return }
        let identity: [String: Any] = ["id": text("id"), "name": String(text("name").prefix(64)), "platform": text("platform"), "port": service.port]
        engine.queue.async { [weak self] in guard let self else { return }; try? self.engine.learn(identity, host: host) }
    }
    deinit { browser.stop(); advertised?.stop(); for service in services.values { service.stop() } }
}
