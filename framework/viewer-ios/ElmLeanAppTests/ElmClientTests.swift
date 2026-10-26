import Foundation
import Testing
@testable import ElmLeanApp

// MARK: - A scripted bridge behind URLProtocol

/// One canned HTTP reply, or a transport failure.
enum StubReply: Sendable {
    case http(Int, String)
    case failure(URLError.Code)

    static func ok(_ json: String) -> StubReply { .http(200, json) }
}

/// What the client sent, as seen by the stub.
struct StubRequest: Sendable {
    let method: String
    let path: String
    let body: Data

    var json: [String: Any] {
        (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
    }
    var seq: Int? { json["seq"] as? Int }
    var eventPath: [Int]? { json["path"] as? [Int] }
    var eventKind: String? { (json["event"] as? [String: Any])?["k"] as? String }
    var eventValue: Any? { (json["event"] as? [String: Any])?["value"] }
}

/// A fake bridge for one test: a switchable handler plus a log of every request, both behind one lock.
/// Registered under a unique host so tests do not see each other's traffic.
final class StubServer: @unchecked Sendable {
    typealias Handler = @Sendable (StubRequest) -> StubReply

    let host: String
    private let lock = NSLock()
    private var handler: Handler
    private var log: [StubRequest] = []

    init(handler: @escaping Handler) {
        self.host = "t-\(UUID().uuidString.lowercased()).test"
        self.handler = handler
        StubProtocol.register(self)
    }

    deinit { StubProtocol.unregister(host) }

    var baseURL: URL { URL(string: "http://\(host)")! }

    /// Replace the script for the rest of the test (e.g. bridge comes back after a failure).
    func respond(_ handler: @escaping Handler) {
        lock.lock(); defer { lock.unlock() }
        self.handler = handler
    }

    func serve(_ request: StubRequest) -> StubReply {
        lock.lock(); defer { lock.unlock() }
        log.append(request)
        return handler(request)
    }

    var requests: [StubRequest] {
        lock.lock(); defer { lock.unlock() }
        return log
    }
    var posts: [StubRequest] { requests.filter { $0.method == "POST" } }
    var gets: [StubRequest] { requests.filter { $0.method == "GET" } }
}

/// Routes every request on a registered host to its `StubServer`. Installed per test through
/// `URLSessionConfiguration.protocolClasses`, so nothing leaves the process.
final class StubProtocol: URLProtocol {
    private static let registryLock = NSLock()
    nonisolated(unsafe) private static var registry: [String: StubServer] = [:]

    static func register(_ server: StubServer) {
        registryLock.lock(); defer { registryLock.unlock() }
        registry[server.host] = server
    }

    static func unregister(_ host: String) {
        registryLock.lock(); defer { registryLock.unlock() }
        registry[host] = nil
    }

    private static func server(for request: URLRequest) -> StubServer? {
        guard let host = request.url?.host else { return nil }
        registryLock.lock(); defer { registryLock.unlock() }
        return registry[host]
    }

    override class func canInit(with request: URLRequest) -> Bool {
        server(for: request) != nil
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let server = Self.server(for: request), let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        let stubRequest = StubRequest(method: request.httpMethod ?? "GET", path: url.path, body: Self.body(of: request))
        switch server.serve(stubRequest) {
        case .failure(let code):
            client?.urlProtocol(self, didFailWithError: URLError(code))
        case .http(let status, let json):
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Type": "application/json", "Cache-Control": "no-store"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(json.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}

    /// URLSession hands a POST body to a protocol as a stream, not as `httpBody`.
    private static func body(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let size = 4096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let n = stream.read(buffer, maxLength: size)
            if n <= 0 { break }
            data.append(buffer, count: n)
        }
        return data
    }
}

// MARK: - Fixtures (the todo view shape: field at [1,0], Add button at [1,1])

enum Views {
    /// Draft empty, Add disabled.
    static let v0 = #"{"t":"col","c":[{"t":"text","s":"Todos","style":"title"},{"t":"row","c":[{"t":"field","placeholder":"What needs doing?","value":"","submits":true},{"t":"button","label":"Add","role":"primary","enabled":false}]},{"t":"col","c":[]},{"t":"divider"},{"t":"text","s":"0 left","style":"caption"}]}"#
    /// Draft "a", Add enabled.
    static let v1 = #"{"t":"col","c":[{"t":"text","s":"Todos","style":"title"},{"t":"row","c":[{"t":"field","placeholder":"What needs doing?","value":"a","submits":true},{"t":"button","label":"Add","role":"primary","enabled":true}]},{"t":"col","c":[]},{"t":"divider"},{"t":"text","s":"0 left","style":"caption"}]}"#
    /// One todo added, draft cleared.
    static let v2 = #"{"t":"col","c":[{"t":"text","s":"Todos","style":"title"},{"t":"row","c":[{"t":"field","placeholder":"What needs doing?","value":"","submits":true},{"t":"button","label":"Add","role":"primary","enabled":false}]},{"t":"col","c":[{"t":"row","c":[{"t":"toggle","label":"a","on":false},{"t":"spacer"},{"t":"button","label":"Delete","role":"destructive","enabled":true}]}]},{"t":"divider"},{"t":"text","s":"1 left","style":"caption"}]}"#
    /// The node at [1,0] is a text, not a field.
    static let noField = #"{"t":"col","c":[{"t":"text","s":"Todos","style":"title"},{"t":"row","c":[{"t":"text","s":"read only","style":"body"},{"t":"button","label":"Add","role":"primary","enabled":true}]}]}"#
    /// The field at [1,0] no longer submits.
    static let noSubmit = #"{"t":"col","c":[{"t":"text","s":"Todos","style":"title"},{"t":"row","c":[{"t":"field","placeholder":"What needs doing?","value":"a","submits":false},{"t":"button","label":"Add","role":"primary","enabled":true}]}]}"#

