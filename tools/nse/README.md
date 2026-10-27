# NSE tooling

Two implementations of the same container live here, and they are used to cross-check each
other:

* `nse_ref.py` — the **executable specification** (encoder, decoder, streaming reader,
  procedural generator, converter). Pure Python 3, no dependencies.
* `../refbench/refbench.c` — a **C model of the engine's data structures** used for
  benchmarks and as an independent reader/writer.

## nse_ref.py

```bash
# self test (encoder/decoder/stream/procedural round trip)
python3 nse_ref.py selftest

# convert a Psych chart: writes song.nse and (optionally) the header-only song-lazy.json
python3 nse_ref.py convert assets/preload/data/monster/monster.json /tmp/monster.nse \
        --lazy /tmp/monster-lazy.json

# decode checks
python3 nse_ref.py verify /tmp/monster.nse
python3 nse_ref.py dump   /tmp/monster.nse --limit 40

# procedural charts (9 varints -> any number of notes)
python3 nse_ref.py gen /tmp/proc.nse --notes 1000000000

# quick model benchmark
python3 nse_ref.py bench --notes 10000000
```

`convert` prints what matters for huge charts: notes, chunks, section runs, BPM changes,
bytes per note, the on-disk TOC size and the RAM the chunk directory will need at load time.

## check_charts.py

```bash
python3 tools/nse/check_charts.py            # every built-in chart: convert + verify + C cross-check
python3 tools/nse/check_charts.py --write    # also write <song>.nse and <song>-lazy.json
python3 tools/nse/check_charts.py --limit 50 # fewer notes per cross-check (faster)
```

## refbench.c

```bash
cd tools/refbench
gcc -O2 -march=native -o refbench refbench.c -lm

./refbench write --notes 1000000000 --out /tmp/big.nse     # write a 2.0 GiB, 1e9-note chart
./refbench file  --file /tmp/big.nse --frames 600          # open + stream + simulate frames
./refbench dump  --file /tmp/big.nse --limit 40            # decoded notes (compare with nse_ref dump)
./refbench nse   --notes 1000000000 --per-step 8           # procedural chart, no file at all
./refbench pump  --notes 100000000                    # decode + staging throughput
./refbench sweep --per-step 32 --live-cap 131072      # per-frame cost vs live note count
./refbench naive --notes 1000000000 --mem-budget-mb 600  # stock 0.6.3 model for comparison
./refbench procdump --notes 100 --per-step 8 --lanes 4    # procedural notes (compare with ProcStream)
```

`file` reports: TOC parse time, process RSS, full-decode throughput, integrity check
(monotonic times), then simulates `--frames` frames of the real loop (spawn window, live
window, per-note position update, reaping) and prints µs/frame and peak live notes.

### Cross-implementation checks

```bash
# notes: python encoder -> C decoder
python3 tools/nse/nse_ref.py dump /tmp/monster.nse --limit 40 > /tmp/py.txt
./tools/refbench/refbench dump --file /tmp/monster.nse --limit 40 > /tmp/c.txt
diff /tmp/py.txt /tmp/c.txt && echo "encoders/decoders agree"
```

The same comparison exists for procedural charts (`ProcStream` vs `procdump`); both are
part of the repository's manual test checklist because the Haxe engine must produce exactly
the same notes as both of them.
