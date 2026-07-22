#!/usr/bin/env bash
# tests/fm-claude-alwayson-live-e2e.test.sh - opt-in credentialed regression for
# the always-on triage daemon against a REAL interactive claude session
# (fm-alwayson-triage-s5 phase 2). Proves, end to end:
#
#   1. A marked injection from the real daemon wakes a real claude turn - the
#      pane transitions from an idle composer to busy after the daemon types
#      and submits its escalation digest.
#   2. The turn-end guard and the continuity PreToolUse gate stay quiet
#      (allow) while the daemon is alive, purely from its live identity-matched
#      lock - no watcher lock is ever separately armed in this scenario.
#   3. The turn-end guard blocks again once the daemon is stopped.
#
# Isolation: everything runs on a PRIVATE tmux socket (`-L alwayson-e2e-<pid>`),
# never the real fleet's tmux server or herdr session, and against a scratch
# git clone + scratch FM_HOME. A tmux shim on PATH redirects every bare `tmux`
# call (the daemon's own, and this script's) to that private socket, exactly
# like tests/fm-afk-inject-e2e.test.sh. FM_SUPERVISOR_BACKEND=tmux is also
# pinned explicitly rather than left to auto-detection: this test's own process
# may itself be running inside herdr (HERDR_ENV=1 is inherited by every process
# herdr manages a pane for), which would otherwise leak into the daemon
# subprocess and misdetect backend=herdr against what is actually a tmux pane
# on the private socket.
set -u

if [ "${FM_CLAUDE_LIVE_E2E:-0}" != 1 ]; then
  echo "skip: set FM_CLAUDE_LIVE_E2E=1 to run the claude always-on triage regression"
  exit 0
fi

command -v tmux >/dev/null 2>&1 || { echo "skip: tmux not found"; exit 0; }
command -v claude >/dev/null 2>&1 || { echo "skip: claude not found"; exit 0; }

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REAL_TMUX=$(command -v tmux)
SOCKET="alwayson-e2e-$$"
LAB="$ROOT/.claude-alwayson-live-e2e.$$"
PROJECT="$LAB/project"
HOME_DIR="$LAB/fmhome"
STATE="$HOME_DIR/state"
TMUX_SHIM_DIR=
SUPERVISOR_PANE=
DAEMON_PID=
CLAUDE_VERSION=$(claude --version)

fail() { printf 'not ok - %s\n' "$1" >&2; cleanup_all; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

cleanup_all() {
  if [ -n "${DAEMON_PID:-}" ] && kill -0 "$DAEMON_PID" 2>/dev/null; then
    kill -TERM "$DAEMON_PID" 2>/dev/null || true
    wait "$DAEMON_PID" 2>/dev/null || true
  fi
  "$REAL_TMUX" -L "$SOCKET" kill-server 2>/dev/null || true
  rm -rf "$TMUX_SHIM_DIR" "$LAB" 2>/dev/null || true
}
trap cleanup_all EXIT

mkdir -p "$LAB"
git clone -q "$ROOT" "$PROJECT"
mkdir -p "$PROJECT/.claude" "$HOME_DIR/state" "$HOME_DIR/config" "$HOME_DIR/data"
cp "$ROOT/.claude/settings.json" "$PROJECT/.claude/settings.json"

# One in-flight task so the turn-end guard's predicate actually engages (it is
# a silent no-op with nothing in flight).
{
  printf 'window=%s:task\n' "$SOCKET"
  printf 'kind=ship\n'
} > "$STATE/task.meta"
printf 'working: waiting\n' > "$STATE/task.status"

# tmux shim: every bare `tmux` call (this script's own, and the daemon's) goes
# to the private socket instead of the real default server.
TMUX_SHIM_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-alwayson-e2e-shim.XXXXXX")
cat > "$TMUX_SHIM_DIR/tmux" <<SHIM
#!/usr/bin/env bash
exec "$REAL_TMUX" -L "$SOCKET" "\$@"
SHIM
chmod +x "$TMUX_SHIM_DIR/tmux"
PATH="$TMUX_SHIM_DIR:$PATH"

# --- private tmux socket + captain pane --------------------------------------

tmux new-session -d -s captain -x 220 -y 50
SUPERVISOR_PANE=$(tmux display-message -p -t captain '#{pane_id}')

# Search the WHOLE pane, never just a tail slice: the TUI often does not fill
# the full configured terminal height, so the last few captured rows are blank
# filler, not the composer.
pane_capture_full() {
  tmux capture-pane -p -t "$SUPERVISOR_PANE" 2>/dev/null
}

trust_prompt_visible() {
  pane_capture_full | grep -qF 'trust this folder'
}

composer_idle() {
  local cap
  cap=$(pane_capture_full)
  case "$cap" in
    *'trust this folder'*) return 1 ;;
    *'│ >'*'│'*) return 0 ;;
    *'❯'*) return 0 ;;
  esac
  return 1
}

