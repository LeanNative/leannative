import SwiftUI

/// Recursive, generic renderer for a `Node`. Child `i` of a container lives at `path + [i]`.
/// Never put `.id(seq)` on an ancestor: it would reset child @State and focus on every update.
struct NodeView: View {
    @Environment(ElmClient.self) private var client
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let node: Node
    let path: [Int]

    /// Rows are horizontal, but at accessibility text sizes their children no longer fit side by
    /// side (button labels start wrapping mid-word), so they stack. `AnyLayout` keeps child
    /// identity across the switch, so field @State and focus survive it.
    private var rowLayout: AnyLayout {
        dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
            : AnyLayout(HStackLayout(spacing: 12))
    }

    var body: some View {
        switch node {
        case .text(let s, let style):
            switch style {
            case .title:
                Text(s).font(.title2.bold())
            case .body:
                Text(s).font(.body)
            case .caption:
                Text(s).font(.caption).foregroundStyle(.secondary)
            }

        case .col(let nodes):
            VStack(alignment: .leading, spacing: 12) {
                children(nodes)
            }

        case .row(let nodes):
            rowLayout {
                children(nodes)
            }
            .frame(minHeight: 44)

        case .button(let label, let role, let enabled):
            let button = Button(label, role: role == .destructive ? .destructive : nil) {
                client.send(path: path, event: .click)
            }
            .disabled(!enabled)
            if role == .primary {
                button.buttonStyle(.borderedProminent).controlSize(.large)
            } else {
                button.buttonStyle(.bordered)
            }

        case .field(let placeholder, let value, let submits):
            FieldView(path: path, placeholder: placeholder, value: value, submits: submits)

        case .toggle(let label, let on):
            Toggle(label, isOn: Binding(
                get: { on },
                set: { client.send(path: path, event: .toggle($0)) }
            ))

        case .divider:
            Divider()

        case .spacer:
            Spacer(minLength: 0)

        case .unknown(let type):
            UnknownNodeView(type: type)
        }
    }

    @ViewBuilder
    private func children(_ nodes: [Node]) -> some View {
        ForEach(Array(nodes.enumerated()), id: \.offset) { index, child in
            NodeView(node: child, path: path + [index])
        }
    }
}
