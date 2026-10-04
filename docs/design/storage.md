# rime storage design — shared, bounded, content-addressed build storage

**Status:** draft spec for the storage core (subsystem 1 of the build orchestrator).
**Scope of this doc:** how rime stores build artifacts, how that storage is shared
across projects and machines, and exactly how storage limits are planned,
enforced, and reclaimed. Manifest/resolution and the rustc driver are separate
subsystems; this doc only defines what they *consume* (the Store interface).

---

## 1. Problem

A cargo `target/` directory is a private, project-local cache. Nothing is shared
between checkouts or projects, so the same dependency artifacts exist once per
project. Measured on a real developer machine (2026-10, macOS/APFS):

| Observation | Size |
|---|---|
| `target/` across ~15 repos | **270 GB** |
| worst single `target/` | 118 GB |
| `deps/` + `incremental/` across all repos | ~94 GB |
| one project's `target/debug/incremental` | 5.7 GB |
| `~/.cargo` (registry + git, already shared) | 7.4 GB |

The shared part of the cargo universe is tiny; the duplicated part is enormous.
Two structural causes:

1. **No global identity for artifacts.** An `rlib` for `serde-1.0.200` built with
   the same toolchain/flags is byte-identical across projects, but cargo stores
   one copy per project per profile.
2. **No storage limits, no reclaim policy.** `target/` grows until the disk
   fills; `cargo clean` is all-or-nothing per project. Users manage disk space
   by hand (deleting `target/` dirs wholesale, losing all cached work).

A third, non-cache category also lives in `target/` in practice (observed: a
37 GB corpus directory): user data parked next to build outputs. A storage
design must not silently delete it (§9.6).

## 2. Goals

1. **One copy per artifact per machine.** All projects share a single global
   content-addressed store; identical outputs are stored exactly once.
2. **Bounded storage, always.** Every byte rime owns is under a configured
   limit with a defined behavior when the limit is reached. No unbounded growth.
3. **Predictable reclaim.** Reclaim is automatic (quota/age), explicit
   (`rime gc`), and explainable (`rime gc --explain`, `rime cache stat`). Users
   can always answer "what is taking space and what will deleting it cost me?".
4. **Memory sharing for free.** Artifacts are immutable files served read-only;
   all processes share one physical copy through the OS page cache. No daemon
   required for this. (A RAM-resident hot tier is a possible later addition, §12.)
5. **Team sharing.** The same store model extends to a network cache so a team
   shares artifacts the same way a machine does.
6. **Crash-safe, self-healing.** The store's authoritative state is immutable
   files; any index is rebuildable. A killed build never corrupts the store.

## 3. Non-goals

- Remote *execution* (the network cache stores artifacts, it does not run builds).
- Sharing rustc incremental-compilation sessions across machines (compiler
  internal format; kept as a bounded, project-local, aggressively trimmed
  class, §9.5).
- Deduplication *within* a blob (whole-object granularity only).
- Windows support (macOS + Linux for v1; the platform seam is §7.2).

## 4. Architecture overview

```
                ┌───────────────────────────────────────────────┐
   build tool   │                 Store (deep module)           │
   (rustc       │  put / get / materialize / pin / gc / stats   │
    driver,     ├───────────────────────────────────────────────┤
    resolver)   │ ingest  object  manifest  materialize  state  │
                │ scan    gc      cold      action      remote  │
                └──────────┬────────────────────────┬───────────┘
                           │                        │
                ┌──────────▼──────────┐   ┌─────────▼──────────┐
                │  local store (CAS)  │   │  network cache     │
                │  hot / cold tiers   │   │  (HTTP CAS, same   │
                │  + state (pins,     │   │   object model;    │
                │  leases, actions)   │   │   optional push)   │
                └─────────────────────┘   └────────────────────┘
```

The **Store** is the deep module: the build tool knows `put/get/materialize/
pin/gc/stats` and nothing about layouts, compression, cloning, or eviction.
Everything else is behind that interface (§11).

A project's build output directory (`rime-out/`, replacing `target/`) is a
**view** of the store, not a store: it contains only what the user asked for
(final binaries and other terminal artifacts), materialized by copy-on-write
clone where possible. It can be deleted at any time and regenerated from the
store.

