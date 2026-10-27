// ElmLean Swift runtime for the differential test CLI.
//
// Generic over the app: the generated code supplies an `ElmApp` (initial model, update, view) and this file
// supplies everything else: the `Html` tree with handlers (a mirror of Lean's `Html msg`), dispatch by path,
// erasure to the wire grammar of PROTOCOL.md, a JSON reader that implements the number rule exactly
// (`seq` and path elements are JSON numbers whose VALUE is a non-negative integer), and the stdin/stdout
// loop of `Session.handle` (one reply line per request line; error precedence bad-json > stale > bad-path >
// no-handler; `{"reset":true}` restores the initial model; exit 0 at EOF).
//
// Build:  swiftc -O -o elmlean-swift Runtime.swift <generated files> main.swift
// where main.swift contains:  runElmCli(TodoApp.self)

import Foundation

// MARK: - UI language (mirror of ElmLean.Html)

enum TextStyle: String { case title, body, caption }
enum ButtonRole: String { case plain, primary, destructive }

indirect enum Html<Msg> {
    case text(String, TextStyle)
    case col([Html<Msg>])
    case row([Html<Msg>])
    case button(label: String, role: ButtonRole, onClick: Msg?)
    case field(placeholder: String, value: String, onInput: (String) -> Msg, onSubmit: Msg?)
    case toggle(label: String, on: Bool, onToggle: (Bool) -> Msg)
    case divider
    case spacer

    var children: [Html<Msg>] {
        switch self {
        case .col(let cs), .row(let cs): return cs
        default: return []
        }
    }

    func at(_ path: [Int]) -> Html<Msg>? {
        var cur = self
        for i in path {
            let cs = cur.children
            guard i >= 0, i < cs.count else { return nil }
            cur = cs[i]
        }
        return cur
    }

    func handle(_ e: Event) -> Msg? {
        switch (self, e) {
        case (.button(_, _, let c), .click): return c
        case (.field(_, _, let f, _), .input(let s)): return f(s)
        case (.field(_, _, _, let s), .submit): return s
        case (.toggle(_, _, let f), .toggle(let b)): return f(b)
        default: return nil
        }
    }

    /// Erase handlers: the exact JSON of PROTOCOL.md's node grammar, keys in alphabetical order.
    func wireJSON() -> String {
        switch self {
        case .text(let s, let st): return "{\"s\":\(q(s)),\"style\":\"\(st.rawValue)\",\"t\":\"text\"}"
        case .col(let cs): return "{\"c\":[\(cs.map { $0.wireJSON() }.joined(separator: ","))],\"t\":\"col\"}"
        case .row(let cs): return "{\"c\":[\(cs.map { $0.wireJSON() }.joined(separator: ","))],\"t\":\"row\"}"
        case .button(let l, let r, let c):
            return "{\"enabled\":\(c != nil),\"label\":\(q(l)),\"role\":\"\(r.rawValue)\",\"t\":\"button\"}"
        case .field(let p, let v, _, let s):
            return "{\"placeholder\":\(q(p)),\"submits\":\(s != nil),\"t\":\"field\",\"value\":\(q(v))}"
        case .toggle(let l, let on, _): return "{\"label\":\(q(l)),\"on\":\(on),\"t\":\"toggle\"}"
        case .divider: return "{\"t\":\"divider\"}"
        case .spacer: return "{\"t\":\"spacer\"}"
        }
    }
}

enum Event {
    case click
    case input(String)
    case submit
    case toggle(Bool)
}

/// JSON string literal with the escapes JSON requires (non-ASCII stays raw UTF-8, like Lean's `Json.compress`).
func q(_ s: String) -> String {
    var out = "\""
    for u in s.unicodeScalars {
        switch u {
        case "\"": out += "\\\""
        case "\\": out += "\\\\"
        case "\n": out += "\\n"
        case "\r": out += "\\r"
        case "\t": out += "\\t"
        default:
            if u.value < 0x20 { out += String(format: "\\u%04x", u.value) } else { out.unicodeScalars.append(u) }
        }
    }
    return out + "\""
}

