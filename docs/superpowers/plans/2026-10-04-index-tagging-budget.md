# Index, Tagging & Budget Implementation Plan (Plan B — v2 Storage Upgrade)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:delegate (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Upgrade the v1 flat-file store to v2: a vendored-SQLite metadata + tagging index, a tagging API on `Store`, write-time admission control under one total budget, tag-aware GC, and the matching CLI additions — with zero breaking changes to existing `Store` method signatures and an automatic v1→v2 migration.

**Architecture:** One new deep submodule, `index` (SQLite-backed: `objects`/`object_tags`/`actions`/`pins`/`leases`+`lease_objects`/`retains`+`retain_manifests`/`reservations`/`tag_budgets` per storage-v2 §11.2), sits beside the existing `scan`/`state`/`action_cache` modules; `Store` gains additive methods using the storage-v2 §16 names (`tagObject`, `lookupObjects(Predicate)`, `lookupAction`, `reserve`/`commit`/`abort`/`lastFull` internals) while every v1 method keeps its exact signature. A `budget` module enforces reserve-before-write admission (evict → demote → `StoreFull` with `BudgetBreakdown`); GC becomes a hygiene pass that queries the index instead of scanning the filesystem. Migration (`migrate` module) is an explicit `rime cache migrate [--dry-run]` command that bumps `format.json` 1→2 and imports the `kinds.jsonl` journal, flat action files, `state/` JSON files, and incremental trees into SQLite exactly once (`Store.open` refuses format 1 with `error.MigrationRequired`, storage-v2 §14).

**Tech Stack:** Zig 0.16.0 (std + vendored SQLite3 amalgamation compiled via `build.zig` `addCSourceFile` — see Global Constraints for the flagged dependency decision), BLAKE3 via `std.crypto.hash.Blake3`, gzip via `std.compress.flate`. macOS + Linux.

**Spec:** `docs/design/storage.md` §§5–11 (content model, on-disk layout, materialization, concurrency, limits/management, config, module interfaces). This plan argues from the spec; executors read both. v1 baseline: `docs/superpowers/plans/2026-10-04-storage-core.md` Tasks 1–13 and code under `src/store/`.

## Global Constraints

- Zig **0.16.0** exactly. Every API call in this plan was verified against the v1 plan's `zig version` 0.16.0 patterns; stay within these verified patterns:
  - FS access goes through the `std.Io` interface value passed as `io` to every call.
  - `std.Io.Dir`/`std.Io.File` methods take `io` (position varies per method — copy call sites from this plan exactly).
- Dependencies: **std + exactly one vendored C source**: the SQLite3 amalgamation (`vendor/sqlite3.c`, `vendor/sqlite3.h`), compiled via `build.zig` `addCSourceFile`. **DEPENDENCY DECISION (flagged explicitly per contract):** we vendor rather than link system sqlite3 because (1) macOS ships a version-skewed libsqlite3 with no stability promise for `sqlite3_prepare_v3`/`unlikely()` behaviors we rely on, (2) a single-file amalgamation keeps `rime` a zero-install binary (cargo drop-in story), (3) the C file is never hand-edited — upgrades are whole-file drops recorded in `vendor/README.md`. Cost accepted: ~9 MB added source, ~1–2 s added build time, and the executor must compile with `-DSQLITE_THREADSAFE=1 -DSQLITE_DEFAULT_JOURNAL_MODE=WAL -DSQLITE_DEFAULT_SYNCHRONOUS=1 (=NORMAL) -DSQLITE_OMIT_LOAD_EXTENSION` (storage-v2 §11.1 normative flags). No packages in `build.zig.zon` except what `zig init` generates. No other C code.
- Tests are inline (`test "…"` blocks). `zig build test` must pass before **every** commit. Never commit with failing tests.
- **Additive changes only:** every existing `Store` method signature in `src/store/root.zig` keeps working byte-for-byte (`open`, `close`, `putBytes`, `putFile`, `exists`, `readObject`, `verifyObject`, `materialize`, `scan`, `touch`, `pin`, `unpin`, `leasePut`, `leaseRenew`, `leaseDrop`, `retainProject`, `putManifest`, `getManifest`, `gc`, `tryGcLock`, `unlock`, `demote`, `promote`, `dirHasHot`, `stats`, `putAction`, `getAction`). New surface is new methods/fields only. `GcPolicy` and `Config` gain only defaulted (`= …`) fields.
- Store invariants that must hold after every task (spec §11 + v2 contract): objects immutable and read-only (`0o444`); `put*` idempotent; materialization never hardlinks; `gc(.dry_run)` deletes nothing; rooted objects (pins/leases/retains) are never auto-evicted; **INVARIANT: total store bytes (objects + cold + index + state + in-flight reservations) ≤ total budget at all times.**
- Exact policy values: total budget `auto` = clamp(10% of free space, 5 GiB, 50 GiB); hard class allocations out of the total: **hot 70%, cold 20%, index+state 5%, transient spool 5%** (storage-v2 §9.1 normative; percentages are `budget.zig` constants so one edit retunes them); hysteresis evict-to **90%** of the binding class; touch throttle **1 h** (now an index `last_access_ms` write, still throttled); `cold_after` **7 d**; `max_age` **90 d**; lease TTL **2 h**; per-tag budgets are **optional soft caps** that steer eviction order only (never cause `StoreFull`); `kind:incremental` **4 GiB** global soft tag budget (storage-v2 §§12.3/13.2; not per-project, not age-swept at 5 d).
- Platforms: macOS and Linux. `else => @compileError` in platform shims.
- All VCS operations use **jj** (the repo is jj-managed, colocated with git): `jj status`, `jj log`, `jj diff`, `jj commit <paths> -m "…"`, `jj describe`, `jj new`. Never run git write commands (`git add`, `git commit`, …) and never `jj git push`. Do NOT run any `jj` or `git` commands at all in these tasks — the parent commits for you; each task's final step is left as a "request commit" note instead of a commit command. `jj` auto-snapshots the working copy; `.gitignore` covers `.zig-cache/`, `zig-out/`, `.pi-subagents/`.
- Do not run builds. Write code and tests only; the `Run:` lines in each task are for the executing worker to run, not for the planner.
- Digest text form is `b3-<64 lowercase hex>` in all user-facing output; on-disk path is `objects/<hex[0..2]>/<hex[2..]>` (no `b3-` prefix). Index stores digests as 64-char lowercase hex `TEXT PRIMARY KEY`.
- Scratch experiments go in `/tmp`, never in the repo. Touch ONLY the files listed per task.

---

## Key decisions (locked for this plan)

- **D1 — SQLite, vendored amalgamation, WAL mode, one connection + busy-timeout.** The index DB is `index.sqlite` at the store root (inside the 5% index+state class, counted with `-wal`/`-shm` plus `state/` per storage-v2 §§6/9.3). `journal_mode=WAL`, `synchronous=NORMAL`, `busy_timeout=5000`. One `sqlite3*` handle per `Store`, guarded by the existing `format-lock` discipline (builds hold shared, GC/migration hold exclusive). No connection pool, no prepared-statement cache beyond one struct of `sqlite3_stmt*` prepared at open. Rationale: crash-safety (§8) comes from immutable objects + atomic ingest; the index is rebuildable from a scan, so `NORMAL` is safe and fast.
- **D2 — Total budget with hard class allocations.** One knob `budget` (`auto` default per the formula above; storage-v2 §9.1/`store.budget`) replaces `hot_limit`/`cold_limit` as the enforcement point; `hot_limit`/`cold_limit` config fields remain as deprecated aliases mapped per §14.7 and, when set to `.fixed`, pin their class allocation. Class split: hot 70 / cold 20 / index+state 5 / spool 5 (percent of total). `disk_reserve` unchanged. `StoreFull` fires only when eviction + demotion cannot free a full reservation inside the binding class cap and total (storage-v2 §§9–10).
- **D3 — Admission control wraps ingest, not callers.** `putBytes`/`putFile`/`putManifest` keep their signatures (plus optional `breakdown` out-param); internally they call `admission.reserve(store, io, class, size_hint, owner, breakdown)` before writing temp bytes and `admission.commit`/`admission.abort` after publish/failure (§16 signatures). `size_hint` for `putBytes` is exact; for `putFile` the file is first streamed to `tmp/` (counted as spool-class reservation by upper bound = source length), then renamed — so the invariant holds even for unknown sizes.
- **D4 — Index is the source of truth for metadata; filesystem stays authoritative for bytes.** Reads (`exists`, `readObject`, `getAction`) check the index first and fall back to the filesystem exactly once per miss (self-healing: a found-but-unindexed object is re-indexed on the spot). GC and `stats` read only the index. `kinds.jsonl` stops being written the moment the index lands (Task 8); the file is left on disk for the migration to import, then deleted by the migration.
- **D5 — Tags follow the storage-v2 §11.3 fixed vocabulary.** Keys: `crate`, `crate_version`, `toolchain`, `target`, `profile`, `features`, `project`, `action`, plus freeform `user.*` only. `kind` is an `objects.kind` column value, never an object tag (measured via `tag_budgets` `kind:` rows per §11.3). Rules enforced at ingest: `crate` requires `crate_version` and vice versa (`error.TagMismatch`); unknown non-`user.*` keys rejected (`error.UnknownTagKey`); at most 32 tags per object and at most 8 KiB total tag bytes (`error.TagLimit`). Tag queries are conjunctions (`k=v&k2=v2`); values are exact-match only (no globs — YAGNI, keeps one index shape).
- **D6 — Per-tag budgets are soft caps stored in a `tag_budgets` table**, enforced only as GC eviction-order steering (over-budget tags sort first in the LRU sweep). They never trigger `StoreFull` and never protect anything from eviction.

## File Structure

```
build.zig                  MODIFY: add sqlite3 amalgamation C source to store + exe modules
vendor/sqlite3.c           ADD: upstream amalgamation, never hand-edited (Task 1)
vendor/sqlite3.h           ADD: upstream amalgamation header (Task 1)
vendor/README.md           ADD: version + drop-in upgrade procedure (Task 1)
src/store/root.zig         MODIFY: additive Store methods only (tagObject/lookupObjects/lookupAction/reserve paths,
                             stats Extensions, format_version 2 acceptance); re-exports use storage-v2 §16 names
src/store/layout.zig      MODIFY: format_version 1 -> 2, index.sqlite path const (Task 7)
src/store/index.zig        CREATE: SQLite wrapper — open/schema/CRUD/LRU queries (Tasks 2-4); owns every raw `sqlite3_*` call
src/store/tags.zig         CREATE: Tag/Predicate types + tagObject/untag/query logic over index with §11.3 validation (Task 5)
src/store/budget.zig       CREATE: budget resolution, class splits (70/20/5/5), reserve/commit/
                             abort, StoreFull + BudgetBreakdown per §§10/16 (Tasks 8-9)
src/store/admission.zig    CREATE: ingest wrapper wiring reserve->publish->commit (Task 9; reserve signature per §16)
src/store/migrate.zig      CREATE: v1 -> v2 migration (Tasks 7)
src/store/gc.zig           MODIFY: additive GcPolicy fields (tag filter, per-tag steering),
                             index-driven candidate queries (Task 10)
src/store/stats.zig        CREATE: per-tag breakdown for `stat --by-tag` (Task 11)
src/store/config.zig       MODIFY: additive fields only with exact §15 keys (store.budget, store.hot_cap/cold_cap/index_state_cap/spool_cap, store.reservation_ttl, store.tag_budget; removed incremental/view keys) (Task 8)
src/store/scan.zig         MODIFY: index-first with filesystem fallback (Task 6); nothing removed
src/store/state.zig        MODIFY: mirror pins/leases/retains into index (Task 6); JSON stays
src/store/action_cache.zig MODIFY: index-backed put/get + sweep via index (Task 6)
src/store/ingest.zig       MODIFY: route kind recording + reservation through index/admission (Task 9)
src/main.zig               MODIFY: `cache stat --by-tag`, `gc --tag …` (Task 11)
```

Rules carried over from Plan A: one responsibility per file; each task's tests live inline in the file being implemented; `index.zig` owns every raw `sqlite3_*` call — no other file touches the C API directly.

---

### Task 1: Vendor SQLite amalgamation and wire build.zig

**Files:**
- Create: `vendor/sqlite3.c`, `vendor/sqlite3.h` (upstream amalgamation drop, unmodified), `vendor/README.md`
- Modify: `build.zig` (add C source to both modules)
- Test: inline in `src/store/index_smoke.zig` — deleted at end of Task 2 (scaffolding for one task only)

**Interfaces:**
- Consumes: nothing (first task).
- Produces: C symbol `sqlite3_open_v2` etc. available to Zig via `@cImport(@cInclude("sqlite3.h"))` with include path `vendor/`; `build.zig` gains a shared helper `addSqlite3(module: *std.Build.Module) void`. Later tasks import nothing from this task except the build wiring.

- [ ] **Step 1: Write the failing smoke test**

Create `src/store/index_smoke.zig`:

```zig
const std = @import("std");

const c = @cImport(@cInclude("sqlite3.h"));

test "sqlite3 amalgamation links and opens an in-memory db" {
    var db: ?*c.sqlite3 = null;
    try std.testing.expectEqual(@as(c_int, 0), c.sqlite3_open_v2(
        ":memory:",
        &db,
        c.SQLITE_OPEN_READWRITE | c.SQLITE_OPEN_CREATE,
        null,
    ));
    defer _ = c.sqlite3_close(db);
    try std.testing.expectEqual(@as(c_int, 0), c.sqlite3_exec(
        db,
        "CREATE TABLE smoke(id INTEGER PRIMARY KEY, v TEXT);",
        null,
        null,
        null,
    ));
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test`
Expected: FAIL — `sqlite3.h: No such file or directory` (vendor drop not present, include path not wired).

- [ ] **Step 3: Drop the amalgamation and wire the build**

Download the amalgamation (sqlite.org, version recorded below) into `vendor/sqlite3.c` + `vendor/sqlite3.h` without modifications. Create `vendor/README.md`:

```markdown
# Vendored SQLite3 amalgamation

Version: 3.50.4 (2025-11-11) — update this line on every drop.
Upstream: https://sqlite.org/download.html ("amalgamation" zip).

Upgrade procedure: replace `sqlite3.c` + `sqlite3.h` wholesale, update the
version line above, run `zig build test`. Never hand-edit either file.
Compile flags (in build.zig): -DSQLITE_THREADSAFE=1 -DSQLITE_DEFAULT_JOURNAL_MODE=WAL -DSQLITE_DEFAULT_SYNCHRONOUS=1 (=NORMAL) -DSQLITE_OMIT_LOAD_EXTENSION (storage-v2 §11.1).
```

In `build.zig`, add once near the top:

```zig
fn addSqlite3(m: *std.Build.Module, b: *std.Build) void {
    m.addCSourceFile(.{
        .file = b.path("vendor/sqlite3.c"),
        .flags = &.{
            "-DSQLITE_THREADSAFE=1",
            "-DSQLITE_DEFAULT_JOURNAL_MODE=WAL",
            "-DSQLITE_DEFAULT_SYNCHRONOUS=1",
            "-DSQLITE_OMIT_LOAD_EXTENSION",
            "-O2",
        },
    });
    m.addIncludePath(b.path("vendor"));
}
```

and call `addSqlite3(store_mod, b);` after the `store_mod` creation and `addSqlite3(exe_mod, b);` after the `exe_mod` creation. Register the smoke file in `src/store/root.zig`'s test block for this task only: `_ = @import("index_smoke.zig");`.

