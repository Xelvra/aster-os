#!/usr/bin/env bash
# Aster OS docs sync check.
#
# The public website (docs/, English) is a translation layer over the
# internal spec (spec/, Czech). Each docs/*.md page carries YAML front
# matter listing the Czech source(s) it translates:
#
#   ---
#   source: spec/roadmap.md, CHANGELOG.md
#   ---
#
# Exception: a page without `source:` (docs/index.md, the intro page
# explaining the two-layer strategy) is exempt from the sync check — it is
# not a translation of a Czech source.
#
# The check is GIT-BASED, not date-tag-based: a page is in sync when its
# English translation was committed at or after the last commit that touched
# its Czech source. Editing a `synced:` date cannot fool it — git history is
# the only authority.
#
# The page footer shows "Last synced from <source> on <synced>" to the reader.
# The `synced:` front-matter date is also checked: it must not be older than
# the last change of the source (same SYNC_DAYS window), so a stale page is
# visible to a human even before the push-blocking check trips.
#
# --check: report drift and fail hard once a page has been out of sync for
# more than SYNC_DAYS (default 14). Within the window it warns; past the
# window it exits 1, blocking the push (pre-push hook + CI).
#
# Requires full history for `git log -- <file>`; CI checks out with
# fetch-depth: 0.
set -euo pipefail
cd "$(dirname "$0")/.."

SYNC_DAYS="${SYNC_DAYS:-14}"
fail=0
warned=0

for page in docs/*.md; do
    src="$(sed -n 's/^source: //p' "$page" | head -1)"
    if [[ -z "$src" ]]; then
        # Pages without source: are not translations of a Czech spec —
        # e.g. docs/index.md, the intro page explaining the two-layer
        # strategy. They are exempt from the sync check by design.
        continue
    fi
    synced="$(sed -n 's/^synced: //p' "$page" | head -1)"
    if [[ -z "$synced" ]]; then
        echo "sync-docs: $page is missing 'synced:' front matter (shown in the footer)" >&2
        fail=1
        continue
    fi

    page_ts="$(git log -1 --format=%ct -- "$page" 2>/dev/null || echo 0)"
    if (( page_ts == 0 )); then
        echo "sync-docs: $page is not tracked in git" >&2
        fail=1
        continue
    fi
    synced_ts="$(date -u -d "$synced" +%s 2>/dev/null || echo 0)"
    if (( synced_ts == 0 )); then
        echo "sync-docs: $page has an unparseable 'synced:' date ('$synced')" >&2
        fail=1
        continue
    fi

    IFS=',' read -ra srcs <<< "$src"
    for s in "${srcs[@]}"; do
        s="${s#"${s%%[![:space:]]*}"}" # trim leading whitespace
        if [[ ! -f "$s" ]]; then
            echo "sync-docs: $page source '$s' does not exist" >&2
            fail=1
            continue
        fi
        src_ts="$(git log -1 --format=%ct -- "$s" 2>/dev/null || echo 0)"

        # Day-granularity comparison in UTC: `synced:` is a date, git commit
        # times carry hours and local offsets, so floor both to whole UTC
        # days. `date -u` keeps it deterministic across machines/timezones.
        src_day=$(( src_ts / 86400 ))
        synced_day=$(( synced_ts / 86400 ))

        # 1) git-based check: page committed at/after the source change
        if (( src_ts > page_ts )); then
            age_days=$(( (src_ts - page_ts) / 86400 ))
            if (( age_days > SYNC_DAYS )); then
                echo "sync-docs: $page OUT OF SYNC — source '$s' changed $age_days days ago and the English page was not updated (limit ${SYNC_DAYS}d)" >&2
                fail=1
            else
                echo "sync-docs: warn — $page source '$s' changed, re-sync within ${SYNC_DAYS}d (age ${age_days}d)" >&2
                warned=1
            fi
        fi

        # 2) footer-based check: synced: date must be current vs the source
        if (( src_day > synced_day )); then
            footer_age=$(( src_day - synced_day ))
            if (( footer_age > SYNC_DAYS )); then
                echo "sync-docs: $page footer claims synced $synced but source '$s' changed $footer_age days later — update 'synced:' (limit ${SYNC_DAYS}d)" >&2
                fail=1
            else
                echo "sync-docs: warn — $page footer synced $synced, source '$s' changed $footer_age days later" >&2
                warned=1
            fi
        fi
    done
done

if (( fail )); then
    echo "sync-docs: FAIL — update the English translations above and commit them (git history is the check)" >&2
    exit 1
fi

if (( warned )); then
    echo "sync-docs: WARNINGS above — pages will block a push once out of sync past ${SYNC_DAYS} days"
    exit 0
fi

echo "sync-docs: OK (all English pages committed at/after their Czech sources)"
