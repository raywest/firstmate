#!/usr/bin/env bash
# fm-afk-launch.sh - the historical compatibility CLI entry point for daemon
# terminal lifecycle operations. bin/fm-daemon-launch.sh is the single owner of
# launch, stop, terminal reconciliation, and the separate afk delivery-style
# toggles; see its header for the full contract, usage, supported backends, and
# test seams. This shim remains because legacy afk paths and their tests call it
# by this name.
set -u

FM_AFK_LAUNCH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-daemon-launch.sh
. "$FM_AFK_LAUNCH_DIR/fm-daemon-launch.sh"

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  fm_afk_launch_main "$@"
fi
