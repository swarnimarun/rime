# rime validation corpus

Real, runnable Rust projects that rime is validated against end to end.
Each project is accepted by the pinned real cargo (see toolchain below),
and each ships committed golden files produced by actual successful cargo
invocations. The goldens are the conformance bar for manifest support,
crates.io behavior, resolution, and lockfile semantics.

## Layout

| Project | What it covers |
|---|---|
| `basic-workspace/` | 3-member workspace (`lib` + `bin` + path-dep member), workspace inheritance (`version`/`edition`/`license` + `workspace = true` deps), shared `[workspace.dependencies]`, one registry dep (`serde`), one dev-dep (`serde_json` on the bin), one build-dep + one dev-dep (both `anyhow` on `core-lib`) with `build.rs` emitting a `cfg`. |
| `feature-matrix/` | Optional deps with feature implications (`json`/`tls`/`full`), renamed dep (`http_client` = crates.io `ureq`), target-specific deps (`[target.'cfg(unix)'.dependencies]` on `libc`, `[target.'cfg(windows)'.dependencies]` on `windows-sys`), `resolver = "2"`, `dep:` syntax, weak dep (`serde?/derive`). |
| `lockfile-golden/` | Resolver/lockfile byte-compare golden: real crates.io deps (`serde` + `derive`, `serde_json`, `anyhow`, `libc`, dev-dep `tempfile`). The committed `Cargo.lock` is the golden rime's resolver/lock writer must reproduce. |
| `full-manifest/` | Manifest breadth: `[package]` with most keys (`description`, `license`, `repository`, `homepage`, `documentation`, `readme`, `keywords`, `categories`, `authors`, `rust-version`, `build`, `publish = false`, `exclude`), `[lib]` + `[[bin]]` + `[[example]]` + `[[bench]]` (`harness = false`) + `[[test]]` targets, `[profile.dev]` / `[profile.release]` / `[profile.dev.package."*"]` / `[profile.release.package."*"]` overrides, `[package.metadata]` (must be tolerated/ignored), `[patch.crates-io]` with a local path patch for `smallvec`. |

### Coverage matrix (which project exercises what)

| Concern | basic-workspace | feature-matrix | lockfile-golden | full-manifest |
|---|---|---|---|---|
| `[workspace]` + members | ✅ | | | ✅ (empty, standalone) |
| `[workspace.package]` / `[workspace.dependencies]` inheritance | ✅ | | | |
| path deps between members | ✅ (`core-lib`, `util`) | | | |
| registry deps | ✅ (`serde`, `anyhow`) | ✅ | ✅ | ✅ |
| dev-deps / build-deps + `build.rs` | ✅ | ✅ (dev) | ✅ (dev) | ✅ (both) |
| optional deps + `[features]` | | ✅ | | ✅ (`extra`) |
| `dep:` / weak (`?/`) syntax | | ✅ | | |
| renamed dep (`package =`) | | ✅ (`http_client`→`ureq`) | | |
| target-specific deps | | ✅ (unix + windows) | | ✅ (unix `libc`) |
| `resolver = "2"` | ✅ (workspace) | ✅ (package) | | |
| profiles (`dev`/`release`/`package."*"`) | | | | ✅ |
| `[package.metadata]` tolerance | | | | ✅ |
| `[patch.crates-io]` path patch | | | | ✅ (`smallvec`) |
| committed lockfile golden | ✅ (`golden.Cargo.lock`) | ✅ (`golden.Cargo.lock`) | ✅ (`Cargo.lock`) | ✅ (`golden.Cargo.lock`) |
| `cargo tree` golden | ✅ | ✅ (+ `-e features`, `--all-features`) | ✅ | ✅ |

## Golden files

Per project (names vary slightly, see table above):

- `golden.metadata.json` — output of `cargo metadata --format-version 1`.
- `golden.Cargo.lock` (or committed `Cargo.lock` in `lockfile-golden/`) —
  output of `cargo generate-lockfile`. The `lockfile-golden/Cargo.lock`
  is the byte-compare golden for rime's resolver/lock writer.
- `golden.tree.txt` — output of `cargo tree` (plus
  `golden.tree-features.txt` / `golden.tree-all-features.txt` for
  `feature-matrix`).

## Toolchain used to generate the goldens

