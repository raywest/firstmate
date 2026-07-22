#!/usr/bin/env bash
# Deterministic return-catch-up gate regression.
#
# Covers the second half of the 2026-07-14 incident: an away-mode blocked event
# survived in durable state, but the ordinary return request could proceed to
# Bearings before Firstmate owned remediation. The shared script now stops,
# drains, preserves evidence, and refuses ordinary work until every live open
# `blocked:` event is resolved or durably reclassified.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-afk-return-tests)

install_runner() {  # <case-dir>
  local dir=$1
  mkdir -p "$dir/bin" "$dir/home/state" "$dir/home/data" "$dir/home/config"
  cp "$ROOT/bin/fm-afk-return.sh" "$dir/bin/"
  cp "$ROOT/bin/fm-wake-lib.sh" "$dir/bin/"
  cp "$ROOT/bin/fm-classify-lib.sh" "$dir/bin/"
  cp "$ROOT/bin/fm-backend.sh" "$dir/bin/"
  cat > "$dir/bin/fm-harness.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "${FM_TEST_HARNESS:-claude}"
SH
  cat > "$dir/bin/fm-daemon-launch.sh" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = afk-exit ] || exit 2
printf 'afk-exit\n' >> "$FM_HOME/exit.log"
if [ -e "$FM_HOME/state/.fail-afk-exit-once" ]; then
  rm -f "$FM_HOME/state/.fail-afk-exit-once"
  exit 1
fi
rm -f "$FM_HOME/state/.afk"
SH
  cat > "$dir/bin/fm-afk-launch.sh" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = stop ] || exit 2
printf 'stop\n' >> "$FM_HOME/stop.log"
rm -f "$FM_HOME/state/.afk-daemon-terminal" "$FM_HOME/state/.fake-daemon-live"
SH
  cat > "$dir/bin/fm-wake-drain.sh" <<'SH'
#!/usr/bin/env bash
file="$FM_HOME/state/.fake-drain"
[ -f "$file" ] && cat "$file"
: > "$file"
SH
  chmod +x "$dir/bin/"*.sh
}

run_return() {  # <case-dir> <mode>
  local dir=$1 mode=$2
  FM_HOME="$dir/home" FM_STATE_OVERRIDE="$dir/home/state" \
    FM_TEST_HARNESS="${FM_TEST_HARNESS:-claude}" FM_SUPERVISOR_BACKEND="${FM_TEST_BACKEND:-tmux}" \
    "$dir/bin/fm-afk-return.sh" "$mode" 2>&1
}

seed_live_blocker() {  # <case-dir> <backend> <key>
  local dir=$1 backend=$2 key=$3 target
  case "$backend" in
    tmux) target='synthetic:fm-repair-task' ;;
    herdr) target='fm-lab-synthetic:w1:p2' ;;
  esac
  cat > "$dir/home/state/repair-task.meta" <<EOF
window=$target
backend=$backend
kind=ship
EOF
  printf 'blocked [key=%s]: firstmate can refresh the synthetic token\n' "$key" > "$dir/home/state/repair-task.status"
}