    static func reply(seq: Int, view: String) -> String { #"{"seq":\#(seq),"view":\#(view)}"# }
    static func stale(seq: Int, view: String) -> String { #"{"seq":\#(seq),"error":"stale","view":\#(view)}"# }
    static let restarted = #"{"error":"cli-restarted","seq":0}"#
    static let unavailable = #"{"error":"cli-unavailable","detail":"binary missing"}"#

    /// A broken fixture shows up as a visible placeholder in the failing comparison, not as a crash.
    static func node(_ json: String) -> Node {
        (try? JSONDecoder().decode(Node.self, from: Data(json.utf8))) ?? .unknown(type: "fixture did not decode")
    }
}

/// Holds a stub reply on the session's thread until the test lets it go, so the test can act while that
/// request is in flight. The wait gives up after 2 s: a mistake fails the test instead of hanging it.
final class Gate: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)
    func open() { semaphore.signal() }
    func wait() { _ = semaphore.wait(timeout: .now() + 2) }
}

let fieldPath = [1, 0]
let addPath = [1, 1]

// MARK: - Tests

@Suite("ElmClient queue rules", .serialized)
@MainActor
struct ElmClientTests {
    private func makeClient(_ server: StubServer) -> ElmClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return ElmClient(baseURL: server.baseURL, configuration: configuration)
    }

    /// A client that has fetched `Views.v0` at seq 0 from `server`.
    private func connectedClient(_ server: StubServer) async throws -> ElmClient {
        let client = makeClient(server)
        client.refresh()
        await client.waitUntilIdle()
        try #require(client.root == Views.node(Views.v0))
        try #require(client.seq == 0)
        try #require(client.isConnected)
        return client
    }

