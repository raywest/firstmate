#!/usr/bin/env bash
# fm-afk-launch.sh - the historical CLI entry point for the away-mode daemon
# TERMINAL lifecycle (launch / stop / reconcile a non-visible tracked terminal
# per backend). bin/fm-daemon-launch.sh is now the single owner of that
# lifecycle - see its header for the full contract, usage, supported backends,
# and test seams - and this script only sources it and reuses its functions and
# CLI dispatch unchanged, so every existing afk entry path, record file, and
# rollback behavior stays byte-equivalent (data/fm-alwayson-triage-s5/report.md
# phase 0). Kept as a separate file/name because /afk, the afk skill, and their
# tests call it by this path.
set -u

FM_AFK_LAUNCH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-daemon-launch.sh
. "$FM_AFK_LAUNCH_DIR/fm-daemon-launch.sh"

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  fm_afk_launch_main "$@"
fi
