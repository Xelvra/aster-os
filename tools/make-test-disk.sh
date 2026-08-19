#!/usr/bin/env bash
# Create a deterministic Aster OS test disk image (spec/roadmap.md M6.1.5):
# GPT with one ext2 partition populated from a fixed root filesystem tree.
#
# The exact mke2fs invocation is the ADR-023 contract: ext2, no dir_index
# (HTree unsupported), files from ./tools/test-disk-root/, 1024 B blocks
# (explicit -b 1024: mke2fs's own default block-size heuristic differs by
# e2fsprogs version/host — CI picked 4096 B for the same 15 MiB filesystem
# where local dev machines picked 1024 B. 4096 B blocks are NOT a bug in the
# ext2 driver (verified on fresh disks, spec/troubleshooting.md C54 → H6), but
# pinning the size keeps every build identical regardless of host, per
# ADR-014, and avoids slow TCG runs without KVM).
#
# Usage: tools/make-test-disk.sh <output.img>
set -euo pipefail

cd "$(dirname "$0")/.."

OUT="${1:?usage: make-test-disk.sh <output.img>}"

SIZE=16          # MiB
PART_START=2048  # 1 MiB in 512-byte sectors
OFFSET=$((PART_START * 512))

ROOTFS="tools/test-disk-root"
if [[ ! -d "$ROOTFS" ]]; then
    echo "error: $ROOTFS not found" >&2
    exit 1
fi

# Disk apps (spec/adr/026): the launcher discovers wasm apps by scanning
# /apps/ on disk, so the test disk needs the freshly built calculator.wasm
# there too — a build artifact, so it is staged in, not committed under
# tools/test-disk-root/ (that tree is the source-controlled fixture).
zig build >/dev/null
STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT
cp -r "$ROOTFS"/. "$STAGING"/
mkdir -p "$STAGING/apps"
cp zig-out/apps/calculator.wasm "$STAGING/apps/calculator.wasm"

rm -f "$OUT"
dd if=/dev/zero of="$OUT" bs=1M count=$SIZE status=none
parted -s "$OUT" mklabel gpt
parted -s "$OUT" mkpart primary ext2 "${PART_START}s" 100%
mke2fs -q -t ext2 -b 1024 -O ^dir_index -d "$STAGING" -E offset=$OFFSET "$OUT"

echo "test disk: $OUT (${SIZE} MiB, GPT + ext2, ^dir_index)"
