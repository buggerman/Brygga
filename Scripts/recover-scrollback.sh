#!/usr/bin/env bash
# SPDX-License-Identifier: BSD-3-Clause
# Copyright (c) 2026 Brygga contributors
#
# recover-scrollback.sh — diagnostic for the test-pollution incident fixed in
# the ServerStore-injection PR. Walks ~/Library/Application Support/Brygga and
# ~/Library/Logs/Brygga and prints a report of orphan scrollback directories
# (UUIDs that no longer appear in servers.json) so the user can rebind one to
# a freshly-added Server entry.
#
# Read-only. Never moves or deletes anything. Prints exact `mv` commands the
# user can copy and run manually after re-adding their server in Brygga.
#
# Usage:
#     ./Scripts/recover-scrollback.sh

set -euo pipefail

SUPPORT="${HOME}/Library/Application Support/Brygga"
LOGS="${HOME}/Library/Logs/Brygga"
SERVERS_JSON="${SUPPORT}/servers.json"
SCROLLBACK_DIR="${SUPPORT}/scrollback"

bold()  { printf '\033[1m%s\033[0m\n' "$*"; }
muted() { printf '\033[2m%s\033[0m\n' "$*"; }
warn()  { printf '\033[33m%s\033[0m\n' "$*" >&2; }

if [[ ! -d "${SUPPORT}" ]]; then
    warn "No Brygga data directory at: ${SUPPORT}"
    warn "Nothing to recover. Has Brygga ever been launched on this machine?"
    exit 0
fi

# 1. Active servers — UUIDs that AppState still knows about.
active_uuids=()
if [[ -f "${SERVERS_JSON}" ]]; then
    bold "Active servers (in servers.json):"
    # Use python3 (ships with macOS) so we don't depend on jq.
    python3 - "${SERVERS_JSON}" <<'PY'
import json, sys
with open(sys.argv[1]) as f:
    snap = json.load(f)
for s in snap.get("servers", []):
    print(f"  {s.get('id', '<no id>'):38}  {s.get('name', '?'):20}  ({s.get('host', '?')})")
