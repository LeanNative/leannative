#!/bin/bash
# End-to-end check of framework/bridge/bridge.py over HTTP (see PROTOCOL.md, "HTTP bridge").
# The probes assume the Todo layout (a field at [1,0]); the Todo example and scripts/fake_cli.py have it.
# CLI is an absolute path or a command line relative to framework/ (this script runs from there):
#   PORT=8791 CLI="$PWD/.lake/build/bin/todo-cli" ../../framework/scripts/bridge_test.sh     (from examples/todo)
#   SKIP_RESTART=1 CLI="/opt/homebrew/bin/python3 scripts/fake_cli.py" scripts/bridge_test.sh  (from framework/)
# The bridge's stderr (its own log plus the CLI's diagnostics) is captured to a file and shown on failure.
set -euo pipefail
cd "$(dirname "$0")/.."

PORT="${PORT:-8791}"
CLI="${CLI:?set CLI to the app binary (absolute path) or a command line}"
SKIP_RESTART="${SKIP_RESTART:-0}"
PY=/opt/homebrew/bin/python3
BASE="http://127.0.0.1:$PORT"
LSOF_FALLBACK=/usr/sbin/lsof  # macOS keeps lsof in /usr/sbin, which a reduced PATH (e.g. under make or CI) may lack

# The port-ownership checks below need lsof; resolve it once so a missing lsof is reported as such instead of
# surfacing later as "port N is busy: listening pid(s) ''" against a healthy bridge.
if LSOF="$(command -v lsof 2>/dev/null)" && [ -n "$LSOF" ]; then
  :
elif [ -x "$LSOF_FALLBACK" ]; then
  LSOF="$LSOF_FALLBACK"
else
  echo "FAIL: lsof not found; needed for the port-ownership check (PATH=$PATH, fallback $LSOF_FALLBACK)" >&2
  exit 1
fi

BRIDGE_PID=""
LOG="$(mktemp)"
BODY="$(mktemp)"
fail() {
  echo "FAIL: $*" >&2
  if [ -s "$LOG" ]; then
    echo "--- bridge stderr (tail) ---" >&2
    tail -n 40 "$LOG" >&2
  fi
  exit 1
}
ok() { echo "  ok: $*"; }
json_get() { "$PY" -c 'import json,sys; d=json.load(sys.stdin); print(d.get(sys.argv[1]))' "$1"; }
code_of() { curl -s -o /dev/null -w '%{http_code}' "$@"; }
headers_of() { curl -s -D - -o /dev/null "$@"; }
post() { curl -s -o "$BODY" -w '%{http_code}' -X POST -H 'Content-Type: application/json' --data-binary "$1" "$BASE/event"; }
# Pids listening on $PORT, space-separated; empty when nothing listens (lsof -t exits 1 then, hence || true).
listeners() { "$LSOF" -t -iTCP:"$PORT" -sTCP:LISTEN 2>/dev/null | sort -u | tr '\n' ' ' | sed 's/ $//' || true; }
view_seq() { curl -s "$BASE/view" | json_get seq; }

cleanup() {
  if [ -n "$BRIDGE_PID" ]; then
    kill "$BRIDGE_PID" 2>/dev/null || true
    wait "$BRIDGE_PID" 2>/dev/null || true
  fi
  rm -f "$BODY" "$LOG"
}
trap cleanup EXIT

# Never test a foreign server: the port must be free before the bridge starts, and the listener must be the
# bridge afterwards (a bridge that lost the bind race would have died, and the assertions would run elsewhere).
busy="$(listeners)"
[ -z "$busy" ] || fail "port $PORT is busy (listening pid(s): $busy); set PORT to a free port"

"$PY" bridge/bridge.py --port "$PORT" --cli "$CLI" 2>"$LOG" &
BRIDGE_PID=$!

up=0
for _ in $(seq 1 50); do
  kill -0 "$BRIDGE_PID" 2>/dev/null || fail "bridge exited during startup"
  if curl -fs "$BASE/view" >/dev/null 2>&1; then up=1; break; fi
  sleep 0.1
