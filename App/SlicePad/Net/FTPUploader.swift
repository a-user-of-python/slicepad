import Foundation
import Network

// MARK: - FTPUploader — implicit FTPS upload to the printer's microSD card
//
// Implements findings-network.md §3.1:
// - Implicit TLS on port 990 (encrypted from the first byte — NOT explicit
//   AUTH TLS, NOT SFTP). User "bblp", password = LAN access code.
// - Command order after login matters: TYPE I -> PBSZ 0 -> PROT P.
// - Upload target is /cache/ (Bambu Studio's directory). If CWD cache
//   fails, the upload proceeds at the card root and the step log says so
//   (the MQTT url in PrinterConnection assumes /cache/ — a root upload
//   would need the alternative url dialect noted there).
// - PASV only; the advertised IP in the 227 reply is ignored (it is often
//   bogus) — the data connection goes to the control connection's host.
// - Network.framework cannot reuse the control TLS session on the data
//   connection (no public API for session tickets); a plain fresh TLS data
//   connection is used. Per the findings' dialect notes this is accepted
//   by the A1 mini firmware family; if a future firmware answers
//   "522 session reuse required", that reply is surfaced in the step log.
// - The closing 226 is slow (the printer flushes the file to SD first), so
//   it is awaited with a long transfer timeout, never a command timeout.
// - One file at a time; no resume. A failed upload restarts from byte 0.

final class FTPUploader {

    enum UploadError: LocalizedError {
        case stepFailed(String)
        case timeout(String)
        case connectionFailed(String)

        var errorDescription: String? {
            switch self {
            case .stepFailed(let s): return "FTP step failed: \(s)"
            case .timeout(let s): return "FTP timeout: \(s)"
            case .connectionFailed(let s): return "FTP connection failed: \(s)"
            }
        }
    }

    private var control: NWConnection?
    private var dataConnection: NWConnection?
    private var receiveBuffer = ""
    private var replyWaiter: ((Int, String) -> Void)?
    private var timeoutWork: DispatchWorkItem?
    private var completion: ((Result<Void, Error>, [String]) -> Void)?
    private var steps: [String] = []
    private var finished = false

