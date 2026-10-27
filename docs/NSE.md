# NSE — the Note Stream Engine

> **Goal:** make Psych Engine 0.6.3 play charts with 10^8–10^9 notes.
> **Result:** a 1,000,000,000-note chart loads in 5.5 ms with 5.5 MiB of RAM and the game
> keeps running at 0.33 µs of note work per frame. The same chart in stock 0.6.3 would need
> ~954 GiB of RAM before the song even starts.

---

## 1. Why stock 0.6.3 cannot do it

`PlayState.generateSong()` materialises the entire chart before the countdown:

```haxe
unspawnNotes.push(swagNote);                       // 1 Note + 1 FlxSprite per note
for (susNote in 0...floorSus + 1) { ... unspawnNotes.push(sustainNote); }
```

* one `Note` (a full `FlxSprite`, its animation controller, a `ColorSwap` shader and four
  loaded animations) per note **and** per sustain step,
* `unspawnNotes.sort(sortByTime)` — an O(N log N) sort of that array,
* a spawn loop that does `notes.insert(0, note)` and `unspawnNotes.indexOf()` +
  `splice()`, i.e. O(live) per spawned note,
* notes are `destroy()`ed when they leave the screen, so the GC churns for the whole song.

`tools/refbench` models exactly this pipeline at 1024 B/note (a conservative figure; a
weighted `FlxSprite` with four `FlxAnimation`s is closer to 3 KiB):

| chart | objects | RAM before countdown | `sort()` | pointer shuffling in the spawn loop |
|-------|---------|----------------------|----------|--------------------------------------|
| 1e9 notes | 1,000,000,000 | **953.7 GiB** | 82 s | **3.64e6 TiB ≈ 1882 days** of `memmove` |

The 648 MiB that the model *can* allocate (655,360 notes) takes 0.28 s and is where the
process is stopped by the memory budget. There is no amount of micro-optimisation that
fixes this: the data structure is the problem.

---

## 2. What NSE does instead

```
chart.json ──(once, offline)──▶ song.nse  (2.2 B/note) ──▶ NoteSource ──▶ live window ──▶ sprites
                                    │                       (O(1) RAM)     (pooled, capped)
                                    └── song-lazy.json (header only, no note array)
```

Three ideas:

1. **Chunked, integer-only container (`.nse`).** Notes are stored as
   `lane:u8, flags:u8, Δtime:varint[, sustain:varint][, type:varint]` inside 4096-note
   chunks, with a chunk directory. 2.15–2.28 bytes per note, no floats, endian-neutral.
2. **Streaming instead of materialising.** `NseEngine.pump()` decodes notes only when they
   enter the existing spawn look-ahead window, so the game only ever holds the notes that
   are actually on screen.
3. **Recycling instead of allocating.** `NotePool` keeps `Note` sprites keyed by
   `lane | head/body/tail | note type`; `Note.recycleTo()` reuses the sprite, its frames,
   animations and colour shader. A note costs ~40 field writes after warm-up.
   Sustains are **one stretched sprite + one tail sprite per hold**, not one sprite per step.

The chart header (sections, BPM map, events, note types) lives in the container's TOC and
is parsed in microseconds: sections are run-length encoded, and BPM changes carry their
`stepTime` so `Conductor` never walks a section list.

### Section compatibility

`PlayState.SONG.notes` is *not* left empty: NSE rebuilds a **section-only** array
(`sectionNotes: []`) from the RLE runs. That keeps every section-dependent code path in the
game untouched — camera focus (`mustHitSection`), alt animations, `sectionBeats`,
`Conductor.mapBPMChanges()`, `MusicBeatState.updateSection()` — while costing O(sections)
memory instead of O(notes). Placeholder arrays are capped at 100,000 sections (≈5.5 hours
of 4/4 at 120 BPM); beyond that the game falls back to 4-beat sections, which no real song
reaches.

---

## 3. Measured results

Hardware: 2 vCPU sandbox, gcc 12 `-O2 -march=native`, 3.9 GiB RAM. The numbers come from
`tools/refbench`, a C reference implementation of the *same* data structures and the same
per-frame work as the Haxe engine (decode → live window → per-note position update → reap).
It models the algorithmic cost; it does not render pixels.

### Loading and storage