- `cargo 1.99.0-nightly (7c83d4cc0 2026-07-29)`, host `aarch64-apple-darwin`
- `rustc 1.99.0-nightly (1ed2df61a 2026-08-04)`

Exact commands (run in each project dir, in this order):

```sh
cargo generate-lockfile
cp Cargo.lock golden.Cargo.lock        # every project EXCEPT lockfile-golden,
                                       # where Cargo.lock itself is the golden
cargo metadata --format-version 1 > golden.metadata.json
cargo tree > golden.tree.txt
# feature-matrix only:
cargo tree -e features --prefix none > golden.tree-features.txt
cargo tree --all-features > golden.tree-all-features.txt
```

Plus `cargo check` per project (`--all-targets` for workspace/lockfile/full;
default and `--all-features` for feature-matrix) to prove each fixture
actually builds, not just resolves.

## Oracle

`oracle.sh` re-runs `cargo metadata`, `cargo tree` (all variants), and
`cargo generate-lockfile` for every project and diffs the fresh output
against the committed goldens. Exit `0` = match, exit `1` = mismatch
(per-project `FAIL:` lines, first 20 diff lines each).

```sh
./validation/oracle.sh
```

Notes:

- `cargo metadata` / `cargo tree` embed absolute checkout paths, so the
  oracle normalizes the validation root to `@VALIDATION_ROOT@` on both
  sides before diffing. Lockfiles contain no absolute paths and are
  compared byte-for-byte.
- For `lockfile-golden/`, the oracle backs up the committed `Cargo.lock`,
  regenerates, diffs, and restores it, so the committed golden is never
  dirtied. For the other projects the scratch `Cargo.lock` is gitignored
  (see `.gitignore`) and left in place to keep later cargo runs offline.
- Regenerating goldens from a clean machine needs network (crates.io
  index + downloads). Re-running the oracle against warm caches works
  offline. New crate releases upstream will legitimately invalidate the
  lock goldens — that is the signal to consciously re-pin, not a failure.

## How rime's tests should consume this corpus

- **Offline:** everything needed is committed. Tests can parse the
  `Cargo.toml` fixtures and assert against `golden.metadata.json`
  (normalized the same way `oracle.sh` does), `golden.tree*.txt`, and
  the lock goldens without any network.
- **Online / conformance:** run `./validation/oracle.sh` to confirm the
  goldens still match the real cargo, then run rime's resolver over each
  project and diff rime's lock output against `golden.Cargo.lock`
  (`lockfile-golden/Cargo.lock` byte-for-byte).
- Suggested rime-side assertions per project: workspace member discovery
  + inheritance (`basic-workspace`); feature unification incl. weak deps
  and target-gated deps (`feature-matrix`, incl. `--all-features` tree);
  exact lock reproduction (`lockfile-golden`); ignoring
  `[package.metadata]`/profiles while honoring `[patch.crates-io]`
  (`full-manifest`).

## Cargo behavior surprises (observed while building the corpus)

1. `cargo::` build-script syntax vs `rust-version`: `full-manifest` first
   used `rust-version = "1.74"` with `cargo::rustc-check-cfg` output lines
   and cargo refused it — the `cargo::` syntax needs rust-version ≥ 1.77.
   Bumped to `rust-version = "1.77"`. (This also confirms rime must
   enforce/observe the rust-version × build-script-syntax interaction.)
2. `libc::getpagesize` is gone from current `libc` (`lockfile-golden`
   failed to compile); replaced with `libc::getpid`. Rime-side note:
   none — fixture-only, but don't assume old libc APIs exist.
3. Current `serde_json` pulls an extra `zmij` dependency (visible in all
   `cargo tree` goldens) — a reminder that `cargo tree` goldens pin the
   transitive closure as of generation date and will drift as upstream
   releases move.
4. `cargo generate-lockfile` on `feature-matrix` notes
   `ureq v2.12.1 (available: v3.4.2)` / `windows-sys v0.59.0 (available:
   v0.61.2)` — requirements resolve to latest *compatible*, not latest
   overall. Rime's resolver must implement semver-compatible max, not max.
5. `[[bench]]` with `harness = false` is a plain `fn main` target and
   checks cleanly on stable-pinned nightly without extra config.
