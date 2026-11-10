import SwiftUI

// MARK: - SlicePad entry point
//
// iPad app (iOS 17). AppModel is created once here and shared through the
// environment; it owns the imported mesh, slice settings/result, printer
// connection and AMS state.

@main
struct SlicePadApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .onOpenURL { url in
                    // "Open in SlicePad" / share-sheet delivery of an STL.
                    model.handleIncomingFile(url: url)
                }
        }
    }
}
