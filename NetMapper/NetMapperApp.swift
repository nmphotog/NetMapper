import SwiftUI

@main
struct NetMapperApp: App {
    var body: some Scene {
        WindowGroup("NetMapper") {
            ContentView()
        }
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}
