// SwiftUI element kit for generated ElmLean apps.
//
// The generated screen is a structural image of the app's Lean `view`: every `Html` constructor becomes one of
// these views with the SAME argument expressions (labels, roles, `Option Msg` handlers, `String -> Msg` and
// `Bool -> Msg` closures), plus `send: store.send`. Nothing here knows the app.

import SwiftUI

@MainActor @Observable
final class Store<App: ElmApp> {
    var model: App.Model
    /// Called after every message with the message and the PRE-state; an app with commands starts its
    /// commands here (`attach`), computed from the same model `update` saw, as `Session.step` does.
    @ObservationIgnored var effects: ((App.Msg, App.Model) -> Void)?
    init() { model = App.initial }
    func send(_ msg: App.Msg) {
        let pre = model
        model = App.update(msg, model)
        effects?(msg, pre)
    }
}

/// The host of an app with commands: runs one command and answers with one host message. Written by
/// hand per app (the Send example's host calls Winnow's WalletCore); it is trusted, not proven.
@MainActor
protocol CmdHost: AnyObject {
    associatedtype App: CmdElmApp
    func run(_ cmd: App.Cmd) async -> App.Host
}

extension Store where App: CmdElmApp {
    /// Run every command of every message on `host` and feed each answer back through `App.host`, the
    /// only way a host answer reaches `update`.
    func attach<H: CmdHost>(_ host: H) where H.App == App {
        effects = { [weak self] msg, pre in
            for c in App.cmds(msg, pre) {
                Task { @MainActor in
                    let answer = await host.run(c)
                    self?.send(App.host(answer))
                }
            }
        }
    }

    /// An unsolicited host message (the Send example's wallet balance at launch).
    func hostSays(_ h: App.Host) { send(App.host(h)) }
}

struct ElmText: View {
    let s: String
    let style: TextStyle
    init(_ s: String, _ style: TextStyle) { self.s = s; self.style = style }
    var body: some View {
        if CharWrappedText.needs(s) {
            // SwiftUI hyphenates a long word when it wraps, showing a "-" that is not in the string: an
            // address or a txid must appear exactly as it is, so such text wraps at characters instead.
            CharWrappedText(text: s, style: style)
        } else {
            switch style {
            case .title: Text(s).font(.title2.bold())
            case .body: Text(s).font(.body)
            case .caption: Text(s).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// A `UILabel` wrapped at characters (Winnow's review screen does the same for addresses).
struct CharWrappedText: UIViewRepresentable {
    let text: String
    let style: TextStyle

    /// A run of 20 or more characters with no whitespace (addresses, txids, hex).
    static func needs(_ s: String) -> Bool {
        var run = 0
        for c in s.unicodeScalars {
            run = c.properties.isWhitespace ? 0 : run + 1
            if run >= 20 { return true }
        }
        return false
    }

    func makeUIView(context: Context) -> UILabel {
        let label = UILabel()
        label.numberOfLines = 0
        label.lineBreakMode = .byCharWrapping
        label.adjustsFontForContentSizeCategory = true
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }

    func updateUIView(_ label: UILabel, context: Context) {
        label.text = text
        switch style {
        case .title:
            let base = UIFont.preferredFont(forTextStyle: .title2)
            label.font = UIFont(descriptor: base.fontDescriptor.withSymbolicTraits(.traitBold) ?? base.fontDescriptor, size: 0)
            label.textColor = .label
        case .body:
            label.font = .preferredFont(forTextStyle: .body)
            label.textColor = .label
        case .caption:
            label.font = .preferredFont(forTextStyle: .caption1)
            label.textColor = .secondaryLabel
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UILabel, context: Context) -> CGSize? {
        let width = proposal.width ?? 320
        let fit = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: width, height: fit.height)
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
/// The keyboard never rewrites what is typed (no autocapitalization, no autocorrection): the text the app
/// receives is the text the user entered, which matters for addresses and amounts.
struct ElmField<Msg>: View {
    let placeholder: String
    let value: String
    let onInput: (String) -> Msg
    let onSubmit: Msg?
    let send: (Msg) -> Void
    var body: some View {
        TextField(placeholder, text: Binding(get: { value }, set: { send(onInput($0)) }))
            .textFieldStyle(.roundedBorder)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
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