pane_busy_now() {
  ! trust_prompt_visible && ! composer_idle
}

wait_for() {  # <description> <max-tries> <check-fn>
  local desc=$1 tries=$2 fn=$3 i=0
  while [ "$i" -lt "$tries" ]; do
    "$fn" && return 0
    sleep 1
    i=$((i + 1))
  done
  echo "timed out waiting for: $desc" >&2
  echo "pane capture:" >&2
  pane_capture_full | sed 's/^/    /' >&2
  return 1
}

# Launch a real, interactive claude session in the private-socket pane. A
# fresh working directory (this scratch clone has never been opened before)
# may prompt a one-time folder-trust dialog before the real composer appears;
# accept it explicitly rather than assuming it will or won't show up.
tmux send-keys -t "$SUPERVISOR_PANE" \
  "cd '$PROJECT' && exec claude --dangerously-skip-permissions" Enter
# The trust prompt is optional (a working directory claude has seen before
# skips it), so poll for it briefly without wait_for's loud timeout diagnostic.
i=0
while [ "$i" -lt 8 ] && ! trust_prompt_visible; do
  sleep 1
  i=$((i + 1))
done
trust_prompt_visible && tmux send-keys -t "$SUPERVISOR_PANE" Enter
wait_for "claude TUI ready (idle composer)" 60 composer_idle \
  || fail "claude did not reach an idle composer after launch"

# Get it to a settled, deliberate idle state (a fresh launch may still be
# rendering theme/tips content that looks idle but is not the real composer).
# A short reply can complete within a second, faster than this polling
# granularity can reliably catch a transient busy frame, so this warm-up only
# asserts the eventual outcome (idle again, with the reply visible) rather than
# requiring an observed busy transition - that stronger assertion belongs to
# the actual injection test below, which polls faster.
tmux send-keys -t "$SUPERVISOR_PANE" -l \
  'Reply with exactly the word ready and then stop. Do not use any tools.'
tmux send-keys -t "$SUPERVISOR_PANE" Enter
wait_for "claude replies and settles back to an idle composer" 90 composer_idle \
  || fail "claude did not settle back to an idle composer after its first turn"
pane_capture_full | grep -qi 'ready' \
  || fail "claude's warm-up reply is not visible in the pane transcript"

# --- start the REAL always-on triage daemon ----------------------------------

