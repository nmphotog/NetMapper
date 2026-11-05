import Foundation
import Network
import Darwin

// MARK: - IPv4 helpers

enum IPv4 {
    static func string(_ v: UInt32) -> String {
        "\((v >> 24) & 0xff).\((v >> 16) & 0xff).\((v >> 8) & 0xff).\(v & 0xff)"
    }

    static func parse<S: StringProtocol>(_ s: S) -> UInt32? {
        let parts = s.split(separator: ".").compactMap { UInt32($0) }
        guard parts.count == 4, parts.allSatisfy({ $0 < 256 }) else { return nil }
        return parts.reduce(0) { ($0 << 8) | $1 }
    }
}

// MARK: - Local interface

struct NetworkInterface {
    let name: String
    let address: UInt32   // host byte order
    let netmask: UInt32   // host byte order

    var prefixLength: Int { netmask.nonzeroBitCount }
    var network: UInt32 { address & netmask }
    var broadcast: UInt32 { network | ~netmask }
    var cidr: String { "\(IPv4.string(network))/\(prefixLength)" }

    /// The first active, non-loopback IPv4 interface, preferring en* (Wi-Fi / Ethernet).
    static func primary() -> NetworkInterface? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else { return nil }
        defer { freeifaddrs(head) }

        var found: [NetworkInterface] = []
        var ptr = head
        while let p = ptr {
            let ifa = p.pointee
            ptr = ifa.ifa_next

            let flags = Int32(ifa.ifa_flags)
            guard let addr = ifa.ifa_addr, let mask = ifa.ifa_netmask,
                  addr.pointee.sa_family == sa_family_t(AF_INET),
                  flags & IFF_UP != 0, flags & IFF_RUNNING != 0, flags & IFF_LOOPBACK == 0
            else { continue }

            let a = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            let m = mask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            if (a >> 16) == 0xA9FE { continue } // skip 169.254.x.x link-local
            found.append(NetworkInterface(name: String(cString: ifa.ifa_name), address: a, netmask: m))
        }
        return found.first { $0.name.hasPrefix("en") } ?? found.first
    }

    /// This Mac's hardware address for the interface (from its AF_LINK entry).
    var macAddress: String? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else { return nil }
        defer { freeifaddrs(head) }
        var ptr = head
        while let p = ptr {
            let ifa = p.pointee
            ptr = ifa.ifa_next
            guard let addr = ifa.ifa_addr, addr.pointee.sa_family == sa_family_t(AF_LINK),
                  String(cString: ifa.ifa_name) == name else { continue }
            let bytes = UnsafeRawPointer(addr).assumingMemoryBound(to: UInt8.self)
            return SystemInfo.macFromSockaddrDL(bytes, limit: Int(addr.pointee.sa_len))
        }
        return nil
    }
}

// MARK: - Host model

struct DiscoveredHost: Identifiable, Hashable {
    let address: UInt32
    var hostname: String?
    var mac: String?
    var latency: Double?
    var isThisMac = false
    var isGateway = false

    var id: UInt32 { address }
    var ip: String { IPv4.string(address) }
    var displayName: String {
        if let hostname { return hostname }
        if isThisMac { return "This Mac" }
        if isGateway { return "Router" }
        return "Unknown"
    }
    var symbol: String {
        if isGateway { return "wifi.router" }
        if isThisMac { return "laptopcomputer" }
        return "desktopcomputer"
    }
}

// MARK: - Probing

private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}

enum Prober {
    /// Common ports. A host is "alive" if any port accepts OR actively refuses the connection.
    static let ports: [UInt16] = [80, 443, 22, 445, 62078, 5000]

    static func isAlive(_ ip: String, timeout: TimeInterval = 1.0) async -> Double? {
        await withTaskGroup(of: Double?.self) { group in
            for port in ports {
                group.addTask { await probe(ip, port: port, timeout: timeout) }
            }
            var best: Double?
            for await r in group {
                if let r { best = min(best ?? r, r) }
            }
            return best
        }
    }

    static func probe(_ ip: String, port: UInt16, timeout: TimeInterval) async -> Double? {
        await withCheckedContinuation { cont in
            let once = ResumeOnce()
            let start = DispatchTime.now().uptimeNanoseconds
            let queue = DispatchQueue(label: "probe.\(ip).\(port)")
            let conn = NWConnection(host: NWEndpoint.Host(ip),
                                    port: NWEndpoint.Port(rawValue: port)!,
                                    using: .tcp)

            let finish: (Bool) -> Void = { alive in
                guard once.claim() else { return }
                conn.stateUpdateHandler = nil
                conn.cancel()
                let ms = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
                cont.resume(returning: alive ? ms : nil)
            }

            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    finish(true)
                case .waiting(let error):
                    if case .posix(.ECONNREFUSED) = error { finish(true) }
                case .failed(let error):
                    if case .posix(.ECONNREFUSED) = error { finish(true) } else { finish(false) }
                default:
                    break
                }
            }
            conn.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) { finish(false) }
        }
    }
}

