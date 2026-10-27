import Foundation

/// The view tree an ElmLean app emits (PROTOCOL.md, "Node grammar"), decoded from JSON. The renderer
/// knows only this grammar, never the app. An unknown `t` decodes as `.unknown` and renders as a visible
/// placeholder. Child `i` of a container is at `path + [i]`, in the order of `c`.
indirect enum NativeNode: Equatable, Sendable {
    enum Role: String, Sendable { case plain, primary, destructive }
    enum Style: String, Sendable { case title, body, caption }
    enum InputKind: String, Sendable { case plain, secure, multiline, number, decimal }

    case text(String, Style)
    case col([NativeNode])
    case row([NativeNode])
    case button(label: String, role: Role, enabled: Bool)
    case field(placeholder: String, value: String, submits: Bool)
    case toggle(label: String, on: Bool)
    case divider
    case spacer
    case input(kind: InputKind, label: String, placeholder: String, value: String, submits: Bool)
    case list([NativeNode])
    case section(header: String, footer: String, [NativeNode])
    case labeled(label: String, value: String)
    case screen(title: String, back: Bool, refreshable: Bool, [NativeNode])
    case toolbar([NativeNode])
    case tabs(labels: [String], icons: [String], selected: Int, [NativeNode])
    case sheet(title: String, dismissable: Bool, [NativeNode])
    case alert(title: String, message: String, [NativeNode])
    case picker(label: String, options: [String], selected: Int)
    case progress(String)
    case icon(String)
    case qr(String)
    case share(label: String, text: String, file: Bool)
    case link(label: String, url: String)
    case page(String)
    case empty(title: String, icon: String, message: String, [NativeNode])
    case disclosure(title: String, expanded: Bool, [NativeNode])
    case stepper(label: String, value: Int, lo: Int, hi: Int, detail: String)
    case unknown(String)

    init(json: Any?) {
        guard let o = json as? [String: Any] else { self = .unknown("not an object"); return }
        let t = o["t"] as? String ?? "?"
        func s(_ k: String) -> String { o[k] as? String ?? "" }
        func b(_ k: String) -> Bool { o[k] as? Bool ?? false }
        func n(_ k: String) -> Int { o[k] as? Int ?? 0 }
        func ss(_ k: String) -> [String] { o[k] as? [String] ?? [] }
        func kids() -> [NativeNode] { (o["c"] as? [Any] ?? []).map { NativeNode(json: $0) } }
        switch t {
        case "text": self = .text(s("s"), Style(rawValue: s("style")) ?? .body)
        case "col": self = .col(kids())
        case "row": self = .row(kids())
        case "button": self = .button(label: s("label"), role: Role(rawValue: s("role")) ?? .plain, enabled: o["enabled"] as? Bool ?? true)
        case "field": self = .field(placeholder: s("placeholder"), value: s("value"), submits: b("submits"))
        case "toggle": self = .toggle(label: s("label"), on: b("on"))
        case "divider": self = .divider
        case "spacer": self = .spacer
        case "input":
            self = .input(kind: InputKind(rawValue: s("kind")) ?? .plain, label: s("label"), placeholder: s("placeholder"),
                          value: s("value"), submits: b("submits"))
        case "list": self = .list(kids())
        case "section": self = .section(header: s("header"), footer: s("footer"), kids())
        case "labeled": self = .labeled(label: s("label"), value: s("value"))
        case "screen": self = .screen(title: s("title"), back: b("back"), refreshable: b("refreshable"), kids())
        case "toolbar": self = .toolbar(kids())
        case "tabs": self = .tabs(labels: ss("labels"), icons: ss("icons"), selected: n("selected"), kids())
        case "sheet": self = .sheet(title: s("title"), dismissable: b("dismissable"), kids())
        case "alert": self = .alert(title: s("title"), message: s("message"), kids())
        case "picker": self = .picker(label: s("label"), options: ss("options"), selected: n("selected"))
        case "progress": self = .progress(s("label"))
        case "icon": self = .icon(s("name"))
        case "qr": self = .qr(s("text"))
        case "share": self = .share(label: s("label"), text: s("text"), file: b("file"))
        case "link": self = .link(label: s("label"), url: s("url"))
        case "page": self = .page(s("path"))
        case "empty": self = .empty(title: s("title"), icon: s("icon"), message: s("message"), kids())
        case "disclosure": self = .disclosure(title: s("title"), expanded: b("expanded"), kids())
        case "stepper": self = .stepper(label: s("label"), value: n("value"), lo: n("lo"), hi: n("hi"), detail: s("detail"))
        default: self = .unknown(t)
        }
    }
}

/// Events the renderer sends (PROTOCOL.md, "Client → CLI").
enum NativeEvent {
    case click, submit, dismiss
    case input(String)
    case toggle(Bool)
    case select(Int)

    var json: [String: Any] {
        switch self {
        case .click: return ["k": "click"]
        case .submit: return ["k": "submit"]
        case .dismiss: return ["k": "dismiss"]
        case .input(let s): return ["k": "input", "value": s]
        case .toggle(let b): return ["k": "toggle", "value": b]
        case .select(let n): return ["k": "select", "value": n]
        }
    }
}
