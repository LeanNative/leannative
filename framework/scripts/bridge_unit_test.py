#!/opt/homebrew/bin/python3 -I
"""Unit tests for bridge/bridge.py (see PROTOCOL.md, "HTTP bridge"), stdlib unittest, no network port.

    /opt/homebrew/bin/python3 -I scripts/bridge_unit_test.py

`Cli` is driven directly with scripts/fake_cli.py and throwaway `python3 -c` CLIs: failed start, 503
cli-unavailable with /view unchanged, recovery with 502, desynchronised replies, reply timeout. `Handler` is
driven over a fake connection (no socket): NUL in the path, an absolute-form target with an unbalanced bracket,
the POST pre-filter, log sanitising (escaped event kind, truncated path and seq).
"""
import importlib.util
import io
import json
import os
import subprocess
import sys
import time
import unittest
from unittest import mock

sys.dont_write_bytecode = True  # bridge.py is imported below; never leave bridge/__pycache__ behind in the tree

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PY = sys.executable
FAKE = os.path.join(ROOT, "scripts", "fake_cli.py")
VIEW0 = {"t": "col", "c": []}
INIT_LINE = json.dumps({"seq": 0, "view": VIEW0})

# Throwaway CLIs (argv lists). Each prints what the comment says and exits on EOF or when killed.
EXIT3 = [PY, "-c", "import sys; sys.exit(3)"]                                           # exits before any output
GARBAGE_THEN_HANG = [PY, "-c", "import sys; print('not json', flush=True); sys.stdin.read()"]
SILENT_HANG = [PY, "-c", "import sys; sys.stdin.read()"]                                # never prints anything
VIEW_THEN_HANG = [PY, "-c", "import sys; print(%r, flush=True)\nfor line in sys.stdin: pass" % INIT_LINE]
VIEW_SEQ5 = [PY, "-c", "import sys; print(%r, flush=True); sys.stdin.read()" % json.dumps({"seq": 5, "view": VIEW0})]