// MARK: - The app contract the generated code fulfils

protocol ElmApp {
    associatedtype Model
    associatedtype Msg
    static var initial: Model { get }
    static func update(_ msg: Msg, _ m: Model) -> Model
    static func view(_ m: Model) -> Html<Msg>
}

// MARK: - Minimal JSON reader with the number rule

/// A JSON number as written: sign, digits, and a decimal exponent, never materialised.
struct JNum {
    var negative = false
    var mantissa: [UInt8] = []   // ASCII digits (integer part + fraction); leading zeros stripped later
    var exp = 0                  // decimal exponent relative to the full mantissa
    var expHuge = 0              // +1 / -1 when the exponent did not fit an Int

    /// The non-negative integer VALUE, or nil when the number is not one (PROTOCOL.md number rule).
    /// `.huge` stands for an integer value above Int range (such a seq is never current; such an index
    /// is never inside a view).
    enum Nat { case small(Int), huge }
    var natValue: Nat? {
        let zero = UInt8(ascii: "0")
        var lo = 0
        while lo < mantissa.count, mantissa[lo] == zero { lo += 1 }
        if lo == mantissa.count { return .small(0) }     // zero, whatever the sign or exponent
        if negative { return nil }
        if expHuge > 0 { return .huge }
        if expHuge < 0 { return nil }                   // 1e-(huge): a fraction
        var hi = mantissa.count                         // digits are mantissa[lo..<hi]
        var e = exp
        if e < 0 {                                      // 10^-e must divide the mantissa: strip trailing zeros
            if hi - lo < -e { return nil }
            for k in 1...(-e) where mantissa[hi - k] != zero { return nil }
            hi += e
            e = 0
        }
        if (hi - lo) + e > 18 { return .huge }
        var v = 0
        for k in lo..<hi { v = v * 10 + Int(mantissa[k] - zero) }
        for _ in 0..<e { v *= 10 }
        return .small(v)
    }
}

indirect enum JSON {
    case object([(String, JSON)])
    case array([JSON])
    case string(String)
    case number(JNum)
    case bool(Bool)
    case null

    /// The value of `key`, as Lean's `Json.getObjVal?` sees it: keys compare exactly (code point by code
    /// point, not by Swift's canonical equivalence) and a repeated key keeps its last value.
    subscript(key: String) -> JSON? {
        if case .object(let kvs) = self { return kvs.last(where: { $0.0.unicodeScalars.elementsEqual(key.unicodeScalars) })?.1 }
        return nil
    }
}

struct JSONReader {
    let s: [UInt8]
    var i = 0
    init(_ text: String) { s = Array(text.utf8) }

    struct Err: Error { let what: String }

    mutating func parseDocument() throws -> JSON {
        skipWS()
        let v = try parseValue()
        skipWS()
        guard i == s.count else { throw Err(what: "trailing characters") }
        return v
    }

    mutating func skipWS() { while i < s.count, [0x20, 0x09, 0x0a, 0x0d].contains(s[i]) { i += 1 } }

    mutating func parseValue() throws -> JSON {
        guard i < s.count else { throw Err(what: "unexpected end") }
        switch s[i] {
        case UInt8(ascii: "{"): return try parseObject()
        case UInt8(ascii: "["): return try parseArray()
        case UInt8(ascii: "\""): return .string(try parseString())
        case UInt8(ascii: "t"): try expect("true"); return .bool(true)
        case UInt8(ascii: "f"): try expect("false"); return .bool(false)
        case UInt8(ascii: "n"): try expect("null"); return .null
        default: return .number(try parseNumber())
        }
    }

    mutating func expect(_ word: String) throws {
        let w = Array(word.utf8)
        guard i + w.count <= s.count, Array(s[i..<i + w.count]) == w else { throw Err(what: "bad literal") }
        i += w.count
    }

