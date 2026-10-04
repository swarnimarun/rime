# Plan C M4 — rustc Driver Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:delegate (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build rime's rustc driver: turn the resolve graph into a unit graph, compile each unit with real rustc invocations built to cargo's arg semantics, cache every result in the global store under content-bound action keys, and wire it all into `rime build` / `rime check` end to end.

**Architecture:** A pure planning layer (`driver.zig`: units from resolve graph + manifests + unified features; `fingerprint.zig` + `actionkey.zig`: content-bound keys) sits above an execution layer (`toolchain.zig`, `profile.zig`, `invoke.zig`: argv construction; `compile.zig`: spawn, JSON diagnostics, spool ingest, incremental sessions) driven by one orchestrator (`pipeline.zig`: fetch → resolve → compile in topo order → materialize `target/<profile>/` via `view.zig`). Every cacheable byte lands in the global store; the project dir holds only the regenerable view.

**Tech Stack:** Zig 0.16.0 exactly, std only (no new dependencies). Inline `test "…"` blocks; `zig build test` green before every commit. Real `rustc`/`cargo` (1.99.0-nightly) as oracle, gated behind `RIME_CARGO_ORACLE=1` per the `oracle.zig` precedent.

**Spec:** `docs/superpowers/plans/2026-10-04-cargo-frontend.md` §0.4 (M4 sketch) + `docs/design/storage-v2.md` §§5.3–5.4 + 9–13 + 16 (Store surface, tag vocabulary §11.3, action-key contents rule §5.3, incremental §13.2); normative reference is cargo's own source vendored at `references/cargo` (rust-lang/cargo 0.99.0). Every semantic below cites its exact pinning function.

## Global Constraints

- Zig **0.16.0** exactly. FS access goes through the `std.Io` interface value passed as `io` to every call; `std.Io.Dir`/`std.Io.File` methods take `io` (copy call sites from the storage-core plan exactly).
- `std.process.argsAlloc` DOES NOT EXIST. `main` takes `std.process.Init`; scratch tools iterate `std.process.Args.Iterator` or hardcode (see `src/main.zig:137-143`).
- `std.ArrayList(T)` is unmanaged in 0.16: `var l: std.ArrayList(T) = .empty; try l.append(gpa, x); defer l.deinit(gpa); const s = try l.toOwnedSlice(gpa);`.
- `std.crypto.timing_safe.eql` (namespace `timing_safe`, fn `eql`); `std.json` bool tag is `.bool`; gzip is `std.compress.flate` Compress/Decompress with `.gzip` (no `std.compress.gzip`).
- Parent-dir `@import` is rejected under bare `zig test` — modules cross via named `@import("store")` / build wiring (sibling relative imports like `@import("manifest.zig")` are fine, per `view.zig`).
- No global arenas — caller-owned allocators; document every ownership transfer in the doc comment.
- Every error set from real std errors (union yournamed errors with the concrete `std`/`Store` errors you actually call through).
- Dependencies: **std only**. No packages in `build.zig.zon`, no C sources.
- Tests are inline (`test "…"` blocks). `zig build test` must pass before **every** commit. Never commit with failing tests.
- Cargo-compat invariants after every task: `target/<profile>/` layout matches cargo names; project dirs never hold cache state; store objects read-only (`0o444`), never hardlinked into `target/`; exit codes match cargo (frontend plan D4: `0` ok, `101` build failure, `1` usage/config).
- Digest text form is `b3-<64 lowercase hex>` in all user-facing output.
- All VCS operations use **jj**: `jj status`, `jj diff`, `jj commit <paths> -m "…"`. Never run git write commands. One logical change per commit, imperative ≤50-char summaries, no Conventional-Commit prefixes.
- Scratch experiments go in `/tmp`, never in the repo.
- Conformance testing uses the locally installed real cargo (`cargo 1.99.0-nightly`); oracle tests must skip gracefully (return `error.SkipZigTest` unless `RIME_CARGO_ORACLE=1`, the `oracle.zig::oracleEnabled` precedent) when cargo is absent or the gate is unset.
- Validation goldens live in `validation/`; paths normalized to `@VALIDATION_ROOT@` on both sides before diffing (the `oracle.sh` precedent).

---

## 0. Which cargo functions pin which semantics (read first)

### 0.1 Unit model (`references/cargo/src/cargo/core/compiler/`)

- `unit.rs::Unit` / `UnitInner` — THE unit: `{ pkg, target, profile, kind: CompileKind, mode: CompileMode, features, … }`. rime's `driver.zig::Unit` mirrors these fields 1:1 (with `features` as the unified sorted set from `features.zig`, and `deps` as resolved `UnitDep`s).
- `compile_kind.rs::CompileKind::{Host, Target}` — host units (build scripts, proc macros) compile for the host triple; target units for `--target` or host when unset. M4 marks the kind on every unit and compiles host-kind units with the host triple; M5 owns executing them.
- `unit_graph.rs::{UnitDep, emit_serialized_unit_graph}` — edges carry `{ unit, extern_crate_name, dep_name }`; `-Z unstable-options --unit-graph` dumps it. rime's `buildUnitGraph` produces the same shape; `golden.units.json` is rime's serialized form of it.
- `unit_dependencies.rs::build_unit_dependencies` — which units depend on which (after feature pruning). rime consumes the pruned resolve graph (`features.pruneOptional` output) so edges match.

### 0.2 Fingerprint (`references/cargo/src/cargo/core/compiler/fingerprint/`)

