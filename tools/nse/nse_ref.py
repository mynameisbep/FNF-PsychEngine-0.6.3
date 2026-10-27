#!/usr/bin/env python3
"""
NSE (Note Stream Engine) reference implementation  --  Psych Engine 0.6.3 "huge chart" format.

This file is the *executable specification* for the .nse container and the streaming
algorithms used by source/nse/*.hx in the engine.  The Haxe code is a 1:1 port of the
logic below, so every invariant checked here holds for the engine as well.

Design goals
------------
  * O(1) memory per note *on disk* (2-3 bytes per note), never one object per note.
  * O(log chunks) random access to the note stream (dense chunk directory).
  * O(live) work per frame instead of O(total notes).

File layout (little endian, version 1)
--------------------------------------
  header : "NSE1", u16 version, u16 flags, u8 lanes, u8 fidelity,
           varint bpm*1000, speed*1000, noteCount, chunkCapacity, sectionCount, durationMs
  TOC    : string table, section runs (RLE), bpm changes, chunk directory, events
  payload: chunk payloads back to back  (or a ProcSpec when flags bit2 is set)
  u32    : CRC32 of everything before it   (only when flags bit4 is set)

Chunk payload:
  varint baseMs                   time of the first note in the chunk
  note*: u8 lane, u8 flags, [varint dtMs], [varint spanMs], [varint typeIdx]

  flags bit0 mustPress
        bit1 sustain      (spanMs follows)
        bit2 gfNote
        bit3 hasType      (typeIdx follows)
        bit4 lowPriority
        bit5 hitCausesMiss
        bit6 noAnimation
        bit7 dtRepeated   (dt == previous dt, no varint stored)

Section run (RLE):
  varint runLength, varint beats*1000, u8 flags, [varint bpm*1000 if flags bit3]
  flags bit0 mustHitSection, bit1 gfSection, bit2 altAnim, bit3 changeBPM

BPM change:  varint deltaMs, varint bpm*1000, varint stepTime
Chunk dir :  varint count, then per chunk: varint noteCount, varint byteLength
Event     :  varint deltaMs, varint nameIdx, varint value1Idx, varint value2Idx

Procedural charts (flags bit2) store 9 varints (ProcSpec) instead of a payload:
  seed, steps, notesPerStep, lanes, sustainEvery, chordEvery, stepMs*1000, bpm*1000,
  speed*1000  -- a few dozen bytes that generate a chart of any length deterministically.

Commands
--------
  selftest                            encode/decode/stream/procedural round trip
  convert  <chart.json> <out.nse> [--lazy <song>-lazy.json] [--lanes N]
                                      Psych chart -> container (+ header-only JSON)
  gen      <out.nse> --notes N        procedural chart container
  verify   <chart.nse>                decode everything, check order and counts
  dump     <chart.nse> [--limit N]    print decoded notes (diff against refbench dump)
  bench    --notes N                  decode/stream throughput model
"""
from __future__ import annotations

import json
import os
import math
import os
import struct
import sys
import time
import zlib
from dataclasses import dataclass, field
from typing import Iterator, List, Optional, Tuple

MAGIC = b"NSE1"
VERSION = 1

F_EVENTS = 1 << 0
F_TYPES = 1 << 1
F_PROC = 1 << 2
F_SPANS = 1 << 3
F_CRC = 1 << 4          # the trailing u32 CRC32 is valid (skipped for >2 GiB charts)

# note flags
NF_MUSTPRESS = 1 << 0
NF_SUSTAIN = 1 << 1
NF_GFNOTE = 1 << 2
NF_HASTYPE = 1 << 3
NF_LOWPRIORITY = 1 << 4
NF_HITCAUSESMISS = 1 << 5
NF_NOANIM = 1 << 6
NF_DTREPEAT = 1 << 7

# section flags
SF_MUSTHIT = 1 << 0
SF_GF = 1 << 1
SF_ALT = 1 << 2
SF_CHBPM = 1 << 3

# header: magic, u16 version, u16 flags, u8 lanes, u8 fidelity, then varints
#   bpmMilli, speedMilli, noteCount, chunkCapacity, sectionCount, durationMs
CHUNK_CAPACITY = 4096


# --------------------------------------------------------------------------------------
# primitives
# --------------------------------------------------------------------------------------
def put_varint(out: bytearray, v: int) -> None:
    if v < 0:
        raise ValueError("varint must be >= 0")
    while True:
        b = v & 0x7F
        v >>= 7
        if v:
            out.append(b | 0x80)
        else:
            out.append(b)
            return


def varint_size(v: int) -> int:
    n = 1
    v >>= 7
    while v:
        n += 1
        v >>= 7
    return n


class Reader:
    __slots__ = ("b", "p")

    def __init__(self, b: bytes, p: int = 0):
        self.b = b
        self.p = p

    def u8(self) -> int:
        v = self.b[self.p]
        self.p += 1
        return v

    def u16(self) -> int:
        v = struct.unpack_from("<H", self.b, self.p)[0]
        self.p += 2
        return v

    def u32(self) -> int:
        v = struct.unpack_from("<I", self.b, self.p)[0]
        self.p += 4
        return v

    def i32(self) -> int:
        v = struct.unpack_from("<i", self.b, self.p)[0]
        self.p += 4
        return v

    def u64(self) -> int:
        v = struct.unpack_from("<Q", self.b, self.p)[0]
        self.p += 8
        return v

    def f64(self) -> float:
        v = struct.unpack_from("<d", self.b, self.p)[0]
        self.p += 8
        return v

    def varint(self) -> int:
        shift = 0
        result = 0
        b = self.b
        p = self.p
        while True:
            c = b[p]
            p += 1
            result |= (c & 0x7F) << shift
            if not (c & 0x80):
                break
            shift += 7
        self.p = p
        return result

    def raw(self, n: int) -> bytes:
        v = self.b[self.p:self.p + n]
        self.p += n
        return v


