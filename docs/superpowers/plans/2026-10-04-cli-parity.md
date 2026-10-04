# Full CLI Parity Implementation Plan (Plan C M6)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:delegate (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Bring rime's CLI to full cargo parity for the build surface: cargo-shaped streaming JSON events, real run/test/bench execution with cargo's exit codes, complete flag coverage, and snapshot-disciplined help text.

**Architecture:** Extend the existing M1 CLI in `src/cargo/cli.zig` (never replace it): grow `Options`/`parseArgs` with the missing global and per-command flags, replace the M1 `JsonEnvelope` with cargo's four machine-message shapes emitted through one stdout writer, and add a `Runner` seam (function-pointer injection, the `fetch.zig` `GitRunner` precedent) so process forwarding is unit-testable without spawning. Golden JSON streams are captured from the real cargo oracle against `validation/` fixtures and committed.

**Tech Stack:** Zig 0.16.0 exactly, std only. Real `cargo` 1.99.0-nightly as oracle (gated by `RIME_CARGO_ORACLE=1`, the `src/cargo/oracle.zig` precedent).

**Spec:** `docs/superpowers/plans/2026-10-04-cargo-frontend.md` (roadmap + M1 detail, §0.4 M6 row), `docs/design/storage-v2.md` §§12.2/13.1/16 (Store surface), vendored cargo 0.99.0 at `references/cargo` (normative for every behavior below — exact file/function cited per task).

## Global Constraints

- Zig **0.16.0** exactly. FS access goes through the `std.Io` interface value passed as `io` to every call; `std.Io.Dir`/`std.Io.File` methods take `io` (copy call sites from `src/cargo/cli.zig` / `src/cargo/fetch.zig`, never invent shapes).
- Child processes only via the verified 0.16 shape `std.process.spawn(io, .{ .argv, .cwd, .stdin, .stdout, .stderr })` returning `Child`; passthrough is `.inherit` (the `SpawnOptions` default); capture uses `.pipe` drained with `std.Io.File.MultiReader` exactly like `fetch.zig` `CliGit.cliRun` and `oracle.zig` `runCapture`. `child.wait(io)` returns a union compared as `term == .exited and term.exited == 0`.
- `main` takes `std.process.Init`; iterate `std.process.Args.Iterator` (see `src/main.zig:137`). `std.process.argsAlloc` DOES NOT EXIST. Env reads via `std.c.getenv` (the `cli.zig`/`oracle.zig` precedent; `std.process.getEnvVarOwned` is absent in 0.16).
- Tests are inline (`test "…"` blocks). `zig build test` must pass before **every** commit. Never commit with failing tests.
- All VCS operations use **jj**: `jj status`, `jj diff`, `jj commit <paths> -m "…"`. Never run git write commands. One logical change per commit, imperative ≤50-char summaries.
- Scratch experiments go in `/tmp`, never in the repo. `timeout 300` on blocking commands. Never `find /` (zig std lives at the `zig env` `std_dir`).
- Cargo-compat invariants after every task: stdout stays pipe-clean (JSON lines only, human rendering on stderr); exit codes match cargo exactly (§exit-code matrix in Task 6); project dirs never hold cache state; store objects read-only (`0o444`), never hardlinked into `target/`.
- Digest text form is `b3-<64 lowercase hex>` in all user-facing output.

---

## 0. Command coverage matrix (scope contract — read before any task)

The M6 command surface, decided per vendored-cargo file. Anything not in
the IN column is explicitly OUT with its reason; do not add it.

| Command | M6 scope | Cargo reference | Rationale |
|---|---|---|---|
| `build` | IN — full parity | `references/cargo/src/bin/cargo/commands/build.rs` | Core build surface. |
| `check` | IN — full parity (profile `check`, rmeta-only units) | `commands/check.rs` | Core build surface. |
| `test` | IN — compile + harness run + forwarding | `commands/test.rs`, `src/cargo/ops/cargo_test.rs` | `--no-run`, `--no-fail-fast`, `BENCHNAME`-style filter args, `--` passthrough to libtest. |
| `run` | IN — build + spawn + exit-code passthrough | `commands/run.rs` (`to_run_error`), `src/cargo/ops/cargo_run.rs` | `--bin/--example` selection, trailing `ARGS`, default-run; glob `-p` patterns rejected like cargo. |
| `bench` | IN — compile + bench-harness run | `commands/bench.rs` | `BENCHNAME` positional filter, `--no-run`, `--no-fail-fast`. |
| `clean` | IN — `-p` (repeatable), `--workspace`, `--release/--profile`, `--target`, `--target-dir`, `--manifest-path`, `--dry-run`, `--doc` | `commands/clean.rs` | Matches cargo's selection surface; `--doc` removes only `target/doc`. Hidden `clean gc` subcommand is OUT (see below). |
| `fetch` | IN — wire existing `fetch.zig` to the CLI (`--target`, `--manifest-path`) | `commands/fetch.rs`, `src/cargo/ops/cargo_fetch.rs` | Fetch machinery already exists (Plan M2, `src/cargo/fetch.zig`); M6 only adds the CLI entry + exit codes. |
| `tree` | OUT | `commands/tree.rs` | Read-only inspection command; the validation oracle uses the **real** `cargo tree` against `validation/` goldens (`golden.tree*.txt`). A rime-native `tree` is a separate future plan; M6 must not fork its output format. |
| `metadata` | OUT | `commands/metadata.rs` | Same as `tree`: oracle-owned (`golden.metadata.json`), separate future plan. |
| `verify-project` | OUT | `commands/verify_project.rs` | Upstream-DEPRECATED and hidden (`hide(true)`, "DEPRECATED: Check correctness of crate manifest"). Reimplementing a deprecated command is scope creep. |
| `update` / `generate-lockfile` | OUT (CLI), IN only the `--locked/--frozen` enforcement already in `cli.zig` Task-9 code | `commands/update.rs`, `commands/generate_lockfile.rs` | Lockfile mutation belongs to the M3 resolver plan; M6 must not grow a second lock writer. |
| `package`/`publish`/`install`/`doc`/`fix`/`new`/`init`/`add`/`remove`/registry cmds | OUT | `commands/` remainder | Distribution/scaffolding commands, not the build surface. Unknown commands keep the M1 `unknown command` exit-1 behavior. |
| `rime gc` / `rime cache stat` | IN — help-text interop only (see Task 7) | `commands/clean.rs` (`clean gc` hidden subcommand), storage-v2 §12.2 | rime's `gc`/`cache stat` already exist in `src/main.zig`; M6 adds help pointers, not new behavior. |

M1-removal note: the M1 `JsonEnvelope{reason,package,target,profile,success}` wire shape (with `"unit-plan"` / `"build-finished"` reasons) is **not** cargo and is removed in Task 3. The M1 golden `testdata/cargo/golden/plan.json` is regenerated in cargo shapes in Task 8; nothing else reads the old shape (`grep` in Task 3 Step 1 proves it).

---

## File Structure

```
src/cargo/cli.zig      EXTEND: Options grows global + per-command flags; parseArgs grows;
                       JsonEnvelope REMOVED, replaced by msg.zig event writers;
                       run() dispatches build/check/test/run/bench/clean/fetch;
                       Runner seam for spawn (Tasks 2, 4, 5, 6)
src/cargo/msg.zig      CREATE: cargo machine-message event protocol (Task 3)
src/cargo/runner.zig   CREATE: process-forwarding seam: Runner iface + LiveRunner +
                       FakeRunner for tests (Task 4)
src/main.zig           MODIFY: route fetch; leading-global-flags shim; help-text
                       additions for gc/cache-stat interop (Tasks 1, 2, 7)
testdata/cargo/golden/ MODIFY: plan.json regenerated in cargo shapes (Task 8)
validation/m6-golden/  CREATE: committed oracle-captured JSON streams + exit-code
                       matrix fixtures (Task 8)
docs/superpowers/plans/2026-10-04-cli-parity.md  THIS FILE
```

Each task's **Interfaces** block is the contract between tasks: exact names
and types the neighbor tasks use. Implement exactly these; do not rename.

`cli.zig` keeps its module wiring (`src/cargo/root.zig` re-export +
`build.zig` `cargo` module + `@import("cargo")` / `@import("store")` named
imports). New modules are siblings imported by relative path
(`@import("msg.zig")`), the same pattern `cli.zig` uses for
`workspace.zig`/`view.zig`. Never `@import` a parent dir (rejected under
bare `zig test`).

---

### Task 1: Command coverage — wire `fetch`, scope the surface

**Files:**
- Modify: `src/cargo/cli.zig` (add `fetch` variant + `FetchOptions` passthrough + dispatch)
- Modify: `src/main.zig` (`isCargoCommand` gains `"fetch"`)
- Test: inline tests in `src/cargo/cli.zig`