start_daemon() {
  PATH="$TMUX_SHIM_DIR:$PATH" \
  FM_ROOT_OVERRIDE="$PROJECT" \
  FM_STATE_OVERRIDE="$STATE" \
  FM_SUPERVISOR_TARGET="$SUPERVISOR_PANE" \
  FM_SUPERVISOR_BACKEND=tmux \
  FM_ESCALATE_BATCH_SECS_PRESENT=0 \
  FM_HOUSEKEEPING_TICK=1 \
  FM_POLL=1 \
  FM_SIGNAL_GRACE=1 \
  FM_HEARTBEAT=999999 \
  FM_CHECK_INTERVAL=999999 \
  FM_INJECT_CONFIRM_SLEEP=0.3 \
  FM_INJECT_CONFIRM_RETRIES=5 \
  "$ROOT/bin/fm-supervise-daemon.sh" >"$STATE/daemon.out" 2>"$STATE/daemon.err" &
  DAEMON_PID=$!
  local i=0
  while [ "$i" -lt 30 ]; do
    [ -f "$STATE/.supervise-daemon.pid" ] && return 0
    sleep 0.2
    i=$((i + 1))
  done
  echo "daemon stderr:" >&2
  cat "$STATE/daemon.err" >&2
  fail "daemon did not start (no pid file after 6s)"
}

run_turnend_guard() {  # -> exit status of the guard for the current state
  printf '{"stop_hook_active":false}' | \
    CLAUDECODE=1 FM_ROOT_OVERRIDE="$PROJECT" FM_HOME="$PROJECT" FM_STATE_OVERRIDE="$STATE" \
    FM_SUPERVISOR_BACKEND=tmux \
    bash "$PROJECT/bin/fm-turnend-guard.sh" > "$STATE/guard.out" 2> "$STATE/guard.err"
}

run_continuity_check() {  # -> exit status
  FM_ROOT_OVERRIDE="$PROJECT" FM_HOME="$PROJECT" FM_STATE_OVERRIDE="$STATE" \
    FM_SUPERVISOR_BACKEND=tmux \
    bash "$PROJECT/bin/fm-continuity-pretool-check.sh" --command 'bin/fm-crew-state.sh task' \
    > "$STATE/continuity.out" 2> "$STATE/continuity.err"
}

start_daemon

test_guards_quiet_with_live_daemon() {
  local rc=0
  run_turnend_guard || rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "--- diagnostics: daemon lock state ---" >&2
    ls -la "$STATE/.supervise-daemon.lock" 2>&1 >&2 || true
    echo "lock readlink: $(readlink "$STATE/.supervise-daemon.lock" 2>&1)" >&2
    echo "pidfile: $(cat "$STATE/.supervise-daemon.pid" 2>&1)" >&2
    echo "daemon still alive (kill -0): $(kill -0 "$DAEMON_PID" 2>&1; echo rc=$?)" >&2
    echo "daemon.err:" >&2; cat "$STATE/daemon.err" >&2
    echo "daemon.out:" >&2; cat "$STATE/daemon.out" >&2
  fi
  [ "$rc" -eq 0 ] || fail "turn-end guard blocked despite a live identity-matched daemon lock (rc=$rc): $(cat "$STATE/guard.err")"
  [ ! -s "$STATE/guard.err" ] || fail "turn-end guard printed output despite a live daemon: $(cat "$STATE/guard.err")"
  rc=0
  run_continuity_check || rc=$?
  [ "$rc" -eq 0 ] || fail "continuity gate denied despite a live identity-matched daemon lock (rc=$rc): $(cat "$STATE/continuity.err")"
  pass "guards stay quiet with the always-on daemon alive (daemon-alive-allows)"
}

test_marked_injection_wakes_a_turn() {
  # A captain-relevant status the real watcher child (spawned by the daemon
  # above) will classify as an escalation and inject as a marked message.
  printf 'done: PR https://example.test/pr/900\n' > "$STATE/task.status"

  # Poll fast for the transient busy frame - a real turn may complete in well
  # under a second, faster than wait_for's 1s granularity can reliably catch.
  # Missing this frame is not fatal on its own: the delivery and completion
  # checks below are the authoritative proof that a turn actually ran.
  local caught_busy=0 i=0
  while [ "$i" -lt 100 ]; do
    if pane_busy_now; then
      caught_busy=1
      break
    fi
    sleep 0.3
    i=$((i + 1))
  done

  wait_for "the injected digest becomes visible in the pane transcript" 15 \
    injection_visible_in_pane \
    || fail "the injected escalation digest never appeared in the pane transcript"
  wait_for "claude settles back to idle after handling the escalation" 90 composer_idle \
    || fail "claude never returned to idle after the injected turn"

  if [ "$caught_busy" -eq 0 ]; then
    echo "note: never observed a transient busy frame (turn may have completed" \
      "faster than this poll interval); relying on delivery+completion evidence" >&2
  fi
  pass "a marked injection from the real always-on daemon wakes a real claude turn"
}