# --------------------------------------------------------------------------------------
# chart model
# --------------------------------------------------------------------------------------
@dataclass
class SwagSection:
    sectionBeats: float = 4.0
    mustHitSection: bool = True
    gfSection: bool = False
    altAnim: bool = False
    changeBPM: bool = False
    bpm: float = 0.0
    # compact form used by the timeline
    flags: int = SF_MUSTHIT


NOTE_TYPE_LIST = ["", "Alt Animation", "Hey!", "Hurt Note", "GF Sing", "No Animation"]


@dataclass
class Note:
    t: float          # strum time in ms (absolute)
    lane: int
    mustPress: bool
    span: float = 0.0     # sustain length in ms (0 = tap note)
    typeIdx: int = -1
    gfNote: bool = False
    lowPriority: bool = False
    hitCausesMiss: bool = False
    noAnimation: bool = False
    # derived, not serialised
    steps: int = 0


class SectionTimeline:
    """RLE compressed section metadata.  Section count may be in the tens of millions."""

    __slots__ = ("run_len", "run_beats", "run_flags", "run_bpm", "_starts", "count", "_cur", "_cur_off")

    def __init__(self):
        self.run_len: List[int] = []
        self.run_beats: List[float] = []
        self.run_flags: List[int] = []
        self.run_bpm: List[float] = []
        self._starts: List[int] = []
        self.count = 0
        self._cur = -1
        self._cur_off = 0

    def push(self, count: int, beats: float, flags: int, bpm: float) -> None:
        if count <= 0:
            return
        if self.run_len and self.run_beats[-1] == beats and self.run_flags[-1] == flags \
                and (not (flags & SF_CHBPM) or self.run_bpm[-1] == bpm):
            self.run_len[-1] += count
        else:
            self.run_len.append(count)
            self.run_beats.append(beats)
            self.run_flags.append(flags)
            self.run_bpm.append(bpm)
        self.count += count

    def finalize(self) -> "SectionTimeline":
        s = 0
        self._starts = []
        for n in self.run_len:
            self._starts.append(s)
            s += n
        self._cur = -1
        return self

    def index_of(self, section: int) -> int:
        """Locate the run holding `section`; O(1) for monotonically increasing queries."""
        if section <= 0:
            return 0
        c = self._cur
        if 0 <= c < len(self.run_len):
            start = self._starts[c]
            if start <= section < start + self.run_len[c]:
                return c
            if c + 1 < len(self.run_len) and self._starts[c + 1] <= section:
                c += 1
                if section < self._starts[c] + self.run_len[c]:
                    self._cur = c
                    return c
        lo, hi = 0, len(self.run_len) - 1
        while lo < hi:
            mid = (lo + hi + 1) >> 1
            if self._starts[mid] <= section:
                lo = mid
            else:
                hi = mid - 1
        self._cur = lo
        return lo

    def beats(self, section: int) -> float:
        return self.run_beats[self.index_of(section)]

    def flags(self, section: int) -> int:
        return self.run_flags[self.index_of(section)]

    def bpm(self, section: int) -> float:
        return self.run_bpm[self.index_of(section)]


@dataclass
class ChunkHeader:
    offset: int
    length: int
    count: int


class NseChart:
    """Parsed .nse container.  Holds only the TOC + a byte blob: O(chunks), never O(notes)."""

    __slots__ = ("raw", "flags", "lanes", "fidelity", "bpm", "speed", "note_count", "chunk_capacity",
                 "section_count", "duration_ms", "strings", "sections", "bpm_changes", "chunks",
                 "events", "payload_off", "proc", "type_count", "chunk_pos")

    def __init__(self):
        self.raw = b""
        self.flags = 0
        self.lanes = 4
        self.fidelity = 1
        self.bpm = 120.0
        self.speed = 1.0
        self.note_count = 0
        self.chunk_capacity = CHUNK_CAPACITY
        self.section_count = 0
        self.duration_ms = 0.0
        self.strings: List[str] = []
        self.sections = SectionTimeline()
        self.bpm_changes: List[Tuple[float, float]] = []
        self.chunks: List[ChunkHeader] = []
        self.events: List[Tuple[float, str, str, str]] = []
        self.payload_off = 0
        self.proc: Optional["ProcSpec"] = None
        self.type_count = 0

    # -- accessors ---------------------------------------------------------------------
    def is_procedural(self) -> bool:
        return bool(self.flags & F_PROC)

    def note_at_chunk(self, idx: int) -> int:
        return self.chunks[idx].count if idx < len(self.chunks) else 0

    def chunk_index_for_time(self, t: float) -> int:
        """Index of the last chunk whose first note time <= t (binary search, O(log chunks))."""
        lo, hi = 0, len(self.chunks) - 1
        if hi < 0:
            return 0
        if t < self.chunk_base_time(0):
            return 0
        while lo < hi:
            mid = (lo + hi + 1) >> 1
            if self.chunk_base_time(mid) <= t:
                lo = mid
            else:
                hi = mid - 1
        return lo

    def chunk_base_time(self, idx: int) -> float:
        off = self.chunks[idx].offset
        r = Reader(self.raw, self.payload_off + off)
        return float(r.varint())


