# Index, Tagging & Budget Implementation Plan (Plan B — v2 Storage Upgrade)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:delegate (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Upgrade the v1 flat-file store to v2: a vendored-SQLite metadata + tagging index, a tagging API on `Store`, write-time admission control under one total budget, tag-aware GC, and the matching CLI additions — with zero breaking changes to existing `Store` method signatures and an automatic v1→v2 migration.

**Architecture:** One new deep submodule, `index` (SQLite-backed: objects/tags/actions/pins/leases/retains tables), sits beside the existing `scan`/`state`/`action_cache` modules; `Store` gains additive methods (`tag`, `queryByTag`, `putBytesReserve` internals) while every v1 method keeps its exact signature. A `budget` module enforces reserve-before-write admission (evict → demote → `StoreFull`); GC becomes a hygiene pass that queries the index instead of scanning the filesystem. Migration (`migrate` module) bumps `format.json` 1→2 and imports the `kinds.jsonl` journal, flat action files, and `state/` JSON files into SQLite exactly once.

**Tech Stack:** Zig 0.16.0 (std + vendored SQLite3 amalgamation compiled via `build.zig` `addCSourceFile` — see Global Constraints for the flagged dependency decision), BLAKE3 via `std.crypto.hash.Blake3`, gzip via `std.compress.flate`. macOS + Linux.

**Spec:** `docs/design/storage.md` §§5–11 (content model, on-disk layout, materialization, concurrency, limits/management, config, module interfaces). This plan argues from the spec; executors read both. v1 baseline: `docs/superpowers/plans/2026-10-04-storage-core.md` Tasks 1–13 and code under `src/store/`.

## Global Constraints

- Zig **0.16.0** exactly. Every API call in this plan was verified against the v1 plan's `zig version` 0.16.0 patterns; stay within these verified patterns:
  - FS access goes through the `std.Io` interface value passed as `io` to every call.
  - `std.Io.Dir`/`std.Io.File` methods take `io` (position varies per method — copy call sites from this plan exactly).
- Dependencies: **std + exactly one vendored C source**: the SQLite3 amalgamation (`vendor/sqlite3.c`, `vendor/sqlite3.h`), compiled via `build.zig` `addCSourceFile`. **DEPENDENCY DECISION (flagged explicitly per contract):** we vendor rather than link system sqlite3 because (1) macOS ships a version-skewed libsqlite3 with no stability promise for `sqlite3_prepare_v3`/`unlikely()` behaviors we rely on, (2) a single-file amalgamation keeps `rime` a zero-install binary (cargo drop-in story), (3) the C file is never hand-edited — upgrades are whole-file drops recorded in `vendor/README.md`. Cost accepted: ~9 MB added source, ~1–2 s added build time, and the executor must compile with `-DSQLITE_THREADSAFE=1 -DSQLITE_DEFAULT_SYNCHRONOUS=2`. No packages in `build.zig.zon` except what `zig init` generates. No other C code.
- Tests are inline (`test "…"` blocks). `zig build test` must pass before **every** commit. Never commit with failing tests.
- **Additive changes only:** every existing `Store` method signature in `src/store/root.zig` keeps working byte-for-byte (`open`, `close`, `putBytes`, `putFile`, `exists`, `readObject`, `verifyObject`, `materialize`, `scan`, `touch`, `pin`, `unpin`, `leasePut`, `leaseRenew`, `leaseDrop`, `retainProject`, `putManifest`, `getManifest`, `gc`, `tryGcLock`, `unlock`, `demote`, `promote`, `dirHasHot`, `stats`, `putAction`, `getAction`). New surface is new methods/fields only. `GcPolicy` and `Config` gain only defaulted (`= …`) fields.
- Store invariants that must hold after every task (spec §11 + v2 contract): objects immutable and read-only (`0o444`); `put*` idempotent; materialization never hardlinks; `gc(.dry_run)` deletes nothing; rooted objects (pins/leases/retains) are never auto-evicted; **INVARIANT: total store bytes (objects + cold + index + state + in-flight reservations) ≤ total budget at all times.**
- Exact policy values: total budget `auto` = clamp(10% of free space, 5 GiB, 50 GiB); hard class allocations out of the total: **hot 60%, cold 25%, index+state 5%, transient spool 10%** (decision D2 below; percentages are `budget.zig` constants so one edit retunes them); hysteresis evict-to **90%** of the binding class; touch throttle **1 h** (now an index `last_access_ms` write, still throttled); `cold_after` **7 d**; `max_age` **90 d**; lease TTL **2 h**; per-tag budgets are **optional soft caps** that steer eviction order only (never cause `StoreFull`); `incremental_limit` **4 GiB** per project; `incremental_max_age` **5 d**.
- Platforms: macOS and Linux. `else => @compileError` in platform shims.
- All VCS operations use **jj** (the repo is jj-managed, colocated with git): `jj status`, `jj log`, `jj diff`, `jj commit <paths> -m "…"`, `jj describe`, `jj new`. Never run git write commands (`git add`, `git commit`, …) and never `jj git push`. Do NOT run any `jj` or `git` commands at all in these tasks — the parent commits for you; each task's final step is left as a "request commit" note instead of a commit command. `jj` auto-snapshots the working copy; `.gitignore` covers `.zig-cache/`, `zig-out/`, `.pi-subagents/`.
- Do not run builds. Write code and tests only; the `Run:` lines in each task are for the executing worker to run, not for the planner.
- Digest text form is `b3-<64 lowercase hex>` in all user-facing output; on-disk path is `objects/<hex[0..2]>/<hex[2..]>` (no `b3-` prefix). Index stores digests as 64-char lowercase hex `TEXT PRIMARY KEY`.
- Scratch experiments go in `/tmp`, never in the repo. Touch ONLY the files listed per task.

---

## Key decisions (locked for this plan)

- **D1 — SQLite, vendored amalgamation, WAL mode, one connection + busy-timeout.** The index DB is `state/index.db` (inside the 5% index+state class). `journal_mode=WAL`, `synchronous=NORMAL`, `busy_timeout=5000`. One `sqlite3*` handle per `Store`, guarded by the existing `format-lock` discipline (builds hold shared, GC/migration hold exclusive). No connection pool, no prepared-statement cache beyond one struct of `sqlite3_stmt*` prepared at open. Rationale: crash-safety (§8) comes from immutable objects + atomic ingest; the index is rebuildable from a scan, so `NORMAL` is safe and fast.
- **D2 — Total budget with hard class allocations.** One knob `total_budget` (`auto` default per the formula above) replaces `hot_limit`/`cold_limit` as the enforcement point; `hot_limit`/`cold_limit` config fields remain (additive rule) and, when set to `.fixed`, override their class allocation. Class split: hot 60 / cold 25 / index+state 5 / spool 10 (percent of total). `disk_reserve` unchanged. `StoreFull` fires only when eviction + demotion cannot free a full reservation inside the total.
- **D3 — Admission control wraps ingest, not callers.** `putBytes`/`putFile`/`putManifest` keep their signatures; internally they call `budget.reserve(store, io, gpa, size_hint)` before writing temp bytes and `budget.commit`/`budget.rollback` after publish/failure. `size_hint` for `putBytes` is exact; for `putFile` the file is first streamed to `tmp/` (counted as spool-class reservation by upper bound = source length), then renamed — so the invariant holds even for unknown sizes.
- **D4 — Index is the source of truth for metadata; filesystem stays authoritative for bytes.** Reads (`exists`, `readObject`, `getAction`) check the index first and fall back to the filesystem exactly once per miss (self-healing: a found-but-unindexed object is re-indexed on the spot). GC and `stats` read only the index. `kinds.jsonl` stops being written the moment the index lands (Task 8); the file is left on disk for the migration to import, then deleted by the migration.
- **D5 — Tags are freeform key/value pairs with a reserved `rime.*` prefix.** Reserved keys: `rime.crate` (`name@version`), `rime.toolchain`, `rime.target`, `rime.profile`, `rime.features` (feature-set hash), `rime.project`, `rime.action`, `rime.kind` (mirrors `Kind`). Anything else is a user tag. Tag queries are conjunctions (`k=v&k2=v2`); values are exact-match only (no globs — YAGNI, keeps one index shape).
- **D6 — Per-tag budgets are soft caps stored in a `tag_budgets` table**, enforced only as GC eviction-order steering (over-budget tags sort first in the LRU sweep). They never trigger `StoreFull` and never protect anything from eviction.

## File Structure