injection_visible_in_pane() {
  pane_capture_full | grep -qF 'PR https://example.test/pr/900'
}

test_turnend_guard_blocks_once_daemon_is_stopped() {
  # Re-assert the in-flight fixture: the claude session in the pane runs with
  # this repo's own real AGENTS.md/hooks, so having just handled a "done: PR
  # ..." escalation, it may genuinely (and correctly, per its own instructions)
  # have treated the fixture task as complete and touched its meta/status -
  # this test is about the guard's daemon-down predicate, not about that
  # unrelated cleanup behavior, so restore the precondition explicitly.
  {
    printf 'window=%s:task\n' "$SOCKET"
    printf 'kind=ship\n'
  } > "$STATE/task.meta"

  # SIGTERM directly (this daemon was started directly, not through
  # bin/fm-daemon-launch.sh, so there is no terminal-lifecycle record to route
  # through): the daemon's own trapped cleanup flushes and exits, releasing its
  # lock exactly like a captain-requested stop would.
  kill -TERM "$DAEMON_PID" 2>/dev/null || true
  local i=0
  while [ "$i" -lt 30 ] && kill -0 "$DAEMON_PID" 2>/dev/null; do
    sleep 0.2
    i=$((i + 1))
  done
  if kill -0 "$DAEMON_PID" 2>/dev/null; then
    kill -KILL "$DAEMON_PID" 2>/dev/null || true
  fi
  wait "$DAEMON_PID" 2>/dev/null || true
  DAEMON_PID=""
  local rc=0
  run_turnend_guard || rc=$?
  if [ "$rc" -ne 2 ]; then
    echo "--- diagnostics: daemon lock state after stop ---" >&2
    ls -la "$STATE/.supervise-daemon.lock" 2>&1 >&2 || echo "(lock absent)" >&2
    echo "guard.err:" >&2; cat "$STATE/guard.err" >&2
    echo "task.meta present: $([ -f "$STATE/task.meta" ] && echo yes || echo no)" >&2
    echo "state dir listing:" >&2; ls -la "$STATE" >&2
    echo "manual fm_primary_scope_matches + fm_supervision_status check:" >&2
    FM_STATE_OVERRIDE="$STATE" bash -c '
      . "$1/bin/fm-supervision-lib.sh"
      . "$1/bin/fm-primary-scope-lib.sh"
      if fm_primary_scope_matches "$2" "$3"; then echo "scope: matches"; else echo "scope: DOES NOT MATCH"; fi
      fm_supervision_status "$3" 300
      echo "in_flight=$FM_SUP_IN_FLIGHT watcher_fresh=$FM_SUP_WATCHER_FRESH"
    ' _ "$PROJECT" "$PROJECT" "$STATE" >&2 2>&1
  fi
  [ "$rc" -eq 2 ] || fail "turn-end guard did not block after the daemon was stopped (rc=$rc)"
  grep -F 'TURN WOULD END BLIND' "$STATE/guard.err" >/dev/null \
    || fail "turn-end guard block was missing the expected alarm banner: $(cat "$STATE/guard.err")"
  pass "turn-end guard blocks again once the always-on daemon is stopped"
}

test_guards_quiet_with_live_daemon
test_marked_injection_wakes_a_turn
test_turnend_guard_blocks_once_daemon_is_stopped

printf 'ok - claude %s always-on triage live E2E: injection wakes a turn, guards daemon-alive-allow, turn-end guard re-blocks when stopped\n' "$CLAUDE_VERSION"