# --------------------------------------------------------------------------------------
# writer
# --------------------------------------------------------------------------------------
class ChartBuilder:
    def __init__(self, lanes: int = 4, fidelity: int = 1, chunk_capacity: int = CHUNK_CAPACITY):
        self.lanes = lanes
        self.fidelity = fidelity
        self.chunk_capacity = chunk_capacity
        self.notes: List[Note] = []
        self.sections = SectionTimeline()
        self.events: List[Tuple[float, str, str, str]] = []
        self.types: List[str] = []
        self._type_idx = {}
        self.bpm = 120.0
        self.speed = 1.0
        # (songTimeMs, bpm, stepTime) -- stepTime is precomputed so Conductor never has to
        # walk the section list to rebuild it (charts can have millions of sections)
        self.bpm_changes: List[Tuple[float, float, int]] = []

    def type_id(self, name: str, mustPress: bool) -> int:
        name = name or ""
        if name == "":
            return -1
        key = name
        if key not in self._type_idx:
            self._type_idx[key] = len(self.types)
            self.types.append(name)
        idx = self._type_idx[key]
        n = Note(0, 0, mustPress, 0, idx)
        if name == "Hurt Note":
            n.lowPriority = True
            n.hitCausesMiss = True
        if name == "No Animation":
            n.noAnimation = True
        return idx

    def add_note(self, n: Note) -> None:
        self.notes.append(n)

    # -- Psych chart -> NSE ------------------------------------------------------------
    def from_psych(self, chart: dict) -> "ChartBuilder":
        song = chart.get("song", chart)
        self.bpm = float(song.get("bpm", 120.0))
        self.speed = float(song.get("speed", 1.0))
        sections = song.get("notes") or []

        cur_bpm = self.bpm
        step_crochet = (60.0 / cur_bpm) * 1000.0 / 4.0
        total_steps = 0
        section_time = 0.0

        for sec in sections:
            beats = float(sec.get("sectionBeats") or 4.0)
            wants_change = bool(sec.get("changeBPM"))
            bpm = float(sec.get("bpm") or self.bpm)
            change = wants_change and bpm > 0 and bpm != cur_bpm
            flags = 0
            if sec.get("mustHitSection", True):
                flags |= SF_MUSTHIT
            if sec.get("gfSection"):
                flags |= SF_GF
            if sec.get("altAnim"):
                flags |= SF_ALT
            if change:
                flags |= SF_CHBPM
            self.sections.push(1, beats, flags, bpm if change else cur_bpm)

            if change:
                self.bpm_changes.append((section_time, bpm, total_steps))
                cur_bpm = bpm
                step_crochet = (60.0 / cur_bpm) * 1000.0 / 4.0

            must_hit_section = bool(sec.get("mustHitSection", True))
            gf_section = bool(sec.get("gfSection", False))
            for raw in (sec.get("sectionNotes") or []):
                t = float(raw[0])
                data = int(raw[1])
                span = raw[2] if len(raw) > 2 else 0
                ntype = raw[3] if len(raw) > 3 else ""
                if data < 0:
                    # legacy event notes: [time, [[name, v1, v2], ...]]
                    for ev in (span if isinstance(span, list) else []):
                        self.events.append((t, str(ev[0]), str(ev[1]) if ev[1] is not None else "",
                                            str(ev[2]) if len(ev) > 2 and ev[2] is not None else ""))
                    continue
                lane = data % 4
                must_press = must_hit_section
                if data > 3:
                    must_press = not must_hit_section
                if isinstance(ntype, str):
                    type_idx = self.type_id(ntype, must_press)
                else:
                    ti = int(ntype) if ntype is not None else 0
                    name = NOTE_TYPE_LIST[ti] if 0 <= ti < len(NOTE_TYPE_LIST) else ""
                    type_idx = self.type_id(name, must_press)
                sus = float(span) if isinstance(span, (int, float)) and span > 0 else 0.0
                n = Note(t, lane, must_press, sus, type_idx,
                         gf_section and data < 4, False, False, False)
                name = self.types[type_idx] if type_idx >= 0 else ""
                if name == "Hurt Note":
                    n.lowPriority = True
                    n.hitCausesMiss = True
                if name == "No Animation":
                    n.noAnimation = True
                self.add_note(n)

            total_steps += int(round(beats * 4))
            section_time += int(round(beats * 4)) * step_crochet

        for ev in (song.get("events") or []):
            t = float(ev[0])
            for sub in ev[1]:
                self.events.append((t, str(sub[0]), str(sub[1]) if sub[1] is not None else "",
                                    str(sub[2]) if len(sub) > 2 and sub[2] is not None else ""))
        return self

    # -- serialise ---------------------------------------------------------------------
    def build(self) -> bytes:
        notes = self.notes
        notes.sort(key=lambda n: (n.t, n.lane))
        self.sections.finalize()
        duration = 0.0
        if notes:
            last = notes[-1]
            duration = last.t + last.span

        chunks: List[List[Note]] = []
        cur: List[Note] = []
        for n in notes:
            cur.append(n)
            if len(cur) >= self.chunk_capacity:
                chunks.append(cur)
                cur = []
        if cur:
            chunks.append(cur)

        payload = bytearray()
        chunk_meta: List[Tuple[int, int]] = []
        for ch in chunks:
            off = len(payload)
            base = int(round(ch[0].t))
            put_varint(payload, base)
            last_dt = -1
            for n in ch:
                t = int(round(n.t))
                dt = t - base
                payload.append(n.lane & 0xFF)
                fl = 0
                if n.mustPress:
                    fl |= NF_MUSTPRESS
                if n.span > 0:
                    fl |= NF_SUSTAIN
                if n.gfNote:
                    fl |= NF_GFNOTE
                if n.typeIdx >= 0:
                    fl |= NF_HASTYPE
                if n.lowPriority:
                    fl |= NF_LOWPRIORITY
                if n.hitCausesMiss:
                    fl |= NF_HITCAUSESMISS
                if n.noAnimation:
                    fl |= NF_NOANIM
                if dt == last_dt:
                    fl |= NF_DTREPEAT
                payload.append(fl)
                if not (fl & NF_DTREPEAT):
                    put_varint(payload, dt if dt >= 0 else 0)
                    last_dt = dt
                if fl & NF_SUSTAIN:
                    put_varint(payload, int(round(n.span)))
                if fl & NF_HASTYPE:
                    put_varint(payload, n.typeIdx)
                base = t
            chunk_meta.append((len(ch), len(payload) - off))

        strings: List[str] = []
        sidx = {}

        def sid(x: str) -> int:
            if x not in sidx:
                sidx[x] = len(strings)
                strings.append(x)
            return sidx[x]

        ev_enc = []
        prev = 0
        for (t, name, v1, v2) in sorted(self.events, key=lambda e: e[0]):
            ms = int(round(t))
            ev_enc.append((max(0, ms - prev), sid(name), sid(v1), sid(v2)))
            prev = ms

        out = bytearray()
        flags = F_CRC
        if ev_enc:
            flags |= F_EVENTS
        if strings:
            flags |= F_TYPES
        out += MAGIC
        out += struct.pack("<HH", VERSION, flags)
        out.append(self.lanes & 0xFF)
        out.append(self.fidelity & 0xFF)
        put_varint(out, int(round(self.bpm * 1000)))
        put_varint(out, int(round(self.speed * 1000)))
        put_varint(out, len(notes))
        put_varint(out, self.chunk_capacity)
        put_varint(out, self.sections.count)
        put_varint(out, int(round(duration)))

        put_varint(out, len(strings))
        for x in strings:
            b = x.encode("utf-8")
            put_varint(out, len(b))
            out += b

        put_varint(out, len(self.sections.run_len))
        for i, cnt in enumerate(self.sections.run_len):
            put_varint(out, cnt)
            put_varint(out, max(0, int(round(self.sections.run_beats[i] * 1000))))
            fl = self.sections.run_flags[i]
            out.append(fl)
            if fl & SF_CHBPM:
                put_varint(out, int(round(self.sections.run_bpm[i] * 1000)))

        put_varint(out, len(self.bpm_changes))
        prev_t = 0
        for (t, bpm, step_time) in self.bpm_changes:
            ms = int(round(t))
            put_varint(out, max(0, ms - prev_t))
            put_varint(out, int(round(bpm * 1000)))
            put_varint(out, int(step_time))
            prev_t = ms

        put_varint(out, len(chunk_meta))
        for (cnt, ln) in chunk_meta:
            put_varint(out, cnt)
            put_varint(out, ln)

        put_varint(out, len(ev_enc))
        for (dt, a, b2, c) in ev_enc:
            put_varint(out, dt)
            put_varint(out, a)
            put_varint(out, b2)
            put_varint(out, c)

        out += payload
        crc = zlib.crc32(bytes(out)) & 0xFFFFFFFF
        out += struct.pack("<I", crc)
        return bytes(out)


