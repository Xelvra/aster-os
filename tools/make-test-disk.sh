#!/usr/bin/env bash
# Create a deterministic Aster OS test disk image (spec/roadmap.md M6.1.5):
# GPT with one ext2 partition populated from a fixed root filesystem tree.
#
# The exact mke2fs invocation is the ADR-023 contract: ext2, no dir_index
# (HTree unsupported), files from ./tools/test-disk-root/.
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

rm -f "$OUT"
dd if=/dev/zero of="$OUT" bs=1M count=$SIZE status=none
parted -s "$OUT" mklabel gpt
parted -s "$OUT" mkpart primary ext2 "${PART_START}s" 100%
mke2fs -q -t ext2 -O ^dir_index -d "$ROOTFS" -E offset=$OFFSET "$OUT"

echo "test disk: $OUT (${SIZE} MiB, GPT + ext2, ^dir_index)"
