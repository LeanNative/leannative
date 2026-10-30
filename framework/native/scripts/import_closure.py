#!/usr/bin/env python3
"""Print the modules (with their package dir) in the import closure of a root module, restricted to the
given package source dirs (the app's and LeanNative's); toolchain modules (Init, Std, Lean) are skipped.
usage: import_closure.py <Root.Module> <package dir>...   → lines "<package dir>\t<Module.Name>" """
import os, re, sys
root, pkgs = sys.argv[1], list(dict.fromkeys(sys.argv[2:]))
imp = re.compile(r'^\s*(?:public\s+|private\s+)?import\s+(?:all\s+)?([\w.]+)', re.M)
def locate(mod):
    rel = mod.replace('.', '/') + '.lean'
    for p in pkgs:
        if os.path.isfile(os.path.join(p, rel)):
            return p, os.path.join(p, rel)
    return None
seen, todo = set(), [root]
while todo:
    m = todo.pop()
    if m in seen: continue
    loc = locate(m)
    if not loc: continue
    seen.add(m)
    print(f"{loc[0]}\t{m}")
    src = open(loc[1], encoding='utf-8').read()
    todo += imp.findall(src)
