/*
 * refbench.c -- reference benchmark for the Note Stream Engine (NSE) used by
 * Psych Engine 0.6.3 + NSE (source/nse/*.hx).
 *
 * This file re-implements, in C, exactly the data structures and hot loops of the Haxe code
 * in source/nse/ so the numbers are a faithful model of the engine's behaviour:
 *
 *   1. `nse`    : procedural chart (O(1) memory) + bounded live window + per-frame note math.
 *   2. `file`   : reads a real .nse chart from disk with a fixed-size window (O(1) RSS).
 *   3. `pump`   : decode+stage throughput ceiling (notes/s).
 *   4. `sweep`  : per-frame cost as a function of simultaneously live notes.
 *   5. `write`  : writes a .nse chart (also used to validate the format at scale).
 *   6. `naive`  : what Psych 0.6.3 does today -- one Haxe object + FlxSprite per note and per
 *                 sustain segment, `unspawnNotes.sort()` over the whole chart and
 *                 `Array.splice()`/`insert(0)` (O(N) memmove) for every spawned note.
 *
 * Container layout (version 1, see docs/NSE_FORMAT.md):
 *   magic 'NSE1', u16 version, u16 flags, u8 lanes, u8 fidelity,
 *   varint bpmMilli, speedMilli, noteCount, chunkCapacity, sectionCount, durationMs,
 *   varint stringCount + strings, varint runCount + section runs,
 *   varint bpmChangeCount + (deltaMs, bpmMilli, stepTime),
 *   varint chunkCount + (noteCount, byteLen) per chunk, varint eventCount + events,
 *   payload: varint chunkBaseTimeMs + per note {u8 lane, u8 flags, [varint dtMs], [varint spanMs],
 *   [varint typeIdx]}, finally u32 crc32 when F_CRC is set.
 *
 * build:  gcc -O2 -march=native -o refbench refbench.c -lm
 * usage:  ./refbench nse   --notes 1000000000 --per-step 8 --live-cap 4096
 *         ./refbench file  --file chart.nse --frames 3600
 *         ./refbench pump  --notes 100000000 --per-step 8
 *         ./refbench sweep --per-step 32 --step-ms 10 --live-cap 131072
 *         ./refbench naive --notes 1000000000 --mem-budget-mb 600
 *         ./refbench write --notes 1000000000 --out /tmp/big.nse
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <math.h>
#include <time.h>

/* ------------------------------------------------------------------ note flags (must match Nse.hx) */
#define NF_MUSTPRESS     (1u << 0)
#define NF_SUSTAIN       (1u << 1)
#define NF_GFNOTE        (1u << 2)
#define NF_HASTYPE       (1u << 3)
#define NF_LOWPRIORITY   (1u << 4)
#define NF_HITCAUSESMISS (1u << 5)
#define NF_NOANIM        (1u << 6)
#define NF_DTREPEAT      (1u << 7)

/* ------------------------------------------------------------------ util */
static double now_s(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec + (double)ts.tv_nsec * 1e-9;
}

static long rss_kb(void) {
    FILE *f = fopen("/proc/self/status", "r");
    if (!f) return -1;
    char line[256];
    long kb = -1;
    while (fgets(line, sizeof line, f)) {
        if (!strncmp(line, "VmRSS:", 6)) { kb = atol(line + 6); break; }
    }
    fclose(f);
    return kb;
}

static void *xmalloc(size_t n) {
    void *p = malloc(n ? n : 1);
    if (!p) {
        fprintf(stderr, "  !! out of memory allocating %.1f MiB\n", (double)n / 1048576.0);
        exit(3);
    }
    return p;
}

static size_t varint_len(uint64_t v) { size_t n = 1; while (v >>= 7) n++; return n; }

/* ------------------------------------------------------------------ PRNG (identical to ProcChart.hx) */
#define HASH_A 0x9E3779B9u
#define HASH_B 0x85EBCA6Bu
#define HASH_C 0x21F0AAADu
#define HASH_D 0x735A2D97u

static inline uint32_t mul32(uint32_t a, uint32_t b) { return a * b; }

static inline uint32_t mix32(uint32_t x) {
    uint32_t z = x + HASH_A;
    z = mul32(z ^ (z >> 16), HASH_C);
    z = mul32(z ^ (z >> 15), HASH_D);
    return z ^ (z >> 15);
}

/* ------------------------------------------------------------------ note record (10 bytes, SoA friendly) */
typedef struct {
    float    t;      /* strum time, ms                    */
    float    span;   /* sustain length ms, 0 = tap        */
    uint8_t  lane;
    uint8_t  flags;
    uint16_t type;
} NseNote;

/* ------------------------------------------------------------------ procedural note source */
typedef struct {
    uint64_t seed;
    int64_t  steps;
    int      per_step;
    int      lanes;
    int      sustain_every;
    int      chord_every;
    double   step_ms;
    int64_t  step;
    int      k;
    int64_t  cached_step;
    uint8_t  cur_lanes[32];
} ProcSrc;

static void proc_init(ProcSrc *s, uint64_t seed, int64_t steps, int per_step, int lanes,
                      int sustain_every, int chord_every, double step_ms) {
    memset(s, 0, sizeof *s);
    if (per_step < 1) per_step = 1;
    if (per_step > 32) per_step = 32;
    if (lanes < 1) lanes = 1;
    s->seed = seed; s->steps = steps; s->per_step = per_step; s->lanes = lanes;
    s->sustain_every = sustain_every; s->chord_every = chord_every; s->step_ms = step_ms;
    s->cached_step = -1;
}

