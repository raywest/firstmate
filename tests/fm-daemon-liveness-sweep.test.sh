#!/usr/bin/env bash
# tests/fm-daemon-liveness-sweep.test.sh - bin/fm-bootstrap.sh's
# daemon_liveness_sweep(), the session-start (locked) guarantee that the
# always-on triage daemon (docs/alwayson-triage.md) is running on a supported
# combination - claude on tmux or herdr, the daemon's own supported injection
# backends (bin/fm-supervise-daemon.sh FM_SUPERVISOR_SUPPORTED_BACKENDS).
#
# The function is extracted from the live script and sourced in isolation
# (never the full fm-bootstrap.sh flow): fm-bootstrap.sh's OTHER mutating
# sweeps - in particular fm-pr-check-migrate.sh, which unconditionally pauses
# and TERMinates an identity-matched watcher as part of its own legacy-check
# migration, independent of anything under test here - would otherwise
# confound every watcher-lock fixture this file needs. Extraction keeps this
# suite testing exactly daemon_liveness_sweep's own logic, deterministically,
# with no risk to this session's own real daemon, watcher, lock, or state
# (AGENTS.md prime directive #1) and no dependency on real herdr/tmux.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-daemon-liveness-sweep)

# shellcheck source=bin/fm-backend.sh
. "$ROOT/bin/fm-backend.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$ROOT/bin/fm-wake-lib.sh"
# shellcheck source=bin/fm-supervisor-target-lib.sh
. "$ROOT/bin/fm-supervisor-target-lib.sh"
first_line() { head -1; }

# Extract daemon_liveness_sweep's exact current body from the live script, so
# this suite tracks the real implementation rather than a hand-copied drift
# risk, without ever running fm-bootstrap.sh's other sweeps.
mkdir -p "$TMP_ROOT"
FN_FILE="$TMP_ROOT/daemon_liveness_sweep.fn.sh"
awk '/^daemon_liveness_sweep\(\) \{/,/^\}/' "$ROOT/bin/fm-bootstrap.sh" > "$FN_FILE"
[ -s "$FN_FILE" ] || fail "could not extract daemon_liveness_sweep() from bin/fm-bootstrap.sh"
# shellcheck source=/dev/null
. "$FN_FILE"

# new_case <name>: a scratch SCRIPT_DIR/STATE/FM_HOME triple plus stub
# fm-harness.sh (prints FM_TEST_HARNESS, default claude) and fm-daemon-launch.sh
# (appends each subcommand to $DAEMON_LAUNCH_LOG, exits 0 unless
# DAEMON_LAUNCH_FAIL names that exact subcommand). Echoes the case dir.
new_case() {
  local name=$1 dir
  dir="$TMP_ROOT/$name"
  mkdir -p "$dir/bin" "$dir/state"
  cat > "$dir/bin/fm-harness.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "${FM_TEST_HARNESS:-claude}"
EOF
  cat > "$dir/bin/fm-daemon-launch.sh" <<'EOF'
#!/usr/bin/env bash
sub=${1:-}
printf '%s\n' "$sub" >> "${DAEMON_LAUNCH_LOG:?DAEMON_LAUNCH_LOG unset}"
case " ${DAEMON_LAUNCH_FAIL:-} " in *" $sub "*) exit 1 ;; esac
exit 0
EOF
  chmod +x "$dir/bin/fm-harness.sh" "$dir/bin/fm-daemon-launch.sh"
  printf '%s\n' "$dir"
}

run_sweep() {  # <dir> <harness> [backend env assignments...] -> daemon-launch.log contents
  local dir=$1 harness=$2; shift 2
  local log="$dir/daemon-launch.log"
  : > "$log"
  # shellcheck disable=SC2016  # $1-$4 belong to the inner bash -c process.
  env -u TMUX -u HERDR_ENV -u CMUX_WORKSPACE_ID "$@" \
    SCRIPT_DIR="$dir/bin" STATE="$dir/state" FM_HOME="$dir" FM_TEST_HARNESS="$harness" DAEMON_LAUNCH_LOG="$log" \
    bash -c '
      . "$1"
      . "$2"
      . "$3"
      first_line() { head -1; }
      . "$4"
      daemon_liveness_sweep
    ' _ "$ROOT/bin/fm-backend.sh" "$ROOT/bin/fm-wake-lib.sh" "$ROOT/bin/fm-supervisor-target-lib.sh" "$FN_FILE" \
    > "$dir/sweep.out" 2>&1
  cat "$log"
}

