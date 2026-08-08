#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

ISO="${1:-}"
if [[ -z "$ISO" ]]; then
    echo "building ISO..."
    zig build iso
    ISO="$(find .zig-cache -name aster.iso -printf '%T@ %p\n' | sort -rn | head -1 | cut -d' ' -f2-)"
fi

BOOT_MARKER="ASTER KERNEL ENTRY"
ENTRY_MARKER="ASTER FIRST FRAME"
TIMEOUT="${BENCH_TIMEOUT:-30}"

echo "bench: booting $ISO"
echo "bench: waiting for '$BOOT_MARKER' then '$ENTRY_MARKER' (timeout ${TIMEOUT}s)"

tmpdir="$(mktemp -d)"
mkfifo "$tmpdir/serial.in" "$tmpdir/serial.out"

start_ns="$(date +%s%N)"

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

boot_ns=""
entry_ns=""
while IFS= read -r line; do
    if [[ -z "$boot_ns" ]] && grep -q "$BOOT_MARKER" <<<"$line"; then
        boot_ns="$(date +%s%N)"
    fi
    if grep -q "$ENTRY_MARKER" <<<"$line"; then
        entry_ns="$(date +%s%N)"
        break
    fi
done <"$tmpdir/serial.out"

kill "$qemu_pid" 2>/dev/null || true
wait "$qemu_pid" 2>/dev/null || true
rm -rf "$tmpdir"

if [[ -z "$entry_ns" ]]; then
    echo "bench: FAIL (markers '$BOOT_MARKER'/'$ENTRY_MARKER' not found)"
    exit 1
fi

elapsed_ns="$((entry_ns - start_ns))"
kernel_ns="$((entry_ns - boot_ns))"
elapsed_ms="$(awk "BEGIN { printf \"%.1f\", $elapsed_ns / 1000000 }")"
kernel_ms="$(awk "BEGIN { printf \"%.1f\", $kernel_ns / 1000000 }")"

echo "bench: Firmware -> First Frame (wall clock, incl. BIOS+Limine): ${elapsed_ms} ms"
echo "bench: Kernel Entry -> First Frame (kernel only): ${kernel_ms} ms"

BIN="${BIN:-zig-out/bin/aster}"
if [[ -f "$BIN" ]]; then
    size="$(stat -c %s "$BIN")"
    echo "bench: kernel image size: $size bytes"
fi
