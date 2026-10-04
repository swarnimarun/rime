# Cargo Frontend Implementation Plan (Plan C)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:delegate (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build rime's cargo-compatible frontend: parse manifests, discover workspaces, and materialize a cargo-identical `target/` view — as the first of six milestones toward a full cargo drop-in.

**Architecture:** A pure parsing/planning frontend (`src/cargo/`) sits above the `Store` deep module: it reads `Cargo.toml`/`Cargo.lock`, resolves the workspace member graph, computes the unit plan, and materializes only terminal outputs into `target/` via `Store.materialize` (clone-or-copy, never hardlink). All cacheable state lives in the global store; the project dir holds a regenerable view. Later milestones add fetching, resolution, and the rustc driver behind the same seam.

**Tech Stack:** Zig 0.16.0, std only (no new dependencies in milestone 1; the SQLite amalgamation decision in §0.3 is owned by Plan B, not this plan).

**Spec:** `docs/design/storage-v2.md` §§4–5 + 11 + 16 (the Store interface this frontend consumes: `open/close`, `exists/readObject`, `materialize`, `getManifest`, `stats` in M1; plus `putManifest`, `pin/unpin`, `leasePut/leaseRenew/leaseDrop`, `retainProject`, `gc` from M4 on; tag queries via the storage-v2 §16 canonical `Store.lookupObjects(Predicate)` with `pub const Predicate = struct { tags: []Tag, limit: u32 = 10 };` from M2 on; `Store.tagObject` for writes; `Store.lastFull()` for `StoreFull` diagnostics).

## Global Constraints