done
[ "$up" = 1 ] || fail "bridge did not answer /view on port $PORT within 5s"
kill -0 "$BRIDGE_PID" 2>/dev/null || fail "bridge exited right after startup"
listener="$(listeners)"
# An empty set here is not a foreign server: /view just answered, so lsof itself failed to see the listener.
[ -n "$listener" ] || fail "could not determine who listens on port $PORT ($LSOF reported no listener although bridge pid $BRIDGE_PID answers /view)"
[ "$listener" = "$BRIDGE_PID" ] || fail "port $PORT is busy: listening pid(s) '$listener', bridge pid $BRIDGE_PID"
echo "bridge up on $BASE (pid $BRIDGE_PID, cli: $CLI, lsof: $LSOF)"

# --- the bridge serves /view and /event only (no static files) ---
for p in '/' '/index.html' '/app.js'; do
  c="$(code_of "$BASE$p")"
  [ "$c" = "404" ] || fail "GET $p -> $c (expected 404: the bridge serves no static files)"
done
ok "GET / and other paths -> 404 (no static files)"
h="$(headers_of "$BASE/view")"
grep -qi '^cache-control: no-store' <<<"$h" || fail "GET /view lacks Cache-Control: no-store"
grep -qi '^content-type: application/json' <<<"$h" || fail "GET /view content-type: $(grep -i content-type <<<"$h")"
ok "GET /view application/json, no-store"
c="$(code_of --path-as-is "$BASE/../bridge/bridge.py")"
[ "$c" != "200" ] || fail "GET /../bridge/bridge.py returned 200 (path traversal)"
ok "GET /../bridge/bridge.py -> $c (not 200)"
# A NUL in the request target is refused with 400 (it used to raise inside the stdlib and drop the connection).
for p in '/%00' '/view%00' '/view?x=%00'; do
  c="$(code_of --path-as-is "$BASE$p")"
  [ "$c" = "400" ] || fail "GET $p -> '$c' (expected 400; 000 means the connection was closed without a response)"
  c="$(code_of --path-as-is -I "$BASE$p")"
  [ "$c" = "400" ] || fail "HEAD $p -> '$c' (expected 400)"
done
[ "$(view_seq)" = "0" ] || fail "/view not served after the NUL probes"
ok "GET/HEAD with an encoded NUL -> 400, /view still served"
# An absolute-form target with an unbalanced bracket made urllib.parse.urlsplit raise ValueError inside do_GET /
# do_POST: traceback on the bridge's stderr and the connection closed without a response. curl would rewrite
# the target, so the request line is sent verbatim over a socket; the status line must be an HTTP/1.x 400.
raw_status() {  # $1: request line; prints the status line the bridge answers ("" if it closed without one)
  "$PY" -I -c '
import socket, sys
port, line = int(sys.argv[1]), sys.argv[2]
try:
    with socket.create_connection(("127.0.0.1", port), timeout=5) as s:
        s.sendall((line + "\r\nHost: x\r\nContent-Length: 0\r\n\r\n").encode("ascii"))
        data = b""
        while True:  # HTTP/1.0: the server closes after one response
            chunk = s.recv(4096)
            if not chunk:
                break
            data += chunk
except OSError as e:
    data = ("ERR " + str(e)).encode()
sys.stdout.write(data.split(b"\r\n", 1)[0].decode("iso-8859-1"))
' "$PORT" "$1"
}
for line in 'GET http://[/view HTTP/1.0' 'HEAD http://[/view HTTP/1.0' 'POST http://[/event HTTP/1.0'; do
  st="$(raw_status "$line")"
  case "$st" in
    HTTP/1.[01]\ 400*) ;;
    *) fail "'$line' -> status line '$st' (expected HTTP/1.x 400; empty means the connection was closed without a response)" ;;
  esac
done
[ "$(view_seq)" = "0" ] || fail "/view not served after the absolute-form probes"
! grep -q 'Traceback (most recent call last)' "$LOG" || fail "bridge stderr shows a traceback after the absolute-form probes"
ok "absolute-form target with an unbalanced bracket -> 400 for GET/HEAD/POST, no traceback, /view still served"