static void proc_build_lanes(ProcSrc *s) {
    uint32_t base = mix32((uint32_t)s->seed ^ mul32((uint32_t)s->step, HASH_A));
    int chord = s->chord_every && (s->step % s->chord_every == 0);
    for (int i = 0; i < s->per_step; i++) {
        uint32_t v = mix32(base + mul32((uint32_t)i, HASH_B));
        int lane = chord ? (int)(((uint32_t)i + (v >> 8)) % (uint32_t)s->lanes)
                         : (int)((v >> 1) % (uint32_t)s->lanes);
        s->cur_lanes[i] = (uint8_t)lane;
    }
    for (int i = 1; i < s->per_step; i++) {
        uint8_t v = s->cur_lanes[i];
        int j = i - 1;
        while (j >= 0 && s->cur_lanes[j] > v) { s->cur_lanes[j + 1] = s->cur_lanes[j]; j--; }
        s->cur_lanes[j + 1] = v;
    }
    s->cached_step = s->step;
}

static inline int proc_peek_time(ProcSrc *s, double *out) {
    if (s->step >= s->steps) return 0;
    *out = (double)s->step * s->step_ms;
    return 1;
}

static inline int proc_next(ProcSrc *s, NseNote *n) {
    while (s->step < s->steps) {
        if (s->cached_step != s->step) proc_build_lanes(s);
        if (s->k >= s->per_step) { s->step++; s->k = 0; continue; }
        n->t = (float)((double)s->step * s->step_ms);
        n->span = (s->sustain_every && (s->step % s->sustain_every) == 0 && s->k == 0)
                  ? (float)(s->step_ms * 3.0) : 0.0f;
        n->lane = s->cur_lanes[s->k];
        n->flags = ((s->step / 16) % 2 == 1) ? 0 : NF_MUSTPRESS;
        n->type = 0;
        s->k++;
        return 1;
    }
    return 0;
}

/* ------------------------------------------------------------------ engine: bounded live window */
typedef struct {
    double   spawn_time, kill_offset, song_pos;
    NseNote *live;
    int      cap, n, head, tail;
    int64_t  spawned, killed, skipped;
    double   move_wall;
} Engine;

static void eng_init(Engine *e, int cap, double spawn_time, double kill_offset) {
    memset(e, 0, sizeof *e);
    e->cap = cap;
    e->live = (NseNote *)xmalloc(sizeof(NseNote) * (size_t)(cap + 2));
    e->spawn_time = spawn_time;
    e->kill_offset = kill_offset;
}

static inline void eng_push(Engine *e, const NseNote *n) {
    e->live[e->tail] = *n;
    e->tail = (e->tail + 1) % (e->cap + 2);
    e->n++;
    e->spawned++;
}

static inline void eng_pop(Engine *e) {
    e->head = (e->head + 1) % (e->cap + 2);
    e->n--;
    e->killed++;
}

/* PlayState.update()'s note loop, reduced to its arithmetic */
static inline void note_move(const NseNote *n, double song_pos, double song_speed, int down) {
    double distance = 0.45 * (song_pos - (double)n->t) * song_speed;
    if (!down) distance = -distance;
    double y2 = distance + 27.5 * ((150.0 / 100) - 1) * (song_speed - 1);
    volatile double sink = (double)n->lane + y2;
    (void)sink;
}

typedef struct {
    int64_t frames, spawned, killed, peak_live;
    double  wall, move_wall, notes_per_s;
    int     exhausted;
} NseRun;

static void report_run(const char *tag, Engine *e, NseRun *r) {
    double dt_ms = 1000.0 / 60.0;
    double chart_ms = (double)r->frames * dt_ms;
    double us_per_frame = r->wall * 1e6 / (double)(r->frames ? r->frames : 1);
    printf("%s frames=%-7lld spawned=%-11lld skipped=%-9lld peak_live=%-6lld wall=%7.3fs\n"
           "  %8.3f us/frame (move %7.3f)  %.3f%% of a 16.67 ms frame   "
           "chart density %.0f notes/s   staging %.2f M notes/s\n",
           tag, (long long)r->frames, (long long)r->spawned, (long long)e->skipped,
           (long long)r->peak_live, r->wall, us_per_frame,
           r->move_wall * 1e6 / (double)(r->frames ? r->frames : 1),
           100.0 * us_per_frame / (1e6 / 60.0),
           (double)r->spawned / (chart_ms / 1000.0), r->notes_per_s / 1e6);
}

