#!/opt/homebrew/bin/python3
"""HTTP bridge between the generic SwiftUI renderer (ios/) and the ElmLean CLI. See PROTOCOL.md, "HTTP bridge".

    bridge.py [--cli CMD] [--port 8787] [--bind 127.0.0.1]

GET /view            -> {"seq","view"} snapshot (no CLI round trip)
POST /event          -> forwards exactly {"seq","path","event"}; 200 view / 409 stale / 400 rejected /
                        502 cli-restarted (fresh model) / 503 cli-unavailable (could not restart; /view keeps the last view)
anything else        -> 404 {"error":"not-found"}. Every response carries Cache-Control: no-store. Stdlib only.
"""
import argparse
import http.server
import json
import os
import queue
import shlex
import subprocess
import sys
import threading
import time
import urllib.parse

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
REPLY_TIMEOUT = 5.0  # seconds to wait for one reply line (and for the initial view); a module global so tests can lower it


def log(msg):
    sys.stderr.write(msg + "\n")
    sys.stderr.flush()


def _seq_of(reply):
    """The reply's `seq` if it is a JSON integer (bool excluded), else None."""
    s = reply.get("seq")
    return s if type(s) is int else None


def _is_view(reply):
    return "view" in reply and "error" not in reply and _seq_of(reply) is not None


class CliDead(Exception):
    """The CLI produced no usable reply line (timeout, EOF or a non-JSON line); the message says which."""


class Cli:
    """One CLI subprocess; `send` is serialised by a lock and restarts the CLI when it dies, hangs or desynchronises.

    Invariant: `self.proc`/`self.q` are either both None (no usable CLI) or belong to a CLI whose initial view was
    read and validated; `self.current` is only ever replaced by a validated reply, so GET /view can keep serving it
    while the CLI is unavailable."""

    def __init__(self, argv):
        self.argv = argv
        self.lock = threading.Lock()
        self.proc = None
        self.q = None
        self.current = None  # last validated {"seq","view"} message, replaced atomically
        self._start()

    def _start(self):
        """Spawn the CLI and read its initial view. On any failure the new process is killed, self.proc/self.q are
        left untouched (None) and a RuntimeError with a short reason (no argv) is raised."""
        try:
            proc = subprocess.Popen(self.argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=None,
                                    text=True, encoding="utf-8", errors="replace", bufsize=1)
        except OSError as e:
            log(f"bridge: cannot start cli {self.argv!r}: {e}")
            raise RuntimeError(f"cannot start CLI: {e.strerror or e}") from e
        q = queue.Queue()
        threading.Thread(target=self._pump, args=(proc.stdout, q), daemon=True).start()
        try:
            first = self._read(q)
            if not _is_view(first) or first["seq"] != 0:
                raise CliDead("first line is not a seq-0 view: %r" % (first,))
        except CliDead as e:
            why = str(e)
            if why.startswith("EOF"):  # stdout closed: give the process a moment to be reapable, then name its exit code
                try:
                    why = f"CLI exited with code {proc.wait(timeout=1)} before printing a view"
                except subprocess.TimeoutExpired:
                    pass
            self._kill_proc(proc)
            log(f"bridge: cli {self.argv!r} did not start: {why[:200]}")
            raise RuntimeError(why[:200]) from None
        self.proc, self.q, self.current = proc, q, first
        log(f"bridge: cli started pid={proc.pid} seq={first['seq']}")

    @staticmethod
    def _pump(stream, q):
        try:
            for line in stream:
                q.put(line)
        finally:
            q.put(None)
            stream.close()  # EOF: nobody else reads this pipe, so close it here instead of leaking it to the GC

    @staticmethod
    def _read(q):
        """One parsed reply object from `q`; raises CliDead on timeout, EOF or a line that is not a JSON object."""
        try:
            line = q.get(timeout=REPLY_TIMEOUT)
        except queue.Empty:
            raise CliDead("no reply within %.0fs" % REPLY_TIMEOUT) from None
        if line is None:
            raise CliDead("EOF on CLI stdout")
        try:
            reply = json.loads(line)
        except ValueError:
            raise CliDead("non-JSON reply line %r" % line[:80]) from None
        if not isinstance(reply, dict):
            raise CliDead("reply is not a JSON object: %r" % line[:80])
        return reply

    def _restart(self, why):
        """Kill the CLI (if any) and start a fresh one: 502 cli-restarted on success, 503 cli-unavailable otherwise."""
        log(f"bridge: restarting cli ({why})")
        self.kill()
        try:
            self._start()
        except (RuntimeError, OSError) as e:
            log(f"bridge: cli unavailable ({e})")
            return 503, {"error": "cli-unavailable", "detail": str(e)[:200]}
        return 502, {"error": "cli-restarted", "seq": self.current["seq"]}

    @staticmethod
    def _kill_proc(p):
        try:
            p.stdin.close()
        except OSError:
            pass
        if p.poll() is None:
            p.kill()
        try:
            p.wait(timeout=2)
        except subprocess.TimeoutExpired:
            pass

    def kill(self):
        p, self.proc, self.q = self.proc, None, None
        if p is not None:
            self._kill_proc(p)

    def send(self, req):
        """(http status, json body) for one client->CLI object."""
        with self.lock:
            if self.proc is None:
                return self._restart("cli not running")
            if self.proc.poll() is not None:
                return self._restart(f"exited with {self.proc.returncode}")
            try:
                self.proc.stdin.write(json.dumps(req, separators=(",", ":")) + "\n")
                self.proc.stdin.flush()
            except (BrokenPipeError, OSError) as e:
                return self._restart(f"write failed: {e}")
            try:
                reply = self._read(self.q)
            except CliDead as e:
                return self._restart(str(e))
            # PROTOCOL.md: a view reply must carry seq = current + 1, an error reply seq = current; anything else
            # (a late initial view, a skipped or repeated reply) means the CLI and the bridge disagree on the state.
            cur = self.current["seq"]
            if _is_view(reply):
                if reply["seq"] != cur + 1:
                    return self._restart(f"desync: view with seq {reply['seq']} after seq {cur}")
                self.current = reply
                return 200, reply
            err = reply.get("error")
            if isinstance(err, str) and _seq_of(reply) == cur:
                return (409 if err == "stale" else 400), reply
            return self._restart(f"desync: unintelligible reply {reply!r}"[:200])


