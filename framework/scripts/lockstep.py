#!/usr/bin/env python3
"""Lockstep differential driver: feed identical request lines to two ElmLean-protocol CLIs and compare replies.

    python3 -I lockstep.py "<cli A command>" "<cli B command>" [steps=300] [seed=1] ["<oracle command>"]

Replies are compared as PARSED JSON (escaping may differ between implementations):
  * view replies: seq and the whole view must be equal;
  * error replies: seq and error code must be equal (detail text may differ);
  * both CLIs must print exactly one line per request and exit 0 at EOF.
Steps are a seeded random walk over the advertised controls of A's current view (80%), non-advertised
pairs (15%: wrong seq, bad path, wrong event kind) and shell probes (5%: reset, blank line, non-JSON).

Apps with commands (PROTOCOL.md, "Commands"): when the samples source answers `{"samples":true}` with a
list (A, or the optional ORACLE: a third CLI, normally the Lean one, fed every line and held to the same
replies, so that two generated CLIs can be compared on host answers too), view replies
must also agree on `cmds`, and half of the steps (every step on a view with no advertised control) are
host answers instead: A alone is asked for the plausible
host answers in its current model, one is picked and sent to both as `{"host":…}`, or (one in ten) an
odd host line (malformed, or with repeated keys).
Prints "lockstep OK (<n> steps, <k> views, <e> rejections[, <h> host answers, <c> commands])" and exits 0,
or the first mismatch and exits 1.
"""
import json
import os
import queue
import random
import shlex
import subprocess
import sys
import threading

TIMEOUT = 10.0


class Cli:
    def __init__(self, cmd):
        # A bare path to an existing binary is used verbatim (the workspace path contains spaces);
        # anything else is a command line, shlex-split (so "python3 scripts/fake_cli.py" works).
        self.argv = [cmd] if os.path.isfile(cmd) else shlex.split(cmd)
        self.p = subprocess.Popen(self.argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True,
                                  encoding="utf-8", bufsize=1)
        self.q = queue.Queue()
        threading.Thread(target=self._pump, daemon=True).start()

    def _pump(self):
        for line in self.p.stdout:
            self.q.put(line.rstrip("\n"))
        self.q.put(None)

    def read(self):
        try:
            line = self.q.get(timeout=TIMEOUT)
        except queue.Empty:
            return ("TIMEOUT", None)
        if line is None:
            return ("EOF", None)
        try:
            return ("ok", json.loads(line))
        except ValueError:
            return ("NONJSON", line[:200])

    def send(self, line):
        self.p.stdin.write(line + "\n")
        self.p.stdin.flush()
        return self.read()

    def extra_lines(self):
        """Any stray line already printed without a request (non-blocking; EOF handling catches late ones)."""
        try:
            line = self.q.get_nowait()
        except queue.Empty:
            return None
        return line

    def close(self):
        try:
            self.p.stdin.close()
        except OSError:
            pass
        return self.p.wait(timeout=TIMEOUT)


def advertised(node, path=()):
    """All (path, event) pairs the wire tree advertises."""
    out = []
    t = node.get("t")
    if t == "button" and node.get("enabled"):
        out.append((list(path), {"k": "click"}))
    elif t == "field":
        out.append((list(path), {"k": "input"}))
        if node.get("submits"):
            out.append((list(path), {"k": "submit"}))
    elif t == "toggle":
        out.append((list(path), {"k": "toggle"}))
    for i, c in enumerate(node.get("c") or []):
        out.extend(advertised(c, path + (i,)))
    return out


def all_paths(node, path=()):
    out = [list(path)]
    for i, c in enumerate(node.get("c") or []):
        out.extend(all_paths(c, path + (i,)))
    return out


WORDS = ["Milk", "  spaces  ", "", "éclair", "日本語", "a\"quote", "back\\slash", "tab\there", "x" * 40, "Call mom", "🙂"]
# digit strings, so that forms asking for a number (the Send example's amount) can be filled in
NUMS = ["25000", " 1200 ", "007", "546", "0"]

# odd host lines: malformed answers both CLIs must reject as bad-json, and repeated keys they must read as
# Lean does
HOST_PROBES = ['{"host":"nope"}', '{"host":5}', '{"host":{}}', '{"host":{"a":{},"b":{}}}', '{"host":null}',
            # repeated keys: Lean keeps the last value (the first is not a host answer, the second is)
            '{"host":{"balance":{"text":"a"}},"host":{"balance":{"text":"b"}}}',
            '{"host":{"balance":{"text":1},"balance":{"text":"last"}}}',
            '{"host":{"balance":{"text":"x","text":"y"}}}']


