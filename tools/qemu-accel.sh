#!/usr/bin/env bash
# Echo QEMU acceleration arguments for this machine: "-enable-kvm" when the
# KVM device is available, nothing otherwise (QEMU falls back to TCG).
set -euo pipefail

if [[ -r /dev/kvm ]]; then
    echo "-enable-kvm"
fi
