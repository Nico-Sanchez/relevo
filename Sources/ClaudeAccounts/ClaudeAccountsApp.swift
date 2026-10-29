import SwiftUI

@main
struct ClaudeAccountsApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuView(model: model)
                .frame(width: 340)
        } label: {
            Image(systemName: "person.2.circle")
        }
        .menuBarExtraStyle(.window)
    }
}
