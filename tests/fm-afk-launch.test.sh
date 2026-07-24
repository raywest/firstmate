#!/usr/bin/env bash
# tests/fm-afk-launch.test.sh - the script-owned, backend-aware away-daemon
# launch (bin/fm-afk-launch.sh) and the away-mode stale-artifact lifecycle fixes
# (bin/fm-afk-start.sh). Two layers:
#
#   UNIT (always run, no backend): the session-scoped stale-artifact clear on a
#   fresh entry vs a refresh, and the daemon lifecycle (start/start-native/stop)
#   never touching state/.afk - that style flag is owned only by the dedicated
#   afk-enter/afk-exit subcommands (always-on triage phase 2).
#
#   E2E TOPOLOGY (per backend, skipped when its tool is absent): the anti-
#   regression for the pane split/shrink - entering AND exiting away mode leaves
#   the captain's active tab topology UNCHANGED, because the daemon lands in a
#   NON-VISIBLE separate terminal (a herdr dedicated workspace, a detached tmux
#   session), never a split of the captain's pane. The herdr path runs on a
#   throwaway, NEVER-default HERDR_SESSION and asserts the default session is
#   byte-identical via the fm-herdr-lab.sh fleet-state tripwire; the tmux path
#   uses uniquely-named throwaway sessions killed by exact name. A harmless
#   sleeper replaces the real daemon (FM_AFK_LAUNCH_ENTRY) so the test observes
#   only the terminal lifecycle.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LAUNCH="$ROOT/bin/fm-afk-launch.sh"
START="$ROOT/bin/fm-afk-start.sh"

FAILED=0
fail() { printf 'not ok - %s\n' "$1" >&2; FAILED=1; }
pass() { printf 'ok - %s\n' "$1"; }

SLEEPER=$(mktemp "${TMPDIR:-/tmp}/fm-afk-sleeper.XXXXXX")
printf '#!/usr/bin/env bash\nexec sleep 600\n' > "$SLEEPER"
chmod +x "$SLEEPER"
TRACK_TMUX_SESSIONS=""
GLOBAL_CLEANUP() {
  rm -f "$SLEEPER" 2>/dev/null || true
  local s
  for s in $TRACK_TMUX_SESSIONS; do
    tmux kill-session -t "$s" 2>/dev/null || true
  done
}
trap GLOBAL_CLEANUP EXIT

# ---------------------------------------------------------------------------
# UNIT 1: fm_afk_clear_stale_artifacts removes exactly the three stale artifacts.
# ---------------------------------------------------------------------------
unit_clear_stale() {
  local st
  st=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-clear.XXXXXX")
  mkdir -p "$st/state"
  : > "$st/state/.subsuper-escalations"
  : > "$st/state/.subsuper-escalations.since"
  : > "$st/state/.subsuper-escalations-urgent"
  : > "$st/state/.subsuper-inject-wedged"
  : > "$st/state/.wake-queue"          # durable queue must be untouched
  # Source fm-afk-start.sh inside a child bash (it sets `set -eu` and would
  # otherwise leak that into this test shell) and call the clear helper.
  FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" \
    bash -c '. "$1"; fm_afk_clear_stale_artifacts "$2"' _ "$START" "$st/state"
  if [ ! -e "$st/state/.subsuper-escalations" ] \
     && [ ! -e "$st/state/.subsuper-escalations.since" ] \
     && [ ! -e "$st/state/.subsuper-escalations-urgent" ] \
     && [ ! -e "$st/state/.subsuper-inject-wedged" ]; then
    pass "clear-stale: removes escalations buffer, sidecar, and wedge marker"
  else
    fail "clear-stale: stale artifacts survived"
  fi
  if [ -e "$st/state/.wake-queue" ]; then
    pass "clear-stale: leaves the durable wake-queue intact (no pending work dropped)"
  else
    fail "clear-stale: removed the durable wake-queue"
  fi
  rm -rf "$st"
}