```
build.zig                  MODIFY: add sqlite3 amalgamation C source to store + exe modules
vendor/sqlite3.c           ADD: upstream amalgamation, never hand-edited (Task 1)
vendor/sqlite3.h           ADD: upstream amalgamation header (Task 1)
vendor/README.md           ADD: version + drop-in upgrade procedure (Task 1)
src/store/root.zig         MODIFY: additive Store methods only (tag/queryByTag/reserve paths,
                             stats Extensions, format_version 2 acceptance); re-exports
src/store/layout.zig      MODIFY: format_version 1 -> 2, index.db path const (Task 7)
src/store/index.zig        CREATE: SQLite wrapper — open/schema/CRUD/LRU queries (Tasks 2-4)
src/store/tags.zig         CREATE: Tag/TagQuery types + tag/untag/query logic over index (Task 5)
src/store/budget.zig       CREATE: total-budget resolution, class splits, reserve/commit/
                             rollback, StoreFull + BudgetBreakdown (Tasks 8-9)
src/store/admission.zig    CREATE: ingest wrapper wiring reserve->publish->commit (Task 9)
src/store/migrate.zig      CREATE: v1 -> v2 migration (Tasks 7)
src/store/gc.zig           MODIFY: additive GcPolicy fields (tag filter, per-tag steering),
                             index-driven candidate queries (Task 10)
src/store/stats.zig        CREATE: per-tag breakdown for `stat --by-tag` (Task 11)
src/store/config.zig       MODIFY: additive fields only (total_budget, tag_budgets path) (Task 8)
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
Compile flags (in build.zig): -DSQLITE_THREADSAFE=1 -DSQLITE_DEFAULT_SYNCHRONOUS=2.
```

In `build.zig`, add once near the top:

```zig
fn addSqlite3(m: *std.Build.Module, b: *std.Build) void {
    m.addCSourceFile(.{
        .file = b.path("vendor/sqlite3.c"),
        .flags = &.{
            "-DSQLITE_THREADSAFE=1",
            "-DSQLITE_DEFAULT_SYNCHRONOUS=2",
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
- Modify: `src/store/root.zig` (re-export + test block: swap `index_smoke.zig` for `index.zig`), `src/store/layout.zig` (add `index_file = "state/index.db"` const)
- Test: inline in `src/store/index.zig`

**Interfaces:**
- Consumes: build wiring from Task 1; `layout.state_dir`.
- Produces: `index.Index` struct with `open(io, store_dir: Io.Dir) OpenError!Index`, `close(idx: *Index) void`, `execAll(idx, sql: []const u8) ExecError!void`; schema constant `index.schema_version: u32 = 1` (index-internal; distinct from store `format.json`). Error set `index.DbError = error{DbOpen, DbExec, DbPrepare, DbStep, DbBusy, OutOfMemory, Unexpected} || Io.Cancelable`. Later tasks add statement-level CRUD; nobody outside `index.zig`/`tags.zig` calls `sqlite3_*` directly.

- [ ] **Step 1: Write the failing tests**

Create `src/store/index.zig` with types, schema SQL, and tests only:

```zig
const std = @import("std");

const c = @cImport(@cInclude("sqlite3.h"));

const Io = std.Io;

pub const DbError = error{ DbOpen, DbExec, DbPrepare, DbStep, DbBusy, OutOfMemory, Unexpected } || Io.Cancelable;

pub const schema_version: u32 = 1;

/// v2 contract schema: objects/tags/actions/pins/leases/retains + tag budgets.
/// `objects.digest_hex` is the 64-char lowercase hex (no b3- prefix).
pub const schema_sql: [:0]const u8 =
    \\CREATE TABLE IF NOT EXISTS objects(
    \\  digest_hex TEXT PRIMARY KEY,
    \\  size INTEGER NOT NULL,
    \\  compressed_size INTEGER,
    \\  tier TEXT NOT NULL CHECK(tier IN ('hot','cold')),
    \\  kind TEXT NOT NULL,
    \\  created_ms INTEGER NOT NULL,
    \\  last_access_ms INTEGER NOT NULL
    \\);
    \\CREATE TABLE IF NOT EXISTS tags(
    \\  digest_hex TEXT NOT NULL REFERENCES objects(digest_hex) ON DELETE CASCADE,
    \\  key TEXT NOT NULL,
    \\  value TEXT NOT NULL,
    \\  PRIMARY KEY(digest_hex, key, value)
    \\);
    \\CREATE INDEX IF NOT EXISTS idx_tags_key_value ON tags(key, value);
    \\CREATE TABLE IF NOT EXISTS actions(
    \\  action_hex TEXT PRIMARY KEY,
    \\  manifest_hex TEXT NOT NULL,
    \\  created_ms INTEGER NOT NULL
    \\);
    \\CREATE TABLE IF NOT EXISTS pins(
    \\  name TEXT PRIMARY KEY,
    \\  digest_hex TEXT NOT NULL,
    \\  created_ms INTEGER NOT NULL
    \\);
    \\CREATE TABLE IF NOT EXISTS leases(
    \\  build_id TEXT PRIMARY KEY,
    \\  digest_hexes TEXT NOT NULL,
    \\  expires_ms INTEGER NOT NULL
    \\);
    \\CREATE TABLE IF NOT EXISTS retains(
    \\  project_id TEXT PRIMARY KEY,
    \\  manifest_hexes TEXT NOT NULL,
    \\  updated_ms INTEGER NOT NULL
    \\);
    \\CREATE TABLE IF NOT EXISTS tag_budgets(
    \\  key TEXT NOT NULL,
    \\  value TEXT NOT NULL,
    \\  max_bytes INTEGER NOT NULL,
    \\  PRIMARY KEY(key, value)
    \\);
;

test "index opens inside a store dir and creates the schema" {
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var idx = try Index.open(io, tmp.dir);
    defer idx.close();
    try std.testing.expect(try idx.tableExists("objects"));
    try std.testing.expect(try idx.tableExists("tags"));
    try std.testing.expect(try idx.tableExists("actions"));
    try std.testing.expect(try idx.tableExists("pins"));
    try std.testing.expect(try idx.tableExists("leases"));
    try std.testing.expect(try idx.tableExists("retains"));
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

    /// Opens (creating) `state/index.db` under the store dir, applies
    /// pragmas + schema. One handle per Store (decision D1).
    pub fn open(io: Io, store_dir: Io.Dir) OpenError!Index {
        _ = io;
        try store_dir.createDirPath(io, "state");
        var path_buf: [Io.Dir.max_path_bytes]u8 = undefined;
        const dir_len = try store_dir.realPath(io, &path_buf);
        var db_path: [Io.Dir.max_path_bytes + 32]u8 = undefined;
        const full = try std.fmt.bufPrintZ(&db_path, "{s}/state/index.db", .{path_buf[0..dir_len]});

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
        _ = c.sqlite3_bind_text(stmt, 1, z.ptr, -1, c.SQLITE_TRANSIENT());
        const rc = c.sqlite3_step(stmt);
        return rc == c.SQLITE_ROW;
    }
};
```

In `src/store/layout.zig` add: `pub const index_file = "state/index.db";`. In `src/store/root.zig` replace the `index_smoke.zig` test line with `_ = @import("index.zig");` and delete `src/store/index_smoke.zig`.

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
- Produces: `index.ObjectRow{ digest_hex: [64]u8, size: u64, compressed_size: ?u64, tier: index.Tier (.hot/.cold), kind: []const u8, created_ms: i64, last_access_ms: i64 }`; `index.upsertObject(idx, row: ObjectRow) DbError!void`; `index.touchObject(idx, digest_hex, now_ms: i64) DbError!void` (single UPDATE, no throttle here — throttle lives in `scan.touch`); `index.lruCandidates(idx, gpa, tier: ?Tier, limit: u32) DbError![]ObjectRow` ordered by `last_access_ms ASC`; `index.objectCount(idx) DbError!u64`. GC (Task 10) consumes `lruCandidates`; `scan` (Task 6) consumes `upsertObject`.

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
        .digest_hex = .{'a'} ** 64,
        .size = 10,
        .compressed_size = null,
        .tier = .hot,
        .kind = "rlib",
        .created_ms = 1000,
        .last_access_ms = 3000,
    });
    try idx.upsertObject(.{
        .digest_hex = .{'b'} ** 64,
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
    try std.testing.expectEqual([64]u8, .{'b'} ** 64, rows[0].digest_hex);
    try std.testing.expectEqual(@as(u64, 2), try idx.objectCount());
}

test "touchObject moves the row to the back of lru" {
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var idx = try Index.open(io, tmp.dir);
    defer idx.close();

    try idx.upsertObject(.{
        .digest_hex = .{'c'} ** 64,
        .size = 5,
        .compressed_size = null,
        .tier = .cold,
        .kind = "other",
        .created_ms = 1000,
        .last_access_ms = 1000,
    });
    try idx.touchObject(&.{'c'} ** 64, 9999);
    const rows = try idx.lruCandidates(std.testing.allocator, .cold, 10);
    defer std.testing.allocator.free(rows);
    try std.testing.expectEqual(@as(i64, 9999), rows[0].last_access_ms);
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test`
Expected: FAIL with `unknown reference 'upsertObject'` (and `ObjectRow`, `Tier`).

- [ ] **Step 3: Write minimal implementation**

Append to `src/store/index.zig`:

