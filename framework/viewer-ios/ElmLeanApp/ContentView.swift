import SwiftUI

struct ContentView: View {
    @Environment(ElmClient.self) private var client
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("baseURL") private var baseURLString = ElmClient.defaultBaseURLString
    @State private var showSettings = false
    @State private var parkedRetryDelay: Double = 1

    var body: some View {
        NavigationStack {
            content
                .safeAreaInset(edge: .top, spacing: 0) { statusBanner }
                .navigationTitle("ElmLean")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        if client.isBusy {
                            ProgressView().accessibilityLabel("Working")
                        }
                        Button {
                            showSettings = true
                        } label: {
                            Image(systemName: "gear")
                        }
                        .accessibilityLabel("Settings")
                    }
                }
                .sheet(isPresented: $showSettings) { SettingsSheet() }
        }
        .task(id: "\(baseURLString)|\(client.isConnected)") { await reconnectLoop() }
        .task(id: client.parkEpoch) { await retryParkedInputs() }
        .task(id: client.notice) { await expireNotice() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { client.refresh() }
        }
        .onChange(of: client.isBusy) { _, busy in
            // Idle with nothing parked: the backend took everything, so the next outage starts at 1 s again.
            if !busy, !client.hasParkedInputs { parkedRetryDelay = 1 }
        }
        // PROTOCOL.md: the retry delay resets whenever a view is adopted. A new `seq` means a new view was
        // adopted (a 200, a 409 body, or a `GET /view` that moved because the CLI processed something); the
        // cached `GET /view` of a 503 cycle returns the same `seq`, so it does not fire and the backoff holds.
        .onChange(of: client.seq) { _, _ in parkedRetryDelay = 1 }
        // The backend answered `/event` with something other than 503 (200/400/409/502): the outage is
        // over even when `seq` did not move (a 400 is followed by a fetch of the same view).
        .onChange(of: client.unavailable) { _, unavailable in
            if unavailable == nil { parkedRetryDelay = 1 }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let root = client.root {
            ScrollView {
                NodeView(node: root, path: [])
                    .padding()
            }
            .scrollDismissesKeyboard(.interactively)
        } else {
            ContentUnavailableView {
                Label("Not connected", systemImage: "antenna.radiowaves.left.and.right.slash")
            } description: {
                Text(client.lastError ?? "Waiting for \(baseURLString)")
            } actions: {
                Button("Retry") { client.refresh() }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    /// Top safe-area strip, three kinds of message (PROTOCOL.md, "Client rules for queued events"):
    /// the sticky "cannot reach the bridge" warning when a tree exists but the bridge is gone (clears on
    /// any readable reply), the sticky "backend unavailable" notice (503 or an unintelligible `/event`
    /// reply; clears only on the next `/event` reply, never on a timer or a cached `GET /view`), and the
    /// transient notice (discarded actions, rejected events, restart) that `expireNotice` removes.
    @ViewBuilder
    private var statusBanner: some View {
        VStack(spacing: 0) {
            if client.root != nil, !client.isConnected {
                Label(client.lastError.map { "Disconnected: \($0)" } ?? "Disconnected", systemImage: "wifi.exclamationmark")
                    .font(.footnote)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                    .background(Color.yellow.opacity(0.3))
            }
            if let unavailable = client.unavailable {
                Label(unavailable, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                    .background(Color.red.opacity(0.15))
            }
            if let notice = client.notice {
                Label(notice, systemImage: "info.circle")
                    .font(.footnote)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                    .background(Color.orange.opacity(0.2))
            }
        }
    }

    /// Fetch with 1 → 8 s backoff until the bridge answers. Re-run whenever the URL or the
    /// connection state changes (via `.task(id:)`), so the delay starts at 1 s again as soon as a view
    /// is adopted (`isConnected` flips, the task restarts) and on every new outage.
    private func reconnectLoop() async {
        if let url = URL(string: baseURLString) { client.setBaseURL(url) }
        var delay: Double = 1
        while !Task.isCancelled, !client.isConnected {
            client.refresh()
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            delay = min(delay * 2, 8)
        }
    }

    /// The bridge answered 503 (CLI down) while typed text was pending: PROTOCOL.md says keep the view and
    /// retry later. One delayed fetch per parking; a successful fetch re-queues the parked inputs, and if
    /// they are parked again the next `parkEpoch` schedules the next retry, 1 → 8 s apart (the cap is
    /// 8 s; the resets live on `body`). Transport failures are `reconnectLoop`'s job instead
    /// (`isConnected` is false there).
    private func retryParkedInputs() async {
        guard client.isConnected, client.hasParkedInputs else { return }
        do { try await Task.sleep(for: .seconds(parkedRetryDelay)) } catch { return }
        // Only a completed wait escalates: a typing burst re-parks on every keystroke and restarts this
        // task each time, and the first retry should still land about 1 s after the last keystroke.
        parkedRetryDelay = min(parkedRetryDelay * 2, 8)
        if client.isConnected, client.hasParkedInputs { client.refresh() }
    }

    /// Only the transient notice expires; `client.unavailable` is sticky and the client clears it itself.
    private func expireNotice() async {
        guard client.notice != nil else { return }
        do { try await Task.sleep(for: .seconds(4)) } catch { return }
        client.clearNotice()
    }
}
