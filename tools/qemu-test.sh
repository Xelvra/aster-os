#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

ISO="${1:-}"
if [[ -z "$ISO" ]]; then
    echo "building ISO with runtime tests..."
    zig build iso -Druntime-tests=true
    ISO="zig-out/aster.iso"  # fixed output path (audit 2026-08-15)
fi

PASS_CODE="99"
TIMEOUT="${QEMU_TEST_TIMEOUT:-30}"
DISK="${QEMU_TEST_DISK:-}"

read -r -a ACCEL <<< "$(./tools/qemu-accel.sh)"

echo "qemu-test: booting $ISO"
echo "qemu-test: expecting isa-debug-exit pass code $PASS_CODE (timeout ${TIMEOUT}s)"
if [[ -n "$DISK" ]]; then
    echo "qemu-test: disk attached: $DISK"
fi

disk_args=()
if [[ -n "$DISK" ]]; then
    disk_args=(-drive "file=$DISK,format=raw,if=none,id=hd0" -device virtio-blk-pci,drive=hd0,disable-legacy=on)
fi

# Keep the serial stream so a failure is diagnosable (audit 2026-08-15).
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT
serial_log="$tmpdir/serial.log"

set +e
timeout "$TIMEOUT" qemu-system-x86_64 \
    "${ACCEL[@]}" \
    -M q35 \
    -m 512M \
    -cdrom "$ISO" \
    "${disk_args[@]}" \
    -device isa-debug-exit \
    -serial stdio \
    -boot order=d \
    -no-reboot \
    -display none \
    >"$serial_log" 2>&1
exit_code=$?
set -e

if [[ "$exit_code" -eq "$PASS_CODE" ]]; then
    echo "qemu-test: PASS (exit $exit_code)"
    exit 0
else
    echo "qemu-test: FAIL (exit $exit_code, expected $PASS_CODE)"
    echo "qemu-test: last serial output:"
    tail -n 40 "$serial_log"
    exit 1
fi