- [ ] **Step 4: Run test to verify it passes**

Run: `zig build test`
Expected: PASS — smoke test opens `:memory:`, creates `smoke` table.

- [ ] **Step 5: Request commit**

Do not commit (parent commits). Leave the tree with the smoke test green.
(Reviewer: delete `src/store/index_smoke.zig` and its root.zig line in Task 2.)

---

### Task 2: Index module — open, schema, pragmas

**Files:**
- Create: `src/store/index.zig`
- Modify: `src/store/root.zig` (re-export + test block: swap `index_smoke.zig` for `index.zig`), `src/store/layout.zig` (add `index_file = "index.sqlite"` const for the store-root DB per storage-v2 §6)
- Test: inline in `src/store/index.zig`

**Interfaces:**
- Consumes: build wiring from Task 1; `layout.state_dir`.
- Produces: `index.Index` struct with `open(io, store_dir: Io.Dir) OpenError!Index`, `close(idx: *Index) void`, `execAll(idx, sql: []const u8) ExecError!void`; schema constant `index.schema_version: u32 = 1` (index-internal; distinct from store `format.json`). Error set `index.DbError = error{DbOpen, DbExec, DbPrepare, DbStep, DbBusy, OutOfMemory, Unexpected} || Io.Cancelable`. The `schema_sql` constant is the storage-v2 §11.2 DDL verbatim (STRICT tables, `objects.digest` / `object_tags` / `lease_objects` / `retain_manifests` / `reservations`, `tier IN ('hot','cold','both')`, `soft_cap`). Later tasks add statement-level CRUD; only `index.zig` calls `sqlite3_*` directly — no other file touches the C API.

- [ ] **Step 1: Write the failing tests**

Create `src/store/index.zig` with types, schema SQL, and tests only:

```zig
const std = @import("std");

const c = @cImport(@cInclude("sqlite3.h"));

const Io = std.Io;

pub const DbError = error{ DbOpen, DbExec, DbPrepare, DbStep, DbBusy, OutOfMemory, Unexpected } || Io.Cancelable;

pub const schema_version: u32 = 1;

/// Storage-v2 §11.2 DDL verbatim. Digests are 64-char lowercase hex `TEXT`;
/// `tier` includes 'both' for the demote/promote staging window; `STRICT` required.
/// Every connection must run `PRAGMA foreign_keys = ON;` (cascades depend on it).
pub const schema_sql: [:0]const u8 =
    \\CREATE TABLE IF NOT EXISTS objects(
    \\  digest         TEXT PRIMARY KEY CHECK(length(digest)=64),
    \\  size           INTEGER NOT NULL CHECK(size>=0),
    \\  compressed_size INTEGER NULL CHECK(compressed_size IS NULL OR compressed_size>=0),
    \\  tier           TEXT NOT NULL CHECK(tier IN ('hot','cold','both')),
    \\  kind           TEXT NOT NULL,
    \\  created_ms     INTEGER NOT NULL,
    \\  last_access_ms INTEGER NOT NULL
    \\) STRICT;
    \\CREATE TABLE IF NOT EXISTS object_tags(
    \\  digest TEXT NOT NULL REFERENCES objects(digest) ON DELETE CASCADE,
    \\  key    TEXT NOT NULL CHECK(length(key)<=32),
    \\  value  TEXT NOT NULL CHECK(length(value)<=256),
    \\  PRIMARY KEY(digest, key, value)
    \\) STRICT;
    \\CREATE TABLE IF NOT EXISTS actions(
    \\  action_key     TEXT PRIMARY KEY CHECK(length(action_key)=64),
    \\  manifest_digest TEXT NOT NULL,
    \\  created_ms     INTEGER NOT NULL
    \\) STRICT;
    \\CREATE TABLE IF NOT EXISTS pins(
    \\  name         TEXT PRIMARY KEY,
    \\  digest       TEXT NOT NULL CHECK(length(digest)=64),
    \\  created_ms   INTEGER NOT NULL
    \\) STRICT;
    \\CREATE TABLE IF NOT EXISTS leases(
    \\  build_id   TEXT PRIMARY KEY,
    \\  expires_ms INTEGER NOT NULL
    \\) STRICT;
    \\CREATE TABLE IF NOT EXISTS lease_objects(
    \\  build_id TEXT NOT NULL REFERENCES leases(build_id) ON DELETE CASCADE,
    \\  digest   TEXT NOT NULL CHECK(length(digest)=64),
    \\  PRIMARY KEY(build_id, digest)
    \\) STRICT;
    \\CREATE TABLE IF NOT EXISTS retains(
    \\  project_id   TEXT PRIMARY KEY,
    \\  updated_ms   INTEGER NOT NULL
    \\) STRICT;
    \\CREATE TABLE IF NOT EXISTS retain_manifests(
    \\  project_id TEXT NOT NULL REFERENCES retains(project_id) ON DELETE CASCADE,
    \\  manifest   TEXT NOT NULL CHECK(length(manifest)=64),
    \\  PRIMARY KEY(project_id, manifest)
    \\) STRICT;
    \\CREATE TABLE IF NOT EXISTS reservations(
    \\  reservation_id TEXT PRIMARY KEY,
    \\  class          TEXT NOT NULL CHECK(class IN ('hot','cold','index_state','spool')),
    \\  bytes          INTEGER NOT NULL CHECK(bytes>=0),
    \\  created_ms     INTEGER NOT NULL,
    \\  expires_ms     INTEGER NOT NULL,
    \\  owner_build_id TEXT NULL
    \\) STRICT;
    \\CREATE TABLE IF NOT EXISTS tag_budgets(
    \\  key          TEXT NOT NULL,
    \\  value        TEXT NOT NULL,
    \\  soft_cap     INTEGER NOT NULL CHECK(soft_cap>0),
    \\  PRIMARY KEY(key, value)
    \\) STRICT;
    \\CREATE INDEX IF NOT EXISTS idx_tags_kv ON object_tags(key, value);
    \\CREATE INDEX IF NOT EXISTS idx_tags_digest ON object_tags(digest);
    \\CREATE INDEX IF NOT EXISTS idx_objects_access ON objects(last_access_ms);
    \\CREATE INDEX IF NOT EXISTS idx_objects_tier_access ON objects(tier, last_access_ms);
    \\CREATE INDEX IF NOT EXISTS idx_reservations_expiry ON reservations(expires_ms);
    \\CREATE INDEX IF NOT EXISTS idx_leases_expiry ON leases(expires_ms);
;

test "index opens inside a store dir and creates the schema" {
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var idx = try Index.open(io, tmp.dir);
    defer idx.close();
    try std.testing.expect(try idx.tableExists("objects"));
    try std.testing.expect(try idx.tableExists("object_tags"));
    try std.testing.expect(try idx.tableExists("actions"));
    try std.testing.expect(try idx.tableExists("pins"));
    try std.testing.expect(try idx.tableExists("leases"));
    try std.testing.expect(try idx.tableExists("lease_objects"));
    try std.testing.expect(try idx.tableExists("retains"));
    try std.testing.expect(try idx.tableExists("retain_manifests"));
    try std.testing.expect(try idx.tableExists("reservations"));
    try std.testing.expect(try idx.tableExists("tag_budgets"));
}

test "index reopen is idempotent (IF NOT EXISTS)" {
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var a = try Index.open(io, tmp.dir);
    a.close();
    var b = try Index.open(io, tmp.dir);
    defer b.close();
    try std.testing.expect(try b.tableExists("objects"));
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test`
Expected: FAIL with `unknown reference 'Index'` (type not defined yet).

- [ ] **Step 3: Write minimal implementation**

Append to `src/store/index.zig` (above the tests):

```zig
pub const Index = struct {
    db: ?*c.sqlite3,

    pub const OpenError = DbError || Io.Dir.CreateDirPathError || Io.Dir.WriteFileError;

    /// Opens (creating) `index.sqlite` at the store root, applies
    /// pragmas + schema. One handle per Store (decision D1).
    pub fn open(io: Io, store_dir: Io.Dir) OpenError!Index {
        _ = io;
        try store_dir.createDirPath(io, ".");
        var path_buf: [Io.Dir.max_path_bytes]u8 = undefined;
        const dir_len = try store_dir.realPath(io, &path_buf);
        var db_path: [Io.Dir.max_path_bytes + 32]u8 = undefined;
        const full = try std.fmt.bufPrintZ(&db_path, "{s}/index.sqlite", .{path_buf[0..dir_len]});

        var db: ?*c.sqlite3 = null;
        if (c.sqlite3_open_v2(
            full.ptr,
            &db,
            c.SQLITE_OPEN_READWRITE | c.SQLITE_OPEN_CREATE | c.SQLITE_OPEN_FULLMUTEX,
            null,
        ) != c.SQLITE_OK) return error.DbOpen;
        errdefer _ = c.sqlite3_close(db);

        var idx = Index{ .db = db };
        try idx.execAll("PRAGMA journal_mode=WAL;");
        try idx.execAll("PRAGMA synchronous=NORMAL;");
        try idx.execAll("PRAGMA busy_timeout=5000;");
        try idx.execAll("PRAGMA foreign_keys=ON;");
        try idx.execAll(schema_sql);
        return idx;
    }

    pub fn close(idx: *Index) void {
        _ = c.sqlite3_close(idx.db);
        idx.db = null;
    }

    pub fn execAll(idx: *Index, sql: [:0]const u8) DbError!void {
        var errmsg: ?*[*:0]u8 = null;
        const rc = c.sqlite3_exec(idx.db, sql.ptr, null, null, null);
        if (rc != c.SQLITE_OK) return error.DbExec;
        _ = errmsg;
    }

    pub fn tableExists(idx: *Index, name: []const u8) DbError!bool {
        var name_z: [64]u8 = undefined;
        const z = try std.fmt.bufPrintZ(&name_z, "{s}", .{name});
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(idx.db, "SELECT 1 FROM sqlite_master WHERE name=?1;", -1, &stmt, null) != c.SQLITE_OK)
            return error.DbPrepare;
        defer _ = c.sqlite3_finalize(stmt);
        _ = c.sqlite3_bind_text(stmt, 1, z.ptr, -1, c.SQLITE_TRANSIENT);
        const rc = c.sqlite3_step(stmt);
        return rc == c.SQLITE_ROW;
    }
};
```

In `src/store/layout.zig` add: `pub const index_file = "index.sqlite";` (store-root DB per storage-v2 §6; `index.sqlite-wal`/`-shm` counted in index+state per §9.3). In `src/store/root.zig` replace the `index_smoke.zig` test line with `_ = @import("index.zig");` and delete `src/store/index_smoke.zig`.

- [ ] **Step 4: Run test to verify it passes**

Run: `zig build test`
Expected: PASS — both index tests green; smoke file gone.

- [ ] **Step 5: Request commit**

Do not commit (parent commits).

---

### Task 3: Object rows — upsert, access touch, LRU candidates

**Files:**
- Modify: `src/store/index.zig` (object CRUD + queries)
- Test: inline in `src/store/index.zig`

**Interfaces:**
- Consumes: `Index.open/close` from Task 2; `Digest.toHex`.
- Produces: `index.ObjectRow{ digest: [64]u8, size: u64, compressed_size: ?u64, tier: index.Tier (.hot/.cold/.both), kind: []const u8, created_ms: i64, last_access_ms: i64 }`; `index.upsertObject(idx, row: ObjectRow) DbError!void`; `index.touchObject(idx, digest, now_ms: i64) DbError!void` (single UPDATE, no throttle here — throttle lives in `scan.touch`); `index.lruCandidates(idx, gpa, tier: ?Tier, limit: u32) DbError![]ObjectRow` ordered by `last_access_ms ASC`; `index.objectCount(idx) DbError!u64`. GC (Task 10) consumes `lruCandidates`; `scan` (Task 6) consumes `upsertObject`.

- [ ] **Step 1: Write the failing tests**

Append to the test section of `src/store/index.zig`:

```zig
test "upsert then lru order follows last_access" {
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var idx = try Index.open(io, tmp.dir);
    defer idx.close();

    try idx.upsertObject(.{
        .digest = .{'a'} ** 64,
        .size = 10,
        .compressed_size = null,
        .tier = .hot,
        .kind = "rlib",
        .created_ms = 1000,
        .last_access_ms = 3000,
    });
    try idx.upsertObject(.{
        .digest = .{'b'} ** 64,
        .size = 20,
        .compressed_size = null,
        .tier = .hot,
        .kind = "bin",
        .created_ms = 1000,
        .last_access_ms = 1000,
    });
    const rows = try idx.lruCandidates(std.testing.allocator, .hot, 10);
    defer std.testing.allocator.free(rows);
    try std.testing.expectEqual(@as(usize, 2), rows.len);
    try std.testing.expectEqual([64]u8, .{'b'} ** 64, rows[0].digest);
    try std.testing.expectEqual(@as(u64, 2), try idx.objectCount());
}

test "touchObject moves the row to the back of lru" {
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var idx = try Index.open(io, tmp.dir);
    defer idx.close();

    try idx.upsertObject(.{
        .digest = .{'c'} ** 64,
        .size = 5,
        .compressed_size = null,
        .tier = .cold,
        .kind = "other",
        .created_ms = 1000,
        .last_access_ms = 1000,
    });
    try idx.touchObject(&.{'c'} ** 64, 9999);
    const rows = try idx.lruCandidates(std.testing.allocator, .cold, 10);
    defer store.index.freeRows(std.testing.allocator, rows);
    try std.testing.expectEqual(@as(i64, 9999), rows[0].last_access_ms);
}
```

> NOTE: both Task 3 tests free LRU rows with `freeRows` (which frees per-row `kind` dupes), not plain `allocator.free` — executors apply this when wiring.

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test`
Expected: FAIL with `unknown reference 'upsertObject'` (and `ObjectRow`, `Tier`).

- [ ] **Step 3: Write minimal implementation**

Append to `src/store/index.zig`:

```zig
pub const Tier = enum { hot, cold, both };

pub const ObjectRow = struct {
    digest: [64]u8,
    size: u64,
    compressed_size: ?u64,
    tier: Tier,
    kind: []const u8,
    created_ms: i64,
    last_access_ms: i64,
};

fn bindText(stmt: ?*c.sqlite3_stmt, col: c_int, text: []const u8) void {
    _ = c.sqlite3_bind_text(stmt, col, text.ptr, @intCast(text.len), c.SQLITE_TRANSIENT);
}

/// INSERT OR REPLACE: ingest is idempotent, so re-put of the same digest
/// refreshes size/tier/kind but never duplicates the row.
pub fn upsertObject(idx: *Index, row: ObjectRow) DbError!void {
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(idx.db,
        "INSERT OR REPLACE INTO objects(digest,size,compressed_size,tier,kind,created_ms,last_access_ms)" ++
        " VALUES(?1,?2,?3,?4,?5,?6,?7);", -1, &stmt, null) != c.SQLITE_OK)
        return error.DbPrepare;
    defer _ = c.sqlite3_finalize(stmt);
    bindText(stmt, 1, &row.digest);
    _ = c.sqlite3_bind_int64(stmt, 2, @intCast(row.size));
    if (row.compressed_size) |cs| {
        _ = c.sqlite3_bind_int64(stmt, 3, @intCast(cs));
    } else {
        _ = c.sqlite3_bind_null(stmt, 3);
    }
    bindText(stmt, 4, if (row.tier == .hot) "hot" else if (row.tier == .cold) "cold" else "both");
    bindText(stmt, 5, row.kind);
    _ = c.sqlite3_bind_int64(stmt, 6, row.created_ms);
    _ = c.sqlite3_bind_int64(stmt, 7, row.last_access_ms);
    if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.DbStep;
}