static void run_engine_proc(Engine *e, ProcSrc *src, int frames, NseRun *out) {
    memset(out, 0, sizeof *out);
    const double dt_ms = 1000.0 / 60.0;
    const double song_speed = 2.0;
    double t0 = now_s();
    NseNote n;
    int got = 1;
    for (int f = 0; f < frames; f++) {
        e->song_pos += dt_ms;
        out->frames++;
        for (;;) {
            if (!e->n) break;
            NseNote front = e->live[e->head];
            if (e->song_pos <= (double)front.t + e->kill_offset) break;
            eng_pop(e);
        }
        for (;;) {
            double nt;
            if (!proc_peek_time(src, &nt)) { got = 0; break; }
            if (nt - e->song_pos >= e->spawn_time) break;
            if (e->n >= e->cap) { e->skipped++; break; }
            proc_next(src, &n);
            eng_push(e, &n);
        }
        if (e->n > out->peak_live) out->peak_live = e->n;
        double m0 = now_s();
        int idx = e->head;
        for (int i = 0; i < e->n; i++) {
            note_move(&e->live[idx], e->song_pos, song_speed, 0);
            if (++idx >= e->cap + 2) idx = 0;
        }
        out->move_wall += now_s() - m0;
        if (!got && !e->n) { out->exhausted = 1; break; }
    }
    out->wall = now_s() - t0;
    out->spawned = e->spawned;
    out->killed = e->killed;
    out->notes_per_s = (double)e->spawned / (out->wall > 0 ? out->wall : 1e-9);
}

/* ------------------------------------------------------------------ raw pump ceiling */
static void run_procdump(uint64_t notes, int per_step, int lanes, double step_ms, uint32_t seed, int limit) {
    ProcSrc src;
    proc_init(&src, seed, (int64_t)(notes / (uint64_t)per_step), per_step, lanes, 8, 4, step_ms);
    NseNote n;
    int shown = 0;
    printf("notes=%llu\n", (unsigned long long)((int64_t)(notes / (uint64_t)per_step) * per_step));
    if (limit <= 0) limit = 24;
    while (proc_next(&src, &n) && shown < limit) {
        /* same layout as `nse_ref.py dump` so the two can be diffed byte for byte */
        int fl = n.flags & 0x7F;
        if (n.span > 0) fl |= NF_SUSTAIN;
        printf("%d t=%.3f lane=%u flags=%u span=%.3f type=%u\n",
               shown, (double)(int)llround((double)n.t), n.lane, (unsigned)fl, (double)n.span, 0u);
        shown++;
    }
}

static void run_pump(uint64_t notes, int per_step) {
    int64_t steps = (int64_t)(notes / (uint64_t)(per_step ? per_step : 1));
    ProcSrc src;
    proc_init(&src, 0x9E3779B97F4A7C15ULL, steps, per_step, 4, 8, 4, 100.0);
    Engine e;
    eng_init(&e, 8192, 2000.0, 350.0);
    NseNote n;
    double t0 = now_s();
    while (proc_next(&src, &n)) {
        if (e.n >= e.cap) eng_pop(&e);
        eng_push(&e, &n);
        note_move(&n, 0.0, 2.0, 0);
    }
    double dt = now_s() - t0;
    printf("[pump] %llu notes decoded + staged in %.3fs = %.2f M notes/s (%.1f ns/note), RSS %.1f MiB\n",
           (unsigned long long)e.spawned, dt, (double)e.spawned / dt / 1e6,
           dt * 1e9 / (double)e.spawned, (double)rss_kb() / 1024.0);
    free(e.live);
}

static void run_sweep(int per_step, double step_ms, int frames, int max_cap) {
    printf("[sweep] per-step %d, step %.3f ms (%.0f notes/s of song) -- cost vs live note count\n",
           per_step, step_ms, (double)per_step * 1000.0 / step_ms);
    for (int cap = 512; cap <= max_cap; cap *= 4) {
        int64_t steps = (int64_t)frames * 20 + 4096;
        ProcSrc src;
        proc_init(&src, 0x9E3779B97F4A7C15ULL, steps, per_step, 4, 8, 4, step_ms);
        Engine e;
        eng_init(&e, cap, 2000.0, 350.0);
        NseRun r;
        run_engine_proc(&e, &src, frames, &r);
        report_run(" ", &e, &r);
        free(e.live);
    }
}

/* ------------------------------------------------------------------ naive Psych 0.6.3 model */
typedef struct NaiveNote {
    double  strumTime;
    double  sustainLength;
    int     noteData;
    int     noteType;
    void   *sprite;
    void   *animController;
    void   *colorSwap;
    void   *shader;
    void   *tailArray;
    void   *extraDataMap;
    void   *parent;
    void   *prev;
    void   *next;
    uint8_t flags[8];
} NaiveNote;

static double g_bytes_per_note = 1024.0;
static double g_mem_budget_mb = 900.0;

static int cmp_ptr_time(const void *a, const void *b) {
    const NaiveNote *x = *(NaiveNote *const *)a;
    const NaiveNote *y = *(NaiveNote *const *)b;
    if (x->strumTime < y->strumTime) return -1;
    if (x->strumTime > y->strumTime) return 1;
    return 0;
}