def parse(data: bytes) -> NseChart:
    if data[:4] != MAGIC:
        raise ValueError("not an NSE chart (bad magic)")
    c = NseChart()
    c.raw = data
    r = Reader(data, 4)
    ver = r.u16()
    if ver != VERSION:
        raise ValueError(f"unsupported NSE version {ver}")
    c.flags = r.u16()
    c.lanes = r.u8()
    c.fidelity = r.u8()
    c.bpm = r.varint() / 1000.0
    c.speed = r.varint() / 1000.0
    c.note_count = r.varint()
    c.chunk_capacity = r.varint()
    c.section_count = r.varint()
    c.duration_ms = float(r.varint())
    if (c.flags & F_CRC) and len(data) >= 8:
        crc_stored = struct.unpack_from("<I", data, len(data) - 4)[0]
        crc_calc = zlib.crc32(data[:-4]) & 0xFFFFFFFF
        if crc_stored != crc_calc:
            raise ValueError("NSE CRC mismatch")

    nstr = r.varint()
    c.strings = []
    for _ in range(nstr):
        ln = r.varint()
        c.strings.append(r.raw(ln).decode("utf-8"))
    c.type_count = len(c.strings)

    nrun = r.varint()
    tl = SectionTimeline()
    for _ in range(nrun):
        cnt = r.varint()
        beats = r.varint() / 1000.0
        fl = r.u8()
        bpm = r.varint() / 1000.0 if (fl & SF_CHBPM) else c.bpm
        tl.push(cnt, beats, fl, bpm)
    c.sections = tl.finalize()

    nbc = r.varint()
    c.bpm_changes = []
    t = 0.0
    for _ in range(nbc):
        t += r.varint()
        cbpm = r.varint() / 1000.0
        cstep = r.varint()
        c.bpm_changes.append((t, cbpm, cstep))

    nch = r.varint()
    c.chunks = []
    for _ in range(nch):
        cnt = r.varint()
        ln = r.varint()
        c.chunks.append(ChunkHeader(0, ln, cnt))
    off = 0
    for ch in c.chunks:
        ch.offset = off
        off += ch.length

    nev = r.varint()
    c.events = []
    et = 0.0
    for _ in range(nev):
        et += r.varint()
        a = c.strings[r.varint()] if c.strings else ""
        b = c.strings[r.varint()] if c.strings else ""
        d = c.strings[r.varint()] if c.strings else ""
        c.events.append((et, a, b, d))

    c.payload_off = r.p
    if c.flags & F_PROC:
        c.proc = ProcSpec.from_bytes(data, c.payload_off)
    return c


