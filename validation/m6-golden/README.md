# M6 validation goldens (CLI parity)

Committed oracle-captured streams + the exit-code matrix for the M6 CLI
surface. Toolchain pin: `cargo 1.99.0-nightly` (see `regen.sh`).

## Oracle-verified facts (cargo 1.99.0-nightly, 2026-07-29)

Recorded against `validation/basic-workspace` and scratch fixtures; rime
matches every row (Suite B asserts equality per row):

| Situation | Code |
|---|---|
| unknown command / unknown flag / bad flag value / `--help` misuse | 1 |
| `--help` / `--version` | 0 (stdout) |
| missing `--manifest-path` target | 101 (`could not find Cargo.toml`) |
| invalid manifest TOML | 101 |
| unknown `-p` name | 101 |
| message-format two-kinds conflict (`json,human`) | 101 |
| message-format unknown specifier (`yaml`) | 1 |
| `--release` + `--profile` | 1 |
| `-C DIR` (unstable) | 1 |
| `-j0` / `-jabc` | 101 |
| `--bin no-such-bin` | 101 |
| stale lock under `--locked`/`--frozen` | 101 (`cannot update the lock file … because --locked was passed…`) |
| `run`: child exits N | N |
| `run`: spawn failure / signal | 101 |

Rule of thumb: clap-level parse failures exit 1; everything after a
successful parse (workspace discovery, selection, jobs/config validation,
fetch, build, spawn) is the anyhow class and exits 101.

## Package ID wire forms (oracle-observed)

- registry: `registry+https://github.com/rust-lang/crates.io-index#serde@1.0.229`
- path: `path+file:///abs/dir#0.1.0` (NO name — the name is redundant with
  the path; `msg.packageId` implements exactly this)
- git: `git+<url>#<name>@<version>`

## Target object shapes (oracle-observed)

- lib: `{"kind":["lib"],"crate_types":["lib"],"name":"core_lib",…,"doc":true,"doctest":true,"test":true}` (dashes → underscores)
- bin: `{"kind":["bin"],"crate_types":["bin"],"name":"cli-bin",…,"doc":true,"doctest":false,"test":true}` (dashes KEPT)
- build scripts: `{"kind":["custom-build"],…,"name":"build-script-build",…,"doc":false,"doctest":false,"test":false}` (rime never emits `custom-build`; build scripts are plan-level units)
- profile dev: `{"opt_level":"0","debuginfo":2,…}`; build-script units compile with `debuginfo:0`

## Files

- `basic-workspace.build.json` — normalized WARM-rebuild oracle stream
  (`cargo build --message-format=json`, second run so every artifact is
  `fresh:true`). Normalizations: absolute scratch root →
  `@VALIDATION_ROOT@`, 16-hex metadata hashes → `<META>----------`.
  Goldens change only via `regen.sh`.
- `exit-matrix.json` — `{rows: [{argv, fixture, code, needle}]}`; `@FIXTURE@`
  substitutes the scratch copy of `fixture`. Suite B asserts rime's code ==
  cargo's code == `code`, plus the needle on rime's stderr.
- `stale-lock/` — path-only virtual-workspace fixture whose lock is stale
  (app 0.2.0 vs locked 0.1.0) for the `--locked` row. Path-only so the row
  needs no network. (A root-package + path-dep shape crashes the frozen M4
  pipeline with an `owned_exts` double-free — pre-existing M4 bug, out of
  M6 scope; the virtual shape is the workaround. See impl report.)
- `regen.sh` — regenerates the stream golden with the pinned toolchain.
- `README.md` — this file.

## Suites

- A (gated `RIME_CARGO_ORACLE=1`): `compareJsonStream` replays the oracle
  warm rebuild and diffs the normalized stream against the golden. Note:
  rime's own real-build JSON comes from the frozen M4 pipeline envelopes;
  Suite A pins the normative oracle stream that `msg.zig` shapes are
  unit-tested against.
- B (gated): `checkExitMatrix` runs every matrix row against both binaries.
- C (always): help-text snapshot tests pin rime's own strings
  (`src/main.zig`); cargo-command help is NEVER byte-compared to cargo's.