# --- protocol over HTTP ---
seq="$(view_seq)"
[ "$seq" = "0" ] || fail "initial seq is $seq, expected 0"
ok "initial seq 0"

c="$(post '{"seq":0,"path":[1,0],"event":{"k":"input","value":"Milk"}}')"
[ "$c" = "200" ] || fail "POST input -> $c (expected 200): $(cat "$BODY")"
seq="$(json_get seq <"$BODY")"
[ "$seq" = "1" ] || fail "POST input returned seq $seq, expected 1"
[ "$(view_seq)" = "1" ] || fail "/view seq did not advance to 1"
ok "POST input -> 200, seq 1"

c="$(post '{"seq":0,"path":[1,0],"event":{"k":"input","value":"Milk"}}')"
[ "$c" = "409" ] || fail "POST with stale seq 0 -> $c (expected 409): $(cat "$BODY")"
[ "$(json_get error <"$BODY")" = "stale" ] || fail "409 body is not a stale error: $(cat "$BODY")"
[ "$(json_get view <"$BODY")" != "None" ] || fail "409 body lacks the current view"
ok "POST seq 0 again -> 409 stale with view"

c="$(post '{"seq":1,"path":[99],"event":{"k":"click"}}')"
[ "$c" = "400" ] || fail "POST [99] click -> $c (expected 400): $(cat "$BODY")"
[ "$(json_get error <"$BODY")" = "bad-path" ] || fail "400 body is not bad-path: $(cat "$BODY")"
ok "POST [99] click -> 400 bad-path"

c="$(post 'not json')"
[ "$c" = "400" ] || fail "POST 'not json' -> $c (expected 400): $(cat "$BODY")"
[ "$(json_get error <"$BODY")" = "bad-request" ] || fail "400 body is not bad-request: $(cat "$BODY")"
ok "POST 'not json' -> 400 bad-request"

# The bridge's own pre-filter (PROTOCOL.md): seq and path elements JSON integers, path a list, event an object.
for bad in '{"seq":"1","path":[1,0],"event":{"k":"submit"}}' \
           '{"seq":true,"path":[1,0],"event":{"k":"submit"}}' \
           '{"seq":1.0,"path":[1,0],"event":{"k":"submit"}}' \
           '{"seq":1,"path":[1.0,0],"event":{"k":"submit"}}' \
           '{"seq":1,"path":"1,0","event":{"k":"submit"}}' \
           '{"seq":1,"path":[1,0],"event":"submit"}' \
           '[1,[1,0],{"k":"submit"}]'; do
  c="$(post "$bad")"
  [ "$c" = "400" ] || fail "POST $bad -> $c (expected 400)"
  [ "$(json_get error <"$BODY")" = "bad-request" ] || fail "POST $bad: body is not bad-request: $(cat "$BODY")"
  [ "$(json_get seq <"$BODY")" = "None" ] || fail "POST $bad: bridge's own 400 must carry no seq: $(cat "$BODY")"
done
ok "non-int seq / non-int path element / non-list path / non-object event -> 400 bad-request without seq"

c="$(curl -s -o "$BODY" -w '%{http_code}' -X POST -d '{}' "$BASE/nope")"
[ "$c" = "404" ] || fail "POST /nope -> $c (expected 404)"
ok "POST /nope -> 404"