def normalize(reply):
    """What must agree between the two CLIs."""
    if not isinstance(reply, dict):
        return ("notobject", reply)
    if "error" in reply:
        return ("error", reply.get("seq"), reply.get("error"), reply.get("view") if reply.get("error") == "stale" else None)
    return ("view", reply.get("seq"), reply.get("view"), reply.get("cmds"))


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        return 2
    a, b = Cli(sys.argv[1]), Cli(sys.argv[2])
    steps = int(sys.argv[3]) if len(sys.argv) > 3 else 300
    rng = random.Random(int(sys.argv[4]) if len(sys.argv) > 4 else 1)
    oracle = Cli(sys.argv[5]) if len(sys.argv) > 5 else None
    clis = [("A", a), ("B", b)] + ([("ORACLE", oracle)] if oracle else [])
    firsts = [c.read() for _, c in clis]
    if any(r[0] != "ok" for r in firsts):
        print("FAIL initial line:", firsts)
        return 1
    if any(normalize(r[1]) != normalize(firsts[0][1]) for r in firsts):
        print("FAIL initial view differs:", [json.dumps(r[1])[:300] for r in firsts])
        return 1
    ra = firsts[0]
    cur = ra[1]
    src = oracle or a
    probe = src.send('{"samples":true}')
    cmd_app = probe[0] == "ok" and isinstance(probe[1].get("samples"), list)
    views = rejections = hosts = ncmds = 0
    kinds = {}
    for step in range(1, steps + 1):
        seq = cur["seq"]
        view = cur["view"]
        r = rng.random()
        samples = []
        if cmd_app and (rng.random() < 0.5 or not advertised(view)):
            got = src.send('{"samples":true}')
            if got[0] != "ok" or not isinstance(got[1].get("samples"), list):
                print("FAIL step", step, "samples request:", got)
                return 1
            samples = got[1]["samples"]
        if samples or (cmd_app and r < 0.01):
            if samples and rng.random() < 0.9:
                line = json.dumps({"host": rng.choice(samples)}, ensure_ascii=False)
                hosts += 1
            else:
                line = rng.choice(HOST_PROBES)
        elif r < 0.05:
            line = rng.choice(['{"reset":true}', "", "not json", '{"seq":"x","path":[],"event":{"k":"click"}}',
                               '{"seq":%d,"path":[0],"event":{"k":"zap"}}' % seq])
        elif r < 0.20:
            kind = rng.choice(["stale", "badpath", "nohandler"])
            if kind == "stale":
                p, e = rng.choice(advertised(view) or [([], {"k": "click"})])
                line = json.dumps({"seq": seq + rng.choice([-1, 1, 7]), "path": p, "event": fill(e, rng)})
            elif kind == "badpath":
                p = rng.choice(all_paths(view)) + [rng.choice([99, 7])]
                line = json.dumps({"seq": seq, "path": p, "event": {"k": "click"}})
            else:
                adv = {(tuple(p), e["k"]) for p, e in advertised(view)}
                cands = [(p, k) for p in all_paths(view) for k in ("click", "input", "submit", "toggle")
                         if (tuple(p), k) not in adv]
                p, k = rng.choice(cands)
                line = json.dumps({"seq": seq, "path": p, "event": fill({"k": k}, rng)})
        else:
            adv = advertised(view)
            if not adv:
                line = '{"reset":true}'
            else:
                p, e = rng.choice(adv)
                line = json.dumps({"seq": seq, "path": p, "event": fill(e, rng)})
        ra, rb = a.send(line), b.send(line)
        ro = oracle.send(line) if oracle else ra
        if ra[0] != "ok" or rb[0] != "ok" or ro[0] != "ok":
            print("FAIL step", step, "request:", line[:300], "\nA:", ra, "\nB:", rb, "\nORACLE:", ro)
            return 1
        if normalize(ra[1]) != normalize(rb[1]) or normalize(ra[1]) != normalize(ro[1]):
            print("FAIL step", step, "request:", line[:300])
            print("A:", json.dumps(ra[1], ensure_ascii=False)[:800])
            print("B:", json.dumps(rb[1], ensure_ascii=False)[:800])
            if oracle:
                print("ORACLE:", json.dumps(ro[1], ensure_ascii=False)[:800])
            return 1
        if "error" in ra[1]:
            rejections += 1
            if ra[1]["error"] == "stale":
                cur = {"seq": ra[1]["seq"], "view": ra[1]["view"]}
        else:
            views += 1
            for c in ra[1].get("cmds") or []:
                ncmds += 1
                kind = c if isinstance(c, str) else next(iter(c), "?") if isinstance(c, dict) else "?"
                kinds[kind] = kinds.get(kind, 0) + 1
            cur = ra[1]
        for name, cli in clis:
            extra = cli.extra_lines()
            if extra is not None:
                print("FAIL step", step, name, "printed an extra line:", extra[:200])
                return 1
    codes = [(name, cli.close()) for name, cli in clis]
    if any(code != 0 for _, code in codes):
        print("FAIL exit codes at EOF:", codes)
        return 1
    extra = ", %d host answers, %d commands: %s" % (
        hosts, ncmds, " ".join("%s %d" % kv for kv in sorted(kinds.items()))) if cmd_app else ""
    print("lockstep OK (%d steps, %d views, %d rejections%s)" % (steps, views, rejections, extra))
    return 0


def fill(e, rng):
    e = dict(e)
    if e["k"] == "input":
        e["value"] = rng.choice(NUMS if rng.random() < 0.4 else WORDS)
    elif e["k"] == "toggle":
        e["value"] = rng.choice([True, False])
    return e


if __name__ == "__main__":
    sys.exit(main())
