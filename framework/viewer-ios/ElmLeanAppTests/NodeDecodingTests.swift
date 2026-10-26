import Foundation
import Testing
@testable import ElmLeanApp

@Suite("Node decoding")
struct NodeDecodingTests {
    private func decode(_ json: String) throws -> Node {
        try JSONDecoder().decode(Node.self, from: Data(json.utf8))
    }

    // MARK: Every node kind

    @Test func text() throws {
        #expect(try decode(#"{"s":"Todos","style":"title","t":"text"}"#) == .text("Todos", .title))
        #expect(try decode(#"{"t":"text","s":"hi","style":"body"}"#) == .text("hi", .body))
        #expect(try decode(#"{"t":"text","s":"0 left","style":"caption"}"#) == .text("0 left", .caption))
    }

    @Test func col() throws {
        #expect(try decode(#"{"t":"col","c":[{"t":"divider"},{"t":"spacer"}]}"#) == .col([.divider, .spacer]))
    }

    @Test func row() throws {
        #expect(try decode(#"{"c":[{"t":"text","s":"a","style":"body"}],"t":"row"}"#) == .row([.text("a", .body)]))
    }

    @Test func button() throws {
        #expect(try decode(#"{"enabled":false,"label":"Add","role":"primary","t":"button"}"#)
                == .button(label: "Add", role: .primary, enabled: false))
        #expect(try decode(#"{"t":"button","label":"Delete","role":"destructive","enabled":true}"#)
                == .button(label: "Delete", role: .destructive, enabled: true))
        #expect(try decode(#"{"t":"button","label":"All","role":"plain","enabled":true}"#)
                == .button(label: "All", role: .plain, enabled: true))
    }

    @Test func field() throws {
        #expect(try decode(#"{"placeholder":"What needs doing?","submits":true,"t":"field","value":"Milk"}"#)
                == .field(placeholder: "What needs doing?", value: "Milk", submits: true))
    }

    @Test func toggle() throws {
        #expect(try decode(#"{"label":"Milk","on":true,"t":"toggle"}"#) == .toggle(label: "Milk", on: true))
    }

    @Test func dividerAndSpacer() throws {
        #expect(try decode(#"{"t":"divider"}"#) == .divider)
        #expect(try decode(#"{"t":"spacer"}"#) == .spacer)
    }

    // MARK: Robustness

    @Test func unknownTypeBecomesPlaceholder() throws {
        #expect(try decode(#"{"t":"carousel"}"#) == .unknown(type: "carousel"))
        #expect(try decode(#"{"t":"carousel","items":[1,2,3]}"#) == .unknown(type: "carousel"))
    }

    @Test func missingOptionalKeysDefault() throws {
        #expect(try decode(#"{"t":"text"}"#) == .text("", .body))
        #expect(try decode(#"{"t":"text","s":"x","style":"headline"}"#) == .text("x", .body))
        #expect(try decode(#"{"t":"button"}"#) == .button(label: "", role: .plain, enabled: true))
        #expect(try decode(#"{"t":"button","role":"fancy"}"#) == .button(label: "", role: .plain, enabled: true))
        #expect(try decode(#"{"t":"field"}"#) == .field(placeholder: "", value: "", submits: false))
        #expect(try decode(#"{"t":"toggle"}"#) == .toggle(label: "", on: false))
        #expect(try decode(#"{"t":"col"}"#) == .col([]))
        #expect(try decode(#"{"t":"row"}"#) == .row([]))
    }

    @Test func extraKeysAreIgnored() throws {
        #expect(try decode(#"{"t":"divider","future":{"nested":true}}"#) == .divider)
    }

    @Test func initialTodoViewDecodes() throws {
        // Exactly what `elmlean view` prints on start (keys alphabetical).
        let json = #"""
        {"c":[{"s":"Todos","style":"title","t":"text"},{"c":[{"placeholder":"What needs doing?","submits":true,"t":"field","value":""},{"enabled":false,"label":"Add","role":"primary","t":"button"}],"t":"row"},{"c":[],"t":"col"},{"t":"divider"},{"c":[{"enabled":true,"label":"All","role":"primary","t":"button"},{"enabled":true,"label":"Active","role":"plain","t":"button"},{"enabled":true,"label":"Done","role":"plain","t":"button"}],"t":"row"},{"s":"0 left","style":"caption","t":"text"},{"enabled":false,"label":"Clear done","role":"destructive","t":"button"}],"t":"col"}
        """#
        let root = try decode(json)
        guard case .col(let children) = root else {
            Issue.record("root is not a col: \(root)")
            return
        }
        #expect(children.count == 7)
        #expect(children[0] == .text("Todos", .title))
        #expect(children[1] == .row([
            .field(placeholder: "What needs doing?", value: "", submits: true),
            .button(label: "Add", role: .primary, enabled: false),
        ]))
        #expect(children[2] == .col([]))
        #expect(children[3] == .divider)
        #expect(children[6] == .button(label: "Clear done", role: .destructive, enabled: false))
    }
}

@Suite("Wire types")
struct WireTypeTests {
    private func object(_ value: some Encodable) throws -> [String: Any] {
        let data = try JSONEncoder().encode(value)
        let any = try JSONSerialization.jsonObject(with: data)
        return try #require(any as? [String: Any])
    }

    @Test func eventInputEncodes() throws {
        let obj = try object(Event.input("x"))
        #expect(obj["k"] as? String == "input")
        #expect(obj["value"] as? String == "x")
        #expect(obj.count == 2)
    }

    @Test func otherEventsEncode() throws {
        let click = try object(Event.click)
        #expect(click["k"] as? String == "click")
        #expect(click.count == 1)

        let submit = try object(Event.submit)
        #expect(submit["k"] as? String == "submit")
        #expect(submit.count == 1)

        let toggle = try object(Event.toggle(true))
        #expect(toggle["k"] as? String == "toggle")
        #expect(toggle["value"] as? Bool == true)
        #expect(toggle.count == 2)
    }

    @Test func eventRequestEncodes() throws {
        let obj = try object(EventRequest(seq: 3, path: [2, 0, 2], event: .click))
        #expect(obj["seq"] as? Int == 3)
        #expect(obj["path"] as? [Int] == [2, 0, 2])
        #expect((obj["event"] as? [String: Any])?["k"] as? String == "click")
    }

    @Test func viewResponseDecodesEveryShape() throws {
        let decoder = JSONDecoder()

        let ok = try decoder.decode(ViewResponse.self, from: Data(#"{"seq":1,"view":{"t":"divider"}}"#.utf8))
        #expect(ok.seq == 1)
        #expect(ok.view == .divider)
        #expect(ok.error == nil)

        let stale = try decoder.decode(ViewResponse.self, from: Data(#"{"seq":4,"error":"stale","view":{"t":"spacer"}}"#.utf8))
        #expect(stale.seq == 4)
        #expect(stale.error == "stale")
        #expect(stale.view == .spacer)

        let badPath = try decoder.decode(ViewResponse.self, from: Data(#"{"seq":2,"error":"bad-path"}"#.utf8))
        #expect(badPath.seq == 2)
        #expect(badPath.error == "bad-path")
        #expect(badPath.view == nil)

        let badJSON = try decoder.decode(ViewResponse.self, from: Data(#"{"seq":2,"error":"bad-json","detail":"x"}"#.utf8))
        #expect(badJSON.detail == "x")

        // The bridge's own 400 has no seq at all.
        let badRequest = try decoder.decode(ViewResponse.self, from: Data(#"{"error":"bad-request"}"#.utf8))
        #expect(badRequest.seq == nil)
        #expect(badRequest.error == "bad-request")

        let restarted = try decoder.decode(ViewResponse.self, from: Data(#"{"error":"cli-restarted","seq":0}"#.utf8))
        #expect(restarted.seq == 0)
        #expect(restarted.error == "cli-restarted")
    }
}
