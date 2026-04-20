import SwiftUI

@main
struct AirPDFMacApp: App {
    @StateObject private var appModel = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appModel)
        }
        .defaultSize(width: 960, height: 640)
    }
}