pub fn touchObject(idx: *Index, digest: *const [64]u8, now_ms: i64) DbError!void {
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(idx.db,
        "UPDATE objects SET last_access_ms=?1 WHERE digest=?2;", -1, &stmt, null) != c.SQLITE_OK)
        return error.DbPrepare;
    defer _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_bind_int64(stmt, 1, now_ms);
    bindText(stmt, 2, digest);
    if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.DbStep;
}

/// Oldest-first candidate rows for one tier (null tier = both tiers).
/// Caller frees the slice. Fixed-size stack buffers: no allocator inside.
pub fn lruCandidates(idx: *Index, gpa: std.mem.Allocator, tier: ?Tier, limit: u32) DbError![]ObjectRow {
    const sql: [:0]const u8 = if (tier == null)
        "SELECT digest,size,compressed_size,tier,kind,created_ms,last_access_ms FROM objects ORDER BY last_access_ms ASC LIMIT ?1;"
    else
        "SELECT digest,size,compressed_size,tier,kind,created_ms,last_access_ms FROM objects WHERE tier=?2 ORDER BY last_access_ms ASC LIMIT ?1;";
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(idx.db, sql.ptr, -1, &stmt, null) != c.SQLITE_OK)
        return error.DbPrepare;
    defer _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_bind_int64(stmt, 1, @intCast(limit));
    if (tier) |t| bindText(stmt, 2, if (t == .hot) "hot" else if (t == .cold) "cold" else "both");

    var list: std.ArrayList(ObjectRow) = .empty;
    errdefer list.deinit(gpa);
    while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
        var row = ObjectRow{
            .digest = undefined,
            .size = @intCast(c.sqlite3_column_int64(stmt, 1)),
            .compressed_size = if (c.sqlite3_column_type(stmt, 2) == c.SQLITE_NULL)
                null
            else
                @intCast(c.sqlite3_column_int64(stmt, 2)),
            .tier = if (std.mem.eql(u8, std.mem.span(c.sqlite3_column_text(stmt, 3)), "hot")) .hot else if (std.mem.eql(u8, std.mem.span(c.sqlite3_column_text(stmt, 3)), "cold")) .cold else .both,
            .kind = "",
            .created_ms = c.sqlite3_column_int64(stmt, 5),
            .last_access_ms = c.sqlite3_column_int64(stmt, 6),
        };
        const hex_ptr = c.sqlite3_column_text(stmt, 0);
        @memcpy(&row.digest, std.mem.span(hex_ptr)[0..64]);
        row.kind = try gpa.dupe(u8, std.mem.span(c.sqlite3_column_text(stmt, 4)));
        // NOTE: kind strings leak one dupe per row; freed by freeRows below.
        try list.append(gpa, row);
    }
    return try list.toOwnedSlice(gpa);
}

/// Frees a slice from lruCandidates (including per-row kind dupes).
pub fn freeRows(gpa: std.mem.Allocator, rows: []ObjectRow) void {
    for (rows) |r| gpa.free(r.kind);
    gpa.free(rows);
}

pub fn objectCount(idx: *Index) DbError!u64 {
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(idx.db, "SELECT COUNT(*) FROM objects;", -1, &stmt, null) != c.SQLITE_OK)
        return error.DbPrepare;
    defer _ = c.sqlite3_finalize(stmt);
    if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return error.DbStep;
    return @intCast(c.sqlite3_column_int64(stmt, 0));
}
```

Fix the Task 3 test frees: replace `std.testing.allocator.free(rows)` with `freeRows(std.testing.allocator, rows)` in both new tests (the plan's Step 1 snippet uses plain free; the implementation requires `freeRows` — executors apply this correction when wiring).

- [ ] **Step 4: Run test to verify it passes**

Run: `zig build test`
Expected: PASS — upsert/LRU/touch tests green.

- [ ] **Step 5: Request commit**

Do not commit (parent commits).

---

### Task 4: Store owns the index (open/close wiring, cold-aware writes)

**Files:**
- Modify: `src/store/root.zig` (Store gains `index: index_mod.Index` field; `open` opens it; `close` closes it), `src/store/index.zig` (add `deleteObject`, `setTier`, `getObject`)
- Test: inline in `src/store/root.zig` (new test) + `src/store/index.zig`

**Interfaces:**
- Consumes: `Index.open/close`, `layout.index_file`.
- Produces: `index.deleteObject(idx, digest) DbError!void`; `index.setTier(idx, digest, tier, compressed_size: ?u64) DbError!void`; `index.getObject(idx, digest) DbError!?ObjectRow` (caller frees `kind` via `gpa.free` — signature `getObject(idx, gpa, digest)`). `Store.open` on a v2 store opens the index after the shared lock is taken; `Store.close` closes the index before unlocking. `Store.open` refuses format 1 with `error.MigrationRequired` (no auto-migration; explicit `rime cache migrate` in Task 7). No signature changes to `open`/`close`.

- [ ] **Step 1: Write the failing tests**

Add to `src/store/index.zig` tests:

```zig
test "deleteObject and setTier round trip" {
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var idx = try Index.open(io, tmp.dir);
    defer idx.close();

    try idx.upsertObject(.{
        .digest = .{'d'} ** 64,
        .size = 100,
        .compressed_size = null,
        .tier = .hot,
        .kind = "obj",
        .created_ms = 1000,
        .last_access_ms = 1000,
    });
    try idx.setTier(&.{'d'} ** 64, .cold, 30);
    const got = try idx.getObject(std.testing.allocator, &.{'d'} ** 64);
    try std.testing.expect(got != null);
    defer std.testing.allocator.free(got.?.kind);
    try std.testing.expect(got.?.tier == .cold);
    try std.testing.expectEqual(@as(?u64, 30), got.?.compressed_size);
    try idx.deleteObject(&.{'d'} ** 64);
    try std.testing.expect((try idx.getObject(std.testing.allocator, &.{'d'} ** 64)) == null);
}
```

Add to `src/store/root.zig` tests:

```zig
test "v2 store open wires the index" {
    const io = std.Io.Threaded.global_single_threaded.io();
    var ts = test_support.openTestStore(io, .{});
    defer ts.deinit(io);
    try std.testing.expect(try ts.store.index.tableExists("objects"));
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test`
Expected: FAIL — `unknown field 'index'` on `Store`, `unknown reference 'deleteObject'`.

- [ ] **Step 3: Write minimal implementation**

Append to `src/store/index.zig`:

```zig
pub fn deleteObject(idx: *Index, digest: *const [64]u8) DbError!void {
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(idx.db, "DELETE FROM objects WHERE digest=?1;", -1, &stmt, null) != c.SQLITE_OK)
        return error.DbPrepare;
    defer _ = c.sqlite3_finalize(stmt);
    bindText(stmt, 1, digest);
    if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.DbStep;
}

pub fn setTier(idx: *Index, digest: *const [64]u8, tier: Tier, compressed_size: ?u64) DbError!void {
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(idx.db,
        "UPDATE objects SET tier=?1, compressed_size=?2 WHERE digest=?3;", -1, &stmt, null) != c.SQLITE_OK)
        return error.DbPrepare;
    defer _ = c.sqlite3_finalize(stmt);
    bindText(stmt, 1, if (tier == .hot) "hot" else if (tier == .cold) "cold" else "both");
    if (compressed_size) |cs| {
        _ = c.sqlite3_bind_int64(stmt, 2, @intCast(cs));
    } else {
        _ = c.sqlite3_bind_null(stmt, 2);
    }
    bindText(stmt, 3, digest);
    if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.DbStep;
}

/// Null when the digest is not indexed. Caller frees `row.kind`.
pub fn getObject(idx: *Index, gpa: std.mem.Allocator, digest: *const [64]u8) DbError!?ObjectRow {
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(idx.db,
        "SELECT size,compressed_size,tier,kind,created_ms,last_access_ms FROM objects WHERE digest=?1;",
        -1, &stmt, null) != c.SQLITE_OK)
        return error.DbPrepare;
    defer _ = c.sqlite3_finalize(stmt);
    bindText(stmt, 1, digest);
    if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return null;
    return ObjectRow{
        .digest = digest.*,
        .size = @intCast(c.sqlite3_column_int64(stmt, 0)),
        .compressed_size = if (c.sqlite3_column_type(stmt, 1) == c.SQLITE_NULL)
            null
        else
            @intCast(c.sqlite3_column_int64(stmt, 1)),
        .tier = if (std.mem.eql(u8, std.mem.span(c.sqlite3_column_text(stmt, 2)), "hot")) .hot else if (std.mem.eql(u8, std.mem.span(c.sqlite3_column_text(stmt, 2)), "cold")) .cold else .both,
        .kind = try gpa.dupe(u8, std.mem.span(c.sqlite3_column_text(stmt, 3))),
        .created_ms = c.sqlite3_column_int64(stmt, 4),
        .last_access_ms = c.sqlite3_column_int64(stmt, 5),
    };
}
```

In `src/store/root.zig`: add `const index_mod = @import("index.zig");`, add field `index: index_mod.Index` to `Store`, add `_ = @import("index.zig");` to the test block. In `Store.open`, after the shared lock is taken and before `readDiskUsage`, insert:

```zig
        var index = try index_mod.Index.open(io, dir);
        errdefer index.close();
```

and include `.index = index` in the returned struct literal. In `Store.close`, insert `store.index.close();` before unlocking. `OpenError` gains `index_mod.DbError` to the union.

- [ ] **Step 4: Run test to verify it passes**

Run: `zig build test`
Expected: PASS — all v1 tests still green (index empty but open), new tests green.

- [ ] **Step 5: Request commit**

Do not commit (parent commits).

---

### Task 5: Tagging API (tags.zig + Store.tagObject/lookupObjects)

**Files:**
- Create: `src/store/tags.zig`
- Modify: `src/store/root.zig` (additive `tagObject`, `lookupObjects(Predicate)`, `lookupAction` methods using storage-v2 §16 names + re-exports)
- Test: inline in `src/store/tags.zig`

**Interfaces:**
- Consumes: `index.Index`, `Digest`.
- Produces (storage-v2 §16 names; `Tag`/`Predicate` spellings match §16 exactly): `tags.Tag{ key: []const u8, value: []const u8 }`; `tags.Predicate = struct { tags: []Tag, limit: u32 = 10 }`; `tags.tagObject(idx, digest, tags: []const Tag) TagError!void` (validates every pair per §11.3 before writing: unknown non-`user.*` key → `error.UnknownTagKey`; `crate` without `crate_version` or vice versa → `error.TagMismatch`; >32 tags or >8 KiB total tag bytes → `error.TagLimit`); `tags.untag(idx, digest, key, value) DbError!void`; `tags.tagsFor(idx, gpa, digest) DbError![]Tag` (caller frees via `tags.freeTags`); `tags.query(idx, gpa, pred: Predicate) DbError![][64]u8` (conjunction = INTERSECT over per-pair selects ordered by `last_access_ms DESC` with `LIMIT`; empty filter returns newest-first up to `limit`). Store wrappers: `store.tagObject(io, digest, tags) TagError!void`, `store.lookupObjects(io, gpa, pred) LookupError![]Digest`, `store.lookupAction(io, gpa, key) GetError!?ActionEntry` (index-backed; see Task 6), `store.tagsFor` stays as an internal helper (not part of the §16 surface). `TagError = index.DbError || error{ UnknownTagKey, TagMismatch, TagLimit }`. `kind` is never a tag (it is the `objects.kind` column; `kind:` rows in `tag_budgets` join `objects` directly per §11.3).

- [ ] **Step 1: Write the failing tests**

Create `src/store/tags.zig` with tests first:

```zig
const std = @import("std");
const index_mod = @import("index.zig");
const digest_mod = @import("digest.zig");

pub const Tag = struct { key: []const u8, value: []const u8 };

pub const Predicate = struct { tags: []Tag, limit: u32 = 10 };

pub const TagError = index_mod.DbError || error{ UnknownTagKey, TagMismatch, TagLimit };

test "tag query conjunction narrows results" {
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var idx = try index_mod.Index.open(io, tmp.dir);
    defer idx.close();

    const a: [64]u8 = .{'a'} ** 64;
    const b: [64]u8 = .{'b'} ** 64;
    try idx.upsertObject(.{ .digest = a, .size = 1, .compressed_size = null, .tier = .hot, .kind = "rlib", .created_ms = 1, .last_access_ms = 1 });
    try idx.upsertObject(.{ .digest = b, .size = 1, .compressed_size = null, .tier = .hot, .kind = "rlib", .created_ms = 1, .last_access_ms = 1 });
    try tagObject(&idx, &a, &.{ .{ .key = "crate", .value = "serde" }, .{ .key = "crate_version", .value = "1.0.200" } });
    try tagObject(&idx, &a, &.{.{ .key = "profile", .value = "release" }});
    try tagObject(&idx, &b, &.{ .{ .key = "crate", .value = "serde" }, .{ .key = "crate_version", .value = "1.0.200" } });

    const both = try query(std.testing.allocator, &idx, .{ .tags = &.{.{ .key = "crate", .value = "serde" }} });
    defer std.testing.allocator.free(both);
    try std.testing.expectEqual(@as(usize, 2), both.len);

    const narrow = try query(std.testing.allocator, &idx, .{ .tags = &.{
        .{ .key = "crate", .value = "serde" },
        .{ .key = "profile", .value = "release" },
    } });
    defer std.testing.allocator.free(narrow);
    try std.testing.expectEqual(@as(usize, 1), narrow.len);
    try std.testing.expectEqual(a, narrow[0]);
}

test "untag removes the pair and tagsFor lists the rest" {
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var idx = try index_mod.Index.open(io, tmp.dir);
    defer idx.close();

    const a: [64]u8 = .{'a'} ** 64;
    try idx.upsertObject(.{ .digest = a, .size = 1, .compressed_size = null, .tier = .hot, .kind = "other", .created_ms = 1, .last_access_ms = 1 });
    try tagObject(&idx, &a, &.{.{ .key = "user.custom", .value = "x" }});
    try tagObject(&idx, &a, &.{.{ .key = "user.custom", .value = "y" }});
    try untag(&idx, &a, "user.custom", "x");
    const left = try tagsFor(std.testing.allocator, &idx, &a);
    defer freeTags(std.testing.allocator, left);
    try std.testing.expectEqual(@as(usize, 1), left.len);
    try std.testing.expectEqualStrings("y", left[0].value);
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test`
Expected: FAIL with `unknown reference 'tagObject'` / `'query'` / `'Predicate'`.

- [ ] **Step 3: Write minimal implementation**

Prepend to `src/store/tags.zig` (above the tests):

```zig
const TagError = index_mod.DbError || error{ UnknownTagKey, TagMismatch, TagLimit };
const c = @cImport(@cInclude("sqlite3.h"));

fn bindText(stmt: ?*c.sqlite3_stmt, col: c_int, text: []const u8) void {
    _ = c.sqlite3_bind_text(stmt, col, text.ptr, @intCast(text.len), c.SQLITE_TRANSIENT);
}

fn isKnownKey(key: []const u8) bool {
    const fixed = [_][]const u8{ "crate", "crate_version", "toolchain", "target", "profile", "features", "project", "action" };
    for (fixed) |k| if (std.mem.eql(u8, k, key)) return true;
    return std.mem.startsWith(u8, key, "user.");
}

fn validateTags(tags: []const Tag) TagError!void {
    if (tags.len > 32) return error.TagLimit;
    var total: usize = 0;
    var has_crate = false;
    var has_crate_version = false;
    for (tags) |t| {
        if (t.key.len == 0 or t.key.len > 32 or t.value.len > 256) return error.TagLimit;
        if (std.mem.eql(u8, t.key, "kind")) return error.UnknownTagKey;
        if (!isKnownKey(t.key)) return error.UnknownTagKey;
        if (std.mem.eql(u8, t.key, "crate")) has_crate = true;
        if (std.mem.eql(u8, t.key, "crate_version")) has_crate_version = true;
        total += t.key.len + t.value.len;
    }
    if (total > 8 * 1024) return error.TagLimit;
    if (has_crate != has_crate_version) return error.TagMismatch;
}

/// §16 `tagObject`: validates per §11.3, then writes one `object_tags` row per pair.
pub fn tagObject(idx: *index_mod.Index, digest: *const [64]u8, tags: []const Tag) TagError!void {
    try validateTags(tags);
    for (tags) |t| {
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(idx.db, "INSERT OR IGNORE INTO object_tags(digest,key,value) VALUES(?1,?2,?3);", -1, &stmt, null) != c.SQLITE_OK)
            return error.DbPrepare;
        defer _ = c.sqlite3_finalize(stmt);
        bindText(stmt, 1, digest);
        bindText(stmt, 2, t.key);
        bindText(stmt, 3, t.value);
        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.DbStep;
    }
}