def load_bridge():
    spec = importlib.util.spec_from_file_location("bridge", os.path.join(ROOT, "bridge", "bridge.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


bridge = load_bridge()


def req(seq, path=(1, 0), event=None):
    return {"seq": seq, "path": list(path), "event": event or {"k": "input", "value": "x"}}


class Base(unittest.TestCase):
    def setUp(self):
        self.saved_timeout = bridge.REPLY_TIMEOUT
        bridge.REPLY_TIMEOUT = 1.0  # keep failure paths fast; every test below is calibrated against this
        self.clis = []
        self.procs = []  # every Popen the bridge created while a test ran (recorded by the patched Popen below)
        self.real_popen = bridge.subprocess.Popen

        def popen(*a, **kw):
            p = self.real_popen(*a, **kw)
            self.procs.append(p)
            return p

        self.popen_patch = mock.patch.object(bridge.subprocess, "Popen", side_effect=popen)
        self.popen_patch.start()

    def tearDown(self):
        self.popen_patch.stop()
        for c in self.clis:
            c.kill()
        for p in self.procs:  # belt and braces: nothing a test started may outlive it
            if p.poll() is None:
                p.kill()
            try:
                p.wait(timeout=5)
            except subprocess.TimeoutExpired:
                pass
        bridge.REPLY_TIMEOUT = self.saved_timeout

    def cli(self, argv):
        c = bridge.Cli(argv)
        self.clis.append(c)
        return c

    def assertDeadProcs(self):
        for p in self.procs:
            self.assertIsNotNone(p.poll(), f"pid {p.pid} ({p.args[-1][:40]!r}) was left running")


class StartTests(Base):
    def test_exit_before_view_raises_and_leaves_no_proc(self):
        with self.assertRaises(RuntimeError) as cm:
            bridge.Cli(EXIT3)
        self.assertIn("exited with code 3", str(cm.exception))
        self.assertEqual(len(self.procs), 1)
        self.assertDeadProcs()

    def test_missing_binary_raises_runtime_error(self):
        with self.assertRaises(RuntimeError) as cm:
            bridge.Cli(["/nonexistent/elmlean-binary"])
        self.assertIn("cannot start CLI", str(cm.exception))
        self.assertEqual(self.procs, [])

    def test_garbage_first_line_kills_the_process(self):
        with self.assertRaises(RuntimeError) as cm:
            bridge.Cli(GARBAGE_THEN_HANG)
        self.assertIn("non-JSON", str(cm.exception))
        self.assertDeadProcs()

    def test_no_initial_view_within_timeout_kills_the_process(self):
        t0 = time.monotonic()
        with self.assertRaises(RuntimeError) as cm:
            bridge.Cli(SILENT_HANG)
        dt = time.monotonic() - t0
        self.assertIn("no reply within", str(cm.exception))
        self.assertGreaterEqual(dt, 0.9)
        self.assertLess(dt, 4.0)
        self.assertDeadProcs()

    def test_initial_view_must_have_seq_0(self):
        with self.assertRaises(RuntimeError) as cm:
            bridge.Cli(VIEW_SEQ5)
        self.assertIn("seq-0 view", str(cm.exception))
        self.assertDeadProcs()

    def test_detail_never_contains_argv(self):
        secret = "/nonexistent/dir with spaces/elmlean"
        with self.assertRaises(RuntimeError) as cm:
            bridge.Cli([secret])
        self.assertNotIn("dir with spaces", str(cm.exception))


class SendTests(Base):
    def test_happy_path_and_error_mapping(self):
        c = self.cli([PY, FAKE])
        self.assertEqual(c.current["seq"], 0)
        status, body = c.send(req(0, event={"k": "input", "value": "Milk"}))
        self.assertEqual((status, body["seq"]), (200, 1))
        self.assertIs(c.current, body)
        status, body = c.send(req(0, event={"k": "input", "value": "Milk"}))
        self.assertEqual((status, body["error"], body["seq"]), (409, "stale", 1))
        self.assertIn("view", body)
        self.assertEqual(c.current["seq"], 1)
        status, body = c.send(req(1, path=[99], event={"k": "click"}))
        self.assertEqual((status, body["error"], body["seq"]), (400, "bad-path", 1))
        status, body = c.send(req(1, event={"k": "nope"}))
        self.assertEqual((status, body["error"]), (400, "bad-json"))
        self.assertEqual(c.current["seq"], 1)

    def test_dead_cli_that_cannot_restart_gives_503_and_keeps_current(self):
        c = self.cli([PY, FAKE])
        status, view1 = c.send(req(0, event={"k": "input", "value": "Milk"}))
        self.assertEqual(status, 200)
        c.argv = EXIT3
        c.proc.kill()
        c.proc.wait(timeout=5)
        for _ in range(2):  # every POST tries again and fails the same way
            status, body = c.send(req(1, event={"k": "submit"}))
            self.assertEqual(status, 503)
            self.assertEqual(body["error"], "cli-unavailable")
            self.assertIn("exited with code 3", body["detail"])
            self.assertIs(c.current, view1, "GET /view must keep serving the last known view")
            self.assertIsNone(c.proc)
            self.assertIsNone(c.q)
        # the binary is back: the next POST restarts (502, seq 0) and then everything works again
        c.argv = [PY, FAKE]
        status, body = c.send(req(1, event={"k": "submit"}))
        self.assertEqual((status, body), (502, {"error": "cli-restarted", "seq": 0}))
        self.assertEqual(c.current["seq"], 0)
        self.assertIsNotNone(c.proc)
        status, body = c.send(req(0, event={"k": "input", "value": "Eggs"}))
        self.assertEqual((status, body["seq"]), (200, 1))
        self.assertEqual(c.current["view"]["c"][1]["c"][0]["value"], "Eggs")
        self.assertEqual(c.send(req(1, event={"k": "submit"}))[0], 200)
        self.assertEqual(c.current["seq"], 2)

    def test_missing_binary_gives_503_with_detail(self):
        c = self.cli([PY, FAKE])
        c.argv = ["/nonexistent/elmlean-binary"]
        c.proc.kill()
        c.proc.wait(timeout=5)
        status, body = c.send(req(0, event={"k": "submit"}))
        self.assertEqual(status, 503)
        self.assertEqual(body["error"], "cli-unavailable")
        self.assertIn("cannot start CLI", body["detail"])
        self.assertEqual(c.current["seq"], 0)

    def test_late_initial_view_is_a_desync_not_a_200(self):
        c = self.cli([PY, FAKE])
        self.assertEqual(c.send(req(0, event={"k": "input", "value": "Milk"}))[0], 200)
        old_proc = c.proc
        c.q.put(INIT_LINE + "\n")  # a seq-0 view from a previous CLI lands in the live queue
        status, body = c.send(req(1, event={"k": "submit"}))
        self.assertEqual((status, body), (502, {"error": "cli-restarted", "seq": 0}))
        self.assertIsNot(c.proc, old_proc)
        self.assertIsNotNone(old_proc.poll())
        self.assertEqual(c.current["seq"], 0)
        status, body = c.send(req(0, event={"k": "input", "value": "again"}))
        self.assertEqual((status, body["seq"]), (200, 1))

    def test_view_with_skipped_seq_is_a_desync(self):
        c = self.cli([PY, FAKE])
        c.q.put(json.dumps({"seq": 2, "view": VIEW0}) + "\n")
        status, body = c.send(req(0, event={"k": "submit"}))
        self.assertEqual(status, 502)
        self.assertEqual(c.current["seq"], 0)
        self.assertNotEqual(c.current["view"], VIEW0, "current must come from the fresh CLI, not the stray line")

    def test_error_reply_with_wrong_seq_is_a_desync(self):
        c = self.cli([PY, FAKE])
        c.q.put(json.dumps({"seq": 5, "error": "bad-path"}) + "\n")
        status, body = c.send(req(0, event={"k": "submit"}))
        self.assertEqual((status, body), (502, {"error": "cli-restarted", "seq": 0}))
        self.assertEqual(c.send(req(0, event={"k": "input", "value": "x"}))[0], 200)

    def test_bool_seq_in_reply_is_not_an_int(self):
        c = self.cli([PY, FAKE])
        c.q.put(json.dumps({"seq": True, "view": VIEW0}) + "\n")  # True == 1 but is not a JSON integer
        self.assertEqual(c.send(req(0, event={"k": "submit"}))[0], 502)

    def test_non_json_reply_restarts(self):
        c = self.cli([PY, FAKE])
        c.q.put("garbage\n")
        status, body = c.send(req(0, event={"k": "submit"}))
        self.assertEqual((status, body["error"]), (502, "cli-restarted"))

    def test_hung_cli_gives_502_after_reply_timeout(self):
        c = self.cli(VIEW_THEN_HANG)
        first = c.proc
        t0 = time.monotonic()
        status, body = c.send(req(0, event={"k": "submit"}))
        dt = time.monotonic() - t0
        self.assertEqual((status, body), (502, {"error": "cli-restarted", "seq": 0}))
        self.assertGreaterEqual(dt, 0.9)
        self.assertLess(dt, 4.0)
        self.assertIsNotNone(first.poll(), "the hung CLI must be killed")
        self.assertIsNot(c.proc, first)
        self.assertEqual(c.current, {"seq": 0, "view": VIEW0})

    def test_exited_cli_restarts_with_502(self):
        c = self.cli([PY, FAKE])
        c.proc.kill()
        c.proc.wait(timeout=5)
        status, body = c.send(req(0, event={"k": "submit"}))
        self.assertEqual((status, body), (502, {"error": "cli-restarted", "seq": 0}))
        self.assertEqual(c.send(req(0, event={"k": "input", "value": "x"}))[0], 200)

    def test_kill_clears_proc_and_queue(self):
        c = self.cli([PY, FAKE])
        p = c.proc
        c.kill()
        self.assertIsNone(c.proc)
        self.assertIsNone(c.q)
        self.assertIsNotNone(p.poll())
        self.assertEqual(c.current["seq"], 0)
        status, body = c.send(req(0, event={"k": "submit"}))  # proc is None: start again
        self.assertEqual((status, body), (502, {"error": "cli-restarted", "seq": 0}))


class FakeConnection:
    """What BaseHTTPRequestHandler needs from a socket: makefile, sendall, settimeout."""

    def __init__(self, data):
        self.rfile = io.BytesIO(data)
        self.out = io.BytesIO()

    def makefile(self, mode, *a, **kw):
        return self.rfile if "r" in mode else self.out

    def sendall(self, b):
        self.out.write(b)

    def settimeout(self, t):
        pass

    def close(self):
        pass


class StubCli:
    def __init__(self):
        self.current = {"seq": 3, "view": VIEW0}
        self.sent = []

    def send(self, r):
        self.sent.append(r)
        return 400, {"seq": 3, "error": "bad-json", "detail": "stub"}


def handle(raw, cli=None):
    """Run one raw HTTP request through Handler; returns (status, headers dict, body bytes, stderr text)."""
    conn = FakeConnection(raw)
    err = io.StringIO()
    bridge.Handler.cli = cli or StubCli()
    with mock.patch.object(sys, "stderr", err):
        bridge.Handler(conn, ("127.0.0.1", 12345), None)
    out = conn.out.getvalue()
    head, _, body = out.partition(b"\r\n\r\n")
    lines = head.decode("iso-8859-1").split("\r\n")
    status = int(lines[0].split()[1])
    headers = {k.lower(): v for k, v in (l.split(": ", 1) for l in lines[1:] if ": " in l)}
    return status, headers, body, err.getvalue()


def get(path):
    return handle(f"GET {path} HTTP/1.0\r\nHost: x\r\n\r\n".encode("iso-8859-1"))


def post(body, cli=None, path="/event"):
    data = body if isinstance(body, bytes) else body.encode("utf-8")
    raw = (f"POST {path} HTTP/1.0\r\nHost: x\r\nContent-Type: application/json\r\n"
           f"Content-Length: {len(data)}\r\n\r\n").encode("ascii") + data
    return handle(raw, cli)


class HandlerTests(unittest.TestCase):
    def test_view_and_nothing_else(self):
        status, headers, body, _ = get("/view")
        self.assertEqual(status, 200)
        self.assertEqual(json.loads(body), {"seq": 3, "view": VIEW0})
        self.assertEqual(headers.get("cache-control"), "no-store")
        for p in ("/", "/index.html", "/app.js", "/../bridge/bridge.py"):   # no static files are served
            status, headers, body, _ = get(p)
            self.assertEqual(status, 404, p)
            self.assertEqual(json.loads(body), {"error": "not-found"})
            self.assertEqual(headers.get("cache-control"), "no-store")

    def test_nul_in_path_is_400_not_a_traceback(self):
        for p in ("/%00", "/index.html%00", "/app.js?x=%00", "/%2500%00", "/view%00"):
            status, headers, _, err = get(p)
            self.assertEqual(status, 400, p)
            self.assertEqual(headers.get("cache-control"), "no-store")
            self.assertNotIn("Traceback", err)
        self.assertEqual(get("/view")[0], 200)

    def test_absolute_form_target_with_unbalanced_bracket_is_400(self):
        # urllib.parse.urlsplit raises ValueError("Invalid IPv6 URL") on these; the bridge used to let it escape
        # the handler (traceback, connection closed without a response). "//[/view" is deliberately absent:
        # parse_request collapses leading slashes, so it is the ordinary unknown path "/[/view" (404).
        for raw in (b"GET http://[/view HTTP/1.0\r\nHost: x\r\n\r\n",
                    b"HEAD http://[/view HTTP/1.0\r\nHost: x\r\n\r\n",
                    b"GET http://[::1/app.js HTTP/1.0\r\nHost: x\r\n\r\n",
                    b"POST http://[/event HTTP/1.0\r\nHost: x\r\nContent-Type: application/json\r\n"
                    b"Content-Length: 2\r\n\r\n{}"):
            cli = StubCli()
            status, headers, body, err = handle(raw, cli)
            self.assertEqual(status, 400, raw)
            self.assertEqual(headers.get("cache-control"), "no-store", raw)
            self.assertNotIn("Traceback", err, raw)
            self.assertEqual(cli.sent, [], f"{raw!r} must not reach the CLI")
            if raw.startswith(b"HEAD"):
                self.assertEqual(body, b"", "a HEAD response carries no body")
            if raw.startswith(b"POST"):
                self.assertEqual(json.loads(body), {"error": "bad-request"})
                self.assertIn("bad-request", err)
        self.assertEqual(get("/view")[0], 200)
        self.assertEqual(get("/[/view")[0], 404)

    def test_post_prefilter(self):
        for bad in ('{"seq":"1","path":[1,0],"event":{"k":"click"}}',
                    '{"seq":true,"path":[1,0],"event":{"k":"click"}}',
                    '{"seq":1.0,"path":[1,0],"event":{"k":"click"}}',
                    '{"seq":1,"path":[1.0],"event":{"k":"click"}}',
                    '{"seq":1,"path":[true],"event":{"k":"click"}}',
                    '{"seq":1,"path":"1","event":{"k":"click"}}',
                    '{"seq":1,"path":[1],"event":"click"}',
                    '{"seq":1,"path":[1]}',
                    '[1]', 'not json', ''):
            cli = StubCli()
            status, _, body, err = post(bad, cli)
            self.assertEqual(status, 400, bad)
            self.assertEqual(json.loads(body), {"error": "bad-request"}, bad)
            self.assertEqual(cli.sent, [], f"{bad!r} must not reach the CLI")
            self.assertIn("bad-request", err)

    def test_post_forwards_exactly_seq_path_event(self):
        cli = StubCli()
        status, _, body, _ = post('{"seq":3,"path":[1,0],"event":{"k":"click","x":1},"reset":true,"extra":2}', cli)
        self.assertEqual(status, 400)
        self.assertEqual(json.loads(body)["error"], "bad-json")
        self.assertEqual(cli.sent, [{"seq": 3, "path": [1, 0], "event": {"k": "click", "x": 1}}])

    def test_post_elsewhere_is_404(self):
        status, _, body, _ = post("{}", path="/nope")
        self.assertEqual(status, 404)
        self.assertEqual(json.loads(body), {"error": "not-found"})

    def test_log_escapes_event_kind_and_truncates_path(self):
        _, _, _, err = post(json.dumps({"seq": 3, "path": [0] * 5000, "event": {"k": "click\nINJECTED\r\n" + "A" * 500}}))
        lines = err.splitlines()
        self.assertEqual(len(lines), 1, err)
        self.assertFalse(any(l.startswith("INJECTED") for l in lines))
        self.assertIn('"click\\nINJECTED', lines[0])
        self.assertLess(len(lines[0]), 400)
        _, _, _, err = post(json.dumps({"seq": 3, "path": [1, 0], "event": {"k": 7}}))
        self.assertIn(" 7 -> 400 ", err)
        _, _, _, err = post(json.dumps({"seq": 3, "path": [1, 0], "event": {}}))
        self.assertIn(" null -> 400 ", err)

    def test_log_truncates_huge_seq(self):
        # A 4000-digit seq is a JSON integer (under Python's 4300-digit int-str limit), so it passes the pre-filter
        # and reaches the CLI (which answers stale); the log line must stay bounded all the same.
        huge = int("1" * 4000)
        cli = StubCli()
        _, _, body, err = post(json.dumps({"seq": huge, "path": [1, 0], "event": {"k": "click"}}), cli)
        self.assertEqual(json.loads(body)["error"], "bad-json")  # the stub's reply, i.e. the request got through
        self.assertEqual(cli.sent, [{"seq": huge, "path": [1, 0], "event": {"k": "click"}}], "seq is forwarded whole")
        lines = err.splitlines()
        self.assertEqual(len(lines), 1, err[:300])
        self.assertLess(len(lines[0]), 120, lines[0][:200])
        self.assertTrue(lines[0].startswith("1" * 17 + "... [1,0] "), lines[0][:60])
        # boundary: 20 digits are logged whole, 21 are truncated to 20 characters including the marker
        _, _, _, err = post(json.dumps({"seq": 10 ** 19, "path": [1, 0], "event": {"k": "click"}}))
        self.assertTrue(err.startswith(str(10 ** 19) + " [1,0] "), err[:60])
        _, _, _, err = post(json.dumps({"seq": 10 ** 20, "path": [1, 0], "event": {"k": "click"}}))
        self.assertTrue(err.startswith("1" + "0" * 16 + "... [1,0] "), err[:60])
        self.assertEqual(len(err.split(" ")[0]), 20)


if __name__ == "__main__":
    unittest.main(verbosity=2)