static void run_naive(uint64_t notes, int per_step) {
    double step_ms = 100.0;
    int64_t steps = (int64_t)(notes / (uint64_t)per_step);
    printf("\n[naive] Psych 0.6.3: 1 Haxe object + FlxSprite per note AND per sustain segment\n");
    printf("  chart: %llu notes, %d per step   (%.0f bytes/note assumed)\n",
           (unsigned long long)notes, per_step, g_bytes_per_note);

    double t0 = now_s();
    size_t cap = 1 << 20, n = 0;
    NaiveNote **arr = (NaiveNote **)xmalloc(cap * sizeof(NaiveNote *));
    int oom = 0;
    ProcSrc src;
    proc_init(&src, 0x9E3779B97F4A7C15ULL, steps, per_step, 4, 8, 4, step_ms);
    NseNote nn;
    while (proc_next(&src, &nn)) {
        if ((n & 0xFFFF) == 0 && n && ((double)rss_kb() / 1024.0) > g_mem_budget_mb) { oom = 2; break; }
        if (n + (size_t)per_step + 64 >= cap) {
            while (n + (size_t)per_step + 64 >= cap) cap *= 2;
            NaiveNote **narr = (NaiveNote **)realloc(arr, cap * sizeof(NaiveNote *));
            if (!narr) { oom = 1; break; }
            arr = narr;
        }
        NaiveNote *o = (NaiveNote *)malloc((size_t)g_bytes_per_note);
        if (!o) { oom = 1; break; }
        memset(o, 0, sizeof(NaiveNote));
        o->strumTime = (double)nn.t;
        o->sustainLength = (double)nn.span;
        o->noteData = nn.lane;
        arr[n++] = o;
        if (nn.span > 0.0f) {
            int floor_sus = (int)floor((double)nn.span / step_ms);
            for (int s = 0; s <= floor_sus; s++) {
                NaiveNote *so = (NaiveNote *)malloc((size_t)g_bytes_per_note);
                if (!so) { oom = 1; break; }
                memset(so, 0, sizeof(NaiveNote));
                so->strumTime = o->strumTime + step_ms * s;
                so->noteData = o->noteData;
                arr[n++] = so;
            }
        }
        if (oom) break;
    }
    double t_alloc = now_s() - t0;
    double bytes = (double)n * g_bytes_per_note + (double)cap * 8.0;
    printf("  materialised %zu note objects (%.1f MiB) in %.3fs%s\n",
           n, bytes / 1048576.0, t_alloc,
           oom == 2 ? "  [STOPPED: memory budget -- this is where vanilla dies]" :
           oom ? "  [STOPPED: out of memory]" : "");
    printf("  RSS after materialise: %.1f MiB\n", (double)rss_kb() / 1024.0);
    printf("  extrapolated for %llu notes: %.1f GiB  -- vanilla cannot load this\n",
           (unsigned long long)notes, (double)notes * g_bytes_per_note / 1073741824.0);

    if (n > 100000) {
        size_t m = n < 4000000 ? n : 4000000;
        NaiveNote **samp = (NaiveNote **)xmalloc(sizeof(NaiveNote *) * m);
        memcpy(samp, arr, sizeof(NaiveNote *) * m);
        double s0 = now_s();
        qsort(samp, m, sizeof(NaiveNote *), cmp_ptr_time);
        double dt = now_s() - s0;
        double per = dt / (double)m;
        double lg = log((double)n) / log(2.0), lgm = log((double)m) / log(2.0);
        printf("  unspawnNotes.sort(): %.3fs for %zu notes (%.0f ns/note) -> %.1f s for %llu notes\n",
               dt, m, per * 1e9, per * (double)notes * (lg / lgm), (unsigned long long)notes);
        free(samp);
    }
    if (n > 2000) {
        NaiveNote **scratch = (NaiveNote **)xmalloc(sizeof(NaiveNote *) * n);
        memcpy(scratch, arr, sizeof(NaiveNote *) * n);
        size_t iters = n < 4000 ? n / 2 : 4000;
        size_t bytes_per_iter = (n - 1) * sizeof(NaiveNote *);
        double s0 = now_s();
        for (size_t i = 0; i < iters; i++) {
            memmove(scratch, scratch + 1, (n - 1) * sizeof(NaiveNote *));
            scratch[n - 1] = NULL;
        }
        double dt = now_s() - s0;
        double bw = (double)bytes_per_iter * (double)iters / dt;
        double total_bytes = (double)notes * (double)notes / 2.0 * 8.0;
        printf("  spawn memmove bandwidth: %.1f GiB/s at N=%zu\n", bw / 1073741824.0, n);
        printf("  -> total pointer shuffling for %llu notes: %.1f TiB = %.1f days of pure memmove\n",
               (unsigned long long)notes, total_bytes / 1099511627776.0,
               total_bytes / bw / 86400.0);
        free(scratch);
    }
    for (size_t i = 0; i < n; i++) free(arr[i]);
    free(arr);
}

/* ------------------------------------------------------------------ .nse writer */
static void put_varint(FILE *fp, uint64_t v) {
    for (;;) {
        uint8_t b = (uint8_t)(v & 0x7F);
        v >>= 7;
        if (v) { b |= 0x80; fputc(b, fp); } else { fputc(b, fp); return; }
    }
}
static inline void buf_varint(uint8_t *buf, size_t *p, uint64_t v) {
    do {
        uint8_t b = (uint8_t)(v & 0x7F);
        v >>= 7;
        if (v) b |= 0x80;
        buf[(*p)++] = b;
    } while (v);
}

typedef struct { uint32_t count; uint32_t len; } ChunkMeta;