pub fn untag(idx: *index_mod.Index, digest: *const [64]u8, key: []const u8, value: []const u8) DbError!void {
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(idx.db, "DELETE FROM object_tags WHERE digest=?1 AND key=?2 AND value=?3;", -1, &stmt, null) != c.SQLITE_OK)
        return error.DbPrepare;
    defer _ = c.sqlite3_finalize(stmt);
    bindText(stmt, 1, digest);
    bindText(stmt, 2, key);
    bindText(stmt, 3, value);
    if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.DbStep;
}

pub fn tagsFor(gpa: std.mem.Allocator, idx: *index_mod.Index, digest: *const [64]u8) DbError![]Tag {
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(idx.db, "SELECT key,value FROM object_tags WHERE digest=?1 ORDER BY key,value;", -1, &stmt, null) != c.SQLITE_OK)
        return error.DbPrepare;
    defer _ = c.sqlite3_finalize(stmt);
    bindText(stmt, 1, digest);
    var list: std.ArrayList(Tag) = .empty;
    errdefer freeTags(gpa, try list.toOwnedSlice(gpa));
    while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
        const k = try gpa.dupe(u8, std.mem.span(c.sqlite3_column_text(stmt, 0)));
        errdefer gpa.free(k);
        const v = try gpa.dupe(u8, std.mem.span(c.sqlite3_column_text(stmt, 1)));
        try list.append(gpa, .{ .key = k, .value = v });
    }
    return try list.toOwnedSlice(gpa);
}

pub fn freeTags(gpa: std.mem.Allocator, tags: []Tag) void {
    for (tags) |t| {
        gpa.free(t.key);
        gpa.free(t.value);
    }
    gpa.free(tags);
}

/// Conjunction query: objects carrying ALL pairs, newest-first. One SELECT per pair
/// INTERSECTed and joined to `objects` for `last_access_ms DESC` + `LIMIT` (§12.1).
/// Empty filter returns newest-first up to `pred.limit` (default 10, max 1,000).
pub fn query(gpa: std.mem.Allocator, idx: *index_mod.Index, pred: Predicate) DbError![][64]u8 {
    const filt = pred.tags;
    const limit = @min(@max(pred.limit, 1), 1000);
    if (filt.len == 0) {
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(idx.db, "SELECT digest FROM objects ORDER BY last_access_ms DESC LIMIT ?1;", -1, &stmt, null) != c.SQLITE_OK)
            return error.DbPrepare;
        defer _ = c.sqlite3_finalize(stmt);
        _ = c.sqlite3_bind_int64(stmt, 1, @intCast(limit));
        var all: std.ArrayList([64]u8) = .empty;
        errdefer all.deinit(gpa);
        while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
            var hex: [64]u8 = undefined;
            @memcpy(&hex, std.mem.span(c.sqlite3_column_text(stmt, 0))[0..64]);
            try all.append(gpa, hex);
        }
        return try all.toOwnedSlice(gpa);
    }
    var sql_buf: [1024]u8 = undefined;
    var sql = std.io.fixedBufferStream(&sql_buf);
    for (filt, 0..) |_, i| {
        if (i > 0) sql.writer().print(" INTERSECT ", .{}) catch return error.Unexpected;
        sql.writer().print("SELECT digest FROM object_tags WHERE key=?{d} AND value=?{d}", .{ 2 * i + 1, 2 * i + 2 }) catch return error.Unexpected;
    }
    var sql_z: [1088]u8 = undefined;
    const z = try std.fmt.bufPrintZ(&sql_z, "{s}", .{sql_buf[0..sql.pos]});
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(idx.db, z.ptr, -1, &stmt, null) != c.SQLITE_OK)
        return error.DbPrepare;
    defer _ = c.sqlite3_finalize(stmt);
    for (filt, 0..) |t, i| {
        bindText(stmt, @intCast(2 * i + 1), t.key);
        bindText(stmt, @intCast(2 * i + 2), t.value);
    }
    var out: std.ArrayList([64]u8) = .empty;
    errdefer out.deinit(gpa);
    while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
        var hex: [64]u8 = undefined;
        @memcpy(&hex, std.mem.span(c.sqlite3_column_text(stmt, 0))[0..64]);
        try out.append(gpa, hex);
    }
    return try out.toOwnedSlice(gpa);
}
```

In `src/store/root.zig` add `const tags_mod = @import("tags.zig");`, `_ = @import("tags.zig");` in the test block, re-exports `pub const Tag = tags_mod.Tag;`, `pub const Predicate = tags_mod.Predicate;`, and `pub const TagError = tags_mod.TagError;` (storage-v2 §16 spellings), plus Store methods:

```zig
    pub fn tagObject(store: *Store, io: Io, d: Digest, tags: []const Tag) TagError!void {
        _ = io;
        const hex = d.toHex();
        return tags_mod.tagObject(&store.index, &hex, tags);
    }

    pub fn untag(store: *Store, io: Io, d: Digest, key: []const u8, value: []const u8) TagError!void {
        _ = io;
        const hex = d.toHex();
        return tags_mod.untag(&store.index, &hex, key, value);
    }

    pub fn tagsFor(store: *Store, io: Io, gpa: std.mem.Allocator, d: Digest) TagError![]Tag {
        _ = io;
        const hex = d.toHex();
        return tags_mod.tagsFor(gpa, &store.index, &hex);
    }

    /// Storage-v2 §16 canonical lookup: conjunctive tag predicate, newest-first, bounded LIMIT.
    pub fn lookupObjects(store: *Store, io: Io, gpa: std.mem.Allocator, pred: Predicate) TagError![]Digest {
        _ = io;
        const hexes = try tags_mod.query(gpa, &store.index, pred);
        defer gpa.free(hexes);
        var out = try gpa.alloc(Digest, hexes.len);
        errdefer gpa.free(out);
        for (hexes, out) |h, *slot| slot.* = Digest.fromHex(&h) catch return error.Unexpected;
        return out;
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `zig build test`
Expected: PASS — both tagging tests green; all v1 tests untouched and green.

- [ ] **Step 5: Request commit**

Do not commit (parent commits).

---

### Task 6: Index mirrors — ingest/scan/state/action_cache go index-first

**Files:**
- Modify: `src/store/ingest.zig` (upsert object row on publish), `src/store/scan.zig` (index-first, filesystem fallback + self-heal), `src/store/state.zig` (mirror pins/leases/retains rows), `src/store/action_cache.zig` (index-backed put/get + sweep), `src/store/cold.zig` (setTier on demote/promote), `src/store/gc.zig` (delete index rows on evict)
- Test: extend inline tests in `scan.zig` and `action_cache.zig` (append new tests, do not edit existing ones)

**Interfaces:**
- Consumes: `index.upsertObject/deleteObject/setTier/getObject`, `tags` untouched.
- Produces: no new public API. Behavioral contracts: `scan` returns identical `ObjectInfo` values but served from the index when row count matches the filesystem walk (fallback: full walk + upsert missing rows); `putAction`/`getAction` keep signatures, backed by the `actions` table with the flat files kept as write-through until Task 8 deletes them; pins/leases/retains JSON files remain authoritative, index rows are mirrors written in the same call. `cold.demote/promote` update the tier column.

- [ ] **Step 1: Write the failing tests**

Append to `src/store/scan.zig` tests:

```zig
test "scan serves indexed objects (index row present; fallback disabled)" {
    const io = std.Io.Threaded.global_single_threaded.io();
    const gpa = std.testing.allocator;
    var ts = test_support.openTestStore(io, .{});
    defer ts.deinit(io);

    const d = try ts.store.putBytes(io, "indexed", .rlib);
    // Failing-first gate: the index row must exist (proves the ingest mirror ran).
    // Executors must additionally disable the filesystem fallback (e.g. stub `scanTier` to return empty)
    // and confirm this test still passes — otherwise it passes vacuously on the old walk path.
    const hex = d.toHex();
    const row = try ts.store.index.getObject(gpa, &hex);
    try std.testing.expect(row != null);
    if (row) |r| gpa.free(r.kind);
    const infos = try ts.store.scan(io, gpa);
    defer gpa.free(infos);
    try std.testing.expectEqual(@as(usize, 1), infos.len);
    try std.testing.expectEqual(d.bytes, infos[0].digest.bytes);
    try std.testing.expectEqual(root.Kind.rlib, infos[0].kind);
}
```

Append to `src/store/action_cache.zig` tests:

```zig
test "action entries survive through the index mirror" {
    const io = std.Io.Threaded.global_single_threaded.io();
    const gpa = std.testing.allocator;
    var ts = test_support.openTestStore(io, .{});
    defer ts.deinit(io);

    const man = try ts.store.putBytes(io, "manifest-body", .manifest);
    const key = root.hashBytes("action-key");
    try ts.store.putAction(io, key, man);
    const got = try ts.store.getAction(io, gpa, key);
    try std.testing.expect(got != null);
    try std.testing.expectEqual(man.bytes, got.?.manifest.bytes);
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test`
Expected: FAIL — `putBytes` does not yet upsert index rows so the `getObject != null` assertion fails; `putAction` index mirror missing. The `getObject` assertion is the failing-first gate (the old filesystem walk alone cannot satisfy it).

- [ ] **Step 3: Write minimal implementation**

`ingest.zig`: after `publish` + `recordKind` in both `putBytes` and `putFile`, upsert the index row (hot tier, `created_ms = last_access_ms = now`):

```zig
fn indexUpsert(store: *root.Store, io: Io, d: Digest, size: u64, kind: root.Kind) void {
    const now_ms = Io.Timestamp.now(io, .real).toMilliseconds();
    const hex = d.toHex();
    store.index.upsertObject(.{
        .digest = hex,
        .size = size,
        .compressed_size = null,
        .tier = .hot,
        .kind = @tagName(kind),
        .created_ms = now_ms,
        .last_access_ms = now_ms,
    }) catch {};
}
```

Call `indexUpsert(store, io, d, bytes.len, kind)` at the end of `putBytes` (both fast-path return and fresh publish — fast path also refreshes `last_access_ms` via `touchObject`), and in `putFile` with `offset` as size. Needs `const index_mod` import only for the `Tier` type — the method lives on `store.index` so no import needed beyond root.

`scan.zig`: at the top of `scan`, try the index path first — fetch all rows via `lruCandidates(gpa, null, 1_000_000)`, map each to `ObjectInfo` (parse kind via `stringToEnum` or `.other`, `mtime_ms = last_access_ms`), and verify each digest's file still exists in either tier (skip missing = self-heal by `deleteObject`). If the index count is zero but the filesystem walk is non-zero (pre-migration store), fall back to the existing walk and upsert every found object. Keep the existing `scanTier`/`loadKinds` code untouched as the fallback.

`state.zig`: after each successful `writeJsonAtomic` in `putPin`/`putLease`/`putRetain`, mirror the row into the index (`pins`, `leases`+`lease_objects`, `retains`+`retain_manifests` per §11.2; leases/retains fan out one row per member digest/manifest). This requires `state` functions to take the `*Index` — but signatures are internal (only `Store` calls them), so add a trailing `idx: *index_mod.Index` parameter to `putPin`, `removePin`, `putLease`, `renewLease`, `dropLease`, `putRetain` and update the `Store` wrappers in `root.zig` to pass `&store.index`. `removePin`/`dropLease` also delete the index row. Read paths (`listPins`, `liveLeases`, `listRetains`) keep reading JSON (authoritative, decision D4).

`action_cache.zig`: `putAction`/`getAction` take the same new trailing `idx` parameter pattern; write-through to both the flat file and the `actions(action_key, manifest_digest, created_ms)` table (via `index.insertAction` from Task 7); `getAction` checks the table first, then the file (re-index on file hit). `sweepStale`/`countStale` keep filesystem behavior — GC's index-driven sweep lands in Task 10. `Store.lookupAction` is the storage-v2 §16 index-backed read; v1 `getAction` keeps its signature as a thin alias delegating to it (additive rule).

`cold.zig`: after a successful demote, call `store.index.setTier(&hex, .cold, compressed_size)`; after promote, `setTier(&hex, .hot, null)`. After `gc` evicts (in `gc.zig` `evict`), call `store.index.deleteObject(&hex)` (best-effort `catch {}` — bytes are authoritative).

- [ ] **Step 4: Run test to verify it passes**

Run: `zig build test`
Expected: PASS — new mirror tests green; every v1 test still green.

- [ ] **Step 5: Request commit**

Do not commit (parent commits).

---

### Task 7: Migration v1 → v2 (explicit `rime cache migrate`; journal + actions + roots + incremental + budget mapping)

**Files:**
- Create: `src/store/migrate.zig`
- Modify: `src/store/layout.zig` (`format_version: u32 = 2`, add `kinds_journal = "state/kinds.jsonl"` const), `src/store/root.zig` (`Store.open` refuses format 1 with `error.MigrationRequired`; add `rime cache migrate [--dry-run]` wiring in `src/main.zig`), `src/store/index.zig` (add `insertAction`)
- Test: inline in `src/store/migrate.zig`
- Test: inline in `src/store/migrate.zig`

**Interfaces:**
- Consumes: `Index`, `layout` consts, `state.listPins/liveLeases/listRetains`, `scan` filesystem walk.
- Produces: `migrate.migrate(io, store_dir, idx, opts: MigrateOpts) MigrateError!MigrateReport` invoked only by `rime cache migrate [--dry-run]` (never by `Store.open`). `MigrateOpts = struct { dry_run: bool = false }`; `MigrateReport` counts imported objects/actions/roots plus re-homed incremental bytes. `MigrateError = index.DbError || state.StateError || scan.ScanError`. `Store.open` refuses `{"format":1}` with `error.MigrationRequired` (run `rime cache migrate`); format-to-error table per storage-v2 §14 (1→`MigrationRequired` on v2 open, 2→ok, missing/corrupt/other→`UnknownFormat`; v1 binaries refuse 2 with `UnknownFormat`). Migration holds the exclusive `format-lock` for the whole run (storage-v2 §14.1); `open` never upgrades/migrates.

- [ ] **Step 1: Write the failing tests**

Create `src/store/migrate.zig` with tests first:

```zig
const std = @import("std");
const index_mod = @import("index.zig");

test "migrate imports journal kinds and bumps format to 2" {
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // Fake a v1 store: layout dirs + format 1 + one journal line + one object dir entry.
    try tmp.dir.createDirPath(io, "objects/ab");
    try tmp.dir.createDirPath(io, "state");
    try tmp.dir.writeFile(io, .{ .sub_path = "format.json", .data = "{\"format\":1}\n" });
    try tmp.dir.writeFile(io, .{
        .sub_path = "state/kinds.jsonl",
        .data = "{\"digest\":\"ab" ++ "c" ** 62 ++ "\",\"kind\":\"rlib\"}\nmalformed line\n",
    });

    var idx = try index_mod.Index.open(io, tmp.dir);
    defer idx.close();
    const rep = try migrate(io, tmp.dir, &idx, .{});
    try std.testing.expectEqual(@as(u64, 1), rep.objects_imported);
    const rep2 = try migrate(io, tmp.dir, &idx, .{});
    try std.testing.expectEqual(@as(u64, 0), rep2.objects_imported); // second run imports nothing (idempotent)

    const fmt = try tmp.dir.readFileAlloc(io, "format.json", std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(fmt);
    try std.testing.expect(std.mem.indexOf(u8, fmt, "\"format\":2") != null);
    // Imported action row must be readable via the index helper (no placeholder path).
    // (`index.getAction` backs `Store.lookupAction`; freed `manifest_digest` below.)
    const got = try idx.getAction(std.testing.allocator, &([64]u8{ 'e' } ** 64));
    defer if (got) |g| std.testing.allocator.free(g.manifest_digest);
    try std.testing.expect(got != null);
}

test "migrate --dry-run changes nothing" {
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "state");
    try tmp.dir.writeFile(io, .{ .sub_path = "format.json", .data = "{\"format\":1}\n" });
    var idx = try index_mod.Index.open(io, tmp.dir);
    defer idx.close();
    _ = try migrate(io, tmp.dir, &idx, .{ .dry_run = true });
    // Dry run reports counts but deletes nothing and bumps nothing.
    const fmt = try tmp.dir.readFileAlloc(io, "format.json", std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(fmt);
    try std.testing.expect(std.mem.indexOf(u8, fmt, "\"format\":1") != null);
}

test "v2 open refuses format 1 with MigrationRequired" {
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "state");
    try tmp.dir.writeFile(io, .{ .sub_path = "format.json", .data = "{\"format\":1}\n" });
    try std.testing.expectError(error.MigrationRequired, test_openRefusesV1(io, tmp.dir));
}
```

> `test_openRefusesV1` is a test-only helper calling `Store.open` on the tmp dir; executors wire the real `Store.open` refusal (`format==1` → `error.MigrationRequired`, never auto-migrate).
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test`
Expected: FAIL with `unknown reference 'migrate'` (`migrate`, `MigrateOpts`, `insertAction` not yet defined).

- [ ] **Step 3: Write minimal implementation**

Prepend to `src/store/migrate.zig`:

```zig
const std = @import("std");
const index_mod = @import("index.zig");
const layout = @import("layout.zig");
const state = @import("state.zig");
const digest_mod = @import("digest.zig");

const Io = std.Io;

pub const MigrateError = index_mod.DbError || state.StateError || error{ Unexpected, OutOfMemory };

pub const MigrateOpts = struct { dry_run: bool = false };

pub const MigrateReport = struct {
    objects_imported: u64 = 0,
    actions_imported: u64 = 0,
    roots_imported: u64 = 0,
    incremental_rehomed_bytes: u64 = 0,
};

/// Explicit `rime cache migrate` only (never called by `Store.open`, which refuses
/// format 1 with `error.MigrationRequired` per storage-v2 §14). Steps per §14.1–14.8:
/// preconditions + backup → content untouched → index build → actions import →
/// roots import → incremental re-homing → budget mapping → commit + verify.
/// `dry_run` reports counts, deletes nothing, bumps nothing. Idempotent
/// (all writes are INSERT OR REPLACE / IGNORE).
pub fn migrate(io: Io, store_dir: Io.Dir, idx: *index_mod.Index, opts: MigrateOpts) MigrateError!MigrateReport {
    const fmt_bytes = store_dir.readFileAlloc(io, layout.format_file, std.heap.page_allocator, .unlimited) catch return error.Unexpected;
    defer std.heap.page_allocator.free(fmt_bytes);
    const parsed = std.json.parseFromSlice(layout.FormatJson, std.heap.page_allocator, fmt_bytes, .{}) catch return error.Unexpected;
    defer parsed.deinit();
    if (parsed.value.format != 1) return .{};

    // §14.1 preconditions: no live leases here in the doc sketch (real code checks
    // `state.liveLeases` non-empty → return `error.LeasesLive` unless `--wait` drained them;
    // exclusive `format-lock` is held by the `rime cache migrate` caller, not here).
    // §14.1 backup: copy `state/` to `state/migrate-backup/` (skipped when `dry_run`).
    var rep = MigrateReport{};
    rep.objects_imported = try importJournal(io, store_dir, idx, opts.dry_run);
    rep.actions_imported = try importActions(io, store_dir, idx, opts.dry_run);
    rep.roots_imported = try importRoots(io, store_dir, idx, opts.dry_run);
    // §14.6 incremental re-homing: `state/projects/*/incremental/` trees are ingested as
    // `kind=incremental` objects (content-hash dedup may collapse identical sessions),
    // tagged at least `action=rustc` + `project=<dir id>`; source trees deleted (unless `dry_run`).
    // The `kind:incremental = 4GiB` soft tag budget is installed (§12.3).
    rep.incremental_rehomed_bytes = try rehomeIncremental(io, store_dir, idx, opts.dry_run);
    // §14.7 budget mapping: `hot_limit`/`cold_limit` → derived `budget`+caps (fully derived:
    // both set → `budget=ceil((H+C)/0.9)` with H/C pinned and 5%+5% for index/spool;
    // only H → `budget=ceil(H/0.7)`; only C → `budget=ceil(C/0.2)`; unset → `auto`).
    // Config is rewritten by the caller (skipped when `dry_run`).
    if (opts.dry_run) return rep;
    store_dir.writeFile(io, .{ .sub_path = layout.format_file, .data = "{\"format\":2}\n" }) catch return error.Unexpected;
    // Journal is superseded by the objects table (decision D4); remove it only after
    // the read-only `verify` pass (§11.5) exits 0 — kept as the tag-loss backstop until then.
    // `actions/` + v1 `state/` JSON sources are removed on success (post-verify).
    return rep;
}

/// Journal lines: {"digest":"<64hex>","kind":"<tag>"}; malformed lines skipped (v1 §5.2 rule).
fn importJournal(io: Io, store_dir: Io.Dir, idx: *index_mod.Index, dry_run: bool) MigrateError!u64 {
    const bytes = store_dir.readFileAlloc(io, "state/kinds.jsonl", std.heap.page_allocator, .unlimited) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return error.Unexpected,
    };
    defer std.heap.page_allocator.free(bytes);
    const now_ms = Io.Timestamp.now(io, .real).toMilliseconds();
    var count: u64 = 0;
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const entry = parseJournalLine(line) catch continue;
        // Size/tier come from the real file; journal only supplies kind.
        const st = statBothTiers(store_dir, io, entry.digest) catch continue;
        if (dry_run) {
            count += 1;
            continue;
        }
        var hex: [64]u8 = undefined;
        hex = entry.digest.toHex();
        idx.upsertObject(.{
            .digest = hex,
            .size = st.size,
            .compressed_size = if (st.tier == .cold) st.size else null,
            .tier = st.tier,
            .kind = @tagName(entry.kind),
            .created_ms = now_ms,
            .last_access_ms = st.mtime_ms,
        }) catch return error.Unexpected;
        count += 1;
    }
    return count;
}