# ---------------------------------------------------------------------------
# UNIT: fm_afk_launch_daemon_cmd (bin/fm-daemon-launch.sh) sources
# config/daemon.env BEFORE config/x-mode.env, both guarded no-ops when absent,
# and a daemon.env var reaches the exec'd process unless x-mode.env overrides it.
# ---------------------------------------------------------------------------
unit_daemon_cmd_sources_config_files() {
  local st cmd daemon_idx xmode_idx out printer override_config
  st=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-daemoncmd.XXXXXX")
  mkdir -p "$st/config"
  printer=$(mktemp "${TMPDIR:-/tmp}/fm-afk-printer.XXXXXX")
  printf '#!/usr/bin/env bash\nprintenv FM_PAUSE_RESURFACE_SECS\n' > "$printer"
  chmod +x "$printer"

  # (a) generated command text includes both guarded sources, daemon.env first.
  cmd=$(FM_HOME="$st" bash -c '. "$1"; fm_afk_launch_daemon_cmd tgt backend /bin/true' _ "$ROOT/bin/fm-daemon-launch.sh")
  daemon_idx=$(printf '%s' "$cmd" | grep -bo "config/daemon.env" | head -1 | cut -d: -f1)
  xmode_idx=$(printf '%s' "$cmd" | grep -bo "config/x-mode.env" | head -1 | cut -d: -f1)
  if [ -n "$daemon_idx" ] && [ -n "$xmode_idx" ] && [ "$daemon_idx" -lt "$xmode_idx" ]; then
    pass "daemon-cmd: sources config/daemon.env before config/x-mode.env"
  else
    fail "daemon-cmd: daemon.env is not sourced before x-mode.env ($cmd)"
  fi

  # (b) absent files: the built command is a silent no-op wrapper around the entry.
  out=$(FM_HOME="$st" bash -c '. "$1"; cmd=$(fm_afk_launch_daemon_cmd tgt backend true); bash -c "$cmd"' _ "$ROOT/bin/fm-daemon-launch.sh" 2>&1)
  if [ -z "$out" ]; then
    pass "daemon-cmd: absent daemon.env and x-mode.env is a silent no-op"
  else
    fail "daemon-cmd: absent config files produced unexpected output: $out"
  fi

  # (c) a daemon.env var reaches the exec'd process env.
  printf 'export FM_PAUSE_RESURFACE_SECS=14400\n' > "$st/config/daemon.env"
  out=$(FM_HOME="$st" bash -c '. "$1"; cmd=$(fm_afk_launch_daemon_cmd tgt backend "$2"); bash -c "$cmd"' _ "$ROOT/bin/fm-daemon-launch.sh" "$printer")
  if [ "$out" = "14400" ]; then
    pass "daemon-cmd: a var set in config/daemon.env reaches the daemon process env"
  else
    fail "daemon-cmd: config/daemon.env var did not reach the process env (got '$out')"
  fi

  # (d) x-mode.env still wins over daemon.env for an overlapping var.
  printf 'export FM_PAUSE_RESURFACE_SECS=999\n' > "$st/config/x-mode.env"
  out=$(FM_HOME="$st" bash -c '. "$1"; cmd=$(fm_afk_launch_daemon_cmd tgt backend "$2"); bash -c "$cmd"' _ "$ROOT/bin/fm-daemon-launch.sh" "$printer")
  if [ "$out" = "999" ]; then
    pass "daemon-cmd: config/x-mode.env still wins over config/daemon.env on overlap"
  else
    fail "daemon-cmd: x-mode.env did not win over daemon.env on overlap (got '$out')"
  fi

  override_config="$st/override-config"
  mkdir -p "$override_config"
  printf 'export FM_PAUSE_RESURFACE_SECS=14400\n' > "$override_config/daemon.env"
  out=$(FM_HOME="$st" FM_CONFIG_OVERRIDE="$override_config" bash -c '. "$1"; cmd=$(fm_afk_launch_daemon_cmd tgt backend "$2"); bash -c "$cmd"' _ "$ROOT/bin/fm-daemon-launch.sh" "$printer")
  if [ "$out" = "14400" ]; then
    pass "daemon-cmd: daemon.env uses FM_CONFIG_OVERRIDE"
  else
    fail "daemon-cmd: daemon.env ignored FM_CONFIG_OVERRIDE (got '$out')"
  fi

  printf 'export FM_PAUSE_RESURFACE_SECS=777\n' > "$override_config/x-mode.env"
  out=$(FM_HOME="$st" FM_CONFIG_OVERRIDE="$override_config" bash -c '. "$1"; cmd=$(fm_afk_launch_daemon_cmd tgt backend "$2"); bash -c "$cmd"' _ "$ROOT/bin/fm-daemon-launch.sh" "$printer")
  if [ "$out" = "777" ]; then
    pass "daemon-cmd: x-mode.env uses FM_CONFIG_OVERRIDE"
  else
    fail "daemon-cmd: x-mode.env ignored FM_CONFIG_OVERRIDE (got '$out')"
  fi

  rm -rf "$st"
  rm -f "$printer"
}

# ---------------------------------------------------------------------------
# UNIT 2: a FRESH entry clears; a REFRESH (daemon already alive) preserves the
# current session's buffered escalations.
# ---------------------------------------------------------------------------
unit_fresh_vs_refresh() {
  local st sleep_pid lock
  st=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-refresh.XXXXXX")
  mkdir -p "$st/state"
  : > "$st/state/.subsuper-escalations"
  : > "$st/state/.subsuper-escalations-urgent"
  : > "$st/state/.subsuper-inject-wedged"
  # A live "daemon": a real process whose identity the lock records, so
  # daemon_lock_held_by_live_daemon returns true (a refresh).
  sleep 600 &
  sleep_pid=$!
  lock="$st/state/.supervise-daemon.lock"
  mkdir -p "$lock"
  printf '%s' "$sleep_pid" > "$lock/pid"
  ( . "$ROOT/bin/fm-wake-lib.sh"; fm_pid_identity "$sleep_pid" > "$lock/pid-identity" 2>/dev/null ) || true
  FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" "$START" >/dev/null 2>&1
  if [ -e "$st/state/.subsuper-escalations" ] && [ -e "$st/state/.subsuper-escalations-urgent" ] && [ -e "$st/state/.subsuper-inject-wedged" ]; then
    pass "refresh: daemon already alive - stale artifacts preserved (current session's buffer kept)"
  else
    fail "refresh: incorrectly cleared the current session's buffered escalations"
  fi
  kill "$sleep_pid" 2>/dev/null || true
  wait "$sleep_pid" 2>/dev/null || true
  rm -rf "$st"
}

# ---------------------------------------------------------------------------
# UNIT 3: fm_afk_launch_stop never touches state/.afk. Always-on triage phase
# 2 decouples the daemon's process lifecycle from the away/present delivery
# STYLE flag: only fm-daemon-launch.sh afk-enter/afk-exit own that flag, so a
# stop for a self-update restart or pane retarget preserves whichever style
# was active - the daemon is never stopped just because the captain returned.
# ---------------------------------------------------------------------------
unit_stop_never_touches_afk() {
  local st lock daemon_pid
  st=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-stop.XXXXXX")
  mkdir -p "$st/state"
  date '+%s' > "$st/state/.afk"
  bash -c 'trap "exit 0" TERM; while :; do sleep 0.2; done' &
  daemon_pid=$!
  lock="$st/state/.supervise-daemon.lock"
  mkdir -p "$lock"
  printf '%s' "$daemon_pid" > "$lock/pid"
  ( . "$ROOT/bin/fm-wake-lib.sh"; fm_pid_identity "$daemon_pid" > "$lock/pid-identity" 2>/dev/null ) || true
  printf 'none\t-\tnative\n' > "$st/state/.afk-daemon-terminal"
  FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" "$LAUNCH" stop >/dev/null 2>&1
  if [ -e "$st/state/.afk" ]; then
    pass "stop: never touches state/.afk (style flag is independent lifecycle state)"
  else
    fail "stop: removed state/.afk even though it no longer owns the style flag"
  fi
  if [ ! -e "$st/state/.afk-daemon-terminal" ]; then
    pass "stop: daemon-terminal record removed"
  else
    fail "stop: record not removed"
  fi
  kill "$daemon_pid" 2>/dev/null || true
  wait "$daemon_pid" 2>/dev/null || true
  rm -rf "$st"
}

