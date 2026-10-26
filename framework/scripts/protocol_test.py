#!/opt/homebrew/bin/python3
"""Drive an ElmLean app's CLI over stdin/stdout and check it against PROTOCOL.md.

    protocol_test.py [--shape list] "<cli command>"
        e.g.  protocol_test.py --shape list examples/todo/.lake/build/bin/todo-cli
              protocol_test.py --shape list "/opt/homebrew/bin/python3 framework/scripts/fake_cli.py"
              protocol_test.py path/to/any-app-cli

Without --shape the harness assumes nothing about the app: it records a short seeded walk over the
advertised controls, runs the converse cases that the view allows (each missing ingredient is reported as
a skip), a 300-step random walk, and the exhaustive replay over the recorded walk. `--shape list` adds the
checks for list-shaped apps (the todo and counter examples): a submitting field whose submit adds a row of
(toggle, spacer, destructive button), the scripted input/submit/toggle/delete run used for the replay, and
one toggle and one destructive button per row along the random walk.

Paths are discovered by walking the view tree, never hardcoded. `advertised(view)` mirrors the table in
PROTOCOL.md; the tests check the machine-checked guarantee (advertised iff dispatch succeeds) on the real glue.
Stdlib only. Exit 1 if any test fails.
"""
import json
import os
import queue
import random
import shlex
import subprocess
import sys
import threading
import copy

REPLY_TIMEOUT = 5.0
QUIET_WINDOW = 0.1  # after every reply, nothing else may appear on stdout within this window


class ProtocolError(AssertionError):
    pass


class Cli:
    def __init__(self, argv):
        self.proc = subprocess.Popen(argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=None,
                                     text=True, bufsize=1)
        self.q = queue.Queue()
        threading.Thread(target=self._pump, daemon=True).start()
        self.lines_sent = 0

    def _pump(self):
        for line in self.proc.stdout:
            self.q.put(line)
        self.q.put(None)

    def _get(self, timeout):
        line = self.q.get(timeout=timeout)
        if line is None:
            raise ProtocolError("CLI closed stdout (EOF)")
        try:
            return json.loads(line)
        except ValueError as e:
            raise ProtocolError(f"non-JSON stdout line {line!r}: {e}")

    def initial(self):
        return self._get(REPLY_TIMEOUT)

    def send_raw(self, raw):
        """Write one line, return exactly one parsed reply; fail if a second line follows."""
        self.proc.stdin.write(raw + "\n")
        self.proc.stdin.flush()
        self.lines_sent += 1
        reply = self._get(REPLY_TIMEOUT)
        try:
            extra = self.q.get(timeout=QUIET_WINDOW)
        except queue.Empty:
            return reply
        raise ProtocolError(f"more than one reply to {raw!r}: second line {extra!r}")

    def send(self, obj):
        return self.send_raw(json.dumps(obj))

    def close(self):
        self.proc.stdin.close()
        code = self.proc.wait(timeout=REPLY_TIMEOUT)
        leftover = []
        while True:
            try:
                l = self.q.get(timeout=0.2)
            except queue.Empty:
                break
            if l is None:
                break
            leftover.append(l)
        return code, leftover


# ---------- tree helpers (generic over the node grammar) ----------

def children(node):
    return node.get("c", []) if node.get("t") in ("col", "row") else []


def walk(node, path=()):
    yield list(path), node
    for i, c in enumerate(children(node)):
        yield from walk(c, path + (i,))


def at(node, path):
    for i in path:
        kids = children(node)
        if i >= len(kids):
            return None
        node = kids[i]
    return node


def advertised(view):
    """(path, event) pairs the renderer may fire, exactly as PROTOCOL.md's table says."""
    out = []
    for path, n in walk(view):
        t = n.get("t")
        if t == "button" and n.get("enabled") is True:
            out.append((path, {"k": "click"}))
        elif t == "field":
            out.append((path, {"k": "input", "value": n.get("value", "") + "x"}))
            if n.get("submits") is True:
                out.append((path, {"k": "submit"}))
        elif t == "toggle":
            out.append((path, {"k": "toggle", "value": not n.get("on")}))
    return out


def all_events_for(node):
    """Every structurally valid event kind (so a rejection can only be bad-path/no-handler, never bad-json)."""
    return [{"k": "click"}, {"k": "input", "value": "x"}, {"k": "submit"}, {"k": "toggle", "value": True}]


def toggles(view):
    return [p for p, n in walk(view) if n.get("t") == "toggle"]


