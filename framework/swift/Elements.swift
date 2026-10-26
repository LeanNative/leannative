// SwiftUI element kit for generated ElmLean apps.
//
// The generated screen is a structural image of the app's Lean `view`: every `Html` constructor becomes one of
// these views with the SAME argument expressions (labels, roles, `Option Msg` handlers, `String -> Msg` and
// `Bool -> Msg` closures), plus `send: store.send`. Nothing here knows the app.

import SwiftUI

@MainActor @Observable
final class Store<App: ElmApp> {
    var model: App.Model
    init() { model = App.initial }
    func send(_ msg: App.Msg) { model = App.update(msg, model) }
}

struct ElmText: View {
    let s: String
    let style: TextStyle
    init(_ s: String, _ style: TextStyle) { self.s = s; self.style = style }
    var body: some View {
        switch style {
        case .title: Text(s).font(.title2.bold())
        case .body: Text(s).font(.body)
        case .caption: Text(s).font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// `Html.button label role onClick`: `msg == nil` is a disabled button, exactly as on the wire.
struct RoleButton<Msg>: View {
    let label: String
    let role: ButtonRole
    let msg: Msg?
    let send: (Msg) -> Void
    init(_ label: String, role: ButtonRole, msg: Msg?, send: @escaping (Msg) -> Void) {
        self.label = label; self.role = role; self.msg = msg; self.send = send
    }
    var body: some View {
        Group {
            switch role {
            case .primary:
                Button(label) { if let m = msg { send(m) } }.buttonStyle(.borderedProminent).controlSize(.large)
            case .plain:
                Button(label) { if let m = msg { send(m) } }.buttonStyle(.bordered)
            case .destructive:
                Button(label, role: .destructive) { if let m = msg { send(m) } }.buttonStyle(.bordered)
            }
        }
        .disabled(msg == nil)
    }
}

/// `Html.field placeholder value onInput onSubmit`: every keystroke is a message, the return key is `onSubmit`.
struct ElmField<Msg>: View {
    let placeholder: String
    let value: String
    let onInput: (String) -> Msg
    let onSubmit: Msg?
    let send: (Msg) -> Void
    var body: some View {
        TextField(placeholder, text: Binding(get: { value }, set: { send(onInput($0)) }))
            .textFieldStyle(.roundedBorder)
            .submitLabel(onSubmit == nil ? .done : .go)
            .onSubmit { if let m = onSubmit { send(m) } }
    }
}

/// `Html.toggle label on onToggle`: the toggle's new value is the message's payload (authoritative, never a flip).
struct ElmToggle<Msg>: View {
    let label: String
    let on: Bool
    let onToggle: (Bool) -> Msg
    let send: (Msg) -> Void
    var body: some View {
        Toggle(label, isOn: Binding(get: { on }, set: { send(onToggle($0)) }))
    }
}
