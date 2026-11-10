import SwiftUI
import UniformTypeIdentifiers
import UIKit

// MARK: - ContentView
//
// iPad layout: preview on the left (mesh / toolpath with a layer slider),
// control panel on the right (filament + AMS slot, settings summary, slice,
// result card, export, send-to-printer).

struct ContentView: View {
    @EnvironmentObject private var model: AppModel

    @State private var showingImporter = false
    @State private var showingFileList = false
    @State private var displayMode: PreviewDisplayMode = .mesh
    @State private var layerZ: Double = 0

    private var maxZ: Double { model.result?.maxZ ?? 180 }

    var body: some View {
        NavigationStack {
            HStack(spacing: 0) {
                previewColumn
                Divider()
                controlPanel
                    .frame(width: 380)
            }
            .navigationTitle("SlicePad — A1 mini")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingFileList = true
                    } label: {
                        Label("Open STL", systemImage: "folder")
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingImporter = true
                    } label: {
                        Label("System File Picker", systemImage: "square.and.arrow.down")
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    NavigationLink {
                        PrinterView()
                    } label: {
                        Label("Printer", systemImage: "printer")
                    }
                }
            }
        }
        .sheet(isPresented: $showingFileList) {
            STLFileListView()
        }
        .fileImporter(isPresented: $showingImporter,
                      allowedContentTypes: [UTType(filenameExtension: "stl") ?? .item, .item],
                      allowsMultipleSelection: false) { outcome in
            if case .success(let urls) = outcome, let url = urls.first,
               url.pathExtension.lowercased() == "stl" {
                model.importSTL(from: url)
            }
        }
        .fileExporter(isPresented: $model.showingExporter,
                      document: model.exportDocument,
                      contentType: .item,
                      defaultFilename: model.exportFilename) { _ in }
        .sheet(isPresented: $model.showingShare) {
            ShareSheet(items: model.shareItems)
        }
        .onChange(of: model.result?.layerCount) { _ in
            // Start the layer slider at the top layer (show everything).
            layerZ = model.result?.maxZ ?? 0
            if model.result != nil { displayMode = .toolpath }
        }
    }

    // MARK: Left — preview

    private var previewColumn: some View {
        VStack(spacing: 8) {
            MetalPreview(mesh: model.mesh,
                         previewPaths: model.result?.preview ?? [],
                         displayMode: displayMode,
                         layerZ: layerZ)
                .background(Color(white: 0.08))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay {
                    if model.mesh == nil {
                        Text("Open an STL file to preview it here.")
                            .foregroundStyle(.secondary)
                    }
                }

            Picker("Preview", selection: $displayMode) {
                Text("Mesh").tag(PreviewDisplayMode.mesh)
                Text("Toolpath").tag(PreviewDisplayMode.toolpath)
                Text("Both").tag(PreviewDisplayMode.both)
            }
            .pickerStyle(.segmented)

            if model.result != nil {
                HStack {
                    Text("Layer up to")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Slider(value: $layerZ, in: 0...max(0.1, maxZ), step: 0.2)
                    Text(String(format: "%.1f mm", layerZ))
                        .font(.caption.monospacedDigit())
                        .frame(width: 64, alignment: .trailing)
                }
            }

            Text(model.statusText)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding()
    }

    // MARK: Right — control panel

    private var controlPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                filamentSection
                settingsSection
                sliceSection
                if let result = model.result {
                    resultCard(result)
                }
                exportSection
                sendSection
                howToSection
                logSection
            }
            .padding()
        }
    }

    private var filamentSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader("Filament")
            Picker("Preset", selection: $model.presetChoice) {
                ForEach(AppModel.PresetChoice.allCases) { choice in
                    Text(choice.displayName).tag(choice)
                }
            }
            .pickerStyle(.menu)

            // AMS slot picker: UI slots 1-4 map to Core slotIndex 0-3
            // (the G-code M620 S value is slot - 1).
            Picker("AMS lite slot", selection: Binding(
                get: { model.settings.slotIndex + 1 },
                set: { model.settings.slotIndex = $0 - 1 }
            )) {
                ForEach(1...4, id: \.self) { slot in
                    Text(slotLabel(slot)).tag(slot)
                }
            }
            .pickerStyle(.segmented)

            if let status = model.printerStatus {
                let slot = model.settings.slotIndex
                if slot >= 0, slot < status.trays.count, !status.trays[slot].present {
                    Label("Slot \(slot + 1) appears empty on the printer.",
                          systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            } else {
                Text("Connect to the printer to see which AMS lite slots are loaded.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// "1 · PLA" style label, annotated with live tray info when connected.
    private func slotLabel(_ slot: Int) -> String {
        guard let status = model.printerStatus,
              status.trays.indices.contains(slot - 1) else {
            return "\(slot)"
        }
        let tray = status.trays[slot - 1]
        guard tray.present else { return "\(slot) · empty" }
        return tray.type.isEmpty ? "\(slot)" : "\(slot) · \(tray.type)"
    }

    private var settingsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader("Settings")
            Text("Layer \(String(format: "%.2f", model.settings.layerHeight)) mm · "
                 + "\(model.settings.wallCount) walls · "
                 + "infill \(Int(model.settings.infillPercent))% · "
                 + "brim \(String(format: "%.0f", model.settings.brimWidth)) mm · "
                 + "skirt \(model.settings.skirtLoops)")
                .font(.callout)
                .foregroundStyle(.secondary)
            NavigationLink {
                SettingsView()
            } label: {
                Label("All print settings", systemImage: "slider.horizontal.3")
            }
        }
    }

    private var sliceSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                model.slice()
            } label: {
                HStack {
                    if model.isSlicing { ProgressView() }
                    Text(model.isSlicing ? "Slicing…" : "Slice")
                        .font(.headline)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(model.mesh == nil || model.isSlicing)
        }
    }

    private func resultCard(_ result: SliceResult) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionHeader("Result")
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(AppModel.formatDuration(result.estimatedSeconds))
                    .font(.system(size: 44, weight: .bold, design: .rounded))
                    .monospacedDigit()
                Text("Estimate")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(String(format: "Filament %.1f g · %.2f m",
                        result.filamentUsedGrams, result.filamentUsedMM / 1000))
            Text("\(result.layerCount) layers · max Z \(String(format: "%.1f", result.maxZ)) mm")
                .foregroundStyle(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
    }

    private var exportSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader("Export")
            Button {
                model.shareExports()
            } label: {
                Label("Share .gcode.3mf + .gcode", systemImage: "square.and.arrow.up")
            }
            .disabled(model.result == nil)
            HStack {
                Button("Save .gcode.3mf") { model.prepareFileExport(kind: .threeMF) }
                Button("Save .gcode") { model.prepareFileExport(kind: .gcode) }
            }
            .buttonStyle(.bordered)
            .disabled(model.result == nil)
            Text("Output is a .gcode.3mf for AMS use. Plain .gcode export works only with the external spool.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var sendSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader("Printer")
            Button {
                model.sendToPrinter()
            } label: {
                HStack {
                    if model.isSending { ProgressView() }
                    Text("Send to Printer")
                        .font(.headline)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.green)
            .controlSize(.large)
            .disabled(!model.canSendToPrinter)
            if !model.printerConfigured {
                Text("Add the printer IP, serial and access code (Printer screen) to enable sending.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                Circle()
                    .fill(model.isPrinterConnected ? Color.green : Color.gray)
                    .frame(width: 9, height: 9)
                Text(model.isPrinterConnected
                     ? "Connected — \(model.printerStatus?.state ?? "")"
                     : "Not connected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var howToSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionHeader("Printing from SD card")
            Text("Copy the .gcode.3mf file to the root of the printer's microSD card (not inside a folder), then select it on the printer: Print Files → your file → Start Printing.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Plain .gcode: external spool only — no AMS, start from the printer screen.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var logSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionHeader("Log")
            ForEach(Array(model.logLines.suffix(30).enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

// MARK: - Small shared pieces

struct SectionHeader: View {
    let title: String
    init(_ title: String) { self.title = title }
    var body: some View {
        Text(title)
            .font(.headline)
    }
}

/// UIActivityViewController wrapper for the share sheet.
struct ShareSheet: UIViewControllerRepresentable {
    var items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