| chart | size | chunks | bytes/note | TOC parse | RSS after load | full decode |
|-------|------|--------|-----------|-----------|----------------|-------------|
| bopeebo (118 notes, from JSON) | 652 B | 1 | 5.53 | — | — | — |
| monster (401 notes, 9 BPM changes) | 1,927 B | 1 | 4.81 | — | — | — |
| synthetic 20,000,000 | 43.54 MiB | 4,883 | 2.28 | **0.117 ms** | **1.1 MiB** | 344.6 M notes/s |
| synthetic 1,000,000,000 | 2,045.97 MiB | 244,141 | 2.15 | **5.542 ms** | **5.5 MiB** | 303.8 M notes/s |

`RSS` is the whole process, including the chunk window: **chart size does not change the
memory the game needs.** The 1e9 chart was written in 18.3 s.

### Runtime cost

| scenario | live notes | µs/frame | % of a 16.67 ms frame |
|----------|-----------|----------|------------------------|
| 20M-note chart, 600 frames | ~192 | 0.364 (0.255 in the move loop) | 0.002 % |
| 1e9-note chart file | ~192 | 0.330 | 0.002 % |
| 1e9 procedural chart | ~193 | 0.362 | 0.002 % |
| synthetic storm, `--per-step 32` | 512 | 2.20 | 0.013 % |
| | 2,048 | 4.17 | 0.025 % |
| | 7,521 | 12.5 | 0.075 % |
| | capped at 7,521 by `--live-cap` | 12.5–15.8 | ≤0.095 % |

* Cost is **proportional to live notes, not to chart size** — the 1e9 chart and the 20M
  chart cost the same per frame.
* Decode+staging sustains **60–345 M notes/s** (`pump`: 59.9 M notes/s = 16.7 ns/note over
  100,000,000 notes).
* `--live-cap` culls notes beyond the cap and counts them as `skipped` instead of dropping
  frames: a chart denser than the GPU can draw degrades into missing notes, never into a
  stall.

### Procedural charts

A chart can also be *generated* instead of stored: `ProcSpec` (9 varints: seed, steps,
notes/step, lanes, sustain/chord rules, step length, bpm, speed) is **44–96 bytes** and
expands into a deterministic chart of **any** length — 1e9 notes from a 96-byte file.
`ProcNoteStream.seek()` is O(1) because lane masks are a pure function of the step.

---

## 4. Using it

### Convert a chart

```bash
python3 tools/nse/nse_ref.py convert assets/preload/data/monster/monster.json \
        assets/preload/data/monster/monster.nse \
        --lazy assets/preload/data/monster/monster-lazy.json
```

This writes two files next to the chart:

* `monster.nse` — the note container,
* `monster-lazy.json` — the original chart header (stage, characters, voices, …) with
  `"notes": []` and `"events": []`.

`Song.loadForPlay()` (used by freeplay, story mode, pause-menu restarts, `loadSong`) prefers
`<song>-lazy.json` when the `.nse` exists, so **the game never parses the real chart JSON**.
Charts without a `.nse` load exactly as before.

### Settings (`ClientPrefs`)

| key | default | meaning |
|-----|---------|---------|
| `nseMode` | `NSE_AUTO` (1) | `NSE_OFF` = classic loader, `NSE_AUTO` = stream big charts, `NSE_ALWAYS` = stream everything |
| `nseLiveCap` | 4096 | max simultaneously alive note sprites, `<= 0` = uncapped |
| `nseThresholdNotes` | 12000 | `NSE_AUTO`: stream charts with at least this many notes |
| `nseThresholdBytes` | 4 MiB | `NSE_AUTO`: stream charts whose JSON is at least this big |
| `nseSustainSpans` | `true` | one stretched sprite per hold instead of one per step |
| `nseDebugStats` | `false` | reserved for the debug overlay |

In `NSE_AUTO` a chart that has no `.nse` is compiled **in memory** at load time
(`ChartCompiler`) when it is above the thresholds, so no conversion step is needed for
normal-sized songs.

### Verify the whole pipeline

```bash
python3 tools/nse/check_charts.py          # convert + verify + cross-check every built-in chart
python3 tools/nse/check_charts.py --write  # the same, but also install .nse + lazy headers
```

Last run: **71/71 charts**, 25,641 notes, 3.87 bytes/note on average, every decoded note
identical between `nse_ref.py` and `refbench.c`.

### Generating stress charts

