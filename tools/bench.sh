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
TIMEOUT="${BENCH_TIMEOUT:-30}"

echo "bench: booting $ISO"
echo "bench: waiting for marker '$MARKER' (timeout ${TIMEOUT}s)"

tmpdir="$(mktemp -d)"
mkfifo "$tmpdir/serial.in" "$tmpdir/serial.out"

start_ns="$(date +%s%N)"

timeout "$TIMEOUT" qemu-system-x86_64 \
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

end_ns="$(date +%s%N)"

kill "$qemu_pid" 2>/dev/null || true
wait "$qemu_pid" 2>/dev/null || true
rm -rf "$tmpdir"

if [[ -z "$found" ]]; then
    echo "bench: FAIL (marker '$MARKER' not found)"
    exit 1
fi

elapsed_ns="$((end_ns - start_ns))"
elapsed_ms="$(awk "BEGIN { printf \"%.1f\", $elapsed_ns / 1000000 }")"
echo "bench: Kernel Entry -> First Frame (wall clock): ${elapsed_ms} ms"

BIN="${BIN:-zig-out/bin/aster}"
if [[ -f "$BIN" ]]; then
    size="$(stat -c %s "$BIN")"
    echo "bench: kernel image size: $size bytes"
fi