// MARK: - System lookups

enum SystemInfo {
    private static func run(_ path: String, _ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do { try p.run() } catch { return "" }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    /// Reads the MAC out of a raw sockaddr_dl:
    /// len(1) family(1) index(2) type(1) nlen(1) alen(1) slen(1) data[...] where MAC = data[nlen..<nlen+alen].
    static func macFromSockaddrDL(_ p: UnsafePointer<UInt8>, limit: Int) -> String? {
        guard limit >= 8, p[1] == UInt8(AF_LINK) else { return nil }
        let nlen = Int(p[5]), alen = Int(p[6])
        guard alen == 6, 8 + nlen + 6 <= limit else { return nil }
        let mac = (0..<6).map { String(format: "%02x", p[8 + nlen + $0]) }.joined(separator: ":")
        guard mac != "00:00:00:00:00:00", mac != "ff:ff:ff:ff:ff:ff", !mac.hasPrefix("01:00:5e") else { return nil }
        return mac
    }

    /// IP -> MAC from the kernel ARP cache. Probing populates this, so it also
    /// catches devices that ignore every port (firewalled phones, IoT, etc.).
    /// Reads the routing table directly via sysctl; falls back to /usr/sbin/arp.
    static func arpTable() -> [UInt32: String] {
        if let table = arpTableSysctl(), !table.isEmpty { return table }
        return arpTableCommand()
    }

    static func arpTableSysctl() -> [UInt32: String]? {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, AF_INET, NET_RT_FLAGS, RTF_LLINFO]
        var len = 0
        guard sysctl(&mib, u_int(mib.count), nil, &len, nil, 0) == 0 else { return nil }
        guard len > 0 else { return [:] }
        len += len / 4 // slack in case the table grows between calls
        var buf = [UInt8](repeating: 0, count: len)
        guard sysctl(&mib, u_int(mib.count), &buf, &len, nil, 0) == 0 else { return nil }

        var result: [UInt32: String] = [:]
        let headerSize = MemoryLayout<rt_msghdr>.size
        buf.withUnsafeBufferPointer { bp in
            guard let base = bp.baseAddress else { return }
            var off = 0
            while off + headerSize <= len {
                let msgLen = Int(UnsafeRawPointer(base + off).loadUnaligned(as: rt_msghdr.self).rtm_msglen)
                guard msgLen > 0, off + msgLen <= len else { break }
                let end = off + msgLen

                // First sockaddr after the header is the IPv4 destination (sockaddr_in).
                let sinOff = off + headerSize
                if sinOff + MemoryLayout<sockaddr_in>.size <= end {
                    let sin = UnsafeRawPointer(base + sinOff).loadUnaligned(as: sockaddr_in.self)
                    // sockaddrs are padded to 4-byte boundaries in routing messages.
                    let sinLen = sin.sin_len == 0 ? 4 : (Int(sin.sin_len) + 3) & ~3
                    let sdlOff = sinOff + sinLen
                    if sin.sin_family == sa_family_t(AF_INET), sdlOff < end,
                       let mac = macFromSockaddrDL(base + sdlOff, limit: end - sdlOff) {
                        result[UInt32(bigEndian: sin.sin_addr.s_addr)] = mac
                    }
                }
                off = end
            }
        }
        return result
    }

    static func arpTableCommand() -> [UInt32: String] {
        var result: [UInt32: String] = [:]
        // Line format: ? (192.168.1.1) at a4:2b:b0:1:2:3 on en0 ifscope [ethernet]
        for line in run("/usr/sbin/arp", ["-an"]).split(separator: "\n") {
            guard let open = line.firstIndex(of: "("), let close = line.firstIndex(of: ")"),
                  let ip = IPv4.parse(line[line.index(after: open)..<close]) else { continue }
            let rest = line[close...].split(separator: " ")
            guard rest.count >= 3, rest[1] == "at" else { continue }
            let mac = rest[2].split(separator: ":").map { $0.count == 1 ? "0\($0)" : String($0) }.joined(separator: ":")
            guard mac.count == 17, mac != "ff:ff:ff:ff:ff:ff", !mac.hasPrefix("01:00:5e") else { continue }
            result[ip] = mac
        }
        return result
    }

