#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

ISO="${1:-}"
if [[ -z "$ISO" ]]; then
    echo "building ISO..."
    zig build iso
    ISO="zig-out/aster.iso"  # fixed output path (audit 2026-08-15)
fi

MARKER="${SMOKE_MARKER:-ASTER BOOT OK}"
TIMEOUT="${SMOKE_TIMEOUT:-30}"
DISK="${SMOKE_DISK:-}"

if ! command -v qemu-system-x86_64 >/dev/null 2>&1; then
    echo "smoke: qemu-system-x86_64 not found" >&2
    exit 1
fi

echo "smoke: booting $ISO"
echo "smoke: waiting for marker '$MARKER' (timeout ${TIMEOUT}s)"
if [[ -n "$DISK" ]]; then
    echo "smoke: disk attached: $DISK"
fi

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT
mkfifo "$tmpdir/serial.in" "$tmpdir/serial.out"

read -r -a ACCEL <<< "$(./tools/qemu-accel.sh)"

disk_args=()
if [[ -n "$DISK" ]]; then
    disk_args=(-drive "file=$DISK,format=raw,if=none,id=hd0" -device virtio-blk-pci,drive=hd0,disable-legacy=on)
fi

timeout "$TIMEOUT" qemu-system-x86_64 \
    "${ACCEL[@]}" \
    -M q35 \
    -m 512M \
    -cdrom "$ISO" \
    "${disk_args[@]}" \
    -chardev pipe,id=serial0,path="$tmpdir/serial" \
    -serial chardev:serial0 \
    -display none \
    -boot order=d \
    -no-reboot \
    -no-shutdown \
    >/dev/null 2>&1 &

qemu_pid=$!

found=""
log=""
while IFS= read -r line; do
    clean="$(sed $'s/\x1b\[[0-9;]*m//g' <<<"$line")"
    log+="$clean"$'\n'
    if grep -qF "$MARKER" <<<"$clean"; then
        found="$clean"
        break
    fi
done <"$tmpdir/serial.out"

kill "$qemu_pid" 2>/dev/null || true
wait "$qemu_pid" 2>/dev/null || true

if [[ -n "$found" ]]; then
    echo "smoke: PASS ($MARKER found)"
    exit 0
else
    echo "smoke: FAIL (marker '$MARKER' not found)"
    printf '%s' "$log" | tail -n 20
    exit 1
fi