def destructive_buttons(view):
    return [p for p, n in walk(view) if n.get("t") == "button" and n.get("role") == "destructive"]


def strings(view):
    for _, n in walk(view):
        for key in ("s", "label"):
            if isinstance(n.get(key), str):
                yield n[key]


def one_delete_per_row(view):
    """Every container holding a toggle holds exactly one toggle and exactly one destructive button."""
    rows = 0
    for _, n in walk(view):
        kids = children(n)
        nt = sum(1 for k in kids if k.get("t") == "toggle")
        if nt == 0:
            continue
        nd = sum(1 for k in kids if k.get("t") == "button" and k.get("role") == "destructive")
        if nt != 1 or nd != 1:
            return False, f"container with {nt} toggles and {nd} destructive buttons"
        rows += 1
    if rows != len(toggles(view)):
        return False, f"{len(toggles(view))} toggles but {rows} todo rows"
    return True, f"{rows} rows, one toggle + one destructive button each"


# ---------- checks ----------

def check(cond, msg):
    if not cond:
        raise ProtocolError(msg)


def expect_view(reply, seq_before, what):
    check("error" not in reply, f"{what}: expected a view, got {short(reply)}")
    check(reply.get("seq") == seq_before + 1, f"{what}: expected seq {seq_before + 1}, got {reply.get('seq')}")
    check(isinstance(reply.get("view"), dict), f"{what}: reply has no view object")
    return reply


def expect_error(reply, code, seq, what, want_view=False):
    check(reply.get("error") == code, f"{what}: expected error {code!r}, got {short(reply)}")
    check(reply.get("seq") == seq, f"{what}: seq should stay {seq}, got {reply.get('seq')}")
    if want_view:
        check(isinstance(reply.get("view"), dict), f"{what}: stale reply must carry the current view")
    else:
        check("view" not in reply, f"{what}: {code} reply must not carry a view")
    return reply


def short(reply):
    s = json.dumps(reply, sort_keys=True)
    return s if len(s) < 160 else s[:150] + "...}"


class Session:
    """Client-side mirror of seq + current view, updated from every reply."""

    def __init__(self, cli):
        self.cli = cli
        first = cli.initial()
        check(first.get("seq") == 0 and isinstance(first.get("view"), dict),
              f"first line must be {{seq:0,view}}, got {short(first)}")
        self.seq, self.view = 0, first["view"]
        self.initial_view = copy.deepcopy(first["view"])

    def fire(self, path, event, what="event"):
        """Send an advertised pair; expect seq+1 and a view."""
        r = self.cli.send({"seq": self.seq, "path": path, "event": event})
        expect_view(r, self.seq, what)
        self.seq, self.view = r["seq"], r["view"]
        return r

    def reject(self, path, event, code, what, seq=None):
        r = self.cli.send({"seq": self.seq if seq is None else seq, "path": path, "event": event})
        expect_error(r, code, self.seq, what, want_view=(code == "stale"))
        return r

    def reset(self):
        r = self.cli.send({"reset": True})
        expect_view(r, self.seq, "reset")
        self.seq, self.view = r["seq"], r["view"]
        return r


def test_scripted(s):
    """Returns the recorded requests and views v_0..v_k for the replay test."""
    views = [copy.deepcopy(s.view)]
    reqs = []

    def step(path, event, what):
        s.fire(path, event, what)
        reqs.append((path, event))
        views.append(copy.deepcopy(s.view))

    fields = [p for p, n in walk(s.view) if n.get("t") == "field"]
    check(fields, "no field in the initial view")
    fpath = fields[0]
    n_toggles = len(toggles(s.view))

    step(fpath, {"k": "input", "value": "Milk"}, "input Milk")
    f = at(s.view, fpath)
    check(f and f.get("t") == "field" and f.get("value") == "Milk",
          f"after input the field at {fpath} should hold 'Milk', node is {short(f or {})}")

    f_submits = at(views[0], fpath).get("submits") is True
    check(f_submits, f"the field at {fpath} must advertise submit for the scripted sequence")
    step(fpath, {"k": "submit"}, "submit")
    check(len(toggles(s.view)) == n_toggles + 1,
          f"submit should add exactly one toggle: {n_toggles} -> {len(toggles(s.view))}")
    check(any("Milk" in x for x in strings(s.view)), "no text/label containing 'Milk' after submit")

    tpath = toggles(s.view)[-1]
    before = at(s.view, tpath)["on"]
    step(tpath, {"k": "toggle", "value": not before}, "toggle last toggle")
    after = at(s.view, tpath)
    check(after and after.get("t") == "toggle" and after["on"] == (not before),
          f"toggle should flip on: {before} -> {after and after.get('on')}")

    # the destructive button that lives in a row with a toggle ("Delete"), else any enabled destructive one
    cands = [p for p in destructive_buttons(s.view) if at(s.view, p).get("enabled") is True]
    in_row = [p for p in cands if any(k.get("t") == "toggle" for k in children(at(s.view, p[:-1])))]
    check(cands, "no enabled destructive button to click")
    dpath = (in_row or cands)[-1]
    nt = len(toggles(s.view))
    step(dpath, {"k": "click"}, "click destructive")
    check(len(toggles(s.view)) == nt - 1, f"destructive click should remove a toggle: {nt} -> {len(toggles(s.view))}")
    return reqs, views