const JournalEntry = struct { digest: digest_mod.Digest, kind: KindAlias };
// Storage-v2 §5.2 kind spellings plus the two v2 values (incremental, spool).
const KindAlias = enum { rlib, rmeta, obj, staticlib, dylib, bin, dep_info, manifest, build_script_out, source, other, incremental, spool };

fn parseJournalLine(line: []const u8) error{InvalidLine}!JournalEntry {
    const d_start = std.mem.indexOf(u8, line, "\"digest\":\"") orelse return error.InvalidLine;
    const d_val = line[d_start + 10 ..];
    const d_end = std.mem.indexOfScalar(u8, d_val, '"') orelse return error.InvalidLine;
    const k_start = std.mem.indexOf(u8, line, "\"kind\":\"") orelse return error.InvalidLine;
    const k_val = line[k_start + 8 ..];
    const k_end = std.mem.indexOfScalar(u8, k_val, '"') orelse return error.InvalidLine;
    return .{
        .digest = digest_mod.Digest.fromHex(d_val[0..d_end]) catch return error.InvalidLine,
        .kind = std.meta.stringToEnum(KindAlias, k_val[0..k_end]) orelse return error.InvalidLine,
    };
}

const TierStat = struct { size: u64, tier: index_mod.Tier, mtime_ms: i64 };

fn statBothTiers(store_dir: Io.Dir, io: Io, d: digest_mod.Digest) error{Missing}!TierStat {
    var rbuf: [67]u8 = undefined;
    const rel = d.relPath(&rbuf);
    var hot_buf: [75]u8 = undefined;
    @memcpy(hot_buf[0..8], "objects/");
    @memcpy(hot_buf[8..], rel);
    if (store_dir.statFile(io, hot_buf[0..75], .{})) |st| {
        return .{ .size = st.size, .tier = .hot, .mtime_ms = st.mtime.toMilliseconds() };
    } else |_| {}
    var cold_buf: [75]u8 = undefined;
    @memcpy(cold_buf[0..5], "cold/");
    @memcpy(cold_buf[5..72], rel);
    if (store_dir.statFile(io, cold_buf[0..72], .{})) |st| {
        return .{ .size = st.size, .tier = .cold, .mtime_ms = st.mtime.toMilliseconds() };
    } else |_| {}
    return error.Missing;
}

/// Flat action files actions/xx/<64hex> -> actions(action_key, manifest_digest, created_ms).
/// Stale entries (manifest file gone) are dropped and counted (v1 §9.7 phase-1 rule).
fn importActions(io: Io, store_dir: Io.Dir, idx: *index_mod.Index, dry_run: bool) MigrateError!u64 {
    var count: u64 = 0;
    const top = store_dir.openDir(io, "actions", .{ .iterate = true }) catch return 0;
    defer top.close(io);
    const now_ms = Io.Timestamp.now(io, .real).toMilliseconds();
    var fan = top.iterate() catch return error.Unexpected;
    while (fan.next(io) catch return error.Unexpected) |fanout| {
        if (fanout.name.len != 2) continue;
        const sub = top.openDir(io, fanout.name, .{ .iterate = true }) catch continue;
        defer sub.close(io);
        var it = sub.iterate() catch continue;
        while (it.next(io) catch null) |entry| {
            if (entry.name.len != 64) continue;
            const action_key = digest_mod.Digest.fromHex(entry.name[0..64]) catch continue;
            const rel = std.fmt.allocPrint(std.heap.page_allocator, "actions/{s}/{s}", .{ fanout.name, entry.name }) catch return error.OutOfMemory;
            defer std.heap.page_allocator.free(rel);
            const bytes = store_dir.readFileAlloc(io, rel, std.heap.page_allocator, .limited(4096)) catch continue;
            defer std.heap.page_allocator.free(bytes);
            const parsed = std.json.parseFromSlice(struct { manifest_digest: []const u8, created_ms: i64 }, std.heap.page_allocator, bytes, .{}) catch continue;
            defer parsed.deinit();
            if (dry_run) {
                count += 1;
                continue;
            }
            var ahex: [64]u8 = undefined;
            ahex = action_key.toHex();
            idx.insertAction(&ahex, parsed.value.manifest_digest, now_ms) catch return error.Unexpected;
            count += 1;
        }
    }
    return count;
}

/// index helper used above (add to `src/store/index.zig` next to `upsertObject`):
/// `pub fn insertAction(idx: *Index, action_key: *const [64]u8, manifest_digest: []const u8, created_ms: i64) DbError!void`
/// — one `INSERT OR REPLACE INTO actions(action_key, manifest_digest, created_ms)` prepared statement.

/// Pins/leases/retains JSON -> §11.2 rows (authoritative files stay until post-verify removal).
/// Corrupt root files abort fail-closed with the filename (v1 skip-and-ignore does NOT carry over, §11.5).
fn importRoots(io: Io, store_dir: Io.Dir, idx: *index_mod.Index, dry_run: bool) MigrateError!u64 {
    const gpa = std.heap.page_allocator;
    const now_ms = Io.Timestamp.now(io, .real).toMilliseconds();
    var count: u64 = 0;
    const pins = try state.listPins(io, gpa, store_dir);
    defer state.freePins(gpa, pins);
    for (pins) |p| {
        count += 1;
        if (dry_run) continue;
        idx.insertPin(p.name, p.digest_hex, now_ms) catch return error.Unexpected;
    }
    const leases = try state.listLeases(io, gpa, store_dir, now_ms);
    defer state.freeLeases(gpa, leases);
    for (leases) |l| {
        count += 1;
        if (dry_run) continue;
        idx.insertLease(l.build_id, l.expires_ms) catch return error.Unexpected;
        for (l.digest_hexes) |h| idx.insertLeaseObject(l.build_id, h) catch return error.Unexpected;
    }
    const retains = try state.listRetains(io, gpa, store_dir);
    defer state.freeRetains(gpa, retains);
    for (retains) |r| {
        count += 1;
        if (dry_run) continue;
        idx.insertRetain(r.project_id, r.updated_ms) catch return error.Unexpected;
        for (r.manifest_hexes) |m| idx.insertRetainManifest(r.project_id, m) catch return error.Unexpected;
    }
    return count;
}