unit_stop_rejects_reused_pid() {
  local st lock sleeper_pid
  st=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-pid-reuse.XXXXXX")
  mkdir -p "$st/state"
  date '+%s' > "$st/state/.afk"
  sleep 600 &
  sleeper_pid=$!
  lock="$st/state/.supervise-daemon.lock"
  mkdir -p "$lock"
  printf '%s' "$sleeper_pid" > "$lock/pid"
  printf 'different-process-identity' > "$lock/pid-identity"
  FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" "$LAUNCH" stop >/dev/null 2>&1
  if kill -0 "$sleeper_pid" 2>/dev/null; then
    pass "stop identity: stale lock cannot signal an unrelated live process"
  else
    fail "stop identity: stale lock signaled an unrelated live process"
  fi
  kill "$sleeper_pid" 2>/dev/null || true
  wait "$sleeper_pid" 2>/dev/null || true
  rm -rf "$st"
}

unit_failed_start_rolls_back_state() {
  local st
  st=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-failed-start.XXXXXX")
  mkdir -p "$st/state"
  printf 'pending\n' > "$st/state/.subsuper-escalations"
  printf 'wedged\n' > "$st/state/.subsuper-inject-wedged"
  if FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" FM_SUPERVISOR_TARGET=unused \
    FM_SUPERVISOR_BACKEND=unsupported "$LAUNCH" start >/dev/null 2>&1; then
    fail "failed start: unsupported backend unexpectedly succeeded"
  elif [ ! -e "$st/state/.afk" ] \
    && [ "$(cat "$st/state/.subsuper-escalations")" = pending ] \
    && [ "$(cat "$st/state/.subsuper-inject-wedged")" = wedged ]; then
    pass "failed start: away flag and delivery artifacts roll back"
  else
    fail "failed start: left false away state or discarded delivery artifacts"
  fi
  rm -rf "$st"
}

unit_concurrent_start_serialized() {
  command -v tmux >/dev/null 2>&1 || { echo "skip: tmux not found (concurrent start)"; return 0; }
  local st cap_session cap_pane first second rec count
  st=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-concurrent.XXXXXX")
  cap_session="fm-afk-concurrent-cap-$$"
  tmux new-session -d -s "$cap_session" 2>/dev/null || { fail "concurrent start: captain session creation failed"; rm -rf "$st"; return 0; }
  TRACK_TMUX_SESSIONS="$TRACK_TMUX_SESSIONS $cap_session"
  cap_pane=$(tmux display-message -p -t "$cap_session" '#{pane_id}')
  FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" FM_SUPERVISOR_TARGET="$cap_pane" \
    FM_SUPERVISOR_BACKEND=tmux FM_AFK_LAUNCH_ENTRY="$SLEEPER" "$LAUNCH" start >/dev/null 2>&1 & first=$!
  FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" FM_SUPERVISOR_TARGET="$cap_pane" \
    FM_SUPERVISOR_BACKEND=tmux FM_AFK_LAUNCH_ENTRY="$SLEEPER" "$LAUNCH" start >/dev/null 2>&1 & second=$!
  wait "$first"; wait "$second"
  rec=$(cut -f2 "$st/state/.afk-daemon-terminal" 2>/dev/null || true)
  count=$(tmux list-sessions -F '#{session_name}' 2>/dev/null | awk -v expected="$rec" '$0 == expected {n++} END{print n+0}')
  TRACK_TMUX_SESSIONS="$TRACK_TMUX_SESSIONS $rec"
  if [ -n "$rec" ] && tmux has-session -t "$rec" 2>/dev/null && [ "$count" -eq 1 ]; then
    pass "concurrent start: one serialized daemon terminal remains tracked"
  else
    fail "concurrent start: leaked or lost daemon terminal (count $count, record $rec)"
  fi
  FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" "$LAUNCH" stop >/dev/null 2>&1
  tmux kill-session -t "$cap_session" 2>/dev/null || true
  rm -rf "$st"
}

unit_lock_initialization_grace() {
  local st marker initializer
  st=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-lock-init.XXXXXX")
  marker="$st/initialized"
  mkdir -p "$st/state/.afk-launch.lock"
  (
    sleep 0.15
    if [ -d "$st/state/.afk-launch.lock" ]; then
      printf '%s' "$$" > "$st/state/.afk-launch.lock/pid"
      ( . "$ROOT/bin/fm-wake-lib.sh"; fm_pid_identity "$$" > "$st/state/.afk-launch.lock/pid-identity" 2>/dev/null ) || true
      : > "$marker"
      sleep 0.15
      rm -rf "$st/state/.afk-launch.lock"
    fi
  ) &
  initializer=$!
  if FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" bash -c '
    . "$1"
    fm_afk_launch_lock_acquire
    fm_afk_launch_lock_release
  ' _ "$LAUNCH" && [ -e "$marker" ]; then
    pass "launcher lock: incomplete publication receives initialization grace"
  else
    fail "launcher lock: contender removed a lock during initialization"
  fi
  wait "$initializer" 2>/dev/null || true
  rm -rf "$st"
}

unit_signal_exits_with_lock_cleanup() {
  local st marker child
  st=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-signal.XXXXXX")
  marker="$st/resumed"
  FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" bash -c '
    . "$1"
    fm_afk_launch_start() { sleep 30; }
    fm_afk_launch_main start
    : > "$2"
  ' _ "$LAUNCH" "$marker" &
  child=$!
  for _ in $(seq 1 40); do
    [ -d "$st/state/.afk-launch.lock" ] && break
    sleep 0.05
  done
  kill -TERM "$child" 2>/dev/null || true
  wait "$child" 2>/dev/null || true
  if [ ! -e "$marker" ] && [ ! -e "$st/state/.afk-launch.lock" ]; then
    pass "launcher signal: TERM exits and releases the lifecycle lock"
  else
    fail "launcher signal: interrupted lifecycle resumed or retained its lock"
  fi
  rm -rf "$st"
}