def test_converse(s, shape):
    v = s.view
    adv_set = {(tuple(p), e["k"]) for p, e in advertised(v)}
    click = {"k": "click"}
    unclickable = [p for p, n in walk(v) if (tuple(p), "click") not in adv_set]
    check(unclickable, "every node of the view advertises click (impossible: containers never do)")
    texts = [p for p, n in walk(v) if n.get("t") == "text"]
    if texts:
        s.reject(texts[0], click, "no-handler", "click on text")
    elif shape:
        check(False, "no text node to click")
    else:
        print("    (no text node in this view; skipped that case)")
    if v.get("t") in ("col", "row"):
        s.reject([], click, "no-handler", "click on root")
    disabled = [p for p, n in walk(v) if n.get("t") == "button" and n.get("enabled") is False]
    if disabled:
        s.reject(disabled[0], click, "no-handler", "click disabled button")
    elif shape:
        check(False, "no disabled button in the view")
    else:
        print("    (no disabled button in this view; skipped that case)")
    nonsub = [p for p, n in walk(v) if n.get("t") == "field" and n.get("submits") is not True]
    if nonsub:
        s.reject(nonsub[0], {"k": "submit"}, "no-handler", "submit on non-submitting field")
    else:
        print("    (no non-submitting field in this view; skipped that case)")
    s.reject([99], {"k": "click"}, "bad-path", "path [99]")
    leaf = next(p for p, n in walk(v) if not children(n))
    s.reject(leaf + [0], {"k": "click"}, "bad-path", f"leaf path {leaf}+[0]")
    adv = advertised(v)
    check(adv, "view advertises nothing")
    path, ev = adv[0]
    r = s.reject(path, ev, "stale", "seq+1", seq=s.seq + 1)
    check(r["view"] == v, "stale reply's view differs from the current view")
    if s.seq > 0:
        s.reject(path, ev, "stale", "seq-1", seq=s.seq - 1)
    # precedence: stale beats bad-path and no-handler
    s.reject([99], {"k": "click"}, "stale", "stale beats bad-path", seq=s.seq + 1)
    s.reject(unclickable[0], click, "stale", "stale beats no-handler", seq=s.seq + 1)
    for raw, what in (("not json", "line 'not json'"), ("", "empty line"), ("   ", "whitespace line"),
                      ('{"seq":%d,"path":[99],"event":{"k":"nope"}}' % (s.seq + 1), "bad-json beats stale/bad-path")):
        r = s.cli.send_raw(raw)
        expect_error(r, "bad-json", s.seq, what)
    spelled = number_spellings(s)
    fields = [p for p, n in walk(s.view) if n.get("t") == "field"]
    if fields:
        s.fire(fields[0], {"k": "input", "value": "still alive"}, "valid input after errors")
        check(at(s.view, fields[0])["value"] == "still alive", "loop survived but input was not applied")
    else:
        path, ev = advertised(s.view)[0]
        s.fire(path, ev, "valid event after errors")
    return spelled


