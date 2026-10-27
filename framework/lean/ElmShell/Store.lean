import ElmShell.Swift

/-! # ElmShell.Store: `NativeStore.swift` and `NativeApp.swift`, the shell around the C interface -/

namespace ElmShell

/-- `guard let data = try? JSONSerialization.data(withJSONObject: x), let line = String(…) else { return }` -/
def serialize (x : String) : Stmt :=
  .guardS [s!"let data = try? JSONSerialization.data(withJSONObject: {x})", "let line = String(data: data, encoding: .utf8)"] [.ret none]

def store : Decl :=
  .doc "The app's state as the shell sees it: the last view Lean returned and its `seq`. Every call into Lean
happens on the main actor except `elmlean_wait`, which blocks a background thread until Lean has
something queued; the main actor then drains it."
  (.ty "@MainActor @Observable\nfinal class NativeStore"
    [ .prop "private(set) var view: NativeNode" (some (r ".col([])"))
    , .prop "private(set) var seq" (some (r "0"))
    , .prop "private(set) var failure: String?" none
    , .prop "@ObservationIgnored private let capabilities" (some (r "Capabilities()"))
    , .blank
    , .fn "init()"
      [ .ifS ["elmlean_boot() != 0"] [.set "failure" (.lit "The app failed to start."), .ret none] []
      , s "apply(take(elmlean_start()))"
      , .letS "thread" (cb "Thread" [] "[weak self]"
          [.whileS "true" [s "elmlean_wait()", s "DispatchQueue.main.sync { self?.drain() }"]])
      , .set "thread.stackSize" (r "8 << 20")
      , s "thread.start()" ]
    , .blank
    , .fn "func send(path: [Int], event: NativeEvent)"
      [ .letS "request: [String: Any]" (r "[\"seq\": seq, \"path\": path, \"event\": event.json]")
      , serialize "request"
      , s "apply(take(line.withCString { elmlean_event($0) }))" ]
    , .blank
    , .fn "func drain()" [s "apply(take(elmlean_drain()))"]
    , .blank
    , .doc "A system event (scene phase, screen capture) for the app's `system` mapping."
      (.fn "func system(_ event: [String: Any])"
        [ serialize "event", s "apply(take(line.withCString { elmlean_system($0) }))" ])
    , .blank
    , .fn "private func take(_ p: UnsafeMutablePointer<CChar>?) -> String"
      [ .guardS ["let p"] [.ret (some (.lit ""))]
      , .deferS [s "free(p)"]
      , .ret (some (r "String(cString: p)")) ]
    , .blank
    , .fn "private func apply(_ reply: String)"
      [ .guardS ["let data = reply.data(using: .utf8)", "let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any]"] [.ret none]
      , .ifS ["let s = o[\"seq\"] as? Int"] [.set "seq" (r "s")] []
      , .ifS ["let v = o[\"view\"]"] [.set "view" (r "NativeNode(json: v)")] []
      , .ifS ["let e = o[\"error\"] as? String", "e != \"stale\""] [.set "failure" (r "e")] []
      , .forS "cap in o[\"caps\"] as? [[String: Any]] ?? []"
        [ .letS "id" (r "cap[\"id\"] as? Int ?? -1")
        , .e (.call (r "capabilities.run")
            [(some "name", r "cap[\"name\"] as? String ?? \"\""), (some "args", r "cap[\"args\"] as? [String: Any] ?? [:]")]
            [(none, .lam "result"
              [ .letS "answer: [String: Any]" (r "[\"id\": id, \"result\": result]")
              , serialize "answer"
              , s "line.withCString { elmlean_cap_result($0) }" ])]) ] ] ])

def storeFile : List Decl := [.imp "Foundation", .imp "Observation", store]

def app : Decl :=
  .doc "The whole iOS app of an ElmLean native app: the generic renderer around whatever view Lean returns.
An app ships no Swift of its own; its name comes from Info.plist (`CFBundleDisplayName`).
While the scene is not active the content is covered (app-switcher snapshots never show it)."
  (.ty "@main\nstruct ElmLeanNativeApp: App"
    [ .prop "@State private var store" (some (r "NativeStore()"))
    , .prop "@Environment(\\.scenePhase) private var scenePhase" none
    , .blank
    , .fn "var body: some Scene"
      [.e (cb "WindowGroup" [] ""
        [.e (.chain (cb "ZStack" [] ""
            [ .ifS ["let failure = store.failure"] [s "Text(failure).foregroundStyle(.red).padding()"] [s "NativeRoot(node: store.view)"]
            , .ifS ["scenePhase != .active"] [s "Color(.systemBackground).ignoresSafeArea()"] [] ])
          [ r "environment(store)"
          , .call (r "onChange") [(some "of", r "scenePhase"), (some "initial", r "true")] [(none, .lam "_, phase"
              [ .letS "name" (r "phase == .active ? \"active\" : phase == .background ? \"background\" : \"inactive\"")
              , s "store.system([\"scene\": name])" ])]
          , .call (r "onReceive") [(none, r "NotificationCenter.default.publisher(for: UIScreen.capturedDidChangeNotification)")]
              [(none, .lam "_" [s "store.system([\"captured\": UIScreen.main.isCaptured])"])] ])])] ])

def appFile : List Decl := [.imp "SwiftUI", app]

end ElmShell
