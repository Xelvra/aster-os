#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

ISO="${1:-}"
if [[ -z "$ISO" ]]; then
    echo "building ISO with runtime tests..."
    zig build iso -Druntime-tests=true
    ISO="$(find .zig-cache -name aster.iso -printf '%T@ %p\n' | sort -rn | head -1 | cut -d' ' -f2-)"
fi

PASS_CODE="99"
TIMEOUT="${QEMU_TEST_TIMEOUT:-30}"

read -r -a ACCEL <<< "$(./tools/qemu-accel.sh)"

echo "qemu-test: booting $ISO"
echo "qemu-test: expecting isa-debug-exit pass code $PASS_CODE (timeout ${TIMEOUT}s)"

set +e
timeout "$TIMEOUT" qemu-system-x86_64 \
    "${ACCEL[@]}" \
    -M q35 \
    -m 512M \
    -cdrom "$ISO" \
    -device isa-debug-exit \
    -serial stdio \
    -boot order=d \
    -no-reboot \
    -display none \
    >/dev/null 2>&1
exit_code=$?
set -e

if [[ "$exit_code" -eq "$PASS_CODE" ]]; then
    echo "qemu-test: PASS (exit $exit_code)"
    exit 0
else
    echo "qemu-test: FAIL (exit $exit_code, expected $PASS_CODE)"
    exit 1
fi
