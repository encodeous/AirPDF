import SwiftUI

@main
struct AirPDFApp: App {
    #if os(macOS)
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var appModel = AppModel()
    #endif

    var body: some Scene {
        #if os(macOS)
        WindowGroup {
            MacContentView()
                .environmentObject(appModel)
        }
        .defaultSize(width: 960, height: 640)
        #else
        WindowGroup {
            ConnectionView()
        }
        #endif
    }
}
