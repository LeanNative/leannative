import SwiftUI

@main
@MainActor
struct ElmLeanApp: App {
    @State private var client: ElmClient

    init() {
        let stored = UserDefaults.standard.string(forKey: "baseURL")
        let url = stored.flatMap(URL.init(string:)) ?? URL(string: ElmClient.defaultBaseURLString)!
        _client = State(initialValue: ElmClient(baseURL: url))
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(client)
        }
    }
}