unit_herdr_partial_create_recovery() {
  local st recorded
  st=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-herdr-partial.XXXXXX")
  recorded="$st/recorded"
  FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" FM_AFK_LAUNCH_ENTRY=/bin/true \
    FM_AFK_LAUNCH_LABEL=afk-exact-label RECORDED="$recorded" bash -c '
    . "$1"
    fm_backend_source() { return 0; }
    fm_backend_herdr_server_ensure() { return 0; }
    fm_backend_herdr_cli() {
      if [ "$2 $3" = "workspace create" ]; then
        printf %s '\''truncated'\''
        return 1
      elif [ "$2 $3" = "workspace list" ]; then
        printf %s '\''{"result":{"workspaces":[{"workspace_id":"ws-partial","label":"afk-exact-label"}]}}'\''
      else
        printf %s '\''{"result":{"panes":[{"pane_id":"pane-exact"}]}}'\''
      fi
    }
    fm_afk_launch_record_write() { printf "%s:%s:%s" "$1" "$2" "$3" > "$RECORDED"; }
    fm_afk_launch_create_herdr lab:captain herdr
  ' _ "$LAUNCH"
  if [ "$(cat "$recorded" 2>/dev/null || true)" = "herdr:lab:pane-exact:ws-partial" ]; then
    pass "herdr create: malformed response recovers durable exact ownership"
  else
    fail "herdr create: malformed response left terminal ownership unknown"
  fi
  rm -rf "$st"
}

unit_herdr_error_with_exact_ids_closes_exact() {
  local st
  st=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-herdr-error-exact.XXXXXX")
  FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" bash -c '
    . "$1"
    fm_backend_source() { return 0; }
    fm_backend_herdr_server_ensure() { return 0; }
    fm_backend_herdr_cli() {
      if [ "$2 $3" = "workspace create" ]; then
        printf %s '\''{"result":{"workspace":{"workspace_id":"ws-exact"},"root_pane":{"pane_id":"pane-exact"}}}'\''
        return 1
      elif [ "$2 $3" = "pane get" ]; then
        printf %s '\''{"error":{"code":"transport_error"}}'\''
        return 2
      fi
      return 2
    }
    ! fm_afk_launch_create_herdr lab:captain herdr
  ' _ "$LAUNCH"
  if [ "$(cut -f2 "$st/state/.afk-daemon-terminal" 2>/dev/null || true)" = "lab:pane-exact" ]; then
    pass "herdr create error: unconfirmed exact id is persisted for reconciliation"
  else
    fail "herdr create error: unconfirmed exact cleanup id was discarded"
  fi
  rm -rf "$st"
}

unit_herdr_run_failure_preserves_unconfirmed_record() {
  local st
  st=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-herdr-run-fail.XXXXXX")
  FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" bash -c '
    . "$1"
    fm_backend_source() { return 0; }
    fm_backend_herdr_server_ensure() { return 0; }
    fm_backend_herdr_cli() {
      if [ "$2 $3" = "workspace create" ]; then
        printf %s '\''{"result":{"workspace":{"workspace_id":"ws-exact"},"root_pane":{"pane_id":"pane-exact"}}}'\''
        return 0
      elif [ "$2 $3" = "pane run" ]; then
        return 1
      elif [ "$2 $3" = "pane get" ]; then
        printf %s '\''{"error":{"code":"transport_error"}}'\''
        return 2
      fi
      return 2
    }
    ! fm_afk_launch_create_herdr lab:captain herdr
  ' _ "$LAUNCH"
  if [ "$(cut -f2 "$st/state/.afk-daemon-terminal" 2>/dev/null || true)" = "lab:pane-exact" ]; then
    pass "herdr run failure: unconfirmed exact id remains reconcilable"
  else
    fail "herdr run failure: unconfirmed exact id was discarded"
  fi
  rm -rf "$st"
}

unit_record_failure_closes_terminal() {
  local st closed
  st=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-record-fail.XXXXXX")
  closed="$st/closed"
  FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" CLOSED="$closed" bash -c '
    . "$1"
    fm_afk_launch_record_write() { return 1; }
    fm_afk_launch_close_terminal() { printf "%s:%s" "$1" "$2" > "$CLOSED"; }
    ! fm_afk_launch_commit_terminal tmux exact-session ""
  ' _ "$LAUNCH"
  if [ "$(cat "$closed" 2>/dev/null || true)" = "tmux:exact-session" ]; then
    pass "record failure: newly created terminal is closed by exact id"
  else
    fail "record failure: newly created terminal leaked"
  fi
  rm -rf "$st"
}

unit_readiness_failure_rolls_back_terminal() {
  local st closed
  st=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-not-ready.XXXXXX")
  closed="$st/closed"
  FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" CLOSED="$closed" bash -c '
    . "$1"
    fm_afk_launch_wait_ready() { return 1; }
    fm_afk_launch_close_terminal() { printf "%s:%s" "$1" "$2" > "$CLOSED"; }
    fm_afk_launch_terminal_absent() { [ -e "$CLOSED" ]; }
    ! fm_afk_launch_commit_terminal tmux exact-session ""
  ' _ "$LAUNCH"
  if [ "$(cat "$closed" 2>/dev/null || true)" = "tmux:exact-session" ] \
    && [ ! -e "$st/state/.afk-daemon-terminal" ]; then
    pass "readiness failure: exact terminal and durable record roll back"
  else
    fail "readiness failure: terminal or record survived"
  fi
  rm -rf "$st"
}

unit_readiness_failure_preserves_unconfirmed_record() {
  local st
  st=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-not-ready-unconfirmed.XXXXXX")
  FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" bash -c '
    . "$1"
    fm_afk_launch_wait_ready() { return 1; }
    fm_afk_launch_close_terminal() { return 1; }
    fm_afk_launch_terminal_absent() { return 1; }
    ! fm_afk_launch_commit_terminal tmux exact-session ""
  ' _ "$LAUNCH"
  if [ "$(cut -f2 "$st/state/.afk-daemon-terminal" 2>/dev/null || true)" = exact-session ]; then
    pass "readiness failure: unconfirmed terminal retains its reconciliation id"
  else
    fail "readiness failure: unconfirmed terminal lost its reconciliation id"
  fi
  rm -rf "$st"
}

unit_tmux_absence_distinguishes_probe_failure() {
  local st
  st=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-tmux-probe.XXXXXX")
  if FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" bash -c '
    . "$1"
    tmux() { printf "%s" "can'\''t find session: exact-session" >&2; return 1; }
    fm_afk_launch_terminal_absent tmux exact-session
    tmux() { printf "%s" "error connecting to /tmp/tmux.sock" >&2; return 1; }
    ! fm_afk_launch_terminal_absent tmux exact-session
  ' _ "$LAUNCH"; then
    pass "tmux absence: clean missing differs from transport probe failure"
  else
    fail "tmux absence: probe failure was treated as confirmed absence"
  fi
  rm -rf "$st"
}

