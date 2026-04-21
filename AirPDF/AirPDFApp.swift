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
                .focusedObject(appModel)
        }
        .defaultSize(width: 960, height: 640)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open…") { appModel.showOpenPanel = true }
                    .keyboardShortcut("o", modifiers: .command)
                Button("Save") { appModel.saveSelectedPDF() }
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(appModel.selectedSessionID == nil)
            }
        }
        #else
        WindowGroup {
            ConnectionView()
        }
        #endif
    }
}