    mutating func parseObject() throws -> JSON {
        i += 1
        var kvs: [(String, JSON)] = []
        skipWS()
        if i < s.count, s[i] == UInt8(ascii: "}") { i += 1; return .object(kvs) }
        while true {
            skipWS()
            guard i < s.count, s[i] == UInt8(ascii: "\"") else { throw Err(what: "key expected") }
            let k = try parseString()
            skipWS()
            guard i < s.count, s[i] == UInt8(ascii: ":") else { throw Err(what: "colon expected") }
            i += 1
            skipWS()
            let v = try parseValue()
            kvs.append((k, v))
            skipWS()
            guard i < s.count else { throw Err(what: "unterminated object") }
            if s[i] == UInt8(ascii: ",") { i += 1; continue }
            if s[i] == UInt8(ascii: "}") { i += 1; return .object(kvs) }
            throw Err(what: "bad object")
        }
    }

    mutating func parseArray() throws -> JSON {
        i += 1
        var items: [JSON] = []
        skipWS()
        if i < s.count, s[i] == UInt8(ascii: "]") { i += 1; return .array(items) }
        while true {
            skipWS()
            items.append(try parseValue())
            skipWS()
            guard i < s.count else { throw Err(what: "unterminated array") }
            if s[i] == UInt8(ascii: ",") { i += 1; continue }
            if s[i] == UInt8(ascii: "]") { i += 1; return .array(items) }
            throw Err(what: "bad array")
        }
    }

    mutating func parseString() throws -> String {
        i += 1
        var bytes: [UInt8] = []
        while i < s.count {
            let c = s[i]
            if c == UInt8(ascii: "\"") { i += 1; return String(decoding: bytes, as: UTF8.self) }
            if c == UInt8(ascii: "\\") {
                i += 1
                guard i < s.count else { break }
                let e = s[i]
                i += 1
                switch e {
                case UInt8(ascii: "\""): bytes.append(0x22)
                case UInt8(ascii: "\\"): bytes.append(0x5c)
                case UInt8(ascii: "/"): bytes.append(0x2f)
                case UInt8(ascii: "b"): bytes.append(0x08)
                case UInt8(ascii: "f"): bytes.append(0x0c)
                case UInt8(ascii: "n"): bytes.append(0x0a)
                case UInt8(ascii: "r"): bytes.append(0x0d)
                case UInt8(ascii: "t"): bytes.append(0x09)
                case UInt8(ascii: "u"):
                    var scalar = try parseHex4()
                    if (0xD800...0xDBFF).contains(scalar), i + 1 < s.count, s[i] == UInt8(ascii: "\\"), s[i + 1] == UInt8(ascii: "u") {
                        i += 2
                        let lo = try parseHex4()
                        if (0xDC00...0xDFFF).contains(lo) { scalar = 0x10000 + ((scalar - 0xD800) << 10) + (lo - 0xDC00) }
                        else { throw Err(what: "bad surrogate") }
                    }
                    guard let u = Unicode.Scalar(scalar) else { throw Err(what: "bad scalar") }
                    bytes.append(contentsOf: Array(String(Character(u)).utf8))
                default: throw Err(what: "bad escape")
                }
                continue
            }
            if c < 0x20 { throw Err(what: "control character in string") }
            bytes.append(c)
            i += 1
        }
        throw Err(what: "unterminated string")
    }

    mutating func parseHex4() throws -> UInt32 {
        guard i + 4 <= s.count else { throw Err(what: "bad \\u") }
        var v: UInt32 = 0
        for _ in 0..<4 {
            let c = s[i]
            i += 1
            v <<= 4
            switch c {
            case 0x30...0x39: v |= UInt32(c - 0x30)
            case 0x41...0x46: v |= UInt32(c - 0x41 + 10)
            case 0x61...0x66: v |= UInt32(c - 0x61 + 10)
            default: throw Err(what: "bad hex")
            }
        }
        return v
    }

