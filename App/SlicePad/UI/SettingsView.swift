import SwiftUI

// MARK: - SettingsView
//
// The full settings form: geometry, speeds, filament values (editable
// overrides initialised from the preset), and a link to the printer setup.

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Form {
            Section("Filament") {
                Picker("Preset", selection: $model.presetChoice) {
                    ForEach(AppModel.PresetChoice.allCases) { choice in
                        Text(choice.displayName).tag(choice)
                    }
                }
                Picker("AMS lite slot", selection: Binding(
                    get: { model.settings.slotIndex + 1 },
                    set: { model.settings.slotIndex = $0 - 1 }
                )) {
                    ForEach(1...4, id: \.self) { slot in
                        Text("Slot \(slot)").tag(slot)
                    }
                }
                Stepper(value: $model.nozzleTemp, in: 170...300, step: 1) {
                    Text("Nozzle \(Int(model.nozzleTemp)) °C")
                }
                .onChange(of: model.nozzleTemp) { _ in model.persistFilamentOverrides() }
                Stepper(value: $model.bedTemp, in: 0...110, step: 1) {
                    Text("Bed \(Int(model.bedTemp)) °C")
                }
                .onChange(of: model.bedTemp) { _ in model.persistFilamentOverrides() }
                HStack {
                    Text("Flow ratio")
                    Spacer()
                    Text(String(format: "%.2f", model.flowRatio))
                        .foregroundStyle(.secondary)
                }
                Slider(value: $model.flowRatio, in: 0.85...1.10, step: 0.01)
                    .onChange(of: model.flowRatio) { _ in model.persistFilamentOverrides() }
                HStack {
                    Text("Volumetric cap (from preset)")
                    Spacer()
                    Text(String(format: "%.0f mm³/s", model.volumetricCap))
                        .foregroundStyle(.secondary)
                }
            }

            Section("Layers & walls") {
                HStack {
                    Text("Layer height")
                    Spacer()
                    Text(String(format: "%.2f mm", model.settings.layerHeight))
                        .foregroundStyle(.secondary)
                }
                Slider(value: $model.settings.layerHeight, in: 0.08...0.32, step: 0.02)
                HStack {
                    Text("First layer height")
                    Spacer()
                    Text(String(format: "%.2f mm", model.settings.firstLayerHeight))
                        .foregroundStyle(.secondary)
                }
                Slider(value: $model.settings.firstLayerHeight, in: 0.08...0.40, step: 0.02)
                Stepper(value: $model.settings.wallCount, in: 1...6) {
                    Text("Walls: \(model.settings.wallCount)")
                }
                Stepper(value: $model.settings.topLayers, in: 0...10) {
                    Text("Top layers: \(model.settings.topLayers)")
                }
                Stepper(value: $model.settings.bottomLayers, in: 0...10) {
                    Text("Bottom layers: \(model.settings.bottomLayers)")
                }
                HStack {
                    Text("Infill")
                    Spacer()
                    Text("\(Int(model.settings.infillPercent))%")
                        .foregroundStyle(.secondary)
                }
                Slider(value: $model.settings.infillPercent, in: 0...100, step: 1)
            }

            Section("Line widths") {
                HStack {
                    Text("Outer wall")
                    Spacer()
                    Text(String(format: "%.2f mm", model.settings.lineWidth))
                        .foregroundStyle(.secondary)
                }
                Slider(value: $model.settings.lineWidth, in: 0.30...0.60, step: 0.01)
                HStack {
                    Text("Inner wall / infill")
                    Spacer()
                    Text(String(format: "%.2f mm", model.settings.innerLineWidth))
                        .foregroundStyle(.secondary)
                }
                Slider(value: $model.settings.innerLineWidth, in: 0.30...0.60, step: 0.01)
            }

            Section("Speeds (mm/s)") {
                speedRow("Outer wall", value: $model.settings.outerWallSpeed)
                speedRow("Inner wall", value: $model.settings.innerWallSpeed)
                speedRow("Infill", value: $model.settings.infillSpeed)
                speedRow("Solid infill", value: $model.settings.solidInfillSpeed)
                speedRow("Top surface", value: $model.settings.topSurfaceSpeed)
                speedRow("First layer", value: $model.settings.firstLayerSpeed)
                speedRow("Travel", value: $model.settings.travelSpeed)
            }

            Section("Retraction & adhesion") {
                HStack {
                    Text("Retraction length")
                    Spacer()
                    Text(String(format: "%.1f mm", model.settings.retractionLength))
                        .foregroundStyle(.secondary)
                }
                Slider(value: $model.settings.retractionLength, in: 0...2, step: 0.1)
                HStack {
                    Text("Retraction speed")
                    Spacer()
                    Text("\(Int(model.settings.retractionSpeed)) mm/s")
                        .foregroundStyle(.secondary)
                }
                Slider(value: $model.settings.retractionSpeed, in: 10...60, step: 1)
                HStack {
                    Text("Brim width")
                    Spacer()
                    Text(String(format: "%.0f mm", model.settings.brimWidth))
                        .foregroundStyle(.secondary)
                }
                Slider(value: $model.settings.brimWidth, in: 0...10, step: 0.5)
                Stepper(value: $model.settings.skirtLoops, in: 0...3) {
                    Text("Skirt loops: \(model.settings.skirtLoops)")
                }
            }

            Section("Printer") {
                NavigationLink {
                    PrinterView()
                } label: {
                    Label("Printer connection & AMS", systemImage: "printer")
                }
                Text("Sending prints requires LAN Only Mode + Developer Mode enabled on the printer.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func speedRow(_ label: String, value: Binding<Double>) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text("\(Int(value.wrappedValue))")
                .foregroundStyle(.secondary)
            Stepper("", value: value, in: 5...700, step: 5)
                .labelsHidden()
        }
    }
}