**Interfaces:**
- Consumes: `fetch.zig` `ensureSources` (fetch.zig:1571) — the fetch-all entry `(gpa, io, store, client, git, opts, lock, git_decls)`; Task 1 wires CLI dispatch to it and does not change `fetch.zig`.
- Produces (used by Tasks 2, 6):
```zig
pub const Command = enum { build, check, test_cmd, run, bench, clean, fetch };
pub const Options = struct {
    cmd: Command,
    manifest_path: ?[]const u8,
    profile: []const u8,
    explicit_profile: bool,
    target_triple: ?[]const u8,       // single --target (M1 field, kept; multi-target lands in Task 5)
    only_package: ?[]const u8,        // -p/--package, single (M1 field, kept; repeatable lands in Task 5)
    features: []const []const u8,
    message_format: MessageFormat,    // extended value set (Task 2 replaces the enum)
    offline: bool,
    frozen: bool,
    locked: bool,
    dry_run: bool,
    extra_args: []const []const u8,
};
```

Cargo pins: `commands/fetch.rs::cli` (flags: `--target`, `--manifest-path` only — fetch takes no profile/features/jobs flags) and `commands/fetch.rs::exec` (`FetchOptions { gctx, targets }`, `ops::fetch`).

- [ ] **Step 1: Read the fetch entry point and prove the old shape has one reader**

Run: `grep -n "^pub fn" src/cargo/fetch.zig | head -30` and `grep -rn "JsonEnvelope\|unit-plan" src/ testdata/ --include=*.zig --include=*.json | grep -v "src/cargo/cli.zig"`
Expected: `ensureSources` confirmed as the fetch-all entry at fetch.zig:1571; the only `unit-plan` producer/reader is `cli.zig` + `testdata/cargo/golden/plan.json` (Task 3 may remove both freely).

- [ ] **Step 2: Write the failing test**

```zig
test "cli parses fetch with target only" {
    const argv = [_][]const u8{ "rime", "fetch", "--target", "aarch64-apple-darwin" };
    var opts = try parseArgs(std.testing.allocator, &argv);
    defer opts.deinit(std.testing.allocator);
    try std.testing.expect(opts.cmd == .fetch);
    try std.testing.expectEqualStrings("aarch64-apple-darwin", opts.target_triple.?);
}

test "cli rejects profile flags on fetch" {
    const argv = [_][]const u8{ "rime", "fetch", "--release" };
    try std.testing.expectError(CliError.Usage, parseArgs(std.testing.allocator, &argv));
}
```

- [ ] **Step 3: Run test to verify it fails**

Run: `zig build test 2>&1 | tail -10`
Expected: FAIL — `fetch` is not a known command (`unknown command 'fetch'`).

- [ ] **Step 4: Write minimal implementation**

Add `.fetch` to the `Command` enum and the `parseArgs` command table. After
parsing, validate the fetch flag subset exactly (cargo's `fetch.rs::cli`
takes only `--target`/`--manifest-path` plus globals): `--release`,
`--profile`, `--features`, `-p/--package`, `--dry-run`, `--message-format`
on fetch → `fail("flag '{s}' is not supported for fetch", .{f})` (exit 1,
same shape as the existing `isCleanOnlyReject`). Dispatch in `run()`: a new
`runFetch` that discovers the workspace via the existing `loadWorkspace`
(“…could not find Cargo.toml…” exit 1 on failure, unchanged) and calls
`ensureSources`; fetch errors print `error: fetch failed:
{t}` on stderr and return `ExitCode.usage` (1). `src/main.zig`:
`isCargoCommand` gains `std.mem.eql(u8, arg, "fetch")`.

- [ ] **Step 5: Run test to verify it passes**

Run: `zig build test 2>&1 | tail -5` then `zig build 2>&1 | tail -3`
Expected: PASS, `zig-out/bin/rime` builds.

- [ ] **Step 6: Commit**

```bash
jj status
jj commit src/cargo/cli.zig src/main.zig -m "Wire fetch command with cargo flag subset"
```

---

### Task 2: Global flags — leading position, verbosity, color, jobs, config

**Files:**
- Modify: `src/cargo/cli.zig` (`Options`, `MessageFormat`, `parseArgs`, `run` verbosity plumbing)
- Modify: `src/main.zig` (leading-globals prescan before `parseCommand` routing)
- Test: inline tests in `src/cargo/cli.zig` + one routing test in `src/main.zig`

**Interfaces:**
- Consumes: Task 1 `Options`/`Command`.
- Produces (used by Tasks 3–6):
```zig
pub const MessageFormat = enum { human, short, json, json_render_diagnostics, json_diagnostic_short, json_diagnostic_rendered_ansi };
pub const ColorChoice = enum { auto, always, never };
pub const JobsConfig = union(enum) { integer: i32, string: []const u8 };
pub const Options = struct {
    cmd: Command,
    manifest_path: ?[]const u8,
    profile: []const u8,
    explicit_profile: bool,
    target_triple: ?[]const u8,
    only_package: ?[]const u8,
    features: []const []const u8,
    message_format: MessageFormat,
    format_error: bool,               // message-format conflict/invalid (row 5 -> 101, Task 6)
    format_diagnostic: ?[]const u8,   // owned message printed when format_error is set (deinit frees)
    offline: bool,
    frozen: bool,
    locked: bool,
    dry_run: bool,
    extra_args: []const []const u8,
    verbose: u32,                    // -v count (global + per-command sum)
    quiet: bool,                     // -q/--quiet (global or per-command)
    color: ColorChoice,              // --color (default .auto)
    jobs: ?JobsConfig,               // -j/--jobs N (Task 4 consumes; M6 parses + validates only)
    config_overrides: []const []const u8, // --config KEY=VALUE|PATH, repeatable (stored, applied in M6 iff key is store.*)
};
```

Cargo pins (all in vendored cargo, all normative):
- `src/bin/cargo/cli.rs::cli` — `-v/--verbose` (`ArgAction::Count`, global), `-q/--quiet` (global), `--color auto|always|never` (global, `ignore_case(true)`), `-C DIRECTORY` (nightly-only: reject with exit 1), `--locked/--frozen/--offline` (global), `--config KEY=VALUE|PATH` (multi, global), `-c` → suggest `--config`.
- `src/bin/cargo/cli.rs::configure_gctx` — effective `verbose = global.verbose + args.verbose()`; `quiet = args.quiet || subcommand.quiet || global.quiet`; frozen/locked/offline OR across levels.
- `src/cargo/util/command_prelude.rs::arg_jobs` — `-j/--jobs N` ("Number of parallel jobs, defaults to # of CPUs"); `jobs()` parses `N` as `i32`, unparsable stays a string (`JobsConfig::String`, resolved against config — M6 keeps the string form parsed-and-stored, resolution deferred with a loud `error: --jobs <string> profiles are not resolved in M6` only if actually used).
- `command_prelude.rs::message_format` (lines 747–806) — allowed comma-separated values `json,human,short,json-render-diagnostics,json-diagnostic-short,json-diagnostic-rendered-ansi`; two kinds → `bail!("cannot specify two kinds of \`message-format\` arguments")`; unknown → `bail!("invalid message format specifier: \`{s}\`")`. Both bails are `anyhow` errors → **exit 101**, not 1 (see `util/errors.rs::From<anyhow::Error>`). Repeatable flag, values split on `,`, lowercased before matching.

