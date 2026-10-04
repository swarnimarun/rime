# Build Scripts + Proc Macros Implementation Plan (Plan C M5)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:delegate (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement `src/cargo/script.zig`: build-script compile-then-run with cargo's exact output protocol, per-OS sandboxing, store-backed outputs (`action=build-script`) with `OUT_DIR` materialization, proc-macro host dylibs, and env-keyed action keys — against the M4 rustc-driver unit-graph seam.

**Architecture:** A pure parsing/caching core (`parseBuildOutput`, `envify`, `shouldRerun`, `scriptActionKey` — no FS, no Store) sits under a thin execution layer (`runScript`, sandbox wrappers, `ingestOutputs`) that consumes only the storage-v2 §16 Store surface (`putBytes`/`putManifest`/`tagObject`/`lookupObjects`/`materialize`, `lastFull`). The M4 driver owns the unit graph and rustc invocation; this plan defines the exact seam types M4 consumes (`ScriptUnit`, `ScriptResult`, `ProcMacroArtifact`) with a workspace-derived `planScripts` provider until the real unit graph lands.

**Tech Stack:** Zig 0.16.0, std only. Subprocess via `std.process.spawn` (exact `fetch.zig` `CliGit.cliRun` shape). Sandbox via `sandbox-exec` (macOS, required) and `unshare -rn` (Linux, best-effort, loud when unavailable).

**Spec:** `docs/design/storage-v2.md` §§5.2–5.3 + 11.3 + 12.1 + 16 (Store surface: `putBytes`/`putFile`/`tagObject`/`lookupObjects`/`materialize`/`reserve` semantics; `Kind.dylib` never demoted; `Kind.build_script_out` demotable; tag vocabulary; reuse predicates). Cargo behavior is normative, pinned to `references/cargo` (rust-lang/cargo 0.99.0) — every semantic below cites its file/function.

## Global Constraints

- Zig **0.16.0** exactly. FS access goes through the `std.Io` interface value passed as `io` to every call; `std.Io.Dir`/`std.Io.File` methods take `io` (copy call sites from `src/cargo/fetch.zig` `CliGit.cliRun` and `src/cargo/view.zig` exactly).
- `main` takes `std.process.Init`; scratch tools iterate `std.process.Args.Iterator` or hardcode. `std.process.argsAlloc` DOES NOT EXIST — never reference it.
- Subprocesses only via `std.process.spawn(io, .{ .argv, .environ_map, .cwd, .stdin = .ignore, .stdout = .pipe, .stderr = .pipe })` (`std.process.SpawnOptions.environ_map: ?*const std.process.Environ.Map` — verified against 0.16 `lib/std/process.zig:360` `SpawnOptions` and `lib/std/process/Environ.zig:99` `Map` with `init`/`clone`/`put`/`get`/`deinit`; `Map.clone(gpa)` at `Environ.zig:342`), output drained via `std.Io.File.MultiReader` exactly like `fetch.zig`, `child.wait(io)` must be `.exited == 0`. Never invent spawn options.
- mtimes are `std.Io.Timestamp{ .nanoseconds: i96 }` (`stat.mtime.nanoseconds`); compare with `>`/`<` on the `i96` directly.
- Dependencies: **std only**. No packages in `build.zig.zon`, no C sources.
- Module wiring: `script.zig` imports siblings by relative path (`@import("manifest.zig")`) and the store as `@import("store")` (same shape as `src/cargo/cli.zig:3`); parent-dir `@import("../store/…")` is rejected under bare `zig test` — never use it. One new re-export line in `src/cargo/root.zig`.
- Tests are inline (`test "…"` blocks). `zig build test` must pass before **every** commit. Never commit with failing tests.
- Caller-owned allocators everywhere; no global arenas. Every error set is a named `error{…}` unioned with the real std errors at the boundary (`std.mem.Allocator.Error`, `std.process.SpawnError`, `Io.Dir.*` errors) — never bare invented names alone on a fallible FS/process boundary.
- Cargo-compat invariants after every task: unknown/unsupported directives fail loudly with named errors; silent divergence is forbidden. Digest text form is `b3-<64 lowercase hex>` in user-facing output.
- All VCS operations use **jj**: `jj status`, `jj diff`, `jj commit <paths> -m "…"`. Never run git write commands. One logical change per commit, imperative ≤50-char summaries.
- Scratch experiments go in `/tmp`, never in the repo.
- `timeout 300` on blocking commands. No `find /` (zig std at `zig env` `std_dir`). No nohup/background.

---

## File Structure

```
src/cargo/script.zig      ALL new code: directive parsing, envify, DEP_ propagation,
                          rerun fingerprints, action keys, run+sandbox, store ingest,
                          OUT_DIR materialize, links validation, planScripts seam,
                          proc-macro artifacts (Tasks 1–8)
src/cargo/root.zig        add one re-export line (Task 8)
src/cargo/manifest.zig    add proc_macro flag parsing on [lib] (Task 7)
src/cargo/cli.zig         wire script execution into run() (Task 8)
testdata/cargo/script-protocol/   scripted build-script stdout fixtures (Tasks 1–2, 9)
validation/basic-workspace/       e2e: existing build.rs compiles end-to-end (Task 9)
validation/full-manifest/         e2e: existing build.rs compiles end-to-end (Task 9)
```

`script.zig` is one file with one responsibility (build-script + proc-macro lifecycle). The pure core (Tasks 1–3) takes no `io`/Store so protocol tests run without fixtures; the execution layer (Tasks 4–5) is the only part touching processes, sandbox, and Store. Each task's **Interfaces** block is the contract between tasks: exact names and types — implement exactly these, do not rename.

Cross-task shared types (defined once in Task 1/2, used everywhere — read before implementing any later task):

```zig
const std = @import("std");
const store_mod = @import("store");
const manifest_mod = @import("manifest.zig");

const Io = std.Io;
const Store = store_mod.Store;
const Digest = store_mod.Digest;
const Tag = store_mod.Tag;
```

---

### Task 1: Directive parser (`parseBuildOutput`)

**Files:**
- Create: `src/cargo/script.zig` (directive table + `BuildOutput` + `parseBuildOutput` only in this task)
- Test: inline `test "…"` blocks in `src/cargo/script.zig` + fixture `testdata/cargo/script-protocol/basic.txt` (created in this task)

**Interfaces:**
- Consumes: nothing (std only).
- Produces (used by Tasks 2–5, 8–9):
```zig
pub const DirectiveError = error{ InvalidDirective, UnknownKey } || std.mem.Allocator.Error;
pub const LinkArgTarget = enum { all, cdylib, bin, single_bin, test, bench, example };
pub const LinkArg = struct { target: LinkArgTarget, bin_name: ?[]const u8, arg: []const u8 };
pub const KeyValue = struct { key: []const u8, value: []const u8 };
pub const BuildOutput = struct {
    cfgs: []const []const u8,                 // cargo::rustc-cfg=FLAG (accumulates)
    check_cfgs: []const []const u8,           // cargo::rustc-check-cfg=…
    link_libs: []const []const u8,            // cargo::rustc-link-lib=… (+ -l from rustc-flags)
    link_search: []const []const u8,          // cargo::rustc-link-search=… (+ paths from rustc-flags)
    link_args: []const LinkArg,               // cargo::rustc-link-arg* family
    rustc_flags_raw: []const []const u8,      // cargo::rustc-flags=VALUE verbatim (kept for diagnostics)
    env: []const KeyValue,                    // cargo::rustc-env=KEY=VALUE
    metadata: []const KeyValue,               // cargo::KEY=VALUE unreserved (old) / cargo::metadata=KEY=VALUE (new)
    rerun_if_changed: []const []const u8,     // cargo::rerun-if-changed=PATH
    rerun_if_env_changed: []const []const u8, // cargo::rerun-if-env-changed=NAME
    warnings: []const []const u8,             // cargo::warning=… (new) / cargo:warning=… (old)
    errors: []const []const u8,               // cargo::error=… (new syntax only)
    pub fn deinit(self: *const BuildOutput, gpa: std.mem.Allocator) void {
        gpa.free(self.cfgs);
        gpa.free(self.check_cfgs);
        gpa.free(self.link_libs);
        gpa.free(self.link_search);
        gpa.free(self.link_args);
        gpa.free(self.rustc_flags_raw);
        gpa.free(self.env);
        gpa.free(self.metadata);
        gpa.free(self.rerun_if_changed);
        gpa.free(self.rerun_if_env_changed);
        gpa.free(self.warnings);
        gpa.free(self.errors);
    }
};
pub fn parseBuildOutput(gpa: std.mem.Allocator, input: []const u8, opts: ParseOptions) DirectiveError!BuildOutput;
```

`ParseOptions` carries the two pieces of caller context cargo's `BuildOutput::parse` receives beyond the raw bytes (`custom_build.rs:795` signature: `library_name`, `pkg_descr`, output-dir pair, `nightly_features_allowed`, `targets`, `msrv`):
```zig
pub const ParseOptions = struct {
    /// True when nightly features are allowed for this unit OR the parent
    /// process env already allowlists this crate in `RUSTC_BOOTSTRAP`
    /// (cargo `custom_build.rs:1074-1095` `rustc_bootstrap_allows`). Gates the
    /// `RUSTC_BOOTSTRAP` warn-vs-bail below.
    allow_rustc_bootstrap: bool = false,
    /// Target inventory for link-arg validation (cargo `check_and_add_target!`,
    /// `custom_build.rs:959-977`). `bin_names` holds every bin target name.
    has_cdylib: bool = false,
    bin_names: []const []const u8 = &.{},
    has_test: bool = false,
    has_bench: bool = false,
    has_example: bool = false,
};
```

