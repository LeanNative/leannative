#!/opt/homebrew/bin/python3
"""Protocol-conformant test double for `elmlean` (see PROTOCOL.md) with a toy todo model.

Same node grammar, same error codes and precedence (bad-json > stale > bad-path > no-handler),
`{"reset":true}`, exactly one reply per input line, flushed, exit 0 at EOF. Stdlib only.
"""
import decimal
import json
import sys

if hasattr(sys, "set_int_max_str_digits"):
    sys.set_int_max_str_digits(0)  # a 5000-digit integer literal is a number here as in Lean (then stale / bad-path)

INIT = {"todos": [], "draft": ""}
KINDS = {"click": None, "submit": None, "input": str, "toggle": bool}


def view(m):
    rows = [{"t": "row", "c": [{"t": "toggle", "label": t["title"], "on": t["done"]}, {"t": "spacer"},
                                {"t": "button", "label": "Delete", "role": "destructive", "enabled": True}]}
            for t in m["todos"]]
    left = sum(1 for t in m["todos"] if not t["done"])
    return {"t": "col", "c": [
        {"t": "text", "s": "Fake todos", "style": "title"},
        {"t": "row", "c": [{"t": "field", "placeholder": "What needs doing?", "value": m["draft"], "submits": True},
                           {"t": "button", "label": "Add", "role": "primary", "enabled": bool(m["draft"].strip())}]},
        {"t": "col", "c": rows},
        {"t": "divider"},
        {"t": "text", "s": f"{left} left", "style": "caption"}]}


def at(node, path):
    for i in path:
        kids = node.get("c", []) if node["t"] in ("col", "row") else []
        if i >= len(kids):
            return None
        node = kids[i]
    return node


def add(m):
    title = m["draft"].strip()
    return m if not title else {"todos": m["todos"] + [{"title": title, "done": False}], "draft": ""}


def handle(m, path, ev):
    """Mirror of Html.dispatch + update: an error code string, or the new model."""
    node = at(view(m), path)
    if node is None:
        return "bad-path"
    t, k = node["t"], ev["k"]
    if t == "button" and k == "click" and node["enabled"]:
        return add(m) if path == [1, 1] else {**m, "todos": [x for j, x in enumerate(m["todos"]) if j != path[1]]}
    if t == "field" and k == "input":
        return {**m, "draft": ev["value"]}
    if t == "field" and k == "submit" and node["submits"]:
        return add(m)
    if t == "toggle" and k == "toggle":
        return {**m, "todos": [{**x, "done": ev["value"]} if j == path[1] else x for j, x in enumerate(m["todos"])]}
    return "no-handler"


HUGE = 10 ** 60  # stands in for any integer value >= 10^60: stale as a seq, bad-path as a path index, never materialised


def nat(x, what):
    """PROTOCOL.md: a JSON number whose VALUE is a non-negative integer (1, 1.0, 1e0 and 10e-1 all denote 1).
    `parse` turns every non-integer literal into an exact Decimal, so 1.0 == 1 and 1.5 is rejected; a bool is
    not a number (type(True) is bool, not int). An integer-valued Decimal of 10^60 or more (1E+3000000,
    1e999999999999999999) is not converted with int(), which would build every digit (25 s for 1E+3000000,
    MemoryError beyond): its exact value cannot matter, no seq or child index gets anywhere near it, so HUGE is
    returned instead and the outcome is the one the real CLI gives, stale or bad-path. Zero is tested first
    because 0E+999999 has adjusted() == 999999 and must stay 0."""
    if type(x) is int:
        if x >= 0:
            return x
    elif isinstance(x, decimal.Decimal) and x >= 0 and x == x.to_integral_value():
        if x == 0:
            return 0
        if x.adjusted() >= 60:
            return HUGE
        return int(x)
    raise ValueError(f"{what}: natural number expected")


def no_constant(name):
    raise ValueError(f"{name} is not JSON")  # Python's json accepts NaN/Infinity/-Infinity; PROTOCOL.md does not


def parse(line):
    """'reset', or (seq, path, event). Raises ValueError (-> bad-json) on anything malformed. The stdlib can raise
    more than ValueError on hostile input (decimal.InvalidOperation, an ArithmeticError, for 1e1000000000000000000,
    whose exponent exceeds what a Decimal can hold; MemoryError or RecursionError on absurd sizes): `main` maps
    every exception from here to bad-json, since the contract is one reply per line, whatever the line."""
    j = json.loads(line, parse_float=decimal.Decimal, parse_constant=no_constant)
    if not isinstance(j, dict):
        raise ValueError("object expected")
    if j.get("reset") is True:
        return "reset"
    for key in ("seq", "path", "event"):
        if key not in j:
            raise ValueError(f"property not found: {key}")
    seq = nat(j["seq"], "seq")
    if not isinstance(j["path"], list):
        raise ValueError("path: array expected")
    path = [nat(i, "path element") for i in j["path"]]
    ev = j["event"]
    if not isinstance(ev, dict):
        raise ValueError("event: object expected")
    k = ev.get("k")
    if not isinstance(k, str) or k not in KINDS:  # the isinstance guard: `[] in KINDS` would raise TypeError (unhashable)
        raise ValueError(f"unknown event kind {k!r}")
    want = KINDS[k]
    if want is not None and type(ev.get("value")) is not want:
        raise ValueError("property not found: value" if "value" not in ev else "value: wrong type")
    return seq, path, ev


def emit(obj):
    sys.stdout.write(json.dumps(obj, sort_keys=True, separators=(",", ":")) + "\n")
    sys.stdout.flush()


def main(argv):
    if argv[1:] in (["selftest"], ["--selftest"]):
        print("fake_cli selftest: ok (nothing to check)", file=sys.stderr)
        return 0
    m, seq = INIT, 0
    emit({"seq": seq, "view": view(m)})
    if argv[1:] == ["view"]:
        return 0
    for line in sys.stdin:
        try:
            req = parse(line.rstrip("\n"))
        except (ValueError, ArithmeticError, MemoryError, RecursionError, TypeError) as e:
            # ValueError is the validator's own verdict; the others are the stdlib giving up on a hostile line
            # (decimal.InvalidOperation is an ArithmeticError). Never a traceback, never an exit: one reply per line.
            detail = str(e) if isinstance(e, ValueError) else f"{type(e).__name__}: {e}"
            emit({"seq": seq, "error": "bad-json", "detail": detail})
            continue
        if req == "reset":
            m, seq = INIT, seq + 1
        else:
            rseq, path, ev = req
            if rseq != seq:
                emit({"seq": seq, "error": "stale", "view": view(m)})
                continue
            r = handle(m, path, ev)
            if isinstance(r, str):
                emit({"seq": seq, "error": r})
                continue
            m, seq = r, seq + 1
        emit({"seq": seq, "view": view(m)})
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
