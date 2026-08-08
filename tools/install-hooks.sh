#!/usr/bin/env bash
# Install the project git hooks (hooks/* -> .git/hooks/).
# The pre-push hook refuses to push when the documented boot log
# (docs/boot-log.md and the README terminal block) is stale.
set -euo pipefail

cd "$(dirname "$0")/.."

mkdir -p .git/hooks
for hook in hooks/*; do
    name="$(basename "$hook")"
    cp "$hook" ".git/hooks/$name"
    chmod +x ".git/hooks/$name"
    echo "installed: .git/hooks/$name"
done
