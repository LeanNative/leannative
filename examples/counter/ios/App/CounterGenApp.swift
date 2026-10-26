import SwiftUI

/// The whole hand-written part of the generated app: a window around the generated screen.
@main
@MainActor
struct CounterGenApp: App {
    @State private var store = Store<CounterApp>()

    var body: some Scene {
        WindowGroup {
            NavigationStack {
                ScrollView {
                    CounterScreen(store: store).padding()
                }
                .scrollDismissesKeyboard(.interactively)
                .navigationTitle("Counter · generated")
                .navigationBarTitleDisplayMode(.inline)
            }
        }
    }
}