# Client-controlled strings must not reach the log raw: an event kind with a newline is logged JSON-escaped on
# one line, and a huge path is truncated.
c="$(post '{"seq":1,"path":[1,0],"event":{"k":"click\nINJECTED"}}')"
[ "$c" = "400" ] || fail "POST with a newline in the event kind -> $c (expected 400): $(cat "$BODY")"
longpath="$("$PY" -c 'print("[" + ",".join(["0"] * 5000) + "]")')"
c="$(post "{\"seq\":1,\"path\":$longpath,\"event\":{\"k\":\"click\"}}")"
[ "$c" = "400" ] || fail "POST with a 5000-element path -> $c (expected 400 bad-path): $(cat "$BODY")"
[ "$(json_get error <"$BODY")" = "bad-path" ] || fail "5000-element path: $(cat "$BODY")"
# A 4000-digit seq is a JSON integer (the bridge's pre-filter lets it through, the CLI answers stale); it used to
# be logged whole, a 4027-character line. The log shows str(seq) cut to 20 characters with a "..." marker.
hugeseq="$("$PY" -c 'print("1" * 4000)')"
c="$(post "{\"seq\":$hugeseq,\"path\":[1,0],\"event\":{\"k\":\"click\"}}")"
[ "$c" = "409" ] || fail "POST with a 4000-digit seq -> $c (expected 409 stale): $(head -c 300 "$BODY")"
[ "$(json_get error <"$BODY")" = "stale" ] || fail "4000-digit seq: $(head -c 300 "$BODY")"
sleep 0.3  # the log line is written after the response
! grep -q '^INJECTED' "$LOG" || fail "bridge log contains a line injected through the event kind"
grep -q 'click\\nINJECTED' "$LOG" || fail "bridge log does not show the escaped event kind"
grep -q '^11111111111111111\.\.\. \[1,0\] "click" -> 409 ' "$LOG" || fail "bridge log lacks the truncated 4000-digit seq line"
# Only request-log lines ("<seq> <path> <kind> -> <status> <ms>ms"): the startup line carries the web directory path.
longest="$(awk '/ -> [0-9]+ [0-9.]+ms$/ { if (length($0) > m) m = length($0) } END { print m + 0 }' "$LOG")"
[ "$longest" -ge 200 ] || fail "no request-log line of the 5000-element path found (longest $longest chars)"
[ "$longest" -le 400 ] || fail "bridge log has a $longest-character request line (path not truncated)"
ok "event kind logged JSON-escaped, long path and 4000-digit seq truncated (longest request-log line $longest chars)"

[ "$(view_seq)" = "1" ] || fail "rejected requests changed /view seq"
ok "rejections left seq at 1"

# --- CLI death -> 502 and transparent restart ---
if [ "$SKIP_RESTART" = "1" ]; then
  echo "  (SKIP_RESTART=1: restart section skipped)"
else
  cli_name="$(basename "$CLI")"
  cli_pid="$(pgrep -P "$BRIDGE_PID" -x "$cli_name" || true)"
  [ -n "$cli_pid" ] || fail "cannot find the bridge's own '$cli_name' child to kill (set SKIP_RESTART=1 for non-binary CLIs)"
  kill "$cli_pid"
  sleep 0.3
  c="$(post '{"seq":1,"path":[1,0],"event":{"k":"input","value":"after kill"}}')"
  [ "$c" = "502" ] || fail "POST after CLI death -> $c (expected 502): $(cat "$BODY")"
  [ "$(json_get error <"$BODY")" = "cli-restarted" ] || fail "502 body: $(cat "$BODY")"
  [ "$(json_get seq <"$BODY")" = "0" ] || fail "502 body seq is $(json_get seq <"$BODY"), expected 0"
  ok "killed cli pid $cli_pid -> next POST 502 cli-restarted"
  [ "$(view_seq)" = "0" ] || fail "/view seq after restart is not 0"
  ok "/view seq 0 again"
  c="$(post '{"seq":0,"path":[1,0],"event":{"k":"input","value":"alive"}}')"
  [ "$c" = "200" ] || fail "POST after restart -> $c (expected 200): $(cat "$BODY")"
  [ "$(json_get seq <"$BODY")" = "1" ] || fail "POST after restart returned seq $(json_get seq <"$BODY")"
  ok "POST after restart -> 200, seq 1"
  new_pid="$(pgrep -P "$BRIDGE_PID" -x "$cli_name" || true)"
  [ -n "$new_pid" ] && [ "$new_pid" != "$cli_pid" ] || fail "bridge did not spawn a fresh CLI"
  ok "fresh cli pid $new_pid"
fi

! grep -q 'Traceback (most recent call last)' "$LOG" || fail "bridge stderr shows a traceback"
echo "bridge OK"
