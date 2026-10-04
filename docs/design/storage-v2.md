# rime storage design v2 — total budget, admission control, and the tagging index

**Status:** draft spec. This document **supersedes `docs/design/storage.md` (v1)
where they conflict.** Where v1 still holds, this doc cites it (e.g. "v1 §5.1,
unchanged") instead of restating it. **Do not edit v1.**

**Scope of this doc:** the storage core's v2 contract — one total byte budget
with hard class allocations, write-time admission control, a queryable
SQLite metadata/tagging index, tag-aware reuse and cleanup, the
global-cache-only mandate with cargo-compatible outputs outside the budget,
and migration from the v1 format. Manifest/resolution and the rustc driver
are separate subsystems; this doc defines what they consume (the Store
interface, §16).

**Shared design contract (authoritative goals for v2):**

1. **Fully cargo compatible.** rime is a cargo drop-in for Rust: reads
   `Cargo.toml`/`Cargo.lock`, supports workspaces, build scripts, and proc
   macros, and supports the cargo command surface
   (`build`/`check`/`test`/`run`/`bench`/`clean`) with matching exit codes
   and conventions. Storage touchpoints only are specified here (§13);
   driver behavior belongs to the driver subsystem spec.
2. **Global caches only.** No project-local cache state ever. All cacheable
   state (compiled artifacts, dependency sources, action results,
   incremental sessions) lives in the single global store. Project dirs
   hold only materialized terminal outputs (`target/<profile>/` binaries
   for cargo compat); outputs are **not** counted against the cache budget.
3. **Metadata + tagging index.** A real queryable index: SQLite, vendored
   sqlite3 amalgamation compiled via `build.zig` `addCSourceFile`
   (**dependency decision, flagged explicitly in §11.1**). Tables for
   objects (digest, size, compressed size, tier, kind, created/access
   times), tags (key/value pairs: crate, toolchain, target triple, profile,
   feature-set hash, project id, action kind, plus freeform user tags),
   actions (action key → manifest digest), and pins/leases/retains.
   Tag queries power reuse lookup and cleanup.
4. **Very bounded storage.** One total budget knob
   (default `clamp(10% of free space, 5 GiB, 50 GiB)`) split into hard
   class allocations: hot tier, cold tier, index+state, transient spool.
   Write-time admission control: every put reserves bytes first; over
   budget evicts unrooted LRU, then demotes, then fails with `StoreFull`
   plus a budget breakdown. **Invariant: total store bytes ≤ budget at all
   times (in-flight reservations counted).** GC becomes hygiene, not the
   enforcement mechanism. Roots (pins/leases/retains) are never
   auto-evicted; per-tag budgets are optional soft caps that steer eviction
   order.

**How to read this against v1:** §§5–8 below are written in the v1 style
(tables, exact defaults, evidence citations). Each subsection names what
it keeps from v1 and what it supersedes; §18 lists every supersession as
old → new.

---

## 1. Problem (v2 delta)

v1 (storage.md §§1–2) solved identity (one copy per artifact per machine),
atomicity, and post-facto reclaim (quota/age GC with roots). Three gaps
remain, each observed against the implemented core (`src/store/`, plan
`docs/superpowers/plans/2026-10-04-storage-core.md`):

1. **No bound is enforced at write time.** The implemented `putBytes`/`putFile`
   (`src/store/ingest.zig`) publish first; `gc` (`src/store/gc.zig`) reclaims
   later. Between the two the store is over limit by construction. Per-tier
   `hot_limit`/`cold_limit` also do not bound the *total* (index, state,
   spool, and the cold tier's uncompressed-equivalent accounting escape
   them). There is no single number an operator can reason about.
2. **No queryable metadata.** Kind is an append-only `state/kinds.jsonl`
   journal (`src/store/ingest.zig:recordKind`, `src/store/scan.zig:loadKinds`);
   everything else (which crate, which toolchain, which project) is
   unrecorded. Reuse is exact-digest or exact-action-key only; cleanup is
   "LRU over everything" with no per-crate/per-project scoping. At ~1 M
   objects the full-scan quota path v1 §12 warned about becomes the
   steady-state path.
3. **Project-local state violates the global mandate.** The implemented
   `state/projects/<id>/incremental/` class (v1 §9.5, `src/store/gc.zig:
   sweepIncremental`) is a per-project cache dir inside the global store
   with its own limits — exactly the "private cache per project" shape the
   contract abolishes. Cargo-compatible output placement is also
   underspecified: which bytes count against the budget and which do not.

v2 closes all three: a total budget enforced before any byte is written
(§§9–10), a SQLite index with a fixed tag vocabulary (§11) powering
tag-aware reuse and cleanup (§12), and a hard global-only rule with
outputs outside the budget (§13).

## 2. Goals

1. One copy per artifact per machine **and** one number bounding all of it.
2. Bounded storage, **always** — the invariant holds between operations,
   not just after GC. GC is hygiene (§10.6).
3. Predictable, explainable reclaim **and** admission: `StoreFull` tells
   the caller exactly what is full and what would free space (§10.4).
4. Queryable reuse: "do we already have `serde-1.0.200` for this
   toolchain/target/profile/features?" is one indexed query (§12.1).
5. Scoped cleanup: per-tag budgets and `gc --tag` scope what dies first (§12.2).
6. Memory sharing for free (v1 §2 goal 4, unchanged: immutable read-only
   objects, page-cache sharing, clone-first materialization).
7. Team sharing via the same object model (v1 §2 goal 5; protocol v1 §10.2,
   unchanged by v2 except action/tag replication notes in §15.3).
8. Crash-safe, self-healing (v1 §2 goal 6, extended to the index: content
   authoritative, index rebuildable, §11.5).

## 3. Non-goals

- Remote *execution* (v1 §3, unchanged).
- Sharing rustc incremental sessions across machines (v1 §3, unchanged;
   sessions are now global *tagged* objects, still never pushed to the
   network cache, §13.2).
- Deduplication *within* a blob (v1 §3, unchanged).
- Windows support (v1 §3, unchanged: macOS + Linux; platform seam v1 §7.2).
- A query language beyond conjunctive tag predicates plus recency ordering
   (§12.1). No joins across tables from the CLI, no SQL passthrough.

## 4. Architecture overview

```
                ┌─────────────────────────────────────────────────┐
   build tool   │                     Store (deep module)         │
   (rustc       │  reserve / put / get / materialize / pin /      │
    driver,     │  lookup / gc / stats  (+ StoreFull on admit)    │
    resolver)   ├─────────────────────────────────────────────────┤
                │ ingest  objects  manifest  materialize  state   │
                │ scan    gc       cold      action  index spool  │
                │              ▲                                 │
                │        admission gate (reserve → evict →       │
                │        demote → StoreFull, §10)                │
                └──────────┬────────────────────────┬───────────┘
                           │                        │
        ┌──────────────────▼────────┐   ┌───────────▼───────────┐
        │  local store (CAS)        │   │  network cache        │
        │  hot / cold tiers (bytes) │   │  (HTTP CAS, same      │
        │  + index.sqlite (SQLite,  │   │   object model;       │
        │  vendored amalgamation)   │   │   optional push)      │
        │  + state (pins, leases,   │   │                       │
        │  retains in index)        │   │                       │
        │  + spool (tmp reservations)│  │                       │
        └───────────────────────────┘   └─────────────────────┘
```

The Store remains the deep module (v1 §4, unchanged in shape). v2 adds two
pieces behind its interface: the **admission gate** (every mutating path
reserves before writing, §10) and the **index** (every put/get/GC consults
SQLite, §11). The build tool still knows `put/get/materialize/pin/gc/stats`
plus two v2 calls — `reserve` (usually implicit inside `put*`) and `lookup`
(tag-aware reuse) — and nothing about layouts, compression, cloning,
eviction, or SQL (§16).

## 5. Content model

### 5.1 Digests

**v1 §5.1, unchanged.** BLAKE3, 32 bytes; text form `b3-<64 lowercase hex>`;
on-disk `objects/<hex[0..2]>/<hex[2..]>`. Objects are identified by the
digest of their exact bytes. Implemented reality matches:
`src/store/digest.zig` (`toHex`/`fromHex`/`relPath`, `hashBytes`/`hashFile`).

### 5.2 Objects

v1 §5.2 invariants 1–4 **unchanged** (immutability, `0o444`, reads never
mutate bytes, hot-uncompressed/cold-gzip with digest of uncompressed
bytes). Implemented: `src/store/ingest.zig` (temp + rename + `0o444`),
`src/store/objects.zig` (cold-transparent reads), `src/store/cold.zig`
(gzip level 6, verify-before-delete both directions).

Kinds: the v1 §5.2 list is kept and extended by exactly two values:

| Kind | Tiering | Notes |
|---|---|---|
| `rlib`, `rmeta`, `obj`, `staticlib` | demotable | as v1 |
| `dylib`, `bin` | **never demoted** | v1 §9.4, implemented in `cold.isDemotable`; executed/loaded in place |
| `dep_info`, `manifest`, `build_script_out`, `source`, `other` | demotable | as v1 |
| `incremental` | demotable, never pushed remote | **new in v2**: rustc incremental sessions as global tagged objects (§13.2) |
| `spool` | never stored (transient only) | **new in v2**: build-spool bytes counted in the spool class, never admitted as objects |

Kind remains best-effort performance metadata, never correctness
(v1 §5.2; implemented as the `kinds.jsonl` journal, migrated to the index
in §14). The kind journal's readers-skip-malformed-lines rule carries over
to index rebuild (§11.5).

### 5.3 Manifests and action results (REAPI-shaped)

**v1 §5.3, unchanged**, including the JSON shape (`format`, `kind`,
`outputs[]` with `path`/`digest`/`size`/`mode`), the action-key contents
rule (toolchain identity incl. sysroot lib digests, target triple,
normalized args, relevant env, input digests), and the hints-not-roots rule
(stale entries degrade to rebuilds). Implemented: `src/store/manifest.zig`,
`src/store/action_cache.zig` (flat `actions/` files; migrated to the
`actions` table in §14).

Action keys additionally bind the **feature-set hash** and **profile** in
v2 (they were implicit in "normalized args" before; §11.3 makes them
explicit tags so reuse queries can filter on them without re-hashing keys).

### 5.4 Tags (new in v2)

Every object may carry a set of `(key, value)` tags recorded in the index
at ingest. Tags are metadata only: they never affect the digest, never
affect correctness of reads, and are never required for an object to exist.
Untagged objects are legal and are treated as evictable-first (§12.2).

The fixed vocabulary is defined in §11.3. Tag keys are lowercase
`[a-z][a-z0-9_]*`, at most 32 bytes; values are UTF-8, at most 256 bytes;
at most 32 tags per object **and** at most 8 KiB total tag bytes per object
(sum of `length(key) + length(value)` over the object's tags) — both caps
exact (mirrored in §11.3), enforced at ingest; violations
return `error.TagLimit`, the put fails before reserving.

### 5.5 What goes where

Supersedes v1 §5.4 (old → new in §18.2). The `incremental` and view rows
change; everything else is unchanged:

| Content | Location | Class | Counted? |
|---|---|---|---|
| dependency artifacts (rlib, rmeta, proc-macro dylib) | global store objects | hot/cold | yes |
| build-script outputs | global store objects (keyed incl. env) | hot/cold | yes |
| dep-info, output manifests | global store objects | hot/cold | yes |
| incremental sessions | global store objects, `kind=incremental` + tags | hot/cold | yes (was: per-project dir, §13.2) |
| fetched dependency sources | store objects, `source` kind | hot/cold | yes |
| final user binaries (store copy) | global store objects | hot (never demoted) | yes, once |
| final user binaries (project view) | `target/<profile>/`, clone-or-copy | — (view) | **no** (§13.3) |
| in-flight build spool (`tmp/`) | store spool dir | spool | yes, against spool cap |
| index + state (`index.sqlite*`, `state/`) | store root | index+state | yes, against its cap |
| user data parked in `target/` (corpora etc.) | `rime store` pins (§13.4) | hot/cold | yes; pinned, never auto-evicted |

## 6. The store on disk

v1 §6 layout is kept; v2 adds three entries and re-homes roots. Exact
v2 layout (`$RIME_CACHE_DIR/`, default XDG cache dir / `rime`, v1 §6):

```
$RIME_CACHE_DIR/
  format.json                        # {"format": 2} — refuse unknown formats (v1 §6 rule kept; per-value error table in §14)
  objects/ab/cdef…                   # hot tier: immutable objects (0444) — unchanged
  cold/ab/cdef…                      # cold tier: gzip containers — unchanged
  actions/                           # v1 flat action files — KEPT during migration, removed after (§14)
  tmp/                               # spool: in-flight writes + reservation staging (§10.2)
  index.sqlite                       # v2 index: objects, tags, actions, roots, reservations (§11)
  index.sqlite-wal                   # WAL (normal operation; counted in index+state, §9.3)
  index.sqlite-shm                   # shm (counted in index+state, §9.3)
  state/
    pins/<name>                      # v1 roots — KEPT during migration, removed after (§14)
    leases/<build-id>                # ditto
    projects/<project-id>.json       # ditto (retains); per-project incremental/ REMOVED (§13.2)
    kinds.jsonl                      # v1 kind journal — KEPT during migration, removed after (§14)
    backup.json                      # pre-repair roots backup (§11.5); absent in steady state
  format-lock                        # advisory lock file, v1 §8.2 semantics kept, extended in §8.2
```

`project-id` = BLAKE3 of the normalized workspace path (v1 §6, unchanged;
now recorded as the `project` tag value, never as a directory). The
`rime-out/` view dir is renamed: cargo-compat projects materialize into
`target/<profile>/` (§13.3); `rime-out/last-build.json` becomes
`target/.rime-last-build.json` (a view-local hint, not store state).

## 7. Materialization semantics

### 7.1 Clone-first, copy-always-fallback, never hardlink

**v1 §7.1, unchanged**, including the order (clone → byte copy → never
hardlink), the temp + rename destination protocol, and the per-(device,
filesystem) capability probe. Implemented: `src/store/clone.zig`
(`clonefile`/`FICLONE` shims), `src/store/materialize.zig`.

### 7.2 Platform seam

**v1 §7.2, unchanged** (one function table, Darwin/Linux adapters,
`else => @compileError`, injectable `.copy_only` strategy for tests).

### 7.3 Read-only inputs

**v1 §7.3, unchanged** (store paths passed read-only; callers needing
writable inputs materialize private spool copies).

### 7.4 Cargo-compatible views (new in v2)

Materialization destinations for cargo-compat builds are
`<project>/target/<profile>/` paths (profile = `debug` | `release` |
custom profile name). Views are **not storage**: deleting a view never
touches the store; rebuilding a view never re-runs the compiler when the
store still holds the objects (re-materialize from digests). View bytes
are excluded from every budget class (§9.3). `cargo clean` equivalence =
delete `target/` views (store untouched); `rime gc` never deletes views.

## 8. Concurrency and crash safety

### 8.1 Atomic ingest

v1 §8.1 protocol **unchanged** (write `tmp/`, hash while writing, fsync,
`chmod 0444`, rename; rename-with-existing-target = dedup race won by
another writer). v2 prepends one step: **reserve before writing**
(§10.2). A reservation that never commits is garbage counted against the
budget until its TTL expires (default 10 min, §10.2) — bounded by the
spool cap, swept on open like stale `tmp/` files (v1 §8.1 sweep rule
kept: anything older than 1 h is garbage; reservations additionally expire
by their own TTL).

### 8.2 Locking

v1 §8.2 (shared lock for builds, exclusive for GC, lock-free publication
with lease-before-ingest) is kept with two v2 extensions:

1. **SQLite is the second lock domain.** All index mutations run in
   `IMMEDIATE` transactions. Filesystem rename and index-row insert are
   **not** one atomic transaction (impossible across systems) — publication
   follows the normative order `rename → insert row → commit(token)`
   (§10.1), and the §11.5 verifier/repairer is the reconciler that converges
   both crash windows: file-without-row is re-inserted (or quarantined when
   corrupt), row-without-file deletes the row. GC's exclusive
   `format-lock` additionally checkpoints the WAL (`PRAGMA wal_checkpoint
   (TRUNCATE)`) so a killed GC never leaves unbounded WAL growth.
2. **Reservations are registered before ingestion begins** (same rule as
   v1 leases, extended): a crash between reserve and commit leaks at most
   one TTL window of budget, never store corruption.

### 8.3 Index durability

Supersedes v1 §8.3 (old → new in §18.2). v1 had no authoritative index;
v2 has one with split durability:

- **Authoritative and irrecoverable:** `objects/` + `cold/` bytes and the
  `pins`/`leases`/`retains` root rows. A corrupt/partial root row is
  **not** ignored (v1's rule for state files does not carry over):
  `open` fails closed on unreadable roots tables and directs the operator
  to `rime cache verify --repair`, which restores roots from
  `state/backup.json` (§11.5).
- **Rebuildable:** `objects`/`object_tags`/`actions` rows and all derived
  stats. Rebuilt from a tier scan plus the migration journals when
  present (§11.5, §14). A corrupt index with intact content loses
  performance (cold LRU order, tag recall), never user data.

## 9. Total budget model

This section is the v2 replacement for v1 §9.1 (old → new in §18.2).

### 9.1 The one knob

| Setting | Default | Meaning |
|---|---|---|
| `budget` | `auto` = `clamp(10% of free space, 5 GiB, 50 GiB)` | total bytes rime may own, all classes combined |
| `disk_reserve` | `auto` = `max(5 GiB, 5% of FS size)` | FS free-space floor; admission refuses before breaching it (v1 §9.1, unchanged) |
| `hot_cap` | 70% of resolved `budget` | hard cap, hot tier bytes (uncompressed sizes) |
| `cold_cap` | 20% of resolved `budget` | hard cap, cold tier bytes (**compressed** sizes, v1 §9.4 rule kept) |
| `index_state_cap` | 5% of resolved `budget` | hard cap, index + state bytes (§9.3) |
| `spool_cap` | 5% of resolved `budget` | hard cap, transient `tmp/` bytes (§9.3) |
| `hysteresis` | 90% | evict-to target, all reclaim paths (v1 §9.1 Nx-style rule kept) |

Rationale and evidence (research brief, 2026-10-04): the `auto` formula is
v1 §9.1 (Nx 10%-of-disk sizing, sccache 10 GB local-LRU precedent, Go/Gradle
age-trim complements); the 70/20 split keeps the working set hot while cold
absorbs one full hot-turnover plus headroom; 5% index+state bounds a ~1 M
object index (≈150–250 B/row + tag rows) to ≈0.5 GiB on a 10 GiB budget with
room for WAL; 5% spool bounds concurrent ingests (a single rustc output set
is MiBs; 5% of the 5 GiB floor = 256 MiB ≈ dozens of concurrent puts).
All six knobs accept explicit byte values (`store.budget = "20GiB"`,
`store.hot_cap = "14GiB"`, …); explicit class caps must sum to ≤ `budget`
(config validation error otherwise). Each class cap is a hard upper bound:
when the caps sum to less than `budget`, the leftover slack is unallocated
headroom that no class may borrow — a put breaching its class cap fails even
while total usage is below `budget`, and I-TOTAL (§9.2) still binds the sum. `rime cache stat` prints the resolved
budget, all four class usages vs caps, and the binding constraint (v1 §9.7
`stat` surface, extended).

Implemented-reality note: `src/store/config.zig` today resolves
`hot`/`cold`/`reserve` with `cold auto = 2 × hot`. That resolution is
**superseded**: `hot_limit`/`cold_limit` become deprecated aliases mapped
in §14, and `resolveLimits` gains `budget: u64` plus the four class caps.

### 9.2 The invariant

> **I-TOTAL: at every observable point — before and after each Store
> operation, including crashes — `hot + cold + index_state + spool ≤
> budget`, where each term includes in-flight reservations against that
> class.**

Consequences, all normative:

1. GC can never be the mechanism that restores compliance, because
   non-compliance is unrepresentable: puts that would breach the budget
   do not happen (§10). GC remains as hygiene (age trim, demotion,
   defragmentation of reclaimable-but-unreserved space, §10.6).
2. **Roots are never auto-evicted AND roots count against the budget.**
   A pin/lease/retain that would breach the budget fails at creation with
   `StoreFull` (or `error.NoSpaceForRoot` on the pin path, same payload)
   instead of pushing the store over limit. This supersedes v1 §9.1's
   "over-limit-by-roots is legal" rule (old → new in §18.2): v1 reported
   `over quota by N (pinned)`; v2 refuses the pin and lists what to unpin.
3. The filesystem can still fill beneath rime (another process writing):
   the `disk_reserve` floor is enforced independently at admission (§10.3)
   and by emergency trim (§10.6); breaching `disk_reserve` from outside is
   reported, never silently absorbed.

### 9.3 What counts where (exact accounting)

| Byte source | Class | Measured as |
|---|---|---|
| `objects/` file bytes | hot | `statFile.size` (uncompressed; digest input bytes) |
| `cold/` file bytes | cold | `statFile.size` (gzip bytes on disk, v1 §9.4 rule kept) |
| `index.sqlite` + `-wal` + `-shm` | index+state | sum of the three `statFile.size` (WAL included; `page_count × page_size` is **not** used because it hides WAL) |
| `state/` (during migration; `backup.json` otherwise) | index+state | recursive sum of file sizes |
| `tmp/` files + open reservation bytes not yet on disk | spool | file sizes + `SUM(bytes)` over live reservations against spool |
| reserved-but-unwritten bytes for an admitted put | issuing class of the put: fresh `put*` always reserves **hot**; demote staging reserves **cold** (estimated gzip bytes, §10.1); index/state growth reserves **index_state**; `tmp/` staging reserves **spool** (§10.2) | `reservations.bytes` included in class usage until commit/abort/expiry |
| project views (`target/<profile>/`) | — | **excluded** (§13.3) |
| network-cache bytes | — | excluded client-side; server enforces its own budget (v1 §9.8 rule kept) |

Double-entry rule: a reservation's bytes are counted **once**, in the
reservation ledger; on commit the ledger entry is atomically replaced by
the file's bytes (no window where both count). On abort/expiry the ledger
entry is deleted. `stats` reports `reserved_bytes` per class separately so
`used + reserved` is auditable (§16).

### 9.4 Per-tag soft budgets (preview; enforced in §12.3)

Per-tag budgets are **not** a fifth class: they are optional soft caps of
the form `(tag_key, tag_value) → bytes` (e.g. `("crate","serde") →
2 GiB`) that steer eviction order inside the hard class caps. They never
cause `StoreFull` by themselves and never protect anything from eviction.
Full semantics in §12.3.

## 10. Admission control

### 10.1 The pipeline (normative order)

Every mutating path (`putBytes`, `putFile`, `putManifest`, demote staging,
spool writes) executes, in order:

```
reserve(bytes, class)          # §10.2; idempotent fast path first (§10.5)
  → evict unrooted LRU         # §10.6 step order; bounded effort per admit
  → demote hot → cold          # only when admitting to hot and cold has room
  → StoreFull | commit token   # §10.4 payload; caller sees one error shape
write tmp/ (spool-counted) → fsync → chmod 0444 → rename (v1 §8.1)
  → commit(token)              # ledger → file atom swap (§9.3)
```

Reads (`exists`, `readObject`, `getManifest`, `getAction`, `lookup`,
`materialize` to an outside path) never reserve. `materialize` into a
project view writes outside the store and reserves nothing; `demote` stages
its gzip output under a **cold**-class reservation (estimated compressed
bytes), evicting cold LRU first when full (v1 §9.4 "evict cold LRU
first" rule kept), then deletes the hot copy and commits — net effect shrinks
hot, but the staging window is reserved so I-TOTAL holds throughout.

### 10.2 Reservations

`reserve(class, bytes, opts) -> Reservation`:

- **Token:** 128-bit random id (`io.random`, same source as v1 tmp names),
  row in `reservations(reservation_id, class, bytes, created_ms,
  expires_ms, owner_build_id NULL)`.
- **TTL:** default 10 min (`reservation_ttl = "10m"`), renewable by the
  owning put while streaming; swept on `open` and every 60 s of store
  activity alongside the v1 `tmp/` sweep (stale `tmp/` files > 1 h
  unchanged, v1 §8.1).
- **Owner:** optional `owner_build_id`; a live lease for the same build
  extends matching reservations to the lease TTL (2 h) so long builds with
  large outputs do not lose their reservation mid-link.
- **Bounded effort:** one `reserve` triggers at most one eviction pass bounded
  by **both** limits — at most 1,000 objects **and** at most 10% of the class
  cap in bytes, stopping at whichever bound is hit first;
  beyond that it returns `StoreFull` instead of stalling the writer. The
  caller may retry after `rime gc`, or stream in smaller puts.
- **Spool coupling:** bytes staged in `tmp/` count against `spool_cap`
  while staged; the hot-class reservation covers the final object size.
  A put whose staged bytes alone exceed `spool_cap` fails fast with
  `StoreFull{ class = "spool" }` before writing (protects against a single
  pathological artifact wedging every concurrent build).

### 10.3 The `disk_reserve` floor

Admission checks `free space on the store filesystem − bytes ≥
disk_reserve` (same `statfs` source as implemented
`src/store/disk_usage.zig`) in addition to class caps. Failure returns
`StoreFull{ class = "disk_reserve" }` with current free bytes and the
reserve floor. Emergency trim (§10.6, v1 §9.7 emergency rule kept) covers
space lost to processes outside rime.

### 10.4 What callers see (`StoreFull`)

All admission failures surface as one error with one payload (Zig:
`error.StoreFull`; the detail is returned per call via a
`breakdown: ?*BudgetBreakdown` out-param populated exactly when `StoreFull`
is returned, because Zig errors carry no payload). `store.lastFull()`
remains as a convenience returning the last admission diagnostic on that
Store handle; it is overwritten by the next admission and is racy under
concurrent puts — concurrent callers must use the per-call out-param:

```zig
pub const BudgetBreakdown = struct {
    requested_bytes: u64,
    class: Class,            // hot | cold | index_state | spool | disk_reserve
    budget: u64,             // the total budget
    used_total: u64,         // hot + cold + index_state + spool (reservations incl.)
    used_class: u64,         // class usage incl. reservations
    cap_class: u64,          // the binding cap (or disk_reserve floor)
    reserved_class: u64,     // in-flight reservations against this class
    reclaimable_class: u64,  // unrooted LRU bytes that eviction would free
    hint: Hint,              // .run_gc | .unpin_named (name) | .raise_budget | .free_disk
};
```

CLI rendering (exact fields, `rime build` stderr on cache-write failure):

```
rime: store full admitting 12 MiB to hot (budget 10 GiB, hot 7.0/7.0 GiB,
  reserved 41 MiB, reclaimable 0 B): all hot bytes are rooted;
  unpin one of [release-1.4.2 (1.1 GiB), corpus-main (800 MiB)] or raise store.budget
```

Build-driver rule: a `StoreFull` on a cache *write* never fails the build
(the artifact is still produced; it is delivered via spool and simply not
cached — cache is a hint, v1 §5.3 philosophy extended to writes). A
`StoreFull` on a *root* write (pin/retain/lease-grow) fails the command
with the breakdown above. Exit codes for the cargo surface are unchanged
by cache-write pressure (§13.1).

### 10.5 Idempotency fast path

`put*` hashes first (bytes) or checks existence first exactly as
implemented (`src/store/ingest.zig` fast path): if the object already
exists in either tier, the put succeeds with **no reservation** and only
touches access metadata (1 h throttle, v1 §9.2). Reservation happens only
for bytes that will actually be written. `putManifest`/`putAction` for
existing entries are likewise reservation-free (index row already present;
access timestamps updated).

### 10.6 GC becomes hygiene

With admission enforcing the invariant, `gc` (implemented
`src/store/gc.zig`, phases kept) is re-scoped:

**Order** (first that suffices, then stop; v1 §9.7 order kept, reworded):

1. Expired leases and stale action entries (bookkeeping, zero cost).
2. Age trim: unrooted objects unused > `max_age` (default 90 d, v1 §9.1).
3. Demote hot → cold past `cold_after` (default 7 d, v1 §9.4).
4. Quota sweep: unrooted LRU to ≤ 90% of each class cap (hysteresis kept).
   Incremental sessions participate as ordinary tagged objects (no
   separate sweep; the v1 `sweepIncremental` pass is removed in §14).
5. Emergency: unrooted LRU both tiers until `disk_reserve` restored; if
   roots alone breach it, print the pin list and stop (v1 §9.7 rule kept;
   under v2 this state requires out-of-band writes, §9.2.3).

**Triggers** (v1 §9.7, unchanged): end of build (background, ≤1/hour),
`rime gc` with `--dry-run`/`--to-size`/`--older-than`, and the new
`--tag k=v` scope (§12.2). `gc --dry-run` and `stats` additionally report
`reserved_bytes` and the index-vs-file reconciliation delta (§11.5).

## 11. Metadata and tagging index

### 11.1 Dependency decision (flagged explicitly)

**The index is SQLite, vendored as the sqlite3 amalgamation
(`third_party/sqlite3/sqlite3.c` + `sqlite3.h`, pinned version recorded in
`third_party/sqlite3/VERSION`), compiled into the `store` module via
`build.zig` `addCSourceFile` with `-DSQLITE_THREADSAFE=1`,
`-DSQLITE_DEFAULT_JOURNAL_MODE=WAL`, `-DSQLITE_DEFAULT_SYNCHRONOUS=NORMAL`,
and `-DSQLITE_OMIT_LOAD_EXTENSION`. No system sqlite3, no package-manager
dependency, no `build.zig.zon` package.**

Why vendored amalgamation over the alternatives:

- vs system sqlite3: reproducible builds on macOS + Linux with no host
  dependency; the store must open on a fresh machine with only the rime
  binary (same zero-dependency argument as v1 §12's gzip choice).
- vs LMDB: SQL queryability for tag predicates and `GROUP BY` accounting
  (`stat --by-tag`) without hand-rolled cursors; Pants' LMDB experience
  (research brief) shows the KV path works but leaves every query as
  custom code.
- vs keeping flat files (`kinds.jsonl`, `actions/`): scan cost grows with
  object count on every quota decision; the v1 §12 "SQLite if scans prove
  slow" trigger is pulled now, at spec time, because admission control
  needs O(indexed) eviction-candidate queries on the write path.

Cost accepted: ~9 MB source in-tree, C compilation on every clean build
(cached incrementally; measured impact to be recorded in the implementation
plan, not here). Rollback: content files remain the authority (§8.3); the
index can be deleted and rebuilt (§11.5) with no data loss beyond tag
recall for objects whose tags were never journaled (migration window only).

### 11.2 SQLite schema (exact DDL)

Digests are stored as 64-char lowercase hex `TEXT` (`CHECK(length(x)=64)`);
times are Unix millis `INTEGER`; sizes are bytes `INTEGER`. Kinds are the
§5.2 enum spellings as `TEXT`. Every index connection must execute
`PRAGMA foreign_keys = ON;` on open — the `REFERENCES … ON DELETE CASCADE`
clauses below depend on it (SQLite leaves foreign keys off by default, so
without this pragma cascades silently do not run).

```sql
CREATE TABLE IF NOT EXISTS objects(
  digest         TEXT PRIMARY KEY CHECK(length(digest)=64),
  size           INTEGER NOT NULL CHECK(size>=0),          -- hot bytes (uncompressed)
  compressed_size INTEGER NULL CHECK(compressed_size IS NULL OR compressed_size>=0), -- cold bytes when present
  tier           TEXT NOT NULL CHECK(tier IN ('hot','cold','both')),
  kind           TEXT NOT NULL,
  created_ms     INTEGER NOT NULL,
  last_access_ms INTEGER NOT NULL
) STRICT;
CREATE TABLE IF NOT EXISTS object_tags(
  digest TEXT NOT NULL REFERENCES objects(digest) ON DELETE CASCADE,
  key    TEXT NOT NULL CHECK(length(key)<=32),
  value  TEXT NOT NULL CHECK(length(value)<=256),
  PRIMARY KEY(digest, key, value)
) STRICT;
CREATE TABLE IF NOT EXISTS actions(
  action_key     TEXT PRIMARY KEY CHECK(length(action_key)=64),
  manifest_digest TEXT NOT NULL,                            -- hints only (§5.3); no FK
  created_ms     INTEGER NOT NULL
) STRICT;
CREATE TABLE IF NOT EXISTS pins(
  name         TEXT PRIMARY KEY,
  digest       TEXT NOT NULL CHECK(length(digest)=64),
  created_ms   INTEGER NOT NULL
) STRICT;
CREATE TABLE IF NOT EXISTS leases(
  build_id   TEXT PRIMARY KEY,
  expires_ms INTEGER NOT NULL
) STRICT;
CREATE TABLE IF NOT EXISTS lease_objects(
  build_id TEXT NOT NULL REFERENCES leases(build_id) ON DELETE CASCADE,
  digest   TEXT NOT NULL CHECK(length(digest)=64),
  PRIMARY KEY(build_id, digest)
) STRICT;
CREATE TABLE IF NOT EXISTS retains(
  project_id   TEXT PRIMARY KEY,
  updated_ms   INTEGER NOT NULL
) STRICT;
CREATE TABLE IF NOT EXISTS retain_manifests(
  project_id TEXT NOT NULL REFERENCES retains(project_id) ON DELETE CASCADE,
  manifest   TEXT NOT NULL CHECK(length(manifest)=64),
  PRIMARY KEY(project_id, manifest)
) STRICT;
CREATE TABLE IF NOT EXISTS reservations(
  reservation_id TEXT PRIMARY KEY,
  class          TEXT NOT NULL CHECK(class IN ('hot','cold','index_state','spool')),
  bytes          INTEGER NOT NULL CHECK(bytes>=0),
  created_ms     INTEGER NOT NULL,
  expires_ms     INTEGER NOT NULL,
  owner_build_id TEXT NULL
) STRICT;
CREATE TABLE IF NOT EXISTS tag_budgets(
  key          TEXT NOT NULL,
  value        TEXT NOT NULL,
  soft_cap     INTEGER NOT NULL CHECK(soft_cap>0),
  PRIMARY KEY(key, value)
) STRICT;
CREATE INDEX IF NOT EXISTS idx_tags_kv ON object_tags(key, value);
CREATE INDEX IF NOT EXISTS idx_tags_digest ON object_tags(digest);
CREATE INDEX IF NOT EXISTS idx_objects_access ON objects(last_access_ms);
CREATE INDEX IF NOT EXISTS idx_objects_tier_access ON objects(tier, last_access_ms);
CREATE INDEX IF NOT EXISTS idx_reservations_expiry ON reservations(expires_ms);
CREATE INDEX IF NOT EXISTS idx_leases_expiry ON leases(expires_ms);
```

Conformance notes: `tier='both'` covers the demote/promote staging window
(both copies present; counted once as hot + cold respectively, never
double-counted in the total). `manifest_digest` deliberately has no FK
(stale entries are *found* by absence, v1 §5.3). `STRICT` tables are required
(type errors fail loudly rather than coercing sizes to text).

### 11.3 Tag vocabulary (exact)

| Key | Value format | Example | Set by |
|---|---|---|---|
| `crate` | crate name, `[A-Za-z0-9_-]{1,64}` | `serde` | driver at ingest |
| `crate_version` | semver-ish `[A-Za-z0-9.+_-]{1,32}` | `1.0.200` | driver at ingest |
| `toolchain` | `rustc <version> <sysroot-digest8>` | `rustc 1.82.0 a1b2c3d4` | driver (sysroot lib digests per v1 §5.3) |
| `target` | triple `[A-Za-z0-9_.-]{1,64}` | `aarch64-apple-darwin` | driver |
| `profile` | `debug` \| `release` \| custom `[A-Za-z0-9_-]{1,32}` | `release` | driver |
| `features` | `fh-<16 lowercase hex>` = BLAKE3(sorted `feature1+feature2…`)[0..8] hex | `fh-9c41aa02d1e57f03` | driver (empty set = hash of empty string) |
| `project` | `pb3-<64 hex>` = project-id per §6 | `pb3-af13…` | driver (workspace root hash) |
| `action` | `rustc` \| `build-script` \| `proc-macro` \| `link` \| `other` | `rustc` | driver |
| `user.*` | freeform, suffix follows key rules | `user.ticket=abc-123` | `rime store put --tag` / `rime pin --tag` |

Rules: keys outside this table are rejected (`error.UnknownTagKey`) except
`user.*`. `crate` without `crate_version` (and vice versa) is rejected at
ingest (`error.TagMismatch`) — half-identified crates poison reuse queries.
`features` must match `fh-[0-9a-f]{16}`. Cardinality: one value per key per
object except `user.*` (many). Index size guard: objects with > 32 tags or
tag bytes > 8 KiB total (sum of `length(key) + length(value)`, §5.4 caps)
are rejected before reserving.

Budget-key extension: `tag_budgets.key` additionally accepts the literal
`kind`, which is **not** an object tag — it measures the `objects.kind`
column (§5.2 spellings: `rlib`, `incremental`, …) instead of `object_tags`.
This is what `kind:incremental` (§12.3) binds to. `kind` never appears in
`object_tags` and is never set via `tagObject`; `key = "kind"` rows in
`tag_budgets` join `objects` directly (measurement SQL in §12.3).

### 11.4 Index-size accounting and enforcement

Class usage for `index_state` = `size(index.sqlite) + size(-wal) +
size(-shm) + size(state/)` (§9.3). Enforcement points:

- Every transaction that grows the index checks the cap first; growth
  beyond the cap deletes index rows for already-evicted objects first
  (should be zero — eviction deletes rows in the same transaction) and,
  if still over, compacts via `VACUUM INTO` staged **in `tmp/` under a
  spool-class reservation**: the scratch copy is spool-counted (never
  index_state-counted) and reserved before writing, so the transient
  duplication obeys I-TOTAL via the spool cap (`StoreFull{ class = "spool" }`
  if the scratch copy does not fit). On success the compacted file replaces
  the index and the spool reservation is released; if still over afterwards,
  return `StoreFull{ class = "index_state" }`. Steady-state index writes (one row + ≤10 tag rows per
  put) cannot hit this on any budget ≥ 5 GiB floor; the path exists so the
  invariant has no hole.
- `auto_vacuum = INCREMENTAL` with a post-GC `PRAGMA incremental_vacuum`
  when freelist pages exceed 1,024 (≈4 MiB), so delete-heavy GC actually
  returns file bytes.
- `rime cache stat` prints index bytes split as `db / wal / state/` and
  the row counts (`objects`, `object_tags`, `actions`, roots).

### 11.5 Rebuild and repair story

Content is authoritative; the index is derived except for roots (§8.3):

- **Verify (read-only):** `rime cache verify` scans `objects/` + `cold/`
  (same enumeration as implemented `src/store/scan.zig`, filename = full
  64-hex rule kept) and diffs against `objects` rows: missing rows,
  missing files, size/tier mismatches, and orphan tag rows. Exit 0 clean,
  exit 1 with the diff list otherwise. Never writes.
- **Repair:** `rime cache verify --repair` (1) copies roots tables to
  `state/backup.json` (pins, leases+members, retains+members,
  tag_budgets), (2) replays the tier scan: upsert `objects` rows
  (size/tier from stat, `created_ms`/`last_access_ms` from mtime where
  rows are absent, `kind` from the `kinds.jsonl` journal when present else
  `other`; tags re-attached from `state/tags.jsonl` — the normative v2 tag
  journal: every ingest that records tags appends one JSON line
  `{"digest": "<64hex>", "tags": [["k","v"], …], "created_ms": <int>}`
  after the content rename (fsync with the batch; readers skip malformed
  lines like the `kinds.jsonl` rule, §5.2). Journal bytes count toward
  `index_state` (§9.3) and the file is truncated only by a passing `verify`
  (migration, §14.8) — for exactly this repair purpose), (3) drops `actions`
  rows whose manifest file is gone (v1 stale-sweep rule,
  `src/store/action_cache.zig`), (4) restores roots from backup, (5)
  checkpoints the WAL. Repair prints bytes reconciled and tags lost
  (objects whose tags were never journaled come back untagged →
  evictable-first, §12.2 — the accepted cost flagged in §11.1).
- **Total loss:** delete `index.sqlite*` and run `rime cache verify
  --repair`: full rescan path. Roots are then recovered from
  `state/backup.json` if present, else from the v1 `state/` JSON files
  when they still exist (migration window, §14), else roots are empty
  (GC then treats everything as unrooted — the operator is warned and
  must confirm with `--i-understand-roots-are-empty`).
- **Corrupt content:** `verifyObject` re-hash rule (v1 §5.2 invariant 2,
  implemented `src/store/objects.zig`) is unchanged; corrupt objects are
  quarantine-deleted (rooted or not, with a loud warning: corruption
  breaks the identity contract, keeping the bytes helps nobody) and their
  index rows removed in the same transaction.

## 12. Tag-aware reuse lookup and cleanup policies

### 12.1 Reuse lookup

Two lookup paths, in order (exact-first, tag-second):

1. **Action-key exact hit** (`lookupAction(action_key) -> manifest?`):
   v1 §5.3 semantics unchanged (implemented
   `src/store/action_cache.zig:getAction`). The manifest + referenced
   objects must exist in either tier or the entry is stale (counted, then
   swept per §10.6).
2. **Tag predicate query** (`lookupObjects(predicate, limit) ->
   []digest` ordered by `last_access_ms DESC`): conjunctive equality over
   tag keys with `LIMIT` (default 10, max 1,000). The canonical reuse
   predicate for a rustc unit is
   `crate=X AND crate_version=Y AND toolchain=T AND target=R AND
   profile=P AND features=F AND action=rustc`. `project` is **never**
   part of the reuse predicate (cross-project sharing is the point of the
   global store, v1 §2 goal 1). The driver verifies the winner by digest
   against its own action key before use (tags are hints; digests are
   truth — same trust split as action entries, v1 §5.3).

Index support: `idx_tags_kv` serves one indexed lookup per predicate key
with intersection over digests, ordered via `idx_objects_access`; no table
scan at any object count. (No fixed seek count is promised: cost grows with
predicate arity and the bounded candidate set under `LIMIT`.) `touch` on reuse follows the 1 h throttle (v1 §9.2, implemented
`src/store/scan.zig:touch`).

### 12.2 Cleanup policies and the gc query surface

```
rime gc [--dry-run] [--to-size <bytes>] [--older-than <dur>]
        [--tag <k=v> ...] [--project <id>]
        [--unpin <name>] [--unrooted-all] [--explain]
rime cache stat [--by-tag <key>] [--top <n>]
rime cache ls [--tag <k=v> ...] [--limit <n>]
```

Semantics:

- `--tag k=v` (repeatable, conjunctive) scopes all reclaim phases (§10.6)
  to matching objects. `--project <id>` is sugar for
  `--tag project=<id>`. Scoped GC still never touches roots, still
  reports the unscoped totals alongside so operators see what scoping
  excluded.
- `--explain` prints the reclaim plan per §10.6 with per-tag freed bytes
  ("what this costs": action entries that would go stale, v1 §9.7 rule kept).
- `stat --by-tag <key>` prints `GROUP BY value` bytes/counts using the
  index (no scan). `ls --tag` lists newest-first with sizes.
- **Eviction order inside every phase** (normative): (i) untagged objects
  first (no recall value), (ii) objects in over-soft-budget tags (§12.3),
  LRU within each group, (iii) everything else LRU. Roots are never
  candidates (invariant R-ROOTS, §17).

### 12.3 Per-tag soft budgets

Config form (TOML + env, §15):

```toml
[store.tag_budget]
"crate:serde" = "2GiB"        # key:value pair → soft cap
"project:pb3-af13…" = "10GiB"
"kind:incremental" = "4GiB"   # v1 incremental_limit successor (§13.2)
```

Env: `RIME_TAG_BUDGET_<KEY>_<VALUE>=<size>` (uppercased, non-alnum → `_`).
Stored in `tag_budgets` (§11.2). Semantics (normative):

- Soft: exceeding a tag budget never returns `StoreFull`, never protects
  under-budget tags from eviction when the hard class cap binds.
- Steering: when reclaim needs N bytes, candidates from over-budget tags
  (usage > soft_cap, usage measured by live index bytes per tag-value)
  sort before all other unrooted candidates, LRU within tag. Normative
  per-tag-value byte measure (hot sizes, cold compressed sizes, both copies
  during the `both` staging window):
  ```sql
  SUM(CASE WHEN o.tier = 'cold' THEN COALESCE(o.compressed_size, o.size)
           WHEN o.tier = 'both' THEN o.size + COALESCE(o.compressed_size, 0)
           ELSE o.size END)
  ```
  over `object_tags t JOIN objects o ON o.digest = t.digest` grouped by
  `(t.key, t.value)`; for `key = 'kind'` budgets the same `CASE` expression
  is summed over `objects` grouped by `kind` with no tag join.
- Accounting: `stat --by-tag` marks over-budget tags (`! 2.4/2.0 GiB`).
  Tag usage is the §12.3 `CASE` measure computed from the index (cold rows
  contribute `compressed_size`), reconciled with the filesystem on `verify`.
- Defaults: no tag budgets ship by default except `kind:incremental`
  (`4 GiB`, v1 `incremental_limit` successor) — set automatically on
  migration (§14) so incremental sessions stay bounded while remaining
  ordinary global objects.

## 13. Global-cache-only mandate and cargo-compatible outputs

### 13.1 Cargo compatibility (storage touchpoints)

rime's cargo surface (`build`/`check`/`test`/`run`/`bench`/`clean`,
matching exit codes and conventions per the contract) touches storage
only through: action keys binding toolchain/target/profile/features
(§5.3, §11.3), tagged `rustc`/`build-script`/`proc-macro` objects, and
view materialization into `target/<profile>/` (§7.4). Workspace
membership, lockfile parsing, script execution, and proc-macro loading
rules belong to the driver/resolver specs, not here. Normative storage
rule: **two builds of the same crate version with different
workspaces but identical (toolchain, target, profile, features, inputs)
must resolve to the same store objects** (the `project` tag distinguishes
provenance; it never partitions reuse, §12.1).

### 13.2 Incremental sessions are global objects

Supersedes v1 §9.5 (old → new in §18.2): `state/projects/<id>/incremental/`
is removed. rustc incremental sessions are ingested as ordinary
`kind=incremental` objects tagged with (`crate`, `crate_version`,
`toolchain`, `target`, `profile`, `features`, `project`, `action=rustc`).
They demote like any object, are bounded by the `kind:incremental`
4 GiB soft tag budget by default (§12.3). **Flagged v1 deltas:** (a) the cap
moves from 4 GiB *per project* (v1 §9.5) to 4 GiB *global* — justified by
the global-caches-only contract (§13 preamble): per-project partitions are
the duplicated-cache shape v2 abolishes, and sessions dedup by content hash
so identical sessions across projects now share one object; (b) retention
moves from v1's 5-day incremental sweep to the standard `max_age` (90 d) —
justified because sessions are now ordinary LRU objects under admission
control and the 4 GiB soft budget (not age) is the binding bound; deleting
them still costs only recompilation of changed crates. They are never pushed to the
network cache (compiler-internal format, v1 §3 non-goal kept). Deleting
them costs recompilation of changed crates only (v1 §9.5 rule kept).

### 13.3 Outputs sit outside the budget

`target/<profile>/` binaries (and only the terminal outputs the user
asked for — v1 §4 "view" concept kept) are materialized views, excluded
from every class in §9.3. The store copy of the same bytes is counted
exactly once (hot, never demoted for `bin`, §5.2). Copy-on-write cloning
(v1 §7.1) means the view usually costs no additional disk. `cargo clean`
equivalence deletes views only. The store never writes through a view
path into budgeted bytes, and GC never deletes a view.

### 13.4 Durable user data (`rime store`)

v1 §9.6 `rime store put <file> --as <name>` / `get` semantics kept
(ingest + pin; pinned bytes counted, never auto-evicted), extended with
`--tag user.k=v` (repeatable) so corpora and fixtures participate in
`--tag`-scoped queries. The 37 GB corpus case from v1 §1 remains the
reference: durable data is ordinary pinned content, not a second system.

## 14. Migration from v1 format

`format.json` `{"format":1}` → `{"format":2}`. v2 `open` **refuses**
format 1 with `error.MigrationRequired` (implemented
`src/store/root.zig:open`). Format-to-error contract (normative):

| `format.json` | v1 binary (`open`) | v2 binary (`open`) |
|---|---|---|
| missing / corrupt | `UnknownFormat`, fail closed | `UnknownFormat`, fail closed |
| `{"format":1}` | ok | `MigrationRequired` (run `rime cache migrate`) |
| `{"format":2}` | `UnknownFormat`, fail closed | ok |
| any other value (0, 3, …) | `UnknownFormat`, fail closed | `UnknownFormat`, fail closed |

`MigrationRequired` and `UnknownFormat` are distinct errors in the same
fail-closed family: `MigrationRequired` means "this binary knows the format
but needs migration"; `UnknownFormat` means "this binary does not know the
format". Migration runs
via `rime cache migrate [--dry-run]` (dry run reports every step's byte
counts and deletes nothing — v1 §11 invariant 3 generalized):

1. Preconditions: no live leases (or `--wait` for builds to drain; the
   exclusive `format-lock` is held for the whole migration, v1 §8.2),
   free space ≥ index headroom estimate (`max(256 MiB, 1% of hot bytes)`),
   publishable backup of `state/` (copied to `state/migrate-backup/`).
2. Content untouched: `objects/`, `cold/`, `tmp/` sweep rule, `0o444`
   modes, and fanout paths are identical between formats (v1 §§5.1, 6, 8.1
   unchanged — no byte moves).
3. Index build: full tier scan (implemented `scan` semantics) →
   `objects` rows (size/tier from stat, access times from mtime, `kind`
   from `state/kinds.jsonl` with malformed-line skipping per v1 §5.2,
   else `other`); tags: `kind` row → object tag where known, all other
   tag keys absent (objects come back minimally tagged; untagged-first
   eviction in §12.2 is the accepted transient).
4. Actions import: `actions/` flat files → `actions` table rows, revalidating
   each manifest's existence (stale entries dropped and counted, v1 §9.7
   phase-1 rule). `actions/` dir removed on success.
5. Roots import: `state/pins/*`, `state/leases/*`,
   `state/projects/*.json` → `pins`/`leases`+`lease_objects`/
   `retains`+`retain_manifests` rows (corrupt files: migration aborts
   fail-closed with the filename — v1's skip-and-ignore state rule,
   §8.3, does **not** carry over to roots, §11.5). Source files removed
   on success.
6. Incremental re-homing: `state/projects/*/incremental/` trees are
   ingested as `kind=incremental` objects (content-hash dedup may collapse
   identical sessions to one object), tagged with at least
   (`action=rustc`, retaining project id as the `project` tag from the
   directory name), then the source trees are deleted. The
   `kind:incremental = 4GiB` soft tag budget is installed (§12.3).
   `state/projects/` keeps only retain JSON until step 5 removes them.
7. Budget mapping: `store.hot_limit/cold_limit` config keys become
   deprecated aliases with fully derived caps (normative): if both are set
   (`H`, `C`), `budget = ceil((H + C) / 0.9)` with `hot_cap = H`,
   `cold_cap = C` pinned and `index_state_cap = spool_cap = 5%` of the
   resolved budget (shares sum exactly to `budget`, warning emitted); if
   only `hot_limit = H` is set, `budget = ceil(H / 0.7)` with `hot_cap = H`
   pinned and the remaining three caps at their default shares; if only
   `cold_limit = C` is set, `budget = ceil(C / 0.2)` likewise; if
   unset, `budget = auto` (§9.1). `disk_reserve`, `cold_after`,
   `max_age`, lease TTL, touch interval carry over unchanged.
8. Commit: write `{"format":2}`, checkpoint WAL, `verify` (read-only
   pass, §11.5) must exit 0, delete `state/kinds.jsonl` remnants only
   after verify passes (journal kept as the tag-loss backstop until then).

Rollback: `migrate --dry-run` first; the `state/migrate-backup/` copy plus
untouched content bytes allow re-emitting format 1 state files from the
index (`rime cache migrate --back`) until the operator deletes the
backup. Downgrade: v1 binaries refuse format 2 (`UnknownFormat`, v1 §6
rule kept).

## 15. Configuration and protocol (v2 deltas to v1 §10)

v1 §10.1 config surface is kept; the table below lists v2 changes only
(TOML `rime.toml` + env, durations/sizes syntax unchanged,
`512MiB`/`5GiB`/`7d`/`12h` per implemented `src/store/config.zig`):

| Key | Change |
|---|---|
| `store.budget` | **new**, the one knob (`"auto"` default, §9.1) |
| `store.hot_limit` / `store.cold_limit` | deprecated aliases → budget mapping (§14.7) |
| `store.hot_cap` / `cold_cap` / `index_state_cap` / `spool_cap` | **new** explicit class caps (percent or bytes; must sum ≤ budget) |
| `store.reservation_ttl` | **new**, default `"10m"` (§10.2) |
| `store.tag_budget` table | **new** soft caps (§12.3) |
| `store.incremental_limit` / `incremental_max_age` | **removed** → `kind:incremental` tag budget + `max_age` (§13.2) |
| `project.view_dir` | default changes `rime-out` → `target` (§§6, 7.4) |
| `project.incremental` | **removed** (sessions always global, §13.2) |
| `RIME_BUDGET`, `RIME_RESERVATION_TTL`, `RIME_TAG_BUDGET_*` | **new** env overrides; `RIME_CACHE_DIR`, `RIME_HOT_LIMIT`, `RIME_COLD_LIMIT` (deprecated alias), `RIME_NETWORK_CACHE`, `RIME_PUSH` kept |

Network protocol (v1 §10.2) is unchanged for objects; v2 adds tag/action
replication notes: pushes include the PUT object's tag set (one JSON sidecar
per object, `PUT /objects/<digest>/tags`). Normative order: `PUT`
object bytes first, then `PUT` the tags sidecar; the server applies the
sidecar idempotently. Pulls fetch the object first, then tags, and populate
both the same way. A missing/failed sidecar never fails the transfer — the
object lands untagged (evictable-first per §12.2) and a later sidecar retry
converges; tags are never required for reads. The server enforces its own total budget with the same admission
semantics and never assumes client persistence (v1 §9.8 rules kept).

## 16. Module design (Store interface deltas)

v1 §11 interface is kept; v2 adds admission, index, and lookup. New and
changed methods on `Store` (`src/store/root.zig` grows; new files
`src/store/admit.zig`, `src/store/index.zig`, `src/store/tags.zig`):

```zig
pub const Class = enum { hot, cold, index_state, spool };
pub const Tag = struct { key: []const u8, value: []const u8 };
pub const BuildId = []const u8; // opaque build identifier (lease owner)
pub const Reservation = struct { id: [16]u8, class: Class, bytes: u64 };
pub const Hint = enum { run_gc, unpin_named, raise_budget, free_disk };
pub const BudgetBreakdown = struct { /* fields in §10.4 */ };
pub const Predicate = struct { tags: []Tag, limit: u32 = 10 };
pub const AdmitError = error{ StoreFull, UnknownTagKey, TagMismatch, TagLimit };

pub fn reserve(store: *Store, io: Io, class: Class, bytes: u64, owner: ?BuildId, breakdown: ?*BudgetBreakdown) AdmitError!Reservation;
pub fn commit(store: *Store, io: Io, r: Reservation, digest: Digest) void;
pub fn abort(store: *Store, io: Io, r: Reservation) void;
pub fn lastFull(store: *Store) BudgetBreakdown; // last admission diagnostic; overwritten by next admission (racy under concurrency — prefer `breakdown`)
pub fn lookupObjects(store: *Store, io: Io, gpa: Allocator, pred: Predicate) LookupError![]Digest;
pub fn lookupAction(store: *Store, io: Io, gpa: Allocator, key: Digest) GetError!?ActionEntry; // v1 getAction, index-backed
pub fn tagObject(store: *Store, io: Io, digest: Digest, tags: []const Tag) TagError!void;
pub fn stats(store: *Store, io: Io, gpa: Allocator) StatsError!Stats; // + reserved_bytes, index split, by-tag
```

`putBytes`/`putFile`/`putManifest` keep their v1 signatures plus an optional
`breakdown: ?*BudgetBreakdown` out-param and return
`error.StoreFull` (per-call detail via `breakdown`; `lastFull` is the
single-threaded convenience) instead of overrunning; internal
seams gain **Admit** (reserve/evict/demote policy) and **Index** (SQLite
handle behind a seam with an in-memory fake for tests, mirroring the v1
§11 Materializer/Remote adapter pattern). Key invariants the interface
guarantees (v1 §11 invariants 1–5 kept, plus v2):

6. `reserve` either returns a token with bytes counted in the class or
   returns `StoreFull` with a populated breakdown; no third outcome.
7. After any successful `put*`, I-TOTAL holds (§9.2); tests assert
   `used_total + reserved_total ≤ budget` after every admitted write.
8. `stats` totals reconcile with `du` ± spool staging and WAL bytes;
   `verify` diff is empty after repair.
9. Roots created via `pin`/`leasePut`/`retainProject` are never removed
   by `gc`, scoped or otherwise (R-ROOTS).

## 17. Future work (explicitly out of v2)

v1 §12 items carry over unchanged (RAM tier, REAPI/ByteStream compat, zstd
cold tier behind the codec seam, chunk-level dedup) with one status change:
the SQLite-index item is **done in v2** (removed from this list). Added v2
deferrals: tag-predicate disjunction/negation (conjunctive equality only,
§12.1); cross-machine incremental sessions (still never shared, §13.2);
server-side tag-budget federation (per-client soft caps only, §15).

## 18. Evidence base, supersessions, and citations

### 18.1 Evidence base (research brief, 2026-10-04; v1 §13 carried forward)

- Action-key contents: sccache's Rust key (v1 §13, unchanged; plus
  explicit profile/features binding, §5.3).
- Byte-quota LRU with mtime-order reconstruction: sccache `LruDiskCache`
  (now index-accelerated via `idx_objects_tier_access`, §11.2).
- Age thresholds + 1 h touch throttle: Go `cache.go` (5-day trim, 1-hour
  mtime interval), Gradle (7-day unused removal) — kept as `max_age` 90 d /
  `cold_after` 7 d / `touch_interval_ns` 1 h (v1 §9 values, unchanged).
- 90% hysteresis + 10%-of-disk sizing: Nx cache defaults (kept, §9.1).
- Roots/pins semantics: Nix GC roots; Buck2's action-result lifetime rule
  → entries are hints (both kept, §§5.3, 10.6).
- CAS + ActionResult split: Bazel REAPI `Digest{hash,size}` (kept, §5.3).
- Clone-never-hardlink: APFS `clonefile`/`COPYFILE_CLONE`, Linux `FICLONE`;
  cargo/sccache hardlink corruption reports (kept, §7.1).
- Immutable files + rebuildable index: sccache disk cache, Zig cache
  manifests (kept and strengthened: the index is now real but still
  derived, §11.5); Pants LMDB as the considered KV alternative (§11.1).

### 18.2 Decisions that supersede v1 (old → new)

| # | v1 (storage.md) | v2 (this doc) | Reason |
|---|---|---|---|
| S-1 | §9.1 per-tier limits (`hot_limit auto`, `cold_limit = 2×hot`) bound each tier; no total | §9.1 one `budget auto` + hard class shares (70/20/5/5); per-tier keys deprecated aliases | operators need one number; index/spool escaped the old model (§1.1) |
| S-2 | §9.1 over-limit-by-roots is legal (`over quota by N (pinned)`) | §9.2 roots count; pin/retain/lease-grow fail with `StoreFull` instead | I-TOTAL admits no exceptions; deliberate roots get an explicit refusal + unpin list, not silent debt |
| S-3 | §§9.1/9.7 GC enforces limits (post-facto reclaim) | §§9.2/10 admission enforces; GC is hygiene | bound must hold between operations, not just after GC (§1.1) |
| S-4 | §9.5 project-local `projects/<id>/incremental/` class (4 GiB/project, 5 d) | §13.2 global `kind=incremental` tagged objects + 4 GiB global soft tag budget | global-caches-only contract; per-project dirs are the duplicated-cache shape v1 §1 measured |
| S-5 | §5.4 `rime-out/` view + `target/` user-data ambiguity | §§6/7.4/13.3 `target/<profile>/` views, excluded from budget; user data via `rime store` pins (§13.4) | cargo drop-in requires `target/`; budget requires views excluded |
| S-6 | §8.3 no authoritative index; corrupt state files ignored | §8.3 split durability: content + root rows authoritative (fail closed), derived rows rebuildable | admission + lookup need an index worth trusting; roots fail closed instead of silently dropping |
| S-7 | §6 `state/` JSON files + `kinds.jsonl` + `actions/` flat files | §11 SQLite tables; flat files removed post-migration (§14) | O(indexed) admit/evict/lookup at scale; scan-per-decision does not survive ~1 M objects (§1.2) |
| S-8 | §9.7 unscoped LRU-only reclaim | §12.2 `--tag`/`--project` scoping + untagged-first/over-budget-first order; §12.3 soft tag budgets | operators need scoped cleanup ("this crate is eating disk") without new mechanisms |
| S-9 | §10.1 `hot_limit`/`cold_limit`, `incremental_*`, `view_dir=rime-out` | §15 `budget`, class caps, `reservation_ttl`, `tag_budget`; `view_dir=target`; incremental keys removed | config follows the model change; mapping in §14.7 |

### 18.3 V1 sections that still hold (citation index)

Unchanged: §§1–4 (problem/goals/non-goals/architecture shape, extended by
§§1–4 here), §5.1 digests, §5.2 object invariants + kinds base list,
§5.3 manifests/actions, §§7.1–7.3 materialization, §8.1 atomic ingest,
§8.2 locking base, §§9.1/9.4/9.7 exact values carried into §§9–10
(`auto` formula, `disk_reserve`, gzip-6, `bin`/`dylib` exclusion,
hysteresis 90%, `cold_after` 7 d, `max_age` 90 d, lease TTL 2 h, touch
throttle 1 h), §9.6 durable store, §9.8 network policy, §10.2 protocol
base, §11 interface/invariants 1–5, §12 future items (minus SQLite),
§13 evidence.
