#!/usr/bin/env bash
# check-ki-docs.sh — verify that every KI identifier in the code is
# documented in the specifications.
#
# The Kernel Interface spec (kernel-interface.md §4/6) claims the
# documentation of the KI is "ABI truth": numbers are frozen and the
# documented surface is the contract. This check makes that an
# enforceable invariant instead of a good intention — the same class of
# drift that audits keep re-finding (a KI op or binding added to the
# code but never written into the specs) now fails the build.
#
# What is checked:
#   - each GraphicsOp/InputOp/TimerOp/RuntimeOp/StorageOp member from
#     src/kernel/api/<mod>.zig appears in the corresponding spec/<mod>.md,
#   - each Syscall and KiStatus member from src/kernel/api/sys.zig appears
#     in spec/kernel-interface.md,
#   - each Lua binding name (the luaL_Reg tables) in
#     src/kernel/lua/bindings.zig appears in spec/runtime.md §4
#     (the Lua bindings convention table).
#
# Identifier spellings differ between the specs (camelCase in the KI
# module tables, snake_case in the sub-op lists), so each enum member is
# searched in both forms.
#
# --check: report missing identifiers and exit 1 (CI + pre-push hook).
set -euo pipefail
cd "$(dirname "$0")/.."

# --check is the CI/pre-push invocation; the script always runs the check,
# the flag just makes the caller's intent explicit (sync-docs.sh convention).
[[ "${1:-}" == "--check" ]] || [[ -z "${1:-}" ]] || {
    echo "usage: $0 [--check]" >&2
    exit 2
}

fail=0

snake_to_camel() {
    # draw_rect -> drawRect
    printf '%s' "$1" | sed -E 's/_([a-z])/\U\1/g'
}

# enum_members <file> <enum-name> — the member names of a Zig u64 enum.
enum_members() {
    local file="$1" name="$2"
    sed -n "/pub const $name = enum(u64) {/,/^};/p" "$file" \
        | sed -E -n 's/^    ([a-zA-Z_][a-zA-Z0-9_]*) = .*/\1/p'
}

# documented <haystack-file> <snake-case-id> — is the identifier present,
# in either snake_case or camelCase form?
documented() {
    local file="$1" id="$2" camel
    camel="$(snake_to_camel "$id")"
    grep -qE "(^|[^A-Za-z0-9_])($id|$camel)($|[^A-Za-z0-9_])" "$file"
}

check_enum() {
    local file="$1" enum="$2" spec="$3" mod="$4"
    local member camel
    while read -r member; do
        [[ -n "$member" ]] || continue
        if ! documented "$spec" "$member"; then
            echo "check-ki-docs: $mod.$member (from $file) not found in $spec" >&2
            fail=1
        fi
    done < <(enum_members "$file" "$enum")
}

# Syscall and KiStatus members are PascalCase; kernel-interface.md uses
# the exact same spelling, so search verbatim.
check_pascal_enum() {
    local file="$1" enum="$2" spec="$3"
    local member
    while read -r member; do
        [[ -n "$member" ]] || continue
        if ! grep -qE "(^|[^A-Za-z0-9_])$member($|[^A-Za-z0-9_])" "$spec"; then
            echo "check-ki-docs: $member (from $file) not found in $spec" >&2
            fail=1
        fi
    done < <(enum_members "$file" "$enum")
}

# Sub-op enums → their subsystem spec (kernel-interface.md §2 points at
# these as the authoritative detail).
check_enum src/kernel/api/graphics.zig GraphicsOp spec/graphics.md graphics
check_enum src/kernel/api/input.zig InputOp spec/input.md input
check_enum src/kernel/api/timer.zig TimerOp spec/timer.md timer
check_enum src/kernel/api/runtime.zig RuntimeOp spec/runtime.md runtime
check_enum src/kernel/api/storage.zig StorageOp spec/storage.md storage

# syscall numbers + status codes live in kernel-interface.md itself.
check_pascal_enum src/kernel/api/sys.zig Syscall spec/kernel-interface.md
check_pascal_enum src/kernel/api/sys.zig KiStatus spec/kernel-interface.md

# Lua bindings: every name in the luaL_Reg tables must be in runtime.md §4
# (the table of what Lua can actually call). Restrict to the §4 section so a
# mention elsewhere in the file cannot satisfy the check.
runtime_section4="$(sed -n '/^## 4\. Lua bindings konvence/,/^## 5\./p' spec/runtime.md)"
while read -r name; do
    [[ -n "$name" ]] || continue
    if ! grep -qF "$name" <<<"$runtime_section4"; then
        echo "check-ki-docs: binding '$name' (from src/kernel/lua/bindings.zig) not found in spec/runtime.md §4" >&2
        fail=1
    fi
done < <(grep -oE '\.name = "[a-z0-9_]+"' src/kernel/lua/bindings.zig | sed -E 's/\.name = "([a-z0-9_]+)"/\1/')

if (( fail )); then
    echo "check-ki-docs: FAIL — document the missing identifiers in the specs above (kernel-interface.md §4/6: docs are ABI-truth)" >&2
    exit 1
fi

echo "check-ki-docs: OK (all KI operations, syscall numbers, status codes and Lua bindings are documented)"