    mutating func parseNumber() throws -> JNum {
        var n = JNum()
        if i < s.count, s[i] == UInt8(ascii: "-") { n.negative = true; i += 1 }
        var intDigits: [UInt8] = []
        while i < s.count, (0x30...0x39).contains(s[i]) { intDigits.append(s[i]); i += 1 }
        guard !intDigits.isEmpty else { throw Err(what: "digit expected") }
        if intDigits.count > 1, intDigits[0] == UInt8(ascii: "0") { throw Err(what: "leading zero") }
        var frac: [UInt8] = []
        if i < s.count, s[i] == UInt8(ascii: ".") {
            i += 1
            while i < s.count, (0x30...0x39).contains(s[i]) { frac.append(s[i]); i += 1 }
            guard !frac.isEmpty else { throw Err(what: "fraction digits expected") }
        }
        var exp = 0
        var expHuge = 0
        if i < s.count, s[i] == UInt8(ascii: "e") || s[i] == UInt8(ascii: "E") {
            i += 1
            var neg = false
            if i < s.count, s[i] == UInt8(ascii: "+") { i += 1 } else if i < s.count, s[i] == UInt8(ascii: "-") { neg = true; i += 1 }
            var digits: [UInt8] = []
            while i < s.count, (0x30...0x39).contains(s[i]) { digits.append(s[i]); i += 1 }
            guard !digits.isEmpty else { throw Err(what: "exponent digits expected") }
            let stripped = digits.drop(while: { $0 == UInt8(ascii: "0") })
            if stripped.count > 15 { expHuge = neg ? -1 : 1 }
            else { var v = 0; for d in stripped { v = v * 10 + Int(d - UInt8(ascii: "0")) }; exp = neg ? -v : v }
        }
        n.mantissa = intDigits + frac
        n.exp = exp - frac.count
        n.expHuge = expHuge
        if n.expHuge != 0, n.mantissa.allSatisfy({ $0 == UInt8(ascii: "0") }) { n.expHuge = 0; n.exp = 0 }
        return n
    }
}

// MARK: - Session (mirror of ElmLean.Session.handle) and the stdin/stdout loop

struct Request {
    let seq: JNum.Nat
    let path: [JNum.Nat]
    let event: Event
}

enum Parsed {
    case request(Request)
    case reset
    case bad(String)
}

func parseLine(_ line: String) -> Parsed {
    var r = JSONReader(line)
    let j: JSON
    do { j = try r.parseDocument() } catch let e as JSONReader.Err { return .bad(e.what) } catch { return .bad("parse") }
    guard case .object = j else { return .bad("object expected") }
    if case .bool(true)? = j["reset"] { return .reset }
    guard let sj = j["seq"], case .number(let sn) = sj, let seq = sn.natValue else { return .bad("seq: natural number expected") }
    guard let pj = j["path"], case .array(let items) = pj else { return .bad("path: array expected") }
    var path: [JNum.Nat] = []
    for it in items {
        guard case .number(let n) = it, let v = n.natValue else { return .bad("path: natural number expected") }
        path.append(v)
    }
    guard let ej = j["event"], case .object = ej, let kj = ej["k"], case .string(let k) = kj else { return .bad("event: kind expected") }
    let event: Event
    switch k {
    case "click": event = .click
    case "submit": event = .submit
    case "input":
        guard let vj = ej["value"], case .string(let v) = vj else { return .bad("input: string value expected") }
        event = .input(v)
    case "toggle":
        guard let vj = ej["value"], case .bool(let b) = vj else { return .bad("toggle: bool value expected") }
        event = .toggle(b)
    default: return .bad("unknown event kind")
    }
    return .request(Request(seq: seq, path: path, event: event))
}

final class Session<App: ElmApp> {
    var seq = 0
    var model: App.Model
    var lastView: Html<App.Msg>

    init() {
        model = App.initial
        lastView = App.view(model)
    }

    func viewReply() -> String { "{\"seq\":\(seq),\"view\":\(lastView.wireJSON())}" }
    func errorReply(_ code: String, detail: String? = nil, withView: Bool = false) -> String {
        var s = "{"
        if let d = detail { s += "\"detail\":\(q(d))," }
        s += "\"error\":\"\(code)\",\"seq\":\(seq)"
        if withView { s += ",\"view\":\(lastView.wireJSON())" }
        return s + "}"
    }

