#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

OPTIMIZE="${OPTIMIZE:-ReleaseSafe}"
TMPDIR_BASE="$(mktemp -d)"

cleanup() {
    rm -rf "$TMPDIR_BASE"
}
trap cleanup EXIT

build_once() {
    local cache_dir="$1"
    mkdir -p "$cache_dir"
    ZIG_LOCAL_CACHE_DIR="$cache_dir" zig build -Doptimize="$OPTIMIZE" >/dev/null 2>&1
    sha256sum zig-out/bin/aster | awk '{print $1}'
}

echo "reproducible: building kernel twice (-Doptimize=$OPTIMIZE)..."

hash1="$(build_once "$TMPDIR_BASE/cache1")"
rm -rf zig-out
hash2="$(build_once "$TMPDIR_BASE/cache2")"

echo "reproducible: hash #1 $hash1"
echo "reproducible: hash #2 $hash2"

if [[ "$hash1" == "$hash2" ]]; then
    echo "reproducible: PASS (deterministic build, ADR-014)"
    exit 0
else
    echo "reproducible: FAIL (hashes differ)"
    exit 1
fi