static int write_chart(const char *path, uint64_t notes, int per_step, int chunk_cap) {
    if (per_step > 32) per_step = 32;
    if (per_step < 1) per_step = 1;
    int64_t steps = (int64_t)(notes / (uint64_t)per_step);
    ProcSrc src;
    proc_init(&src, 0x9E3779B97F4A7C15ULL, steps, per_step, 4, 8, 4, 100.0);

    size_t dir_cap = 1024, dir_n = 0;
    ChunkMeta *dir = (ChunkMeta *)xmalloc(sizeof(ChunkMeta) * dir_cap);
    {
        NseNote n;
        uint32_t cnt = 0;
        uint64_t len = 0;
        int64_t prev_dt = -1, base = 0;
        while (proc_next(&src, &n)) {
            int64_t t = (int64_t)llround((double)n.t);
            if (cnt == 0) { base = t; len = varint_len((uint64_t)base); prev_dt = -1; }
            int64_t dt = t - base;
            len += 2;
            if (dt != prev_dt) { len += varint_len((uint64_t)dt); prev_dt = dt; }
            if (n.span > 0) len += varint_len((uint64_t)n.span);
            base = t;
            cnt++;
            if ((int)cnt >= chunk_cap) {
                if (dir_n == dir_cap) { dir_cap *= 2; dir = (ChunkMeta *)realloc(dir, sizeof(ChunkMeta) * dir_cap); }
                dir[dir_n].count = cnt; dir[dir_n].len = (uint32_t)len; dir_n++;
                cnt = 0;
            }
        }
        if (cnt) {
            if (dir_n == dir_cap) { dir_cap *= 2; dir = (ChunkMeta *)realloc(dir, sizeof(ChunkMeta) * dir_cap); }
            dir[dir_n].count = cnt; dir[dir_n].len = (uint32_t)len; dir_n++;
        }
    }

    FILE *fp = fopen(path, "wb");
    if (!fp) { perror(path); return 0; }
    uint64_t note_count = (uint64_t)steps * (uint64_t)per_step;
    fwrite("NSE1", 1, 4, fp);
    uint8_t hdr[4] = { 1, 0, 0, 0 };
    fwrite(hdr, 1, 4, fp);
    fputc(4, fp); fputc(1, fp);
    put_varint(fp, 150000);
    put_varint(fp, 1000);
    put_varint(fp, note_count);
    put_varint(fp, (uint64_t)chunk_cap);
    put_varint(fp, (uint64_t)(steps / 4));
    put_varint(fp, (uint64_t)steps * 100);
    put_varint(fp, 0);
    put_varint(fp, 0);
    put_varint(fp, 0);
    put_varint(fp, (uint64_t)dir_n);
    for (size_t i = 0; i < dir_n; i++) { put_varint(fp, dir[i].count); put_varint(fp, dir[i].len); }
    put_varint(fp, 0);

    proc_init(&src, 0x9E3779B97F4A7C15ULL, steps, per_step, 4, 8, 4, 100.0);
    NseNote n;
    uint32_t cnt = 0;
    int64_t base = 0, prev_dt = -1;
    size_t bcap = (size_t)chunk_cap * 16 + 64, blen = 0;
    uint8_t *buf = (uint8_t *)xmalloc(bcap);
    double tw0 = now_s();
    while (proc_next(&src, &n)) {
        int64_t t = (int64_t)llround((double)n.t);
        if (cnt == 0) { base = t; prev_dt = -1; blen = 0; buf_varint(buf, &blen, (uint64_t)base); }
        int64_t dt = t - base;
        uint8_t nf = NF_MUSTPRESS;
        if (n.span > 0) nf |= NF_SUSTAIN;
        if (dt == prev_dt) nf |= NF_DTREPEAT; else prev_dt = dt;
        buf[blen++] = n.lane;
        buf[blen++] = nf;
        if (!(nf & NF_DTREPEAT)) buf_varint(buf, &blen, (uint64_t)dt);
        if (n.span > 0) buf_varint(buf, &blen, (uint64_t)n.span);
        base = t;
        cnt++;
        if ((int)cnt >= chunk_cap) { fwrite(buf, 1, blen, fp); cnt = 0; }
    }
    if (cnt) fwrite(buf, 1, blen, fp);
    free(buf);
    double tw = now_s() - tw0;
    uint32_t crc = 0; fwrite(&crc, 4, 1, fp);
    long sz = ftell(fp);
    fclose(fp);
    printf("[write] %s: %llu notes, %zu chunks, %.2f MiB (%.2f bytes/note) written in %.2fs (%.2f GB/s)\n",
           path, (unsigned long long)note_count, dir_n, (double)sz / 1048576.0,
           (double)sz / (double)note_count, tw, (double)sz / tw / 1e9);
    free(dir);
    return 1;
}

/* ------------------------------------------------------------------ .nse streaming reader */
typedef struct { FILE *fp; uint8_t buf[1 << 16]; size_t pos, len; } BR;

static inline int br_byte(BR *b) {
    if (b->pos >= b->len) {
        b->len = fread(b->buf, 1, sizeof b->buf, b->fp);
        b->pos = 0;
        if (!b->len) return -1;
    }
    return b->buf[b->pos++];
}
static uint64_t br_varint(BR *b) {
    uint64_t r = 0; int shift = 0;
    for (;;) {
        int c = br_byte(b);
        if (c < 0) return r;
        r |= (uint64_t)(c & 0x7F) << shift;
        if (!(c & 0x80)) break;
        shift += 7;
    }
    return r;
}
static void br_read(BR *b, void *dst, size_t n) {
    uint8_t *d = (uint8_t *)dst;
    while (n) {
        if (b->pos >= b->len) {
            b->len = fread(b->buf, 1, sizeof b->buf, b->fp);
            b->pos = 0;
            if (!b->len) return;
        }
        size_t take = b->len - b->pos;
        if (take > n) take = n;
        memcpy(d, b->buf + b->pos, take);
        b->pos += take; d += take; n -= take;
    }
}
static void br_skip(BR *b, size_t n) {
    b->pos = b->len = 0;
    fseek(b->fp, (long)n, SEEK_CUR);
}

