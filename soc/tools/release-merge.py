#!/usr/bin/env python3
"""Put releases made separately (one board each, as GitHub's release
workflow makes them) together into one: release-merge.py OUT DIR...

The files are copied into OUT; MANIFEST.json's systems and SUMMARY.md's
rows are joined; SHA256SUMS is made again. Every DIR must be the same tag.
"""
import hashlib
import json
import os
import shutil
import sys


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    out, dirs = sys.argv[1], sys.argv[2:]
    os.makedirs(out, exist_ok=True)
    tag = commit = date = None
    systems = {}
    head, rows = [], []
    for d in dirs:
        man = json.load(open(os.path.join(d, "MANIFEST.json")))
        if tag and man["version"] != tag:
            sys.exit(f"release-merge: {d} is {man['version']}, not {tag}")
        tag, commit, date = man["version"], man["commit"], man["date"]
        for system, boards in man["systems"].items():
            systems.setdefault(system, {}).update(boards)
        lines = open(os.path.join(d, "SUMMARY.md")).read().splitlines()
        table = [i for i, l in enumerate(lines) if l.startswith("|---")]
        if not head and table:
            head = lines[:table[0] + 1]
        rows += lines[table[0] + 1:] if table else []
        for f in os.listdir(d):
            if f.startswith("kakao-") or f == "THIRD-PARTY.txt":
                shutil.copy(os.path.join(d, f), os.path.join(out, f))
    json.dump({"project": "kakao", "version": tag, "commit": commit, "date": date, "systems": systems},
              open(os.path.join(out, "MANIFEST.json"), "w"), indent=1)
    rows = [r for r in rows if r.startswith("|")]
    rows.sort()
    open(os.path.join(out, "SUMMARY.md"), "w").write("\n".join(head + rows) + "\n")
    names = sorted(f for f in os.listdir(out) if f.startswith("kakao-")) + ["THIRD-PARTY.txt", "MANIFEST.json"]
    with open(os.path.join(out, "SHA256SUMS"), "w") as s:
        for f in names:
            h = hashlib.sha256(open(os.path.join(out, f), "rb").read()).hexdigest()
            s.write(f"{h}  {f}\n")
    failed = [r for r in rows if "not built" in r]
    print(f"release-merge: {tag}: {len(names) - 2} files into {out}")
    if failed:
        print("release-merge: not built:\n" + "\n".join(failed))
        sys.exit(1)


if __name__ == "__main__":
    main()