unit_native_lifecycle() {
  local st
  st=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-native.XXXXXX")
  mkdir -p "$st/state"
  : > "$st/state/.subsuper-escalations"
  if FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" "$LAUNCH" start-native >/dev/null 2>&1 \
    && [ "$(cut -f1 "$st/state/.afk-daemon-terminal")" = none ] \
    && [ ! -e "$st/state/.subsuper-escalations" ]; then
    pass "native lifecycle: launcher owns state with no terminal, never touching state/.afk"
  else
    fail "native lifecycle: state preparation or no-terminal record failed"
  fi
  FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" "$LAUNCH" stop >/dev/null 2>&1
  if [ ! -e "$st/state/.afk-daemon-terminal" ]; then
    pass "native lifecycle: uniform stop clears terminal record"
  else
    fail "native lifecycle: uniform stop retained state"
  fi
  rm -rf "$st"
}

unit_native_entry_is_style_neutral() {
  local st
  st=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-native-entry.XXXXXX")
  mkdir -p "$st/state"
  : > "$st/state/.subsuper-escalations"
  FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" bash -c '
    . "$1"
    FM_AFK_DAEMON=/bin/true
    fm_afk_start_main
  ' _ "$START" >/dev/null 2>&1
  if [ ! -e "$st/state/.afk" ] && [ ! -e "$st/state/.subsuper-escalations" ]; then
    pass "native entry: starts without changing delivery style"
  else
    fail "native entry: changed delivery style or retained stale artifacts"
  fi
  rm -rf "$st"
}

unit_close_failure_preserves_record() {
  local st
  st=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-close-fail.XXXXXX")
  mkdir -p "$st/state"
  printf 'tmux\texact-session\towned\n' > "$st/state/.afk-daemon-terminal"
  FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" bash -c '
    . "$1"
    fm_afk_launch_close_terminal() { return 1; }
    fm_afk_launch_terminal_absent() { return 1; }
    ! fm_afk_launch_reconcile
  ' _ "$LAUNCH"
  if [ -e "$st/state/.afk-daemon-terminal" ]; then
    pass "teardown failure: exact terminal record is preserved"
  else
    fail "teardown failure: exact terminal record was discarded"
  fi
  rm -rf "$st"
}

unit_record_publication_atomic() {
  local st
  st=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-record-atomic.XXXXXX")
  mkdir -p "$st/state"
  printf 'tmux\told-session\towned\n' > "$st/state/.afk-daemon-terminal"
  if FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" bash -c '
    . "$1"
    mv() { return 1; }
    ! fm_afk_launch_record_write tmux new-session owned
  ' _ "$LAUNCH" \
    && [ "$(cat "$st/state/.afk-daemon-terminal")" = $'tmux\told-session\towned' ] \
    && ! find "$st/state" -name '.afk-daemon-terminal.pending.*' -print -quit | grep -q .; then
    pass "record publication: failed atomic rename preserves the complete prior record"
  else
    fail "record publication: failed write truncated or replaced the prior record"
  fi
  rm -rf "$st"
}

unit_malformed_record_fails_closed() {
  local st acted
  st=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-record-malformed.XXXXXX")
  mkdir -p "$st/state"
  printf 'tmux\tonly-two-fields\n' > "$st/state/.afk-daemon-terminal"
  acted="$st/acted"
  if FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" ACTED="$acted" bash -c '
    . "$1"
    fm_afk_launch_close_terminal() { : > "$ACTED"; }
    ! fm_afk_launch_reconcile
  ' _ "$LAUNCH" \
    && [ ! -e "$acted" ] && [ -e "$st/state/.afk-daemon-terminal" ]; then
    pass "record read: malformed record fails closed without acting on a partial id"
  else
    fail "record read: malformed record was acted on or discarded"
  fi
  rm -rf "$st"
}

unit_stop_malformed_record_fails_closed() {
  local st
  st=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-stop-malformed.XXXXXX")
  mkdir -p "$st/state"
  : > "$st/state/.afk"
  printf 'tmux\tonly-two-fields\n' > "$st/state/.afk-daemon-terminal"
  if FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" bash -c '
    . "$1"
    ! fm_afk_launch_stop
  ' _ "$LAUNCH" && [ -e "$st/state/.afk" ] && [ -e "$st/state/.afk-daemon-terminal" ]; then
    pass "stop: malformed terminal record preserves away state and fails closed"
  else
    fail "stop: malformed terminal record cleared protected lifecycle state"
  fi
  rm -rf "$st"
}

unit_tmux_planned_record_and_collision() {
  local st first second
  st=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-tmux-plan.XXXXXX")
  mkdir -p "$st/state"
  if FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" bash -c '
    . "$1"
    tmux() {
      if [ "$1" = new-session ]; then
        [ -s "$FM_AFK_LAUNCH_RECORD" ] || return 9
        printf "%s" "$4" > "$FM_HOME/created-name"
        return 1
      fi
      [ "$1" != kill-session ] || : > "$FM_HOME/killed"
      return 1
    }
    ! fm_afk_launch_create_tmux captain:0 tmux
  ' _ "$LAUNCH" && [ ! -e "$st/state/.afk-daemon-terminal" ] && [ ! -e "$st/killed" ]; then
    pass "tmux launch: planned exact target is recorded before creation and removed on failure"
  else
    fail "tmux launch: creation began before exact target publication"
  fi
  first=$(cat "$st/created-name")
  rm -rf "$st"

  st=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-tmux-unique.XXXXXX")
  mkdir -p "$st/state"
  if FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" bash -c '
    . "$1"
    tmux() {
      [ "$1" != new-session ] || { printf "%s" "$4" > "$FM_HOME/created-name"; return 1; }
      [ "$1" != kill-session ] || : > "$FM_HOME/killed"
      return 1
    }
    ! fm_afk_launch_create_tmux captain:0 tmux
  ' _ "$LAUNCH" && [ ! -e "$st/killed" ]; then
    second=$(cat "$st/created-name")
    if [ "$first" != "$second" ]; then
      pass "tmux launch: unique names eliminate collision teardown"
    else
      fail "tmux launch: consecutive launches reused a session name"
    fi
  else
    fail "tmux launch: creation failure attempted session teardown"
  fi
  rm -rf "$st"
}

