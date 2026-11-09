import Foundation
#if canImport(Darwin)
import Darwin
#endif

// MARK: - Discovery — SSDP search for Bambu printers on the LAN
//
// Implements findings-network.md §1:
// - M-SEARCH for urn:bambulab-com:device:3dprinter:1 sent to the SSDP
//   multicast group 239.255.255.250:2021 and to the broadcast address
//   255.255.255.255:2021.
// - Replies carry USN: (the serial — used verbatim in MQTT topics),
//   Location: (bare printer IP), DevModel.bambu.com: (model code, "N1" =
//   A1 mini) and DevName.bambu.com: (user-set name). The access code is
//   never broadcast; it is always typed in by the user.
// - Implemented with a plain POSIX UDP socket on a background queue:
//   sending to the multicast group does not require joining it, and the
//   printer answers with a unicast reply to our source port. Manual IP
//   entry in PrinterView remains the guaranteed fallback (iOS multicast
//   entitlement behaviour on sideloaded builds is verified on-device).

enum Discovery {

    /// Runs one 4-second search. Completion fires once on the main queue
    /// with every distinct printer that answered (deduped by serial).
    static func discover(completion: @escaping ([DiscoveredPrinter]) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let found = search(timeout: 4)
            DispatchQueue.main.async { completion(found) }
        }
    }

    private static func search(timeout: TimeInterval) -> [DiscoveredPrinter] {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return [] }
        defer { close(fd) }

        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &yes, socklen_t(MemoryLayout<Int32>.size))
        var ttl: UInt8 = 4
        setsockopt(fd, IPPROTO_IP, IP_MULTICAST_TTL, &ttl, socklen_t(MemoryLayout<UInt8>.size))

        // Bind to an ephemeral port so replies come back to us.
        var local = sockaddr_in()
        local.sin_family = sa_family_t(AF_INET)
        local.sin_port = 0
        local.sin_addr.s_addr = INADDR_ANY
        let bindResult = withUnsafePointer(to: &local) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else { return [] }

        let request = "M-SEARCH * HTTP/1.1\r\n" +
            "HOST: 239.255.255.250:2021\r\n" +
            "MAN: \"ssdp:discover\"\r\n" +
            "MX: 1\r\n" +
            "ST: urn:bambulab-com:device:3dprinter:1\r\n" +
            "\r\n"
        let requestData = [UInt8](request.utf8)

        for target in ["239.255.255.250", "255.255.255.255"] {
            var dest = sockaddr_in()
            dest.sin_family = sa_family_t(AF_INET)
            dest.sin_port = in_port_t(2021).bigEndian
            dest.sin_addr.s_addr = inet_addr(target)
            _ = withUnsafePointer(to: &dest) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { destPtr in
                    requestData.withUnsafeBytes { bytes in
                        sendto(fd, bytes.baseAddress, requestData.count, 0, destPtr,
                               socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
        }

        // Receive until the deadline; each recv waits at most 0.5 s.
        var tv = timeval(tv_sec: 0, tv_usec: 500_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var bySerial: [String: DiscoveredPrinter] = [:]
        let deadline = Date().addingTimeInterval(timeout)
        var buffer = [UInt8](repeating: 0, count: 4096)
        while Date() < deadline {
            var sender = sockaddr_in()
            var senderLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let capacity = buffer.count
            let received = withUnsafeMutablePointer(to: &sender) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { senderPtr in
                    buffer.withUnsafeMutableBytes { bytes in
                        recvfrom(fd, bytes.baseAddress, capacity, 0, senderPtr, &senderLen)
                    }
                }
            }
            guard received > 0 else { continue }
            let text = String(bytes: buffer[0..<received], encoding: .utf8) ?? ""
            if let printer = parseResponse(text, sender: sender) {
                bySerial[printer.serial] = printer
            }
        }
        return bySerial.values.sorted { $0.serial < $1.serial }
    }

    /// Parses one SSDP response / NOTIFY into a DiscoveredPrinter.
    /// Header names are matched case-insensitively by prefix, covering both
    /// the documented "DevModel.bambu.com" form and short variants.
    static func parseResponse(_ text: String, sender: sockaddr_in) -> DiscoveredPrinter? {
        var headers: [String: String] = [:]
        for line in text.components(separatedBy: "\r\n") {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }
        guard let serial = headers["usn"], !serial.isEmpty else { return nil }

        var ip = headers["location"] ?? ""
        // Location is a bare IP in Bambu announcements; strip any URL dressing.
        if ip.contains("://") {
            ip = ip.components(separatedBy: "://").last ?? ip
            ip = ip.components(separatedBy: "/").first ?? ip
            ip = ip.components(separatedBy: ":").first ?? ip
        }
        if ip.isEmpty {
            ip = String(cString: inet_ntoa(sender.sin_addr))
        }

        let model = headers.first { $0.key.hasPrefix("devmodel") }?.value ?? ""
        let name = headers.first { $0.key.hasPrefix("devname") }?.value ?? ""
        return DiscoveredPrinter(serial: serial, ip: ip, model: model, name: name)
    }
}
