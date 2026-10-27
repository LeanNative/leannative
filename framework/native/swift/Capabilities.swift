import Foundation
import LocalAuthentication
import Security
import UIKit

/// What only iOS can do, offered to every ElmLean native app by name. The app asks with
/// `Effects.cap name args`; the answer goes back as JSON. Nothing here knows the app.
///
/// | name | args | result |
/// |---|---|---|
/// | `auth` | `reason` | `{"ok":true}` or `{"ok":false,"error":…}` (device-owner authentication) |
/// | `keychain.get` | `key`, `service`? | `{"value":…}` or `{"value":null}` (`service` defaults to the bundle id) |
/// | `keychain.set` | `key`, `value`, `service`? | `{"ok":…,"status":…}` (the `OSStatus`); this device only, while unlocked |
/// | `keychain.delete` | `key`, `service`? | `{"ok":…,"status":…}` |
/// | `keychain.clear` | `service` | `{"ok":…,"status":…}` deletes every item of that service (a test namespace's reset) |
/// | `build` | — | `{"debug":…}` whether this is a Debug build (`#if DEBUG`): test hooks stay off in Release |
/// | `clipboard.set` | `text`, `localOnly`, `expiresIn` (s) | `{"ok":true}` |
/// | `clipboard.get` | — | `{"text":…}` |
/// | `documents` | — | `{"path":…}` the app's Documents directory |
/// | `paths` | — | `{"documents","support","tmp"}`: Documents, Application Support (created), temporary |
/// | `exclude-from-backup` | `path`, `complete`? | `{"ok":…}` marks a file or directory as excluded from iCloud/device backup; with `complete`, also `FileProtectionType.complete` (readable only while unlocked) |
/// | `http.get` | `url`, `maxBytes`, `timeout` (s), `accept`? | `{"status":…,"body":hex}` or `{"error":…}`; ephemeral session, no cookies or cache, redirects only within the same host and never from https to http |
/// | `open` | `url` | `{"ok":…}` opens the URL outside the app |
@MainActor
final class Capabilities {
    let service = Bundle.main.bundleIdentifier ?? "elmlean"

    func run(name: String, args: [String: Any], answer: @escaping @MainActor ([String: Any]) -> Void) {
        switch name {
        case "auth":
            let context = LAContext()
            var unavailable: NSError?
            guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &unavailable) else {
                #if targetEnvironment(simulator)
                answer(["ok": true, "note": "simulator without a passcode"])
                #else
                answer(["ok": false, "error": "Set a device passcode first."])
                #endif
                return
            }
            let reason = args["reason"] as? String ?? "Confirm"
            context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { ok, error in
                let result: [String: Any] = ok ? ["ok": true] : ["ok": false, "error": error?.localizedDescription ?? "Authentication failed."]
                DispatchQueue.main.async { answer(result) }
            }
        case "keychain.get":
            var query = base(args)
            query[kSecReturnData as String] = true
            var out: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &out)
            if status == errSecSuccess, let data = out as? Data, let s = String(data: data, encoding: .utf8) {
                answer(["value": s])
            } else {
                answer(["value": NSNull()])
            }
        case "keychain.set":
            let data = Data((args["value"] as? String ?? "").utf8)
            SecItemDelete(base(args) as CFDictionary)
            var query = base(args)
            query[kSecValueData as String] = data
            query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let status = SecItemAdd(query as CFDictionary, nil)
            answer(["ok": status == errSecSuccess, "status": Int(status)])
        case "keychain.delete":
            let status = SecItemDelete(base(args) as CFDictionary)
            answer(["ok": status == errSecSuccess || status == errSecItemNotFound, "status": Int(status)])
        case "keychain.clear":
            guard let svc = args["service"] as? String, !svc.isEmpty else { answer(["ok": false, "status": Int(errSecParam)]); return }
            let status = SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: svc] as CFDictionary)
            answer(["ok": status == errSecSuccess || status == errSecItemNotFound, "status": Int(status)])
        case "build":
            #if DEBUG
            answer(["debug": true])
            #else
            answer(["debug": false])
            #endif
        case "clipboard.set":
            // `localOnly` keeps it off Universal Clipboard; `expiresIn` (seconds) clears it afterwards
            var options: [UIPasteboard.OptionsKey: Any] = [:]
            if args["localOnly"] as? Bool == true { options[.localOnly] = true }
            if let seconds = args["expiresIn"] as? Int { options[.expirationDate] = Date().addingTimeInterval(TimeInterval(seconds)) }
            UIPasteboard.general.setItems([[UIPasteboard.typeAutomatic: args["text"] as? String ?? ""]], options: options)
            answer(["ok": true])
        case "clipboard.get":
            answer(["text": UIPasteboard.general.string ?? NSNull()])
        case "documents":
            answer(["path": FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.path ?? ""])
        case "paths":
            let fm = FileManager.default
            let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            if let support { try? fm.createDirectory(at: support, withIntermediateDirectories: true) }
            answer(["documents": fm.urls(for: .documentDirectory, in: .userDomainMask).first?.path ?? "",
                    "support": support?.path ?? "", "tmp": fm.temporaryDirectory.path])
        case "exclude-from-backup":
            var url = URL(fileURLWithPath: args["path"] as? String ?? "")
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var ok = (try? url.setResourceValues(values)) != nil
            if ok, args["complete"] as? Bool == true {
                ok = (try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: url.path)) != nil
            }
            answer(["ok": ok])
        case "http.get":
            guard let url = URL(string: args["url"] as? String ?? ""), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
                answer(["error": "bad-url"]); return
            }
            let maxBytes = args["maxBytes"] as? Int ?? 1_000_000
            var request = URLRequest(url: url)
            request.timeoutInterval = TimeInterval(args["timeout"] as? Int ?? 30)
            if let accept = args["accept"] as? String { request.setValue(accept, forHTTPHeaderField: "Accept") }
            HTTPFetch.shared.session.dataTask(with: request) { data, response, error in
                let result: [String: Any]
                if let error {
                    result = ["error": error.localizedDescription]
                } else if let http = response as? HTTPURLResponse, let data {
                    result = data.count > maxBytes ? ["error": "tooLarge"]
                        : ["status": http.statusCode, "body": data.map { String(format: "%02x", $0) }.joined()]
                } else {
                    result = ["error": "response"]
                }
                DispatchQueue.main.async { answer(result) }
            }.resume()
        case "open":
            if let url = URL(string: args["url"] as? String ?? "") {
                UIApplication.shared.open(url)
                answer(["ok": true])
            } else {
                answer(["ok": false])
            }
        default:
            answer(["error": "unknown capability \(name)"])
        }
    }

    /// The item named by `key` within `service` (the app's bundle id unless the app names one).
    private func base(_ args: [String: Any]) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: args["service"] as? String ?? service,
         kSecAttrAccount as String: args["key"] as? String ?? ""]
    }
}

/// One ephemeral URLSession for `http.get`: no cookies, no cache, redirects only within the same host and
/// never from https down to http.
final class HTTPFetch: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static let shared = HTTPFetch()
    private(set) lazy var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieStorage = nil
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForResource = 120
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let to = request.url, let from = response.url,
              to.host?.lowercased() == from.host?.lowercased(),
              !(from.scheme == "https" && to.scheme != "https") else { completionHandler(nil); return }
        completionHandler(request)
    }
}