typedef struct {
    FILE    *fp;
    size_t   payload_off;
    uint32_t nchunks;
    uint64_t *chunk_off;
    uint32_t *chunk_cnt;
    uint32_t *chunk_len;
    uint8_t  *buf;
    size_t    buf_cap;
    uint32_t  chunk, idx, cnt;
    size_t    pos, end;
    double    cur_t;
    int64_t   prev_dt;
    uint64_t  note_count;
} NseStream;

static int ns_open(NseStream *s, const char *path) {
    memset(s, 0, sizeof *s);
    s->fp = fopen(path, "rb");
    if (!s->fp) { perror(path); return 0; }
    BR b; memset(&b, 0, sizeof b); b.fp = s->fp;
    uint8_t magic[4];
    br_read(&b, magic, 4);
    if (memcmp(magic, "NSE1", 4) != 0) { fprintf(stderr, "bad magic\n"); return 0; }
    int ver = br_byte(&b) | (br_byte(&b) << 8);
    (void)br_byte(&b); (void)br_byte(&b);
    (void)br_byte(&b); (void)br_byte(&b);
    if (ver != 1) { fprintf(stderr, "bad version %d\n", ver); return 0; }
    (void)br_varint(&b);                          /* bpm*1000     */
    (void)br_varint(&b);                          /* speed*1000   */
    s->note_count = br_varint(&b);
    (void)br_varint(&b);                          /* chunk cap    */
    (void)br_varint(&b);                          /* section count*/
    (void)br_varint(&b);                          /* duration ms  */

    uint64_t nstr = br_varint(&b);
    for (uint64_t i = 0; i < nstr; i++) { uint64_t n = br_varint(&b); br_skip(&b, n); }
    uint64_t nruns = br_varint(&b);
    for (uint64_t i = 0; i < nruns; i++) {
        (void)br_varint(&b); (void)br_varint(&b);
        int fl = br_byte(&b);
        if (fl & 8) (void)br_varint(&b);
    }
    uint64_t nbpm = br_varint(&b);
    /* delta ms, bpm*1000, stepTime */
    for (uint64_t i = 0; i < nbpm; i++) { (void)br_varint(&b); (void)br_varint(&b); (void)br_varint(&b); }
    uint32_t nch = (uint32_t)br_varint(&b);
    s->nchunks = nch;
    s->chunk_off = (uint64_t *)xmalloc(sizeof(uint64_t) * (nch ? nch : 1));
    s->chunk_cnt = (uint32_t *)xmalloc(sizeof(uint32_t) * (nch ? nch : 1));
    s->chunk_len = (uint32_t *)xmalloc(sizeof(uint32_t) * (nch ? nch : 1));
    uint64_t off = 0;
    size_t maxlen = 0;
    for (uint32_t i = 0; i < nch; i++) {
        s->chunk_cnt[i] = (uint32_t)br_varint(&b);
        uint32_t ln = (uint32_t)br_varint(&b);
        s->chunk_len[i] = ln;
        s->chunk_off[i] = off;
        off += ln;
        if (ln > maxlen) maxlen = ln;
    }
    uint64_t nev = br_varint(&b);
    for (uint64_t i = 0; i < nev; i++) { (void)br_varint(&b); (void)br_varint(&b); (void)br_varint(&b); (void)br_varint(&b); }
    s->payload_off = (size_t)ftell(s->fp) - (b.len - b.pos);
    s->buf_cap = maxlen + 64;
    s->buf = (uint8_t *)xmalloc(s->buf_cap);
    if (getenv("REFBENCH_VERBOSE"))
        fprintf(stderr, "  [stream] %llu notes, %u chunks indexed (%.1f MiB index, %.1f KiB window)\n",
                (unsigned long long)s->note_count, nch,
                (double)(sizeof(uint64_t) + 2 * sizeof(uint32_t)) * nch / 1048576.0,
                (double)s->buf_cap / 1024.0);
    return 1;
}

static void ns_load(NseStream *s, uint32_t i) {
    if (i >= s->nchunks) { s->chunk = s->nchunks; s->cnt = 0; s->idx = 0; return; }
    fseek(s->fp, (long)(s->payload_off + s->chunk_off[i]), SEEK_SET);
    size_t got = fread(s->buf, 1, s->chunk_len[i], s->fp);
    s->chunk = i;
    s->cnt = s->chunk_cnt[i];
    s->idx = 0;
    s->pos = 0;
    s->end = got;
    uint64_t base = 0; int shift = 0;
    for (;;) {
        uint8_t c = s->buf[s->pos++];
        base |= (uint64_t)(c & 0x7F) << shift;
        if (!(c & 0x80)) break;
        shift += 7;
    }
    s->cur_t = (double)base;
    s->prev_dt = -1;
}

static inline uint64_t mem_varint(uint8_t *p, size_t *pos) {
    uint64_t r = 0; int shift = 0;
    for (;;) {
        uint8_t c = p[(*pos)++];
        r |= (uint64_t)(c & 0x7F) << shift;
        if (!(c & 0x80)) break;
        shift += 7;
    }
    return r;
}

