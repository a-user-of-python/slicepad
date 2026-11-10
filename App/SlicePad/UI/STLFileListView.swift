import SwiftUI

// MARK: - STLFileListView
//
// The primary STL import path: an in-app browser over the SlicePad
// Documents folder (visible in the Files app as On My iPad → SlicePad).
// On some installs the system document picker never opens, so the app
// does not depend on it — this list always works.

struct STLFileListView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var files: [LocalSTLFile] = []

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Put STL files in Files → On My iPad → SlicePad, then pick them here. Files shared to SlicePad (“Open in SlicePad”) show up here too.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                if files.isEmpty {
                    Section {
                        Text("No STL files in the SlicePad folder yet.")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Section("In the SlicePad folder") {
                        ForEach(files, id: \.url) { file in
                            Button {
                                model.importLocalSTL(file)
                                dismiss()
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(file.name)
                                        .foregroundStyle(.primary)
                                    Text("\(ByteCountFormatter.string(fromByteCount: file.sizeBytes, countStyle: .file)) · \(file.modified, format: .dateTime.month().day().hour().minute())")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .onDelete { offsets in
                            for index in offsets { model.deleteLocalSTL(files[index]) }
                            reload()
                        }
                    }
                }

                Section {
                    Text("There is also a “System File Picker” button in the toolbar, but on some installs it doesn't open. This list is the reliable way in.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Open STL")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .onAppear { reload() }
        }
    }

    private func reload() {
        files = model.localSTLFiles()
    }
}