unit_stop_validates_before_signal() {
  local st sleeper_pid
  st=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-stop-validate.XXXXXX")
  mkdir -p "$st/state"
  : > "$st/state/.afk"
  printf 'tmux\tonly-two-fields\n' > "$st/state/.afk-daemon-terminal"
  sleep 30 & sleeper_pid=$!
  mkdir -p "$st/state/.supervise-daemon.lock"
  printf '%s' "$sleeper_pid" > "$st/state/.supervise-daemon.lock/pid"
  ( . "$ROOT/bin/fm-wake-lib.sh"; fm_pid_identity "$sleeper_pid" > "$st/state/.supervise-daemon.lock/pid-identity" )
  FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" "$LAUNCH" stop >/dev/null 2>&1 || true
  if kill -0 "$sleeper_pid" 2>/dev/null && [ -e "$st/state/.afk" ]; then
    pass "stop validation: malformed record causes no daemon or state side effects"
  else
    fail "stop validation: malformed record signaled daemon or cleared state"
  fi
  kill "$sleeper_pid" 2>/dev/null || true
  wait "$sleeper_pid" 2>/dev/null || true
  rm -rf "$st"
}

unit_lock_requires_complete_metadata() {
  local st
  st=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-lock-metadata.XXXXXX")
  mkdir -p "$st/state"
  if FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" bash -c '
    . "$1"
    fm_pid_identity() { return 1; }
    ! fm_afk_launch_lock_acquire
  ' _ "$LAUNCH" && [ ! -e "$st/state/.afk-launch.lock" ]; then
    pass "launcher lock: incomplete metadata fails acquisition and releases lock"
  else
    fail "launcher lock: incomplete metadata was accepted"
  fi
  rm -rf "$st"
}

unit_stop_confirms_daemon_exit() {
  local st daemon_pid
  st=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-stop-live.XXXXXX")
  mkdir -p "$st/state/.supervise-daemon.lock"
  : > "$st/state/.afk"
  printf 'none\t-\tnative\n' > "$st/state/.afk-daemon-terminal"
  bash -c 'trap "" TERM; while :; do sleep 1; done' &
  daemon_pid=$!
  printf '%s' "$daemon_pid" > "$st/state/.supervise-daemon.lock/pid"
  ( . "$ROOT/bin/fm-wake-lib.sh"; fm_pid_identity "$daemon_pid" > "$st/state/.supervise-daemon.lock/pid-identity" )
  if FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" bash -c '
    . "$1"
    seq() { printf "1\n"; }
    sleep() { :; }
    kill() {
      command kill "$@"
      if [ "$1" = -TERM ]; then
        rm -rf "$FM_AFK_LAUNCH_STATE/.supervise-daemon.lock"
      fi
    }
    ! fm_afk_launch_stop
  ' _ "$LAUNCH" && kill -0 "$daemon_pid" 2>/dev/null \
    && [ ! -e "$st/state/.supervise-daemon.lock" ] \
    && [ -e "$st/state/.afk" ] && [ -e "$st/state/.afk-daemon-terminal" ]; then
    pass "stop liveness: captured live daemon preserves lifecycle state after lock release"
  else
    fail "stop liveness: lock release was mistaken for captured daemon exit"
  fi
  kill -KILL "$daemon_pid" 2>/dev/null || true
  wait "$daemon_pid" 2>/dev/null || true
  rm -rf "$st"
}

unit_refresh_validates_record() {
  local st daemon_pid
  st=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-refresh-record.XXXXXX")
  mkdir -p "$st/state/.supervise-daemon.lock"
  printf 'tmux\tonly-two-fields\n' > "$st/state/.afk-daemon-terminal"
  sleep 30 & daemon_pid=$!
  printf '%s' "$daemon_pid" > "$st/state/.supervise-daemon.lock/pid"
  ( . "$ROOT/bin/fm-wake-lib.sh"; fm_pid_identity "$daemon_pid" > "$st/state/.supervise-daemon.lock/pid-identity" )
  if FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" FM_SUPERVISOR_TARGET=unused \
    FM_SUPERVISOR_BACKEND=tmux bash -c '
      . "$1"
      ! fm_afk_launch_start && ! fm_afk_launch_start_native
    ' _ "$LAUNCH" && [ ! -e "$st/state/.afk" ]; then
    pass "refresh record: malformed terminal identity fails closed"
  else
    fail "refresh record: malformed terminal identity was accepted"
  fi
  kill "$daemon_pid" 2>/dev/null || true
  wait "$daemon_pid" 2>/dev/null || true
  rm -rf "$st"
}

unit_clear_failure_aborts_entry() {
  local st
  st=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-clear-fail.XXXXXX")
  mkdir -p "$st/state"
  : > "$st/state/.subsuper-escalations"
  : > "$st/state/.subsuper-escalations-urgent"
  if FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" bash -c '
    . "$1"
    fm_afk_launch_reconcile() { return 0; }
    fm_afk_clear_stale_artifacts() { return 1; }
    ! fm_afk_launch_start_native
  ' _ "$LAUNCH" && [ ! -e "$st/state/.afk" ] && [ -e "$st/state/.subsuper-escalations" ] && [ -e "$st/state/.subsuper-escalations-urgent" ]; then
    pass "clear failure: native entry aborts and restores prior state"
  else
    fail "clear failure: native entry proceeded or lost prior state"
  fi
  rm -rf "$st"
}

unit_confirmed_absence_succeeds() {
  local st
  st=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-confirmed-absent.XXXXXX")
  mkdir -p "$st/state"
  printf 'tmux\texact-session\towned\n' > "$st/state/.afk-daemon-terminal"
  if FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" bash -c '
    . "$1"
    fm_afk_launch_close_terminal() { return 1; }
    fm_afk_launch_terminal_absent() { return 0; }
    fm_afk_launch_reconcile
  ' _ "$LAUNCH" && [ ! -e "$st/state/.afk-daemon-terminal" ]; then
    pass "confirmed absence: cleanup succeeds and removes the stale record"
  else
    fail "confirmed absence: close error incorrectly failed reconciliation"
  fi
  rm -rf "$st"
}

