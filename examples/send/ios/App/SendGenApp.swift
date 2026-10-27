import SwiftUI

/// The hand-written shell: a window around the generated screen, and the host that runs its commands.
@main
@MainActor
struct SendGenApp: App {
    @State private var store = Store<SendApp>()
    @State private var host = WalletHost()

    var body: some Scene {
        WindowGroup {
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        SendScreen(store: store)
                        Text(WalletHost.disclosure).font(.footnote).foregroundStyle(.secondary)
                    }
                    .padding()
                }
                .scrollDismissesKeyboard(.interactively)
                .navigationTitle("Send · generated")
                .navigationBarTitleDisplayMode(.inline)
            }
            .task {
                store.attach(host)
                await host.start(store)
            }
        }
    }
}
