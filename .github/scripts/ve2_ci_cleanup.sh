#!/bin/bash
#
# Reclaim disk after a VE2 build.
#
# The Yocto output tree (build/tmp, ~13G) is removed after every run, whether
# the build passed or failed. downloads/ and sstate-cache/ are kept by default
# so the next run does not refetch ~9G and can restore from sstate; both are
# shared by every PR, so they do not grow per pull request.
#
# When the build failed the log is copied out of the workspace first, since the
# next run wipes ve2-artifacts/.
#
# Environment:
#   VE2_JOB_STATUS   Outcome of the build step ("success" when it passed).
#   VE2_MIN_FREE_GB  Drop the shared caches too if free space is below this
#                    after removing tmp/ (default 40).
#   VE2_KEEP_LOGS    How many failed-build logs to retain (default 20).

set -uo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
YOCTO_DIR=$(readlink -m "$REPO_ROOT/../yocto/edf")
LOG_KEEP_DIR=$(readlink -m "$REPO_ROOT/../ve2-failed-logs")
STATUS=${VE2_JOB_STATUS:-unknown}
MIN_FREE_GB=${VE2_MIN_FREE_GB:-40}
KEEP_LOGS=${VE2_KEEP_LOGS:-20}

free_gb() {
    df -BG --output=avail "$1" 2>/dev/null | tail -1 | tr -dc '0-9'
}

reclaimed_from=$(free_gb "$REPO_ROOT")

if [[ "$STATUS" != "success" ]]; then
    log="$REPO_ROOT/ve2-artifacts/build_ve2.log.gz"
    if [[ -f "$log" ]]; then
        mkdir -p "$LOG_KEEP_DIR"
        stamp="pr${VE2_PR_NUMBER:-0}-run${GITHUB_RUN_ID:-local}-$(date +%Y%m%d-%H%M%S).log.gz"
        cp "$log" "$LOG_KEEP_DIR/$stamp"
        echo "Kept failed build log at $LOG_KEEP_DIR/$stamp"

        # Retain only the most recent KEEP_LOGS files.
        mapfile -t old < <(ls -1t "$LOG_KEEP_DIR" 2>/dev/null | tail -n +$((KEEP_LOGS + 1)))
        for f in "${old[@]:-}"; do
            [[ -n "$f" ]] && rm -f "$LOG_KEEP_DIR/$f"
        done
    else
        echo "No build log to keep at $log"
    fi
fi

if [[ -d "$YOCTO_DIR/build/tmp" ]]; then
    echo "Removing $YOCTO_DIR/build/tmp"
    rm -rf "$YOCTO_DIR/build/tmp"
fi

# Only give up the shared caches if the host is genuinely tight on space, since
# losing them costs a full refetch and a from-scratch rebuild.
avail=$(free_gb "$REPO_ROOT")
if [[ -n "$avail" && "$avail" -lt "$MIN_FREE_GB" ]]; then
    echo "Only ${avail}G free (below ${MIN_FREE_GB}G), dropping sstate-cache"
    rm -rf "$YOCTO_DIR/build/sstate-cache"
    avail=$(free_gb "$REPO_ROOT")
    if [[ -n "$avail" && "$avail" -lt "$MIN_FREE_GB" ]]; then
        echo "Still only ${avail}G free, dropping downloads"
        rm -rf "$YOCTO_DIR/build/downloads"
    fi
fi

avail=$(free_gb "$REPO_ROOT")
echo "Free space: ${reclaimed_from}G -> ${avail}G"

if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    {
        echo "### Cleanup"
        echo
        echo "- Build status: \`${STATUS}\`"
        echo "- Removed \`build/tmp\`; free space ${reclaimed_from}G -> ${avail}G"
        if [[ "$STATUS" != "success" ]]; then
            echo "- Failed build log retained on the runner in \`ve2-failed-logs/\`"
        fi
    } >> "$GITHUB_STEP_SUMMARY"
fi
