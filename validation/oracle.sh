#!/usr/bin/env bash
# Oracle: re-run the real cargo against every validation project and diff
# the fresh output against the committed goldens. Exit 1 on any mismatch.
#
# Regenerating needs network (crates.io index) the first time; once the
# local cargo cache is warm, `cargo metadata`/`cargo tree` work offline
# because every project has a lockfile on disk.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FAILURES=0

# cargo metadata / cargo tree embed absolute checkout paths. Normalize the
# validation root out of both sides before diffing so the oracle passes
# from any checkout location. golden.*.Cargo.lock / Cargo.lock files never
# contain absolute paths and are compared byte-for-byte.
normalize() {
  sed "s|${ROOT}|@VALIDATION_ROOT@|g" "$1"
}

check_metadata() {
  local dir="$1"
  if ! cargo metadata --format-version 1 --manifest-path "$dir/Cargo.toml" \
      > "$dir/.oracle.metadata.fresh" 2>"$dir/.oracle.metadata.err"; then
    echo "FAIL: $dir: cargo metadata exited non-zero"
    tail -5 "$dir/.oracle.metadata.err"
    rm -f "$dir/.oracle.metadata.fresh" "$dir/.oracle.metadata.err"
    FAILURES=$((FAILURES + 1))
    return
  fi
  rm -f "$dir/.oracle.metadata.err"
  if ! diff <(normalize "$dir/golden.metadata.json") \
            <(normalize "$dir/.oracle.metadata.fresh") \
            > "$dir/.oracle.metadata.diff"; then
    echo "FAIL: $dir: cargo metadata differs from golden.metadata.json"
    head -20 "$dir/.oracle.metadata.diff"
    FAILURES=$((FAILURES + 1))
  else
    echo "ok:   $dir metadata"
    rm -f "$dir/.oracle.metadata.diff"
  fi
  rm -f "$dir/.oracle.metadata.fresh"
}

check_tree() {
  local dir="$1" golden="$2"
  shift 2
  local name
  name="$(basename "$golden")"
  if ! cargo tree --manifest-path "$dir/Cargo.toml" "$@" \
      > "$dir/.oracle.$name.fresh" 2>"$dir/.oracle.$name.err"; then
    echo "FAIL: $dir: cargo tree $* exited non-zero"
    tail -5 "$dir/.oracle.$name.err"
    rm -f "$dir/.oracle.$name.fresh" "$dir/.oracle.$name.err"
    FAILURES=$((FAILURES + 1))
    return
  fi
  rm -f "$dir/.oracle.$name.err"
  if ! diff <(normalize "$dir/$golden") \
            <(normalize "$dir/.oracle.$name.fresh") \
            > "$dir/.oracle.$name.diff"; then
    echo "FAIL: $dir: cargo tree $* differs from $golden"
    head -20 "$dir/.oracle.$name.diff"
    FAILURES=$((FAILURES + 1))
  else
    echo "ok:   $dir $name"
    rm -f "$dir/.oracle.$name.diff"
  fi
  rm -f "$dir/.oracle.$name.fresh"
}

# Regenerate the lockfile from scratch (delete the scratch lock first so
# resolution really re-runs) and byte-compare against the golden.
# $1 = project dir, $2 = golden filename (Cargo.lock or golden.Cargo.lock)
check_lock() {
  local dir="$1" golden="$2"
  if [ "$golden" = "Cargo.lock" ]; then
    # The committed Cargo.lock IS the golden: back it up, regenerate,
    # compare, restore, so the oracle never dirties the committed file.
    cp "$dir/Cargo.lock" "$dir/.oracle.lock.orig"
    if ! (cd "$dir" && cargo generate-lockfile 2>"$dir/.oracle.lock.err"); then
      echo "FAIL: $dir: cargo generate-lockfile exited non-zero"
      tail -5 "$dir/.oracle.lock.err"
      cp "$dir/.oracle.lock.orig" "$dir/Cargo.lock"
      rm -f "$dir/.oracle.lock.orig" "$dir/.oracle.lock.err"
      FAILURES=$((FAILURES + 1))
      return
    fi
    rm -f "$dir/.oracle.lock.err"
    if ! diff "$dir/.oracle.lock.orig" "$dir/Cargo.lock" > "$dir/.oracle.lock.diff"; then
      echo "FAIL: $dir: regenerated Cargo.lock differs from committed Cargo.lock"
      head -20 "$dir/.oracle.lock.diff"
      FAILURES=$((FAILURES + 1))
    else
      echo "ok:   $dir Cargo.lock"
      rm -f "$dir/.oracle.lock.diff"
    fi
    cp "$dir/.oracle.lock.orig" "$dir/Cargo.lock"
    rm -f "$dir/.oracle.lock.orig"
  else
    rm -f "$dir/Cargo.lock"
    if ! (cd "$dir" && cargo generate-lockfile 2>"$dir/.oracle.lock.err"); then
      echo "FAIL: $dir: cargo generate-lockfile exited non-zero"
      tail -5 "$dir/.oracle.lock.err"
      rm -f "$dir/.oracle.lock.err"
      FAILURES=$((FAILURES + 1))
      return
    fi
    rm -f "$dir/.oracle.lock.err"
    if ! diff "$dir/$golden" "$dir/Cargo.lock" > "$dir/.oracle.lock.diff"; then
      echo "FAIL: $dir: regenerated Cargo.lock differs from $golden"
      head -20 "$dir/.oracle.lock.diff"
      FAILURES=$((FAILURES + 1))
    else
      echo "ok:   $dir $golden"
      rm -f "$dir/.oracle.lock.diff"
    fi
    # The scratch Cargo.lock is gitignored; leaving the fresh one in place
    # keeps later cargo invocations offline-friendly.
  fi
}

for proj in basic-workspace feature-matrix lockfile-golden full-manifest; do
  dir="$ROOT/$proj"
  check_metadata "$dir"
  check_tree "$dir" golden.tree.txt
done
check_tree "$ROOT/feature-matrix" golden.tree-features.txt -e features --prefix none
check_tree "$ROOT/feature-matrix" golden.tree-all-features.txt --all-features

check_lock "$ROOT/basic-workspace" golden.Cargo.lock
check_lock "$ROOT/feature-matrix" golden.Cargo.lock
check_lock "$ROOT/lockfile-golden" Cargo.lock
check_lock "$ROOT/full-manifest" golden.Cargo.lock

if [ "$FAILURES" -ne 0 ]; then
  echo "oracle: $FAILURES mismatch(es)"
  exit 1
fi
echo "oracle: all goldens match"