def number_spellings(s):
    """PROTOCOL.md: seq and every path element are accepted by VALUE (a non-negative integer), whatever the
    spelling. The lines are RAW strings, never json.dumps, which would re-spell the numbers. An accepted
    spelling targets the field with an input, so success is harmless, and the session re-syncs seq/view from
    the reply; a rejected spelling must be bad-json with seq unchanged (it carries the current seq, so a CLI
    that wrongly accepted it would answer with a view instead)."""
    fields = [p for p, n in walk(s.view) if n.get("t") == "field"]
    if fields:
        fpath = fields[0]
        ev = '{"k":"input","value":"spelled"}'
    else:
        # no field: probe with the first advertised control; acceptance is then checked by seq + view alone
        fpath, ev_obj = advertised(s.view)[0]
        ev = json.dumps(ev_obj, separators=(",", ":"))
    plain = json.dumps(fpath, separators=(",", ":"))

    def line(seq_raw, path_raw):
        nonlocal ev
        if not fields:  # re-pick the probe in the current view: the previous one may no longer be advertised
            adv = [(p, e) for p, e in advertised(s.view) if p == fpath]
            check(adv, f"number spellings: no advertised control left at {fpath}")
            ev = json.dumps(adv[0][1], separators=(",", ":"))
        return '{"seq":%s,"path":%s,"event":%s}' % (seq_raw, path_raw, ev)

    def accepted(seq_raw, path_raw, what):
        n = s.seq
        r = s.cli.send_raw(line(seq_raw, path_raw))
        expect_view(r, n, what)
        s.seq, s.view = r["seq"], r["view"]
        if fields:
            f = at(s.view, fpath)
            check(f and f.get("t") == "field" and f.get("value") == "spelled", f"{what}: accepted but the input was not applied")

    def rejected(seq_raw, path_raw, what):
        expect_error(s.cli.send_raw(line(seq_raw, path_raw)), "bad-json", s.seq, what)

    accepted("%d.0" % s.seq, plain, 'seq spelled "%d.0"' % s.seq)
    accepted("%de0" % s.seq, plain, 'seq spelled "%de0"' % s.seq)
    accepted("%de-1" % (10 * s.seq), plain, 'seq spelled "%de-1"' % (10 * s.seq))
    dotted = "[" + ",".join("%d.0" % i for i in fpath) + "]"
    accepted("%d" % s.seq, dotted, "path elements spelled %s" % dotted)
    n_acc = 4
    rejected("%d.5" % s.seq, plain, 'seq "%d.5"' % s.seq)
    rejected("-1", plain, "seq -1")
    rejected('"%d"' % s.seq, plain, 'seq as the JSON string "%d"' % s.seq)
    rejected("true", plain, "seq true")
    rejected("null", plain, "seq null")
    rejected("%d" % s.seq, "[0.5]", "path [0.5]")
    rejected("%d" % s.seq, "[-1]", "path [-1]")
    n_rej = 7
    # an integer-valued spelling far beyond the current seq is a number, so it is stale, not bad-json
    r = s.cli.send_raw(line("1E400", plain))
    expect_error(r, "stale", s.seq, "seq 1E400 (a number, hence stale)", want_view=True)
    check(r["view"] == s.view, "stale reply's view differs from the current view")
    # hostile exponents must be decided at once (REPLY_TIMEOUT bounds them), with one reply and no crash: a
    # 3-million-digit integer is a number (stale); a huge negative exponent is a fraction (bad-json); a mantissa
    # with 10^5 trailing decimal zeros denotes the plain value (the cost of stripping them must not be quadratic)
    r = s.cli.send_raw(line("1E+3000000", plain))
    expect_error(r, "stale", s.seq, "seq 1E+3000000 (a number, hence stale)", want_view=True)
    check(r["view"] == s.view, "stale reply's view differs from the current view")
    rejected("1e-99999999", plain, "seq 1e-99999999 (a fraction)")
    zeros = "0" * 100000
    accepted("%d.%s" % (s.seq, zeros), plain, "seq spelled with 10^5 trailing decimal zeros")
    long_path = "[" + ",".join("%d.%s" % (i, zeros) for i in fpath) + "]"
    accepted("%d" % s.seq, long_path, "path elements spelled with 10^5 trailing decimal zeros")
    n_acc += 2
    n_rej += 1
    return f"number spellings: {n_acc} accepted -> view, {n_rej} rejected -> bad-json, 1E400 and 1E+3000000 -> stale"


