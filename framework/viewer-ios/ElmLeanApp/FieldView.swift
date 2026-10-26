import SwiftUI

/// A `field` node. Owns the text while the user types; the server's value only overwrites it
/// when no input for this path is pending (so "Add clears the draft" works even while focused,
/// and nothing ever clobbers a keystroke). "Pending" includes inputs the client parked while the
/// bridge was down; only when the client discards an input for good (`droppedInputs`) does the
/// field fall back to the server's value (PROTOCOL.md, "Client rules for queued events").
struct FieldView: View {
    @Environment(ElmClient.self) private var client

    let path: [Int]
    let placeholder: String
    let serverValue: String
    let submits: Bool

    @State private var text: String
    @State private var lastKnown: String

    init(path: [Int], placeholder: String, value: String, submits: Bool) {
        self.path = path
        self.placeholder = placeholder
        self.serverValue = value
        self.submits = submits
        _text = State(initialValue: value)
        _lastKnown = State(initialValue: value)
    }

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.roundedBorder)
            .frame(minHeight: 44)
            .submitLabel(submits ? .done : .return)
            .onChange(of: text) { _, newValue in
                if newValue != lastKnown {
                    lastKnown = newValue
                    client.send(path: path, event: .input(newValue))
                }
            }
            .onChange(of: serverValue) { _, _ in reconcile() }
            .onChange(of: client.seq) { _, _ in reconcile() }
            // An input was discarded for good (502, stale cap, path no longer a field, bridge switch):
            // if none of ours is pending any more, the server's value is the truth again.
            .onChange(of: client.droppedInputs) { _, _ in reconcile() }
            .onSubmit {
                flushDraft()   // the submit is created against the pre-input seq; the queue rules re-stamp it
                if submits { client.send(path: path, event: .submit) }
            }
    }

    /// Adopt the server's value unless the user is ahead of it (an input of ours is queued, in flight
    /// or parked). Setting `lastKnown` first keeps `onChange(of: text)` from echoing an input.
    private func reconcile() {
        guard serverValue != text, !client.hasPendingInput(for: path) else { return }
        lastKnown = serverValue
        text = serverValue
    }

    /// Send anything typed that has not gone out yet.
    private func flushDraft() {
        guard text != lastKnown else { return }
        lastKnown = text
        client.send(path: path, event: .input(text))
    }
}