## 5. Content model

### 5.1 Digests

- Hash: **BLAKE3**, 32 bytes (`std.crypto.hash.Blake3`).
- Text form: `b3-<64 lowercase hex>`. On-disk path: `objects/<hex[0..2]>/<hex[2..]>`.
- Objects are identified by the digest of their **exact bytes**. No
  normalization. (Action keys — §5.3 — are a separate namespace.)

### 5.2 Objects

An object is an immutable file in the store. Invariants:

1. Once published, bytes never change. Publication is atomic (§8.1).
2. Stored mode is read-only (`0o444`). The store never writes through an
   object path; ingestion always writes a temp file and renames.
3. Reading an object never updates its bytes; it may update access metadata
   (§9.2).
4. Objects are stored **uncompressed in the hot tier**, gzip-compressed in the
   cold tier (§9.4). The digest is always of the uncompressed bytes.

Kinds (metadata only, informs tiering/eviction, §9.4): `rlib`, `rmeta`, `obj`,
`staticlib`, `dylib`, `bin`, `dep_info`, `manifest`, `build_script_out`,
`source`, `other`.

### 5.3 Manifests and action results (REAPI-shaped)

- A **manifest** is a JSON object describing one atomic output set (e.g. all
  files one rustc invocation produced). Manifests are themselves objects:

```json
{
  "format": 1,
  "kind": "rustc",
  "outputs": [
    { "path": "libfoo.rlib", "digest": "b3-…", "size": 8123123, "mode": 420 },
    { "path": "foo.d",       "digest": "b3-…", "size": 412,     "mode": 420 }
  ]
}
```

