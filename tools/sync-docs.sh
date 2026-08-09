#!/usr/bin/env bash
# Aster OS docs sync tooling.
#
# The public website (docs/, English) is a curated layer over the internal
# spec (spec/, Czech). Each docs/*.md page carries YAML front matter:
#
#   source: spec/roadmap.md            # one or more (comma-separated) repo
#   synced: 2026-08-09                 # last date the page was synced
#
# --check: fail if any page has drifted from its sources for more than
# SYNC_DAYS (default 14). A page drifts when the newest change of any of its
# sources is older than the synced date by more than the window — i.e. the
# English page must be re-synced within 14 days of the Czech source changing.
#
# Run from anywhere; repo root is resolved from the script location.
set -euo pipefail
cd "$(dirname "$0")/.."

SYNC_DAYS="${SYNC_DAYS:-14}"
fail=0

for page in docs/*.md; do
    src="$(sed -n 's/^source: //p' "$page" | head -1)"
    synced="$(sed -n 's/^synced: //p' "$page" | head -1)"

    if [[ -z "$src" ]]; then
        echo "sync-docs: $page is missing 'source:' front matter" >&2
        fail=1
        continue
    fi
    if [[ -z "$synced" ]]; then
        echo "sync-docs: $page is missing 'synced:' front matter" >&2
        fail=1
        continue
    fi

    # Newest change among all listed sources (git log --format=%ct = unix ts).
    newest=0
    IFS=',' read -ra srcs <<< "$src"
    for s in "${srcs[@]}"; do
        s="${s#"${s%%[![:space:]]*}"}" # trim leading whitespace
        if [[ ! -f "$s" ]]; then
            echo "sync-docs: $page source '$s' does not exist" >&2
            fail=1
            continue
        fi
        ts="$(git log -1 --format=%ct -- "$s" 2>/dev/null || echo 0)"
        (( ts > newest )) && newest="$ts"
    done

    synced_ts="$(date -d "$synced" +%s 2>/dev/null || echo 0)"
    if (( newest > 0 && synced_ts > 0 )); then
        age_days=$(( (newest - synced_ts) / 86400 ))
        if (( age_days > SYNC_DAYS )); then
            echo "sync-docs: $page synced $synced but source(s) '$src' changed $age_days days ago (limit ${SYNC_DAYS}d)" >&2
            fail=1
        fi
    fi
done

if (( fail )); then
    echo "sync-docs: FAIL — re-sync the docs pages above with their spec sources and bump 'synced:'" >&2
    exit 1
fi

echo "sync-docs: OK (all pages within ${SYNC_DAYS}d of their sources)"