test_return_gate_orders_catchup_before_bearings() {
  local dir out rc gate wake_count
  dir="$TMP_ROOT/ordering"
  install_runner "$dir"
  seed_live_blocker "$dir" herdr synthetic-dependency
  date +%s > "$dir/home/state/.afk"
  printf 'repair-task.status: blocked synthetic dependency\n' > "$dir/home/state/.subsuper-escalations"
  : > "$dir/home/state/.subsuper-escalations-urgent"
  printf 'fm away-mode inject WEDGED: 4555s undelivered\n' > "$dir/home/state/.subsuper-inject-wedged"
  {
    printf '1784074271\t2\tsignal\trepair-task.status\tsignal: synthetic status\n'
    printf 'wake annotation: latest wake-EVENT observed at drain, not current state: repair-task.status: blocked synthetic dependency\n'
  } > "$dir/home/state/.fake-drain"

  set +e
  out=$(run_return "$dir" begin)
  rc=$?
  set -e
  [ "$rc" -eq 3 ] || fail "return begin should gate on a live blocker (rc=$rc): $out"
  gate="$dir/home/state/.afk-return-catchup"
  [ -s "$gate" ] || fail "return begin did not persist its fail-closed catch-up gate"
  assert_contains "$out" 'firstmate-actionable blocker: repair-task [key=synthetic-dependency]' "return output did not assign blocker remediation to Firstmate"
  grep -F $'evidence\twake\t1784074271' "$gate" >/dev/null || fail "drained wake evidence was not retained in the durable gate"
  grep -F $'evidence\twake\twake annotation: latest wake-EVENT observed at drain, not current state: repair-task.status: blocked synthetic dependency' "$gate" >/dev/null \
    || fail "the separate drain annotation was not retained as away-return evidence"
  grep -F $'evidence\twedge\tfm away-mode inject WEDGED: 4555s undelivered' "$gate" >/dev/null || fail "wedge evidence was not retained in the durable gate"
  grep -F $'evidence\tescalation\trepair-task.status: blocked synthetic dependency' "$gate" >/dev/null || fail "buffered escalation evidence was not retained in the durable gate"
  [ "$(wc -l < "$dir/home/exit.log" | tr -d ' ')" -eq 1 ] || fail "return begin did not clear the away-mode style flag exactly once"

  # The exact incident regression: Bearings is an ordinary request and must
  # refuse before reading/rendering while this shared gate remains open.
  set +e
  out=$(FM_HOME="$dir/home" FM_STATE_OVERRIDE="$dir/home/state" "$ROOT/bin/fm-bearings-snapshot.sh" --json 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq 3 ] || fail "Bearings should refuse behind the return gate (rc=$rc): $out"
  assert_contains "$out" 'return catch-up is pending' "Bearings refusal did not point to the shared return owner"

  # Restart/re-entry is idempotent: no second stop, no duplicate catch-up line,
  # and the same unresolved blocker remains authoritative.
  set +e
  out=$(run_return "$dir" begin)
  rc=$?
  set -e
  [ "$rc" -eq 3 ] || fail "repeated begin should preserve the unresolved gate"
  [ "$(wc -l < "$dir/home/exit.log" | tr -d ' ')" -eq 1 ] || fail "repeated begin cleared an already-cleared style flag twice"
  wake_count=$(grep -c $'^evidence\twake\t1784074271' "$gate" || true)
  [ "$wake_count" -eq 1 ] || fail "repeated begin duplicated retained wake evidence ($wake_count copies)"
  [ "$(grep -c $'^evidence\twedge\t' "$gate" || true)" -eq 1 ] || fail "repeated begin duplicated retained wedge evidence"
  [ "$(grep -c $'^evidence\tescalation\t' "$gate" || true)" -eq 1 ] || fail "repeated begin duplicated retained escalation evidence"

  printf 'resolved [key=synthetic-dependency]: refreshed the synthetic token and resumed the task\n' >> "$dir/home/state/repair-task.status"
  out=$(run_return "$dir" check) || fail "resolved blocker did not clear return catch-up: $out"
  assert_contains "$out" 'catch-up clear' "successful check did not announce that ordinary work may proceed"
  [ ! -e "$gate" ] || fail "successful check left the return gate behind"
  [ ! -e "$dir/home/state/.subsuper-escalations" ] || fail "successful check left delivered escalation state behind"
  [ ! -e "$dir/home/state/.subsuper-escalations-urgent" ] || fail "successful check left escalation urgency state behind"
  [ ! -e "$dir/home/state/.subsuper-inject-wedged" ] || fail "successful check left the wedge marker behind"

  out=$(run_return "$dir" check) || fail "an already-clear repeated check should be idempotent: $out"
  [ ! -e "$gate" ] || fail "idempotent clear check recreated a gate"
  pass "return catch-up precedes Bearings, owns live blocker remediation, preserves evidence once, and clears idempotently"
}

test_explicit_reclassification_requires_durable_reason() {
  local backend dir out rc
  for backend in tmux herdr; do
    dir="$TMP_ROOT/reclassify-$backend"
    install_runner "$dir"
    seed_live_blocker "$dir" "$backend" vendor-release
    date +%s > "$dir/home/state/.afk"
    : > "$dir/home/state/.fake-drain"
    set +e
    out=$(run_return "$dir" begin)
    rc=$?
    set -e
    [ "$rc" -eq 3 ] || fail "$backend blocker did not open the return gate"

    # A pause alone cannot mask the keyed blocker. The old concern must be
    # explicitly resolved with the durable reclassification reason first.
    printf 'paused [key=vendor-release]: waiting for the synthetic vendor window\n' >> "$dir/home/state/repair-task.status"
    set +e
    out=$(run_return "$dir" check)
    rc=$?
    set -e
    [ "$rc" -eq 3 ] || fail "$backend pause silently masked an unresolved blocked key"

    printf 'resolved [key=vendor-release]: reclassified as an external wait because the synthetic vendor owns the next event\n' >> "$dir/home/state/repair-task.status"
    printf 'paused [key=vendor-release]: waiting for the synthetic vendor window\n' >> "$dir/home/state/repair-task.status"
    out=$(run_return "$dir" check) || fail "$backend durable reclassification did not clear the return gate: $out"
    [ ! -e "$dir/home/state/.afk-return-catchup" ] || fail "$backend reclassification left a gate behind"
  done
  pass "tmux and Herdr blockers require the same explicit durable reclassification before ordinary work"
}

test_captain_decision_does_not_masquerade_as_firstmate_blocker() {
  local dir out
  dir="$TMP_ROOT/captain-decision"
  install_runner "$dir"
  cat > "$dir/home/state/decision-task.meta" <<'EOF'
window=synthetic:fm-decision-task
backend=tmux
kind=ship
EOF
  printf 'needs-decision [key=api-shape]: captain must choose the synthetic API shape\n' > "$dir/home/state/decision-task.status"
  date +%s > "$dir/home/state/.afk"
  printf '1784074271\t1\tsignal\tdecision-task.status\tsignal: synthetic decision\n' > "$dir/home/state/.fake-drain"
  out=$(run_return "$dir" begin) || fail "captain-owned decision should not be treated as a firstmate blocker: $out"
  assert_contains "$out" 'catch-up wake:' "captain-owned decision wake was not surfaced in catch-up"
  [ ! -e "$dir/home/state/.afk-return-catchup" ] || fail "captain-owned decision incorrectly opened a firstmate blocker gate"
  pass "captain-owned needs-decision remains reportable without masquerading as a firstmate-actionable blocker"
}

