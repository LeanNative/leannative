import Foundation
import Observation

/// Talks to the bridge (PROTOCOL.md, "HTTP bridge"). One serial drain loop, one request in flight at a
/// time. Every event job remembers the `seq` of the view it was created against (`genSeq`); when it
/// reaches the head of the queue, and again after a 409, the rules of PROTOCOL.md "Client rules for
/// queued events" decide whether it is sent as is, re-stamped with the current `seq`, or dropped.
@MainActor
@Observable
final class ElmClient {
    static let defaultBaseURLString = "http://127.0.0.1:8787"

    enum Job: Equatable, Sendable {
        case fetch
        /// `genSeq` is the client's `seq` when the job was created, i.e. the view the user acted on.
        case event(path: [Int], event: Event, genSeq: Int)

        var isInput: Bool {
            if case .event(_, let e, _) = self { return e.isInput }
            return false
        }

        func isInput(for path: [Int]) -> Bool {
            if case .event(let p, let e, _) = self { return p == path && e.isInput }
            return false
        }

        var isEvent: Bool {
            if case .event = self { return true }
            return false
        }
    }

    // MARK: Observable state

    private(set) var root: Node?
    private(set) var seq: Int = 0
    private(set) var isConnected = false
    private(set) var lastError: String?
    /// Transient notice (discarded actions, rejected events, restart). The view expires it on a timer.
    private(set) var notice: String?
    /// Sticky "backend unavailable" notice (PROTOCOL.md, "Client rules for queued events"): set by a 503
    /// or an unintelligible `/event` reply, cleared only by the next `/event` reply of any status. A
    /// successful `GET /view` leaves it alone: the bridge serves its cached view while the CLI is down,
    /// so a 200 from it proves nothing. The other sticky kind, "cannot reach the bridge", is
    /// `isConnected == false` and clears on any readable reply.
    private(set) var unavailable: String?
    private(set) var baseURL: URL
    private(set) var queue: [Job] = []
    private(set) var inFlight: Job?
    /// `input` jobs waiting for the bridge or the CLI to come back (503 / transport failure), latest
    /// value per path. They are re-queued after the next successful reply and then re-validated by the
    /// queue rules like any other job.
    private(set) var parked: [Job] = []
    /// Bumped whenever an `input` job is discarded for good (502, stale cap, path no longer a field,
    /// bridge switch). A field whose input is no longer pending then falls back to the server's value.
    private(set) var droppedInputs = 0
    /// Bumped whenever inputs are parked (monotonic). The view keys its delayed retry on it.
    private(set) var parkEpoch = 0

    var isBusy: Bool { inFlight != nil || !queue.isEmpty }
    var hasParkedInputs: Bool { !parked.isEmpty }

    @ObservationIgnored private var draining = false
    @ObservationIgnored private var consecutiveStales = 0
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private let session: URLSession

    /// `configuration` lets tests inject a `URLProtocol` stub; `.ephemeral` returns a fresh instance per
    /// call, so the timeouts below never leak into a shared configuration.
    init(baseURL: URL, configuration: URLSessionConfiguration = .ephemeral) {
        self.baseURL = baseURL
        configuration.timeoutIntervalForRequest = 5
        configuration.waitsForConnectivity = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.session = URLSession(configuration: configuration)
    }

    // MARK: Public API

    /// Switch bridges. Drops everything that belonged to the old one, parked inputs included.
    func setBaseURL(_ url: URL) {
        guard url != baseURL else { return }
        generation += 1
        baseURL = url
        root = nil
        seq = 0
        isConnected = false
        lastError = nil
        notice = nil
        unavailable = nil
        let lostInputs = pendingJobs(inFlight: inFlight).filter(\.isInput).count
        queue.removeAll()
        parked.removeAll()
        consecutiveStales = 0
        if lostInputs > 0 { droppedInputs += lostInputs }
    }

    /// Queue a fetch of the current view. Coalesced: at most one `.fetch` is queued at a time.
    func refresh() {
        if !queue.contains(.fetch) { queue.append(.fetch) }
        drain()
    }