/// Incremental re-homing (§14.6): ingest each `state/projects/*/incremental/` tree as
/// `kind=incremental` objects with at least `action=rustc` + `project=<dir id>` tags
/// (dedup may collapse identical sessions); delete source trees unless `dry_run`.
/// Returns re-homed bytes. Installs the `kind:incremental = 4GiB` soft tag budget.
fn rehomeIncremental(io: Io, store_dir: Io.Dir, idx: *index_mod.Index, dry_run: bool) MigrateError!u64 {
    _ = io;
    _ = store_dir;
    _ = idx;
    _ = dry_run;
    return 0; // real walk ingests file bytes via `putFile`-equivalent + `tagObject`; stub shape only
}
```

In `src/store/layout.zig`: change `format_version` to `2`, add `pub const kinds_journal = "state/kinds.jsonl";`. In `src/store/root.zig`: `Store.open` refuses `{"format":1}` with `error.MigrationRequired` (run `rime cache migrate`); format-to-error table per storage-v2 §14 (`1`→`MigrationRequired` on v2 open, `2`→ok, missing/corrupt/other→`UnknownFormat`). Migration runs only via `rime cache migrate [--dry-run]` holding the exclusive `format-lock` (preconditions + `state/migrate-backup/` + §14.2–14.8 steps above; dry run deletes nothing). Keep the v1 test `store open refuses unknown format version` passing (99 still refused); the existing `store open creates layout` test now asserts `"format":2` content on fresh creation — update that test's expectation string accordingly. Add the `MigrationRequired` vs `UnknownFormat` distinction to `OpenError` docs.

- [ ] **Step 4: Run test to verify it passes**

Run: `zig build test`
Expected: PASS — migration tests green; v1 layout tests updated and green.

- [ ] **Step 5: Request commit**

Do not commit (parent commits).

---

### Task 8: Budget config + class allocation model (70/20/5/5)

**Files:**
- Create: `src/store/budget.zig` (resolution + class split + usage accounting)
- Modify: `src/store/config.zig` (additive fields: `budget: Limit = .auto`, `tag_budgets: []TagBudget = &.{}`, explicit `hot_cap`/`cold_cap`/`index_state_cap`/`spool_cap` optional overrides; `spool` cap derived not configured separately), `src/store/root.zig` (Store gains `budget: budget_mod.ResolvedBudget`)
- Test: inline in `src/store/budget.zig`

**Interfaces:**
- Consumes: `config.Limit`, `disk_usage.DiskUsage`, `index.objectCount`/sums.
- Produces: `budget.TagBudget{ key: []const u8, value: []const u8, soft_cap: u64 }` (soft cap, decision D6; SQLite `tag_budgets.soft_cap` column per §11.2; TOML key is singular `store.tag_budget` per §15); `budget.ResolvedBudget{ total: u64, hot: u64, cold: u64, index_state: u64, spool: u64, reserve: u64 }`; `budget.resolveBudget(cfg: Config, usage: DiskUsage) ResolvedBudget` (total = `budget.fixed` or clamp(10% free, 5GiB, 50GiB); classes = 70/20/5/5% of total per §9.1; deprecated `hot_limit.fixed`/`cold_limit.fixed` pin their class per §14.7; explicit class caps must sum ≤ `budget` or config validation fails; reserve unchanged); `budget.classUsage(store, io, gpa) ClassUsage!{hot, cold, index_state, spool}` (hot/cold from index `SUM` queries at compressed sizes — never a 1M-row fetch; index_state = `index.sqlite` + `-wal` + `-shm` + recursive `state/` walk; spool = recursive `tmp/` walk + live spool reservations).

- [ ] **Step 1: Write the failing tests**

Create `src/store/budget.zig` with tests first:

```zig
const std = @import("std");
const config_mod = @import("config.zig");

test "auto total splits into hard classes" {
    const b = resolveBudget(.{}, .{ .free_bytes = 1000 * config_mod.GiB, .fs_size = 2000 * config_mod.GiB });
    // clamp(10% of 1000 GiB, 5 GiB, 50 GiB) = 50 GiB total; §9.1 split 70/20/5/5
    try std.testing.expectEqual(@as(u64, 50 * config_mod.GiB), b.total);
    try std.testing.expectEqual(@as(u64, 35 * config_mod.GiB), b.hot);
    try std.testing.expectEqual(@as(u64, 10 * config_mod.GiB), b.cold);
    try std.testing.expectEqual(@as(u64, 50 * config_mod.GiB / 20), b.index_state);
    try std.testing.expectEqual(@as(u64, 50 * config_mod.GiB / 20), b.spool);
    try std.testing.expectEqual(b.total, b.hot + b.cold + b.index_state + b.spool);
}

test "explicit class caps must sum to <= budget" {
    const cfg = config_mod.Config{
        .budget = .{ .fixed = 10 * config_mod.GiB },
        .hot_cap = .{ .fixed = 7 * config_mod.GiB },
        .cold_cap = .{ .fixed = 4 * config_mod.GiB }, // 7+4 already > 10 with index/spool shares
    };
    try std.testing.expectError(error.InvalidConfig, resolveBudgetChecked(cfg, .{ .free_bytes = 10 * config_mod.GiB, .fs_size = 10 * config_mod.GiB }));
}

test "fixed hot and cold limits override their classes" {
    const cfg = config_mod.Config{
        .hot_limit = .{ .fixed = 2 * config_mod.GiB },
        .cold_limit = .{ .fixed = 3 * config_mod.GiB },
        .disk_reserve = .{ .fixed = 1 * config_mod.GiB },
    };
    const b = resolveBudget(cfg, .{ .free_bytes = 10 * config_mod.GiB, .fs_size = 10 * config_mod.GiB });
    try std.testing.expectEqual(@as(u64, 2 * config_mod.GiB), b.hot);
    try std.testing.expectEqual(@as(u64, 3 * config_mod.GiB), b.cold);
    try std.testing.expectEqual(@as(u64, 1 * config_mod.GiB), b.reserve);
}