def test_random_walk(s, shape, steps=300, seed=20261025):
    rng = random.Random(seed)
    adv_count = rej_count = 0
    for i in range(1, steps + 1):
        adv = advertised(s.view)
        check(adv, f"step {i}: view advertises nothing")
        if rng.random() < 0.3:
            # advertised-ness is a property of (path, event kind): a field accepts every input value and
            # a toggle every boolean, so the payload must not take part in the comparison
            adv_set = {(tuple(p), e["k"]) for p, e in adv}
            paths = [p for p, _ in walk(s.view)] + [[99], [0, 99]]
            pool = [(p, e) for p in paths for e in all_events_for(None)
                    if (tuple(p), e["k"]) not in adv_set]
            path, ev = rng.choice(pool)
            code = "bad-path" if at(s.view, path) is None else "no-handler"
            s.reject(path, ev, code, f"step {i}: non-advertised {path} {ev}")
            rej_count += 1
        else:
            path, ev = rng.choice(adv)
            s.fire(path, ev, f"step {i}: advertised {path} {ev}")
            adv_count += 1
        if shape and i % 50 == 0:
            ok, detail = one_delete_per_row(s.view)
            check(ok, f"step {i}: {detail}")
    return f"{adv_count} advertised -> view, {rej_count} non-advertised -> rejected, seq now {s.seq}"


def test_recorded_walk(s, steps=8, seed=7):
    """Generic stand-in for the scripted run: a short seeded walk over advertised controls, recorded."""
    rng = random.Random(seed)
    views = [copy.deepcopy(s.view)]
    reqs = []
    for i in range(steps):
        adv = advertised(s.view)
        check(adv, f"recorded walk step {i + 1}: view advertises nothing")
        path, ev = rng.choice(adv)
        s.fire(path, ev, f"recorded walk step {i + 1}: {path} {ev}")
        reqs.append((path, ev))
        views.append(copy.deepcopy(s.view))
    return reqs, views


def test_replay(s, reqs, views):
    replays = 0
    for k, vk in enumerate(views):
        for path, ev in advertised(vk):
            r = s.reset()
            check(r["view"] == views[0], "reset did not restore the initial view")
            for j, (p, e) in enumerate(reqs[:k]):
                s.fire(p, e, f"replay prefix {k}, step {j}")
                check(s.view == views[j + 1], f"replay prefix {k}: view after step {j} differs from recorded v_{j + 1}")
            check(s.view == vk, f"replay prefix {k}: view differs from recorded v_{k}")
            s.fire(path, ev, f"prefix {k} + advertised {path} {ev}")
            replays += 1
    return f"{replays} (prefix, advertised pair) replays, all deterministic and accepted"


def main():
    args = sys.argv[1:]
    shape = False
    if args[:2] == ["--shape", "list"]:
        shape, args = True, args[2:]
    if len(args) != 1:
        print(__doc__)
        return 2
    arg = args[0]
    argv = [arg] if os.path.isfile(arg) else shlex.split(arg)  # a bare binary path may contain spaces
    cli = Cli(argv)
    failures = 0
    results = []

    def run(name, fn, *a):
        nonlocal failures
        try:
            detail = fn(*a)
            results.append(detail)
            print(f"PASS {name}" + (f": {detail}" if isinstance(detail, str) else ""))
            return detail
        except (ProtocolError, queue.Empty, BrokenPipeError, OSError) as e:
            failures += 1
            msg = "no reply within %.1fs" % REPLY_TIMEOUT if isinstance(e, queue.Empty) else str(e)
            print(f"FAIL {name}: {msg}")
            return None

    s = None
    try:
        s = Session(cli)
    except (ProtocolError, queue.Empty) as e:
        print(f"FAIL startup: {e}")
        cli.proc.kill()
        return 1
    if shape:
        rec = run("1 scripted (input/submit/toggle/delete)", test_scripted, s)
    else:
        rec = run("1 recorded walk (8 seeded advertised steps)", test_recorded_walk, s)
    run("2 converse (no-handler/bad-path/stale/bad-json, loop survives)", test_converse, s, shape)
    run("3 random walk (300 seeded steps)", test_random_walk, s, shape)
    if rec:
        run("4 exhaustive replay (reset + prefix + advertised pair)", test_replay, s, *rec)
    else:
        failures += 1
        print("FAIL 4 exhaustive replay: skipped, the sequence to replay was not recorded")
    try:
        code, leftover = cli.close()
        check(code == 0, f"exit code {code} at EOF (expected 0)")
        check(not leftover, f"unexpected output after EOF: {leftover!r}")
        print(f"PASS 5 EOF: exit 0 after {cli.lines_sent} request lines, one reply each")
    except (ProtocolError, subprocess.TimeoutExpired) as e:
        failures += 1
        print(f"FAIL 5 EOF: {e}")
        cli.proc.kill()
    print("protocol OK" if failures == 0 else f"{failures} test(s) FAILED")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