```zig
pub const Tier = enum { hot, cold };

pub const ObjectRow = struct {
    digest_hex: [64]u8,
    size: u64,
    compressed_size: ?u64,
    tier: Tier,
    kind: []const u8,
    created_ms: i64,
    last_access_ms: i64,
};

fn bindText(stmt: ?*c.sqlite3_stmt, col: c_int, text: []const u8) void {
    _ = c.sqlite3_bind_text(stmt, col, text.ptr, @intCast(text.len), c.SQLITE_TRANSIENT());
}

/// INSERT OR REPLACE: ingest is idempotent, so re-put of the same digest
/// refreshes size/tier/kind but never duplicates the row.
pub fn upsertObject(idx: *Index, row: ObjectRow) DbError!void {
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(idx.db,
        "INSERT OR REPLACE INTO objects(digest_hex,size,compressed_size,tier,kind,created_ms,last_access_ms)" ++
        " VALUES(?1,?2,?3,?4,?5,?6,?7);", -1, &stmt, null) != c.SQLITE_OK)
        return error.DbPrepare;
    defer _ = c.sqlite3_finalize(stmt);
    bindText(stmt, 1, &row.digest_hex);
    _ = c.sqlite3_bind_int64(stmt, 2, @intCast(row.size));
    if (row.compressed_size) |cs| {
        _ = c.sqlite3_bind_int64(stmt, 3, @intCast(cs));
    } else {
        _ = c.sqlite3_bind_null(stmt, 3);
    }
    bindText(stmt, 4, if (row.tier == .hot) "hot" else "cold");
    bindText(stmt, 5, row.kind);
    _ = c.sqlite3_bind_int64(stmt, 6, row.created_ms);
    _ = c.sqlite3_bind_int64(stmt, 7, row.last_access_ms);
    if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.DbStep;
}

pub fn touchObject(idx: *Index, digest_hex: *const [64]u8, now_ms: i64) DbError!void {
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(idx.db,
        "UPDATE objects SET last_access_ms=?1 WHERE digest_hex=?2;", -1, &stmt, null) != c.SQLITE_OK)
        return error.DbPrepare;
    defer _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_bind_int64(stmt, 1, now_ms);
    bindText(stmt, 2, digest_hex);
    if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.DbStep;
}

/// Oldest-first candidate rows for one tier (null tier = both tiers).
/// Caller frees the slice. Fixed-size stack buffers: no allocator inside.
pub fn lruCandidates(idx: *Index, gpa: std.mem.Allocator, tier: ?Tier, limit: u32) DbError![]ObjectRow {
    const sql: [:0]const u8 = if (tier == null)
        "SELECT digest_hex,size,compressed_size,tier,kind,created_ms,last_access_ms FROM objects ORDER BY last_access_ms ASC LIMIT ?1;"
    else
        "SELECT digest_hex,size,compressed_size,tier,kind,created_ms,last_access_ms FROM objects WHERE tier=?2 ORDER BY last_access_ms ASC LIMIT ?1;";
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(idx.db, sql.ptr, -1, &stmt, null) != c.SQLITE_OK)
        return error.DbPrepare;
    defer _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_bind_int64(stmt, 1, @intCast(limit));
    if (tier) |t| bindText(stmt, 2, if (t == .hot) "hot" else "cold");

    var list: std.ArrayList(ObjectRow) = .empty;
    errdefer list.deinit(gpa);
    while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
        var row = ObjectRow{
            .digest_hex = undefined,
            .size = @intCast(c.sqlite3_column_int64(stmt, 1)),
            .compressed_size = if (c.sqlite3_column_type(stmt, 2) == c.SQLITE_NULL)
                null
            else
                @intCast(c.sqlite3_column_int64(stmt, 2)),
            .tier = if (std.mem.eql(u8, std.mem.span(c.sqlite3_column_text(stmt, 3)), "hot")) .hot else .cold,
            .kind = "",
            .created_ms = c.sqlite3_column_int64(stmt, 5),
            .last_access_ms = c.sqlite3_column_int64(stmt, 6),
        };
        const hex_ptr = c.sqlite3_column_text(stmt, 0);
        @memcpy(&row.digest_hex, std.mem.span(hex_ptr)[0..64]);
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
- Produces: `index.deleteObject(idx, digest_hex) DbError!void`; `index.setTier(idx, digest_hex, tier, compressed_size: ?u64) DbError!void`; `index.getObject(idx, digest_hex) DbError!?ObjectRow` (caller frees `kind` via `gpa.free` — signature `getObject(idx, gpa, digest_hex)`). `Store.open` on a v2 store opens the index after the shared lock is taken; `Store.close` closes the index before unlocking. No signature changes to `open`/`close`.

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
        .digest_hex = .{'d'} ** 64,
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
pub fn deleteObject(idx: *Index, digest_hex: *const [64]u8) DbError!void {
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(idx.db, "DELETE FROM objects WHERE digest_hex=?1;", -1, &stmt, null) != c.SQLITE_OK)
        return error.DbPrepare;
    defer _ = c.sqlite3_finalize(stmt);
    bindText(stmt, 1, digest_hex);
    if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.DbStep;
}

pub fn setTier(idx: *Index, digest_hex: *const [64]u8, tier: Tier, compressed_size: ?u64) DbError!void {
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(idx.db,
        "UPDATE objects SET tier=?1, compressed_size=?2 WHERE digest_hex=?3;", -1, &stmt, null) != c.SQLITE_OK)
        return error.DbPrepare;
    defer _ = c.sqlite3_finalize(stmt);
    bindText(stmt, 1, if (tier == .hot) "hot" else "cold");
    if (compressed_size) |cs| {
        _ = c.sqlite3_bind_int64(stmt, 2, @intCast(cs));
    } else {
        _ = c.sqlite3_bind_null(stmt, 2);
    }
    bindText(stmt, 3, digest_hex);
    if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.DbStep;
}

/// Null when the digest is not indexed. Caller frees `row.kind`.
pub fn getObject(idx: *Index, gpa: std.mem.Allocator, digest_hex: *const [64]u8) DbError!?ObjectRow {
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(idx.db,
        "SELECT size,compressed_size,tier,kind,created_ms,last_access_ms FROM objects WHERE digest_hex=?1;",
        -1, &stmt, null) != c.SQLITE_OK)
        return error.DbPrepare;
    defer _ = c.sqlite3_finalize(stmt);
    bindText(stmt, 1, digest_hex);
    if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return null;
    return ObjectRow{
        .digest_hex = digest_hex.*,
        .size = @intCast(c.sqlite3_column_int64(stmt, 0)),
        .compressed_size = if (c.sqlite3_column_type(stmt, 1) == c.SQLITE_NULL)
            null
        else
            @intCast(c.sqlite3_column_int64(stmt, 1)),
        .tier = if (std.mem.eql(u8, std.mem.span(c.sqlite3_column_text(stmt, 2)), "hot")) .hot else .cold,
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

### Task 5: Tagging API (tags.zig + Store.tag/queryByTag)

**Files:**
- Create: `src/store/tags.zig`
- Modify: `src/store/root.zig` (additive `tag`, `untag`, `queryByTag`, `tagsFor` methods + re-exports)
- Test: inline in `src/store/tags.zig`

**Interfaces:**
- Consumes: `index.Index`, `Digest`.
- Produces: `tags.Tag{ key: []const u8, value: []const u8 }`; `tags.Reserved` prefix const `tags.rime_prefix = "rime."`; `tags.tag(idx, digest_hex, key, value) DbError!void`; `tags.untag(idx, digest_hex, key, value) DbError!void`; `tags.tagsFor(idx, gpa, digest_hex) DbError![]Tag` (caller frees via `tags.freeTags`); `tags.query(idx, gpa, filt: []const Tag) DbError![][64]u8` (conjunction = INTERSECT over per-pair selects; empty filter returns all digests up to 1M rows). Store wrappers with identical names minus `idx`: `store.tag(io, digest, key, value) TagError!void`, `store.untag(io, digest, key, value) TagError!void`, `store.queryByTag(io, gpa, filt) TagError![]Digest`, `store.tagsFor(io, gpa, digest) TagError![]Tag`. `TagError = index.DbError` (re-export, no new failure modes).

- [ ] **Step 1: Write the failing tests**

Create `src/store/tags.zig` with tests first:

```zig
const std = @import("std");
const index_mod = @import("index.zig");
const digest_mod = @import("digest.zig");

pub const rime_prefix = "rime.";

pub const Tag = struct { key: []const u8, value: []const u8 };

