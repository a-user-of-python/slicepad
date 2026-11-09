// ThreeMF.swift — SlicePad slicer core: .gcode.3mf packaging.
// A .gcode.3mf is a plain ZIP with STORED (uncompressed) entries:
// the plate G-code plus the metadata the printer and AMS mapping need.
// File shapes are aligned to a genuine Bambu Studio 2.9.1 A1 mini export
// (research findings-golden.md; golden tree in research/golden/), which
// wins over the older format findings wherever they differ. Two golden
// values are CLI quirks and are NOT copied (see notes at slice_info):
// printer_model_id and the zero filament weights.
// The ZIP writer, CRC32 and MD5 (CryptoKit) are implemented here;
// no third-party code.

import Foundation
import CryptoKit

private func appendU16(_ d: inout Data, _ v: UInt16) {
    d.append(UInt8(v & 0xFF)); d.append(UInt8((v >> 8) & 0xFF))
}
private func appendU32(_ d: inout Data, _ v: UInt32) {
    d.append(UInt8(v & 0xFF)); d.append(UInt8((v >> 8) & 0xFF))
    d.append(UInt8((v >> 16) & 0xFF)); d.append(UInt8((v >> 24) & 0xFF))
}

/// Uppercase-hex MD5 of the G-code, as Bambu's plate_1.gcode.md5 expects
/// (exactly 32 bytes, no trailing newline — verified against the golden).
private func md5UpperHex(_ data: Data) -> String {
    Insecure.MD5.hash(data: data).map { String(format: "%02X", $0) }.joined()
}

private func xmlEscape(_ s: String) -> String {
    s.replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
        .replacingOccurrences(of: "\"", with: "&quot;")
}

/// Fixed 2-decimal formatting (golden used_m / used_g style: "1.26", "0.00").
private func fmt2(_ v: Double) -> String { String(format: "%.2f", v) }

