import SwiftUI

/// The whole hand-written part of the generated app: a window around the generated screen.
@main
@MainActor
struct TodoGenApp: App {
    @State private var store = Store<TodoApp>()

    var body: some Scene {
        WindowGroup {
            NavigationStack {
                ScrollView {
                    TodoScreen(store: store).padding()
                }
                .scrollDismissesKeyboard(.interactively)
                .navigationTitle("Todo · generated")
                .navigationBarTitleDisplayMode(.inline)
            }
        }
    }
}