- An **action key** hashes everything that determines an action's outputs:
  toolchain identity (rustc version + sysroot lib digests), target triple,
  normalized arguments, relevant environment, and the digests of all inputs
  (sccache's Rust key is the reference design). This is deliberately the same
  key space cargo-cache tools use, so keys survive tool upgrades only when
  inputs change.
- An **action entry** maps `action key -> manifest digest`. Action entries are
  *hints*: an entry is valid only while its manifest and referenced objects
  exist. GC never needs to understand them; a stale entry degrades to a
  rebuild (§9.3).

### 5.4 What goes where

| Content | Location | Class |
|---|---|---|
| dependency artifacts (rlib, rmeta, proc-macro dylib) | global store objects | shareable |
| build-script outputs | global store objects (keyed incl. env) | shareable |
| dep-info, output manifests | global store objects | shareable |
| final user binaries | project view (materialized) + store copy | shareable, materialized |
| incremental sessions | store `projects/<id>/incremental/` | project-local class |
| user data (corpora etc.) | **never auto-deleted**; `rime store`/pins, §9.6 | durable |
| fetched dependency sources | store objects, `source` kind | shareable |

Rustc consumes dependency artifacts **directly from store paths** (`--extern
name=<store path>`); inputs are read-only so no materialization is needed. Only
terminal outputs (binaries the user runs) are materialized into the project
view. This is why the project directory shrinks to roughly "the things you ship".

## 6. The store on disk

```
$RIME_CACHE_DIR/                     # default: XDG cache dir / rime
  format.json                        # {"format": 1} — refuse to operate on unknown formats
  objects/ab/cdef…                   # hot tier: immutable objects (0444)
  cold/ab/cdef…                      # cold tier: same digest names, gzip container
  actions/ab/cdef…                   # action key -> {"manifest": "b3-…", …}
  tmp/                               # in-flight writes; safe to delete on start
  state/
    pins/<name>                      # one JSON file per pin (root)
    leases/<build-id>                # one JSON file per live build (root, TTL)
    projects/<project-id>.json       # per-project retains + accounting
  format-lock                        # advisory lock file for GC vs. builds (§8.2)
```

`project-id` = BLAKE3 of the normalized workspace path (privacy: no paths in
the store). `rime-out/last-build.json` maps the project to its current
manifest digests.

## 7. Materialization semantics

### 7.1 Clone-first, copy-always-fallback, never hardlink

Materializing object `D` to path `P`:

1. **Clone** (APFS `clonefile` / `copyfile(COPYFILE_CLONE)` on macOS;
   `ioctl(FICLONE)` on Linux when the FS supports reflink). Nearly free, true
   CoW: later writes to `P` do not touch the object.
2. **Byte copy** when cloning is unsupported (e.g. ext4). Write to `P.tmp…`,
   fsync, rename to `P`.
3. **Never hardlink** into a mutable destination: a build or user mutating a
   hardlinked file corrupts the store for every project (the known cache
   corruption class in cargo/sccache reports). Hardlinks are only permitted
   inside the store itself.

Capability is probed once per (device, filesystem) pair by cloning a test
object, and cached in-process. Failure of a clone attempt falls back to copy
and records the pair as copy-only. Cloned files are verified by the caller only
in `rime cache verify`, not on every materialize.

### 7.2 Platform seam

One internal function table, two adapters (Darwin, Linux), selected at
compile time:

```
clone(src_path, dest_path) -> CloneResult   // .cloned | .copied | .failed
```

Both adapters share the atomic-publish protocol; tests exercise the
fallback path by forcing `.copied` (§11).

### 7.3 Read-only inputs

Passing store paths to external tools is safe because objects are immutable
and read-only. If a tool demands a writable file (rare; e.g. some build
scripts patch their inputs), the *caller* materializes a private copy into the
build's spool dir — the store never relaxes immutability.

## 8. Concurrency and crash safety

### 8.1 Atomic ingest

```
write tmp/<random>  →  hash while writing  →  fsync  →  chmod 0444
  →  rename into objects/xx/<digest>
  →  (rename with the target existing = someone else won the race: delete tmp, success)
```

A reader sees either no object or a complete, verified object. `tmp/` is swept
on store open (any file older than the sweep is garbage from a dead process).

### 8.2 Locking

- **Builds** hold a shared advisory lock on `format-lock` while ingesting.
- **GC** takes an exclusive lock; if a build holds the shared lock, GC defers
  (tried again at the next trigger; `rime gc` forces by waiting).
- Object publication is lock-free w.r.t. GC: worst case an object is evicted
  between rename and lease registration, which is prevented by registering the
  lease *before* ingestion begins (leases list expected output digests when
  known, else the build id and a TTL that keeps *all* of that build's outputs
  alive — see §9.3).

### 8.3 Index durability

There is no authoritative index database in v1 (§12). The authoritative state
is: objects + `state/` + `actions/` files. Everything is plain files written
atomically. A corrupt/partial state file is ignored and rebuilt from
`rime-out/last-build.json` where possible.

## 9. Storage limits and management

This is the heart of the tool: every byte rime owns is in a **class** with a
**limit** and a defined **reclaim order**.

### 9.1 Limit model

| Limit | Default | Meaning |
|---|---|---|
| `hot_limit` | `auto` = clamp(10% of free space, 5 GiB, 50 GiB) | hot tier ceiling |
| `cold_limit` | `auto` = 2 × `hot_limit` | cold tier ceiling |
| `disk_reserve` | max(5 GiB, 5% of FS size) | never let the FS fall below this free |
| `ram_limit` | `0` (off) | reserved for future RAM tier (§12) |
| `incremental_limit` | 4 GiB per project | incremental class ceiling |
| `incremental_max_age` | 5 days | unused incremental is deleted |

Rationale for the defaults: Nx caps its cache at 10% of cache disk capped at
10 GB and evicts to 90%; Go trims build-cache entries unused for 5 days;
Gradle removes unused build-cache entries after 7 days; sccache's local LRU
default is 10 GB. The `auto` formula keeps a laptop's store modest (≈10–50 GiB
hot) while letting a build server opt into hundreds of GB explicitly. All
limits are settable in `rime.toml`/env (§10) and shown by `rime cache stat`.

**Hysteresis:** quota reclaim evicts until usage ≤ **90%** of the limit
(Nx-style), so steady-state inserts don't trigger GC on every build.

**Over-limit is possible only by roots** (pins/leases): rooted objects are
never evicted, so a store with 60 GiB of pins on a 50 GiB limit is legal;
`rime cache stat` reports `over quota by 10 GiB (pinned)` and lists pins by
size. This is the "manage around it" story: limits steer automatic reclaim,
pins are deliberate, and the tool always tells you which one is binding.

