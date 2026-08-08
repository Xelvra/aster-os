#!/usr/bin/env bash
set -e

# Regenerate CHANGELOG.md from the full git history.
#
# The aggregated, per-milestone changelog (what the system can do) is written
# by hand and committed. This script is a DEV TOOL: it dumps the raw commit
# log (oldest first, verbatim) so you always have the full history at hand.
#
# Usage:
#   tools/generate-changelog.sh           write the raw commit log to CHANGELOG.md
#   tools/generate-changelog.sh --log     print the raw commit log to stdout
#   tools/generate-changelog.sh --help    show this help

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    sed -n '4,14p' "$0" | sed 's/^# //'
    exit 0
fi

if [[ "${1:-}" == "--log" ]]; then
    git log --reverse --format="### %s%n%n%b%n"
    exit 0
fi

# Write the header (overwrites CHANGELOG.md)
cat << 'EOF' > CHANGELOG.md
# Changelog

All notable changes to this project will be documented in this file.

EOF

# Append the raw commits to the end of the file
git log --reverse --format="### %s%n%n%b%n" >> CHANGELOG.md

# Print confirmation with the commit count
COUNT=$(git rev-list --count HEAD)
echo "wrote raw commit log to CHANGELOG.md: $COUNT commits"