    static func defaultGateway() -> UInt32? {
        for line in run("/sbin/route", ["-n", "get", "default"]).split(separator: "\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces) == "gateway" {
                return IPv4.parse(parts[1].trimmingCharacters(in: .whitespaces))
            }
        }
        return nil
    }

    static func reverseDNS(_ ip: UInt32) -> String? {
        var sin = sockaddr_in()
        sin.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        sin.sin_family = sa_family_t(AF_INET)
        sin.sin_addr.s_addr = ip.bigEndian
        var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let rc = withUnsafePointer(to: &sin) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getnameinfo($0, socklen_t(MemoryLayout<sockaddr_in>.size),
                            &buf, socklen_t(buf.count), nil, 0, NI_NAMEREQD)
            }
        }
        guard rc == 0 else { return nil }
        let name = String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return name.hasSuffix(".") ? String(name.dropLast()) : name
    }
}

// MARK: - Scanner

@MainActor
final class ScannerModel: ObservableObject {
    @Published private(set) var hosts: [DiscoveredHost] = []
    @Published private(set) var isScanning = false
    @Published private(set) var progress = 0.0
    @Published private(set) var status = "Ready"
    @Published private(set) var interface: NetworkInterface?

    private var gateway: UInt32?
    private var task: Task<Void, Never>?
    private let maxConcurrentHosts = 24

    func toggle() { isScanning ? stop() : start() }

    func stop() {
        task?.cancel()
        status = "Stopping…"
    }

    func start() {
        guard !isScanning else { return }
        guard let iface = NetworkInterface.primary() else {
            status = "No active IPv4 network connection."
            return
        }
        interface = iface
        hosts = []
        progress = 0
        isScanning = true
        task = Task {
            await run(iface)
            isScanning = false
        }
    }

    private func run(_ iface: NetworkInterface) async {
        // Large subnets (bigger than /22) are limited to this Mac's /24.
        var first = iface.network &+ 1
        var last = iface.broadcast &- 1
        if iface.prefixLength < 22 {
            let base = iface.address & 0xFFFF_FF00
            first = base + 1
            last = base + 254
        }
        guard first <= last else { status = "Subnet too small to scan."; return }

        gateway = await Task.detached { SystemInfo.defaultGateway() }.value
        upsert(iface.address)
        if let i = hosts.firstIndex(where: { $0.isThisMac }) {
            hosts[i].hostname = ProcessInfo.processInfo.hostName
            hosts[i].mac = iface.macAddress
        }

        let targets = Array(first...last).filter { $0 != iface.address }
        status = "Scanning \(targets.count) addresses on \(iface.name)…"
        var done = 0

        await withTaskGroup(of: (UInt32, Double?).self) { group in
            var it = targets.makeIterator()
            for _ in 0..<maxConcurrentHosts {
                guard let t = it.next() else { break }
                group.addTask { (t, await Prober.isAlive(IPv4.string(t))) }
            }
            while let result = await group.next() {
                done += 1
                progress = Double(done) / Double(targets.count)
                if let latency = result.1 { upsert(result.0, latency: latency) }
                if done % 64 == 0 { await mergeARP(first...last) }
                if Task.isCancelled { continue } // drain without adding more work
                if let t = it.next() {
                    group.addTask { (t, await Prober.isAlive(IPv4.string(t))) }
                }
            }
        }

        await mergeARP(first...last)

        status = "Resolving names…"
        let addresses = hosts.filter { $0.hostname == nil }.map(\.address)
        let names = await withTaskGroup(of: (UInt32, String?).self) { group -> [UInt32: String] in
            for a in addresses { group.addTask { (a, SystemInfo.reverseDNS(a)) } }
            var d: [UInt32: String] = [:]
            for await r in group { if let n = r.1 { d[r.0] = n } }
            return d
        }
        for (a, n) in names {
            if let i = hosts.firstIndex(where: { $0.address == a }) { hosts[i].hostname = n }
        }

        progress = 1
        let summary = "Found \(hosts.count) device\(hosts.count == 1 ? "" : "s") on \(iface.cidr)"
        let macsFound = hosts.contains { !$0.isThisMac && $0.mac != nil }
        let note = macsFound ? "" : " — couldn't read the ARP table, so MAC addresses are unavailable"
        status = (Task.isCancelled ? "Stopped. " : "") + summary + note
    }

    private func mergeARP(_ range: ClosedRange<UInt32>) async {
        let table = await Task.detached { SystemInfo.arpTable() }.value
        for (ip, mac) in table where range.contains(ip) {
            upsert(ip, mac: mac)
        }
    }

    private func upsert(_ ip: UInt32, latency: Double? = nil, mac: String? = nil) {
        if let i = hosts.firstIndex(where: { $0.address == ip }) {
            if let latency { hosts[i].latency = latency }
            if let mac { hosts[i].mac = mac }
        } else {
            hosts.append(DiscoveredHost(address: ip, mac: mac, latency: latency,
                                        isThisMac: ip == interface?.address,
                                        isGateway: ip == gateway))
            hosts.sort { $0.address < $1.address }
        }
    }
}