    func handle(_ line: String) -> String {
        switch parseLine(line) {
        case .bad(let why):
            return errorReply("bad-json", detail: why)
        case .reset:
            model = App.initial
            lastView = App.view(model)
            seq += 1
            return viewReply()
        case .request(let r):
            guard case .small(let s) = r.seq, s == seq else { return errorReply("stale", withView: true) }
            var ints: [Int] = []
            for p in r.path {
                guard case .small(let i) = p else { return errorReply("bad-path") }
                ints.append(i)
            }
            guard let node = lastView.at(ints) else { return errorReply("bad-path") }
            guard let msg = node.handle(r.event) else { return errorReply("no-handler") }
            model = App.update(msg, model)
            lastView = App.view(model)
            seq += 1
            return viewReply()
        }
    }
}

func emit(_ line: String) {
    FileHandle.standardOutput.write((line + "\n").data(using: .utf8)!)
}

/// The CLI: initial view, then exactly one reply per input line until EOF.
func runElmCli<App: ElmApp>(_ app: App.Type) -> Never {
    let session = Session<App>()
    emit(session.viewReply())
    while let line = readLine(strippingNewline: true) {
        emit(session.handle(line))
    }
    exit(0)
}

// MARK: - Apps with commands (mirror of ElmLean.CmdApp and Session.step)

extension JSON {
    /// Generated codecs ask through these two instead of matching `.object(let kvs)` themselves: binding that
    /// payload from another file trips a "circular reference" in the Swift 6 type checker (Xcode 27.1).
    var isObject: Bool {
        if case .object = self { return true }
        return false
    }
    /// The one key and value of an object with one distinct key (a repeated key keeps its last value, as in
    /// Lean's parser): how Lean encodes a constructor with fields.
    var onlyEntry: (key: String, value: JSON)? {
        guard case .object(let kvs) = self, let last = kvs.last,
              kvs.allSatisfy({ $0.0.unicodeScalars.elementsEqual(last.0.unicodeScalars) }) else { return nil }
        return (last.0, last.1)
    }
    /// Whether the object has `key` at all (a constructor payload must have every field, `Option` ones included).
    func hasKey(_ key: String) -> Bool { self[key] != nil }
}

/// A value that crosses the JSON boundary between an app and its host in the format of Lean's derived
/// `ToJson` / `FromJson`. elmgen prints the conformance of every command and host-answer type.
protocol LeanCodable {
    func leanJSON() -> String
    /// `nil` input is a missing key (only an `Optional` accepts it, as `none`, like Lean's decoder).
    static func fromLean(_ j: JSON?) -> Self?
}

extension JNum {
    /// Lean's `FromJson Nat`: the parser keeps a number as `mantissa / 10^exponent` and normalises only a
    /// positive exponent into the mantissa, so a value is a `Nat` iff it has no more fractional digits than
    /// its exponent (`1e0`, `5`, `-0` yes; `1.0`, `10e-1` no) and is not negative.
    var leanNatValue: Int? {
        let zero = UInt8(ascii: "0")
        if mantissa.allSatisfy({ $0 == zero }) { return exp >= 0 && expHuge <= 0 ? 0 : nil }
        if negative || expHuge != 0 || exp < 0 { return nil }
        var lo = 0
        while lo < mantissa.count, mantissa[lo] == zero { lo += 1 }
        if (mantissa.count - lo) + exp > 18 { return nil }
        var v = 0
        for k in lo..<mantissa.count { v = v * 10 + Int(mantissa[k] - zero) }
        for _ in 0..<exp { v *= 10 }
        return v
    }
}

extension Int: LeanCodable {
    func leanJSON() -> String { String(self) }
    static func fromLean(_ j: JSON?) -> Int? {
        guard case .number(let n)? = j else { return nil }
        return n.leanNatValue
    }
}

extension String: LeanCodable {
    func leanJSON() -> String { q(self) }
    static func fromLean(_ j: JSON?) -> String? {
        guard case .string(let s)? = j else { return nil }
        return s
    }
}

