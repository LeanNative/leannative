import ElmShell.Swift

/-! # ElmShell.Capabilities: `Capabilities.swift`

One table row per capability: its name, the documentation of its arguments and result (printed as the
table in the class's doc comment), and the Swift that runs it, which answers through `answer`. The
dispatch on the name is printed from the same rows, so a documented capability is a handled one. -/

namespace ElmShell

structure Capability where
  name : String
  args : String
  result : String
  body : List Stmt

def ans (dict : String) : Stmt := s s!"answer({dict})"

/-- `answer(["ok": …, "status": Int(status)])` for a Keychain call whose "not found" is success or not. -/
def statusAnswer (notFoundOk : Bool) : Stmt :=
  ans s!"[\"ok\": status == errSecSuccess{if notFoundOk then " || status == errSecItemNotFound" else ""}, \"status\": Int(status)]"

def capabilities : List Capability :=
  [ { name := "auth", args := "`reason`", result := "`{\"ok\":true}` or `{\"ok\":false,\"error\":…}` (device-owner authentication)"
      body :=
        [ .letS "context" (r "LAContext()")
        , s "var unavailable: NSError?"
        , .guardS ["context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &unavailable)"]
            [ .ifdef "targetEnvironment(simulator)" [ans "[\"ok\": true, \"note\": \"simulator without a passcode\"]"]
                [ans "[\"ok\": false, \"error\": \"Set a device passcode first.\"]"]
            , .ret none ]
        , .letS "reason" (r "args[\"reason\"] as? String ?? \"Confirm\"")
        , .e (.call (r "context.evaluatePolicy") [(none, r ".deviceOwnerAuthentication"), (some "localizedReason", r "reason")]
            [(none, .lam "ok, error"
              [ .letS "result: [String: Any]" (r "ok ? [\"ok\": true] : [\"ok\": false, \"error\": error?.localizedDescription ?? \"Authentication failed.\"]")
              , s "DispatchQueue.main.async { answer(result) }" ])]) ] }
  , { name := "keychain.get", args := "`key`, `service`?", result := "`{\"value\":…}` or `{\"value\":null}` (`service` defaults to the bundle id)"
      body :=
        [ .varS "query" (r "base(args)")
        , .set "query[kSecReturnData as String]" (r "true")
        , s "var out: CFTypeRef?"
        , .letS "status" (r "SecItemCopyMatching(query as CFDictionary, &out)")
        , .ifS ["status == errSecSuccess", "let data = out as? Data", "let s = String(data: data, encoding: .utf8)"]
            [ans "[\"value\": s]"] [ans "[\"value\": NSNull()]"] ] }
  , { name := "keychain.set", args := "`key`, `value`, `service`?", result := "`{\"ok\":…,\"status\":…}` (the `OSStatus`); this device only, while unlocked"
      body :=
        [ .letS "data" (r "Data((args[\"value\"] as? String ?? \"\").utf8)")
        , s "SecItemDelete(base(args) as CFDictionary)"
        , .varS "query" (r "base(args)")
        , .set "query[kSecValueData as String]" (r "data")
        , .set "query[kSecAttrAccessible as String]" (r "kSecAttrAccessibleWhenUnlockedThisDeviceOnly")
        , .letS "status" (r "SecItemAdd(query as CFDictionary, nil)")
        , statusAnswer false ] }
  , { name := "keychain.delete", args := "`key`, `service`?", result := "`{\"ok\":…,\"status\":…}`"
      body := [ .letS "status" (r "SecItemDelete(base(args) as CFDictionary)"), statusAnswer true ] }
  , { name := "keychain.clear", args := "`service`", result := "`{\"ok\":…,\"status\":…}` deletes every item of that service (a test namespace's reset)"
      body :=
        [ .guardS ["let svc = args[\"service\"] as? String", "!svc.isEmpty"] [ans "[\"ok\": false, \"status\": Int(errSecParam)]", .ret none]
        , .letS "status" (r "SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: svc] as CFDictionary)")
        , statusAnswer true ] }
  , { name := "build", args := "—", result := "`{\"debug\":…}` whether this is a Debug build (`#if DEBUG`): test hooks stay off in Release"
      body := [.ifdef "DEBUG" [ans "[\"debug\": true]"] [ans "[\"debug\": false]"]] }
  , { name := "clipboard.set", args := "`text`, `localOnly`, `expiresIn` (s)", result := "`{\"ok\":true}`"
      body :=
        [ .comment "`localOnly` keeps it off Universal Clipboard; `expiresIn` (seconds) clears it afterwards"
        , .varS "options: [UIPasteboard.OptionsKey: Any]" (r "[:]")
        , .ifS ["args[\"localOnly\"] as? Bool == true"] [.set "options[.localOnly]" (r "true")] []
        , .ifS ["let seconds = args[\"expiresIn\"] as? Int"] [.set "options[.expirationDate]" (r "Date().addingTimeInterval(TimeInterval(seconds))")] []
        , s "UIPasteboard.general.setItems([[UIPasteboard.typeAutomatic: args[\"text\"] as? String ?? \"\"]], options: options)"
        , ans "[\"ok\": true]" ] }
  , { name := "clipboard.get", args := "—", result := "`{\"text\":…}`"
      body := [ans "[\"text\": UIPasteboard.general.string ?? NSNull()]"] }
  , { name := "documents", args := "—", result := "`{\"path\":…}` the app's Documents directory"
      body := [ans "[\"path\": FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.path ?? \"\"]"] }
  , { name := "paths", args := "—", result := "`{\"documents\",\"support\",\"tmp\"}`: Documents, Application Support (created), temporary"
      body :=
        [ .letS "fm" (r "FileManager.default")
        , .letS "support" (r "fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first")
        , .ifS ["let support"] [s "try? fm.createDirectory(at: support, withIntermediateDirectories: true)"] []
        , ans "[\"documents\": fm.urls(for: .documentDirectory, in: .userDomainMask).first?.path ?? \"\",\n                    \"support\": support?.path ?? \"\", \"tmp\": fm.temporaryDirectory.path]" ] }
  , { name := "exclude-from-backup", args := "`path`, `complete`?"
      result := "`{\"ok\":…}` marks a file or directory as excluded from iCloud/device backup; with `complete`, also `FileProtectionType.complete` (readable only while unlocked)"
      body :=
        [ .varS "url" (r "URL(fileURLWithPath: args[\"path\"] as? String ?? \"\")")
        , .varS "values" (r "URLResourceValues()")
        , .set "values.isExcludedFromBackup" (r "true")
        , .varS "ok" (r "(try? url.setResourceValues(values)) != nil")
        , .ifS ["ok", "args[\"complete\"] as? Bool == true"]
            [.set "ok" (r "(try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: url.path)) != nil")] []
        , ans "[\"ok\": ok]" ] }
  , { name := "http.get", args := "`url`, `maxBytes`, `timeout` (s), `accept`?"
      result := "`{\"status\":…,\"body\":hex}` or `{\"error\":…}`; ephemeral session, no cookies or cache, redirects only within the same host and never from https to http"
      body :=
        [ .guardS ["let url = URL(string: args[\"url\"] as? String ?? \"\")", "[\"http\", \"https\"].contains(url.scheme?.lowercased() ?? \"\")"]
            [ans "[\"error\": \"bad-url\"]", .ret none]
        , .letS "maxBytes" (r "args[\"maxBytes\"] as? Int ?? 1_000_000")
        , .varS "request" (r "URLRequest(url: url)")
        , .set "request.timeoutInterval" (r "TimeInterval(args[\"timeout\"] as? Int ?? 30)")
        , .ifS ["let accept = args[\"accept\"] as? String"] [s "request.setValue(accept, forHTTPHeaderField: \"Accept\")"] []
        , .e (.chain (.call (r "HTTPFetch.shared.session.dataTask") [(some "with", r "request")]
              [(none, .lam "data, response, error"
                [ s "let result: [String: Any]"
                , .ifS ["let error"] [.set "result" (r "[\"error\": error.localizedDescription]")]
                    [.ifS ["let http = response as? HTTPURLResponse", "let data"]
                      [.set "result" (r "data.count > maxBytes ? [\"error\": \"tooLarge\"]\n                        : [\"status\": http.statusCode, \"body\": data.map { String(format: \"%02x\", $0) }.joined()]")]
                      [.set "result" (r "[\"error\": \"response\"]")]]
                , s "DispatchQueue.main.async { answer(result) }" ])])
            [r "resume()"]) ] }
  , { name := "open", args := "`url`", result := "`{\"ok\":…}` opens the URL outside the app"
      body :=
        [ .ifS ["let url = URL(string: args[\"url\"] as? String ?? \"\")"]
            [s "UIApplication.shared.open(url)", ans "[\"ok\": true]"] [ans "[\"ok\": false]"] ] } ]

def capabilitiesDoc : String :=
  "What only iOS can do, offered to every ElmLean native app by name. The app asks with
`Effects.cap name args`; the answer goes back as JSON. Nothing here knows the app.

| name | args | result |
|---|---|---|
" ++ "\n".intercalate (capabilities.map fun c => s!"| `{c.name}` | {c.args} | {c.result} |")

def capabilitiesClass : Decl :=
  .doc capabilitiesDoc
  (.ty "@MainActor\nfinal class Capabilities"
    [ .prop "let service" (some (r "Bundle.main.bundleIdentifier ?? \"elmlean\""))
    , .blank
    , .fn "func run(name: String, args: [String: Any], answer: @escaping @MainActor ([String: Any]) -> Void)"
      [.switchS (r "name") (capabilities.map (fun c => (s!"\"{c.name}\"", c.body)) ++
        [("default", [ans "[\"error\": \"unknown capability \\(name)\"]"])])]
    , .blank
    , .doc "The item named by `key` within `service` (the app's bundle id unless the app names one)."
      (.fn "private func base(_ args: [String: Any]) -> [String: Any]"
        [s "[kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: args[\"service\"] as? String ?? service,\n         kSecAttrAccount as String: args[\"key\"] as? String ?? \"\"]"]) ])

def httpFetch : Decl :=
  .doc "One ephemeral URLSession for `http.get`: no cookies, no cache, redirects only within the same host and
never from https down to http."
  (.ty "final class HTTPFetch: NSObject, URLSessionTaskDelegate, @unchecked Sendable"
    [ .prop "static let shared" (some (r "HTTPFetch()"))
    , .prop "private(set) lazy var session: URLSession" (some (.call (.lam ""
        [ .letS "config" (r "URLSessionConfiguration.ephemeral")
        , .set "config.httpShouldSetCookies" (r "false")
        , .set "config.httpCookieStorage" (r "nil")
        , .set "config.urlCache" (r "nil")
        , .set "config.requestCachePolicy" (r ".reloadIgnoringLocalCacheData")
        , .set "config.timeoutIntervalForResource" (r "120")
        , .ret (some (r "URLSession(configuration: config, delegate: self, delegateQueue: nil)")) ]) [] []))
    , .blank
    , .fn "func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,\n                newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void)"
      [ .guardS ["let to = request.url, let from = response.url",
                 "to.host?.lowercased() == from.host?.lowercased()",
                 "!(from.scheme == \"https\" && to.scheme != \"https\")"] [s "completionHandler(nil)", .ret none]
      , s "completionHandler(request)" ] ])

def capabilitiesFile : List Decl :=
  [.imp "Foundation", .imp "LocalAuthentication", .imp "Security", .imp "UIKit", capabilitiesClass, httpFetch]

end ElmShell