- Zig **0.16.0** exactly. FS access goes through the `std.Io` interface value passed as `io` to every call; `std.Io.Dir`/`std.Io.File` methods take `io` (copy call sites from the storage-core plan exactly).
- Dependencies: **std only** for milestone 1. No packages in `build.zig.zon`, no C sources. (SQLite amalgamation via `build.zig` `addCSourceFile` is a Plan B decision; this plan's code must not import it — tag queries go through the index API Plan B provides.)
- Tests are inline (`test "…"` blocks). `zig build test` must pass before **every** commit. Never commit with failing tests.
- Cargo-compat invariants after every task: `target/<profile>/` layout matches cargo names; project dirs never hold cache state; store objects read-only (`0o444`), never hardlinked into `target/`; exit codes match cargo (§2.1).
- All VCS operations use **jj**: `jj status`, `jj diff`, `jj commit <paths> -m "…"`. Never run git write commands. One logical change per commit, imperative ≤50-char summaries, no Conventional-Commit prefixes.
- Scratch experiments go in `/tmp`, never in the repo.
- Digest text form is `b3-<64 lowercase hex>` in all user-facing output.

---

## 0. Architecture + roadmap (all milestones)

### 0.1 Module map

```
src/cargo/toml.zig        minimal TOML parser (manifest + lock subset only)
src/cargo/manifest.zig    Package / Dependency / Target / Profile model
src/cargo/lock.zig        Cargo.lock read + write (round-trip stable)
src/cargo/workspace.zig   discovery (walk-up, members globs, excludes)
src/cargo/cli.zig         cargo CLI surface (parse + dispatch + exit codes)
src/cargo/view.zig        target/ layout + materialize + last-build.json + clean
src/cargo/fetch.zig       M2: crates.io + git sources, hash verification
src/cargo/resolve.zig     M3: resolver + lockfile writer
src/cargo/driver.zig      M4: rustc invocation, action keys, fingerprints
src/cargo/script.zig      M5: build scripts + proc macros
src/main.zig              wires cli.zig dispatch to the above
testdata/cargo/           real-world Cargo.toml / Cargo.lock fixtures (M1)
```

`src/cargo/*.zig` form one `cargo` module in `build.zig` (new `b.createModule`, imported by the `rime` exe; exe unit tests cover `cli.zig` inline per the existing `build.zig` pattern). The frontend **consumes** `Store.materialize / getManifest / stats` in M1 (`putManifest`, `pin`/`unpin`, `leasePut`/`leaseRenew`/`leaseDrop`, `retainProject`, `gc` from M4 on) and (from M2 on) Plan B's tag-query API (storage-v2 §16 canonical `Store.lookupObjects(store, io, gpa, pred: Predicate)`, never raw SQL; `Store.tagObject` for tag writes). It never touches `objects/`, `cold/`, `index.sqlite`, or `state/` paths directly.

### 0.2 Design contract adherence (v2 goals)

1. **Cargo drop-in.** Manifest/lock formats parsed per cargo's own grammar subset (§2.1); `target/` naming (not `rime-out/`) — an explicit, deliberate divergence from `storage.md` §4/§6 noted in decision D1 below. Subcommands `build/check/test/run/bench/clean` with cargo's exit codes and `--message-format=json` line protocol.
2. **Global caches only.** The frontend owns zero cache state. `target/` is a view: final binaries (and `.d`/fingerprint stubs cargo tooling expects) materialized by clone-or-copy; deletable at any time. No `target/.rime-cache/`, no fingerprints used as build cache — fingerprints are recomputed from store manifests.
3. **Metadata + tagging index.** Milestone 1 *writes* the tag values the index will need (`crate`, `crate_version`, `profile`, `target` triple when `--target` is passed, `project` id, `action` kind) into `target/.rime-view.json` / `last-build.json` so Plan B can backfill; it does **not** implement the index. M1 metas are explicitly partial: `toolchain` and `features` (v2 §11.3) are driver-known and stay null until M4 fills them — Plan B must not ingest M1 metas as index tags (see `writeViewMeta`'s `"complete": false` marker in Task 6). **Dependency decision (explicit):** the index is SQLite via the vendored amalgamation compiled with `build.zig` `addCSourceFile`, owned by Plan B. Frontend code must go through Plan B's Zig query API so the SQLite dependency never leaks into the CLI path (keeps `rime build --offline` linkable without sqlite if Plan B makes it optional).
4. **Very bounded storage.** One total budget knob (`store.budget`, default `clamp(10% of free space, 5 GiB, 50 GiB)`) split into hard class allocations per storage-v2 §9.1 (hot 70 / cold 20 / index+state 5 / transient spool 5). The frontend's only bounded-storage duty: spool all build-script I/O and materialize staging under the transient-spool reservation, and surface `error.StoreFull` with the `Store.lastFull()` budget breakdown verbatim instead of retrying. The frontend never calls `reserve` explicitly: `Store.putBytes`/`putFile`/`putManifest` reserve internally and fail with `StoreFull` (storage-v2 §16, Plan B Task 9); the frontend only handles that error. Invariant `total store bytes <= budget` (in-flight reservations counted) is enforced by the store; the frontend must never bypass admission by writing directly into the store dir. GC stays hygiene. Roots (pins/leases/retains) are never auto-evicted; per-tag budgets are optional soft caps the frontend may pass as hints only.

### 0.3 Key compatibility decisions

- **D1 — `target/`, not `rime-out/`.** `storage.md` §4 names the view `rime-out/`; the v2 contract requires cargo compat, so the view is `target/<profile>/` with cargo's file names (`debug/` vs `release/`, `deps/lib<name>-<meta>.rlib`, `.fingerprint/`). Divergence is layout-only; the "view, not a store" semantics are unchanged.
- **D2 — TOML subset, reject loudly.** Hand-written parser for exactly the keys rime understands (see Task 1 table); unknown `[profile.*]` keys error with `file:line: unknown key`, never silently ignored (silent ignore is how builds become unreproducible).
- **D3 — Lockfile is authoritative when present.** If `Cargo.lock` exists and `--locked`/`--frozen` semantics apply, the frontend never re-resolves (M1: reads; M3: writes). Checksum field is opaque passthrough (`sha256:` hex) verified at fetch time (M2).
- **D4 — Exit codes match cargo:** `0` success; `101` build/test failure (compilation or test failure, workspace valid); `1` usage/config error (bad manifest, unknown flag, undiscoverable workspace). `--message-format=json` emits one JSON object per line on stdout; human rendering goes to stderr so stdout stays pipe-clean.
- **D5 — No network in milestone 1.** Path dependencies only for graph edges; registry/git dependency *declarations* parse (so fixtures with real manifests work) but any command needing the source errors `need source: run after M2 (fetch)` with exit code `1`. `--offline`/`--frozen` flags parse in M1 and are enforced from M2 on.

### 0.4 Milestone roadmap

- **M1 — CLI + manifest/lock + workspace + view (THIS PLAN, fully detailed below).** Deliverable: `rime build/check/test/run/bench/clean` parse a real workspace, print the unit plan (`--dry-run` / `--message-format=json`), lay out `target/<profile>/`, materialize store-listed terminal outputs, `clean` removes only the view. Testable with real `Cargo.toml`/`Cargo.lock` fixtures. No network, no rustc.
- **M2 — Source fetching (coarse).** `fetch.zig`: sparse-registry client (`+https://github.com/rust-lang/crates.io-index` protocol subset), `.crate` download, `sha256` verification against lock checksum, git deps (pinned rev, shallow clone into store `source` objects), all tagged per storage-v2 §11.3 (`crate` + `crate_version`, `action`, plus `user.source=registry|git` for provenance; never `crate=name@version` single-tag form). Tests: local file-registry stub + hash-mismatch rejection.
- **M3 — Resolver + lock write (coarse).** `resolve.zig`: semver requirement matching, feature unification (v1 semantics), workspace inheritance, `Cargo.lock` writer preserving cargo's ordering/checksum lines; `--locked/--frozen/--offline` enforcement. Tests: diamond-dep, feature-unify, and lock-round-trip fixtures.
- **M4 — rustc driver + action keys (coarse).** `driver.zig`: fingerprint → action key (toolchain id + target triple + normalized args + input digests + relevant env, per sccache reference in spec §13), `--extern` pointing at store paths, dep-info capture, manifest `putManifest`, `leasePut` per build (`leaseRenew` on activity, `leaseDrop` at end), incremental sessions as global `kind=incremental` tagged objects under the 4 GiB global `kind:incremental` soft tag budget (storage-v2 §§12.3/13.2; never a project-local class). Tests: rebuild-after-touch, flag-change rebuild, no-op rebuild is a cache hit.
- **M5 — Build scripts + proc macros (coarse).** `script.zig`: script compile-then-run sandbox (env-keyed action keys, spooled I/O under transient budget), `cargo::` directive parsing (`rerun-if-changed`, `rustc-link-lib/search`), proc-macro dylib loading from store paths (never demoted `dylib` kind). Tests: rerun-if-changed matrix, link-search propagation.
- **M6 — Full CLI parity (coarse).** Streaming `--message-format=json` (`compiler-artifact`, `build-finished`, `test` events), `run` arg forwarding, `bench` harness flags, `clean -p/--release`, `rime gc --explain` wiring to store stats, man/help text parity for the six commands. Tests: golden JSON streams, exit-code matrix.

---

## Milestone 1 detail — file structure

```
build.zig                        add cargo module + import into exe (Task 5)
src/cargo/toml.zig               TomlValue, TomlParser, parseDocument (Task 1)
src/cargo/manifest.zig           Package, Dependency, TargetDesc, Manifest (Task 2)
src/cargo/lock.zig               LockPackage, Lockfile, parse + serialize (Task 3)
src/cargo/workspace.zig          Workspace, discover(), memberGraph() (Task 4)
src/cargo/cli.zig                Command, parseArgs(), dispatch(), exit codes (Task 5)
src/cargo/view.zig               layoutPaths(), materializeOutputs(), clean() (Task 6)
src/main.zig                     wire dispatch (Task 5)
testdata/cargo/minimal/          single-package fixture (Tasks 2-3, 7)
testdata/cargo/workspace/        3-member workspace + lockfile (Tasks 4, 7)
testdata/cargo/golden/plan.json  expected unit plan for the fixture (Task 7)
```

Each task's **Interfaces** block is the contract between tasks: exact names and types the neighbor tasks use. Implement exactly these; do not rename.

---

### Task 1: TOML subset parser

**Files:**
- Create: `src/cargo/toml.zig`
- Test: inline `test "…"` blocks in `src/cargo/toml.zig`

**Interfaces:**
- Consumes: nothing (std only).
- Produces (used by Tasks 2–3):
```zig
pub const Span = struct { line: u32, col: u32 };
pub const TomlError = error{ ParseError, UnsupportedType, OutOfMemory };
pub const TomlValue = union(enum) {
    string: []const u8,
    boolean: bool,
    integer: i64,
    array: []TomlValue,
    table: TomlTable,
};
pub const TomlTable = struct {
    entries: std.StringHashMap(TomlEntry),
    // Pointer access: TomlValue holds a TomlTable holding a StringHashMap — returning by value would copy the map header.
    // get returns *const TomlValue; field access auto-derefs, so `t.get("k").?.table` still compiles.
    pub fn get(self: *const TomlTable, key: []const u8) ?*const TomlValue { ... }
    pub fn require(self: *const TomlTable, key: []const u8) TomlError!*const TomlValue { ... }
};
pub const TomlEntry = struct { value: TomlValue, span: Span };
pub const TomlDoc = struct {
    arena: std.heap.ArenaAllocator,
    root: TomlTable,
    pub fn deinit(self: *TomlDoc) void { ... }
};
pub fn parseDocument(gpa: std.mem.Allocator, text: []const u8) TomlError!TomlDoc;
```

Supported subset (everything else → `ParseError` with line/col): `[table]`, `[[array-table]]`, `key = "string" | 'literal' | true/false | integer | [array-of-above] | { inline-table }`, `#` comments, dotted keys (`a.b = 1`). Multiline `"""` strings, floats, datetimes, hex/oct/bin integers are **rejected** with `ParseError` (decision D2).

- [ ] **Step 1: Write the failing test**

```zig
test "toml parses package table with deps" {
    var doc = try parseDocument(std.testing.allocator,
        \\[package]
        \\name = "foo"
        \\version = "0.1.0"
        \\edition = "2021"
        \\
        \\[dependencies]
        \\serde = "1.0"
        \\
    );
    defer doc.deinit();
    const pkg = &doc.root.get("package").?.table; // *const TomlTable: no map-header copy
    const name = pkg.get("name").?.string;
    try std.testing.expectEqualStrings("foo", name);
    const deps = &doc.root.get("dependencies").?.table; // *const TomlTable: no map-header copy
    try std.testing.expectEqualStrings("1.0", deps.get("serde").?.string);
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test 2>&1 | tail -20`
Expected: FAIL — `src/cargo/toml.zig` does not exist / `parseDocument` not defined. (If the `cargo` module is not yet in `build.zig`, add it now as part of this step with the single canonical root — `const cargo_mod = b.createModule(.{ .root_source_file = b.path("src/cargo/root.zig"), ... })` wired only to the test step, where `src/cargo/root.zig` (created in this step) contains one line, `pub const toml = @import("toml.zig");`, and each later task appends its own re-export line. There is exactly one cargo module root (`src/cargo/root.zig`), never `toml.zig` as root; the full exe import wiring lands in Task 5.)

- [ ] **Step 3: Write minimal implementation**

```zig
const std = @import("std");

pub const Span = struct { line: u32, col: u32 };
pub const TomlError = error{ ParseError, UnsupportedType, OutOfMemory };
pub const TomlValue = union(enum) {
    string: []const u8,
    boolean: bool,
    integer: i64,
    array: []TomlValue,
    table: TomlTable,
};
pub const TomlTable = struct {
    entries: std.StringHashMap(TomlEntry),
    pub fn get(self: *const TomlTable, key: []const u8) ?*const TomlValue {
        const e = self.entries.getPtr(key) orelse return null;
        return &e.value;
    }
    pub fn require(self: *const TomlTable, key: []const u8) TomlError!*const TomlValue {
        const e = self.entries.getPtr(key) orelse return TomlError.ParseError;
        return &e.value;
    }
};
pub const TomlEntry = struct { value: TomlValue, span: Span };
pub const TomlDoc = struct {
    arena: std.heap.ArenaAllocator,
    root: TomlTable,
    pub fn deinit(self: *TomlDoc) void {
        self.arena.deinit();
    }
};

const Parser = struct {
    gpa: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    text: []const u8,
    pos: usize,
    line: u32,
    col: u32,
    // ... cursor helpers, parseValue, parseTableHeader, parseDocument inner loop ...
};

pub fn parseDocument(gpa: std.mem.Allocator, text: []const u8) TomlError!TomlDoc {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    var p = Parser{ .gpa = gpa, .arena = arena, .text = text, .pos = 0, .line = 1, .col = 1 };
    const root = try p.parseRoot();
    return .{ .arena = arena, .root = root };
}
```

The full `Parser` body: line scanner splitting on `\n` (tracking `line`/`col` for every `TomlEntry.span`), `#` comment strip (not inside quotes), `[table]` / `[[array-table]]` header handling with dotted-path descent creating intermediate tables, value parsing for the five supported kinds, and `return TomlError.ParseError` on floats (`1.0` with dot followed by digit inside a value position is rejected — note `"0.1.0"` is a *string*, fine), datetimes, `"""`, `0x/0o/0b`. All allocations (strings, arrays, table maps) come from `arena.allocator()`; the returned `TomlDoc` owns the arena.

- [ ] **Step 4: Add edge-case tests and make them pass**

```zig
test "toml rejects floats and multiline strings" {
    try std.testing.expectError(TomlError.ParseError, parseDocument(std.testing.allocator, "k = 1.5\n"));
    try std.testing.expectError(TomlError.ParseError, parseDocument(std.testing.allocator, "k = \"\"\"x\"\"\"\n"));
}

test "toml array tables collect members" {
    var doc = try parseDocument(std.testing.allocator, "[[bin]]\nname = \"a\"\n[[bin]]\nname = \"b\"\n");
    defer doc.deinit();
    const bins = doc.root.get("bin").?.array;
    try std.testing.expectEqual(@as(usize, 2), bins.len);
    try std.testing.expectEqualStrings("b", bins[1].table.get("name").?.string);
}
```

Run: `zig build test 2>&1 | tail -5`
Expected: PASS (all `toml` tests green; whole suite green).

- [ ] **Step 5: Commit**

```bash
jj status
jj commit src/cargo/toml.zig -m "Add TOML subset parser for manifests"
```

---

### Task 2: Manifest model (Cargo.toml)

**Files:**
- Create: `src/cargo/manifest.zig`
- Test: inline tests in `src/cargo/manifest.zig` + fixture `testdata/cargo/minimal/Cargo.toml` (created in this task)

**Interfaces:**
- Consumes: `toml.parseDocument`, `toml.TomlTable`, `toml.TomlValue` (Task 1).
- Produces (used by Tasks 4, 7):
```zig
pub const ManifestError = error{ InvalidManifest, UnsupportedKey, OutOfMemory, ParseError, UnsupportedType };
pub const DependencyKind = union(enum) {
    version_req: []const u8,          // "1.0" (owns no memory; borrows doc arena)
    path: []const u8,                // { path = "../x" }
    git: GitSpec,                    // { git = "url", rev/branch/tag = … }
    workspace_inherit: void,         // { workspace = true }
};
pub const GitSpec = struct { url: []const u8, ref: ?[]const u8 };
pub const TargetDesc = struct { name: []const u8, path: ?[]const u8, kind: TargetKind };
pub const TargetKind = enum { lib, bin, example, test, bench };
pub const Package = struct {
    name: []const u8,
    version: []const u8,
    edition: []const u8,              // default "2021" when absent
    build_script: ?[]const u8,       // None, "build.rs" default when file exists (checked by workspace task)
};
pub const Manifest = struct {
    arena: std.heap.ArenaAllocator,                  // owns ALL borrowed strings/slices below; deinit frees arena + deps map header
    pkg: ?Package,                                  // null for virtual workspace roots
    deps: std.StringHashMap(DependencyKind),
    targets: []TargetDesc,                           // explicit [lib]/[[bin]] or defaults
    workspace_members: ?[]const []const u8,         // [workspace] members globs, if present
    workspace_exclude: []const []const u8,
    pub fn deinit(self: *Manifest) void { self.deps.deinit(); self.arena.deinit(); }
};
pub fn parseManifest(gpa: std.mem.Allocator, text: []const u8) ManifestError!Manifest;
```

Unknown keys inside `[package]` other than the allow-list (`name, version, edition, build, build-script, rust-version, description, license`) → `UnsupportedKey` naming the key. `[dependencies] X = "req"` and `{ version/path/git/workspace = … }` forms supported; `optional = true` recorded but features resolution deferred to M3 (parse, don't resolve).

- [ ] **Step 1: Write the fixture and the failing test**

`testdata/cargo/minimal/Cargo.toml`:
```toml
[package]
name = "rime-minimal"
version = "0.1.0"
edition = "2021"

[dependencies]
serde = "1.0"

[dependencies.rime-dep]
path = "../rime-dep"
```

```zig
test "manifest parses minimal package" {
    const text = @embedFile("../../testdata/cargo/minimal/Cargo.toml");
    var m = try parseManifest(std.testing.allocator, text);
    defer m.deinit();
    try std.testing.expectEqualStrings("rime-minimal", m.pkg.?.name);
    try std.testing.expectEqualStrings("1.0", m.deps.get("serde").?.version_req);
    try std.testing.expectEqualStrings("../rime-dep", m.deps.get("rime-dep").?.path);
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test -- --test-filter "manifest parses minimal" 2>&1 | tail -10` (if `--test-filter` is unsupported in this tree, run full `zig build test` and confirm the new test fails).
Expected: FAIL — `manifest.zig` / `parseManifest` not defined.

- [ ] **Step 3: Write minimal implementation**

```zig
const std = @import("std");
const toml = @import("toml.zig"); // wired via the cargo module; see build.zig note in Task 5

// ... DependencyKind / GitSpec / TargetDesc / TargetKind / Package / Manifest decls above ...

pub fn parseManifest(gpa: std.mem.Allocator, text: []const u8) ManifestError!Manifest {
    var doc = toml.parseDocument(gpa, text) catch |e| return @as(ManifestError, switch (e) {
        toml.TomlError.ParseError => ManifestError.ParseError,
        toml.TomlError.UnsupportedType => ManifestError.UnsupportedType,
        toml.TomlError.OutOfMemory => ManifestError.OutOfMemory,
    });
    // NOTE: doc.arena outlives the Manifest — Manifest borrows strings from it.
    // Ownership transfer (exact): move doc.arena into the returned Manifest; Manifest.deinit frees it.
    var m = Manifest{ .arena = doc.arena, .pkg = null, .deps = std.StringHashMap(DependencyKind).init(gpa), .targets = &.{}, .workspace_members = null, .workspace_exclude = &.{} };
    errdefer { m.deps.deinit(); m.arena.deinit(); }
    if (doc.root.get("package")) |pv| {
        const pt = &pv.table; // *const TomlTable: no map-header copy (pv is *const TomlValue)
        m.pkg = Package{
            .name = try requiredString(pt, "name"),
            .version = try requiredString(pt, "version"),
            .edition = optionalString(pt, "edition") orelse "2021",
            .build_script = optionalString(pt, "build").orelse(optionalString(pt, "build-script")),
        };
        try checkPackageKeys(pt);
    }
    if (doc.root.get("dependencies")) |dv| {
        var it = dv.table.entries.iterator();
        while (it.next()) |kv| try m.deps.put(kv.key_ptr.*, try parseDep(kv.value_ptr.value));
    }
    // [lib] / [[bin]] explicit targets; else default single lib-or-bin (resolved by workspace task via file probe)
    // [workspace] members/exclude string arrays when present
    // ... (store doc.arena into Manifest for deinit; see deinit impl)
    return m;
}
```

Include helpers `requiredString`, `optionalString`, `checkPackageKeys` (allow-list loop returning `UnsupportedKey`), `parseDep` (string → version_req; table with `path`/`git`/`workspace` keys). All table-taking helpers take `*const TomlTable` (never a by-value table — Task 1 pointer rule). Keep the real code in the file; the sketch above is the shape, not a stub.

- [ ] **Step 4: Run test to verify it passes**

```zig
test "manifest rejects unknown package keys loudly" {
    try std.testing.expectError(ManifestError.UnsupportedKey, parseManifest(std.testing.allocator, "[package]\nname = \"a\"\nversion = \"0.1.0\"\nflux-capacitor = true\n"));
}

test "manifest parses git and workspace-inherit deps" {
    const text = "[package]\nname = \"a\"\nversion = \"0.1.0\"\n[dependencies]\ng = { git = \"https://example.com/r.git\", rev = \"abc123\" }\nw = { workspace = true }\n";
    var m = try parseManifest(std.testing.allocator, text);
    defer m.deinit();
    try std.testing.expectEqualStrings("https://example.com/r.git", m.deps.get("g").?.git.url);
    try std.testing.expect(m.deps.get("w").? == .workspace_inherit);
}
```

Run: `zig build test 2>&1 | tail -5`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
jj status
jj commit src/cargo/manifest.zig testdata/cargo/minimal/Cargo.toml -m "Add Cargo.toml manifest model"
```

---

### Task 3: Lockfile read + write (Cargo.lock)

**Files:**
- Create: `src/cargo/lock.zig`
- Test: inline tests + fixture `testdata/cargo/minimal/Cargo.lock` (real cargo format, hand-written to match cargo output ordering)

**Interfaces:**
- Consumes: `toml.parseDocument` (Task 1) for reading; writer is plain string building (no TOML emitter needed).
- Produces (used by Tasks 4, 7, and M3's writer):
```zig
pub const LockError = error{ InvalidLock, ParseError, UnsupportedType, OutOfMemory };
pub const LockPackage = struct {
    name: []const u8,
    version: []const u8,
    source: ?[]const u8,     // "registry+https://…" | "git+https://…#rev" | null for path deps
    checksum: ?[]const u8,   // sha256 hex; opaque passthrough (verified in M2)
    dependencies: []const []const u8,  // edge list as written ("name version (source)" short form supported)
};
pub const Lockfile = struct {
    arena: std.heap.ArenaAllocator, // owns ALL borrowed strings/slices below; deinit frees it
    version: u32,             // `version = 4` header; default 3 when absent
    packages: []LockPackage,
    pub fn deinit(self: *Lockfile) void { self.arena.deinit(); }
    pub fn find(self: *const Lockfile, name: []const u8) ?LockPackage { ... }
    pub fn serialize(self: *const Lockfile, gpa: std.mem.Allocator) LockError![]u8 { ... }
};
pub fn parseLock(gpa: std.mem.Allocator, text: []const u8) LockError!Lockfile;
```

Round-trip stability requirement: `serialize(parseLock(x))` must be byte-identical to cargo's own output for the fixtures (header `# This file is automatically @generated by Cargo.` + `version = 4`, packages sorted as read, `[[package]]` blocks with `name/version/source/checksum/dependencies` in cargo's field order). M1 only reads + re-serializes; M3 adds resolution-driven writes.

- [ ] **Step 1: Write the fixture and the failing test**

`testdata/cargo/minimal/Cargo.lock` (cargo v4 format):
```toml
# This file is automatically @generated by Cargo.
# It is not intended for manual editing.
version = 4

[[package]]
name = "rime-minimal"
version = "0.1.0"
dependencies = [
 "serde",
]

[[package]]
name = "serde"
version = "1.0.200"
source = "registry+https://github.com/rust-lang/crates.io-index"
checksum = "deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
```

```zig
test "lock parses v4 fixture and round-trips" {
    const text = @embedFile("../../testdata/cargo/minimal/Cargo.lock");
    var lf = try parseLock(std.testing.allocator, text);
    defer lf.deinit();
    try std.testing.expectEqual(@as(u32, 4), lf.version);
    const serde = lf.find("serde").?;
    try std.testing.expectEqualStrings("1.0.200", serde.version);
    try std.testing.expect(serde.checksum != null);
    const out = try lf.serialize(std.testing.allocator);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings(text, out);
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test 2>&1 | tail -10`
Expected: FAIL — `lock.zig` / `parseLock` not defined.

- [ ] **Step 3: Write minimal implementation**

Parser: `parseDocument`, read root `version` integer (default 3), iterate `package` array-table; each entry requires `name`+`version`, optional `source`/`checksum`, optional `dependencies` string array (each entry kept verbatim, including cargo's `"name version (source)"` disambiguation form). Serializer: fixed template emitting the header comment, `version = N`, then per-package blocks in slice order with fields in cargo order (`name`, `version`, `source`?, `checksum`?, `dependencies`? multi-line array with trailing commas exactly as cargo writes). All strings borrowed from the doc arena owned by `Lockfile`.

- [ ] **Step 4: Run test to verify it passes**

Add the missing-field test:
```zig
test "lock rejects package without version" {
    try std.testing.expectError(LockError.InvalidLock, parseLock(std.testing.allocator, "[[package]]\nname = \"x\"\n"));
}
```

Run: `zig build test 2>&1 | tail -5`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
jj status
jj commit src/cargo/lock.zig testdata/cargo/minimal/Cargo.lock -m "Add Cargo.lock read and write"
```

---

### Task 4: Workspace discovery

**Files:**
- Create: `src/cargo/workspace.zig`
- Test: inline tests + fixtures `testdata/cargo/workspace/{Cargo.toml,Cargo.lock,crates/{a,b,c}/Cargo.toml,crates/{a,b,c}/src/lib.rs}` (3-member workspace: `a` depends on `b` by path, `c` standalone, root virtual manifest)

**Interfaces:**
- Consumes: `manifest.parseManifest` (Task 2), `lock.parseLock` (Task 3).
- Produces (used by Tasks 5–7):
```zig
pub const DiscoverError = error{ NoWorkspace, Cycle, InvalidManifest, UnsupportedKey, ParseError, UnsupportedType, InvalidLock, OutOfMemory };
pub const Member = struct {
    name: []const u8,
    version: []const u8,
    dir: []const u8,          // absolute dir path (owned by workspace arena)
    manifest: Manifest,      // Task-2 model (borrows workspace arena via dup)
    is_root: bool,
};
pub const Workspace = struct {
    arena: std.heap.ArenaAllocator,
    root_dir: []const u8,
    members: []Member,
    lock: ?Lockfile,          // parsed if Cargo.lock present next to root (null = resolve in M3)
    pub fn deinit(self: *Workspace) void { ... }
    pub fn findMember(self: *const Workspace, name: []const u8) ?*const Member { ... }
};
pub fn discover(gpa: std.mem.Allocator, io: std.Io, start_dir: []const u8, manifest_path: ?[]const u8) DiscoverError!Workspace;
pub fn memberEdges(gpa: std.mem.Allocator, ws: *const Workspace) DiscoverError![]const []const usize; // adjacency: member i -> path-dep member indices (for Task 7 plan); caller-owned: free each inner slice, then the outer slice, with gpa (planUnits does this right after its Kahn pass)
```

Behavior: if `manifest_path` given, start there; else walk up from `start_dir` to the first dir containing `Cargo.toml` (stop at filesystem root → `NoWorkspace`). Parse root manifest; if it has `[workspace]` with `members` globs (support exact paths + single-`*` globs like `crates/*`, plus `exclude`), expand against the FS (list dirs via `std.Io.Dir`, match globs, skip excluded, read each member manifest). Path-dependency edges resolved relative to the declaring member dir; an edge naming a non-member path dep is kept as an external stub (not an error — registry deps resolve in M3). Depends-on cycles between members → `Cycle`. Virtual root (`[workspace]` without `[package]`) allowed; non-virtual root is itself a member (`is_root = true`).

- [ ] **Step 1: Write fixtures and the failing test**

Root `testdata/cargo/workspace/Cargo.toml`:
```toml
[workspace]
members = ["crates/*"]
exclude = ["crates/c"]
resolver = "2"
```
plus `crates/a/Cargo.toml` (depends `b = { path = "../b" }`), `crates/b/Cargo.toml`, `crates/c/Cargo.toml`, each with `src/lib.rs` containing `pub fn x() {}`.

```zig
test "workspace discovers glob members minus excludes" {
    var ws = try discover(std.testing.allocator, std.Io.Threaded.global_single_threaded.io(), "testdata/cargo/workspace/crates/a", null);
    defer ws.deinit();
    try std.testing.expectEqual(@as(usize, 2), ws.members.len);
    try std.testing.expect(ws.findMember("a") != null);
    try std.testing.expect(ws.findMember("b") != null);
    try std.testing.expect(ws.findMember("c") == null);
}
```

(Note: tests run with cwd = repo root; use relative fixture paths. The `std.Io` value is `std.Io.Threaded.global_single_threaded.io()` — the exact accessor the storage-core plan uses.)

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test 2>&1 | tail -10`
Expected: FAIL — `workspace.zig` / `discover` not defined.

- [ ] **Step 3: Write minimal implementation**

`discover`: resolve start (`manifest_path` dir or walk-up loop checking `Cargo.toml` existence via `dir.statFile`), read file bytes (`readFileAlloc` capped at 1 MiB — manifests larger than that → `InvalidManifest`), `parseManifest`, glob expansion (`readDir` entries, `*` matches any single path segment, no `**` in M1 → `InvalidManifest` if used), per-member read+parse, edge resolution + cycle check (DFS over member index map). All owned strings/structs duplicated into `ws.arena`. Lock: if `<root>/Cargo.lock` exists, read + `parseLock`, store in workspace (borrowing the same arena via re-parse into arena allocator — simplest: parse with arena allocator directly).

- [ ] **Step 4: Run tests to verify behavior**

```zig
test "workspace honors explicit manifest path" { ... manifest_path = "testdata/cargo/workspace/Cargo.toml" ... expect 2 members ... }
test "workspace rejects member cycles" {
    // synthetic: member a path-depends on b, b path-depends on a (fixture pair under testdata/cargo/cycle/)
    try std.testing.expectError(DiscoverError.Cycle, discover(std.testing.allocator, std.Io.Threaded.global_single_threaded.io(), "testdata/cargo/cycle", null));
}
test "workspace missing manifest walks to root and fails" {
    try std.testing.expectError(DiscoverError.NoWorkspace, discover(std.testing.allocator, std.Io.Threaded.global_single_threaded.io(), "/tmp", null));
}
```

Create the `testdata/cargo/cycle/{Cargo.toml,a/Cargo.toml,b/Cargo.toml}` fixture pair in this step. Run: `zig build test 2>&1 | tail -5`. Expected: PASS.

- [ ] **Step 5: Commit**

```bash
jj status
jj commit src/cargo/workspace.zig testdata/cargo/workspace testdata/cargo/cycle -m "Add workspace discovery"
```

---

### Task 5: CLI surface (commands, flags, exit codes, JSON envelope)

**Files:**
- Create: `src/cargo/cli.zig`
- Modify: `build.zig` (add `cargo` module; import into exe module), `src/main.zig` (dispatch to `cli.run`)
- Test: inline tests in `src/cargo/cli.zig` (pure `parseArgs` table tests — no FS)

**Interfaces:**
- Consumes: `workspace.discover` + `workspace.Workspace` (Task 4), `view.layoutPaths/materializeOutputs/clean` + `view.planUnits` (Task 6 — signatures below; Task 5 codes against them, Task 6 implements). IMPLEMENTATION ORDER: Tasks 1–4, then Task 6, then this task's `run()`/`main.zig` wiring (which calls Task 6's `planUnits`/`materializeOutputs`/`clean`), then Task 7. Only `parseArgs`/envelope tests land here independently of that order.
- Produces (used by `src/main.zig`, Task 7 golden tests):
```zig
pub const Command = enum { build, check, test_cmd, run, bench, clean };
pub const MessageFormat = enum { human, json };
pub const Options = struct {
    cmd: Command,
    manifest_path: ?[]const u8,
    profile: []const u8,        // "dev" default; "release" with --release; custom via --profile
    target_triple: ?[]const u8, // --target
    features: []const []const u8,
    message_format: MessageFormat,
    offline: bool, frozen: bool, locked: bool,
    dry_run: bool,              // M1-only planning flag (prints unit plan, writes view skeleton)
    extra_args: []const []const u8,  // trailing args after -- (for run/test/bench)
};
pub const CliError = error{ Usage, OutOfMemory };
pub fn parseArgs(gpa: std.mem.Allocator, argv: []const []const u8) CliError!Options;
pub const ExitCode = struct { pub const ok: u8 = 0; pub const usage: u8 = 1; pub const build_failed: u8 = 101; };
pub const JsonEnvelope = struct {
    reason: []const u8,          // "unit-plan" | "build-finished" | "compiler-message"
    package: []const u8,
    target: []const u8,
    profile: []const u8,
    success: bool,
    pub fn writeLine(self: *const JsonEnvelope, w: *std.Io.Writer) !void { ... }
};
pub fn run(gpa: std.mem.Allocator, io: std.Io, opts: Options, stdout: *std.Io.Writer, stderr: *std.Io.Writer) u8;
```

Flag table (M1): `--manifest-path <p>`, `--release` (= `--profile release`), `--profile <name>`, `--target <triple>`, `--features <csv>` (repeatable), `--message-format=json|human`, `--offline/--frozen/--locked` (accepted; `frozen/locked` enforce lockfile presence in M3 — in M1 they only require the lock to exist when the workspace has registry deps, else `Usage` + stderr hint), `--dry-run`, `-p/--package <name>` (limit plan to member + its path-deps), `-- <args…>` passthrough. Unknown flags → `Usage` with `error: unknown flag '--foo'` on stderr, exit `1`. `run` outside a workspace → exit `1`. Commands needing sources not yet fetched (any non-path dep when actually building, i.e. not `--dry-run`) → stderr `need source: <name> requires M2 fetch; re-run with --dry-run to inspect the plan`, exit `1` (decision D5).

- [ ] **Step 1: Write the failing parse tests**

```zig
test "cli parses build with release and json" {
    const argv = [_][]const u8{ "rime", "build", "--release", "--message-format=json" };
    var opts = try parseArgs(std.testing.allocator, &argv);
    defer std.testing.allocator.free(opts.features);
    try std.testing.expect(opts.cmd == .build);
    try std.testing.expectEqualStrings("release", opts.profile);
    try std.testing.expect(opts.message_format == .json);
}

test "cli rejects unknown flags with usage error" {
    const argv = [_][]const u8{ "rime", "build", "--warp-drive" };
    try std.testing.expectError(CliError.Usage, parseArgs(std.testing.allocator, &argv));
}

test "cli splits run passthrough args" {
    const argv = [_][]const u8{ "rime", "run", "-p", "a", "--", "--hello", "world" };
    var opts = try parseArgs(std.testing.allocator, &argv);
    defer { std.testing.allocator.free(opts.features); std.testing.allocator.free(opts.extra_args); }
    try std.testing.expect(opts.cmd == .run);
    try std.testing.expectEqual(@as(usize, 2), opts.extra_args.len);
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `zig build test 2>&1 | tail -10`
Expected: FAIL — `cli.zig` / `parseArgs` not defined.

- [ ] **Step 3: Write minimal implementation (parseArgs + envelope)**

Hand-rolled argv loop over the flag table (no std arg parser — exact cargo spelling including `--flag=value` and `--flag value` forms). `parseArgs` allocates `features`/`extra_args` with `gpa`; document the free contract in the doc comment (`free opts.features and opts.extra_args with the same allocator`). `JsonEnvelope.writeLine` writes single-line JSON via `std.json.Stringify` with no spaces (field order fixed: reason, package, target, profile, success) followed by `\n`.

- [ ] **Step 4: Wire dispatch + build.zig, verify exit codes**

`build.zig` addition (exact; `src/cargo/root.zig` already exists since Task 1 — this step only adds the exe import):
```zig
const cargo_mod = b.createModule(.{
    .root_source_file = b.path("src/cargo/root.zig"), // by now re-exports toml/manifest/lock/workspace/cli/view (view line landed with Task 6)
    .target = target,
    .optimize = optimize,
});
exe_mod.addImport("cargo", cargo_mod); // same addImport shape build.zig already uses for its current imports; main.zig then uses @import("cargo").cli
```
`src/cargo/root.zig` already exists since Task 1; in this step extend it to its final five-module form (`pub const toml = @import("toml.zig");` etc. plus `pub const cli` and `pub const view` lines) — do not create a second module root.

`run()`: discover workspace (cwd when `manifest_path == null`), on `DiscoverError.NoWorkspace` → stderr `error: could not find Cargo.toml…`, return `1`; compute member plan (Task 6's `planUnits` — already implemented per the order note in Interfaces, called here with the exact `createModule` wiring above); `--dry-run` prints one `JsonEnvelope{reason="unit-plan"}` line per unit (json) or `Compiling <name> v<ver> (<target>)` lines (human); non-dry-run with registry deps → `need source` error, exit `1`; pure-path workspaces proceed to `view.materializeOutputs` skeleton + `build-finished` envelope, exit `0`; `clean` → `view.clean`, exit `0`. `src/main.zig`: parse `std.process.argsAlloc`, call `cli.run`, `process.exit(code)`.

Tests:
```zig
test "run clean on empty dir reports no workspace" {
    // run() with manifest_path pointing at an empty tmp dir returns 1 and writes "could not find" to stderr
}
```

Run: `zig build test 2>&1 | tail -5` then `zig build 2>&1 | tail -3` — both must pass/produce `zig-out/bin/rime`.
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
jj status
jj commit build.zig src/cargo/root.zig src/cargo/cli.zig src/main.zig -m "Add cargo CLI surface"
```

---

### Task 6: target/ view layout (materialize + clean)

**Files:**
- Create: `src/cargo/view.zig`
- Test: inline tests (use a real `Store` from the storage core for the materialize test — no mocks)

**Interfaces:**
- Consumes: `Store.materialize` (`src/store/root.zig:126`: `pub fn materialize(store: *Store, io: Io, d: Digest, dest_path: []const u8, mode: u32) MaterializeError!MaterializeMethod`), `Store.getManifest`, `workspace.Workspace` (Task 4).
- Imports (top of `view.zig` — `Store`/`Digest`/`TargetKind` below resolve through these, no missing imports): `const store_mod = @import("../store/root.zig"); const manifest_mod = @import("manifest.zig"); const Store = store_mod.Store; const Digest = store_mod.Digest; const TargetKind = manifest_mod.TargetKind;`
- Exact call shape: `const method = try store.materialize(io, digest, dest_path, mode);` (`store: *Store` receiver, `io: std.Io`, absolute `dest_path`, `mode: u32`; clone-or-copy inside, never hardlink). Mode-per-kind (normative): `TargetKind.bin` outputs → `0o755` (the view copy must be executable for cargo-compat `run`/`test`); every other kind (rlib/rmeta/obj/staticlib/dylib/dep-info) → `0o444` (store objects stay read-only). Materialize failures map to `ViewError.StoreRead` (`ObjectNotFound`/unexpected/IO); `error.StoreFull` cannot come from `materialize` (no admission on the read path) — `ViewError.StoreFull` exists for the M4 put paths that reuse this error set, surfaced with the `Store.lastFull()` breakdown verbatim.
- Produces (used by Task 5 `run`, Task 7):
```zig
pub const ViewError = error{ Io, StoreRead, StoreFull, OutOfMemory };
pub const Layout = struct {
    view_root: []const u8,    // "<ws>/target"
    profile_dir: []const u8,  // "<ws>/target/<profile>"
    deps_dir: []const u8,     // "<ws>/target/<profile>/deps"
    fingerprint_dir: []const u8,
};
pub fn layoutPaths(gpa: std.mem.Allocator, ws_root: []const u8, profile: []const u8) ViewError!Layout;
pub fn profileDirName(profile: []const u8) []const u8; // "dev" -> "debug", else verbatim ("release"->"release", custom stays)
pub fn depFileName(gpa: std.mem.Allocator, crate_name: []const u8, meta: []const u8, ext: []const u8) ViewError![]u8;
pub fn materializeOutputs(gpa: std.mem.Allocator, io: std.Io, store: *Store, ws_root: []const u8, profile: []const u8, units: []const UnitPlan) ViewError!void;
pub fn writeViewMeta(gpa: std.mem.Allocator, io: std.Io, ws_root: []const u8, profile: []const u8, units: []const UnitPlan) ViewError!void;
pub fn clean(gpa: std.mem.Allocator, io: std.Io, ws_root: []const u8, profile: ?[]const u8) ViewError!void;
pub const UnitPlan = struct {
    package: []const u8,
    version: []const u8,
    target: []const u8,       // target name (lib name or bin name)
    kind: TargetKind,          // re-exported from manifest.zig
    manifest_digest: ?Digest, // set from M4 on; null in M1 (plan without artifacts)
    outputs: []const []const u8, // terminal output file names for this unit (M1: predicted names)
};
pub fn planUnits(gpa: std.mem.Allocator, ws: *const Workspace, only_package: ?[]const u8) ViewError![]UnitPlan;
```

Layout rules (cargo-identical): `dev → target/debug/`, `release → target/release/`, custom `--profile foo` → `target/foo/`. `depFileName("serde", "ab12", ".rlib")` → `libserde-ab12.rlib`; bins → `<name>` (+ `.exe` only on Windows — unreachable, documented). `materializeOutputs`: for each unit with a non-null `manifest_digest`, `getManifest` → for each output entry `store.materialize(io, digest, dest_path, mode)` into `deps_dir`/`profile_dir` with the Interfaces mode-per-kind table (`0o755` bins, `0o444` everything else; clone-or-copy via store, never hardlink); units with null digests (all of M1) get fingerprint-dir stubs only. `writeViewMeta`: writes `target/<profile>/.rime-view.json` (`{ "version": 1, "complete": false, "project_id": "pb3-<64 hex of normalized ws path>", "profile": …, "units": [{ "package": "a", "version": "0.1.0", "target": "a", "tags": { "crate": "a", "crate_version": "0.1.0", "toolchain": null, "target": "<triple or null>", "profile": "dev", "features": null, "project": "pb3-<id>", "action": "rustc" } }] }`) — the full v2 §11.3 key set with M1-partial values: M1 fills `crate`, `crate_version`, `profile`, `project`, `action` (plus `target` only when `--target` was passed, else null); `toolchain`/`features` are driver-known and stay null until M4 fills them. `"complete": false` marks the row PARTIAL — Plan B must not ingest it as index tags until M4 flips it to `true` with complete rows. Plus `last-build.json` (`{ "manifests": [] }` in M1, real digests from M4). `clean` with `profile == null` deletes the whole `target/` dir; with a profile deletes only that subdir; never touches the store (assert: store dir mtime/count unchanged — tested).

- [ ] **Step 1: Write the failing layout tests**

```zig
test "view maps dev to debug and keeps custom profiles" {
    try std.testing.expectEqualStrings("debug", profileDirName("dev"));
    try std.testing.expectEqualStrings("release", profileDirName("release"));
    try std.testing.expectEqualStrings("fast", profileDirName("fast"));
}

test "view dep file names match cargo" {
    const n = try depFileName(std.testing.allocator, "serde", "ab12cd34", ".rlib");
    defer std.testing.allocator.free(n);
    try std.testing.expectEqualStrings("libserde-ab12cd34.rlib", n);
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `zig build test 2>&1 | tail -10`
Expected: FAIL — `view.zig` not defined.

- [ ] **Step 3: Write minimal implementation**

Pure path-join functions (`layoutPaths` via `std.fs.path.join`, caller frees with matching frees — provide `Layout.deinit`), `profileDirName` mapping, `depFileName` (`lib` prefix + `-` + meta + ext for rlib/rmeta; bare name for bins). `planUnits`: topological order over `memberEdges(gpa, ws)` (free the edges with gpa right after the Kahn pass; dependencies before dependents; `-p` filters to the named member plus its transitive path-deps; unknown `-p` name → `ViewError.Io` with a `package not found` message formatted by the caller). `materializeOutputs`/`writeViewMeta`/`clean` as specified above using `io`-threaded `Dir` calls (`makePath`, `writeFile`, `deleteTree` — copy exact `std.Io` call shapes from the storage-core plan's `layout.zig`/`materialize.zig` usage).

- [ ] **Step 4: Verify materialize + clean against a real store**

```zig
// Test imports (top of view.zig test block): test_support = @import("../store/test_support.zig")
// (store root already imported as store_mod per Interfaces; ManifestOutput = store_mod.Store.ManifestOutput).
test "view materializes store objects and clean removes only the view" {
    const io = std.Io.Threaded.global_single_threaded.io();
    const gpa = std.testing.allocator;
    var ts = test_support.openTestStore(io, .{});
    defer ts.deinit(io);

    // One .bin object in the store, referenced by a manifest entry with mode 0o755.
    const d = try ts.store.putBytes(io, "hello-bin", .bin);
    var outs = [_]store_mod.Store.ManifestOutput{
        .{ .path = "hello-bin", .digest = d, .size = "hello-bin".len, .mode = 0o755 },
    };
    const man_digest = try ts.store.putManifest(io, .{ .kind = .bin, .outputs = &outs });

    // Separate workspace dir (absolute path: Store.materialize resolves relative dests under the store).
    var ws_tmp = std.testing.tmpDir(.{});
    defer ws_tmp.cleanup();
    const ws_root = try ws_tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(ws_root);

    const units = [_]UnitPlan{.{
        .package = "hello",
        .version = "0.1.0",
        .target = "hello",
        .kind = .bin,
        .manifest_digest = man_digest,
        .outputs = &.{"hello-bin"},
    }};
    try materializeOutputs(gpa, io, &ts.store, ws_root, "dev", &units);

    // View copy: identical bytes, executable bit per the mode-per-kind table.
    const got = try ws_tmp.dir.readFileAlloc(io, "target/debug/hello-bin", gpa, .unlimited);
    defer gpa.free(got);
    try std.testing.expectEqualStrings("hello-bin", got);
    const vst = try ws_tmp.dir.statFile(io, "target/debug/hello-bin", .{});
    try std.testing.expectEqual(@as(std.posix.mode_t, 0o755), vst.permissions.toMode());

    // Store object untouched: still read-only 0o444, still verifies.
    var hex_buf: [65]u8 = undefined;
    const obj_path = try std.fs.path.join(gpa, &.{ "objects", d.relPath(&hex_buf) });
    defer gpa.free(obj_path);
    const ost = try ts.store.dir.statFile(io, obj_path, .{});
    try std.testing.expectEqual(@as(std.posix.mode_t, 0o444), ost.permissions.toMode());
    try ts.store.verifyObject(io, d);

    // clean(ws_root, null) removes target/ and nothing else: store object survives.
    try clean(gpa, io, ws_root, null);
    try std.testing.expectError(error.FileNotFound, ws_tmp.dir.statFile(io, "target", .{}));
    try std.testing.expect(test_support.dirHasHot(&ts.store, io, d));
    try std.testing.expect(test_support.dirHasHot(&ts.store, io, man_digest));
}
```

Run: `zig build test 2>&1 | tail -5`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
jj status
jj commit src/cargo/view.zig -m "Add target view layout and materialize"
```

---

### Task 7: Fixture goldens + end-to-end dry-run

**Files:**
- Create: `testdata/cargo/golden/plan.json`
- Test: new inline tests in `src/cargo/cli.zig` (or `src/cargo/plan_test.zig` if `cli.zig` grows past ~400 lines — prefer staying inline; split only on size)

**Interfaces:**
- Consumes: all of Tasks 1–6. Produces nothing (leaf task); proves the milestone.

- [ ] **Step 1: Write the golden file and the failing e2e test**

`testdata/cargo/golden/plan.json` — expected `--message-format=json` output for `rime build --dry-run` in `testdata/cargo/workspace` (2 units, dependencies-first order):
```json
{"reason":"unit-plan","package":"b","target":"b","profile":"dev","success":true}
{"reason":"unit-plan","package":"a","target":"a","profile":"dev","success":true}
```
(one object per line; exact field order as `JsonEnvelope.writeLine` emits).

```zig
test "e2e dry-run plan matches golden" {
    var ws = try workspace.discover(std.testing.allocator, std.Io.Threaded.global_single_threaded.io(), "testdata/cargo/workspace", null);
    defer ws.deinit();
    const units = try view.planUnits(std.testing.allocator, &ws, null);
    defer std.testing.allocator.free(units);
    // render each unit as a JsonEnvelope{reason="unit-plan"} line into a buffer
    // compare buffer to @embedFile("../../testdata/cargo/golden/plan.json")
}
```

Also add the human-format assertion (`Compiling b v0.1.0`, `Compiling a v0.1.0` order) and the `need source` test: `run()` on the `minimal` fixture (which declares registry `serde`) without `--dry-run` returns exit `1` and stderr contains `need source: serde`.

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test 2>&1 | tail -10`
Expected: FAIL — golden mismatch (ordering or field-order difference) or `planUnits` order not yet topological.

- [ ] **Step 3: Fix ordering / rendering to match golden**

Topological sort in `planUnits` (Kahn's algorithm over `memberEdges(gpa, ws)`; ties broken alphabetically for determinism), envelope field order pinned in `writeLine`. No fixture edits to make the test pass — the golden file is the authority; if the golden is wrong (e.g. profile should be `debug` not `dev` — decision: envelope carries the *profile name* `dev`, the *dir* is `debug`; document this in a comment above the test), fix the golden and re-verify by hand.

- [ ] **Step 4: Run full suite + manual CLI smoke**

Run: `zig build test 2>&1 | tail -3`
Expected: all green.
Run: `zig build && ./zig-out/bin/rime build --manifest-path testdata/cargo/workspace/Cargo.toml --dry-run`
Expected: two `Compiling …` lines, exit `0`.
Run: `./zig-out/bin/rime build --manifest-path testdata/cargo/workspace/Cargo.toml --dry-run --message-format=json`
Expected: matches `testdata/cargo/golden/plan.json` byte-for-byte (`diff` clean).
Run: `./zig-out/bin/rime build --manifest-path testdata/cargo/minimal/Cargo.toml`
Expected: exit `1`, stderr `need source: serde…`.

- [ ] **Step 5: Commit**

```bash
jj status
jj commit testdata/cargo/golden src/cargo/cli.zig -m "Add dry-run golden plan tests"
```

---

## Appendix A — spec coverage (milestone 1 vs storage.md)

| Spec section | M1 coverage | Task |
|---|---|---|
| §4 Store as deep module; view-not-store | `view.zig` consumes only `Store.materialize/getManifest`; `clean` never touches store | 6 |
| §5.1 digest text form `b3-…` | preserved in view metas / `last-build.json` manifest digests; never rehashed (envelopes carry package/target/profile names only — no digest field by design) | 5, 6 |
| §5.3 manifests/action entries | `manifest_digest` plumbed, null in M1; `last-build.json` skeleton ready for M4 | 6 |
| §5.4 final binaries materialized; sources in store | terminal-output-only materialization; source fetching deferred to M2 (D5 error) | 5, 6 |
| §7 clone-first, never hardlink | delegated to `Store.materialize`; asserted in test | 6 |
| §11 Store interface | only the five consumed methods; no direct `objects/` access | 6 |

## Appendix B — open questions (for M2+ owners, not M1)

1. Sparse-index protocol subset: which `config.json` / cache-header behaviors must we mirror for `--frozen` to be trustworthy?
2. Git deps: allow arbitrary revs or pin to commits only (cargo allows branches; reproducibility says commits)?
3. Feature unification v1 vs v2 resolver semantics for the M3 resolver — default?
4. Build-script sandboxing depth on macOS (seatbelt?) vs Linux (namespaces?) — what does `script.zig` promise?
5. `target/` fingerprint stubs: how much of cargo's `.fingerprint/` must exist for `cargo`↔`rime` interop in the same dir?

## Self-review note

Coverage: every M1 deliverable in the objective (CLI surface incl. `--message-format=json`; `Cargo.toml`/`Cargo.lock` parsing; workspace discovery; `target/` layout materialized from the store) has ≥1 task; D1–D5 pin the compat decisions; M2–M6 are sketches only (no task bodies) per instructions. Placeholder scan: no TBD/TODO/bare "handle edge cases" — every step names exact code, commands, and expected output. Type consistency: `Manifest`/`Lockfile`/`Workspace`/`Options`/`Layout`/`UnitPlan` signatures are identical everywhere they appear.
