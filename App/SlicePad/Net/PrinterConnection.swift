import Foundation
import Network

// MARK: - PrinterConnection — minimal MQTT 3.1.1 client for a Bambu printer
//
// Implements findings-network.md §2 and §6:
// - Broker is the printer itself: mqtts://<ip>:8883, user "bblp",
//   password = LAN access code, topics device/<serial>/report (subscribe)
//   and device/<serial>/request (publish).
// - The printer's certificate is self-signed (Bambu private CA), so TLS
//   verification is disabled for THIS LAN connection only, via a verify
//   block that accepts any cert. Never reuse these parameters elsewhere.
// - On connect: SUBSCRIBE, then publish get_version + pushall to baseline.
//   A1-class printers then send incremental diffs, so every report is
//   DEEP-MERGED into a stored dictionary (arrays/scalars replace wholesale —
//   in particular a `tray` array replaces the previous one entirely).
// - Commands are QoS 1 (the printer ignores QoS 0 while busy). Incoming
//   QoS 1 publishes are PUBACKed. PINGREQ every 45 s (keepalive 60).
// - There are NO command acknowledgements from the printer: a successful
//   project_file publish is reported as "command sent — watch the printer",
//   and launch confirmation comes only from watching the report stream.

final class PrinterConnection {

    // MARK: Callbacks (always invoked on the main queue)

    var onStatus: ((PrinterStatus) -> Void)?
    var onConnectionChange: ((Bool) -> Void)?
    var onLog: ((String) -> Void)?

    private(set) var isConnected = false

    private var connection: NWConnection?
    private var serial: String = ""
    private var buffer = Data()
    private var nextPacketId: UInt16 = 1
    private var pingTimer: Timer?
    private var didSubscribe = false

    /// Deep-merged report state. Top level holds "print", "info", ...
    private var mergedState: [String: Any] = [:]

    // MARK: - Connect / disconnect

    func connect(host: String, serial: String, accessCode: String) {
        disconnect()
        self.serial = serial
        buffer.removeAll()
        mergedState.removeAll()
        didSubscribe = false

        // TLS with verification disabled for this printer LAN connection
        // only (self-signed Bambu CA cert, CN = serial, no SAN).
        let tlsOptions = NWProtocolTLS.Options()
        sec_protocol_options_set_verify_block(
            tlsOptions.securityProtocolOptions,
            { _, _, complete in complete(true) },
            DispatchQueue.main
        )
        let parameters = NWParameters(tls: tlsOptions, tcp: NWProtocolTCP.Options())

        guard let port = NWEndpoint.Port(rawValue: 8883) else { return }
        let conn = NWConnection(host: NWEndpoint.Host(host), port: port, using: parameters)
        connection = conn

        conn.stateUpdateHandler = { [weak self] (state: NWConnection.State) in
            guard let self else { return }
            switch state {
            case .ready:
                self.log("TCP/TLS ready — sending MQTT CONNECT")
                self.sendConnect(accessCode: accessCode)
                self.receiveMore()
            case .failed(let error):
                self.log("Connection failed: \(error.localizedDescription)")
                self.setConnected(false)
            case .cancelled:
                self.setConnected(false)
            default:
                break
            }
        }
        conn.start(queue: DispatchQueue.main)
        log("Connecting to \(host):8883 …")
    }

    func disconnect() {
        pingTimer?.invalidate()
        pingTimer = nil
        connection?.cancel()
        connection = nil
        if isConnected { setConnected(false) }
    }

    // MARK: - Print start (project_file)

