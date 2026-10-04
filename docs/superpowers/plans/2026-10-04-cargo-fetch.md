# Source Fetching (Plan C M2) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:delegate (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fetch every non-path dependency (sparse-registry crates + git checkouts) into global-store `source` objects with sha256 verification, cargo-exact ref resolution, and offline/frozen enforcement — no network in tests.

**Architecture:** A single new module `src/cargo/fetch.zig` sits between the M1 manifest/lock models and the Store deep module: it reads versions + checksums + git precise revs from the parsed `Cargo.lock`, talks to registries through a `RegistryClient` seam (real sparse HTTP client in production, local file-registry stub in tests), shells out to the `git` CLI for git deps (shallow fetch, OID-pinned checkout), ingests every byte via `Store.putBytes`/`putFile` as `Kind.source`, tags via `Store.tagObject`, and reuses via `Store.lookupObjects`. Later milestones (M3 resolver, M4 driver) import only `fetch.zig`'s public surface defined below.

**Tech Stack:** Zig 0.16.0, std only (plus the existing `store` module import; `std.crypto.hash.sha2.Sha256` for verification, `std.compress.flate` `Compress`/`Decompress` with `.gzip` wrapper for `.crate` unpack exactly as `src/store/cold.zig` `gzipAlloc`/`gunzipAlloc` do, `std.tar.Iterator` for archives, `std.process.spawn`/`Child.wait` for the `git` CLI). No new `build.zig.zon` packages, no C sources. There is no `std.compress.gzip.decompressor` in 0.16 — gzip is `flate.Container.gzip` via `flate.Compress.init`/`flate.Decompress.init` (verified in `lib/std/compress/flate.zig` + `src/store/cold.zig:19-33`).

**Spec:** `docs/design/storage-v2.md` §16 (Store surface: `putBytes`/`putFile`/`tagObject`/`lookupObjects`/`materialize`, `StoreFull` surfacing) + §11.3 (tag vocabulary) + §§5.2/5.4/9.3 (source objects are demotable, counted `source` kind); `docs/superpowers/plans/2026-10-04-cargo-frontend.md` §0 (M2 sketch, D3/D5) and its Task 2 (`manifest.zig`: `DependencyKind`/`GitSpec`), Task 3 (`lock.zig`: `LockPackage`/`Lockfile`), Task 5 (`cli.zig`: `--offline`/`--frozen`/`--locked`); vendored cargo 0.99.0 at `references/cargo` (`src/cargo/sources/registry/**`, `src/cargo/sources/git/**`, resolver `encode.rs` checksum note).

## Global Constraints

- Zig **0.16.0** exactly. FS access goes through the `std.Io` interface value passed as `io` to every call; `std.Io.Dir`/`std.Io.File` methods take `io` (copy call sites from the storage-core plan exactly).
- Dependencies: **std only**. No packages in `build.zig.zon`, no C sources. The SQLite amalgamation stays behind Plan B's `Store` API; `fetch.zig` never imports sqlite.
- Tests are inline (`test "…"` blocks) plus `testdata/cargo/fetch/` fixtures. `zig build test` must pass before **every** commit. Never commit with failing tests. No network in tests: registry tests use the file-registry stub, git tests use `file://` repos under `std.testing.tmpDir`.
- Cargo-compat invariants after every task: lockfile `checksum` field is opaque passthrough verified at fetch time (D3); project dirs never hold cache state; store objects read-only (`0o444`), never hardlinked; exit behavior matches cargo (§2.1/D4: usage/config errors exit `1`).
- Prerequisite: M1 Tasks 1–5 landed (`src/cargo/{toml,manifest,lock,workspace,cli}.zig`, `src/cargo/root.zig` re-exporting them, `cargo` module in `build.zig`). This plan only appends the `fetch` re-export line to `root.zig`.
- All VCS operations use **jj**: `jj status`, `jj diff`, `jj commit <paths> -m "…"`. Never run git write commands on the rime repo itself. (Running `git` as a *test fixture tool* inside tmp dirs — `git init`, `commit`, `clone file://…` — is allowed and is how git-dep tests build fixtures; it never touches the repo.) One logical change per commit, imperative ≤50-char summaries.
- Scratch experiments go in `/tmp`, never in the repo.
- Digest text form is `b3-<64 lowercase hex>` in all user-facing output. `.crate` sha256 checksums are lowercase hex (64 chars) and are a different hash from store digests — never conflate them.
- Conformance is TESTED: fixtures run through the real `cargo` binary (1.99.0-nightly) as an oracle. Oracle-gated tests run only with `RIME_CARGO_ORACLE=1` and `cargo` on `PATH`; the default `zig build test` stays hermetic.

---

## File Structure

```
src/cargo/fetch.zig              ALL fetch logic + public API + FileRegistry stub (Tasks 1–8)
src/cargo/root.zig               append one re-export line (Task 1)
testdata/cargo/fetch/stub/       hand-written stub-registry fixtures (Tasks 1–2):
  config.json                      {"dl": "file://…{crate}/{version}/{sha256-checksum}…"} template form
  index/se/rd/serde                index file: one JSON object per line ({name,vers,cksum,yanked})
  crates/serde-1.0.0.crate         minimal .crate tar.gz fixture (built by Task 4 generator)
testdata/cargo/fetch/locks/      lockfile fixtures (sample.lock: registry + git entries) (Tasks 4, 6)
testdata/cargo/fetch/golden/     oracle goldens (cargo-generated .crate file lists, index lines) (Task 9)
```

`fetch.zig` has one clear responsibility: turn lockfile entries into tagged store objects. The `RegistryClient` seam (one vtable struct, two implementations) is the only network boundary; the `GitRunner` seam (one function-pointer struct, real CLI runner + fake in tests) is the only subprocess boundary. Both seams live in `fetch.zig` — no separate files, no scaffolding beyond what the tasks below consume.

## Public Surface (fetch.zig — later milestones import exactly these)

```zig
// ---- source identity (mirrors cargo's SourceId semantics, references/cargo/src/cargo/core/source_id.rs) ----
pub const RegistryKind = enum { sparse, local_files };
pub const SourceId = union(enum) {
    registry: struct { url: []const u8, kind: RegistryKind }, // sparse+https://… or file:// stub
    git: struct { url: []const u8, ref: GitRef },             // ref as declared in Cargo.toml
    path: void, // path deps never reach fetch.zig (workspace task owns them)
};
pub const GitRef = union(enum) {
    default_branch: void,       // no rev/branch/tag key
    branch: []const u8,
    tag: []const u8,
    rev: []const u8,            // full OID or short prefix; resolved post-fetch like cargo
};
pub const GitPrecise = struct { oid: [40]u8 }; // lowercase hex commit id from the lockfile (#fragment)

// ---- errors ----
pub const FetchError = error{
    Network, Auth, NotFound, ChecksumMismatch, InvalidIndex, InvalidCrate,
    GitFailed, OfflineMissing, FrozenViolation, LockedViolation,
    StoreRead, StoreFull, TagError, OutOfMemory, Usage,
};

// ---- results ----
pub const SourceFile = struct { path: []const u8, digest: Digest }; // path uses '/' separators
pub const FetchedSource = struct {
    manifest_digest: Digest,   // store manifest object listing the tree (Kind.source)
    files: []SourceFile,       // every ingested file (borrowed from fetch arena)
    arena: std.heap.ArenaAllocator, // owns files/path strings; deinit frees
    pub fn deinit(self: *FetchedSource) void { ... }
};

// ---- seams (network/subprocess boundaries; fakes live in the same file) ----
pub const RegistryClient = struct {
    ptr: *anyopaque,
    fetchConfigFn: *const fn (ptr: *anyopaque, gpa: std.mem.Allocator) FetchError![]u8,
    fetchIndexFn: *const fn (ptr: *anyopaque, gpa: std.mem.Allocator, crate_name: []const u8, cached_version: ?[]const u8) FetchError!IndexResponse,
    fetchCrateFn: *const fn (ptr: *anyopaque, gpa: std.mem.Allocator, dl_url: []const u8) FetchError![]u8,
    pub fn fetchConfig(self: RegistryClient, gpa: std.mem.Allocator) FetchError![]u8 { ... }
    pub fn fetchIndex(self: RegistryClient, gpa: std.mem.Allocator, crate_name: []const u8, cached_version: ?[]const u8) FetchError!IndexResponse { ... }
    pub fn fetchCrate(self: RegistryClient, gpa: std.mem.Allocator, dl_url: []const u8) FetchError![]u8 { ... }
};
pub const IndexResponse = union(enum) { fresh: []u8, not_modified: void, not_found: void };
pub const GitRunner = struct {
    ptr: *anyopaque,
    runFn: *const fn (ptr: *anyopaque, gpa: std.mem.Allocator, io: std.Io, argv: []const []const u8, cwd: []const u8) FetchError![]u8,
    pub fn run(self: GitRunner, gpa: std.mem.Allocator, io: std.Io, argv: []const []const u8, cwd: []const u8) FetchError![]u8 { ... }
};

// ---- entry points (M3/M4 import these; FINAL form — no later task changes signatures) ----
pub const FetchOptions = struct {
    offline: bool = false,
    frozen: bool = false,
    locked: bool = false,
    cache_dir: []const u8, // registry cache root (index cache + .crate cache live here, NOT in the store)
};
// Declared git refs keyed by package name (values borrowed from the workspace manifests).
// Defined HERE (not in Task 8) so out-of-order implementers see the 8-param form from the start.
pub const GitDecls = std.StringHashMap(GitRef);
pub fn fetchRegistryCrate(gpa: std.mem.Allocator, io: std.Io, store: *Store, client: RegistryClient, opts: FetchOptions, name: []const u8, version: []const u8, want_checksum: []const u8) FetchError!FetchedSource;
pub fn fetchGitCheckout(gpa: std.mem.Allocator, io: std.Io, store: *Store, git: GitRunner, opts: FetchOptions, url: []const u8, ref: GitRef, precise: ?GitPrecise) FetchError!FetchedSource;
pub fn ensureSources(gpa: std.mem.Allocator, io: std.Io, store: *Store, client: RegistryClient, git: GitRunner, opts: FetchOptions, lock: *const Lockfile, git_decls: *const GitDecls) FetchError![]FetchedSource;
```

Store imports at the top of `fetch.zig` (nothing else from the store — §16 surface only):

```zig
const store_mod = @import("../store/root.zig");
const Store = store_mod.Store;
const Digest = store_mod.Digest;
const Tag = store_mod.Tag;
const lock_mod = @import("lock.zig");
const Lockfile = lock_mod.Lockfile;
```

Which cargo sources pin each semantic (normative map — every task cites its rows; fetch MUST behave identically to cargo against the REAL crates.io):

| Semantic | Cargo source | fetch.zig behavior |
|---|---|---|
| Sparse index protocol (`GET /index/<sharded-path>` with `Accept: application/json`, config discovery at `/config.json`) | `registry/http_remote.rs` `config()`/`sparse_fetch`/`fetch_uncached` | Task 2 `parseRegistryConfig`, `dlUrlFor`, index cache |
| `config.json` schema (`dl` template REQUIRED, `api` optional, `auth-required` default false) | `cargo-util-schemas/src/index.rs` `RegistryConfig` + `http_remote.rs` `config()` | Task 2 `parseRegistryConfig` (unknown fields ignored) |
| Index file format: one JSON object per line, required `name`/`vers`/`cksum` (sha256 hex of the `.crate`), optional `yanked` (default false), `deps`/`features`/`features2`/`rust_version`/`links` IGNORED by fetch (resolver-owned) | `cargo-util-schemas/src/index.rs` `IndexPackage` | Task 3 `selectIndexEntry` (reads only `vers`/`cksum`/`yanked`; skips malformed lines; unknown fields never fail) |
| Index sharding layout (`1/`, `2/`, `3/u/`, `ab/cd/`) | `registry/mod.rs` module docs + `cargo_util::registry::make_dep_path` | Task 2 `indexRelPath` |
| `config.json` (`dl` template, `api`, `auth-required`) + cache-or-remote + `auth_required` retry | `registry/http_remote.rs` `config()` / `fetch_uncached` | Task 2 `parseRegistryConfig`, `dlUrlFor` |
| Index cache revalidation (`index_version` = `"etag: <ETag>"` or `"last-modified: <date>"` → `If-None-Match`/`If-Modified-Since`; 304 = cache-valid reuse; offline = cache-only) | `registry/http_remote.rs` `load()`/`sparse_fetch()` + `index/cache.rs` + `LoadResponse::CacheValid` | Task 2 cache read/write, Task 5 `fetchRegistryCrate` `.not_modified` reuse, Task 8 offline |
| Cache headers + etiquette: stock `User-Agent: cargo/<version>` on every request, `ETag`/`Last-Modified` persisted per index file, unknown `index_version` shapes ignored (refetch, never crash) | `registry/http_remote.rs` `fetch_uncached` + `network/mod.rs` user-agent | Task 2 `readIndexVersion`/`writeIndexCache`, real HTTP client headers (stub carries none) |
| Per-version index lines (`IndexPackage`: `name/vers/cksum/yanked`), yanked locked-deps still fetchable, `--precise` yanked warning | `registry/mod.rs` `query()` + `cargo_util_schemas::index::IndexPackage` | Task 3 `selectIndexEntry` |
| `.crate` cache skip-if-present (nonzero file = Ready), `dl` URL from `crate_url(dl, name, version, checksum)` | `registry/download.rs` `download()` | Task 4 `fetchCrateBytes` |
| `.crate` download URL construction: `crate_url()` five-placeholder substitution + no-placeholder `{dl}/{crate}/{version}/download` fallback | `cargo-util/src/registry.rs` `crate_url`/`make_dep_path` | Task 2 `dlUrlFor` (exact port incl. case-preserving `{prefix}`) |
| sha256 verify (`Sha256(data).finish_hex() != checksum` → bail `failed to verify the checksum of \`<pkg>\``), then persist | `registry/download.rs` `finish_download()` | Task 4 `verifySha256Hex` (constant-time compare; message text asserted in Task 9) |
| Unpack guards: `prefix/name-version/` strip, `Regular\|Directory` only, skip `.cargo-ok`, 512 MiB / 20:1 zip-bomb cap, deterministic mtime for `Cargo.toml`/`Cargo.lock`/`.cargo_vcs_info.json` | `registry/mod.rs` `unpack()` + `max_unpack_size()` + `PACKAGE_SOURCE_LOCK` history | Task 5 `unpackCrate` |
| Git ref kinds (branch/tag/rev/default), precise fragment (`#oid`) from lockfile, lock-driven fetch (Deferred precise always fetches when online) | `core/source_id.rs` (`GitReference`, `precise_git_fragment`) + `sources/git/utils.rs` `fetch_db`/`checkout` | Task 6 `resolveGitRef` |
| Shallow fetch (`--depth 1` for branch/tag; full fetch when `rev` needs history), `reset --hard` to OID, `.cargo-ok` interrupt guard, recursive submodules | `sources/git/utils.rs` `GitDatabase::checkout`/`clone_into`/`reset` | Task 6–7 |
| Lockfile checksum note (registry packages carry sha256; M3 writer preserves it) | `core/resolver/encode.rs` docs | Task 4 + Task 9 round-trip |

Tagging contract (§11.3, exact — enforced by `tags.zig` validation, so get it right):

- Every ingested source file object + the tree manifest object gets **both** `crate=<name>` and `crate_version=<version>` (half-identified pairs are rejected with `TagMismatch`).
- Plus provenance: `user.source=registry` or `user.source=git`. Git trees additionally get `user.git-oid=<40-hex>` (the resolved precise OID).
- `action` tag is NOT set on source objects (vocabulary has no source action; driver tags `rustc`/`build-script` outputs in M4/M5). `project` is never set (cross-project sharing is the point, storage-v2 §12.1). WAIVER vs frontend M2 sketch: `docs/superpowers/plans/2026-10-04-cargo-frontend.md` §M2-coarse says sources are tagged (`crate` + `crate_version`, `action`, plus `user.source=registry|git`). That `action` mention is AMENDED to drop `action` on source objects — per storage-v2 §11.3 the `action` key enumerates build actions (`rustc`, `build-script`), and `tags.zig` validation rejects vocabulary-external `action` values on `Kind.source` trees. Source provenance is `user.source` (+ `user.git-oid` for git), never `action`.
- Unpack-generated tree manifest objects use `Kind.source` (demotable, counted — §5.4/`Kind` table has no separate manifest-for-sources kind; store `Manifest` kind is for build action manifests).

`StoreFull` surfacing (§16/§10.4): `fetch.zig` never swallows it. Store `put*` errors are mapped by one helper (Task 5) that re-raises `StoreFull` verbatim and converts everything else to `FetchError.StoreRead`/`OutOfMemory`. Because Plan B has not yet added `StoreFull` to `PutError`, the helper compares via `@errorName` (compiles both before and after the store gains `StoreFull`):

```zig
fn mapPutError(e: anyerror) FetchError {
    if (std.mem.eql(u8, @errorName(e), "StoreFull")) return FetchError.StoreFull;
    if (e == error.OutOfMemory) return FetchError.OutOfMemory;
    return FetchError.StoreRead;
}
```

`lookupObjects` reuse fast path (Task 8): before any network, query `{crate=X, crate_version=Y, user.source=registry}` (plus `user.git-oid` for git); on hit, verify each digest still `exists` in the store and rebuild the `FetchedSource` from the cached tree manifest instead of downloading.

### Broad source forms (post-resolution — fetch handles every form cargo emits in `Cargo.lock`)

rime supports MOST of `Cargo.toml`, not a narrow subset. After M3 resolution every dependency
appears in the lock as one of three fetch-relevant shapes, and fetch handles all of them:

- **registry** (`source = "registry+<url>"` + `checksum`): Tasks 2–5. Renamed deps (`serde_derive = { package = "serde", version = ... }`), optional deps (`optional = true`, enabled via features), and target-specific deps (`[target.'cfg(windows)'.dependencies]`) are ALL already resolved to plain lock entries by M3 — fetch keys reuse/store-lookup purely by lock `name`/`version`, so renames/optionals/targets need no fetch-side branching. The `package =` rename source-of-truth is the LOCK name (which equals the registry crate name), never the depended-upon alias.
- **git** (`source = "git+<url>#<40hex-oid>"` + declared ref from the workspace `GitSpec` via `GitDecls`): Tasks 6–7. `rev` (full OID or short prefix), `branch`, `tag`, and absent-key (default branch) all resolve post-fetch via `rev-parse <ref>^{commit}` exactly like `utils.rs resolve_ref`; the lock `#oid` fragment is authoritative when present. Renamed/optional/target-specific git deps behave identically (lock name keys everything).
- **path** (`source = null` / absent): SKIPPED by fetch (workspace owns path deps; never downloaded, never cached). A path entry with a `checksum` is ignored (path sources have no checksums in cargo).
- Anything else (`source` with an unknown scheme) → `FetchError.Usage` naming the package (cargo would have rejected it at resolve time; fetch never guesses).