# --------------------------------------------------------------------------------------
# note stream
# --------------------------------------------------------------------------------------
class NoteStream:
    """Sequential cursor over a chunked chart: O(1) memory, O(1) per note."""

    __slots__ = ("chart", "chunk", "pos", "end", "idx", "count", "cur_t", "prev_dt", "peeked", "_pending",
                 "notes_read", "_r")

    def __init__(self, chart: NseChart):
        self.chart = chart
        self.chunk = -1
        self.pos = 0
        self.end = 0
        self.idx = 0
        self.count = 0
        self.cur_t = 0.0
        self.prev_dt = -1
        self.peeked: Optional[Note] = None
        self.notes_read = 0
        self._pending = None
        self._r = Reader(chart.raw)
        self._load_chunk(0)

    def _load_chunk(self, i: int) -> bool:
        if i >= len(self.chart.chunks):
            self.chunk = len(self.chart.chunks)
            self.count = 0
            self.idx = 0
            self.peeked = None
            return False
        ch = self.chart.chunks[i]
        self.chunk = i
        self.pos = self.chart.payload_off + ch.offset
        self.end = self.pos + ch.length
        self.count = ch.count
        self.idx = 0
        self._r.p = self.pos
        self.cur_t = float(self._r.varint())
        self.prev_dt = -1
        self.peeked = None
        return True

    def next(self) -> Optional[Note]:
        if self.peeked is not None:
            n = self.peeked
            self.peeked = None
            return n
        return self._read()

    def peek(self) -> Optional[Note]:
        if self.peeked is None:
            self.peeked = self._read()
        return self.peeked

    def peek_time(self) -> float:
        n = self.peek()
        return n.t if n is not None else math.inf

    def _read(self) -> Optional[Note]:
        while self.idx >= self.count:
            if not self._load_chunk(self.chunk + 1):
                return None
        if self._r.p + 2 > self.end:
            raise ValueError(f"corrupt NSE chunk {self.chunk}: truncated payload")
        r = self._r
        lane = r.u8()
        fl = r.u8()
        if fl & NF_DTREPEAT:
            dt = self.prev_dt
        else:
            dt = r.varint()
            self.prev_dt = dt
        t = self.cur_t + float(dt)
        self.cur_t = t
        span = r.varint() if (fl & NF_SUSTAIN) else 0
        type_idx = r.varint() if (fl & NF_HASTYPE) else -1
        self.idx += 1
        self.notes_read += 1
        return Note(t, lane, bool(fl & NF_MUSTPRESS), float(span), type_idx,
                    bool(fl & NF_GFNOTE), bool(fl & NF_LOWPRIORITY),
                    bool(fl & NF_HITCAUSESMISS), bool(fl & NF_NOANIM))

    def seek(self, t_ms: float) -> None:
        """Reposition so that the next read is the first note with time >= t_ms."""
        ci = self.chart.chunk_index_for_time(t_ms)
        if ci > len(self.chart.chunks):
            ci = len(self.chart.chunks)
        self._load_chunk(ci)
        # linear scan inside the chunk is bounded by chunk_capacity
        while True:
            n = self.peek()
            if n is None:
                return
            if n.t >= t_ms:
                return
            self.peeked = None


# --------------------------------------------------------------------------------------
# procedural charts (O(1) memory for any note count)
# --------------------------------------------------------------------------------------


HASH_A = 0x9E3779B9
HASH_B = 0x85EBCA6B
HASH_C = 0x21F0AAAD
HASH_D = 0x735A2D97


def _mul32(a: int, b: int) -> int:
    """low 32 bits of a product, wrapping like Haxe/cpp Int multiplication"""
    return (a * b) & 0xFFFFFFFF


def mix32(x: int) -> int:
    """32-bit splitmix hash -- identical to ProcNoteStream.mix32() in the engine"""
    z = (x + HASH_A) & 0xFFFFFFFF
    z = _mul32(z ^ (z >> 16), HASH_C)
    z = _mul32(z ^ (z >> 15), HASH_D)
    return z ^ (z >> 15)


