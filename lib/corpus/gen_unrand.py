#!/usr/bin/env python3
"""Emit unrand.ml from the checked-in data/unrand-names/*.txt rosters.

Run by the dune rule beside this file, not by hand. The rosters themselves come
from tools/unrand-roster, which needs a provisioned build tree; this step only
turns them into a module so the webapp carries the vocabulary without reading
data/ at runtime.
"""
import os, sys


def ml_string(s):
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


def main(paths):
    out = ["open! Core\n", "\n", "let table =\n", "  [ "]
    entries = []
    for path in sorted(paths):
        version = os.path.basename(path)[: -len(".txt")]
        names = [l.strip() for l in open(path, encoding="utf-8") if l.strip()]
        body = "\n      ; ".join(ml_string(n) for n in names)
        entries.append(f"{ml_string(version)}, [ {body} ]")
    out.append("\n  ; ".join(entries))
    out.append("\n  ]\n;;\n\n")
    out.append("let names ~version = List.Assoc.find table version ~equal:String.equal\n")
    out.append("let versions = List.map table ~f:fst\n")
    sys.stdout.write("".join(out))


if __name__ == "__main__":
    main(sys.argv[1:])
