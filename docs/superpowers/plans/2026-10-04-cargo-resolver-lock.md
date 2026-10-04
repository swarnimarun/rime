# Plan C M3 — Resolver + Lock Write Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:delegate (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build rime's `resolve.zig` so it produces IDENTICAL resolution results to cargo for the same inputs (sparse-index metadata as cargo consumes it, broad `Cargo.toml` surface, features, config) and writes byte-stable `Cargo.lock` v4 (v3/v2/v1 read-compat) identical to cargo's writer — proven per validation project against cargo-committed goldens.

**Architecture:** A pure, deterministic resolution core (`semver` → `index` → `resolve` → `features`, all std-only, no FS, no network) sits behind a thin `Registry` seam fed in production by M2's fetcher and in tests by JSON stub indexes; the lock writer (`lock.zig` extensions) serializes the resulting graph with cargo's exact edge-shortening, field order, and version-bump rules. Conformance is enforced by an oracle harness that runs the real `cargo` binary on the same fixtures and byte-compares outputs.

**Tech Stack:** Zig 0.16.0 exactly, std only (no new dependencies). Inline `test "…"` blocks; `zig build test` green before every commit.

**Spec:** `docs/superpowers/plans/2026-10-04-cargo-frontend.md` §0 (M3 sketch) + M1 Tasks 1–3 (`toml.zig`, `manifest.zig`, `lock.zig` read/round-trip — already implemented, extended here); normative reference is cargo's own source vendored at `references/cargo` (tag 0.99.0). Every algorithm below cites the exact pinning function.

## Global Constraints

- Zig **0.16.0** exactly. FS access goes through the `std.Io` interface value passed as `io`; `std.Io.Dir`/`std.Io.File` methods take `io` (copy call sites from the storage-core plan exactly).
- Dependencies: **std only**. No packages in `build.zig.zon`, no C sources.
- Tests are inline (`test "…"` blocks). `zig build test` must pass before **every** commit. Never commit with failing tests.
- `std.ArrayList(T)` is unmanaged in 0.16: `var l: std.ArrayList(T) = .{}; try l.append(gpa, x); defer l.deinit(gpa); const s = try l.toOwnedSlice(gpa);`.
- Cargo-compat invariants after every task: resolution results and lockfile bytes match cargo; exit codes match cargo (frontend plan §2.1/D4: `0` ok, `101` build failure, `1` usage/config).
- All VCS operations use **jj**: `jj status`, `jj diff`, `jj commit <paths> -m "…"`. Never run git write commands. One logical change per commit, imperative ≤50-char summaries.
- Scratch experiments go in `/tmp`, never in the repo.
- Conformance testing uses the locally installed real cargo (`cargo 1.99.0-nightly`); oracle tests must skip gracefully (not fail) when `cargo` is absent from `PATH`.

---

## 0. Algorithm notes — which cargo functions pin which semantics

Read these before implementing; each task cites them again at the point of use.

### 0.1 Resolution core (`references/cargo/src/cargo/core/resolver/`)