### 9.2 Access tracking

- LRU order is **mtime of the object file**, updated on access (a read or a
  cache hit) at most **once per hour** per object (Go's `mtimeInterval = 1h`
  precedent; avoids write amplification).
- No read-time index write at all in v1: a store scan sorts objects by mtime.
  Scan cost is bounded by GC frequency (§9.7), not by build frequency.
- `atime` is not used (unreliable: `noatime`/`relatime` mounts).

### 9.3 Roots: what is never automatically evicted

A rooted object survives any quota/age reclaim. Roots are exactly:

1. **Pins** — user-declared, persistent, one file per pin in `state/pins/`.
   `rime pin <digest> --as my-corpus`. Pins are the durable-storage mechanism
   (§9.6) and team-release anchors (§9.8).
2. **Leases** — per-build liveness, `state/leases/<build-id>`, TTL 2 h,
   renewed on each completed action. A lease names the digests the build has
   produced or will produce. Expired leases are deleted at the start of GC.
3. **Project retains** — each project's last successful build manifests
   (`retain_last_build = true` default), so `rime gc` never forces a full
   rebuild of currently-checked-out work.

Reachability is **flat** (a root lists digests directly; manifests referenced
by retained builds are walked one level to retain their outputs). This is
deliberately shallower than Nix's full closure GC: build artifacts are
rebuildable, so the cost of over-collecting is a rebuild, not a broken system.

### 9.4 Tiering: hot → cold

- Objects not accessed for `cold_after` (default 7 days) are **demoted** to the
  cold tier: gzip-compressed (level 6, `std.compress.flate`) into
  `cold/xx/<digest>`, then the hot copy is deleted. Digest stays the digest of
  the uncompressed bytes.
- Kinds `bin` and `dylib` are never demoted (they are executed/loaded; the
  materialize path would otherwise decompress on every run). Everything else
  is demotable.
- Reads are transparent: `get` decompresses to a buffer or to a materialize
  destination. Demotion is counted at its **compressed** size for quota.
- If the cold tier is full, demotion first evicts cold-tier LRU (unrooted).

### 9.5 Incremental state (project-local class)

rustc incremental sessions (`dep-graph.bin`, `query-cache.bin`,
`work-products.bin`, work products) are compiler-internal, tied to exact
session configuration, and were measured as the #2 space consumer after
`deps/`. Policy:

- Stored under `projects/<id>/incremental/` (not in the shared object space;
  keys are not portable across projects per rustc docs).
- Bounded by `incremental_limit` (4 GiB/project) and `incremental_max_age`
  (5 days), trimmed oldest-first. Deletable at any time; costs recompilation
  of changed crates only.
- Opt-out per project: `rime build --no-incremental` / config.

### 9.6 Durable data (non-cache) — `rime store`

The observed 37 GB corpus-in-`target/` case: data that must survive GC because
it is *not a cache artifact*. `rime store put <file> --as <name>` = ingest into
the store + create a pin. `rime store get <name> [--out <path>]` materializes
it. Durable objects are ordinary objects with a root — same storage, same
limits accounting, exempt from automatic reclaim because pinned (§9.1
over-limit-by-roots rule applies). This avoids a second storage system.

### 9.7 Reclaim: triggers, order, explain

**Triggers**
- End of every build (background, skipped if another GC ran in the last hour).
- Hourly when idle (optional `rime daemon` later; v1: opportunistic only).
- `rime gc` (explicit; `--dry-run`, `--to-size <bytes>`, `--older-than <dur>`,
  `--unpin <name>`, `--unrooted-all`).
- **Emergency trim** whenever free space on the store's filesystem drops below
  `disk_reserve` at any trigger point.

**Order** (first that frees enough, then stop):
1. Expired leases and stale action entries (bookkeeping, zero cost).
2. Age trim: unrooted objects unused > `cold_max_age` (90 days), both tiers.
3. Demote hot → cold (freeing hot space; §9.4).
4. Quota sweep: unrooted objects by LRU (oldest mtime first) until ≤ 90% of
   the tier's limit. Incremental class swept first within its own limit.
