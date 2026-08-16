#!/usr/bin/env bash
# Run the Lua shell regression tests (tests/lua/) on the host with a plain
# Lua interpreter: the kernel binding globals are stubbed (tests/lua/stubs.lua)
# and the real shell modules are concatenated after them, exactly like the
# kernel does (src/kernel/lua/lua.zig keeps the same order).
#
# Usage: tools/lua-shell-test.sh
set -euo pipefail

cd "$(dirname "$0")/.."

LUA="${LUA:-lua}"
if ! command -v "$LUA" >/dev/null 2>&1; then
    echo "lua-shell-test: '$LUA' not found (install a Lua 5.4 interpreter)" >&2
    exit 1
fi

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

cat tests/lua/stubs.lua > "$tmpdir/shell.lua"
for f in theme wm repl editor files launcher input main; do
    cat "src/kernel/lua/ui/$f.lua" >> "$tmpdir/shell.lua"
done
cat tests/lua/run.lua >> "$tmpdir/shell.lua"

"$LUA" "$tmpdir/shell.lua"
