import AppKit
import SwiftUI

@main
struct AirPDFMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var appModel = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appModel)
        }
        .defaultSize(width: 960, height: 640)
    }
}