5. Emergency: unrooted LRU both tiers until `disk_reserve` is restored;
   if roots alone keep the FS below reserve, print the pin list and stop
   (never auto-unpin).

**Explainability.** `rime gc --dry-run` prints the exact reclaim plan (bytes
per class, count of objects, and "what this costs": action entries that would
go stale). `rime cache stat` prints tier usage vs limits, root usage (pins by
name/size, live leases, retained projects), top-10 largest objects, and the
binding constraint.

### 9.8 Network cache and team limits

- The network cache stores the same objects (digest-addressed; §10.2 protocol).
- **Client policy** (`push`): `never` (pull-only), `manual` (`rime cache push`),
  `on-build` (upload outputs of successful actions). Pull is always
  read-through: miss locally → fetch → local ingest.
- **Server-side quota is independent** (server runs the same GC engine with
  its own limits; team cache typically 100s of GB). The client never assumes a
  remote object persists: local store is the only required tier.
- **Team roots**: a pin pushed with `--publish` becomes a server-side root
  (release anchors: e.g. a CI-published manifest pins the binaries of a
  release so server LRU cannot evict them). Unpublishing removes the root.

## 10. Configuration and protocol

### 10.1 Config (rime.toml, env overrides)

```toml
[store]
dir          = "…"              # default: XDG cache dir / rime
hot_limit    = "auto"           # or "50GiB", "10GiB", …
cold_limit   = "auto"
disk_reserve = "auto"
cold_after   = "7d"
max_age      = "90d"

[store.network]
url   = "https://cache.example.com"
push  = "manual"                # never | manual | on-build

[project]
incremental       = true
incremental_limit = "4GiB"
view_dir          = "rime-out"
```

Env: `RIME_CACHE_DIR`, `RIME_HOT_LIMIT`, `RIME_COLD_LIMIT`, `RIME_NETWORK_CACHE`,
`RIME_PUSH`. Durations/sizes accept `512MiB`, `5GiB`, `7d`, `12h`. Config
discovery and TOML parsing belong to the config module (a minimal TOML subset:
sections, string/bool/int/duration/size values).

### 10.2 Network protocol (v1: plain HTTP CAS)

```
HEAD /objects/<digest>        -> 200 | 404
GET  /objects/<digest>        -> 200 (bytes) | 404
PUT  /objects/<digest>        -> 201 (stored) | 200 (already present) | 409 (digest mismatch)
POST /objects/exists          -> {"missing": ["b3-…", …]}     # batch probe
PUT  /pins/<name>?digest=…    -> 201 | 403                     # publish team root
```

Server verifies every uploaded digest; `GET`/`PUT` are plain object bytes
(gzip content-encoding for cold-tier objects is separate from HTTP encoding).
TLS via `std.http.Client`/`Server`. A later revision can add REAPI
compatibility; the object model (§5) is already REAPI-shaped.

## 11. Module design (interfaces)

The storage core is one Zig module, `rime/store/`. Tests are inline (`zig
build test`); every module is testable through its own interface.

**Store** — the deep module the build tool uses:

