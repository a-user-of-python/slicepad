import Foundation

// MARK: - AMS lite / printer status model
//
// Shapes follow findings-network.md §2.2–2.3:
// - AMS lite is a single unit with exactly 4 trays (slots 0...3 internally,
//   labelled 1...4 in the UI).
// - The AMS lite does NOT report a usable remaining-% — there is deliberately
//   no `remain` field here; the UI shows "—" instead of inventing a number.
// - tray colours arrive as RRGGBBAA hex; AMSTray.colorHex is normalised to
//   "#RRGGBB" for display.

/// One AMS lite tray (slot is 0-based: UI slot number = slot + 1).
struct AMSTray: Identifiable, Equatable {
    var id: Int { slot }
    /// 0...3
    var slot: Int
    /// Physical presence from `tray_exist_bits` (hex bitfield), not guessed
    /// from tray_type alone.
    var present: Bool
    /// Base material string, e.g. "PLA", "PETG". "" when nothing configured.
    var type: String
    /// "#RRGGBB" normalised from the printer's RRGGBBAA value.
    var colorHex: String
    /// Bambu filament preset ID, e.g. "GFA00". The most reliable key for
    /// matching a tray to a sliced filament profile.
    var trayInfoIdx: String
    /// True when this tray is the one currently fed to the extruder
    /// (`tray_now == slot`).
    var isActive: Bool

    static func empty(slot: Int) -> AMSTray {
        AMSTray(slot: slot, present: false, type: "", colorHex: "#000000",
                trayInfoIdx: "", isActive: false)
    }

    /// Four empty trays, used before the first status report arrives.
    static var emptySet: [AMSTray] { (0..<4).map { empty(slot: $0) } }
}

/// Snapshot of the printer's live state, extracted from the deep-merged
/// MQTT report dictionary (PrinterConnection owns the merging).
struct PrinterStatus: Equatable {
    /// e.g. "IDLE", "RUNNING", "PAUSE", "FINISH", "FAILED"
    var state: String = "—"
    var nozzleTemp: Double = 0
    var bedTemp: Double = 0
    var targetNozzle: Double = 0
    var targetBed: Double = 0
    /// mc_percent, 0...100, when reported.
    var progress: Int? = nil
    /// subtask_name, falling back to gcode_file, when reported.
    var currentFile: String? = nil
    /// Always 4 entries for the AMS lite (empty placeholders included).
    var trays: [AMSTray] = AMSTray.emptySet
    /// Raw tray_now: 0...3 = AMS slot, 254 = external spool, 255 = none.
    var trayNow: Int = 255

    var isExternalSpoolActive: Bool { trayNow == 254 }
}

/// A printer found by SSDP discovery (Discovery.swift).
struct DiscoveredPrinter: Identifiable, Equatable {
    var id: String { serial }
    var serial: String
    var ip: String
    /// Raw DevModel code, e.g. "N1" (A1 mini). Hint only — never hard-fail
    /// on an unknown code.
    var model: String
    var name: String = ""
}