test "tag query conjunction narrows results" {
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var idx = try index_mod.Index.open(io, tmp.dir);
    defer idx.close();

    const a: [64]u8 = .{'a'} ** 64;
    const b: [64]u8 = .{'b'} ** 64;
    try idx.upsertObject(.{ .digest_hex = a, .size = 1, .compressed_size = null, .tier = .hot, .kind = "rlib", .created_ms = 1, .last_access_ms = 1 });
    try idx.upsertObject(.{ .digest_hex = b, .size = 1, .compressed_size = null, .tier = .hot, .kind = "rlib", .created_ms = 1, .last_access_ms = 1 });
    try tag(&idx, &a, "rime.crate", "serde@1.0.200");
    try tag(&idx, &a, "rime.profile", "release");
    try tag(&idx, &b, "rime.crate", "serde@1.0.200");

    const both = try query(std.testing.allocator, &idx, &.{ .{ .key = "rime.crate", .value = "serde@1.0.200" } });
    defer std.testing.allocator.free(both);
    try std.testing.expectEqual(@as(usize, 2), both.len);

    const narrow = try query(std.testing.allocator, &idx, &.{
        .{ .key = "rime.crate", .value = "serde@1.0.200" },
        .{ .key = "rime.profile", .value = "release" },
    });
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
    try idx.upsertObject(.{ .digest_hex = a, .size = 1, .compressed_size = null, .tier = .hot, .kind = "other", .created_ms = 1, .last_access_ms = 1 });
    try tag(&idx, &a, "custom", "x");
    try tag(&idx, &a, "custom", "y");
    try untag(&idx, &a, "custom", "x");
    const left = try tagsFor(std.testing.allocator, &idx, &a);
    defer freeTags(std.testing.allocator, left);
    try std.testing.expectEqual(@as(usize, 1), left.len);
    try std.testing.expectEqualStrings("y", left[0].value);
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test`
Expected: FAIL with `unknown reference 'tag'` / `'query'` / `'tagsFor'`.

- [ ] **Step 3: Write minimal implementation**

Prepend to `src/store/tags.zig` (above the tests):

```zig
const DbError = index_mod.DbError;
const c = @cImport(@cInclude("sqlite3.h"));

fn bindText(stmt: ?*c.sqlite3_stmt, col: c_int, text: []const u8) void {
    _ = c.sqlite3_bind_text(stmt, col, text.ptr, @intCast(text.len), c.SQLITE_TRANSIENT());
}

pub fn tag(idx: *index_mod.Index, digest_hex: *const [64]u8, key: []const u8, value: []const u8) DbError!void {
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(idx.db, "INSERT OR IGNORE INTO tags(digest_hex,key,value) VALUES(?1,?2,?3);", -1, &stmt, null) != c.SQLITE_OK)
        return error.DbPrepare;
    defer _ = c.sqlite3_finalize(stmt);
    bindText(stmt, 1, digest_hex);
    bindText(stmt, 2, key);
    bindText(stmt, 3, value);
    if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.DbStep;
}

pub fn untag(idx: *index_mod.Index, digest_hex: *const [64]u8, key: []const u8, value: []const u8) DbError!void {
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(idx.db, "DELETE FROM tags WHERE digest_hex=?1 AND key=?2 AND value=?3;", -1, &stmt, null) != c.SQLITE_OK)
        return error.DbPrepare;
    defer _ = c.sqlite3_finalize(stmt);
    bindText(stmt, 1, digest_hex);
    bindText(stmt, 2, key);
    bindText(stmt, 3, value);
    if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.DbStep;
}

pub fn tagsFor(gpa: std.mem.Allocator, idx: *index_mod.Index, digest_hex: *const [64]u8) DbError![]Tag {
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(idx.db, "SELECT key,value FROM tags WHERE digest_hex=?1 ORDER BY key,value;", -1, &stmt, null) != c.SQLITE_OK)
        return error.DbPrepare;
    defer _ = c.sqlite3_finalize(stmt);
    bindText(stmt, 1, digest_hex);
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

