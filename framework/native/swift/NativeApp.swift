import SwiftUI

/// The whole iOS app of an ElmLean native app: the generic renderer around whatever view Lean returns.
/// An app ships no Swift of its own; its name comes from Info.plist (`CFBundleDisplayName`).
/// While the scene is not active the content is covered (app-switcher snapshots never show it).
@main
struct ElmLeanNativeApp: App {
    @State private var store = NativeStore()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ZStack {
                if let failure = store.failure {
                    Text(failure).foregroundStyle(.red).padding()
                } else {
                    NativeRoot(node: store.view)
                }
                if scenePhase != .active {
                    Color(.systemBackground).ignoresSafeArea()
                }
            }
            .environment(store)
            .onChange(of: scenePhase, initial: true) { _, phase in
                let name = phase == .active ? "active" : phase == .background ? "background" : "inactive"
                store.system(["scene": name])
            }
            .onReceive(NotificationCenter.default.publisher(for: UIScreen.capturedDidChangeNotification)) { _ in
                store.system(["captured": UIScreen.main.isCaptured])
            }
        }
    }
}
