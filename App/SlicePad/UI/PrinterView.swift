import SwiftUI

// MARK: - PrinterView
//
// Connection form (IP, serial, access code), live status, AMS lite trays.
// The access code is written to the Keychain on Save and is never shown
// back or stored anywhere else. No Bambu account is used anywhere here.

struct PrinterView: View {
    @EnvironmentObject private var model: AppModel
    @State private var accessCodeInput: String = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                guidanceCard
                connectionForm
                discoverySection
                if let status = model.printerStatus {
                    statusCard(status)
                    amsGrid(status)
                } else if model.isPrinterConnected {
                    Text("Connected — waiting for the first status report…")
                        .foregroundStyle(.secondary)
                }
            }
            .padding()
        }
        .navigationTitle("Printer")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: Guidance

    private var guidanceCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("LAN setup required", systemImage: "wifi")
                .font(.headline)
            Text("Requires LAN Only Mode + Developer Mode enabled on the printer (Settings on the printer). No Bambu account is used.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("Enter the printer's IP address, serial number (exact case) and the 8-character access code shown on the printer's LAN Only screen.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: Connection form

    private var connectionForm: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader("Connection")
            TextField("Printer IP address, e.g. 192.168.1.64", text: $model.printerIP)
                .textFieldStyle(.roundedBorder)
                .keyboardType(.decimalPad)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            TextField("Serial number (exact case)", text: $model.printerSerial)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.characters)
            SecureField(KeychainStore.accessCode() == nil
                        ? "Access code (8 characters)"
                        : "Access code (saved — type to replace)",
                        text: $accessCodeInput)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.characters)

            HStack {
                Button("Save") {
                    model.savePrinterConfig(accessCode: accessCodeInput)
                    accessCodeInput = ""
                }
                .buttonStyle(.bordered)
                Spacer()
                if model.isPrinterConnected {
                    Button("Disconnect", role: .destructive) {
                        model.disconnectPrinter()
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Button("Connect") {
                        model.connectPrinter()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.printerConfigured)
                }
            }
            if !model.printerConfigured {
                Text("Save an access code and fill in IP + serial to connect. If the printer connects but no data arrives, check the serial's letter case; if the connection is refused, check the access code.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Discovery

    private var discoverySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionHeader("Discovery")
                Spacer()
                Button {
                    model.discoverPrinters()
                } label: {
                    HStack {
                        if model.isDiscovering { ProgressView() }
                        Text(model.isDiscovering ? "Searching…" : "Search LAN")
                    }
                }
                .buttonStyle(.bordered)
                .disabled(model.isDiscovering)
            }
            if model.discoveredPrinters.isEmpty {
                Text("Searches for Bambu printers by SSDP. Manual entry above always works, even if discovery finds nothing.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.discoveredPrinters) { found in
                    Button {
                        model.applyDiscovered(found)
                    } label: {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(found.name.isEmpty ? found.serial : found.name)
                                    .font(.callout.bold())
                                Text("\(found.serial) · \(found.ip)\(found.model.isEmpty ? "" : " · \(found.model)")")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text("Use")
                                .font(.callout)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Divider()
                }
            }
        }
    }

    // MARK: Live status

    private func statusCard(_ status: PrinterStatus) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader("Status")
            HStack(spacing: 8) {
                Circle()
                    .fill(status.state == "RUNNING" ? Color.green : Color.blue)
                    .frame(width: 10, height: 10)
                Text(status.state)
                    .font(.title3.bold())
                if let file = status.currentFile {
                    Text(file)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            HStack(spacing: 24) {
                Label(String(format: "Nozzle %.0f / %.0f °C", status.nozzleTemp, status.targetNozzle),
                      systemImage: "thermometer.medium")
                Label(String(format: "Bed %.0f / %.0f °C", status.bedTemp, status.targetBed),
                      systemImage: "square.grid.2x2")
            }
            .font(.callout)
            if let progress = status.progress {
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: Double(progress), total: 100)
                    Text("Progress \(progress)%")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if status.isExternalSpoolActive {
                Text("External spool is the active filament source.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: AMS lite trays

    private func amsGrid(_ status: PrinterStatus) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader("AMS lite")
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                ForEach(status.trays) { tray in
                    trayCard(tray)
                }
            }
            Text("Remaining filament is not shown: the AMS lite does not report it.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func trayCard(_ tray: AMSTray) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Slot \(tray.slot + 1)")
                    .font(.headline)
                if tray.isActive {
                    Text("LOADED")
                        .font(.caption2.bold())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.green.opacity(0.25), in: Capsule())
                }
                Spacer()
                RoundedRectangle(cornerRadius: 4)
                    .fill(tray.present ? Color(hexString: tray.colorHex) : Color.clear)
                    .frame(width: 26, height: 26)
                    .overlay {
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(Color.secondary.opacity(0.5))
                    }
            }
            if tray.present {
                Text(tray.type.isEmpty ? "Filament" : tray.type)
                    .font(.callout.bold())
                Text(tray.colorHex)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                if !tray.trayInfoIdx.isEmpty {
                    Text("Preset \(tray.trayInfoIdx)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Text("Remaining")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("—") // AMS lite does not report remaining %
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("Empty")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text("No filament detected in this slot.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: - Colour helper

extension Color {
    /// Colour from "#RRGGBB" (alpha ignored — tray colours are opaque).
    init(hexString: String) {
        var hex = hexString
        if hex.hasPrefix("#") { hex.removeFirst() }
        let value = UInt64(hex, radix: 16) ?? 0
        let r = Double((value >> 16) & 0xFF) / 255
        let g = Double((value >> 8) & 0xFF) / 255
        let b = Double(value & 0xFF) / 255
        self.init(red: r, green: g, blue: b)
    }
}