/// Conjunction query: objects carrying ALL pairs. One SELECT per pair
/// INTERSECTed; empty filter lists every object (capped at 1M rows).
pub fn query(gpa: std.mem.Allocator, idx: *index_mod.Index, filt: []const Tag) DbError![][64]u8 {
    if (filt.len == 0) {
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(idx.db, "SELECT digest_hex FROM objects LIMIT 1000000;", -1, &stmt, null) != c.SQLITE_OK)
            return error.DbPrepare;
        defer _ = c.sqlite3_finalize(stmt);
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
        sql.writer().print("SELECT digest_hex FROM tags WHERE key=?{d} AND value=?{d}", .{ 2 * i + 1, 2 * i + 2 }) catch return error.Unexpected;
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

In `src/store/root.zig` add `const tags_mod = @import("tags.zig");`, `_ = @import("tags.zig");` in the test block, re-exports `pub const Tag = tags_mod.Tag;` and `pub const TagError = index_mod.DbError;`, plus Store methods:

```zig
    pub fn tag(store: *Store, io: Io, d: Digest, key: []const u8, value: []const u8) TagError!void {
        _ = io;
        const hex = d.toHex();
        return tags_mod.tag(&store.index, &hex, key, value);
    }

    pub fn untag(store: *Store, io: Io, d: Digest, key: []const u8, value: []const u8) TagError!void {
        _ = io;
        const hex = d.toHex();
        return tags_mod.untag(&store.index, &hex, key, value);
    }

    pub fn tagsFor(store: *Store, io: Io, gpa: std.mem.Allocator, d: Digest) TagError![]Tag {
        _ = io;
        _ = gpa;
        const hex = d.toHex();
        return tags_mod.tagsFor(gpa, &store.index, &hex);
    }

    pub fn queryByTag(store: *Store, io: Io, gpa: std.mem.Allocator, filt: []const Tag) TagError![]Digest {
        _ = io;
        const hexes = try tags_mod.query(gpa, &store.index, filt);
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
test "scan serves indexed objects without walking after delete of journal" {
    const io = std.Io.Threaded.global_single_threaded.io();
    const gpa = std.testing.allocator;
    var ts = test_support.openTestStore(io, .{});
    defer ts.deinit(io);

    const d = try ts.store.putBytes(io, "indexed", .rlib);
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
Expected: FAIL — `putBytes` does not yet upsert index rows so `scan` (once switched) misses; `putAction` index mirror missing. (If run before the Step 3 edits, the scan test passes vacuously on the old path — the gate is the post-edit behavior; executors must confirm the new tests exercise the index path by temporarily breaking the filesystem fallback. Document the check in the commit note.)

- [ ] **Step 3: Write minimal implementation**

`ingest.zig`: after `publish` + `recordKind` in both `putBytes` and `putFile`, upsert the index row (hot tier, `created_ms = last_access_ms = now`):

```zig
fn indexUpsert(store: *root.Store, io: Io, d: Digest, size: u64, kind: root.Kind) void {
    const now_ms = Io.Timestamp.now(io, .real).toMilliseconds();
    const hex = d.toHex();
    store.index.upsertObject(.{
        .digest_hex = hex,
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

`state.zig`: after each successful `writeJsonAtomic` in `putPin`/`putLease`/`putRetain`, mirror the row into the index (`pins`/`leases`/`retains` tables; leases serialize `digest_hexes` as comma-joined 64-hex). This requires `state` functions to take the `*Index` — but signatures are internal (only `Store` calls them), so add a trailing `idx: *index_mod.Index` parameter to `putPin`, `removePin`, `putLease`, `renewLease`, `dropLease`, `putRetain` and update the `Store` wrappers in `root.zig` to pass `&store.index`. `removePin`/`dropLease` also delete the index row. Read paths (`listPins`, `liveLeases`, `listRetains`) keep reading JSON (authoritative, decision D4).

`action_cache.zig`: `putAction`/`getAction` take the same new trailing `idx` parameter pattern; write-through to both the flat file and the `actions` table; `getAction` checks the table first, then the file (re-index on file hit). `sweepStale`/`countStale` keep filesystem behavior — GC's index-driven sweep lands in Task 10.

`cold.zig`: after a successful demote, call `store.index.setTier(&hex, .cold, compressed_size)`; after promote, `setTier(&hex, .hot, null)`. After `gc` evicts (in `gc.zig` `evict`), call `store.index.deleteObject(&hex)` (best-effort `catch {}` — bytes are authoritative).

- [ ] **Step 4: Run test to verify it passes**

Run: `zig build test`
Expected: PASS — new mirror tests green; every v1 test still green.

- [ ] **Step 5: Request commit**

Do not commit (parent commits).

---

### Task 7: Migration v1 → v2 (format.json 1 → 2, journal + action + state import)

**Files:**
- Create: `src/store/migrate.zig`
- Modify: `src/store/layout.zig` (`format_version: u32 = 2`, add `kinds_journal = "state/kinds.jsonl"` const), `src/store/root.zig` (`Store.open` runs migration when `format.json == 1`)
- Test: inline in `src/store/migrate.zig`

**Interfaces:**
- Consumes: `Index`, `layout` consts, `state.listPins/liveLeases/listRetains`, `scan` filesystem walk.
- Produces: `migrate.migrateIfNeeded(io, store_dir: Io.Dir, idx: *Index) MigrateError!bool` (returns true when it migrated; no-op when `format.json` already `2`). `MigrateError = index.DbError || state.StateError || scan.ScanError`. `Store.open` calls it after opening the index and before sweeping tmp: on `format == 1`, take the work under the already-held shared lock upgraded… no — migration needs exclusivity: `open` attempts `tryLock(.exclusive)`; if that fails, return `error.StoreBusyMigrating` (caller retries; builds never half-migrate). New `OpenError` variant documented in root.zig.

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
    try std.testing.expect(try migrateIfNeeded(io, tmp.dir, &idx));
    try std.testing.expect(!(try migrateIfNeeded(io, tmp.dir, &idx))); // second run is a no-op

    const fmt = try tmp.dir.readFileAlloc(io, "format.json", std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(fmt);
    try std.testing.expect(std.mem.indexOf(u8, fmt, "\"format\":2") != null);
}

test "migrate on fresh format-2 store is a no-op" {
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "state");
    try tmp.dir.writeFile(io, .{ .sub_path = "format.json", .data = "{\"format\":2}\n" });
    var idx = try index_mod.Index.open(io, tmp.dir);
    defer idx.close();
    try std.testing.expect(!(try migrateIfNeeded(io, tmp.dir, &idx)));
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test`
Expected: FAIL with `unknown reference 'migrateIfNeeded'`.

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

/// Imports v1 flat state into the index and bumps format.json to 2.
/// Idempotent: safe to re-run (all writes are INSERT OR REPLACE / IGNORE).
pub fn migrateIfNeeded(io: Io, store_dir: Io.Dir, idx: *index_mod.Index) MigrateError!bool {
    const fmt_bytes = store_dir.readFileAlloc(io, layout.format_file, std.heap.page_allocator, .unlimited) catch return false;
    defer std.heap.page_allocator.free(fmt_bytes);
    const parsed = std.json.parseFromSlice(layout.FormatJson, std.heap.page_allocator, fmt_bytes, .{}) catch return false;
    defer parsed.deinit();
    if (parsed.value.format != 1) return false;

    try importJournal(io, store_dir, idx);
    try importActions(io, store_dir, idx);
    try importRoots(io, store_dir, idx);

    store_dir.writeFile(io, .{ .sub_path = layout.format_file, .data = "{\"format\":2}\n" }) catch return error.Unexpected;
    // Journal is superseded by the objects table (decision D4); remove it so
    // no writer ever appends post-migration lines.
    store_dir.deleteFile(io, "state/kinds.jsonl") catch {};
    return true;
}

/// Journal lines: {"digest":"<64hex>","kind":"<tag>"}; malformed lines skipped.
fn importJournal(io: Io, store_dir: Io.Dir, idx: *index_mod.Index) MigrateError!void {
    const bytes = store_dir.readFileAlloc(io, "state/kinds.jsonl", std.heap.page_allocator, .unlimited) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return error.Unexpected,
    };
    defer std.heap.page_allocator.free(bytes);
    const now_ms = Io.Timestamp.now(io, .real).toMilliseconds();
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const entry = parseJournalLine(line) catch continue;
        // Size/tier come from the real file; journal only supplies kind.
        const st = statBothTiers(store_dir, io, entry.digest) catch continue;
        var hex: [64]u8 = undefined;
        hex = entry.digest.toHex();
        idx.upsertObject(.{
            .digest_hex = hex,
            .size = st.size,
            .compressed_size = if (st.tier == .cold) st.size else null,
            .tier = st.tier,
            .kind = @tagName(entry.kind),
            .created_ms = now_ms,
            .last_access_ms = st.mtime_ms,
        }) catch return error.Unexpected;
    }
}

const JournalEntry = struct { digest: digest_mod.Digest, kind: KindAlias };
const KindAlias = enum { rlib, rmeta, obj, staticlib, dylib, bin, dep_info, manifest, build_script_out, source, other };

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

/// Flat action files actions/xx/<hex> -> {"manifest_hex":…}: import each.
fn importActions(io: Io, store_dir: Io.Dir, idx: *index_mod.Index) MigrateError!void {
    const top = store_dir.openDir(io, "actions", .{ .iterate = true }) catch return;
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
            const rel = std.fmt.allocPrint(std.heap.page_allocator, "actions/{s}/{s}", .{ fanout.name, entry.name }) catch return error.OutOfMemory;
            defer std.heap.page_allocator.free(rel);
            const bytes = store_dir.readFileAlloc(io, rel, std.heap.page_allocator, .limited(4096)) catch continue;
            defer std.heap.page_allocator.free(bytes);
            const parsed = std.json.parseFromSlice(struct { manifest_hex: []const u8, created_ms: i64 }, std.heap.page_allocator, bytes, .{}) catch continue;
            defer parsed.deinit();
            var stmt: ?*@cImportSqlite3().sqlite3_stmt = null;
            _ = stmt;
            _ = idx;
            _ = now_ms;
            // Real insert is one line; kept explicit so executors see it:
            idx.execAll("SELECT 1;") catch return error.Unexpected;
            _ = parsed;
        }
    }
}

/// Pins/leases/retains JSON -> index mirror tables (authoritative files stay).
fn importRoots(io: Io, store_dir: Io.Dir, idx: *index_mod.Index) MigrateError!void {
    const gpa = std.heap.page_allocator;
    const now_ms = Io.Timestamp.now(io, .real).toMilliseconds();
    const pins = try state.listPins(io, gpa, store_dir);
    defer state.freePins(gpa, pins);
    for (pins) |p| {
        const sql = try std.fmt.allocPrintZ(gpa, "INSERT OR IGNORE INTO pins(name,digest_hex,created_ms) VALUES('{s}','{s}',{d});", .{ p.name, p.digest_hex, now_ms });
        defer gpa.free(sql);
        idx.execAll(sql) catch return error.Unexpected;
    }
    const leases = try state.peekLiveLeases(io, gpa, store_dir, now_ms);
    defer state.freeLeases(gpa, leases);
    for (leases) |l| {
        const joined = try joinHexes(gpa, l.digest_hexes);
        defer gpa.free(joined);
        const sql = try std.fmt.allocPrintZ(gpa, "INSERT OR REPLACE INTO leases(build_id,digest_hexes,expires_ms) VALUES('{s}','{s}',{d});", .{ l.build_id, joined, l.expires_ms });
        defer gpa.free(sql);
        idx.execAll(sql) catch return error.Unexpected;
    }
    const retains = try state.listRetains(io, gpa, store_dir);
    defer state.freeRetains(gpa, retains);
    for (retains) |r| {
        const joined = try joinHexes(gpa, r.manifest_hexes);
        defer gpa.free(joined);
        const sql = try std.fmt.allocPrintZ(gpa, "INSERT OR REPLACE INTO retains(project_id,manifest_hexes,updated_ms) VALUES('{s}','{s}',{d});", .{ r.project_id, joined, r.updated_ms });
        defer gpa.free(sql);
        idx.execAll(sql) catch return error.Unexpected;
    }
}

fn joinHexes(gpa: std.mem.Allocator, hexes: []const []const u8) error{OutOfMemory}![]u8 {
    var total: usize = 0;
    for (hexes, 0..) |h, i| total += h.len + @intFromBool(i > 0);
    var out = try gpa.alloc(u8, total);
    var pos: usize = 0;
    for (hexes, 0..) |h, i| {
        if (i > 0) {
            out[pos] = ',';
            pos += 1;
        }
        @memcpy(out[pos..][0..h.len], h);
        pos += h.len;
    }
    return out;
}
```

NOTE to executors (fix before implementing): the `importActions` sketch above uses two placeholders that must be replaced with a real prepared INSERT — add `index.insertAction(idx, action_hex: *const [64]u8, manifest_hex: []const u8, created_ms: i64) DbError!void` to `index.zig` (same shape as `upsertObject`, one `INSERT OR REPLACE INTO actions…` statement) and call it from `importActions` after parsing each file with `Digest.fromHex(entry.name)` for the key. The `@cImportSqlite3()` / `SELECT 1` lines are scaffolding to delete, not code to keep.

In `src/store/layout.zig`: change `format_version` to `2`, add `pub const kinds_journal = "state/kinds.jsonl";`. In `src/store/root.zig`: `Store.open` — after the format.json validation, if version is `1`, attempt the exclusive lock upgrade for migration (`store.lock_file.tryLock(io, .exclusive)` → run `migrate.migrateIfNeeded` → downgrade back to shared; on failure return `error.StoreBusyMigrating`); accept both `1` and `2` as known versions, refuse anything else with `error.UnknownFormat`. Keep the v1 test `store open refuses unknown format version` passing (99 still refused); the existing `store open creates layout` test now asserts `"format":2` content on fresh creation — update that test's expectation string accordingly.

- [ ] **Step 4: Run test to verify it passes**

Run: `zig build test`
Expected: PASS — migration tests green; v1 layout tests updated and green.

- [ ] **Step 5: Request commit**

Do not commit (parent commits).

---

### Task 8: Total-budget config + class allocation model

**Files:**
- Create: `src/store/budget.zig` (resolution + class split + usage accounting)
- Modify: `src/store/config.zig` (additive fields: `total_budget: Limit = .auto`, `tag_budgets: []TagBudget = &.{}`, `spool_limit` derived not configured), `src/store/root.zig` (Store gains `budget: budget_mod.ResolvedBudget`)
- Test: inline in `src/store/budget.zig`

**Interfaces:**
- Consumes: `config.Limit`, `disk_usage.DiskUsage`, `index.objectCount`/sums.
- Produces: `budget.TagBudget{ key: []const u8, value: []const u8, max_bytes: u64 }` (soft cap, decision D6); `budget.ResolvedBudget{ total: u64, hot: u64, cold: u64, index_state: u64, spool: u64, reserve: u64 }`; `budget.resolveBudget(cfg: Config, usage: DiskUsage) ResolvedBudget` (total = fixed or clamp(10% free, 5GiB, 50GiB); classes = 60/25/5/10% of total; `hot_limit.fixed`/`cold_limit.fixed` override their class when set; reserve unchanged); `budget.classUsage(store, io, gpa) ClassUsage!{hot, cold, index_state, spool}` (hot/cold from index sums at compressed sizes; index_state = `statFile(state/index.db)` + `state/` walk; spool = `tmp/` walk).

- [ ] **Step 1: Write the failing tests**

Create `src/store/budget.zig` with tests first:

```zig
const std = @import("std");
const config_mod = @import("config.zig");

test "auto total splits into hard classes" {
    const b = resolveBudget(.{}, .{ .free_bytes = 1000 * config_mod.GiB, .fs_size = 2000 * config_mod.GiB });
    // clamp(10% of 1000 GiB, 5 GiB, 50 GiB) = 50 GiB total
    try std.testing.expectEqual(@as(u64, 50 * config_mod.GiB), b.total);
    try std.testing.expectEqual(@as(u64, 30 * config_mod.GiB), b.hot);
    try std.testing.expectEqual(@as(u64, 25 * config_mod.GiB / 2), b.cold);
    try std.testing.expectEqual(b.total, b.hot + b.cold + b.index_state + b.spool);
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
    const cfg = config_mod.Config{ .total_budget = .{ .fixed = 20 * config_mod.GiB } };
    const b = resolveBudget(cfg, .{ .free_bytes = 10 * config_mod.GiB, .fs_size = 10 * config_mod.GiB });
    try std.testing.expectEqual(@as(u64, 20 * config_mod.GiB), b.total);
    try std.testing.expectEqual(@as(u64, 12 * config_mod.GiB), b.hot);
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test`
Expected: FAIL with `unknown reference 'resolveBudget'` (and `total_budget` field missing on `Config`).

- [ ] **Step 3: Write minimal implementation**

In `src/store/config.zig` add (additive only — no existing field touched):

```zig
pub const TagBudgetCfg = struct { key: []const u8, value: []const u8, max_bytes: u64 };
```

and to `Config` add fields `total_budget: Limit = .auto` and `tag_budgets: []const TagBudgetCfg = &.{}`.

Create `src/store/budget.zig` implementation above the tests:

```zig
const std = @import("std");
const config_mod = @import("config.zig");
const disk_usage = @import("disk_usage.zig");
const index_mod = @import("index.zig");

const Io = std.Io;

pub const TagBudget = struct { key: []const u8, value: []const u8, max_bytes: u64 };

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

/// Total budget: fixed or clamp(10% free, 5 GiB, 50 GiB). Classes are hard
/// splits of the total (hot 60 / cold 25 / index+state 5 / spool 10);
/// legacy fixed hot/cold limits override their class (additive compat).
pub fn resolveBudget(cfg: config_mod.Config, usage: disk_usage.DiskUsage) ResolvedBudget {
    const total = switch (cfg.total_budget) {
        .fixed => |v| v,
        .auto => clamp(usage.free_bytes / 10, 5 * config_mod.GiB, 50 * config_mod.GiB),
    };
    const hot = switch (cfg.hot_limit) {
        .fixed => |v| v,
        .auto => total * 60 / 100,
    };
    const cold = switch (cfg.cold_limit) {
        .fixed => |v| v,
        .auto => total * 25 / 100,
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
        .spool = total * 10 / 100,
        .reserve = reserve,
    };
}

pub const ClassUsage = struct { hot: u64, cold: u64, index_state: u64, spool: u64 };

pub const UsageError = error{Unexpected, OutOfMemory} || Io.Cancelable || index_mod.DbError;

/// Hot/cold from the index (compressed sizes for cold); index_state and
/// spool from small directory walks. Best-effort: unreadable entries skip.
pub fn classUsage(store: *const @import("root.zig").Store, io: Io, gpa: std.mem.Allocator) UsageError!ClassUsage {
    _ = gpa;
    var u = ClassUsage{ .hot = 0, .cold = 0, .index_state = 0, .spool = 0 };
    const rows = try store.index.lruCandidates(std.heap.page_allocator, null, 1_000_000);
    defer store.index.freeRows(std.heap.page_allocator, rows);
    for (rows) |r| switch (r.tier) {
        .hot => u.hot += r.size,
        .cold => u.cold += r.compressed_size orelse r.size,
    };
    u.index_state = try dirBytes(io, store.dir, "state");
    u.spool = try dirBytes(io, store.dir, "tmp");
    return u;
}

fn dirBytes(io: Io, store_dir: Io.Dir, sub: []const u8) UsageError!u64 {
    var total: u64 = 0;
    const d = store_dir.openDir(io, sub, .{ .iterate = true }) catch return 0;
    defer d.close(io);
    var it = d.iterate() catch return 0;
    while (it.next(io) catch null) |entry| {
        const st = d.statFile(io, entry.name, .{}) catch continue;
        if (st.kind == .directory) continue; // one level is enough: state/ files + index.db are flat-ish
        total += st.size;
    }
    // Add index.db explicitly (it lives one level down: state/index.db).
    if (std.mem.eql(u8, sub, "state")) {
        if (store_dir.statFile(io, "state/index.db", .{})) |st| total += st.size else |_| {}
        if (store_dir.statFile(io, "state/index.db-wal", .{})) |st| total += st.size else |_| {}
    }
    return total;
}
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
- Modify: `src/store/ingest.zig` (wrap both puts with reserve/commit/rollback), `src/store/root.zig` (re-export `StoreFull`, `BudgetBreakdown`)
- Test: inline in `src/store/admission.zig`

**Interfaces:**
- Consumes: `budget.ResolvedBudget`, `budget.classUsage`, `index.lruCandidates/deleteObject`, `cold.isDemotable/demote`, roots live-set builder (extracted from `gc.zig` as `gc.liveSet(store, io, gpa)` — small refactor inside `gc.zig`, no signature change to `gc`).
- Produces: `admission.BudgetBreakdown{ total: u64, used: u64, hot_used: u64, cold_used: u64, index_state_used: u64, spool_used: u64, reservations: u64 }`; `admission.AdmissionError = error{ StoreFull, OutOfMemory, Unexpected } || Io.Cancelable || index.DbError`; `admission.reserve(store, io, gpa, bytes: u64) AdmissionError!Reservation` (registers an in-flight reservation in a `Store.reservations: u64` counter; evicts oldest unrooted LRU then demotes demotable hot objects until `used + bytes ≤ total`; returns `StoreFull` with breakdown attached via `store.last_breakdown` when it cannot); `admission.commit(store, r: Reservation) void`; `admission.rollback(store, r: Reservation) void`. `Store` gains additive fields `reservations: u64` (init 0 in `open`) and `last_breakdown: BudgetBreakdown`. `putBytes`/`putFile` signatures unchanged; `StoreFull` surfaces as a new `PutError` variant (additive: callers matching `else` still compile; document in task).

- [ ] **Step 1: Write the failing tests**

Create `src/store/admission.zig` with tests first:

```zig
const std = @import("std");
const root = @import("root.zig");
const test_support = @import("test_support.zig");

test "reserve fails StoreFull when roots alone fill the budget" {
    const io = std.Io.Threaded.global_single_threaded.io();
    var ts = test_support.openTestStore(io, .{ .total_budget = .{ .fixed = 100 } });
    defer ts.deinit(io);

    const d = try ts.store.putBytes(io, "0123456789", .other); // 10 B
    try ts.store.pin(io, "root", d);
    // Shrink the budget below the pinned bytes: nothing evictable.
    ts.store.budget.total = 5;
    const r = reserve(&ts.store, io, std.testing.allocator, 50);
    try std.testing.expectError(error.StoreFull, r);
    try std.testing.expect(ts.store.last_breakdown.used >= 10);
}

test "reserve evicts unrooted lru before failing" {
    const io = std.Io.Threaded.global_single_threaded.io();
    var ts = test_support.openTestStore(io, .{ .total_budget = .{ .fixed = 24 } });
    defer ts.deinit(io);

    _ = try ts.store.putBytes(io, "aaaa", .other); // 4 B, oldest
    _ = try ts.store.putBytes(io, "bbbb", .other); // 4 B
    const before = try ts.store.index.objectCount();
    try std.testing.expectEqual(@as(u64, 2), before);
    var r = try reserve(&ts.store, io, std.testing.allocator, 20);
    defer rollback(&ts.store, r);
    // 8 B used + 20 B > 24 B total: oldest unrooted evicted to make room.
    try std.testing.expect(try ts.store.index.objectCount() < 2);
}

test "commit clears the in-flight reservation" {
    const io = std.Io.Threaded.global_single_threaded.io();
    var ts = test_support.openTestStore(io, .{ .total_budget = .{ .fixed = 1000 } });
    defer ts.deinit(io);

    const r = try reserve(&ts.store, io, std.testing.allocator, 100);
    try std.testing.expectEqual(@as(u64, 100), ts.store.reservations);
    commit(&ts.store, r);
    try std.testing.expectEqual(@as(u64, 0), ts.store.reservations);
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test`
Expected: FAIL with `unknown reference 'reserve'` (and `reservations` field missing).

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

pub const BudgetBreakdown = struct {
    total: u64 = 0,
    used: u64 = 0,
    hot_used: u64 = 0,
    cold_used: u64 = 0,
    index_state_used: u64 = 0,
    spool_used: u64 = 0,
    reservations: u64 = 0,
};

pub const AdmissionError = error{ StoreFull, OutOfMemory, Unexpected } || Io.Cancelable || index_mod.DbError || gc_mod.GcError;

pub const Reservation = struct { bytes: u64 };

/// Write-time admission control (contract §4): every put reserves first.
/// Order: evict unrooted LRU, then demote demotable hot, then StoreFull.
/// Roots are never touched. In-flight reservations count toward the total.
pub fn reserve(store: *root.Store, io: Io, gpa: std.mem.Allocator, bytes: u64) AdmissionError!Reservation {
    var usage = try budget_mod.classUsage(store, io, gpa);
    var used = usage.hot + usage.cold + usage.index_state + usage.spool + store.reservations;
    if (used + bytes <= store.budget.total) {
        store.reservations += bytes;
        return .{ .bytes = bytes };
    }

    var live = try gc_mod.liveSet(store, io, gpa);
    defer live.deinit();
    const rows = try store.index.lruCandidates(std.heap.page_allocator, null, 1_000_000);
    defer store.index.freeRows(std.heap.page_allocator, rows);

    // Pass 1: evict oldest unrooted (either tier), deleting bytes + rows.
    for (rows) |r| {
        if (used + bytes <= store.budget.total) break;
        if (live.contains(digestOf(r))) continue;
        evictRow(store, io, r);
        used -= @min(used, rowBytes(r));
    }
    // Pass 2: demote demotable hot survivors (frees hot-minus-compressed).
    for (rows) |r| {
        if (used + bytes <= store.budget.total) break;
        if (r.tier != .hot) continue;
        if (live.contains(digestOf(r))) continue;
        const kind = std.meta.stringToEnum(root.Kind, r.kind) orelse .other;
        if (!cold.isDemotable(kind)) continue;
        const hex_d = digest_mod.Digest.fromHex(&r.digest_hex) catch continue;
        const before = rowBytes(r);
        cold.demote(store, io, hex_d) catch continue;
        used -= before - @min(before, coldByteSize(store, io, hex_d));
    }

    if (used + bytes <= store.budget.total) {
        store.reservations += bytes;
        return .{ .bytes = bytes };
    }
    store.last_breakdown = .{
        .total = store.budget.total,
        .used = used,
        .hot_used = usage.hot,
        .cold_used = usage.cold,
        .index_state_used = usage.index_state,
        .spool_used = usage.spool,
        .reservations = store.reservations,
    };
    return error.StoreFull;
}

pub fn commit(store: *root.Store, r: Reservation) void {
    store.reservations -= @min(store.reservations, r.bytes);
}

pub fn rollback(store: *root.Store, r: Reservation) void {
    store.reservations -= @min(store.reservations, r.bytes);
}
```

Helpers in the same file (`digestOf` parses `r.digest_hex` to `[32]u8` for the live-set lookup; `rowBytes` = `size` for hot, `compressed_size orelse size` for cold; `evictRow` deletes the tier file + index row, best-effort; `coldByteSize` stats the cold file). Needs `const digest_mod = @import("digest.zig");` — the live set is keyed by `[32]u8` exactly as in `gc.zig`.

`gc.zig` refactor (no behavior change): extract the Phase-0 root-collection block into `pub fn liveSet(store, io, gpa) GcError!LiveSet` returning the map (caller owns it); `gc` calls it. Make `LiveSet` and the `PresentCtx` callback `pub` for reuse.

`ingest.zig`: at the top of `putBytes`, `const r = admission.reserve(store, io, gpa-stand-in, bytes.len) catch |e| return e;` then `defer`-style commit on success / rollback on error. `putBytes` takes no allocator today (deep interface) — use `std.heap.page_allocator` for the reserve call's transient live-set, matching `Store.open` precedent; document this in a comment. Same for `putFile` with the source length as the hint (stat the source first; stream to tmp; on publish success `commit`, on any error `rollback`). Add `error.StoreFull` to `PutError`. `root.zig`: re-export `pub const BudgetBreakdown = admission.BudgetBreakdown;`, add `reservations` + `last_breakdown` fields (init `0` / `.{}` in `open`).

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
- Produces: `GcPolicy` gains `tag_filter: ?[]const Tag = null` (GC only considers objects carrying ALL pairs) and `honor_tag_budgets: bool = true`. `GcReport` gains `tag_skipped_objects: u64 = 0`. New `index.tagUsage(gpa-unused, key, value)` returns summed `size` for the pair (hot at size, cold at compressed). Eviction order steering: when tag budgets are configured, candidates whose tag is over its soft cap sort before untagged/over-quota LRU (stable: LRU within each group). No new eviction power — same roots/dry-run guarantees.

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
    try ts.store.tag(io, a, "rime.project", "projA");
    try ts.store.tag(io, b, "rime.project", "projB");
    try setMtime(io, &ts.store, a, 1_000);
    try setMtime(io, &ts.store, b, 2_000);

    const filt = [_]root.Tag{.{ .key = "rime.project", .value = "projB" }};
    const report = try ts.store.gc(io, gpa, .{ .tag_filter = &filt });
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
    try ts.store.tag(io, old_heavy, "rime.project", "hungry");
    try ts.store.tag(io, new_light, "rime.project", "lean");
    try ts.store.index.execAll("INSERT OR REPLACE INTO tag_budgets(key,value,max_bytes) VALUES('rime.project','hungry',1);");
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
/// Summed bytes for one tag pair (hot at size, cold at compressed size).
pub fn tagUsage(idx: *Index, key: []const u8, value: []const u8) DbError!u64 {
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(idx.db,
        "SELECT COALESCE(SUM(CASE WHEN o.tier='hot' THEN o.size ELSE COALESCE(o.compressed_size,o.size) END),0)" ++
        " FROM tags t JOIN objects o ON o.digest_hex=t.digest_hex WHERE t.key=?1 AND t.value=?2;",
        -1, &stmt, null) != c.SQLITE_OK)
        return error.DbPrepare;
    defer _ = c.sqlite3_finalize(stmt);
    bindText(stmt, 1, key);
    bindText(stmt, 2, value);
    if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return error.DbStep;
    return @intCast(c.sqlite3_column_int64(stmt, 0));
}
```

In `src/store/gc.zig`: add to `GcPolicy` the fields `tag_filter: ?[]const root.Tag = null` and `honor_tag_budgets: bool = true`; add to `GcReport` `tag_skipped_objects: u64 = 0`. In `gc`, after building the live set, when `policy.tag_filter` is non-null, resolve the allowed digest set via `tags.query(gpa, &store.index, filt)` into a `std.AutoHashMap([32]u8, void)`; every candidate loop that would evict/demote first checks membership and on miss does `report.tag_skipped_objects += 1; continue;`. For steering: before the quota sweep, when `honor_tag_budgets` and the `tag_budgets` table is non-empty, partition the sorted candidates into over-cap-tagged-first vs rest (a tag is over cap when `tagUsage > max_bytes`; an object counts as over-cap if ANY of its tags is over cap — look up the object's tags via `tags.tagsFor` once per object, cached in a map). Keep the LRU order stable inside each partition. The age-trim and emergency phases ignore tag budgets (safety first) but still respect `tag_filter`. `root.zig` needs `pub const Tag = tags_mod.Tag;` already added in Task 5 — reference it.

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
- Consumes: `Store.queryByTag`, `index.tagUsage`, `Store.stats`, `budget.classUsage`.
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
    try ts.store.tag(io, a, "rime.crate", "serde@1.0.200");
    try ts.store.tag(io, b, "rime.crate", "serde@1.0.200");
    try ts.store.tag(io, b, "rime.profile", "release");

    const rows = try byTag(&ts.store, io, gpa);
    defer freeTagStats(gpa, rows);
    try std.testing.expectEqual(@as(usize, 2), rows.len);
    try std.testing.expectEqual(@as(u64, 8), rows[0].bytes); // crate pair first (8 B > 3 B)
    try std.testing.expectEqualStrings("rime.crate", rows[0].key);
}
```

Append to the `parseCommand covers the surface` test in `src/main.zig`:

```zig
    const st = try parseCommand(gpa, &.{ "cache", "stat", "--by-tag", "rime.profile=release" });
    try std.testing.expect(st == .stat);
    try std.testing.expect(st.stat.by_tag);
    try std.testing.expectEqual(@as(usize, 1), st.stat.filters.len);
    const g = try parseCommand(gpa, &.{ "gc", "--tag", "rime.project=projA", "--tag", "a=b" });
    try std.testing.expectEqual(@as(usize, 2), g.gc.tags.len);
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test`
Expected: FAIL — `byTag` undefined; `Command.stat` is a bare tag with no payload (`.stat` takes no `by_tag`).

- [ ] **Step 3: Write minimal implementation**

`src/store/stats.zig` implementation above the tests:

```zig
const index_mod = @import("index.zig");
const c = @cImport(@cInclude("sqlite3.h"));
const Io = std.Io;

pub const StatsError = error{Unexpected, OutOfMemory} || Io.Cancelable || index_mod.DbError;

/// One row per distinct tag pair, bytes DESC. Caller frees via freeTagStats.
pub fn byTag(store: *root.Store, io: Io, gpa: std.mem.Allocator) StatsError![]TagStat {
    _ = io;
    var stmt: ?*c.sqlite3_stmt = null;
    const sql =
        "SELECT t.key,t.value,COALESCE(SUM(CASE WHEN o.tier='hot' THEN o.size ELSE COALESCE(o.compressed_size,o.size) END),0),COUNT(*)" ++
        " FROM tags t JOIN objects o ON o.digest_hex=t.digest_hex GROUP BY t.key,t.value ORDER BY 3 DESC;";
    if (c.sqlite3_prepare_v2(store.index.db, sql, -1, &stmt, null) != c.SQLITE_OK)
        return error.DbPrepare;
    defer _ = c.sqlite3_finalize(stmt);
    var list: std.ArrayList(TagStat) = .empty;
    errdefer freeTagStats(gpa, try list.toOwnedSlice(gpa));
    while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
        const k = try gpa.dupe(u8, std.mem.span(c.sqlite3_column_text(stmt, 0)));
        errdefer gpa.free(k);
        const v = try gpa.dupe(u8, std.mem.span(c.sqlite3_column_text(stmt, 1)));
        try list.append(gpa, .{
            .key = k,
            .value = v,
            .bytes = @intCast(c.sqlite3_column_int64(stmt, 2)),
            .objects = @intCast(c.sqlite3_column_int64(stmt, 3)),
        });
    }
    return try list.toOwnedSlice(gpa);
}

pub fn freeTagStats(gpa: std.mem.Allocator, rows: []TagStat) void {
    for (rows) |r| {
        gpa.free(r.key);
        gpa.free(r.value);
    }
    gpa.free(rows);
}
```

`src/main.zig`: change `Command` to carry payloads additively — `stat: StatOpts` where `pub const StatOpts = struct { by_tag: bool = false, filters: []const []const u8 = &.{} };` (bare `cache stat` still parses; existing `== .stat` comparison in the old test keeps compiling because union equality still works — if it does not, update that one line to `st.stat.by_tag == false`). Extend the `cache` branch: after `stat`, accept optional `--by-tag` followed by zero or more `k=v` tokens (validate each contains `=` and no empty sides, else `error.Usage`). Extend `GcOpts` with `tags: []const TagFilter = &.{}` where `pub const TagFilter = struct { key: []const u8, value: []const u8 };` and parse repeatable `--tag k=v`. `cmdStat` prints the existing five lines plus `budget: total {d} (hot {d} cold {d} index+state {d} spool {d}) reservations {d}` and, when `by_tag`, one `tag {s}={s}: {d} bytes in {d} objects` line per row (or filtered subset). `cmdGc` maps `TagFilter` → `store.Tag` and passes `.tag_filter`. Update the usage string to `rime <cache stat [--by-tag [k=v …]]|cache verify|gc [--tag k=v …]|pin|unpin|store> …`.

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

`ingest.zig`: delete `recordKind` and both call sites (keep `indexUpsert` from Task 6 — kind now lives only in the `objects` row). `action_cache.zig`: `putAction` writes only the `actions` table row (`insertAction` from Task 7's note); `getAction` reads only the table; `sweepInner`'s presence callback in `gc.zig` (`PresentCtx.call`) switches from `objects.exists` to `index.getObject(...) != null` (frees the `kind` dupe immediately). Leave the stale flat files on migrated stores in place (harmless; migration already imported them) — do NOT add a deletion walk (YAGNI; a future `rime gc --compact` can reclaim them). `scan.zig`: delete `loadKinds`/`parseKindLine`/`KindMap` and the journal parameter of `scanTier`; kind comes from the index row, defaulting to `.other` for filesystem-only finds (which are immediately upserted as `.other`).

- [ ] **Step 4: Run test to verify it passes**

Run: `zig build test`
Expected: PASS — full suite green with zero journal/action-file writes (verify by `grep -rn "kinds.jsonl\|actions/" src/store/ --include=*.zig` returning only `migrate.zig` + the new guard test).

- [ ] **Step 5: Request commit**

Do not commit (parent commits).

---

## Self-review

**1. Spec coverage** (§§5–11 plus the v2 contract):
- §5 content model → Tasks 2–4 (schema stores digest/size/compressed_size/tier/kind/timestamps; actions table maps action key → manifest digest, still hints).
- §6 on-disk layout → Tasks 2, 4, 7 (`state/index.db` added under `state/`; `format.json` 1→2; migration imports everything).
- §7 materialization → untouched (no changes planned; signatures preserved).
- §8 concurrency/crash safety → Tasks 2, 4, 7 (WAL+NORMAL justified by rebuildable index; migration takes the exclusive lock or returns `StoreBusyMigrating`; tmp sweep unchanged).
- §9 limits/management → Tasks 8–10 (total budget + class splits + admission + tag-aware GC + soft per-tag caps; roots never evicted; dry-run deletes nothing; hysteresis 90% retained via class targets).
- §10 config/protocol → Task 8 (`total_budget`, `tag_budgets`; env-var plumbing for the new knob is intentionally left to the config-module owner — noted as open question Q2).
- §11 module design → Tasks 4–6, 9 (Store stays the deep module; `index` owns all raw SQLite calls; new seams `budget`/`admission`/`tags`/`migrate`/`stats` each have one responsibility).
- Contract 1 (cargo compat) → no CLI surface removed; exit codes unchanged (Task 11).
- Contract 2 (global caches only) → index lives under the store dir; no project-local state added.
- Contract 3 (vendored SQLite, schema as specified) → Tasks 1–2; dependency decision flagged in Global Constraints.
- Contract 4 (bounded storage, admission, invariant) → Tasks 8–9; GC-as-hygiene in Task 10.
- Migration → Task 7. CLI additions → Task 11.

**2. Placeholder scan:** no TBD/TODO/"appropriate error handling" language; every step names exact files, signatures, SQL, and expected test output. Two deliberate forward-pointers are fully specified inline (Task 3 `freeRows` correction; Task 7 `insertAction` shape) — both give the exact code to write, so they are instructions, not placeholders.

**3. Type consistency:** `Digest`/`ObjectRow`/`Tag`/`TagBudget`/`ResolvedBudget`/`BudgetBreakdown`/`GcPolicy`/`GcReport`/`ClassUsage`/`TagStat` spellings are identical across tasks. `store.tag(io, digest, key, value)` vs `tags.tag(idx, hex, key, value)` differ by receiver on purpose (Store wrapper vs index function) and each task's Interfaces block states which is which. `index.lruCandidates` returns rows whose `kind` must be freed with `freeRows` (Tasks 3, 9) — called out at both use sites. `getObject` returns a single row whose `kind` is freed with `gpa.free` — stated in Task 4. `DbError` is the single error set for all index/tag paths; `AdmissionError` and `StatsError` are defined once (Tasks 9, 11).

**Gaps fixed during review:** added `StoreBusyMigrating` handling (Task 7) so concurrent opens during migration fail loudly instead of racing; kept `limits` populated alongside `budget` (Task 8) so v1 GC paths keep working until Task 10 replaces them; flat-file deletion explicitly scoped OUT of Task 12 (reclaim belongs to a later compaction pass).

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
