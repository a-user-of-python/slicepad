// Settings.swift — SlicePad slicer core: filament presets, slice settings,
// injected template text, and the slice result types.
// Preset values are the *effective* values from Bambu Studio's A1 mini
// profile chains (see research findings-flow.md / findings-machine.md).

import Foundation

public struct FilamentPreset {
    public var id: String          // Bambu filament_id, e.g. "GFA00"
    public var displayName: String
    public var type: String        // "PLA", "PETG", ...
    public var colorHex: String    // "#RRGGBB"
    public var nozzleTemp: Int     // deg C (also initial-layer temp for these presets)
    public var bedTemp: Int        // deg C, Textured PEI Plate (A1 mini default plate)
    public var flowRatio: Double   // filament_flow_ratio
    public var maxVolumetric: Double // filament_max_volumetric_speed, mm^3/s
    public var density: Double     // filament_density, g/cm^3

    public init(id: String, displayName: String, type: String, colorHex: String,
                nozzleTemp: Int, bedTemp: Int, flowRatio: Double,
                maxVolumetric: Double, density: Double) {
        self.id = id; self.displayName = displayName; self.type = type
        self.colorHex = colorHex; self.nozzleTemp = nozzleTemp; self.bedTemp = bedTemp
        self.flowRatio = flowRatio; self.maxVolumetric = maxVolumetric; self.density = density
    }
}

public enum FilamentPresets {
    /// Bambu PLA Basic @BBL A1M — nozzle 220, textured bed 65 (leaf A1M file),
    /// flow ratio 0.98 and volumetric cap 21 (Bambu PLA Basic @base.json),
    /// density 1.26 (Bambu PLA Basic @base.json filament_density),
    /// filament_id GFA00 (@base.json).
    public static let bambuPLABasic = FilamentPreset(
        id: "GFA00", displayName: "Bambu PLA Basic", type: "PLA", colorHex: "#00AE42",
        nozzleTemp: 220, bedTemp: 65, flowRatio: 0.98, maxVolumetric: 21, density: 1.26)

    /// Generic PLA @BBL A1M — nozzle 220, textured bed 65, flow ratio 0.98
    /// (Generic PLA @base.json), volumetric cap 12 (fdm_filament_pla.json),
    /// density 1.24 (fdm_filament_pla.json), filament_id GFL99 (@base.json).
    public static let genericPLA = FilamentPreset(
        id: "GFL99", displayName: "Generic PLA", type: "PLA", colorHex: "#808080",
        nozzleTemp: 220, bedTemp: 65, flowRatio: 0.98, maxVolumetric: 12, density: 1.24)

    /// Bambu PETG Basic @BBL A1M (0.4 nozzle). Chain read from the local
    /// Bambu Studio profiles (resources/profiles/BBL/filament/):
    /// leaf "Bambu PETG Basic @BBL A1M 0.4 nozzle.json" overrides
    /// nozzle_temperature / nozzle_temperature_initial_layer to 245,
    /// filament_flow_ratio to 0.94 and filament_max_volumetric_speed to 13;
    /// its parent "Bambu PETG Basic @base.json" sets textured_plate_temp /
    /// textured_plate_temp_initial_layer to 70 (the A1 mini default plate)
    /// and filament_density to 1.25; filament_id GFG00 comes from @base.
    public static let bambuPETGBasic = FilamentPreset(
        id: "GFG00", displayName: "Bambu PETG Basic", type: "PETG", colorHex: "#000000",
        nozzleTemp: 245, bedTemp: 70, flowRatio: 0.94, maxVolumetric: 13, density: 1.25)
}

public struct SliceSettings {
    public var layerHeight: Double = 0.2
    public var firstLayerHeight: Double = 0.2
    public var lineWidth: Double = 0.42       // outer wall line width
    public var innerLineWidth: Double = 0.45  // inner wall / infill line width
    public var wallCount: Int = 2
    public var topLayers: Int = 5
    public var bottomLayers: Int = 3
    public var infillPercent: Double = 15.0
    public var outerWallSpeed: Double = 200.0   // mm/s
    public var innerWallSpeed: Double = 300.0
    public var infillSpeed: Double = 270.0
    public var solidInfillSpeed: Double = 270.0
    public var topSurfaceSpeed: Double = 200.0
    public var firstLayerSpeed: Double = 50.0
    public var travelSpeed: Double = 500.0      // mm/s; machine cap is 500 (machine_max_speed_x/y)
    public var retractionLength: Double = 0.8
    public var retractionSpeed: Double = 30.0
    public var skirtLoops: Int = 0
    public var brimWidth: Double = 0.0          // mm, 0 = off
    public var slotIndex: Int = 0               // 0-based AMS filament index -> M620 S<slotIndex>
    public var preset: FilamentPreset = FilamentPresets.bambuPLABasic
    public var timelapse: Bool = false

    // User overrides on top of the selected preset (nil = use the preset).
    public var nozzleTempOverride: Int? = nil
    public var bedTempOverride: Int? = nil
    public var flowRatioOverride: Double? = nil
    public var maxVolumetricOverride: Double? = nil

    /// Effective values: the override when set, else the preset value.
    /// All slicing, template binding, header/config and 3MF code must use
    /// these, never the raw preset fields, for the four overridable values.
    public var effNozzleTemp: Int { nozzleTempOverride ?? preset.nozzleTemp }
    public var effBedTemp: Int { bedTempOverride ?? preset.bedTemp }
    public var effFlowRatio: Double { flowRatioOverride ?? preset.flowRatio }
    public var effMaxVolumetric: Double { maxVolumetricOverride ?? preset.maxVolumetric }

    public init() {}
}

/// The Bambu machine/filament G-code templates, injected by the app layer
/// (loaded from bundle resources there). The Core never reads a Bundle.
public struct TemplateSet {
    public var start: String
    public var end: String
    public var layerChange: String
    public var filamentStart: String
    public var filamentEnd: String
    public init(start: String, end: String, layerChange: String, filamentStart: String, filamentEnd: String) {
        self.start = start; self.end = end; self.layerChange = layerChange
        self.filamentStart = filamentStart; self.filamentEnd = filamentEnd
    }
}

public enum PreviewKind {
    case outerWall, innerWall, infill, solidInfill, topSurface, travel, skirtOrBrim
}

public struct PreviewPath {
    public var kind: PreviewKind
    public var points: [Vec3] // polyline vertices; z = layer z
    public init(kind: PreviewKind, points: [Vec3]) { self.kind = kind; self.points = points }
}

public struct SliceResult {
    public var gcode: String
    public var estimatedSeconds: Double
    public var filamentUsedMM: Double
    public var filamentUsedGrams: Double
    public var layerCount: Int
    public var maxZ: Double
    public var preview: [PreviewPath]
    public init(gcode: String, estimatedSeconds: Double, filamentUsedMM: Double,
                filamentUsedGrams: Double, layerCount: Int, maxZ: Double, preview: [PreviewPath]) {
        self.gcode = gcode; self.estimatedSeconds = estimatedSeconds
        self.filamentUsedMM = filamentUsedMM; self.filamentUsedGrams = filamentUsedGrams
        self.layerCount = layerCount; self.maxZ = maxZ; self.preview = preview
    }
}
