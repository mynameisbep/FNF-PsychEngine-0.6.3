#!/usr/bin/env python3
"""
Converts every built-in Psych chart to NSE and cross-checks the result.

For each `assets/preload/data/<song>/<song>.json` this script

  1. compiles the chart to a temporary `.nse` (ChartBuilder.from_psych),
  2. verifies that the decoder returns exactly as many notes as the chart has, in order,
  3. if `tools/refbench/refbench` is built, compares the first N decoded notes with the C
     implementation note for note,
  4. with `--write`, writes `<song>.nse` and `<song>-lazy.json` next to the chart, which is
     what the game picks up (see docs/NSE.md).

Usage:
    python3 tools/nse/check_charts.py            # check only
    python3 tools/nse/check_charts.py --write    # install .nse + lazy headers
    python3 tools/nse/check_charts.py --limit 200 --quiet
"""
import glob
import json
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import nse_ref  # noqa: E402

ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
DATA = os.path.join(ROOT, "assets", "preload", "data")
REFBENCH = os.path.join(ROOT, "tools", "refbench", "refbench")


def lazy_header(chart: dict) -> dict:
    song = chart.get("song", chart)
    header = dict(song)
    header["notes"] = []
    header["events"] = []
    return {"song": header}


def main(argv):
    write = "--write" in argv
    quiet = "--quiet" in argv
    limit = 500
    if "--limit" in argv:
        limit = int(argv[argv.index("--limit") + 1])

    has_c = os.path.exists(REFBENCH)
    charts = sorted(glob.glob(os.path.join(DATA, "*", "*.json")))
    tmpdir = tempfile.mkdtemp(prefix="nse-check-")
    tmp = os.path.join(tmpdir, "chart.nse")

    total = ok = failures = 0
    notes_total = 0
    bytes_total = 0

    for path in charts:
        name = os.path.splitext(os.path.basename(path))[0]
        if name.endswith("events"):
            continue
        rel = os.path.relpath(path, ROOT)
        total += 1
        try:
            chart = nse_ref.load_chart_json(path)
            builder = nse_ref.ChartBuilder(lanes=4).from_psych(chart)
            data = builder.build()
            with open(tmp, "wb") as f:
                f.write(data)

            parsed = nse_ref.parse(data)
            stream = nse_ref.NoteStream(parsed)
            count = 0
            last = -1.0
            while True:
                note = stream.next()
                if note is None:
                    break
                if note.t < last - 1e-9:
                    raise ValueError("notes out of order")
                last = note.t
                count += 1
            if count != len(builder.notes):
                raise ValueError(f"decoded {count} of {len(builder.notes)} notes")

            if has_c:
                py = subprocess.run([sys.executable, os.path.join(HERE, "nse_ref.py"), "dump", tmp,
                                     "--limit", str(limit)], capture_output=True, text=True, check=True).stdout
                c = subprocess.run([REFBENCH, "dump", "--file", tmp, "--limit", str(limit)],
                                   capture_output=True, text=True, check=True).stdout
                if py.strip() != c.strip():
                    raise ValueError("python and refbench.c disagree on the decoded notes")

            if write:
                out = os.path.join(os.path.dirname(path), name + ".nse")
                with open(out, "wb") as f:
                    f.write(data)
                with open(os.path.join(os.path.dirname(path), name + "-lazy.json"), "w", encoding="utf-8") as f:
                    json.dump(lazy_header(chart), f, separators=(",", ":"))

            ok += 1
            notes_total += len(builder.notes)
            bytes_total += len(data)
            if not quiet:
                print(f"  ok   {rel:52s} {len(builder.notes):6d} notes, {len(data):7d} bytes "
                      f"({len(data)/max(1,len(builder.notes)):.2f} B/note)")
        except Exception as exc:  # noqa: BLE001
            failures += 1
            print(f"  FAIL {rel}: {exc}")

    print(f"\n{ok}/{total} charts ok, {notes_total} notes, {bytes_total} bytes "
          f"({bytes_total/max(1,notes_total):.2f} B/note average)")
    if has_c:
        print(f"cross-checked against {os.path.relpath(REFBENCH, ROOT)} (first {limit} notes per chart)")
    else:
        print("refbench.c not built - skipping the C cross-check (gcc -O2 -o tools/refbench/refbench tools/refbench/refbench.c -lm)")
    if write:
        print("wrote <song>.nse and <song>-lazy.json next to every chart")
    return 0 if failures == 0 else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
