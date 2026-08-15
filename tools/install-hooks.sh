#!/usr/bin/env bash
# Install the project git hooks (hooks/* -> .git/hooks/).
# The pre-push hook refuses to push when the documented boot log is stale.
set -euo pipefail

cd "$(dirname "$0")/.."

if ! git rev-parse --git-dir >/dev/null 2>&1; then
    echo "error: not inside a git repository" >&2
    exit 1
fi

mkdir -p .git/hooks
drift=0
for hook in hooks/*; do
    name="$(basename "$hook")"
    if [[ -f ".git/hooks/$name" ]] && ! cmp -s "$hook" ".git/hooks/$name"; then
        echo "warning: .git/hooks/$name is stale vs hooks/$name, reinstalling"
        drift=1
    fi
    cp "$hook" ".git/hooks/$name"
    chmod +x ".git/hooks/$name"
    echo "installed: .git/hooks/$name"
done
if [[ "$drift" -eq 1 ]]; then
    echo "note: a previously installed hook was out of date; reinstall fixes it (audit 2026-08-15)"
fi