test "fixed total budget splits proportionally" {
    const cfg = config_mod.Config{ .budget = .{ .fixed = 20 * config_mod.GiB } };
    const b = resolveBudget(cfg, .{ .free_bytes = 10 * config_mod.GiB, .fs_size = 10 * config_mod.GiB });
    try std.testing.expectEqual(@as(u64, 20 * config_mod.GiB), b.total);
    try std.testing.expectEqual(@as(u64, 14 * config_mod.GiB), b.hot);
    try std.testing.expectEqual(@as(u64, 4 * config_mod.GiB), b.cold);
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test`
Expected: FAIL with `unknown reference 'resolveBudget'` (and `budget` field missing on `Config`).

- [ ] **Step 3: Write minimal implementation**

In `src/store/config.zig` add (additive only — no existing field touched):

```zig
pub const TagBudgetCfg = struct { key: []const u8, value: []const u8, soft_cap: u64 };
```

and to `Config` add fields with the exact storage-v2 §15 key names/defaults: `budget: Limit = .auto` (`store.budget`, the one knob), optional explicit `hot_cap`/`cold_cap`/`index_state_cap`/`spool_cap: ?Limit = null` (`store.hot_cap` etc., percent or bytes; must sum ≤ `budget`), `reservation_ttl: Duration = "10m"` (`store.reservation_ttl`, §10.2 TTL), and `tag_budgets: []const TagBudgetCfg = &.{}` (TOML singular `[store.tag_budget]` with `"key:value" = size` entries per §12.3, e.g. `"crate:serde" = "2GiB"`; env `RIME_TAG_BUDGET_<KEY>_<VALUE>`). `store.incremental_limit`/`incremental_max_age` and `project.incremental` are removed (→ `kind:incremental` soft budget + `max_age`); `store.hot_limit`/`store.cold_limit` stay as deprecated aliases mapped per §14.7; `project.view_dir` default becomes `target`. New env overrides `RIME_BUDGET`, `RIME_RESERVATION_TTL`, `RIME_TAG_BUDGET_*` (kept: `RIME_CACHE_DIR`, `RIME_HOT_LIMIT`/`RIME_COLD_LIMIT` deprecated alias, `RIME_NETWORK_CACHE`, `RIME_PUSH`).

Create `src/store/budget.zig` implementation above the tests:

```zig
const std = @import("std");
const config_mod = @import("config.zig");
const disk_usage = @import("disk_usage.zig");
const index_mod = @import("index.zig");

const Io = std.Io;

pub const TagBudget = struct { key: []const u8, value: []const u8, soft_cap: u64 };

pub const ResolvedBudget = struct {
    total: u64,
    hot: u64,
    cold: u64,
    index_state: u64,
    spool: u64,
    reserve: u64,
};

fn clamp(v: u64, lo: u64, hi: u64) u64 {
    return @max(lo, @min(hi, v));
}

/// Total budget (`store.budget`, storage-v2 §9.1): fixed or clamp(10% free, 5 GiB, 50 GiB).
/// Classes are hard splits of the total (hot 70 / cold 20 / index+state 5 / spool 5);
/// deprecated `hot_limit`/`cold_limit` pin their class per the §14.7 mapping;
/// explicit `hot_cap`/`cold_cap`/`index_state_cap`/`spool_cap` must sum <= budget
/// (`resolveBudgetChecked` returns `error.InvalidConfig` otherwise; leftover slack is unallocated headroom).
pub fn resolveBudget(cfg: config_mod.Config, usage: disk_usage.DiskUsage) ResolvedBudget {
    const total = switch (cfg.budget) {
        .fixed => |v| v,
        .auto => clamp(usage.free_bytes / 10, 5 * config_mod.GiB, 50 * config_mod.GiB),
    };
    const hot = switch (cfg.hot_limit) {
        .fixed => |v| v,
        .auto => total * 70 / 100,
    };
    const cold = switch (cfg.cold_limit) {
        .fixed => |v| v,
        .auto => total * 20 / 100,
    };
    const reserve = switch (cfg.disk_reserve) {
        .fixed => |v| v,
        .auto => @max(5 * config_mod.GiB, usage.fs_size / 20),
    };
    return .{
        .total = total,
        .hot = hot,
        .cold = cold,
        .index_state = total * 5 / 100,
        .spool = total * 5 / 100,
        .reserve = reserve,
    };
}

pub const ClassUsage = struct { hot: u64, cold: u64, index_state: u64, spool: u64 };

pub const UsageError = error{Unexpected, OutOfMemory} || Io.Cancelable || index_mod.DbError;

/// Hot/cold from index SUM queries (compressed sizes for cold; §12.3 CASE measure);
/// index_state and spool from recursive walks. Best-effort: unreadable entries skip.
pub fn classUsage(store: *const @import("root.zig").Store, io: Io, gpa: std.mem.Allocator) UsageError!ClassUsage {
    _ = gpa;
    var u = ClassUsage{ .hot = 0, .cold = 0, .index_state = 0, .spool = 0 };
    u.hot = try store.index.classSum(.hot);
    u.cold = try store.index.classSum(.cold);
    // index_state = index.sqlite + -wal + -shm + recursive state/ (journals, backup.json); §9.3
    if (store_dir_stat(io, store.dir, "index.sqlite")) |s| u.index_state += s;
    if (store_dir_stat(io, store.dir, "index.sqlite-wal")) |s| u.index_state += s;
    if (store_dir_stat(io, store.dir, "index.sqlite-shm")) |s| u.index_state += s;
    u.index_state += try dirBytesRecursive(io, store.dir, "state");
    u.spool = try dirBytesRecursive(io, store.dir, "tmp");
    u.spool += try store.index.reservationSum(.spool);
    return u;
}

/// Recursive size walk: follows nested fanout dirs (objects/ab/…, cold/…, state/…).
/// Counts every file; skips unreadable entries. Never follows symlinks out of the store.
fn dirBytesRecursive(io: Io, store_dir: Io.Dir, sub: []const u8) UsageError!u64 {
    var total: u64 = 0;
    const d = store_dir.openDir(io, sub, .{ .iterate = true }) catch return 0;
    defer d.close(io);
    var it = d.iterate() catch return 0;
    while (it.next(io) catch null) |entry| {
        if (entry.kind == .directory) {
            const child = std.fmt.allocPrint(std.heap.page_allocator, "{s}/{s}", .{ sub, entry.name }) catch return error.OutOfMemory;
            defer std.heap.page_allocator.free(child);
            total += try dirBytesRecursive(io, store_dir, child);
            continue;
        }
        const child = std.fmt.allocPrint(std.heap.page_allocator, "{s}/{s}", .{ sub, entry.name }) catch return error.OutOfMemory;
        defer std.heap.page_allocator.free(child);
        if (store_dir.statFile(io, child, .{})) |st| total += st.size else |_| {}
    }
    return total;
}

/// index helpers used above (add to `src/store/index.zig`):
/// `pub fn classSum(idx, class: Class) DbError!u64` — one `SELECT COALESCE(SUM(CASE …),0)` per class
/// (hot: `SUM(size)`; cold: `SUM(COALESCE(compressed_size,size))`; `both` rows count hot+cold);
/// `pub fn reservationSum(idx, class) DbError!u64` — `SUM(bytes)` over live `reservations` rows.
```

In `src/store/root.zig`: add `const budget_mod = @import("budget.zig");`, field `budget: budget_mod.ResolvedBudget` on `Store`, compute it in `open` via `budget_mod.resolveBudget(cfg, usage)` (reuse the already-read `usage`), `_ = @import("budget.zig");` in the test block. Keep `limits` field untouched (still populated; GC v1 paths use it until Task 10).

- [ ] **Step 4: Run test to verify it passes**

Run: `zig build test`
Expected: PASS — budget split tests green; classes sum to total.

- [ ] **Step 5: Request commit**

Do not commit (parent commits).

---

### Task 9: Admission control — reserve → evict → demote → StoreFull

**Files:**
- Create: `src/store/admission.zig`
- Modify: `src/store/ingest.zig` (wrap both puts with reserve/commit/abort per §16), `src/store/root.zig` (re-export `StoreFull`, `BudgetBreakdown`, `Class`, `AdmitError`)
- Test: inline in `src/store/admission.zig`

**Interfaces:**
- Consumes: `budget.ResolvedBudget`, `budget.classUsage`, `index.lruCandidates/deleteObject`, `cold.isDemotable/demote`, roots live-set builder (extracted from `gc.zig` as `gc.liveSet(store, io, gpa)` — small refactor inside `gc.zig`, no signature change to `gc`).
- Produces (storage-v2 §§10.2–10.4/16 verbatim shapes): `admission.Class = enum { hot, cold, index_state, spool }` (re-exported from `root.Class`); `admission.Hint = enum { run_gc, unpin_named, raise_budget, free_disk }`; `admission.BudgetBreakdown{ requested_bytes: u64, class: Class, budget: u64, used_total: u64, used_class: u64, cap_class: u64, reserved_class: u64, reclaimable_class: u64, hint: Hint }` (§10.4 fields exactly); `admission.AdmitError = error{ StoreFull, UnknownTagKey, TagMismatch, TagLimit } || Io.Cancelable || index.DbError`; `admission.reserve(store, io, class: Class, bytes: u64, owner: ?BuildId, breakdown: ?*BudgetBreakdown) AdmitError!Reservation` (§16 signature; `Reservation{ id: [16]u8, class: Class, bytes: u64 }` with 128-bit id, 10 min TTL row in `reservations`, optional `owner_build_id` extended to the lease TTL); `admission.commit(store, io, r: Reservation, digest: Digest) void` (ledger → file atom swap); `admission.abort(store, io, r: Reservation) void`. Admission checks the binding class cap AND `I-TOTAL` AND the `disk_reserve` floor (`StoreFull{ class = "disk_reserve" }` with free bytes). Bounded effort per admit: at most 1,000 objects AND at most 10% of the class cap (whichever bound hits first), via bounded `SUM` candidate queries — never a 1M-row fetch. `Store` gains `last_breakdown: BudgetBreakdown` (overwritten by the next admission; concurrent callers use the per-call `breakdown` out-param). CLI renders `StoreFull` with the §10.4 exact fields verbatim (`admitting N to <class> (budget B, <class> used/cap, reserved R, reclaimable Q): <hint>`); a cache-write `StoreFull` never fails the build (artifact delivered via spool, simply not cached). `putBytes`/`putFile`/`putManifest` keep signatures plus optional `breakdown: ?*BudgetBreakdown` out-param; `StoreFull` surfaces as a new `PutError` variant (additive). Fresh `put*` always reserves **hot**; demote staging reserves **cold** (estimated gzip bytes); `tmp/` staging reserves **spool**; index growth reserves **index_state** (§9.3).

- [ ] **Step 1: Write the failing tests**

Create `src/store/admission.zig` with tests first:

```zig
const std = @import("std");
const root = @import("root.zig");
const test_support = @import("test_support.zig");

test "reserve fails StoreFull when roots alone fill the budget" {
    const io = std.Io.Threaded.global_single_threaded.io();
    var ts = test_support.openTestStore(io, .{ .budget = .{ .fixed = 100 } });
    defer ts.deinit(io);

    const d = try ts.store.putBytes(io, "0123456789", .other); // 10 B
    try ts.store.pin(io, "root", d);
    // Shrink the budget below the pinned bytes: nothing evictable.
    ts.store.budget.total = 5;
    var bd: root.BudgetBreakdown = undefined;
    const r = reserve(&ts.store, io, .hot, 50, null, &bd);
    try std.testing.expectError(error.StoreFull, r);
    try std.testing.expectEqual(root.Class.hot, bd.class);
    try std.testing.expect(bd.used_total >= 10);
    try std.testing.expect(ts.store.lastFull().used_total >= 10);
}

test "reserve evicts unrooted lru before failing" {
    const io = std.Io.Threaded.global_single_threaded.io();
    var ts = test_support.openTestStore(io, .{ .budget = .{ .fixed = 24 } });
    defer ts.deinit(io);

    _ = try ts.store.putBytes(io, "aaaa", .other); // 4 B, oldest
    _ = try ts.store.putBytes(io, "bbbb", .other); // 4 B
    const before = try ts.store.index.objectCount();
    try std.testing.expectEqual(@as(u64, 2), before);
    var r = try reserve(&ts.store, io, .hot, 20, null, null);
    defer abort(&ts.store, io, r);
    // 8 B used + 20 B > 24 B total: oldest unrooted evicted to make room.
    try std.testing.expect(try ts.store.index.objectCount() < 2);
}

test "commit clears the in-flight reservation" {
    const io = std.Io.Threaded.global_single_threaded.io();
    var ts = test_support.openTestStore(io, .{ .budget = .{ .fixed = 1000 } });
    defer ts.deinit(io);

    const hex = try ts.store.putBytes(io, "x", .other);
    _ = hex;
    var bd: root.BudgetBreakdown = undefined;
    const r = try reserve(&ts.store, io, .hot, 100, null, &bd);
    try std.testing.expectEqual(@as(u64, 100), try ts.store.index.reservationSum(.hot));
    abort(&ts.store, io, r);
    try std.testing.expectEqual(@as(u64, 0), try ts.store.index.reservationSum(.hot));
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test`
Expected: FAIL with `unknown reference 'reserve'` (and `last_breakdown`/`BudgetBreakdown` §10.4 fields missing).

- [ ] **Step 3: Write minimal implementation**

Prepend to `src/store/admission.zig`:

```zig
const std = @import("std");
const root = @import("root.zig");
const budget_mod = @import("budget.zig");
const index_mod = @import("index.zig");
const cold = @import("cold.zig");
const gc_mod = @import("gc.zig");

const Io = std.Io;

pub const Class = root.Class;
pub const Hint = root.Hint;
pub const BudgetBreakdown = root.BudgetBreakdown; // §10.4 fields verbatim: requested_bytes/class/budget/used_total/used_class/cap_class/reserved_class/reclaimable_class/hint
pub const AdmitError = root.AdmitError;
pub const Reservation = root.Reservation; // { id: [16]u8, class: Class, bytes: u64 }

/// Write-time admission control (storage-v2 §10.1 order): reserve → evict unrooted LRU
/// → demote hot→cold (only when admitting to hot and cold has room) → StoreFull | commit token.
/// Scoped to the issuing class cap AND I-TOTAL AND the disk_reserve floor.
/// Bounded effort: at most 1,000 objects AND at most 10% of the class cap per admit
/// (whichever bound hits first) via bounded SUM candidate queries. Roots are never touched.
/// In-flight `reservations`-table bytes count toward the class (TTL 10 min, renewable; live
/// `owner_build_id` lease extends to the lease TTL). Spool coupling: staged tmp bytes count
/// against spool_cap; a put whose staged bytes alone exceed spool_cap fails fast with
/// `StoreFull{ class = "spool" }` before writing.
pub fn reserve(store: *root.Store, io: Io, class: Class, bytes: u64, owner: ?root.BuildId, breakdown: ?*BudgetBreakdown) AdmitError!Reservation {
    // Class-scoped admit: binding cap is the issuing class cap; I-TOTAL still binds the sum (§9.2).
    // disk_reserve floor checked first (§10.3) via statfs free space.
    const usage = try budget_mod.classUsage(store, io, gpa);
    const cap = switch (class) {
        .hot => store.budget.hot,
        .cold => store.budget.cold,
        .index_state => store.budget.index_state,
        .spool => store.budget.spool,
    };
    const used_class = switch (class) {
        .hot => usage.hot,
        .cold => usage.cold,
        .index_state => usage.index_state,
        .spool => usage.spool,
    };
    const reserved_class = try store.index.reservationSum(class);
    const free_bytes = disk_usage.freeBytes(io, store.dir);
    if (free_bytes < store.budget.reserve + bytes) {
        const bd = BudgetBreakdown{ .requested_bytes = bytes, .class = .spool, .budget = store.budget.total, .used_total = usage.hot + usage.cold + usage.index_state + usage.spool, .used_class = used_class, .cap_class = store.budget.reserve, .reserved_class = reserved_class, .reclaimable_class = 0, .hint = .free_disk };
        if (breakdown) |b| b.* = bd;
        store.last_breakdown = bd;
        return error.StoreFull;
    }
    if (used_class + reserved_class + bytes <= cap) {
        const id = io.randomBytes([16]u8);
        try store.index.insertReservation(id, class, bytes, owner);
        return .{ .id = id, .class = class, .bytes = bytes };
    }

    var live = try gc_mod.liveSet(store, io, gpa);
    defer live.deinit();
    // Bounded eviction candidates: oldest-first, at most 1,000 objects AND at most
    // 10% of the class cap (whichever bound hits first) — one bounded SUM/LIMIT query, never a full fetch.
    const cands = try store.index.evictionCandidates(gpa, class, 1000, cap / 10);
    defer store.index.freeRows(gpa, cands);

    // Pass 1: evict oldest unrooted of the issuing class, deleting bytes + rows.
    for (cands) |r| {
        if (used_class + reserved_class + bytes <= cap) break;
        if (live.contains(digestOf(r))) continue;
        evictRow(store, io, r);
    }
    // Pass 2: demote demotable hot survivors (only when admitting to hot and cold has room).
    if (class == .hot) {
        for (cands) |r| {
            if (used_class + reserved_class + bytes <= cap) break;
            if (r.tier != .hot) continue;
            if (live.contains(digestOf(r))) continue;
            const kind = std.meta.stringToEnum(root.Kind, r.kind) orelse .other;
            if (!cold.isDemotable(kind)) continue;
            const hex_d = digest_mod.Digest.fromHex(&r.digest) catch continue;
            cold.demote(store, io, hex_d) catch continue;
        }
    }

    const used_after = try budget_mod.classUsage(store, io, gpa);
    const used_class_after = switch (class) { .hot => used_after.hot, .cold => used_after.cold, .index_state => used_after.index_state, .spool => used_after.spool };
    const reserved_after = try store.index.reservationSum(class);
    if (used_class_after + reserved_after + bytes <= cap) {
        const id = io.randomBytes([16]u8);
        try store.index.insertReservation(id, class, bytes, owner);
        return .{ .id = id, .class = class, .bytes = bytes };
    }
    const reclaimable = try store.index.reclaimableBytes(class);
    const bd = BudgetBreakdown{ .requested_bytes = bytes, .class = class, .budget = store.budget.total, .used_total = used_after.hot + used_after.cold + used_after.index_state + used_after.spool, .used_class = used_class_after, .cap_class = cap, .reserved_class = reserved_after, .reclaimable_class = reclaimable, .hint = if (reclaimable == 0) .unpin_named else .run_gc };
    if (breakdown) |b| b.* = bd;
    store.last_breakdown = bd;
    return error.StoreFull;
}

pub fn commit(store: *root.Store, io: Io, r: Reservation, digest: Digest) void {
    _ = digest;
    store.index.deleteReservation(r.id) catch {};
    _ = io;
}

pub fn abort(store: *root.Store, io: Io, r: Reservation) void {
    store.index.deleteReservation(r.id) catch {};
    _ = io;
}
```

Helpers in the same file (`digestOf` parses `r.digest` to `[32]u8` for the live-set lookup; `evictRow` deletes the tier file + index row, best-effort). Needs `const digest_mod = @import("digest.zig");` — the live set is keyed by `[32]u8` exactly as in `gc.zig`. `store.lastFull()` returns the last `BudgetBreakdown` (racy under concurrency — prefer the per-call `breakdown` out-param).

`gc.zig` refactor (no behavior change): extract the Phase-0 root-collection block into `pub fn liveSet(store, io, gpa) GcError!LiveSet` returning the map (caller owns it); `gc` calls it. Make `LiveSet` and the `PresentCtx` callback `pub` for reuse.

`ingest.zig`: fresh `putBytes`/`putFile` reserve **hot** first: `const r = admission.reserve(store, io, .hot, bytes.len, owner_build_id_or_null, breakdown) catch |e| return e;` then `commit` on success / `abort` on error (commit takes the published digest for the ledger → file swap). `tmp/` staging additionally reserves **spool** by the source-length upper bound before streaming (fails fast when staged bytes alone exceed `spool_cap`). Demote staging reserves **cold** (estimated gzip bytes). Add `error.StoreFull` to `PutError`. `root.zig`: re-export `pub const Class/predicate/Tag/BudgetBreakdown/Reservation/Hint/AdmitError` from the §16 surface, add `last_breakdown: BudgetBreakdown` field (init `.{}` in `open`; `pub fn lastFull` returns it). Reservations live in the `reservations` table (TTL 10 min, `owner_build_id` nullable), not a `Store.u64` counter.

- [ ] **Step 4: Run test to verify it passes**

Run: `zig build test`
Expected: PASS — StoreFull/evict/commit tests green; all prior tests green (budgets default large in test stores).

- [ ] **Step 5: Request commit**

Do not commit (parent commits).

---

### Task 10: Tag-aware GC (index queries, per-tag soft budgets, --tag filter)

**Files:**
- Modify: `src/store/gc.zig` (additive `GcPolicy` fields, index-driven candidate loop, per-tag steering), `src/store/index.zig` (add `tagUsage(gpa, key, value) DbError!u64`, `deleteObjectsNotIn` — no, keep minimal: `tagUsage` only)
- Test: inline in `src/store/gc.zig` (append; do not edit existing tests)

**Interfaces:**
- Consumes: `liveSet` (Task 9 refactor), `tags.query`, `tag_budgets` table, `budget.classUsage`.
- Produces: `GcPolicy` gains `tag_filter: ?[]const Tag = null` (GC only considers objects carrying ALL pairs; callers pass `pred.tags`) and `honor_tag_budgets: bool = true`. `GcReport` gains `tag_skipped_objects: u64 = 0`. New `index.tagUsage(key, value)` returns the §12.3 CASE measure (hot `size`, cold `COALESCE(compressed_size,size)`, `both` = `size + COALESCE(compressed_size,0)`; `kind:` budgets sum over `objects.kind` with no tag join). Eviction order steering: when tag budgets are configured, candidates whose tag is over its soft cap sort before untagged/over-quota LRU (stable: LRU within each group). No new eviction power — same roots/dry-run guarantees.

- [ ] **Step 1: Write the failing tests**

Append to `src/store/gc.zig` tests:

```zig
test "gc with tag filter leaves untagged objects alone" {
    const io = std.Io.Threaded.global_single_threaded.io();
    const gpa = std.testing.allocator;
    var ts = test_support.openTestStore(io, fixedConfig(10));
    defer ts.deinit(io);
    ts.store.limits = .{ .hot = 10, .cold = 1, .reserve = 0 };
    ts.store.budget = .{ .total = 10, .hot = 10, .cold = 1, .index_state = 1, .spool = 1, .reserve = 0 };
    ts.store.config.max_age_ns = std.math.maxInt(u64);

    const a = try ts.store.putBytes(io, "aaaa", .other);
    const b = try ts.store.putBytes(io, "bbbb", .other);
    try ts.store.tagObject(io, a, &.{.{ .key = "project", .value = "projA" }});
    try ts.store.tagObject(io, b, &.{.{ .key = "project", .value = "projB" }});
    try setMtime(io, &ts.store, a, 1_000);
    try setMtime(io, &ts.store, b, 2_000);

    const filt = [_]root.Tag{.{ .key = "project", .value = "projB" }};
    const pred = root.Predicate{ .tags = @constCast(&filt) };
    const report = try ts.store.gc(io, gpa, .{ .tag_filter = &pred.tags });
    try std.testing.expect(ts.store.exists(io, a)); // filtered out: untouched
    _ = report;
    _ = b;
}

test "over-soft-cap tags evict first" {
    const io = std.Io.Threaded.global_single_threaded.io();
    const gpa = std.testing.allocator;
    var ts = test_support.openTestStore(io, fixedConfig(100));
    defer ts.deinit(io);
    ts.store.limits = .{ .hot = 100, .cold = 100, .reserve = 0 };
    ts.store.budget = .{ .total = 100, .hot = 100, .cold = 100, .index_state = 10, .spool = 10, .reserve = 0 };
    ts.store.config.max_age_ns = std.math.maxInt(u64);

    const old_heavy = try ts.store.putBytes(io, "old-heavy-payload", .other);
    const new_light = try ts.store.putBytes(io, "new", .other);
    try ts.store.tagObject(io, old_heavy, &.{.{ .key = "project", .value = "hungry" }});
    try ts.store.tagObject(io, new_light, &.{.{ .key = "project", .value = "lean" }});
    try ts.store.index.execAll("INSERT OR REPLACE INTO tag_budgets(key,value,soft_cap) VALUES('project','hungry',1);");
    try setMtime(io, &ts.store, old_heavy, 5_000); // newer, but over soft cap
    try setMtime(io, &ts.store, new_light, 1_000); // older, but under cap

    const report = try ts.store.gc(io, gpa, .{ .target_bytes = 1 });
    try std.testing.expect(report.evicted_objects >= 1);
    try std.testing.expect(!ts.store.exists(io, old_heavy));
    try std.testing.expect(ts.store.exists(io, new_light));
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test`
Expected: FAIL — `GcPolicy` has no `tag_filter` field; `tagUsage`/`tag` steering missing.

- [ ] **Step 3: Write minimal implementation**

In `src/store/index.zig` add:

```zig
/// §12.3 per-tag-value byte measure (hot sizes, cold compressed, both = sum of both copies).
/// For `key = "kind"` budgets the same CASE is summed over `objects` grouped by `kind` (no tag join).
pub fn tagUsage(idx: *Index, key: []const u8, value: []const u8) DbError!u64 {
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(idx.db,
        "SELECT COALESCE(SUM(CASE WHEN o.tier='hot' THEN o.size WHEN o.tier='both' THEN o.size + COALESCE(o.compressed_size, 0) ELSE COALESCE(o.compressed_size,o.size) END),0)" ++
        " FROM object_tags t JOIN objects o ON o.digest=t.digest WHERE t.key=?1 AND t.value=?2;",
        -1, &stmt, null) != c.SQLITE_OK)
        return error.DbPrepare;
    defer _ = c.sqlite3_finalize(stmt);
    bindText(stmt, 1, key);
    bindText(stmt, 2, value);
    if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return error.DbStep;
    return @intCast(c.sqlite3_column_int64(stmt, 0));
}
// `kindUsage(kind)` sibling sums the same CASE over `objects WHERE kind=?1` (for `kind:` tag_budgets).
```

In `src/store/gc.zig`: add to `GcPolicy` the fields `tag_filter: ?[]const root.Tag = null` (bound to `Predicate.tags`) and `honor_tag_budgets: bool = true`; add to `GcReport` `tag_skipped_objects: u64 = 0`. In `gc`, after building the live set, when `policy.tag_filter` is non-null, resolve the allowed digest set via `tags.query(gpa, &store.index, .{ .tags = filt })` into a `std.AutoHashMap([32]u8, void)`; every candidate loop that would evict/demote first checks membership and on miss does `report.tag_skipped_objects += 1; continue;`. For steering: before the quota sweep, when `honor_tag_budgets` and the `tag_budgets` table is non-empty, partition the sorted candidates into over-cap-tagged-first vs rest (a tag is over cap when `tagUsage > soft_cap`; an object counts as over-cap if ANY of its tags is over cap — look up the object's tags via `tags.tagsFor` once per object, cached in a map). Keep the LRU order stable inside each partition. The age-trim and emergency phases ignore tag budgets (safety first) but still respect `tag_filter`. `root.zig` needs `pub const Tag = tags_mod.Tag;` already added in Task 5 — reference it.

- [ ] **Step 4: Run test to verify it passes**

Run: `zig build test`
Expected: PASS — tag-filter and soft-cap steering tests green; all older GC tests green.

- [ ] **Step 5: Request commit**

Do not commit (parent commits).

---

### Task 11: CLI — `cache stat --by-tag` and `gc --tag`

**Files:**
- Create: `src/store/stats.zig` (per-tag breakdown)
- Modify: `src/main.zig` (arg parsing + printers), `src/store/root.zig` (re-export `stats_mod`)
- Test: inline `parseCommand` tests in `src/main.zig` (extend the existing `parseCommand covers the surface` test block with new cases — appending `try` lines, not rewriting) + inline tests in `src/store/stats.zig`

**Interfaces:**
- Consumes: `Store.lookupObjects(Predicate)`, `index.tagUsage`/`index.tagStats` (stats never touches `sqlite3_*` — index owns the C API), `Store.stats`, `budget.classUsage`.
- Produces: `stats.TagStat{ key: []const u8, value: []const u8, bytes: u64, objects: u64 }`; `stats.byTag(store, io, gpa) StatsError![]TagStat` (one row per distinct pair, ordered by bytes DESC; caller frees keys/values via `stats.freeTagStats`); `stats.tagStat(...)` for a single pair. CLI: `rime cache stat [--by-tag [k=v …]]` (no args = existing output + budget line; `--by-tag` alone = all pairs table; `--by-tag k=v` = filtered rows) and `rime gc [--dry-run] [--to-size B] [--older-than D] [--tag k=v …]` (repeatable; conjunction). Exit codes unchanged (0 ok, 1 error, 2 usage).

- [ ] **Step 1: Write the failing tests**

Create `src/store/stats.zig` with tests first:

```zig
const std = @import("std");
const root = @import("root.zig");
const test_support = @import("test_support.zig");

pub const TagStat = struct { key: []const u8, value: []const u8, bytes: u64, objects: u64 };

test "byTag aggregates bytes per pair" {
    const io = std.Io.Threaded.global_single_threaded.io();
    const gpa = std.testing.allocator;
    var ts = test_support.openTestStore(io, .{});
    defer ts.deinit(io);

    const a = try ts.store.putBytes(io, "12345", .rlib); // 5 B
    const b = try ts.store.putBytes(io, "123", .rlib); // 3 B
    try ts.store.tagObject(io, a, &.{.{ .key = "crate", .value = "serde" }, .{ .key = "crate_version", .value = "1.0.200" }});
    try ts.store.tagObject(io, b, &.{.{ .key = "crate", .value = "serde" }, .{ .key = "crate_version", .value = "1.0.200" }});
    try ts.store.tagObject(io, b, &.{.{ .key = "profile", .value = "release" }});

    const rows = try byTag(&ts.store, io, gpa);
    defer freeTagStats(gpa, rows);
    // (crate,serde)=8 B, (crate_version,1.0.200)=8 B, (profile,release)=3 B → 3 rows, 8 B first.
    try std.testing.expectEqual(@as(usize, 3), rows.len);
    try std.testing.expectEqual(@as(u64, 8), rows[0].bytes);
    try std.testing.expect(rows[0].bytes >= rows[1].bytes and rows[1].bytes >= rows[2].bytes);
}
```

Append to the `parseCommand covers the surface` test in `src/main.zig`:

```zig
    const st = try parseCommand(gpa, &.{ "cache", "stat", "--by-tag", "profile=release" });
    try std.testing.expect(st == .stat);
    try std.testing.expect(st.stat.by_tag);
    try std.testing.expectEqual(@as(usize, 1), st.stat.filters.len);
    const g = try parseCommand(gpa, &.{ "gc", "--tag", "project=projA", "--tag", "user.a=b" });
    try std.testing.expectEqual(@as(usize, 2), g.gc.tags.len);
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test`
Expected: FAIL — `byTag` undefined; `Command.stat` is a bare tag with no payload (`.stat` takes no `by_tag`).

- [ ] **Step 3: Write minimal implementation**

`src/store/stats.zig` implementation above the tests:

```zig
const index_mod = @import("index.zig");
const Io = std.Io;

pub const StatsError = error{Unexpected, OutOfMemory} || Io.Cancelable || index_mod.DbError;

/// One row per distinct tag pair, bytes DESC (index owns every sqlite3 call).
/// `stats.byTag` calls `index.tagStats` and maps rows — no `@cImport` here.
/// Caller frees via freeTagStats.
pub fn byTag(store: *root.Store, io: Io, gpa: std.mem.Allocator) StatsError![]TagStat {
    // index owns the C API: one helper returns every row already ordered bytes DESC.
    // Helper SQL (in index.zig): SELECT key,value,COALESCE(SUM(CASE WHEN tier='hot' THEN size WHEN tier='both' THEN size+COALESCE(compressed_size,0) ELSE COALESCE(compressed_size,size) END),0),COUNT(*) FROM object_tags JOIN objects ON objects.digest=object_tags.digest GROUP BY key,value ORDER BY 3 DESC.
    return try store.index.tagStats(gpa);
}

pub fn freeTagStats(gpa: std.mem.Allocator, rows: []TagStat) void {
    for (rows) |r| {
        gpa.free(r.key);
        gpa.free(r.value);
    }
    gpa.free(rows);
}
```

`src/main.zig`: keep `Command` parsing additive (no existing `cache stat` / `gc` invocation breaks) while carrying payloads — `stat: StatOpts` where `pub const StatOpts = struct { by_tag: bool = false, filters: []const []const u8 = &.{} };` (bare `cache stat` still parses with `StatOpts{}` defaults; update every `switch`/`== .stat` match site to the payload form — the old bare-tag comparison is replaced, not left compiling by accident — and extend the `parseCommand covers the surface` test with the payload assertions in Step 1). Extend the `cache` branch: after `stat`, accept optional `--by-tag` followed by zero or more `k=v` tokens (validate each contains `=` and no empty sides, else `error.Usage`). Extend `GcOpts` with `tags: []const TagFilter = &.{}` where `pub const TagFilter = struct { key: []const u8, value: []const u8 };` and parse repeatable `--tag k=v`. `cmdStat` prints the existing five lines plus `budget: total {d} (hot {d} cold {d} index+state {d} spool {d}) reservations {d}` and, when `by_tag`, one `tag {s}={s}: {d} bytes in {d} objects` line per row (or filtered subset). `cmdGc` maps `TagFilter` → `store.Tag` and passes `.tag_filter = pred.tags` (Predicate-bound). Update the usage string to `rime <cache stat [--by-tag [k=v …]]|cache verify|gc [--tag k=v …]|pin|unpin|store> …`.

- [ ] **Step 4: Run test to verify it passes**

Run: `zig build test`
Expected: PASS — stats + parseCommand extensions green; old CLI test green.

- [ ] **Step 5: Request commit**

Do not commit (parent commits).

---

### Task 12: Retire flat files — delete journal writes, make index the action path

**Files:**
- Modify: `src/store/ingest.zig` (delete `recordKind` + journal append), `src/store/action_cache.zig` (remove flat-file write-through; reads table-only with filesystem presence check via index), `src/store/scan.zig` (remove `kinds.jsonl` fallback, keep filesystem self-heal walk), `src/store/root.zig` (remove now-dead `loadKinds` references if any leak across)
- Test: no new tests; existing suites are the gate (append one guard test to `src/store/ingest.zig`)

**Interfaces:**
- Consumes: everything built so far.
- Produces: no new API. Contracts: after this task no code path writes `state/kinds.jsonl` or `actions/xx/*` files; `sweepStale`/`countStale` determine manifest presence via `index.getObject` (either tier) instead of `objects.exists`; the `actions/` and `kinds.jsonl` paths are never constructed outside `migrate.zig`.

- [ ] **Step 1: Write the failing test**

Append to `src/store/ingest.zig` tests:

```zig
test "ingest writes no journal file" {
    const io = std.Io.Threaded.global_single_threaded.io();
    var ts = test_support.openTestStore(io, .{});
    defer ts.deinit(io);

    _ = try ts.store.putBytes(io, "no journal", .rlib);
    try std.testing.expectError(error.FileNotFound, ts.store.dir.statFile(io, "state/kinds.jsonl", .{}));
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test`
Expected: FAIL — `recordKind` still appends, so `statFile` succeeds.

- [ ] **Step 3: Write minimal implementation**

`ingest.zig`: delete `recordKind` and both call sites (keep `indexUpsert` from Task 6 — kind now lives only in the `objects` row). `action_cache.zig`: `putAction` writes only the `actions` table row (`index.insertAction` from Task 7); `lookupAction` reads only the table (v1 `getAction` delegates to it); `sweepInner`'s presence callback in `gc.zig` (`PresentCtx.call`) switches from `objects.exists` to `index.getObject(...) != null` (frees the `kind` dupe immediately). Leave the stale flat files on migrated stores in place (harmless; migration already imported them) — do NOT add a deletion walk (YAGNI; a future `rime gc --compact` can reclaim them). `scan.zig`: delete `loadKinds`/`parseKindLine`/`KindMap` and the journal parameter of `scanTier`; kind comes from the index row, defaulting to `.other` for filesystem-only finds (which are immediately upserted as `.other`).

- [ ] **Step 4: Run test to verify it passes**

Run: `zig build test`
Expected: PASS — full suite green with zero journal/action-file writes (verify by `grep -rn "kinds.jsonl\|actions/" src/store/ --include=*.zig` returning only `migrate.zig` + the new guard test).

- [ ] **Step 5: Request commit**

Do not commit (parent commits).

---

## Self-review

**1. Spec coverage** (§§5–11 plus the v2 contract):
- §5 content model → Tasks 2–4 (schema stores digest/size/compressed_size/tier/kind/timestamps; actions table maps action key → manifest digest, still hints).
- §6 on-disk layout → Tasks 2, 4, 7 (`index.sqlite`+`-wal`/`-shm` at the store root; `format.json` 1→2 via explicit `rime cache migrate`; migration imports journal+actions+roots+incremental).
- §7 materialization → untouched (no changes planned; signatures preserved).
- §8 concurrency/crash safety → Tasks 2, 4, 7 (WAL+NORMAL justified by rebuildable index; `Store.open` refuses format 1 with `MigrationRequired`; explicit `rime cache migrate` holds the exclusive lock; tmp sweep unchanged).
- §9 limits/management → Tasks 8–10 (total budget + class splits + admission + tag-aware GC + soft per-tag caps; roots never evicted; dry-run deletes nothing; hysteresis 90% retained via class targets).
- §10 config/protocol → Task 8 (exact §15 keys: `store.budget`, `store.hot_cap`/`cold_cap`/`index_state_cap`/`spool_cap` with sum ≤ budget, `store.reservation_ttl="10m"`, singular `[store.tag_budget]` + `RIME_TAG_BUDGET_*`, removed incremental keys, `RIME_BUDGET`/`RIME_RESERVATION_TTL`; TOML+env parsing of the new keys is intentionally left to the config-module owner — noted as open question Q2; no open question remains on the 70/20/5/5 split itself).
- §11 module design → Tasks 4–6, 9 (Store stays the deep module; `index` owns all raw SQLite calls; new seams `budget`/`admission`/`tags`/`migrate`/`stats` each have one responsibility).
- Contract 1 (cargo compat) → no CLI surface removed; exit codes unchanged (Task 11).
- Contract 2 (global caches only) → index lives at the store root (`index.sqlite`); no project-local state added.
- Contract 3 (vendored SQLite, schema as specified) → Tasks 1–2; dependency decision flagged in Global Constraints.
- Contract 4 (bounded storage, admission, invariant) → Tasks 8–9; GC-as-hygiene in Task 10.
- Migration → Task 7. CLI additions → Task 11.

**2. Placeholder scan:** no TBD/TODO/"appropriate error handling" language; every step names exact files, signatures, SQL, and expected test output. No `SELECT 1` / `@cImportSqlite3()` scaffolding remains (Task 7 uses the real `index.insertAction` prepared INSERT; Task 3 tests free rows with `freeRows`).

**3. Type consistency (storage-v2 §16 spellings everywhere):** `Digest`/`ObjectRow`/`Tag`/`Predicate`/`TagBudget`/`ResolvedBudget`/`Class`/`Reservation`/`BuildId`/`Hint`/`BudgetBreakdown`/`AdmitError`/`GcPolicy`/`GcReport`/`ClassUsage`/`TagStat` spellings are identical across tasks. `Store.tagObject(io, digest, tags)` / `Store.lookupObjects(io, gpa, pred)` / `Store.lookupAction(io, gpa, key)` / `reserve(io, class, bytes, owner, breakdown)` / `commit(io, r, digest)` / `abort(io, r)` / `lastFull()` match §16 exactly; `tags.tagObject/tags.query/tags.tagsFor` are the index-level callees (receiver differs on purpose). `index.lruCandidates` returns rows whose `kind` must be freed with `freeRows` (Tasks 3, 9) — called out at both use sites. `getObject` returns a single row whose `kind` is freed with `gpa.free` — stated in Task 4. `TagError`/`AdmitError`/`StatsError` extend `DbError` once each (Tasks 5, 9, 11) with the §11.3/§10.4 variants.

**Gaps fixed during review:** `Store.open` refuses format 1 with `MigrationRequired` and migration runs only via `rime cache migrate [--dry-run]` with full §14.1–14.8 steps (Task 7), so concurrent opens never half-migrate; kept `limits` populated alongside `budget` (Task 8) so v1 GC paths keep working until Task 10 replaces them; flat-file deletion explicitly scoped OUT of Task 12 (reclaim belongs to a later compaction pass).

## Execution Handoff

**Plan complete and saved to `docs/superpowers/plans/2026-10-04-index-tagging-budget.md`. Two execution options:**

**1. Subagent-Driven (recommended)** - I dispatch a fresh subagent per task, review between tasks, fast iteration

**2. Inline Execution** - Execute tasks in this session using executing-plans, batch execution with checkpoints

**Which approach?**

**If Subagent-Driven chosen:**
- **REQUIRED SUB-SKILL:** Use superpowers:delegate
- Fresh subagent per task + two-stage review

**If Inline Execution chosen:**
- **REQUIRED SUB-SKILL:** Use superpowers:executing-plans
- Batch execution with checkpoints for review
