#!/usr/bin/env python3
"""Lockstep differential driver: feed identical request lines to two ElmLean-protocol CLIs and compare replies.

    python3 -I lockstep.py "<cli A command>" "<cli B command>" [steps=300] [seed=1]

Replies are compared as PARSED JSON (escaping may differ between implementations):
  * view replies: seq and the whole view must be equal;
  * error replies: seq and error code must be equal (detail text may differ);
  * both CLIs must print exactly one line per request and exit 0 at EOF.
Steps are a seeded random walk over the advertised controls of A's current view (80%), non-advertised
pairs (15%: wrong seq, bad path, wrong event kind) and shell probes (5%: reset, blank line, non-JSON).
Prints "lockstep OK (<n> steps, <k> views, <e> rejections)" and exits 0, or the first mismatch and exits 1.
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


def normalize(reply):
    """What must agree between the two CLIs."""
    if not isinstance(reply, dict):
        return ("notobject", reply)
    if "error" in reply:
        return ("error", reply.get("seq"), reply.get("error"), reply.get("view") if reply.get("error") == "stale" else None)
    return ("view", reply.get("seq"), reply.get("view"))


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        return 2
    a, b = Cli(sys.argv[1]), Cli(sys.argv[2])
    steps = int(sys.argv[3]) if len(sys.argv) > 3 else 300
    rng = random.Random(int(sys.argv[4]) if len(sys.argv) > 4 else 1)
    ra, rb = a.read(), b.read()
    if ra[0] != "ok" or rb[0] != "ok":
        print("FAIL initial line:", ra, rb)
        return 1
    if normalize(ra[1]) != normalize(rb[1]):
        print("FAIL initial view differs:\nA:", json.dumps(ra[1])[:600], "\nB:", json.dumps(rb[1])[:600])
        return 1
    cur = ra[1]
    views = rejections = 0
    for step in range(1, steps + 1):
        seq = cur["seq"]
        view = cur["view"]
        r = rng.random()
        if r < 0.05:
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
        if ra[0] != "ok" or rb[0] != "ok":
            print("FAIL step", step, "request:", line[:300], "\nA:", ra, "\nB:", rb)
            return 1
        if normalize(ra[1]) != normalize(rb[1]):
            print("FAIL step", step, "request:", line[:300])
            print("A:", json.dumps(ra[1], ensure_ascii=False)[:800])
            print("B:", json.dumps(rb[1], ensure_ascii=False)[:800])
            return 1
        if "error" in ra[1]:
            rejections += 1
            if ra[1]["error"] == "stale":
                cur = {"seq": ra[1]["seq"], "view": ra[1]["view"]}
        else:
            views += 1
            cur = ra[1]
        for name, cli in (("A", a), ("B", b)):
            extra = cli.extra_lines()
            if extra is not None:
                print("FAIL step", step, name, "printed an extra line:", extra[:200])
                return 1
    ea, eb = a.close(), b.close()
    if ea != 0 or eb != 0:
        print("FAIL exit codes at EOF: A", ea, "B", eb)
        return 1
    print("lockstep OK (%d steps, %d views, %d rejections)" % (steps, views, rejections))
    return 0


def fill(e, rng):
    e = dict(e)
    if e["k"] == "input":
        e["value"] = rng.choice(WORDS)
    elif e["k"] == "toggle":
        e["value"] = rng.choice([True, False])
    return e


if __name__ == "__main__":
    sys.exit(main())
