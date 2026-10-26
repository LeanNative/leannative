import Foundation

/// Text styles a `text` node may carry. Unknown styles decode as `.body`.
enum TextStyle: String, Sendable, Equatable {
    case title, body, caption
}

/// The generic UI tree emitted by the CLI (PROTOCOL.md, "Node grammar").
/// The renderer knows only this grammar, never the application behind it.
indirect enum Node: Sendable, Equatable {
    /// Button roles. Nested so it cannot collide with `SwiftUI.ButtonRole`.
    enum Role: String, Sendable, Equatable {
        case plain, primary, destructive
    }

    case text(String, TextStyle)
    case col([Node])
    case row([Node])
    case button(label: String, role: Role, enabled: Bool)
    case field(placeholder: String, value: String, submits: Bool)
    case toggle(label: String, on: Bool)
    case divider
    case spacer
    case unknown(type: String)
}

extension Node {
    /// The node at `path` (child indices from the root, `[]` is the root), or nil when the path leaves
    /// the tree. Only `col` and `row` have children (PROTOCOL.md, "Client → CLI").
    func node(at path: [Int]) -> Node? {
        var current = self
        for index in path {
            let children: [Node]
            switch current {
            case .col(let c), .row(let c):
                children = c
            default:
                return nil
            }
            guard children.indices.contains(index) else { return nil }
            current = children[index]
        }
        return current
    }
}

extension Node: Decodable {
    private enum Keys: String, CodingKey {
        case t, s, style, c, label, role, enabled, placeholder, value, submits, on
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        let t = try c.decodeIfPresent(String.self, forKey: .t) ?? "?"
        switch t {
        case "text":
            let s = try c.decodeIfPresent(String.self, forKey: .s) ?? ""
            let style = try c.decodeIfPresent(String.self, forKey: .style)
                .flatMap(TextStyle.init(rawValue:)) ?? .body
            self = .text(s, style)
        case "col":
            self = .col(try c.decodeIfPresent([Node].self, forKey: .c) ?? [])
        case "row":
            self = .row(try c.decodeIfPresent([Node].self, forKey: .c) ?? [])
        case "button":
            let label = try c.decodeIfPresent(String.self, forKey: .label) ?? ""
            let role = try c.decodeIfPresent(String.self, forKey: .role)
                .flatMap(Role.init(rawValue:)) ?? .plain
            let enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
            self = .button(label: label, role: role, enabled: enabled)
        case "field":
            let placeholder = try c.decodeIfPresent(String.self, forKey: .placeholder) ?? ""
            let value = try c.decodeIfPresent(String.self, forKey: .value) ?? ""
            let submits = try c.decodeIfPresent(Bool.self, forKey: .submits) ?? false
            self = .field(placeholder: placeholder, value: value, submits: submits)
        case "toggle":
            let label = try c.decodeIfPresent(String.self, forKey: .label) ?? ""
            let on = try c.decodeIfPresent(Bool.self, forKey: .on) ?? false
            self = .toggle(label: label, on: on)
        case "divider":
            self = .divider
        case "spacer":
            self = .spacer
        default:
            // Renderers must show an unknown `t` as a visible placeholder, never fail.
            self = .unknown(type: t)
        }
    }
}

/// Events a renderer may send (PROTOCOL.md, "Client → CLI").
enum Event: Sendable, Equatable, Encodable {
    case click
    case submit
    case input(String)
    case toggle(Bool)

    private enum Keys: String, CodingKey { case k, value }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        switch self {
        case .click:
            try c.encode("click", forKey: .k)
        case .submit:
            try c.encode("submit", forKey: .k)
        case .input(let value):
            try c.encode("input", forKey: .k)
            try c.encode(value, forKey: .value)
        case .toggle(let on):
            try c.encode("toggle", forKey: .k)
            try c.encode(on, forKey: .value)
        }
    }

    var isInput: Bool {
        if case .input = self { return true }
        return false
    }
}

/// `POST /event` body.
struct EventRequest: Encodable, Sendable {
    let seq: Int
    let path: [Int]
    let event: Event
}

/// Every HTTP body the bridge returns decodes into this and nothing else (data, never code).
/// `seq` is optional because the 400 `{"error":"bad-request"}` body carries none.
struct ViewResponse: Decodable, Sendable {
    let seq: Int?
    let view: Node?
    let error: String?
    let detail: String?
}