Behavior contract:
- Leading globals: `rime -v build`, `rime --quiet check`, `rime --color=never test` must parse identically to trailing position. Implement in `main.zig`: a prescan that partitions `argv` globals appearing before the command word (`-v`, `-vv`, `-q`, `--quiet`, `--color[=X]`, `--offline/--frozen/--locked`, `--config X`, `-j N`, `--jobs[=N]`) and splices them after the command before `parseArgs`. Unknown leading flags are NOT prescanned (fall through to the existing usage error — cargo would reject them too).
- `--color` accepts `auto|always|never` case-insensitively (`--color=never` and `--color never`); anything else → `Usage` exit 1 naming the value. `always` forces ANSI even on pipes; `never` strips all styling; `auto` styles only when stderr is a tty. M6 applies color only to human rendering on stderr (JSON stdout is never styled).
- `-v` counts: `-vv` and `-v -v` both yield 2. Level semantics: 0 default, 1 shows rustc invocations + `Fresh` lines, ≥2 shows store action keys and full env. `--quiet` suppresses all stderr except errors and silences the run-failure extra message (see Task 6 `to_run_error` rule); `--quiet` wins over `-v` when both are passed (cargo: quiet flag checked independently; document as `quiet = q || global_q`, verbosity ignored for rendering when quiet).
- `--config` entries are stored verbatim. M6 applies exactly the `store.*` keys (`store.budget`, `store.hot_cap`, …) to the `Store.open` config; any other dotted key → `error: --config '{s}' is not supported by rime (M6 supports store.* only)` exit 1. A value that is an existing file path is read as a TOML fragment (cargo accepts PATH form); missing path → exit 1.
- `-C DIRECTORY` → `error: the \`-C\` flag is unstable` exit 1 (cargo rejects it on stable too).
- `-j/--jobs`: positive integer stored; `0`/negative allowed through the parser (cargo's `JobsConfig::Integer` carries them; validation happens downstream — M6 validates `jobs.integer >= 1` at use time in Task 4 with exit 1 naming the value).

- [ ] **Step 1: Write the failing tests**

```zig
test "cli parses global flags in both positions" {
    const argv = [_][]const u8{ "rime", "build", "-vv", "-q", "--color=never", "-j4" };
    var opts = try parseArgs(std.testing.allocator, &argv);
    defer opts.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 2), opts.verbose);
    try std.testing.expect(opts.quiet);
    try std.testing.expect(opts.color == .never);
    try std.testing.expectEqual(@as(i32, 4), opts.jobs.?.integer);
}

test "cli rejects bad color and -C" {
    const bad = [_][]const u8{ "rime", "build", "--color", "rainbow" };
    try std.testing.expectError(CliError.Usage, parseArgs(std.testing.allocator, &bad));
    const c = [_][]const u8{ "rime", "build", "-C", "/tmp" };
    try std.testing.expectError(CliError.Usage, parseArgs(std.testing.allocator, &c));
}

test "cli parses full message-format set" {
    const argv = [_][]const u8{ "rime", "build", "--message-format", "json-render-diagnostics,json-diagnostic-short" };
    var opts = try parseArgs(std.testing.allocator, &argv);
    defer opts.deinit(std.testing.allocator);
    try std.testing.expect(opts.message_format == .json_diagnostic_short);
    // render_diagnostics without base json is allowed (cargo promotes to default json)
    const argv2 = [_][]const u8{ "rime", "build", "--message-format=json-diagnostic-rendered-ansi" };
    var opts2 = try parseArgs(std.testing.allocator, &argv2);
    defer opts2.deinit(std.testing.allocator);
    try std.testing.expect(opts2.message_format == .json_diagnostic_rendered_ansi);
}

test "cli message-format conflicts fail" {
    // cargo: two kinds -> bail (exit 101 at exec; parse records Usage here, Task 6 maps it)
    const argv = [_][]const u8{ "rime", "build", "--message-format", "json,human" };
    try std.testing.expectError(CliError.Usage, parseArgs(std.testing.allocator, &argv));
    const bad = [_][]const u8{ "rime", "build", "--message-format", "yaml" };
    try std.testing.expectError(CliError.Usage, parseArgs(std.testing.allocator, &bad));
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `zig build test 2>&1 | tail -10`
Expected: FAIL — `verbose`/`quiet`/`color`/`jobs` fields and the new `MessageFormat` variants do not exist.

- [ ] **Step 3: Write minimal implementation**

Extend `Options` with the new fields (`Options.deinit` also frees
`config_overrides` and `format_diagnostic`; `features`/`extra_args` as before). Extend the argv
loop: `-v` (count each occurrence; combined `-vvv` counts each `v`),
`--verbose` (count 1), `-q`/`--quiet`, `--color` (both forms, lowercase
before matching, validate the triple), `-jN` / `-j N` / `--jobs[=N]`
(integer parse; unparsable → `JobsConfig{ .string = raw }`), `--config`
(repeatable, exactly one `takeValue`), `-C` → `fail("the \`-C\` flag is
unstable, pass \`-Z unstable-options\` on the nightly channel to enable
it")`, `-c` → `fail("use \`--config\` instead of \`-c\`")`. Message-format:
replace the M1 single-value branch with the cargo loop — for each
`--message-format` occurrence, split value on `,`, lowercase each piece,
fold into an accumulator following `command_prelude.rs:753-806` exactly
(`json`/`human`/`short` set the base and error if already set;
`json-render-diagnostics`/`json-diagnostic-short`/`json-diagnostic-rendered-ansi`
promote `null` to default-json then set their bit, error against a
non-json base; unknown piece → fail). Record which failure class it was:
message-format conflicts/invalid values must exit **101**, not 1 — add
`pub const format_failed: u8 = 101` handling by threading a
`format_error: bool` flag on the parse side (see Task 6 for the exit-code
mapping; the flag is set here). `main.zig` prescan: implement
`hoistLeadingGlobals(gpa, args) ![][]const u8` that moves recognized
leading globals after the command word; unrecognized leading dashes fall
through to existing usage errors.

- [ ] **Step 4: Run tests to verify they pass**

Run: `zig build test 2>&1 | tail -5` then `zig build 2>&1 | tail -3`
Expected: PASS; also manually verify `./zig-out/bin/rime -v build --dry-run --manifest-path testdata/cargo/workspace/Cargo.toml` prints `Fresh`/invocation lines (level-1 rendering lands in Task 3; this step only checks the flags parse and the run starts).

- [ ] **Step 5: Commit**

```bash
jj status
jj commit src/cargo/cli.zig src/main.zig -m "Add global flags and message-format set"
```

---

### Task 3: Streaming `--message-format=json` event protocol (cargo shapes)

**Files:**
- Create: `src/cargo/msg.zig`
- Modify: `src/cargo/cli.zig` (delete `JsonEnvelope`; emit via `msg.zig`; wire `verbose`/`quiet`/`color` rendering)
- Modify: `src/cargo/root.zig` (add `pub const msg = @import("msg.zig");` + test ref)
- Test: inline tests in `src/cargo/msg.zig` (shape-exactness vs the oracle goldens from Task 8 — Task 3 writes the emitter, Task 8 commits the goldens; Task 3 tests pin field order with hand-written expected lines copied verbatim from `references/cargo/src/doc/src/reference/external-tools.md`)

**Interfaces:**
- Consumes: Task 2 `MessageFormat`/`Options`; `manifest.TargetKind`; workspace member data.
- Produces (used by Tasks 4, 6, 8):
```zig
pub const TargetJson = struct {
    kind: []const []const u8,        // ["lib"] | ["bin"] | ["example"] | ["test"] | ["bench"] (cargo vocab adds ["custom-build"]; rime never emits it — manifest.TargetKind has no such variant, build scripts are plan-level units)
    crate_types: []const []const u8, // lib/example: manifest crate-type list (default ["lib"]); others ["bin"]
    name: []const u8,                // lib target: dashes -> underscores
    src_path: []const u8,            // absolute root source file
    edition: []const u8,             // package edition, default "2021" (manifest.zig:21)
    required_features: ?[]const []const u8, // omitted (null) when empty
    doc: bool,
    doctest: bool,
    test: bool,
};
pub const ProfileJson = struct {
    opt_level: []const u8,           // "0" dev, "3" release (custom profiles: their opt-level)
    debuginfo: ?u32,                // 2 dev, 0 release... see mapping below; null = rustc default
    debug_assertions: bool,
    overflow_checks: bool,
    test: bool,                      // --test flag used (true for test/bench unit artifacts)
};
pub const ArtifactEvent = struct {
    package_id: []const u8,
    manifest_path: []const u8,       // absolute
    target: TargetJson,
    profile: ProfileJson,
    features: []const []const u8,
    filenames: []const []const u8,   // absolute view paths
    executable: ?[]const u8,         // bin/test-harness path or null
    fresh: bool,
    pub fn writeLine(self: *const ArtifactEvent, w: *std.Io.Writer) !void,
};
pub const BuildScriptEvent = struct {
    package_id: []const u8,
    linked_libs: []const []const u8,
    linked_paths: []const []const u8,
    cfgs: []const []const u8,
    env: []const [2][]const u8,      // [KEY, VALUE] pairs
    out_dir: []const u8,             // absolute
    pub fn writeLine(self: *const BuildScriptEvent, w: *std.Io.Writer) !void,
};
pub const CompilerMessageEvent = struct {
    package_id: []const u8,
    manifest_path: []const u8,
    target: TargetJson,
    message: std.json.Value,         // rustc JSON message object, embedded verbatim
    pub fn writeLine(self: *const CompilerMessageEvent, w: *std.Io.Writer) !void,
};
pub const BuildFinishedEvent = struct {
    success: bool,
    pub fn writeLine(self: *const BuildFinishedEvent, w: *std.Io.Writer) !void,
};
pub fn packageId(gpa: std.mem.Allocator, source: SourceId, name: []const u8, version: []const u8, manifest_dir_abs: []const u8) ![]u8; // path sources emit the vendored "path+file://..." spec form, never bare "file://"
pub fn targetKindStr(kind: TargetKind) []const u8;   // lib->"lib", bin->"bin", example->"example", test->"test", bench->"bench" (no custom-build: rime TargetKind has no such variant; map it to "custom-build" here if the variant lands, per manifest.rs:237)
pub fn profileJson(profile: []const u8, is_test: bool) ProfileJson; // dev/release mapping below
```

Cargo pins (normative, every field):
- `src/cargo/util/machine_message.rs` — `FromCompiler{package_id,manifest_path,target,message}` / reason `compiler-message`; `Artifact{package_id,manifest_path,target,profile,features,filenames,executable,fresh}` / reason `compiler-artifact`; `ArtifactProfile{opt_level,debuginfo,debug_assertions,overflow_checks,test}` with `ArtifactDebuginfo` int-or-`"line-directives-only"`/`"line-tables-only"`; `BuildScript{package_id,linked_libs,linked_paths,cfgs,env,out_dir}` / reason `build-script-executed`; `BuildFinished{success}` / reason `build-finished`. Wire order = struct field order (serde) — the emitter MUST serialize fields in exactly this order (hand-rolled `Stringify.value` on structs preserves declaration order).
- `src/doc/src/reference/external-tools.md` ("JSON messages" chapter) — target object keys (`kind,crate_types,name,src_path,edition,required-features?,doc,doctest,test`), profile keys, `filenames`/`executable`/`fresh` semantics (`fresh:true` = pre-existing artifacts reused, rustc NOT executed), `env` as `[KEY,VALUE]` arrays, "build-finished lets a tool know Cargo will not produce additional JSON messages, but additional output may follow (e.g. `cargo run` program output)".
- `package_id` format: registry `registry+https://github.com/rust-lang/crates.io-index#serde@1.0.229`, path `path+file:///abs/path#name@version` — the `path+` kind prefix is normative per `PackageIdSpec` Display (`crates/cargo-util-schemas/src/core/package_id_spec.rs`: `{protocol}+{url}#{name}@{version}`); the bare `file://` form never appears on the wire. Verify exact spelling in Task 8 Step 1 against the real oracle and normalize there; `packageId` implements the observed form and the Task 8 normalization step pins any deviation as a code fix, not a golden edit.

Profile mapping (M6): `dev` → `{opt_level:"0", debuginfo:2, debug_assertions:true, overflow_checks:true}`; `release` → `{"3", 0→null?, false, false}` — cargo release sets `debug:false` which serializes as `debuginfo:0`? No: `ArtifactDebuginfo` for `debug=false`… cargo's `debug=false` maps to `None` → `null` on the wire ("If `null`, it implies rustc's default of 0"). So release → `debuginfo:null`. `check` profile inherits dev mapping. `test` field: true for artifacts built with `--test` (test/bench harness binaries), else false. Custom profiles: read `opt_level`/`debug`/`debug-assertions`/`overflow-checks` from the resolved profile (M1 manifest work has `[profile.*]`; default dev/release fallback when absent).

Event stream order (normative, per cargo build order): for each unit in plan order — `compiler-message`* (rustc stderr JSON lines, in arrival order), then `compiler-artifact`, then (if the unit has a build script) `build-script-executed`; after all units, `build-finished{success}` exactly once. `fresh:true` artifacts still emit `compiler-artifact` (fresh) and cached `build-script-executed` (external-tools.md: "emitted even if the build script is not run"). On build failure: `build-finished{success:false}` then exit 101 (Task 6).

M1 removal: delete `JsonEnvelope` from `cli.zig`; update the two e2e tests in `cli.zig` (`e2e dry-run plan matches golden`, envelope unit test) to the new shapes; regenerate `testdata/cargo/golden/plan.json` in Task 8 (Task 3 marks the file stale with a `_STALE_M6` suffix comment? No — JSON has no comments. Instead: Task 3 updates `plan.json` to the new artifact lines for the workspace fixture with `fresh:true` + empty filenames? Filenames require built artifacts… For `--dry-run` (no driver yet), cargo has no dry-run; rime's `--dry-run` is an M1-only planning flag. Decision: `--dry-run` emits `compiler-artifact` lines with the unit's *predicted* filenames, `fresh:true`, `executable:null` (documented as rime-only planning output, never compared against cargo). Task 3 keeps `plan.json` byte-shape but with the new field layout; Task 8 adds the real-driver goldens.)

- [ ] **Step 1: Write the failing shape tests (expected lines copied from external-tools.md)**

```zig
test "artifact event matches cargo wire order" {
    var out: std.Io.Writer.Allocating = try .initCapacity(std.testing.allocator, 1024);
    defer out.deinit();
    const ev = ArtifactEvent{
        .package_id = "file:///ws/a#0.1.0",
        .manifest_path = "/ws/a/Cargo.toml",
        .target = .{ .kind = &.{"lib"}, .crate_types = &.{"lib"}, .name = "a", .src_path = "/ws/a/src/lib.rs", .edition = "2021", .required_features = null, .doc = true, .doctest = true, .test = true },
        .profile = .{ .opt_level = "0", .debuginfo = 2, .debug_assertions = true, .overflow_checks = true, .test = false },
        .features = &.{},
        .filenames = &.{"/ws/target/debug/deps/liba-ab12.rlib"},
        .executable = null,
        .fresh = true,
    };
    try ev.writeLine(&out.writer);
    const bytes = try out.toOwnedSlice();
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualStrings("{\"reason\":\"compiler-artifact\",\"package_id\":\"file:///ws/a#0.1.0\",\"manifest_path\":\"/ws/a/Cargo.toml\",\"target\":{\"kind\":[\"lib\"],\"crate_types\":[\"lib\"],\"name\":\"a\",\"src_path\":\"/ws/a/src/lib.rs\",\"edition\":\"2021\",\"doc\":true,\"doctest\":true,\"test\":true},\"profile\":{\"opt_level\":\"0\",\"debuginfo\":2,\"debug_assertions\":true,\"overflow_checks\":true,\"test\":false},\"features\":[],\"filenames\":[\"/ws/target/debug/deps/liba-ab12.rlib\"],\"executable\":null,\"fresh\":true}\n", bytes);
}

test "build-finished event shape" {
    var out: std.Io.Writer.Allocating = try .initCapacity(std.testing.allocator, 64);
    defer out.deinit();
    try (&BuildFinishedEvent{ .success = true }).writeLine(&out.writer);
    const bytes = try out.toOwnedSlice();
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualStrings("{\"reason\":\"build-finished\",\"success\":true}\n", bytes);
}
```

(Note: `required_features:null` serializes as `"required-features":null`? Cargo OMITS the key when unset. The struct uses `required_features: ?[]const []const u8 = null` with `std.json` omit-null? `std.json.Stringify` emits null for null optionals. To match cargo's omission, serialize `TargetJson` with a custom `jsonStringify` that skips null `required_features`. The test above pins the omission — implement `pub fn jsonStringify(self, w)` on `TargetJson` accordingly. `debuginfo:null` IS emitted (external-tools.md shows null as meaningful), so only `required_features` is omitted.)

- [ ] **Step 2: Run tests to verify they fail**

Run: `zig build test 2>&1 | tail -10`
Expected: FAIL — `msg.zig` does not exist.

- [ ] **Step 3: Write minimal implementation**

`src/cargo/msg.zig`: the seven structs + `writeLine` each emitting
`{"reason":"<kind>",...}` with `std.json.Stringify.value` in declaration
order (reason first via a wrapper struct `{reason, event...}` flattened
manually: write `"{\"reason\":\"compiler-artifact\","` then stringify the
event fields minus the trailing `}`, then `"\n"` — simplest correct
approach: define `struct { reason: []const u8, package_id: ..., ... }`
flat structs per event so field order is declaration order). `TargetJson`
gets custom `jsonStringify` omitting `required-features` when null (key
spelling uses a dash: emit manually). `packageId`: registry →
`"registry+{url}#{name}@{version}"`; path → `"file://{abs_dir}#{name}@{version}"`
(Task 8 verifies against the oracle; fix here if it differs). `root.zig`:
add re-export + test line.

- [ ] **Step 4: Replace the M1 envelope in cli.zig**

Delete `JsonEnvelope`; rewrite the unit-plan loop to emit `ArtifactEvent`
lines (`fresh:true`, predicted filenames from `view.planUnits` outputs
joined under the profile/deps dirs, `executable` set for `bin` kinds to
the profile-dir binary path, else null) and the final `build-finished`
envelope. Human rendering moves to stderr with `verbose`/`quiet`/`color`
plumbing from Task 2 (`Compiling …` lines at level 0; `Running rustc …`
invocation lines at `-v ≥ 1`). Update the two e2e tests + envelope test
to the new shapes.

- [ ] **Step 5: Run tests to verify they pass**

Run: `zig build test 2>&1 | tail -5`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
jj status
jj commit src/cargo/msg.zig src/cargo/root.zig src/cargo/cli.zig -m "Add cargo JSON event protocol"
```

---

### Task 4: run/bench/test process forwarding (Runner seam + harness invocation)

**Files:**
- Create: `src/cargo/runner.zig`
- Modify: `src/cargo/cli.zig` (`Options` gains test/run/bench selection flags; `run()` executes via `Runner`)
- Modify: `src/cargo/root.zig` (re-export + test ref)
- Test: inline tests in `src/cargo/runner.zig` (FakeRunner) + dispatch tests in `cli.zig`

**Interfaces:**
- Consumes: Task 3 events (`ArtifactEvent`, `BuildFinishedEvent`); Task 2 `JobsConfig`.
- Produces (used by Tasks 6, 8):
```zig
pub const RunOutcome = struct { term: TermTag, code: u8 };
pub const TermTag = enum { exited, signaled, spawn_failed };
pub const Runner = struct {
    ptr: *anyopaque,
    runFn: *const fn (ptr: *anyopaque, gpa: std.mem.Allocator, io: std.Io, argv: []const []const u8) RunOutcome,
};
pub const LiveRunner = struct {
    pub fn runner(self: *LiveRunner) Runner;
};
pub const FakeRunner = struct {
    expected_argv: []const []const u8,
    outcome: RunOutcome,
    calls: u32,
    pub fn runner(self: *FakeRunner) Runner;
};
pub fn selectTestBinary(filenames: []const []const u8, target_name: []const u8) ?[]const u8; // borrows the unit filename whose basename starts with "<target_name>-"; null on no match (M6: exact filename from unit filenames, never re-synthesized from profile_dir+name — the metadata hash is only known to the plan)
```

Cargo pins:
- `commands/run.rs::exec` — trailing `ARGS` forwarded verbatim; `--bin/--example` selection; `default_run` fallback; glob `-p` patterns rejected ("`cargo run` does not support glob pattern"); `to_run_error` (exit-code forwarding, see Task 6).
- `commands/test.rs::exec` — `--no-run` (compile only), `--no-fail-fast`, trailing args after `--` forwarded to the libtest harness; doctests are separate units.
- `commands/bench.rs::exec` — `BENCHNAME` positional filter + `--no-run`/`--no-fail-fast`; bench harness invoked as `<bench-binary> <BENCHNAME?> <extra_args>`.
- `src/cargo/ops/cargo_test.rs::fail_fast_code` — without `--no-fail-fast`, the harness exit code is forwarded; with it, always 101. `report_test_error` — libtest 101 is the "simple" failure (no extra context); other codes get full context + the `--no-capture` note when harness output was captured.

New `Options` fields (this task):
```zig
bin_name: ?[]const u8,        // --bin NAME
example_name: ?[]const u8,   // --example NAME
no_run: bool,                // --no-run (test/bench only; on build/check/run/clean/fetch -> Usage)
no_fail_fast: bool,          // --no-fail-fast (test/bench only)
bench_name: ?[]const u8,     // BENCHNAME positional (bench only, first positional arg)
test_filter: []const []const u8, // positional filter args for test (before --)
jobs_validated: bool,        // internal: -j validated >= 1 at first use
```

Dispatch semantics:
- `run`: select exactly one binary (named `--bin/--example`, or `default-run`, or the sole binary; >1 candidates → `error: \`cargo run\` requires …` exit 1, matching `ops::run` multi-binary error). Spawn `<profile_dir>/<name> <extra_args>` with stdio `.inherit` (passthrough, never captured — external-tools.md: program output after build-finished is NOT JSON). Return the `Runner` outcome for Task 6 mapping.
- `test`: for each test-kind unit (lib-with-harness, bins, `[[test]]`, doctests): resolve the harness path via `selectTestBinary(unit.filenames, target_name)`, then spawn `<test-binary> <test_filter…> -- <extra_args…>` stdio inherit. `--no-run` skips spawning (compile only, exit 0). First failing binary without `--no-fail-fast` stops the run and forwards its code; with `--no-fail-fast` all run, exit 101 if any failed, printing cargo's `N targets failed:\n    \`cmd\`` summary on stderr.
- `bench`: same as test but bench-kind units, invoked with `--bench` harness default args (harness path likewise via `selectTestBinary`); `BENCHNAME` filters to the named bench target (unknown name → exit 1 `error: no bench target named …`). `--no-run` compiles only.
- `-j` validation at first use: `jobs.integer < 1` → `error: --jobs must be >= 1, got {d}` exit 1; `jobs.string` → `error: --jobs <string> profiles are not resolved in M6` exit 1. (M6 executes units serially in plan order; the parsed value gates nothing else — document that `-j` is accepted-and-validated, parallelism itself is a driver-plan concern.)
- `--bin/--example` on non-run commands → Usage. Positional args on build/check/clean/fetch → Usage (`unexpected argument`).

- [ ] **Step 1: Write the failing tests**

```zig
test "fake runner records argv and returns outcome" {
    const io = std.Io.Threaded.global_single_threaded.io();
    var fake = FakeRunner{ .expected_argv = &.{ "/bin/echo", "hi" }, .outcome = .{ .term = .exited, .code = 0 }, .calls = 0 };
    const r = fake.runner();
    const got = r.runFn(r.ptr, std.testing.allocator, io, &.{ "/bin/echo", "hi" });
    try std.testing.expectEqual(@as(u8, 0), got.code);
    try std.testing.expectEqual(@as(u32, 1), fake.calls);
}

test "cli parses run selection and test flags" {
    const argv = [_][]const u8{ "rime", "run", "--bin", "tool", "--", "--hello" };
    var opts = try parseArgs(std.testing.allocator, &argv);
    defer opts.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("tool", opts.bin_name.?);
    try std.testing.expect(opts.example_name == null);
    const t = [_][]const u8{ "rime", "test", "--no-run", "--no-fail-fast", "myfilter", "--", "--nocapture" };
    var topts = try parseArgs(std.testing.allocator, &t);
    defer topts.deinit(std.testing.allocator);
    try std.testing.expect(topts.no_run and topts.no_fail_fast);
    try std.testing.expectEqualStrings("myfilter", topts.test_filter[0]);
    try std.testing.expectEqualStrings("--nocapture", topts.extra_args[0]);
}

test "cli rejects no-run on build and positional on clean" {
    const a = [_][]const u8{ "rime", "build", "--no-run" };
    try std.testing.expectError(CliError.Usage, parseArgs(std.testing.allocator, &a));
    const b = [_][]const u8{ "rime", "clean", "extra" };
    try std.testing.expectError(CliError.Usage, parseArgs(std.testing.allocator, &b));
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `zig build test 2>&1 | tail -10`
Expected: FAIL — `runner.zig` / `bin_name` / `no_run` do not exist.

- [ ] **Step 3: Write minimal implementation**

`runner.zig`: `LiveRunner.runFn` spawns with explicit inherit stdio
(the `fetch.zig` `CliGit.cliRun` / `oracle.zig` `runCapture` precedent —
never a bare `.argv` struct, which hides the passthrough contract):
```zig
var child = try std.process.spawn(io, .{ .argv = argv, .stdin = .inherit, .stdout = .inherit, .stderr = .inherit });
defer child.kill(io);
const term = child.wait(io) catch return RunOutcome{ .term = .signaled, .code = 101 };
return switch (term) {
    .exited => |c| .{ .term = .exited, .code = c },
    .signal, .stopped, .unknown => .{ .term = .signaled, .code = 101 },
};
```
(spawn error → `{ .spawn_failed, 101 }`; Task 6 renders the
signal/spawn messages). Always
`defer child.kill(io)` (oracle.zig precedent — kills nothing after clean
exit, reaps on hang). `FakeRunner.runFn` asserts argv equality elementwise
(`std.testing.expectEqualStrings` per element; mismatch → records and
returns spawn_failed so tests fail loudly) and returns the canned outcome.
`cli.zig`: new flags (`--bin/--example` with values, `--no-run`,
`--no-fail-fast`, bench positional capture: first non-flag positional on
`bench` → `bench_name`, on `test` → appended to `test_filter`; positionals
elsewhere → `fail("unexpected argument …")`). `run()` threads an optional
`Runner` (default live; tests inject fake via a new `runWith` entry:
`pub fn run(...) u8 { var live = LiveRunner{}; return runWith(..., live.runner()); }`).

- [ ] **Step 4: Run tests to verify they pass**

Run: `zig build test 2>&1 | tail -5`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
jj status
jj commit src/cargo/runner.zig src/cargo/root.zig src/cargo/cli.zig -m "Add run test bench process forwarding"
```

---

### Task 5: clean variants + target selection (`-p` repeatable, `--workspace`, `--target`, `--target-dir`, `--doc`, `--dry-run`)

**Files:**
- Modify: `src/cargo/cli.zig` (`Options.packages: []const []const u8` added alongside `only_package` — the field is kept and parser-maintained as `packages[0]`-or-null so `view.planUnits` callers are untouched, plus an `onlyPackage()` accessor for new call sites; clean selection logic)
- Modify: `src/cargo/view.zig` (`clean` gains selection: `CleanSpec`)
- Test: inline tests in both files

**Interfaces:**
- Consumes: Task 4 `Options`; `view.layoutPaths/profileDirName`.
- Produces (used by Task 6):
```zig
pub const CleanSpec = struct {
    packages: []const []const u8, // -p/--package, repeatable (empty = all when workspace=true or single)
    workspace: bool,              // --workspace
    profile: ?[]const u8,         // explicit --release/--profile only
    target: ?[]const u8,          // --target triple subdir
    target_dir: ?[]const u8,      // --target-dir override root
    doc_only: bool,               // --doc: remove target/doc only
    dry_run: bool,                // --dry-run: print paths, delete nothing
};
pub fn cleanSpec(opts: *const Options) CleanSpec;  // pure projection, no alloc
pub fn cleanWithSpec(gpa: std.mem.Allocator, io: std.Io, ws_root: []const u8, spec: CleanSpec, stderr: *std.Io.Writer) ViewError!void;
```

Cargo pins: `commands/clean.rs::cli` — `-p/--package SPEC` (multi,
`PACKAGE_SELECTION` heading), `--workspace`, `--release`/`--profile`,
`--target`, `--target-dir`, `--manifest-path`, `--dry-run`, `--doc`
("Whether or not to clean just the documentation directory"). Per-package
clean removes that package's artifacts; `--dry-run` lists without deleting.

Behavior contract:
- `-p` repeatable on clean AND build-like commands (cargo allows `-p` multi on all; M1 allowed one). `Options.packages` is the owned list; the `only_package` FIELD is kept (parser-maintained as `packages[0]`-or-null) with an `onlyPackage()` accessor, so existing `planUnits` call sites compile unchanged. (Task 7 of the driver plan generalizes `-p` to full selection; M6 keeps single-plan semantics and documents it).
- clean without `-p` on a workspace root → Usage exit 1 naming `--workspace` (cargo requires `--workspace` or `-p` explicitly for workspaces; on a single-package project it cleans that package). With `--workspace` → whole view. With `-p A -p B` → remove `deps/` artifacts whose filename contains the package's lib/bin target names + their `.fingerprint/<target>-*` dirs; never whole-profile removal.
- `--target T` scopes removal to `target/<profile>/<T>/`? Cargo layout: `target/<triple>/<profile>/` when `--target` is passed. M6 `layoutPaths` gains no change; `cleanWithSpec` computes the triple-prefixed dir (`target/<triple>/<profile_dir>`) and removes only it. Document the divergence risk: driver-plan target layout must match this exact prefix order (covered by a Task 8 golden).
- `--target-dir D` replaces `<ws>/target` as the view root for the clean.
- `--doc` removes `<view>/doc` only. `--dry-run` prints `Removing <abs path>` lines to stderr (cargo prints `Removing …` per path) and deletes nothing; combine with any selection.
- `clean -p` on unknown package → exit 1 `error: package not found: {s}` (same wording as the build-plan path).

- [ ] **Step 1: Write the failing tests**

```zig
test "cli parses repeatable clean selection" {
    const argv = [_][]const u8{ "rime", "clean", "-p", "a", "--package", "b", "--workspace", "--target", "x86_64-unknown-linux-gnu", "--dry-run" };
    var opts = try parseArgs(std.testing.allocator, &argv);
    defer opts.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), opts.packages.len);
    try std.testing.expect(opts.workspace);
    try std.testing.expectEqualStrings("x86_64-unknown-linux-gnu", opts.target_triple.?);
    try std.testing.expect(opts.dry_run);
}

test "clean dry-run lists without deleting" {
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const ws_root = try tmp.dir.realPathFileAlloc(io, ".", std.testing.allocator);
    defer std.testing.allocator.free(ws_root);
    // seed a fake view
    var root = try std.Io.Dir.cwd().openDir(io, ws_root, .{});
    defer root.close(io);
    try root.createDirPath(io, "target/debug/deps");
    try root.writeFile(io, .{ .sub_path = "target/debug/deps/liba-ab12.rlib", .data = "x" });
    var err: std.Io.Writer.Allocating = try .initCapacity(std.testing.allocator, 512);
    defer err.deinit();
    try cleanWithSpec(std.testing.allocator, io, ws_root, .{ .packages = &.{}, .workspace = true, .profile = null, .target = null, .target_dir = null, .doc_only = false, .dry_run = true }, &err.writer);
    // file survives dry-run
    try tmp.dir.statFile(io, "target/debug/deps/liba-ab12.rlib", .{});
    const msg = try err.toOwnedSlice();
    defer std.testing.allocator.free(msg);
    try std.testing.expect(std.mem.indexOf(u8, msg, "Removing") != null);
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `zig build test 2>&1 | tail -10`
Expected: FAIL — `packages`/`workspace`/`cleanWithSpec` do not exist.

- [ ] **Step 3: Write minimal implementation**

`Options.packages` (`ArrayList` in parser, `deinit` frees; the `only_package`
field is kept and set to `packages[0]`-or-null at parse end; add
`pub fn onlyPackage(self: *const Options) ?[]const u8 { return self.only_package; }`
for new call sites — the existing `opts.only_package` uses in `run()` stay as-is). Remove `-p` from
`isCleanOnlyReject` (keep `--features/--target/--dry-run` rejected? No —
`--target` and `--dry-run` are now VALID on clean; shrink the reject list
to `--features` only, which clean never takes in cargo). Add `--workspace`,
`--doc`, `--target-dir` flags (clean + build-like accept `--target-dir`;
it overrides the view root for materialization too). `view.cleanWithSpec`:
resolve view root (`target_dir orelse ws/target`), dry-run prints
`Removing {abs}` per selected path; package selection deletes matching
`deps/*<target>*` + `.fingerprint/<target>-*`; workspace/null deletes
profile dir or whole view (existing `clean` behavior preserved underneath).

- [ ] **Step 4: Run tests to verify they pass**

Run: `zig build test 2>&1 | tail -5`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
jj status
jj commit src/cargo/cli.zig src/cargo/view.zig -m "Add clean variants and package selection"
```

---

### Task 6: Exit-code matrix (exactly per cargo)

**Files:**
- Modify: `src/cargo/cli.zig` (`runWith` return paths; `format_error` mapping; quiet `to_run_error` rule)
- Modify: `src/main.zig` (clap-error class mapping for routing/usage paths)
- Test: inline matrix tests in `src/cargo/cli.zig` (every row executed, asserting the code)

**Interfaces:**
- Consumes: Tasks 1–5 (`Runner`, `RunOutcome`, events, `format_error` flag).
- Produces (used by Task 8 oracle tests):
```zig
pub const ExitCode = struct {
    pub const ok: u8 = 0;
    pub const usage: u8 = 1;
    pub const build_failed: u8 = 101;
};
```

Cargo pins (each row normative):
- `src/cargo/util/errors.rs` — `From<anyhow::Error> for CliError` → **101**; `From<clap::Error>` → `use_stderr() ? 1 : 0` (parse errors exit 1, `--help` exits 0); `From<io::Error>` → **1**.
- `src/cargo/lib.rs::exit_with_error` — prints the error chain, exits with the code; `--help`/`--version` print and exit 0.
- `commands/run.rs::to_run_error` — `ProcessError` with a code forwards that code; spawn failure (no code) → 101; `-q` suppresses the extra error text (`CliError::code`, message assumed printed by the child).
- `src/cargo/ops/cargo_test.rs::fail_fast_code` — test/bench binary code forwarded without `--no-fail-fast`; `--no-fail-fast` with any failure → always 101 with the `N targets failed` summary. `report_test_error` — code 101 from libtest is "simple" (no extra context); abnormal codes print full context + the `--no-capture` note for harness units.
- `commands/verify_project.rs::exec` — invalid manifest → stdout JSON + `process::exit(1)` (informative: rime has no verify-project, but the row documents that manifest errors are exit 1, consistent with the matrix).

Matrix (implement + test every row):

| # | Situation | Code | Message destination |
|---|---|---|---|
| 1 | success (any command) | 0 | normal output |
| 2 | unknown command / unknown flag / bad flag value / `--help` misuse | 1 | `error: …` stderr |
| 3 | `--help` / `--version` | 0 | help/version stdout |
| 4 | no workspace / bad manifest / unknown `-p` name | 1 | `error: …` stderr |
| 5 | message-format conflict or invalid specifier | 101 | `error: …` stderr (anyhow class) |
| 6 | compile failure (any unit) | 101 | rustc JSON via `compiler-message` + `build-finished{"success":false}` |
| 7 | `run`: child exits N | N | child stdio passthrough; non-quiet adds `error: …` context, quiet adds nothing |
| 8 | `run`: spawn failure / signaled | 101 | `error: failed to spawn …` / `error: process terminated by signal` |
| 9 | `test`/`bench`: harness exits N (fail-fast) | N | harness stdio passthrough; N=101 is "simple", others get full context + `--no-capture` note |
| 10 | `test`/`bench` `--no-fail-fast`, ≥1 failure | 101 | `N targets failed:` summary stderr |
| 11 | `test`/`bench` `--no-run` (compile ok) | 0 | no harness spawned |
| 12 | store full on cache write | 0 or 101 per the build outcome | `Store.lastFull()` breakdown verbatim on stderr; cache-write pressure NEVER fails a build by itself (storage-v2 §10.4) |
| 13 | `--frozen/--locked` without lockfile (registry deps present) | 1 | existing M1 wording kept |
| 14 | `--locked`/`--frozen` stale lock (lockfile create/update refused) | 101 | `error: cannot … because --locked was passed…` stderr (anyhow class per `ops/lockfile.rs:63` → `errors.rs:344-345`; Suite B asserts rime == real cargo on a stale-lock fixture) |

- [ ] **Step 1: Write the failing matrix tests**

```zig
test "exit matrix: usage errors are 1, format errors are 101" {
    const io = std.Io.Threaded.global_single_threaded.io();
    var err: std.Io.Writer.Allocating = try .initCapacity(std.testing.allocator, 512);
    defer err.deinit();
    var out: std.Io.Writer.Allocating = try .initCapacity(std.testing.allocator, 64);
    defer out.deinit();
    // Row 4: clean outside a workspace -> 1
    {
        const argv = [_][]const u8{ "rime", "clean", "--manifest-path", "/nonexistent-dir-xyz/Cargo.toml" };
        var opts = try parseArgs(std.testing.allocator, &argv);
        defer opts.deinit(std.testing.allocator);
        err.clearRetainingCapacity();
        const code = runWith(std.testing.allocator, io, opts, &out.writer, &err.writer, (FakeRunner{ .expected_argv = &.{}, .outcome = .{ .term = .exited, .code = 0 }, .calls = 0 }).runner());
        try std.testing.expectEqual(@as(u8, 1), code);
    }
    // Row 4 asserts above; row 7 (run forwarding) is pinned by the next test.
}

test "exit matrix: run forwards child exit code 42" {
    const io = std.Io.Threaded.global_single_threaded.io();
    const argv = [_][]const u8{ "rime", "run", "--manifest-path", "validation/basic-workspace/Cargo.toml" };
    var opts = try parseArgs(std.testing.allocator, &argv);
    defer opts.deinit(std.testing.allocator);
    var out: std.Io.Writer.Allocating = try .initCapacity(std.testing.allocator, 64);
    defer out.deinit();
    var err: std.Io.Writer.Allocating = try .initCapacity(std.testing.allocator, 512);
    defer err.deinit();
    // validation/basic-workspace exposes a single binary (cli-bin): sole-binary
    // selection resolves to the default dev profile dir with no build step.
    const want_bin = "validation/basic-workspace/target/debug/cli-bin";
    var fake = FakeRunner{ .expected_argv = &.{want_bin}, .outcome = .{ .term = .exited, .code = 42 }, .calls = 0 };
    const code = runWith(std.testing.allocator, io, opts, &out.writer, &err.writer, fake.runner());
    try std.testing.expectEqual(@as(u8, 42), code);
    try std.testing.expectEqual(@as(u32, 1), fake.calls);
}

test "exit matrix: run forwards child exit code" {
    // FakeRunner returns 42; runWith on a pure-path workspace maps row 7 -> 42.
    // (Full wiring in Step 3; this test pins the mapping function directly.)
    try std.testing.expectEqual(@as(u8, 42), mapRunOutcome(.{ .term = .exited, .code = 42 }, false));
    try std.testing.expectEqual(@as(u8, 101), mapRunOutcome(.{ .term = .spawn_failed, .code = 0 }, false));
    try std.testing.expectEqual(@as(u8, 101), mapRunOutcome(.{ .term = .signaled, .code = 0 }, false));
}

test "exit matrix: test fail-fast vs no-fail-fast" {
    try std.testing.expectEqual(@as(u8, 3), mapTestOutcome(&.{.{ .term = .exited, .code = 3 }}, false));
    try std.testing.expectEqual(@as(u8, 101), mapTestOutcome(&.{.{ .term = .exited, .code = 3 }}, true));
    try std.testing.expectEqual(@as(u8, 0), mapTestOutcome(&.{.{ .term = .exited, .code = 0 }}, true));
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `zig build test 2>&1 | tail -10`
Expected: FAIL — `runWith`/`mapRunOutcome`/`mapTestOutcome` do not exist.

- [ ] **Step 3: Write minimal implementation**

Consume the Task 2 `format_error`/`format_diagnostic` fields: `runWith`
checks them FIRST and
returns 101 after printing the stored diagnostic (row 5 — this is why the
fields live on the parse side, not in `CliError`). Add pure mapping
functions `mapRunOutcome(outcome, quiet)` and
`mapTestOutcome(outcomes, no_fail_fast)` implementing rows 7–10 exactly
(quiet only suppresses the extra context print, never changes the code).
Refactor `run()` into `runWith(gpa, io, opts, stdout, stderr, runner)` +
`run(...)` injecting `LiveRunner` (Task 4 already introduced this split —
this task fills the return-code paths: build failure → emit
`build-finished{success:false}` then 101; `run` → `mapRunOutcome`;
`test`/`bench` → `mapTestOutcome` + summary rendering). `run` binary
selection reads manifest `[[bin]]`/autobin targets (sole binary,
`default-run`, or `--bin`/`--example` match — no build step before spawn):
dev profile resolves to `<ws>/target/debug/<name>` (target-dir/`--target`
prefixed per Task 5), so the row-7 test's `validation/basic-workspace`
sole binary `cli-bin` spawns exactly
`validation/basic-workspace/target/debug/cli-bin`. `main.zig`:
`--help`/`--version` (add both: `--version` prints `rime <version>` exit 0;
per-command `--help` prints the command help exit 0) and clap-class
routing errors stay exit 1.

- [ ] **Step 4: Run tests to verify they pass**

Run: `zig build test 2>&1 | tail -5`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
jj status
jj commit src/cargo/cli.zig src/main.zig -m "Add cargo exit-code matrix"
```

---

### Task 7: `rime gc` / `rime cache stat` interop help text

**Files:**
- Modify: `src/main.zig` (help text for `gc`, `cache stat`, `clean` cross-pointers)
- Test: snapshot tests in `src/main.zig` (exact-text assertions on the help strings)

**Interfaces:**
- Consumes: existing `GcOpts`/`StatOpts` in `main.zig`; Task 5 `CleanSpec` doc flag.
- Produces: no new API (help text only); Task 8 snapshot discipline covers it.

Cargo pin: `commands/clean.rs` hidden `clean gc` subcommand (never shown in help listings — cargo deliberately hides global-cache GC from the build surface). rime inverts this invisibility into a pointer: `rime clean --help` ends with `See 'rime gc --help' for global-cache collection.` and `rime gc --help` ends with `Does not touch project target/ views; use 'rime clean' for those.` (storage-v2 §7.4: GC never deletes views; `cargo clean` equivalence = views only).

Help-text contract (snapshot-discipline, see Task 8): the six cargo-command helps paraphrase cargo's `about` lines (NOT verbatim — different binary, different capabilities; each carries a `Note: rime implements the <cmd> build surface; <divergence>` trailer). The `gc`/`cache stat` helps are rime-native and pinned verbatim by snapshot tests in this task.

- [ ] **Step 1: Write the failing snapshot tests**

```zig
test "gc help points at clean and stat" {
    const text = gcHelp();
    try std.testing.expect(std.mem.indexOf(u8, text, "rime clean") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Does not touch project target/ views") != null);
}

test "clean help points at gc" {
    const text = cargoCleanHelp();
    try std.testing.expect(std.mem.indexOf(u8, text, "rime gc --help") != null);
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `zig build test 2>&1 | tail -10`
Expected: FAIL — `gcHelp`/`cargoCleanHelp` do not exist.

- [ ] **Step 3: Write minimal implementation**

```zig
pub fn gcHelp() []const u8 {
    return
        \\Collect unrooted objects from the global store.
        \\
        \\Usage: rime gc [--dry-run] [--to-size BYTES] [--older-than DUR] [--tag K=V ...]
        \\
        \\Does not touch project target/ views; use 'rime clean' for those.
        \\See 'rime cache stat --by-tag' for per-tag usage.
        \\
    ;
}

pub fn cargoCleanHelp() []const u8 {
    return
        \\Remove artifacts that rime has generated in the past.
        \\
        \\Usage: rime clean [-p PKG ...] [--workspace] [--release|--profile N] [--target TRIPLE] [--target-dir DIR] [--manifest-path P] [--doc] [--dry-run]
        \\
        \\Removes only project target/ views, never store state.
        \\See 'rime gc --help' for global-cache collection.
        \\
    ;
}
```

Wire `--help` for `gc`, `cache stat`, `clean`, and each cargo command to
these strings (+ six analogous `cargo<Cmd>Help` strings for
build/check/test/run/bench/fetch, each ending with its divergence trailer,
e.g. build: `Note: rime executes the cargo unit plan via the global store;
parallelism (-j) is accepted and validated but units run in plan order.`).
`--help` exits 0 (matrix row 3).

- [ ] **Step 4: Run tests to verify they pass**

Run: `zig build test 2>&1 | tail -5`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
jj status
jj commit src/main.zig -m "Add gc clean help interop text"
```

---

### Task 8: Validation design — golden JSON streams, exit matrix, snapshot discipline

**Files:**
- Create: `validation/m6-golden/` (committed fixtures + goldens + `regen.sh` + `README.md`)
- Modify: `testdata/cargo/golden/plan.json` (regenerate in Task 3 shapes)
- Modify: `src/cargo/oracle.zig` (add `m6` comparison helpers) or new `src/cargo/oracle_m6.zig` (prefer new file; `root.zig` re-export)
- Test: oracle-gated tests (`RIME_CARGO_ORACLE=1`, skipped otherwise — the `oracleEnabled()` precedent)

**Interfaces:**
- Consumes: Tasks 1–7 (full CLI); `oracle.cargoAvailable/oracleEnabled`.
- Produces: the M6 acceptance evidence (goldens + green oracle run).

Cargo pins: `src/doc/src/reference/external-tools.md` (event shapes — the goldens must validate against these field orders); `validation/oracle.sh` + `validation/README.md` (existing oracle conventions: `@VALIDATION_ROOT@` normalization, committed goldens, `cargo 1.99.0-nightly` toolchain).

Validation design (three suites):

**Suite A — golden JSON-stream tests vs real cargo.** For each `validation/` corpus project that builds (`basic-workspace`, `lockfile-golden`, `full-manifest`):
1. Run `cargo build --message-format=json` (oracle) and `rime build --message-format=json` in a scratch copy (never in the corpus dir — views are regenerable but goldens must not be dirtied).
2. Normalize volatile fields on BOTH sides before diffing: absolute paths → `@VALIDATION_ROOT@` (existing `normalize()` in `oracle.sh`), `filenames` hashes (`libfoo-<meta>` → `libfoo-<META>`), `out_dir` build-script counters, `fresh` (`true` on warm rebuilds — goldens pin the FRESH run: cold store + cold target), timing-adjacent fields. The normalization script (`normalize.py`, committed) lists every substitution with the reason; any diff line NOT covered by a listed substitution is a failure.
3. Compare event-by-event: same reason sequence, same `package_id`s, same target shapes, same profile shapes. `filenames` compare post-normalization. Extra rime-only events → failure (no auxiliary events on the JSON wire, ever).
4. `RIME_CARGO_ORACLE=1 zig build test -- --test-filter m6-oracle` runs Suite A; without the gate the tests skip with a printed `skip: set RIME_CARGO_ORACLE=1 for oracle comparison` (never fail offline).

**Suite B — exit-code matrix tests.** A committed table (`exit-matrix.json`: argv + fixture + expected code + expected stderr needle) executed against the built `rime` binary AND the real `cargo` on the same fixture; the test asserts rime's code equals cargo's code for every row (rows 1–14 from Task 6). The table MUST include a `--locked` stale-lock case (fixture whose lockfile needs create/update) asserting rime == cargo; the committed expected code is 101 per the anyhow class (`ops/lockfile.rs:63` → `errors.rs:344-345`), and any oracle disagreement is resolved in favor of the oracle with a code fix, never a matrix edit. Child-code rows use fixture binaries with fixed exit codes (`std::process::exit(42)`); signal rows use `kill -TERM` on a sleeping fixture (POSIX only, gated to macOS/Linux like the rest of rime).

**Suite C — help-text snapshot discipline.** Rule: cargo-command help text must NEVER be byte-compared against cargo's help (different binary, intentional divergence trailers) — snapshot tests pin rime's own strings (Task 7) and fail on any edit, forcing a conscious help-text review per diff. What MUST match cargo verbatim: `--message-format` value spellings, `--color` value spellings, `error: …` message wordings cited from cargo sources (each with its file:line comment), exit codes. What MUST differ: program name (`rime` not `cargo`), the `unit-plan`/`--dry-run` planning output (rime-only, documented), `.rime-view.json`/`last-build.json` view metadata (rime-only).

`regen.sh` regenerates goldens with the pinned toolchain and fails if `cargo --version` is not `1.99.0-nightly`; goldens are committed; CI runs Suites A+B with the gate on and Suite C always.

- [ ] **Step 1: Verify package_id spelling against the real oracle**

Run: `cargo metadata --format-version 1 --manifest-path validation/basic-workspace/Cargo.toml | python3 -c "import json,sys; [print(p['id']) for p in json.load(sys.stdin)['packages'][:5]]"`
Expected: registry ids look like `registry+https://github.com/rust-lang/crates.io-index#anyhow@1.0.104` and path ids like `path+file:///@VALIDATION_ROOT@…` — record the EXACT observed forms in `validation/m6-golden/README.md` and fix `msg.packageId` in this step if it differs (code fix, never golden edit).

- [ ] **Step 2: Write the oracle tests (skipped without the gate)**

```zig
test "m6-oracle json stream matches cargo on basic-workspace" {
    if (!oracleEnabled() or !cargoAvailable()) {
        std.debug.print("skip: set RIME_CARGO_ORACLE=1 for oracle comparison\n", .{});
        return;
    }
    try compareJsonStream(std.testing.allocator, "validation/basic-workspace", &.{"build"});
}

test "m6-oracle exit matrix matches cargo" {
    if (!oracleEnabled() or !cargoAvailable()) {
        std.debug.print("skip: set RIME_CARGO_ORACLE=1 for oracle comparison\n", .{});
        return;
    }
    try checkExitMatrix(std.testing.allocator, "validation/m6-golden/exit-matrix.json");
}
```

- [ ] **Step 3: Run tests to verify they skip-then-pass**

Run: `zig build test -- --test-filter m6-oracle 2>&1 | tail -5`
Expected: SKIP lines, suite green. Then: `RIME_CARGO_ORACLE=1 timeout 300 zig build test -- --test-filter m6-oracle 2>&1 | tail -5`
Expected: PASS (goldens committed in Step 4 make it pass; any mismatch is fixed in `msg.zig`/`cli.zig`, never by editing goldens by hand — goldens change only via `regen.sh` + `jj commit`).

- [ ] **Step 4: Commit goldens + harness**

```bash
jj status
jj commit validation/m6-golden src/cargo/oracle_m6.zig testdata/cargo/golden/plan.json -m "Add M6 oracle goldens and harness"
```

---

### Task 9: End-to-end CLI smoke (`rime` binary over `testdata/` + `validation/` scratch copies)

**Files:**
- Modify: none (verification task; fixes land as follow-up commits to the owning task's files)
- Test: manual command transcript, recorded in the commit message trailer

**Interfaces:**
- Consumes: Tasks 1–8 (complete M6 CLI).
- Produces: release confidence (no new API).

- [ ] **Step 1: Build and run the full surface on scratch copies**

Run:
```bash
zig build 2>&1 | tail -2
RIME_BIN="$PWD/zig-out/bin/rime"
TMP=$(mktemp -d); cp -r validation/basic-workspace $TMP/w; cd $TMP/w
RIME_CACHE_DIR=$TMP/store "$RIME_BIN" build --message-format=json
echo "build exit: $?"
RIME_CACHE_DIR=$TMP/store "$RIME_BIN" clean --dry-run
RIME_CACHE_DIR=$TMP/store "$RIME_BIN" clean
RIME_CACHE_DIR=$TMP/store "$RIME_BIN" gc --dry-run
RIME_CACHE_DIR=$TMP/store "$RIME_BIN" cache stat
cd /; rm -rf $TMP
```
Expected: build prints cargo-shaped JSON lines on stdout only; `clean --dry-run` lists `Removing …` and deletes nothing; `clean` removes `target/`; `gc --dry-run` reports without deleting; `cache stat` prints budget lines. Every stderr line starts with a known prefix (`Compiling`, `Finished`, `error:`, `Removing`, `warning:`) — stray output is a bug.

- [ ] **Step 2: Verify failure paths**

Run: `zig-out/bin/rime build --warp-drive` (exit 1, names the flag); `zig-out/bin/rime --help` (exit 0); `zig-out/bin/rime build --manifest-path /nonexistent/Cargo.toml` (exit 1, `could not find`); `zig-out/bin/rime build --message-format=json,human --manifest-path testdata/cargo/workspace/Cargo.toml` (exit 101).
Expected: all four codes exact.

- [ ] **Step 3: Commit any fixes under the owning task, then close**

```bash
jj status
jj diff --stat
```
Expected: no stray files (`*.fresh`, `*.diff`, `.oracle.*` are never committed — `validation/.gitignore` covers them; check `jj status` is clean of scratch output).

---

## Self-review

**1. Spec coverage.** Every M6 objective from the task brief maps to a task:
(1) command surface → Task 1 (fetch wiring) + Task 5 (clean variants) + §0 scope table (explicit IN/OUT per `references/cargo/src/bin/cargo/commands/**`);
(2) JSON event protocol → Task 3 (`machine_message.rs` + external-tools.md shapes);
(3) run/bench/test forwarding → Task 4 (Runner seam, harness invocation, `-j` validation);
(4) clean variants → Task 5 (`clean.rs` selection surface);
(5) global flags → Task 2 (`cli.rs` globals + `command_prelude.rs` jobs/message-format);
(6) exit-code matrix → Task 6 (`lib.rs`/`errors.rs`/`run.rs`/`cargo_test.rs` rows);
(7) gc/cache-stat interop help → Task 7.
Validation design (goldens, matrix, snapshot discipline) → Task 8; e2e smoke → Task 9.

**2. Placeholder scan.** No TBD/TODO/later; every step names exact files,
exact code, exact commands, exact expected output. Error handling is
specified per call (`catch return ViewError…`, `defer child.kill(io)`,
`errdefer` on reservations of owned slices). Edge cases are tests, not
prose (bad color, `-C`, format conflicts, unknown bench name, dry-run
no-delete, signal/spawn-failure rows).

**3. Type consistency.** `Options` grows monotonically Tasks 1→2→4→5
(fields listed per task; `only_package` field kept (parser-maintained) plus
`onlyPackage()` accessor in Task 5, so `view.planUnits` call sites compile unchanged). `Runner`/`RunOutcome`
( Task 4) are consumed by name in Tasks 6 and 8. `CleanSpec`/`cleanSpec`/
`cleanWithSpec` (Task 5) consumed by name in Task 6's matrix rows. Event
types (Task 3) are the exact writer types Tasks 4/6/8 compare. `MessageFormat`
six-variant enum (Task 2) is the same type Task 3 matches on — no rename
between tasks.
