import SwiftUI

/// Lets the user point the app at a different bridge. Persisted in `@AppStorage("baseURL")`.
struct SettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("baseURL") private var baseURLString = ElmClient.defaultBaseURLString
    @State private var draft = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(ElmClient.defaultBaseURLString, text: $draft)
                        .keyboardType(.URL)
                        .textContentType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .frame(minHeight: 44)
                } header: {
                    Text("Bridge URL")
                } footer: {
                    Text("Simulator: 127.0.0.1 reaches the Mac. Physical device: use the Mac's LAN IP.")
                }

                Section {
                    Button("Reset to default") { draft = ElmClient.defaultBaseURLString }
                        .frame(minHeight: 44)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        baseURLString = trimmedDraft
                        dismiss()
                    }
                    .disabled(!isValid)
                }
            }
            .onAppear { draft = baseURLString }
        }
    }

    private var trimmedDraft: String {
        draft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Save is allowed only for an http/https URL that names a host.
    private var isValid: Bool {
        guard let url = URL(string: trimmedDraft),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host(), !host.isEmpty
        else { return false }
        return true
    }
}