static inline int ns_next(NseStream *s, NseNote *out) {
    while (s->idx >= s->cnt) {
        if (s->chunk + 1 >= s->nchunks) return 0;
        ns_load(s, s->chunk + 1);
    }
    if (s->pos + 2 > s->end) return 0;
    uint8_t *p = s->buf;
    uint8_t lane = p[s->pos++];
    uint8_t fl = p[s->pos++];
    int64_t dt;
    if (fl & NF_DTREPEAT) dt = s->prev_dt;
    else { dt = (int64_t)mem_varint(p, &s->pos); s->prev_dt = dt; }
    double t = s->cur_t + (double)dt;
    s->cur_t = t;
    uint64_t span = 0, type = 0;
    if (fl & NF_SUSTAIN) span = mem_varint(p, &s->pos);
    if (fl & NF_HASTYPE) type = mem_varint(p, &s->pos);
    s->idx++;
    out->t = (float)t;
    out->span = (float)span;
    out->lane = lane;
    out->flags = fl;
    out->type = (uint16_t)type;
    return 1;
}

static void ns_reset(NseStream *s) { ns_load(s, 0); }

static void run_engine_stream(Engine *e, NseStream *st, int frames, NseRun *out) {
    memset(out, 0, sizeof *out);
    const double dt_ms = 1000.0 / 60.0;
    const double song_speed = 2.0;
    double t0 = now_s();
    NseNote n;
    int got = 1;
    for (int f = 0; f < frames; f++) {
        e->song_pos += dt_ms;
        out->frames++;
        for (;;) {
            if (!e->n) break;
            NseNote front = e->live[e->head];
            if (e->song_pos <= (double)front.t + e->kill_offset) break;
            eng_pop(e);
        }
        for (;;) {
            if (!got) break;
            if (e->n >= e->cap) { e->skipped++; break; }
            uint32_t sc = st->chunk, si = st->idx;
            size_t sp = st->pos, se = st->end;
            double stt = st->cur_t; int64_t sdt = st->prev_dt;
            if (!ns_next(st, &n)) { got = 0; break; }
            if ((double)n.t - e->song_pos >= e->spawn_time) {
                st->chunk = sc; st->idx = si; st->pos = sp; st->end = se;
                st->cur_t = stt; st->prev_dt = sdt;
                break;
            }
            eng_push(e, &n);
        }
        if (e->n > out->peak_live) out->peak_live = e->n;
        double m0 = now_s();
        int idx = e->head;
        for (int i = 0; i < e->n; i++) {
            note_move(&e->live[idx], e->song_pos, song_speed, 0);
            if (++idx >= e->cap + 2) idx = 0;
        }
        out->move_wall += now_s() - m0;
        if (!got && !e->n) { out->exhausted = 1; break; }
    }
    out->wall = now_s() - t0;
    out->spawned = e->spawned;
    out->killed = e->killed;
    out->notes_per_s = (double)e->spawned / (out->wall > 0 ? out->wall : 1e-9);
}

/* ------------------------------------------------------------------ dump (cross-check) */
static void run_nsedump(const char *path, int limit) {
    NseStream st;
    if (!ns_open(&st, path)) exit(1);
    ns_reset(&st);
    printf("notes=%llu\n", (unsigned long long)st.note_count);
    NseNote n;
    int i = 0;
    while (i < limit && ns_next(&st, &n)) {
        /* DTREPEAT is an encoding detail, compare the semantic flag bits only */
        printf("%d t=%.3f lane=%u flags=%u span=%.3f type=%u\n",
               i, (double)(int)llround((double)n.t), n.lane, (unsigned)(n.flags & 0x7F), (double)n.span, n.type);
        i++;
    }
    fclose(st.fp);
}

/* ------------------------------------------------------------------ main */
static void usage(void) {
    printf("usage: refbench <nse|file|dump|pump|sweep|write|naive|all|procdump> [options]\n"
           "  --notes N           note count (default 100000000)\n"
           "  --per-step P        notes per step for the procedural chart (default 8)\n"
           "  --step-ms MS        step length in ms for sweep (default 10)\n"
           "  --live-cap C        maximum simultaneously alive note sprites (default 4096)\n"
           "  --frames F          frames to simulate (default 60000)\n"
           "  --file PATH         .nse file for the 'file' mode\n"
           "  --out PATH          output file for the 'write' mode\n"
           "  --chunk-cap N       notes per chunk when writing (default 4096)\n"
           "  --spawn-time MS     note spawn look-ahead (default 2000)\n"
           "  --kill-offset MS    note reap delay (default 350)\n"
           "  --bytes-per-note B  naive-model object cost (default 1024)\n"
           "  --mem-budget-mb M   stop the naive model at this RSS (default 900)\n");
}