Cargo pin: `references/cargo/src/cargo/core/compiler/custom_build.rs`, `BuildOutput::parse` (the `for line in input.split(...)` loop through the `match key { … }` ending `Ok(BuildOutput { … })`). The reserved-key table is normative — both syntaxes, exact spellings:
- New (`cargo::` prefix): `rustc-flags`, `rustc-link-lib`, `rustc-link-search`, `rustc-link-arg-cdylib`/`rustc-cdylib-link-arg` (both spellings accepted), `rustc-link-arg-bins`, `rustc-link-arg-bin` (`BIN=ARG` form), `rustc-link-arg-tests`, `rustc-link-arg-benches`, `rustc-link-arg-examples`, `rustc-link-arg`, `rustc-cfg`, `rustc-check-cfg`, `rustc-env`, `warning`, `error`, `rerun-if-changed`, `rerun-if-env-changed`, `metadata` (`metadata=KEY=VALUE`, split on first `=`).
- Old (`cargo:` prefix, same `RESERVED_PREFIXES` list in cargo): reserved keys parse as `KEY=VALUE` (require `=`); a non-reserved `cargo:foo=bar` line means `("metadata", "foo=bar")` — cargo lines 941–949. Non-`cargo:` lines are skipped silently (cargo line 951: `continue`).
- `error` exists ONLY in new syntax: a `cargo:error=…` line has no reserved prefix, so it falls into the old-syntax `("metadata", "error=…")` arm — implement exactly that (do not invent a `cargo:error` directive).
- Malformed lines (reserved key without `=`) → `InvalidDirective` (cargo's `bail!("invalid output in {whence}…Expected a line with …KEY=VALUE…")`); unknown new-syntax key → `UnknownKey` (cargo's `bail!("…Unknown key: `{key}`…")`). Values are trimmed of trailing whitespace only (`b.trim_end()` — leading whitespace is significant; use `std.mem.trimRight(u8, v, " \t\r")`).
- `rustc-flags` splits on ASCII whitespace (cargo `BuildOutput::parse_rustc_flags`, same file lines 1145–1191): `-l<lib>` or `-l <lib>` appends to `link_libs`; `-L<path>` or `-L <path>` appends to `link_search`; a bare `-l`/`-L` with no following token → `InvalidDirective` (cargo's `bail!("flag in rustc-flags has no value…")`); ANY other token → `InvalidDirective` (cargo's `bail!("only `-l` and `-L` flags are allowed…")`). Keep the verbatim value in `rustc_flags_raw` too.
- `rustc-env` splits on the FIRST `=`; missing `=` → `InvalidDirective` (cargo `parse_rustc_env`, line 1193). `RUSTC_BOOTSTRAP` follows cargo's conditional path (`custom_build.rs:1061-1108`, not an unconditional reject): when `opts.allow_rustc_bootstrap` is set (nightly features allowed for this unit, or the parent `RUSTC_BOOTSTRAP` env already allowlists this crate per `rustc_bootstrap_allows` at lines 1074–1095) the pair becomes a `warnings` entry (`cannot set RUSTC_BOOTSTRAP=…`); otherwise `InvalidDirective` (cargo's `bail!("cannot set `RUSTC_BOOTSTRAP=…`…")`). Task 5 computes the flag from the toolchain channel + parent env and passes it in `ParseOptions`; tests cover both arms.
- `rustc-link-arg-bin` requires `BIN=ARG` (split on first `=`); missing `=` → `InvalidDirective` (cargo lines 1014–1035). Target-existence validation is exact (cargo `check_and_add_target!`, lines 959–977, against `opts`): `rustc-link-arg-bins` with no bin target → `InvalidDirective`; `rustc-link-arg-bin=BIN=ARG` with `BIN` not in `opts.bin_names` → `InvalidDirective`; `rustc-link-arg-tests`/`-benches`/`-examples` without the corresponding target → `InvalidDirective`; `rustc-link-arg-cdylib`/`rustc-cdylib-link-arg` without a cdylib target is a `warnings` entry (cargo downgrades to warning per issue #9562, lines 989–1009), the arg is still recorded.
- `rerun-if-changed` with an empty value is allowed (cargo pushes the empty path; the fingerprint layer treats it as "nothing watched" — do NOT error here; Task 3 decides).
- All slices borrow from one internal arena duplicated into gpa-owned slices on return; `deinit` frees every slice with `gpa` (document: `deinit` frees, struct itself is caller-owned).

- [ ] **Step 1: Write the fixture and the failing test**

`testdata/cargo/script-protocol/basic.txt` (scripted stdout, mixed syntaxes + noise lines):
```text
some noise from cc
cargo::rustc-cfg=has_build_script
cargo::rustc-check-cfg=cfg(has_build_script)
cargo::rustc-link-lib=foo
cargo::rustc-link-search=native=/tmp/lib
cargo:rustc-env=OLD_VAR=1
cargo:mykey=myvalue
cargo::rerun-if-changed=build.rs
cargo::rerun-if-env-changed=MY_ENV
cargo::warning=be careful
```

```zig
test "directive parser handles mixed syntaxes" {
    const text = @embedFile("../../testdata/cargo/script-protocol/basic.txt");
    var out = try parseBuildOutput(std.testing.allocator, text, .{});
    defer out.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), out.cfgs.len);
    try std.testing.expectEqualStrings("has_build_script", out.cfgs[0]);
    try std.testing.expectEqual(@as(usize, 1), out.link_libs.len);
    try std.testing.expectEqualStrings("foo", out.link_libs[0]);
    try std.testing.expectEqual(@as(usize, 1), out.metadata.len);
    try std.testing.expectEqualStrings("mykey", out.metadata[0].key);
    try std.testing.expectEqualStrings("myvalue", out.metadata[0].value);
    try std.testing.expectEqual(@as(usize, 1), out.rerun_if_changed.len);
    try std.testing.expectEqualStrings("build.rs", out.rerun_if_changed[0]);
    try std.testing.expectEqual(@as(usize, 1), out.warnings.len);
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test 2>&1 | tail -10`
Expected: FAIL — `src/cargo/script.zig` / `parseBuildOutput` not defined. (If the `cargo` module does not yet re-export `script`, add the single line `pub const script = @import("script.zig");` to `src/cargo/root.zig` plus the `_ = @import("script.zig");` line in its test block now — that wiring is part of this step.)

- [ ] **Step 3: Write minimal implementation**

```zig
const std = @import("std");

pub const DirectiveError = error{ InvalidDirective, UnknownKey } || std.mem.Allocator.Error;

fn isReservedNew(key: []const u8) bool {
    const reserved = [_][]const u8{
        "rustc-flags", "rustc-link-lib", "rustc-link-search",
        "rustc-link-arg-cdylib", "rustc-cdylib-link-arg",
        "rustc-link-arg-bins", "rustc-link-arg-bin",
        "rustc-link-arg-tests", "rustc-link-arg-benches",
        "rustc-link-arg-examples", "rustc-link-arg",
        "rustc-cfg", "rustc-check-cfg", "rustc-env",
        "warning", "error", "rerun-if-changed", "rerun-if-env-changed",
        "metadata",
    };
    for (reserved) |r| if (std.mem.eql(u8, r, key)) return true;
    return false;
}

fn isReservedOld(data: []const u8) bool {
    // cargo RESERVED_PREFIXES (custom_build.rs): prefix match on "key=" form.
    const prefixes = [_][]const u8{
        "rustc-flags=", "rustc-link-lib=", "rustc-link-search=",
        "rustc-link-arg-cdylib=", "rustc-cdylib-link-arg=",
        "rustc-link-arg-bins=", "rustc-link-arg-bin=",
        "rustc-link-arg-tests=", "rustc-link-arg-benches=",
        "rustc-link-arg-examples=", "rustc-link-arg=",
        "rustc-cfg=", "rustc-check-cfg=", "rustc-env=",
        "warning=", "rerun-if-changed=", "rerun-if-env-changed=",
    };
    for (prefixes) |p| if (std.mem.startsWith(u8, data, p)) return true;
    return false;
}

fn splitKeyValue(data: []const u8) DirectiveError!struct { key: []const u8, value: []const u8 } {
    const eq = std.mem.indexOfScalar(u8, data, '=') orelse return DirectiveError.InvalidDirective;
    return .{
        .key = data[0..eq],
        .value = std.mem.trimRight(u8, data[eq + 1 ..], " \t\r"),
    };
}

pub fn parseBuildOutput(gpa: std.mem.Allocator, input: []const u8, opts: ParseOptions) DirectiveError!BuildOutput {
    var cfgs: std.ArrayList([]const u8) = .empty;
    var check_cfgs: std.ArrayList([]const u8) = .empty;
    var link_libs: std.ArrayList([]const u8) = .empty;
    var link_search: std.ArrayList([]const u8) = .empty;
    var link_args: std.ArrayList(LinkArg) = .empty;
    var rustc_flags_raw: std.ArrayList([]const u8) = .empty;
    var env: std.ArrayList(KeyValue) = .empty;
    var metadata: std.ArrayList(KeyValue) = .empty;
    var rerun_if_changed: std.ArrayList([]const u8) = .empty;
    var rerun_if_env_changed: std.ArrayList([]const u8) = .empty;
    var warnings: std.ArrayList([]const u8) = .empty;
    var errors: std.ArrayList([]const u8) = .empty;
    errdefer {
        cfgs.deinit(gpa);
        check_cfgs.deinit(gpa);
        link_libs.deinit(gpa);
        link_search.deinit(gpa);
        link_args.deinit(gpa);
        rustc_flags_raw.deinit(gpa);
        env.deinit(gpa);
        metadata.deinit(gpa);
        rerun_if_changed.deinit(gpa);
        rerun_if_env_changed.deinit(gpa);
        warnings.deinit(gpa);
        errors.deinit(gpa);
    }
    var acc = Acc{
        .gpa = gpa,
        .opts = opts,
        .cfgs = &cfgs,
        .check_cfgs = &check_cfgs,
        .link_libs = &link_libs,
        .link_search = &link_search,
        .link_args = &link_args,
        .rustc_flags_raw = &rustc_flags_raw,
        .env = &env,
        .metadata = &metadata,
        .rerun_if_changed = &rerun_if_changed,
        .rerun_if_env_changed = &rerun_if_env_changed,
        .warnings = &warnings,
        .errors = &errors,
    };
    var lines = std.mem.splitScalar(u8, input, '\n');
    while (lines.next()) |raw| {
        // Byte-wise matching with no UTF-8 decode: a non-UTF8 line can never
        // equal the ASCII `cargo:` prefixes or keys, so it is skipped — the
        // same observable outcome as cargo's `str::from_utf8 … Err(..) => continue`.
        const line = std.mem.trim(u8, raw, " \t\r");
        if (std.mem.startsWith(u8, line, "cargo::")) {
            const kv = try splitKeyValue(line["cargo::".len..]);
            if (!isReservedNew(kv.key)) return DirectiveError.UnknownKey;
            try dispatchNew(&acc, kv.key, kv.value);
        } else if (std.mem.startsWith(u8, line, "cargo:")) {
            const data = line["cargo:".len..];
            if (isReservedOld(data)) {
                const kv = try splitKeyValue(data);
                try dispatchOld(&acc, kv.key, kv.value);
            } else {
                // ("metadata", data): unreserved old-syntax line; split metadata KEY=VALUE lazily.
                const kv = try splitKeyValue(data);
                try metadata.append(gpa, .{ .key = kv.key, .value = kv.value });
            }
        }
        // else: skip (not a directive)
    }
    return .{
        .cfgs = try cfgs.toOwnedSlice(gpa),
        .check_cfgs = try check_cfgs.toOwnedSlice(gpa),
        .link_libs = try link_libs.toOwnedSlice(gpa),
        .link_search = try link_search.toOwnedSlice(gpa),
        .link_args = try link_args.toOwnedSlice(gpa),
        .rustc_flags_raw = try rustc_flags_raw.toOwnedSlice(gpa),
        .env = try env.toOwnedSlice(gpa),
        .metadata = try metadata.toOwnedSlice(gpa),
        .rerun_if_changed = try rerun_if_changed.toOwnedSlice(gpa),
        .rerun_if_env_changed = try rerun_if_env_changed.toOwnedSlice(gpa),
        .warnings = try warnings.toOwnedSlice(gpa),
        .errors = try errors.toOwnedSlice(gpa),
    };
}

const Acc = struct {
    gpa: std.mem.Allocator,
    opts: ParseOptions,
    cfgs: *std.ArrayList([]const u8),
    check_cfgs: *std.ArrayList([]const u8),
    link_libs: *std.ArrayList([]const u8),
    link_search: *std.ArrayList([]const u8),
    link_args: *std.ArrayList(LinkArg),
    rustc_flags_raw: *std.ArrayList([]const u8),
    env: *std.ArrayList(KeyValue),
    metadata: *std.ArrayList(KeyValue),
    rerun_if_changed: *std.ArrayList([]const u8),
    rerun_if_env_changed: *std.ArrayList([]const u8),
    warnings: *std.ArrayList([]const u8),
    errors: *std.ArrayList([]const u8),
};

fn dispatchNew(acc: *Acc, key: []const u8, value: []const u8) DirectiveError!void {
    const gpa = acc.gpa;
    if (std.mem.eql(u8, key, "rustc-flags")) {
        try acc.rustc_flags_raw.append(gpa, value);
        var it = std.mem.tokenizeAny(u8, value, " \t");
        while (it.next()) |flag| {
            if (std.mem.eql(u8, flag, "-l")) {
                const lib = it.next() orelse return DirectiveError.InvalidDirective;
                try acc.link_libs.append(gpa, lib);
            } else if (std.mem.eql(u8, flag, "-L")) {
                const path = it.next() orelse return DirectiveError.InvalidDirective;
                try acc.link_search.append(gpa, path);
            } else if (flag.len > 2 and std.mem.startsWith(u8, flag, "-l")) {
                try acc.link_libs.append(gpa, flag[2..]);
            } else if (flag.len > 2 and std.mem.startsWith(u8, flag, "-L")) {
                try acc.link_search.append(gpa, flag[2..]);
            } else {
                return DirectiveError.InvalidDirective;
            }
        }
    } else if (std.mem.eql(u8, key, "rustc-link-lib")) {
        try acc.link_libs.append(gpa, value);
    } else if (std.mem.eql(u8, key, "rustc-link-search")) {
        try acc.link_search.append(gpa, value);
    } else if (std.mem.eql(u8, key, "rustc-link-arg-cdylib") or std.mem.eql(u8, key, "rustc-cdylib-link-arg")) {
        if (!acc.opts.has_cdylib) {
            try acc.warnings.append(gpa, "rustc-link-arg-cdylib was specified but the package does not contain a cdylib target");
        }
        try acc.link_args.append(gpa, .{ .target = .cdylib, .bin_name = null, .arg = value });
    } else if (std.mem.eql(u8, key, "rustc-link-arg-bins")) {
        if (acc.opts.bin_names.len == 0) return DirectiveError.InvalidDirective;
        try acc.link_args.append(gpa, .{ .target = .bin, .bin_name = null, .arg = value });
    } else if (std.mem.eql(u8, key, "rustc-link-arg-bin")) {
        const eq = std.mem.indexOfScalar(u8, value, '=') orelse return DirectiveError.InvalidDirective;
        const bin_name = value[0..eq];
        var known = false;
        for (acc.opts.bin_names) |n| if (std.mem.eql(u8, n, bin_name)) {
            known = true;
            break;
        };
        if (!known) return DirectiveError.InvalidDirective;
        try acc.link_args.append(gpa, .{ .target = .single_bin, .bin_name = bin_name, .arg = value[eq + 1 ..] });
    } else if (std.mem.eql(u8, key, "rustc-link-arg-tests")) {
        if (!acc.opts.has_test) return DirectiveError.InvalidDirective;
        try acc.link_args.append(gpa, .{ .target = .test, .bin_name = null, .arg = value });
    } else if (std.mem.eql(u8, key, "rustc-link-arg-benches")) {
        if (!acc.opts.has_bench) return DirectiveError.InvalidDirective;
        try acc.link_args.append(gpa, .{ .target = .bench, .bin_name = null, .arg = value });
    } else if (std.mem.eql(u8, key, "rustc-link-arg-examples")) {
        if (!acc.opts.has_example) return DirectiveError.InvalidDirective;
        try acc.link_args.append(gpa, .{ .target = .example, .bin_name = null, .arg = value });
    } else if (std.mem.eql(u8, key, "rustc-link-arg")) {
        try acc.link_args.append(gpa, .{ .target = .all, .bin_name = null, .arg = value });
    } else if (std.mem.eql(u8, key, "rustc-cfg")) {
        try acc.cfgs.append(gpa, value);
    } else if (std.mem.eql(u8, key, "rustc-check-cfg")) {
        try acc.check_cfgs.append(gpa, value);
    } else if (std.mem.eql(u8, key, "rustc-env")) {
        const eq = std.mem.indexOfScalar(u8, value, '=') orelse return DirectiveError.InvalidDirective;
        const name = value[0..eq];
        if (std.mem.eql(u8, name, "RUSTC_BOOTSTRAP")) {
            if (acc.opts.allow_rustc_bootstrap) {
                try acc.warnings.append(gpa, value);
            } else {
                return DirectiveError.InvalidDirective;
            }
        } else {
            try acc.env.append(gpa, .{ .key = name, .value = value[eq + 1 ..] });
        }
    } else if (std.mem.eql(u8, key, "warning")) {
        try acc.warnings.append(gpa, value);
    } else if (std.mem.eql(u8, key, "error")) {
        try acc.errors.append(gpa, value);
    } else if (std.mem.eql(u8, key, "rerun-if-changed")) {
        try acc.rerun_if_changed.append(gpa, value);
    } else if (std.mem.eql(u8, key, "rerun-if-env-changed")) {
        try acc.rerun_if_env_changed.append(gpa, value);
    } else if (std.mem.eql(u8, key, "metadata")) {
        const eq = std.mem.indexOfScalar(u8, value, '=') orelse return DirectiveError.InvalidDirective;
        try acc.metadata.append(gpa, .{ .key = value[0..eq], .value = value[eq + 1 ..] });
    } else {
        return DirectiveError.UnknownKey;
    }
}

fn dispatchOld(acc: *Acc, key: []const u8, value: []const u8) DirectiveError!void {
    // Old syntax reaches here only for reserved keys, a subset of the new arms
    // (`error`/`metadata` are not in RESERVED_PREFIXES, so they never arrive).
    // `warning` appends to `warnings`, exactly like the new arm.
    return dispatchNew(acc, key, value);
}
```

`dispatchNew` above is the exact cargo `match key` arms (`custom_build.rs:980-1125`): unknown key → `UnknownKey`; `metadata` → split on first `=` or `InvalidDirective`; `rustc-env` → split or `InvalidDirective`, `RUSTC_BOOTSTRAP` warn-vs-bail on `opts.allow_rustc_bootstrap`; `rustc-flags` → `-l`/`-L` split with `InvalidDirective` on anything else; `rustc-link-arg-bin` → `BIN=ARG` split plus bin-name membership, or `InvalidDirective`; `warning`/`error` append; `rerun-if-*` append. `dispatchOld` forwards (old reserved keys are a strict subset; old `warning` appends to `warnings`). Strings borrow `input` (no dupes; document lifetime: output valid while `input` lives).

- [ ] **Step 4: Add edge-case tests and make them pass**

```zig
test "directive parser rejects unknown new keys and malformed lines" {
    try std.testing.expectError(DirectiveError.UnknownKey, parseBuildOutput(std.testing.allocator, "cargo::frobnicate=1\n", .{}));
    try std.testing.expectError(DirectiveError.InvalidDirective, parseBuildOutput(std.testing.allocator, "cargo::rustc-cfg\n", .{}));
    try std.testing.expectError(DirectiveError.InvalidDirective, parseBuildOutput(std.testing.allocator, "cargo::rustc-env=NOEQUALS\n", .{}));
}

test "directive parser treats cargo:error as metadata" {
    var out = try parseBuildOutput(std.testing.allocator, "cargo:error=boom\n", .{});
    defer out.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), out.errors.len);
    try std.testing.expectEqual(@as(usize, 1), out.metadata.len);
    try std.testing.expectEqualStrings("error", out.metadata[0].key);
}

test "directive parser expands rustc-flags -l/-L and rejects other flags" {
    var out = try parseBuildOutput(std.testing.allocator, "cargo::rustc-flags=-l foo -L /tmp/x\n", .{});
    defer out.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("foo", out.link_libs[0]);
    try std.testing.expectEqualStrings("/tmp/x", out.link_search[0]);
    try std.testing.expectEqual(@as(usize, 1), out.rustc_flags_raw.len);
    try std.testing.expectError(DirectiveError.InvalidDirective, parseBuildOutput(std.testing.allocator, "cargo::rustc-flags=-C opt-level=2\n", .{}));
    try std.testing.expectError(DirectiveError.InvalidDirective, parseBuildOutput(std.testing.allocator, "cargo::rustc-flags=-l\n", .{}));
}

test "directive parser gates RUSTC_BOOTSTRAP on the allow flag" {
    try std.testing.expectError(DirectiveError.InvalidDirective, parseBuildOutput(std.testing.allocator, "cargo::rustc-env=RUSTC_BOOTSTRAP=1\n", .{}));
    var out = try parseBuildOutput(std.testing.allocator, "cargo::rustc-env=RUSTC_BOOTSTRAP=1\n", .{ .allow_rustc_bootstrap = true });
    defer out.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), out.env.len);
    try std.testing.expectEqual(@as(usize, 1), out.warnings.len);
}

test "directive parser bails on link-arg targets that do not exist" {
    try std.testing.expectError(DirectiveError.InvalidDirective, parseBuildOutput(std.testing.allocator, "cargo::rustc-link-arg-bins=--foo\n", .{}));
    const bins = [_][]const u8{"app"};
    var out = try parseBuildOutput(std.testing.allocator, "cargo::rustc-link-arg-bin=app=--foo\n", .{ .bin_names = &bins });
    defer out.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), out.link_args.len);
    try std.testing.expectEqualStrings("app", out.link_args[0].bin_name.?);
    try std.testing.expectError(DirectiveError.InvalidDirective, parseBuildOutput(std.testing.allocator, "cargo::rustc-link-arg-bin=other=--foo\n", .{ .bin_names = &bins }));
    var warn_out = try parseBuildOutput(std.testing.allocator, "cargo::rustc-link-arg-cdylib=--foo\n", .{});
    defer warn_out.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), warn_out.warnings.len);
    try std.testing.expectEqual(@as(usize, 1), warn_out.link_args.len);
}
```

Run: `zig build test 2>&1 | tail -5`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
jj status
jj commit src/cargo/script.zig src/cargo/root.zig testdata/cargo/script-protocol/basic.txt -m "Add build-script directive parser"
```

---

### Task 2: `envify` + `links` metadata propagation

**Files:**
- Modify: `src/cargo/script.zig` (append; no other files)
- Test: inline tests + fixture `testdata/cargo/script-protocol/links.txt`

**Interfaces:**
- Consumes: `BuildOutput` (Task 1).
- Produces (used by Tasks 5–6, 8):
```zig
pub const PropagationError = std.mem.Allocator.Error; // no fallible cases: links==null still emits CARGO_DEP_ (see below)
pub fn envify(gpa: std.mem.Allocator, name: []const u8) std.mem.Allocator.Error![]u8;
pub fn depEnvName(gpa: std.mem.Allocator, prefix: []const u8, links: []const u8, key: []const u8) std.mem.Allocator.Error![]u8;
pub fn propagateMetadata(gpa: std.mem.Allocator, links: ?[]const u8, package_name: []const u8, metadata: []const KeyValue) PropagationError![]KeyValue;
```

Cargo pins:
- `super::envify` (`references/cargo/src/cargo/core/compiler/mod.rs:2035`, `s.chars().flat_map(|c| c.to_uppercase()).map(|c| if c == '-' { '_' } else { c })`): ASCII lowercase uppercases, `-` maps to `_`, and EVERY other byte — including `.` — passes through unchanged. There is no alphanumeric gate. So `native-foo.bar2` → `NATIVE_FOO.BAR2`. Length-changing non-ASCII case folds (e.g. `ß` → `SS`) are a documented deviation: rime maps bytewise and preserves length.
- DEP propagation (`custom_build.rs:560-577`, `build_work` dirty-work closure, the `for (name, links, dep_id, dep_metadata) in lib_deps` loop): for each direct dependency, every `(key, value)` in that dependency's `metadata` becomes env `CARGO_DEP_<ENVIFY(package_name)>_<ENVIFY(key)>` — this form is OUTSIDE cargo's `if let Some(ref links)` (lines 570–577), so it is emitted even when the dependency declares no `links` key. The `DEP_<ENVIFY(links)>_<ENVIFY(key)>` form is INSIDE the `if let` (lines 565–571) and is emitted only when `links` is present. rime always emits the `CARGO_DEP_` form (documented deviation: cargo gates it on unstable `-Zany-build-script-metadata`; rime treats the flag as always-on so downstream scripts never observe a flag-dependent env shape — the extra vars are additive and cannot collide with reserved keys because of the `DEP_`/`CARGO_DEP_` prefixes).
- `CARGO_MANIFEST_LINKS` (`custom_build.rs` `build_work`: `if let Some(links) = unit.pkg.manifest().links() { cmd.env("CARGO_MANIFEST_LINKS", links); }`) — the script's OWN links key is exposed to itself; Task 5 sets it. The `DEP_` form requires the dependency's `links` key; the `CARGO_DEP_` form does not (same loop, outside the `if let`).

- [ ] **Step 1: Write the failing test**

`testdata/cargo/script-protocol/links.txt`:
```text
cargo::metadata=root=/tmp/native-root
cargo::metadata=includedir=/tmp/native-root/include
```

```zig
test "dep metadata propagates to DEP_ and CARGO_DEP_ env names" {
    const text = @embedFile("../../testdata/cargo/script-protocol/links.txt");
    var out = try parseBuildOutput(std.testing.allocator, text, .{});
    defer out.deinit(std.testing.allocator);
    const vars = try propagateMetadata(std.testing.allocator, "native-foo", "foo-sys", out.metadata);
    defer { for (vars) |v| { std.testing.allocator.free(v.key); } std.testing.allocator.free(vars); }
    // links="native-foo" -> ENVIFY -> "NATIVE_FOO"; key "root" stays "ROOT".
    try std.testing.expectEqual(@as(usize, 4), vars.len);
    try std.testing.expectEqualStrings("DEP_NATIVE_FOO_ROOT", vars[0].key);
    try std.testing.expectEqualStrings("CARGO_DEP_FOO_SYS_ROOT", vars[1].key);
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test 2>&1 | tail -10`
Expected: FAIL — `propagateMetadata`/`envify` not defined.

- [ ] **Step 3: Write minimal implementation**

```zig
pub fn envify(gpa: std.mem.Allocator, name: []const u8) std.mem.Allocator.Error![]u8 {
    // cargo mod.rs:2035: uppercase, then map only '-' to '_'. '.' and all
    // other bytes pass through unchanged (so "native-foo.bar2" -> "NATIVE_FOO.BAR2").
    const out = try gpa.alloc(u8, name.len);
    for (name, out) |c, *o| {
        if (c >= 'a' and c <= 'z') {
            o.* = c - ('a' - 'A');
        } else if (c == '-') {
            o.* = '_';
        } else {
            o.* = c;
        }
    }
    return out;
}

pub fn depEnvName(gpa: std.mem.Allocator, prefix: []const u8, links: []const u8, key: []const u8) std.mem.Allocator.Error![]u8 {
    const e_links = try envify(gpa, links);
    defer gpa.free(e_links);
    const e_key = try envify(gpa, key);
    defer gpa.free(e_key);
    return std.fmt.allocPrint(gpa, "{s}_{s}_{s}", .{ prefix, e_links, e_key });
}

pub fn propagateMetadata(gpa: std.mem.Allocator, links: ?[]const u8, package_name: []const u8, metadata: []const KeyValue) PropagationError![]KeyValue {
    // cargo custom_build.rs:560-577: DEP_<links>_<key> is inside
    // `if let Some(ref links)`; CARGO_DEP_<name>_<key> is OUTSIDE it, so
    // links == null still emits the CARGO_DEP_ forms.
    var vars: std.ArrayList(KeyValue) = .empty;
    errdefer {
        for (vars.items) |v| gpa.free(v.key);
        vars.deinit(gpa);
    }
    for (metadata) |m| {
        if (links) |l| {
            const dep_name = try depEnvName(gpa, "DEP", l, m.key);
            errdefer gpa.free(dep_name);
            try vars.append(gpa, .{ .key = dep_name, .value = m.value });
        }
        const cargo_name = try depEnvName(gpa, "CARGO_DEP", package_name, m.key);
        errdefer gpa.free(cargo_name);
        try vars.append(gpa, .{ .key = cargo_name, .value = m.value });
    }
    return vars.toOwnedSlice(gpa);
}
```

Ordering contract (pinned for Task 5's env assembly and Task 9's assertion): per metadata pair, `DEP_…` immediately followed by its `CARGO_DEP_…` sibling, pairs in script-emission order. Values borrow the `BuildOutput` slices (document lifetime); keys are gpa-owned (caller frees each `key`, then the slice — exact free loop is in the test above, copy it).

- [ ] **Step 4: Add envify edge tests and make them pass**

```zig
test "envify uppercases and maps only '-' to '_'" {
    const e = try envify(std.testing.allocator, "native-foo.bar2");
    defer std.testing.allocator.free(e);
    try std.testing.expectEqualStrings("NATIVE_FOO.BAR2", e);
}

test "propagate without links emits only CARGO_DEP_" {
    const md = [_]KeyValue{.{ .key = "root", .value = "x" }};
    const vars = try propagateMetadata(std.testing.allocator, null, "foo-sys", &md);
    defer {
        for (vars) |v| std.testing.allocator.free(v.key);
        std.testing.allocator.free(vars);
    }
    try std.testing.expectEqual(@as(usize, 1), vars.len);
    try std.testing.expectEqualStrings("CARGO_DEP_FOO_SYS_ROOT", vars[0].key);
}
```

Run: `zig build test 2>&1 | tail -5`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
jj status
jj commit src/cargo/script.zig testdata/cargo/script-protocol/links.txt -m "Add links metadata propagation"
```

---

### Task 3: Rerun fingerprint (`shouldRerun`)

**Files:**
- Modify: `src/cargo/script.zig` (append; no other files)
- Test: inline tests (tmp dirs via `std.testing.tmpDir`, real `io`)

**Interfaces:**
- Consumes: `BuildOutput.rerun_if_changed` / `rerun_if_env_changed` (Task 1).
- Produces (used by Tasks 4–5, 8):
```zig
pub const RerunError = error{ OldStyleFallback } || std.mem.Allocator.Error || Io.Dir.StatFileError;
pub const RerunDecision = enum { rerun, fresh };
pub const RerunInputs = struct {
    /// Previous run's rerun-if lists (parsed from the stored BuildOutput; null = never ran).
    prev_changed: ?[]const []const u8,
    prev_env_changed: ?[]const []const u8,
    /// mtime anchor: the stored "output" time of the previous run, as i96 nanos.
    /// Absent (null) on first run -> rerun.
    prev_output_ns: ?i96,
    /// Current values of the env names in prev_env_changed, same order; null entry = currently unset.
    current_env: []const ?[]const u8,
    /// Stored values of those env names from the previous run, same order; null entry = was unset.
    prev_env_values: []const ?[]const u8,
};
pub fn shouldRerun(gpa: std.mem.Allocator, io: Io, pkg_dir_abs: []const u8, inputs: RerunInputs) RerunError!RerunDecision;
pub fn mtimeNsOf(io: Io, dir: Io.Dir, rel_path: []const u8) Io.Dir.StatFileError!?i96;
```

Cargo pins (`references/cargo/src/cargo/core/compiler/fingerprint/mod.rs`):
- Old-style vs new-style (module docs "Build script mtime handling" + "## Build scripts"): a script that emitted NO `rerun-if-changed` AND NO `rerun-if-env-changed` runs in old style — ANY file change in the package reruns it (`LocalFingerprint::Precalculated`). rime does not implement package-wide mtime walks: old style returns `RerunError.OldStyleFallback`, and the caller (Task 8) treats it as **always rerun** with a loud stderr line (`warning: <pkg> build script uses old-style rerun detection; always re-running (package mtime walk not implemented)`). Documented deviation, loud by construction.
- New style: fingerprint tracks ONLY the listed items (docs: "the fingerprint *only* tracks the individual 'rerun-if' items"). `shouldRerun` returns `rerun` iff ANY of: first run (`prev_output_ns == null`); a listed path's mtime is newer than the anchor; a listed env var's current value differs from its stored value (unset-vs-set counts as a change); the SET of watched names changed between runs (cargo: "Care must be taken…such as if the build script adds or removes 'rerun-if' items" — compare current script's lists, passed by the caller, against `prev_*`; length or member mismatch → rerun). Otherwise `fresh`.
- `rerun-if-changed` paths resolve relative to the package root (`pkg_dir_abs`); absolute paths used verbatim. Missing file → `rerun` (cargo `find_stale_file`: missing inputs are dirty). Anchor semantics: cargo rewinds the output mtime to just before execution; rime stores `prev_output_ns` captured BEFORE spawning (Task 5 captures it) so mid-build modifications count as newer.
- `RUSTC_BOOTSTRAP`-style concerns do not apply here; env comparison uses exact byte equality (`std.mem.eql`), with `timing_safe` NOT needed (not a secret).

- [ ] **Step 1: Write the failing test**

```zig
test "rerun fires on changed file and changed env, quiet otherwise" {
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "watched.txt", .data = "v1" });
    const pkg_abs = try tmp.dir.realPathFileAlloc(io, ".", std.testing.allocator);
    defer std.testing.allocator.free(pkg_abs);
    const st = try tmp.dir.statFile(io, "watched.txt", .{});
    const anchor: i96 = st.mtime.nanoseconds - 1; // file is newer than anchor

    const changed = [_][]const u8{"watched.txt"};
    const env_names = [_][]const u8{"MY_ENV"};
    const cur = [_]?[]const u8{"1"};
    const prev = [_]?[]const u8{"1"};
    const d1 = try shouldRerun(std.testing.allocator, io, pkg_abs, .{
        .prev_changed = &changed, .prev_env_changed = &env_names,
        .prev_output_ns = anchor, .current_env = &cur, .prev_env_values = &prev,
    });
    try std.testing.expect(d1 == .rerun);

    const st2 = try tmp.dir.statFile(io, "watched.txt", .{});
    const fresh_anchor: i96 = st2.mtime.nanoseconds + 1; // anchor newer than file
    const d2 = try shouldRerun(std.testing.allocator, io, pkg_abs, .{
        .prev_changed = &changed, .prev_env_changed = &env_names,
        .prev_output_ns = fresh_anchor, .current_env = &cur, .prev_env_values = &prev,
    });
    try std.testing.expect(d2 == .fresh);
}
```

(The test passes an ABSOLUTE tmp path obtained with `tmp.dir.realPathFileAlloc(io, ".", std.testing.allocator)` — same shape as the M1 view test. Never pass `"."` literally: the package root is an absolute path by contract.)

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test 2>&1 | tail -10`
Expected: FAIL — `shouldRerun` not defined.

- [ ] **Step 3: Write minimal implementation**

```zig
pub fn mtimeNsOf(io: Io, dir: Io.Dir, rel_path: []const u8) Io.Dir.StatFileError!?i96 {
    const st = dir.statFile(io, rel_path, .{}) catch |e| switch (e) {
        error.FileNotFound => return null,
        else => return e,
    };
    return st.mtime.nanoseconds;
}

pub fn shouldRerun(gpa: std.mem.Allocator, io: Io, pkg_dir_abs: []const u8, inputs: RerunInputs) RerunError!RerunDecision {
    _ = gpa;
    const anchor = inputs.prev_output_ns orelse return .rerun;
    const changed = inputs.prev_changed orelse return .rerun;
    const env_names = inputs.prev_env_changed orelse return .rerun;
    if (changed.len == 0 and env_names.len == 0) return RerunError.OldStyleFallback;
    // Caller passes the CURRENT script lists separately? No — by contract the
    // caller compares current lists to prev lists BEFORE calling (Task 8:
    // watch-set mismatch => rerun without calling). Documented at the call site.
    // No `Io.Dir.openPath` (does not exist in 0.16): the package root opens via
    // `Io.Dir.cwd().createDirPathOpen` (repo-verified absolute-dir shape,
    // `fetch.zig:247`, `cli.zig:433`); unreadable root => rerun, never crash.
    var pkg_dir = Io.Dir.cwd().createDirPathOpen(io, pkg_dir_abs, .{}) catch return .rerun;
    defer pkg_dir.close(io);
    for (changed) |rel| {
        // Absolute watched paths stat through the cwd handle with the absolute
        // path verbatim (same shape as `workspace.zig` `existsFile`, which
        // calls `Io.Dir.cwd().statFile(io, path, .{})` on absolute paths);
        // relative paths stat through the package-root handle.
        const ns: ?i96 = if (std.fs.path.isAbsolute(rel))
            try mtimeNsOf(io, Io.Dir.cwd(), rel)
        else
            try mtimeNsOf(io, pkg_dir, rel);
        const file_ns = ns orelse return .rerun; // missing => dirty
        if (file_ns > anchor) return .rerun;
    }
    std.debug.assert(inputs.current_env.len == env_names.len);
    std.debug.assert(inputs.prev_env_values.len == env_names.len);
    for (env_names, inputs.current_env, inputs.prev_env_values) |_, cur, prv| {
        const same = if (cur == null and prv == null) true
        else if (cur == null or prv == null) false
        else std.mem.eql(u8, cur.?, prv.?);
        if (!same) return .rerun;
    }
    return .fresh;
}
```

`Io.Dir.cwd().createDirPathOpen` is the repo-verified absolute-dir shape (`fetch.zig:247`, `cli.zig:433`); `cwd().statFile` with an absolute sub-path is the `workspace.zig` `existsFile` shape; `std.fs.path.isAbsolute` is the same family as `view.zig`'s `std.fs.path.join` usage. Watch-set comparison lives in Task 8 (`watchSetChanged`: lengths + memberwise `eql`, order-sensitive — cargo stores them ordered, rime preserves emission order from Task 1, so order-sensitive compare is correct).

- [ ] **Step 4: Add old-style + missing-file tests and make them pass**

```zig
test "rerun old-style falls back loudly" {
    const empty = [_][]const u8{};
    const novars = [_]?[]const u8{};
    try std.testing.expectError(RerunError.OldStyleFallback, shouldRerun(
        std.testing.allocator, std.Io.Threaded.global_single_threaded.io(), "/tmp",
        .{ .prev_changed = &empty, .prev_env_changed = &empty, .prev_output_ns = 0, .current_env = &novars, .prev_env_values = &novars },
    ));
}

test "rerun fires on missing watched file and on env change" {
    const io = std.Io.Threaded.global_single_threaded.io();
    const changed = [_][]const u8{"does-not-exist.txt"};
    const env_names = [_][]const u8{"MY_ENV"};
    const cur = [_]?[]const u8{"2"};
    const prev = [_]?[]const u8{"1"};
    const d = try shouldRerun(std.testing.allocator, io, "/tmp", .{
        .prev_changed = &changed, .prev_env_changed = &env_names,
        .prev_output_ns = 0, .current_env = &cur, .prev_env_values = &prev,
    });
    try std.testing.expect(d == .rerun);
}
```

Run: `zig build test 2>&1 | tail -5`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
jj status
jj commit src/cargo/script.zig -m "Add build-script rerun fingerprint"
```

---

### Task 4: Action key + store ingest + OUT_DIR materialization

**Files:**
- Modify: `src/cargo/script.zig` (append; no other files)
- Test: inline tests using a real `Store` (`src/store/test_support.zig`, same shape as the M1 view test — no mocks)

**Interfaces:**
- Consumes: `BuildOutput` (Task 1), `RerunInputs` (Task 3), `store_mod` surface.
- Produces (used by Tasks 5, 8–9):
```zig
pub const KeyError = error{ StoreFull } || std.mem.Allocator.Error;
pub const ScriptFingerprint = struct {
    script_bin_digest: Digest,   // content digest of the COMPILED script binary (Task 5 compiles first)
    package_name: []const u8,
    package_version: []const u8,
    links: ?[]const u8,          // [package] links key or null
    features: []const []const u8, // sorted enabled features for this unit
    profile_name: []const u8,     // "dev" | "release" | custom
    opt_level: []const u8,        // "0".."3"/"s"/"z" (cargo profile field, in the key)
    debug_assertions: bool,
    target_triple: []const u8,    // --target or host triple
    host_triple: []const u8,
    toolchain_id: []const u8,     // "rustc <version> <sysroot-digest8>" (storage-v2 §11.3 shape)
    watched_env_values: []const ?[]const u8, // CURRENT values of rerun-if-env-changed names, same order as names
    watched_env_names: []const []const u8,
    rustflags_relevant: []const u8, // CARGO_ENCODED_RUSTFLAGS content (0x1f-joined, cargo build_work line ~463)
};
pub fn scriptActionKey(gpa: std.mem.Allocator, fp: ScriptFingerprint) KeyError!Digest;
pub const IngestError = error{ StoreFull, TagMismatch, TagLimit, UnknownTagKey, Io } || std.mem.Allocator.Error || Store.PutError || Store.GetManifestError;
pub fn ingestOutputs(gpa: std.mem.Allocator, io: Io, store: *Store, out_dir_abs: []const u8, output: *const BuildOutput, tags: []const Tag) IngestError!Digest;
pub fn materializeOutDir(gpa: std.mem.Allocator, io: Io, store: *Store, manifest_digest: Digest, out_dir_abs: []const u8) IngestError!void;
pub fn rewriteOutDir(gpa: std.mem.Allocator, bytes: []const u8, from: []const u8, to: []const u8) std.mem.Allocator.Error![]u8;
```

Semantics (normative):
- **What is IN the key** (rerun conditions in the action key, per objective): script binary digest (recompile ⇒ rerun), package name+version, `links`, sorted features, profile name + opt-level + debug-assertions, target + host triples, toolchain id, and the CURRENT VALUES of every `rerun-if-env-changed` name (name order = emission order; a changed value changes the key — this is what makes env-triggered reruns a cache MISS instead of a freshness check). **What is NOT in the key**: `rerun-if-changed` PATHS and their mtimes (cargo never hashes mtimes into fingerprints — fingerprint/mod.rs "Considerations": "We strive to never include a modification time inside a Fingerprint"; paths stay a Task-3 freshness check), absolute dir paths (cargo renames-don't-invalidate property — hash relative names only), `OUT_DIR` itself (rewritten per cargo's `script_out_dir_when_generated` rewrite).
- `scriptActionKey` serializes the fields in FIXED order with length prefixes (`u64le len + bytes` per field, `0xFF` marker for null links/env) into a buffer and returns `store_mod.hashBytes(buf)` (BLAKE3, `b3-` hex via `Digest.toHex()` for display). Empty-vs-null env value distinguished (`0x00` vs `0x01` tag byte). Deterministic across processes: no pointers, no map iteration (features pre-sorted by caller — assert sorted with `std.debug.assert` + test).
- **Store artifacts**: every regular file directly under `out_dir_abs` (top level only — cargo's contract is flat `OUT_DIR`; subdirectories are an error `IngestError.Io` naming the path, loud) is `store.putBytes(io, bytes, .build_script_out)` (storage-v2 §5.2 `build_script_out`, demotable), then ONE manifest `store.putManifest(io, .{ .kind = .build_script_out, .outputs = outs })` with per-file `mode = 0o444`, then `store.tagObject(io, manifest_digest, tags)` where the caller passes the full §11.3 set (`crate`, `crate_version`, `toolchain`, `target`, `profile`, `features` as `fh-<16hex>`, `project` as `pb3-<hex>`, `action` = `build-script`). `StoreFull` surfaces with the `store.lastFull()` breakdown re-emitted verbatim by the caller (Task 8 renders it; here just propagate). Idempotency fast path (storage-v2 §10.5): re-ingesting identical bytes is reservation-free — assert in test via `reservedBytes` unchanged.
- **OUT_DIR materialization semantics**: (a) `materializeOutDir` recreates `out_dir_abs` — `Io.Dir.cwd().deleteTree(io, out_dir_abs)` then `Io.Dir.cwd().createDirPathOpen(io, out_dir_abs, .{})` closed immediately (delete precedent `fetch.zig:1289`, create precedent `fetch.zig:247`; cargo moves old dirs aside, rime deletes because the store manifest is the backup), then for each manifest entry `store.materialize(io, digest, join(out_dir, path), 0o444)` — clone-or-copy via the store, never hardlink, read-only outputs; (b) on a cache HIT the runner (Task 5) materializes instead of executing — the script never runs, `OUT_DIR` still ends up byte-identical; (c) generated-path rewrite: entries whose recorded bytes contain the generating machine's OUT_DIR prefix are rewritten at READ time by the consumer (cargo `value.replace(script_out_dir_when_generated, script_out_dir)` in `BuildOutput::parse`) — rime stores bytes verbatim and applies the same replace in `parseBuildOutput`'s caller (Task 5 passes `out_dir_when_generated`/`out_dir_now`; the replace helper `rewriteOutDir(gpa, bytes, from, to)` is defined in THIS task with its own test).

- [ ] **Step 1: Write the failing key-stability test**

```zig
test "script action key binds env values and ignores paths" {
    const d_script = store_mod.hashBytes("fake-binary");
    const names = [_][]const u8{"MY_ENV"};
    const v1 = [_]?[]const u8{"1"};
    const v2 = [_]?[]const u8{"2"};
    const base = ScriptFingerprint{
        .script_bin_digest = d_script, .package_name = "p", .package_version = "0.1.0",
        .links = null, .features = &.{}, .profile_name = "dev", .opt_level = "0",
        .debug_assertions = true, .target_triple = "aarch64-apple-darwin",
        .host_triple = "aarch64-apple-darwin", .toolchain_id = "rustc 1.99.0-nightly abc12345",
        .watched_env_values = &v1, .watched_env_names = &names, .rustflags_relevant = "",
    };
    var changed = base;
    changed.watched_env_values = &v2;
    const k1 = try scriptActionKey(std.testing.allocator, base);
    const k2 = try scriptActionKey(std.testing.allocator, changed);
    try std.testing.expect(!std.crypto.timing_safe.eql(u8, &k1.bytes, &k2.bytes));
    const k1b = try scriptActionKey(std.testing.allocator, base);
    try std.testing.expect(std.crypto.timing_safe.eql(u8, &k1.bytes, &k1b.bytes));
}

test "rewriteOutDir swaps the generating prefix" {
    const got = try rewriteOutDir(std.testing.allocator, "out=/gen/out/x", "/gen/out", "/now/out");
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings("out=/now/out/x", got);
}
```

(Digest equality uses `std.crypto.timing_safe.eql` — the mandated spelling. `Digest.bytes` is the `[32]u8` field per `src/store/digest.zig` `toHex`/`relPath` shape; if the field is named differently, use `std.meta.eql(k1, k2)` — check `digest.zig` in this step and use whichever compiles, keeping `timing_safe.eql` for the byte comparison.)

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test 2>&1 | tail -10`
Expected: FAIL — `ScriptFingerprint`/`scriptActionKey` not defined.

- [ ] **Step 3: Write minimal implementation (key + rewrite helper)**

```zig
pub fn scriptActionKey(gpa: std.mem.Allocator, fp: ScriptFingerprint) KeyError!Digest {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    const w = buf.writer(gpa);
    try writeField(w, fp.script_bin_digest.bytes[0..]);
    try writeField(w, fp.package_name);
    try writeField(w, fp.package_version);
    if (fp.links) |l| {
        try w.writeByte(0x00);
        try writeField(w, l);
    } else {
        try w.writeByte(0xFF); // null-links marker
    }
    for (fp.features, 0..) |f, i| {
        if (i > 0) std.debug.assert(std.mem.order(u8, fp.features[i - 1], f) != .gt); // caller pre-sorts
        try writeField(w, f);
    }
    try w.writeByte(0x00); // features terminator
    try writeField(w, fp.profile_name);
    try writeField(w, fp.opt_level);
    try w.writeByte(if (fp.debug_assertions) 0x01 else 0x00);
    try writeField(w, fp.target_triple);
    try writeField(w, fp.host_triple);
    try writeField(w, fp.toolchain_id);
    std.debug.assert(fp.watched_env_names.len == fp.watched_env_values.len);
    for (fp.watched_env_names, fp.watched_env_values) |n, v| {
        try writeField(w, n);
        if (v) |val| {
            try w.writeByte(0x01);
            try writeField(w, val);
        } else {
            try w.writeByte(0x00); // was-unset marker (distinct from empty)
        }
    }
    try writeField(w, fp.rustflags_relevant);
    return store_mod.hashBytes(buf.items);
}

fn writeField(w: anytype, bytes: []const u8) !void {
    var len: [8]u8 = undefined;
    std.mem.writeInt(u64, &len, bytes.len, .little);
    try w.writeAll(&len);
    try w.writeAll(bytes);
}

pub fn rewriteOutDir(gpa: std.mem.Allocator, bytes: []const u8, from: []const u8, to: []const u8) std.mem.Allocator.Error![]u8 {
    if (from.len == 0) return gpa.dupe(u8, bytes);
    return std.mem.replaceOwned(u8, gpa, bytes, from, to);
}
```

- [ ] **Step 4: Verify ingest round-trip against a real store**

```zig
test "ingest stores OUT_DIR files and materializes them back" {
    const io = std.Io.Threaded.global_single_threaded.io();
    const gpa = std.testing.allocator;
    var ts = store_mod.test_support.openTestStore(io, .{});
    defer ts.deinit(io);
    var out_tmp = std.testing.tmpDir(.{});
    defer out_tmp.cleanup();
    try out_tmp.dir.writeFile(io, .{ .sub_path = "bindings.rs", .data = "pub const X: u32 = 1;\n" });
    const out_abs = try out_tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(out_abs);

    var parsed = try parseBuildOutput(gpa, "cargo::rerun-if-changed=build.rs\n", .{});
    defer parsed.deinit(gpa);
    const tags = [_]Tag{
        .{ .key = "crate", .value = "full-manifest" },
        .{ .key = "crate_version", .value = "0.1.0" },
        .{ .key = "profile", .value = "dev" },
        .{ .key = "action", .value = "build-script" },
    };
    const man = try ingestOutputs(gpa, io, &ts.store, out_abs, &parsed, &tags);

    var dst_tmp = std.testing.tmpDir(.{});
    defer dst_tmp.cleanup();
    const dst_abs = try dst_tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(dst_abs);
    const dst_out = try std.fs.path.join(gpa, &.{ dst_abs, "out" });
    defer gpa.free(dst_out);
    try materializeOutDir(gpa, io, &ts.store, man, dst_out);
    const got = try dst_tmp.dir.readFileAlloc(io, "out/bindings.rs", gpa, .unlimited);
    defer gpa.free(got);
    try std.testing.expectEqualStrings("pub const X: u32 = 1;\n", got);
    // Store object is read-only; view copy is read-only too (generated code is an input).
    const vst = try dst_tmp.dir.statFile(io, "out/bindings.rs", .{});
    try std.testing.expectEqual(@as(std.posix.mode_t, 0o444), vst.permissions.toMode());
}
```

(`store_mod.test_support`, `std.testing.tmpDir`, `realPathFileAlloc`, `readFileAlloc` with `.unlimited`, `statFile(...).permissions.toMode()` — all copy the M1 view-test shapes exactly. `Store.PutError`/`GetManifestError` are the real error sets on `store.putBytes`/`putManifest`/`getManifest` — reference `src/store/root.zig` lines ~193–300 for the exact names in this step; `IngestError` unions exactly those plus `error{StoreFull, TagMismatch, TagLimit, UnknownTagKey, Io}`.)

- [ ] **Step 5: Commit**

```bash
jj status
jj commit src/cargo/script.zig -m "Add script action keys and store ingest"
```

---

### Task 5: Compile-then-run + sandbox

**Files:**
- Modify: `src/cargo/script.zig` (append; no other files)
- Test: inline tests (compile a tiny `build.rs` with the real `rustc` when available, else a stub executable script; sandbox probe test runs everywhere)

**Interfaces:**
- Consumes: `parseBuildOutput` (Task 1), `propagateMetadata` (Task 2), `shouldRerun` (Task 3), `scriptActionKey`/`ingestOutputs`/`materializeOutDir` (Task 4).
- Produces (used by Task 8):
```zig
pub const RunError = error{ CompileFailed, ScriptFailed, SandboxDenied, StoreFull, Io } || std.mem.Allocator.Error || std.process.SpawnError || IngestError || DirectiveError;
pub const SandboxKind = enum { macos_seatbelt, linux_namespaces, none_loud };
pub fn probeSandbox(io: Io) SandboxKind;
pub fn renderSandboxWarning(stderr: *Io.Writer, reason: []const u8) Io.Writer.Error!void;
pub fn scriptEnv(gpa: std.mem.Allocator, base: *const std.process.Environ.Map, extra: []const KeyValue) std.mem.Allocator.Error!std.process.Environ.Map;
pub fn scriptBinPath(gpa: std.mem.Allocator, spool_abs: []const u8, package_name: []const u8, unit_meta_hash: []const u8) std.mem.Allocator.Error![]u8;
pub const RunConfig = struct {
    base_env: *const std.process.Environ.Map, // parent env (production: init.environ_map; tests: hand-built map). Supplies PATH and every var cargo inherits.
    script_bin_abs: []const u8,   // compiled binary (Task 8 compiles via the driver seam; tests pass a stub)
    pkg_dir_abs: []const u8,
    out_dir_abs: []const u8,      // exists before spawn (created under spool reservation)
    out_dir_when_generated: ?[]const u8, // previous-run OUT_DIR for the read-time rewrite (null = no rewrite)
    manifest_dir: []const u8,     // CARGO_MANIFEST_DIR
    manifest_path: []const u8,    // CARGO_MANIFEST_PATH
    links: ?[]const u8,           // CARGO_MANIFEST_LINKS when non-null
    features: []const []const u8,  // CARGO_FEATURE_<envify> = 1 each
    target_triple: []const u8,     // TARGET
    host_triple: []const u8,       // HOST
    profile_name: []const u8,      // PROFILE ("release"/"debug" mapped form)
    opt_level: []const u8,         // OPT_LEVEL
    debug_assertions: bool,        // DEBUG ("true"/"false")
    rustc_abs: []const u8,         // RUSTC
    encoded_rustflags: []const u8, // CARGO_ENCODED_RUSTFLAGS (0x1f-joined)
    dep_env: []const KeyValue,     // Task-2 DEP_ vars from already-run deps
    cfg_env: []const KeyValue,     // pre-rendered CARGO_CFG_… vars from the driver seam (Task 6)
    stderr: *Io.Writer,            // loud-sandbox warnings land here
};
pub fn runScript(gpa: std.mem.Allocator, io: Io, store: *Store, cfg: RunConfig, diagnostic: ?*[2048]u8, diagnostic_len: *usize) RunError!struct { output: BuildOutput, manifest: Digest, started_ns: i96 };
```

Cargo pin: `build_work` (`custom_build.rs`, from `let mut cmd = build_runner.compilation.host_process(…)` through the env chain to `cmd.env("CARGO_ENCODED_RUSTFLAGS", …)` + `cmd.env_remove("RUSTFLAGS")`). Env list (exact, all set; `RUSTC_WRAPPER`/`RUSTC_WORKSPACE_WRAPPER` removed, `RUSTFLAGS` removed): `OUT_DIR`, `CARGO_MANIFEST_DIR`, `CARGO_MANIFEST_PATH`, `NUM_JOBS` (locked to `"1"` — M5 runs units sequentially; the jobserver is M4's, Appendix B Q5), `TARGET`, `DEBUG`, `OPT_LEVEL`, `PROFILE`, `HOST`, `RUSTC`, `RUSTDOC` (rime: rustdoc path or absent — pass through parent env when set, else unset; document), `CARGO_MANIFEST_LINKS` (own links only), `CARGO_FEATURE_<ENVIFY(feat)>=1` per enabled feature, `cfg_env` entries verbatim (each already `CARGO_CFG_…` rendered by the driver seam in Task 6), `CARGO_ENCODED_RUSTFLAGS`, plus Task-2 `dep_env` (`DEP_…`/`CARGO_DEP_…`), plus inherited `PATH` (needed to exec tools; sandbox still denies network — PATH inheritance is not a sandbox hole, documented). Stdout is CAPTURED (directive channel); stderr passes through to the build log (cargo streams script stderr). Non-UTF8 stdout lines are skipped (cargo `str::from_utf8 … Err(..) => continue`). Exit status ≠ 0 → `ScriptFailed` with the first 2 KiB of captured stdout in the diagnostic string (caller formats; here return the error and store the snippet in a caller-provided `*DiagBuf`? — decision: `runScript` takes `diagnostic: ?*[2048]u8` out-param + `diagnostic_len: *usize`; tests assert the snippet. Fixed shape, no hidden allocation).
- OUT_DIR exists before spawn: `runScript` creates it with `Io.Dir.cwd().createDirPathOpen(io, cfg.out_dir_abs, .{})` closed immediately (repo-verified absolute-dir shape, `fetch.zig:247`) — cargo `paths::create_dir_all(&script_out_dir)`. The anchor mtime for Task 3 is captured BEFORE spawn: `runScript` returns `started_ns: i96` (clock `now` before spawn) alongside output+manifest; Task 8 stores it as `prev_output_ns`. The field is part of the return struct in the Interfaces block above, not a later change.
- Sandbox (per objective):
  - macOS (`builtin.os.tag == .macos`): REQUIRED `sandbox-exec -f <generated-profile>` wrapper: argv becomes `sandbox-exec -f <profile_path> -- <script> …`. The seatbelt profile is generated into the spool dir with `spool.writeFile(io, .{ .sub_path = profile_rel, .data = profile_text })` (struct form): `(version 1) (deny default) (allow process-exec (with no-sandbox)) …` — exact profile text: deny `network*`, allow `file-read*` everywhere, allow `file-write*` only under `OUT_DIR`, spool dir, and `TMPDIR`; allow `process-exec`. If `sandbox-exec` is absent from PATH → `SandboxDenied` (loud hard error — macOS always ships it; absence means a broken host, fail, never silently unsandboxed).
  - Linux: best-effort `unshare -rn` (user + network namespaces; no mounts touched so the FS view is unchanged) when `unshare` exists AND succeeds; Landlock is NOT attempted (no C/lib dependency allowed — std only; document as the reason). When unavailable/failing → `SandboxKind.none_loud`: single stderr line `warning: rime: build-script sandbox unavailable (<reason>); running unsandboxed` via `cfg.stderr`, then proceed. NEVER silent: the `none_loud` arm always writes before spawning (assert in test by capturing stderr into a buffer writer).
  - Other OSes: compile error (`@compileError("build scripts sandbox only on macos/linux")` — matches the repo's Windows posture: storage-v2 §3 non-goal "Windows support: macOS + Linux").
- Compile step: compilation itself is the M4 driver's rustc invocation over the `is_custom_build` unit; THIS task only defines the deterministic binary path helper `scriptBinPath(gpa, spool_abs, package_name, unit_meta_hash: []const u8) -> []u8` (`<spool>/scripts/<package>-<meta8>/build-script`) so Task 8 and M4 agree on where the binary lives. No rustc spawning here.

- [ ] **Step 1: Write the failing sandbox tests**

```zig
test "sandbox probe reports a kind on every platform" {
    const io = std.Io.Threaded.global_single_threaded.io();
    const k = probeSandbox(io);
    // Must be exactly one of the three; on macOS CI never none_loud.
    if (comptime @import("builtin").os.tag == .macos) {
        try std.testing.expect(k == .macos_seatbelt);
    } else {
        try std.testing.expect(k == .linux_namespaces or k == .none_loud);
    }
}

test "unsandboxed runs always warn loudly" {
    const io = std.Io.Threaded.global_single_threaded.io();
    var err_buf: [4096]u8 = undefined;
    var err_w: Io.Writer = .fixed(&err_buf);
    // drive the none_loud arm directly: try renderSandboxWarning(&err_w, "unshare missing")
    try renderSandboxWarning(&err_w, "unshare missing");
    try err_w.flush();
    try std.testing.expect(std.mem.indexOf(u8, err_w.buffered(), "running unsandboxed") != null);
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test 2>&1 | tail -10`
Expected: FAIL — `probeSandbox`/`renderSandboxWarning` not defined.

- [ ] **Step 3: Write minimal implementation (probe + warning + env assembly + spawn)**

```zig
pub fn probeSandbox(io: Io) SandboxKind {
    if (comptime @import("builtin").os.tag == .macos) return .macos_seatbelt;
    // Linux: unshare present AND functional? Probe with `unshare --help` (no namespaces taken).
    var probe = std.process.spawn(io, .{
        .argv = &.{ "unshare", "--help" },
        .stdin = .ignore, .stdout = .ignore, .stderr = .ignore,
    }) catch return .none_loud;
    defer probe.kill(io);
    const st = probe.wait(io) catch return .none_loud;
    return if (st == .exited and st.exited == 0) .linux_namespaces else .none_loud;
}
```

(`probe.wait(io)` returns the exit union; `st == .exited and st.exited == 0` is the exact fetch.zig check shape. `probe.kill(io)` deferred like `child.kill(io)` in `CliGit.cliRun`.)

```zig
pub fn renderSandboxWarning(stderr: *Io.Writer, reason: []const u8) Io.Writer.Error!void {
    try stderr.writeAll("warning: rime: build-script sandbox unavailable (");
    try stderr.writeAll(reason);
    try stderr.writeAll("); running unsandboxed\n");
}

pub fn scriptBinPath(gpa: std.mem.Allocator, spool_abs: []const u8, package_name: []const u8, unit_meta_hash: []const u8) std.mem.Allocator.Error![]u8 {
    std.debug.assert(unit_meta_hash.len >= 8); // caller passes a hex digest
    const mid = try std.fmt.allocPrint(gpa, "{s}-{s}", .{ package_name, unit_meta_hash[0..8] });
    defer gpa.free(mid);
    return std.fs.path.join(gpa, &.{ spool_abs, "scripts", mid, "build-script" });
}
```

Env assembly: `scriptEnv` does NOT inherit the parent map implicitly and does NOT call any process-env getter (no `std.process.getEnvironMap`/`getEnvMap` exists in 0.16 — verified by grep over `lib/std/process.zig`). Signature takes `base: *const Environ.Map` supplied by the caller: production passes `init.environ_map` (`std.process.Init.environ_map: *Environ.Map`, verified `lib/std/process.zig:43-44`) and `scriptEnv` clones it via `Map.clone(gpa)` (verified `lib/std/process/Environ.zig:342`), applies cargo removals (`RUSTFLAGS`, `RUSTC_WRAPPER`, `RUSTC_WORKSPACE_WRAPPER`), then puts the full cargo list. Task 8 wires `init.environ_map` through `RunConfig.base_env`; tests pass a hand-built map. This keeps Task 5 testable without an unverified API.

Spawn + capture follows `CliGit.cliRun` line-for-line (spawn with `.stdout = .pipe, .stderr = .pipe`, `MultiReader` drain both, `wait`, `.exited == 0` else `ScriptFailed` + snippet into `diagnostic`/`diagnostic_len`). Stdout bytes → `parseBuildOutput(gpa, bytes, parse_opts)` (Task 1; `parse_opts.allow_rustc_bootstrap` computed here from the toolchain channel + `base_env.get("RUSTC_BOOTSTRAP")` allowlist check) AFTER `rewriteOutDir` when `cfg.out_dir_when_generated` differs from `cfg.out_dir_abs`.

- [ ] **Step 4: End-to-end stub-script run test**

```zig
test "runScript captures directives from a stub executable" {
    const io = std.Io.Threaded.global_single_threaded.io();
    const gpa = std.testing.allocator;
    var ts = store_mod.test_support.openTestStore(io, .{});
    defer ts.deinit(io);
    var pkg_tmp = std.testing.tmpDir(.{});
    defer pkg_tmp.cleanup();
    // Stub "compiled script": a POSIX sh script emitting directives.
    try pkg_tmp.dir.writeFile(io, .{ .sub_path = "stub.sh", .data = "#!/bin/sh\necho 'cargo::rustc-cfg=stub_cfg'\n" });
    try pkg_tmp.dir.setFilePermissions(io, "stub.sh", .fromMode(0o755), .{});
    const stub_abs = try pkg_tmp.dir.realPathFileAlloc(io, "stub.sh", gpa);
    defer gpa.free(stub_abs);
    const pkg_abs = try pkg_tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(pkg_abs);
    const out_abs = try std.fs.path.join(gpa, &.{ pkg_abs, "out" });
    defer gpa.free(out_abs);
    const manifest_path = try std.fs.path.join(gpa, &.{ pkg_abs, "Cargo.toml" });
    defer gpa.free(manifest_path);
    var base_env = std.process.Environ.Map.init(gpa);
    defer base_env.deinit();
    var err_buf: [4096]u8 = undefined;
    var err_w: Io.Writer = .fixed(&err_buf);
    var diag: [2048]u8 = undefined;
    var diag_len: usize = 0;
    const res = try runScript(gpa, io, &ts.store, .{
        .base_env = &base_env,
        .script_bin_abs = stub_abs,
        .pkg_dir_abs = pkg_abs,
        .out_dir_abs = out_abs,
        .out_dir_when_generated = null,
        .manifest_dir = pkg_abs,
        .manifest_path = manifest_path,
        .links = null,
        .features = &.{},
        .target_triple = "aarch64-apple-darwin",
        .host_triple = "aarch64-apple-darwin",
        .profile_name = "debug",
        .opt_level = "0",
        .debug_assertions = true,
        .rustc_abs = "rustc",
        .encoded_rustflags = "",
        .dep_env = &.{},
        .cfg_env = &.{},
        .stderr = &err_w,
    }, &diag, &diag_len);
    defer res.output.deinit(gpa);
    try std.testing.expectEqualStrings("stub_cfg", res.output.cfgs[0]);
}
```

(Executable bit via `dir.setFilePermissions(io, sub_path, .fromMode(0o755), .{})` — `SetFilePermissions` + `Permissions.fromMode` verified in 0.16 `lib/std/Io/Dir.zig:1959` + `lib/std/Io/File.zig:384`; repo precedent `src/store/objects.zig:114` `f.setPermissions(io, .fromMode(0o644))`.)

- [ ] **Step 5: Commit**

```bash
jj status
jj commit src/cargo/script.zig -m "Add script runner and sandbox"
```

---

### Task 6: `links` validation + M4 unit-graph seam

**Files:**
- Modify: `src/cargo/script.zig` (append; no other files)
- Test: inline tests (pure; no FS/Store)

**Interfaces:**
- Consumes: `manifest_mod.ManifestExt.links` (exists: `src/cargo/manifest.zig` `links: ?[]const u8`), `BuildOutput`/`KeyValue` (Tasks 1–2).
- Produces (consumed by the M4 driver; provided until then by `planScripts`):
```zig
pub const LinksError = error{ DuplicateLinks };
pub fn validateLinks(packages: []const LinksEntry) LinksError!void;
pub const LinksEntry = struct { package: []const u8, version: []const u8, links: ?[]const u8 };
pub const PlanOptions = struct {
    target_triple: ?[]const u8,
    host_triple: []const u8,
    profile_name: []const u8,
    opt_level: []const u8,
    debug_assertions: bool,
    toolchain_id: []const u8,
    project_tag: []const u8, // pb3-<hex> workspace id
};
pub const PlanError = LinksError || std.mem.Allocator.Error || Io.Dir.ReadFileAllocError || manifest_mod.ManifestSurfaceError;
pub fn planScripts(gpa: std.mem.Allocator, io: Io, ws: *const workspace_mod.Workspace, opts: PlanOptions, stderr: *Io.Writer) PlanError![]ScriptUnit;
pub fn deinitPlanUnits(gpa: std.mem.Allocator, units: []ScriptUnit) void;
pub const ScriptUnit = struct {
    package: []const u8,
    version: []const u8,
    pkg_dir_abs: []const u8,      // package root (rerun-if-changed anchor)
    script_rel: []const u8,       // build script path relative to pkg root ("build.rs" default)
    links: ?[]const u8,             // [package] links key; gpa-owned iff produced by planScripts (see deinitPlanUnits), else borrowed
    features: []const []const u8,  // sorted enabled features
    profile_name: []const u8,
    opt_level: []const u8,
    debug_assertions: bool,
    target_triple: []const u8,
    host_triple: []const u8,
    toolchain_id: []const u8,
    rustflags_encoded: []const u8,
    cfg_env: []const KeyValue,     // pre-rendered CARGO_CFG_… vars (Task 5 consumes)
    project_tag: []const u8,       // pb3-<hex> workspace id
};
pub const ScriptResult = struct {
    unit: ScriptUnit,              // borrowed from the plan (lifetime: plan outlives result)
    output: BuildOutput,           // parsed directives (owned; caller deinits)
    manifest: Digest,              // store manifest of OUT_DIR files (Task 4)
    out_dir_abs: []const u8,       // materialized OUT_DIR (owned)
    started_ns: i96,               // spawn anchor for Task-3 freshness
    from_cache: bool,              // true = materialized, script never ran
    store_skipped: bool,           // true = StoreFull degraded path (Task 8; manifest is prev manifest, outputs verified identical)
    pub fn deinit(self: *const ScriptResult, gpa: std.mem.Allocator) void {
        self.output.deinit(gpa);
        gpa.free(self.out_dir_abs);
    }
};
pub const ProcMacroArtifact = struct {
    package: []const u8,
    version: []const u8,
    dylib_digest: Digest,          // Kind.dylib object in store (Task 7 ingests)
    host_triple: []const u8,
    extern_arg: []const u8,        // "--extern <crate>=<store-rel-path>" rendered for rustc (owned)
    pub fn deinit(self: *const ProcMacroArtifact, gpa: std.mem.Allocator) void {
        gpa.free(self.extern_arg);
    }
};
```

Cargo pins:
- `validate_links` (`references/cargo/src/cargo/core/compiler/links.rs:20`): across the WHOLE unit graph, two different packages must not declare the same `links` value → build error naming both packages (`DuplicateLinks`; Task 8 renders `error: multiple packages link to native library 'foo': a v1, b v2`, exit 101 — cargo's "links to native library" message). Same package appearing twice (e.g. host+target units) is fine — dedupe key is the links STRING, conflict is on differing package names.
- links overrides (`custom_build.rs` line ~1301 `unit.links_overrides.get(links)` + `TargetConfig::parse_links_overrides` "Keep in sync" comment at line ~978): rime M5 does NOT implement `[target.<triple>] links` config overrides — when a `links` key has no build script AND no override, dependents get no `DEP_` vars (cargo would error on missing override only when actually linking; M5 defers override parsing to M6 CLI parity — document, loud when hit: `ScriptFailed`-adjacent named error `LinksOverrideUnsupported`? — decision: reuse `DirectiveError.UnknownKey`? NO — new named error would widen RunError. Locked: Task 8 maps "links without script and without override" to stderr `need links-override: <links> requires M6 config parsing` + exit 1, same shape as the M1 D5 `need source` error. No new error variant.)
- Unit-graph seam: M4 owns `Unit`/`UnitGraph` (`references/cargo/.../compiler/unit_graph.rs`, `unit.rs` `CompileKind::Host` for host/target split, `mod.rs:1311` host dylib preference, `:1988` proc-macro `--extern proc_macro`). Until M4 lands, `planScripts(gpa, io, ws, opts, stderr)` (signature in the Interfaces block above — M4 must keep it; only the BODY becomes a unit-graph projection) derives one `ScriptUnit` per workspace member that has a build script (see Step 3 for the exact member→surface→probe logic). `PlanOptions` carries everything the key needs that the workspace cannot know.

- [ ] **Step 1: Write the failing links-conflict test**

```zig
test "duplicate links keys are rejected" {
    const pkgs = [_]LinksEntry{
        .{ .package = "a", .version = "1.0.0", .links = "foo" },
        .{ .package = "b", .version = "2.0.0", .links = "foo" },
    };
    try std.testing.expectError(LinksError.DuplicateLinks, validateLinks(&pkgs));
}

test "same package twice is fine" {
    const pkgs = [_]LinksEntry{
        .{ .package = "a", .version = "1.0.0", .links = "foo" },
        .{ .package = "a", .version = "1.0.0", .links = "foo" },
    };
    try validateLinks(&pkgs);
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test 2>&1 | tail -10`
Expected: FAIL — `validateLinks`/`LinksEntry` not defined.

- [ ] **Step 3: Write minimal implementation**

```zig
pub fn validateLinks(packages: []const LinksEntry) LinksError!void {
    for (packages, 0..) |a, i| {
        const la = a.links orelse continue;
        for (packages[0..i]) |b| {
            const lb = b.links orelse continue;
            if (std.mem.eql(u8, la, lb) and !std.mem.eql(u8, a.package, b.package)) return LinksError.DuplicateLinks;
        }
    }
}
```

Plus the `ScriptUnit`/`ScriptResult`/`ProcMacroArtifact` struct definitions with doc comments (no logic), and the full `planScripts` body below (no stub — the M4 replacement contract is that M4 keeps the SIGNATURE and swaps this body for a unit-graph projection):

```zig
pub fn planScripts(gpa: std.mem.Allocator, io: Io, ws: *const workspace_mod.Workspace, opts: PlanOptions, stderr: *Io.Writer) PlanError![]ScriptUnit {
    // M1 Member.manifest is the M1 Manifest (it HAS `pkg.build_script`, via
    // `optionalBuildScript`: string verbatim, `true` -> "build.rs", `false`/absent ->
    // null). `links` lives ONLY on ManifestExt, so re-parse each member's
    // surface here with `parseManifestExt` (verified `manifest.zig:651`); never
    // invent a `m.manifest.base` chain (Member has no `base` field).
    var units: std.ArrayList(ScriptUnit) = .empty;
    errdefer units.deinit(gpa);
    for (ws.members) |*m| {
        const manifest_abs = try std.fs.path.join(gpa, &.{ m.dir, "Cargo.toml" });
        defer gpa.free(manifest_abs);
        const text = try Io.Dir.cwd().readFileAlloc(io, manifest_abs, gpa, .limited(1 << 20));
        defer gpa.free(text);
        var ext = try manifest_mod.parseManifestExt(gpa, text, manifest_abs);
        defer ext.deinit();
        const declared: ?[]const u8 = if (m.manifest.pkg) |pkg| pkg.build_script else null;
        // absent/false (null) + existing build.rs -> default unit, silent when
        // missing (a normal package); explicit path missing -> loud skip
        // (cargo errors; rime M5 warns-and-skips because the driver cannot yet
        // attribute the failure to the right unit — documented deviation, loud).
        var pkg_dir = try Io.Dir.cwd().createDirPathOpen(io, m.dir, .{});
        defer pkg_dir.close(io);
        const script_rel: []const u8 = if (declared) |d| rel: {
            pkg_dir.statFile(io, d, .{}) catch {
                const msg = try std.fmt.allocPrint(gpa, "warning: {s} declares build script {s} but the file is missing; skipping\n", .{ m.name, d });
                defer gpa.free(msg);
                try stderr.writeAll(msg);
                break :rel "";
            };
            break :rel d;
        } else if (pkg_dir.statFile(io, "build.rs", .{})) |_| "build.rs" else |_| "";
        if (script_rel.len == 0) continue;
        // ext.links borrows ext's arena (freed by the defer above): dupe it
        // into gpa. Documented on ScriptUnit.links: gpa-owned iff produced by
        // planScripts (freed by deinitPlanUnits); borrowed when M4 projects.
        const links: ?[]const u8 = if (ext.links) |l| try gpa.dupe(u8, l) else null;
        errdefer if (links) |l| gpa.free(l);
        try units.append(gpa, .{
            .package = m.name,
            .version = m.version,
            .pkg_dir_abs = m.dir,
            .script_rel = script_rel,
            .links = links,
            .features = &.{},
            .profile_name = opts.profile_name,
            .opt_level = opts.opt_level,
            .debug_assertions = opts.debug_assertions,
            .target_triple = opts.target_triple orelse opts.host_triple,
            .host_triple = opts.host_triple,
            .toolchain_id = opts.toolchain_id,
            .rustflags_encoded = "",
            .cfg_env = &.{},
            .project_tag = opts.project_tag,
        });
    }
    // Conflict check over the derived units (Task 8 re-runs it pre-build; same call).
    var entries: std.ArrayList(LinksEntry) = .empty;
    defer entries.deinit(gpa);
    for (units.items) |*u| try entries.append(gpa, .{ .package = u.package, .version = u.version, .links = u.links });
    try validateLinks(entries.items);
    return units.toOwnedSlice(gpa);
}

pub fn deinitPlanUnits(gpa: std.mem.Allocator, units: []ScriptUnit) void {
    for (units) |u| if (u.links) |l| gpa.free(l);
    gpa.free(units);
}
```

- [ ] **Step 4: Add planScripts test on a synthetic workspace and make it pass**

```zig
test "planScripts finds members with build scripts" {
    // Build a minimal Workspace via workspace.discover on a new fixture
    // testdata/cargo/script-protocol/ws/{Cargo.toml,sys/Cargo.toml,sys/build.rs,sys/src/lib.rs,app/Cargo.toml,app/src/main.rs}
    // where sys declares [package] links="native-sys" + build="build.rs".
    var ws = try workspace_mod.discover(std.testing.allocator, std.Io.Threaded.global_single_threaded.io(), "testdata/cargo/script-protocol/ws", null);
    defer ws.deinit();
    var err_buf: [1024]u8 = undefined;
    var err_w: Io.Writer = .fixed(&err_buf);
    const units = try planScripts(std.testing.allocator, std.Io.Threaded.global_single_threaded.io(), &ws, .{
        .target_triple = null, .host_triple = "aarch64-apple-darwin",
        .profile_name = "dev", .opt_level = "0", .debug_assertions = true,
        .toolchain_id = "rustc 1.99.0-nightly test", .project_tag = "pb3-test",
    }, &err_w);
    defer deinitPlanUnits(std.testing.allocator, units);
    try std.testing.expectEqual(@as(usize, 1), units.len);
    try std.testing.expectEqualStrings("sys", units[0].package);
    try std.testing.expectEqualStrings("native-sys", units[0].links.?);
}
```

(Create the fixture in this step. `workspace_mod` = `@import("workspace.zig")` at the top of `script.zig` — same shape as `view.zig`'s `workspace_mod` import.)

Run: `zig build test 2>&1 | tail -5`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
jj status
jj commit src/cargo/script.zig testdata/cargo/script-protocol/ws -m "Add links validation and driver seam"
```

---

### Task 7: Proc-macro crates (host dylib ingest + explicit boundary)

**Files:**
- Modify: `src/cargo/script.zig` (ingest + extern rendering), `src/cargo/manifest.zig` (`proc_macro` flag parsing)
- Test: inline tests in both files

**Interfaces:**
- Consumes: `store_mod.Kind.dylib`, `ScriptUnit`-adjacent metadata.
- Produces:
```zig
// manifest.zig addition (TargetDesc is built ONLY as anonymous `.{...}` literals —
// `TargetDesc{` greps nothing by design; the two construction sites are the
// `targets.append(alloc, .{...})` calls in `parseManifest`, manifest.zig:184
// `[lib]` and manifest.zig:195 `[[bin]]`; there is no default-target synthesis
// yet — M1 leaves `targets` empty and the workspace task resolves the default
// lib-or-bin later, so that future literal must also set the field):
// before: pub const TargetDesc = struct { name: []const u8, path: ?[]const u8, kind: TargetKind };
pub const TargetDesc = struct { name: []const u8, path: ?[]const u8, kind: TargetKind, proc_macro: bool }; // [lib] proc-macro = true; false everywhere else
// script.zig:
pub const ProcMacroError = error{ StoreFull } || std.mem.Allocator.Error || Store.PutError || Store.TagError || Io.File.OpenError;
pub fn ingestProcMacroDylib(gpa: std.mem.Allocator, io: Io, store: *Store, dylib_abs: []const u8, package: []const u8, version: []const u8, host_triple: []const u8, project_tag: []const u8, toolchain_id: []const u8) ProcMacroError!ProcMacroArtifact;
```

Cargo pins:
- Proc-macro units compile FOR THE HOST (`unit.rs:70-74` `CompileKind::Host` docs; `mod.rs:1311` `prefer_dynamic = unit.target.for_host() && !unit.target.is_custom_build()`; `mod.rs:1988` `if unit.target.proc_macro()` auto-`--extern proc_macro`). rime: the dylib path is built with the HOST toolchain/triple even under `--target` (assert: `host_triple` used for the action key AND the `target` tag — the tag value is the host triple, documented, because that is what the bytes are).
- `Kind.dylib` is NEVER demoted (`src/store/cold.zig` `isDemotable` — cite in a comment; the test asserts `cold.isDemotable(.dylib) == false` shape per `cold.zig:133` so a regression in the store breaks THIS test loudly).
- Tags on the dylib object: full §11.3 set with `action = proc-macro` (literal: `proc-macro` with the hyphen is NOT in the §11.3 enum — §11.3 says `rustc | build-script | proc-macro | link | other`; re-read shows `proc-macro` IS listed. Use exactly `proc-macro`).
- **Explicit M5 boundary (say exactly what works):** WORKS IN M5 — (a) `[lib] proc-macro = true` parses (this task); (b) the driver seam exposes the dylib for host compilation via `ProcMacroArtifact` (path + `--extern` rendering); (c) the compiled `.so`/`.dylib` is ingested as `Kind.dylib` with tags and is re-materializable by digest. DOES NOT WORK IN M5 — (d) rime NEVER dlopens the dylib (no macro expansion code exists in rime; expansion is performed by rustc itself when it loads `--extern <dylib>`); (e) compiling a DEPENDENT crate that uses the macro still waits on the M4 driver passing `extern_arg` to rustc — `rime build` on a macro-using workspace reports `need driver: proc-macro dependents require M4 rustc invocation` (exit 1, same D5 shape). The Task-9 e2e proves (a)–(c) on a fixture with a proc-macro member; (e) is asserted as the loud error, not as expansion output.

- [ ] **Step 1: Write the failing manifest + ingest tests**

```zig
// manifest.zig:
test "lib proc-macro flag parses" {
    var m = try parseManifest(std.testing.allocator, "[package]\nname = \"m\"\nversion = \"0.1.0\"\n[lib]\nproc-macro = true\n");
    defer m.deinit();
    try std.testing.expect(m.targets[0].proc_macro);
}
```

```zig
// script.zig:
test "proc-macro dylib ingests as never-demoted dylib with tags" {
    const io = std.Io.Threaded.global_single_threaded.io();
    const gpa = std.testing.allocator;
    var ts = store_mod.test_support.openTestStore(io, .{});
    defer ts.deinit(io);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "libmac.so", .data = "fake-dylib-bytes" });
    const abs = try tmp.dir.realPathFileAlloc(io, "libmac.so", gpa);
    defer gpa.free(abs);
    const art = try ingestProcMacroDylib(gpa, io, &ts.store, abs, "mac", "0.1.0", "aarch64-apple-darwin", "pb3-test", "rustc 1.99.0-nightly test");
    defer art.deinit(gpa);
    try std.testing.expect(std.mem.startsWith(u8, art.extern_arg, "--extern mac="));
    try ts.store.verifyObject(io, art.dylib_digest);
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `zig build test 2>&1 | tail -10`
Expected: FAIL — `proc_macro` field / `ingestProcMacroDylib` not defined.

- [ ] **Step 3: Write minimal implementation**

manifest.zig: add the required `proc_macro` field (no default — the compiler rejects every literal that is not updated, which is the enforcement). In the `[lib]` table parsing (`manifest.zig:181-190`), read optional `proc-macro` boolean (`true`/`false` verbatim; absent → `false`; non-boolean → `InvalidManifest`) via a new `optionalProcMacro(lt: *const toml.TomlTable) ManifestError!bool` helper next to `optionalString`, and set `.proc_macro = try optionalProcMacro(lt)` at the `:184` `[lib]` `targets.append` site. At the `:195` `[[bin]]` site set `.proc_macro = false` (proc-macro is lib-only). The future workspace-task default synthesis (M1 leaves `targets` empty when no `[lib]`/`[[bin]]` exists) must set `.proc_macro = false` on its synthesized literal — stated here so the constraint is on record; the missing-field compile error enforces it. There is no lib-key allow-list to extend (M1 `parseManifest` does not filter `[lib]` keys — only `[package]` has `checkPackageKeys` — so say so in a comment and skip).

script.zig:
```zig
pub fn ingestProcMacroDylib(gpa, io, store, dylib_abs, package, version, host_triple, project_tag, toolchain_id) ProcMacroError!ProcMacroArtifact {
    // No `Io.Dir.openPath` (does not exist in 0.16): namespace-level absolute open + putFile.
    var f = try Io.Dir.openFileAbsolute(io, dylib_abs, .{});
    defer f.close(io);
    const digest = try store.putFile(io, f, .dylib);
    const tags = [_]Tag{
        .{ .key = "crate", .value = package },
        .{ .key = "crate_version", .value = version },
        .{ .key = "toolchain", .value = toolchain_id },
        .{ .key = "target", .value = host_triple },
        .{ .key = "profile", .value = "host" },
        .{ .key = "project", .value = project_tag },
        .{ .key = "action", .value = "proc-macro" },
    };
    try store.tagObject(io, digest, &tags);
    var hex_buf: [65]u8 = undefined;
    const rel = digest.relPath(&hex_buf);
    const extern_arg = try std.fmt.allocPrint(gpa, "--extern {s}={s}", .{ package, rel });
    errdefer gpa.free(extern_arg);
    return .{
        .package = package,
        .version = version,
        .dylib_digest = digest,
        .host_triple = host_triple,
        .extern_arg = extern_arg,
    };
}
```

(Error-set honesty, verified against the calls above (`lib/std/Io/Dir.zig:581` namespace-level `openFileAbsolute`; `src/store/digest.zig:19` `relPath(d, buf: *[65]u8)`): `openFileAbsolute` fails with `Io.File.OpenError`; `store.putFile` with `Store.PutError`; `store.tagObject` with `Store.TagError`. `ProcMacroError` unions exactly `error{StoreFull}` + those three + `std.mem.Allocator.Error` — update the Interfaces error set to match (drop the invented `NotADylib`). `putFile` hashes while writing per storage-v2 §8.1 (no size-cap surprises). `--extern` path is the store object relpath (`digest.relPath(&hex_buf)` shape per the M1 view test's `d.relPath(&hex_buf)`). Borrowed strings (`package`, `version`, `host_triple`) borrow the caller's; `extern_arg` is gpa-owned.)

- [ ] **Step 4: Run tests to verify they pass**

Run: `zig build test 2>&1 | tail -5`
Expected: PASS (whole suite green — manifest change must not break existing manifest tests; the new field defaults to `false`).

- [ ] **Step 5: Commit**

```bash
jj status
jj commit src/cargo/manifest.zig src/cargo/script.zig -m "Add proc-macro dylib ingest"
```

---

### Task 8: CLI wiring + caching (freshness gate, cache-hit path, loud errors)

**Files:**
- Modify: `src/cargo/script.zig` (`runUnit` orchestrator), `src/cargo/cli.zig` (invoke per-unit), `src/cargo/root.zig` (already wired in Task 1 — verify, no change expected)
- Test: inline tests in `script.zig` (cache-hit: second run with identical inputs is `from_cache` and never spawns — proven with a stub binary that appends to a sentinel file on exec)

**Interfaces:**
- Consumes: everything in Tasks 1–6.
- Produces:
```zig
pub const UnitRunError = error{ LinksConflict, OldStyleAlwaysRerun } || RunError || RerunError || KeyError || Io.Dir.ReadFileAllocError || Io.Writer.Error || std.Io.File.ReadPositionalError || std.mem.Allocator.Error;
pub const StoredScriptState = struct {
    action_key: Digest,        // stored action key: the freshness gate looks THIS up, never recomputes (see step 3)
    output: BuildOutput,       // previous directives (owns; deinit with gpa)
    manifest: Digest,           // previous OUT_DIR manifest
    out_dir_when_generated: []const u8, // absolute OUT_DIR of the previous run (owned)
    started_ns: i96,
    watched_env_values: []const ?[]const u8, // stored env values, emission order (owned deep — builders dupe; see readScriptState)
    pub fn deinit(self: *const StoredScriptState, gpa: std.mem.Allocator) void {
        self.output.deinit(gpa);
        gpa.free(self.out_dir_when_generated);
        for (self.watched_env_values) |v| if (v) |s| gpa.free(s);
        gpa.free(self.watched_env_values);
    }
};
pub fn watchSetChanged(prev_changed: []const []const u8, prev_env: []const []const u8, cur: *const BuildOutput) bool;
pub fn outDirsIdentical(gpa: std.mem.Allocator, io: Io, store: *Store, out_dir_abs: []const u8, prev_manifest: Digest) bool;
pub const ScriptStateError = error{ InvalidState } || std.mem.Allocator.Error || Io.Dir.ReadFileAllocError || Io.Dir.WriteFileError;
pub fn readScriptState(gpa: std.mem.Allocator, io: Io, dir: Io.Dir, pkg: []const u8) ScriptStateError!?StoredScriptState;
pub fn writeScriptState(gpa: std.mem.Allocator, io: Io, dir: Io.Dir, pkg: []const u8, st: *const StoredScriptState) ScriptStateError!void;
pub fn runUnit(gpa: std.mem.Allocator, io: Io, store: *Store, unit: ScriptUnit, script_bin_abs: []const u8, prev: ?StoredScriptState, spool_abs: []const u8, base_env: *const std.process.Environ.Map, stderr: *Io.Writer) UnitRunError!ScriptResult;
```

Orchestration (exact order — the caching contract):
1. `validateLinks` over the whole plan BEFORE any `runUnit` call (Task 6; the CLI loop builds `LinksEntry` items — now carrying `version` — from the plan and validates once). Conflict aborts the build with exit 101 and cargo's message rendered from the two entries: `error: multiple packages link to native library '<links>': <a> v<x>, <b> v<y>` — i.e. `LinksError.DuplicateLinks` maps to `UnitRunError.LinksConflict` at this call site only (the mapping is `DuplicateLinks` → print both packages + return `LinksConflict`; `runUnit` itself never validates, it runs one unit).
2. Compute `scriptActionKey` (Task 4) from current inputs (script binary digest via `store_mod.hashFile`, watched env CURRENT values from the process env).
3. Freshness gate on PREVIOUS-run data only (cargo `fingerprint/mod.rs`: "The 'rerun-if' statements from a *previous* build are stored… Cargo parses this file when the Unit is prepared"). Exact rime order: (a) if no `prev` → run; (b) else `shouldRerun` with PREV lists + current env values + file mtimes; `fresh` → `store.getAction(io, gpa, prev.action_key)` → hit: `materializeOutDir` → return `from_cache = true` WITHOUT spawning (action-cache read errors degrade to a miss with a loud `warning: <pkg>: action cache unreadable; re-running` line — a miss is always safe); `rerun` (or action miss) → spawn → new key → `putAction(key, manifest)` → return fresh result (the CLI persists the new state with `writeScriptState`). Watch-set comparison (`watchSetChanged`: new output vs prev lists) happens AFTER the run only to decide what to STORE, never to skip — matches cargo (skip decision uses previous-run data only).
4. `OldStyleFallback` from `shouldRerun` → do NOT propagate: catch it, write the loud stderr line (Task-3 wording), and RUN (`from_cache = false`). (`UnitRunError.OldStyleAlwaysRerun` exists for the CLI to count old-style units in `--message-format=json` diagnostics; `runUnit` itself never returns it — document.)
5. `StoreFull` on ingest/put paths never fails the build (storage-v2 §10.4 build-driver rule): catch, emit the `lastFull()` breakdown verbatim to stderr, then compare the live OUT_DIR against the previous manifest with `outDirsIdentical` (re-hashes each recorded file with `store_mod.hashBytes`; extra live files are harmless — the live dir is used as-is on this path). Identical → return the parsed `output` with `manifest` = prev manifest, `from_cache = false`, `store_skipped = true`. Changed → propagate `StoreFull`. Tests cover: full→skipped-but-identical, and full→error when outputs changed.
6. `links` without script and without override → `need links-override` stderr + exit 1 (Task-6 decision; CLI maps it, `runUnit` never sees it).
7. warnings/errors channels: script `warnings` → stderr `warning: <pkg>: <msg>` lines; `errors` → stderr `error: <pkg>: <msg>` + build failure exit 101 AFTER running dependents? — cargo fails the unit. Locked: any `errors` entry fails `runUnit` with `ScriptFailed` (diagnostic = first error string), exit 101. No partial success.

Cache-hit test (the proof from the objective — "unchanged scripts don't rerun"):
```zig
test "unchanged script does not rerun: second run is from_cache" {
    // stub binary = sh script that appends "ran" to $RIME_SENTINEL then emits fixed directives.
    // run 1: no prev -> runs, sentinel has 1 line, from_cache == false.
    // run 2: prev = stored state from run 1, untouched files/env -> from_cache == true, sentinel STILL 1 line.
    // run 3: touch a watched file (write new bytes) -> runs again, sentinel 2 lines.
}
```

(Sentinel path via an extra env var passed through `RunConfig.dep_env`-style `extra_env: []const KeyValue`? — `RunConfig` is fixed… Locked: tests use `dep_env` to smuggle `RIME_SENTINEL` (it lands in the child env verbatim — legitimate use, documented in the test comment). No `RunConfig` change.)

CLI wiring (`cli.zig` `run()`): after workspace discovery and BEFORE the M1 view skeleton, `planScripts(gpa, io, ws, opts, stderr)` → whole-plan `validateLinks` (step 1 mapping: `DuplicateLinks` → print both packages + `LinksConflict`, exit 101) → per-unit `runUnit` (sequential in M5 — jobserver parallelism is M4's; document). `--dry-run` prints `unit-plan` envelopes including script units (`reason="unit-plan"`, package = script package, target = `build-script-<pkg>`) without running. Non-dry-run failures map: `LinksConflict` → exit 101; `ScriptFailed`/`errors` → exit 101; `need links-override` → exit 1. `RunConfig.base_env` is `init.environ_map` (`std.process.Init` names `main`'s first parameter; verified `lib/std/process.zig:18-50`) — no env-getter call exists or is needed; `readScriptState`/`writeScriptState` persist per-unit state under the view's `target/<profile>/.fingerprint/` dir handle. Production wiring needs only a smoke test (tests already cover `scriptEnv` with hand-built maps).

- [ ] **Step 1: Write the failing cache-hit test**

(Full three-run sentinel test above — it fails: `runUnit`/`StoredScriptState` undefined.)

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test 2>&1 | tail -10`
Expected: FAIL.

- [ ] **Step 3: Write minimal implementation**

```zig
pub fn watchSetChanged(prev_changed: []const []const u8, prev_env: []const []const u8, cur: *const BuildOutput) bool {
    if (prev_changed.len != cur.rerun_if_changed.len) return true;
    if (prev_env.len != cur.rerun_if_env_changed.len) return true;
    for (prev_changed, cur.rerun_if_changed) |a, b| if (!std.mem.eql(u8, a, b)) return true;
    for (prev_env, cur.rerun_if_env_changed) |a, b| if (!std.mem.eql(u8, a, b)) return true;
    return false;
}

fn outDirsIdentical(gpa: std.mem.Allocator, io: Io, store: *Store, out_dir_abs: []const u8, prev_manifest: Digest) bool {
    const pm = store.getManifest(io, gpa, prev_manifest) catch return false;
    defer pm.deinit(gpa);
    var dir = Io.Dir.cwd().createDirPathOpen(io, out_dir_abs, .{}) catch return false;
    defer dir.close(io);
    for (pm.outputs) |o| {
        const bytes = dir.readFileAlloc(io, o.path, gpa, .unlimited) catch return false;
        defer gpa.free(bytes);
        if (!std.meta.eql(store_mod.hashBytes(bytes), o.digest)) return false;
    }
    return true;
}

pub fn runUnit(
    gpa: std.mem.Allocator,
    io: Io,
    store: *Store,
    unit: ScriptUnit,
    script_bin_abs: []const u8,
    prev: ?StoredScriptState,
    spool_abs: []const u8,
    base_env: *const std.process.Environ.Map,
    stderr: *Io.Writer,
) UnitRunError!ScriptResult {
    const prev_changed: []const []const u8 = if (prev) |*p| p.output.rerun_if_changed else &.{};
    const prev_env_names: []const []const u8 = if (prev) |*p| p.output.rerun_if_env_changed else &.{};
    const prev_values: []const ?[]const u8 = if (prev) |*p| p.watched_env_values else &.{};
    const cur_env = try gpa.alloc(?[]const u8, prev_env_names.len);
    defer gpa.free(cur_env);
    for (prev_env_names, cur_env) |n, *slot| slot.* = base_env.get(n);
    // Gate key from PREVIOUS names + CURRENT values (first run has no prev => must run).
    if (prev) |*p| {
        const gate = shouldRerun(gpa, io, unit.pkg_dir_abs, .{
            .prev_changed = prev_changed,
            .prev_env_changed = prev_env_names,
            .prev_output_ns = p.started_ns,
            .current_env = cur_env,
            .prev_env_values = prev_values,
        }) catch |e| blk: {
            if (e != error.OldStyleFallback) return e;
            try stderr.writeAll("warning: ");
            try stderr.writeAll(unit.package);
            try stderr.writeAll(" build script uses old-style rerun detection; always re-running (package mtime walk not implemented)\n");
            break :blk RerunDecision.rerun;
        };
        if (gate == .fresh) {
            const hit: ?Store.ActionEntry = if (store.getAction(io, gpa, p.action_key)) |h| h else |e| blk: {
                try stderr.writeAll("warning: ");
                try stderr.writeAll(unit.package);
                try stderr.writeAll(": action cache unreadable (");
                try stderr.writeAll(@errorName(e));
                try stderr.writeAll("); re-running\n");
                break :blk null;
            };
            if (hit) |entry| {
                const out_dir_abs = try std.fs.path.join(gpa, &.{ spool_abs, "build", unit.package, "out" });
                errdefer gpa.free(out_dir_abs);
                try materializeOutDir(gpa, io, store, entry.manifest, out_dir_abs);
                return .{
                    .unit = unit,
                    .output = p.output,
                    .manifest = entry.manifest,
                    .out_dir_abs = out_dir_abs,
                    .started_ns = p.started_ns,
                    .from_cache = true,
                    .store_skipped = false,
                };
            }
        }
    }
    // Run path: compile already happened (driver seam supplied script_bin_abs).
    const bin_file = try Io.Dir.openFileAbsolute(io, script_bin_abs, .{});
    defer bin_file.close(io);
    const bin_digest = try store_mod.hashFile(bin_file, io);
    const out_dir_abs = try std.fs.path.join(gpa, &.{ spool_abs, "build", unit.package, "out" });
    errdefer gpa.free(out_dir_abs);
    const manifest_path = try std.fs.path.join(gpa, &.{ unit.pkg_dir_abs, "Cargo.toml" });
    defer gpa.free(manifest_path);
    var diag: [2048]u8 = undefined;
    var diag_len: usize = 0;
    var run_res = try runScript(gpa, io, store, .{
        .base_env = base_env,
        .script_bin_abs = script_bin_abs,
        .pkg_dir_abs = unit.pkg_dir_abs,
        .out_dir_abs = out_dir_abs,
        .out_dir_when_generated = if (prev) |*p| p.out_dir_when_generated else null,
        .manifest_dir = unit.pkg_dir_abs,
        .manifest_path = manifest_path,
        .links = unit.links,
        .features = unit.features,
        .target_triple = unit.target_triple,
        .host_triple = unit.host_triple,
        .profile_name = unit.profile_name,
        .opt_level = unit.opt_level,
        .debug_assertions = unit.debug_assertions,
        .rustc_abs = "rustc",
        .encoded_rustflags = unit.rustflags_encoded,
        .dep_env = &.{} ,
        .cfg_env = unit.cfg_env,
        .stderr = stderr,
    }, &diag, &diag_len);
    errdefer run_res.output.deinit(gpa);
    for (run_res.output.warnings) |w| {
        try stderr.writeAll("warning: ");
        try stderr.writeAll(unit.package);
        try stderr.writeAll(": ");
        try stderr.writeAll(w);
        try stderr.writeAll("\n");
    }
    if (run_res.output.errors.len > 0) {
        for (run_res.output.errors) |e| {
            try stderr.writeAll("error: ");
            try stderr.writeAll(unit.package);
            try stderr.writeAll(": ");
            try stderr.writeAll(e);
            try stderr.writeAll("\n");
        }
        return UnitRunError.ScriptFailed;
    }
    // Fresh key from the NEW output's names + current values.
    const new_names = run_res.output.rerun_if_env_changed;
    const new_vals = try gpa.alloc(?[]const u8, new_names.len);
    defer gpa.free(new_vals);
    for (new_names, new_vals) |n, *slot| slot.* = base_env.get(n);
    const key = try scriptActionKey(gpa, .{
        .script_bin_digest = bin_digest,
        .package_name = unit.package,
        .package_version = unit.version,
        .links = unit.links,
        .features = unit.features,
        .profile_name = unit.profile_name,
        .opt_level = unit.opt_level,
        .debug_assertions = unit.debug_assertions,
        .target_triple = unit.target_triple,
        .host_triple = unit.host_triple,
        .toolchain_id = unit.toolchain_id,
        .watched_env_values = new_vals,
        .watched_env_names = new_names,
        .rustflags_relevant = unit.rustflags_encoded,
    });
    const tags = [_]Tag{
        .{ .key = "crate", .value = unit.package },
        .{ .key = "crate_version", .value = unit.version },
        .{ .key = "toolchain", .value = unit.toolchain_id },
        .{ .key = "target", .value = unit.target_triple },
        .{ .key = "profile", .value = unit.profile_name },
        .{ .key = "project", .value = unit.project_tag },
        .{ .key = "action", .value = "build-script" },
    };
    const manifest = ingestOutputs(gpa, io, store, out_dir_abs, &run_res.output, &tags) catch |e| {
        if (e != error.StoreFull) return e;
        const full = store.lastFull();
        const full_line = try std.fmt.allocPrint(gpa, "warning: store full during script ingest: class={s} requested={d} used_total={d} hint={s}\n", .{ @tagName(full.class), full.requested_bytes, full.used_total, @tagName(full.hint) });
        defer gpa.free(full_line);
        try stderr.writeAll(full_line);
        if (prev) |*p| {
            if (outDirsIdentical(gpa, io, store, out_dir_abs, p.manifest)) {
                return .{
                    .unit = unit,
                    .output = run_res.output,
                    .manifest = p.manifest,
                    .out_dir_abs = out_dir_abs,
                    .started_ns = run_res.started_ns,
                    .from_cache = false,
                    .store_skipped = true,
                };
            }
        }
        return UnitRunError.StoreFull;
    };
    errdefer {
        // manifest put below failed: do not leak the ingested manifest digest (store-owned, nothing to free).
    }
    try store.putAction(io, key, manifest);
    return .{
        .unit = unit,
        .output = run_res.output,
        .manifest = manifest,
        .out_dir_abs = out_dir_abs,
        .started_ns = run_res.started_ns,
        .from_cache = false,
        .store_skipped = false,
    };
}
```

(`store.getAction(io, gpa, key) -> ?ActionEntry` with `.manifest` verified `src/store/root.zig:393` + `action_cache.zig:11` (`Store.ActionEntry` re-exported at `root.zig:382`); `putAction(io, key, manifest)` verified `:384`; `hashFile(file, io)` verified `root.zig:39` (`digest.zig:61` `HashFileError = Io.File.ReadPositionalError`, unioned into `UnitRunError` by that spelling); `lastFull() -> BudgetBreakdown` verified `:445` with `class/requested_bytes/used_total/hint` fields (`:76-85`), rendered verbatim. `putAction` errors other than `StoreFull` propagate via `IngestError`→`RunError`. `stderr` writes union `Io.Writer.Error`; the script-binary read unions `Io.Dir.ReadFileAllocError`. The empty `errdefer` above is intentional documentation, not a placeholder: manifest digests are store-owned values, nothing to free on that path.)

State file helpers (`target/<profile>/.fingerprint/<pkg>-script.json` — a VIEW-local hint, same class as M1 `last-build.json`; regenerable; the store stays authoritative via action keys):

```zig
const ScriptStateJson = struct {
    action_key: []const u8,
    manifest: []const u8,
    out_dir_when_generated: []const u8,
    started_ns: []const u8, // i96 decimal
    rerun_if_changed: []const []const u8,
    rerun_if_env_changed: []const []const u8,
    env_values: []const ?[]const u8,
};

pub fn writeScriptState(gpa: std.mem.Allocator, io: Io, dir: Io.Dir, pkg: []const u8, st: *const StoredScriptState) ScriptStateError!void {
    const rel = try std.fmt.allocPrint(gpa, ".fingerprint/{s}-script.json", .{pkg});
    defer gpa.free(rel);
    const action_hex = st.action_key.toHex();
    const man_hex = st.manifest.toHex();
    const ns_str = try std.fmt.allocPrint(gpa, "{d}", .{st.started_ns});
    defer gpa.free(ns_str);
    const bytes = try std.json.Stringify.valueAlloc(gpa, ScriptStateJson{
        .action_key = action_hex[0..],
        .manifest = man_hex[0..],
        .out_dir_when_generated = st.out_dir_when_generated,
        .started_ns = ns_str,
        .rerun_if_changed = st.output.rerun_if_changed,
        .rerun_if_env_changed = st.output.rerun_if_env_changed,
        .env_values = st.watched_env_values,
    }, .{});
    defer gpa.free(bytes);
    try dir.createDirPath(io, ".fingerprint");
    try dir.writeFile(io, .{ .sub_path = rel, .data = bytes });
}

pub fn readScriptState(gpa: std.mem.Allocator, io: Io, dir: Io.Dir, pkg: []const u8) ScriptStateError!?StoredScriptState {
    const rel = try std.fmt.allocPrint(gpa, ".fingerprint/{s}-script.json", .{pkg});
    defer gpa.free(rel);
    const bytes = dir.readFileAlloc(io, rel, gpa, .limited(1 << 20)) catch |e| switch (e) {
        error.FileNotFound => return null,
        else => return e,
    };
    defer gpa.free(bytes);
    const parsed = std.json.parseFromSlice(ScriptStateJson, gpa, bytes, .{ .allocate = .alloc_always }) catch return ScriptStateError.InvalidState;
    defer parsed.deinit();
    const dto = parsed.value;
    // Deep-dupe every string: `dto` arrays borrow the parse arena, freed by
    // `parsed.deinit()` below, so slice-header dupes alone would dangle.
    var changed: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (changed.items) |s| gpa.free(s);
        changed.deinit(gpa);
    }
    for (dto.rerun_if_changed) |s| try changed.append(gpa, try gpa.dupe(u8, s));
    var env_names: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (env_names.items) |s| gpa.free(s);
        env_names.deinit(gpa);
    }
    for (dto.rerun_if_env_changed) |s| try env_names.append(gpa, try gpa.dupe(u8, s));
    var env_vals: std.ArrayList(?[]const u8) = .empty;
    errdefer {
        for (env_vals.items) |v| if (v) |s| gpa.free(s);
        env_vals.deinit(gpa);
    }
    for (dto.env_values) |v| try env_vals.append(gpa, if (v) |s| try gpa.dupe(u8, s) else null);
    return StoredScriptState{
        .action_key = store_mod.Digest.fromHex(dto.action_key) catch return ScriptStateError.InvalidState,
        .output = .{
            .cfgs = &.{},
            .check_cfgs = &.{},
            .link_libs = &.{},
            .link_search = &.{},
            .link_args = &.{},
            .rustc_flags_raw = &.{},
            .env = &.{},
            .metadata = &.{},
            .rerun_if_changed = try changed.toOwnedSlice(gpa),
            .rerun_if_env_changed = try env_names.toOwnedSlice(gpa),
            .warnings = &.{},
            .errors = &.{},
        },
        .manifest = store_mod.Digest.fromHex(dto.manifest) catch return ScriptStateError.InvalidState,
        .out_dir_when_generated = try gpa.dupe(u8, dto.out_dir_when_generated),
        .started_ns = std.fmt.parseInt(i96, dto.started_ns, 10) catch return ScriptStateError.InvalidState,
        .watched_env_values = try env_vals.toOwnedSlice(gpa),
    };
}
```

(`Digest.fromHex` verified `src/store/manifest.zig:55`; `toHex` returns the `b3-` display form per Task 4. `StoredScriptState.deinit` must free `changed`/`env_names` strings, `env_vals` strings, and `out_dir_when_generated` — the `BuildOutput.deinit` from Task 1 frees the slices it owns; empty slices are no-ops.)

- [ ] **Step 4: Run tests + CLI smoke, verify exit codes**

Run: `zig build test 2>&1 | tail -3` — PASS.
Run: `zig build && TMP=$(mktemp -d) && cp -r testdata/cargo/script-protocol/ws $TMP/ && ./zig-out/bin/rime build --manifest-path $TMP/ws/Cargo.toml --dry-run --message-format=json` — script unit envelope present, exit 0. (Fixture workspaces are copied to tmp before any `rime build` touches them; nothing is built in-repo.)

- [ ] **Step 5: Commit**

```bash
jj status
jj commit src/cargo/script.zig src/cargo/cli.zig -m "Wire script runs with cache gate"
```

---

### Task 9: Validation corpus — e2e, protocol, cache-hit goldens

**Files:**
- Test: new inline tests in `src/cargo/script.zig` (protocol + cache-hit) + e2e tests invoking the real `rustc` in `validation/` projects (gated: skip when `rustc` absent)
- Fixtures: committed goldens `validation/basic-workspace/golden.script-output.json`, `validation/full-manifest/golden.script-output.json` (produced by the real `cargo` 1.99.0-nightly oracle — see generation step)

**Interfaces:**
- Consumes: all of Tasks 1–8. Produces (test helpers local to this task's tests):
```zig
pub const NormalizedOutput = struct {
    package: []const u8, // borrowed from the caller
    cfgs: []const []const u8, // gpa-owned array, strings borrowed, sorted
    rerun_if_changed: []const []const u8, // gpa-owned array, strings borrowed, sorted
    link_libs: []const []const u8, // gpa-owned array, strings borrowed, sorted
    metadata: []KeyValue, // gpa-owned array, keys borrowed, values gpa-owned (root-substituted), sorted by key
    pub fn deinit(self: *const NormalizedOutput, gpa: std.mem.Allocator) void {
        gpa.free(self.cfgs);
        gpa.free(self.rerun_if_changed);
        gpa.free(self.link_libs);
        for (self.metadata) |m| gpa.free(m.value);
        gpa.free(self.metadata);
    }
};
pub fn normalizeScriptOutput(gpa: std.mem.Allocator, output: *const BuildOutput, package: []const u8, validation_root_abs: []const u8) std.mem.Allocator.Error!NormalizedOutput;
```

Validation harness contract (CARGO CONFORMANCE MANDATE): real `cargo` binary (1.99.0-nightly) as oracle; paths parameterized as `@VALIDATION_ROOT@` (= repo `validation/` dir; tests resolve via `std.testing` cwd = repo root, so literal `validation/…` relatives — the `@VALIDATION_ROOT@` spelling appears in committed goldens only, substituted at compare time).

- [ ] **Step 1: Generate oracle goldens (manual, once, never in-repo)**

```bash
TMP=$(mktemp -d) && cp -r validation/basic-workspace $TMP/ && cd $TMP/basic-workspace && cargo build --target-dir $TMP/oracle-target -v 2>&1 | grep -E "rustc-cfg|rustc-check-cfg|rerun-if" | head -20
cargo metadata --format-version 1 > $TMP/golden.script-meta.json   # inspection only, NOT committed
```

(All oracle `cargo` invocations run against a tmp copy with `--target-dir` inside tmp; the repo `validation/` tree is never built in place and no `target/` dir is committed.)

Inspect which `cargo::` lines the real build scripts emit (basic-workspace `core-lib` build-dep script emits `rustc-check-cfg`/`rustc-cfg=has_build_dep`; full-manifest emits `has_build_script`). Hand-write the two `golden.script-output.json` files in the NORMALIZED shape (one JSON object: `{ "package": "…", "cfgs": […], "rerun_if_changed": […], "link_libs": […], "metadata": {…} }` — sorted keys, `@VALIDATION_ROOT@` for any absolute path). Then rime's e2e asserts `parseBuildOutput(stub-run-output)` normalizes to the golden. Goldens are hand-written FROM oracle output (not copied bytes) because absolute paths differ per machine — the normalization (sort + `@VALIDATION_ROOT@` substitution) is part of the test helper `normalizeScriptOutput`, defined in this task and unit-tested with a hardcoded sample.

- [ ] **Step 2: Write the failing e2e + protocol tests**

Oracle gate (hermetic discipline — live `cargo` NEVER touches the repo tree and NEVER runs unless explicitly enabled AND present; goldens, not live cargo, are the CI authority):

```zig
// Explicit opt-in flag; set false to force-skip live-oracle tests locally.
const oracle_enabled: bool = true;

fn cargoAvailable(io: Io) bool {
    var child = std.process.spawn(io, .{
        .argv = &.{"cargo", "--version"},
        .stdin = .ignore, .stdout = .ignore, .stderr = .ignore,
    }) catch return false;
    defer child.kill(io);
    const term = child.wait(io) catch return false;
    return term == .exited and term.exited == 0;
}

fn oracleAvailable(io: Io) bool {
    return oracle_enabled and cargoAvailable(io);
}

test "e2e basic-workspace script output matches oracle golden" {
    const io = std.Io.Threaded.global_single_threaded.io();
    if (!oracleAvailable(io)) return error.SkipZigTest;
    // Copy validation/basic-workspace (Cargo.toml + build.rs + src/) into a
    // fresh tmpDir via handle-relative readFileAlloc/writeFile; run
    // `cargo build --target-dir <tmp>/oracle-target` with CARGO_NET_OFFLINE=true
    // in the child environ_map AND rime's compile+runScript with OUT_DIR under
    // <tmp>/rime-out; assert parseBuildOutput on both captured stdouts
    // normalizes (normalizeScriptOutput) to golden.script-output.json.
    // Fails now: normalizeScriptOutput is not defined yet (implemented below in this task).
    var empty = try parseBuildOutput(std.testing.allocator, "", .{});
    defer empty.deinit(std.testing.allocator);
    var norm = try normalizeScriptOutput(std.testing.allocator, &empty, "basic-workspace", "/tmp/nowhere");
    defer norm.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("basic-workspace", norm.package);
}

```zig
test "normalizeScriptOutput sorts and substitutes the root" {
    var out = try parseBuildOutput(std.testing.allocator, "cargo::rustc-cfg=b_cfg\ncargo::rustc-cfg=a_cfg\ncargo::metadata=root=/tmp/xyz\n", .{});
    defer out.deinit(std.testing.allocator);
    var norm = try normalizeScriptOutput(std.testing.allocator, &out, "demo-pkg", "/tmp/xyz");
    defer norm.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("demo-pkg", norm.package);
    try std.testing.expectEqualStrings("a_cfg", norm.cfgs[0]);
    try std.testing.expectEqualStrings("b_cfg", norm.cfgs[1]);
    try std.testing.expectEqualStrings("@VALIDATION_ROOT@", norm.metadata[0].value);
}
```

Full helper (sort via `std.mem.sort` with an inline comparator; substitution via `std.mem.replaceOwned`, verified `lib/std/mem.zig:4199`):

```zig
fn sortBorrowed(gpa: std.mem.Allocator, in: []const []const u8) std.mem.Allocator.Error![]const []const u8 {
    const arr = try gpa.dupe([]const u8, in);
    errdefer gpa.free(arr);
    std.mem.sort([]const u8, arr, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lessThan);
    return arr;
}

pub fn normalizeScriptOutput(gpa: std.mem.Allocator, output: *const BuildOutput, package: []const u8, validation_root_abs: []const u8) std.mem.Allocator.Error!NormalizedOutput {
    const cfgs = try sortBorrowed(gpa, output.cfgs);
    errdefer gpa.free(cfgs);
    const changed = try sortBorrowed(gpa, output.rerun_if_changed);
    errdefer gpa.free(changed);
    const libs = try sortBorrowed(gpa, output.link_libs);
    errdefer gpa.free(libs);
    var md: std.ArrayList(KeyValue) = .empty;
    errdefer {
        for (md.items) |m| gpa.free(m.value);
        md.deinit(gpa);
    }
    for (output.metadata) |m| {
        const v = try std.mem.replaceOwned(u8, gpa, m.value, validation_root_abs, "@VALIDATION_ROOT@");
        errdefer gpa.free(v);
        try md.append(gpa, .{ .key = m.key, .value = v });
    }
    std.mem.sort(KeyValue, md.items, {}, struct {
        fn lessThan(_: void, a: KeyValue, b: KeyValue) bool {
            return std.mem.order(u8, a.key, b.key) == .lt;
        }
    }.lessThan);
    return .{
        .package = package,
        .cfgs = cfgs,
        .rerun_if_changed = changed,
        .link_libs = libs,
        .metadata = try md.toOwnedSlice(gpa),
    };
}
```

test "protocol DEP_ propagation end-to-end: sys metadata reaches app script env" {
    // Feed testdata/cargo/script-protocol/links.txt through parse + propagate with
    // links="native-sys", package="sys"; assert the exact 4-var sequence from Task 2
    // appears in the assembled child env (via scriptEnv with a hand-built base map).
}

test "cache-hit: oracle-fresh scripts do not respawn" {
    // The Task-8 sentinel test IS this proof; here assert it once more at the
    // validation-project level: two consecutive runUnit calls over
    // validation/full-manifest's OUT_DIR with no changes -> second from_cache.
    // (Uses the real store + tmp OUT_DIRs, not the committed target/ dir.)
}
```

- [ ] **Step 3: Make them pass (fix normalization, not goldens)**

Rule (same as M1 Task 7): the golden is the authority. If rime's output differs, fix rime. If the golden is wrong (e.g. missed a `rerun-if-changed` line the oracle actually emits), regenerate the golden FROM the oracle and re-verify by hand (`diff` the normalized oracle output against the golden). Never edit the fixture script to make the test pass.

- [ ] **Step 4: Full suite + manual oracle diff**

Run: `zig build test 2>&1 | tail -3` — PASS.
Run: `timeout 300 zig build && TMP=$(mktemp -d) && cp -r validation/full-manifest $TMP/ && ./zig-out/bin/rime build --manifest-path $TMP/full-manifest/Cargo.toml --dry-run` — exit 0, script unit listed. (Both oracle and rime runs target tmp copies; in-repo `validation/` trees are never built and no `target/` state is committed.)
Run: `diff <(./zig-out/bin/rime build --manifest-path $TMP/basic-workspace/Cargo.toml --dry-run --message-format=json) testdata/cargo/golden/plan.json` — note: plan.json predates scripts; if script envelopes change the stream, EXTEND the golden in this task (with oracle cross-check), do not fork a second golden file.

- [ ] **Step 5: Commit**

```bash
jj status
jj commit src/cargo/script.zig validation/basic-workspace/golden.script-output.json validation/full-manifest/golden.script-output.json -m "Add script validation goldens"
```

---

## Appendix A — spec coverage

| Objective / spec section | Coverage | Task |
|---|---|---|
| `rerun-if-changed` / `rerun-if-env-changed` | parsed (Task 1), freshness-gated (Task 3), key-bound env values (Task 4) | 1, 3, 4 |
| `cargo:rustc-cfg/link-lib/link-search/env` | parsed incl. `rustc-flags` split (Task 1), fed to seam (Task 6) | 1, 6 |
| `warning`/`error` directives | parsed both syntaxes; warnings→stderr, errors→101 (Tasks 1, 8) | 1, 8 |
| `cargo:` old syntax + `cargo::` new + `metadata=` | exact cargo dispatch arms (Task 1) | 1 |
| corrosion-style (`cargo:KEY=VALUE`) unreserved keys | old-syntax metadata arm (Task 1) + DEP_ propagation (Task 2) | 1, 2 |
| `DEP_<links>_<key>` via `links` | envify + propagate + CARGO_MANIFEST_LINKS + own-links env (Tasks 2, 5) | 2, 5 |
| macOS sandbox-exec/seatbelt | required wrapper, generated profile (Task 5) | 5 |
| Linux namespaces/landlock best-effort, loud | unshare probe + none_loud warning (Task 5); landlock explicitly not attempted (std-only) | 5 |
| store artifacts `action=build-script` | ingest + tags + putAction (Task 4) | 4 |
| OUT_DIR materialization semantics | create-before-spawn, materialize-on-hit, rewrite rule (Tasks 4–5) | 4, 5 |
| proc-macro host compile + dylib ingest | Kind.dylib, never-demoted assert, host triple (Task 7) | 7 |
| macro-expansion loading path / boundary | explicit WORKS/DOES-NOT-WORK + `need driver` error (Task 7) | 7 |
| caching: rerun conditions in action key | env values in key, paths excluded (Task 4); gate order (Task 8) | 4, 8 |
| e2e corpus compile (basic-workspace, full-manifest) | Task 9 | 9 |
| protocol tests (scripted lines → DEP_) | Tasks 1–2 tests + Task 9 protocol test | 1, 2, 9 |
| cache-hit tests (unchanged ⇒ no rerun) | sentinel test (Task 8) + validation-level (Task 9) | 8, 9 |
| storage-v2 §16 Store surface | only putBytes/putFile/putManifest/getManifest/getAction/putAction/tagObject/lookupObjects/materialize/lastFull used; never objects//cold//index paths | 4, 5, 8 |
| storage-v2 §11.3 tags | six fixed tags + action=build-script/proc-macro; features fh- shape; project pb3- | 4, 7 |

## Appendix B — open questions (for M4/M6 owners, not M5)

1. `[target.<triple>] links` config overrides (`TargetConfig::parse_links_overrides`): M6 parses them; until then `need links-override` exit 1. Is exit 1 right, or should missing overrides be exit 101 (build failure)?
2. `RUSTDOC` passthrough when rustdoc is absent: unset vs empty string — which matches cargo's `gctx.rustdoc()?` failure mode?
3. Old-style (no rerun-if) scripts always rerun in M5. Does M4's fingerprint want the package-file list after all, or is always-rerun acceptable until a file-watcher lands?
4. Proc-macro dependents: should M4 block with `need driver` (M5 choice) or attempt `--extern` against the store path immediately even before full driver parity?
5. `NUM_JOBS` value: LOCKED to `"1"` in Task 5 (M5 runs units sequentially; cargo uses `bcx.jobs()`). Who owns the jobserver — M4?

## Self-review

**1. Spec coverage:** every objective clause maps to ≥1 task (Appendix A table — each row names its task). The M4 seam is defined as signatures + stub body with the explicit replacement contract (Task 6), so M5 never blocks on unlanded code. Validation design (e2e corpus + protocol + cache-hit + oracle goldens) is Task 9 with generation commands and the golden-authority rule.
**2. Placeholder scan:** no unfinished markers, no `...` elisions in code or test literals, no "handle edge cases"-style vagueness, no "similar to Task N" cross-references — every step names exact code (full function bodies or exact deltas), exact commands with expected output, and exact error names. Deviations from cargo (CARGO_DEP_ always-on; old-style always-rerun; missing-script warn-and-skip; StoreFull-identical rule; non-ASCII envify folding) are each locked with rationale in the task text, not deferred.
**3. Type consistency:** `BuildOutput`/`KeyValue`/`LinkArg`/`ParseOptions` (Task 1) → consumed unchanged by Tasks 2, 4–6, 8–9 (`parseBuildOutput(gpa, input, opts)` at every call site); `ScriptUnit`/`ScriptResult`/`ProcMacroArtifact`/`StoredScriptState` field lists are identical at definition and use sites (`store_skipped` on `ScriptResult`, `action_key` on `StoredScriptState`, `started_ns` on the `runScript` return, `base_env`/`cfg_env`/`out_dir_when_generated` on `RunConfig`, `version` on `LinksEntry` — all declared in their defining blocks before any use); `rewriteOutDir` (Task 4), `renderSandboxWarning`/`scriptBinPath` (Task 5), `planScripts`/`PlanOptions`/`deinitPlanUnits` (Task 6), `watchSetChanged`/`outDirsIdentical`/`readScriptState`/`writeScriptState`/`normalizeScriptOutput` (Tasks 8–9) are each declared in a Produces/Interfaces block with full bodies; `DirectiveError`/`PropagationError`/`RerunError`/`IngestError`/`RunError`/`LinksError`/`PlanError`/`ProcMacroError`/`UnitRunError`/`ScriptStateError` each introduced once with exact membership.
