#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

ISO="${1:-}"
if [[ -z "$ISO" ]]; then
    echo "building ISO..."
    zig build iso
    ISO="$(find .zig-cache -name aster.iso -printf '%T@ %p\n' | sort -rn | head -1 | cut -d' ' -f2-)"
fi

MARKER="ASTER BOOT OK"
TIMEOUT="${SMOKE_TIMEOUT:-30}"

echo "smoke: booting $ISO"
echo "smoke: waiting for marker '$MARKER' (timeout ${TIMEOUT}s)"

tmpdir="$(mktemp -d)"
mkfifo "$tmpdir/serial.in" "$tmpdir/serial.out"

read -r -a ACCEL <<< "$(./tools/qemu-accel.sh)"

timeout "$TIMEOUT" qemu-system-x86_64 \
    "${ACCEL[@]}" \
    -M q35 \
    -m 512M \
    -cdrom "$ISO" \
    -chardev pipe,id=serial0,path="$tmpdir/serial" \
    -serial chardev:serial0 \
    -display none \
    -no-reboot \
    -no-shutdown \
    >/dev/null 2>&1 &

qemu_pid=$!

found=""
while IFS= read -r line; do
    if grep -q "$MARKER" <<<"$line"; then
        found="$line"
        break
    fi
done <"$tmpdir/serial.out"

kill "$qemu_pid" 2>/dev/null || true
wait "$qemu_pid" 2>/dev/null || true
rm -rf "$tmpdir"

if [[ -n "$found" ]]; then
    echo "smoke: PASS ($MARKER found)"
    exit 0
else
    echo "smoke: FAIL (marker '$MARKER' not found)"
    exit 1
fi