int main(int argc, char **argv) {
    if (argc < 2) { usage(); return 2; }
    const char *mode = argv[1];
    uint64_t notes = 100000000ULL;
    int per_step = 8, live_cap = 4096, frames = 60000, chunk_cap = 4096, limit = 32;
    double spawn_time = 2000.0, kill_offset = 350.0;
    const char *file = NULL, *out = NULL;
    for (int i = 2; i < argc; i++) {
        if (!strcmp(argv[i], "--notes") && i + 1 < argc) notes = strtoull(argv[++i], NULL, 10);
        else if (!strcmp(argv[i], "--per-step") && i + 1 < argc) per_step = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--live-cap") && i + 1 < argc) live_cap = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--frames") && i + 1 < argc) frames = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--file") && i + 1 < argc) file = argv[++i];
        else if (!strcmp(argv[i], "--out") && i + 1 < argc) out = argv[++i];
        else if (!strcmp(argv[i], "--chunk-cap") && i + 1 < argc) chunk_cap = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--spawn-time") && i + 1 < argc) spawn_time = atof(argv[++i]);
        else if (!strcmp(argv[i], "--kill-offset") && i + 1 < argc) kill_offset = atof(argv[++i]);
        else if (!strcmp(argv[i], "--bytes-per-note") && i + 1 < argc) g_bytes_per_note = atof(argv[++i]);
        else if (!strcmp(argv[i], "--limit") && i + 1 < argc) limit = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--mem-budget-mb") && i + 1 < argc) g_mem_budget_mb = atof(argv[++i]);
    }

    if (!strcmp(mode, "naive")) { run_naive(notes, per_step); return 0; }
    if (!strcmp(mode, "pump")) { run_pump(notes, per_step); return 0; }
    if (!strcmp(mode, "dump")) {
        if (!file) { fprintf(stderr, "dump needs --file\n"); return 2; }
        run_nsedump(file, limit > 0 ? limit : 32);
        return 0;
    }
    if (!strcmp(mode, "procdump")) {
        double step_ms = 100.0; uint32_t seed = 0x2F6E2B1; int lanes = 4;
        for (int i = 2; i < argc; i++) {
            if (!strcmp(argv[i], "--seed") && i + 1 < argc) seed = (uint32_t)strtoul(argv[++i], NULL, 10);
            else if (!strcmp(argv[i], "--step-ms") && i + 1 < argc) step_ms = atof(argv[++i]);
            else if (!strcmp(argv[i], "--lanes") && i + 1 < argc) lanes = atoi(argv[++i]);
        }
        run_procdump(notes, per_step, lanes, step_ms, seed, limit);
        return 0;
    }
    if (!strcmp(mode, "sweep")) {
        double step_ms = 10.0;
        for (int i = 2; i < argc; i++) if (!strcmp(argv[i], "--step-ms") && i + 1 < argc) step_ms = atof(argv[++i]);
        run_sweep(per_step, step_ms, frames, live_cap);
        return 0;
    }
    if (!strcmp(mode, "write")) {
        if (!out) { fprintf(stderr, "write mode needs --out\n"); return 2; }
        return write_chart(out, notes, per_step, chunk_cap) ? 0 : 1;
    }
    if (!strcmp(mode, "nse") || !strcmp(mode, "all")) {
        printf("[nse] procedural chart: %llu notes, %d per step, live cap %d\n",
               (unsigned long long)notes, per_step, live_cap);
        int64_t steps = (int64_t)(notes / (uint64_t)per_step);
        ProcSrc src;
        proc_init(&src, 0x9E3779B97F4A7C15ULL, steps, per_step, 4, 8, 4, 100.0);
        Engine e;
        eng_init(&e, live_cap, spawn_time, kill_offset);
        NseRun r;
        run_engine_proc(&e, &src, frames, &r);
        report_run(" ", &e, &r);
        printf("  chart storage: %zu bytes (procedural spec)   process RSS %.1f MiB\n",
               sizeof(ProcSrc), (double)rss_kb() / 1024.0);
        free(e.live);
    }
    if (!strcmp(mode, "file")) {
        if (!file) { fprintf(stderr, "file mode needs --file\n"); return 2; }
        double t0 = now_s();
        NseStream st;
        if (!ns_open(&st, file)) return 1;
        double t_parse = now_s() - t0;
        printf("[file] %s: %llu notes\n", file, (unsigned long long)st.note_count);
        printf("  TOC parse + %u-entry chunk index: %.3f ms   process RSS %.1f MiB\n",
               st.nchunks, t_parse * 1e3, (double)rss_kb() / 1024.0);

        NseNote n;
        ns_reset(&st);
        double t1 = now_s();
        uint64_t decoded = 0, nonmono = 0;
        double last = -1e30;
        while (ns_next(&st, &n)) {
            if ((double)n.t < last - 1e-6) nonmono++;
            last = (double)n.t;
            decoded++;
        }
        double t_stream = now_s() - t1;
        printf("  full sequential decode: %llu notes in %.3fs = %.2f M notes/s (out-of-order %llu, %s)\n",
               (unsigned long long)decoded, t_stream, (double)decoded / t_stream / 1e6,
               (unsigned long long)nonmono,
               (decoded == st.note_count && nonmono == 0) ? "integrity OK" : "INTEGRITY FAIL");

        ns_reset(&st);
        Engine e;
        eng_init(&e, live_cap, spawn_time, kill_offset);
        NseRun r;
        run_engine_stream(&e, &st, frames, &r);
        report_run(" ", &e, &r);
        printf("  -> engine streamed %.2f M notes/s with %.1f MiB RSS\n",
               r.notes_per_s / 1e6, (double)rss_kb() / 1024.0);
        free(e.live);
        free(st.chunk_off); free(st.chunk_cnt); free(st.chunk_len); free(st.buf);
        fclose(st.fp);
    }
    if (!strcmp(mode, "all")) run_naive(notes, per_step);
    return 0;
}