unit_incomplete_restore_retains_backup() {
  local st backup
  st=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-restore-fail.XXXXXX")
  mkdir -p "$st/state"
  backup=$(mktemp -d "$st/state/.afk-launch-backup.XXXXXX")
  printf 'prior escalations\n' > "$backup/.subsuper-escalations"
  if FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" bash -c '
    . "$1"
    cp() { return 1; }
    ! fm_afk_launch_restore_backup "$2"
  ' _ "$LAUNCH" "$backup" && [ -d "$backup" ] && [ -e "$backup/.subsuper-escalations" ]; then
    pass "rollback restore: incomplete restoration retains its recovery backup"
  else
    fail "rollback restore: incomplete restoration discarded its backup"
  fi
  rm -rf "$st"
}

# afk-enter/afk-exit are the ONLY owners of the style flag now; start/start-native
# never touch it (unit_native_lifecycle above), so this exercises the toggle
# directly as its own independent lifecycle surface.
unit_afk_enter_exit_independent_of_daemon() {
  local st
  st=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-flag-toggle.XXXXXX")
  mkdir -p "$st/state"
  FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" "$LAUNCH" afk-enter >/dev/null 2>&1
  if [ -e "$st/state/.afk" ] && [ ! -e "$st/state/.afk-daemon-terminal" ]; then
    pass "afk-enter: writes state/.afk without touching daemon lifecycle state"
  else
    fail "afk-enter: did not write state/.afk cleanly"
  fi
  FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" "$LAUNCH" afk-exit >/dev/null 2>&1
  if [ ! -e "$st/state/.afk" ]; then
    pass "afk-exit: clears state/.afk"
  else
    fail "afk-exit: did not clear state/.afk"
  fi
  rm -rf "$st"
}

# ---------------------------------------------------------------------------
# E2E herdr: topology invariant.
# ---------------------------------------------------------------------------
e2e_herdr() {
  command -v herdr >/dev/null 2>&1 || { echo "skip: herdr not found (herdr e2e)"; return 0; }
  command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (herdr e2e)"; return 0; }
  # shellcheck source=tests/herdr-test-safety.sh
  . "$ROOT/tests/herdr-test-safety.sh"
  # shellcheck source=/dev/null
  . "$ROOT/bin/fm-backend.sh"

  local SESSION home_tmp cap_ws cap_tab cap_pane target
  local before during after ws_before ws_during ws_after out dtgt dtab
  SESSION="fm-lab-afk-launch-e2e-$$"
  export HERDR_SESSION="$SESSION"
  home_tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-e2e-home.XXXXXX")
  E2E_HERDR_CLEANUP() {
    FM_HOME="$home_tmp" FM_STATE_OVERRIDE="$home_tmp/state" \
      FM_SUPERVISOR_TARGET="$target" FM_SUPERVISOR_BACKEND=herdr "$LAUNCH" stop >/dev/null 2>&1 || true
    herdr_safe_stop_and_delete "$SESSION" >/dev/null 2>&1 || true
    rm -rf "$home_tmp" 2>/dev/null || true
  }
  fm_herdr_lab_prepare "$SESSION" || { fail "herdr e2e: could not prepare isolated lab session"; return 0; }
  fm_backend_source herdr || { E2E_HERDR_CLEANUP; fail "herdr e2e: fm_backend_source herdr failed"; return 0; }
  fm_backend_herdr_server_ensure "$SESSION" || { E2E_HERDR_CLEANUP; fail "herdr e2e: lab server did not start"; return 0; }

  out=$(fm_backend_herdr_cli "$SESSION" workspace create --cwd "$ROOT" --label captain --no-focus 2>/dev/null)
  cap_ws=$(printf '%s' "$out" | jq -r '.result.workspace.workspace_id // empty')
  cap_tab=$(printf '%s' "$out" | jq -r '.result.tab.tab_id // empty')
  cap_pane=$(printf '%s' "$out" | jq -r '.result.root_pane.pane_id // empty')
  if [ -z "$cap_ws" ] || [ -z "$cap_pane" ]; then E2E_HERDR_CLEANUP; fail "herdr e2e: could not create captain workspace"; return 0; fi
  target="$SESSION:$cap_pane"
  before=$(fm_backend_herdr_cli "$SESSION" pane list --workspace "$cap_ws" 2>/dev/null | jq --arg t "$cap_tab" '[.result.panes[]?|select(.tab_id==$t)]|length')
  ws_before=$(fm_backend_herdr_cli "$SESSION" workspace list 2>/dev/null | jq '[.result.workspaces[]?]|length')

  FM_HOME="$home_tmp" FM_STATE_OVERRIDE="$home_tmp/state" \
    FM_SUPERVISOR_TARGET="$target" FM_SUPERVISOR_BACKEND=herdr FM_AFK_LAUNCH_ENTRY="$SLEEPER" \
    "$LAUNCH" start >/dev/null 2>&1

  during=$(fm_backend_herdr_cli "$SESSION" pane list --workspace "$cap_ws" 2>/dev/null | jq --arg t "$cap_tab" '[.result.panes[]?|select(.tab_id==$t)]|length')
  ws_during=$(fm_backend_herdr_cli "$SESSION" workspace list 2>/dev/null | jq '[.result.workspaces[]?]|length')
  dtgt=$(cut -f2 "$home_tmp/state/.afk-daemon-terminal" 2>/dev/null || true)
  dtab=$(fm_backend_herdr_cli "$SESSION" pane get "${dtgt#*:}" 2>/dev/null | jq -r '.result.pane.tab_id // empty')

  if [ "$before" = "$during" ]; then pass "herdr e2e: captain tab pane count unchanged after start (no split)"; else fail "herdr e2e: captain tab pane count changed ($before -> $during)"; fi
  if [ "$ws_during" -gt "$ws_before" ]; then pass "herdr e2e: daemon launched in a separate non-visible workspace"; else fail "herdr e2e: no separate daemon workspace created"; fi
  if [ -n "$dtab" ] && [ "$dtab" != "$cap_tab" ]; then pass "herdr e2e: daemon pane is NOT in the captain's tab"; else fail "herdr e2e: daemon pane shares the captain tab ($dtab)"; fi
  case "$dtgt" in "$SESSION":*) pass "herdr e2e: daemon terminal scoped to the lab session" ;; *) fail "herdr e2e: daemon terminal not in the lab session ($dtgt)" ;; esac

  FM_HOME="$home_tmp" FM_STATE_OVERRIDE="$home_tmp/state" \
    FM_SUPERVISOR_TARGET="$target" FM_SUPERVISOR_BACKEND=herdr "$LAUNCH" stop >/dev/null 2>&1

  after=$(fm_backend_herdr_cli "$SESSION" pane list --workspace "$cap_ws" 2>/dev/null | jq --arg t "$cap_tab" '[.result.panes[]?|select(.tab_id==$t)]|length')
  ws_after=$(fm_backend_herdr_cli "$SESSION" workspace list 2>/dev/null | jq '[.result.workspaces[]?]|length')
  if [ "$after" = "$before" ]; then pass "herdr e2e: captain tab pane count restored after stop"; else fail "herdr e2e: captain tab pane count not restored ($before -> $after)"; fi
  if [ "$ws_after" = "$ws_before" ]; then pass "herdr e2e: daemon workspace removed by exact id on stop"; else fail "herdr e2e: daemon workspace leaked ($ws_before -> $ws_after)"; fi
  if [ ! -e "$home_tmp/state/.afk-daemon-terminal" ]; then pass "herdr e2e: terminal record cleared on stop"; else fail "herdr e2e: terminal record not cleared"; fi

  E2E_HERDR_CLEANUP
}

