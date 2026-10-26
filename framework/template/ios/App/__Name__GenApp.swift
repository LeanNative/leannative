import SwiftUI

/// The whole hand-written part of the generated app: a window around the generated screen.
@main
@MainActor
struct __Name__GenApp: App {
    @State private var store = Store<__Name__App>()

    var body: some Scene {
        WindowGroup {
            NavigationStack {
                ScrollView {
                    __Name__Screen(store: store).padding()
                }
                .scrollDismissesKeyboard(.interactively)
                .navigationTitle("__Name__")
                .navigationBarTitleDisplayMode(.inline)
            }
        }
    }
}
