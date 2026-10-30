import Foundation
import Darwin
import HopCore

/// Uses the existing hop/1 discovery port. Unicast probes do not require
/// Apple's restricted multicast entitlement on personal development accounts.
final class UDPDiscovery {
    private unowned let engine: HopEngine
    private var fd: Int32 = -1
    private var source: DispatchSourceRead?, timer: DispatchSourceTimer?
    init(engine: HopEngine) { self.engine = engine }
    func start() {
        fd = socket(AF_INET, SOCK_DGRAM, 0); guard fd >= 0 else { return }
        var yes: Int32 = 1
        setsockopt(fd,SOL_SOCKET,SO_REUSEADDR,&yes,socklen_t(MemoryLayout.size(ofValue: yes)))
        setsockopt(fd,SOL_SOCKET,SO_BROADCAST,&yes,socklen_t(MemoryLayout.size(ofValue: yes)))
        fcntl(fd,F_SETFL,O_NONBLOCK)
        var address = sockaddr_in(); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET); address.sin_port = UInt16(47800).bigEndian
        let result = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd,$0,socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard result == 0 else { Darwin.close(fd); fd = -1; return }
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: engine.queue); self.source = source
        source.setEventHandler { [weak self] in self?.read() }; source.resume()
        let timer = DispatchSource.makeTimerSource(queue: engine.queue); self.timer = timer
        timer.schedule(deadline: .now(), repeating: 5); timer.setEventHandler { [weak self] in self?.announce() }; timer.resume()
    }
    private func read() {
        var bytes = [UInt8](repeating: 0, count: 4096)
        for _ in 0..<100 {
            var remote = sockaddr_in(), length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let n = withUnsafeMutablePointer(to: &remote) { ptr in ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd,&bytes,bytes.count,0,$0,&length) } }
            guard n > 0 else { return }
            guard let value = try? JSONSerialization.jsonObject(with: Data(bytes.prefix(n))) as? [String: Any], value["proto"] as? String == "hop/1", value["type"] as? String == "hello" else { continue }
            var ip = remote.sin_addr; var host = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN)); inet_ntop(AF_INET,&ip,&host,socklen_t(host.count))
            try? engine.learn(value, host: String(cString: host))
        }
    }
    private func announce() {
        guard fd >= 0, let bytes = try? JSONSerialization.data(withJSONObject: engine.identity.merging(["proto":"hop/1","type":"hello"]) { _,b in b }) else { return }
        var hosts = Set(engine.peers.values.map(\.host)); hosts.insert("255.255.255.255")
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        if getifaddrs(&interfaces) == 0 {
            var ptr = interfaces
            while let current = ptr { defer { ptr = current.pointee.ifa_next }; let info = current.pointee
                guard String(cString: info.ifa_name) == "en0", let address = info.ifa_addr, address.pointee.sa_family == AF_INET else { continue }
                let ipv4 = UnsafeRawPointer(address).assumingMemoryBound(to: sockaddr_in.self).pointee.sin_addr.s_addr.bigEndian
                let prefix = ipv4 & 0xffffff00
                for suffix in 1...254 { let ip = prefix | UInt32(suffix); if ip != ipv4 { hosts.insert("\((ip >> 24) & 255).\((ip >> 16) & 255).\((ip >> 8) & 255).\(ip & 255)") } }
            }
            freeifaddrs(interfaces)
        }
        for (index,host) in hosts.sorted().enumerated() { engine.queue.asyncAfter(deadline: .now() + Double(index) * 0.01) { [weak self] in self?.send(bytes, host: host) } }
    }
    private func send(_ bytes: Data, host: String) {
        guard fd >= 0 else { return }; var address = sockaddr_in(); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET); address.sin_port = UInt16(47800).bigEndian
        guard inet_pton(AF_INET,host,&address.sin_addr) == 1 else { return }
        bytes.withUnsafeBytes { buffer in withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { _ = sendto(fd,buffer.baseAddress,bytes.count,0,$0,socklen_t(MemoryLayout<sockaddr_in>.size)) } } }
    }
    deinit { timer?.cancel(); source?.cancel(); if fd >= 0 { Darwin.close(fd) } }
}