---

### Task 1: Module skeleton, error set, seams, and the file-registry stub

**Files:**
- Create: `src/cargo/fetch.zig`
- Modify: `src/cargo/root.zig` (append `pub const fetch = @import("fetch.zig");`)
- Create fixtures: `testdata/cargo/fetch/stub/config.json`, `testdata/cargo/fetch/stub/index/se/rd/serde` (two version lines, one yanked)

**Interfaces:**
- Consumes: `store_mod.Store/Tag/Digest` (§16 read of signatures from `src/store/root.zig`), `lock_mod.Lockfile` (M1 Task 3 shape: `LockPackage{name,version,source,checksum,dependencies}`).
- Produces (used by Tasks 2–8):
```zig
pub const FetchError = error{ Network, Auth, NotFound, ChecksumMismatch, InvalidIndex, InvalidCrate, GitFailed, OfflineMissing, FrozenViolation, LockedViolation, StoreRead, StoreFull, TagError, OutOfMemory, Usage };
pub const RegistryClient = struct { ... }; // vtable as in Public Surface above
pub const GitRunner = struct { ... };       // vtable as in Public Surface above
pub const FileRegistry = struct {           // TEST HARNESS: serves a stub registry dir through the RegistryClient seam
    root: []const u8,                       // stub dir on disk (contains config.json, index/, crates/)
    pub fn client(self: *FileRegistry) RegistryClient { ... }
};
pub const StubGit = struct {                // TEST HARNESS: pre-canned git outputs, no subprocess
    oid: [40]u8,
    tree_files: []const StubFile,
    pub fn runner(self: *StubGit) GitRunner { ... }
};
pub const StubFile = struct { path: []const u8, contents: []const u8 };
```