    /// Polls on the main actor until `condition` holds or `timeout` passes (the caller then asserts).
    private func waitUntil(_ condition: @autoclosure () -> Bool, timeout: Duration = .seconds(5)) async {
        let deadline = ContinuousClock.now + timeout
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(2))
        }
    }

    // (1) 502 clears every queued event and refetches.
    @Test func restartClearsQueueAndRefetches() async throws {
        let server = StubServer { request in
            switch (request.method, request.path) {
            case ("GET", "/view"): return .ok(Views.reply(seq: 0, view: Views.v0))
            case ("POST", "/event"): return .http(502, Views.restarted)
            default: return .http(404, #"{"error":"not-found"}"#)
            }
        }
        let client = try await connectedClient(server)

        client.send(path: fieldPath, event: .input("a"))   // goes out first, gets the 502
        client.send(path: addPath, event: .click)          // still queued when the 502 arrives
        client.send(path: fieldPath, event: .input("ab"))  // (replaces nothing: the tail is the click)
        #expect(client.queue.count == 3)                    // the drain task has not run yet
        await client.waitUntilIdle()

        // Exactly one POST (the first input); the click and the second input were never sent.
        #expect(server.posts.count == 1)
        #expect(server.posts[0].eventKind == "input")
        // Then exactly one more GET /view (the initial fetch plus the resync).
        #expect(server.gets.count == 2)
        #expect(client.queue.isEmpty)
        #expect(client.parked.isEmpty)
        #expect(client.inFlight == nil)
        #expect(client.notice == "Backend restarted; view reloaded")
        // Both inputs were discarded for good: the one in flight and the one still queued.
        #expect(client.droppedInputs == 2)
        #expect(client.hasPendingInput(for: fieldPath) == false)
        #expect(client.root == Views.node(Views.v0))
        #expect(client.seq == 0)
        #expect(client.isConnected)
    }

    // (2) A click created against seq n is dropped, never POSTed, once seq advanced to n+1.
    @Test func staleClickIsDroppedWithNotice() async throws {
        let server = StubServer { request in
            switch (request.method, request.path) {
            case ("GET", "/view"): return .ok(Views.reply(seq: 0, view: Views.v0))
            case ("POST", "/event"): return .ok(Views.reply(seq: 1, view: Views.v1))
            default: return .http(404, #"{"error":"not-found"}"#)
            }
        }
        let client = try await connectedClient(server)

        client.send(path: fieldPath, event: .input("a"))   // created against seq 0, sent, → seq 1
        client.send(path: addPath, event: .click)          // created against seq 0, reaches the head at seq 1
        await client.waitUntilIdle()

        #expect(server.posts.count == 1)
        #expect(server.posts[0].eventKind == "input")
        #expect(client.seq == 1)
        #expect(client.root == Views.node(Views.v1))
        #expect(client.notice == "The view changed; tap again")
        #expect(client.droppedInputs == 0)
        #expect(client.queue.isEmpty)
    }

    // (3) An input created against seq n is re-stamped and sent when a field is still at its path.
    @Test func olderInputIsRestampedWhenFieldStillThere() async throws {
        let server = StubServer { request in
            switch (request.method, request.path) {
            case ("GET", "/view"): return .ok(Views.reply(seq: 0, view: Views.v0))
            case ("POST", "/event"):
                return request.eventKind == "click"
                    ? .ok(Views.reply(seq: 1, view: Views.v1))
                    : .ok(Views.reply(seq: 2, view: Views.v1))
            default: return .http(404, #"{"error":"not-found"}"#)
            }
        }
        let client = try await connectedClient(server)

        client.send(path: addPath, event: .click)          // created against seq 0, sent with 0 → seq 1
        client.send(path: fieldPath, event: .input("a"))   // created against seq 0; field still at [1,0]
        await client.waitUntilIdle()

        let posts = server.posts
        try #require(posts.count == 2)
        #expect(posts[0].eventKind == "click")
        #expect(posts[0].seq == 0)
        #expect(posts[1].eventKind == "input")
        #expect(posts[1].seq == 1)                          // re-stamped, not the queue-time 0
        #expect(posts[1].eventPath == fieldPath)
        #expect(posts[1].eventValue as? String == "a")
        #expect(client.seq == 2)
        #expect(client.notice == nil)
        #expect(client.droppedInputs == 0)
    }

    // (3b) A submit from an older view is re-stamped iff the node is still a submitting field.
    @Test func olderSubmitIsRestampedOnlyForSubmittingField() async throws {
        let server = StubServer { request in
            switch (request.method, request.path) {
            case ("GET", "/view"): return .ok(Views.reply(seq: 0, view: Views.v0))
            case ("POST", "/event"):
                switch request.eventKind {
                case "input": return .ok(Views.reply(seq: 1, view: Views.v1))
                case "submit": return .ok(Views.reply(seq: 2, view: Views.v2))
                default: return .http(400, #"{"seq":0,"error":"no-handler"}"#)
                }
            default: return .http(404, #"{"error":"not-found"}"#)
            }
        }
        let client = try await connectedClient(server)

        // Type then Return in one burst: both are created against seq 0.
        client.send(path: fieldPath, event: .input("a"))
        client.send(path: fieldPath, event: .submit)
        await client.waitUntilIdle()

        let posts = server.posts
        try #require(posts.count == 2)
        #expect(posts[1].eventKind == "submit")
        #expect(posts[1].seq == 1)
        #expect(client.root == Views.node(Views.v2))
        #expect(client.seq == 2)

        // Now the field at [1,0] stops submitting: a submit from the older view is dropped.
        server.respond { request in
            switch (request.method, request.path) {
            case ("POST", "/event"):
                return request.eventKind == "input"
                    ? .ok(Views.reply(seq: 3, view: Views.noSubmit))
                    : .http(400, #"{"seq":3,"error":"no-handler"}"#)
            default: return .ok(Views.reply(seq: 3, view: Views.noSubmit))
            }
        }
        client.send(path: fieldPath, event: .input("a"))
        client.send(path: fieldPath, event: .submit)
        await client.waitUntilIdle()

        #expect(server.posts.count == 3)                   // the second submit never went out
        #expect(client.seq == 3)
        #expect(client.notice == "The view changed; tap again")
        #expect(client.droppedInputs == 0)
    }

    // (4) A transport failure parks the input and it is sent after the next successful fetch.
    @Test func transportFailureParksInputUntilNextFetch() async throws {
        let server = StubServer { request in
            switch (request.method, request.path) {
            case ("GET", "/view"): return .ok(Views.reply(seq: 0, view: Views.v0))
            case ("POST", "/event"): return .failure(.cannotConnectToHost)
            default: return .http(404, #"{"error":"not-found"}"#)
            }
        }
        let client = try await connectedClient(server)

        client.send(path: fieldPath, event: .input("a"))
        client.send(path: addPath, event: .click)          // dropped: taps are not parked
        await client.waitUntilIdle()

        #expect(server.posts.count == 1)
        #expect(client.isConnected == false)
        #expect(client.lastError != nil)
        #expect(client.parked == [.event(path: fieldPath, event: .input("a"), genSeq: 0)])
        #expect(client.hasPendingInput(for: fieldPath))
        #expect(client.hasParkedInputs)
        #expect(client.parkEpoch == 1)
        #expect(client.notice == "Disconnected; 1 action was discarded")
        #expect(client.droppedInputs == 0)
        #expect(client.root == Views.node(Views.v0))      // the view was kept
        #expect(client.seq == 0)

        // The bridge is back; the reconnect loop would call refresh().
        server.respond { request in
            switch (request.method, request.path) {
            case ("GET", "/view"): return .ok(Views.reply(seq: 0, view: Views.v0))
            case ("POST", "/event"): return .ok(Views.reply(seq: 1, view: Views.v1))
            default: return .http(404, #"{"error":"not-found"}"#)
            }
        }
        client.refresh()
        await client.waitUntilIdle()

        let posts = server.posts
        try #require(posts.count == 2)
        #expect(posts[1].eventKind == "input")
        #expect(posts[1].eventValue as? String == "a")
        #expect(posts[1].seq == 0)
        #expect(client.isConnected)
        #expect(client.parked.isEmpty)
        #expect(client.hasPendingInput(for: fieldPath) == false)
        #expect(client.root == Views.node(Views.v1))
        #expect(client.seq == 1)
        #expect(client.droppedInputs == 0)
    }

    // (4b) Parking keeps only the latest input per path; a newer input evicts a parked one.
    @Test func parkingKeepsLatestInputPerPath() async throws {
        let server = StubServer { request in
            switch (request.method, request.path) {
            case ("GET", "/view"): return .ok(Views.reply(seq: 0, view: Views.v0))
            case ("POST", "/event"): return .failure(.timedOut)
            default: return .http(404, #"{"error":"not-found"}"#)
            }
        }
        let client = try await connectedClient(server)

        client.send(path: fieldPath, event: .input("a"))   // in flight when the failure comes
        client.send(path: addPath, event: .click)
        client.send(path: fieldPath, event: .input("ab"))  // queued behind the click
        await client.waitUntilIdle()
        #expect(client.parked == [.event(path: fieldPath, event: .input("ab"), genSeq: 0)])

        // Typing more while disconnected replaces the parked value.
        client.send(path: fieldPath, event: .input("abc"))
        await client.waitUntilIdle()
        #expect(client.parked == [.event(path: fieldPath, event: .input("abc"), genSeq: 0)])
        #expect(server.posts.count == 2)

        // Return while parked: the parked draft goes out before the submit.
        server.respond { request in
            switch (request.method, request.path) {
            case ("GET", "/view"): return .ok(Views.reply(seq: 0, view: Views.v0))
            case ("POST", "/event"):
                return request.eventKind == "input"
                    ? .ok(Views.reply(seq: 1, view: Views.v1))
                    : .ok(Views.reply(seq: 2, view: Views.v2))
            default: return .http(404, #"{"error":"not-found"}"#)
            }
        }
        client.send(path: fieldPath, event: .submit)
        #expect(client.parked.isEmpty)
        await client.waitUntilIdle()

        let posts = server.posts
        try #require(posts.count == 4)
        #expect(posts[2].eventKind == "input")
        #expect(posts[2].eventValue as? String == "abc")
        #expect(posts[2].seq == 0)
        #expect(posts[3].eventKind == "submit")
        #expect(posts[3].seq == 1)                          // re-stamped behind the input
        #expect(client.root == Views.node(Views.v2))
        #expect(client.seq == 2)
    }

    // (5) A 503 keeps the view and raises the sticky "backend unavailable" notice; a dropped tap is counted
    // in a separate, transient notice.
    @Test func unavailableKeepsViewAndNotices() async throws {
        let server = StubServer { request in
            switch (request.method, request.path) {
            case ("GET", "/view"): return .ok(Views.reply(seq: 0, view: Views.v0))
            case ("POST", "/event"): return .http(503, Views.unavailable)
            default: return .http(404, #"{"error":"not-found"}"#)
            }
        }
        let client = try await connectedClient(server)

        client.send(path: fieldPath, event: .input("a"))
        await client.waitUntilIdle()

        #expect(server.posts.count == 1)
        #expect(server.gets.count == 1)                     // no resync: the view is kept
        #expect(client.root == Views.node(Views.v0))
        #expect(client.seq == 0)
        #expect(client.isConnected)                         // the bridge answered
        #expect(client.lastError == nil)
        #expect(client.unavailable == "Backend unavailable: binary missing")
        #expect(client.notice == nil)                       // nothing was discarded: no transient notice
        #expect(client.parked == [.event(path: fieldPath, event: .input("a"), genSeq: 0)])
        #expect(client.hasPendingInput(for: fieldPath))
        #expect(client.parkEpoch == 1)
        #expect(client.droppedInputs == 0)

        // A tap during the outage is dropped and counted in the transient notice; the sticky one is unchanged.
        client.send(path: addPath, event: .click)
        await client.waitUntilIdle()
        #expect(client.notice == "Backend unavailable; 1 action was discarded")
        #expect(client.unavailable == "Backend unavailable: binary missing")
        #expect(client.parked.count == 1)
    }

    // (5b) The sticky notice survives a successful GET /view (served from the bridge's cache) and is
    // cleared by the next /event reply of any status, here a 400.
    @Test func unavailableIsStickyUntilNextEventReply() async throws {
        let server = StubServer { request in
            switch (request.method, request.path) {
            case ("GET", "/view"): return .ok(Views.reply(seq: 0, view: Views.v0))
            case ("POST", "/event"): return .http(503, Views.unavailable)
            default: return .http(404, #"{"error":"not-found"}"#)
            }
        }
        let client = try await connectedClient(server)

        // A tap, not a draft: nothing is parked, so the fetch below is not followed by another POST.
        client.send(path: addPath, event: .click)
        await client.waitUntilIdle()
        #expect(server.posts.count == 1)
        #expect(client.unavailable == "Backend unavailable: binary missing")
        #expect(client.notice == "Backend unavailable; 1 action was discarded")
        #expect(client.parked.isEmpty)
        #expect(client.isConnected)

        // GET /view 200 proves nothing about the CLI: the sticky notice stays.
        client.refresh()
        await client.waitUntilIdle()
        #expect(server.gets.count == 2)
        #expect(server.posts.count == 1)
        #expect(client.root == Views.node(Views.v0))
        #expect(client.unavailable == "Backend unavailable: binary missing")

        // The next /event reply, whatever its status, clears it.
        server.respond { request in
            switch (request.method, request.path) {
            case ("GET", "/view"): return .ok(Views.reply(seq: 0, view: Views.v0))
            case ("POST", "/event"): return .http(400, #"{"seq":0,"error":"no-handler"}"#)
            default: return .http(404, #"{"error":"not-found"}"#)
            }
        }
        client.send(path: addPath, event: .click)
        await client.waitUntilIdle()
        #expect(server.posts.count == 2)
        #expect(server.gets.count == 3)                     // the 400 triggered a resync
        #expect(client.unavailable == nil)
        #expect(client.notice == "Rejected: no-handler")
    }

    // (5c) The discarded-count notice is transient and independent of the sticky one: clearing it (what the
    // view's timer does) leaves `unavailable` alone, a later transport failure writes its own count without
    // touching `unavailable`, and a 200 /event reply finally clears the sticky notice.
    @Test func discardedNoticeIsTransientAndIndependent() async throws {
        let server = StubServer { request in
            switch (request.method, request.path) {
            case ("GET", "/view"): return .ok(Views.reply(seq: 0, view: Views.v0))
            case ("POST", "/event"): return .http(503, Views.unavailable)
            default: return .http(404, #"{"error":"not-found"}"#)
            }
        }
        let client = try await connectedClient(server)

        client.send(path: addPath, event: .click)
        await client.waitUntilIdle()
        try #require(client.notice == "Backend unavailable; 1 action was discarded")
        try #require(client.unavailable == "Backend unavailable: binary missing")

        client.clearNotice()
        #expect(client.notice == nil)
        #expect(client.unavailable == "Backend unavailable: binary missing")

        // The bridge goes away: the transport notice gets its own count; the sticky notice is not an
        // /event reply's business here and stays.
        server.respond { request in
            switch (request.method, request.path) {
            case ("GET", "/view"): return .ok(Views.reply(seq: 0, view: Views.v0))
            case ("POST", "/event"): return .failure(.cannotConnectToHost)
            default: return .http(404, #"{"error":"not-found"}"#)
            }
        }
        client.send(path: addPath, event: .click)
        await client.waitUntilIdle()
        #expect(client.isConnected == false)
        #expect(client.notice == "Disconnected; 1 action was discarded")
        #expect(client.unavailable == "Backend unavailable: binary missing")

        // Back, and the CLI with it: a 200 /event reply clears the sticky notice and reconnects.
        server.respond { request in
            switch (request.method, request.path) {
            case ("GET", "/view"): return .ok(Views.reply(seq: 0, view: Views.v0))
            case ("POST", "/event"): return .ok(Views.reply(seq: 1, view: Views.v1))
            default: return .http(404, #"{"error":"not-found"}"#)
            }
        }
        client.refresh()
        await client.waitUntilIdle()
        #expect(client.isConnected)
        #expect(client.unavailable == "Backend unavailable: binary missing")   // GET /view: still set
        client.send(path: fieldPath, event: .input("a"))
        await client.waitUntilIdle()
        #expect(client.seq == 1)
        #expect(client.unavailable == nil)
        #expect(client.notice == "Disconnected; 1 action was discarded")     // transient: the view's timer clears it
    }

    // (5d) An unintelligible /event reply counts as the backend being unavailable (sticky, inputs parked,
    // still connected); the parked draft goes out once the backend answers again, which clears the notice.
    @Test func unreadableEventReplyIsUnavailable() async throws {
        let server = StubServer { request in
            switch (request.method, request.path) {
            case ("GET", "/view"): return .ok(Views.reply(seq: 0, view: Views.v0))
            case ("POST", "/event"): return .http(200, "<html>oops</html>")
            default: return .http(404, #"{"error":"not-found"}"#)
            }
        }
        let client = try await connectedClient(server)

        client.send(path: fieldPath, event: .input("a"))
        await client.waitUntilIdle()
        #expect(server.posts.count == 1)
        #expect(server.gets.count == 1)                     // the view is kept, no resync
        #expect(client.isConnected)                         // the bridge answered, however badly
        #expect(client.lastError == nil)
        #expect(client.unavailable == "Backend unavailable: unreadable response (HTTP 200)")
        #expect(client.notice == nil)
        #expect(client.parked == [.event(path: fieldPath, event: .input("a"), genSeq: 0)])
        #expect(client.parkEpoch == 1)
        #expect(client.droppedInputs == 0)

        server.respond { request in
            switch (request.method, request.path) {
            case ("GET", "/view"): return .ok(Views.reply(seq: 0, view: Views.v0))
            case ("POST", "/event"): return .ok(Views.reply(seq: 1, view: Views.v1))
            default: return .http(404, #"{"error":"not-found"}"#)
            }
        }
        client.refresh()                                    // what retryParkedInputs() does
        await client.waitUntilIdle()
        let posts = server.posts
        try #require(posts.count == 2)
        #expect(posts[1].eventKind == "input")
        #expect(posts[1].seq == 0)
        #expect(client.seq == 1)
        #expect(client.unavailable == nil)
        #expect(client.parked.isEmpty)
    }

    // (6) A 409 whose body view no longer has a field at the input's path drops the input.
    @Test func staleWithoutFieldDropsInput() async throws {
        let server = StubServer { request in
            switch (request.method, request.path) {
            case ("GET", "/view"): return .ok(Views.reply(seq: 0, view: Views.v0))
            case ("POST", "/event"): return .http(409, Views.stale(seq: 1, view: Views.noField))
            default: return .http(404, #"{"error":"not-found"}"#)
            }
        }
        let client = try await connectedClient(server)

        client.send(path: fieldPath, event: .input("a"))
        await client.waitUntilIdle()

        #expect(server.posts.count == 1)
        #expect(server.gets.count == 1)                     // the 409 body was adopted, no GET /view
        #expect(client.root == Views.node(Views.noField))
        #expect(client.seq == 1)
        #expect(client.droppedInputs == 1)
        #expect(client.hasPendingInput(for: fieldPath) == false)
        #expect(client.queue.isEmpty)
        #expect(client.parked.isEmpty)
        #expect(client.notice == "The view changed; 1 action was discarded")
    }

    // (6b) A 409 whose body still has the field re-stamps the input and re-sends it; taps are dropped.
    @Test func staleWithFieldRestampsInput() async throws {
        let server = StubServer { request in
            switch (request.method, request.path) {
            case ("GET", "/view"): return .ok(Views.reply(seq: 0, view: Views.v0))
            case ("POST", "/event"):
                return request.seq == 0
                    ? .http(409, Views.stale(seq: 5, view: Views.v0))
                    : .ok(Views.reply(seq: 6, view: Views.v1))
            default: return .http(404, #"{"error":"not-found"}"#)
            }
        }
        let client = try await connectedClient(server)

        client.send(path: fieldPath, event: .input("a"))   // 409 → re-stamped to 5 → 200
        client.send(path: addPath, event: .click)          // from seq 0: dropped at the 409
        await client.waitUntilIdle()

        let posts = server.posts
        try #require(posts.count == 2)
        #expect(posts[0].seq == 0)
        #expect(posts[1].seq == 5)
        #expect(posts[1].eventKind == "input")
        #expect(server.gets.count == 1)
        #expect(client.seq == 6)
        #expect(client.droppedInputs == 0)
        #expect(client.notice == "The view changed; 1 action was discarded")
    }

    // (6c) Three consecutive 409s drop everything, inputs included, and resync once.
    @Test func threeStalesDropEverythingAndResync() async throws {
        let server = StubServer { request in
            switch (request.method, request.path) {
            case ("GET", "/view"): return .ok(Views.reply(seq: 9, view: Views.v0))
            case ("POST", "/event"):
                let next = (request.seq ?? 0) + 1
                return .http(409, Views.stale(seq: next, view: Views.v0))
            default: return .http(404, #"{"error":"not-found"}"#)
            }
        }
        let client = makeClient(server)
        client.refresh()
        await client.waitUntilIdle()
        try #require(client.seq == 9)

        client.send(path: fieldPath, event: .input("a"))
        await client.waitUntilIdle()

        #expect(server.posts.count == 3)                    // 9, 10, 11 → stale each time
        #expect(server.posts.map(\.seq) == [9, 10, 11])
        #expect(server.gets.count == 2)                     // initial + the resync after the cap
        #expect(client.droppedInputs == 1)
        #expect(client.queue.isEmpty)
        #expect(client.parked.isEmpty)
        #expect(client.hasPendingInput(for: fieldPath) == false)
        #expect(client.notice == "The view changed; 1 action was discarded")
        #expect(client.isConnected)
    }

    // (6d) "Consecutive" means within one drain of the queue: two taps dropped by 409s in separate drains
    // (the client went idle in between) do not count against a later draft, whose own 409 is only its
    // first strike. The draft is re-stamped and survives; nothing is resynced.
    @Test func staleStreakResetsWhenQueueDrains() async throws {
        let server = StubServer { request in
            switch (request.method, request.path) {
            case ("GET", "/view"): return .ok(Views.reply(seq: 0, view: Views.v0))
            case ("POST", "/event"):
                let next = (request.seq ?? 0) + 1
                if request.eventKind == "click" || request.seq == 2 {
                    return .http(409, Views.stale(seq: next, view: Views.v0))
                }
                return .ok(Views.reply(seq: 4, view: Views.v1))   // the re-stamped input (seq 3) is accepted
            default: return .http(404, #"{"error":"not-found"}"#)
            }
        }
        let client = try await connectedClient(server)

        client.send(path: addPath, event: .click)          // 409 → seq 1, tap dropped; queue empty → idle
        await client.waitUntilIdle()
        try #require(client.seq == 1)
        try #require(client.notice == "The view changed; 1 action was discarded")

        client.send(path: addPath, event: .click)          // 409 → seq 2, tap dropped; idle again
        await client.waitUntilIdle()
        try #require(client.seq == 2)
        try #require(server.posts.count == 2)
        client.clearNotice()

        client.send(path: fieldPath, event: .input("a"))   // 409 → seq 3: first strike of this drain, not third
        await client.waitUntilIdle()

        #expect(server.posts.map(\.seq) == [0, 1, 2, 3])
        #expect(server.posts.map(\.eventKind) == ["click", "click", "input", "input"])
        #expect(server.gets.count == 1)                     // no cap, no resync
        #expect(client.seq == 4)
        #expect(client.root == Views.node(Views.v1))
        #expect(client.droppedInputs == 0)
        #expect(client.hasPendingInput(for: fieldPath) == false)
        #expect(client.notice == nil)                       // nothing was discarded
        #expect(client.queue.isEmpty)
        #expect(client.parked.isEmpty)
    }

    // (6e) The cap notice counts what is actually discarded at the third 409, after the table and the
    // per-path coalescing of the earlier ones in the same drain: here one draft, not the three jobs queued.
    @Test func staleCapNoticeCountsWhatIsLeft() async throws {
        let server = StubServer { request in
            switch (request.method, request.path) {
            case ("GET", "/view"): return .ok(Views.reply(seq: 0, view: Views.v0))
            case ("POST", "/event"):
                let next = (request.seq ?? 0) + 1
                return .http(409, Views.stale(seq: next, view: Views.v0))
            default: return .http(404, #"{"error":"not-found"}"#)
            }
        }
        let client = try await connectedClient(server)

        client.send(path: fieldPath, event: .input("a"))   // in flight at the first 409
        client.send(path: addPath, event: .click)          // dropped by the table at the first 409
        client.send(path: fieldPath, event: .input("ab"))  // supersedes "a" when both are re-stamped
        await client.waitUntilIdle()

        let posts = server.posts
        #expect(posts.map(\.seq) == [0, 1, 2])
        #expect(posts.map(\.eventKind) == ["input", "input", "input"])
        #expect(posts[1].eventValue as? String == "ab")
        #expect(posts[2].eventValue as? String == "ab")
        #expect(server.gets.count == 2)                     // initial + the resync after the cap
        #expect(client.droppedInputs == 1)                  // "ab"; "a" was superseded, not discarded
        #expect(client.notice == "The view changed; 1 action was discarded")
        #expect(client.queue.isEmpty)
        #expect(client.parked.isEmpty)
        #expect(client.hasPendingInput(for: fieldPath) == false)
    }

    // (6f) The cap counts only what the table would have kept (PROTOCOL.md: "an event the table drops anyway
    // gets its own 'tap again' notice"). A draft is 409ed twice and re-stamped to seq 2; while its third POST
    // is out, a tap is made, also against seq 2. The third 409 adopts seq 3: the table drops the tap, as after
    // any 409, and keeps the re-stamped draft, which is the one thing the cap then discards. So "1 action",
    // not 2. The client has one transient notice slot, so the cap notice replaces the tap's (here identical)
    // one; the tap is not a draft, so `droppedInputs` moves by one.
    @Test func staleCapNoticeExcludesWhatTheTableDrops() async throws {
        let gate = Gate()
        let server = StubServer { request in
            switch (request.method, request.path) {
            case ("GET", "/view"): return .ok(Views.reply(seq: 0, view: Views.v0))
            case ("POST", "/event"):
                let next = (request.seq ?? 0) + 1
                if request.seq == 2 { gate.wait() }        // hold the third POST so the test can tap meanwhile
                return .http(409, Views.stale(seq: next, view: Views.v0))
            default: return .http(404, #"{"error":"not-found"}"#)
            }
        }
        let client = try await connectedClient(server)

        client.send(path: fieldPath, event: .input("a"))   // 409 → seq 1, 409 → seq 2, third POST held
        await waitUntil(client.seq == 2)
        try #require(client.seq == 2)
        try #require(client.inFlight == .event(path: fieldPath, event: .input("a"), genSeq: 2))
        client.send(path: addPath, event: .click)          // against seq 2: stale once seq 3 is adopted
        gate.open()
        await client.waitUntilIdle()

        #expect(server.posts.map(\.seq) == [0, 1, 2])
        #expect(server.posts.map(\.eventKind) == ["input", "input", "input"])   // the tap never went out
        #expect(server.gets.count == 2)                     // initial + the resync after the cap
        #expect(client.droppedInputs == 1)                  // the draft; a tap is not a draft
        #expect(client.notice == "The view changed; 1 action was discarded")   // the draft, not the tap
        #expect(client.queue.isEmpty)
        #expect(client.parked.isEmpty)
        #expect(client.inFlight == nil)
        #expect(client.hasPendingInput(for: fieldPath) == false)
    }

    // setBaseURL discards queued and parked inputs and bumps the counter.
    @Test func switchingBridgeDiscardsEverything() async throws {
        let server = StubServer { request in
            switch (request.method, request.path) {
            case ("GET", "/view"): return .ok(Views.reply(seq: 0, view: Views.v0))
            case ("POST", "/event"): return .failure(.cannotConnectToHost)
            default: return .http(404, #"{"error":"not-found"}"#)
            }
        }
        let client = try await connectedClient(server)
        client.send(path: fieldPath, event: .input("a"))
        await client.waitUntilIdle()
        try #require(client.parked.count == 1)

        let other = StubServer { request in
            switch (request.method, request.path) {
            case ("GET", "/view"): return .ok(Views.reply(seq: 3, view: Views.v1))
            default: return .http(404, #"{"error":"not-found"}"#)
            }
        }
        client.setBaseURL(other.baseURL)
        #expect(client.root == nil)
        #expect(client.seq == 0)
        #expect(client.parked.isEmpty)
        #expect(client.queue.isEmpty)
        #expect(client.droppedInputs == 1)
        #expect(client.hasPendingInput(for: fieldPath) == false)

        client.refresh()
        await client.waitUntilIdle()
        #expect(client.root == Views.node(Views.v1))
        #expect(client.seq == 3)
        #expect(server.posts.count == 1)
        #expect(other.posts.isEmpty)
    }

    // An input reaching the head of the queue after a 200 removed its field is dropped there, never sent.
    @Test func inputDroppedAtHeadWhenFieldGone() async throws {
        let server = StubServer { request in
            switch (request.method, request.path) {
            case ("GET", "/view"): return .ok(Views.reply(seq: 0, view: Views.v0))
            case ("POST", "/event"): return .ok(Views.reply(seq: 1, view: Views.noField))
            default: return .http(404, #"{"error":"not-found"}"#)
            }
        }
        let client = try await connectedClient(server)

        client.send(path: addPath, event: .click)          // → seq 1, and [1,0] is now a text
        client.send(path: fieldPath, event: .input("a"))   // created against seq 0
        await client.waitUntilIdle()

        #expect(server.posts.count == 1)
        #expect(server.posts[0].eventKind == "click")
        #expect(client.droppedInputs == 1)
        #expect(client.hasPendingInput(for: fieldPath) == false)
        #expect(client.notice == "The view changed; your text was discarded")
        #expect(client.root == Views.node(Views.noField))
        #expect(client.seq == 1)
    }

    // A 409 without a view in its body (not per protocol) resyncs first; the rules run after the fetch.
    @Test func staleWithoutViewResyncsThenRestamps() async throws {
        let server = StubServer { request in
            switch (request.method, request.path) {
            case ("GET", "/view"): return .ok(Views.reply(seq: 4, view: Views.v0))
            default: return .http(404, #"{"error":"not-found"}"#)
            }
        }
        let client = makeClient(server)
        client.refresh()
        await client.waitUntilIdle()
        try #require(client.seq == 4)

        // The server has moved on to seq 5 (another client acted) and answers a bare 409.
        server.respond { request in
            switch (request.method, request.path) {
            case ("GET", "/view"): return .ok(Views.reply(seq: 5, view: Views.v1))
            case ("POST", "/event"):
                return request.seq == 4
                    ? .http(409, #"{"seq":5,"error":"stale"}"#)
                    : .ok(Views.reply(seq: 6, view: Views.v1))
            default: return .http(404, #"{"error":"not-found"}"#)
            }
        }

        client.send(path: addPath, event: .click)          // 409 → kept until the fetch, then dropped (older view)
        client.send(path: fieldPath, event: .input("a"))   // re-stamped to 5 after the fetch and sent
        await client.waitUntilIdle()

        let posts = server.posts
        try #require(posts.count == 2)
        #expect(posts[0].eventKind == "click")
        #expect(posts[0].seq == 4)
        #expect(posts[1].eventKind == "input")
        #expect(posts[1].seq == 5)
        #expect(server.gets.count == 2)                     // initial + the resync forced by the bare 409
        #expect(client.seq == 6)
        #expect(client.droppedInputs == 0)
        #expect(client.notice == "The view changed; tap again")
    }

    // 400 from the CLI: notice, resync, and the rest of the queue is re-checked afterwards.
    @Test func rejectedEventResyncsAndKeepsQueue() async throws {
        let server = StubServer { request in
            switch (request.method, request.path) {
            case ("GET", "/view"): return .ok(Views.reply(seq: 0, view: Views.v0))
            case ("POST", "/event"):
                return request.eventKind == "click"
                    ? .http(400, #"{"seq":0,"error":"no-handler"}"#)
                    : .ok(Views.reply(seq: 1, view: Views.v1))
            default: return .http(404, #"{"error":"not-found"}"#)
            }
        }
        let client = try await connectedClient(server)

        client.send(path: addPath, event: .click)          // disabled button: no-handler
        client.send(path: fieldPath, event: .input("a"))   // still valid once the fetch has applied (seq unchanged)
        await client.waitUntilIdle()

        #expect(server.posts.count == 2)
        #expect(server.gets.count == 2)
        #expect(server.posts[1].eventKind == "input")
        #expect(server.posts[1].seq == 0)
        #expect(client.seq == 1)
        #expect(client.root == Views.node(Views.v1))
    }
}

@Suite("Node lookup")
struct NodeLookupTests {
    @Test func nodeAtPath() {
        let root = Views.node(Views.v0)
        #expect(root.node(at: []) == root)
        #expect(root.node(at: [0]) == .text("Todos", .title))
        #expect(root.node(at: [1, 0]) == .field(placeholder: "What needs doing?", value: "", submits: true))
        #expect(root.node(at: [1, 1]) == .button(label: "Add", role: .primary, enabled: false))
        #expect(root.node(at: [2]) == .col([]))
        #expect(root.node(at: [3]) == .divider)
    }

    @Test func nodeAtBadPath() {
        let root = Views.node(Views.v0)
        #expect(root.node(at: [9]) == nil)
        #expect(root.node(at: [-1]) == nil)
        #expect(root.node(at: [0, 0]) == nil)        // text has no children
        #expect(root.node(at: [1, 0, 0]) == nil)     // field has no children
        #expect(root.node(at: [1, 2]) == nil)
        #expect(root.node(at: [2, 0]) == nil)        // empty col
        #expect(Node.divider.node(at: [0]) == nil)
    }
}