    /// Queue an event, created against the current `seq`. If the queue tail is an unsent `.input` for the
    /// same path it is replaced (latest full value wins); otherwise the event is appended.
    func send(path: [Int], event: Event) {
        let job = Job.event(path: path, event: event, genSeq: seq)
        switch event {
        case .input:
            // A newer full value supersedes an older parked one for the same path.
            parked.removeAll { $0.isInput(for: path) }
            if let last = queue.last, last.isInput(for: path) {
                queue[queue.count - 1] = job
            } else {
                queue.append(job)
            }
        case .submit:
            // Return after typing while the bridge was down: the parked draft must reach the server first.
            if let index = parked.firstIndex(where: { $0.isInput(for: path) }) {
                queue.append(parked.remove(at: index))
            }
            queue.append(job)
        case .click, .toggle:
            queue.append(job)
        }
        drain()
    }

    /// True while an `.input` for `path` is queued, in flight or parked (the field must not be clobbered).
    func hasPendingInput(for path: [Int]) -> Bool {
        if let inFlight, inFlight.isInput(for: path) { return true }
        return queue.contains { $0.isInput(for: path) } || parked.contains { $0.isInput(for: path) }
    }

    func clearNotice() { notice = nil }

    /// Suspends until nothing is queued or in flight (polls on the main actor). Meant for tests.
    func waitUntilIdle(timeout: Duration = .seconds(5)) async {
        let deadline = ContinuousClock.now + timeout
        while isBusy, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    // MARK: Drain loop

    private func drain() {
        guard !draining else { return }
        draining = true
        Task { [self] in
            defer { draining = false }
            while !queue.isEmpty {
                let job = queue.removeFirst()
                guard let ready = admit(job) else { continue }
                inFlight = ready
                await perform(ready)
                inFlight = nil
            }
            // The queue ran empty, so the client is idle: a later 409 is not consecutive with the ones
            // seen in this drain (PROTOCOL.md: "consecutive means within one drain of the queue"). Two
            // taps dropped minutes apart must not cost an unrelated draft its third strike.
            consecutiveStales = 0
        }
    }

    /// The head-of-queue check of PROTOCOL.md "Client rules for queued events": a job created against the
    /// current view goes out as is; an older one is re-stamped or dropped by `revalidate`.
    private func admit(_ job: Job) -> Job? {
        if let ready = revalidate(job) { return ready }
        if job.isInput {
            droppedInputs += 1
            notice = "The view changed; your text was discarded"
        } else {
            notice = "The view changed; tap again"
        }
        return nil
    }

    /// PROTOCOL.md "Client rules for queued events", one job against the current `root`/`seq`:
    /// created against the current `seq` → unchanged; click/toggle from an older view → nil (never
    /// re-targeted: there is no node identity on the wire); input → re-stamped iff the node at `path` is
    /// still a field; submit → re-stamped iff it is a field with `submits`.
    private func revalidate(_ job: Job) -> Job? {
        guard case .event(let path, let event, let genSeq) = job else { return job }
        if genSeq == seq { return job }
        switch event {
        case .click, .toggle:
            return nil
        case .input:
            guard case .field? = root?.node(at: path) else { return nil }
            return .event(path: path, event: event, genSeq: seq)
        case .submit:
            guard case .field(_, _, let submits)? = root?.node(at: path), submits else { return nil }
            return .event(path: path, event: event, genSeq: seq)
        }
    }

    private func perform(_ job: Job) async {
        var request: URLRequest
        switch job {
        case .fetch:
            request = URLRequest(url: baseURL.appending(path: "view"))
            request.httpMethod = "GET"
        case .event(let path, let event, let genSeq):
            request = URLRequest(url: baseURL.appending(path: "event"))
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            do {
                // `genSeq` equals `seq` here (admit/revalidate guarantee it); encoding the job's own stamp
                // means a job that somehow skipped the check gets a 409 instead of mis-targeting a path.
                request.httpBody = try JSONEncoder().encode(EventRequest(seq: genSeq, path: path, event: event))
            } catch {
                // Cannot happen with these types; the job is lost, not parked (it would never encode).
                if job.isInput { droppedInputs += 1 }
                notice = "Could not encode event: \(error.localizedDescription)"
                return
            }
        }
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let startedGeneration = generation
        let data: Data
        let status: Int
        do {
            let (d, response) = try await session.data(for: request)
            data = d
            status = (response as? HTTPURLResponse)?.statusCode ?? 0
        } catch {
            if startedGeneration == generation { transportFailure(error.localizedDescription, job: job) }
            return
        }
        // The bridge changed under us while this request was out; its answer is meaningless now.
        guard startedGeneration == generation else { return }

        // Responses are decoded only into ViewResponse: data, never code.
        guard let reply = try? JSONDecoder().decode(ViewResponse.self, from: data) else {
            unintelligible("unreadable response (HTTP \(status))", job: job)
            return
        }
        handle(reply, status: status, job: job)
    }

    private func handle(_ reply: ViewResponse, status: Int, job: Job) {
        // The bridge answered, so transport is fine whatever the status says.
        isConnected = true
        lastError = nil
        // Any `/event` reply, whatever its status (200/400/409/502, or another 503 that sets it again
        // below), is the bridge reporting on the CLI: the sticky notice ends here. A `/view` reply is
        // served from the bridge's cache and says nothing about the CLI, so it leaves the notice alone.
        if job.isEvent { unavailable = nil }

        if status == 409 || reply.error == "stale" {
            handleStale(reply, job: job)
            return
        }
        consecutiveStales = 0

        if status == 502 || reply.error == "cli-restarted" {
            // The CLI was restarted with a fresh model: every pending event is void, inputs included.
            // `seq` is not taken from the 502 body: `root` is still the old view, and a job created before
            // the fetch below applies must keep its old stamp so the queue rules re-check it.
            let lostInputs = pendingJobs(inFlight: job).filter(\.isInput).count
            queue.removeAll()
            parked.removeAll()
            if lostInputs > 0 { droppedInputs += lostInputs }
            notice = "Backend restarted; view reloaded"
            queue = [.fetch]
            return
        }

        if status == 503 || reply.error == "cli-unavailable" {
            backendUnavailable(detail: reply.detail, job: job)
            return
        }

        if let error = reply.error {
            // 400 bad-path / no-handler / bad-json / bad-request, or any other error body: adopt its seq
            // if it has one, tell the user, and refetch (reverts an optimistic toggle). The rest of the
            // queue stays and is re-checked by the queue rules once the fetch has applied.
            if let s = reply.seq { seq = s }
            notice = "Rejected: \(error)"
            prependFetch()
            return
        }

        guard (200..<300).contains(status), let view = reply.view, let s = reply.seq else {
            unintelligible("unexpected response (HTTP \(status))", job: job)
            return
        }
        apply(view: view, seq: s)
        // The backend is alive again: give the parked inputs their turn (the queue rules re-validate
        // them when they reach the head). After the queued jobs, so that a tap made meanwhile is not
        // invalidated by an input of ours advancing `seq` first.
        if !parked.isEmpty {
            queue += parked
            parked.removeAll()
        }
    }

    /// 409: adopt the body's view and `seq` (no `GET /view` needed), then apply the queue rules to the
    /// in-flight job, the queue and the parked inputs. After three consecutive 409s drop everything
    /// and resync.
    private func handleStale(_ reply: ViewResponse, job: Job) {
        consecutiveStales += 1

        var adopted = false
        if let view = reply.view, let s = reply.seq {
            apply(view: view, seq: s)
            adopted = true
        }

        let candidates = pendingJobs(inFlight: job).filter(\.isEvent)
        parked.removeAll()

        // The table first, as after any 409, cap or not: a job the view change already invalidated is
        // dropped with its usual handling and notice here, so the cap below never counts it (PROTOCOL.md:
        // "The cap notice reports the number of events the cap itself discarded, i.e. those the table would
        // have kept"). Without a view in the body the table cannot run; it runs after the fetch instead.
        let kept = adopted ? reconcile(candidates) : candidates

        if consecutiveStales >= 3 {
            // Something keeps changing the view under us; stop replaying and just resync. What the cap
            // costs is what would still have been sent: the survivors, inputs coalesced per path (a
            // superseded value is not a discard), each surviving draft bumping `droppedInputs` once.
            consecutiveStales = 0
            let survivors = latestInputPerPath(kept)
            let lostInputs = survivors.filter(\.isInput).count
            if lostInputs > 0 { droppedInputs += lostInputs }
            queue = [.fetch]
            if !survivors.isEmpty { notice = "The view changed; \(discarded(survivors.count))" }
            return
        }

        guard adopted else {
            // No view in the 409 body (not per protocol): resync first; the queue rules run on each job
            // when it reaches the head, after the fetch has applied.
            queue = [.fetch] + latestInputPerPath(kept)
            return
        }

        queue = latestInputPerPath(kept)
    }

    /// The table of PROTOCOL.md "Client rules for queued events" over `jobs`, against the view just
    /// adopted: returns the jobs it keeps (re-stamped where needed, in order) and gives the dropped ones
    /// their usual handling, a discarded draft per dropped input and one transient notice for all of them.
    private func reconcile(_ jobs: [Job]) -> [Job] {
        var kept: [Job] = []
        var dropped = 0
        var lostInputs = 0
        for job in jobs {
            if let ready = revalidate(job) {
                kept.append(ready)
            } else {
                dropped += 1
                if job.isInput { lostInputs += 1 }
            }
        }
        if lostInputs > 0 { droppedInputs += lostInputs }
        if dropped > 0 { notice = "The view changed; \(discarded(dropped))" }
        return kept
    }

    private func apply(view: Node, seq newSeq: Int) {
        root = view
        seq = newSeq
    }

    private func prependFetch() {
        queue.removeAll { $0 == .fetch }
        queue.insert(.fetch, at: 0)
    }

    /// 503, or an unintelligible `/event` reply: the bridge is up but the CLI is not. Keep the view, park
    /// the typed text, drop the rest, and raise the sticky notice; `handle` clears it on the next `/event`
    /// reply of any status. The discarded count is a separate, transient notice. The view retries the
    /// parked inputs later (ContentView).
    private func backendUnavailable(detail: String?, job: Job) {
        let dropped = park(inFlight: job)
        var text = "Backend unavailable"
        if let detail, !detail.isEmpty { text += ": \(detail)" }
        unavailable = text
        if dropped > 0 { notice = "Backend unavailable; \(discarded(dropped))" }
    }

    /// A reply that is not JSON, or carries neither a view nor an error. From `/event` it is the
    /// "unintelligible reply" of PROTOCOL.md and counts as the backend being unavailable (sticky until the
    /// next `/event` reply). From `GET /view`, which never touches the CLI, it means the bridge itself is
    /// not sane: a transport problem, so the reconnect loop keeps fetching until a readable view arrives.
    private func unintelligible(_ message: String, job: Job) {
        if job.isEvent {
            backendUnavailable(detail: message, job: job)
        } else {
            transportFailure("Bridge sent an \(message)", job: job)
        }
    }

    /// Transport failure (connection refused, timeout, unreadable `GET /view` body): keep the view, park
    /// the typed text, drop the other jobs. The view's reconnect loop fetches until the bridge answers.
    private func transportFailure(_ message: String, job: Job?) {
        isConnected = false
        lastError = message
        let dropped = park(inFlight: job)
        if dropped > 0 { notice = "Disconnected; \(discarded(dropped))" }
    }

    /// Parks the `input` jobs among the in-flight job and the queue (latest value per path, newer ones
    /// replacing older parked ones), empties the queue and returns how many other jobs were dropped.
    private func park(inFlight job: Job?) -> Int {
        var dropped = 0
        for candidate in pendingJobs(inFlight: job) {
            guard case .event(let path, let event, _) = candidate else { continue }  // a fetch is simply retried later
            if event.isInput {
                parked.removeAll { $0.isInput(for: path) }
                parked.append(candidate)
            } else {
                dropped += 1
            }
        }
        queue.removeAll()
        consecutiveStales = 0
        if !parked.isEmpty { parkEpoch += 1 }  // typed text is waiting: the view schedules a retry
        return dropped
    }

    /// Everything pending, oldest first: parked inputs, the in-flight job, then the queue.
    private func pendingJobs(inFlight job: Job?) -> [Job] {
        var jobs = parked
        if let job { jobs.append(job) }
        jobs += queue
        return jobs
    }

    /// Inputs carry the full value, so only the last one per path matters; other jobs are kept in order.
    private func latestInputPerPath(_ jobs: [Job]) -> [Job] {
        var seen = Set<[Int]>()
        return jobs.reversed().filter { job in
            guard case .event(let p, let e, _) = job, e.isInput else { return true }
            return seen.insert(p).inserted
        }.reversed()
    }

    private func discarded(_ count: Int) -> String {
        count == 1 ? "1 action was discarded" : "\(count) actions were discarded"
    }
}