class Handler(http.server.BaseHTTPRequestHandler):
    timeout = 10
    cli = None  # set in main

    def end_headers(self):
        self.send_header("Cache-Control", "no-store")
        super().end_headers()

    def handle(self):
        try:
            super().handle()
        except (BrokenPipeError, ConnectionResetError):
            pass

    def log_message(self, fmt, *args):  # access logs are noise; events are logged in do_POST
        pass

    def send_json(self, status, body):
        data = json.dumps(body, separators=(",", ":")).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _target_path(self):
        """The path component of the request target, or None once a 400 has been answered. The target is parsed
        here, in one place, because an absolute-form target with an unbalanced bracket ("GET http://[/view
        HTTP/1.0") makes urlsplit raise ValueError, which used to close the connection without a response and
        print a traceback. A NUL in the target is refused the same way. A POST gets the JSON 400 its clients
        expect; GET/HEAD get a plain 400."""
        try:
            if "\x00" in urllib.parse.unquote(self.path):
                raise ValueError("NUL in request target")
            return urllib.parse.urlsplit(self.path).path
        except ValueError:
            if self.command == "POST":
                self.send_json(400, {"error": "bad-request"})
            else:
                self.send_error(400, "Bad request path")
            return None

    def do_GET(self):
        target = self._target_path()
        if target is None:
            return
        if target == "/view":
            self.send_json(200, self.cli.current)
        else:
            self.send_json(404, {"error": "not-found"})

    def do_HEAD(self):
        target = self._target_path()
        if target is None:
            return
        self.send_response(200 if target == "/view" else 404)
        self.send_header("Content-Type", "application/json")
        self.end_headers()

    def do_POST(self):
        target = self._target_path()
        if target is None:
            log(f"bridge: bad-request {self.client_address[0]} -> 400")
            return
        if target != "/event":
            self.send_json(404, {"error": "not-found"})
            return
        t0 = time.monotonic()
        try:
            n = int(self.headers.get("Content-Length") or 0)
            body = json.loads(self.rfile.read(n).decode("utf-8")) if n else None
        except (ValueError, UnicodeDecodeError):
            body = None
        # PROTOCOL.md: seq and every path element must be JSON integers (bool is not one), path a list, event an
        # object; anything else is the bridge's own 400 bad-request and never reaches the CLI.
        ok = (isinstance(body, dict) and type(body.get("seq")) is int and isinstance(body.get("path"), list)
              and all(type(i) is int for i in body["path"]) and isinstance(body.get("event"), dict))
        if not ok:
            self.send_json(400, {"error": "bad-request"})
            log(f"bridge: bad-request {self.client_address[0]} -> 400")
            return
        req = {"seq": body["seq"], "path": body["path"], "event": body["event"]}  # never forward `reset` or extras
        status, reply = self.cli.send(req)
        self.send_json(status, reply)
        ms = (time.monotonic() - t0) * 1000
        # Client-controlled values are logged JSON-encoded (no raw newlines or control characters) and truncated,
        # so the line is bounded whatever the client sends. seq is an int here, and one of at most 4300 digits:
        # json.loads already rejected anything longer (int-str limit), so str() cannot raise. Only the log is
        # truncated; the request forwarded to the CLI carried the full value.
        seq = str(req["seq"])
        if len(seq) > 20:
            seq = seq[:17] + "..."
        kind = json.dumps(req["event"].get("k"))[:80]
        path = json.dumps(req["path"], separators=(",", ":"))[:200]
        log(f"{seq} {path} {kind} -> {status} {ms:.1f}ms")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--cli", required=True,
                    help="the app's CLI: a path to its binary (may contain spaces) or a command line, "
                         "shlex-split (so a quoted 'python3 scripts/fake_cli.py' works)")
    ap.add_argument("--port", type=int, default=8787)
    ap.add_argument("--bind", default="127.0.0.1")
    args = ap.parse_args()

    # A bare path to an existing binary is used verbatim (the workspace path contains spaces);
    # anything else is a command line, shlex-split.
    try:
        cli = Cli([args.cli] if os.path.isfile(args.cli) else shlex.split(args.cli))
    except (RuntimeError, OSError) as e:
        log(f"bridge: cannot start: {e}")
        return 1
    Handler.cli = cli
    try:
        server = http.server.ThreadingHTTPServer((args.bind, args.port), Handler)
    except OSError as e:
        cli.kill()
        log(f"bridge: cannot listen on {args.bind}:{args.port}: {e}")
        return 1
    log(f"bridge: serving /view and /event on http://{args.bind}:{args.port}/")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
        cli.kill()
        log("bridge: stopped")
    return 0


if __name__ == "__main__":
    sys.exit(main())