# ---------------------------------------------------------------------------
# E2E tmux: topology invariant (captain window untouched; daemon in a separate
# detached session).
# ---------------------------------------------------------------------------
e2e_tmux() {
  command -v tmux >/dev/null 2>&1 || { echo "skip: tmux not found (tmux e2e)"; return 0; }
  local cap_session home_tmp cap_pane before during after rec
  cap_session="fm-afk-launch-cap-$$"
  home_tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-tmux-home.XXXXXX")
  tmux new-session -d -s "$cap_session" 2>/dev/null || { fail "tmux e2e: could not create captain session"; rm -rf "$home_tmp"; return 0; }
  TRACK_TMUX_SESSIONS="$TRACK_TMUX_SESSIONS $cap_session"
  cap_pane=$(tmux display-message -p -t "$cap_session" '#{pane_id}')
  before=$(tmux list-panes -t "$cap_session" | wc -l | tr -d ' ')

  FM_HOME="$home_tmp" FM_STATE_OVERRIDE="$home_tmp/state" \
    FM_SUPERVISOR_TARGET="$cap_pane" FM_SUPERVISOR_BACKEND=tmux FM_AFK_LAUNCH_ENTRY="$SLEEPER" \
    "$LAUNCH" start >/dev/null 2>&1

  during=$(tmux list-panes -t "$cap_session" | wc -l | tr -d ' ')
  rec=$(cut -f2 "$home_tmp/state/.afk-daemon-terminal" 2>/dev/null || true)
  TRACK_TMUX_SESSIONS="$TRACK_TMUX_SESSIONS $rec"
  if [ "$before" = "$during" ]; then pass "tmux e2e: captain window pane count unchanged after start (no split-window)"; else fail "tmux e2e: captain window pane count changed ($before -> $during)"; fi
  if [ -n "$rec" ] && tmux has-session -t "$rec" 2>/dev/null && [ "$rec" != "$cap_session" ]; then pass "tmux e2e: daemon launched in a separate detached session"; else fail "tmux e2e: no separate daemon session ($rec)"; fi

  FM_HOME="$home_tmp" FM_STATE_OVERRIDE="$home_tmp/state" \
    FM_SUPERVISOR_TARGET="$cap_pane" FM_SUPERVISOR_BACKEND=tmux "$LAUNCH" stop >/dev/null 2>&1

  after=$(tmux list-panes -t "$cap_session" | wc -l | tr -d ' ')
  if [ "$after" = "$before" ]; then pass "tmux e2e: captain window pane count unchanged after stop"; else fail "tmux e2e: captain window changed ($before -> $after)"; fi
  if [ -n "$rec" ] && ! tmux has-session -t "$rec" 2>/dev/null; then pass "tmux e2e: daemon session killed by exact id on stop"; else fail "tmux e2e: daemon session leaked ($rec)"; fi
  if [ ! -e "$home_tmp/state/.afk-daemon-terminal" ]; then pass "tmux e2e: terminal record cleared on stop"; else fail "tmux e2e: terminal record not cleared"; fi

  tmux kill-session -t "$cap_session" 2>/dev/null || true
  rm -rf "$home_tmp" 2>/dev/null || true
}

unit_clear_stale
unit_daemon_cmd_sources_config_files
unit_fresh_vs_refresh
unit_stop_never_touches_afk
unit_stop_rejects_reused_pid
unit_failed_start_rolls_back_state
unit_concurrent_start_serialized
unit_lock_initialization_grace
unit_signal_exits_with_lock_cleanup
unit_herdr_partial_create_recovery
unit_herdr_error_with_exact_ids_closes_exact
unit_herdr_run_failure_preserves_unconfirmed_record
unit_record_failure_closes_terminal
unit_readiness_failure_rolls_back_terminal
unit_readiness_failure_preserves_unconfirmed_record
unit_tmux_absence_distinguishes_probe_failure
unit_native_lifecycle
unit_native_entry_is_style_neutral
unit_close_failure_preserves_record
unit_record_publication_atomic
unit_malformed_record_fails_closed
unit_stop_malformed_record_fails_closed
unit_tmux_planned_record_and_collision
unit_stop_validates_before_signal
unit_lock_requires_complete_metadata
unit_stop_confirms_daemon_exit
unit_refresh_validates_record
unit_clear_failure_aborts_entry
unit_confirmed_absence_succeeds
unit_incomplete_restore_retains_backup
unit_afk_enter_exit_independent_of_daemon
e2e_herdr
e2e_tmux

[ "$FAILED" -eq 0 ] || exit 1