test_away_reentry_refuses_pending_return_gate() {
  local dir out rc
  dir="$TMP_ROOT/reentry"
  mkdir -p "$dir/home/state" "$dir/home/data" "$dir/home/config"
  printf 'schema\tfm-afk-return.v1\nphase\tblocked\n' > "$dir/home/state/.afk-return-catchup"
  set +e
  out=$(FM_HOME="$dir/home" FM_STATE_OVERRIDE="$dir/home/state" "$ROOT/bin/fm-afk-launch.sh" start-native 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "away re-entry succeeded while return catch-up was pending"
  assert_contains "$out" 'return catch-up is still pending' "away re-entry refusal did not explain the pending owner"
  [ ! -e "$dir/home/state/.afk" ] || fail "away re-entry wrote .afk despite the pending return gate"
  pass "away-mode re-entry fails closed while the prior return catch-up is pending"
}

test_check_retries_failed_style_flag_clear() {
  local dir gate out rc
  dir="$TMP_ROOT/flag-clear-retry"
  install_runner "$dir"
  gate="$dir/home/state/.afk-return-catchup"
  date +%s > "$dir/home/state/.afk"
  touch "$dir/home/state/.fail-afk-exit-once"

  set +e
  out=$(run_return "$dir" begin)
  rc=$?
  set -e
  [ "$rc" -eq 3 ] || fail "a failed style-flag clear should keep return catch-up gated (rc=$rc): $out"
  [ -e "$gate" ] || fail "a failed style-flag clear cleared the return gate"
  [ -e "$dir/home/state/.afk" ] || fail "a failed style-flag clear removed the flag anyway (must retry, not partially succeed)"

  out=$(run_return "$dir" check) || fail "check did not retry the failed style-flag clear: $out"
  [ ! -e "$dir/home/state/.afk" ] || fail "successful check left the away-mode style flag behind"
  [ ! -e "$gate" ] || fail "successful style-flag-clear retry left the return gate behind"
  [ "$(wc -l < "$dir/home/exit.log" | tr -d ' ')" -eq 2 ] || fail "check did not retry the style-flag clear exactly once"
  pass "check retries a failed style-flag clear and keeps catch-up gated until success"
}

test_supported_return_preserves_daemon() {
  local dir out
  dir="$TMP_ROOT/supported-return"
  install_runner "$dir"
  date +%s > "$dir/home/state/.afk"
  : > "$dir/home/state/.afk-daemon-terminal"
  : > "$dir/home/state/.fake-daemon-live"
  out=$(run_return "$dir" begin) || fail "supported return should clear cleanly: $out"
  [ ! -e "$dir/home/state/.afk" ] || fail "supported return left the away style flag behind"
  [ -e "$dir/home/state/.afk-daemon-terminal" ] || fail "supported return stopped the daemon terminal"
  [ -e "$dir/home/state/.fake-daemon-live" ] || fail "supported return stopped the live daemon fixture"
  [ ! -e "$dir/home/stop.log" ] || fail "supported return called the legacy daemon stop"
  [ "$(cat "$dir/home/exit.log")" = afk-exit ] || fail "supported return did not clear the style flag"
  pass "supported return clears delivery style without stopping the daemon"
}

test_unflipped_return_stops_daemon() {
  local dir out
  dir="$TMP_ROOT/unflipped-return"
  install_runner "$dir"
  date +%s > "$dir/home/state/.afk"
  : > "$dir/home/state/.afk-daemon-terminal"
  : > "$dir/home/state/.fake-daemon-live"
  out=$(FM_TEST_HARNESS=pi run_return "$dir" begin) || fail "unflipped return should clear cleanly: $out"
  [ ! -e "$dir/home/state/.afk" ] || fail "unflipped return left the away style flag behind"
  [ ! -e "$dir/home/state/.afk-daemon-terminal" ] || fail "unflipped return retained the daemon terminal"
  [ ! -e "$dir/home/state/.fake-daemon-live" ] || fail "unflipped return retained the live daemon fixture"
  [ "$(cat "$dir/home/stop.log")" = stop ] || fail "unflipped return did not stop the daemon"
  [ "$(cat "$dir/home/exit.log")" = afk-exit ] || fail "unflipped return did not clear the style flag"
  pass "unflipped return stops the legacy daemon before clearing delivery style"
}

test_return_gate_orders_catchup_before_bearings
test_explicit_reclassification_requires_durable_reason
test_captain_decision_does_not_masquerade_as_firstmate_blocker
test_away_reentry_refuses_pending_return_gate
test_check_retries_failed_style_flag_clear
test_supported_return_preserves_daemon
test_unflipped_return_stops_daemon