PY
    while IFS= read -r line; do
        active_uuids+=("${line}")
    done < <(python3 -c '
import json, sys
with open(sys.argv[1]) as f:
    print("\n".join(s.get("id", "") for s in json.load(f).get("servers", []) if s.get("id")))
' "${SERVERS_JSON}")
else
    warn "  (no servers.json on disk)"
fi
echo

# 2. Networks with plain-text logs — these are the user's *real* server names,
#    intact because DiskLogger keys by network name not UUID.
if [[ -d "${LOGS}" ]]; then
    bold "Networks with plain-text logs (~/Library/Logs/Brygga/):"
    find "${LOGS}" -maxdepth 1 -mindepth 1 -type d -print0 2>/dev/null \
        | xargs -0 -I{} basename {} \
        | sort \
        | while IFS= read -r net; do
            channel_count=$(find "${LOGS}/${net}" -maxdepth 1 -name '*.log' 2>/dev/null | wc -l | tr -d ' ')
            echo "  ${net}  (${channel_count} channels)"
          done
else
    muted "  (no plain-text logs at ${LOGS})"
fi
echo

# 3. Orphan scrollback dirs — UUIDs in scrollback/ that aren't in servers.json.
if [[ ! -d "${SCROLLBACK_DIR}" ]]; then
    bold "No scrollback directory — nothing to recover."
    exit 0
fi

# Walk every subdir, gather (mtime_epoch, uuid, file_count, channel_preview).
# Skip empty dirs (no .log files = nothing to recover) and classify dirs whose
# channels look like test-fixture noise so they don't drown out real data.
active_set=$(printf '%s\n' "${active_uuids[@]}" 2>/dev/null | sort -u)
real_orphans=()
test_orphan_count=0

while IFS= read -r line; do
    if [[ "${line}" == TEST$'\t'* ]]; then
        # Plain assignment instead of `((var++))` — the latter returns the
        # pre-increment value, which is 0 on the first hit and trips
        # `set -e`. Bash gotcha.
        test_orphan_count=$((test_orphan_count + 1))
    else
        real_orphans+=("${line}")
    fi
done < <(
    for dir in "${SCROLLBACK_DIR}"/*/; do
        [[ -d "${dir}" ]] || continue
        uuid=$(basename "${dir}")
        # Skip non-UUID directories (defensive — if some other tool wrote into scrollback/).
        [[ "${uuid}" =~ ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$ ]] || continue
        # Skip if this UUID is still referenced by servers.json.
        if grep -qx -F "${uuid}" <<<"${active_set}" 2>/dev/null; then
            continue
        fi
        file_count=$(find "${dir}" -maxdepth 1 -name '*.log' 2>/dev/null | wc -l | tr -d ' ')
        # Skip dirs with no .log files — empty shells from restore that never
        # received any append. Nothing to recover from them.
        [[ "${file_count}" -gt 0 ]] || continue
        # Most recent .log mtime in the dir. `-print0` + null-delimited read so
        # paths with spaces (the "Application Support" segment) don't get
        # word-split.
        latest_epoch=$(find "${dir}" -maxdepth 1 -name '*.log' -print0 2>/dev/null \
            | xargs -0 stat -f '%m' 2>/dev/null \
            | sort -n \
            | tail -1)
        latest_epoch="${latest_epoch:-0}"
        latest_iso=$(date -r "${latest_epoch}" '+%Y-%m-%d %H:%M' 2>/dev/null || echo "—")
        channels_full=$(find "${dir}" -maxdepth 1 -name '*.log' -print0 2>/dev/null \
            | xargs -0 -n1 basename \
            | sed 's/\.log$//' \
            | sort \
            | tr '\n' ',' \
            | sed 's/,$//')
        channels_preview=$(tr ',' '\n' <<<"${channels_full}" \
            | head -10 \
            | tr '\n' ' ' \
            | sed 's/ *$//')
        # Heuristic: if every channel filename matches a test-fixture name
        # (`_test`, `alice`, `__server__`), tag this orphan as test pollution
        # so it gets summarized rather than listed individually.
        if [[ "${channels_full}" =~ ^(_test|alice|__server__)(,(_test|alice|__server__))*$ ]]; then
            printf 'TEST\t%s\n' "${uuid}"
        else
            printf '%010d\t%s\t%-19s\t%-7s\t%s\n' "${latest_epoch}" "${uuid}" "${latest_iso}" "${file_count}" "${channels_preview}"
        fi
    done
)

bold "Orphan scrollback with real chat data (most-recent first):"
echo
if [[ "${#real_orphans[@]}" -eq 0 ]]; then
    muted "  None found. If you expected scrollback here, check that you re-added"
    muted "  the server with the same nickname so DiskLogger's plain-text logs"
    muted "  under ~/Library/Logs/Brygga/ still match."
else
    printf "  %-38s  %-19s  %-7s  %s\n" "UUID" "MOST RECENT" "FILES" "FIRST 10 CHANNELS"
    printf "  %-38s  %-19s  %-7s  %s\n" "----" "-----------" "-----" "-----------------"
    printf '%s\n' "${real_orphans[@]}" | sort -r -k1,1 | while IFS=$'\t' read -r _ uuid iso files channels; do
        printf "  %-38s  %-19s  %-7s  %s\n" "${uuid}" "${iso}" "${files}" "${channels}"
    done
fi
echo
if [[ "${test_orphan_count}" -gt 0 ]]; then
    muted "(${test_orphan_count} additional orphan dirs hold only test-fixture noise — \`_test\`, \`alice\`, \`__server__\` — and are hidden. They're safe to delete: \`find \"${SCROLLBACK_DIR}\" -maxdepth 1 -type d\` to inspect, or leave them alone.)"
fi
echo

echo
bold "How to recover one of these:"
echo "  1. Open Brygga, add a fresh Server entry (Server → New Server…) for the network you want."
echo "  2. Quit Brygga so AppState writes the new UUID to servers.json."
echo "  3. Look up the new UUID:"
echo "     python3 -c \"import json; print('\\n'.join(s['id']+'  '+s['name'] for s in json.load(open('${SERVERS_JSON}'))['servers']))\""
echo "  4. Pick the orphan UUID above whose channel list looks right, then:"
echo "     mv \"${SCROLLBACK_DIR}/<orphan-UUID>\" \"${SCROLLBACK_DIR}/<new-UUID>\""
echo "  5. Relaunch Brygga — channel scrollback shows up on next channel JOIN."
echo
muted "This script never deletes or moves anything; only prints commands."