/// Build a complete .gcode.3mf (ZIP, stored entries) for one plate.
public func buildThreeMF(gcode: String, modelName: String, settings: SliceSettings,
                         estimatedSeconds: Double, filamentUsedGrams: Double,
                         layerCount: Int, bboxMin: Vec2, bboxMax: Vec2,
                         thumbnailPNG: Data, projectSettingsJSON: String) -> Data {
    let preset = settings.preset
    let gcodeData = Data(gcode.utf8)
    let md5 = md5UpperHex(gcodeData)
    // Filament length in metres, derived from the weight:
    // grams / density = cm^3; cm^3 * 1000 / filament area = mm; / 1000 = m.
    let usedM = preset.density > 0 ? filamentUsedGrams / preset.density / filamentAreaMM2 : 0

    // printer_model_id: the golden's value is "" because Studio's CLI
    // dropped the machine preset's inherits chain (findings-golden.md
    // section 7.1) — do not copy it. The format research (findings-format
    // section 5/6) specifies the A1 mini's id from its machine model file
    // (Bambu Lab A1 mini.json: model_id "N1"), so "N1" is used here.
    // TODO verify on device: confirm "N1" against a GUI-exported file.
    let printerModelId = "N1"

    // XML shapes follow the golden slice_info.config key-for-key. The
    // golden's weight="" and used_g="0.00" come from its CLI resolving
    // filament_density to 0; ours are computed from the real density.
    let sliceInfo = """
    <?xml version="1.0" encoding="UTF-8"?>
    <config>
      <header>
        <header_item key="X-BBL-Client-Type" value="slicer"/>
        <header_item key="X-BBL-Client-Version" value="SlicePad 1.0"/>
      </header>
      <plate>
        <metadata key="index" value="1"/>
        <metadata key="extruder_type" value="0"/>
        <metadata key="nozzle_volume_type" value="0"/>
        <metadata key="printer_model_id" value="\(printerModelId)"/>
        <metadata key="nozzle_diameters" value="0.4"/>
        <metadata key="timelapse_type" value="0"/>
        <metadata key="prediction" value="\(Int(estimatedSeconds.rounded()))"/>
        <metadata key="weight" value="\(fmt2(filamentUsedGrams))"/>
        <metadata key="pause_count" value="0"/>
        <metadata key="first_layer_time" value="0.000000"/>
        <metadata key="outside" value="false"/>
        <metadata key="support_used" value="false"/>
        <metadata key="label_object_enabled" value="true"/>
        <metadata key="support_material_on_wipe_tower" value="false"/>
        <metadata key="enable_filament_dynamic_map" value="false"/>
        <metadata key="has_filament_switcher" value="false"/>
        <metadata key="multi_nozzle_diameter_mode" value="0"/>
        <metadata key="filament_maps" value="1"/>
        <metadata key="limit_filament_maps" value="0"/>
        <object identify_id="1" name="\(xmlEscape(modelName))" skipped="false" />
        <filament id="1" tray_info_idx="\(xmlEscape(preset.id))" type="\(xmlEscape(preset.type))" color="\(xmlEscape(preset.colorHex))" used_m="\(fmt2(usedM))" used_g="\(fmt2(filamentUsedGrams))" group_id="0" nozzle_diameter="0.40" volume_type="Standard" used_for_object="true" used_for_support="false" directly_used="true" total_load_time="0.00" total_unload_time="0.00"/>
        <nozzle id="0" extruder_id="1" nozzle_diameter="0.4" volume_type="Standard"/>
        <layer_filament_lists>
          <layer_filament_list filament_list="0" layer_ranges="0 \(max(layerCount - 1, 0))" />
        </layer_filament_lists>
      </plate>
    </config>
    """

    // Golden model_settings shape. The golden's per-part uuid / matrix /
    // mesh_stat block describes the source mesh, which buildThreeMF does
    // not receive, so only the object + plate structure is reproduced.
    let modelSettings = """
    <?xml version="1.0" encoding="UTF-8"?>
    <config>
      <object id="2">
        <metadata key="name" value="\(xmlEscape(modelName))"/>
        <metadata key="extruder" value="1"/>
      </object>
      <plate>
        <metadata key="plater_id" value="1"/>
        <metadata key="plater_name" value=""/>
        <metadata key="locked" value="false"/>
        <metadata key="filament_map_mode" value="Auto For Flush"/>
        <metadata key="filament_maps" value="1"/>
        <metadata key="filament_volume_maps" value="0"/>
        <metadata key="gcode_file" value="Metadata/plate_1.gcode"/>
        <model_instance>
          <metadata key="object_id" value="2"/>
          <metadata key="instance_id" value="0"/>
          <metadata key="identify_id" value="1"/>
        </model_instance>
      </plate>
      <assemble>
      </assemble>
    </config>
    """

    let modelSettingsRels = """
    <?xml version="1.0" encoding="UTF-8"?>
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
     <Relationship Target="/Metadata/plate_1.gcode" Id="rel-1" Type="http://schemas.bambulab.com/package/2021/gcode"/>
    </Relationships>
    """

    // Golden plate_1.json key set. bed_type uses Studio's snake-case plate
    // id form ("cool_plate" in the golden, whose job used the Cool Plate;
    // SlicePad targets the Textured PEI Plate, hence "textured_plate").
    let bboxArea = max(0.0, (bboxMax.x - bboxMin.x) * (bboxMax.y - bboxMin.y))
    let jsonName = modelName.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    let plateJSON = """
    {"bbox_all":[\(spNum(bboxMin.x, 3)),\(spNum(bboxMin.y, 3)),\(spNum(bboxMax.x, 3)),\(spNum(bboxMax.y, 3))],"bbox_objects":[{"area":\(spNum(bboxArea, 2)),"bbox":[\(spNum(bboxMin.x, 3)),\(spNum(bboxMin.y, 3)),\(spNum(bboxMax.x, 3)),\(spNum(bboxMax.y, 3))],"id":1,"layer_height":\(spNum(settings.layerHeight, 4)),"name":"\(jsonName)"}],"bed_type":"textured_plate","filament_colors":["\(preset.colorHex)"],"filament_ids":[0],"first_extruder":\(settings.slotIndex),"first_layer_time":0.0,"is_seq_print":false,"nozzle_diameter":0.4,"version":2}
    """

    let filamentSequence = """
    {"plate_1":{"nozzle_sequence":[0],"optimal_assignment":[0],"sequence":[1]}}
    """

    let cutInformation = """
    <?xml version="1.0" encoding="utf-8"?>
    <objects>
     <object id="1">
      <cut_id id="0" check_sum="1" connectors_cnt="0"/>
     </object>
    </objects>
    """

    // Verbatim shape of the golden [Content_Types].xml (four Defaults).
    let contentTypes = """
    <?xml version="1.0" encoding="UTF-8"?>
    <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
     <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
     <Default Extension="model" ContentType="application/vnd.ms-package.3dmanufacturing-3dmodel+xml"/>
     <Default Extension="png" ContentType="image/png"/>
     <Default Extension="gcode" ContentType="text/x.gcode"/>
    </Types>
    """

    // Verbatim shape of the golden _rels/.rels, including the thumbnail
    // relationships (SlicePad does ship real PNGs, so none of these dangle).
    let rels = """
    <?xml version="1.0" encoding="UTF-8"?>
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
     <Relationship Target="/3D/3dmodel.model" Id="rel-1" Type="http://schemas.microsoft.com/3dmanufacturing/2013/01/3dmodel"/>
     <Relationship Target="/Metadata/plate_1.png" Id="rel-2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/thumbnail"/>
     <Relationship Target="/Metadata/plate_1.png" Id="rel-4" Type="http://schemas.bambulab.com/package/2021/cover-thumbnail-middle"/>
    <Relationship Target="/Metadata/plate_1_small.png" Id="rel-5" Type="http://schemas.bambulab.com/package/2021/cover-thumbnail-small"/>
    </Relationships>
    """

    // Golden-style 3dmodel.model root. Studio's export embeds the mesh
    // under 3D/Objects/, but buildThreeMF receives no mesh, so resources
    // and build stay empty here (sliced-file scaffolding only).
    let model3D = """
    <?xml version="1.0" encoding="UTF-8"?>
    <model unit="millimeter" xml:lang="en-US" xmlns="http://schemas.microsoft.com/3dmanufacturing/core/2015/02" xmlns:BambuStudio="http://schemas.bambulab.com/package/2021" xmlns:p="http://schemas.microsoft.com/3dmanufacturing/production/2015/06" requiredextensions="p">
     <metadata name="Application">SlicePad-1.0</metadata>
     <metadata name="BambuStudio:3mfVersion">1</metadata>
     <resources>
     </resources>
     <build>
     </build>
    </model>
    """

    let entries: [(name: String, data: Data)] = [
        ("[Content_Types].xml", Data(contentTypes.utf8)),
        ("Metadata/plate_1.json", Data(plateJSON.utf8)),
        ("3D/3dmodel.model", Data(model3D.utf8)),
        ("Metadata/project_settings.config", Data(projectSettingsJSON.utf8)),
        ("Metadata/plate_1.gcode.md5", Data(md5.utf8)),
        ("Metadata/plate_1.gcode", gcodeData),
        ("Metadata/_rels/model_settings.config.rels", Data(modelSettingsRels.utf8)),
        ("Metadata/model_settings.config", Data(modelSettings.utf8)),
        ("Metadata/cut_information.xml", Data(cutInformation.utf8)),
        ("Metadata/slice_info.config", Data(sliceInfo.utf8)),
        ("Metadata/filament_sequence.json", Data(filamentSequence.utf8)),
        ("Metadata/plate_1.png", thumbnailPNG),
        ("Metadata/plate_1_small.png", thumbnailPNG),
        ("_rels/.rels", Data(rels.utf8)),
    ]

    // ZIP with STORED entries: local headers, data, central directory, EOCD.
    // Fixed DOS timestamp (2024-01-01) keeps output deterministic.
    let dosTime: UInt16 = 0
    let dosDate: UInt16 = ((2024 - 1980) << 9) | (1 << 5) | 1
    var zip = Data()
    var central = Data()
    for entry in entries {
        let nameBytes = Data(entry.name.utf8)
        let crc = spCRC32(entry.data)
        let size = UInt32(entry.data.count)
        let localOffset = UInt32(zip.count)
        appendU32(&zip, 0x0403_4B50) // local file header
        appendU16(&zip, 20)          // version needed
        appendU16(&zip, 0)           // flags
        appendU16(&zip, 0)           // method 0 = stored
        appendU16(&zip, dosTime)
        appendU16(&zip, dosDate)
        appendU32(&zip, crc)
        appendU32(&zip, size)
        appendU32(&zip, size)
        appendU16(&zip, UInt16(nameBytes.count))
        appendU16(&zip, 0)           // extra length
        zip.append(nameBytes)
        zip.append(entry.data)

        appendU32(&central, 0x0201_4B50) // central directory header
        appendU16(&central, 20)          // version made by
        appendU16(&central, 20)          // version needed
        appendU16(&central, 0)
        appendU16(&central, 0)
        appendU16(&central, dosTime)
        appendU16(&central, dosDate)
        appendU32(&central, crc)
        appendU32(&central, size)
        appendU32(&central, size)
        appendU16(&central, UInt16(nameBytes.count))
        appendU16(&central, 0) // extra
        appendU16(&central, 0) // comment
        appendU16(&central, 0) // disk
        appendU16(&central, 0) // internal attrs
        appendU32(&central, 0) // external attrs
        appendU32(&central, localOffset)
        central.append(nameBytes)
    }
    let centralOffset = UInt32(zip.count)
    zip.append(central)
    appendU32(&zip, 0x0605_4B50) // end of central directory
    appendU16(&zip, 0)
    appendU16(&zip, 0)
    appendU16(&zip, UInt16(entries.count))
    appendU16(&zip, UInt16(entries.count))
    appendU32(&zip, UInt32(central.count))
    appendU32(&zip, centralOffset)
    appendU16(&zip, 0)
    return zip
}