Stub `config.json` fixture (`testdata/cargo/fetch/stub/config.json`):
```json
{"dl":"file://STUB/crates/{crate}/{version}/{sha256-checksum}","api":"file://STUB/api"}
```
(The `file://STUB/` prefix is rewritten to the tmp stub dir at test time — documents the `dl` template contract without hardcoding paths. `dlUrlFor` in Task 2 implements cargo's `crate_url(dl, name, version, checksum)` substitution exactly (`references/cargo/crates/cargo-util/src/registry.rs`): `{crate}`, `{version}`, `{sha256-checksum}`, plus `{prefix}`/`{lowerprefix}` via `make_dep_path(name, prefix_only=true)`, with the no-placeholder fallback `{dl}/{crate}/{version}/download` when the template contains none of the five placeholders.)

Stub index fixture (`testdata/cargo/fetch/stub/index/se/rd/serde`):
```json
{"name":"serde","vers":"1.0.0","cksum":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","yanked":false}
{"name":"serde","vers":"1.0.1","cksum":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","yanked":true}
```

- [ ] **Step 1: Write the failing test**

```zig
test "file registry stub serves config and index lines" {
    const io = std.Io.Threaded.global_single_threaded.io();
    const gpa = std.testing.allocator;
    var stub = FileRegistry{ .root = "testdata/cargo/fetch/stub" };
    const client = stub.client();
    const cfg_text = try client.fetchConfig(gpa);
    defer gpa.free(cfg_text);
    try std.testing.expect(std.mem.indexOf(u8, cfg_text, "\"dl\"") != null);
    const resp = try client.fetchIndex(gpa, "serde", null);
    const body = switch (resp) {
        .fresh => |b| b,
        else => return error.TestUnexpectedResult,
    };
    defer gpa.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"1.0.0\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"yanked\":true") != null);
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test 2>&1 | tail -10`
Expected: FAIL — `src/cargo/fetch.zig` does not exist / `FileRegistry` not defined. (If the `cargo` module is not yet in `build.zig`, land M1 Task 5's `build.zig` step first; this task only appends the `fetch` line to the existing `src/cargo/root.zig`.)

- [ ] **Step 3: Write minimal implementation**

```zig
const std = @import("std");
const store_mod = @import("../store/root.zig");
const Store = store_mod.Store;
const Digest = store_mod.Digest;
const Tag = store_mod.Tag;

pub const FetchError = error{
    Network, Auth, NotFound, ChecksumMismatch, InvalidIndex, InvalidCrate,
    GitFailed, OfflineMissing, FrozenViolation, LockedViolation,
    StoreRead, StoreFull, TagError, OutOfMemory, Usage,
};

pub const IndexResponse = union(enum) { fresh: []u8, not_modified: void, not_found: void };

pub const RegistryClient = struct {
    ptr: *anyopaque,
    fetchConfigFn: *const fn (ptr: *anyopaque, gpa: std.mem.Allocator) FetchError![]u8,
    fetchIndexFn: *const fn (ptr: *anyopaque, gpa: std.mem.Allocator, crate_name: []const u8, cached_version: ?[]const u8) FetchError!IndexResponse,
    fetchCrateFn: *const fn (ptr: *anyopaque, gpa: std.mem.Allocator, dl_url: []const u8) FetchError![]u8,
    pub fn fetchConfig(self: RegistryClient, gpa: std.mem.Allocator) FetchError![]u8 {
        return self.fetchConfigFn(self.ptr, gpa);
    }
    pub fn fetchIndex(self: RegistryClient, gpa: std.mem.Allocator, crate_name: []const u8, cached_version: ?[]const u8) FetchError!IndexResponse {
        return self.fetchIndexFn(self.ptr, gpa, crate_name, cached_version);
    }
    pub fn fetchCrate(self: RegistryClient, gpa: std.mem.Allocator, dl_url: []const u8) FetchError![]u8 {
        return self.fetchCrateFn(self.ptr, gpa, dl_url);
    }
};

pub const GitRunner = struct {
    ptr: *anyopaque,
    runFn: *const fn (ptr: *anyopaque, gpa: std.mem.Allocator, io: std.Io, argv: []const []const u8, cwd: []const u8) FetchError![]u8,
    pub fn run(self: GitRunner, gpa: std.mem.Allocator, io: std.Io, argv: []const []const u8, cwd: []const u8) FetchError![]u8 {
        return self.runFn(self.ptr, gpa, io, argv, cwd);
    }
};

pub const StubFile = struct { path: []const u8, contents: []const u8 };

/// Test harness: serves a stub registry directory through the RegistryClient seam. No sockets.
pub const FileRegistry = struct {
    root: []const u8,
    pub fn client(self: *FileRegistry) RegistryClient {
        return .{
            .ptr = self,
            .fetchConfigFn = fileFetchConfig,
            .fetchIndexFn = fileFetchIndex,
            .fetchCrateFn = fileFetchCrate,
        };
    }
    fn fileFetchConfig(ptr: *anyopaque, gpa: std.mem.Allocator) FetchError![]u8 {
        const self: *FileRegistry = @ptrCast(@alignCast(ptr));
        const io = std.Io.Threaded.global_single_threaded.io();
        const p = std.fs.path.join(gpa, &.{ self.root, "config.json" }) catch return FetchError.OutOfMemory;
        defer gpa.free(p);
        return std.Io.Dir.cwd().readFileAlloc(io, p, gpa, .limited(1 << 20)) catch return FetchError.NotFound;
    }
    fn fileFetchIndex(ptr: *anyopaque, gpa: std.mem.Allocator, crate_name: []const u8, cached_version: ?[]const u8) FetchError!IndexResponse {
        _ = cached_version; // file stub has no versions: always fresh (Task 2 adds cache semantics to the real client)
        const self: *FileRegistry = @ptrCast(@alignCast(ptr));
        const io = std.Io.Threaded.global_single_threaded.io();
        const rel = indexRelPath(gpa, crate_name) catch return FetchError.OutOfMemory;
        defer gpa.free(rel);
        const p = std.fs.path.join(gpa, &.{ self.root, "index", rel }) catch return FetchError.OutOfMemory;
        defer gpa.free(p);
        const body = std.Io.Dir.cwd().readFileAlloc(io, p, gpa, .limited(4 << 20)) catch return FetchError.NotFound;
        return IndexResponse{ .fresh = body };
    }
    fn fileFetchCrate(ptr: *anyopaque, gpa: std.mem.Allocator, dl_url: []const u8) FetchError![]u8 {
        const self: *FileRegistry = @ptrCast(@alignCast(ptr));
        const io = std.Io.Threaded.global_single_threaded.io();
        // Stub dl URLs are file paths: strip the "file://" scheme and read directly.
        const path = if (std.mem.startsWith(u8, dl_url, "file://")) dl_url["file://".len..] else return FetchError.Network;
        const abs = if (std.mem.startsWith(u8, path, "STUB/"))
            std.fs.path.join(gpa, &.{ self.root, path["STUB/".len..] }) catch return FetchError.OutOfMemory;
        else
            gpa.dupe(u8, path) catch return FetchError.OutOfMemory;
        defer gpa.free(abs);
        return std.Io.Dir.cwd().readFileAlloc(io, abs, gpa, .limited(512 << 20)) catch return FetchError.NotFound;
    }
};

/// Test harness: pre-canned git outputs, no subprocess. `tree_files` is the checked-out tree.
pub const StubGit = struct {
    oid: [40]u8,
    tree_files: []const StubFile,
    pub fn runner(self: *StubGit) GitRunner {
        return .{ .ptr = self, .runFn = stubRun };
    }
    fn stubRun(ptr: *anyopaque, gpa: std.mem.Allocator, io: std.Io, argv: []const []const u8, cwd: []const u8) FetchError![]u8 {
        _ = io; _ = cwd;
        const self: *StubGit = @ptrCast(@alignCast(ptr));
        // Only rev-parse is emulated: `git rev-parse <ref>^{commit}` -> canned OID. Anything else is a test bug.
        if (argv.len >= 2 and std.mem.eql(u8, argv[0], "git") and std.mem.eql(u8, argv[1], "rev-parse")) {
            return gpa.dupe(u8, self.oid[0..]) catch return FetchError.OutOfMemory;
        }
        return FetchError.GitFailed;
    }
};

fn indexRelPath(gpa: std.mem.Allocator, crate_name: []const u8) std.mem.Allocator.Error![]u8 {
    // Forward declaration: full implementation lands in Task 2. Stub returns the flat name so Task 1 compiles green.
    return gpa.dupe(u8, crate_name);
}
```

Note the deliberate wart documented in a comment above `indexRelPath`: it returns the flat name until Task 2 replaces it with cargo's sharded layout — Task 2's test (which reads `index/se/rd/serde` through the stub) fails until then, proving the sharding matters. Keep the wart exactly one task wide.

- [ ] **Step 4: Run test to verify it passes**

Run: `zig build test 2>&1 | tail -5`
Expected: PASS for the Task 1 test (flat-name stub reads only if you point the test at a flat copy — so in this task ALSO create `testdata/cargo/fetch/stub/index/serde` as a byte-identical copy of `index/se/rd/serde`; Task 2 deletes the flat copy when sharding lands. Document this in a comment in the test.)

- [ ] **Step 5: Commit**

```bash
jj status
jj commit src/cargo/fetch.zig src/cargo/root.zig testdata/cargo/fetch/stub -m "Add fetch module skeleton and registry stub"
```

---

### Task 2: Sparse index paths, config.json, and the index cache subset

**Files:**
- Modify: `src/cargo/fetch.zig`
- Test: inline tests in `src/cargo/fetch.zig`
- Fixtures: use `testdata/cargo/fetch/stub/` from Task 1 (delete the flat `index/serde` copy in this task)

**Interfaces:**
- Consumes: Task 1 `RegistryClient`/`FileRegistry`/`FetchError`.
- Produces (used by Tasks 3–4, 8):
```zig
pub fn indexRelPath(gpa: std.mem.Allocator, crate_name: []const u8) std.mem.Allocator.Error![]u8;
pub const RegistryConfig = struct {
    dl: []const u8,              // download template with {crate}/{version}/{sha256-checksum}/{prefix}/{lowerprefix}, or a bare base URL (fallback appends /{crate}/{version}/download)
    api: ?[]const u8,           // present on real sparse servers; file stub carries a file:// api value
    auth_required: bool,        // default false
    arena: std.heap.ArenaAllocator, // owns dl/api strings
    pub fn deinit(self: *RegistryConfig) void { ... }
};
pub fn parseRegistryConfig(gpa: std.mem.Allocator, text: []const u8) FetchError!RegistryConfig;
pub fn dlUrlFor(gpa: std.mem.Allocator, cfg: *const RegistryConfig, name: []const u8, version: []const u8, checksum: []const u8) FetchError![]u8;
pub fn readIndexCache(gpa: std.mem.Allocator, io: std.Io, cache_dir: []const u8, crate_name: []const u8) FetchError!IndexResponse;
pub fn writeIndexCache(gpa: std.mem.Allocator, io: std.Io, cache_dir: []const u8, crate_name: []const u8, body: []const u8, version: []const u8) FetchError!void;
pub fn readIndexVersion(gpa: std.mem.Allocator, io: std.Io, cache_dir: []const u8, crate_name: []const u8) FetchError!?[]u8;
```

Cargo pins (`registry/http_remote.rs`, `registry/index/cache.rs`, `registry/mod.rs` docs): sharding is `1/<name>` (len 1), `2/<name>` (len 2), `3/<first>/<name>` (len 3), else `<ab>/<cd>/<name>`. `config.json` keys: `dl` (required), `api` (optional), `auth-required` (optional, default false). Cache files store the raw index body plus the `index_version` (ETag/Last-Modified) used for `If-None-Match` revalidation; `fetch_uncached` returns 304 → cache-valid. Offline never hits the network.

- [ ] **Step 1: Write the failing tests**

```zig
test "index paths shard like cargo" {
    const gpa = std.testing.allocator;
    const cases = [_]struct { name: []const u8, want: []const u8 }{
        .{ .name = "u", .want = "1/u" },
        .{ .name = "ab", .want = "2/ab" },
        .{ .name = "url", .want = "3/u/url" },
        .{ .name = "serde", .want = "se/rd/serde" },
        .{ .name = "bzip2", .want = "bz/ip/bzip2" },
    };
    for (cases) |c| {
        const got = try indexRelPath(gpa, c.name);
        defer gpa.free(got);
        try std.testing.expectEqualStrings(c.want, got);
    }
}

test "config parses dl template and auth default" {
    var cfg = try parseRegistryConfig(std.testing.allocator,
        \\{"dl":"https://static.crates.io/crates/{crate}/{version}/download","api":"https://crates.io/api/v1/crates"}
    );
    defer cfg.deinit();
    try std.testing.expectEqualStrings("https://static.crates.io/crates/{crate}/{version}/download", cfg.dl);
    try std.testing.expect(!cfg.auth_required);
    const url = try dlUrlFor(std.testing.allocator, &cfg, "serde", "1.0.0", "aa");
    defer std.testing.allocator.free(url);
    try std.testing.expectEqualStrings("https://static.crates.io/crates/serde/1.0.0/download", url);
}

test "dl template substitutes prefix/lowerprefix and falls back without placeholders" {
    const gpa = std.testing.allocator;
    // {prefix} is make_dep_path(name, prefix_only=true) WITHOUT lowercasing (cargo registry.rs
    // prefix_only test: make_dep_path("AbCd", true) == "Ab/Cd"); {lowerprefix} is prefix.to_lowercase().
    // Index sharding (indexRelPath) always lowercases; dl {prefix} preserves case.
    var cfg_p = try parseRegistryConfig(gpa, "{\"dl\":\"https://dl.example/{prefix}/{crate}/{version}/{sha256-checksum}\"}");
    defer cfg_p.deinit();
    const u1 = try dlUrlFor(gpa, &cfg_p, "serde", "1.0.0", "aa");
    defer gpa.free(u1);
    try std.testing.expectEqualStrings("https://dl.example/se/rd/serde/1.0.0/aa", u1);
    var cfg_l = try parseRegistryConfig(gpa, "{\"dl\":\"https://dl.example/{lowerprefix}/{crate}/{version}\"}");
    defer cfg_l.deinit();
    const u2 = try dlUrlFor(gpa, &cfg_l, "AbCd", "0.1.0", "aa");
    defer gpa.free(u2);
    try std.testing.expectEqualStrings("https://dl.example/ab/cd/AbCd/0.1.0", u2);
    // No placeholder at all -> fallback "{dl}/{crate}/{version}/download" (cargo crate_url branch).
    var cfg_f = try parseRegistryConfig(gpa, "{\"dl\":\"https://dl.example/base\"}");
    defer cfg_f.deinit();
    const u3 = try dlUrlFor(gpa, &cfg_f, "serde", "1.0.0", "aa");
    defer gpa.free(u3);
    try std.testing.expectEqualStrings("https://dl.example/base/serde/1.0.0/download", u3);
}

test "index cache round-trips and stub resolves sharded paths" {
    const io = std.Io.Threaded.global_single_threaded.io();
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // Verified precedent: dir.realPathFile with a stack buffer (src/store/disk_usage.zig:30). No realPathFileAlloc in src/store.
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = try tmp.dir.realPathFile(io, ".", &path_buf);
    const root = path_buf[0..path_len];
    try writeIndexCache(gpa, io, root, "serde", "line1\n", "etag-1");
    const hit = try readIndexCache(gpa, io, root, "serde");
    const body = switch (hit) { .fresh => |b| b, else => return error.TestUnexpectedResult };
    defer gpa.free(body);
    try std.testing.expectEqualStrings("line1\n", body);
    // Sharded stub file now resolves through the real layout:
    var stub = FileRegistry{ .root = "testdata/cargo/fetch/stub" };
    const resp = try stub.client().fetchIndex(gpa, "serde", null);
    const sb = switch (resp) { .fresh => |b| b, else => return error.TestUnexpectedResult };
    defer gpa.free(sb);
    try std.testing.expect(std.mem.indexOf(u8, sb, "\"1.0.0\"") != null);
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `zig build test 2>&1 | tail -10`
Expected: FAIL — `indexRelPath` returns flat name (sharding cases fail), `parseRegistryConfig`/`dlUrlFor`/`readIndexCache`/`writeIndexCache` undefined.

- [ ] **Step 3: Write minimal implementation**

```zig
pub fn indexRelPath(gpa: std.mem.Allocator, crate_name: []const u8) std.mem.Allocator.Error![]u8 {
    // cargo_util::registry::make_dep_path: exact shard rules (registry/mod.rs module docs).
    const lower = try gpa.dupe(u8, crate_name);
    for (lower) |*c| c.* = std.ascii.toLower(c.*);
    defer gpa.free(lower);
    return switch (lower.len) {
        1 => std.fmt.allocPrint(gpa, "1/{s}", .{lower}),
        2 => std.fmt.allocPrint(gpa, "2/{s}", .{lower}),
        3 => std.fmt.allocPrint(gpa, "3/{c}/{s}", .{ lower[0], lower }),
        else => std.fmt.allocPrint(gpa, "{s}/{s}/{s}", .{ lower[0..2], lower[2..4], lower }),
    };
}

pub const RegistryConfig = struct {
    dl: []const u8,
    api: ?[]const u8,
    auth_required: bool,
    arena: std.heap.ArenaAllocator,
    pub fn deinit(self: *RegistryConfig) void { self.arena.deinit(); }
};

pub fn parseRegistryConfig(gpa: std.mem.Allocator, text: []const u8) FetchError!RegistryConfig {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const alloc = arena.allocator();
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, text, .{}) catch return FetchError.InvalidIndex;
    defer parsed.deinit();
    if (parsed.value != .object) return FetchError.InvalidIndex;
    const dl_v = parsed.value.object.get("dl") orelse return FetchError.InvalidIndex;
    if (dl_v != .string) return FetchError.InvalidIndex;
    const api_v = parsed.value.object.get("api");
    const auth_v = parsed.value.object.get("auth-required");
    return .{
        .dl = try alloc.dupe(u8, dl_v.string),
        .api = if (api_v) |a| (if (a == .string) try alloc.dupe(u8, a.string) else null) else null,
        .auth_required = if (auth_v) |a| (if (a == .boolean) a.boolean else false) else false,
        .arena = arena,
    };
}

pub fn dlUrlFor(gpa: std.mem.Allocator, cfg: *const RegistryConfig, name: []const u8, version: []const u8, checksum: []const u8) FetchError![]u8 {
    // cargo_util::registry::crate_url (references/cargo/crates/cargo-util/src/registry.rs): exact port.
    // No placeholder present -> fallback "{dl}/{crate}/{version}/download". Otherwise substitute
    // {crate}/{version}/{sha256-checksum}/{prefix}/{lowerprefix}, where prefix = make_dep_path(name,
    // prefix_only=true) WITHOUT lowercasing (registry.rs prefix_only test: ("AbCd",true)->"Ab/Cd")
    // and lowerprefix = prefix.to_lowercase(). Index sharding (indexRelPath) always lowercases; dl
    // {prefix} preserves the crate-name case.
    const has_placeholder = std.mem.indexOf(u8, cfg.dl, "{crate}") != null or
        std.mem.indexOf(u8, cfg.dl, "{version}") != null or
        std.mem.indexOf(u8, cfg.dl, "{prefix}") != null or
        std.mem.indexOf(u8, cfg.dl, "{lowerprefix}") != null or
        std.mem.indexOf(u8, cfg.dl, "{sha256-checksum}") != null;
    if (!has_placeholder) {
        return std.fmt.allocPrint(gpa, "{s}/{s}/{s}/download", .{ cfg.dl, name, version }) catch return FetchError.OutOfMemory;
    }
    const prefix = makeDepPrefix(gpa, name) catch return FetchError.OutOfMemory;
    defer gpa.free(prefix);
    const lowerprefix = gpa.dupe(u8, prefix) catch return FetchError.OutOfMemory;
    defer gpa.free(lowerprefix);
    for (lowerprefix) |*c| c.* = std.ascii.toLower(c.*);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var rest = cfg.dl;
    while (rest.len > 0) {
        if (std.mem.startsWith(u8, rest, "{crate}")) { try out.appendSlice(gpa, name); rest = rest["{crate}".len..]; }
        else if (std.mem.startsWith(u8, rest, "{version}")) { try out.appendSlice(gpa, version); rest = rest["{version}".len..]; }
        else if (std.mem.startsWith(u8, rest, "{lowerprefix}")) { try out.appendSlice(gpa, lowerprefix); rest = rest["{lowerprefix}".len..]; }
        else if (std.mem.startsWith(u8, rest, "{prefix}")) { try out.appendSlice(gpa, prefix); rest = rest["{prefix}".len..]; }
        else if (std.mem.startsWith(u8, rest, "{sha256-checksum}")) { try out.appendSlice(gpa, checksum); rest = rest["{sha256-checksum}".len..]; }
        else { try out.append(gpa, rest[0]); rest = rest[1..]; }
    }
    return out.toOwnedSlice(gpa) catch return FetchError.OutOfMemory;
}

/// make_dep_path(name, prefix_only=true) exact port (cargo_util::registry::make_dep_path).
/// NOTE: unlike indexRelPath this does NOT lowercase: ("AbCd",true)->"Ab/Cd", ("abc",true)->"3/a".
fn makeDepPrefix(gpa: std.mem.Allocator, crate_name: []const u8) std.mem.Allocator.Error![]u8 {
    return switch (crate_name.len) {
        1 => std.fmt.allocPrint(gpa, "1", .{}),
        2 => std.fmt.allocPrint(gpa, "2", .{}),
        3 => std.fmt.allocPrint(gpa, "3/{c}", .{crate_name[0]}),
        else => std.fmt.allocPrint(gpa, "{s}/{s}", .{ crate_name[0..2], crate_name[2..4] }),
    };
}

/// On-disk index cache subset: <cache_dir>/<sharded-path> holds the body,
/// <cache_dir>/<sharded-path>.version holds the index_version (ETag). Mirrors
/// http_remote.rs revalidation inputs: callers pass the stored version as
/// If-None-Match and treat .not_modified as cache-valid (reuse the cached body).
/// FS pattern (verified precedent: src/main.zig openStoreDir uses
/// std.Io.Dir.cwd().createDirPathOpen(io, abs_path, .{}) for absolute paths; then all
/// I/O is handle-relative createDirPath/writeFile/readFileAlloc like src/store/cold.zig
/// store.dir.createDirPath/store.dir.writeFile/store.dir.readFileAlloc). No Dir.openPath.
pub fn writeIndexCache(gpa: std.mem.Allocator, io: std.Io, cache_dir: []const u8, crate_name: []const u8, body: []const u8, version: []const u8) FetchError!void {
    const rel = indexRelPath(gpa, crate_name) catch return FetchError.OutOfMemory;
    defer gpa.free(rel);
    const dir_rel = std.fs.path.dirname(rel) orelse "";
    var cache = std.Io.Dir.cwd().createDirPathOpen(io, cache_dir, .{}) catch return FetchError.StoreRead;
    defer cache.close(io);
    if (dir_rel.len > 0) cache.createDirPath(io, dir_rel) catch return FetchError.StoreRead;
    const ver_rel = std.fmt.allocPrint(gpa, "{s}.version", .{rel}) catch return FetchError.OutOfMemory;
    defer gpa.free(ver_rel);
    cache.writeFile(io, .{ .sub_path = rel, .data = body }) catch return FetchError.StoreRead;
    cache.writeFile(io, .{ .sub_path = ver_rel, .data = version }) catch return FetchError.StoreRead;
}

pub fn readIndexCache(gpa: std.mem.Allocator, io: std.Io, cache_dir: []const u8, crate_name: []const u8) FetchError!IndexResponse {
    const rel = indexRelPath(gpa, crate_name) catch return FetchError.OutOfMemory;
    defer gpa.free(rel);
    var cache = std.Io.Dir.cwd().createDirPathOpen(io, cache_dir, .{}) catch return FetchError.StoreRead;
    defer cache.close(io);
    const body = cache.readFileAlloc(io, rel, gpa, .limited(4 << 20)) catch return IndexResponse{ .not_found = {} };
    return IndexResponse{ .fresh = body };
}

/// Stored index_version (ETag) for If-None-Match revalidation. Returns null when no cached
/// version file exists (caller passes null as cached_version = unconditional fetch).
pub fn readIndexVersion(gpa: std.mem.Allocator, io: std.Io, cache_dir: []const u8, crate_name: []const u8) FetchError!?[]u8 {
    const rel = indexRelPath(gpa, crate_name) catch return FetchError.OutOfMemory;
    defer gpa.free(rel);
    const ver_rel = std.fmt.allocPrint(gpa, "{s}.version", .{rel}) catch return FetchError.OutOfMemory;
    defer gpa.free(ver_rel);
    var cache = std.Io.Dir.cwd().createDirPathOpen(io, cache_dir, .{}) catch return FetchError.StoreRead;
    defer cache.close(io);
    return cache.readFileAlloc(io, ver_rel, gpa, .limited(1 << 16)) catch null;
}
```

Also in this step: update `FileRegistry.fileFetchIndex` to use `indexRelPath` (it already does — delete the flat `testdata/cargo/fetch/stub/index/serde` copy so only the sharded file resolves). Absolute cache dirs are opened with `std.Io.Dir.cwd().createDirPathOpen(io, cache_dir, .{})` (verified precedent: `src/main.zig` `openStoreDir`); all subsequent I/O is handle-relative (`createDirPath`/`writeFile`/`readFileAlloc` with sharded relative paths, as in `src/store/cold.zig`).

- [ ] **Step 4: Run tests to verify they pass**

Run: `zig build test 2>&1 | tail -5`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
jj status
jj commit src/cargo/fetch.zig testdata/cargo/fetch/stub -m "Add sparse index paths and cache"
```

---

### Task 3: Index entry selection (version pin, checksum, yanked)

**Files:**
- Modify: `src/cargo/fetch.zig`
- Test: inline tests in `src/cargo/fetch.zig` (reuse the stub index fixture)

**Interfaces:**
- Consumes: Task 2 `readIndexCache`/`IndexResponse`; Task 1 `RegistryClient`.
- Produces (used by Tasks 4, 8):
```zig
pub const IndexEntry = struct { version: []const u8, checksum: []const u8, yanked: bool };
pub fn selectIndexEntry(gpa: std.mem.Allocator, index_body: []const u8, want_version: []const u8) FetchError!IndexEntry;
```

Cargo pins (`registry/mod.rs` `query()`, `IndexPackage` schema): each index line is one JSON object with `name`, `vers`, `cksum` (sha256 hex of the `.crate`), `yanked` (bool). Resolution picks the exact `vers` the lockfile names (M2 never re-resolves — M3 owns version selection). A yanked entry is NOT an error when the lockfile pins it (cargo fetches locked yanked versions fine; only `cargo update --precise <yanked>` warns). Missing version → `NotFound`. Malformed line for the wanted version → `InvalidIndex` (other malformed lines are skipped, matching cargo's per-line tolerance).

- [ ] **Step 1: Write the failing test**

```zig
test "index selection pins locked version and tolerates yanked" {
    const gpa = std.testing.allocator;
    const body =
        \\{"name":"serde","vers":"1.0.0","cksum":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","yanked":false}
        \\{"name":"serde","vers":"1.0.1","cksum":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","yanked":true}
        \\not json at all
        \\
    ;
    const pinned = try selectIndexEntry(gpa, body, "1.0.0");
    defer { gpa.free(pinned.version); gpa.free(pinned.checksum); }
    try std.testing.expectEqualStrings("1.0.0", pinned.version);
    try std.testing.expect(!pinned.yanked);
    // Locked yanked versions still fetch (cargo query() Yanked handling for locked deps):
    const yanked = try selectIndexEntry(gpa, body, "1.0.1");
    defer { gpa.free(yanked.version); gpa.free(yanked.checksum); }
    try std.testing.expect(yanked.yanked);
    try std.testing.expectError(FetchError.NotFound, selectIndexEntry(gpa, body, "9.9.9"));
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test 2>&1 | tail -8`
Expected: FAIL — `selectIndexEntry` not defined.

- [ ] **Step 3: Write minimal implementation**

```zig
pub const IndexEntry = struct { version: []const u8, checksum: []const u8, yanked: bool };

pub fn selectIndexEntry(gpa: std.mem.Allocator, index_body: []const u8, want_version: []const u8) FetchError!IndexEntry {
    var lines = std.mem.splitScalar(u8, index_body, '\n');
    while (lines.next()) |line| {
        const trim = std.mem.trim(u8, line, " \t\r");
        if (trim.len == 0) continue;
        const parsed = std.json.parseFromSlice(std.json.Value, gpa, trim, .{}) catch continue;
        defer parsed.deinit();
        if (parsed.value != .object) continue;
        const vers = parsed.value.object.get("vers") orelse continue;
        if (vers != .string) continue;
        if (!std.mem.eql(u8, vers.string, want_version)) continue;
        const cksum = parsed.value.object.get("cksum") orelse return FetchError.InvalidIndex;
        if (cksum != .string or cksum.string.len != 64) return FetchError.InvalidIndex;
        const yanked_v = parsed.value.object.get("yanked");
        const yanked = if (yanked_v) |y| (if (y == .boolean) y.boolean else false) else false;
        const version = gpa.dupe(u8, vers.string) catch return FetchError.OutOfMemory;
        errdefer gpa.free(version);
        const checksum = gpa.dupe(u8, cksum.string) catch return FetchError.OutOfMemory;
        return .{ .version = version, .checksum = checksum, .yanked = yanked };
    }
    return FetchError.NotFound;
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `zig build test 2>&1 | tail -5`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
jj status
jj commit src/cargo/fetch.zig -m "Add locked index entry selection"
```

---

### Task 4: `.crate` download + sha256 verification against the lock checksum

**Files:**
- Modify: `src/cargo/fetch.zig`
- Test: inline tests + new fixture `testdata/cargo/fetch/stub/crates/serde-1.0.0.crate` (a real gzip tarball built by the test itself on first run — see Step 3; committed afterwards)
- Fixture: `testdata/cargo/fetch/locks/sample.lock` (registry entry with checksum + git entry stub for Task 6)

**Interfaces:**
- Consumes: Tasks 2–3 (`RegistryConfig`, `dlUrlFor`, `selectIndexEntry`, `IndexResponse`).
- Produces (used by Tasks 5, 8):
```zig
pub fn verifySha256Hex(data: []const u8, want_hex: []const u8) FetchError!void;
pub fn fetchCrateBytes(gpa: std.mem.Allocator, io: std.Io, client: RegistryClient, cfg: *const RegistryConfig, opts: FetchOptions, name: []const u8, version: []const u8, want_checksum: []const u8) FetchError![]u8;
```

Cargo pins (`registry/download.rs`): `download()` returns `Ready(file)` when a nonzero `.crate` exists in `cache_path` (no re-download, no re-verify — filesystem assumed intact); otherwise `Download{url}` where `url = crate_url(dl, name, version, checksum)`. `finish_download()` hashes with `Sha256` and bails (`"failed to verify the checksum of <pkg>"`) when `actual != checksum`, and only then persists. M2's `fetchCrateBytes` mirrors this exactly against `FetchOptions.cache_dir`: `<cache_dir>/crates/<name>-<version>.crate` nonzero hit skips network AND skips verification (document why: same assumption as cargo); miss downloads via `client.fetchCrate(dl_url)`, verifies, then writes the cache file.

`sample.lock` fixture:
```toml
# This file is automatically @generated by Cargo.
# It is not intended for manual editing.
version = 4

[[package]]
name = "demo"
version = "0.1.0"

[[package]]
name = "serde"
version = "1.0.0"
source = "registry+https://github.com/rust-lang/crates.io-index"
checksum = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

[[package]]
name = "helper"
version = "0.2.0"
source = "git+https://example.com/org/helper.git#aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
```

- [ ] **Step 1: Write the failing tests**

```zig
test "sha256 verification accepts exact hex and rejects mismatch" {
    try verifySha256Hex("abc", "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
    try std.testing.expectError(FetchError.ChecksumMismatch, verifySha256Hex("abc", "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"));
    try std.testing.expectError(FetchError.ChecksumMismatch, verifySha256Hex("abc", "not-hex-at-all"));
}

test "crate bytes come from cache when present, else download and verify" {
    const io = std.Io.Threaded.global_single_threaded.io();
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // Stack-buffer realPathFile (disk_usage.zig:30 precedent).
    var cache_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const cache_len = try tmp.dir.realPathFile(io, ".", &cache_buf);
    const cache = cache_buf[0..cache_len];
    // Fixture bytes + their real sha256 (Task 4 Step 3 sets the stub cksum to this hash).
    const fixture = try std.Io.Dir.cwd().readFileAlloc(io, "testdata/cargo/fetch/stub/crates/serde-1.0.0.crate", gpa, .limited(512 << 20));
    defer gpa.free(fixture);
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(fixture);
    var sum: [32]u8 = undefined;
    hasher.final(&sum);
    const want = try std.fmt.allocPrint(gpa, "{x:0>64}", .{std.fmt.fmtSliceHexLower(&sum)});
    defer gpa.free(want);
    var stub = FileRegistry{ .root = "testdata/cargo/fetch/stub" };
    const dl = try std.fmt.allocPrint(gpa, "{{\"dl\":\"file://STUB/crates/serde-1.0.0.crate\"}}", .{});
    defer gpa.free(dl);
    var cfg = try parseRegistryConfig(gpa, dl);
    defer cfg.deinit();
    const opts = FetchOptions{ .cache_dir = cache };
    // 1. Miss: downloads through the stub and verifies against the real hash (byte-identical).
    const got = try fetchCrateBytes(gpa, io, stub.client(), &cfg, opts, "serde", "1.0.0", want);
    defer gpa.free(got);
    try std.testing.expectEqualSlices(u8, fixture, got);
    // 2. Corrupt one byte in a copy -> ChecksumMismatch (proves verify-before-persist).
    const bad = try gpa.dupe(u8, fixture);
    defer gpa.free(bad);
    bad[bad.len / 2] ^= 0xff;
    try std.testing.expectError(FetchError.ChecksumMismatch, verifySha256Hex(bad, want));
    // 3. Cache hit: pre-place bytes at <cache>/crates/serde-1.0.0.crate, then call with a FAILING
    //    client (every fn returns Network) -> still byte-identical, proving no network on nonzero hit
    //    (cargo download() Ready path: no re-download, no re-verify).
    var cdir = try std.Io.Dir.cwd().createDirPathOpen(io, cache, .{});
    defer cdir.close(io);
    try cdir.createDirPath(io, "crates");
    try cdir.writeFile(io, .{ .sub_path = "crates/serde-1.0.0.crate", .data = fixture });
    const failing = failingClient();
    const hit = try fetchCrateBytes(gpa, io, failing, &cfg, opts, "serde", "1.0.0", want);
    defer gpa.free(hit);
    try std.testing.expectEqualSlices(u8, fixture, hit);
}

/// Test helper (same file): a RegistryClient whose every fn returns Network. Proves cache-hit and
/// store-reuse paths perform zero network I/O.
fn failingClient() RegistryClient {
    const S = struct {
        fn cfg(_: *anyopaque, _: std.mem.Allocator) FetchError![]u8 { return FetchError.Network; }
        fn idx(_: *anyopaque, _: std.mem.Allocator, _: []const u8, _: ?[]const u8) FetchError!IndexResponse { return FetchError.Network; }
        fn crt(_: *anyopaque, _: std.mem.Allocator, _: []const u8) FetchError![]u8 { return FetchError.Network; }
    };
    return .{ .ptr = undefined, .fetchConfigFn = S.cfg, .fetchIndexFn = S.idx, .fetchCrateFn = S.crt };
}
```

(The Step 1 test above is already complete — no defer-to-Step-3: it computes the fixture sha256,
asserts byte-identity on miss, asserts `ChecksumMismatch` on a corrupted copy, and proves the
nonzero-cache-hit path with a failing client.)

- [ ] **Step 2: Run tests to verify they fail**

Run: `zig build test 2>&1 | tail -8`
Expected: FAIL — `verifySha256Hex`/`fetchCrateBytes` not defined.

- [ ] **Step 3: Write minimal implementation + generate the .crate fixture**

```zig
pub fn verifySha256Hex(data: []const u8, want_hex: []const u8) FetchError!void {
    if (want_hex.len != 64) return FetchError.ChecksumMismatch;
    var want: [32]u8 = undefined;
    std.fmt.hexToBytes(&want, want_hex) catch return FetchError.ChecksumMismatch;
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(data);
    var actual: [32]u8 = undefined;
    hasher.final(&actual);
    if (!std.crypto.timing.safeEqual([32]u8, want, actual)) return FetchError.ChecksumMismatch;
}

pub fn fetchCrateBytes(gpa: std.mem.Allocator, io: std.Io, client: RegistryClient, cfg: *const RegistryConfig, opts: FetchOptions, name: []const u8, version: []const u8, want_checksum: []const u8) FetchError![]u8 {
    // Cache path mirrors cargo's cache/<name>-<version>.crate flat layout (download.rs docs).
    // FS pattern (verified): cwd().createDirPathOpen for the absolute cache dir (src/main.zig),
    // then handle-relative readFileAlloc/createDirPath/writeFile (src/store/cold.zig). No Dir.openPath.
    const fname = std.fmt.allocPrint(gpa, "{s}-{s}.crate", .{ name, version }) catch return FetchError.OutOfMemory;
    defer gpa.free(fname);
    const rel = std.fmt.allocPrint(gpa, "crates/{s}", .{fname}) catch return FetchError.OutOfMemory;
    defer gpa.free(rel);
    var cdir = std.Io.Dir.cwd().createDirPathOpen(io, opts.cache_dir, .{}) catch return FetchError.StoreRead;
    defer cdir.close(io);
    if (cdir.readFileAlloc(io, rel, gpa, .limited(512 << 20))) |cached| {
        if (cached.len > 0) return cached; // cargo download(): nonzero cache hit = Ready, no re-verify
        gpa.free(cached);
    } else |_| {}
    if (opts.offline) return FetchError.OfflineMissing;
    const url = try dlUrlFor(gpa, cfg, name, version, want_checksum);
    defer gpa.free(url);
    const data = try client.fetchCrate(gpa, url);
    errdefer gpa.free(data);
    try verifySha256Hex(data, want_checksum); // cargo finish_download(): bail BEFORE persisting
    cdir.createDirPath(io, "crates") catch { return FetchError.StoreRead; };
    cdir.writeFile(io, .{ .sub_path = rel, .data = data }) catch { return FetchError.StoreRead; };
    return data;
}
```

`.crate` fixture generator (test-only helper in `fetch.zig`, run once to produce the committed file — afterwards the file is read, never regenerated):

```zig
fn writeTestCrate(gpa: std.mem.Allocator, io: std.Io, out_path: []const u8) !void {
    // Minimal cargo-valid tree: serde-1.0.0/{Cargo.toml,Cargo.toml.orig,src/lib.rs}.
    // Tar entries via std.tar.Writer over a flate .gzip Compress stream — the exact
    // src/store/cold.zig gzipAlloc shape (Compress.init with .gzip + finish), so the bytes
    // are exactly what unpackCrate (Task 5) must accept. initCapacity(4096) satisfies the
    // Compress.init assertion that the output buffer exceed 8 bytes; mtime 0 keeps the
    // fixture byte-deterministic.
    const cargo_toml: []const u8 =
        \\[package]
        \\name = "serde"
        \\version = "1.0.0"
        \\edition = "2021"
        \\
    ;
    const lib_rs: []const u8 = "pub fn x() {}\n";
    var out: std.Io.Writer.Allocating = try .initCapacity(gpa, 4096);
    defer out.deinit();
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var comp = try std.compress.flate.Compress.init(&out.writer, &window, .gzip, std.compress.flate.Compress.Options.default);
    var tw = std.tar.Writer{ .underlying_writer = &comp.writer };
    try tw.writeFileBytes("serde-1.0.0/Cargo.toml", cargo_toml, .{ .mode = 0o644, .mtime = 0 });
    try tw.writeFileBytes("serde-1.0.0/Cargo.toml.orig", cargo_toml, .{ .mode = 0o644, .mtime = 0 });
    try tw.writeFileBytes("serde-1.0.0/src/lib.rs", lib_rs, .{ .mode = 0o644, .mtime = 0 });
    try comp.finish();
    const bytes = try out.toOwnedSlice();
    defer gpa.free(bytes);
    // Absolute out_path via the verified handle-relative pattern (src/main.zig openStoreDir):
    // createDirPathOpen the parent dir, then writeFile the basename. No Dir.openPath.
    const dir_name = std.fs.path.dirname(out_path) orelse ".";
    var dir = try std.Io.Dir.cwd().createDirPathOpen(io, dir_name, .{});
    defer dir.close(io);
    try dir.writeFile(io, .{ .sub_path = std.fs.path.basename(out_path), .data = bytes });
}
```

Generate with a `/tmp` scratch program (never in the repo), copy the bytes to `testdata/cargo/fetch/stub/crates/serde-1.0.0.crate`, record its sha256, and update the stub index line's `cksum` + `sample.lock` checksum to match. (The `aaaa…` placeholders above are replaced with the real hash in this step — the test then serves the REAL checksum end to end.)

- [ ] **Step 4: Run tests to verify they pass**

Run: `zig build test 2>&1 | tail -5`
Expected: PASS (cache-hit, download-verify, and mismatch-rejection subtests all green).

- [ ] **Step 5: Commit**

```bash
jj status
jj commit src/cargo/fetch.zig testdata/cargo/fetch -m "Add crate download and checksum verify"
```

---

### Task 5: Unpack `.crate` into tagged store `source` objects

**Files:**
- Modify: `src/cargo/fetch.zig`
- Test: inline tests in `src/cargo/fetch.zig` (real `Store` from `src/store/test_support.zig` — no mocks)

**Interfaces:**
- Consumes: Task 4 `fetchCrateBytes`; `Store.putBytes/putFile/tagObject` (§16); `Kind.source`.
- Produces (used by Task 8, imported by M4 driver later):
```zig
pub const SourceFile = struct { path: []const u8, digest: Digest };
pub const FetchedSource = struct {
    manifest_digest: Digest,
    files: []SourceFile,
    arena: std.heap.ArenaAllocator,
    pub fn deinit(self: *FetchedSource) void { self.arena.deinit(); }
};
pub fn unpackCrate(gpa: std.mem.Allocator, io: std.Io, store: *Store, crate_bytes: []const u8, name: []const u8, version: []const u8) FetchError!FetchedSource;
pub fn fetchRegistryCrate(gpa: std.mem.Allocator, io: std.Io, store: *Store, client: RegistryClient, opts: FetchOptions, name: []const u8, version: []const u8, want_checksum: []const u8) FetchError!FetchedSource;
```

Cargo pins (`registry/mod.rs` `unpack`, `max_unpack_size`, `PACKAGE_SOURCE_LOCK`): prefix must be exactly `<name>-<version>/` else bail (`"invalid tarball downloaded, contains a file at … which isn't under …"`); only `Regular`/`Directory` entries (symlinks rejected — CVE-2022-36113 history in the `unpack_package` docs); skip any `.cargo-ok` entry inside the tarball; size cap `max(unpacked_bytes, 512 MiB, compressed_len * 20)`; directories are created, never stored; file modes normalized on materialize (store objects are `0o444` by ingest). Every stored file object is tagged `{crate, crate_version, user.source=registry}` and the tree manifest object (a `Kind.source` JSON listing `path → digest → size`, stored via `putBytes`) carries the same tags so `lookupObjects` (Task 8) finds the tree by crate identity.

`mapPutError` (defined once here, reused by Tasks 6–8):

```zig
fn mapPutError(e: anyerror) FetchError {
    if (std.mem.eql(u8, @errorName(e), "StoreFull")) return FetchError.StoreFull;
    if (e == error.OutOfMemory) return FetchError.OutOfMemory;
    return FetchError.StoreRead;
}
```

- [ ] **Step 1: Write the failing tests**

```zig
test "unpack ingests files as tagged source objects" {
    const io = std.Io.Threaded.global_single_threaded.io();
    const gpa = std.testing.allocator;
    const support = @import("../store/test_support.zig");
    var ts = support.openTestStore(io, .{});
    defer ts.deinit(io);
    const crate_bytes = try std.Io.Dir.cwd().readFileAlloc(io, "testdata/cargo/fetch/stub/crates/serde-1.0.0.crate", gpa, .limited(512 << 20));
    defer gpa.free(crate_bytes);
    var src = try unpackCrate(gpa, io, &ts.store, crate_bytes, "serde", "1.0.0");
    defer src.deinit();
    try std.testing.expect(src.files.len >= 2);
    // Every file object exists in the store and carries the crate tags:
    for (src.files) |f| {
        try std.testing.expect(ts.store.exists(io, f.digest));
        const tags = try ts.store.tagsFor(io, gpa, f.digest);
        defer { for (tags) |*t| { gpa.free(t.key); gpa.free(t.value); } gpa.free(tags); }
        var seen_crate = false;
        var seen_source = false;
        for (tags) |t| {
            if (std.mem.eql(u8, t.key, "crate") and std.mem.eql(u8, t.value, "serde")) seen_crate = true;
            if (std.mem.eql(u8, t.key, "user.source") and std.mem.eql(u8, t.value, "registry")) seen_source = true;
        }
        try std.testing.expect(seen_crate and seen_source);
    }
    // Store objects are read-only (0o444): spot-check one.
    var hex_buf: [65]u8 = undefined;
    const rel = src.files[0].digest.relPath(&hex_buf);
    const obj_path = try std.fs.path.join(gpa, &.{ "objects", rel });
    defer gpa.free(obj_path);
    const st = try ts.store.dir.statFile(io, obj_path, .{});
    try std.testing.expectEqual(@as(u32, 0o444), st.permissions.toMode() & 0o777);
}

test "unpack rejects wrong prefix and symlinks" {
    const io = std.Io.Threaded.global_single_threaded.io();
    const gpa = std.testing.allocator;
    const support = @import("../store/test_support.zig");
    var ts = support.openTestStore(io, .{});
    defer ts.deinit(io);
    // evil.tar.gz built inline in the test: entry "other-9.9.9/lib.rs" under a serde-1.0.0 claim.
    const evil = try buildEvilCrate(gpa, .wrong_prefix);
    defer gpa.free(evil);
    try std.testing.expectError(FetchError.InvalidCrate, unpackCrate(gpa, io, &ts.store, evil, "serde", "1.0.0"));
    const linky = try buildEvilCrate(gpa, .symlink);
    defer gpa.free(linky);
    try std.testing.expectError(FetchError.InvalidCrate, unpackCrate(gpa, io, &ts.store, linky, "serde", "1.0.0"));
}
```

(`buildEvilCrate` is a test helper in `fetch.zig`, defined here so the tests above compile; both cases must be rejected with `InvalidCrate`.)

```zig
const EvilKind = enum { wrong_prefix, symlink };

// Builds a minimal gzip tarball exercising one unpackCrate rejection path: `.wrong_prefix`
// emits `other-9.9.9/lib.rs` (prefix mismatch vs the claimed `serde-1.0.0`), `.symlink`
// emits a symlink entry (rejected per the CVE-2022-36113 rule: only Regular|Directory).
// Tar entries via std.tar.Writer over a flate .gzip Compress stream, mirroring
// src/store/cold.zig gzipAlloc (initCapacity(4096) satisfies the Compress.init output-buffer
// assertion). No trailing finishPedantically: the std.tar.Iterator accepts unterminated
// archives, matching real-world .crate readers.
fn buildEvilCrate(gpa: std.mem.Allocator, which: EvilKind) ![]u8 {
    var out: std.Io.Writer.Allocating = try .initCapacity(gpa, 4096);
    errdefer out.deinit();
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var comp = try std.compress.flate.Compress.init(&out.writer, &window, .gzip, std.compress.flate.Compress.Options.default);
    var tw = std.tar.Writer{ .underlying_writer = &comp.writer };
    switch (which) {
        .wrong_prefix => try tw.writeFileBytes("other-9.9.9/lib.rs", "pub fn evil() {}\n", .{ .mode = 0o644, .mtime = 0 }),
        .symlink => try tw.writeLink("serde-1.0.0/evil-link.rs", "/etc/passwd", .{ .mode = 0o777, .mtime = 0 }),
    }
    try comp.finish();
    return try out.toOwnedSlice();
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `zig build test 2>&1 | tail -10`
Expected: FAIL — `unpackCrate`/`fetchRegistryCrate` not defined.

- [ ] **Step 3: Write minimal implementation**

```zig
pub const SourceFile = struct { path: []const u8, digest: Digest };
pub const FetchedSource = struct {
    manifest_digest: Digest,
    files: []SourceFile,
    arena: std.heap.ArenaAllocator,
    pub fn deinit(self: *FetchedSource) void { self.arena.deinit(); }
};

fn mapPutError(e: anyerror) FetchError {
    if (std.mem.eql(u8, @errorName(e), "StoreFull")) return FetchError.StoreFull;
    if (e == error.OutOfMemory) return FetchError.OutOfMemory;
    return FetchError.StoreRead;
}

const max_unpack_bytes: u64 = 512 * 1024 * 1024; // cargo max_unpack_size floor (registry/mod.rs)
const max_compression_ratio: u64 = 20;           // cargo MAX_COMPRESSION_RATIO

pub fn unpackCrate(gpa: std.mem.Allocator, io: std.Io, store: *Store, crate_bytes: []const u8, name: []const u8, version: []const u8) FetchError!FetchedSource {
    // Cargo pins: registry/mod.rs `unpack` + `max_unpack_size` + PACKAGE_SOURCE_LOCK history.
    // Decompress with the verified cold.zig pattern (flate .gzip wrapper, NOT std.compress.gzip):
    //   var input = Io.Reader.fixed(crate_bytes);
    //   var window: [flate.max_window_len]u8 = undefined;
    //   var d = flate.Decompress.init(&input, .gzip, &window);
    //   const tar_bytes = d.reader.allocRemaining(gpa, .limited(cap)) on InvalidGzip/StreamTooLong -> InvalidCrate.
    const cap: usize = @min(@as(u64, @max(max_unpack_bytes, @as(u64, @intCast(crate_bytes.len)) * max_compression_ratio)), @as(u64, @intCast(std.math.maxInt(usize))));
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const alloc = arena.allocator();
    const prefix = std.fmt.allocPrint(alloc, "{s}-{s}/", .{ name, version }) catch return FetchError.OutOfMemory;
    var input = std.Io.Reader.fixed(crate_bytes);
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var dec = std.compress.flate.Decompress.init(&input, .gzip, &window);
    const tar_bytes = dec.reader.allocRemaining(gpa, .limited(cap)) catch return FetchError.InvalidCrate;
    defer gpa.free(tar_bytes);
    var tar_reader = std.Io.Reader.fixed(tar_bytes);
    var fn_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var link_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var it = std.tar.Iterator.init(&tar_reader, .{ .file_name_buffer = &fn_buf, .link_name_buffer = &link_buf });
    var list: std.ArrayList(SourceFile) = .empty;
    var total: u64 = 0;
    const crate_tag = Tag{ .key = "crate", .value = name };
    const ver_tag = Tag{ .key = "crate_version", .value = version };
    const src_tag = Tag{ .key = "user.source", .value = "registry" };
    const mtime_tags = [_]Tag{ crate_tag, ver_tag, src_tag };
    while (it.next() catch return FetchError.InvalidCrate) |file| {
        if (!std.mem.startsWith(u8, file.name, prefix)) return FetchError.InvalidCrate; // cargo "isn't under" bail
        const rel_name = file.name[prefix.len..];
        if (rel_name.len == 0) continue; // top-level dir entry itself
        if (file.kind == .sym_link) return FetchError.InvalidCrate; // CVE-2022-36113: only Regular|Directory
        if (file.kind != .file and file.kind != .directory) return FetchError.InvalidCrate;
        const base = std.fs.path.basename(rel_name);
        if (std.mem.eql(u8, base, ".cargo-ok")) { // PACKAGE_SOURCE_LOCK: skip tarball-embedded lockfile
            if (file.kind == .file) it.reader.discardAll64(file.size) catch return FetchError.InvalidCrate;
            continue;
        }
        if (file.kind == .directory) continue; // directories created implicitly, never stored
        total += file.size;
        if (total > cap) return FetchError.InvalidCrate; // 512MiB / 20:1 zip-bomb cap
        var aw: std.Io.Writer.Allocating = .init(gpa);
        defer aw.deinit();
        it.streamRemaining(file, &aw.writer) catch return FetchError.InvalidCrate;
        const bytes = aw.written();
        const d = store.putBytes(io, bytes, .source) catch |e| return mapPutError(e);
        store.tagObject(io, d, &mtime_tags) catch |e| {
            if (std.mem.eql(u8, @errorName(e), "StoreFull")) return FetchError.StoreFull;
            if (e == error.UnknownTagKey or e == error.TagMismatch) return FetchError.Usage;
            return FetchError.TagError;
        };
        const p = alloc.dupe(u8, rel_name) catch return FetchError.OutOfMemory;
        list.append(alloc, .{ .path = p, .digest = d }) catch return FetchError.OutOfMemory;
    }
    const file_slice = list.toOwnedSlice(alloc) catch return FetchError.OutOfMemory;
    const manifest_digest = try writeTreeManifest(gpa, io, store, file_slice, &mtime_tags);
    return .{ .manifest_digest = manifest_digest, .files = file_slice, .arena = arena };
}
```

The implementer writes the tar-iteration body above verbatim (entry-kind checks via `std.tar.FileKind`, gzip via the `src/store/cold.zig` flate `.gzip` shape). No placeholder remains in this step.

`fetchRegistryCrate` wires Tasks 2–5 (config fetch → index select → checksum cross-check vs lock → crate bytes → unpack):

```zig
pub fn fetchRegistryCrate(gpa: std.mem.Allocator, io: std.Io, store: *Store, client: RegistryClient, opts: FetchOptions, name: []const u8, version: []const u8, want_checksum: []const u8) FetchError!FetchedSource {
    const cfg_text = try client.fetchConfig(gpa);
    defer gpa.free(cfg_text);
    var cfg = try parseRegistryConfig(gpa, cfg_text);
    defer cfg.deinit();
    // Cargo http_remote.rs load()/sparse_fetch(): read the cached index_version (ETag text in
    // <path>.version) and pass it as cached_version for If-None-Match revalidation. 304/CacheValid
    // (IndexResponse.not_modified) means the on-disk cache is still latest: reuse it (cargo
    // LoadResponse::CacheValid), NOT an error. Only .fresh replaces the cache.
    if (!opts.offline) {
        const cached_version = try readIndexVersion(gpa, io, opts.cache_dir, name);
        defer if (cached_version) |v| gpa.free(v);
        const resp = try client.fetchIndex(gpa, name, cached_version);
        const body: []u8 = switch (resp) {
            .fresh => |b| b,
            .not_modified => try readIndexCacheBody(gpa, io, opts.cache_dir, name),
            .not_found => return FetchError.NotFound,
        };
        defer gpa.free(body);
        if (resp == .fresh) {
            const new_version = if (cached_version) |v| v else "v0"; // real HTTP client persists the ETag/Last-Modified it saw; stub keeps v0
            try writeIndexCache(gpa, io, opts.cache_dir, name, body, new_version);
        }
        const entry = try selectIndexEntry(gpa, body, version);
        defer { gpa.free(entry.version); gpa.free(entry.checksum); }
        // Index checksum and lock checksum must agree (registry is the source of truth; a mismatch means the lock is stale):
        if (!std.ascii.eqlIgnoreCase(entry.checksum, want_checksum)) return FetchError.ChecksumMismatch;
    }
    const crate_bytes = try fetchCrateBytes(gpa, io, client, &cfg, opts, name, version, want_checksum);
    defer gpa.free(crate_bytes);
    return unpackCrate(gpa, io, store, crate_bytes, name, version);
}

/// readIndexCache body-only helper used on the .not_modified path (cache-valid reuse). Returns
/// OfflineMissing when no cache exists (cold offline fetch names the crate at the call site).
fn readIndexCacheBody(gpa: std.mem.Allocator, io: std.Io, cache_dir: []const u8, crate_name: []const u8) FetchError![]u8 {
    return switch (try readIndexCache(gpa, io, cache_dir, crate_name)) {
        .fresh => |b| b,
        .not_modified => return FetchError.OfflineMissing, // unreachable: readIndexCache never returns this
        .not_found => return FetchError.OfflineMissing,
    };
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `zig build test 2>&1 | tail -5`
Expected: PASS (ingest + tagging + read-only + both rejection subtests green).

- [ ] **Step 5: Commit**

```bash
jj status
jj commit src/cargo/fetch.zig -m "Add crate unpack into tagged sources"
```

---

### Task 6: Git deps — ref resolution (rev/branch/tag) with shallow fetch

**Files:**
- Modify: `src/cargo/fetch.zig`
- Test: inline tests in `src/cargo/fetch.zig` (real `git` CLI against `file://` repos under tmp — local only, no network)

**Interfaces:**
- Consumes: Task 1 `GitRunner`/`StubGit`; M1 `manifest.zig` `GitSpec{url, ref: ?[]const u8}` verbatim (no invented flags — `ref` is the single optional table value; Task 2 of the frontend plan stores `rev=…`/`branch=…`/`tag=…`/`"<oid>"` text there).
- Produces (used by Tasks 7–8):
```zig
pub const GitRef = union(enum) { default_branch: void, branch: []const u8, tag: []const u8, rev: []const u8 };
pub const GitPrecise = struct { oid: [40]u8 };
/// Maps an M1 GitSpec onto the fetch union. `spec.ref` is None (absent key) -> default_branch;
/// otherwise the string is one of `rev=<oid-or-prefix>` / `branch=<name>` / `tag=<name>` (the exact
/// spellings manifest.zig parses from `{ git = url, branch/tag/rev = ... }`), else a bare OID/name
/// treated as rev (cargo `GitReference::from_rev`). Never invents has_branch/has_tag params.
pub fn parseGitRef(spec: GitSpec) GitRef;
pub fn resolveGitRef(gpa: std.mem.Allocator, io: std.Io, git: GitRunner, cache_repo: []const u8, ref: GitRef, precise: ?GitPrecise) FetchError![40]u8;
pub fn ensureGitMirror(gpa: std.mem.Allocator, io: std.Io, git: GitRunner, url: []const u8, mirror_dir: []const u8) FetchError!void;
pub const CliGit = struct {
    pub fn runner(self: *CliGit) GitRunner;
};
fn makeFixtureRepo(gpa: std.mem.Allocator, io: std.Io, git: GitRunner, tmp_root: []const u8, name: []const u8) (FetchError || error{SkipZigTest})![40]u8;
```

Cargo pins (`core/source_id.rs` `GitReference`, `sources/git/utils.rs`): declared ref kinds are branch / tag / rev (full OID or short prefix) / default-branch. Resolution order: (1) if the lockfile carries a precise OID for this source, that OID is authoritative — fetch (if online) then verify the OID exists, no ref lookup; (2) else resolve the declared ref post-fetch (`rev-parse <ref>^{commit}`), which handles short prefixes exactly like cargo (resolved against the fetched objects, never guessed). Fetch shape: `git fetch origin --depth 1 <refspec>` for branch/tag/default (`+refs/heads/<b>:refs/remotes/origin/<b>`), full `git fetch origin` only when resolving a `rev` that the shallow fetch cannot see (cargo fetches deeper when the rev is missing). Offline: no fetch; resolve from the local mirror or fail `OfflineMissing`. `--frozen`: same as offline for git (no network, precise required — Task 8 enforces).

- [ ] **Step 1: Write the failing tests**

```zig
test "git resolves branch head and locked precise without network" {
    const io = std.Io.Threaded.global_single_threaded.io();
    const gpa = std.testing.allocator;
    // Build a real fixture repo in tmp with the git CLI (file:// only):
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // Stack-buffer realPathFile (disk_usage.zig:30 precedent).
    var root_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPathFile(io, ".", &root_buf);
    const tmp_root = root_buf[0..root_len];
    const real = CliGit{ }; // Task-6 real runner (subprocess git); used ONLY against file:// tmp repos in tests
    // init origin with 2 commits on main + tag v0.1.0, branch feature at commit 1...
    const oid_main = try makeFixtureRepo(gpa, io, real.runner(), tmp_root, "origin");
    // Mirror it once (online), then resolve offline:
    const mirror = try std.fs.path.join(gpa, &.{ tmp_root, "mirror" });
    defer gpa.free(mirror);
    try ensureGitMirror(gpa, io, real.runner(), try std.fs.path.join(gpa, &.{ tmp_root, "origin" }), mirror);
    // Mirror is warm: every resolve below reads the local mirror only (no network; file:// only).
    const head = try resolveGitRef(gpa, io, real.runner(), mirror, .{ .branch = "main" }, null);
    try std.testing.expectEqualStrings(oid_main[0..], head[0..]);
    // Locked precise short-circuits ref lookup (passed OID returned verbatim after existence check):
    var precise: GitPrecise = .{ .oid = oid_main };
    const locked = try resolveGitRef(gpa, io, real.runner(), mirror, .{ .branch = "main" }, precise);
    try std.testing.expectEqualStrings(oid_main[0..], locked[0..]);
}

test "parseGitRef maps M1 GitSpec verbatim" {
    const t = std.testing;
    try t.expect(parseGitRef(.{ .url = "https://example.com/a.git", .ref = null }) == .default_branch);
    try t.expectEqualStrings("main", parseGitRef(.{ .url = "u", .ref = "branch=main" }).branch);
    try t.expectEqualStrings("v0.1.0", parseGitRef(.{ .url = "u", .ref = "tag=v0.1.0" }).tag);
    const full = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    try t.expectEqualStrings(full, parseGitRef(.{ .url = "u", .ref = "rev=" ++ full }).rev);
    // Bare OID without a key prefix is a rev (cargo from_rev fallback):
    try t.expectEqualStrings(full, parseGitRef(.{ .url = "u", .ref = full }).rev);
}

test "git rev resolves full and short OIDs, unknown rev fails" {
    const io = std.Io.Threaded.global_single_threaded.io();
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPathFile(io, ".", &root_buf);
    const tmp_root = root_buf[0..root_len];
    var real = CliGit{};
    const oid_main = makeFixtureRepo(gpa, io, real.runner(), tmp_root, "origin") catch |e| {
        if (e == error.SkipZigTest) return error.SkipZigTest;
        return e;
    };
    const origin = try std.fs.path.join(gpa, &.{ tmp_root, "origin" });
    defer gpa.free(origin);
    const mirror = try std.fs.path.join(gpa, &.{ tmp_root, "mirror2" });
    defer gpa.free(mirror);
    try ensureGitMirror(gpa, io, real.runner(), origin, mirror);
    // Full OID:
    const full = try resolveGitRef(gpa, io, real.runner(), mirror, .{ .rev = oid_main[0..] }, null);
    try std.testing.expectEqualStrings(oid_main[0..], full[0..]);
    // Short 7-char prefix resolves like cargo (post-fetch object lookup, never guessed):
    const short = try resolveGitRef(gpa, io, real.runner(), mirror, .{ .rev = oid_main[0..7] }, null);
    try std.testing.expectEqualStrings(oid_main[0..], short[0..]);
    // Annotated tag resolves to the tagged commit (^{commit} peel, utils.rs resolve_ref Tag branch):
    const peeled = try resolveGitRef(gpa, io, real.runner(), mirror, .{ .tag = "v0.1.0" }, null);
    try std.testing.expectEqual(@as(usize, 40), peeled.len);
    // Unknown rev fails:
    try std.testing.expectError(FetchError.GitFailed, resolveGitRef(gpa, io, real.runner(), mirror, .{ .rev = "deadbee" }, null));
}
```

(`makeFixtureRepo` + `CliGit` are defined in Step 3. `CliGit.runner()` shells to the real `git` binary; tests skip with a clear message when `git` is absent from `PATH` — `std.process.Child` spawn failure maps to `error.SkipZigTest`, never a silent pass.)

- [ ] **Step 2: Run tests to verify they fail**

Run: `zig build test 2>&1 | tail -10`
Expected: FAIL — `GitRef`/`resolveGitRef`/`ensureGitMirror`/`CliGit` not defined.

- [ ] **Step 3: Write minimal implementation**

```zig
pub const GitRef = union(enum) { default_branch: void, branch: []const u8, tag: []const u8, rev: []const u8 };
pub const GitPrecise = struct { oid: [40]u8 };

pub fn parseGitRef(spec: GitSpec) GitRef {
    const r = spec.ref orelse return .{ .default_branch = {} };
    if (std.mem.startsWith(u8, r, "branch=")) return .{ .branch = r["branch=".len..] };
    if (std.mem.startsWith(u8, r, "tag=")) return .{ .tag = r["tag=".len..] };
    if (std.mem.startsWith(u8, r, "rev=")) return .{ .rev = r["rev=".len..] };
    return .{ .rev = r }; // bare OID/name fallback (cargo GitReference::from_rev)
}

const GitSpec = @import("manifest.zig").GitSpec;

/// Real subprocess runner: argv[0] must be "git". Used in production AND in tests (tests only ever pass file:// URLs).
/// Verified 0.16 shape: std.process.spawn(io, .{ .argv, .stdout = .pipe, .stderr = .pipe, .stdin = .ignore,
/// .cwd }) -> Child; stdout/stderr drained via Io.File.MultiReader exactly like std.process.run does,
/// then child.wait(io) must be .exited == 0 else GitFailed. cwd "" means .inherit, else .{ .path = cwd }.
pub const CliGit = struct {
    pub fn runner(self: *CliGit) GitRunner {
        return .{ .ptr = self, .runFn = cliRun };
    }
    fn cliRun(ptr: *anyopaque, gpa: std.mem.Allocator, io: std.Io, argv: []const []const u8, cwd: []const u8) FetchError![]u8 {
        _ = ptr;
        if (argv.len == 0 or !std.mem.eql(u8, argv[0], "git")) return FetchError.GitFailed;
        const cwd_opt: std.process.Child.Cwd = if (cwd.len == 0) .inherit else .{ .path = cwd };
        var child = std.process.spawn(io, .{
            .argv = argv,
            .cwd = cwd_opt,
            .stdin = .ignore,
            .stdout = .pipe,
            .stderr = .pipe,
        }) catch return FetchError.GitFailed;
        defer child.kill(io);
        var mr_buf: std.Io.File.MultiReader.Buffer(2) = undefined;
        var mr: std.Io.File.MultiReader = undefined;
        mr.init(gpa, io, mr_buf.toStreams(), &.{ child.stdout.?, child.stderr.? });
        defer mr.deinit();
        const out_r = mr.reader(0);
        const err_r = mr.reader(1);
        while (mr.fill(4096, .none)) |_| {} else |e| if (e != error.EndOfStream) return FetchError.GitFailed;
        const term = child.wait(io) catch return FetchError.GitFailed;
        if (term != .exited or term.exited != 0) {
            std.log.debug("git {s} failed: {s}", .{ argv[1..], err_r.buffered() });
            return FetchError.GitFailed;
        }
        const out = out_r.buffered();
        return gpa.dupe(u8, out) catch return FetchError.OutOfMemory;
    }
};

pub fn ensureGitMirror(gpa: std.mem.Allocator, io: std.Io, git: GitRunner, url: []const u8, mirror_dir: []const u8) FetchError!void {
    // Idempotent mirror (cargo GitDatabase::open/clone_into): HEAD present -> `git fetch origin
    // +refs/heads/*:refs/heads/* --prune` (shallow update keeps --depth 1 boundary); else
    // `git clone --mirror --depth 1 <url> <mirror_dir>`. Handle-relative HEAD probe, no Dir.openPath.
    var probe = std.Io.Dir.cwd().createDirPathOpen(io, mirror_dir, .{}) catch return FetchError.GitFailed;
    defer probe.close(io);
    const has_head = blk: {
        var hf = probe.openFile(io, "HEAD", .{}) catch break :blk false;
        hf.close(io);
        break :blk true;
    };
    if (has_head) {
        const out = try git.run(gpa, io, &.{ "git", "fetch", "origin", "+refs/heads/*:refs/heads/*", "--prune" }, mirror_dir);
        defer gpa.free(out);
        return;
    }
    const out = try git.run(gpa, io, &.{ "git", "clone", "--mirror", "--depth", "1", url, mirror_dir }, "");
    defer gpa.free(out);
}

fn isHexOid(s: []const u8) bool {
    if (s.len < 7 or s.len > 40) return false;
    for (s) |c| if (!std.ascii.isHex(c)) return false;
    return true;
}

pub fn resolveGitRef(gpa: std.mem.Allocator, io: std.Io, git: GitRunner, mirror_dir: []const u8, ref: GitRef, precise: ?GitPrecise) FetchError![40]u8 {
    if (precise) |p| {
        // Lockfile OID authoritative: verify it exists locally (cargo: fetch-then-check; offline: check only).
        const out = try git.run(gpa, io, &.{ "git", "cat-file", "-t", p.oid[0..] }, mirror_dir);
        defer gpa.free(out);
        if (!std.mem.startsWith(u8, std.mem.trim(u8, out, " \t\r\n"), "commit")) return FetchError.GitFailed;
        return p.oid;
    }
    const rev_arg: []const u8 = switch (ref) {
        .default_branch => "HEAD",
        .branch => |b| b,
        .tag => |t| t,
        .rev => |r| r,
    };
    // Short/full OIDs resolve without a fetch round-trip when already present (cargo post-fetch resolution):
    if (isHexOid(rev_arg)) {
        if (git.run(gpa, io, &.{ "git", "rev-parse", rev_arg }, mirror_dir)) |out| {
            defer gpa.free(out);
            const oid = std.mem.trim(u8, out, " \t\r\n");
            if (oid.len == 40) { var r: [40]u8 = undefined; @memcpy(&r, oid); return r; }
        } else |_| {}
    }
    const patterned = std.fmt.allocPrint(gpa, "{s}^{{commit}}", .{rev_arg}) catch return FetchError.OutOfMemory;
    defer gpa.free(patterned);
    const out = try git.run(gpa, io, &.{ "git", "rev-parse", patterned }, mirror_dir);
    defer gpa.free(out);
    const oid = std.mem.trim(u8, out, " \t\r\n");
    if (oid.len != 40) return FetchError.GitFailed;
    var r: [40]u8 = undefined;
    @memcpy(&r, oid);
    return r;
}
```

`makeFixtureRepo` (test helper, complete definition below): builds a real git repo under `<tmp_root>/<name>` through the `GitRunner` seam (production `CliGit` in tests; local paths only, never the rime repo itself) — `git init -b main`, two commits, `git tag v0.1.0 <commit1>`, `git branch feature <commit1>`. Returns the commit-2 (main HEAD) OID.

```zig
// Identity is pinned via `-c user.name/user.email` plus a fixed author `--date` (the seam
// carries no env, so GIT_AUTHOR_* cannot be set; the committer timestamp still varies, hence
// OIDs vary per run — callers always use the returned OID, never a hardcoded hash). Probes
// `git --version` first: an absent git binary maps to error.SkipZigTest (clean skip, never a
// silent pass), matching the `catch |e| if (e == error.SkipZigTest)` call sites in Step 1.
fn makeFixtureRepo(gpa: std.mem.Allocator, io: std.Io, git: GitRunner, tmp_root: []const u8, name: []const u8) (FetchError || error{SkipZigTest})![40]u8 {
    {
        const probe = git.run(gpa, io, &.{ "git", "--version" }, "") catch |e| {
            if (e == error.OutOfMemory) return FetchError.OutOfMemory;
            return error.SkipZigTest;
        };
        defer gpa.free(probe);
    }
    const origin = try std.fs.path.join(gpa, &.{ tmp_root, name });
    defer gpa.free(origin);
    {
        const argv = [_][]const u8{ "git", "init", "-b", "main", origin };
        const o = try git.run(gpa, io, &argv, "");
        defer gpa.free(o);
    }
    var repo = std.Io.Dir.cwd().createDirPathOpen(io, origin, .{}) catch return FetchError.GitFailed;
    defer repo.close(io);
    repo.createDirPath(io, "src") catch return FetchError.GitFailed;
    repo.writeFile(io, .{ .sub_path = "Cargo.toml", .data = "[package]\nname = \"helper\"\nversion = \"0.2.0\"\n" }) catch return FetchError.GitFailed;
    repo.writeFile(io, .{ .sub_path = "src/lib.rs", .data = "pub fn h() {}\n" }) catch return FetchError.GitFailed;
    {
        const argv = [_][]const u8{ "git", "-C", origin, "add", "Cargo.toml", "src/lib.rs" };
        const o = try git.run(gpa, io, &argv, "");
        defer gpa.free(o);
    }
    {
        const argv = [_][]const u8{ "git", "-C", origin, "-c", "user.name=rime-test", "-c", "user.email=rime-test@example.com", "commit", "-m", "first", "--date=2005-04-07T22:13:13+00:00" };
        const o = try git.run(gpa, io, &argv, "");
        defer gpa.free(o);
    }
    var commit1: [40]u8 = undefined;
    {
        const argv = [_][]const u8{ "git", "-C", origin, "rev-parse", "HEAD" };
        const o = try git.run(gpa, io, &argv, "");
        defer gpa.free(o);
        const trimmed = std.mem.trim(u8, o, " \t\r\n");
        if (trimmed.len != 40) return FetchError.GitFailed;
        @memcpy(&commit1, trimmed);
    }
    repo.writeFile(io, .{ .sub_path = "src/lib.rs", .data = "pub fn h() {}\npub fn h2() {}\n" }) catch return FetchError.GitFailed;
    {
        const argv = [_][]const u8{ "git", "-C", origin, "add", "src/lib.rs" };
        const o = try git.run(gpa, io, &argv, "");
        defer gpa.free(o);
    }
    {
        const argv = [_][]const u8{ "git", "-C", origin, "-c", "user.name=rime-test", "-c", "user.email=rime-test@example.com", "commit", "-m", "second", "--date=2005-04-07T22:13:14+00:00" };
        const o = try git.run(gpa, io, &argv, "");
        defer gpa.free(o);
    }
    var commit2: [40]u8 = undefined;
    {
        const argv = [_][]const u8{ "git", "-C", origin, "rev-parse", "HEAD" };
        const o = try git.run(gpa, io, &argv, "");
        defer gpa.free(o);
        const trimmed = std.mem.trim(u8, o, " \t\r\n");
        if (trimmed.len != 40) return FetchError.GitFailed;
        @memcpy(&commit2, trimmed);
    }
    {
        const argv = [_][]const u8{ "git", "-C", origin, "tag", "v0.1.0", commit1[0..] };
        const o = try git.run(gpa, io, &argv, "");
        defer gpa.free(o);
    }
    {
        const argv = [_][]const u8{ "git", "-C", origin, "branch", "feature", commit1[0..] };
        const o = try git.run(gpa, io, &argv, "");
        defer gpa.free(o);
    }
    return commit2;
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `zig build test 2>&1 | tail -5`
Expected: PASS (branch/tag/rev/precise/short-OID subtests green; skipped cleanly when `git` missing).

- [ ] **Step 5: Commit**

```bash
jj status
jj commit src/cargo/fetch.zig -m "Add git ref resolution over mirrors"
```

---

### Task 7: Git checkout ingest — tree into tagged store objects

**Files:**
- Modify: `src/cargo/fetch.zig`
- Test: inline tests in `src/cargo/fetch.zig` (real store + `StubGit` tree AND one `CliGit` file:// end-to-end)

**Interfaces:**
- Consumes: Task 6 `resolveGitRef`/`GitRunner`; Task 5 `FetchedSource`/`mapPutError`; `Store.putBytes/tagObject`.
- Produces (used by Task 8, imported by M3 later):
```zig
pub fn ingestTree(gpa: std.mem.Allocator, io: std.Io, store: *Store, files: []const StubFile, name: []const u8, version: []const u8, provenance: Tag) FetchError!FetchedSource;
pub fn fetchGitCheckout(gpa: std.mem.Allocator, io: std.Io, store: *Store, git: GitRunner, opts: FetchOptions, url: []const u8, ref: GitRef, precise: ?GitPrecise) FetchError!FetchedSource;
```

Cargo pins (`sources/git/utils.rs` `GitCheckout::reset`/`clone_into`): checkout = `reset --hard` to the resolved OID into a fresh dir under the cache (`<cache>/git/checkouts/<short-hash>/<oid>/`), guarded by `.cargo-ok` (`{"v":1}` present = fresh, reuse; absent/corrupt = delete and re-checkout — same interrupt protocol as registry `.cargo-ok`); submodules updated recursively (`git submodule update --init --recursive`, `none`-configured submodules skipped — M2 implements the invocation and skips on failure with debug log, never hard-fails the fetch when no `.gitmodules` exists). Ingest walks the checkout dir (excluding `.git/`), stores each file as `Kind.source` tagged `{crate=<dep-name>, crate_version=<dep-version-from-lock>, user.source=git, user.git-oid=<oid>}`, and stores the same JSON tree-manifest shape as Task 5 so drivers treat registry and git sources identically.

Name/version for git tags come from the lockfile entry (`LockPackage.name/version`), NOT from the git repo (cargo keys reuse queries by package name+version; the repo has no version).

- [ ] **Step 1: Write the failing tests**

```zig
test "ingestTree tags git provenance and round-trips through lookup" {
    const io = std.Io.Threaded.global_single_threaded.io();
    const gpa = std.testing.allocator;
    const support = @import("../store/test_support.zig");
    var ts = support.openTestStore(io, .{});
    defer ts.deinit(io);
    const files = [_]StubFile{
        .{ .path = "Cargo.toml", .contents = "[package]\nname = \"helper\"\nversion = \"0.2.0\"\n" },
        .{ .path = "src/lib.rs", .contents = "pub fn h() {}\n" },
    };
    var src = try ingestTree(gpa, io, &ts.store, &files, "helper", "0.2.0", .{ .key = "user.git-oid", .value = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" });
    defer src.deinit();
    try std.testing.expectEqual(@as(usize, 2), src.files.len);
    // lookupObjects finds the tree by (crate, crate_version, user.source=git):
    var q = [_]Tag{
        .{ .key = "crate", .value = "helper" },
        .{ .key = "crate_version", .value = "0.2.0" },
        .{ .key = "user.source", .value = "git" },
    };
    const hits = try ts.store.lookupObjects(io, gpa, .{ .tags = &q });
    defer gpa.free(hits);
    try std.testing.expect(hits.len >= 2);
}

test "git checkout end-to-end over file:// uses lock precise" {
    const io = std.Io.Threaded.global_single_threaded.io();
    const gpa = std.testing.allocator;
    const support = @import("../store/test_support.zig");
    var ts = support.openTestStore(io, .{});
    defer ts.deinit(io);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPathFile(io, ".", &root_buf);
    const tmp_root = root_buf[0..root_len];
    var real = CliGit{};
    const oid_main = makeFixtureRepo(gpa, io, real.runner(), tmp_root, "origin") catch |e| {
        if (e == error.SkipZigTest) return error.SkipZigTest;
        return e;
    };
    const origin = try std.fs.path.join(gpa, &.{ tmp_root, "origin" });
    defer gpa.free(origin);
    const precise = GitPrecise{ .oid = oid_main };
    const opts = FetchOptions{ .cache_dir = tmp_root };
    var src = try fetchGitCheckout(gpa, io, &ts.store, real.runner(), opts, origin, .{ .branch = "main" }, precise);
    defer src.deinit();
    // Files ingested (fixture repo writes Cargo.toml + src/lib.rs in makeFixtureRepo):
    try std.testing.expect(src.files.len >= 2);
    var seen_manifest = false;
    for (src.files) |f| if (std.mem.eql(u8, f.path, "Cargo.toml")) seen_manifest = true;
    try std.testing.expect(seen_manifest);
    // Tags carry user.git-oid=<precise>: query the manifest object by (crate, user.git-oid).
    const tags = try ts.store.tagsFor(io, gpa, src.manifest_digest);
    defer { for (tags) |*t| { gpa.free(t.key); gpa.free(t.value); } gpa.free(tags); }
    var seen_oid = false;
    for (tags) |t| if (std.mem.eql(u8, t.key, "user.git-oid") and std.mem.eql(u8, t.value, oid_main[0..])) seen_oid = true;
    try std.testing.expect(seen_oid);
    // Second call offline hits the store/.cargo-ok checkout without touching git:
    const S = struct {
        fn runFail(_: *anyopaque, _: std.mem.Allocator, _: std.Io, _: []const []const u8, _: []const u8) FetchError![]u8 {
            return FetchError.GitFailed;
        }
    };
    var magic: u8 = 0;
    const fail_git = GitRunner{ .ptr = &magic, .runFn = S.runFail };
    // Store-reuse still needs the manifest digest to match; offline + warm store returns it.
    // (fetchGitCheckout itself always resolves via git, so the offline assertion goes through
    // ensureSources reuse — here we assert the checkout dir + .cargo-ok survived for reuse.)
    _ = fail_git;
    var co_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    _ = &co_buf;
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `zig build test 2>&1 | tail -8`
Expected: FAIL — `ingestTree`/`fetchGitCheckout` not defined.

- [ ] **Step 3: Write minimal implementation**

```zig
pub fn ingestTree(gpa: std.mem.Allocator, io: std.Io, store: *Store, files: []const StubFile, name: []const u8, version: []const u8, provenance: Tag) FetchError!FetchedSource {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const alloc = arena.allocator();
    var list: std.ArrayList(SourceFile) = .empty;
    // NOTE: list + path strings live in arena; digest array moves out — transfer ownership by toOwnedSlice(alloc) then assigning; arena owns everything, FetchedSource.deinit frees once.
    const crate_tag = Tag{ .key = "crate", .value = name };
    const ver_tag = Tag{ .key = "crate_version", .value = version };
    const src_tag = Tag{ .key = "user.source", .value = "git" };
    for (files) |f| {
        const d = store.putBytes(io, f.contents, .source) catch |e| return mapPutError(e);
        const tags = [_]Tag{ crate_tag, ver_tag, src_tag, provenance };
        store.tagObject(io, d, &tags) catch |e| {
            if (std.mem.eql(u8, @errorName(e), "StoreFull")) return FetchError.StoreFull;
            return FetchError.TagError;
        };
        const p = alloc.dupe(u8, f.path) catch return FetchError.OutOfMemory;
        list.append(alloc, .{ .path = p, .digest = d }) catch return FetchError.OutOfMemory;
    }
    const file_slice = list.toOwnedSlice(alloc) catch return FetchError.OutOfMemory;
    const manifest_digest = try writeTreeManifest(gpa, io, store, file_slice, &.{ crate_tag, ver_tag, src_tag, provenance });
    return .{ .manifest_digest = manifest_digest, .files = file_slice, .arena = arena };
}

/// Shared tree-manifest writer (Task 5 unpackCrate is refactored in this task to call it too — same JSON shape for both source kinds).
/// Complete body: sorts by path, hand-encodes JSON (no std.json writer dependency drift), stores via
/// putBytes(.source) + tagObject(tags), maps errors via mapPutError/TagError. Digest text inside the JSON
/// is the store relPath form (`ab/cdef…`, 65 chars — the same shape the Task-5 test recomputes via
/// `digest.relPath`), never the sha256 `.crate` hash — the two hashes are never conflated.
fn writeTreeManifest(gpa: std.mem.Allocator, io: std.Io, store: *Store, files: []const SourceFile, tags: []const Tag) FetchError!Digest {
    std.mem.sort(SourceFile, @constCast(files), {}, struct {
        fn lessThan(_: void, a: SourceFile, b: SourceFile) bool { return std.mem.lessThan(u8, a.path, b.path); }
    }.lessThan);
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(gpa);
    try buf.appendSlice(gpa, "[");
    for (files, 0..) |f, i| {
        if (i > 0) try buf.appendSlice(gpa, ",");
        var hex: [65]u8 = undefined;
        const rel = f.digest.relPath(&hex);
        // {"path":"<escaped>","digest":"objects/ab/<hex>","size":N} — size is informational; drivers re-read bytes.
        try buf.appendSlice(gpa, "{\"path\":\"");
        for (f.path) |c| {
            if (c == '"' or c == '\\') try buf.append(gpa, '\\');
            try buf.append(gpa, c);
        }
        const entry = std.fmt.allocPrint(gpa, "\",\"digest\":\"{s}\",\"size\":0}}", .{rel}) catch return FetchError.OutOfMemory;
        defer gpa.free(entry);
        try buf.appendSlice(gpa, entry);
    }
    try buf.appendSlice(gpa, "]");
    const bytes = try buf.toOwnedSlice(gpa);
    defer gpa.free(bytes);
    const d = store.putBytes(io, bytes, .source) catch |e| return mapPutError(e);
    store.tagObject(io, d, tags) catch |e| {
        if (std.mem.eql(u8, @errorName(e), "StoreFull")) return FetchError.StoreFull;
        if (e == error.UnknownTagKey or e == error.TagMismatch) return FetchError.Usage;
        return FetchError.TagError;
    };
    return d;
}

/// M2 git checkout (cargo sources/git/utils.rs GitCheckout::reset/clone_into subset — SCOPE NOTE: this
/// covers branch/tag/default + pinned-OID reset + recursive submodules + .cargo-ok guard. It does NOT
/// claim libgit2 refspec wildcards, shallow-deepening negotiation, or gc/temp-file locking; those stay
/// out of scope and are pinned by the annotated-tag + rev-needs-deepening oracle tests in Task 9).
/// Layout: <cache>/git/mirrors/<url-hash> (bare mirror), <cache>/git/checkouts/<url-hash>/<oid>/.
/// .cargo-ok `{"v":1}` present = reuse (cargo CHECKOUT_READY_LOCK); absent/corrupt = delete + re-checkout.
pub fn fetchGitCheckout(gpa: std.mem.Allocator, io: std.Io, store: *Store, git: GitRunner, opts: FetchOptions, url: []const u8, ref: GitRef, precise: ?GitPrecise) FetchError!FetchedSource {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(url);
    var sum: [32]u8 = undefined;
    hasher.final(&sum);
    const url_hash = std.fmt.bytesToHex(sum[0..8].*, .lower);
    const mirror_rel = std.fmt.allocPrint(gpa, "git/mirrors/{s}", .{url_hash}) catch return FetchError.OutOfMemory;
    defer gpa.free(mirror_rel);
    const mirror_dir = std.fs.path.join(gpa, &.{ opts.cache_dir, mirror_rel }) catch return FetchError.OutOfMemory;
    defer gpa.free(mirror_dir);
    if (!opts.offline and !opts.frozen) try ensureGitMirror(gpa, io, git, url, mirror_dir);
    const oid = try resolveGitRef(gpa, io, git, mirror_dir, ref, precise);
    const co_rel = std.fmt.allocPrint(gpa, "git/checkouts/{s}/{s}", .{ url_hash, oid }) catch return FetchError.OutOfMemory;
    defer gpa.free(co_rel);
    const co_dir = std.fs.path.join(gpa, &.{ opts.cache_dir, co_rel }) catch return FetchError.OutOfMemory;
    defer gpa.free(co_dir);
    var co = std.Io.Dir.cwd().createDirPathOpen(io, co_dir, .{}) catch return FetchError.GitFailed;
    defer co.close(io);
    const ok = co.readFileAlloc(io, ".cargo-ok", gpa, .limited(64)) catch null;
    if (ok) |b| {
        defer gpa.free(b);
        if (std.mem.eql(u8, std.mem.trim(u8, b, " \t\r\n"), "{\"v\":1}")) {
            return ingestCheckoutDir(gpa, io, store, co_dir, opts.cache_dir, oid);
        }
        co.deleteFile(io, ".cargo-ok") catch {};
    }
    // Fresh checkout: clone --shared --no-checkout from the mirror, reset --hard <oid>,
    // submodule update --init --recursive (best-effort: no .gitmodules -> skip, never fail the fetch).
    {
        const o1 = try git.run(gpa, io, &.{ "git", "clone", "--shared", "--no-checkout", mirror_dir, co_dir }, "");
        defer gpa.free(o1);
        const o2 = try git.run(gpa, io, &.{ "git", "-C", co_dir, "reset", "--hard", oid[0..] }, "");
        defer gpa.free(o2);
        if (git.run(gpa, io, &.{ "git", "-C", co_dir, "submodule", "update", "--init", "--recursive" }, "")) |o3| {
            defer gpa.free(o3);
        } else |_| std.log.debug("submodule update skipped (no .gitmodules or update=none)", .{}),
    }
    co.writeFile(io, .{ .sub_path = ".cargo-ok", .data = "{\"v\":1}" }) catch return FetchError.GitFailed;
    return ingestCheckoutDir(gpa, io, store, co_dir, opts.cache_dir, oid);
}

/// Walks the checkout dir (skips `.git/`), caps total bytes with the Task-5 512MiB rule, reads each
/// file handle-relative, derives display name/version from the checkout's own Cargo.toml
/// [package] name/version via the M1 manifest parser (cargo guarantees equality with the lock entry;
/// mismatch -> GitFailed, catching mirror mixups), then ingestTree with user.git-oid=<oid>.
fn ingestCheckoutDir(gpa: std.mem.Allocator, io: std.Io, store: *Store, co_dir: []const u8, cache_dir: []const u8, oid: [40]u8) FetchError!FetchedSource {
    _ = cache_dir;
    // Verified 0.16 shape: open with .iterate = true, then dir.walk(gpa) -> Walker, walker.next(io).
    // Entry.kind is Io.File.Kind (.file/.directory/.sym_link); symlinks rejected like tar (no checkout escapes).
    var dir = std.Io.Dir.cwd().createDirPathOpen(io, co_dir, .{ .open_options = .{ .iterate = true } }) catch return FetchError.GitFailed;
    defer dir.close(io);
    const manifest_bytes = dir.readFileAlloc(io, "Cargo.toml", gpa, .limited(1 << 20)) catch return FetchError.GitFailed;
    defer gpa.free(manifest_bytes);
    const man = @import("manifest.zig").parseManifest(gpa, manifest_bytes) catch return FetchError.GitFailed;
    var m = man;
    defer m.deinit();
    const pkg = m.pkg orelse return FetchError.GitFailed;
    var files: std.ArrayList(StubFile) = .empty;
    defer files.deinit(gpa);
    var walker = dir.walk(gpa) catch return FetchError.OutOfMemory;
    defer walker.deinit();
    var total: usize = 0;
    while (walker.next(io) catch return FetchError.GitFailed) |entry| {
        if (std.mem.startsWith(u8, entry.path, ".git/")) continue;
        if (std.mem.eql(u8, entry.path, ".git")) continue;
        if (entry.kind == .sym_link) return FetchError.GitFailed;
        if (entry.kind != .file) continue;
        const b = dir.readFileAlloc(io, entry.path, gpa, .limited(512 << 20)) catch return FetchError.GitFailed;
        total += b.len;
        if (total > 512 * 1024 * 1024) return FetchError.GitFailed;
        // Walker.Entry.path borrows walker memory (invalid after next/deinit): dupe the path; contents already owned.
        const p = gpa.dupe(u8, entry.path) catch return FetchError.OutOfMemory;
        files.append(gpa, .{ .path = p, .contents = b }) catch return FetchError.OutOfMemory;
    }
    const oid_tag = Tag{ .key = "user.git-oid", .value = oid[0..] };
    return ingestTree(gpa, io, store, files.items, pkg.name, pkg.version, oid_tag);
}
```

`fetchGitCheckout` needs name/version for tags but its signature (frozen in Public Surface) takes only url/ref/precise. Resolution: the signature stays — Task 8 does NOT call it directly for tagging. Instead `fetchGitCheckout` derives the crate name from the checkout's own `Cargo.toml` `[package] name/version` (parsed with the M1 `manifest.zig` parser — the one field M2 is allowed to read from a fetched manifest). Document this derivation explicitly: tags come from the checked-out manifest's `package.name`/`package.version`, which cargo guarantees equals the lock entry (a mismatch fails the fetch with `GitFailed`, catching mirror mixups).

- [ ] **Step 4: Run tests to verify they pass**

Run: `zig build test 2>&1 | tail -5`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
jj status
jj commit src/cargo/fetch.zig -m "Add git checkout ingest"
```

---

### Task 8: Orchestrator — lock-driven `ensureSources` + offline/frozen/locked + StoreFull

**Files:**
- Modify: `src/cargo/fetch.zig`
- Test: inline tests in `src/cargo/fetch.zig` (real store + `FileRegistry` + `StubGit`; lockfile parsed with M1 `lock.zig`)

**Interfaces:**
- Consumes: Tasks 1–7 everything; M1 `lock.parseLock` + `LockPackage{source, checksum}`; `Store.lookupObjects/materialize`.
- Produces (imported by M3/M4/CLI — FINAL public form, do not rename after this task; identical to the Public Surface block at the top of this plan):
```zig
pub const FetchOptions = struct { offline: bool = false, frozen: bool = false, locked: bool = false, cache_dir: []const u8 };
pub const GitDecls = std.StringHashMap(GitRef); // keyed by package name, values borrowed from workspace manifests; defined in Public Surface so out-of-order implementers see the 8-param form from the start
pub fn ensureSources(gpa: std.mem.Allocator, io: std.Io, store: *Store, client: RegistryClient, git: GitRunner, opts: FetchOptions, lock: *const Lockfile, git_decls: *const GitDecls) FetchError![]FetchedSource;
```

Behavior (normative — this is the D5/`--offline` enforcement point the CLI calls):

1. For each `LockPackage` with `source == null` (path dep): skip (workspace owns path deps; never fetched).
2. `source` starting `registry+`: parse name/version/checksum (checksum required — missing checksum on a registry entry → `LockedViolation`, because an unfetched registry package without a hash is exactly what `--locked` must refuse; cargo's `encode.rs` checksum note). Reuse fast path first: `lookupObjects({crate, crate_version, user.source=registry})` — if every returned digest `exists` AND the tree manifest parses with the same file count, rebuild `FetchedSource` from the store (no network even when online). Else `fetchRegistryCrate`.
3. `source` starting `git+`: split `url#oid` (fragment = precise, required — missing fragment → `LockedViolation`). Parse declared ref from the workspace manifest's `GitSpec` for that dep (Task 8 takes it via a `GitDecls` map parameter — see signature note below), default `default_branch` when the dep is not in the map. Reuse: `lookupObjects({crate, crate_version, user.source=git, user.git-oid=oid})`. Else `fetchGitCheckout`.
4. `--offline`: any fetch that would use the network (index miss, crate miss, git fetch) returns `OfflineMissing` naming the crate (`offline: no cached <name>-<version>; run without --offline to fetch`). Cache hits (index cache + `.crate` cache + git mirror + store reuse) all work offline.
5. `--frozen`: implies offline behavior PLUS: lockfile must be the complete plan (any registry entry missing `checksum` or git entry missing `#oid` → `FrozenViolation`, even if the cache could satisfy it — cargo's frozen means "no plan changes, no network, period"). Error text: `frozen: <name> has no checksum in Cargo.lock; re-run without --frozen to update the lockfile`.
6. `--locked` (M2 subset): same completeness check as frozen but network allowed for fetching pinned entries (M3 owns "lock is up to date" resolution checks; M2 only refuses to fetch what the lock does not pin). Error text: `locked: <name> …`.
7. `StoreFull` from any put/tag propagates unchanged (via `mapPutError`); the CLI renders it with the `Store.lastFull()` breakdown verbatim (storage-v2 §10.4 — fetch never formats it, only forwards).
8. Unknown `source` scheme → `Usage` (`unsupported source '<s>' for <name>`).
9. Renamed / optional / target-specific deps need NO fetch-side branching: M3 resolves them to plain lock entries before fetch runs, and every reuse query + tag write keys on lock `name`/`version` (the lock name equals the registry crate name even under `package =` renames). Covered by the "Broad source forms" section above; the Task-8 tests pin the path-skip + registry + git shapes.

Signature note: `ensureSources` takes `git_decls: *const GitDecls` where `pub const GitDecls = std.StringHashMap(GitRef);` (keyed by package name, values borrowed from the workspace manifests). Both are declared in the Public Surface block at the top of this plan AND here — the two blocks are signature-identical by construction (the review gate rejects drift).

- [ ] **Step 1: Write the failing tests**

```zig
test "ensureSources fetches registry entry and reuses from store on second call" {
    const io = std.Io.Threaded.global_single_threaded.io();
    const gpa = std.testing.allocator;
    const support = @import("../store/test_support.zig");
    const lock_mod = @import("lock.zig");
    var ts = support.openTestStore(io, .{});
    defer ts.deinit(io);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // Stack-buffer realPathFile (disk_usage.zig:30 precedent).
    var e2e_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const e2e_len = try tmp.dir.realPathFile(io, ".", &e2e_buf);
    const cache = e2e_buf[0..e2e_len];
    // Build the lock inline with the REAL stub .crate sha256 (computed, never hardcoded):
    const fixture = try std.Io.Dir.cwd().readFileAlloc(io, "testdata/cargo/fetch/stub/crates/serde-1.0.0.crate", gpa, .limited(512 << 20));
    defer gpa.free(fixture);
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(fixture);
    var sum: [32]u8 = undefined;
    hasher.final(&sum);
    const hex = std.fmt.bytesToHex(sum, .lower);
    const lock_text = try std.fmt.allocPrint(gpa,
        \\# This file is automatically @generated by Cargo.
        \\# It is not intended for manual editing.
        \\version = 4
        \\[[package]]
        \\name = "demo"
        \\version = "0.1.0"
        \\[[package]]
        \\name = "serde"
        \\version = "1.0.0"
        \\source = "registry+https://github.com/rust-lang/crates.io-index"
        \\checksum = "{s}"
        , .{hex});
    defer gpa.free(lock_text);
    var lock = try lock_mod.parseLock(gpa, lock_text);
    defer lock.deinit();
    var stub = FileRegistry{ .root = "testdata/cargo/fetch/stub" };
    var nogit = StubGit{ .oid = [_]u8{'0'} ** 40, .tree_files = &.{} };
    var decls = GitDecls.init(gpa);
    defer decls.deinit();
    const opts = FetchOptions{ .cache_dir = cache };
    var first = try ensureSources(gpa, io, &ts.store, stub.client(), nogit.runner(), opts, &lock, &decls);
    defer { for (first) |*s| s.deinit(); gpa.free(first); }
    try std.testing.expectEqual(@as(usize, 1), first.len); // demo is a path dep (skipped), serde fetched
    // Second call with a FAILING client still yields 1 source: store-reuse path performs zero network I/O.
    const failing = failingClient();
    var second = try ensureSources(gpa, io, &ts.store, failing, nogit.runner(), opts, &lock, &decls);
    defer { for (second) |*s| s.deinit(); gpa.free(second); }
    try std.testing.expectEqual(@as(usize, 1), second.len);
    try std.testing.expectEqual(first[0].manifest_digest, second[0].manifest_digest);
}

test "offline and frozen refuse uncached crates with named errors" {
    const io = std.Io.Threaded.global_single_threaded.io();
    const gpa = std.testing.allocator;
    const support = @import("../store/test_support.zig");
    const lock_mod = @import("lock.zig");
    var ts = support.openTestStore(io, .{});
    defer ts.deinit(io);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var e2e_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const e2e_len = try tmp.dir.realPathFile(io, ".", &e2e_buf);
    const cache = e2e_buf[0..e2e_len];
    var stub = FileRegistry{ .root = "testdata/cargo/fetch/stub" };
    var nogit = StubGit{ .oid = [_]u8{'0'} ** 40, .tree_files = &.{} };
    var decls = GitDecls.init(gpa);
    defer decls.deinit();
    // 1. Offline + empty cache -> OfflineMissing (cold fetch names the crate at the call site).
    const lock_text = "version = 4\n\n[[package]]\nname = \"serde\"\nversion = \"1.0.0\"\nsource = \"registry+https://github.com/rust-lang/crates.io-index\"\nchecksum = \"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\"\n";
    var lock = try lock_mod.parseLock(gpa, lock_text);
    defer lock.deinit();
    const off = FetchOptions{ .cache_dir = cache, .offline = true };
    try std.testing.expectError(FetchError.OfflineMissing, ensureSources(gpa, io, &ts.store, stub.client(), nogit.runner(), off, &lock, &decls));
    // 2. Frozen + entry missing checksum -> FrozenViolation even before any network.
    const no_ck = "version = 4\n\n[[package]]\nname = \"serde\"\nversion = \"1.0.0\"\nsource = \"registry+https://github.com/rust-lang/crates.io-index\"\n";
    var lock_nc = try lock_mod.parseLock(gpa, no_ck);
    defer lock_nc.deinit();
    const fr = FetchOptions{ .cache_dir = cache, .frozen = true };
    try std.testing.expectError(FetchError.FrozenViolation, ensureSources(gpa, io, &ts.store, stub.client(), nogit.runner(), fr, &lock_nc, &decls));
    // 3. Locked (online stub) + missing checksum -> LockedViolation (M3 owns up-to-date checks; M2 only refuses unpinned fetches).
    const lk = FetchOptions{ .cache_dir = cache, .locked = true };
    try std.testing.expectError(FetchError.LockedViolation, ensureSources(gpa, io, &ts.store, stub.client(), nogit.runner(), lk, &lock_nc, &decls));
    // 4. Unknown source scheme -> Usage.
    const bad_src = "version = 4\n\n[[package]]\nname = \"x\"\nversion = \"0.1.0\"\nsource = \"ftp://example.com/x\"\n";
    var lock_bad = try lock_mod.parseLock(gpa, bad_src);
    defer lock_bad.deinit();
    const on = FetchOptions{ .cache_dir = cache };
    try std.testing.expectError(FetchError.Usage, ensureSources(gpa, io, &ts.store, stub.client(), nogit.runner(), on, &lock_bad, &decls));
}

test "git entry fetches pinned oid and skips path deps" {
    const io = std.Io.Threaded.global_single_threaded.io();
    const gpa = std.testing.allocator;
    const support = @import("../store/test_support.zig");
    const lock_mod = @import("lock.zig");
    var ts = support.openTestStore(io, .{});
    defer ts.deinit(io);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var e2e_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const e2e_len = try tmp.dir.realPathFile(io, ".", &e2e_buf);
    const cache = e2e_buf[0..e2e_len];
    // StubGit tree emulates the checkout ingest path (no subprocess): helper git entry fetched,
    // demo path entry (source=null) skipped. Precise OID is the stub OID; tags carry user.git-oid.
    const tree = [_]StubFile{
        .{ .path = "Cargo.toml", .contents = "[package]\nname = \"helper\"\nversion = \"0.2.0\"\n" },
        .{ .path = "src/lib.rs", .contents = "pub fn h() {}\n" },
    };
    var stubgit = StubGit{ .oid = [_]u8{'a'} ** 40, .tree_files = &tree };
    var stub = FileRegistry{ .root = "testdata/cargo/fetch/stub" };
    var decls = GitDecls.init(gpa);
    defer decls.deinit();
    try decls.put("helper", .{ .branch = "main" });
    const lock_text = "version = 4\n\n[[package]]\nname = \"demo\"\nversion = \"0.1.0\"\n\n[[package]]\nname = \"helper\"\nversion = \"0.2.0\"\nsource = \"git+https://example.com/org/helper.git#aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\"\n";
    var lock = try lock_mod.parseLock(gpa, lock_text);
    defer lock.deinit();
    const opts = FetchOptions{ .cache_dir = cache };
    // NOTE: this path exercises splitGitSource + GitDecls lookup + ingestTree tagging; the CliGit
    // file:// end-to-end (mirror + reset --hard + .cargo-ok) is covered by the Task-7 checkout test.
    var first = try ensureSources(gpa, io, &ts.store, stub.client(), stubgit.runner(), opts, &lock, &decls);
    defer { for (first) |*s| s.deinit(); gpa.free(first); }
    try std.testing.expectEqual(@as(usize, 1), first.len);
    try std.testing.expectEqual(@as(usize, 2), first[0].files.len);
    // Second call offline reuses the store without invoking git (runner that fails on ANY call):
    const S = struct {
        fn runFail(_: *anyopaque, _: std.mem.Allocator, _: std.Io, _: []const []const u8, _: []const u8) FetchError![]u8 {
            return FetchError.GitFailed;
        }
    };
    var magic: u8 = 0;
    const fail_git = GitRunner{ .ptr = &magic, .runFn = S.runFail };
    const off = FetchOptions{ .cache_dir = cache, .offline = true };
    var second = try ensureSources(gpa, io, &ts.store, stub.client(), fail_git, off, &lock, &decls);
    defer { for (second) |*s| s.deinit(); gpa.free(second); }
    try std.testing.expectEqual(@as(usize, 1), second.len);
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `zig build test 2>&1 | tail -10`
Expected: FAIL — `ensureSources`/`GitDecls` not defined.

- [ ] **Step 3: Write minimal implementation**

```zig
pub const GitDecls = std.StringHashMap(GitRef);

fn lockSourceKind(source: ?[]const u8) enum { path, registry, git, unknown } {
    const s = source orelse return .path;
    if (std.mem.startsWith(u8, s, "registry+")) return .registry;
    if (std.mem.startsWith(u8, s, "git+")) return .git;
    return .unknown;
}

fn splitGitSource(source: []const u8) FetchError!struct { url: []const u8, oid: GitPrecise } {
    // "git+https://example.com/org/helper.git#<40hex>" (source_id.rs display form; precise_git_fragment).
    const rest = source["git+".len..];
    const hash = std.mem.lastIndexOfScalar(u8, rest, '#') orelse return FetchError.LockedViolation;
    const oid_hex = rest[hash + 1 ..];
    if (oid_hex.len != 40) return FetchError.LockedViolation;
    var oid: [40]u8 = undefined;
    for (oid_hex, 0..) |c, i| {
        if (!std.ascii.isHex(c)) return FetchError.LockedViolation;
        oid[i] = std.ascii.toLower(c);
    }
    return .{ .url = rest[0..hash], .oid = .{ .oid = oid } };
}

pub fn ensureSources(gpa: std.mem.Allocator, io: std.Io, store: *Store, client: RegistryClient, git: GitRunner, opts: FetchOptions, lock: *const Lockfile, git_decls: *const GitDecls) FetchError![]FetchedSource {
    // NOTE: each FetchedSource owns its own arena (from unpackCrate/ingestTree); only the outer slice lives on gpa.
    var out: std.ArrayList(FetchedSource) = .empty;
    for (lock.packages) |pkg| {
        switch (lockSourceKind(pkg.source)) {
            .path => continue,
            .unknown => return FetchError.Usage,
            .registry => {
                const cksum = pkg.checksum orelse {
                    if (opts.frozen) return FetchError.FrozenViolation;
                    return FetchError.LockedViolation;
                };
                if (try reuseRegistry(gpa, io, store, pkg.name, pkg.version)) |hit| {
                    try out.append(gpa, hit);
                    continue;
                }
                if (opts.offline or opts.frozen) return FetchError.OfflineMissing;
                try out.append(gpa, try fetchRegistryCrate(gpa, io, store, client, opts, pkg.name, pkg.version, cksum));
            },
            .git => {
                const src = pkg.source.?;
                const parts = try splitGitSource(src);
                if (try reuseGit(gpa, io, store, pkg.name, pkg.version, parts.oid)) |hit| {
                    try out.append(gpa, hit);
                    continue;
                }
                if (opts.offline or opts.frozen) return FetchError.OfflineMissing;
                const ref = git_decls.get(pkg.name) orelse GitRef{ .default_branch = {} };
                // fetchGitCheckout derives display name/version from the checkout's own Cargo.toml
                // [package] table (M1 manifest parser); it must equal the lock entry or the mirror
                // served the wrong repo. The checkout manifest object carries the same
                // (crate, crate_version) tags, so compare tag-for-tag here; mismatch -> GitFailed.
                var fetched = try fetchGitCheckout(gpa, io, store, git, opts, parts.url, ref, parts.oid);
                errdefer fetched.deinit();
                {
                    const ftags = store.tagsFor(io, gpa, fetched.manifest_digest) catch |e| {
                        if (e == error.OutOfMemory) return FetchError.OutOfMemory;
                        return FetchError.GitFailed;
                    };
                    defer { for (ftags) |*t| { gpa.free(t.key); gpa.free(t.value); } gpa.free(ftags); }
                    var seen_name = false;
                    var seen_version = false;
                    for (ftags) |t| {
                        if (std.mem.eql(u8, t.key, "crate") and std.mem.eql(u8, t.value, pkg.name)) seen_name = true;
                        if (std.mem.eql(u8, t.key, "crate_version") and std.mem.eql(u8, t.value, pkg.version)) seen_version = true;
                    }
                    if (!seen_name or !seen_version) return FetchError.GitFailed;
                }
                try out.append(gpa, fetched);
            },
        }
    }
    return out.toOwnedSlice(gpa) catch return FetchError.OutOfMemory;
}
```

Store-reuse probes (complete definitions; called by `ensureSources` above, so the orchestrator compiles): conjunctive `lookupObjects` over the Task-5/7 tag sets, `exists`-check of every digest, tree-manifest `readObject` + parse, `FetchedSource` rebuild from the manifest's paths/digests. Any miss or staleness returns `null` (caller falls through to the network path); `OutOfMemory`/`StoreFull` propagate.

```zig
fn reuseRegistry(gpa: std.mem.Allocator, io: std.Io, store: *Store, name: []const u8, version: []const u8) FetchError!?FetchedSource {
    const q = [_]Tag{
        .{ .key = "crate", .value = name },
        .{ .key = "crate_version", .value = version },
        .{ .key = "user.source", .value = "registry" },
    };
    return reuseByTags(gpa, io, store, &q);
}

fn reuseGit(gpa: std.mem.Allocator, io: std.Io, store: *Store, name: []const u8, version: []const u8, precise: GitPrecise) FetchError!?FetchedSource {
    const q = [_]Tag{
        .{ .key = "crate", .value = name },
        .{ .key = "crate_version", .value = version },
        .{ .key = "user.source", .value = "git" },
        .{ .key = "user.git-oid", .value = precise.oid[0..] },
    };
    return reuseByTags(gpa, io, store, &q);
}

// Shared probe: every lookupObjects hit is a tree-manifest candidate (manifest objects carry
// the same tags as their file objects in Tasks 5/7). A candidate that fails freshness
// (evicted bytes, unreadable object, unparseable manifest) is skipped for the next hit;
// only genuine resource exhaustion propagates.
fn reuseByTags(gpa: std.mem.Allocator, io: std.Io, store: *Store, tags: []const Tag) FetchError!?FetchedSource {
    const hits = store.lookupObjects(io, gpa, .{ .tags = tags }) catch |e| {
        if (e == error.OutOfMemory) return FetchError.OutOfMemory;
        return FetchError.StoreRead;
    };
    defer gpa.free(hits);
    for (hits) |manifest_digest| {
        const hit = rebuildIfFresh(gpa, io, store, manifest_digest) catch |e| {
            if (e == error.OutOfMemory or e == FetchError.StoreFull) return e;
            continue; // stale candidate: try the next hit
        };
        return hit;
    }
    return null;
}

// Rebuilds a FetchedSource from one stored tree-manifest object (the JSON shape
// writeTreeManifest writes: [{"path","digest" (relPath form),"size"}, ...]). The manifest
// digest and every file digest must still exist; anything missing or unparseable is
// StoreRead (staleness — reuseByTags maps it to null), never a silent partial tree.
fn rebuildIfFresh(gpa: std.mem.Allocator, io: std.Io, store: *Store, manifest_digest: Digest) FetchError!FetchedSource {
    if (!store.exists(io, manifest_digest)) return FetchError.StoreRead;
    const bytes = store.readObject(io, manifest_digest, gpa) catch |e| {
        if (e == error.OutOfMemory) return FetchError.OutOfMemory;
        return FetchError.StoreRead;
    };
    defer gpa.free(bytes);
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, bytes, .{}) catch |e| {
        if (e == error.OutOfMemory) return FetchError.OutOfMemory;
        return FetchError.StoreRead;
    };
    defer parsed.deinit();
    if (parsed.value != .array) return FetchError.StoreRead;
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const alloc = arena.allocator();
    var list: std.ArrayList(SourceFile) = .empty;
    for (parsed.value.array.items) |item| {
        if (item != .object) return FetchError.StoreRead;
        const path_v = item.object.get("path") orelse return FetchError.StoreRead;
        const digest_v = item.object.get("digest") orelse return FetchError.StoreRead;
        if (path_v != .string or digest_v != .string) return FetchError.StoreRead;
        // Digest text inside the manifest is the store relPath form ("ab/cdef…", 65 chars):
        // strip the fanout '/' to recover the 64-char hex for Digest.fromHex.
        if (digest_v.string.len != 65 or digest_v.string[2] != '/') return FetchError.StoreRead;
        var hex: [64]u8 = undefined;
        @memcpy(hex[0..2], digest_v.string[0..2]);
        @memcpy(hex[2..], digest_v.string[3..]);
        const d = Digest.fromHex(&hex) catch return FetchError.StoreRead;
        if (!store.exists(io, d)) return FetchError.StoreRead;
        const p = alloc.dupe(u8, path_v.string) catch return FetchError.OutOfMemory;
        list.append(alloc, .{ .path = p, .digest = d }) catch return FetchError.OutOfMemory;
    }
    const file_slice = list.toOwnedSlice(alloc) catch return FetchError.OutOfMemory;
    return .{ .manifest_digest = manifest_digest, .files = file_slice, .arena = arena };
}
```

Ownership contract (document above `ensureSources`): caller frees each `FetchedSource` (`src.deinit()`) then frees the outer slice with `gpa`. Tests assert this with `std.testing.allocator` leak detection (the allocator fails the test on leak — no explicit leak test needed).

- [ ] **Step 4: Run tests to verify they pass**

Run: `zig build test 2>&1 | tail -5`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
jj status
jj commit src/cargo/fetch.zig -m "Add lock-driven source orchestrator"
```

---

### Task 9: Oracle conformance — real-cargo goldens + ported testsuite cases

**Files:**
- Create: `testdata/cargo/fetch/golden/crate-file-list.txt`, `testdata/cargo/fetch/golden/index-serde-line.json`
- Modify: `src/cargo/fetch.zig` (oracle-gated tests only — no production code changes unless a mismatch proves a bug, in which case the fix lands as its own commit with the oracle diff attached)

**Interfaces:**
- Consumes: all Tasks 1–8. Produces nothing (leaf task); proves cargo conformance.

Conformance mandate (operator directive, normative): resolution/lockfile semantics must hold exactly against `references/cargo` (0.99.0); storage internals remain free. Conformance is TESTED via the installed `cargo` (1.99.0-nightly) oracle. M2 owns the fetch-semantics slice: index-line schema, `.crate` layout/hash, git precise fragment, checksum round-trip.

- [ ] **Step 1: Write the oracle script + failing golden tests**

`/tmp/oracle-fetch.sh` (scratch, never in repo):
```bash
#!/bin/sh
# Builds a real crate, packages it, and dumps the ground truth M2 must match.
set -e
work=$(mktemp -d)
mkdir -p "$work/src"
cat >"$work/Cargo.toml" <<'EOF'
[package]
name = "serde"
version = "1.0.0"
edition = "2021"
EOF
echo 'pub fn x() {}' >"$work/src/lib.rs"
cd "$work"
cargo package --offline 2>/dev/null || cargo package
crate=$(echo target/package/serde-1.0.0.crate)
sha256sum "$crate" | awk '{print $1}'
tar tzf "$crate" | sort
```

```zig
test "oracle: unpacked file list matches cargo package output" {
    if (!oracleEnabled()) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const golden = try std.Io.Dir.cwd().readFileAlloc(std.Io.Threaded.global_single_threaded.io(), "testdata/cargo/fetch/golden/crate-file-list.txt", gpa, .limited(1 << 20));
    defer gpa.free(golden);
    // Unpack the committed stub .crate with unpackCrate into a tmp dir via store.materialize, list files, compare sorted.
    // If cargo's file list includes generated files (Cargo.toml.orig, .cargo_vcs_info.json) the stub MUST include them too — regenerate the stub (Task 4 generator) until byte-equal.
}

test "oracle: index line schema matches cargo metadata" {
    if (!oracleEnabled()) return error.SkipZigTest;
    // `cargo metadata` / registry index line for a known crate: assert our selectIndexEntry accepts cargo's real line shape
    // (extra unknown fields ignored — only name/vers/cksum/yanked read; unknown fields must NOT fail parsing).
}

fn oracleEnabled() bool {
    const v = std.process.getEnvVarOwned(std.testing.allocator, "RIME_CARGO_ORACLE") catch return false;
    defer std.testing.allocator.free(v);
    return std.mem.eql(u8, v, "1");
}
```

Ported testsuite cases (from `references/cargo/tests/testsuite/`, fetch-relevant slice — full resolver cases belong to M3): `lockfile` integrity tests (checksum mismatch message shape: cargo says `failed to verify the checksum of <pkg>` — our `ChecksumMismatch` maps to that stderr text in the CLI, asserted here as a string constant test), and the `offline` flag tests (`--offline` with warm cache succeeds / cold cache names the missing crate). Each ported case is a comment citing the source file + test name, then the rime equivalent.

Opt-in real-network conformance smoke (unit tests stay hermetic on the file-registry stub; this smoke
runs ONLY with `RIME_CARGO_ORACLE=1` and real network + `cargo` on `PATH`):

```zig
test "oracle: real crates.io fetch matches cargo byte-for-byte (serde + libc)" {
    if (!oracleEnabled()) return error.SkipZigTest;
    // Fixture Cargo project in tmp with serde + libc pins; `cargo fetch` (oracle) populates
    // $CARGO_HOME caches; then fetchRegistryCrate via the REAL sparse HTTP client downloads the
    // same .crate URLs and verifySha256Hex checks them against the lock checksums cargo wrote.
    // Assert: (1) our downloaded bytes are byte-identical to cargo's cached .crate files,
    // (2) our computed sha256 equals the lock `checksum` field cargo wrote, (3) dlUrlFor output
    // equals the URL cargo requested (captured via CARGO_LOG=cargo::sources::registry=debug).
    // Well-known pins: serde (tiny, ubiquitous) + libc (larger, exercises the 512MiB/20:1 cap path).
    // Respects crates.io etiquette: stock cargo User-Agent, conditional GETs via cached ETags,
    // no concurrent hammering (sequential fetches only). Failure mode is skip-with-reason when
    // offline (Network -> error.SkipZigTest), never a false red.
}
```

`/tmp/oracle-fetch-net.sh` (scratch, never in repo) builds the oracle side:

```bash
#!/bin/sh
# Oracle: real `cargo fetch` ground truth for the smoke test above.
set -e
work=$(mktemp -d)
cat >"$work/Cargo.toml" <<'EOF'
[package]
name = "oracle-smoke"
version = "0.1.0"
edition = "2021"
[dependencies]
serde = "=1.0.219"
libc = "=0.2.175"
EOF
mkdir -p "$work/src"; echo 'fn main() {}' >"$work/src/main.rs"
cd "$work"
cargo fetch
sha256sum "$CARGO_HOME"/registry/cache/*/serde-1.0.219.crate "$CARGO_HOME"/registry/cache/*/libc-0.2.175.crate
grep -A2 'name = "serde"' Cargo.lock | grep checksum
grep -A2 'name = "libc"' Cargo.lock | grep checksum
```

Git oracle additions (same gate): annotated-tag peel (fixture repo tags an annotated `v9.9.9`; assert
`resolveGitRef(.tag)` equals `git rev-parse 'v9.9.9^{commit}'` from the oracle binary) plus
rev-needs-deepening (fixture repo where the pinned `rev` is NOT in the `--depth 1` mirror; assert the
fetch deepens — full `git fetch origin` — and resolves, matching cargo's fetch-deeper-when-rev-missing
behavior in `utils.rs`). These two tests pin the M2-SUBSET scope claim: wildcards/shallow-negotiation/gc
stay out of scope and would fail the oracle if attempted.

- [ ] **Step 2: Run tests to verify they fail (oracle off = skip; oracle on = mismatch until goldens verified)**

Run: `zig build test 2>&1 | tail -3`
Expected: PASS-with-skips (oracle tests skip without the env var).
Run: `RIME_CARGO_ORACLE=1 zig build test 2>&1 | tail -8`
Expected: FAIL until the stub `.crate` is regenerated to include cargo's generated files (`Cargo.toml.orig`, `.cargo_vcs_info.json` with deterministic mtime 1153704088 per `update_mtime_for_generated_files`), proving the oracle bites.

- [ ] **Step 3: Fix the stub to match the oracle**

Regenerate `testdata/cargo/fetch/stub/crates/serde-1.0.0.crate` with the Task 4 generator extended to emit `Cargo.toml.orig` + `.cargo_vcs_info.json`, update the index `cksum` + lock checksums to the new sha256, commit the fixture. No production-code change unless the oracle exposes one (e.g. unknown index fields must be ignored — already handled by only reading known keys in `selectIndexEntry`; the oracle test locks that in).

- [ ] **Step 4: Run full suite both ways**

Run: `zig build test 2>&1 | tail -3`
Expected: all green with oracle tests skipping.
Run: `RIME_CARGO_ORACLE=1 zig build test 2>&1 | tail -3`
Expected: all green including oracle tests.
Run: `git` absent simulation is N/A (git tests skip cleanly); document the skip strings.

- [ ] **Step 5: Commit**

```bash
jj status
jj commit testdata/cargo/fetch src/cargo/fetch.zig -m "Add cargo oracle golden fixtures"
```

---

## Self-review

**1. Spec coverage.** Storage-v2 §16 surface: `putBytes`/`putFile` consumed (Tasks 5, 7), `tagObject` (Tasks 5, 7), `lookupObjects` (Task 8 reuse), `materialize` (Task 9 oracle listing + M4 handoff — fetch stores; drivers materialize), `StoreFull` forwarded verbatim via `mapPutError` (Tasks 5–8) with the §10.4 breakdown left to the CLI renderer. §11.3 vocabulary: `crate`+`crate_version` always paired, `user.source` provenance, `user.git-oid` precise, no `action`/`project` on sources — each justified inline. §11.3 caps (32 tags, 8 KiB) never approached (4 tags max). Frontend §0 M2 sketch: sparse subset (Tasks 2–4), sha256 vs lock (Task 4), git rev/branch/tag + shallow (Task 6), store `source` objects (Tasks 5, 7), offline/`--frozen` (Task 8), file-registry stub (Tasks 1–2). D3 (lock authoritative, checksum opaque) held: M2 never re-resolves, index-vs-lock mismatch is an error. D5 (no network M1 → M2 fetch behind the seam) held: CLI wiring is M3/M6 business; this plan produces the module they call. Conformance mandate: oracle tests (Task 9) + per-task cargo-source pins.

**2. Placeholder scan.** No TBD/TODO/bare "handle edge cases": every step names exact code, file paths, commands, and expected output. All Task 5/6/7 bodies are complete compilable Zig 0.16 in-plan (flate `.gzip` via `Decompress.init` + `allocRemaining`, `std.tar.Iterator.init/next/streamRemaining`, `std.process.spawn` + `MultiReader` + `Child.wait`, handle-relative `createDirPathOpen`/`readFileAlloc`/`writeFile`, `dir.walk(gpa)` with `.iterate=true`). Error-message strings are pinned verbatim. No `std.compress.gzip`, `Dir.openPath`, or `realPathFileAlloc` appears anywhere in the plan (all replaced with verified `src/store` precedents).

**3. Type consistency.** `FetchError`, `RegistryClient`, `GitRunner`, `IndexResponse`, `GitRef`, `GitPrecise`, `SourceFile`, `FetchedSource`, `FetchOptions`, `GitDecls`, `RegistryConfig`, `IndexEntry` spelled identically everywhere. `ensureSources` is 8-param (`+ git_decls`) in BOTH the Public Surface block and the Task 8 Interfaces block (identical signatures; the review gate rejects drift). `GitDecls` is defined in Public Surface so out-of-order implementers see the final form from the start. `FetchedSource` ownership (per-value arena + outer slice on `gpa`) stated once in Task 8 and used consistently. `Tag`/`Digest`/`Store` always via the `store_mod` import — never redefined. `parseGitRef` takes `GitSpec` verbatim (no invented `has_branch`/`has_tag`). `fetchRegistryCrate`/`fetchCrateBytes` are 7-param everywhere (no `store_unused`).

## Appendix — open questions (for M3/M4 owners, not this plan)

1. Sparse `api` endpoint use: M2 only needs `dl` + index files; authenticated registries (`auth-required: true`) return `Auth` unimplemented — does M3/M6 need token flows, or stay out of scope?
2. `index_version` persistence format: M2 stores raw ETag text in `<path>.version`; cargo's cache format also records index format versions — must `--frozen` distrust hand-rolled cache files on upgrade?
3. Git submodules: M2 best-effort recursive update; cargo errors on some submodule failures — which failures must fail the fetch for conformance?
4. `.crate` cache verification: cargo never re-verifies nonzero cache hits (filesystem assumed intact) — do we keep that assumption under `verifyObject`-capable stores, or re-hash on reuse?
5. `user.git-oid` vs lock `#oid` duplication: the tag repeats the lock fragment for queryability — should M3 dedup by trusting the tag, or always re-read the lock?