    /// Uploads `data` as `filename` to the printer. Completion is called
    /// exactly once, on the main queue, with the step log either way.
    func upload(host: String, accessCode: String, filename: String, data: Data,
                completion: @escaping (Result<Void, Error>, [String]) -> Void) {
        self.completion = completion
        steps = []
        finished = false
        receiveBuffer = ""
        step("Connecting to \(host):990 (implicit FTPS) …")

        let conn = makeTLSConnection(host: host, port: 990)
        control = conn
        conn.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.step("TLS ready — waiting for 220 greeting")
                self.receiveControl()
                self.runUpload(host: host, accessCode: accessCode, filename: filename, data: data)
            case .failed(let error):
                self.finish(.failure(UploadError.connectionFailed(error.localizedDescription)))
            default:
                break
            }
        }
        conn.start(queue: .main)
    }

    // MARK: - Upload script (sequential, reply-driven)

    private func runUpload(host: String, accessCode: String, filename: String, data: Data) {
        // Each step: send a command (or none for the greeting), await the
        // expected reply code, then continue. Any mismatch ends the upload.
        awaitReply(timeout: 30, stepName: "greeting") { [weak self] code, line in
            guard let self else { return }
            guard code == 220 else { self.finish(.failure(UploadError.stepFailed("greeting was \(line)"))); return }
            self.step("Greeting OK")
            self.command("USER bblp", expect: 331, stepName: "USER") {
                self.command("PASS \(accessCode)", expect: 230, stepName: "PASS") {
                    self.step("Logged in")
                    self.command("TYPE I", expect: 200, stepName: "TYPE I") {
                        self.command("PBSZ 0", expect: 200, stepName: "PBSZ 0") {
                            self.command("PROT P", expect: 200, stepName: "PROT P") {
                                self.tryEnterCacheThenUpload(host: host, filename: filename, data: data)
                            }
                        }
                    }
                }
            }
        }
    }

    private func tryEnterCacheThenUpload(host: String, filename: String, data: Data) {
        sendCommand("CWD cache")
        awaitReply(timeout: 15, stepName: "CWD cache") { [weak self] code, line in
            guard let self else { return }
            if code == 250 {
                self.step("Directory: /cache/")
            } else {
                self.step("CWD cache refused (\(line)) — uploading to card root instead; note the MQTT url assumes /cache/")
            }
            self.openDataAndStore(host: host, filename: filename, data: data)
        }
    }

    private func openDataAndStore(host: String, filename: String, data: Data) {
        sendCommand("PASV")
        awaitReply(timeout: 15, stepName: "PASV") { [weak self] code, line in
            guard let self else { return }
            guard code == 227, let port = FTPUploader.parsePASVPort(line) else {
                self.finish(.failure(UploadError.stepFailed("PASV reply unusable: \(line)")))
                return
            }
            self.step("Data channel: \(host):\(port) (PASV-advertised IP ignored)")
            let dataConn = self.makeTLSConnection(host: host, port: UInt16(port))
            self.dataConnection = dataConn
            dataConn.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    self.sendCommand("STOR \(filename)")
                    self.awaitReply(timeout: 30, stepName: "STOR") { code, line in
                        guard code == 150 || code == 125 else {
                            self.finish(.failure(UploadError.stepFailed("STOR refused: \(line)")))
                            return
                        }
                        self.step("Sending \(data.count) bytes …")
                        dataConn.send(content: data, completion: .contentProcessed { error in
                            if let error {
                                self.finish(.failure(UploadError.stepFailed("data send: \(error.localizedDescription)")))
                                return
                            }
                            // Closing the data connection signals EOF. The
                            // printer then flushes to SD and only then
                            // sends 226 — allow a long transfer timeout.
                            dataConn.cancel()
                            self.awaitReply(timeout: 180, stepName: "transfer complete (226)") { code, line in
                                guard code == 226 else {
                                    self.finish(.failure(UploadError.stepFailed("expected 226, got: \(line)")))
                                    return
                                }
                                self.step("Transfer complete (226)")
                                self.finish(.success(()))
                            }
                        })
                    }
                case .failed(let error):
                    self.finish(.failure(UploadError.connectionFailed("data channel: \(error.localizedDescription)")))
                default:
                    break
                }
            }
            dataConn.start(queue: .main)
        }
    }

    // MARK: - Control channel plumbing

    private func command(_ text: String, expect expected: Int, stepName: String,
                         then next: @escaping () -> Void) {
        // Never log the PASS command itself (it carries the access code).
        if !text.hasPrefix("PASS") { step("> \(text)") }
        sendCommand(text)
        awaitReply(timeout: 30, stepName: stepName) { [weak self] code, line in
            guard let self else { return }
            guard code == expected else {
                self.finish(.failure(UploadError.stepFailed("\(stepName): expected \(expected), got \(line)")))
                return
            }
            next()
        }
    }

    private func sendCommand(_ text: String) {
        control?.send(content: Data((text + "\r\n").utf8), completion: .contentProcessed { _ in })
    }

    /// Registers a one-shot waiter for the next complete FTP reply.
    /// Multi-line replies ("220-..." ... "220 ...") are folded into one.
    private func awaitReply(timeout: TimeInterval, stepName: String,
                            handler: @escaping (Int, String) -> Void) {
        timeoutWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.finish(.failure(UploadError.timeout(stepName)))
        }
        timeoutWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: work)

        var multilineCode: Int? = nil
        var collected: [String] = []
        replyWaiter = { [weak self] code, line in
            guard let self else { return }
            if line.count > 3, line[line.index(line.startIndex, offsetBy: 3)] == "-" {
                multilineCode = code
                collected.append(line)
                return // keep waiting for the terminating line
            }
            if let open = multilineCode, open != code {
                collected.append(line)
                return
            }
            self.timeoutWork?.cancel()
            self.replyWaiter = nil
            handler(code, (collected + [line]).joined(separator: " "))
        }
        // A reply may already be buffered (pipelined greeting).
        drainBuffer()
    }

    private func receiveControl() {
        control?.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty, let text = String(data: data, encoding: .utf8) {
                self.receiveBuffer += text
                self.drainBuffer()
            }
            if error != nil || isComplete {
                if !self.finished {
                    self.finish(.failure(UploadError.connectionFailed("control channel closed")))
                }
                return
            }
            self.receiveControl()
        }
    }

    private func drainBuffer() {
        while let range = receiveBuffer.range(of: "\r\n") ?? receiveBuffer.range(of: "\n") {
            let line = String(receiveBuffer[..<range.lowerBound])
            receiveBuffer.removeSubrange(...range.upperBound)
            guard line.count >= 3, let code = Int(line.prefix(3)) else { continue }
            replyWaiter?(code, line)
            if finished { return }
        }
    }

    // MARK: - Connection factory / finish

    private func makeTLSConnection(host: String, port: UInt16) -> NWConnection {
        // Same accept-any-cert TLS as the MQTT connection: the printer's
        // cert is self-signed. LAN printer connections only.
        let tlsOptions = NWProtocolTLS.Options()
        sec_protocol_options_set_verify_block(
            tlsOptions.securityProtocolOptions,
            { _, _, complete in complete(true) },
            DispatchQueue.main
        )
        let parameters = NWParameters(tls: tlsOptions, tcp: NWProtocolTCP.Options())
        return NWConnection(host: NWEndpoint.Host(host),
                            port: NWEndpoint.Port(rawValue: port)!,
                            using: parameters)
    }

    private func step(_ line: String) {
        steps.append(line)
    }

    private func finish(_ result: Result<Void, Error>) {
        guard !finished else { return }
        finished = true
        timeoutWork?.cancel()
        replyWaiter = nil
        control?.cancel()
        dataConnection?.cancel()
        control = nil
        dataConnection = nil
        let handler = completion
        completion = nil
        handler?(result, steps)
    }

    /// Parses the port out of a 227 reply: "(h1,h2,h3,h4,p1,p2)".
    static func parsePASVPort(_ line: String) -> Int? {
        guard let open = line.firstIndex(of: "("), let close = line.firstIndex(of: ")"),
              open < close else { return nil }
        let parts = line[line.index(after: open)..<close]
            .split(separator: ",")
            .map { Int($0.trimmingCharacters(in: .whitespaces)) ?? -1 }
        guard parts.count == 6, parts.allSatisfy({ $0 >= 0 }) else { return nil }
        return parts[4] * 256 + parts[5]
    }
}