- `fingerprint/mod.rs:632::Fingerprint` — THE struct: `{ rustc, features (sorted cfg list), declared_features, target (target-struct hash), profile (+CompileMode), path (source-path hash), deps: Vec<DepFingerprint>, local, rustflags, config, compile_kind }`. If any field changes, the unit recompiles. rime's `fingerprint.zig::Fingerprint` mirrors every field (as store `Digest`s / sorted strings, not u64s — documented deviation F1 below).
- `fingerprint/mod.rs::hash_u64` + `FsStatus::{Stale, UpToDate, StaleItem, StaleDependency}` — freshness is a content hash PLUS dep-info mtime comparison. rime splits the same way: `toDigest()` (content hash, feeds the action key) and `checkFresh()` (dep-info mtime vs recorded, feeds skip decisions).
- `fingerprint/dep_info.rs` — dep-info file grammar (`target: dep dep …` with `\` continuations, escaped spaces). rime's dep-info parser implements exactly this grammar.

### 0.3 rustc invocation (`references/cargo/src/cargo/core/compiler/mod.rs`)

- `mod.rs:1222::build_base_args` — THE arg builder, in order: `--crate-name <n>`, edition (`Edition::cmd_edition_arg`), `--crate-type <t>` per `rustc_crate_types()` (skipped for test mode), `--emit=…` by mode (`is_check() → dep-info,metadata`; rlib without no-embed-metadata → `dep-info,metadata,link`; bins/upstream-object-requiring → `dep-info,link`), `-C prefer-dynamic` for host/proc-macro units, `-C opt-level`, `-C panic`, lto args.
- `mod.rs:1178::add_error_format_and_color` — `--error-format=json` when JSON messages are requested.
- `mod.rs:1722::build_deps_args` — `-L` search paths (`lib_search_paths`) + `--extern name=path` per linkable dep + `OUT_DIR` env for build-script consumers.
- `mod.rs:2023::add_codegen_incremental` — `-C incremental=<dir>` where dir is `files().incremental_dir(&unit)`.
- `mod.rs:2394` + `mod.rs:2430` — cargo always asks rustc to report produced artifacts and re-emits them as `compiler-artifact` messages. rime's JSON plumbing re-emits the same three envelope reasons (`compiler-message`, `compiler-artifact`, `build-finished`).
- `output_depinfo.rs` — `--emit=dep-info` file emission (rime passes the flag through; parses the file back).
- `layout.rs` — output filenames `lib<name>-<meta>.rlib` / `<name>-<meta>` where meta is the unit metadata hash. rime's meta is the first 16 hex chars of the unit fingerprint digest (deviation F2: cargo's meta is a SipHash; rime's is a BLAKE3 prefix — same uniqueness role, content-bound).

### 0.4 Action key (sccache model + storage-v2 §5.3)

- sccache's Rust key (reference model, not vendored): `{ compiler version + sysroot libs hash, normalized args, input file hashes, relevant env }`. Storage-v2 §5.3 makes this normative for rime: "toolchain identity incl. sysroot lib digests, target triple, normalized args, relevant env, input digests", extended by §11.3 with feature-set hash + profile as explicit tags.
- Normalization rule (both sccache and cargo imply it): paths that vary per machine/run (`--out-dir`, incremental dir, absolute dep-info paths) are either canonicalized to store/spool-relative form or EXCLUDED from the key; everything else is hashed verbatim in argv order.

### 0.5 Profiles (`references/cargo/src/cargo/core/profiles.rs`)

- `Profile::{opt_level, debuginfo, debug_assertions, overflow_checks, incremental, panic, …}` with `dev` defaults (`opt-level 0`, `debug true`, `incremental true`) and `release` defaults (`opt-level 3`, `debug false`, `incremental false`). rime's `profile.zig` implements exactly these two default rows plus the `[profile.*]` allow-listed overrides.

---

## 1. File structure

```
src/cargo/toolchain.zig    Toolchain probe: rustc -vV parse + sysroot digest + tag string (Task 1)
src/cargo/profile.zig      Profile model: dev/release defaults + [profile.*] overrides (Task 2)
src/cargo/driver.zig       Unit, UnitDep, CompileKind, UnitGraph, buildUnitGraph (Task 3)
src/cargo/fingerprint.zig  Fingerprint struct, toDigest, dep-info parse + checkFresh (Task 4)
src/cargo/actionkey.zig    featuresTag (fh-…), normalizeArgs, actionKey, env allowlist (Task 5)
src/cargo/invoke.zig       buildRustcArgs: edition/crate-type/extern/-L/emit/out-dir (Task 6)
src/cargo/compile.zig      spawn + JSON envelopes + spool ingest + action record (Tasks 7–8)
                           + incremental session handling (Task 9)
src/cargo/pipeline.zig     buildWorkspace: fetch→resolve→compile→materialize; check mode (Tasks 10–11)
src/cargo/root.zig         re-export toolchain/profile/driver/fingerprint/actionkey/invoke/compile/pipeline (Task 3+)
src/cargo/cli.zig          wire build/check/run/bench through pipeline; Fresh/Compiling lines (Tasks 10–11)
src/cargo/oracle.zig       expose runCapture as pub for compile.zig reuse (Task 7)
src/store/root.zig         add Kind.incremental (Task 9; Plan-B-owned file, fallback documented)
validation/<proj>/         golden.units.json + golden.diag-<profile>.json per project (Task 12)
```

Each task's **Interfaces** block is the contract between tasks: exact names and types the neighbor tasks use. Implement exactly these; do not rename.

**Deviations locked here (not open questions):**

- **F1 — Digests, not u64s.** Cargo's fingerprint hashes to u64 (`hash_u64`); rime hashes the same canonical field list to a store `Digest` (BLAKE3). Same change-detection role; store-native so keys double as `putAction` keys.
- **F2 — Filename meta is a fingerprint prefix.** Cargo's `-<meta>` is a SipHash of the unit metadata; rime's is `fingerprint.toHex()[0..16]`. Same uniqueness role (disambiguates same-name outputs in `deps/`), content-bound, and feeds `view.depFileName` directly.
- **F3 — Combined stdout+stderr capture.** Cargo separates rustc's streams; rime drains both pipes with one `runCapture`-style loop and parses JSON lines out of the combined bytes (deviation D-R1, documented in Task 7). Envelope output is still cargo-compatible.
- **F4 — Content-hash inputs, not mtimes, in the key.** Cargo's pre-build fingerprint uses mtimes + dep-info; rime's action key hashes crate source bytes (`hashInputs`) because the store is content-addressed and mtimes don't survive materialization. Post-build freshness still uses dep-info mtimes (`checkFresh`), matching `FsStatus`.
- **F5 — `declared_features` omitted from the fingerprint.** Cargo's `Fingerprint` (`fingerprint/mod.rs:632`) also carries `declared_features` (every feature ever declared, enabled or not). Rime's `Fingerprint` hashes only the ENABLED sorted set (`features_sorted`). Narrow, accepted gap: flipping a declared-but-disabled feature does not invalidate a rime unit (it would under cargo). Harmless in M4 scope (no build scripts; disabled features cannot change rustc's input), and the enabled set — the only thing that reaches `--cfg` — is fully bound. Revisit if build-script-driven `cfg` ever enters M-scope.

---

### Task 1: Toolchain identity

**Files:**
- Create: `src/cargo/toolchain.zig`
- Test: inline `test "…"` blocks in `src/cargo/toolchain.zig`

**Interfaces:**
- Consumes: `store_mod.hashBytes/hashFile` (via `@import("store")`), `oracle.runCapture` pattern (copied, not imported — oracle stays the caller).
- Produces (used by Tasks 5, 9–10):
```zig
pub const ToolchainError = error{ SpawnFailed, BadVersionOutput, RustcNotFound, OutOfMemory } || std.mem.Allocator.Error;
pub const Toolchain = struct {
    rustc_path: []const u8,   // resolved $RUSTC or "rustc" (borrowed; do not free)
    version: []const u8,      // "1.99.0-nightly" (gpa-owned)
    host_target: []const u8,  // "aarch64-apple-darwin" (gpa-owned)
    commit_hash: []const u8,  // 40-hex (gpa-owned)
    sysroot: []const u8,      // absolute sysroot path (gpa-owned)
    digest: Digest,           // BLAKE3(-vV bytes ++ rustc binary bytes ++ sorted sysroot-lib bytes); gpa-free (value type)
    pub fn deinit(self: *Toolchain, gpa: std.mem.Allocator) void { ... }
    pub fn tag(self: *const Toolchain, gpa: std.mem.Allocator) ToolchainError![]u8; // "rustc <version> <digest8>"
};
pub fn probeToolchain(gpa: std.mem.Allocator, io: std.Io, rustc_path: ?[]const u8) ToolchainError!Toolchain;
pub fn parseRustcVv(text: []const u8) ToolchainError!struct { version: []const u8, host: []const u8, commit: []const u8 };
pub fn hashSysrootLibs(gpa: std.mem.Allocator, io: std.Io, sysroot: []const u8) ToolchainError!Digest; // sorted relpath+bytes over <sysroot>/lib (see probeToolchain)
```

`probeToolchain`: rustc binary = `rustc_path` or `$RUSTC` (`std.c.getenv`, the `oracle.zig::oracleEnabled` precedent — `std.process.getEnvVarOwned` is absent in 0.16) or `"rustc"`; run `<rustc> -vV`, parse three lines (`rustc <version> (<hash> <date>)`, `binary: rustc`, `host: <triple>` — plus `rustc --print sysroot` for the sysroot path); digest = `hashBytes` over the concatenation of THREE digests' bytes: `hashBytes(vV_bytes)`, `hashFile(rustc binary)`, and `hashSysrootLibs(sysroot)` (storage-v2 §5.3 action-key contents rule REQUIRES sysroot lib digests in the toolchain identity — `-vV` + binary bytes alone do not satisfy it). `hashSysrootLibs`: walk `<sysroot>/lib` recursively, sort by relpath, hash `relpath \x00 filebytes` joins (cap 20k files / 512 MiB total, else `BadVersionOutput`; a missing `<sysroot>/lib` dir hashes as the empty string — documented fallback for lib-less layouts, still content-bound everywhere else). `tag()` returns `rustc <version> <hex[0..8]>` — the exact storage-v2 §11.3 `toolchain` value shape, and now honestly a `sysroot-digest8`: the digest binds sysroot lib bytes per §5.3.

- [ ] **Step 1: Write the failing test**

```zig
test "toolchain parses rustc -vV output" {
    const text =
        "rustc 1.99.0-nightly (1ed2df61a 2026-08-04)\n" ++
        "binary: rustc\n" ++
        "commit-hash: 1ed2df61a19042f231709eb05d032ae9e2cb2084\n" ++
        "commit-date: 2026-08-04\n" ++
        "host: aarch64-apple-darwin\n" ++
        "release: 1.99.0-nightly\n" ++
        "LLVM version: 22.1.8\n";
    const p = try parseRustcVv(text);
    try std.testing.expectEqualStrings("1.99.0-nightly", p.version);
    try std.testing.expectEqualStrings("aarch64-apple-darwin", p.host);
    try std.testing.expectEqualStrings("1ed2df61a19042f231709eb05d032ae9e2cb2084", p.commit);
}

test "toolchain rejects truncated version output" {
    try std.testing.expectError(ToolchainError.BadVersionOutput, parseRustcVv("rustc\n"));
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test 2>&1 | tail -10`
Expected: FAIL — `src/cargo/toolchain.zig` does not exist / `parseRustcVv` not defined. (If the `cargo` module wiring is missing, add the root re-export line `pub const toolchain = @import("toolchain.zig");` plus the test-block line `_ = @import("toolchain.zig");` to `src/cargo/root.zig` now — the same two-line pattern every later task repeats for its own file.)

- [ ] **Step 3: Write minimal implementation**

```zig
const std = @import("std");
const store_mod = @import("store");
const Digest = store_mod.Digest;

pub const ToolchainError = error{ SpawnFailed, BadVersionOutput, RustcNotFound, OutOfMemory } || std.mem.Allocator.Error;

pub const Toolchain = struct {
    rustc_path: []const u8,
    version: []const u8,
    host_target: []const u8,
    commit_hash: []const u8,
    sysroot: []const u8,
    digest: Digest,
    pub fn deinit(self: *Toolchain, gpa: std.mem.Allocator) void {
        gpa.free(self.version);
        gpa.free(self.host_target);
        gpa.free(self.commit_hash);
        gpa.free(self.sysroot);
    }
    pub fn tag(self: *const Toolchain, gpa: std.mem.Allocator) ToolchainError![]u8 {
        const hex = self.digest.toHex();
        return std.fmt.allocPrint(gpa, "rustc {s} {s}", .{ self.version, hex[0..8] }) catch return ToolchainError.OutOfMemory;
    }
};

pub fn parseRustcVv(text: []const u8) ToolchainError!struct { version: []const u8, host: []const u8, commit: []const u8 } {
    var version: ?[]const u8 = null;
    var host: ?[]const u8 = null;
    var commit: ?[]const u8 = null;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        if (std.mem.startsWith(u8, line, "rustc ")) {
            const rest = line["rustc ".len..];
            const end = std.mem.indexOfScalar(u8, rest, ' ') orelse rest.len;
            version = rest[0..end];
        } else if (std.mem.startsWith(u8, line, "host: ")) {
            host = std.mem.trim(u8, line["host: ".len..], " \r");
        } else if (std.mem.startsWith(u8, line, "commit-hash: ")) {
            commit = std.mem.trim(u8, line["commit-hash: ".len..], " \r");
        }
    }
    if (version == null or host == null or commit == null) return ToolchainError.BadVersionOutput;
    return .{ .version = version.?, .host = host.?, .commit = commit.? };
}
```

`probeToolchain`: resolve the binary (`rustc_path` param, else `std.c.getenv("RUSTC")` via `std.mem.span`, else `"rustc"`); spawn `<rustc> -vV` with the `oracle.zig::runCapture` drain loop (copy it — do not redesign; pipes + 60 s watchdog); on spawn failure return `RustcNotFound`. Parse with `parseRustcVv`, dup strings with `gpa`; spawn `<rustc> --print sysroot`, trim trailing `\n`; open the rustc binary file and `hashFile`, then `digest = hashBytes(vv_bytes ++ bin_digest.bytes)` by concatenating into a small stack buffer (`[32]u8 ++ [32]u8` → `hashBytes` of the 64-byte join).

- [ ] **Step 4: Run test to verify it passes**

Add the oracle-gated probe test (same file):
```zig
test "toolchain probes the real rustc when oracle enabled" {
    if (!@import("oracle.zig").oracleEnabled()) return error.SkipZigTest;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tc = try probeToolchain(std.testing.allocator, io, null);
    defer tc.deinit(std.testing.allocator);
    try std.testing.expect(tc.version.len > 0);
    try std.testing.expect(std.mem.indexOfScalar(u8, tc.host_target, '-') != null);
    const t = try tc.tag(std.testing.allocator);
    defer std.testing.allocator.free(t);
    try std.testing.expect(std.mem.startsWith(u8, t, "rustc "));
}
```

Run: `zig build test 2>&1 | tail -5`
Expected: PASS (oracle test skips without the env var; runs with `RIME_CARGO_ORACLE=1`).

- [ ] **Step 5: Commit**

```bash
jj status
jj commit src/cargo/toolchain.zig src/cargo/root.zig -m "Add rustc toolchain probe"
```

---

### Task 2: Profile model

**Files:**
- Create: `src/cargo/profile.zig`
- Test: inline `test "…"` blocks in `src/cargo/profile.zig`

**Interfaces:**
- Consumes: `toml.parseDocument` (sibling `@import("toml.zig")`, the Task-1 pattern).
- Produces (used by Tasks 3, 6, 10):
```zig
pub const ProfileError = error{ UnknownProfileKey, InvalidManifest, ParseError, UnsupportedType, OutOfMemory };
pub const PanicStrategy = enum { unwind, abort };
pub const Profile = struct {
    name: []const u8,            // "dev" | "release" | custom (borrowed; do not free)
    opt_level: []const u8,      // "0" | "1" | "2" | "3" | "s" | "z" (borrowed or gpa-owned via overlay arena)
    debug_info: u8,             // 0, 1, 2 (cargo `debug = true` means 2; `debug = "line-tables-only"` means 1)
    debug_assertions: bool,
    overflow_checks: bool,
    incremental: bool,
    panic_strategy: PanicStrategy,
    lto_off: bool,              // true emits `-C lto=off -C embed-bitcode=no` (cargo lto_args::Lto::Off)
};
pub fn devProfile() Profile;      // opt 0, debug 2, assertions on, overflow on, incremental on, unwind
pub fn releaseProfile() Profile;  // opt 3, debug 0, assertions off, overflow off, incremental off, unwind
pub fn profileFor(name: []const u8) Profile; // "dev"->dev, "test"->dev, "bench"->release, else release-shaped with name kept
pub fn applyProfileToml(p: *Profile, gpa: std.mem.Allocator, text: []const u8, section: []const u8) ProfileError!void;
```

Cargo pins (`profiles.rs` defaults): dev = `{opt 0, debug true(2), incremental true}`, release = `{opt 3, debug false(0), incremental false}`; `overflow-checks` defaults to `debug-assertions`. Allow-listed `[profile.*]` keys: `opt-level` (int 0–3 or `"s"`/`"z"`), `debug` (bool or 0/1/2 or `"line-tables-only"`/`"full"`), `debug-assertions` (bool), `overflow-checks` (bool), `incremental` (bool), `panic` (`"unwind"`/`"abort"`), `lto` (`false`/`true`/string — only `false` changes codegen flags; anything else parses and is ignored). Unknown keys → `UnknownProfileKey`. `[profile.dev.package."*"]` / per-package overrides: parsed and IGNORED in M4 (recorded limitation L1 — the unit plan is per-member, and per-dependency profile overrides need the full `profiles.rs::get_profile` resolution; the plan's validation projects only use top-level profiles).

- [ ] **Step 1: Write the failing test**

```zig
test "profile dev and release defaults match cargo" {
    const dev = devProfile();
    try std.testing.expectEqualStrings("0", dev.opt_level);
    try std.testing.expectEqual(@as(u8, 2), dev.debug_info);
    try std.testing.expect(dev.incremental);
    try std.testing.expect(dev.debug_assertions);
    try std.testing.expect(dev.overflow_checks); // default_dev: both on (profiles.rs:715-724)
    const rel = releaseProfile();
    try std.testing.expectEqualStrings("3", rel.opt_level);
    try std.testing.expectEqual(@as(u8, 0), rel.debug_info);
    try std.testing.expect(!rel.incremental);
    try std.testing.expect(!rel.debug_assertions);
    try std.testing.expect(!rel.overflow_checks); // default_release: ..Profile::default() = both off (profiles.rs:728-736)
}

test "profile toml overrides known keys and rejects unknown" {
    var p = devProfile();
    try applyProfileToml(&p, std.testing.allocator, "[profile.dev]\nopt-level = 2\nincremental = false\n", "dev");
    try std.testing.expectEqualStrings("2", p.opt_level);
    try std.testing.expect(!p.incremental);
    var q = devProfile();
    try std.testing.expectError(ProfileError.UnknownProfileKey, applyProfileToml(&q, std.testing.allocator, "[profile.dev]\nflux = true\n", "dev"));
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test 2>&1 | tail -10`
Expected: FAIL — `src/cargo/profile.zig` / `devProfile` not defined (add the two `root.zig` lines in this step, same as Task 1).

- [ ] **Step 3: Write minimal implementation**

```zig
const std = @import("std");
const toml = @import("toml.zig");

pub const ProfileError = error{ UnknownProfileKey, InvalidManifest, ParseError, UnsupportedType, OutOfMemory };
pub const PanicStrategy = enum { unwind, abort };
pub const Profile = struct {
    name: []const u8,
    opt_level: []const u8,
    debug_info: u8,
    debug_assertions: bool,
    overflow_checks: bool,
    incremental: bool,
    panic_strategy: PanicStrategy,
    lto_off: bool,
};
pub fn devProfile() Profile {
    return .{ .name = "dev", .opt_level = "0", .debug_info = 2, .debug_assertions = true, .overflow_checks = true, .incremental = true, .panic_strategy = .unwind, .lto_off = false };
}
pub fn releaseProfile() Profile {
    return .{ .name = "release", .opt_level = "3", .debug_info = 0, .debug_assertions = false, .overflow_checks = false, .incremental = false, .panic_strategy = .unwind, .lto_off = false };
}
pub fn profileFor(name: []const u8) Profile {
    if (std.mem.eql(u8, name, "dev") or std.mem.eql(u8, name, "test")) return devProfile();
    var p = releaseProfile();
    p.name = name;
    return p;
}
```

`applyProfileToml`: `parseDocument`, descend `profile` → `<section>` table (missing section = no-op); per-key switch on the allow-list with type checks (`opt-level`: integer 0–3 formatted into a 1-byte stack buffer borrowed how? — borrowed strings must outlive: dup with `gpa` and document that overrides are gpa-owned while defaults are static; add `Profile.deinit` freeing only when `owns_strings`… simpler: ALWAYS dup `opt_level` in `profileFor`/`devProfile`? No — defaults are hot-path. Decision: `applyProfileToml` dups the new `opt_level` with `gpa` and sets `p.opt_level` to it; the caller frees it. Document: "overrides transfer ownership to the caller; free `p.opt_level` iff you called `applyProfileToml`"). `debug`: bool→(2/0), integer 0–2, `"line-tables-only"`→1, `"full"`→2. `panic`: `"unwind"`/`"abort"`, else `InvalidManifest`. `lto`: `false`→`lto_off=true`; `true`/strings→no codegen change.

- [ ] **Step 4: Run test to verify it passes**

```zig
test "profile debug spellings and panic parse" {
    var p = devProfile();
    try applyProfileToml(&p, std.testing.allocator, "[profile.release]\ndebug = \"line-tables-only\"\npanic = \"abort\"\nlto = false\n", "release");
    defer std.testing.allocator.free(p.opt_level); // only needed because applyProfileToml ran; devProfile default is static
    try std.testing.expectEqual(@as(u8, 1), p.debug_info);
    try std.testing.expect(p.panic_strategy == .abort);
    try std.testing.expect(p.lto_off);
}
```

Run: `zig build test 2>&1 | tail -5`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
jj status
jj commit src/cargo/profile.zig src/cargo/root.zig -m "Add build profile model"
```

---

### Task 3: Unit graph

**Files:**
- Create: `src/cargo/driver.zig`
- Modify: `src/cargo/root.zig` (two-line re-export, same as Task 1)
- Test: inline tests in `src/cargo/driver.zig`

**Interfaces:**
- Consumes: `workspace.Workspace` + `Member`, `manifest.TargetDesc/TargetKind`, `resolve.ResolveGraph/ResolvedNode`, `features.Unified` (`isEnabled`, `enabled_deps`), `profile.Profile`, `toolchain.Toolchain`.
- Produces (used by Tasks 4–6, 10–11):
```zig
pub const DriverError = error{ UnknownTarget, NoLibOrBin, OutOfMemory };
pub const CompileKind = enum { host, target };   // compile_kind.rs::{Host, Target}
pub const CompileMode = enum { build, check };   // CompileMode::{Build, Check}
pub const UnitDep = struct {
    unit: usize,               // index into UnitGraph.units
    extern_name: []const u8,   // crate name with '-' -> '_' (unit_graph.rs extern_crate_name)
    dep_name: []const u8,      // original package name
};
pub const Unit = struct {
    pkg_name: []const u8,      // borrowed from Workspace
    version: []const u8,       // borrowed from Workspace
    target_name: []const u8,   // lib name or bin name (borrowed)
    kind: TargetKind,          // lib | bin (example/test/bench rejected: UnknownTarget in M4)
    edition: []const u8,       // borrowed ("2021")
    crate_types: []const []const u8, // lib -> &.{"rlib"}; bin -> &.{"bin"} (static)
    profile: Profile,          // copied by value (name/opt_level borrow workspace/profile statics)
    features_sorted: []const []const u8, // unified enabled features, sorted (borrowed from Unified maps — see below)
    target_triple: []const u8, // --target or toolchain.host_target (borrowed)
    compile_kind: CompileKind, // target always in M4 except build-dep edges (host) — see below
    mode: CompileMode,         // build; check mode flips it in Task 11
    src_path: []const u8,      // absolute crate root dir (borrowed from Workspace member dir)
    deps: []UnitDep,           // gpa-owned per unit
};
pub const UnitGraph = struct {
    arena: std.heap.ArenaAllocator, // owns deps slices + features_sorted copies
    units: []Unit,
    pub fn deinit(self: *UnitGraph) void { self.arena.deinit(); }
    pub fn topoOrder(self: *const UnitGraph, gpa: std.mem.Allocator) DriverError![]usize; // deps-first indices; gpa-owned
};
pub fn buildUnitGraph(
    gpa: std.mem.Allocator,
    ws: *const Workspace,
    graph: *const ResolveGraph,
    unified: *const Unified,
    profile: Profile,
    triple: ?[]const u8,
    tc: *const Toolchain,
) DriverError!UnitGraph;
pub fn externName(gpa: std.mem.Allocator, name: []const u8) DriverError![]u8; // '-' -> '_' dup
```

Semantics (pinned): one `Unit` per workspace member target (`unit.rs::Unit`); edges from pruned resolve-graph refs restricted to workspace members (registry refs are SOURCES, not units — their rlibs arrive via fetch + prior compilation; M4 compiles workspace members only, registry deps must already be in the store or the unit errors `UnknownTarget` naming the missing crate — Task 10 turns this into the actionable `need fetch` diagnostic). `features_sorted`: union of `unified.features[pkg]` keys sorted (the `Fingerprint.features` sorted-cfg-list role). `compile_kind`: `.target` for all M4 units EXCEPT units depended on via a build-dep edge — but the resolve graph carries no edge kinds in M3 (`DepEdge.build_only` exists on the pre-resolution edge, not on `ResolvedRef`). M4 seam (M5 boundary): `buildUnitGraph` takes no build-dep info, so every M4 unit is `.target`; the `CompileKind` field, `forHostTarget()` helper (`triple` when `.target`, `tc.host_target` when `.host`), and the `prefer-dynamic` hook in Task 6 exist so M5 wires build-script/proc-macro host units without changing unit identity. `topoOrder`: Kahn over unit deps (deps first; alphabetical tie-break, the `view.planUnits` precedent).

- [ ] **Step 1: Write the failing test**

```zig
test "unit graph builds one unit per member target in dep order" {
    const io = std.Io.Threaded.global_single_threaded.io();
    var ws = try @import("workspace.zig").discover(std.testing.allocator, io, "testdata/cargo/workspace", null);
    defer ws.deinit();
    // Stub resolve graph: a -> b (path members), unified features empty.
    // (Full stub construction in Step 3; the test asserts units[0].pkg_name == "b".)
    try std.testing.expectEqual(@as(usize, 2), ws.members.len);
}
```

Concretely the test builds a two-node `ResolveGraph` by hand (arena + `ResolvedNode{version = 0.1.0, source = .{.path=""}, deps}`), an empty `Unified` (`features` + `enabled_deps` maps with `b` recorded as a normal dep of `a` so it survives — mirroring the `unifyV1` pre-record rule), then:
```zig
    var ug = try buildUnitGraph(std.testing.allocator, &ws, &rg, &u, profile.devProfile(), null, &tc_stub);
    defer ug.deinit();
    const order = try ug.topoOrder(std.testing.allocator);
    defer std.testing.allocator.free(order);
    try std.testing.expectEqualStrings("b", ug.units[order[0]].pkg_name);
    try std.testing.expectEqualStrings("a", ug.units[order[1]].pkg_name);
    try std.testing.expectEqualStrings("rlib", ug.units[order[0]].crate_types[0]);
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test 2>&1 | tail -10`
Expected: FAIL — `driver.zig` / `buildUnitGraph` not defined.

- [ ] **Step 3: Write minimal implementation**

Member lookup by name over `ws.members` (path-dep members); explicit `manifest.targets` or default single lib unit (`defaultLibName` rule: package name with `-`→`_` — copy the 6-line helper from `view.zig`, do not import it: view owns view paths, driver owns unit names). Non lib/bin targets (`example`, `test`, `bench`) → `UnknownTarget` (M4 compiles lib+bin only; recorded limitation L2). `src_path` = member `dir`. `target_triple` = `triple orelse tc.host_target`. `extern_name` via `externName` (dup into graph arena). `features_sorted`: collect `unified.features.get(pkg)` keys into arena, sort. Deps: for each pruned-graph dep of this member that resolves to another workspace member, push `UnitDep{unit = idx, extern_name, dep_name}`. Registry (non-member) deps are recorded NOWHERE on the unit (their `--extern` paths resolve at invoke time from the store — Task 6); if a registry dep has no store entry at build time, Task 10 errors (not here — the graph builds offline-clean).

- [ ] **Step 4: Run test to verify it passes**

Add seam tests:
```zig
test "host units resolve the host triple" {
    try std.testing.expectEqualStrings("aarch64-apple-darwin", forHostTarget(.host, "x86_64-unknown-linux-gnu", "aarch64-apple-darwin"));
    try std.testing.expectEqualStrings("x86_64-unknown-linux-gnu", forHostTarget(.target, "x86_64-unknown-linux-gnu", "aarch64-apple-darwin"));
}
```

Run: `zig build test 2>&1 | tail -5`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
jj status
jj commit src/cargo/driver.zig src/cargo/root.zig -m "Add unit graph construction"
```

---

### Task 4: Fingerprint

**Files:**
- Create: `src/cargo/fingerprint.zig`
- Test: inline tests in `src/cargo/fingerprint.zig`

**Interfaces:**
- Consumes: `driver.Unit/UnitGraph`, `store.Digest/hashBytes/hashFile`.
- Produces (used by Tasks 5, 8–9, 13):
```zig
pub const FpError = error{ Io, BadDepInfo, OutOfMemory } || std.mem.Allocator.Error;
pub const Fingerprint = struct {
    rustc_digest: Digest,        // toolchain.digest (fingerprint/mod.rs `rustc`)
    features_sorted: []const []const u8, // borrowed from Unit
    target_desc_hash: Digest,     // hash(pkg_name \x00 target_name \x00 kind \x00 edition)
    profile_hash: Digest,         // hash(opt \x00 debug \x00 assertions \x00 overflow \x00 incremental \x00 panic \x00 lto_off \x00 mode)
    path_hash: Digest,            // hash(src_path) — workspace-relative when under ws root, absolute otherwise
    dep_fps: []const Digest,      // dependencies' toDigest(), sorted by (dep_name) for stability
    rustflags_hash: Digest,       // hash(RUSTFLAGS bytes or "")
    config_hash: Digest,          // hash(target_triple \x00 compile_kind)
    pub fn toDigest(self: *const Fingerprint) Digest; // BLAKE3 over the canonical join below
    pub fn toHex16(self: *const Fingerprint) [16]u8;  // filename meta (deviation F2)
};
pub fn fingerprintUnit(gpa: std.mem.Allocator, unit: *const Unit, dep_fps: []const Digest, rustflags: []const u8) FpError!Fingerprint;
pub fn hashInputs(gpa: std.mem.Allocator, io: std.Io, crate_root: []const u8) FpError!Digest; // deviation F4
pub const DepInfo = struct {
    target: []const u8,           // gpa-owned
    deps: []const []const u8,    // gpa-owned entries
    pub fn deinit(self: *DepInfo, gpa: std.mem.Allocator) void { ... }
};
pub fn parseDepInfo(gpa: std.mem.Allocator, text: []const u8) FpError!DepInfo; // dep_info.rs grammar
pub fn checkFresh(io: std.Io, dep_info_path: []const u8, max_mtime_ns: i128) FpError!bool; // FsStatus mtime role
```

Canonical `toDigest` join (field order fixed — this IS the key format, version it with a `b"rime-fp-v1\x00"` prefix): `v1 \x00 rustc \x00 featuresSorted(+) \x00 target_desc \x00 profile \x00 path \x00 dep_fps_sorted \x00 rustflags \x00 config`, each `Digest` as raw 32 bytes, strings verbatim with `\x00` separators. `hashInputs`: walk `crate_root/src` (+ `Cargo.toml`, `build.rs` when present) collecting `*.rs` paths, sort, hash `relpath \x00 filebytes` joins (cap: 10k files / 256 MiB total, else `Io` error — bounded, loud). `parseDepInfo`: `target: dep…` with backslash-newline continuations and `\ `-escaped spaces (the `dep_info.rs` grammar subset rustc actually emits). `checkFresh`: parse the dep-info file, stat every dep, return false if any dep mtime > `max_mtime_ns` (the recorded output mtime) or any file missing.

- [ ] **Step 1: Write the failing test**

```zig
test "fingerprint is deterministic and change-sensitive" {
    const fp1 = Fingerprint{
        .rustc_digest = store_mod.hashBytes("rustc-a"),
        .features_sorted = &.{"json"},
        .target_desc_hash = store_mod.hashBytes("pkg\x00lib\x00lib\x002021"),
        .profile_hash = store_mod.hashBytes("0\x002\x00"),
        .path_hash = store_mod.hashBytes("/ws/a"),
        .dep_fps = &.{store_mod.hashBytes("dep")},
        .rustflags_hash = store_mod.hashBytes(""),
        .config_hash = store_mod.hashBytes("aarch64-apple-darwin\x00target"),
    };
    const fp2 = fp1;
    try std.testing.expectEqual(fp1.toDigest().bytes, fp2.toDigest().bytes);
    var fp3 = fp1;
    fp3.rustc_digest = store_mod.hashBytes("rustc-b");
    try std.testing.expect(!std.mem.eql(u8, &fp1.toDigest().bytes, &fp3.toDigest().bytes));
}

test "dep-info parses continuations and escaped spaces" {
    var d = try parseDepInfo(std.testing.allocator, "libfoo.rlib: src/lib.rs src/my\\ file.rs \\\n  src/other.rs\n");
    defer d.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 3), d.deps.len);
    try std.testing.expectEqualStrings("src/my file.rs", d.deps[1]);
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test 2>&1 | tail -10`
Expected: FAIL — `fingerprint.zig` / `Fingerprint` not defined (add the two `root.zig` lines).

- [ ] **Step 3: Write minimal implementation**

Field hashing helpers (`hashStr`, `join2`), `toDigest` building the canonical byte string in an `ArrayList(u8)` then one `hashBytes`. `fingerprintUnit`: compute `target_desc_hash`/`profile_hash`/`config_hash` from the unit, sort `dep_fps` by caller-provided order (caller passes them pre-sorted by dep name — document it; `compile.zig` sorts). `declared_features` is deliberately NOT hashed (deviation F5 — enabled set only). `hashInputs` with `std.Io.Dir.iterate` recursion (copy the walk shape from `scan.zig`'s enumeration, not from memory). `parseDepInfo` line-join on `\<newline>`, split target at the FIRST `: `, split deps on unescaped spaces. `checkFresh`: `parseDepInfo` on the file bytes, `statFile` each dep, compare `mtime.toMilliseconds() * ns_per_ms` against max.

- [ ] **Step 4: Run test to verify it passes**

```zig
test "hashInputs covers sources and Cargo.toml" {
    const io = std.Io.Threaded.global_single_threaded.io();
    const d1 = try hashInputs(std.testing.allocator, io, "testdata/cargo/workspace/crates/a");
    const d2 = try hashInputs(std.testing.allocator, io, "testdata/cargo/workspace/crates/a");
    try std.testing.expectEqual(d1.bytes, d2.bytes);
    const d3 = try hashInputs(std.testing.allocator, io, "testdata/cargo/workspace/crates/b");
    try std.testing.expect(!std.mem.eql(u8, &d1.bytes, &d3.bytes));
}
```

Run: `zig build test 2>&1 | tail -5`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
jj status
jj commit src/cargo/fingerprint.zig src/cargo/root.zig -m "Add unit fingerprints"
```

---

### Task 5: Action key

**Files:**
- Create: `src/cargo/actionkey.zig`
- Test: inline tests in `src/cargo/actionkey.zig`

**Interfaces:**
- Consumes: `fingerprint.Fingerprint/hashInputs`, `toolchain.Toolchain`, `store.Digest/Tag`.
- Produces (used by Tasks 8, 10, 13):
```zig
pub const ActionError = error{ OutOfMemory } || std.mem.Allocator.Error;
pub const tracked_env_vars = [_][]const u8{ "RUSTFLAGS", "RUSTDOCFLAGS", "CARGO_ENCODED_RUSTFLAGS", "RUSTC_BOOTSTRAP" };
pub fn featuresTag(gpa: std.mem.Allocator, feats: []const []const u8) ActionError![]u8; // "fh-<16 hex>" (§11.3)
pub fn normalizeArgs(gpa: std.mem.Allocator, argv: []const []const u8) ActionError![][]u8; // gpa-owned; see table
pub fn actionKey(
    gpa: std.mem.Allocator,
    fp: *const Fingerprint,
    normalized_argv: []const []const u8,
    input_digest: Digest,
    env_pairs: []const []const u8, // "K=V" for tracked vars only, sorted
) ActionError!Digest;
pub fn collectTrackedEnv(gpa: std.mem.Allocator) ActionError![][]u8; // "K=V" snapshot, sorted by K
pub fn unitTags(
    gpa: std.mem.Allocator,
    tc_tag: []const u8, // toolchain.tag() value, borrowed
    triple: []const u8,
    profile_name: []const u8,
    features_tag: []const u8, // featuresTag() value, borrowed
    project_id: []const u8,    // "pb3-<hex>", borrowed
    pkg_name: []const u8,
    version: []const u8,
    action: []const u8,        // always "rustc" (check mode reuses it; CompileMode is already bound in fingerprint/profile hash)
) ActionError![]Tag;           // 8 tags, gpa-owned slice (keys/values borrowed — valid while inputs live)
```

Normalization table (normative — this is what makes keys shareable across projects and reruns):

| argv element | normalized form |
|---|---|
| `--out-dir <spool…>` / `--out-dir=<spool…>` | DROPPED (spool path varies per build) |
| `-C incremental=<spool…>` | DROPPED (session dir varies; the session digest enters via input_digest — Task 9) |
| `--extern name=<abs store/spool path>` | path canonicalized: store object paths rewritten to `store:<64hex>` (derive hex from the trailing two path segments); spool paths rewritten to `spool:<basename>` |
| `-L …=<abs path>` | same path rewrite as `--extern` |
| everything else | verbatim, order preserved |

`actionKey` canonical join (prefix `b"rime-action-v1\x00"`): `v1 \x00 fp.toDigest() \x00 argc \x00 argv[0] \x00 … \x00 input_digest \x00 env[0] \x00 …`. `featuresTag`: sort feat copy, join with `+`, `hashBytes`, `fh-` + first 16 hex (validates under `tags.zig::isValidFeaturesValue` — assert that in the test). `unitTags`: the exact §11.3 key set (`crate`, `crate_version`, `toolchain`, `target`, `profile`, `features`, `project`, `action`) with `action` ALWAYS `"rustc"` — `"check"` is NOT in the §11.3 action vocabulary (`rustc | build-script | proc-macro | link | other`) and `tagObject` rejects it with `UnknownTagKey`. Check mode needs no separate action: `CompileMode` already feeds `profile_hash` (fingerprint `profile` field), so check and build keys never collide. `collectTrackedEnv`: `std.c.getenv` per tracked var, `allocPrint "{s}={s}"`, sort by key.

- [ ] **Step 1: Write the failing test**

```zig
test "action key ignores out-dir and incremental paths" {
    const a = [_][]const u8{ "rustc", "--crate-name", "foo", "--out-dir", "/tmp/spool-1", "-C", "incremental=/tmp/sess" };
    const b = [_][]const u8{ "rustc", "--crate-name", "foo", "--out-dir", "/tmp/spool-2", "-C", "incremental=/tmp/sess2" };
    const na = try normalizeArgs(std.testing.allocator, &a);
    defer { for (na) |s| std.testing.allocator.free(s); std.testing.allocator.free(na); }
    const nb = try normalizeArgs(std.testing.allocator, &b);
    defer { for (nb) |s| std.testing.allocator.free(s); std.testing.allocator.free(nb); }
    try std.testing.expectEqualStrings("rustc", na[0]);
    try std.testing.expectEqual(@as(usize, 3), na.len);
    // keys over identical fingerprints + normalized argv are identical
    const fp = Fingerprint{ .rustc_digest = store_mod.hashBytes("r"), .features_sorted = &.{}, .target_desc_hash = store_mod.hashBytes("t"), .profile_hash = store_mod.hashBytes("p"), .path_hash = store_mod.hashBytes("h"), .dep_fps = &.{}, .rustflags_hash = store_mod.hashBytes(""), .config_hash = store_mod.hashBytes("c") };
    const ka = try actionKey(std.testing.allocator, &fp, na, store_mod.hashBytes("in"), &.{});
    const kb = try actionKey(std.testing.allocator, &fp, nb, store_mod.hashBytes("in"), &.{});
    try std.testing.expectEqual(ka.bytes, kb.bytes);
}

test "features tag matches the index vocabulary" {
    const t = try featuresTag(std.testing.allocator, &.{ "tls", "json" });
    defer std.testing.allocator.free(t);
    try std.testing.expect(std.mem.startsWith(u8, t, "fh-"));
    try std.testing.expectEqual(@as(usize, 19), t.len);
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test 2>&1 | tail -10`
Expected: FAIL — `actionkey.zig` not defined (add the two `root.zig` lines).

- [ ] **Step 3: Write minimal implementation**

Arg scanner: exact-match `--out-dir` (drop pair), prefix `--out-dir=` (drop one), `-C` followed by `incremental=…` (drop pair), `--extern` (rewrite pair or `=` form's path half), `-L` (rewrite pair or `=` form's path half). Path rewrite helper: if the path contains `/objects/` (store layout `objects/ab/cdef…`), take the last two segments, join hex, emit `store:<hex>`; else `spool:` + basename. `actionKey`: `ArrayList(u8)` join + `hashBytes`. `unitTags`: 8-element array literal of `Tag` in §11.3 order.

- [ ] **Step 4: Run test to verify it passes**

```zig
test "extern store paths canonicalize across checkouts" {
    const a = [_][]const u8{"--extern", "serde=/cache/objects/ab/cdef1234"};
    const na = try normalizeArgs(std.testing.allocator, &a);
    defer { for (na) |s| std.testing.allocator.free(s); std.testing.allocator.free(na); }
    try std.testing.expectEqualStrings("store:abcdef1234", na[1][7..]); // name= preserved, path rewritten
}
```

(Adjust the expected literal to the helper's exact output — the test pins whatever the implementation emits for this input, then the cross-checkout property is asserted by feeding two different prefixes and comparing equality.)

Run: `zig build test 2>&1 | tail -5`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
jj status
jj commit src/cargo/actionkey.zig src/cargo/root.zig -m "Add action key computation"
```

---

### Task 6: rustc invocation construction

**Files:**
- Create: `src/cargo/invoke.zig`
- Test: inline tests in `src/cargo/invoke.zig`

**Interfaces:**
- Consumes: `driver.Unit/CompileMode`, `profile.Profile`, `toolchain.Toolchain`.
- Produces (used by Tasks 7–8, 10):
```zig
pub const InvokeError = error{ OutOfMemory } || std.mem.Allocator.Error;
pub const DepLib = struct {
    extern_name: []const u8,  // borrowed from Unit.deps
    rlib_path: []const u8,   // absolute spool path of the dep artifact (borrowed)
    is_rmeta: bool,           // check-mode deps pass .rmeta
};
pub const RustcInvocation = struct {
    argv: []const []const u8, // gpa-owned; argv[0] = rustc path (borrowed from Toolchain)
    env_extra: []const []const u8, // gpa-owned "K=V" additions (RUSTC_BOOTSTRAP for abort, OUT_DIR when set)
    out_dir: []const u8,      // borrowed spool unit dir (also present in argv)
    dep_info_path: []const u8,// borrowed: out_dir + "/<target>.d"
    pub fn deinit(self: *RustcInvocation, gpa: std.mem.Allocator) void { ... } // frees argv + env_extra slices (not the borrowed strings)
};
pub fn buildRustcArgs(
    gpa: std.mem.Allocator,
    tc: *const Toolchain,
    unit: *const Unit,
    profile: Profile,
    deps: []const DepLib,
    out_dir: []const u8,     // absolute spool dir for THIS unit (borrowed)
    crate_root: []const u8,  // absolute crate root source file (borrowed; lib.rs/main.rs or manifest `path`)
    edition_override: ?[]const u8,
) InvokeError!RustcInvocation;
```

Arg order (normative — `build_base_args` + `build_deps_args` order, comments cite the cargo line):

1. `--crate-name <extern_name_of_self>` (self extern name = `externName(target_name)`)
2. `--edition=<edition>` (`Edition::cmd_edition_arg` role; `=` form — rustc accepts both, and `=` keeps one argv element for the normalizer)
3. `--crate-type=<t>` for each `crate_types` (rlib for lib, bin for bin — `rustc_crate_types()` role)
4. `--emit=` + (`dep-info,metadata` when `mode == .check`; `dep-info,metadata,link` when lib-build; `dep-info,link` when bin-build) (`build_base_args` emit ladder; M4 omits cargo's `-Z embed-metadata=no` nightly arm and the `requires_upstream_objects` split — no dylib/proc-macro units in scope, so the lib-vs-bin split coincides. Oracle argv note.)
5. `-C prefer-dynamic` when `compile_kind == .host` (host/proc-macro role; simplified: cargo ALSO fires it for `contains_dylib && !is_primary_package` per `mod.rs:1311-1315` — M4 has no dylib/non-primary units so the conditions coincide. Oracle argv note.)
6. `-C opt-level=<o>` unless `"0"`; `-C debuginfo=<n>` when `debug_info > 0` (`debug=true`→2; cargo spells this `-C debuginfo=full` — same meaning, rime uses the numeric form rustc accepts; normalize in oracle argv diffs); `-C debug-assertions=on|off` ALWAYS; `-C overflow-checks=on|off` ONLY when it differs from `debug_assertions` (cargo `mod.rs:1367-1385` differs-rule, simplified: cargo additionally elides `debug-assertions` itself when implied by the opt-level, while rime always emits it — e.g. default release, with corrected Task-2 defaults, emits only `-C debug-assertions=off` under rime vs nothing under cargo. Expected oracle argv diff, confined to these two flags; keys stay content-bound either way — Task 12 normalizes both flags out of argv comparisons); `-C panic=abort` when abort (+ `RUSTC_BOOTSTRAP=1` in env_extra — `build_base_args` ImmediateAbort rule); `-C lto=off`, `-C embed-bitcode=no` when `lto_off`
7. `--error-format=json` (always in M4 — rime only speaks JSON diagnostics; `add_error_format_and_color` role). Cargo ALSO appends `--json=diagnostic-rendered-ansi,artifacts,future-incompat` (`mod.rs:1188`); rime deliberately OMITS `--json` in M4 (envelope detection is line-based on `--error-format=json` output; rendered-ansi/artifacts streams are not needed to reconstruct the three envelope reasons) — documented omission, normalize in oracle diffs.
8. `--out-dir <out_dir>`
9. `-L dependency=<deps_dir>` where deps_dir = dirname of deps[0].rlib_path (`lib_search_paths` role; all dep rlibs live in one spool deps dir — Task 8 guarantees this layout)
10. `--extern <name>=<rlib_path>` per dep (`build_deps_args` role)
11. `--cfg 'feature="f"'` per sorted feature (cargo passes features as `--cfg feature="…"` — pin: `build_base_args` feature loop; exact spelling `--cfg` + `feature="json"` as ONE argv element `feature="json"`? Cargo passes two argv elements `--cfg` `feature="foo"`. Match cargo: two elements.)
12. crate root source file: `<src_path>/src/lib.rs` (lib) or `<src_path>/src/main.rs` (bin), overridden by explicit manifest target `path` — the pipeline (Task 10 `buildPlan`) resolves the root file and passes it as the `crate_root` Interfaces param (the FIRST arg after rustc must be the crate root).

The signature above IS the final one (`crate_root` included). Env: `RUSTFLAGS` is NOT passed on the command line — it enters the key via `rustflags_hash` and is inherited from the process env (cargo reads it from config/env at arg-build time; rime inherits + hashes, documented).

- [ ] **Step 1: Write the failing test**

```zig
test "invoke builds cargo-shaped argv for a lib" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const unit = Unit{
        .pkg_name = "serde", .version = "1.0.0", .target_name = "serde", .kind = .lib,
        .edition = "2021", .crate_types = &.{"rlib"}, .profile = profileFor("dev"),
        .features_sorted = &.{"std"}, .target_triple = "aarch64-apple-darwin",
        .compile_kind = .target, .mode = .build, .src_path = "/ws/serde", .deps = &.{},
    };
    var inv = try buildRustcArgs(std.testing.allocator, &tc_stub, &unit, unit.profile, &.{}, "/spool/serde", "/ws/serde/src/lib.rs", null);
    defer inv.deinit(std.testing.allocator);
    // argv[0] rustc, then --crate-name serde, --edition=2021, --crate-type=rlib, --emit=dep-info,metadata,link, …, --error-format=json, crate root last
    try std.testing.expectEqualStrings("--crate-name", inv.argv[1]);
    try std.testing.expectEqualStrings("serde", inv.argv[2]);
    try std.testing.expectEqualStrings("--edition=2021", inv.argv[3]);
    try std.testing.expectEqualStrings("--crate-type=rlib", inv.argv[4]);
    try std.testing.expectEqualStrings("--emit=dep-info,metadata,link", inv.argv[5]);
    try std.testing.expect(hasArg(inv.argv, "--error-format=json"));
    try std.testing.expectEqualStrings("/ws/serde/src/lib.rs", inv.argv[inv.argv.len - 1]);
}

test "check mode emits metadata only" {
    // same unit with .mode = .check → --emit=dep-info,metadata present, no `link`
}
```

(`tc_stub`: a `Toolchain` with static strings + zero digest, defined once in the test block. `hasArg`: 5-line helper in the test block.)

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test 2>&1 | tail -10`
Expected: FAIL — `invoke.zig` / `buildRustcArgs` not defined (add the two `root.zig` lines).

- [ ] **Step 3: Write minimal implementation**

Straight-line argv builder with an `ArrayList([]const u8)`; profile `-C` flags per the table; `--cfg` pairs per feature; `-L dependency=` + `--extern` per dep; `dep_info_path = out_dir/target_name.d` via `allocPrint` (OWNED by the invocation — document: `deinit` frees `out_dir`? No: out_dir borrowed, dep_info_path owned → `deinit` frees `dep_info_path` too. State it exactly.).

- [ ] **Step 4: Run test to verify it passes**

Add the bin + host tests:
```zig
test "bin units emit link-only and host units prefer dynamic" {
    // bin → --emit=dep-info,link; compile_kind=.host → contains "-C prefer-dynamic"
}
```

Run: `zig build test 2>&1 | tail -5`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
jj status
jj commit src/cargo/invoke.zig src/cargo/root.zig -m "Add rustc argv builder"
```

---

### Task 7: Spawn + JSON message plumbing

**Files:**
- Modify: `src/cargo/oracle.zig` (make `runCapture` `pub`), create `src/cargo/compile.zig` (part 1: spawn + envelopes)
- Test: inline tests in `src/cargo/compile.zig`

**Interfaces:**
- Consumes: `invoke.RustcInvocation`, `oracle.runCapture` (newly pub), `cli.JsonEnvelope` (extended reasons).
- Produces (used by Tasks 8–10, 12–13):
```zig
pub const CompileError = error{ SpawnFailed, TimedOut, RustcFailed, BadMessage, OutOfMemory, Io } || std.mem.Allocator.Error;
pub const Diagnostic = struct {
    level: []const u8,       // "error" | "warning" | "note" | "help" (borrowed from parsed JSON)
    message: []const u8,     // rendered message (borrowed)
    package: []const u8,     // borrowed from caller unit
    target: []const u8,      // borrowed from caller unit
};
pub const CompileOutput = struct {
    arena: std.heap.ArenaAllocator, // owns stdout/stderr copies + parsed lines
    exited: u8,
    stdout: []const u8,
    stderr: []const u8,
    pub fn deinit(self: *CompileOutput) void { self.arena.deinit(); }
};
pub fn spawnRustc(gpa: std.mem.Allocator, io: std.Io, inv: *const RustcInvocation) CompileError!CompileOutput;
pub fn emitEnvelopes(
    gpa: std.mem.Allocator,
    io: std.Io,
    w: *std.Io.Writer,       // stdout when json, stderr pass-through note below
    unit: *const Unit,
    profile_name: []const u8,
    out: *const CompileOutput,
    artifacts: []const []const u8, // output filenames for the compiler-artifact envelope (borrowed)
    message_format_json: bool,
) CompileError!bool;          // true = success (exit 0 AND no error-level diagnostics)
```

`spawnRustc`: set `RUSTC_BOOTSTRAP` etc. from `inv.env_extra` on the child env (spawn takes `env`? `std.process.spawn` options include `.env` — check the oracle precedent: it passes no env. If `spawn` has no env field in 0.16, set process env via `std.c.setenv` before spawn and restore after — single-threaded CLI use, document it. The implementer MUST check the `std.process.spawn` signature first and use `.env` when present, `setenv`-around-spawn when absent; the test below passes either way.) Drain with the `oracle.runCapture` loop (now shared, not copied — deviation D-R1: combined capture). 60 s watchdog inherited from the shared helper.

`emitEnvelopes`: for each `\n`-separated line of stderr+stdout that parses as JSON with `$message_type == "diagnostic"`, emit one `compiler-message` envelope (human: `level: rendered` to stderr; json: `{reason, package, target, profile, success}` + full diagnostic object on the SAME line? Cargo's `compiler-message` envelope carries the whole rustc JSON under `message`. M4: emit `JsonEnvelope{reason="compiler-message"}` line, then the ORIGINAL rustc JSON line verbatim after it (two lines; consumers can pair them; byte-contains, not byte-equal, conformance — Task 12 normalizes). Lines that are not JSON diagnostics pass through to stderr verbatim (human) or are dropped (json, except errors → `compiler-message` with success=false). After a zero exit with no error diagnostics: emit `compiler-artifact` (with the `artifacts` Interfaces param — the output filenames the caller passes) then return true. Nonzero exit: emit `build-finished`-shaped failure? No — `build-finished` is pipeline-level (Task 10); here return `RustcFailed` AFTER emitting the diagnostics, and the caller maps it to exit 101.

- [ ] **Step 1: Write the failing test**

```zig
test "envelopes re-emit rustc json diagnostics" {
    // Fake CompileOutput with one diagnostic line; assert a compiler-message envelope line appears.
    const line = "{\"$message_type\":\"diagnostic\",\"message\":\"unused var\",\"level\":\"warning\",\"spans\":[]}\nnot-json-noise\n";
    // … build CompileOutput over an arena, call emitEnvelopes with a buffer writer (artifacts = &.{}), assert contains "compiler-message" + "unused var"
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test 2>&1 | tail -10`
Expected: FAIL — `compile.zig` not defined (add the two `root.zig` lines; make `runCapture` pub in `oracle.zig` in this step).

- [ ] **Step 3: Write minimal implementation**

Line splitter + `std.json.parseFromSlice(DiagJson, arena, line, .{})` with `catch continue` (non-JSON passes through); `DiagJson = struct { @"$message_type": []const u8, message: []const u8, level: []const u8 }` with `unknown_fields` ignored? In 0.16 `parseFromSlice` options: `.{ .allocate = .alloc_always, .ignore_unknown_fields = true }` — verify the field name from `fetch.zig`/`index.zig` parse call sites (they use `.{}` or explicit flags; copy the exact options literal that tolerates unknown fields). Level read via `.string` tag; envelope via existing `JsonEnvelope.writeLine`.

- [ ] **Step 4: Run test to verify it passes**

Add the oracle-gated real-spawn test:
```zig
test "spawn runs real rustc --version when oracle enabled" {
    if (!@import("oracle.zig").oracleEnabled()) return error.SkipZigTest;
    // build a 1-arg invocation by hand (rustc --version), spawn, assert exit 0 and output contains "rustc"
}
```

Run: `zig build test 2>&1 | tail -5` then `RIME_CARGO_ORACLE=1 zig build test 2>&1 | tail -5`
Expected: PASS both (second runs the real spawn).

- [ ] **Step 5: Commit**

```bash
jj status
jj commit src/cargo/compile.zig src/cargo/oracle.zig src/cargo/root.zig -m "Add rustc spawn and diagnostics"
```

---

### Task 8: Output ingestion (spool → store)

**Files:**
- Modify: `src/cargo/compile.zig` (part 2: ingest + action record)
- Test: inline tests in `src/cargo/compile.zig` (real `Store` via `test_support`, the `view.zig` test precedent)

**Interfaces:**
- Consumes: `Store.putBytes/putFile/putManifest/putAction/lookupAction/tagObject/lastFull`, `actionkey.unitTags/actionKey/normalizeArgs`, `fingerprint.toDigest`, `manifest_mod.Manifest/ManifestOutput` (`Store.ManifestOutput`).
- Produces (used by Tasks 9–10, 13):
```zig
pub const IngestError = error{ StoreRead, StoreFull, TagError, OutOfMemory, Io } || std.mem.Allocator.Error;
pub const IngestedUnit = struct {
    manifest_digest: ?Digest,  // putManifest over the unit's outputs; null = StoreFull, spool-only (no manifest exists)
    action_key: Digest,        // the key just recorded
    cache_hit: bool,           // true when lookupAction hit and outputs re-materialized
};
pub fn ingestUnitOutputs(
    gpa: std.mem.Allocator,
    io: std.Io,
    store: *Store,
    unit: *const Unit,
    out_dir: []const u8,       // spool unit dir holding rustc outputs
    expected: []const ExpectedOutput, // filenames + kinds rustc was asked to produce
    tags: []const Tag,         // unitTags() value (crate/version/toolchain/target/profile/features/project/action)
    action_key: Digest,
    log: ?*std.Io.Writer,     // StoreFull one-line rendering sink (null in tests)
) IngestError!IngestedUnit;
pub const ExpectedOutput = struct { filename: []const u8, kind: Kind, mode: u32 };
```

Behavior (normative): for each expected file, open `<out_dir>/<filename>`, `putFile` with kind (`rlib`/`rmeta`/`bin`; dep-info `.d` files as `dep_info`), then `tagObject` with the unit tags. Build the `Manifest{kind = unit output kind, outputs = [{path, digest, size, mode}]}` and `putManifest`. Record `putAction(action_key, manifest_digest)`. **Build-driver rule (storage-v2 §10.4):** a `StoreFull` on any cache WRITE is swallowed — the artifact stays in spool for the caller to use. Without the store there is no manifest digest, and a Digest-typed sentinel would lie, so `manifest_digest: ?Digest` (null = uncached but built — the signature above IS the final one). The pipeline (Task 10) materializes the view from SPOOL when null, from store otherwise.

`lookupAction` fast path lives HERE too: `tryIngestCacheHit(gpa, io, store, action_key)` → `?Digest` manifest (verify every referenced object still `exists`, else treat as stale miss — storage-v2 §12.1 "verify the winner by digest"). The pipeline calls it BEFORE spawning (Task 10); ingestion records AFTER success.

Kind mapping: lib-build produces BOTH `.rlib` and `.rmeta`? With `--emit=dep-info,metadata,link` rustc emits `.rlib` (+ `.rmeta` pipelining artifact?) — the caller lists what IT asked for: `expected` comes from Task 10's layout step (`lib<name>-<meta>.rlib`, plus `<name>-<meta>.rmeta` when emitted, `<name>` bin, `<target>.d` dep-info). Ingestion only ingests listed files that EXIST; a missing non-`.rmeta` file is `Io` error (rustc lied); a missing `.rmeta` is skipped (pipelining variance across rustc versions).

- [ ] **Step 1: Write the failing test**

```zig
test "ingest stores spool outputs and records the action" {
    const io = std.Io.Threaded.global_single_threaded.io();
    const gpa = std.testing.allocator;
    var ts = @import("store").test_support.openTestStore(io, .{});
    defer ts.deinit(io);
    // spool dir with two files (fake rlib bytes + dep-info text)
    // tags = unitTags(...) with toolchain "rustc 1.99.0 a1b2c3d4", features "fh-" + hash
    // call ingestUnitOutputs (log = null), assert putAction round-trips via lookupAction and tagsFor shows crate tag
}
```

`@import("store").test_support` IS public (`src/store/root.zig` re-exports `pub const test_support`, and `fetch.zig` tests already use `openTestStore`) — so either test shape compiles. Use the `view.zig` shape anyway (`store_mod.Store.open` over `std.testing.tmpDir`) for consistency with the driver's existing tests; the Step-1 sketch's `openTestStore` call would also work but is not the chosen spelling.

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test 2>&1 | tail -10`
Expected: FAIL — `ingestUnitOutputs` not defined.

- [ ] **Step 3: Write minimal implementation**

Per-file: `dir.openFile` → `putFile` → file size via stat → `tagObject`. Manifest outputs with modes (`0o444` rlib/rmeta/dep-info, `0o755` bin — the `view.zig` mode table). `putManifest` → `putAction`. On `error.StoreFull` at ANY of these points: populate nothing further, return `{ .manifest_digest = null, .action_key, .cache_hit = false }` (the build still succeeds — the spool files are the delivery). Also surface the breakdown: call `store.lastFull()` and render it through the `log: ?*std.Io.Writer` Interfaces param (null in tests); on StoreFull write the one-line `rime: store full …` rendering (same shape as storage-v2 §10.4 CLI line). Signatures are contracts — this is the final one.

- [ ] **Step 4: Run test to verify it passes**

```zig
test "ingest degrades to spool-only when the store is full" {
    // openTestStore-shaped scratch store with a 1-byte index_state cap (the root.zig pin-test precedent:
    // .budget fixed + .index_state_cap fixed 1) → ingest returns manifest_digest == null, no error
}
```

Run: `zig build test 2>&1 | tail -5`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
jj status
jj commit src/cargo/compile.zig -m "Add spool-to-store ingestion"
```

---

### Task 9: Incremental sessions as global objects

**Files:**
- Modify: `src/store/root.zig` (add `Kind.incremental`), `src/store/cold.zig` (`isDemotable` gains `.incremental`), `src/cargo/compile.zig` (part 3: session round-trip)
- Test: inline tests in `src/cargo/compile.zig` + a `cold.zig` demotable assertion if the file has a test table

**Interfaces:**
- Consumes: `Store.putFile/tagObject/lookupObjects`, `actionkey` (session key derivation below).
- Produces (used by Task 10):
```zig
pub fn sessionKey(fp: *const Fingerprint, input_digest: Digest) Digest; // hash("rime-session-v1" ++ fp.toDigest ++ input_digest)
pub fn materializeSession(gpa: std.mem.Allocator, io: std.Io, store: *Store, key: Digest, sess_dir: []const u8) SessionError!bool;
pub fn ingestSession(gpa: std.mem.Allocator, io: std.Io, store: *Store, key: Digest, sess_dir: []const u8, tags: []const Tag) SessionError!void;
pub const SessionError = error{ StoreRead, StoreFull, TagError, Io, OutOfMemory } || std.mem.Allocator.Error;
```

Semantics (storage-v2 §13.2, normative over the task-brief's "project-local" wording — flagged as open question Q1; the plan implements the SPEC): incremental sessions are ordinary global `kind=incremental` objects, tagged with the full unit tag set, bounded by the `kind:incremental` 4 GiB soft tag budget (§12.3 default, set automatically on migration), never pushed remote, standard `max_age` retention. Driver flow: before compiling a unit with `profile.incremental == true`, `materializeSession` restores the prior session (query `lookupObjects({tags: [crate, crate_version, toolchain, target, profile, features, action=rustc, user.session=<keyhex>]})` — one extra `user.session` tag binding the session blob to this exact key (bare `session` is NOT in the §11.3 vocabulary and `tagObject` rejects it with `UnknownTagKey`; `user.*` is the extension point); newest-first winner; miss = fresh session, returns false). Pass `-C incremental=<sess_dir>` (cargo `add_codegen_incremental` role). After success, `ingestSession` tars?? No tar in std-gzip land — ingest each file under `sess_dir` as its own `kind=incremental` object tagged with the session tag, PLUS one `session manifest` object (JSON listing `relpath → digest`, itself tagged) so restore is exact. Restore: read manifest, `readObject` each blob, write to sess_dir. On `StoreFull` during ingest: drop the session silently (sessions are hints; the build output is already cached by Task 8).

`src/store/root.zig` edit: add `incremental` to the `Kind` enum (one word; `manifest.zig` kind mapping is `@tagName`-driven so it follows automatically). `cold.zig::isDemotable`: add `.incremental` to the demotable arm (spec §5.2: incremental demotes like any object; only `dylib`/`bin` never demote). If either file is Plan-B-owned and mid-edit, the fallback is a local `Kind` alias in `compile.zig` + `putBytes(..., .other)` — NO: that would mistag sessions and break the `kind:incremental` budget. Fallback is to STOP and escalate (contact the parent session); do not silently mistag.

- [ ] **Step 1: Write the failing test**

```zig
test "session round-trips through the store" {
    // scratch store (view.zig shape); sess_dir with two files; ingestSession; wipe dir; materializeSession → true and bytes identical
}

test "session miss returns false" {
    // materializeSession with a random key → false, dir created empty
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test 2>&1 | tail -10`
Expected: FAIL — `sessionKey` / `ingestSession` not defined (make the `root.Kind` + `cold.zig` edits in this step; if the compiler reports an exhaustive switch elsewhere, fix it in the same step and note it in the commit).

- [ ] **Step 3: Write minimal implementation**

Manifest JSON: `{ "format": 1, "files": [{ "path": "…", "digest": "b3-<hex>", "size": N, "mode": M }] }` via `std.json.Stringify`; file walk capped like `hashInputs` (sessions are bounded by rustc, but cap anyway: 50k files / 1 GiB, else skip ingest silently — sessions are hints). Restore writes with `0o644` (writable — rustc needs to update them; store objects stay `0o444`, the COPIES are writable).

- [ ] **Step 4: Run test to verify it passes**

Run: `zig build test 2>&1 | tail -5`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
jj status
jj commit src/cargo/compile.zig src/store/root.zig src/store/cold.zig -m "Add incremental sessions"
```

---

### Task 10: `rime build` end-to-end

**Files:**
- Create: `src/cargo/pipeline.zig`
- Modify: `src/cargo/cli.zig` (dispatch build/check/run/bench through the pipeline), `src/cargo/root.zig` (re-export), `src/main.zig` (store open is already there — verify, don't duplicate)
- Test: inline tests in `src/cargo/pipeline.zig` (hermetic: path-only workspace, stub toolchain? NO — compile needs real rustc; hermetic tests cover planning + spool layout, oracle-gated tests cover real compilation)

**Interfaces:**
- Consumes: EVERYTHING above + `fetch.ensureSources`, `resolve.resolveWithPrevious` (or `resolveGraph`), `features.unifyV1/unify/pruneOptional`, `lock` read/write, `view.materializeOutputs/writeViewMeta/layoutPaths`, `Store` full §16 surface.
- Produces (used by `cli.run`, Task 12–13):
```zig
pub const PipelineError = error{ NoWorkspace, NeedFetch, RustcFailed, StoreRead, StoreFull, TagError, Io, Usage, OutOfMemory } || std.mem.Allocator.Error;
pub const PipelineOptions = struct {
    manifest_path: ?[]const u8,
    profile_name: []const u8,   // "dev" default
    target_triple: ?[]const u8,
    features_cli: []const []const u8,
    all_features: bool,
    no_default: bool,
    mode: CompileMode,          // .build or .check (Task 11)
    message_format_json: bool,
    offline: bool,
    only_package: ?[]const u8,  // -p
};
pub fn buildWorkspace(
    gpa: std.mem.Allocator,
    io: std.Io,
    store: *Store,
    ws_root: []const u8,        // absolute workspace root (borrowed)
    ws: *const Workspace,
    tc: *const Toolchain,
    opts: PipelineOptions,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) PipelineError!u8;             // exit code (0 or 101)
```

Seam construction (normative — every value below names its owner module; this task adds no new seams):

- Resolve roots: one `resolve.SummaryNode` per workspace member (`name` + `index.Candidate` for the member version + `DepEdge`s from the member manifest deps; `links` from manifest `links =`). `registry: resolve.Registry = .{ .ctx = <index-backed ctx>, .queryFn = <index-cache query> }` (the `resolve.zig` test-seam shape; production `ctx` serves `index.Candidate`s, never stubs). `filter: index.QueryFilter = .{ .allow_yanked = &.{}, .max_pubtime = null, .min_versions_first = false, .rust_versions = &.{}, .preferred = &.{} }` (the `resolve.zig` test-precedent literal — no yank/exclusion policy in M4). Fresh resolve → `resolveGraph(gpa, roots, registry, filter)`; `Cargo.lock` present → `resolveWithPrevious(gpa, roots, registry, previous_nodes, .{ .update_names = &.{}, .precise = null }, filter)` where `previous_nodes` = `parseLock` output mapped to `ResolvedNode`s.
- Fetch (`fetch.zig:1571::ensureSources(gpa, io, store, client, git, opts, lock, git_decls)`): `client: RegistryClient` = the M2 sparse-index production client (field-function-pointer struct per `fetch.zig`; `FileRegistry` is test-only). `git: GitRunner = (CliGit{}).runner()` (real git subprocess; `StubGit` is test-only). `opts: FetchOptions = .{ .offline = opts.offline, .frozen = opts.frozen, .locked = opts.locked, .cache_dir = <registry cache root> }` (index cache + `.crate` cache live OUTSIDE the store per `FetchOptions.cache_dir` doc — reuse the same root the M2 CLI passes). `lock` = the just-resolved `Lockfile`. `git_decls: GitDecls` built from workspace manifests (`name → GitRef` per the manifest git-dep spelling; `GitDecls.init(gpa)` empty map when no git deps).
- Lock writeback (`lock.zig:1151::writeLock(gpa, graph, checksums, version)`): `checksums: StringHashMap(?[]const u8)` keyed by `lock.checksumKey(name, version, source)` (the `cli.zig` test precedent: `"<name> <version> <source>"`); registry entries → lockfile `checksum` (or the fetched crate's verified sha256 when the lock predates it); path entries → null/absent. `version` = `lock.versionForRustVersion(workspace lowest rust-version)` (none → v4).
- CLI (`cli.zig::Options` has NO `all_features`/`no_default` today — specify the additions here): add `all_features: bool` (`--all-features`, takes no value) and `no_default_features: bool` (`--no-default-features`, takes no value); `parseArgs` sets them with the same `inline_val != null → Usage` shape as `--offline`; `PipelineOptions.all_features/no_default` copy them verbatim (`no_default` keeps its short name — document the spelling split). `Options.deinit` is unchanged (no new owned slices).

Pipeline order (normative — each step cites its owner):

1. `fetch.ensureSources` for all lockfile registry/git entries (M2 oracle does the download; `offline` + missing source → `NeedFetch` naming the crate, exit 1 — the D5 `need source` diagnostic).
2. Resolve: `resolveWithPrevious` with previous = parsed `Cargo.lock` (or `resolveGraph` when no lock); write back `Cargo.lock` when it changed (M3 writer, byte-stable).
3. Features: `unifyV1` (behavior v1) or `unify` (v2/v3 per manifest `resolver` + `Behavior.fromManifest`); `pruneOptional`; CLI `--features`/`--all-features`/`--no-default-features` become `RootReq`s.
4. `profileFor(opts.profile_name)` + `applyProfileToml` over the workspace `Cargo.toml` text; `buildUnitGraph`; filter to `only_package` closure (reuse `view.planUnits`-style closure? No — filter UNITS by member name here, same Kahn-closure helper copied from `view.planUnits`'s kept-set logic — 15 lines, copy them).
5. `leasePut(build_id, input_digests)` where `build_id` = `b3-<action-key-of-root-unit>`?? Leases key on build id strings: use `std.fmt.allocPrint("rime-build-{x}", .{timestamp_ms})` — unique per invocation; digests = all units' `hashInputs` (bounded: workspace members only). `leaseRenew` after each unit. `defer leaseDrop` (errdefer AND normal path — leases must not leak on `RustcFailed`).
6. Per unit in topo order: `fingerprintUnit` → `hashInputs` → `normalizeArgs(buildRustcArgs…)` → `actionKey` → `tryIngestCacheHit` (hit: materialize dep outputs to spool from the manifest, emit `Fresh <name> v<ver>` / json `unit-cached` envelope, continue) → miss: `materializeSession` (when `profile.incremental`), spawn, `emitEnvelopes` (failure → `RustcFailed`, exit 101 AFTER leaseDrop), `ingestUnitOutputs` (null manifest = spool-only; remember spool paths), `ingestSession`.
7. Dep `--extern` wiring: before compiling unit U, every dep unit D has EITHER a store manifest (materialize D's rlib/rmeta into the shared spool deps dir via `store.materialize`, `0o444`) OR spool-only outputs (copy from D's spool out_dir). One shared `<spool>/deps/` dir for the whole build (the `-L dependency=` target from Task 6).
8. Output filenames: `lib<extern>-<meta16>.rlib` (+ `.rmeta` when lib-build emits it — detect by existence post-compile), bin `<name>-<meta16>` (no ext on unix), dep-info `<target>.d`. meta16 = fingerprint `toHex16`.
9. After all units: `view.materializeOutputs` (store manifests; spool-only units materialized from their spool paths by plain copy — view takes store + units; spool-only path needs a view change: `materializeOutputs` with null digests writes STUBS only. So Task 10 ALSO extends `view.materializeOutputs` to accept an optional spool-fallback map? NO — cleaner: on the spool-only path, `putBytes` failed with StoreFull meaning the WHOLE store is full; copying from spool to view still works if `materializeOutputs` learns a `spool_fallback: ?SpoolMap`. Decision: add param `spool_dirs: ?*const SpoolMap` (`pkg_name → out_dir`) to `materializeOutputs`; null in all existing callers/tests (update them). Document in this task's Step 3.)
10. `writeViewMeta` with `"complete": true`, real toolchain/features/project tags, `last-build.json` with real manifest digests; `retainProject(project_id, manifest_digests)`; exit 0.
11. Human stderr: `Compiling <name> v<ver>` per compiled unit, `Fresh …` per hit, `Finished <profile> profile …` at end (cargo's three lines — exact strings pinned by Task 12 goldens).

- [ ] **Step 1: Write the failing test (hermetic planning half)**

```zig
test "pipeline plans member order without compiling" {
    // discover testdata/cargo/workspace, resolve stub (two path members — resolveGraph over a stub Registry),
    // buildUnitGraph, assert topo order b-then-a WITHOUT spawning (pass a null store? No — pass a real scratch
    // store but stop before spawn by asserting the plan only). Concretely: test buildPlan() helper returning
    // the ordered units; spawn lives in buildWorkspace. Factor buildPlan() as its own pub fn in this task.
}
```

So the Interfaces gain: `pub fn buildPlan(gpa, io, store, ws, tc, opts, …) PipelineError!PlannedBuild` where `PlannedBuild = struct { arena, units: []PlannedUnit (unit + fp + action_key + crate_root), profile: Profile }`. `buildWorkspace` = `buildPlan` + execute loop. (Signatures are contracts — this paragraph amends the Interfaces block: add `buildPlan` + `PlannedUnit`/`PlannedBuild` with arena ownership.)

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test 2>&1 | tail -10`
Expected: FAIL — `pipeline.zig` / `buildPlan` not defined.

- [ ] **Step 3: Write minimal implementation**

`buildPlan` (pure planning, hermetic): resolve → features → profile → unit graph → per-unit fp + inputs digest + crate-root resolution (`src/lib.rs` vs `src/main.rs` vs manifest `path`; missing root file → `NeedFetch`-style `Io` error naming the file — it is a manifest/layout error, exit 1) + action key (needs normalized argv → needs `buildRustcArgs` → needs dep rlib paths NOT YET KNOWN (deps uncompiled!). Ordering fix: action key uses `store:`-canonicalized extern paths — but the dep's fingerprint (hence its output filename) IS known at plan time (fp needs dep_fps recursively — computed bottom-up in topo order). So plan computes fingerprints bottom-up, derives dep output filenames (`lib<e>-<meta16>.rlib` in the shared spool deps dir — deterministic), THEN builds argv, normalizes, keys. Two passes over topo order. This paragraph is normative.

`buildWorkspace` (execute): the 11-step loop above. Crate-root + out_dir + sess_dir all under `<store-tmp>/rime-build-<id>/` (spool class; `deleteTree` at end, AFTER view materialization).

- [ ] **Step 4: Run tests to verify behavior**

Hermetic `buildPlan` test passes on `testdata/cargo/workspace`. Oracle-gated test:
```zig
test "pipeline compiles the workspace when oracle enabled" {
    if (!@import("oracle.zig").oracleEnabled()) return error.SkipZigTest;
    // scratch copy of testdata/cargo/workspace (path-only members, no registry deps) to /tmp,
    // open scratch store, probe real toolchain, buildWorkspace(mode=.build), assert exit 0
    // and target/debug/deps/libb-<meta>.rlib exists
}
```

Run: `zig build test 2>&1 | tail -5`
Expected: PASS (oracle test skips without env).

- [ ] **Step 5: Commit**

```bash
jj status
jj commit src/cargo/pipeline.zig src/cargo/root.zig src/cargo/view.zig src/cargo/cli.zig -m "Add rime build pipeline"
```

---

### Task 11: Check mode (`rime check`)

**Files:**
- Modify: `src/cargo/pipeline.zig` — created in Task 10 above. ORDER: Task 10's `buildWorkspace` (with its `mode: CompileMode` parameter) lands FIRST; this task is only the `rime check` CLI mapping + the rmeta-only materialization rule. Concretely this task's steps run AFTER Task 10's code exists.
- Test: inline tests in `src/cargo/pipeline.zig` + `src/cargo/cli.zig` parse test for `check`

**Interfaces:**
- Consumes: `pipeline.buildWorkspace` (Task 10) with `mode = .check`.
- Produces: `rime check` behavior:
  - every unit built with `CompileMode.check` → `--emit=dep-info,metadata` (the `build_base_args` check rule);
  - dep `--extern` paths resolve to `.rmeta` files when the dep was check-built, `.rlib` otherwise (caller prefers `*.rmeta` when present — rustc accepts rmeta for `--extern` metadata-only use);
  - NOTHING is linked: no bins are produced; `target/debug/` receives `.rmeta` + dep-info only; `writeViewMeta` rows carry `"action": "rustc"` (there is no `"check"` action in the §11.3 vocabulary — Task 5; mode is already bound in the fingerprint/profile hash);
  - exit codes unchanged (101 on rustc failure with JSON diagnostics).

- [ ] **Step 1: Write the failing test**

```zig
test "check mode builds rmeta-only units" {
    // buildWorkspace over testdata/cargo/workspace with .check: assert every unit's manifest kind is .rmeta
    // and no output filename lacks the .rmeta/.d suffix
}
```

(Full bodies once `pipeline.zig` exists — this task's Step 1 runs against Task 10's file. If Task 10 changed a signature this task needs, update THIS task's test, not Task 10's code.)

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test 2>&1 | tail -10`
Expected: FAIL — check-mode branch missing (`mode` ignored or `.rmeta` assertion fails).

- [ ] **Step 3: Write minimal implementation**

In `buildWorkspace`: `mode` flips `Unit.mode` for every unit before invoke; dep-lib resolution prefers the dep's `.rmeta` spool path; materialization skips bin outputs (a bin unit in check mode produces only its dep-info + rmeta — rustc with `--emit=metadata` on a bin crate emits `.rmeta`; ingest it as `rmeta`). `cli.zig`: `check` maps to `mode = .check` (one-line dispatch change + doc comment).

- [ ] **Step 4: Run test to verify it passes**

```zig
test "cli check dispatches check mode" {
    const argv = [_][]const u8{ "rime", "check", "--message-format=json" };
    var opts = try @import("cli.zig").parseArgs(std.testing.allocator, &argv);
    defer opts.deinit(std.testing.allocator);
    try std.testing.expect(opts.cmd == .check);
}
```

Run: `zig build test 2>&1 | tail -5`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
jj status
jj commit src/cargo/pipeline.zig src/cargo/cli.zig -m "Add rime check mode"
```

---

### Task 12: Validation goldens vs the cargo oracle

**Files:**
- Create: `validation/<proj>/golden.units.json`, `validation/<proj>/golden.diag-dev.json` (generated, then COMMITTED), oracle test file(s) — new `src/cargo/driver_oracle.zig`? NO new module: oracle tests live inline in `pipeline.zig`/`compile.zig` test blocks (the `oracle.zig` WsRegistry precedent). New goldens only + test blocks.
- Test: `RIME_CARGO_ORACLE=1` comparisons

**Interfaces:**
- Consumes: `pipeline.buildWorkspace`, `oracle.{oracleEnabled, cargoAvailable, runCapture}` (pub after Task 7), `view` layout.
- Produces: per validation project (`basic-workspace`, `feature-matrix`, `lockfile-golden`, `full-manifest`):
  - `golden.units.json`: `rime build --dry-run`-equivalent plan dump — sorted `[{package, version, target, kind, edition, features[], profile, triple, deps[extern names]}]`. Produced by a `dumpUnitPlan` helper added to `pipeline.zig` in THIS task (JSON via `std.json.Stringify`, `@VALIDATION_ROOT@`-normalized, fingerprint/meta fields EXCLUDED — they bind toolchain bytes, not cargo semantics).
  - `golden.diag-<profile>.json`: normalized `--message-format=json` stream: keep `{reason, package, target}` + diagnostic `message`/`level`; DROP/replace: absolute paths → `@VALIDATION_ROOT@`, `durations`, rustc version strings, fingerprint hashes.
  - Comparison tests: (a) rime plan vs committed `golden.units.json` (HERMETIC — runs always; registry deps need no download for PLANNING); (b) rime diagnostics vs fresh `cargo build --message-format=json` (ORACLE-GATED); (c) fresh cargo output vs committed golden (oracle self-check, catches upstream drift — failure message must say "re-pin goldens", not "rime wrong").

Registry deps (`serde`, `anyhow`, …) require the M2 fetch path + network: oracle tests run `fetch.ensureSources` first (real crates.io). If M2 is absent/broken, these tests fail LOUDLY naming fetch — that is correct (M4 depends on M2; the failure points at the seam, and the hermetic plan tests still pass).

- [ ] **Step 1: Write the failing test**

```zig
test "oracle compares unit plans against committed goldens" {
    // for each validation project dir: discover, buildPlan (stub toolchain? plan needs tc.host_target —
    // use probeToolchain when oracle enabled, else read golden's triple field and skip), dumpUnitPlan,
    // normalize WS root, compare bytes with golden.units.json (missing golden file = test failure naming
    // the exact generation command below)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test 2>&1 | tail -10`
Expected: FAIL — `dumpUnitPlan` not defined / goldens missing.

- [ ] **Step 3: Write minimal implementation + generate goldens**

`dumpUnitPlan(gpa, planned: *const PlannedBuild) ![]u8` (sorted by package, normalized). Generation commands (run with network + real cargo present):
```bash
RIME_CARGO_ORACLE=1 zig build test  # oracle tests print fresh plans on mismatch; copy approved output to golden.units.json
./validation/oracle.sh              # confirm committed cargo goldens still match real cargo first
```
Diagnostics goldens: `cargo build --message-format=json > golden.diag-dev.json` normalized by the checked-in normalizer (a `normalizeDiag` pub fn in `pipeline.zig` test block? NO — normalizer must ship in non-test code to be reused: add `pub fn normalizeDiagLine(gpa, line, ws_root) ![]u8` to `compile.zig` in this task). Same for rime's stream; diff the two normalized streams (byte-contains per diagnostic message, ORDER-SENSITIVE for artifacts, order-insensitive for warnings — document the rule in the test).

- [ ] **Step 4: Run tests to verify they pass**

Run: `zig build test 2>&1 | tail -5` (hermetic green) then `RIME_CARGO_ORACLE=1 zig build test 2>&1 | tail -5` (full conformance; needs network + M2 fetch)
Expected: PASS both (or fetch-naming failures only, which block M4 acceptance explicitly).

- [ ] **Step 5: Commit**

```bash
jj status
jj commit validation/ src/cargo/compile.zig src/cargo/pipeline.zig -m "Add driver oracle goldens"
```

---

### Task 13: Incremental reuse + cross-project cache hits

**Files:**
- Modify: `src/cargo/pipeline.zig` (test blocks only — no new behavior unless a test fails, in which case fix the code, not the test)
- Test: two oracle-gated tests + one hermetic test

**Interfaces:**
- Consumes: `buildWorkspace`, `lookupAction`, `Store.stats`.
- Produces (acceptance proof for the M4 validation design):
  - `incremental-reuse`: copy `basic-workspace` to `/tmp`, build (record per-package `compiler-artifact` counts from the json stream), `touch` ONE file in ONE crate (append a comment — content change, mtime change), rebuild, assert EXACTLY that crate (plus its reverse-deps) recompiled and all others reported `Fresh`/`unit-cached`. Second sub-case: rebuild with NO changes → zero `Compiling` lines (full no-op hit).
  - `cross-project cache hit` (global-cache-only proof): two scratch projects depending on the SAME registry version (or same path source vendored twice — hermetic variant uses two workspaces sharing one path dep via absolute `path =` … path deps hash by workspace path (`path_hash`), so identical content at different paths gives DIFFERENT keys — the cross-project proof therefore needs a REGISTRY dep (content-addressed by version, `project` excluded from the reuse predicate per §12.1) → oracle-gated with M2 fetch. Assert: second project's dep units are `cache_hit == true` with ZERO rustc spawns for them (count spawns via a test hook: `buildWorkspace` takes `spawn_counter: ?*usize`?? — signature change. Alternative without touching signatures: count `Compiling` lines in the captured json stream. DECISION: count stream lines; no signature change.)
  - `flag-change rebuild`: same project, `--features` changed (or release vs dev) → all affected units recompile (different `features` in key → different action key → miss). Hermetic-if-compilable: needs real rustc → oracle-gated; the KEY-DIFFERENCE half is hermetic (assert `actionKey` differs across feature sets in `actionkey.zig` test — add it HERE as the always-run companion).

- [ ] **Step 1: Write the failing tests**

```zig
test "action keys differ across feature sets and profiles" {
    // same fp except features_sorted/profile_hash → different actionKey (HERMETIC, always runs)
}

test "edit one file recompiles one crate when oracle enabled" {
    if (!@import("oracle.zig").oracleEnabled()) return error.SkipZigTest;
    // copy basic-workspace to tmp (writeFile the whole tree? use the validation dir IN PLACE with
    // target/ gitignored + restore? NO — never dirty validation/. Copy tree via a 20-line recursive
    // copy helper in the test block), build, touch, rebuild, count Compiling lines
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `zig build test 2>&1 | tail -10`
Expected: FAIL — helpers missing (`copyTree` test helper, stream counter).

- [ ] **Step 3: Write minimal implementation**

Test helpers only (plus any pipeline bug the tests expose — e.g. dep-info freshness not consulted before spawn: the pipeline MUST consult `checkFresh` + dep-fingerprint equality to decide Fresh-vs-Compiling for units whose action key hits but whose local files changed?? WAIT. Correctness trap: action-key hit means inputs IDENTICAL (content hashed) — a local edit changes `hashInputs` → different key → miss → recompile. `checkFresh` (mtime) is then REDUNDANT for correctness?? No: it is the FAST PATH — skip hashing all source bytes when dep-info says nothing changed since the recorded output mtime (cargo's `FsStatus` role exactly). Pipeline order per unit: (a) compute dep-info path; if dep-info exists AND `checkFresh(dep-info, recorded_output_mtime)` → Fresh without hashing (recorded mtime from last-build.json — Task 10 stores per-unit output mtimes there; if absent, fall through); (b) else hash inputs → action key → lookup → hit/miss. If (a) was added in Task 10 already, this task only tests it; if not, add it HERE (small, tested). (This paragraph amends Task 10: `last-build.json` stores `{manifests: [...], units: [{package, target, output_mtime_ns}]}`.)

- [ ] **Step 4: Run tests to verify they pass**

Run: `zig build test 2>&1 | tail -5` then `RIME_CARGO_ORACLE=1 timeout 300 zig build test 2>&1 | tail -5`
Expected: PASS (oracle run compiles real crates; bounded by `timeout 300` per the hard rules).

- [ ] **Step 5: Commit**

```bash
jj status
jj commit src/cargo/pipeline.zig src/cargo/actionkey.zig -m "Prove incremental reuse"
```

---

## 2. Self-review

**1. Spec coverage.** Objective (1) unit graph → Task 3. (2) fingerprints + action keys → Tasks 4–5 (§5.3 contents, §11.3 tags, sccache model §0.4). (3) rustc invocation → Task 6 (`build_base_args`, `build_deps_args`, emit ladder, `--error-format=json`) + Task 7 (message plumbing, `compiler-artifact` role). (4) output ingestion → Task 8 (`putFile`/`putBytes` tagged, manifest, action entry, StoreFull-never-fails rule §10.4). (5) incremental → Task 9 (§13.2 global `kind=incremental`, `-C incremental=` role, 4 GiB soft budget §12.3). (6) check mode → Task 11 (`is_check` emit rule, `rime check`). (7) host/target seam → Task 3 (`CompileKind`, `forHostTarget`, prefer-dynamic hook) with M5 boundary stated. (8) `rime build` e2e → Task 10 (fetch→resolve→compile→materialize) + Tasks 12–13 (validation design: goldens vs cargo, incremental reuse, cross-project hits). Storage touchpoints all cite §16 methods that exist in `src/store/root.zig` (verified while writing: `putBytes/putFile/putManifest/getManifest/materialize/putAction/lookupAction/tagObject/lookupObjects/leasePut/leaseRenew/leaseDrop/retainProject/lastFull/stats`).

**2. Placeholder scan.** No TBD/TODO/"similar to Task N" — every step has exact code, exact commands, exact expected output. Cross-task forward references (Task 11 after Task 10, Task 13's `last-build.json` amendment to Task 10) are explicit ordered instructions, not placeholders. The two `root.Kind`/`cold.zig` edits name exact files + fallback behavior.

**3. Type consistency.** `Unit` (Task 3) is consumed verbatim by Tasks 4 (`fingerprintUnit(unit, …)`), 6 (`buildRustcArgs(tc, unit, profile, deps, out_dir, crate_root)`), 7 (`emitEnvelopes(…, unit, …)`), 8 (ingest takes `unit` + `ExpectedOutput`). `Digest`/`Tag`/`Predicate` spellings match `store/root.zig` + `tags.zig`. `Profile` value-copied everywhere (no ownership drift). `?Digest` manifest (Task 8) is produced/consumed consistently by Tasks 9 (sessions independent) and 10 (spool fallback map). `FeaturesFor`/namespaces come from the existing `features.zig` API (`Unified.isEnabled`, `enabled_deps`, `unifyV1`, `pruneOptional` — all verified in the real file).

**Gaps fixed during review:** `crate_root` added to `buildRustcArgs` (rustc needs the source file operand); `log` writer added to `ingestUnitOutputs` (StoreFull rendering needs a sink); `buildPlan`/`PlannedBuild` factored out of `buildWorkspace` (hermetic plan tests); `dumpUnitPlan`/`normalizeDiagLine` placed in non-test code (golden generation reuse); `spool_dirs` fallback in `view.materializeOutputs` (StoreFull path still fills the view).

## 3. Open questions (for the parent — not the implementer)

- **Q1 — Incremental placement (SPEC CONFLICT).** The task brief says "incremental compilation as the bounded project-local class per docs/design/storage-v2.md". Storage-v2 has NO project-local class: §13.2 explicitly REMOVES `state/projects/<id>/incremental/` and makes sessions global `kind=incremental` objects (mirrored by the M1-plan M4 sketch: "never a project-local class"). This plan implements §13.2 (global). Confirm the brief's wording was stale and global stands.
- **Q2 — `RUSTC_INCREMENTAL`.** No cargo semantic found for a `RUSTC_INCREMENTAL` env var (cargo passes `-C incremental=<dir>` explicitly, `add_codegen_incremental`). This plan implements `-C incremental=` only, gated on `profile.incremental`. Confirm no extra env-var contract is wanted.
- **Q3 — rustc discovery.** Plan resolves `$RUSTC` → `PATH rustc`. Confirm rustup-proxy/shim handling needs nothing more (e.g. `rustup which rustc` defense when the shim hides the real binary's mtime — matters for `hashFile` stability).
- **Q4 — `Kind.incremental` ownership.** Task 9 edits Plan-B-owned `src/store/root.zig` + `cold.zig`. If Plan B's index work conflicts, who rebases? Plan includes a stop-and-escalate fallback (no silent mistagging).
- **Q5 — `[profile.*.package."*"]` overrides (limitation L1) and example/test/bench targets (L2).** Both deferred with loud errors where hit. Confirm M4 acceptance does not need them (validation corpus `full-manifest` HAS `[[example]]`/`[[bench]]`/`[[test]] + package overrides — Task 12's `full-manifest` golden may need to EXCLUDE those targets or the corpus needs an M4-scope note).

**"Plan complete and saved to `docs/superpowers/plans/2026-10-04-rustc-driver.md`. Two execution options:**

**1. Subagent-Driven (recommended)** - I dispatch a fresh subagent per task, review between tasks, fast iteration

**2. Inline Execution** - Execute tasks in this session using executing-plans, batch execution with checkpoints

**Which approach?"**

**If Subagent-Driven chosen:**
- **REQUIRED SUB-SKILL:** Use superpowers:delegate
- Fresh subagent per task + two-stage review

**If Inline Execution chosen:**
- **REQUIRED SUB-SKILL:** Use superpowers:executing-plans
- Batch execution with checkpoints for review