```zig
// rime/store/root.zig
pub const Store = struct {
    pub fn open(io: Io, dir: Dir, config: Config) OpenError!Store;
    pub fn close(store: *Store, io: Io) void;

    pub fn putFile(store: *Store, io: Io, src: Io.File, kind: Kind) PutError!Digest;
    pub fn putBytes(store: *Store, io: Io, bytes: []const u8, kind: Kind) PutError!Digest;

    pub fn exists(store: *Store, io: Io, digest: Digest) bool;
    pub fn readObject(store: *Store, io: Io, digest: Digest, gpa: Allocator) ReadError![]u8;

    /// clone-or-copy into dest; never hardlinks. Returns how it was written.
    /// `mode` is the final file mode (e.g. 0o755 for executables, 0o444 otherwise).
    pub fn materialize(store: *Store, io: Io, digest: Digest, dest_path: []const u8, mode: u32) MaterializeError!MaterializeMethod;

    pub fn putManifest(store: *Store, io: Io, manifest: Manifest) PutError!Digest;
    pub fn getManifest(store: *Store, io: Io, gpa: Allocator, digest: Digest) ReadError!Manifest;

    pub fn pin(store: *Store, io: Io, name: []const u8, digest: Digest) StateError!void;
    pub fn unpin(store: *Store, io: Io, name: []const u8) StateError!void;
    pub fn leasePut(store: *Store, io: Io, build_id: []const u8, digests: []const Digest) StateError!void;
    pub fn leaseRenew(store: *Store, io: Io, build_id: []const u8) StateError!void;
    pub fn leaseDrop(store: *Store, io: Io, build_id: []const u8) StateError!void;
    pub fn retainProject(store: *Store, io: Io, project: ProjectId, manifests: []const Digest) StateError!void;

    pub fn gc(store: *Store, io: Io, gpa: Allocator, policy: GcPolicy) GcError!GcReport;
    pub fn stats(store: *Store, io: Io, gpa: Allocator) StatsError!Stats;

    // Also implemented (see src/store/root.zig): verifyObject, putAction/getAction,
    // demote/promote (cold tier), tryGcLock/unlock (GC exclusion, §8.2).
};
```

Internal seams (implementation detail of `Store`, exposed only to its own
tests):

- **Materializer** — clone/copy strategy table (§7.2). Two adapters
  (`.clone_first`, `.copy_only`), injectable in tests to force fallback.
- **Tiers** — hot file vs cold gzip file behind one `read`/`demote`/`promote`
  surface; compression codec is an internal choice (gzip v1).
- **StateStore** — pins/leases/retains as atomic JSON files.
- **Remote** — `exists/get/put` trait with `Null` and `Http` adapters (two
  adapters = real seam). Store degrades to local-only when remote fails.

Key invariants the interface guarantees (and tests assert):

1. `put*` is idempotent: same bytes → same digest, stored once.
2. `materialize` never mutates or links mutably to store objects; source object
   bytes are unchanged after the destination is written or modified.
3. `gc` never deletes rooted objects; `gc(.dry_run)` deletes nothing.
4. After `gc` with default policy, tier usage ≤ 90% of each limit unless roots
   alone exceed it.
5. `stats` totals match `du` of the store directory (± tmp files).

## 12. Future work (explicitly out of v1)

- **RAM-resident hot tier** (`rime cached` daemon; `ram_limit`): the page cache
  already shares read-only objects across processes, so this is only for
  latency (avoid decompression/IO) — deferred until measurements say it matters.
- **SQLite/LMDB index** for O(1) quota queries if store scans prove slow
  (>~1 M objects); the flat-file store is authoritative either way.
- **REAPI/ByteStream** compatibility for the network cache.
- **zstd** cold tier (std has decompression only in Zig 0.16; compressor must be
  linked or vendored). Gzip via `std.compress.flate` is the zero-dependency v1
  choice; the codec sits behind the Tiers seam.
- **Chunk-level dedup** for very large near-duplicate objects (corpora).

## 13. Evidence base

Design choices traced to researched prior art (research brief, 2026-10-04;
full citations in `.pi-subagents/` output `research.md`):

- Action-key contents: sccache's Rust key (compiler identity + normalized
  args + source/dep digests + relevant env).
- Byte-quota LRU with mtime-order reconstruction: sccache `LruDiskCache`.
- Age trimming thresholds and hourly access-touch throttle: Go `cache.go`
  (5-day trim, 1-hour mtime interval), Gradle (7-day unused removal).
- 90% hysteresis and 10%-of-disk sizing: Nx cache defaults.
- Roots/pins semantics: Nix GC roots (reachability beats blind LRU for
  named/released artifacts); Buck2's "action results must not outlive CAS
  objects" → action entries are hints, never roots.
- CAS + ActionResult split: Bazel REAPI (`Digest{hash,size}`, CAS blobs).
- Clone-never-hardlink materialization: APFS `clonefile`/`COPYFILE_CLONE`,
  Linux `FICLONE`; cargo/sccache hardlink corruption reports.
- Immutable flat files + rebuildable index: sccache disk cache, Zig cache
  manifests, Pants LMDB (as the counterexample to weigh if scans get slow).
