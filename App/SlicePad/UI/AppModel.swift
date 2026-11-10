import Foundation
import SwiftUI
import UniformTypeIdentifiers

// MARK: - AppModel
//
// Central state for SlicePad. Core (STL loading, slicing, 3MF packaging)
// is pure Swift value types, so slicing runs on a detached background task
// and results are published back on the main actor.
//
// Persistence: non-secret slice settings + printer IP/serial in
// UserDefaults; the printer access code ONLY in the Keychain
// (KeychainStore). Nothing here ever writes the access code to defaults.

@MainActor
final class AppModel: ObservableObject {

    // MARK: Model & slicing

    @Published var mesh: Mesh?
    @Published var result: SliceResult?
    @Published var isSlicing = false
    @Published var statusText = "Open an STL file to begin."
    @Published var logLines: [String] = []

    @Published var settings: SliceSettings {
        didSet { persistSettings() }
    }

    // MARK: Filament preset choice

    enum PresetChoice: String, CaseIterable, Identifiable {
        case bambuPLA
        case genericPLA
        case bambuPETG

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .bambuPLA: return "Bambu PLA Basic"
            case .genericPLA: return "Generic PLA"
            case .bambuPETG: return "Bambu PETG Basic"
            }
        }

        var corePreset: FilamentPreset {
            switch self {
            case .bambuPLA: return FilamentPresets.bambuPLABasic
            case .genericPLA: return FilamentPresets.genericPLA
            case .bambuPETG: return FilamentPresets.bambuPETGBasic
            }
        }

        /// Fallback display values (findings-flow.md / findings-machine.md
        /// §5.5), used only when the preset's own values can't be read.
        var fallbackNozzleTemp: Double { self == .bambuPETG ? 250 : 220 }
        var fallbackBedTemp: Double { self == .bambuPETG ? 70 : 65 }
        var fallbackFlowRatio: Double { self == .bambuPETG ? 0.94 : 0.98 }
        var fallbackVolumetricCap: Double {
            switch self {
            case .bambuPLA: return 21
            case .genericPLA: return 12
            case .bambuPETG: return 13
            }
        }
    }

    @Published var presetChoice: PresetChoice = .bambuPLA {
        didSet {
            settings.preset = presetChoice.corePreset
            refreshPresetDerivedValues()
            UserDefaults.standard.set(presetChoice.rawValue, forKey: Keys.presetChoice)
        }
    }

    /// Editable filament values. Initialised from the chosen preset,
    /// editable in SettingsView, persisted in UserDefaults. At slice time
    /// they are applied to the Core settings as overrides
    /// (SliceSettings.nozzleTempOverride etc.), which Core prefers over
    /// the preset everywhere (templates, clamp, E values, metadata).
    @Published var nozzleTemp: Double = 220
    @Published var bedTemp: Double = 65
    @Published var flowRatio: Double = 0.98
    /// Display-only: the preset's volumetric cap (mm³/s). Core enforces
    /// the cap inside the preset when slicing.
    @Published private(set) var volumetricCap: Double = 21

    // MARK: Printer

    @Published var printerIP: String = "" {
        didSet { UserDefaults.standard.set(printerIP, forKey: Keys.printerIP) }
    }
    @Published var printerSerial: String = "" {
        didSet { UserDefaults.standard.set(printerSerial, forKey: Keys.printerSerial) }
    }
    @Published var isPrinterConnected = false
    @Published var printerStatus: PrinterStatus?
    @Published var discoveredPrinters: [DiscoveredPrinter] = []
    @Published var isDiscovering = false
    @Published var isSending = false

    let printer = PrinterConnection()
    private let uploader = FTPUploader()

    var printerConfigured: Bool {
        !printerIP.isEmpty && !printerSerial.isEmpty && KeychainStore.accessCode() != nil
    }

    var canSendToPrinter: Bool {
        result != nil && printerConfigured && !isSending
    }

    // MARK: Export state (driven by ContentView)

    @Published var shareItems: [Any] = []
    @Published var showingShare = false
    @Published var exportDocument: ExportDocument?
    @Published var exportFilename = "model.gcode.3mf"
    @Published var showingExporter = false

    // MARK: Bundle resources

    /// G-code templates loaded from bundle resources (start_gcode.txt …).
    let templates: TemplateSet
    /// Raw A1 mini project_settings.config content (Studio-generated,
    /// golden-based) — patched per effective settings at packaging time.
    let projectSettingsJSON: String

    // MARK: Init

    private enum Keys {
        static let presetChoice = "presetChoice"
        static let printerIP = "printerIP"
        static let printerSerial = "printerSerial"
        static let nozzleTemp = "nozzleTempOverride"
        static let bedTemp = "bedTempOverride"
        static let flowRatio = "flowRatioOverride"
        static let settingsPrefix = "setting."
    }

    init() {
        templates = AppModel.loadTemplates()
        projectSettingsJSON = AppModel.loadProjectSettings()

        var initial = SliceSettings()
        // Restore persisted settings onto the defaults.
        let d = UserDefaults.standard
        func dbl(_ key: String) -> Double? {
            d.object(forKey: Keys.settingsPrefix + key) as? Double
        }
        func int(_ key: String) -> Int? {
            d.object(forKey: Keys.settingsPrefix + key) as? Int
        }
        if let v = dbl("layerHeight") { initial.layerHeight = v }
        if let v = dbl("firstLayerHeight") { initial.firstLayerHeight = v }
        if let v = dbl("lineWidth") { initial.lineWidth = v }
        if let v = dbl("innerLineWidth") { initial.innerLineWidth = v }
        if let v = int("wallCount") { initial.wallCount = v }
        if let v = int("topLayers") { initial.topLayers = v }
        if let v = int("bottomLayers") { initial.bottomLayers = v }
        if let v = dbl("infillPercent") { initial.infillPercent = v }
        if let v = dbl("outerWallSpeed") { initial.outerWallSpeed = v }
        if let v = dbl("innerWallSpeed") { initial.innerWallSpeed = v }
        if let v = dbl("infillSpeed") { initial.infillSpeed = v }
        if let v = dbl("solidInfillSpeed") { initial.solidInfillSpeed = v }
        if let v = dbl("topSurfaceSpeed") { initial.topSurfaceSpeed = v }
        if let v = dbl("firstLayerSpeed") { initial.firstLayerSpeed = v }
        if let v = dbl("travelSpeed") { initial.travelSpeed = v }
        if let v = dbl("retractionLength") { initial.retractionLength = v }
        if let v = dbl("retractionSpeed") { initial.retractionSpeed = v }
        if let v = int("skirtLoops") { initial.skirtLoops = v }
        if let v = dbl("brimWidth") { initial.brimWidth = v }
        if let v = int("slotIndex") { initial.slotIndex = v }

        let savedChoice = PresetChoice(rawValue: d.string(forKey: Keys.presetChoice) ?? "") ?? .bambuPLA
        initial.preset = savedChoice.corePreset
        settings = initial
        presetChoice = savedChoice

        printerIP = d.string(forKey: Keys.printerIP) ?? ""
        printerSerial = d.string(forKey: Keys.printerSerial) ?? ""

        if let v = d.object(forKey: Keys.nozzleTemp) as? Double { nozzleTemp = v }
        if let v = d.object(forKey: Keys.bedTemp) as? Double { bedTemp = v }
        if let v = d.object(forKey: Keys.flowRatio) as? Double { flowRatio = v }
        refreshPresetDerivedValues(applyStoredOverrides: true)

        printer.onLog = { [weak self] line in self?.appendLog(line) }
        printer.onStatus = { [weak self] status in self?.printerStatus = status }
        printer.onConnectionChange = { [weak self] connected in
            self?.isPrinterConnected = connected
            self?.appendLog(connected ? "Printer connected." : "Printer disconnected.")
        }
    }

    private func persistSettings() {
        let d = UserDefaults.standard
        let p = Keys.settingsPrefix
        d.set(settings.layerHeight, forKey: p + "layerHeight")
        d.set(settings.firstLayerHeight, forKey: p + "firstLayerHeight")
        d.set(settings.lineWidth, forKey: p + "lineWidth")
        d.set(settings.innerLineWidth, forKey: p + "innerLineWidth")
        d.set(settings.wallCount, forKey: p + "wallCount")
        d.set(settings.topLayers, forKey: p + "topLayers")
        d.set(settings.bottomLayers, forKey: p + "bottomLayers")
        d.set(settings.infillPercent, forKey: p + "infillPercent")
        d.set(settings.outerWallSpeed, forKey: p + "outerWallSpeed")
        d.set(settings.innerWallSpeed, forKey: p + "innerWallSpeed")
        d.set(settings.infillSpeed, forKey: p + "infillSpeed")
        d.set(settings.solidInfillSpeed, forKey: p + "solidInfillSpeed")
        d.set(settings.topSurfaceSpeed, forKey: p + "topSurfaceSpeed")
        d.set(settings.firstLayerSpeed, forKey: p + "firstLayerSpeed")
        d.set(settings.travelSpeed, forKey: p + "travelSpeed")
        d.set(settings.retractionLength, forKey: p + "retractionLength")
        d.set(settings.retractionSpeed, forKey: p + "retractionSpeed")
        d.set(settings.skirtLoops, forKey: p + "skirtLoops")
        d.set(settings.brimWidth, forKey: p + "brimWidth")
        d.set(settings.slotIndex, forKey: p + "slotIndex")
    }

    // MARK: Preset-derived values (best-effort read of the opaque preset)

    /// Reads a numeric property off the Core preset by trying common
    /// property names through Mirror. Returns nil when nothing matches —
    /// callers fall back to the documented per-preset values.
    private func presetNumber(_ labels: [String]) -> Double? {
        let mirror = Mirror(reflecting: settings.preset)
        for child in mirror.children {
            guard let label = child.label, labels.contains(label) else { continue }
            switch child.value {
            case let v as Double: return v
            case let v as Float: return Double(v)
            case let v as Int: return Double(v)
            case let v as NSNumber: return v.doubleValue
            default: continue
            }
        }
        return nil
    }

    private func refreshPresetDerivedValues(applyStoredOverrides: Bool = false) {
        let d = UserDefaults.standard
        let choice = presetChoice
        if !applyStoredOverrides || d.object(forKey: Keys.nozzleTemp) == nil {
            nozzleTemp = presetNumber(["nozzleTemperature", "nozzleTemp", "nozzle_temperature"]) ?? choice.fallbackNozzleTemp
        }
        if !applyStoredOverrides || d.object(forKey: Keys.bedTemp) == nil {
            bedTemp = presetNumber(["bedTemperature", "bedTemp", "bed_temperature"]) ?? choice.fallbackBedTemp
        }
        if !applyStoredOverrides || d.object(forKey: Keys.flowRatio) == nil {
            flowRatio = presetNumber(["flowRatio", "filamentFlowRatio"]) ?? choice.fallbackFlowRatio
        }
        volumetricCap = presetNumber(["maxVolumetric", "maxVolumetricSpeed", "volumetricCap", "filamentMaxVolumetricSpeed"]) ?? choice.fallbackVolumetricCap
    }

    func persistFilamentOverrides() {
        let d = UserDefaults.standard
        d.set(nozzleTemp, forKey: Keys.nozzleTemp)
        d.set(bedTemp, forKey: Keys.bedTemp)
        d.set(flowRatio, forKey: Keys.flowRatio)
    }

    // MARK: Import

    func importSTL(from url: URL) {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            let loaded = try loadSTL(data: data, name: url.lastPathComponent)
            mesh = loaded
            result = nil
            statusText = "Loaded \(loaded.name) — \(loaded.triangles.count) triangles. Ready to slice."
            appendLog("Imported \(url.lastPathComponent) (\(data.count) bytes)")
        } catch {
            statusText = "Import failed: \(error.localizedDescription)"
            appendLog("Import failed: \(error.localizedDescription)")
        }
    }

    // MARK: Local files & Open-In

    /// The app's Documents folder. File sharing is enabled, so this is
    /// the "SlicePad" folder visible in the Files app (On My iPad →
    /// SlicePad); STLs copied there are the primary import source for
    /// the in-app browser, because the system document picker is
    /// unreliable on some installs.
    var documentsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    /// Every STL in the Documents folder — including the Inbox
    /// subfolder where iOS drops "Open in" copies — newest first.
    func localSTLFiles() -> [LocalSTLFile] {
        listLocalSTLFiles(in: documentsDirectory)
    }

    func importLocalSTL(_ file: LocalSTLFile) {
        importSTL(from: file.url)
    }

    func deleteLocalSTL(_ file: LocalSTLFile) {
        do {
            try FileManager.default.removeItem(at: file.url)
            appendLog("Deleted \(file.relativePath) from the SlicePad folder.")
        } catch {
            appendLog("Delete failed: \(error.localizedDescription)")
        }
    }

    /// "Open in SlicePad" / share-sheet delivery (wired to .onOpenURL).
    /// The URL may be security-scoped (opened in place from another
    /// app's container) or a copy in Documents/Inbox; importSTL handles
    /// the access for both.
    func handleIncomingFile(url: URL) {
        guard url.isFileURL, url.pathExtension.lowercased() == "stl" else { return }
        importSTL(from: url)
    }

    // MARK: Slicing

    /// Settings + the editable filament values applied as Core overrides
    /// wherever they differ from the preset (nil = pure preset behaviour).
    /// Single source of truth for slicing AND for 3MF packaging, so the
    /// container metadata always matches the G-code that was produced.
    var effectiveSettings: SliceSettings {
        var s = settings
        let preset = s.preset
        let nt = Int(nozzleTemp.rounded())
        s.nozzleTempOverride = nt != preset.nozzleTemp ? nt : nil
        let bt = Int(bedTemp.rounded())
        s.bedTempOverride = bt != preset.bedTemp ? bt : nil
        s.flowRatioOverride = abs(flowRatio - preset.flowRatio) > 0.0001 ? flowRatio : nil
        return s
    }

    func slice() {
        guard let mesh, !isSlicing else { return }
        isSlicing = true
        statusText = "Slicing…"
        let settingsCopy = effectiveSettings
        let templatesCopy = templates
        Task.detached(priority: .userInitiated) {
            let sliced = sliceModel(mesh: mesh, settings: settingsCopy, templates: templatesCopy)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.result = sliced
                self.isSlicing = false
                self.statusText = "Sliced: \(sliced.layerCount) layers, estimate \(AppModel.formatDuration(sliced.estimatedSeconds))."
                self.appendLog("Sliced \(mesh.name): \(sliced.layerCount) layers")
            }
        }
    }

    // MARK: Export

    /// Builds the .gcode.3mf package for the current slice (nil if not sliced).
    func buildThreeMFData() -> Data? {
        guard let mesh, let result else { return nil }
        let thumbnail = makeThumbnailPNG(mesh: mesh, size: 512)
        // On-plate bbox: the slicer centres the model at (90, 90), so the
        // metadata bbox is the raw STL bbox shifted by the same offset.
        let offX = 90.0 - (mesh.minB.x + mesh.maxB.x) / 2.0
        let offY = 90.0 - (mesh.minB.y + mesh.maxB.y) / 2.0
        let plateMin = Vec2(x: mesh.minB.x + offX, y: mesh.minB.y + offY)
        let plateMax = Vec2(x: mesh.maxB.x + offX, y: mesh.maxB.y + offY)
        return buildThreeMF(gcode: result.gcode,
                            modelName: mesh.name,
                            settings: effectiveSettings,
                            estimatedSeconds: result.estimatedSeconds,
                            filamentUsedGrams: result.filamentUsedGrams,
                            layerCount: result.layerCount,
                            bboxMin: plateMin,
                            bboxMax: plateMax,
                            thumbnailPNG: thumbnail,
                            projectSettingsJSON: patchedProjectSettings())
    }

    /// The bundled project_settings.config is Bambu Studio's own output
    /// for the PLA Basic baseline (golden file). Patch the keys that must
    /// agree with the values actually sliced — preset identity, temps,
    /// flow and the process basics — so the container never contradicts
    /// the G-code inside it. (Studio's CLI had also collapsed
    /// filament_max_volumetric_speed to "2"; the patch repairs that too.)
    private func patchedProjectSettings() -> String {
        guard let data = projectSettingsJSON.data(using: .utf8),
              var root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return projectSettingsJSON
        }
        let s = effectiveSettings
        func setArr(_ key: String, _ value: String) {
            if root[key] != nil { root[key] = [value] }
        }
        func setLike(_ key: String, _ value: String) {
            if let existing = root[key] {
                root[key] = (existing is [Any]) ? [value] : value
            }
        }
        setArr("filament_type", s.preset.type)
        setArr("filament_density", AppModel.fmt(s.preset.density))
        setArr("filament_flow_ratio", AppModel.fmt(s.effFlowRatio))
        setArr("filament_max_volumetric_speed", AppModel.fmt(s.effMaxVolumetric))
        setArr("nozzle_temperature", "\(s.effNozzleTemp)")
        setArr("nozzle_temperature_initial_layer", "\(s.effNozzleTemp)")
        setArr("textured_plate_temp", "\(s.effBedTemp)")
        setArr("textured_plate_temp_initial_layer", "\(s.effBedTemp)")
        setLike("layer_height", AppModel.fmt(s.layerHeight))
        setLike("initial_layer_print_height", AppModel.fmt(s.firstLayerHeight))
        setLike("wall_loops", "\(s.wallCount)")
        setLike("top_shell_layers", "\(s.topLayers)")
        setLike("bottom_shell_layers", "\(s.bottomLayers)")
        setLike("sparse_infill_density", "\(Int(s.infillPercent.rounded()))%")
        guard let out = try? JSONSerialization.data(withJSONObject: root, options: [.sortedKeys]),
              let text = String(data: out, encoding: .utf8) else {
            return projectSettingsJSON
        }
        return text
    }

    /// Compact number formatting ("0.98", "21", "1.26").
    private static func fmt(_ v: Double) -> String {
        if v == v.rounded() && abs(v) < 1e15 { return String(Int(v)) }
        var t = String(format: "%.4f", v)
        while t.hasSuffix("0") { t.removeLast() }
        if t.hasSuffix(".") { t.removeLast() }
        return t
    }

    var exportBaseName: String {
        AppModel.sanitizedFilename(mesh?.name ?? "model")
    }

    /// Writes both export files to a temp folder and presents the share sheet.
    func shareExports() {
        guard let result, let threeMF = buildThreeMFData() else { return }
        let base = exportBaseName
        let dir = FileManager.default.temporaryDirectory
        let threeMFURL = dir.appendingPathComponent("\(base).gcode.3mf")
        let gcodeURL = dir.appendingPathComponent("\(base).gcode")
        do {
            try threeMF.write(to: threeMFURL, options: .atomic)
            try Data(result.gcode.utf8).write(to: gcodeURL, options: .atomic)
            shareItems = [threeMFURL, gcodeURL]
            showingShare = true
        } catch {
            appendLog("Export failed: \(error.localizedDescription)")
        }
    }

    func prepareFileExport(kind: ExportKind) {
        guard let result else { return }
        let base = exportBaseName
        switch kind {
        case .threeMF:
            guard let data = buildThreeMFData() else { return }
            exportDocument = ExportDocument(data: data)
            exportFilename = "\(base).gcode.3mf"
        case .gcode:
            exportDocument = ExportDocument(data: Data(result.gcode.utf8))
            exportFilename = "\(base).gcode"
        }
        showingExporter = true
    }

    enum ExportKind { case threeMF, gcode }

    // MARK: Printer actions

    func savePrinterConfig(accessCode: String) {
        if !accessCode.isEmpty {
            KeychainStore.setAccessCode(accessCode)
        }
        // printerIP / printerSerial persist themselves via didSet.
        appendLog("Printer settings saved (access code stored in Keychain).")
    }

    func connectPrinter() {
        guard let code = KeychainStore.accessCode(), !code.isEmpty else {
            appendLog("No access code saved — enter it in the printer settings first.")
            return
        }
        printer.connect(host: printerIP, serial: printerSerial, accessCode: code)
    }

    func disconnectPrinter() {
        printer.disconnect()
    }

    func discoverPrinters() {
        isDiscovering = true
        Discovery.discover { [weak self] found in
            guard let self else { return }
            self.isDiscovering = false
            self.discoveredPrinters = found
            self.appendLog(found.isEmpty ? "Discovery: no printers answered in 4 s."
                                         : "Discovery: found \(found.count) printer(s).")
        }
    }

    func applyDiscovered(_ printerInfo: DiscoveredPrinter) {
        printerIP = printerInfo.ip
        printerSerial = printerInfo.serial
        appendLog("Discovery selected \(printerInfo.serial) at \(printerInfo.ip)")
    }

    /// Send flow: build .gcode.3mf -> FTPS upload to /cache/ -> MQTT
    /// project_file start (when connected). Each step lands in the log.
    func sendToPrinter() {
        guard let result else { return }
        guard printerConfigured, let code = KeychainStore.accessCode() else {
            appendLog("Printer is not configured — add IP, serial and access code first.")
            return
        }
        guard let data = buildThreeMFData() else { return }
        _ = result
        let filename = "\(exportBaseName).gcode.3mf"
        isSending = true
        appendLog("Uploading \(filename) (\(data.count) bytes) to /cache/ …")
        uploader.upload(host: printerIP, accessCode: code, filename: filename, data: data) { [weak self] uploadResult, steps in
            guard let self else { return }
            for step in steps { self.appendLog("FTP: \(step)") }
            switch uploadResult {
            case .failure(let error):
                self.isSending = false
                self.appendLog("Upload failed: \(error.localizedDescription)")
            case .success:
                self.appendLog("Upload complete.")
                if self.isPrinterConnected {
                    self.printer.startPrint(filename: filename,
                                            slotIndex: self.settings.slotIndex,
                                            useAMS: true)
                    self.appendLog("Print start command sent — watch the printer.")
                } else {
                    self.appendLog("File uploaded. Connect to the printer, then send again to start remotely — or start \(filename) from the printer screen.")
                }
                self.isSending = false
            }
        }
    }

    // MARK: Helpers

    func appendLog(_ line: String) {
        logLines.append(line)
        if logLines.count > 200 { logLines.removeFirst(logLines.count - 200) }
    }

    static func formatDuration(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return String(format: "%d:%02d:%02d", h, m, s)
    }

    /// SD/FTP-safe filename stem: ASCII alphanumerics, "_" and "-" only,
    /// capped at 40 characters.
    static func sanitizedFilename(_ name: String) -> String {
        let stem = (name as NSString).deletingPathExtension
        var out = ""
        for scalar in stem.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) || scalar == "_" || scalar == "-" {
                out.append(Character(scalar))
            } else if scalar == " " || scalar == "." {
                out.append("_")
            }
        }
        if out.isEmpty { out = "model" }
        return String(out.prefix(40))
    }

    // MARK: Bundle resource loading

    private static func bundleText(_ resource: String) -> String {
        guard let url = Bundle.main.url(forResource: resource, withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return ""
        }
        return text
    }

    private static func loadTemplates() -> TemplateSet {
        TemplateSet(start: bundleText("start_gcode"),
                    end: bundleText("end_gcode"),
                    layerChange: bundleText("layer_change_gcode"),
                    filamentStart: bundleText("filament_start_gcode"),
                    filamentEnd: bundleText("filament_end_gcode"))
    }

    private static func loadProjectSettings() -> String {
        guard let url = Bundle.main.url(forResource: "project_settings", withExtension: "json"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return "{}"
        }
        return text
    }
}

// MARK: - ExportDocument (for .fileExporter "Save to Files")

struct ExportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.item] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