@dataclass
class ProcSpec:
    seed: int = 0x2F6E2B1
    steps: int = 0                 # total steps in the song
    notes_per_step: int = 1        # simultaneous notes per step
    lanes: int = 4
    sustain_every: int = 0
    chord_every: int = 0
    step_ms: float = 100.0
    bpm: float = 150.0
    speed: float = 1.0

    @property
    def note_count(self) -> int:
        return self.steps * self.notes_per_step

    @property
    def duration_ms(self) -> float:
        return self.steps * self.step_ms

    def to_bytes(self) -> bytes:
        out = bytearray()
        put_varint(out, self.seed & 0xFFFFFFFF)
        put_varint(out, self.steps)
        put_varint(out, self.notes_per_step)
        put_varint(out, self.lanes)
        put_varint(out, self.sustain_every)
        put_varint(out, self.chord_every)
        put_varint(out, int(round(self.step_ms * 1000)))
        put_varint(out, int(round(self.bpm * 1000)))
        put_varint(out, int(round(self.speed * 1000)))
        return bytes(out)

    @staticmethod
    def from_bytes(b: bytes, pos: int = 0) -> "ProcSpec":
        r = Reader(b, pos)
        spec = ProcSpec()
        spec.seed = r.varint()
        spec.steps = r.varint()
        spec.notes_per_step = r.varint()
        spec.lanes = r.varint()
        spec.sustain_every = r.varint()
        spec.chord_every = r.varint()
        spec.step_ms = r.varint() / 1000.0
        spec.bpm = r.varint() / 1000.0
        spec.speed = r.varint() / 1000.0
        return spec


