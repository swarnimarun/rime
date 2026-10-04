#!/bin/sh
# Regenerates M6 oracle goldens with the pinned toolchain.
# Fails unless `cargo --version` is 1.99.0-nightly. Goldens change only here.
set -eu
HERE=$(dirname "$0")
ROOT="$HERE/../.."
WANT="cargo 1.99.0-nightly"
GOT=$(cargo --version 2>/dev/null || true)
case "$GOT" in
  "$WANT"*) ;;
  *) echo "regen.sh: need '$WANT', got '$GOT'" >&2; exit 1;;
esac
FIX="$HERE/basic-workspace.build.json"
SCRATCH=$(mktemp -d)
SCRATCH=$(cd "$SCRATCH" && pwd -P)
trap 'rm -rf "$SCRATCH"' EXIT
cp -r "$ROOT/validation/basic-workspace" "$SCRATCH/w"
# Warm the target dir, then capture the all-fresh rebuild.
(cd "$SCRATCH/w" && cargo build --message-format=json >/dev/null 2>&1)
(cd "$SCRATCH/w" && cargo build --message-format=json 2>/dev/null > "$SCRATCH/stream.json")
python3 - "$SCRATCH/w" "$SCRATCH/stream.json" > "$FIX" <<'EOF'
import sys, re
root, path = sys.argv[1], sys.argv[2]
dash16 = re.compile(r'(-)([0-9a-f]{16})(?=[./"-])')
slash16 = re.compile(r'(/)([0-9a-f]{16})(?=[/])')
with open(path) as f:
    for line in f:
        line = line.replace(root, '@VALIDATION_ROOT@')
        line = dash16.sub(r'\g<1><META>----------', slash16.sub(r'\g<1><META>----------', line))
        sys.stdout.write(line)
EOF
echo "regenerated $FIX"
