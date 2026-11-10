import Foundation

// MARK: - Local STL file listing
//
// SlicePad's primary import path is an in-app browser over the app's own
// Documents folder: the system document picker is unreliable on some
// installs, so the app never depends on it. This helper is pure
// Foundation so the host harness can test the listing rules off-device:
// every .stl under the given root — including the Inbox subfolder where
// iOS drops "Open in" copies — newest first, hidden files skipped.

struct LocalSTLFile: Equatable {
    /// Full URL of the file.
    let url: URL
    /// Display name (last path component).
    let name: String
    /// Path relative to the scanned root ("Inbox/part.stl", "part.stl").
    let relativePath: String
    /// File size in bytes (0 when unknown).
    let sizeBytes: Int64
    /// Last modification date (distant past when unknown).
    let modified: Date
}

/// Recursively lists every STL file under `root`. Extension matching is
/// case-insensitive (".STL" counts). Sorted newest first, ties broken by
/// relative path so the order is stable.
func listLocalSTLFiles(in root: URL, fileManager: FileManager = .default) -> [LocalSTLFile] {
    let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
    guard let enumerator = fileManager.enumerator(at: root,
                                                  includingPropertiesForKeys: keys,
                                                  options: [.skipsHiddenFiles]) else {
        return []
    }
    let rootPath = root.standardizedFileURL.path
    var found: [LocalSTLFile] = []
    for case let url as URL in enumerator {
        guard url.pathExtension.lowercased() == "stl" else { continue }
        let values = try? url.resourceValues(forKeys: Set(keys))
        if let isFile = values?.isRegularFile, !isFile { continue }
        let path = url.standardizedFileURL.path
        let rel = path.hasPrefix(rootPath + "/")
            ? String(path.dropFirst(rootPath.count + 1))
            : url.lastPathComponent
        found.append(LocalSTLFile(url: url,
                                  name: url.lastPathComponent,
                                  relativePath: rel,
                                  sizeBytes: Int64(values?.fileSize ?? 0),
                                  modified: values?.contentModificationDate ?? .distantPast))
    }
    return found.sorted {
        if $0.modified != $1.modified { return $0.modified > $1.modified }
        return $0.relativePath < $1.relativePath
    }
}