test_non_claude_harness_is_noop() {
  local dir out
  dir=$(new_case non-claude)
  out=$(run_sweep "$dir" codex TMUX=1 TMUX_PANE='%1')
  [ -z "$out" ] || fail "a non-claude harness must never touch the daemon lifecycle: $out"
  pass "daemon_liveness_sweep: no-op for a non-claude harness"
}

test_unsupported_backend_is_noop() {
  local dir out
  dir=$(new_case unsupported-backend)
  out=$(run_sweep "$dir" claude)
  [ -z "$out" ] || fail "an undetectable/unsupported backend must never touch the daemon lifecycle: $out"
  pass "daemon_liveness_sweep: no-op when the backend cannot be resolved to tmux/herdr"
}

test_dead_daemon_launches_start() {
  local dir out
  dir=$(new_case dead-daemon)
  out=$(run_sweep "$dir" claude TMUX=1 TMUX_PANE='%1')
  [ "$out" = "start" ] || fail "a dead daemon on a supported combination must be ensured with exactly one fm-daemon-launch.sh start, got: $out"
  pass "daemon_liveness_sweep: launches the daemon when it is not alive on a supported combination"
}

# A live, identity-matched watcher lock left over from before the daemon
# existed (or from an unflipped session) must be TERM'd, home-scoped, before
# the daemon is started - the takeover (always-on triage spec section 5).
test_takeover_terminates_foreign_watcher_before_start() {
  local dir out pid identity
  dir=$(new_case takeover)
  sleep 60 &
  pid=$!
  identity=$(FM_STATE_OVERRIDE="$dir/state" bash -c '. "$1"; fm_pid_identity "$2"' _ "$ROOT/bin/fm-wake-lib.sh" "$pid") \
    || fail "could not identify the foreign watcher fixture"
  mkdir -p "$dir/state/.watch.lock"
  printf '%s\n' "$pid" > "$dir/state/.watch.lock/pid"
  printf '%s\n' "$dir" > "$dir/state/.watch.lock/fm-home"
  printf '%s\n' "$dir/bin/fm-watch.sh" > "$dir/state/.watch.lock/watcher-path"
  printf '%s\n' "$identity" > "$dir/state/.watch.lock/pid-identity"
  out=$(run_sweep "$dir" claude TMUX=1 TMUX_PANE='%1')
  if kill -0 "$pid" 2>/dev/null; then
    kill -9 "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    fail "takeover did not terminate the foreign watcher lock holder"
  fi
  wait "$pid" 2>/dev/null || true
  assert_contains "$out" "start" "takeover must still ensure the daemon after terminating the foreign watcher"
  pass "daemon_liveness_sweep: takes over (terminates) a foreign watcher lock before starting the daemon"
}

# A watcher lock whose recorded identity does NOT match the live process (a
# reused pid, or a different home) must never be signaled - only an exact,
# identity-matched, home-scoped watcher is ever taken over.
test_takeover_never_signals_mismatched_identity() {
  local dir out pid
  dir=$(new_case takeover-mismatch)
  sleep 60 &
  pid=$!
  mkdir -p "$dir/state/.watch.lock"
  printf '%s\n' "$pid" > "$dir/state/.watch.lock/pid"
  printf '%s\n' "$dir" > "$dir/state/.watch.lock/fm-home"
  printf '%s\n' "$dir/bin/fm-watch.sh" > "$dir/state/.watch.lock/watcher-path"
  printf '%s\n' "stale unrelated identity" > "$dir/state/.watch.lock/pid-identity"
  out=$(run_sweep "$dir" claude TMUX=1 TMUX_PANE='%1')
  if ! kill -0 "$pid" 2>/dev/null; then
    fail "takeover signaled a watcher lock whose identity did not match the live process"
  fi
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  assert_contains "$out" "start" "the daemon must still be ensured even when the stale lock is left alone"
  pass "daemon_liveness_sweep: never signals a watcher lock with a mismatched identity"
}