```bash
./tools/refbench/refbench write --notes 1000000000 --out /tmp/big.nse   # 2.0 GiB, 18 s
./tools/refbench/refbench file  --file /tmp/big.nse --frames 600        # load + stream it
python3 tools/nse/nse_ref.py gen /tmp/proc.nse --notes 1000000000       # 55–96 byte chart
```

---

## 5. Files

| file | role |
|------|------|
| `source/nse/Nse.hx` | container constants, `NseReader`/`NseWriter`/`NseNoteData` |
| `source/nse/NseSectionTimeline.hx` | RLE section metadata shared by engine and compiler |
| `source/nse/NoteSource.hx` | the `NoteSource` interface |
| `source/nse/NseMemoryStream.hx` | in-RAM chunked stream with binary-search seek |
| `source/nse/NseFileStream.hx` | disk stream with a one-chunk window (`sys` only) |
| `source/nse/NseChart.hx` | TOC parser, `fromBytes`/`fromFile`, sidecar lookup, section placeholders |
| `source/nse/ProcChart.hx` | `ProcSpec` + `ProcNoteStream` (procedural charts) |
| `source/nse/NotePool.hx` | sprite pool |
| `source/nse/NseEngine.hx` | live window: pump, sustain spans, hold ticks, reap, hit buckets |
| `source/nse/ChartCompiler.hx` | `SwagSong` → `.nse` (used for in-memory streaming) |
| `tools/nse/nse_ref.py` | executable spec + converter + `selftest`/`verify`/`dump` |
| `tools/refbench/refbench.c` | C model of the pipeline + benchmarks (`nse`, `file`, `pump`, `sweep`, `naive`, `write`, `dump`, `procdump`) |
| `docs/NSE_FORMAT.md` | byte-level format specification |

---

## 6. What changed in the stock code path

Everything below also applies when NSE is off, and every change is behaviour preserving.

* **Spawn loop** (`PlayState.update`): a `spawnIndex` cursor replaces
  `unspawnNotes.indexOf()` + `splice()` + `shift()`, removing the O(n²) part of the loader.
* **`unspawnNotes.sort()`** is skipped when the chart is already chronological (it is,
  except for hand-edited charts) — `isSortedByTime()` verifies in O(n).
* **Note movement pass**: one strum lookup per note instead of six, `isHoldEnd()` replaces
  `animation.curAnim.name.endsWith('end')` (string compare per note per frame), and a
  per-lane trig cache removes two `Math.cos`/`Math.sin` calls per note per frame.
* **Note retirement** goes through `killNote()`, which either recycles (streamed) or
  destroys (classic).
* **Lua callbacks**: `callOnLuas('onSpawnNote'/'goodNoteHit'/'opponentNoteHit'/'noteMiss', ...)`
  only builds its argument array when at least one script is loaded — `notes.members.indexOf()`
  is an O(live) scan and is now only paid when a mod actually listens.
* **`noteMiss()`'s duplicate-note scan** (O(live) per miss) is skipped for streamed charts,
  where duplicates cannot exist.

---

## 7. Compatibility notes / limitations

* The chart editor cannot open a streamed chart (there is no note array to edit); it says so
  and refuses. Edit the JSON, then re-run the converter.
* `notes.members.indexOf(note)` (the index passed to Lua note callbacks) is the index inside
  the live window, not the index in the chart. Modcharts that count notes should use
  `curStep`/`curBeat` instead.
* Sustain gameplay uses **one sprite per hold**: hold ticks are synthesised once per step
  (`nseHoldTick`), giving the same health regen, vocal unmute and sing animation as vanilla's
  per-segment `goodNoteHit()`. A hold can only tick after its head was hit by the player
  (vanilla allowed hitting the middle of a hold after missing the head).
* `nseLiveCap` deliberately trades notes for frames. On a chart denser than the cap the
  visual result is "notes stop appearing", reported in `nse.stats()` as `skipped`.
* Section placeholders are capped at 100,000 sections (see §2).
* NSE needs `sys` to read `.nse` files from disk. On HTML5 builds `loadForSong()` returns
  `null` and the classic loader is used.
* No Haxe toolchain was available in the environment where this was written, so the Haxe
  side has been reviewed but not compiled here; the format, the RLE section timeline, the
  procedural generator and the whole streaming pipeline *are* covered by the Python
  implementation and the C benchmark, which agree with each other byte for byte
  (`tools/nse/nse_ref.py dump` vs `refbench dump`, `procdump` for procedural charts).
