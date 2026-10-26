import SwiftUI

/// Visible placeholder for a node type this renderer does not know (PROTOCOL.md: never fail).
struct UnknownNodeView: View {
    let type: String

    var body: some View {
        Text("Unsupported node: \(type)")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .padding(8)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .foregroundStyle(.secondary)
            )
            .accessibilityLabel("Unsupported node \(type)")
    }
}