extension Bool: LeanCodable {
    func leanJSON() -> String { self ? "true" : "false" }
    static func fromLean(_ j: JSON?) -> Bool? {
        guard case .bool(let b)? = j else { return nil }
        return b
    }
}

extension Array: LeanCodable where Element: LeanCodable {
    func leanJSON() -> String { "[" + map { $0.leanJSON() }.joined(separator: ",") + "]" }
    static func fromLean(_ j: JSON?) -> [Element]? {
        guard case .array(let items)? = j else { return nil }
        var out: [Element] = []
        for it in items {
            guard let v = Element.fromLean(it) else { return nil }
            out.append(v)
        }
        return out
    }
}

extension Optional: LeanCodable where Wrapped: LeanCodable {
    func leanJSON() -> String {
        switch self {
        case .none: return "null"
        case .some(let v): return v.leanJSON()
        }
    }
    static func fromLean(_ j: JSON?) -> Wrapped??  {
        switch j {
        case .none, .some(.null): return .some(.none)
        case .some(let v):
            guard let w = Wrapped.fromLean(v) else { return nil }
            return .some(.some(w))
        }
    }
}

/// What the generated code of an app with commands fulfils: `cmds` (from the pre-state) and `host`.
protocol CmdElmApp: ElmApp {
    associatedtype Cmd: LeanCodable
    associatedtype Host: LeanCodable
    static func cmds(_ msg: Msg, _ m: Model) -> [Cmd]
    static func host(_ h: Host) -> Msg
}

/// `Session.step` for an app with commands: user events as in `Session`, `{"host":…}` lines with no `seq`
/// check, and `"cmds"` on every view reply. `{"samples":true}` is answered only by the Lean CLI (the
/// lockstep driver asks it alone); here it is `bad-json`.
final class CmdSession<App: CmdElmApp> {
    let ui = Session<App>()

    func viewReply(_ cs: [App.Cmd]) -> String {
        "{\"cmds\":[\(cs.map { $0.leanJSON() }.joined(separator: ","))],\"seq\":\(ui.seq),\"view\":\(ui.lastView.wireJSON())}"
    }

    func apply(_ msg: App.Msg) -> String {
        let cs = App.cmds(msg, ui.model)          // the pre-state, as in Lean
        ui.model = App.update(msg, ui.model)
        ui.lastView = App.view(ui.model)
        ui.seq += 1
        return viewReply(cs)
    }

    func handle(_ line: String) -> String {
        var r = JSONReader(line)
        if let j = try? r.parseDocument(), case .object = j {
            if case .bool(true)? = j["reset"] {
                ui.model = App.initial
                ui.lastView = App.view(ui.model)
                ui.seq += 1
                return viewReply([])
            }
            if case .bool(true)? = j["samples"] { return ui.errorReply("bad-json", detail: "samples: Lean CLI only") }
            if let hj = j["host"] {
                guard let h = App.Host.fromLean(hj) else { return ui.errorReply("bad-json", detail: "host: not a host answer") }
                return apply(App.host(h))
            }
        }
        switch parseLine(line) {
        case .bad(let why):
            return ui.errorReply("bad-json", detail: why)
        case .reset:
            return viewReply([])   // unreachable: handled above
        case .request(let req):
            guard case .small(let s) = req.seq, s == ui.seq else { return ui.errorReply("stale", withView: true) }
            var ints: [Int] = []
            for p in req.path {
                guard case .small(let i) = p else { return ui.errorReply("bad-path") }
                ints.append(i)
            }
            guard let node = ui.lastView.at(ints) else { return ui.errorReply("bad-path") }
            guard let msg = node.handle(req.event) else { return ui.errorReply("no-handler") }
            return apply(msg)
        }
    }
}

/// The CLI of an app with commands: initial view with no commands, then one reply per line until EOF.
func runCmdElmCli<App: CmdElmApp>(_ app: App.Type) -> Never {
    let session = CmdSession<App>()
    emit(session.viewReply([]))
    while let line = readLine(strippingNewline: true) {
        emit(session.handle(line))
    }
    exit(0)
}
