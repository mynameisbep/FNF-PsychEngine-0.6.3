# NSE container format — version 1

> Status: **stable**. The executable specification is `tools/nse/nse_ref.py`
> (`ChartBuilder.build()` writes, `parse()` reads); `tools/refbench/refbench.c` is an
> independent reader/writer and both agree byte for byte
> (`nse_ref.py dump` vs `refbench dump`, `nse_ref.py` `ProcStream` vs `refbench procdump`).

Everything is **little endian**, and every variable-length integer is an unsigned LEB128
**varint** (`tools/nse/nse_ref.py: put_varint` / `Reader.varint`). There are no floats
anywhere in the file: times are integer microseconds/milliseconds and BPM is stored
multiplied by 1000. That makes the format identical on every Haxe target (cpp, hl, js…)
and safe to `mmap`/`pread` — decoding never needs endian conversion.

## 1. Header

| field | type | notes |
|-------|------|-------|
| magic | 4 bytes | `"NSE1"` (`0x4E 0x53 0x45 0x31`) |
| version | u16 | `1` |
| flags | u16 | see below |
| lanes | u8 | 4 for Psych |
| fidelity | u8 | `1` = sustain spans |
| bpm × 1000 | varint | base BPM of the song |
| speed × 1000 | varint | base scroll speed |
| noteCount | varint | total notes in the chart (not counting sustain steps) |
| chunkCapacity | varint | notes per chunk (4096 when written by these tools) |
| sectionCount | varint | number of sections |
| durationMs | varint | chart length in ms (`last.strumTime + last.span`) |

`flags`:

| bit | name | meaning |
|-----|------|---------|
| 0 | `F_EVENTS` | an event table is present |
| 1 | `F_TYPES` | the string table is present (note types / event names) |
| 2 | `F_PROC` | the payload is a `ProcSpec`, not note chunks |
| 3 | `F_SPANS` | sustains are stored as spans (always set by v1 writers) |
| 4 | `F_CRC` | a CRC32 of the whole file precedes EOF |

## 2. String table (`F_TYPES`)

```
varint count
count × { varint byteLength, byteLength bytes of UTF-8 }
```

Note types and event names/values share this table; note and event records refer to it by
index.

## 3. Section timeline (run-length encoded)

```
varint runCount
runCount × {
    varint runLength            # number of identical sections
    varint beats × 1000         # sectionBeats (usually 4)
    u8     flags
    [varint bpm × 1000]         # only when flags & SF_CHBPM
}
```

`flags` (`SF_*`): `MUSTHIT = 1`, `GF = 2`, `ALT = 4`, `CHBPM = 8`.

Runs are merged while writing, so a chart with 31 million identical sections costs a
handful of bytes. This is what lets `SONG.notes` be rebuilt as section *placeholders*
without ever materialising per-note data (`NseChart.buildSectionPlaceholders()`).

## 4. BPM change map

```
varint count
count × { varint deltaMs, varint bpm × 1000, varint stepTime }
```

`deltaMs` is relative to the previous change (first one relative to 0). `stepTime` is the
absolute step at which the change happens — it is stored so `Conductor.updateCurStep()`
never has to walk the section list (which may have millions of entries).

## 5. Chunk directory

```
varint chunkCount
chunkCount × { varint noteCount, varint byteLength }
```

Offsets are implicit: chunk *i* starts at `payloadOffset + Σ byteLength[0..i)`. The reader
turns this into a flat `Float`/`Int` array (16 bytes per chunk in RAM): a 1e9-note chart
needs 244,141 chunks ≈ 3.7 MiB of directory.

## 6. Event table (`F_EVENTS`)

```
varint count
count × { varint deltaMs, varint nameIndex, varint value1Index, varint value2Index }
```

## 7. Note payload (non-procedural)

Chunks are written back to back after the TOC. Each chunk holds up to `chunkCapacity`
notes:

```
varint baseMs                  # strum time of the first note, absolute
note × {
    u8 lane
    u8 flags
    [varint deltaMs]           # omitted when flags & NF_DTREPEAT
    [varint spanMs]            # when flags & NF_SUSTAIN
    [varint typeIndex]         # when flags & NF_HASTYPE
}
```

`deltaMs` is the difference to the **previous note in the chart** (not to `baseMs` after
the first note). `NF_DTREPEAT` means "same delta as the previous note", which is the common
case for dense streams (chords, 16th streams) and saves one byte per repeated delta.

`flags` (`NF_*`):

| bit | value | meaning |
|-----|-------|---------|
| 0 | 1 | `MUSTPRESS` — player side |
| 1 | 2 | `SUSTAIN` — `spanMs` present |
| 2 | 4 | `GFNOTE` |
| 3 | 8 | `HASTYPE` — `typeIndex` present |
| 4 | 16 | `LOWPRIORITY` ("Hurt Note") |
| 5 | 32 | `HITCAUSESMISS` ("Hurt Note") |
| 6 | 64 | `NOANIM` ("No Animation") |
| 7 | 128 | `DTREPEAT` — delta equals the previous note's delta |

Typical cost: **1.9–2.3 bytes/note** (lane + flags + 1-byte delta).

## 8. Procedural payload (`F_PROC`)

```
varint seed
varint steps
varint notesPerStep
varint lanes
varint sustainEvery
varint chordEvery
varint stepMs × 1000
varint bpm × 1000
varint speed × 1000
```

9 varints — **44 to 96 bytes** — generate a deterministic chart of any length. The note
generator is part of the format (all three implementations agree):

```
v      = mix32(seed ^ mul32(step, HASH_A))
lane   = chord ? (i + (v >> 8)) % lanes : (v >> 1) % lanes        # i = note index in step
span   = (sustainEvery && step % sustainEvery == 0 && i == 0) ? 3 * stepMs : 0
mustPress = ((step / 16) % 2) == 0
HASH_A = 0x9E3779B9
mix32(x): z = x + HASH_A; z = mul32(z ^ (z >>> 16), 0x85EBCA6B);
          z = mul32(z ^ (z >>> 15), 0x735A2D97); return z ^ (z >>> 15)
mul32(a, b) = (a * b) & 0xFFFFFFFF
```

Because lanes are a pure function of the step, `seek()` is O(1).

## 9. Trailer

When `F_CRC` is set, a `u32` CRC32 of every preceding byte is appended. Readers must ignore
the trailer when the flag is clear (both readers compute the payload end from the chunk
directory, so the flag can simply be dropped for speed).

## 10. Decode cost

| operation | cost |
|-----------|------|
| open a chart | read header + TOC; 5.5 ms and 5.5 MiB for 1e9 notes |
| decode one note | 2 byte loads + 1–3 varints |
| sequential decode | 300–345 M notes/s (C, `-O2`) |
| seek to time *t* | O(log chunks) binary search + one chunk decode |
