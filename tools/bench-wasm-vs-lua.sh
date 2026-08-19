#!/usr/bin/env bash
# M7 Fáze C benchmark (spec/roadmap.md): boots a kernel built with
# `-Dbench=true`, which spawns the wasm and Lua Mandelbrot twins
# (src/kernel/apps/bench.zig, src/kernel/lua/programs/bench.lua) once each
# and times the spawn calls with the kernel's own clock, then exits via
# isa-debug-exit. Same foreground `timeout ... >file` pattern as
# tools/qemu-test.sh — no blocking FIFO read, so a QEMU that fails to boot
# cannot hang this script (see tools/qemu-smoke.sh's fix for that class of
# bug).
set -euo pipefail

cd "$(dirname "$0")/.."

ISO="${1:-}"
if [[ -z "$ISO" ]]; then
    echo "building ISO with the M7 benchmark..."
    zig build iso -Dbench=true
    ISO="zig-out/aster.iso"  # fixed output path (2026-08-15-self-audit)
fi

PASS_CODE="99"
TIMEOUT="${BENCH_TIMEOUT:-60}"

read -r -a ACCEL <<< "$(./tools/qemu-accel.sh)"

echo "bench: booting $ISO (timeout ${TIMEOUT}s)"

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT
serial_log="$tmpdir/serial.log"

set +e
timeout "$TIMEOUT" qemu-system-x86_64 \
    "${ACCEL[@]}" \
    -M q35 \
    -m 512M \
    -smp 2 \
    -rtc base=localtime \
    -cdrom "$ISO" \
    -device isa-debug-exit \
    -serial stdio \
    -boot order=d \
    -no-reboot \
    -display none \
    >"$serial_log" 2>&1
exit_code=$?
set -e

if [[ "$exit_code" -ne "$PASS_CODE" ]]; then
    echo "bench: FAIL (exit $exit_code, expected $PASS_CODE)"
    echo "bench: last serial output:"
    tail -n 40 "$serial_log"
    exit 1
fi

wasm_ms="$(grep -oP 'BENCH WASM MS \K[0-9]+' "$serial_log" || true)"
lua_ms="$(grep -oP 'BENCH LUA MS \K[0-9]+' "$serial_log" || true)"
wasm_checksum="$(grep -oP 'BENCH WASM CHECKSUM \K[0-9]+' "$serial_log" || true)"
lua_checksum="$(grep -oP 'BENCH LUA CHECKSUM \K[0-9]+' "$serial_log" || true)"

if [[ -z "$wasm_ms" || -z "$lua_ms" || -z "$wasm_checksum" || -z "$lua_checksum" ]]; then
    echo "bench: FAIL (missing markers in serial output)"
    tail -n 40 "$serial_log"
    exit 1
fi

echo "bench: wasm  ${wasm_ms} ms (checksum ${wasm_checksum})"
echo "bench: lua   ${lua_ms} ms (checksum ${lua_checksum})"

if [[ "$wasm_checksum" != "$lua_checksum" ]]; then
    echo "bench: FAIL (checksum mismatch — the two Mandelbrot implementations diverged)"
    exit 1
fi

echo "bench: PASS (identical result, wasm3 vs Lua 5.4 both interpreted — see spec/roadmap.md Fáze C)"