# A live daemon lock alone is enough: no takeover, no restart, when the
# recorded supervisor target matches this session's own current resolution.
test_live_daemon_matching_target_is_noop() {
  local dir out pid identity
  dir=$(new_case live-daemon-match)
  sleep 60 &
  pid=$!
  identity=$(FM_STATE_OVERRIDE="$dir/state" bash -c '. "$1"; fm_pid_identity "$2"' _ "$ROOT/bin/fm-wake-lib.sh" "$pid") \
    || fail "could not identify the live daemon fixture"
  mkdir -p "$dir/state/.supervise-daemon.lock"
  printf '%s' "$pid" > "$dir/state/.supervise-daemon.lock/pid"
  printf '%s' "$identity" > "$dir/state/.supervise-daemon.lock/pid-identity"
  printf 'tmux\t%%1\n' > "$dir/state/.supervisor-target"
  out=$(run_sweep "$dir" claude TMUX=1 TMUX_PANE='%1')
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  [ -z "$out" ] || fail "a live daemon with a matching recorded target should never call fm-daemon-launch.sh: $out"
  pass "daemon_liveness_sweep: a live daemon whose recorded target matches the current pane is left alone"
}

# The captain's pane moved (new window, reboot): the recorded supervisor
# target no longer matches this session's own discovery, so the sweep
# restarts the daemon (stop, then start) with the current pane.
test_retarget_mismatch_restarts_daemon() {
  local dir out pid identity
  dir=$(new_case retarget)
  sleep 60 &
  pid=$!
  identity=$(FM_STATE_OVERRIDE="$dir/state" bash -c '. "$1"; fm_pid_identity "$2"' _ "$ROOT/bin/fm-wake-lib.sh" "$pid") \
    || fail "could not identify the live daemon fixture"
  mkdir -p "$dir/state/.supervise-daemon.lock"
  printf '%s' "$pid" > "$dir/state/.supervise-daemon.lock/pid"
  printf '%s' "$identity" > "$dir/state/.supervise-daemon.lock/pid-identity"
  printf 'tmux\t%%old-stale-pane\n' > "$dir/state/.supervisor-target"
  out=$(run_sweep "$dir" claude TMUX=1 TMUX_PANE='%1')
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  [ "$out" = "$(printf 'stop\nstart')" ] || fail "retarget mismatch must stop then start exactly once each, got: $out"
  pass "daemon_liveness_sweep: a pane-retarget mismatch restarts the daemon (stop, then start)"
}

# No recorded target at all (a daemon that predates this record, or one whose
# write failed) must not be treated as a mismatch - nothing to compare against,
# so the live daemon is left alone rather than restarted on every sweep.
test_live_daemon_no_recorded_target_is_noop() {
  local dir out pid identity
  dir=$(new_case no-recorded-target)
  sleep 60 &
  pid=$!
  identity=$(FM_STATE_OVERRIDE="$dir/state" bash -c '. "$1"; fm_pid_identity "$2"' _ "$ROOT/bin/fm-wake-lib.sh" "$pid") \
    || fail "could not identify the live daemon fixture"
  mkdir -p "$dir/state/.supervise-daemon.lock"
  printf '%s' "$pid" > "$dir/state/.supervise-daemon.lock/pid"
  printf '%s' "$identity" > "$dir/state/.supervise-daemon.lock/pid-identity"
  out=$(run_sweep "$dir" claude TMUX=1 TMUX_PANE='%1')
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  [ -z "$out" ] || fail "a live daemon with no recorded target should not be restarted: $out"
  pass "daemon_liveness_sweep: a live daemon with no recorded target record is left alone"
}

test_non_claude_harness_is_noop
test_unsupported_backend_is_noop
test_dead_daemon_launches_start
test_takeover_terminates_foreign_watcher_before_start
test_takeover_never_signals_mismatched_identity
test_live_daemon_matching_target_is_noop
test_retarget_mismatch_restarts_daemon
test_live_daemon_no_recorded_target_is_noop