    /// Publishes the project_file command for a file already uploaded to
    /// /cache/ via FTPUploader.
    ///
    /// URL dialect — FIRST choice implemented (findings-network §3.2 / §6):
    /// upload to /cache/ + url "file:///sdcard/cache/<filename>".
    /// Alternatives attested on other firmware, to try on-device if the
    /// first choice is silently ignored (there is no error, no ack):
    ///   - root upload + url "ftp:///<filename>"
    ///   - root upload + url "ftp://<filename>" and "file": "<filename>"
    ///   - url "file:///sdcard/<filename>" (root upload)
    /// Never "file:///mnt/sdcard/…" on A1 (X1 flavour).
    ///
    /// ams_mapping: plain per-filament array [slot] plus the ams_mapping2
    /// object form generated from the same table — the safest documented
    /// encoding (findings §3.2). slotIndex is 0-based (UI slot − 1).
    func startPrint(filename: String, slotIndex: Int, useAMS: Bool) {
        let slot = min(max(slotIndex, 0), 3)
        let printDict: [String: Any] = [
            "sequence_id": "0",
            "command": "project_file",
            "param": "Metadata/plate_1.gcode",
            "project_id": "0",
            "profile_id": "0",
            "task_id": "0",
            "subtask_id": "0",
            "subtask_name": filename,
            "file": filename,
            "url": "file:///sdcard/cache/\(filename)",
            "md5": "",
            "timelapse": false,
            "bed_type": "auto",
            "bed_levelling": true,
            "flow_cali": true,
            "vibration_cali": true,
            "layer_inspect": false,
            "ams_mapping": useAMS ? [slot] : [],
            "ams_mapping2": useAMS ? [["ams_id": 0, "slot_id": slot]] : [],
            "use_ams": useAMS
        ]
        publishJSON(["print": printDict])
        log("project_file sent for \(filename) (AMS slot \(slot + 1)) — command sent, watch the printer (no acknowledgement exists)")
    }

    // MARK: - MQTT wire encoding

    private func sendConnect(accessCode: String) {
        // Variable header: "MQTT", level 4, flags username|password|clean
        // session = 0xC2, keepalive 60 s.
        var variableHeader = Data()
        variableHeader.append(PrinterConnection.utf8String("MQTT"))
        variableHeader.append(4)      // protocol level 3.1.1
        variableHeader.append(0xC2)   // connect flags
        variableHeader.append(0)      // keepalive high byte
        variableHeader.append(60)     // keepalive low byte

        let clientId = "slicepad-\(Int.random(in: 100000...999999))"
        var payload = Data()
        payload.append(PrinterConnection.utf8String(clientId))
        payload.append(PrinterConnection.utf8String("bblp"))
        payload.append(PrinterConnection.utf8String(accessCode))

        var packet = Data([0x10])
        packet.append(PrinterConnection.remainingLength(variableHeader.count + payload.count))
        packet.append(variableHeader)
        packet.append(payload)
        send(packet)
    }

    private func sendSubscribe() {
        let topic = "device/\(serial)/report"
        let packetId = allocatePacketId()
        var body = Data()
        body.append(UInt8(packetId >> 8))
        body.append(UInt8(packetId & 0xFF))
        body.append(PrinterConnection.utf8String(topic))
        body.append(1) // requested QoS 1
        var packet = Data([0x82])
        packet.append(PrinterConnection.remainingLength(body.count))
        packet.append(body)
        send(packet)
        log("Subscribed to \(topic)")
    }

    private func publishJSON(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else {
            log("Failed to encode MQTT JSON")
            return
        }
        publish(topic: "device/\(serial)/request", payload: data)
    }

    private func publish(topic: String, payload: Data) {
        let packetId = allocatePacketId()
        var body = Data()
        body.append(PrinterConnection.utf8String(topic))
        body.append(UInt8(packetId >> 8))
        body.append(UInt8(packetId & 0xFF))
        body.append(payload)
        var packet = Data([0x32]) // PUBLISH, QoS 1
        packet.append(PrinterConnection.remainingLength(body.count))
        packet.append(body)
        send(packet)
    }

    private func sendPubAck(packetId: UInt16) {
        send(Data([0x40, 0x02, UInt8(packetId >> 8), UInt8(packetId & 0xFF)]))
    }

    private func sendPing() {
        send(Data([0xC0, 0x00]))
    }

    private func allocatePacketId() -> UInt16 {
        let id = nextPacketId
        nextPacketId = nextPacketId &+ 1
        if nextPacketId == 0 { nextPacketId = 1 }
        return id
    }

    private func send(_ data: Data) {
        connection?.send(content: data, completion: .contentProcessed { [weak self] error in
            if let error { self?.log("Send error: \(error.localizedDescription)") }
        })
    }