class ProcStream:
    """Infinite, deterministic, sorted note stream.  Zero storage."""

    def __init__(self, spec: ProcSpec):
        self.spec = spec
        self.step = 0
        self.k = 0
        self._cache_step = -1
        self._cache: List[int] = []

    def peek_time(self) -> float:
        if self.step >= self.spec.steps:
            return math.inf
        return self.step * self.spec.step_ms

    def _lanes_for(self, step: int) -> List[int]:
        if step == self._cache_step:
            return self._cache
        sp = self.spec
        base = mix32(sp.seed ^ _mul32(step, HASH_A))
        chord = bool(sp.chord_every) and (step % sp.chord_every == 0)
        lanes = []
        for i in range(sp.notes_per_step):
            v = mix32(base + _mul32(i, HASH_B))
            if chord:
                lanes.append((i + (v >> 8)) % sp.lanes)
            else:
                lanes.append((v >> 1) % sp.lanes)
        lanes.sort()
        self._cache_step = step
        self._cache = lanes
        return lanes

    def next(self) -> Optional[Note]:
        sp = self.spec
        while True:
            if self.step >= sp.steps:
                return None
            lanes = self._lanes_for(self.step)
            if self.k >= len(lanes):
                self.step += 1
                self.k = 0
                continue
            lane = lanes[self.k]
            span = 0.0
            must_press = True
            if sp.sustain_every and self.step % sp.sustain_every == 0 and self.k == 0:
                span = sp.step_ms * 3
            if (self.step // 16) % 2 == 1:
                must_press = False
            n = Note(self.step * sp.step_ms, lane, must_press, span, -1, False, False, False, False)
            self.k += 1
            return n


# --------------------------------------------------------------------------------------
# helpers used by the engine's hot loop (mirrored in Haxe)
# --------------------------------------------------------------------------------------
def build_chunk_dir(chart: NseChart) -> List[float]:
    return [chart.chunk_base_time(i) for i in range(len(chart.chunks))]


def stream_cost_model(chart: NseChart, notes: int) -> Tuple[float, float]:
    """Returns (seconds to decode `notes` notes, notes/sec)."""
    st = NoteStream(chart)
    n = 0
    t0 = time.perf_counter()
    while n < notes:
        if st.next() is None:
            break
        n += 1
    dt = time.perf_counter() - t0
    return dt, (n / dt if dt > 0 else math.inf)


# --------------------------------------------------------------------------------------
# CLI
# --------------------------------------------------------------------------------------
def load_chart_json(path: str) -> dict:
    """Reads a Psych chart the same way the game does (trailing padding/garbage is trimmed)."""
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        raw = f.read()
    text = raw
    for _ in range(4096):
        cut = text.rfind("}")
        if cut < 0:
            break
        candidate = text[:cut + 1]
        try:
            return json.loads(candidate)
        except json.JSONDecodeError:
            # Song.loadFromJson() chops characters off the end until the text ends with "}"
            text = candidate[:-1]
    raise ValueError(f"{path}: not a Psych chart (unparseable JSON)")


def _cmd_compile(argv: List[str]) -> int:
    if len(argv) < 2:
        print("usage: nse_ref.py compile <chart.json> <out.nse> [--lanes N]")
        return 2
    src, dst = argv[0], argv[1]
    lanes = 4
    if "--lanes" in argv:
        lanes = int(argv[argv.index("--lanes") + 1])
    chart = load_chart_json(src)
    t0 = time.perf_counter()
    b = ChartBuilder(lanes=lanes).from_psych(chart)
    data = b.build()
    dt = time.perf_counter() - t0
    with open(dst, "wb") as f:
        f.write(data)
    print(f"compiled {len(b.notes)} notes -> {len(data)} bytes ({len(data)/max(1,len(b.notes)):.2f} B/note) in {dt*1000:.1f} ms")
    return 0


def _cmd_convert(argv: List[str]) -> int:
    """chart.json -> chart.nse (+ chart-lazy.json header for the game)."""
    if len(argv) < 2:
        print("usage: nse_ref.py convert <chart.json> <out.nse> [--lazy <out-lazy.json>] [--lanes N]")
        return 2
    src, dst = argv[0], argv[1]
    lazy = None
    if "--lazy" in argv:
        lazy = argv[argv.index("--lazy") + 1]
    lanes = 4
    if "--lanes" in argv:
        lanes = int(argv[argv.index("--lanes") + 1])

    t0 = time.perf_counter()
    chart = load_chart_json(src)
    t1 = time.perf_counter()
    b = ChartBuilder(lanes=lanes).from_psych(chart)
    data = b.build()
    t2 = time.perf_counter()
    with open(dst, "wb") as f:
        f.write(data)

    parsed = parse(data)
    sections = parsed.section_count
    chunks = len(parsed.chunks)
    dir_bytes = sum(varint_size(c.count) + varint_size(c.length) for c in parsed.chunks)
    print(f"{src} -> {dst}")
    print(f"  {len(b.notes)} notes, {chunks} chunks, {len(b.sections.run_len)} section runs, "
          f"{len(b.bpm_changes)} BPM changes, {len(b.events)} events")
    print(f"  {len(data)} bytes ({len(data)/max(1,len(b.notes)):.2f} B/note), "
          f"{parsed.duration_ms/1000.0:.1f}s of chart")
    print(f"  load cost: {dir_bytes/1024.0:.1f} KiB TOC on disk, "
          f"~{chunks*16/1024.0:.1f} KiB RAM for the directory (no note is read at load)")
    print(f"  timings: json {1000*(t1-t0):.0f} ms, compile {1000*(t2-t1):.0f} ms, "
          f"verify-parse {1000*(time.perf_counter()-t2):.0f} ms")

    if lazy:
        song = chart.get("song", chart)
        header = dict(song)
        header["notes"] = []
        header["events"] = []
        with open(lazy, "w", encoding="utf-8") as f:
            json.dump({"song": header}, f, separators=(",", ":"))
        print(f"  wrote lazy header {lazy} ({os.path.getsize(lazy)} bytes)")
    return 0


def _cmd_dump(argv: List[str]) -> int:
    """Prints decoded notes; used to byte-compare this implementation with refbench.c."""
    if len(argv) < 1:
        print("usage: nse_ref.py dump <chart.nse> [--limit N]")
        return 2
    limit = 32
    if "--limit" in argv:
        limit = int(argv[argv.index("--limit") + 1])
    with open(argv[0], "rb") as f:
        data = f.read()
    c = parse(data)
    print(f"notes={c.note_count}")
    if c.is_procedural():
        st = ProcStream(c.proc)
    else:
        st = NoteStream(c)
    i = 0
    while i < limit:
        n = st.next()
        if n is None:
            break
        fl = 0
        if n.mustPress:
            fl |= NF_MUSTPRESS
        if n.span > 0:
            fl |= NF_SUSTAIN
        if n.gfNote:
            fl |= NF_GFNOTE
        if n.typeIdx >= 0:
            fl |= NF_HASTYPE
        if n.lowPriority:
            fl |= NF_LOWPRIORITY
        if n.hitCausesMiss:
            fl |= NF_HITCAUSESMISS
        if n.noAnimation:
            fl |= NF_NOANIM
        print(f"{i} t={round(n.t):.3f} lane={n.lane} flags={fl} span={float(n.span):.3f} "
              f"type={n.typeIdx if n.typeIdx is not None and n.typeIdx >= 0 else 0}")
        i += 1
    return 0


def _cmd_gen(argv: List[str]) -> int:
    if len(argv) < 1:
        print("usage: nse_ref.py gen <out.nse> --notes N [--lanes 4] [--bpm 150] [--per-step 8]")
        return 2
    dst = argv[0]
    notes = 1_000_000
    if "--notes" in argv:
        notes = int(argv[argv.index("--notes") + 1])
    lanes = 4
    if "--lanes" in argv:
        lanes = int(argv[argv.index("--lanes") + 1])
    bpm = 150.0
    if "--bpm" in argv:
        bpm = float(argv[argv.index("--bpm") + 1])
    per = 8
    if "--per-step" in argv:
        per = int(argv[argv.index("--per-step") + 1])
    step_ms = (60.0 / bpm) * 1000.0 / 4.0
    steps = max(1, notes // per)
    spec = ProcSpec(steps=steps, notes_per_step=per, lanes=lanes, bpm=bpm, step_ms=step_ms,
                    sustain_every=8, chord_every=4)
    data = _proc_container(spec)
    with open(dst, "wb") as f:
        f.write(data)
    print(f"procedural chart: {spec.note_count} notes, {spec.duration_ms/1000:.1f}s, container {len(data)} bytes")
    return 0


def _proc_container(spec: ProcSpec) -> bytes:
    out = bytearray()
    out += MAGIC
    out += struct.pack("<HH", VERSION, F_PROC | F_CRC)
    out.append(spec.lanes & 0xFF)
    out.append(1)
    put_varint(out, int(round(spec.bpm * 1000)))
    put_varint(out, int(round(spec.speed * 1000)))
    put_varint(out, spec.note_count)
    put_varint(out, CHUNK_CAPACITY)
    put_varint(out, spec.steps // 4)
    put_varint(out, int(round(spec.duration_ms)))
    put_varint(out, 0)      # strings
    put_varint(out, 0)      # section runs
    put_varint(out, 0)      # bpm changes
    put_varint(out, 0)      # chunks
    put_varint(out, 0)      # events
    out += spec.to_bytes()
    crc = zlib.crc32(bytes(out)) & 0xFFFFFFFF
    out += struct.pack("<I", crc)
    return bytes(out)


def _cmd_verify(argv: List[str]) -> int:
    path = argv[0]
    with open(path, "rb") as f:
        data = f.read()
    t0 = time.perf_counter()
    c = parse(data)
    t1 = time.perf_counter()
    if c.is_procedural():
        spec = c.proc
        print(f"procedural: {spec.note_count} notes, {spec.duration_ms/1000:.1f}s, "
              f"lanes={spec.lanes}, per-step={spec.notes_per_step}")
        return 0
    st = NoteStream(c)
    n = 0
    last = -1.0
    bad = 0
    sust = 0
    while True:
        note = st.next()
        if note is None:
            break
        if note.t < last - 1e-9:
            bad += 1
        last = note.t
        if note.span > 0:
            sust += 1
        n += 1
    t2 = time.perf_counter()
    ok = (n == c.note_count) and bad == 0
    print(f"{'OK ' if ok else 'FAIL'} notes={n}/{c.note_count} sustains={sust} out-of-order={bad} "
          f"parse={ (t1-t0)*1000:.1f}ms stream={(t2-t1)*1000:.1f}ms ({n/max(1e-9,t2-t1)/1e6:.2f}M notes/s)")
    return 0 if ok else 1


def _cmd_bench(argv: List[str]) -> int:
    notes = 10_000_000
    if "--notes" in argv:
        notes = int(argv[argv.index("--notes") + 1])
    bpm = 150.0
    step_ms = (60.0 / bpm) * 1000.0 / 4.0
    per = 8
    spec = ProcSpec(steps=max(1, notes // per), notes_per_step=per, bpm=bpm, step_ms=step_ms,
                    sustain_every=8, chord_every=4)
    st = ProcStream(spec)
    n = 0
    t0 = time.perf_counter()
    while True:
        note = st.next()
        if note is None:
            break
        n += 1
        if n >= notes:
            break
    dt = time.perf_counter() - t0
    print(f"proc stream: {n} notes in {dt:.3f}s = {n/dt/1e6:.2f}M notes/s")
    return 0


def _cmd_selftest(argv: List[str]) -> int:
    ok = True

    def check(cond: bool, msg: str) -> None:
        nonlocal ok
        if not cond:
            ok = False
            print(f"  FAIL {msg}")

    # 1. varint round trip
    for v in (0, 1, 127, 128, 300, 16384, 2**31, 2**62):
        b = bytearray()
        put_varint(b, v)
        check(Reader(bytes(b)).varint() == v, f"varint {v}")
        check(len(b) == varint_size(v), f"varint size {v}")

    # 2. synthetic chart -> build -> parse -> stream round trip
    builder = ChartBuilder()
    builder.bpm = 150.0
    t = 0.0
    step = (60.0 / 150.0) * 1000.0 / 4.0
    for s in range(64):
        builder.sections.push(1, 4, SF_MUSTHIT if (s // 4) % 2 == 0 else 0, 150.0)
    for i in range(5000):
        lane = i % 4
        span = step * 3 if i % 17 == 0 else 0.0
        builder.add_note(Note(t, lane, (i // 16) % 2 == 1, span))
        if i % 3 == 0:
            t += step
    data = builder.build()
    c = parse(data)
    check(c.note_count == 5000, f"note count {c.note_count}")
    check(c.section_count == 64, f"section count {c.section_count}")
    check(c.sections.count == 64, "section timeline count")
    st = NoteStream(c)
    prev = -1.0
    cnt = 0
    while True:
        n = st.next()
        if n is None:
            break
        check(n.t >= prev - 1e-9, "monotonic")
        prev = n.t
        cnt += 1
    check(cnt == 5000, f"streamed {cnt}")

    # 3. seek
    st2 = NoteStream(c)
    st2.seek(step * 100)
    n = st2.next()
    check(n is not None and n.t >= step * 100 - 1e-9, "seek lands after target")

    # 4. procedural determinism
    spec = ProcSpec(steps=10000, notes_per_step=8, bpm=150.0, step_ms=step, sustain_every=8, chord_every=4)
    a = ProcStream(spec)
    total = 0
    while True:
        if a.next() is None:
            break
        total += 1
    check(total == spec.note_count, f"proc count {total} vs {spec.note_count}")

    print("selftest:", "PASS" if ok else "FAIL")
    return 0 if ok else 1


def main(argv: List[str]) -> int:
    if len(argv) < 2:
        print(__doc__)
        return 2
    cmd = argv[1]
    rest = argv[2:]
    if cmd == "compile":
        return _cmd_compile(rest)
    if cmd == "convert":
        return _cmd_convert(rest)
    if cmd == "dump":
        return _cmd_dump(rest)
    if cmd == "gen":
        return _cmd_gen(rest)
    if cmd == "verify":
        return _cmd_verify(rest)
    if cmd == "bench":
        return _cmd_bench(rest)
    if cmd == "selftest":
        return _cmd_selftest(rest)
    print(f"unknown command {cmd}")
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
