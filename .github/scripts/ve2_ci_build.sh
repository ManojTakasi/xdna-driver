#!/bin/bash
#
# CI wrapper around build/build_ve2.sh.
#
# Runs the Yocto EDF build for the checked-out tree and stages the resulting
# RPMs plus the build log under ve2-artifacts/ so that the workflow can upload
# them (the Yocto tree itself lives outside the workspace).
#
# Environment:
#   VE2_CLEAN=true   Remove the Yocto tree before building (full re-sync).

set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
YOCTO_DIR=$(readlink -m "$REPO_ROOT/../yocto/edf")
ART_DIR="$REPO_ROOT/ve2-artifacts"
LOG="$ART_DIR/build_ve2.log"

rm -rf "$ART_DIR"
mkdir -p "$ART_DIR"

# bitbake refuses to run under a non-UTF-8 locale.
if locale -a 2>/dev/null | grep -qix 'en_US.utf8\|en_US.UTF-8'; then
    export LANG=en_US.UTF-8
    export LC_ALL=en_US.UTF-8
fi

cd "$REPO_ROOT/build"

if [[ "${VE2_CLEAN:-false}" == "true" ]]; then
    echo "VE2_CLEAN is set, removing $YOCTO_DIR"
    ./build_ve2.sh -clean
fi

# build_ve2.sh only initialises submodules on the run that creates the Yocto
# tree, so do it here for every run.
git -C "$REPO_ROOT" submodule update --init --recursive

set +e
./build_ve2.sh 2>&1 | tee "$LOG"
status=${PIPESTATUS[0]}
set -e

# build_ve2.sh reports a bitbake failure on stdout but still exits 0, so the
# log has to be checked as well as the exit status.
if [[ $status -ne 0 ]] || grep -q 'bitbake xrt failed' "$LOG"; then
    echo "::error::build_ve2.sh failed (exit ${status})"
    gzip -f "$LOG"
    exit 1
fi

shopt -s nullglob
rpms=("$YOCTO_DIR/rpms"/*.rpm)
if [[ ${#rpms[@]} -eq 0 ]]; then
    echo "::error::build_ve2.sh reported success but produced no RPMs in $YOCTO_DIR/rpms"
    gzip -f "$LOG"
    exit 1
fi

mkdir -p "$ART_DIR/rpms"
cp -a "$YOCTO_DIR/rpms/." "$ART_DIR/rpms/"
gzip -f "$LOG"

if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    {
        echo "### VE2 RPMs (${#rpms[@]})"
        echo
        echo '```'
        (cd "$ART_DIR/rpms" && ls -1sh -- *.rpm)
        echo '```'
    } >> "$GITHUB_STEP_SUMMARY"
fi

echo "Staged ${#rpms[@]} RPMs in $ART_DIR/rpms"