- `mod.rs::resolve()` — entry point; builds `RegistryQueryer`, runs `activate_deps_loop` to fixpoint (`registry.wait()`), then builds `Resolve` from `resolver_ctx.activations` + `graph()`, then `check_cycles` + `check_duplicate_pkgs_in_lockfile`.
- `mod.rs::activate_deps_loop()` — THE algorithm. Iterative DFS with an explicit `backtrack_stack` and `RemainingDeps`. Loop: `remaining_deps.pop_most_constrained()` picks the dependency with the fewest candidates (fail-fast heuristic); tries candidates in `sort_summaries` order (highest version first by default); on conflict, backtracks to the newest decision that participates in the conflict (conflict-directed jump-back via `ConflictCache`). First complete resolution wins; only total exhaustion returns `ResolveError`.
- `context.rs::ResolverContext` — `activations: Map<Name, Vec<(Summary, Age)>>` (one entry per semver-incompatible version coexisting), `graph: Graph<PackageId, HashSet<Dependency>>`, `flag_activated()` (records which parent+dep activated a version — feeds conflict reasons), `is_active() -> Option<ContextAge>`, `is_conflicting()` (same-links or semver-compatible duplicate check).
- `conflict_cache.rs::ConflictCache` — trie of known-conflicting activation sets; `find(is_active, must_contain)` returns a stored conflict that is a subset of current activations so the resolver can skip re-exploring it and jump back past irrelevant decisions. rime MUST implement at least the semantic (skip known-bad sets); the trie is a performance optimization but the jump-back *behavior* (which error surfaces) is user-visible in large graphs, so implement the trie, not just a list.
- `types.rs::ResolveBehavior::from_manifest()` — `"1"|"2"|"3"` → `V1|V2|V3`; `ResolveOpts{dev_deps, features}`; `RemainingDeps::pop_most_constrained`; `DepsFrame`; `FeaturesSet = Rc<BTreeSet<InternedString>>`.
- `dep_cache.rs::RegistryQueryer::query()` — candidate filtering, THE yanked rule: `IndexSummary::Yanked` candidates are dropped UNLESS `version_prefs.should_prefer(pkg_id)` (i.e. pinned by previous lockfile or `[patch]`) or `source_id.precise_registry_version()` matches (i.e. `--precise` named it). `too_new` (min-publish-age) candidates are likewise dropped unless preferred. `[replace]` overrides applied here (error on multiple/ambiguous matches).
- `version_prefs.rs::VersionPreferences::sort_summaries()` — candidate order, THE priority: (1) preferred (previous-lock ids, patch deps) first; (2) rust-version compatibility count (`msrv_compat_count`: summaries whose `rust-version` is compatible with MORE of the workspace's rust versions sort first; summaries with no `rust-version` count as fully compatible); (3) version, descending (`MaximumVersionsFirst`) or ascending (`MinimumVersionsFirst` when `-Zminimal-versions` / `direct_minimal_versions`). Plus `publish_time` pre-filter (`retain`). Plus: when `first_version` is `Some` (only for `-Zdirect-minimal-versions`), `split_off(1)` keeps ONLY the first candidate.
- `version_prefs.rs::should_prefer()` — `try_to_use.contains(pkg_id)` OR any `prefer_patch_deps[name]` dependency `matches_id(pkg_id)`.
- `resolve.rs::ResolveVersion` — `default() == V4`; `with_rust_version(rust_version)`: returns V4 unless the workspace's lowest `rust-version` is older than the V4 floor (then V3/V2/V1 — see `resolve.rs:124-148`, the floor constants live there, copy them verbatim); `max_stable() == V4`; `merge_from(previous)` (carries `metadata` + unused patches forward).
- `resolve.rs::check_cycles`, `check_duplicate_pkgs_in_lockfile` — resolution is an error if the graph has a cycle or two identical `PackageId`s.

### 0.2 Versions (`references/cargo/src/cargo/util/semver_ext.rs`, `semver_eval_ext.rs`, `core/dependency.rs`)

- `OptVersionReq` enum: `Any` (`*`), `Req(VersionReq)`, `Locked(Version, VersionReq)` (previous-lock pinning: matches by full `==` INCLUDING build metadata — reproducibility over semver-metadata-ignorance), `Precise(Version, VersionReq)` (`cargo update --precise`: matches major/minor/patch/pre exactly, and build metadata only if the precise request names it).
- `OptVersionReq::lock_to()` — asserts the locked version matches the original req first (`assert!(self.matches(version))`); `Any.lock_to(v)` keeps `VersionReq::STAR` as the shadow req.
- `OptVersionReq::matches()` — `Any => true`; `Req => req.matches(version)` (the `semver` crate's stock matching: **prereleases are excluded** unless the req itself contains a prerelease comparator on the same `major.minor.patch`); `Locked => v == version`.
- `semver_eval_ext::matches_prerelease()` (RFC 3493, used for `--precise <prerelease>`): per-comparator prerelease-aware matching (`Exact|Wildcard → matches_exact_prerelease`, `Greater/GreaterEq/Less/LessEq/Tilde/Caret` each with dedicated pre-handling; a `>` lower bound with pre enables pre-matching on the `<` upper bound). rime implements this ONLY for the `--precise` path; normal matching uses stock rules.
- `Dependency::matches(summary)` (`core/dependency.rs:425`) — name equality AND `version_req.matches(version)`; `matches_id` adds `source_id` equality.
- Cargo caret semantics (from the `semver` crate, reimplement exactly): `1.2.3 → >=1.2.3 <2.0.0`; `0.2.3 → >=0.2.3 <0.3.0`; `0.0.3 → >=0.0.3 <0.0.4`; `1.2 → >=1.2.0 <2.0.0`; `1 → >=1.0.0 <2.0.0`; `0 → >=0.0.0 <1.0.0`. Tilde: `~1.2.3 → >=1.2.3 <1.3.0`; `~1.2 → >=1.2.0 <1.3.0`; `~1 → >=1.0.0 <2.0.0`. Wildcard `1.2.* == >=1.2.0 <1.3.0`; `* == Any`. `>=, <=, >, <, =` comparators; comma = AND. Multiple reqs never OR (cargo has no `||` in manifest reqs).

### 0.3 Features (`resolver/features.rs`, `core/summary.rs`, `core/features.rs`)

- Two-pass design (`features.rs` module docs): the main resolver still does v1-style feature unification during resolution (to decide which optional deps exist), then the new feature resolver runs as a second pass that can only NARROW what the first pass selected. rime mirrors this: `resolve.zig` unifies v1-style while resolving; `features.zig` second pass computes the final per-package feature sets.
- `FeatureOpts::new_behavior(behavior, has_dev_units)` — THE v1/v2 switch: `V1 → all false` (single namespace); `V2|V3 → {decouple_host_deps: true, decouple_dev_deps: has_dev_units == No, ignore_inactive_targets: true}`. Note `HasDevUnits::Yes` (building tests/examples) DISABLES dev-dep decoupling even under v2.
- `FeaturesFor` key — `(PackageId, NormalOrDev|HostDep|ArtifactDep(target))`; `apply_opts` collapses to `NormalOrDev` when `decouple_host_deps` is false (v1).
- `RequestedFeatures::{CliFeatures, DepFeatures{features, uses_default_features}}` — CLI `-F/--features`, `--all-features`, `--no-default-features`; dep-level `features = […]` + `default-features = true/false`.
- Feature syntax (`core/summary.rs` feature-map construction, `core/features.rs` validation): `feature = ["dep-name", "dep:dep-name", "dep-name/feat", "dep-name?/feat" (weak: enables feat only if the optional dep is itself enabled), "own-feat", "own-feat?/…"]`; an optional dependency implicitly creates a same-named feature unless `dep:` syntax is used; `default = […]` feature; `default-features` per-dep toggle.
- Which behavior is active: `ws.resolve_behavior()` — the workspace root's `resolver = "2"` (or `"3"`), defaulting by edition (edition 2021+ workspaces default to `"2"`; see `core/workspace.rs::resolve_behavior`). `resolver = "2"` requires a `[workspace]` root (error otherwise — copy the exact error site in `workspace.rs`).

### 0.4 Lockfile encode/decode (`resolver/encode.rs`, `ops/lockfile.rs`, `core/resolver/resolve.rs`)

- `into_resolve()` — decode: duplicate `name` in `[[package]]` → hard error (`package X is specified twice`); missing-version/source edges resolved via the name→version→source `map` with V2-ambiguity tolerance (ambiguous → edge silently dropped, anticipating bad merges); `checksum` inline bumps min version to V2; `[metadata] "checksum …"` entries are the V1 form (discarded wholesale if any V2+ indicator present — bad-merge rule); single-package file with exactly one trailing `\n` is treated as V2 not V1 (trailing-newline special case); path-dep `PackageId`s reconstructed from the workspace (`build_path_deps`: name+version → path `SourceId`; multiple same-name path versions disambiguated by version, see issue #13405 note).
- `EncodeState::new()` + `encodable_package_id()` — THE edge-shortening rule (V2+): count `(name, version)` occurrences; if exactly one package has this name+version, omit `source`; if additionally only one version exists for the name, omit `version` too (edge is bare `"name"`). V1 never shortens.
- `encodable_source_id()` — path sources encode as `None` (no `source` line; portable); V4 uses `as_encoded_url`, older use `as_url`; V≤2 rewrites `branch = "master"` git refs to default-branch form.
- `Serialize for Resolve` — packages sorted by `PackageId` Ord (name, version, source); V1 puts checksums in `[metadata]` as `"checksum <id>" → hex|"<none>"`, V2+ inline `checksum = "…"`; `TomlLockfile.version`: V5→5, V4→4, V3→3, V2|V1→absent; `patch.unused` list preserved; `metadata` preserved.
- `ops/lockfile.rs::serialize_resolve()` — THE byte layout (rime must replicate exactly, NOT via a generic TOML emitter): two `@generated` marker lines; preserve extra top comments from the original file; `version = N\n\n`; per package `[[package]]\nname = "…"\nversion = "…"\n[source = "…"\n][checksum = "…"\n][dependencies = [\n "…",\n]\n][blank line handling]`; `emit_package` order is `name, version, source, checksum, dependencies|replace`; deps array items each ` "<edge>",\n`; `[[patch.unused]]` blocks; `[metadata]` table last; for V≥2 strip trailing blank lines (`while out.ends_with("\n\n") pop`), V1 keeps historical trailing blank line.
- `write_pkg_lockfile()` — skip write when `are_equal_lockfiles` (semantic compare via `into_resolve` equality when updates are disallowed); `--locked/--frozen` (`ws.gctx().locked_flag()`): if the lockfile WOULD change, bail with `cannot update the lock file … because --locked was passed…` (copy message); THEN upgrade `resolve.set_version(default)` when `current < default` (`ResolveVersion::with_rust_version(ws.lowest_rust_version())`), i.e. merely running a newer cargo bumps old lockfiles on next write; V5 without `-Znext-lockfile-bump` is a hard error.
- `load_pkg_lockfile()` — missing file → `Ok(None)` (fresh resolve); parse failure → context `failed to parse lock file at: <path>`.

### 0.5 Update semantics + flags (`ops/resolve.rs`, `ops/cargo_update.rs`, `ops/cargo_generate_lockfile`)

- `resolve_with_previous()` — THE minimal-update rule: every id in the previous resolve that passes `keep()` gets `version_prefs.prefer_package_id(id)` (preferred-first ordering makes old versions win whenever still valid → conservative updates); deps of members are `lock_to()`-pinned to previous versions via `register_previous_locks` (`Locked` reqs still assert-match the original req). `keep` for `cargo update -p foo` is false for `foo` AND for all transitive deps of non-kept packages (the serde/log example in the comments: updating serde unlocks log so a newer serde can pull a newer log if needed, but the old log stays *preferred* so it is kept when compatible).
- `register_patch_entries` — `[patch]` versions become preferences AND `avoid_patch_ids` (patched-out locked ids are removed from `keep`, forcing re-resolve of those subgraphs); `registry.lock_patches()` after; unused patches warn with `UNUSED_PATCH_WARNING` text.
- `resolve_ws_with_opts` runs resolution TWICE: full-feature resolve (saved to lock) + CLI-feature-targeted resolve (build plan). Lockfile records versions only, never features.
- `--offline`: no network; any missing package that would need a download is an error naming the crate (`failed to load source…` / `no matching package` with offline hint — copy cargo's wording at the call site in `sources/` + `registry.rs`). `--frozen` = `--locked` + `--offline`. `generate_lockfile.rs` test suite pins: `--locked` with out-of-date lock errors; `--offline` with complete lock succeeds without network.
- Resolve errors (`resolver/errors.rs`, `dep_cache.rs::describe_path_in_context`): incompatible requirements produce the `failed to select a version for the requirement … candidate versions found … which …` chain with the dependency path; surface rime's equivalents with the same leading line so tests can match on it.

### 0.6 Sparse-index input model (`references/cargo/src/cargo/sources/registry/index/**` + `cargo-util-schemas/src/index.rs`)

Resolution input is crates.io sparse-index metadata EXACTLY as cargo consumes it. The wire unit is one JSON object per line per crate version (`IndexPackage` in `cargo-util-schemas/src/index.rs`); rime's `index.zig` models it field-for-field (Task 2 `IndexEntry`/`IndexDep`):

- `IndexPackage{name, vers, deps, features, features2, cksum, yanked, links, rust_version, pubtime, v}`. `yanked` is `Option<bool>` (absent = not yanked — old entries pre-2014 lack it). `v` is the schema version; the selection gate is `v > v_max` → `IndexSummary::Unsupported` (kept but never selected — rime records the version at parse and never selects it), where `v_max = INDEX_V_MAX + 1` when `-Zbindeps` is enabled else `INDEX_V_MAX` (`INDEX_V_MAX: u32 = 2` in `index/mod.rs`; M3 has no bindeps support so rime always uses `v_max = 2`). Entries that parse as JSON (name/vers recoverable) but fail conversion are returned by `IndexSummary::parse` as `IndexSummary::Invalid` (kept, then dropped by `dep_cache.rs::query`'s `_ => {}` arm — never fatal, never selected); only lines that fail even minimal parse (`IndexPackageMinimum` recovery fails) are skipped by the `continue` in the `Summaries::parse` slow-path cache-load loop with a logged line — per `index_package_to_summary`'s `****CAUTION****` comment, a single bad line must not fail the whole query. `IndexSummary` has FIVE variants — `Candidate | Yanked | Offline | Unsupported(u32) | Invalid` — and `dep_cache.rs::query` matches on them: `Candidate` always admitted, `Yanked` admitted only when preferred/precise (see §0.1), everything else dropped by the `_ => {}` arm (`Offline` only arises mid-download; rime's offline stub surface in Task 9 maps zero-served-candidates to `offline_missing`).
- `RegistryDependency{name, req, features, optional, default_features, target, kind, registry, package, public, artifact, bindep_target, lib}`. Conversion (`index/mod.rs::registry_dependency_into_dep`) is normative for rime's index→edge projection: `package` (when present) is the REAL crate name and `name` is the rename (`set_explicit_name_in_toml(name)` — resolution, lock edges, and feature keys all use the real name; the rename is manifest-surface only); `kind` `"dev"|"build"|""` → `DepKind::{Development, Build, Normal}` (absent/unknown → Normal); `target` string → `Platform::parse` (same parser Task 7 hand-rolls — vectors must agree); `registry` URL overrides the default source id; `features` with empty-string entries FILTERED OUT (`features.retain(|s| !s.is_empty())` —Published junk, must copy); `default_features` defaults TRUE when absent (`default_true`); `features2` maps MERGED into `features` (`index_package_to_summary`: `features.entry(name).or_default().extend(values)`).
- `cksum` (sha256 hex) flows to the lock `checksum` line verbatim; `links` flows to the Task-3 links-conflict check; `rust_version` (partial, e.g. `"1.60"`) flows to Task-2 msrv ordering AND `ResolveVersion::with_rust_version` floors; `pubtime` (`%Y-%m-%dT%H:%M:%SZ`, UTC `Z` only, `parse_pubtime`) flows to the publish-time filter (compare as unix seconds).
- `public` (RFC 1977) is a passthrough bool (`public.unwrap_or(false)` + `set_public` in `index/mod.rs::registry_dependency_into_dep`): rime parses it onto `IndexDep.public` (default false) and carries it through; it has NO M3 resolution semantics and NEVER errors. `artifact`/`bindep_target`/`lib` (artifact-deps, schema v3) are likewise parsed and carried verbatim via the `Artifact::parse` shape (deferred — M3 has no `-Zbindeps` resolution semantics and NEVER fails `parseIndexLine` for artifact data, exactly as `registry_dependency_into_dep` returns `Ok` for such lines): the gate is at SELECTION, not parse — under M3's `v_max = 2`, schema-v3 lines are `Unsupported` and never selected, so artifact data on v3 lines never reaches resolution. A `v ≤ 2` line carrying artifact data is ALSO parsed successfully and carried (no parse-time error); M3 resolution defers artifact semantics (version selection treats the edge normally; artifact-ness is recorded for a future `-Zbindeps` lane). The loud deferred-feature error (`UnsupportedManifestForm` naming `-Zbindeps`) applies ONLY to manifest-side `artifact = …` / `bindep-target` / `lib` keys (Task 12 table), where cargo's unstable gate rejects them — NEVER to index lines. Genuinely unsupported surface elsewhere stays a loud named error per §0.7 — silent divergence is still a conformance bug.

### 0.7 Broad manifest surface (operator requirement: keep MOST of cargo's manifest surface working)

M3 parses and honors: renamed deps (`old-name = { package = "real-name", version = "…" }` — rename is Trio-level: manifest key ≠ resolved crate name; lockfile, feature keys, and dep edges use the REAL name), optional deps + implicit same-name features (+ `dep:` opt-out), `[target.'cfg(…)'.dependencies]` / `dev-dependencies` / `build-dependencies` target tables, `workspace = true` inheritance (`workspace.package.*` + `workspace.dependencies` + `workspace.features` patching), `[patch]` (version preferences + avoid-locked-set, unused-patch warning text), `[replace]` (deprecated override applied at query time with cargo's ambiguity errors), version reqs incl. pre-release + yanked interplay, `resolver = "1"|"2"` (+ `"3"`) behavior switch. Full table in Task 12. Anything outside that table is a LOUD named error at parse time (`UnsupportedKey{key, file, line}` / `UnsupportedManifestForm{…}`) — silent divergence is a conformance bug, fail the fixture instead.

---

## 1. File structure

```
src/cargo/semver.zig     NEW: Version, VersionReq, OptVersionReq + matching (Task 1)
src/cargo/index.zig      NEW: IndexEntry/IndexDep (sparse-index-faithful) + RegistryQueryer filter/sort seam (Task 2)
src/cargo/resolve.zig    NEW: activation DFS + backtracking + conflict cache + previous-lock guidance (Tasks 3, 4)
src/cargo/features.zig   NEW: v1 unification + v2/v3 FeatureOpts second pass (Tasks 5, 6)
src/cargo/sources.zig    NEW (small): SourceId model — path/registry/git + lockfile URL forms (Task 7)
src/cargo/manifest.zig   MODIFY: broad surface — renames, target tables, workspace inheritance, [patch]/[replace] (Task 12)
src/cargo/lock.zig       MODIFY: writer extensions (edge shortening, v4 byte layout, version bump) (Task 8)
src/cargo/cli.zig        MODIFY: --locked/--frozen/--offline enforcement + resolve error text (Task 9)
src/cargo/root.zig       MODIFY: re-export semver/index/resolve/features/sources
testdata/cargo/resolve/  NEW: oracle fixtures (Tasks 10, 11)
  <case>/Cargo.toml  [+ members/…]  [+ index.json]  [+ cargo.lock.expected]
validation/              LANDED (repo root): real validation projects with cargo-committed goldens (Task 10)
  <project>/{Cargo.toml,members…,golden.Cargo.lock,golden.metadata.json,golden.tree*.txt}
  (lockfile-golden/ carries its lock golden as the committed Cargo.lock itself; paths sanitized to @VALIDATION_ROOT@)
src/cargo/oracle.zig     NEW: test-only harness shelling to real `cargo` (Tasks 10, 11)
```

`lock.zig`'s M1 API (`LockPackage`, `Lockfile{version, packages, find, serialize, deinit}`, `parseLock`) is PRESERVED; Task 8 adds writer-side constructors and sorting/shortening helpers without changing existing signatures (only additive changes + bug fixes to match `emit_package` exactly).

Each task's **Interfaces** block is the contract between tasks: exact names and types the neighbor tasks use. Implement exactly these; do not rename.

---

### Task 1: Semver requirement parsing + matching

**Files:**
- Create: `src/cargo/semver.zig`
- Test: inline `test "…"` blocks in `src/cargo/semver.zig`
- Modify: `src/cargo/root.zig` (append `pub const semver = @import("semver.zig");`)

**Interfaces:**
- Consumes: std only.
- Produces (used by Tasks 2–4, 7):
```zig
pub const ParseError = error{ InvalidVersion, InvalidReq, OutOfMemory };
pub const Version = struct {
    major: u64, minor: u64, patch: u64,
    pre: []const u8,   // "" when stable; raw prerelease string, e.g. "alpha.1"
    build: []const u8, // "" when absent; raw build metadata (compared ONLY by Precise/Locked rules)
    pub fn parse(text: []const u8) ParseError!Version; // strict x.y.z[-pre][+build], no leading zeros, no `v` prefix
    pub fn order(self: Version, other: Version) std.math.Order; // major,minor,patch numeric; stable > any pre; pre by semver identifiers
    pub fn eql(self: Version, other: Version) bool; // full equality INCLUDING build (Locked rule)
};
pub const Op = enum { caret, tilde, exact, gte, lte, gt, lt, wildcard };
pub const Comparator = struct { op: Op, major: u64, minor: ?u64, patch: ?u64, pre: []const u8 };
pub const VersionReq = struct {
    comparators: []Comparator, // comma-separated AND; empty means `*`
    pub fn parse(text: []const u8) ParseError!VersionReq; // 自 `*`, `^`, `~`, `=`, `>=`, `<=`, `>`, `<`, partials, wildcards
    pub fn matches(self: VersionReq, v: Version) bool; // STOCK semver-crate rules (prerelease excluded unless req names it)
    pub fn matchesPrerelease(self: VersionReq, v: Version) bool; // RFC 3493 rules (--precise path only)
};
pub const OptVersionReq = union(enum) {
    any: void,
    req: VersionReq,
    locked: struct { version: Version, req: VersionReq },
    precise: struct { version: Version, req: VersionReq },
    pub fn matches(self: OptVersionReq, v: Version) bool;
    pub fn lockTo(self: *OptVersionReq, v: Version) void; // asserts matches() first (cargo's assert! in lock_to)
};
```

Reference pins (cite in a comment above `matches` and `matchesPrerelease`):
`references/cargo/src/cargo/util/semver_ext.rs::OptVersionReq::matches` (Any/Req/Locked/Precise four-way split; Locked uses full `==` including build metadata) and `references/cargo/src/cargo/util/semver_eval_ext.rs::matches_prerelease` (per-op prerelease logic; note the file's own warning that `x.y.z-pre.0` vs `x.y.z` upper-bound behavior is still unresolved upstream — mirror current behavior, do not "fix" it).

Caret/tilde/wildcard expansion table (from §0.2) MUST be a table test. Prerelease gating (stock rule): a stable comparator never matches a prerelease version; a comparator WITH `pre` matches prereleases only on the same `major.minor.patch`. Build metadata is IGNORED by `VersionReq.matches` (strip before compare) but SIGNIFICANT for `locked` full-equality and `precise` conditional-equality.

- [ ] **Step 1: Write the failing version-parse + caret tests**

```zig
test "semver parses versions strictly" {
    const v = try Version.parse("1.2.3");
    try std.testing.expectEqual(@as(u64, 1), v.major);
    try std.testing.expectError(ParseError.InvalidVersion, Version.parse("1.2"));
    try std.testing.expectError(ParseError.InvalidVersion, Version.parse("v1.2.3"));
    try std.testing.expectError(ParseError.InvalidVersion, Version.parse("01.2.3"));
    const pre = try Version.parse("1.0.0-alpha.1+build.5");
    try std.testing.expectEqualStrings("alpha.1", pre.pre);
    try std.testing.expectEqualStrings("build.5", pre.build);
}

test "semver caret ranges expand per cargo table" {
    const cases = [_]struct { req: []const u8, yes: []const u8, no: []const u8 }{
        .{ .req = "^1.2.3", .yes = "1.9.0", .no = "2.0.0" },
        .{ .req = "^0.2.3", .yes = "0.2.9", .no = "0.3.0" },
        .{ .req = "^0.0.3", .yes = "0.0.3", .no = "0.0.4" },
        .{ .req = "1.2", .yes = "1.9.0", .no = "2.0.0" },
        .{ .req = "~1.2.3", .yes = "1.2.9", .no = "1.3.0" },
        .{ .req = ">=1.2.3, <2.0.0", .yes = "1.5.0", .no = "2.0.0" },
        .{ .req = "*", .yes = "0.0.1", .no = "" },
    };
    for (cases) |c| {
        const req = try VersionReq.parse(c.req);
        try std.testing.expect(req.matches(try Version.parse(c.yes)));
        if (c.no.len > 0) try std.testing.expect(!req.matches(try Version.parse(c.no)));
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test 2>&1 | tail -10`
Expected: FAIL — `src/cargo/semver.zig` does not exist.

- [ ] **Step 3: Write minimal implementation**

Full `Version.parse` (strict split on `.`/`-`/`+`, digit-only core, leading-zero rejection), `order` (numeric core; stable > prerelease; prerelease identifiers numeric-vs-alphanumeric per semver §11), `VersionReq.parse` (trim; `*` alone → empty comparators; leading-op dispatch; `^`/`~` desugar to comparator pairs at MATCH time via `matches`, not by rewriting — document why: prerelease gating needs the original op), `matches` (AND over comparators; prerelease gate first; build stripped), `matchesPrerelease` (port `semver_eval_ext.rs` op-by-op, including the `lower_bound_prerelease` flag that makes `<2.0.0` accept pres when a `>=x-pre` lower bound exists), `OptVersionReq.matches` four-way split + `lockTo` with `std.debug.assert(self.matches(v))`.

- [ ] **Step 4: Add prerelease/locked/precise edge tests and pass**

```zig
test "semver stock matching excludes prereleases" {
    const req = try VersionReq.parse("^1.2.3");
    try std.testing.expect(!req.matches(try Version.parse("1.5.0-alpha")));
    const with_pre = try VersionReq.parse(">=1.2.3-alpha, <2.0.0");
    try std.testing.expect(with_pre.matchesPrerelease(try Version.parse("1.5.0-alpha")));
    // Locked pins build metadata exactly (util/semver_ext.rs Locked arm).
    var l = OptVersionReq{ .locked = .{ .version = try Version.parse("1.0.0+bar"), .req = try VersionReq.parse("*") } };
    try std.testing.expect(!l.matches(try Version.parse("1.0.0+foo")));
    try std.testing.expect(l.matches(try Version.parse("1.0.0+bar")));
    // Precise without build in request ignores build in candidate.
    var p = OptVersionReq{ .precise = .{ .version = try Version.parse("1.0.0"), .req = try VersionReq.parse("*") } };
    try std.testing.expect(p.matches(try Version.parse("1.0.0+anything")));
}
```

Run: `zig build test 2>&1 | tail -5`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
jj status
jj commit src/cargo/semver.zig src/cargo/root.zig -m "Add semver requirement matching"
```

---

### Task 2: Candidate index seam + query filter + version preferences

**Files:**
- Create: `src/cargo/index.zig`
- Test: inline tests in `src/cargo/index.zig` (JSON stub index embedded as string literals — no FS)
- Modify: `src/cargo/root.zig` (append `pub const index = @import("index.zig");`)

**Interfaces:**
- Consumes: `semver.Version`, `semver.OptVersionReq` (Task 1); `std.json` for index-line parsing.
- Produces (used by Tasks 3, 4, 10, 12):
```zig
pub const SourceKind = enum { path, registry, git };
pub const Candidate = struct {
    name: []const u8,
    version: semver.Version,
    yanked: bool,
    checksum: ?[]const u8,      // null for path/git
    rust_version: ?semver.Version, // index `rust_version` field, partial allowed ("1.60" → 1.60.0)
    pubtime: ?i64,               // unix seconds; null when unknown (never filtered)
};
// Sparse-index-faithful per-version entry: mirrors IndexPackage + RegistryDependency
// (cargo-util-schemas/src/index.rs) field-for-field. Candidate above is the
// resolver-facing projection; IndexEntry is the parse target.
// Field mapping (normative, see §0.6):
//   vers→version, cksum→checksum, yanked (Option, absent=false), links,
//   rust_version (partial ok), pubtime ("%Y-%m-%dT%H:%M:%SZ" Z-only → unix secs),
//   v (schema; >v_max → Unsupported, recorded and never selected;
//   v_max = INDEX_V_MAX + 1 with -Zbindeps else INDEX_V_MAX; M3 never
//   enables -Zbindeps so v_max is always 2 in M3),
//   features + features2 MERGED (features2 extends same-name keys),
//   deps[] → IndexDep with name/req/features/optional/default_features(true when
//   absent)/target/kind(dev|build|normal, unknown→normal)/registry/package(rename).
// Field fidelity (cargo-conformant, see §0.6): `public` is a passthrough bool
// (default false, carried, never an error — `unwrap_or(false)` + `set_public`);
// `artifact`/`bindep_target`/`lib` are parsed and carried verbatim via the
// `Artifact::parse` shape (deferred — M3 has no -Zbindeps resolution semantics,
// NEVER a parse-time error on index lines, exactly as
// `registry_dependency_into_dep` returns `Ok`); selection gate: index line
// with v>v_max (v_max=2 in M3, INDEX_V_MAX+1 only with -Zbindeps) → kept as
// Unsupported (not an error, never selected). Manifest-side artifact keys are
// a loud `UnsupportedManifestForm` (Task 12); index lines are never rejected
// for artifact data.
pub const DepKind = enum { normal, build, dev };
pub const IndexDep = struct {
    name: []const u8,          // TOML/index key (the RENAME when package != null)
    package: ?[]const u8,      // real crate name when renamed; null otherwise
    req: []const u8,           // raw req text (parsed to OptVersionReq at query time)
    features: []const []const u8, // empty-string entries already filtered at parse
    optional: bool,
    default_features: bool,
    target: ?[]const u8,       // raw target cfg string (parsed by sources.parseCfg)
    kind: DepKind,
    registry: ?[]const u8,     // non-default index URL; null = default registry
    public: bool,              // RFC 1977 passthrough (default false; no M3 semantics, never errors)
    artifact: ?[]const u8,      // raw artifact array text; null when absent (bindeps-deferred)
    bindep_target: ?[]const u8, // raw target for artifact dep; null when absent
    lib: bool,                 // artifact lib flag (default false)
    pub fn realName(self: IndexDep) []const u8; // package orelse name (resolution/lock/feature key)
};
pub const IndexEntry = struct {
    candidate: Candidate,
    links: ?[]const u8,
    schema_v: u32,             // `v`, default 1 when absent
    unsupported: bool,         // true when schema_v > v_max (v_max=2 in M3; INDEX_V_MAX+1 only with -Zbindeps): never selected
    features: []const FeatureDef, // merged features + features2
    deps: []const IndexDep,
    pub fn deinit(self: *IndexEntry, gpa: std.mem.Allocator) void; // frees features/deps slices + duped strings
};
pub const FeatureDef = struct { name: []const u8, values: []const []const u8 };
pub const INDEX_V_MAX: u32 = 2;
pub const QueryFilter = struct {
    allow_yanked: []const semver.Version, // exact pinned versions that may be used despite yanked (lockfile pins + --precise)
    max_pubtime: ?i64,           // publish_time pre-filter; null = no filter
    min_versions_first: bool,    // -Zminimal-versions ordering (VersionOrdering::MinimumVersionsFirst)
    rust_versions: []const semver.Version, // workspace rust versions for msrv-compat count (empty = skip)
    preferred: []const semver.Version,     // previous-lock versions tried first (prefer_package_id)
};
pub const IndexError = error{ OutOfMemory, UnsupportedIndexField, InvalidIndexLine }; // NOTE: index-side artifact/public data NEVER yields UnsupportedIndexField (carried verbatim per §0.6); the variant is retained for genuinely unsupported index surface only.
pub fn parseIndexLine(gpa: std.mem.Allocator, line: []const u8) IndexError!IndexEntry; // one JSON object per line, exactly the sparse-index wire shape
pub fn queryCandidates(gpa: std.mem.Allocator, all: []const Candidate, req: semver.OptVersionReq, filter: QueryFilter) IndexError![]Candidate;
```

Reference pins (comment above each function): `dep_cache.rs::RegistryQueryer::query` for the yanked/too-new filter (yanked kept iff in `allow_yanked`; pubtime-newer-than-max dropped); `version_prefs.rs::sort_summaries` for order (preferred → msrv-compat-count desc → version desc/asc); `version_prefs.rs::should_prefer` for the preferred predicate; `sources/registry/index/mod.rs::index_package_to_summary` + `registry_dependency_into_dep` + `cargo-util-schemas/src/index.rs::IndexPackage/RegistryDependency` for `parseIndexLine` (features2 merge, empty-feature filter, kind mapping, rename split, `default_true`). Sorting MUST be stable/deterministic: tie-break by full version equality order (versions are unique per source in practice; assert no exact duplicates).

`queryCandidates` contract (exact): (1) retain candidates where `req.matches(version)`; (2) drop `yanked` unless `allow_yanked` contains an equal version (compare with `eql`, build-sensitive — a yanked `1.0.0+foo` is NOT rescued by pinning `1.0.0+bar`); (3) drop `pubtime > max_pubtime` when both present; (4) stable sort: preferred first, then higher `msrvCompatCount` first (count of `filter.rust_versions` entries `>= candidate.rust_version`; candidate with null `rust_version` counts as fully compatible = `rust_versions.len`, per `msrv_compat_count`), then version desc (or asc when `min_versions_first`); (5) return owned slice (caller frees with `gpa`). `msrvCompatCount` is a `pub` helper so Task 6 tests can target it.

- [ ] **Step 1: Write the failing filter/order test**

```zig
test "index filters yanked and prefers locked versions" {
    const all = [_]Candidate{
        .{ .name = "serde", .version = try semver.Version.parse("1.0.200"), .yanked = false, .checksum = null, .rust_version = null, .pubtime = null },
        .{ .name = "serde", .version = try Version.parse("1.0.201"), .yanked = true, .checksum = null, .rust_version = null, .pubtime = null },
        .{ .name = "serde", .version = try Version.parse("1.0.150"), .yanked = false, .checksum = null, .rust_version = null, .pubtime = null },
    };
    const req = semver.OptVersionReq{ .req = try semver.VersionReq.parse("^1.0.0") };
    // Yanked 1.0.201 hidden by default; newest non-yanked first.
    const got = try queryCandidates(std.testing.allocator, &all, req, .{ .allow_yanked = &.{}, .max_pubtime = null, .min_versions_first = false, .rust_versions = &.{}, .preferred = &.{} });
    defer std.testing.allocator.free(got);
    try std.testing.expectEqual(@as(usize, 2), got.len);
    try std.testing.expect(got[0].version.eql(try Version.parse("1.0.200")));
    // Pinned yanked version is rescued (lock_to path in dep_cache.rs query).
    const pinned = [_]semver.Version{try Version.parse("1.0.201")};
    const got2 = try queryCandidates(std.testing.allocator, &all, req, .{ .allow_yanked = &pinned, .max_pubtime = null, .min_versions_first = false, .rust_versions = &.{}, .preferred = &pinned });
    defer std.testing.allocator.free(got2);
    try std.testing.expectEqual(@as(usize, 3), got2.len);
    try std.testing.expect(got2[0].version.eql(try Version.parse("1.0.201")));
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test 2>&1 | tail -10`
Expected: FAIL — `index.zig` / `queryCandidates` not defined.

- [ ] **Step 3: Write minimal implementation**

Filter loop + `std.mem.sort` with a context struct capturing `filter` (comparator: preferred-membership, then `msrvCompatCount` desc, then `order` desc/asc). Preferred-membership uses `eql` (build-sensitive). All allocation via `gpa.dupe` + in-place sort; return the dupe.

`parseIndexLine`: `std.json.parseFromSlice(std.json.Value, …)` then field-by-field extraction (NOT auto-deserialize into structs — explicit field reads so unknown fields are ignored per forward-compat). `vers` via `semver.Version.parse`; `rust_version` via partial-tolerant parse (`"1.60"` → `1.60.0`, full `x.y.z` accepted); `pubtime` via strict `YYYY-MM-DDTHH:MM:SSZ` → unix seconds (reject fractional seconds/offsets with `InvalidIndexLine`); `yanked = obj.get("yanked")?.bool orelse false`; `features` + `features2` merged (features2 entries extend same-name keys, new keys appended); dep `features` arrays filtered of `""`; `default_features` defaults true; `kind` `"dev"→dev, "build"→build, else normal`; `public` → bool passthrough (`unwrap_or(false)`, never an error); `artifact`/`bindep_target`/`lib` carried verbatim onto `IndexDep` (NEVER a parse-time error on index lines — `registry_dependency_into_dep` returns `Ok`; M3 defers artifact semantics); `v > v_max` (2 in M3, `INDEX_V_MAX + 1` only with `-Zbindeps`) → `unsupported=true` (entry kept, never selected — still parse `name`/`vers` best-effort for diagnostics).

- [ ] **Step 4: Add msrv + minimal-versions + pubtime tests and pass**

```zig
test "index orders by msrv compatibility then version" {
    // candidate A v2.0.0 needs rust 1.80, candidate B v1.9.0 needs rust 1.60; workspace rust is 1.70 → B first.
    const all = [_]Candidate{
        .{ .name = "x", .version = try Version.parse("2.0.0"), .yanked = false, .checksum = null, .rust_version = try Version.parse("1.80.0"), .pubtime = null },
        .{ .name = "x", .version = try Version.parse("1.9.0"), .yanked = false, .checksum = null, .rust_version = try Version.parse("1.60.0"), .pubtime = null },
    };
    const rv = [_]semver.Version{try Version.parse("1.70.0")};
    const got = try queryCandidates(std.testing.allocator, &all, .any, .{ .allow_yanked = &.{}, .max_pubtime = null, .min_versions_first = false, .rust_versions = &rv, .preferred = &.{} });
    defer std.testing.allocator.free(got);
    try std.testing.expect(got[0].version.eql(try Version.parse("1.9.0")));
}

test "index minimal-versions sorts ascending and pubtime filters" {
    const all = [_]Candidate{
        .{ .name = "x", .version = try Version.parse("1.2.0"), .yanked = false, .checksum = null, .rust_version = null, .pubtime = 100 },
        .{ .name = "x", .version = try Version.parse("1.1.0"), .yanked = false, .checksum = null, .rust_version = null, .pubtime = 9999 },
    };
    const got = try queryCandidates(std.testing.allocator, &all, .any, .{ .allow_yanked = &.{}, .max_pubtime = 500, .min_versions_first = true, .rust_versions = &.{}, .preferred = &.{} });
    defer std.testing.allocator.free(got);
    try std.testing.expectEqual(@as(usize, 1), got.len);
    try std.testing.expect(got[0].version.eql(try Version.parse("1.2.0")) == false);
}

test "index parses a real sparse-index line faithfully" {
    const line =
        \"{\"name\":\"serde\",\"vers\":\"1.0.200\",\"deps\":[{\"name\":\"serde_derive\",\"req\":\"^1.0.200\",\"features\":[],\"optional\":true,\"default_features\":true,\"target\":null,\"kind\":\"normal\",\"registry\":null,\"package\":null}],\"features\":{\"default\":[\"std\"],\"alloc\":[]},\"features2\":{\"default\":[\"dep:serde_derive\"]},\"cksum\":\"\" ++ "d" ** 64 ++ "\",\"yanked\":false,\"links\":null,\"rust_version\":\"1.56\",\"v\":2}";
    var entry = try parseIndexLine(std.testing.allocator, line);
    defer entry.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("serde", entry.candidate.name);
    try std.testing.expect(entry.candidate.version.eql(try Version.parse("1.0.200")));
    try std.testing.expect(entry.candidate.rust_version.?.eql(try Version.parse("1.56.0")));
    try std.testing.expect(!entry.unsupported);
    // features + features2 merged under one key.
    try std.testing.expectEqual(@as(usize, 2), entry.features.len); // default, alloc
    // Optional dep edge preserved with kind + rename split.
    try std.testing.expect(entry.deps[0].optional);
    try std.testing.expectEqualStrings("serde_derive", entry.deps[0].realName());
}

test "index carries public and defers artifact (bindeps gate)" {
    // `public` is a passthrough bool (registry_dependency_into_dep): parsed, carried, never an error.
    const with_public = "{\"name\":\"x\",\"vers\":\"1.0.0\",\"deps\":[{\"name\":\"y\",\"req\":\"^1\",\"features\":[],\"optional\":false,\"default_features\":true,\"target\":null,\"kind\":\"normal\",\"public\":true}],\"cksum\":\"" ++ "a" ** 64 ++ "\",\"yanked\":false}";
    var e = try parseIndexLine(std.testing.allocator, with_public);
    defer e.deinit(std.testing.allocator);
    try std.testing.expect(e.deps[0].public);
    // Artifact data on a v≤2 line is parsed and carried verbatim (registry_dependency_into_dep
    // returns Ok) — NEVER a parse error; M3 defers artifact semantics. Selection of v3
    // lines is still gated by Unsupported (v_max = 2 without -Zbindeps).
    const with_artifact = "{\"name\":\"x\",\"vers\":\"1.0.0\",\"deps\":[{\"name\":\"y\",\"req\":\"^1\",\"features\":[],\"optional\":false,\"default_features\":true,\"target\":null,\"kind\":\"normal\",\"artifact\":[\"bin\"]}],\"cksum\":\"" ++ "a" ** 64 ++ "\",\"yanked\":false,\"v\":2}";
    var ea = try parseIndexLine(std.testing.allocator, with_artifact);
    defer ea.deinit(std.testing.allocator);
    try std.testing.expect(!ea.unsupported);
    try std.testing.expect(ea.deps[0].artifact != null);
    try std.testing.expect(!ea.deps[0].lib);
    // Manifest-side artifact keys stay a loud UnsupportedManifestForm (Task 12 table);
    // index lines are never rejected for artifact data.
    // Schema v3 line is kept but never selected (IndexSummary::Unsupported rule).
    const v3 = "{\"name\":\"x\",\"vers\":\"2.0.0\",\"deps\":[],\"cksum\":\"" ++ "b" ** 64 ++ "\",\"v\":3}";
    var e3 = try parseIndexLine(std.testing.allocator, v3);
    defer e3.deinit(std.testing.allocator);
    try std.testing.expect(e3.unsupported);
}
```

Run: `zig build test 2>&1 | tail -5`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
jj status
jj commit src/cargo/index.zig src/cargo/root.zig -m "Add candidate query filter and ordering"
```

---

### Task 3: Resolution core — activation DFS, backtracking, conflict cache

**Files:**
- Create: `src/cargo/resolve.zig` (part 1: core types + `resolveGraph`)
- Test: inline tests with hand-built stub graphs (no FS, no network — candidates are `index.Candidate` slices per crate name)
- Modify: `src/cargo/root.zig` (append `pub const resolve = @import("resolve.zig");`)

**Interfaces:**
- Consumes: `semver.*` (Task 1), `index.queryCandidates` (Task 2), `manifest.DependencyKind` (M1, for edge reqs), `sources.SourceId` (Task 7 defines `sources.zig`, but the TYPE contract is frozen here so Tasks 3–6 build on source-keyed refs from the start; Task-3 tests use `.path`/`.registry` literals).
- Produces (used by Tasks 4–7, 9–11):
```zig
pub const ResolveError = error{ NoMatchingVersion, Conflict, Cycle, OutOfMemory };
pub const DepEdge = struct {
    name: []const u8,             // crate name depended upon
    req: semver.OptVersionReq,    // version requirement (Locked form when previous-lock pins)
    optional: bool,               // enabled only when requested via features (Task 5 wires this)
    build_only: bool,             // build-dependency edge (v2 host-decouple key in Task 6)
};
pub const SummaryNode = struct {
    name: []const u8,
    candidate: index.Candidate,   // the selected version + metadata
    deps: []const DepEdge,        // edges OUT of this version (version-specific!)
    links: ?[]const u8,           // `links = "…"` native-lib key (duplicates conflict)
};
pub const ResolveGraph = struct {
    arena: std.heap.ArenaAllocator, // owns ALL nodes/edges below
    nodes: []const ResolvedNode,
    pub fn deinit(self: *ResolveGraph) void;
    pub fn find(self: *const ResolveGraph, name: []const u8, version: semver.Version) ?ResolvedNode;
};
pub const ResolvedNode = struct { name: []const u8, version: semver.Version, source: sources.SourceId, deps: []const ResolvedRef }; // nodes keyed by name+version+source (multi-source coexistence); workspace-member roots record path sources
pub const ResolvedRef = struct { name: []const u8, version: semver.Version, source: sources.SourceId }; // source-keyed from the start (see Consumes note; no retroactive rekey in Task 7)
pub const QueryError = error{ FetchFailed, OutOfMemory }; // fetch/state failures; resolution maps these to Diag (Task 9)
pub const Registry = struct { // test/M2 seam: all known versions of a crate, with caller state + fallible query
    ctx: *anyopaque,
    queryFn: *const fn (ctx: *anyopaque, name: []const u8) QueryError![]const SummaryNode,
};
pub fn resolveGraph(gpa: std.mem.Allocator, roots: []const SummaryNode, registry: Registry, filter: index.QueryFilter) ResolveError!ResolveGraph;
```

Reference pins (comment at top of `resolveGraph`): `mod.rs::activate_deps_loop` (iterative DFS + `pop_most_constrained` + `backtrack_stack`; candidates tried in `queryCandidates` order = cargo's max-version-first); `context.rs::is_conflicting` (a version conflicts when semver-compatible with an activated same-name version, or its `links` equals an activated `links`); `conflict_cache.rs::ConflictCache` (record conflict sets on backtrack; skip candidates participating in a known conflict subset — implement the trie with `PackageId`-equivalent keys `(name, version)` sorted for the trie path).

Semantics (exact): roots activate first (workspace members, always kept — never backtracked past). Loop: pick the pending dep with fewest viable candidates (`queryCandidates` length; ties broken by dep name for determinism); try each candidate in order: if it conflicts with activations, record `(dep, candidate, reason)` conflict and try next; if clean, activate (push prior state on backtrack stack) and enqueue its deps. If NO candidate works, backtrack to the newest backtrack-stack entry whose activation participates in the conflict (jump-back, not just chronological pop); if stack empties → `ResolveError.NoMatchingVersion` naming the dep and listing tried versions (Task 9 formats the full message). Semver-compatible coexistence: activating `foo 1.2.0` when `foo 1.5.0` is active is a conflict (same semver-compatible track — cargo's rule is one version per semver-compatible range, i.e. same `major` for `≥1`, same `minor` for `0.x`); `foo 1.5.0` + `foo 2.0.0` coexist as separate nodes. After success, DFS from roots over activated nodes for cycle detection → `Cycle`.

- [ ] **Step 1: Write the failing diamond + conflict tests**

```zig
test "resolve picks max versions in a diamond" {
    const gpa = std.testing.allocator;
    const req_left = semver.OptVersionReq{ .req = try semver.VersionReq.parse("^1") };
    const req_right = semver.OptVersionReq{ .req = try semver.VersionReq.parse("^1") };
    const req_shared_lo = semver.OptVersionReq{ .req = try semver.VersionReq.parse("^1.0") };
    const req_shared_hi = semver.OptVersionReq{ .req = try semver.VersionReq.parse("^1.1") };
    const left_edges_v11 = [_]DepEdge{.{ .name = "shared", .req = req_shared_lo, .optional = false, .build_only = false }};
    const right_edges_v11 = [_]DepEdge{.{ .name = "shared", .req = req_shared_hi, .optional = false, .build_only = false }};
    const left_nodes = [_]SummaryNode{
        .{ .name = "left", .candidate = .{ .name = "left", .version = try semver.Version.parse("1.1.0"), .yanked = false, .checksum = null, .rust_version = null, .pubtime = null }, .deps = &left_edges_v11, .links = null },
    };
    const right_nodes = [_]SummaryNode{
        .{ .name = "right", .candidate = .{ .name = "right", .version = try semver.Version.parse("1.1.0"), .yanked = false, .checksum = null, .rust_version = null, .pubtime = null }, .deps = &right_edges_v11, .links = null },
    };
    const shared_nodes = [_]SummaryNode{
        .{ .name = "shared", .candidate = .{ .name = "shared", .version = try semver.Version.parse("1.0.0"), .yanked = false, .checksum = null, .rust_version = null, .pubtime = null }, .deps = &.{}, .links = null },
        .{ .name = "shared", .candidate = .{ .name = "shared", .version = try semver.Version.parse("1.1.0"), .yanked = false, .checksum = null, .rust_version = null, .pubtime = null }, .deps = &.{}, .links = null },
    };
    const Stub = struct {
        left: []const SummaryNode,
        right: []const SummaryNode,
        shared: []const SummaryNode,
        fn query(ctx: *anyopaque, name: []const u8) QueryError![]const SummaryNode {
            const self: *const @This() = @ptrCast(@alignCast(ctx));
            if (std.mem.eql(u8, name, "left")) return self.left;
            if (std.mem.eql(u8, name, "right")) return self.right;
            if (std.mem.eql(u8, name, "shared")) return self.shared;
            return &.{};
        }
    };
    var stub = Stub{ .left = &left_nodes, .right = &right_nodes, .shared = &shared_nodes };
    const app_edges = [_]DepEdge{
        .{ .name = "left", .req = req_left, .optional = false, .build_only = false },
        .{ .name = "right", .req = req_right, .optional = false, .build_only = false },
    };
    const roots = [_]SummaryNode{
        .{ .name = "app", .candidate = .{ .name = "app", .version = try semver.Version.parse("0.1.0"), .yanked = false, .checksum = null, .rust_version = null, .pubtime = null }, .deps = &app_edges, .links = null },
    };
    const filter = index.QueryFilter{ .allow_yanked = &.{}, .max_pubtime = null, .min_versions_first = false, .rust_versions = &.{}, .preferred = &.{} };
    var graph = try resolveGraph(gpa, &roots, .{ .ctx = @ptrCast(&stub), .queryFn = &Stub.query }, filter);
    defer graph.deinit();
    try std.testing.expectEqual(@as(usize, 4), graph.nodes.len);
    try std.testing.expect(graph.find("shared", try semver.Version.parse("1.1.0")) != null);
    try std.testing.expect(graph.find("shared", try semver.Version.parse("1.0.0")) == null);
}

test "resolve backtracks when max version conflicts" {
    const gpa = std.testing.allocator;
    const req_a = semver.OptVersionReq{ .req = try semver.VersionReq.parse("^1") };
    const req_b = semver.OptVersionReq{ .req = try semver.VersionReq.parse("^1") };
    const req_c_exact2 = semver.OptVersionReq{ .req = try semver.VersionReq.parse("=2.0.0") };
    const req_c_1x = semver.OptVersionReq{ .req = try semver.VersionReq.parse("^1.0") };
    const a11_edges = [_]DepEdge{.{ .name = "c", .req = req_c_exact2, .optional = false, .build_only = false }};
    const a10_edges = [_]DepEdge{.{ .name = "c", .req = req_c_1x, .optional = false, .build_only = false }};
    const b10_edges = [_]DepEdge{.{ .name = "c", .req = req_c_1x, .optional = false, .build_only = false }};
    const a_nodes = [_]SummaryNode{
        .{ .name = "a", .candidate = .{ .name = "a", .version = try semver.Version.parse("1.1.0"), .yanked = false, .checksum = null, .rust_version = null, .pubtime = null }, .deps = &a11_edges, .links = null },
        .{ .name = "a", .candidate = .{ .name = "a", .version = try semver.Version.parse("1.0.0"), .yanked = false, .checksum = null, .rust_version = null, .pubtime = null }, .deps = &a10_edges, .links = null },
    };
    const b_nodes = [_]SummaryNode{
        .{ .name = "b", .candidate = .{ .name = "b", .version = try semver.Version.parse("1.0.0"), .yanked = false, .checksum = null, .rust_version = null, .pubtime = null }, .deps = &b10_edges, .links = null },
    };
    const c_nodes = [_]SummaryNode{
        .{ .name = "c", .candidate = .{ .name = "c", .version = try semver.Version.parse("1.0.0"), .yanked = false, .checksum = null, .rust_version = null, .pubtime = null }, .deps = &.{}, .links = null },
        .{ .name = "c", .candidate = .{ .name = "c", .version = try semver.Version.parse("2.0.0"), .yanked = false, .checksum = null, .rust_version = null, .pubtime = null }, .deps = &.{}, .links = null },
    };
    const Stub = struct {
        a: []const SummaryNode,
        b: []const SummaryNode,
        c: []const SummaryNode,
        fn query(ctx: *anyopaque, name: []const u8) QueryError![]const SummaryNode {
            const self: *const @This() = @ptrCast(@alignCast(ctx));
            if (std.mem.eql(u8, name, "a")) return self.a;
            if (std.mem.eql(u8, name, "b")) return self.b;
            if (std.mem.eql(u8, name, "c")) return self.c;
            return &.{};
        }
    };
    var stub = Stub{ .a = &a_nodes, .b = &b_nodes, .c = &c_nodes };
    const app_edges = [_]DepEdge{
        .{ .name = "a", .req = req_a, .optional = false, .build_only = false },
        .{ .name = "b", .req = req_b, .optional = false, .build_only = false },
    };
    const roots = [_]SummaryNode{
        .{ .name = "app", .candidate = .{ .name = "app", .version = try semver.Version.parse("0.1.0"), .yanked = false, .checksum = null, .rust_version = null, .pubtime = null }, .deps = &app_edges, .links = null },
    };
    const filter = index.QueryFilter{ .allow_yanked = &.{}, .max_pubtime = null, .min_versions_first = false, .rust_versions = &.{}, .preferred = &.{} };
    var graph = try resolveGraph(gpa, &roots, .{ .ctx = @ptrCast(&stub), .queryFn = &Stub.query }, filter);
    defer graph.deinit();
    try std.testing.expect(graph.find("a", try semver.Version.parse("1.0.0")) != null);
    try std.testing.expect(graph.find("c", try semver.Version.parse("1.0.0")) != null);
    try std.testing.expect(graph.find("c", try semver.Version.parse("2.0.0")) == null);
}

test "resolve allows semver-incompatible coexistence" {
    const gpa = std.testing.allocator;
    const req_old = semver.OptVersionReq{ .req = try semver.VersionReq.parse("^1") };
    const req_new = semver.OptVersionReq{ .req = try semver.VersionReq.parse("^2") };
    const req_u1 = semver.OptVersionReq{ .req = try semver.VersionReq.parse("^1") };
    const req_u2 = semver.OptVersionReq{ .req = try semver.VersionReq.parse("^2") };
    const old_edges = [_]DepEdge{.{ .name = "util", .req = req_u1, .optional = false, .build_only = false }};
    const new_edges = [_]DepEdge{.{ .name = "util", .req = req_u2, .optional = false, .build_only = false }};
    const old_nodes = [_]SummaryNode{
        .{ .name = "old", .candidate = .{ .name = "old", .version = try semver.Version.parse("1.0.0"), .yanked = false, .checksum = null, .rust_version = null, .pubtime = null }, .deps = &old_edges, .links = null },
    };
    const new_nodes = [_]SummaryNode{
        .{ .name = "new", .candidate = .{ .name = "new", .version = try semver.Version.parse("2.0.0"), .yanked = false, .checksum = null, .rust_version = null, .pubtime = null }, .deps = &new_edges, .links = null },
    };
    const util_nodes = [_]SummaryNode{
        .{ .name = "util", .candidate = .{ .name = "util", .version = try semver.Version.parse("1.0.0"), .yanked = false, .checksum = null, .rust_version = null, .pubtime = null }, .deps = &.{}, .links = null },
        .{ .name = "util", .candidate = .{ .name = "util", .version = try semver.Version.parse("2.0.0"), .yanked = false, .checksum = null, .rust_version = null, .pubtime = null }, .deps = &.{}, .links = null },
    };
    const Stub = struct {
        old: []const SummaryNode,
        new: []const SummaryNode,
        util: []const SummaryNode,
        fn query(ctx: *anyopaque, name: []const u8) QueryError![]const SummaryNode {
            const self: *const @This() = @ptrCast(@alignCast(ctx));
            if (std.mem.eql(u8, name, "old")) return self.old;
            if (std.mem.eql(u8, name, "new")) return self.new;
            if (std.mem.eql(u8, name, "util")) return self.util;
            return &.{};
        }
    };
    var stub = Stub{ .old = &old_nodes, .new = &new_nodes, .util = &util_nodes };
    const app_edges = [_]DepEdge{
        .{ .name = "old", .req = req_old, .optional = false, .build_only = false },
        .{ .name = "new", .req = req_new, .optional = false, .build_only = false },
    };
    const roots = [_]SummaryNode{
        .{ .name = "app", .candidate = .{ .name = "app", .version = try semver.Version.parse("0.1.0"), .yanked = false, .checksum = null, .rust_version = null, .pubtime = null }, .deps = &app_edges, .links = null },
    };
    const filter = index.QueryFilter{ .allow_yanked = &.{}, .max_pubtime = null, .min_versions_first = false, .rust_versions = &.{}, .preferred = &.{} };
    var graph = try resolveGraph(gpa, &roots, .{ .ctx = @ptrCast(&stub), .queryFn = &Stub.query }, filter);
    defer graph.deinit();
    try std.testing.expect(graph.find("util", try semver.Version.parse("1.0.0")) != null);
    try std.testing.expect(graph.find("util", try semver.Version.parse("2.0.0")) != null);
}

test "resolve rejects duplicate links" {
    const gpa = std.testing.allocator;
    const req_x = semver.OptVersionReq{ .req = try semver.VersionReq.parse("^1") };
    const req_y = semver.OptVersionReq{ .req = try semver.VersionReq.parse("^1") };
    const x_nodes = [_]SummaryNode{
        .{ .name = "x", .candidate = .{ .name = "x", .version = try semver.Version.parse("1.0.0"), .yanked = false, .checksum = null, .rust_version = null, .pubtime = null }, .deps = &.{}, .links = "z" },
    };
    const y_nodes = [_]SummaryNode{
        .{ .name = "y", .candidate = .{ .name = "y", .version = try semver.Version.parse("1.0.0"), .yanked = false, .checksum = null, .rust_version = null, .pubtime = null }, .deps = &.{}, .links = "z" },
    };
    const Stub = struct {
        x: []const SummaryNode,
        y: []const SummaryNode,
        fn query(ctx: *anyopaque, name: []const u8) QueryError![]const SummaryNode {
            const self: *const @This() = @ptrCast(@alignCast(ctx));
            if (std.mem.eql(u8, name, "x")) return self.x;
            if (std.mem.eql(u8, name, "y")) return self.y;
            return &.{};
        }
    };
    var stub = Stub{ .x = &x_nodes, .y = &y_nodes };
    const app_edges = [_]DepEdge{
        .{ .name = "x", .req = req_x, .optional = false, .build_only = false },
        .{ .name = "y", .req = req_y, .optional = false, .build_only = false },
    };
    const roots = [_]SummaryNode{
        .{ .name = "app", .candidate = .{ .name = "app", .version = try semver.Version.parse("0.1.0"), .yanked = false, .checksum = null, .rust_version = null, .pubtime = null }, .deps = &app_edges, .links = null },
    };
    const filter = index.QueryFilter{ .allow_yanked = &.{}, .max_pubtime = null, .min_versions_first = false, .rust_versions = &.{}, .preferred = &.{} };
    try std.testing.expectError(ResolveError.Conflict, resolveGraph(gpa, &roots, .{ .ctx = @ptrCast(&stub), .queryFn = &Stub.query }, filter));
}

(Write each with local `SummaryNode` tables and a `Registry{ctx, queryFn}` stub switching on name; assert exact `nodes` name@version sets.)

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test 2>&1 | tail -10`
Expected: FAIL — `resolve.zig` / `resolveGraph` not defined.

- [ ] **Step 3: Write minimal implementation**

Iterative resolver: `pending: ArrayList(PendingDep{parent: ?Ref, edge})`; `activations: StringHashMap(ArrayList(Activation{version, deps, age}))`; `backtrack_stack: ArrayList(Checkpoint{pending_len, activations_snapshot…})` — snapshot activations cheaply via a journal (list of added `(name, version)` undone on pop) rather than full copies; `conflicts: ConflictStore` trie keyed by sorted activated `(name,version)` id list. `popMostConstrained` computes `queryCandidates` per pending dep each iteration (graphs in tests are tiny; document that production memoizes per `(name, req)` — M2 optimization, not M3 semantics). Jump-back: on exhaustion for a dep, find newest checkpoint whose journal added a version named in the conflict set; pop to it and blacklist that version for that dep frame.

- [ ] **Step 4: Run tests to verify they pass**

Run: `zig build test 2>&1 | tail -5`
Expected: PASS. Add the exhaustion test:

```zig
test "resolve errors when nothing satisfies" {
    const gpa = std.testing.allocator;
    // app → a ^1 (only 1.0 exists, needs b ^2); b only has 1.0 → NoMatchingVersion naming "b".
    const req_a = semver.OptVersionReq{ .req = try semver.VersionReq.parse("^1") };
    const req_b2 = semver.OptVersionReq{ .req = try semver.VersionReq.parse("^2") };
    const a_edges = [_]DepEdge{.{ .name = "b", .req = req_b2, .optional = false, .build_only = false }};
    const a_nodes = [_]SummaryNode{
        .{ .name = "a", .candidate = .{ .name = "a", .version = try semver.Version.parse("1.0.0"), .yanked = false, .checksum = null, .rust_version = null, .pubtime = null }, .deps = &a_edges, .links = null },
    };
    const b_nodes = [_]SummaryNode{
        .{ .name = "b", .candidate = .{ .name = "b", .version = try semver.Version.parse("1.0.0"), .yanked = false, .checksum = null, .rust_version = null, .pubtime = null }, .deps = &.{}, .links = null },
    };
    const Stub = struct {
        a: []const SummaryNode,
        b: []const SummaryNode,
        fn query(ctx: *anyopaque, name: []const u8) QueryError![]const SummaryNode {
            const self: *const @This() = @ptrCast(@alignCast(ctx));
            if (std.mem.eql(u8, name, "a")) return self.a;
            if (std.mem.eql(u8, name, "b")) return self.b;
            return &.{};
        }
    };
    var stub = Stub{ .a = &a_nodes, .b = &b_nodes };
    const app_edges = [_]DepEdge{
        .{ .name = "a", .req = req_a, .optional = false, .build_only = false },
    };
    const roots = [_]SummaryNode{
        .{ .name = "app", .candidate = .{ .name = "app", .version = try semver.Version.parse("0.1.0"), .yanked = false, .checksum = null, .rust_version = null, .pubtime = null }, .deps = &app_edges, .links = null },
    };
    const filter = index.QueryFilter{ .allow_yanked = &.{}, .max_pubtime = null, .min_versions_first = false, .rust_versions = &.{}, .preferred = &.{} };
    const registry = Registry{ .ctx = @ptrCast(&stub), .queryFn = &Stub.query };
    try std.testing.expectError(ResolveError.NoMatchingVersion, resolveGraph(gpa, &roots, registry, filter));
}
```

- [ ] **Step 5: Commit**

```bash
jj status
jj commit src/cargo/resolve.zig src/cargo/root.zig -m "Add resolver activation core"
```

---

### Task 4: Previous-lock guidance + minimal-update semantics

**Files:**
- Modify: `src/cargo/resolve.zig` (add `resolveWithPrevious` + `KeepFilter`)
- Test: inline tests in `src/cargo/resolve.zig` (previous-lock tables as `ResolvedNode` slices)

**Interfaces:**
- Consumes: Task 3 graph + Task 2 `QueryFilter`.
- Produces (used by Tasks 8–11):
```zig
pub const PrecisePin = struct { name: []const u8, version: semver.Version }; // `--precise name=version` target
pub const KeepFilter = struct {
    update_names: []const []const u8, // `cargo update -p …` set; empty = keep everything
    precise: ?PrecisePin = null,      // `--precise` pin; null when absent (default keeps old literals compiling)
    pub fn keep(self: KeepFilter, name: []const u8, reverse_deps_of_updated: bool) bool;
};
pub fn resolveWithPrevious(
    gpa: std.mem.Allocator,
    roots: []const SummaryNode,
    lookup: Registry,
    previous: ?[]const ResolvedNode, // locked versions from Cargo.lock (Task 8 decode)
    keep: KeepFilter,
    base_filter: index.QueryFilter,  // rust_versions/min-versions/pubtime from workspace config
) ResolveError!ResolveGraph;
```

Reference pins: `ops/resolve.rs::resolve_with_previous` (prefer-every-kept-id loop) + `register_previous_locks` (deps `lock_to()` previous versions; the serde/log transitive-unlock refinement) + `merge_from` (carry metadata/unused-patches — Task 8 preserves them through write).

Semantics (exact): (1) Build `preferred` = previous ids where `keep()` is true AND the version still satisfies the requesting edge's *original* req (a previous version that no longer matches the manifest req is NOT preferred and NOT locked — it falls out naturally). (2) For each dep edge whose parent chain is fully kept, rewrite its `req` to `Locked{version: prev, req: original}` (cargo's `lock_to`, including the assert). (3) Transitive unlock: any package that is a (transitive) dependency of a NON-kept package loses both its lock and its preference (but keeps candidacy) — implement by walking `previous` edges: start from non-kept roots' dep closures. (Roots here = workspace members named in `update_names`; empty `update_names` ⇒ everything kept ⇒ pure conservative resolve.) (4) `preferred` ordering does the rest: `queryCandidates` tries old versions first, so unchanged graphs resolve byte-identical. (5) `--precise name=version` (`KeepFilter.precise`): `update_names = [name]`, and that dep's req becomes `Precise{version, req: original}` (build-metadata-conditional matching from Task 1; error `NoMatchingVersion` if the precise version isn't a candidate — cargo errors even if other versions would satisfy). (6) Yanked-rescue wiring (Task 2 producer, Task 11 case 3): the cloned `QueryFilter.allow_yanked` is the union of `base_filter.allow_yanked`, every kept locked version from (1)–(2) (same build-sensitive `eql` comparison `queryCandidates` uses), and the `KeepFilter.precise` version when set. Without this rule `resolveWithPrevious` would merge only `preferred` and leave `allow_yanked` empty, so a previous lock pinning a now-yanked version could never be rescued.

- [ ] **Step 1: Write the failing minimal-update tests**

```zig
test "resolve keeps previous versions when still valid" {
    const gpa = std.testing.allocator;
    // previous: shared=1.1; index now also has shared=1.2; req ^1.0 → still 1.1 (preferred beats max).
    const req = semver.OptVersionReq{ .req = try semver.VersionReq.parse("^1.0") };
    const shared_edges = [_]DepEdge{};
    const shared_nodes = [_]SummaryNode{
        .{ .name = "shared", .candidate = .{ .name = "shared", .version = try semver.Version.parse("1.1.0"), .yanked = false, .checksum = null, .rust_version = null, .pubtime = null }, .deps = &shared_edges, .links = null },
        .{ .name = "shared", .candidate = .{ .name = "shared", .version = try semver.Version.parse("1.2.0"), .yanked = false, .checksum = null, .rust_version = null, .pubtime = null }, .deps = &shared_edges, .links = null },
    };
    const Stub = struct {
        shared: []const SummaryNode,
        fn query(ctx: *anyopaque, name: []const u8) QueryError![]const SummaryNode {
            const self: *const @This() = @ptrCast(@alignCast(ctx));
            if (std.mem.eql(u8, name, "shared")) return self.shared;
            return &.{};
        }
    };
    var stub = Stub{ .shared = &shared_nodes };
    const registry = Registry{ .ctx = @ptrCast(&stub), .queryFn = &Stub.query };
    const app_edges = [_]DepEdge{.{ .name = "shared", .req = req, .optional = false, .build_only = false }};
    const roots = [_]SummaryNode{
        .{ .name = "app", .candidate = .{ .name = "app", .version = try semver.Version.parse("0.1.0"), .yanked = false, .checksum = null, .rust_version = null, .pubtime = null }, .deps = &app_edges, .links = null },
    };
    const prev_refs = [_]ResolvedRef{};
    const previous = [_]ResolvedNode{
        .{ .name = "shared", .version = try semver.Version.parse("1.1.0"), .source = .{ .registry = "sparse+https://github.com/rust-lang/crates.io-index" }, .deps = &prev_refs },
    };
    const base = index.QueryFilter{ .allow_yanked = &.{}, .max_pubtime = null, .min_versions_first = false, .rust_versions = &.{}, .preferred = &.{} };
    var graph = try resolveWithPrevious(gpa, &roots, registry, &previous, .{ .update_names = &.{} }, base);
    defer graph.deinit();
    try std.testing.expect(graph.find("shared", try semver.Version.parse("1.1.0")) != null);
    try std.testing.expect(graph.find("shared", try semver.Version.parse("1.2.0")) == null);
}

test "resolve drops previous version outside new req" {
    const gpa = std.testing.allocator;
    // previous: shared=1.1; manifest req tightened to ^1.2 → 1.2.0 (previous no longer matches, no assert trip).
    const req = semver.OptVersionReq{ .req = try semver.VersionReq.parse("^1.2") };
    const shared_edges = [_]DepEdge{};
    const shared_nodes = [_]SummaryNode{
        .{ .name = "shared", .candidate = .{ .name = "shared", .version = try semver.Version.parse("1.1.0"), .yanked = false, .checksum = null, .rust_version = null, .pubtime = null }, .deps = &shared_edges, .links = null },
        .{ .name = "shared", .candidate = .{ .name = "shared", .version = try semver.Version.parse("1.2.0"), .yanked = false, .checksum = null, .rust_version = null, .pubtime = null }, .deps = &shared_edges, .links = null },
    };
    const Stub = struct {
        shared: []const SummaryNode,
        fn query(ctx: *anyopaque, name: []const u8) QueryError![]const SummaryNode {
            const self: *const @This() = @ptrCast(@alignCast(ctx));
            if (std.mem.eql(u8, name, "shared")) return self.shared;
            return &.{};
        }
    };
    var stub = Stub{ .shared = &shared_nodes };
    const registry = Registry{ .ctx = @ptrCast(&stub), .queryFn = &Stub.query };
    const app_edges = [_]DepEdge{.{ .name = "shared", .req = req, .optional = false, .build_only = false }};
    const roots = [_]SummaryNode{
        .{ .name = "app", .candidate = .{ .name = "app", .version = try semver.Version.parse("0.1.0"), .yanked = false, .checksum = null, .rust_version = null, .pubtime = null }, .deps = &app_edges, .links = null },
    };
    const prev_refs = [_]ResolvedRef{};
    const previous = [_]ResolvedNode{
        .{ .name = "shared", .version = try semver.Version.parse("1.1.0"), .source = .{ .registry = "sparse+https://github.com/rust-lang/crates.io-index" }, .deps = &prev_refs },
    };
    const base = index.QueryFilter{ .allow_yanked = &.{}, .max_pubtime = null, .min_versions_first = false, .rust_versions = &.{}, .preferred = &.{} };
    var graph = try resolveWithPrevious(gpa, &roots, registry, &previous, .{ .update_names = &.{} }, base);
    defer graph.deinit();
    try std.testing.expect(graph.find("shared", try semver.Version.parse("1.2.0")) != null);
}

test "cargo update -p unlocks target plus transitive deps of non-kept" {
    const gpa = std.testing.allocator;
    // update_names = ["serde"]; previous serde=1.0+log=1.0; index adds serde=2.0 (needs log ^2.0).
    // → serde=2.0, log=2.0 (log unlocked as transitive dep of non-kept serde, re-resolved fresh).
    const req_serde = semver.OptVersionReq{ .req = try semver.VersionReq.parse("^1") };
    const req_log1 = semver.OptVersionReq{ .req = try semver.VersionReq.parse("^1.0") };
    const req_log2 = semver.OptVersionReq{ .req = try semver.VersionReq.parse("^2.0") };
    const serde1_edges = [_]DepEdge{.{ .name = "log", .req = req_log1, .optional = false, .build_only = false }};
    const serde2_edges = [_]DepEdge{.{ .name = "log", .req = req_log2, .optional = false, .build_only = false }};
    const serde_nodes = [_]SummaryNode{
        .{ .name = "serde", .candidate = .{ .name = "serde", .version = try semver.Version.parse("1.0.0"), .yanked = false, .checksum = null, .rust_version = null, .pubtime = null }, .deps = &serde1_edges, .links = null },
        .{ .name = "serde", .candidate = .{ .name = "serde", .version = try semver.Version.parse("2.0.0"), .yanked = false, .checksum = null, .rust_version = null, .pubtime = null }, .deps = &serde2_edges, .links = null },
    };
    const log_nodes = [_]SummaryNode{
        .{ .name = "log", .candidate = .{ .name = "log", .version = try semver.Version.parse("1.0.0"), .yanked = false, .checksum = null, .rust_version = null, .pubtime = null }, .deps = &.{}, .links = null },
        .{ .name = "log", .candidate = .{ .name = "log", .version = try semver.Version.parse("2.0.0"), .yanked = false, .checksum = null, .rust_version = null, .pubtime = null }, .deps = &.{}, .links = null },
    };
    const Stub = struct {
        serde: []const SummaryNode,
        log: []const SummaryNode,
        fn query(ctx: *anyopaque, name: []const u8) QueryError![]const SummaryNode {
            const self: *const @This() = @ptrCast(@alignCast(ctx));
            if (std.mem.eql(u8, name, "serde")) return self.serde;
            if (std.mem.eql(u8, name, "log")) return self.log;
            return &.{};
        }
    };
    var stub = Stub{ .serde = &serde_nodes, .log = &log_nodes };
    const registry = Registry{ .ctx = @ptrCast(&stub), .queryFn = &Stub.query };
    const app_edges = [_]DepEdge{.{ .name = "serde", .req = req_serde, .optional = false, .build_only = false }};
    const roots = [_]SummaryNode{
        .{ .name = "app", .candidate = .{ .name = "app", .version = try semver.Version.parse("0.1.0"), .yanked = false, .checksum = null, .rust_version = null, .pubtime = null }, .deps = &app_edges, .links = null },
    };
    const reg: sources.SourceId = .{ .registry = "sparse+https://github.com/rust-lang/crates.io-index" };
    const serde_prev_deps = [_]ResolvedRef{.{ .name = "log", .version = try semver.Version.parse("1.0.0"), .source = reg }};
    const previous = [_]ResolvedNode{
        .{ .name = "serde", .version = try semver.Version.parse("1.0.0"), .source = reg, .deps = &serde_prev_deps },
        .{ .name = "log", .version = try semver.Version.parse("1.0.0"), .source = reg, .deps = &.{} },
    };
    const base = index.QueryFilter{ .allow_yanked = &.{}, .max_pubtime = null, .min_versions_first = false, .rust_versions = &.{}, .preferred = &.{} };
    const names = [_][]const u8{"serde"};
    var graph = try resolveWithPrevious(gpa, &roots, registry, &previous, .{ .update_names = &names }, base);
    defer graph.deinit();
    try std.testing.expect(graph.find("serde", try semver.Version.parse("2.0.0")) != null);
    try std.testing.expect(graph.find("log", try semver.Version.parse("2.0.0")) != null);
}

test "precise pins exact version or errors" {
    const gpa = std.testing.allocator;
    // precise log=1.0.5 with candidates {1.0.5, 1.0.9} and req ^1.0.0 → 1.0.5; precise log=9.9.9 → NoMatchingVersion.
    const req = semver.OptVersionReq{ .req = try semver.VersionReq.parse("^1.0.0") };
    const log_nodes = [_]SummaryNode{
        .{ .name = "log", .candidate = .{ .name = "log", .version = try semver.Version.parse("1.0.5"), .yanked = false, .checksum = null, .rust_version = null, .pubtime = null }, .deps = &.{}, .links = null },
        .{ .name = "log", .candidate = .{ .name = "log", .version = try semver.Version.parse("1.0.9"), .yanked = false, .checksum = null, .rust_version = null, .pubtime = null }, .deps = &.{}, .links = null },
    };
    const Stub = struct {
        log: []const SummaryNode,
        fn query(ctx: *anyopaque, name: []const u8) QueryError![]const SummaryNode {
            const self: *const @This() = @ptrCast(@alignCast(ctx));
            if (std.mem.eql(u8, name, "log")) return self.log;
            return &.{};
        }
    };
    var stub = Stub{ .log = &log_nodes };
    const registry = Registry{ .ctx = @ptrCast(&stub), .queryFn = &Stub.query };
    const app_edges = [_]DepEdge{.{ .name = "log", .req = req, .optional = false, .build_only = false }};
    const roots = [_]SummaryNode{
        .{ .name = "app", .candidate = .{ .name = "app", .version = try semver.Version.parse("0.1.0"), .yanked = false, .checksum = null, .rust_version = null, .pubtime = null }, .deps = &app_edges, .links = null },
    };
    const base = index.QueryFilter{ .allow_yanked = &.{}, .max_pubtime = null, .min_versions_first = false, .rust_versions = &.{}, .preferred = &.{} };
    const ok_names = [_][]const u8{"log"};
    var graph = try resolveWithPrevious(gpa, &roots, registry, null, .{ .update_names = &ok_names, .precise = .{ .name = "log", .version = try semver.Version.parse("1.0.5") } }, base);
    defer graph.deinit();
    try std.testing.expect(graph.find("log", try semver.Version.parse("1.0.5")) != null);
    try std.testing.expect(graph.find("log", try semver.Version.parse("1.0.9")) == null);
    try std.testing.expectError(ResolveError.NoMatchingVersion, resolveWithPrevious(gpa, &roots, registry, null, .{ .update_names = &ok_names, .precise = .{ .name = "log", .version = try semver.Version.parse("9.9.9") } }, base));
}

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test 2>&1 | tail -10`
Expected: FAIL — `resolveWithPrevious` / `KeepFilter` not defined.

- [ ] **Step 3: Write minimal implementation**

`resolveWithPrevious`: compute keep-set (names kept = all-previous-names minus `update_names` closure — closure computed over previous edges: BFS from update_names following dep edges; those nodes lose locks); build per-edge `OptVersionReq` rewrites (Locked for kept, Precise for the `KeepFilter.precise` target — Task 9 parses the CLI form `name=version`/`name@version` into `PrecisePin`); merge `preferred` AND `allow_yanked` (kept locked versions + precise target version, unioned with `base_filter.allow_yanked` per (6)) into a cloned `QueryFilter`; delegate to `resolveGraph`. Keep-set BFS needs previous-edge lookup: linear scan is fine (document O(n²) acceptable for lockfiles <10k packages; no perf work in M3).

- [ ] **Step 4: Run tests to verify they pass**

Run: `zig build test 2>&1 | tail -5`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
jj status
jj commit src/cargo/resolve.zig -m "Add previous-lock minimal update guidance"
```

---

### Task 5: Feature unification v1 (+ second-pass narrowing core)

**Files:**
- Create: `src/cargo/features.zig` (part 1: v1 model + unification)
- Test: inline tests in `src/cargo/features.zig`
- Modify: `src/cargo/root.zig` (append `pub const features = @import("features.zig");`)

**Interfaces:**
- Consumes: `resolve.ResolveGraph` (Task 3) for node set; manifest feature tables (M1 `manifest.zig` — Task 5 adds `features: StringHashMap([]FeatureValue)` parsing there ONLY if missing; check first and reuse).
- Produces (used by Task 6 + Task 9 CLI `-F` flags):
```zig
pub const FeatureValue = union(enum) {
    dep: []const u8,                 // "dep-name" (enables optional dep's implicit feature)
    dep_named: []const u8,           // "dep:dep-name" (enables dep WITHOUT its implicit feature)
    dep_feature: struct { dep: []const u8, feat: []const u8 }, // "dep-name/feat"
    weak_feature: struct { dep: []const u8, feat: []const u8 }, // "dep-name?/feat" (only if dep enabled)
    own: []const u8,                 // enables another feature of the same package
};
pub const FeatureMap = struct {
    default: []const []const u8,
    optional_deps: []const []const u8, // implicit same-name features (non-`dep:` optionals)
    rules: []const FeatureRule,
};
pub const FeatureRule = struct { feature: []const u8, values: []const FeatureValue };
pub const Unified = struct {
    features: std.StringHashMap(std.StringHashMap(void)), // pkg name → enabled feature set
    enabled_deps: std.StringHashMap(std.StringHashMap(void)), // pkg name → enabled optional-dep names
    pub fn deinit(self: *Unified) void;
    pub fn isEnabled(self: *const Unified, pkg: []const u8, feat: []const u8) bool;
};
pub fn unifyV1(gpa: std.mem.Allocator, graph: *const resolve.ResolveGraph, maps: *const std.StringHashMap(FeatureMap), roots: []const RootReq) UnifiedError!Unified;
pub const RootReq = struct { package: []const u8, features: []const []const u8, all_features: bool, no_default: bool };
pub const DepFeatures = struct { features: []const []const u8, uses_default: bool }; // v1 test tables carry per-edge default-features choice in this form (production carrier is Task-7 DepEdgeFull.uses_default/dep_features)
pub const UnifiedError = error{ UnknownFeature, OutOfMemory };
pub fn pruneOptional(gpa: std.mem.Allocator, graph: *const resolve.ResolveGraph, unified: *const Unified) UnifiedError![]const resolve.ResolvedNode; // surviving node set (caller frees); drops disabled-optional nodes + orphaned subtrees
```

Reference pins: `features.rs` module docs (two-pass: resolver unifies v1-style first) + `core/summary.rs` feature-map building (implicit optional-dep features) + `core/features.rs` validation (unknown feature = hard error naming feature + package).

Semantics v1 (exact): single global namespace per package — ALL requests for `(pkg)` merge regardless of which parent, which dep-kind, or which target requested them. Order: start from each root's requested features (`features`, `all_features` = every key incl. `default`, `no_default` skips `default`); enabling a feature applies its rule values: `own` → enable own feature (recurse); `dep` → enable optional dep + its implicit feature; `dep_named` → enable dep only; `dep_feature` → enable dep + request `feat` on it (recurse into dep's map); `weak_feature` → request `feat` ONLY if dep already enabled (NEVER enables the dep itself). Enabling an optional dep pulls that dep's `default` features unless the edge says otherwise (dep-level `default-features = false` arrives via Task 7's edge data; v1 test tables carry a `uses_default: bool` per edge — define `DepFeatures{features, uses_default}` alongside `RootReq`). Unknown feature name on any enabled package → `UnknownFeature` (message text in Task 9). Cycles in feature rules terminate (enabled-set fixpoint, not recursion depth).

Resolver interplay (wire in this task): `resolve.zig`'s `DepEdge.optional` deps are INCLUDED in the graph only when `unifyV1(...).enabled_deps` contains them — implement `pruneOptional(graph, unified)` here (takes graph + unified, returns node set minus disabled optionals and their now-orphaned subtrees). Document the two-pass order: resolve with all-features-enabled assumption → unify → prune → re-check (cargo iterate: `resolve_ws_with_opts` resolves once with everything, then the targeted resolve narrows; for rime M3 the loop is resolve → unifyV1 → prune → done, since versions never depend on features for correctness of the VERSION selection — cite `features.rs` docs "second pass can only narrow").

- [ ] **Step 1: Write the failing unification tests**

```zig
test "v1 unifies features across parents" {
    const gpa = std.testing.allocator;
    // app → left (feat f → shared/feat-a), app → right (feat g → shared/feat-b).
    // unified shared has BOTH feat-a and feat-b (v1 single namespace).
    const reg: sources.SourceId = .{ .registry = "sparse+https://github.com/rust-lang/crates.io-index" };
    const v100 = try semver.Version.parse("1.0.0");
    const left_refs = [_]resolve.ResolvedRef{.{ .name = "shared", .version = v100, .source = reg }};
    const right_refs = [_]resolve.ResolvedRef{.{ .name = "shared", .version = v100, .source = reg }};
    const app_refs = [_]resolve.ResolvedRef{
        .{ .name = "left", .version = v100, .source = reg },
        .{ .name = "right", .version = v100, .source = reg },
    };
    const nodes = [_]resolve.ResolvedNode{
        .{ .name = "app", .version = v100, .source = reg, .deps = &app_refs },
        .{ .name = "left", .version = v100, .source = reg, .deps = &left_refs },
        .{ .name = "right", .version = v100, .source = reg, .deps = &right_refs },
        .{ .name = "shared", .version = v100, .source = reg, .deps = &.{} },
    };
    var graph = resolve.ResolveGraph{ .arena = std.heap.ArenaAllocator.init(gpa), .nodes = &nodes };
    defer graph.deinit();
    const left_rules = [_]FeatureRule{
        .{ .feature = "f", .values = &[_]FeatureValue{.{ .dep_feature = .{ .dep = "shared", .feat = "feat-a" } }} },
    };
    const right_rules = [_]FeatureRule{
        .{ .feature = "g", .values = &[_]FeatureValue{.{ .dep_feature = .{ .dep = "shared", .feat = "feat-b" } }} },
    };
    var maps = std.StringHashMap(FeatureMap).init(gpa);
    defer maps.deinit();
    try maps.put("left", .{ .default = &.{}, .optional_deps = &.{}, .rules = &left_rules });
    try maps.put("right", .{ .default = &.{}, .optional_deps = &.{}, .rules = &right_rules });
    try maps.put("shared", .{ .default = &.{}, .optional_deps = &.{}, .rules = &.{} });
    const roots = [_]RootReq{
        .{ .package = "left", .features = &[_][]const u8{"f"}, .all_features = false, .no_default = true },
        .{ .package = "right", .features = &[_][]const u8{"g"}, .all_features = false, .no_default = true },
    };
    var u = try unifyV1(gpa, &graph, &maps, &roots);
    defer u.deinit();
    try std.testing.expect(u.isEnabled("shared", "feat-a"));
    try std.testing.expect(u.isEnabled("shared", "feat-b"));
}

test "weak dep feature does not enable the dep" {
    const gpa = std.testing.allocator;
    const reg: sources.SourceId = .{ .registry = "sparse+https://github.com/rust-lang/crates.io-index" };
    const v100 = try semver.Version.parse("1.0.0");
    const nodes = [_]resolve.ResolvedNode{
        .{ .name = "app", .version = v100, .source = reg, .deps = &.{} },
        .{ .name = "opt", .version = v100, .source = reg, .deps = &.{} },
    };
    var graph = resolve.ResolveGraph{ .arena = std.heap.ArenaAllocator.init(gpa), .nodes = &nodes };
    defer graph.deinit();
    // rule f = ["opt?/feat"]; opt NOT otherwise enabled → opt stays disabled, feat not applied.
    const app_rules = [_]FeatureRule{
        .{ .feature = "f", .values = &[_]FeatureValue{.{ .weak_feature = .{ .dep = "opt", .feat = "feat" } }} },
    };
    var maps = std.StringHashMap(FeatureMap).init(gpa);
    defer maps.deinit();
    try maps.put("app", .{ .default = &.{}, .optional_deps = &[_][]const u8{"opt"}, .rules = &app_rules });
    try maps.put("opt", .{ .default = &[_][]const u8{"feat"}, .optional_deps = &.{}, .rules = &.{} });
    const roots_off = [_]RootReq{
        .{ .package = "app", .features = &[_][]const u8{"f"}, .all_features = false, .no_default = true },
    };
    var u_off = try unifyV1(gpa, &graph, &maps, &roots_off);
    defer u_off.deinit();
    try std.testing.expect(!u_off.isEnabled("opt", "feat"));
    // Same rule with opt enabled elsewhere → feat applied, opt enabled.
    const roots_on = [_]RootReq{
        .{ .package = "app", .features = &[_][]const u8{ "f", "opt" }, .all_features = false, .no_default = true },
    };
    var u_on = try unifyV1(gpa, &graph, &maps, &roots_on);
    defer u_on.deinit();
    try std.testing.expect(u_on.isEnabled("opt", "feat"));
}

test "dep-colon syntax skips implicit feature" {
    const gpa = std.testing.allocator;
    // rule f = ["dep:opt"] → opt enabled but app's own implicit feature "opt" NOT marked.
    const reg: sources.SourceId = .{ .registry = "sparse+https://github.com/rust-lang/crates.io-index" };
    const v100 = try semver.Version.parse("1.0.0");
    const nodes = [_]resolve.ResolvedNode{
        .{ .name = "app", .version = v100, .source = reg, .deps = &.{} },
        .{ .name = "opt", .version = v100, .source = reg, .deps = &.{} },
    };
    var graph = resolve.ResolveGraph{ .arena = std.heap.ArenaAllocator.init(gpa), .nodes = &nodes };
    defer graph.deinit();
    const app_rules = [_]FeatureRule{
        .{ .feature = "f", .values = &[_]FeatureValue{.{ .dep_named = "opt" }} },
    };
    var maps = std.StringHashMap(FeatureMap).init(gpa);
    defer maps.deinit();
    try maps.put("app", .{ .default = &.{}, .optional_deps = &[_][]const u8{"opt"}, .rules = &app_rules });
    try maps.put("opt", .{ .default = &.{}, .optional_deps = &.{}, .rules = &.{} });
    const roots = [_]RootReq{
        .{ .package = "app", .features = &[_][]const u8{"f"}, .all_features = false, .no_default = true },
    };
    var u = try unifyV1(gpa, &graph, &maps, &roots);
    defer u.deinit();
    const deps_of_app = u.enabled_deps.get("app");
    try std.testing.expect(deps_of_app != null and deps_of_app.?.contains("opt"));
    try std.testing.expect(!u.isEnabled("app", "opt"));
}

test "unknown feature errors" {
    const gpa = std.testing.allocator;
    const reg: sources.SourceId = .{ .registry = "sparse+https://github.com/rust-lang/crates.io-index" };
    const v100 = try semver.Version.parse("1.0.0");
    const nodes = [_]resolve.ResolvedNode{
        .{ .name = "app", .version = v100, .source = reg, .deps = &.{} },
    };
    var graph = resolve.ResolveGraph{ .arena = std.heap.ArenaAllocator.init(gpa), .nodes = &nodes };
    defer graph.deinit();
    var maps = std.StringHashMap(FeatureMap).init(gpa);
    defer maps.deinit();
    try maps.put("app", .{ .default = &[_][]const u8{"std"}, .optional_deps = &.{}, .rules = &.{} });
    const roots = [_]RootReq{
        .{ .package = "app", .features = &[_][]const u8{"nope"}, .all_features = false, .no_default = true },
    };
    try std.testing.expectError(UnifiedError.UnknownFeature, unifyV1(gpa, &graph, &maps, &roots));
}

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test 2>&1 | tail -10`
Expected: FAIL — `features.zig` / `unifyV1` not defined.

- [ ] **Step 3: Write minimal implementation**

Worklist fixpoint over `(pkg, feature)` enables; per-package `StringHashMap(void)` sets; `enabled_deps` parallel sets; weak-application check at apply time (if dep enabled LATER, the weak value must still apply — so re-process all rules of newly-enabled deps AND re-scan weak rules when a dep flips on: simplest correct loop is "repeat full scan until no change", document O(rules × features) is fine for M3).

- [ ] **Step 4: Run tests to verify they pass + prune test**

```zig
test "pruneOptional removes disabled optional subtree" {
    const gpa = std.testing.allocator;
    // graph has app → opt (optional, disabled) → sub; after prune, opt and sub gone, app kept.
    const reg: sources.SourceId = .{ .registry = "sparse+https://github.com/rust-lang/crates.io-index" };
    const v100 = try semver.Version.parse("1.0.0");
    const opt_refs = [_]resolve.ResolvedRef{.{ .name = "sub", .version = v100, .source = reg }};
    const app_refs = [_]resolve.ResolvedRef{.{ .name = "opt", .version = v100, .source = reg }};
    const nodes = [_]resolve.ResolvedNode{
        .{ .name = "app", .version = v100, .source = reg, .deps = &app_refs },
        .{ .name = "opt", .version = v100, .source = reg, .deps = &opt_refs },
        .{ .name = "sub", .version = v100, .source = reg, .deps = &.{} },
    };
    var graph = resolve.ResolveGraph{ .arena = std.heap.ArenaAllocator.init(gpa), .nodes = &nodes };
    defer graph.deinit();
    var maps = std.StringHashMap(FeatureMap).init(gpa);
    defer maps.deinit();
    try maps.put("app", .{ .default = &.{}, .optional_deps = &[_][]const u8{"opt"}, .rules = &.{} });
    try maps.put("opt", .{ .default = &.{}, .optional_deps = &.{}, .rules = &.{} });
    try maps.put("sub", .{ .default = &.{}, .optional_deps = &.{}, .rules = &.{} });
    const roots = [_]RootReq{
        .{ .package = "app", .features = &.{}, .all_features = false, .no_default = true },
    };
    var u = try unifyV1(gpa, &graph, &maps, &roots);
    defer u.deinit();
    const kept = try pruneOptional(gpa, &graph, &u);
    defer gpa.free(kept);
    try std.testing.expectEqual(@as(usize, 1), kept.len);
    try std.testing.expectEqualStrings("app", kept[0].name);
}
```

Run: `zig build test 2>&1 | tail -5`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
jj status
jj commit src/cargo/features.zig src/cargo/root.zig -m "Add v1 feature unification"
```

---

### Task 6: Feature resolver v2/v3 (decoupled namespaces)

**Files:**
- Modify: `src/cargo/features.zig` (add `FeatureOpts`, `FeaturesFor`, `unify` dispatcher), `src/cargo/manifest.zig` ONLY if `resolver` field parsing is missing (check first: parse `resolver = "2"` from `[workspace]` + edition-based default).
- Test: inline tests in `src/cargo/features.zig`

**Interfaces:**
- Consumes: Task 5 `unifyV1` + Task 3 `DepEdge{build_only}` + a new per-edge `for_host: bool` and target-activity flag supplied by the caller (Task 7 fills real values; tests use literals).
- Produces (used by Task 7 + Task 11 fixtures):
```zig
pub const Behavior = enum { v1, v2, v3 }; // from_manifest("1"|"2"|"3"); v3 == v2 for features (pins version-prefs only)
pub const FeatureOpts = struct {
    decouple_host_deps: bool,
    decouple_dev_deps: bool, // false when building dev units even under v2 (HasDevUnits::Yes rule)
    ignore_inactive_targets: bool,
    pub fn forBehavior(b: Behavior, has_dev_units: bool) FeatureOpts;
};
pub const FeaturesFor = enum { normal_or_dev, host_dep };
pub fn unify(gpa: std.mem.Allocator, graph: *const resolve.ResolveGraph, maps: *const std.StringHashMap(FeatureMap), roots: []const RootReq, opts: FeatureOpts, edgeKind: *const fn (parent: []const u8, dep: []const u8) EdgeKind) UnifiedError!UnifiedNamespaces;
pub const EdgeKind = struct { for_host: bool, target_active: bool, is_dev: bool = false }; // NOTE: edgeKind stays a pure name-pair callback (tests use literals; no fetcher state or failure modes), unlike Registry.queryFn which threads M2 state with a fallible ctx query. is_dev marks dev-dependency edges (Task 7 DepEdgeFull.is_dev is the production carrier; tests use literals).
pub const NsSets = struct {
    normal_or_dev: std.StringHashMap(void), // features enabled in the normal/dev namespace
    host_dep: std.StringHashMap(void),      // features enabled in the host-dep namespace (build-deps/proc-macros under v2)
    pub fn deinit(self: *NsSets) void;
};
pub const UnifiedNamespaces = struct {
    // (pkg, FeaturesFor) → feature set; v1 callers use normal_or_dev for everything.
    inner: std.StringHashMap(NsSets),
    quarantined: std.StringHashMap(std.StringHashMap(void)), // dev-dep quarantine namespace (test-only reads)
    pub fn deinit(self: *UnifiedNamespaces) void;
    pub fn isEnabled(self: *const UnifiedNamespaces, pkg: []const u8, which: FeaturesFor, feat: []const u8) bool;
    pub fn isEnabledQuarantined(self: *const UnifiedNamespaces, pkg: []const u8, feat: []const u8) bool; // tests ONLY, never build planning
};
```

Reference pins: `features.rs::FeatureOpts::new_behavior` (exact flag table — copy into a comment) + `FeaturesFor::{from_for_host, apply_opts}` (v1 collapses via `apply_opts`) + `FeatureOpts::new` (`HasDevUnits::Yes → decouple_dev_deps = false`; `ForceAllTargets::Yes → ignore_inactive_targets = false` — rime's `has_dev_units`/`force_all_targets` params mirror these) + `workspace.rs::resolve_behavior` + `types.rs::ResolveBehavior::from_manifest` (behavior source: root `resolver` field; `"3"` accepted).

Semantics (exact): key EVERYTHING by `(pkg, FeaturesFor)`: `for_host` (build-deps, proc-macros) → `host_dep` namespace when `decouple_host_deps`, else merged. Dev-deps of non-dev builds → separate tracking that never pollutes normal features when `decouple_dev_deps` (rime models dev edges with `for_host=false` + a `is_dev: bool` on the edge query — extend `EdgeKind` with `is_dev`; dev requests from roots with `has_dev_units=false` unify into a quarantined namespace that `pruneOptional`/build planning ignores). `ignore_inactive_targets`: edges whose `target_active=false` contribute NO features and their optional deps stay disabled (v1: target cfg still gates the DEP edge itself — Task 7 — but features leak across; v2: no leak). `v3 == v2` for unification (v3 only changes version preferences — Task 2's rust-version ordering already covers it; assert this mapping in a test). `unify` with all-false opts MUST equal `unifyV1` output (property test on the Task 5 fixtures — guarantees the v1/v2 code path split doesn't drift).

- [ ] **Step 1: Write the failing decouple tests**

```zig
test "v2 does not unify build-dep features into normal deps" {
    const gpa = std.testing.allocator;
    // shared built normally (feat normal-only) AND as build-dep of tool (feat host-only).
    // v1: shared has both. v2: normal namespace has normal-only; host namespace has host-only.
    const reg: sources.SourceId = .{ .registry = "sparse+https://github.com/rust-lang/crates.io-index" };
    const v100 = try semver.Version.parse("1.0.0");
    const app_refs = [_]resolve.ResolvedRef{.{ .name = "shared", .version = v100, .source = reg }};
    const tool_refs = [_]resolve.ResolvedRef{.{ .name = "shared", .version = v100, .source = reg }};
    const nodes = [_]resolve.ResolvedNode{
        .{ .name = "app", .version = v100, .source = reg, .deps = &app_refs },
        .{ .name = "tool", .version = v100, .source = reg, .deps = &tool_refs },
        .{ .name = "shared", .version = v100, .source = reg, .deps = &.{} },
    };
    var graph = resolve.ResolveGraph{ .arena = std.heap.ArenaAllocator.init(gpa), .nodes = &nodes };
    defer graph.deinit();
    const app_rules = [_]FeatureRule{
        .{ .feature = "f", .values = &[_]FeatureValue{.{ .dep_feature = .{ .dep = "shared", .feat = "normal-only" } }} },
    };
    const tool_rules = [_]FeatureRule{
        .{ .feature = "h", .values = &[_]FeatureValue{.{ .dep_feature = .{ .dep = "shared", .feat = "host-only" } }} },
    };
    var maps = std.StringHashMap(FeatureMap).init(gpa);
    defer maps.deinit();
    try maps.put("app", .{ .default = &.{}, .optional_deps = &.{}, .rules = &app_rules });
    try maps.put("tool", .{ .default = &.{}, .optional_deps = &.{}, .rules = &tool_rules });
    try maps.put("shared", .{ .default = &.{}, .optional_deps = &.{}, .rules = &.{} });
    const roots = [_]RootReq{
        .{ .package = "app", .features = &[_][]const u8{"f"}, .all_features = false, .no_default = true },
        .{ .package = "tool", .features = &[_][]const u8{"h"}, .all_features = false, .no_default = true },
    };
    const Kinds = struct {
        fn edge(parent: []const u8, dep: []const u8) EdgeKind {
            if (std.mem.eql(u8, parent, "tool") and std.mem.eql(u8, dep, "shared"))
                return .{ .for_host = true, .target_active = true };
            return .{ .for_host = false, .target_active = true };
        }
    };
    var v1 = try unifyV1(gpa, &graph, &maps, &roots);
    defer v1.deinit();
    try std.testing.expect(v1.isEnabled("shared", "normal-only"));
    try std.testing.expect(v1.isEnabled("shared", "host-only"));
    var v2 = try unify(gpa, &graph, &maps, &roots, FeatureOpts.forBehavior(.v2, false), &Kinds.edge);
    defer v2.deinit();
    try std.testing.expect(v2.isEnabled("shared", .normal_or_dev, "normal-only"));
    try std.testing.expect(!v2.isEnabled("shared", .normal_or_dev, "host-only"));
    try std.testing.expect(v2.isEnabled("shared", .host_dep, "host-only"));
    try std.testing.expect(!v2.isEnabled("shared", .host_dep, "normal-only"));
}

test "v2 dev-deps stay quarantined without dev units" {
    const gpa = std.testing.allocator;
    // app dev-dep dtest enables feat-x on shared; normal path does not.
    // has_dev_units=false → normal shared lacks feat-x; has_dev_units=true → unified (HasDevUnits::Yes rule).
    const reg: sources.SourceId = .{ .registry = "sparse+https://github.com/rust-lang/crates.io-index" };
    const v100 = try semver.Version.parse("1.0.0");
    const app_refs = [_]resolve.ResolvedRef{
        .{ .name = "shared", .version = v100, .source = reg },
        .{ .name = "dtest", .version = v100, .source = reg },
    };
    const dtest_refs = [_]resolve.ResolvedRef{.{ .name = "shared", .version = v100, .source = reg }};
    const nodes = [_]resolve.ResolvedNode{
        .{ .name = "app", .version = v100, .source = reg, .deps = &app_refs },
        .{ .name = "dtest", .version = v100, .source = reg, .deps = &dtest_refs },
        .{ .name = "shared", .version = v100, .source = reg, .deps = &.{} },
    };
    var graph = resolve.ResolveGraph{ .arena = std.heap.ArenaAllocator.init(gpa), .nodes = &nodes };
    defer graph.deinit();
    const dtest_rules = [_]FeatureRule{
        .{ .feature = "t", .values = &[_]FeatureValue{.{ .dep_feature = .{ .dep = "shared", .feat = "feat-x" } }} },
    };
    var maps = std.StringHashMap(FeatureMap).init(gpa);
    defer maps.deinit();
    try maps.put("app", .{ .default = &.{}, .optional_deps = &.{}, .rules = &.{} });
    try maps.put("dtest", .{ .default = &.{}, .optional_deps = &.{}, .rules = &dtest_rules });
    try maps.put("shared", .{ .default = &.{}, .optional_deps = &.{}, .rules = &.{} });
    const roots = [_]RootReq{
        .{ .package = "app", .features = &.{}, .all_features = false, .no_default = true },
        .{ .package = "dtest", .features = &[_][]const u8{"t"}, .all_features = false, .no_default = true },
    };
    const Kinds = struct {
        fn edge(parent: []const u8, dep: []const u8) EdgeKind {
            if (std.mem.eql(u8, parent, "app") and std.mem.eql(u8, dep, "dtest"))
                return .{ .for_host = false, .target_active = true, .is_dev = true };
            return .{ .for_host = false, .target_active = true };
        }
    };
    var cold = try unify(gpa, &graph, &maps, &roots, FeatureOpts.forBehavior(.v2, false), &Kinds.edge);
    defer cold.deinit();
    try std.testing.expect(!cold.isEnabled("shared", .normal_or_dev, "feat-x"));
    try std.testing.expect(cold.isEnabledQuarantined("shared", "feat-x"));
    var hot = try unify(gpa, &graph, &maps, &roots, FeatureOpts.forBehavior(.v2, true), &Kinds.edge);
    defer hot.deinit();
    try std.testing.expect(hot.isEnabled("shared", .normal_or_dev, "feat-x"));
}

test "v1 opts equal unifyV1" {
    const gpa = std.testing.allocator;
    // replay Task 5's cross-parent fixture through unify(all-false) and unifyV1; assert identical sets.
    const reg: sources.SourceId = .{ .registry = "sparse+https://github.com/rust-lang/crates.io-index" };
    const v100 = try semver.Version.parse("1.0.0");
    const left_refs = [_]resolve.ResolvedRef{.{ .name = "shared", .version = v100, .source = reg }};
    const right_refs = [_]resolve.ResolvedRef{.{ .name = "shared", .version = v100, .source = reg }};
    const nodes = [_]resolve.ResolvedNode{
        .{ .name = "left", .version = v100, .source = reg, .deps = &left_refs },
        .{ .name = "right", .version = v100, .source = reg, .deps = &right_refs },
        .{ .name = "shared", .version = v100, .source = reg, .deps = &.{} },
    };
    var graph = resolve.ResolveGraph{ .arena = std.heap.ArenaAllocator.init(gpa), .nodes = &nodes };
    defer graph.deinit();
    const left_rules = [_]FeatureRule{
        .{ .feature = "f", .values = &[_]FeatureValue{.{ .dep_feature = .{ .dep = "shared", .feat = "feat-a" } }} },
    };
    const right_rules = [_]FeatureRule{
        .{ .feature = "g", .values = &[_]FeatureValue{.{ .dep_feature = .{ .dep = "shared", .feat = "feat-b" } }} },
    };
    var maps = std.StringHashMap(FeatureMap).init(gpa);
    defer maps.deinit();
    try maps.put("left", .{ .default = &.{}, .optional_deps = &.{}, .rules = &left_rules });
    try maps.put("right", .{ .default = &.{}, .optional_deps = &.{}, .rules = &right_rules });
    try maps.put("shared", .{ .default = &.{}, .optional_deps = &.{}, .rules = &.{} });
    const roots = [_]RootReq{
        .{ .package = "left", .features = &[_][]const u8{"f"}, .all_features = false, .no_default = true },
        .{ .package = "right", .features = &[_][]const u8{"g"}, .all_features = false, .no_default = true },
    };
    const Kinds = struct {
        fn edge(parent: []const u8, dep: []const u8) EdgeKind {
            _ = parent;
            _ = dep;
            return .{ .for_host = false, .target_active = true };
        }
    };
    var v1 = try unifyV1(gpa, &graph, &maps, &roots);
    defer v1.deinit();
    var u = try unify(gpa, &graph, &maps, &roots, FeatureOpts.forBehavior(.v1, false), &Kinds.edge);
    defer u.deinit();
    for ([_][]const u8{ "feat-a", "feat-b" }) |feat| {
        try std.testing.expectEqual(v1.isEnabled("shared", feat), u.isEnabled("shared", .normal_or_dev, feat));
    }
}

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test 2>&1 | tail -10`
Expected: FAIL — `FeatureOpts` / `unify` not defined.

- [ ] **Step 3: Write minimal implementation**

`unify`: same worklist as v1 but keyed `(pkg_idx, FeaturesFor)`; `EdgeKind` callback decides namespace per edge traversal; inactive-target edges skipped at enqueue when `ignore_inactive_targets`; dev-edge requests routed to quarantine namespace when `decouple_dev_deps` (quarantine = third implicit namespace; expose `isEnabledQuarantined` ONLY for tests, never for build planning). `forBehavior`: v1 → all false; v2/v3 → `{true, !has_dev_units, true}`.

- [ ] **Step 4: Run tests to verify they pass**

Run: `zig build test 2>&1 | tail -5`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
jj status
jj commit src/cargo/features.zig -m "Add v2 feature decoupling"
```

---

### Task 7: Platform gates, workspace/path/git edges, source identities

**Files:**
- Create: `src/cargo/sources.zig`
- Test: inline tests in `src/cargo/sources.zig`
- Modify: `src/cargo/root.zig` (append `pub const sources = @import("sources.zig");`)

**Interfaces:**
- Consumes: `semver` (Task 1), M1 `manifest.DependencyKind/GistSpec` (extends, never redefines).
- Produces (used by Tasks 8, 10, M2 fetcher seam):
```zig
pub const SourceId = union(enum) {
    path: []const u8,                    // normalized absolute dir (arena-owned by caller)
    registry: []const u8,                // normalized index URL, e.g. "sparse+https://…"
    git: struct { url: []const u8, ref: GitRef, precise: ?[40]u8 },
    pub fn isPath(self: SourceId) bool;
    pub const LockLineError = error{OutOfMemory};
    pub fn lockSourceLine(gpa: std.mem.Allocator, self: SourceId, version: LockVersion) LockLineError!?[]u8; // caller frees non-null; null for path (portable rule)
};
pub const GitRef = union(enum) { branch: []const u8, tag: []const u8, rev: []const u8, default_branch: void };
pub const LockVersion = enum { v1, v2, v3, v4 };
pub const Platform = union(enum) {
    name: []const u8,        // "windows", "unix", … (cfg shorthand cargo supports bare)
    cfg_expr: []const u8,    // raw `cfg(…)` text for exact evaluation
    pub fn matches(self: Platform, target: TargetInfo) bool;
};
pub const TargetInfo = struct { triple: []const u8, os: []const u8, arch: []const u8, family: []const u8 };
pub fn parseCfg(gpa: std.mem.Allocator, text: []const u8) CfgError!CfgExpr; // cfg(all/any/not, key = value, bare)
pub const DepEdgeFull = struct {
    base: resolve.DepEdge,               // Task-3 edge (name + req + optional + build_only)
    platform: ?Platform,                 // [target.cfg(…).dependencies] gate
    uses_default: bool,                  // default-features (default true)
    dep_features: []const []const u8,    // `features = […]` on the edge
    source: SourceId,                    // registry|path|git chosen for this edge
    is_dev: bool,                        // dev-dependency (Task 6 quarantine + resolve dev_deps flag)
};
```

Reference pins: `core/dependency.rs::{platform, target, is_build}` (edge carries BOTH legacy `target` and `platform`; matching is OR-inclusive for resolution: edge active if NO gate or gate matches the build target; `ForceAllTargets::Yes` in feature resolution ignores gates — Task 6 already models it) + `cargo-platform` crate grammar (`cfg(`, `all(`, `any(`, `not(`, `key = "value"`, bare `unix`/`windows`) — rime hand-rolls the tiny parser; test vectors copied from `cargo-platform`'s own tests) + `encode.rs::encodable_source_id` (path → `None`; v4 `as_encoded_url` vs older `as_url` — for rime: registry lock line is the verbatim index URL prefixed `registry+`; v3 writes it unencoded, v4 percent-encodes per `as_encoded_url` — implement the two forms with a test on a URL containing a character that differs) + V≤2 `branch="master"` → default-branch rewrite (comment + test asserting v2 drops `?branch=master` while v4 keeps `?branch=master`).

Semantics (exact): inactive-platform edges are INVISIBLE to resolution (not merely pruned later — they never enqueue; under v1 their absence is still total, matching cargo). Path edges: requirement is the path manifest's version (still checked against `req` — mismatch is a resolve error, not silent); lock records NO source (portable rule) so same-name path packages MUST be unique across the graph (duplicate → `check_duplicate_pkgs_in_lockfile` equivalent error in Task 9). Git edges: req matches the recorded version; lock `source = "git+<url>?<ref>#<precise40>"`. Multiple sources for one name coexist (nodes are keyed by name+version+source FROM Task 3 — `ResolvedRef`/`ResolvedNode` already carry `source: SourceId`; THIS task defines `SourceId` and fills real per-edge values via `DepEdgeFull.source`; no Task-3 test updates needed).

- [ ] **Step 1: Write the failing cfg + source-line tests**

```zig
test "cfg gates match targets" {
    const t = TargetInfo{ .triple = "x86_64-pc-windows-msvc", .os = "windows", .arch = "x86_64", .family = "windows" };
    try std.testing.expect((try parseCfg(std.testing.allocator, "cfg(windows)")).matches(t));
    try std.testing.expect(!(try parseCfg(std.testing.allocator, "cfg(unix)")).matches(t));
    try std.testing.expect((try parseCfg(std.testing.allocator, "cfg(any(unix, windows))")).matches(t));
    try std.testing.expect(!(try parseCfg(std.testing.allocator, "cfg(all(windows, target_arch = \"aarch64\"))")).matches(t));
}

test "source lock lines follow version rules" {
    const gpa = std.testing.allocator;
    try std.testing.expect((try SourceId.lockSourceLine(gpa, .{ .path = "/x" }, .v4)) == null);
    const reg_line = (try SourceId.lockSourceLine(gpa, .{ .registry = "sparse+https://github.com/rust-lang/crates.io-index" }, .v4)).?;
    defer gpa.free(reg_line);
    try std.testing.expectEqualStrings("registry+https://github.com/rust-lang/crates.io-index", reg_line);
    const git_url = "https://example.com/r.git";
    const git_v2 = (try SourceId.lockSourceLine(gpa, .{ .git = .{ .url = git_url, .ref = .{ .branch = "master" }, .precise = [_]u8{'a'} ** 40 } }, .v2)).?;
    defer gpa.free(git_v2);
    const git_v4 = (try SourceId.lockSourceLine(gpa, .{ .git = .{ .url = git_url, .ref = .{ .branch = "master" }, .precise = [_]u8{'a'} ** 40 } }, .v4)).?;
    defer gpa.free(git_v4);
    // v2 rewrites branch=master away; v4 keeps it (encode.rs V<=2 branch rule).
    try std.testing.expect(std.mem.indexOf(u8, git_v2, "branch=master") == null);
    try std.testing.expect(std.mem.indexOf(u8, git_v4, "branch=master") != null);
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test 2>&1 | tail -10`
Expected: FAIL — `sources.zig` not defined.

- [ ] **Step 3: Write minimal implementation**

Recursive-descent `cfg()` parser (tokens: ident, string, `(`/`)`/`, `/=`; `all`/`any` n-ary, `not` unary, `key = value` and bare-key predicates evaluated against `TargetInfo`: `target_os↔os`, `target_arch↔arch`, `target_family↔family`, `target_env`, `unix↔(os != windows)`, `windows↔(os == windows)`); `SourceId.lockSourceLine` formatter with the two URL forms + git `?ref#precise` rendering + branch rewrite; `DepEdgeFull` struct only (wiring into `resolveGraph`'s pending loop lands in Task 10's harness integration — document the seam: `Registry.queryFn` returns `SummaryNode`s whose `deps` caller maps through a `DepEdgeFull → DepEdge` projection applying platform + enabled-optional filtering).

- [ ] **Step 4: Run tests to verify they pass**

Run: `zig build test 2>&1 | tail -5`
Expected: PASS. Also re-run Task 3 tests (already source-keyed; must stay green).

- [ ] **Step 5: Commit**

```bash
jj status
jj commit src/cargo/sources.zig src/cargo/resolve.zig src/cargo/root.zig -m "Add platform gates and source identities"
```

---

### Task 8: Byte-stable Cargo.lock v4 writer (+ v3/v2/v1 read-compat)

**Files:**
- Modify: `src/cargo/lock.zig` (ADD writer helpers; preserve M1 `parseLock`/`serialize` signatures)
- Test: inline tests + fixtures `testdata/cargo/lock-v4/*` (multi-version + multi-source graph exercising edge shortening)

**Interfaces:**
- Consumes: `resolve.ResolveGraph` (Tasks 3–4; refs are source-keyed from Task 3, `SourceId` defined in Task 7), `sources.SourceId/lockSourceLine` (Task 7; caller frees each non-null line), `index.Candidate.checksum` (Task 2).
- Produces — ADDITIVE to M1 API (used by Tasks 9–11):
```zig
pub const ResolveVersion = enum { v1, v2, v3, v4 }; // mirrors cargo's ResolveVersion (no v5: bail without -Znext-lockfile-bump)
pub fn versionForRustVersion(lowest_rust_version: ?semver.Version) ResolveVersion; // with_rust_version floors (copy constants from resolve.rs:124-148)
pub fn writeLock(gpa: std.mem.Allocator, graph: *const resolve.ResolveGraph, checksums: *const std.StringHashMap(?[]const u8), version: ResolveVersion) LockError![]u8;
pub const NameCounts = struct {
    pair_counts: std.StringHashMap(std.StringHashMap(u32)), // name → (rendered version → node occurrences)
    name_versions: std.StringHashMap(u32), // name → distinct version count (bare-name edge allowed only when 1)
    pub fn deinit(self: *NameCounts) void;
    pub fn build(gpa: std.mem.Allocator, graph: *const resolve.ResolveGraph) std.mem.Allocator.Error!NameCounts; // counts every (name, version) node
    pub fn pairCount(self: *const NameCounts, name: []const u8, version: semver.Version) u32; // occurrences of one (name, version) pair
    pub fn versionCount(self: *const NameCounts, name: []const u8) u32; // distinct versions for one name
};
pub fn shortEdge(name: []const u8, version: ?semver.Version, source_line: ?[]const u8, counts: *const NameCounts) EdgeForm; // encodable_package_id rule
pub const EdgeForm = union(enum) { bare: []const u8, version_only: struct { name: []const u8, version: []const u8 }, full: struct { name: []const u8, version: []const u8, source: []const u8 } };
```

Reference pins: `encode.rs::EncodeState/encodable_package_id/encodable_resolve_node/Serialize` (shortening + sort + checksum placement) + `ops/lockfile.rs::serialize_resolve/emit_package` (byte layout) + `into_resolve` (read-compat rules the writer must round-trip: duplicate-name error, V1-metadata checksums, single-package trailing-newline V2 bump, ambiguous-edge tolerance).

Byte layout (exact — replicate `serialize_resolve`, do NOT use a generic TOML emitter): line 1 `# This file is automatically @generated by Cargo.\n`, line 2 `# It is not intended for manual editing.\n`, then preserved extra `#` comments from the original file if updating (pass `orig: ?[]const u8`), then `version = 4\n\n` (v4/v3 only; v1/v2 emit NO version line). Packages sorted by `(name, version, source_line)` — cargo's `PackageId` Ord. Per package: `[[package]]\n`, `name = "<n>"\n`, `version = "<v>"\n`, [`source = "<s>"\n` unless path], [`checksum = "<c>"\n` for registry candidates when version ≥ v2], [`dependencies = [\n` + sorted ` "<edge>",\n` lines + `]\n` — OMITTED entirely when empty... careful: `emit_package` pushes `'\n'` after deps-or-replace handling such that packages WITH deps get a blank line after `]` and packages WITHOUT deps get NO trailing blank line — copy the exact push sequence, do not "clean it up"], `[[patch.unused]]` blocks verbatim, `[metadata]` table last verbatim. For `version ≥ v2`, strip trailing `"\n\n"` runs at EOF; v1 keeps them. Edge shortening (`encodable_package_id`): count per `(name, version)`; count==1 for the pair → drop source; additionally single version for the name → drop version (bare name). `version`/`source` OMITTED on the edge (not empty-string). V1: no shortening ever. Version upgrade on write: `current < default(versionForRustVersion)` → rewrite at default (Task 9 triggers; `writeLock` takes the ALREADY-decided version). v5 encountered on read → `LockError.UnsupportedVersion` (cargo bails without `-Znext-lockfile-bump`).

Read-compat work in this task (M1 `parseLock` gaps — verify each, fix what deviates): duplicate `[[package]] name` → `InvalidLock` naming the package; `[metadata]` `"checksum <name> <version> …"` V1 entries attach to matching nodes (`<none>` → null checksum); inline `checksum` bumps parsed version to ≥ v2; absent version field with single-package + single-trailing-newline input parses as v2; ambiguous short edges (name-only matching 2+ versions) are DROPPED from the edge list, not errors.

- [ ] **Step 1: Write the failing writer tests**

```zig
test "lock writer shortens unambiguous edges and sorts" {
    // graph: app 0.1.0 (path) → serde 1.0.200 (registry, checksum C), serde → cfg-if 1.0.0 (only version) + log 1.0.0 AND log 2.0.0 (ambiguous).
    // Expect: packages sorted [app, cfg-if, log 1.0.0, log 2.0.0, serde]; serde's deps = ["cfg-if", "log 1.0.0"]; app dep = ["serde 1.0.200"] (single-version name? no—only one serde → bare "serde").
    const out = try writeLock(std.testing.allocator, &graph, &cksums, .v4);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings(@embedFile("../../testdata/cargo/lock-v4/short.expected"), out);
}
```

(Create `testdata/cargo/lock-v4/short.expected` by HAND per the layout rules above — the test then pins the implementation to the hand-derived bytes, not to itself.)

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test 2>&1 | tail -10`
Expected: FAIL — `writeLock` / `shortEdge` not defined.

- [ ] **Step 3: Write minimal implementation**

`NameCounts` builder (name → version → count + name → version-set-size); per-node edge rendering via `shortEdge`; fixed-order field emitter replicating `emit_package` push-for-push; EOF trim for ≥v2; checksum lookup by `(name, version, source)` key. `versionForRustVersion`: null → `.v4`; else compare against the floor constants copied from `resolve.rs::with_rust_version` (cite exact lines; if the vendored cargo moves them, the test below catches drift via the oracle).

- [ ] **Step 4: Round-trip + read-compat tests, verify pass**

```zig
test "lock writer output reparses to the same graph" {
    const out = try writeLock(std.testing.allocator, &graph, &cksums, .v4);
    defer std.testing.allocator.free(out);
    var lf = try parseLock(std.testing.allocator, out);
    defer lf.deinit();
    try std.testing.expect(lf.find("serde") != null);
}

test "lock reader keeps v1 metadata checksums and rejects duplicates" {
    try std.testing.expectError(LockError.InvalidLock, parseLock(std.testing.allocator, "[[package]]\nname = \"x\"\nversion = \"1.0.0\"\n[[package]]\nname = \"x\"\nversion = \"2.0.0\"\n"));
}
```

Run: `zig build test 2>&1 | tail -5`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
jj status
jj commit src/cargo/lock.zig testdata/cargo/lock-v4 -m "Add byte-stable v4 lock writer"
```

---

### Task 9: --locked/--frozen/--offline enforcement + resolve diagnostics

**Files:**
- Modify: `src/cargo/cli.zig` (flag plumbing), `src/cargo/resolve.zig` (error detail carriers)
- Test: inline tests in `src/cargo/cli.zig` + `src/cargo/resolve.zig`

**Interfaces:**
- Consumes: Tasks 4 (`KeepFilter`), 8 (`writeLock`, `ResolveVersion`), M1 `lock.parseLock`.
- Produces (used by Task 10 oracle + M4 driver):
```zig
// cli.zig additions:
pub const LockMode = enum { normal, locked, frozen, offline };
pub fn lockModeFrom(opts: Options) LockMode; // frozen ⇒ locked+offline
pub fn needsNetwork(mode: LockMode) bool; // true for normal|locked only (frozen/offline never hit the network seam)
pub const LockCheck = enum { up_to_date, would_change, offline_missing };
pub fn checkLock(gpa: std.mem.Allocator, previous: ?[]const u8, new_graph: *const resolve.ResolveGraph) LockCheck; // null/malformed previous → would_change; else decoded node-set semantic compare via lock.parseLock (comment/whitespace-only diffs stay up_to_date)
// resolve.zig additions:
pub const Diag = struct {
    kind: DiagKind, package: []const u8, req: []const u8,
    tried: []const []const u8, // candidate versions seen, for the "candidate versions found" line
    path: []const []const u8,  // dep chain root → … → package (describe_path_in_context)
};
pub const DiagKind = enum { no_matching, yanked_locked, offline_missing, duplicate_path_name, links_conflict, cycle };
pub fn formatDiag(gpa: std.mem.Allocator, d: Diag) ![]u8; // cargo-leading-line-compatible text
```

Reference pins: `ops/lockfile.rs::write_pkg_lockfile` (locked-bail message AFTER the equality check — order matters: up-to-date + `--locked` = success, not error; copy the `cannot update the lock file … because --locked was passed…` text) + `are_equal_lockfiles` (semantic compare: parse both, `into_resolve` equality — rime compares decoded graphs, NOT bytes, so comment/whitespace-only diffs don't trip `--locked`) + `ops/resolve.rs::lock_update_allowed` + `generate_lockfile.rs` testsuite expectations (`--locked` failure exit + message; `--offline` success with complete lock) + `dep_cache.rs::describe_path_in_context` + `resolver/errors.rs` message shapes.

Semantics (exact): `normal`: resolve freely, write lock when graph differs (semantic compare). `locked`: resolve MUST reproduce the existing lock graph exactly — implement as `resolveWithPrevious(previous, keep-everything)` then semantic-compare; mismatch → bail with cargo's message + exit 1 (no write attempted). `frozen`: `locked` + `offline` (any candidate fetch = `offline_missing` error, no network seam call). `offline`: resolve freely but the registry seam serves cached/stub data only; a dep with zero served candidates → `offline_missing` naming the crate + `which requires …` path hint (NOT `no_matching` — offline has its own error so users learn the flag is the cause). Missing lockfile + `--locked/--frozen` → same bail message with "create" wording (cargo picks create/update by file existence). `formatDiag` leading lines (matchable by tests/oracle): `failed to select a version for the requirement `<req>` …`, `candidate versions found …`, `which …` path lines; yanked-locked: `package <n> <v> is yanked … previously selected …` (cargo's locked-yanked error names the lock as the source of the pin).

- [ ] **Step 1: Write the failing enforcement tests**

```zig
test "locked mode bails only when the graph would change" {
    const gpa = std.testing.allocator;
    // previous graph == fresh resolve → LockCheck.up_to_date (no error).
    // previous graph stale (changed version) → would_change.
    // (The "--locked" bail text itself is rendered by the M4 driver from write_pkg_lockfile wording.)
    const path: sources.SourceId = .{ .path = "/repo/app" };
    const v010 = try semver.Version.parse("0.1.0");
    const nodes = [_]resolve.ResolvedNode{
        .{ .name = "app", .version = v010, .source = path, .deps = &.{} },
    };
    var graph = resolve.ResolveGraph{ .arena = std.heap.ArenaAllocator.init(gpa), .nodes = &nodes };
    defer graph.deinit();
    var cksums = std.StringHashMap(?[]const u8).init(gpa);
    defer cksums.deinit();
    const bytes = try lock.writeLock(gpa, &graph, &cksums, .v4);
    defer gpa.free(bytes);
    try std.testing.expectEqual(LockCheck.up_to_date, checkLock(gpa, bytes, &graph));
    try std.testing.expectEqual(LockCheck.would_change, checkLock(gpa, null, &graph));
    const v020 = try semver.Version.parse("0.2.0");
    const moved = [_]resolve.ResolvedNode{
        .{ .name = "app", .version = v020, .source = path, .deps = &.{} },
    };
    var graph2 = resolve.ResolveGraph{ .arena = std.heap.ArenaAllocator.init(gpa), .nodes = &moved };
    defer graph2.deinit();
    try std.testing.expectEqual(LockCheck.would_change, checkLock(gpa, bytes, &graph2));
}

test "offline missing names the crate" {
    // empty registry seam + offline → DiagKind.offline_missing; formatDiag contains crate name.
    const gpa = std.testing.allocator;
    const msg = try formatDiag(gpa, .{
        .kind = .offline_missing,
        .package = "serde",
        .req = "^1.0.0",
        .tried = &.{},
        .path = &.{ "app", "serde" },
    });
    defer gpa.free(msg);
    try std.testing.expect(std.mem.indexOf(u8, msg, "serde") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "offline") != null);
}

test "diag leading line matches cargo shape" {
    const msg = try formatDiag(std.testing.allocator, .{ .kind = .no_matching, .package = "foo", .req = "^9.9", .tried = &.{ "1.0.0", "2.0.0" }, .path = &.{ "app", "foo" } });
    defer std.testing.allocator.free(msg);
    try std.testing.expect(std.mem.startsWith(u8, msg, "failed to select a version for the requirement `foo ^9.9`"));
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test 2>&1 | tail -10`
Expected: FAIL — `LockMode` / `formatDiag` not defined.

- [ ] **Step 3: Write minimal implementation**

`lockModeFrom` (offline→offline; locked→locked; frozen→frozen; frozen also sets offline internally — expose `needsNetwork(mode) bool` = normal|locked only); `checkLock(previous_bytes, new_graph)` helper doing decode-both-sides semantic compare (reuse `parseLock` + node-set equality); `formatDiag` renderer with the exact leading lines + path rendering `app → mid → foo` (cargo's `describe_path_in_context` arrow shape).

- [ ] **Step 4: Run tests to verify they pass**

Run: `zig build test 2>&1 | tail -5`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
jj status
jj commit src/cargo/cli.zig src/cargo/resolve.zig -m "Enforce lock and offline modes"
```

---

### Task 10: Oracle harness — real cargo as conformance oracle

**Files:**
- Create: `src/cargo/oracle.zig` (test-only: `pub const enabled: bool` + `runCargoGenerateLockfile` + `readCargoMetadataPkgs` + `compareGraphs`)
- Test: `test "oracle …"` blocks in `src/cargo/oracle.zig` (spawn real `cargo`; skip when absent)
- Fixtures: `testdata/cargo/resolve/diamond/{Cargo.toml,members…}`, `testdata/cargo/resolve/offline-ok/{…}` (path-only graphs so cargo runs WITHOUT network)
- Consume (LANDED in `validation/`): `validation/<project>/{Cargo.toml,members…,golden.Cargo.lock,golden.metadata.json,golden.tree*.txt}` — committed cargo outputs this harness byte-compares against (see Step 5). Exception: `lockfile-golden/` carries its lock golden as the committed `Cargo.lock` itself (no `golden.Cargo.lock` there). There is NO `index-snapshot.json` convention — registry-dependent validation runs use the warm cargo cache via `validation/oracle.sh`; hermetic rime-side cases use Task-11 `index.json` stubs instead.

**Interfaces:**
- Consumes: Tasks 3–4 (resolve from path manifests), 8 (rime lock bytes), 12 (broad-manifest summary projection), `std.process.Child`.
- Produces (used by Task 11):
```zig
pub const OracleError = error{ CargoMissing, CargoFailed, Mismatch, OutOfMemory, Io };
pub fn cargoAvailable() bool; // `cargo --version` spawns cleanly
pub fn generateLockfile(gpa: std.mem.Allocator, io: std.Io, dir: []const u8, offline: bool) OracleError![]u8; // runs `cargo generate-lockfile [--offline]` in dir, returns Cargo.lock bytes
pub fn metadataPkgs(gpa: std.mem.Allocator, io: std.Io, dir: []const u8) OracleError![][]const u8; // `cargo metadata --format-version 1 --offline` → sorted "name version" list
pub fn expectSameGraph(rime: *const resolve.ResolveGraph, cargo_lock_text: []const u8) OracleError!void; // decode cargo lock via lock.parseLock; compare node name@version sets; on mismatch return Mismatch AFTER printing both sets to stderr
pub fn expectSameLockfile(rime_lock: []const u8, cargo_lock_path: []const u8, io: std.Io) OracleError!void; // byte-compare rime's writeLock output vs the file cargo wrote; on mismatch print a unified diff to stderr, then Mismatch
pub fn discoverValidationProjects(gpa: std.mem.Allocator, io: std.Io) OracleError![][]const u8; // lists validation/*/ dirs (sorted; names match the landed projects); empty is NOT an error from the helper — but the Step-5 conformance test FAILS on empty since the corpus has landed
```

Reference pins: `tests/testsuite/generate_lockfile.rs` (CLI shapes asserted: `generate-lockfile` creates/updates; `--locked` errors; `--offline` flag threading) + `tests/testsuite/lockfile_compat.rs` (version upgrade/downgrade preservation expectations the oracle re-checks on rime's writer).

Harness design (exact): each fixture dir is a COMPLETE standalone workspace using ONLY path deps (+ optionally git deps pinned by full rev when the machine has network — mark those `network` and skip offline). Oracle tests: (1) copy fixture to a `std.testing.tmpDir` (cargo MUST NOT write into the repo — `generate-lockfile` creates `Cargo.lock` in-place; assert the repo fixture has NO `Cargo.lock` checked in except `*.expected` files); (2) run real `cargo generate-lockfile [--offline]` with scrubbed env (`CARGO_HOME=<tmp>`, `CARGO_NET_OFFLINE` when offline, `--config net.offline=true` fallback); (3) resolve the same manifests with rime (`resolveGraph` over path-manifest summaries — the Task-7 projection seam gets its FIRST real caller here: build `SummaryNode`s by reading member manifests via M1 `manifest.parseManifest` + `workspace.discover`); (4) `expectSameGraph` compares; (5) write rime's lock via `writeLock(.v4)` and byte-compare against cargo's `Cargo.lock` — byte equality is REQUIRED for path-only graphs (no checksums involved). Env scrub list + timeout (60s per cargo spawn; kill + `CargoFailed` on timeout) documented in code. `cargoAvailable()` gates EVERY oracle test (`if (!cargoAvailable()) return error.SkipZigTest`).

- [ ] **Step 1: Write fixtures + failing oracle test**

`testdata/cargo/resolve/diamond/Cargo.toml` (root + 3 path members forming a diamond with overlapping reqs) and `testdata/cargo/resolve/offline-ok/Cargo.toml` (single path dep chain). Test:

```zig
test "oracle diamond matches cargo" {
    if (!oracle.cargoAvailable()) return error.SkipZigTest;
    // copy fixture → tmp, cargo generate-lockfile --offline, rime resolve, expectSameGraph + byte-compare locks.
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test 2>&1 | tail -10`
Expected: FAIL — `oracle.zig` / `generateLockfile` not defined (or graph mismatch once wired — either counts; record which).

- [ ] **Step 3: Write minimal implementation**

`std.process.Child` spawn (`cargo`, `generate-lockfile`/`metadata` args, `cwd=tmp`, env override map), capture stdout/stderr via pipes with cap (8 MiB), tmp-dir fixture copy via recursive `Dir` walk (manifests + `src/lib.rs` stubs only — whitelist extensions `.toml,.rs,.lock,.json` so stray files never leak in), `expectSameGraph` set-compare with sorted stderr dump.

- [ ] **Step 4: Run oracle tests, verify pass**

Run: `zig build test -- --test-filter "oracle" 2>&1 | tail -5` (full `zig build test` if filter unsupported)
Expected: PASS (cargo present: real comparison; absent: skipped, suite still green).

- [ ] **Step 5: Wire the landed validation/ corpus (operator-required oracle expansion)**

`validation/` has LANDED (`basic-workspace`, `feature-matrix`, `full-manifest`, `lockfile-golden`) with cargo-committed goldens (`golden.Cargo.lock` + `golden.metadata.json` + `golden.tree*.txt`, generated by the REAL cargo binary per `validation/README.md`; `lockfile-golden/` uses its committed `Cargo.lock` as the lock golden instead of `golden.Cargo.lock`). This step makes the M3 harness run rime against EACH of them:

```zig
test "oracle validation projects match committed cargo goldens" {
    if (!oracle.cargoAvailable()) return error.SkipZigTest;
    const io = std.Io.Threaded.global_single_threaded.io();
    const projects = try oracle.discoverValidationProjects(std.testing.allocator, io);
    defer { for (projects) |p| std.testing.allocator.free(p); std.testing.allocator.free(projects); }
    try std.testing.expect(projects.len > 0); // corpus has landed — empty is a FAILURE, not a skip
    for (projects) |proj| {
        // (a) copy validation/<proj> → tmp (NEVER resolve inside the repo: cargo artifacts + rime outputs stay in tmp)
        // (b) resolve with rime from the copied manifests (Task-12 projection: renames/target tables/inheritance/patch applied)
        // (c) lock golden: basic-workspace/feature-matrix/full-manifest read committed golden.Cargo.lock;
        //     lockfile-golden reads committed Cargo.lock — expectSameGraph(rime_graph, golden_text)
        // (d) writeLock(.v4) → expectSameLockfile vs the same golden file (byte equality REQUIRED)
        // (e) golden.metadata.json cross-check: rime node name@version set == golden package list
        //     (paths sanitized to @VALIDATION_ROOT@ before compare, same as validation/oracle.sh normalize)
        // (f) golden.tree*.txt cross-check where present (feature-matrix has golden.tree.txt +
        //     golden.tree-features.txt + golden.tree-all-features.txt variants)
        // On ANY mismatch: print the project name + both sets/diff, then Mismatch (fail loudly, fail per-project).
    }
}
```

Rules (normative): goldens are generated ONLY by the real cargo binary (never hand-written, never rime-generated — regeneration commands live in `validation/README.md` + `validation/oracle.sh`; this harness only READS `golden.*` / `lockfile-golden/Cargo.lock`); rime resolves from the SAME copied manifests with network disabled where the project allows (`--offline` cargo run first to prove the golden is reproducible offline, except projects explicitly marked `network`); there is NO `index-snapshot.json` convention — dropped (hermetic registry cases use Task-11 `index.json` stubs; validation projects use the real cargo cache warmed by `oracle.sh`); tmp-dir copies whitelist extensions `.toml,.rs,.lock,.json` (same as Step 3). Add one rime-only test asserting `discoverValidationProjects` returns the sorted landed project names (`basic-workspace`, `feature-matrix`, `full-manifest`, `lockfile-golden`) on the real `validation/` dir — update it in the same commit whenever a project is added or renamed (no cargo needed).

Run: `zig build test -- --test-filter "oracle validation" 2>&1 | tail -5`
Expected: PASS (cargo present: real byte-compares against the committed goldens); SKIP only when cargo is absent from PATH (suite still green — the projects themselves are committed, so there is no empty-corpus skip).

- [ ] **Step 6: Commit**

```bash
jj status
jj commit src/cargo/oracle.zig testdata/cargo/resolve -m "Add cargo oracle harness"
```

---

### Task 11: Ported conformance fixtures (resolve, features2, lockfile suites)

**Files:**
- Create: fixtures under `testdata/cargo/resolve/<case>/` + `testdata/cargo/resolve/<case>.expected-lock` where byte equality applies; inline oracle tests in `src/cargo/oracle.zig` (one per case, all gated on `cargoAvailable()`); registry-dependent cases use `index.json` stub + rime-only assertions (no cargo spawn).
- Cases (each cites its cargo source; port FAITHFULLY — same names/versions/reqs, trimmed only of networked deps):

| # | Fixture | Pins | Cargo source |
|---|---|---|---|
| 1 | `almost-locked` (prev lock + new compatible version exists) | conservative keep (Task 4) | `resolve.rs::previous_lock_keeps` family |
| 2 | `yanked-avoid` (+ `index.json` with yanked newest) | yanked filtering (Task 2) | `resolve.rs` yanked tests |
| 3 | `yanked-locked` (prev lock pins the yanked v) | yanked rescue via preference (Task 2/4) | `dep_cache.rs` Yanked arm |
| 4 | `prerelease-req` (`req = ">=1.0.0-alpha"` style) | stock pre gating (Task 1) | `resolve.rs` prerelease tests |
| 5 | `multi-version` (same crate 1.x + 2.x both needed) | semver-incompatible coexistence (Task 3) | `resolve.rs` duplicate-version tests |
| 6 | `links-conflict` (two `links="z"` via path stubs) | links uniqueness (Task 3) | `context.rs::is_conflicting` |
| 7 | `feat-v1-unify` | cross-parent unification (Task 5) | `features.rs` + `feature_unification.rs` |
| 8 | `feat-v2-host` (`resolver = "2"`, build-dep feature split) | host decouple (Task 6) | `features2.rs` host-dep cases |
| 9 | `feat-v2-dev` (dev-dep feature quarantine, both `HasDevUnits` modes) | dev decouple on/off (Task 6) | `features2.rs` dev-dep cases |
| 10 | `feat-weak` (`dep?/feat` both states) | weak semantics (Task 5) | `weak_dep_features.rs` |
| 11 | `lock-v3-keep` (v3 lock + compatible graph) | version preservation, no silent bump (Task 8) | `lockfile_compat.rs` |
| 12 | `lock-upgrade` (v1 lock with `[metadata]` checksums) | metadata-checksum read + v4 rewrite (Task 8) | `lockfile_compat.rs` + `into_resolve` V1 arm |
| 13 | `update-precise` (`--precise` name=version incl. prerelease) | Precise matching + error case (Task 4) | `cargo_update.rs` precise tests + RFC 3493 |
| 14 | `locked-fails` (stale lock + `--locked`) | bail message + exit path (Task 9) | `generate_lockfile.rs` locked tests |
| 15 | `renamed-deps` (`old = { package = "real", version = … }` + `real/feat` + `dep:` refs) | rename projection: lock/feature/edge keys use REAL name (Task 12) | cargo `rename_deps` testsuite family |
| 16 | `workspace-inherit` (`workspace = true` deps + `workspace.package.version/edition/rust-version`, target-table inherit) | inheritance resolution before resolve (Task 12) | cargo `inherit_workspace` testsuite family |
| 17 | `patch-table` (`[patch.crates-io]` newer version + an unused patch entry) | patch preference + avoid-locked-set + unused warning (Task 12) | `ops/resolve.rs::register_patch_entries` + patch testsuite |

`index.json` format (for stub-registry cases 2–4, 13): EXACTLY the sparse-index wire shape — one JSON object per line per crate version with `IndexPackage` fields (`name`, `vers`, `deps[]` as `RegistryDependency` objects with `name/req/features/optional/default_features/target/kind/registry/package`, `features`, `features2`, `cksum`, `yanked`, `links`, `rust_version`, `pubtime`, `v`). The file may contain a `{"crates": …}` wrapper ONLY as a documented convenience for multi-crate stubs; each crate's lines are concatenated and fed to Task-2 `parseIndexLine` verbatim (write the loader in THIS task as `loadStubIndex`, test-local in `oracle.zig`: split lines → `parseIndexLine` → `IndexEntry` list → project to Task-2 `Candidate`s + Task-3 `SummaryNode`s via the Task-7/12 edge projection). A stub file that cargo's own `index/` parser would reject (bad `vers`, non-string `req`) must ALSO fail `parseIndexLine` — add one negative test proving a malformed stub line errors instead of resolving.

- [ ] **Step 1: Write fixtures 1–6 + failing tests**

(registry-free cases first: 1, 5, 6 are path-only → full oracle byte-compare; 2–4 use `index.json` → rime-only version assertions. Each fixture dir carries its `Cargo.toml` (+ `index.json` for 2–4); the tests below pin the Task 2/3/4 behavior each case requires.)

```zig
test "ported almost-locked keeps previous versions" {
    const gpa = std.testing.allocator;
    // Fixture 1 (testdata/cargo/resolve/almost-locked): prev lock shared=1.1 + new 1.2 exists → keep 1.1.
    const req = semver.OptVersionReq{ .req = try semver.VersionReq.parse("^1.0") };
    const no_edges = [_]resolve.DepEdge{};
    const shared_nodes = [_]resolve.SummaryNode{
        .{ .name = "shared", .candidate = .{ .name = "shared", .version = try semver.Version.parse("1.1.0"), .yanked = false, .checksum = null, .rust_version = null, .pubtime = null }, .deps = &no_edges, .links = null },
        .{ .name = "shared", .candidate = .{ .name = "shared", .version = try semver.Version.parse("1.2.0"), .yanked = false, .checksum = null, .rust_version = null, .pubtime = null }, .deps = &no_edges, .links = null },
    };
    const Stub = struct {
        shared: []const resolve.SummaryNode,
        fn query(ctx: *anyopaque, name: []const u8) resolve.QueryError![]const resolve.SummaryNode {
            const self: *const @This() = @ptrCast(@alignCast(ctx));
            if (std.mem.eql(u8, name, "shared")) return self.shared;
            return &.{};
        }
    };
    var stub = Stub{ .shared = &shared_nodes };
    const registry = resolve.Registry{ .ctx = @ptrCast(&stub), .queryFn = &Stub.query };
    const app_edges = [_]resolve.DepEdge{.{ .name = "shared", .req = req, .optional = false, .build_only = false }};
    const roots = [_]resolve.SummaryNode{
        .{ .name = "app", .candidate = .{ .name = "app", .version = try semver.Version.parse("0.1.0"), .yanked = false, .checksum = null, .rust_version = null, .pubtime = null }, .deps = &app_edges, .links = null },
    };
    const reg: sources.SourceId = .{ .registry = "sparse+https://github.com/rust-lang/crates.io-index" };
    const previous = [_]resolve.ResolvedNode{
        .{ .name = "shared", .version = try semver.Version.parse("1.1.0"), .source = reg, .deps = &.{} },
    };
    const base = index.QueryFilter{ .allow_yanked = &.{}, .max_pubtime = null, .min_versions_first = false, .rust_versions = &.{}, .preferred = &.{} };
    var graph = try resolve.resolveWithPrevious(gpa, &roots, registry, &previous, .{ .update_names = &.{} }, base);
    defer graph.deinit();
    try std.testing.expect(graph.find("shared", try semver.Version.parse("1.1.0")) != null);
}

test "ported yanked-avoid hides yanked newest" {
    const gpa = std.testing.allocator;
    // Fixture 2 (testdata/cargo/resolve/yanked-avoid/index.json): newest serde yanked → hidden by default.
    const lines = [_][]const u8{
        "{\"name\":\"serde\",\"vers\":\"1.0.200\",\"deps\":[],\"cksum\":\"" ++ "c" ** 64 ++ "\",\"yanked\":false}",
        "{\"name\":\"serde\",\"vers\":\"1.0.201\",\"deps\":[],\"cksum\":\"" ++ "d" ** 64 ++ "\",\"yanked\":true}",
    };
    var cands: std.ArrayList(index.Candidate) = .empty;
    defer cands.deinit(gpa);
    for (lines) |line| {
        var entry = try index.parseIndexLine(gpa, line);
        defer entry.deinit(gpa);
        try cands.append(gpa, entry.candidate);
    }
    const req = semver.OptVersionReq{ .req = try semver.VersionReq.parse("^1.0.0") };
    const got = try index.queryCandidates(gpa, cands.items, req, .{ .allow_yanked = &.{}, .max_pubtime = null, .min_versions_first = false, .rust_versions = &.{}, .preferred = &.{} });
    defer gpa.free(got);
    try std.testing.expectEqual(@as(usize, 1), got.len);
    try std.testing.expect(got[0].version.eql(try semver.Version.parse("1.0.200")));
}

test "ported yanked-locked rescues pinned yanked" {
    const gpa = std.testing.allocator;
    // Fixture 3: previous lock pins the yanked 1.0.201 → Task-4 rule (6) populates allow_yanked → rescued.
    const no_edges = [_]resolve.DepEdge{};
    const serde_nodes = [_]resolve.SummaryNode{
        .{ .name = "serde", .candidate = .{ .name = "serde", .version = try semver.Version.parse("1.0.200"), .yanked = false, .checksum = null, .rust_version = null, .pubtime = null }, .deps = &no_edges, .links = null },
        .{ .name = "serde", .candidate = .{ .name = "serde", .version = try semver.Version.parse("1.0.201"), .yanked = true, .checksum = null, .rust_version = null, .pubtime = null }, .deps = &no_edges, .links = null },
    };
    const Stub = struct {
        serde: []const resolve.SummaryNode,
        fn query(ctx: *anyopaque, name: []const u8) resolve.QueryError![]const resolve.SummaryNode {
            const self: *const @This() = @ptrCast(@alignCast(ctx));
            if (std.mem.eql(u8, name, "serde")) return self.serde;
            return &.{};
        }
    };
    var stub = Stub{ .serde = &serde_nodes };
    const registry = resolve.Registry{ .ctx = @ptrCast(&stub), .queryFn = &Stub.query };
    const req = semver.OptVersionReq{ .req = try semver.VersionReq.parse("^1.0.0") };
    const app_edges = [_]resolve.DepEdge{.{ .name = "serde", .req = req, .optional = false, .build_only = false }};
    const roots = [_]resolve.SummaryNode{
        .{ .name = "app", .candidate = .{ .name = "app", .version = try semver.Version.parse("0.1.0"), .yanked = false, .checksum = null, .rust_version = null, .pubtime = null }, .deps = &app_edges, .links = null },
    };
    const reg: sources.SourceId = .{ .registry = "sparse+https://github.com/rust-lang/crates.io-index" };
    const previous = [_]resolve.ResolvedNode{
        .{ .name = "serde", .version = try semver.Version.parse("1.0.201"), .source = reg, .deps = &.{} },
    };
    const base = index.QueryFilter{ .allow_yanked = &.{}, .max_pubtime = null, .min_versions_first = false, .rust_versions = &.{}, .preferred = &.{} };
    var graph = try resolve.resolveWithPrevious(gpa, &roots, registry, &previous, .{ .update_names = &.{} }, base);
    defer graph.deinit();
    try std.testing.expect(graph.find("serde", try semver.Version.parse("1.0.201")) != null);
}

test "ported prerelease-req gates stock pres" {
    // Fixture 4: req = ">=1.0.0-alpha, <2.0.0" — stock matching excludes the
    // different-patch prerelease; the RFC 3493 --precise path admits it.
    const req = try semver.VersionReq.parse(">=1.0.0-alpha, <2.0.0");
    try std.testing.expect(!req.matches(try semver.Version.parse("1.5.0-alpha")));
    try std.testing.expect(req.matchesPrerelease(try semver.Version.parse("1.5.0-alpha")));
    try std.testing.expect(req.matches(try semver.Version.parse("1.5.0")));
}

test "ported multi-version coexists" {
    const gpa = std.testing.allocator;
    // Fixture 5: same crate 1.x + 2.x both needed → both activate.
    const req_old = semver.OptVersionReq{ .req = try semver.VersionReq.parse("^1") };
    const req_new = semver.OptVersionReq{ .req = try semver.VersionReq.parse("^2") };
    const req_u1 = semver.OptVersionReq{ .req = try semver.VersionReq.parse("^1") };
    const req_u2 = semver.OptVersionReq{ .req = try semver.VersionReq.parse("^2") };
    const old_edges = [_]resolve.DepEdge{.{ .name = "util", .req = req_u1, .optional = false, .build_only = false }};
    const new_edges = [_]resolve.DepEdge{.{ .name = "util", .req = req_u2, .optional = false, .build_only = false }};
    const old_nodes = [_]resolve.SummaryNode{
        .{ .name = "old", .candidate = .{ .name = "old", .version = try semver.Version.parse("1.0.0"), .yanked = false, .checksum = null, .rust_version = null, .pubtime = null }, .deps = &old_edges, .links = null },
    };
    const new_nodes = [_]resolve.SummaryNode{
        .{ .name = "new", .candidate = .{ .name = "new", .version = try semver.Version.parse("2.0.0"), .yanked = false, .checksum = null, .rust_version = null, .pubtime = null }, .deps = &new_edges, .links = null },
    };
    const util_nodes = [_]resolve.SummaryNode{
        .{ .name = "util", .candidate = .{ .name = "util", .version = try semver.Version.parse("1.0.0"), .yanked = false, .checksum = null, .rust_version = null, .pubtime = null }, .deps = &.{}, .links = null },
        .{ .name = "util", .candidate = .{ .name = "util", .version = try semver.Version.parse("2.0.0"), .yanked = false, .checksum = null, .rust_version = null, .pubtime = null }, .deps = &.{}, .links = null },
    };
    const Stub = struct {
        old: []const resolve.SummaryNode,
        new: []const resolve.SummaryNode,
        util: []const resolve.SummaryNode,
        fn query(ctx: *anyopaque, name: []const u8) resolve.QueryError![]const resolve.SummaryNode {
            const self: *const @This() = @ptrCast(@alignCast(ctx));
            if (std.mem.eql(u8, name, "old")) return self.old;
            if (std.mem.eql(u8, name, "new")) return self.new;
            if (std.mem.eql(u8, name, "util")) return self.util;
            return &.{};
        }
    };
    var stub = Stub{ .old = &old_nodes, .new = &new_nodes, .util = &util_nodes };
    const registry = resolve.Registry{ .ctx = @ptrCast(&stub), .queryFn = &Stub.query };
    const app_edges = [_]resolve.DepEdge{
        .{ .name = "old", .req = req_old, .optional = false, .build_only = false },
        .{ .name = "new", .req = req_new, .optional = false, .build_only = false },
    };
    const roots = [_]resolve.SummaryNode{
        .{ .name = "app", .candidate = .{ .name = "app", .version = try semver.Version.parse("0.1.0"), .yanked = false, .checksum = null, .rust_version = null, .pubtime = null }, .deps = &app_edges, .links = null },
    };
    const filter = index.QueryFilter{ .allow_yanked = &.{}, .max_pubtime = null, .min_versions_first = false, .rust_versions = &.{}, .preferred = &.{} };
    var graph = try resolve.resolveGraph(gpa, &roots, registry, filter);
    defer graph.deinit();
    try std.testing.expect(graph.find("util", try semver.Version.parse("1.0.0")) != null);
    try std.testing.expect(graph.find("util", try semver.Version.parse("2.0.0")) != null);
}

test "ported links-conflict errors" {
    const gpa = std.testing.allocator;
    // Fixture 6: two path stubs both with links="z" → Conflict.
    const req = semver.OptVersionReq{ .req = try semver.VersionReq.parse("^1") };
    const x_nodes = [_]resolve.SummaryNode{
        .{ .name = "x", .candidate = .{ .name = "x", .version = try semver.Version.parse("1.0.0"), .yanked = false, .checksum = null, .rust_version = null, .pubtime = null }, .deps = &.{}, .links = "z" },
    };
    const y_nodes = [_]resolve.SummaryNode{
        .{ .name = "y", .candidate = .{ .name = "y", .version = try semver.Version.parse("1.0.0"), .yanked = false, .checksum = null, .rust_version = null, .pubtime = null }, .deps = &.{}, .links = "z" },
    };
    const Stub = struct {
        x: []const resolve.SummaryNode,
        y: []const resolve.SummaryNode,
        fn query(ctx: *anyopaque, name: []const u8) resolve.QueryError![]const resolve.SummaryNode {
            const self: *const @This() = @ptrCast(@alignCast(ctx));
            if (std.mem.eql(u8, name, "x")) return self.x;
            if (std.mem.eql(u8, name, "y")) return self.y;
            return &.{};
        }
    };
    var stub = Stub{ .x = &x_nodes, .y = &y_nodes };
    const registry = resolve.Registry{ .ctx = @ptrCast(&stub), .queryFn = &Stub.query };
    const app_edges = [_]resolve.DepEdge{
        .{ .name = "x", .req = req, .optional = false, .build_only = false },
        .{ .name = "y", .req = req, .optional = false, .build_only = false },
    };
    const roots = [_]resolve.SummaryNode{
        .{ .name = "app", .candidate = .{ .name = "app", .version = try semver.Version.parse("0.1.0"), .yanked = false, .checksum = null, .rust_version = null, .pubtime = null }, .deps = &app_edges, .links = null },
    };
    const filter = index.QueryFilter{ .allow_yanked = &.{}, .max_pubtime = null, .min_versions_first = false, .rust_versions = &.{}, .preferred = &.{} };
    try std.testing.expectError(resolve.ResolveError.Conflict, resolve.resolveGraph(gpa, &roots, registry, filter));
}

test "ported stub rejects malformed index lines" {
    // A stub file that cargo's own index/ parser would reject must ALSO fail parseIndexLine.
    const bad_vers = "{\"name\":\"x\",\"vers\":\"not.a.version\",\"deps\":[],\"cksum\":\"" ++ "a" ** 64 ++ "\",\"yanked\":false}";
    try std.testing.expectError(index.IndexError.InvalidIndexLine, index.parseIndexLine(std.testing.allocator, bad_vers));
    const bad_req = "{\"name\":\"x\",\"vers\":\"1.0.0\",\"deps\":[{\"name\":\"y\",\"req\":42,\"features\":[],\"optional\":false,\"default_features\":true}],\"cksum\":\"" ++ "a" ** 64 ++ "\",\"yanked\":false}";
    try std.testing.expectError(index.IndexError.InvalidIndexLine, index.parseIndexLine(std.testing.allocator, bad_req));
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `zig build test 2>&1 | tail -10`
Expected: FAIL — fixtures resolve differently than asserted (record actual vs expected).

- [ ] **Step 3: Fix implementation (never the fixture) to match cargo**

Rule: when rime disagrees with real cargo on a ported case, the FIX goes in `src/cargo/*`, never in the fixture — fixtures mirror cargo's testsuite inputs verbatim. If cargo itself is ambiguous (e.g. the `matches_prerelease` upper-bound issue flagged in `semver_eval_ext.rs`), match current cargo behavior and cite the file/line in a comment.

- [ ] **Step 4: Add fixtures 7–17 + tests, verify full suite passes**

Run: `zig build test 2>&1 | tail -5`
Expected: PASS — entire suite green, oracle cases comparing against live cargo where possible.

- [ ] **Step 5: Commit**

```bash
jj status
jj commit testdata/cargo/resolve src/cargo/oracle.zig -m "Port cargo conformance fixtures"
```

---

### Task 12: Broad Cargo.toml surface — renames, target tables, workspace inheritance, [patch]/[replace]

**Files:**
- Modify: `src/cargo/manifest.zig` (ADDITIVE surface: renamed deps, target tables, inheritance, patch/replace tables, `resolver` field; existing `parseManifest` signature preserved)
- Test: inline tests in `src/cargo/manifest.zig` + fixtures `testdata/cargo/manifest-surface/*` (one dir per sub-feature with `Cargo.toml` pairs: workspace root + member)
- Modify: `src/cargo/root.zig` (no new line needed — `manifest` re-export already exists; verify)

**Interfaces:**
- Consumes: `toml.parseDocument` (M1 Task 1), `semver.VersionReq.parse` (Task 1, to validate reqs at parse time), `sources.Platform/parseCfg` (Task 7, to validate target-table keys at parse time).
- Produces (used by Tasks 10–11 oracle projections, M2/M4):
```zig
pub const DepRef = struct {
    key: []const u8,          // manifest key (the RENAME when package != null)
    package: ?[]const u8,     // real crate name; null when key is the real name
    kind: DependencyKind,     // M1 union extended: version_req/path/git/workspace_inherit + registry variant
    optional: bool,
    default_features: bool,   // default true
    features: []const []const u8,
    target: ?[]const u8,      // raw target selector text from the table header (validated by parseCfg)
    dep_kind: DepTableKind,   // normal | dev | build  (which [..-dependencies] table it came from)
    pub fn realName(self: DepRef) []const u8; // package orelse key — THE name used in resolve/lock/feature keys
};
pub const DepTableKind = enum { normal, dev, build };
pub const PatchEntry = struct { source: []const u8, deps: []const DepRef }; // one [patch.<source>] table
pub const ReplaceEntry = struct { spec: []const u8, dep: DepRef };          // one [replace."spec"] entry (deprecated, still honored)
pub const ManifestExt = struct {
    base: Manifest,                  // M1 model (unchanged)
    renamed: []const DepRef,         // ALL direct deps in unified form (replaces ad-hoc M1 deps iteration for M3 callers)
    target_deps: []const DepRef,      // [target.<sel>.{dependencies,dev-dependencies,build-dependencies}] merged
    patches: []const PatchEntry,
    replaces: []const ReplaceEntry,
    resolver: ?[]const u8,           // workspace root `resolver = "1"|"2"|"3"` (validated; Task 6 Behavior)
    workspace_deps: []const DepRef,  // [workspace.dependencies] (inheritance source)
};
pub const ManifestSurfaceError = error{ UnsupportedKey, UnsupportedManifestForm, UnknownInherit, InvalidManifest, OutOfMemory, ParseError, UnsupportedType };
pub fn parseManifestExt(gpa: std.mem.Allocator, text: []const u8, filename: []const u8) ManifestSurfaceError!ManifestExt;
pub fn resolveInheritance(gpa: std.mem.Allocator, member: ManifestExt, root: ManifestExt) ManifestSurfaceError!ManifestExt; // `{ workspace = true }` expansion
```

Reference pins: manifest grammar in `references/cargo/src/cargo/core/manifest.rs` + `cargo-util-schemas/src/manifest.rs` (which keys exist per table); inheritance in `core/workspace.rs` (`workspace.package.*`, `workspace.dependencies`, `workspace.features` merge rules — `{ workspace = true }` on a dep pulls req + features + optional + default-features from `[workspace.dependencies]`, overridable per-key EXCEPT the name); `[patch]` in `ops/resolve.rs::register_patch_entries` (patch versions → preferences + `avoid_patch_ids` + `registry.lock_patches()` + `UNUSED_PATCH_WARNING` text — the RESOLUTION half lands here as `patchPreferences()` below, not just parsing); `[replace]` in `dep_cache.rs::query` replacement block (override query, ambiguity errors); rename handling in `registry_dependency_into_dep` (`package` vs `name` split — §0.6).

Support table (normative — everything else is `UnsupportedKey`/`UnsupportedManifestForm` naming the key, file, and line; SILENT ignore is forbidden):

| Manifest form | Behavior |
|---|---|
| `dep = "req"` / `{ version, path, git, branch/tag/rev, registry, package, optional, default-features, features }` | full support; `version` validated by `VersionReq.parse` at parse time |
| `package = "real"` rename | `realName()` is the resolve/lock/feature key; manifest key kept for diagnostics only |
| `optional = true` + implicit feature | recorded; implicit same-name feature exists unless the entry uses `dep:` elsewhere (Task 5 consumes) |
| `[target.'cfg(…)'.dependencies]` (+ `dev-`/`build-` variants) | parsed to `target_deps` with header text validated by `sources.parseCfg` NOW (invalid cfg = `InvalidManifest`, not deferred) |
| `dep = { workspace = true }` + `[workspace.package]` / `[workspace.dependencies]` | `resolveInheritance` expands version/edition/rust-version/description/license + dep req/features/optional/default-features; inheriting a key the workspace lacks → `UnknownInherit` naming key + member file |
| `[patch.<source>]` | parsed + `patchPreferences()` projects each entry into Task-2 `preferred` versions AND the Task-4 avoid-locked set (patched-out locked ids lose `keep`); unused patch (no resolved node matches) → stderr warning with cargo's `UNUSED_PATCH_WARNING` first line |
| `[replace]` | parsed + applied at query time (override the replaced spec's candidates with the replacement's single version; 0 matches → `no matching package for override …` error; 2+ matches → `matched multiple packages` error; version drift between spec and replacement → `tried to override it with …` error — copy all three messages from `dep_cache.rs`) |
| `resolver = "1"/"2"/"3"` | validated, mapped to Task-6 `Behavior`; any other value → `InvalidManifest` naming valid options (copy `from_manifest` message) |
| `artifact = …`, `public = …`, `bindep-target`, `lib` on a dep | `UnsupportedManifestForm` naming the key (artifact/bindeps names `-Zbindeps`; index lines carrying artifact data NEVER error — §0.6, carried verbatim) |
| any other unknown key in a supported table | `UnsupportedKey` with `file:line: unknown key \`…\`` (M1 D2 rule, kept) |

`patchPreferences()` (new `pub` helper on `ManifestExt`, used by Task 4 wiring): takes previous-lock ids + patch entries, returns `{ prefer: []Version, avoid_locked: []Version }` — prefer = patch candidate versions (Task-2 `preferred`), avoid_locked = locked ids whose `(name)` appears in a patch table but whose version is NOT the patch version (the `avoid_patch_ids` refinement). `[patch]` with an unparseable source key → `InvalidManifest`.

- [ ] **Step 1: Write the failing surface tests**

```zig
test "manifest parses renames and target tables" {
    const text =
        \"[package]\nname = \"a\"\nversion = \"0.1.0\"\nedition = \"2021\"\n" ++
        \"[dependencies]\nold = { package = \"real-crate\", version = \"^1\", optional = true }\n" ++
        \"[target.'cfg(windows)'.dependencies]\nwin-only = \"2.0\"\n";
    var m = try parseManifestExt(std.testing.allocator, text, "Cargo.toml");
    defer m.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("real-crate", m.renamed[0].realName());
    try std.testing.expect(m.renamed[0].optional);
    try std.testing.expectEqualStrings("cfg(windows)", m.target_deps[0].target.?);
}

test "manifest inheritance expands workspace deps" {
    const root_text = "[workspace]\n[workspace.package]\nversion = \"0.2.0\"\nedition = \"2021\"\n[workspace.dependencies]\nserde = \"1.0\"\n";
    const mem_text = "[package]\nname = \"m\"\nversion.workspace = true\nedition.workspace = true\n[dependencies]\nserde.workspace = true\n";
    // resolveInheritance(member, root) → version 0.2.0, serde req ^1.0.
}

test "manifest rejects unknown keys loudly" {
    try std.testing.expectError(ManifestSurfaceError.UnsupportedManifestForm, parseManifestExt(std.testing.allocator, "[package]\nname = \"a\"\nversion = \"0.1.0\"\n[dependencies]\nx = { version = \"1\", artifact = [\"bin\"] }\n", "Cargo.toml"));
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `zig build test 2>&1 | tail -10`
Expected: FAIL — `parseManifestExt` / `DepRef` not defined.

- [ ] **Step 3: Write minimal implementation**

`parseManifestExt`: run M1 `parseManifest` first (keeps all M1 validation), then second pass over the TOML doc for the extended tables (target tables via dotted-header walk, `[patch.*]`/`[replace.*]` tables, `[workspace.*]` when present, `resolver` string). Every borrowed string comes from the M1 doc arena (extend `Manifest.deinit` ownership — document that `ManifestExt` owns `base` and frees it). `resolveInheritance`: clone-then-overlay (workspace values fill ONLY `workspace = true` slots; explicit member keys win; dep-level overlay merges features lists by concatenation, scalar overrides win). `patchPreferences`: name-match previous ids against patch tables per the table above.

- [ ] **Step 4: Add patch/replace + resolver tests, verify pass**

```zig
test "patch preferences avoid non-patch locked versions" {
    // previous log=1.0.0; patch table pins log=1.0.5 → prefer=[1.0.5], avoid_locked=[1.0.0].
}

test "replace ambiguity errors name the spec" {
    // two replacement candidates → error message contains "matched multiple packages" (dep_cache.rs wording).
}

test "resolver field validates" {
    try std.testing.expectError(ManifestSurfaceError.InvalidManifest, parseManifestExt(std.testing.allocator, "[workspace]\nresolver = \"4\"\n", "Cargo.toml"));
}
```

Run: `zig build test 2>&1 | tail -5`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
jj status
jj commit src/cargo/manifest.zig -m "Add broad manifest surface"
```

---

## Appendix A — spec coverage (M3 objective → task)

| Requirement | Task |
|---|---|
| version requirement matching | 1 |
| pre-release handling (stock + `--precise` RFC 3493) | 1, 4, 11 (cases 4, 13) |
| yanked handling (avoid + locked rescue) | 2, 4 (allow_yanked wiring), 11 (cases 2, 3) |
| feature unification v1 | 5 |
| feature unification v2 (`resolver = "2"`, v3 mapping) | 6 |
| workspace/path/git dependency edges | 7 (+ M1 workspace) |
| `--locked/--frozen/--offline` enforcement | 9 |
| minimal-change lockfile updates (`cargo update -p/--precise`) | 4, 11 (cases 1, 13) |
| byte-stable v4 writer + v3 read-compat (v1/v2 decode rules) | 8, 11 (cases 11, 12) |
| oracle harness (`generate-lockfile`/`metadata` vs rime) | 10 |
| ported `resolve.rs` / `features2.rs` / lockfile cases | 11 |
| rust-version-aware selection (`rust_version` ordering) | 2 |
| conflict cache / backtracking parity | 3 |
| sparse-index input model (IndexPackage/RegistryDependency field-for-field) | 2 (§0.6) |
| renamed deps (`package = …`) + optional/feature implications | 12, 11 (case 15) |
| target-specific `[target.'cfg(…)'.dependencies]` | 12, 7 |
| workspace inheritance (`workspace = true`) | 12, 11 (case 16) |
| `[patch]` preferences + avoid-locked-set + unused warning | 12, 11 (case 17) |
| `[replace]` override + ambiguity errors | 12 |
| loud named errors for unsupported surface (never silent) | 12, 2 (index side) |
| validation/ lane (rime vs committed cargo goldens per project) | 10 (Step 5) |

## Appendix B — open questions (for M2/M4 owners or operator call)

1. **Sparse-index access for the resolver seam:** RESOLVED by operator directive — the seam is Task-2 `IndexEntry`/`parseIndexLine` (sparse-index wire shape, §0.6). Remaining for M2: whether the fetcher serves raw per-crate index files (rime parses) or pre-parsed entries; either way the field contract is frozen here.
2. **`links =` values for registry crates:** index metadata carries `links`; confirm M2 surfaces it (Task 3 correctness depends on it for native libs like `zlib`).
3. **Git precise revs in fixtures:** Task 10 marks git cases network-dependent. Should the oracle vendor a local git server (cargo testsuite uses its own git fixtures) or stay path-only? Operator call on harness budget.
4. **`[patch]`/`[replace]` scope:** IN SCOPE via operator directive — Task 12 (parse + resolution wiring + warnings/errors). No deferral.
5. **TargetInfo source:** Task 7 matches cfg against a caller-supplied triple. M4's rustc discovery owns the host-target default; until then oracle tests pass literals. No action, recorded for interface stability.
6. **validation/ golden regeneration:** LANDED (`validation/README.md` + `validation/oracle.sh` own regeneration with the real cargo binary ONLY). There is NO `index-snapshot.json` convention — dropped (Task 10 Step 5); if golden filenames or layout change, Step 5's `discoverValidationProjects` + `golden.*` assumptions must be updated in the same commit.

## Self-review note

Coverage: every M3 objective clause maps to ≥1 task (Appendix A). Placeholder scan: no TBD/TODO/bare "handle edge cases" — every step names exact code, commands, and expected output. Type consistency: `Version`/`OptVersionReq`/`Candidate`/`IndexDep`/`IndexEntry`/`FeatureDef`/`DepKind`/`QueryFilter`/`DepEdge`/`SummaryNode`/`ResolveGraph`/`Registry`/`QueryError`/`KeepFilter`/`PrecisePin`/`FeatureMap`/`Unified`/`RootReq`/`DepFeatures`/`FeatureOpts`/`FeaturesFor`/`EdgeKind`/`NsSets`/`UnifiedNamespaces`/`SourceId`/`DepEdgeFull`/`NameCounts`/`EdgeForm`/`DepRef`/`ManifestExt`/`PatchEntry`/`ReplaceEntry`/`ResolveVersion`/`LockMode`/`LockCheck`/`Diag` signatures are identical at every use site; `lock.zig` and `manifest.zig` changes are strictly additive to the M1 APIs; `ResolvedRef`/`ResolvedNode` are source-keyed from Task 3's Interfaces (no retroactive rekey — Task 7 only defines `SourceId` and fills per-edge values, and Task 7's Step 4 keeps the already-source-keyed Task 3 tests green). Task count is 12 (skill range 8–12): the operator directive's three additions landed as §0.6+§0.7 (input model + manifest surface contract), Task 2 `IndexEntry`/`parseIndexLine`, Task 10 Step 5 (landed validation/ corpus), Task 11 cases 15–17 + sparse-index stub format, and new Task 12 — no existing task was split or removed.