    // MARK: - Receiving / packet parsing

    private func receiveMore() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.buffer.append(data)
                self.parseBuffer()
            }
            if let error {
                self.log("Receive error: \(error.localizedDescription)")
                self.setConnected(false)
                return
            }
            if isComplete {
                self.log("Printer closed the connection")
                self.setConnected(false)
                return
            }
            self.receiveMore()
        }
    }

    /// Parses as many complete MQTT packets as the buffer currently holds.
    private func parseBuffer() {
        while buffer.count >= 2 {
            let firstByte = buffer[buffer.startIndex]
            // Decode variable-byte remaining length.
            var multiplier = 1
            var remaining = 0
            var lengthBytes = 0
            var decoded = false
            var idx = buffer.startIndex + 1
            while idx < buffer.endIndex && lengthBytes < 4 {
                let b = buffer[idx]
                remaining += Int(b & 0x7F) * multiplier
                lengthBytes += 1
                idx += 1
                if b & 0x80 == 0 { decoded = true; break }
                multiplier *= 128
            }
            guard decoded else { return } // need more bytes
            let headerSize = 1 + lengthBytes
            guard buffer.count >= headerSize + remaining else { return }
            let packetStart = buffer.startIndex + headerSize
            let packetEnd = packetStart + remaining
            let body = Data(buffer[packetStart..<packetEnd])
            buffer.removeSubrange(buffer.startIndex..<packetEnd)
            handlePacket(type: firstByte >> 4, flags: firstByte & 0x0F, body: body)
        }
    }

    private func handlePacket(type: UInt8, flags: UInt8, body: Data) {
        switch type {
        case 2: // CONNACK
            let returnCode = body.count >= 2 ? body[body.startIndex + 1] : 0
            if returnCode == 0 {
                log("MQTT connected")
                setConnected(true)
                sendSubscribe()
                // Baseline requests (exact JSON per findings-network §2.2/§6).
                publishJSON(["info": ["sequence_id": "0", "command": "get_version"]])
                publishJSON(["pushing": ["sequence_id": "0", "command": "pushall",
                                          "version": 1, "push_target": 1]])
                startPingTimer()
            } else {
                log("MQTT refused (CONNACK \(returnCode)) — check the access code")
                setConnected(false)
            }
        case 3: // PUBLISH
            let qos = (flags >> 1) & 0x03
            guard body.count >= 2 else { return }
            let topicLength = Int(body[body.startIndex]) << 8 | Int(body[body.startIndex + 1])
            var offset = body.startIndex + 2 + topicLength
            guard offset <= body.endIndex else { return }
            if qos > 0 {
                guard offset + 2 <= body.endIndex else { return }
                let packetId = UInt16(body[offset]) << 8 | UInt16(body[offset + 1])
                offset += 2
                if qos == 1 { sendPubAck(packetId: packetId) }
            }
            let payload = Data(body[offset..<body.endIndex])
            handleReport(payload: payload)
        case 4, 9, 13: // PUBACK, SUBACK, PINGRESP — nothing to do
            break
        default:
            break
        }
    }

    private func handleReport(payload: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: payload),
              let dict = object as? [String: Any] else { return }
        mergedState = PrinterConnection.deepMerge(mergedState, dict)
        if dict["print"] != nil || mergedState["print"] != nil {
            onStatus?(PrinterConnection.extractStatus(from: mergedState))
        }
    }

    // MARK: - State extraction

    /// Deep-merge: dictionaries merge recursively; arrays and scalars
    /// replace wholesale (a `tray` array is a complete replacement block —
    /// element-wise merging would leave stale trays behind).
    static func deepMerge(_ base: [String: Any], _ overlay: [String: Any]) -> [String: Any] {
        var out = base
        for (key, value) in overlay {
            if let baseDict = out[key] as? [String: Any],
               let overlayDict = value as? [String: Any] {
                out[key] = deepMerge(baseDict, overlayDict)
            } else {
                out[key] = value
            }
        }
        return out
    }

    static func extractStatus(from merged: [String: Any]) -> PrinterStatus {
        var status = PrinterStatus()
        guard let print = merged["print"] as? [String: Any] else { return status }

        status.state = print["gcode_state"] as? String ?? "—"
        status.nozzleTemp = asDouble(print["nozzle_temper"])
        status.bedTemp = asDouble(print["bed_temper"])
        status.targetNozzle = asDouble(print["nozzle_target_temper"])
        status.targetBed = asDouble(print["bed_target_temper"])
        if print["mc_percent"] != nil { status.progress = asInt(print["mc_percent"]) }
        if let name = print["subtask_name"] as? String, !name.isEmpty {
            status.currentFile = name
        } else if let file = print["gcode_file"] as? String, !file.isEmpty {
            status.currentFile = file
        }

        // AMS: print.ams.ams[0].tray[0..3], tray_exist_bits is a HEX string,
        // tray_now is a string in some firmware, an int in others.
        if let ams = print["ams"] as? [String: Any] {
            status.trayNow = asInt(ams["tray_now"], default: 255)
            let existBits: Int
            if let hex = ams["tray_exist_bits"] as? String {
                existBits = Int(hex, radix: 16) ?? 0
            } else if ams["tray_exist_bits"] != nil {
                existBits = asInt(ams["tray_exist_bits"])
            } else {
                existBits = -1 // unknown — fall back to tray contents below
            }
            var trayDicts: [[String: Any]] = []
            if let units = ams["ams"] as? [[String: Any]], let first = units.first,
               let trays = first["tray"] as? [[String: Any]] {
                trayDicts = trays
            }
            status.trays = (0..<4).map { slot in
                let tray: [String: Any] = slot < trayDicts.count ? trayDicts[slot] : [:]
                let type = tray["tray_type"] as? String ?? ""
                let present: Bool
                if existBits >= 0 {
                    present = (existBits >> slot) & 1 == 1
                } else {
                    present = !type.isEmpty
                }
                return AMSTray(
                    slot: slot,
                    present: present,
                    type: type,
                    colorHex: normaliseColor(tray["tray_color"] as? String ?? ""),
                    trayInfoIdx: tray["tray_info_idx"] as? String ?? "",
                    isActive: status.trayNow == slot
                )
            }
        }
        return status
    }

    /// RRGGBBAA -> "#RRGGBB". Empty/invalid -> "#000000".
    static func normaliseColor(_ raw: String) -> String {
        let hex = raw.hasPrefix("#") ? String(raw.dropFirst()) : raw
        guard hex.count >= 6 else { return "#000000" }
        return "#" + String(hex.prefix(6)).uppercased()
    }

    static func asDouble(_ value: Any?) -> Double {
        if let n = value as? NSNumber { return n.doubleValue }
        if let s = value as? String { return Double(s) ?? 0 }
        return 0
    }

    static func asInt(_ value: Any?, default fallback: Int = 0) -> Int {
        if let n = value as? NSNumber { return n.intValue }
        if let s = value as? String { return Int(s) ?? fallback }
        return fallback
    }

    // MARK: - Helpers

    private func startPingTimer() {
        pingTimer?.invalidate()
        pingTimer = Timer.scheduledTimer(withTimeInterval: 45, repeats: true) { [weak self] _ in
            self?.sendPing()
        }
    }

    private func setConnected(_ value: Bool) {
        if isConnected != value {
            isConnected = value
            onConnectionChange?(value)
        }
        if !value {
            pingTimer?.invalidate()
            pingTimer = nil
        }
    }

    private func log(_ line: String) {
        onLog?(line)
    }

    /// MQTT UTF-8 string: 2-byte big-endian length + bytes. Also used for
    /// binary password fields (same framing).
    static func utf8String(_ string: String) -> Data {
        let bytes = Data(string.utf8)
        var out = Data()
        out.append(UInt8(bytes.count >> 8))
        out.append(UInt8(bytes.count & 0xFF))
        out.append(bytes)
        return out
    }

    static func remainingLength(_ length: Int) -> Data {
        var out = Data()
        var value = length
        repeat {
            var byte = UInt8(value & 0x7F)
            value >>= 7
            if value > 0 { byte |= 0x80 }
            out.append(byte)
        } while value > 0
        return out
    }
}
