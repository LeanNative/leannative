import Foundation
import Observation

/// The app's state as the shell sees it: the last view Lean returned and its `seq`. Every call into Lean
/// happens on the main actor except `elmlean_wait`, which blocks a background thread until Lean has
/// something queued; the main actor then drains it.
@MainActor @Observable
final class NativeStore {
    private(set) var view: NativeNode = .col([])
    private(set) var seq = 0
    private(set) var failure: String?
    @ObservationIgnored private let capabilities = Capabilities()

    init() {
        if elmlean_boot() != 0 { failure = "The app failed to start."; return }
        apply(take(elmlean_start()))
        let thread = Thread { [weak self] in
            while true {
                elmlean_wait()
                DispatchQueue.main.sync { self?.drain() }
            }
        }
        thread.stackSize = 8 << 20
        thread.start()
    }

    func send(path: [Int], event: NativeEvent) {
        let request: [String: Any] = ["seq": seq, "path": path, "event": event.json]
        guard let data = try? JSONSerialization.data(withJSONObject: request),
              let line = String(data: data, encoding: .utf8) else { return }
        apply(take(line.withCString { elmlean_event($0) }))
    }

    func drain() { apply(take(elmlean_drain())) }

    /// A system event (scene phase, screen capture) for the app's `system` mapping.
    func system(_ event: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: event),
              let line = String(data: data, encoding: .utf8) else { return }
        apply(take(line.withCString { elmlean_system($0) }))
    }

    private func take(_ p: UnsafeMutablePointer<CChar>?) -> String {
        guard let p else { return "" }
        defer { free(p) }
        return String(cString: p)
    }

    private func apply(_ reply: String) {
        guard let data = reply.data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        if let s = o["seq"] as? Int { seq = s }
        if let v = o["view"] { view = NativeNode(json: v) }
        if let e = o["error"] as? String, e != "stale" { failure = e }
        for cap in o["caps"] as? [[String: Any]] ?? [] {
            let id = cap["id"] as? Int ?? -1
            capabilities.run(name: cap["name"] as? String ?? "", args: cap["args"] as? [String: Any] ?? [:]) { result in
                let answer: [String: Any] = ["id": id, "result": result]
                guard let data = try? JSONSerialization.data(withJSONObject: answer),
                      let line = String(data: data, encoding: .utf8) else { return }
                line.withCString { elmlean_cap_result($0) }
            }
        }
    }
}
