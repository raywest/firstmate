#!/usr/bin/env bash
# Behavior tests for the kimi harness adapter: guarded turn-end hook
# authentication, the idempotent doctor-validated config.toml append, teardown
# cleanup, brief delivery wiring, and the crewmate/scout-only scope refusals.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TEARDOWN="$ROOT/bin/fm-teardown.sh"
TMP_ROOT=$(fm_test_tmproot fm-kimi-harness)

# Fake tmux for a kimi spawn: beyond the grok fake, it must serve a numeric
# cursor_y and a bordered kimi composer row so fm-spawn's deliver_kimi_brief
# sees a ready composer, and it records paste-buffer/send-keys calls so the
# test can assert the brief went over as a bracketed paste.
make_spawn_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
log="${FM_FAKE_TMUX_LOG:-/dev/null}"
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
  *"#{cursor_y}"*) printf '0\n'; exit 0 ;;
esac
case "${1:-}" in
  capture-pane)
    # A ready, empty kimi composer: dark truecolor border + default-fg `>`.
    printf ' \033[38;2;90;90;90m\xe2\x94\x82\033[39m > \033[7m \033[0m  \033[38;2;90;90;90m\xe2\x94\x82\033[39m\n'
    exit 0 ;;
  display-message) printf 'firstmate\n'; exit 0 ;;
  load-buffer) echo "load-buffer $*" >> "$log"; exit 0 ;;
  paste-buffer) echo "paste-buffer $*" >> "$log"; exit 0 ;;
  send-keys) echo "send-keys $*" >> "$log"; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|kill-window|set-window-option) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  # Fake kimi CLI: `doctor` honors FM_FAKE_KIMI_DOCTOR_EXIT so the fail-closed
  # config-restore path can be exercised.
  cat > "$fakebin/kimi" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  doctor) exit "${FM_FAKE_KIMI_DOCTOR_EXIT:-0}" ;;
esac
exit 0
SH
  chmod +x "$fakebin/kimi"
  fm_fake_exit0 "$fakebin" treehouse gh-axi gh
  printf '%s\n' "$fakebin"
}

make_spawn_case() {
  local name=$1 case_dir home proj wt fakebin kimi_home id
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  kimi_home="$case_dir/kimi"
  id="kimi-$name-x1"
  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config" "$kimi_home"
  printf 'brief line one\nbrief line two\n' > "$home/data/$id/brief.md"
  printf 'default_model = "kimi-code/k3"\n' > "$kimi_home/config.toml"
  fm_git_worktree "$proj" "$wt" "fm/$id"
  touch "$home/state/.last-watcher-beat"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin|$kimi_home|$id"
}

run_kimi_spawn() {
  local home=$1 proj=$2 wt=$3 fakebin=$4 kimi_home=$5 id=$6
  shift 6
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    FM_FAKE_TMUX_LOG="${FM_FAKE_TMUX_LOG:-/dev/null}" \
    KIMI_CODE_HOME="$kimi_home" PATH="$fakebin:$PATH" \
    "$SPAWN" "$id" "$proj" kimi "$@" 2>&1
}

test_kimi_hook_requires_registered_token() {
  local rec case_dir home proj wt fakebin kimi_home id out status hook token target evil evil_target
  rec=$(make_spawn_case hook-auth)
  IFS='|' read -r case_dir home proj wt fakebin kimi_home id <<EOF
$rec
EOF
  out=$(run_kimi_spawn "$home" "$proj" "$wt" "$fakebin" "$kimi_home" "$id")
  status=$?
  expect_code 0 "$status" "kimi spawn should succeed: $out"
  assert_contains "$out" "spawned $id harness=kimi" "kimi spawn did not report success"

  hook="$kimi_home/hooks/fm-turn-end.sh"
  assert_present "$hook" "kimi hook script was not installed"
  assert_grep 'token=' "$wt/.fm-kimi-turnend" "kimi pointer did not contain a token"
  target="$home/state/$id.turn-ended"
  assert_no_grep "$target" "$wt/.fm-kimi-turnend" "kimi pointer exposed the turn-end path"
  token=$(sed -n 's/^token=//p' "$wt/.fm-kimi-turnend")
  assert_present "$kimi_home/hooks/fm-turn-end.d/$token" "kimi auth registry entry was not written"
  assert_grep 'hooks/fm-turn-end.sh' "$kimi_home/config.toml" "config.toml did not get the [[hooks]] Stop append"

  # An unregistered workspace pointing a payload cwd at an arbitrary target must be a no-op.
  evil="$case_dir/evil"
  evil_target="$case_dir/evil-target.turn-ended"
  mkdir -p "$evil"
  printf '%s\n' "$evil_target" > "$evil/.fm-kimi-turnend"
  printf '{"hook_event_name":"Stop","cwd":"%s"}' "$evil" | KIMI_CODE_HOME="$kimi_home" bash "$hook"
  assert_absent "$evil_target" "old-style kimi pointer touched an arbitrary target"

  # A token below the first line must not authenticate.
  {
    printf '%s\n' 'ignored'
    printf 'token=%s\n' "$token"
  } > "$wt/.fm-kimi-turnend"
  printf '{"hook_event_name":"Stop","cwd":"%s"}' "$wt" | KIMI_CODE_HOME="$kimi_home" bash "$hook"
  assert_absent "$target" "kimi pointer accepted token outside the first line"

  # The registered pointer fires via the payload cwd.
  printf 'token=%s\n' "$token" > "$wt/.fm-kimi-turnend"
  printf '{"hook_event_name":"Stop","cwd":"%s"}' "$wt" | KIMI_CODE_HOME="$kimi_home" bash "$hook"
  assert_present "$target" "registered kimi pointer did not touch the task turn-end file"

  # It also fires from a bare cwd when the payload carries none (the fallback).
  rm -f "$target"
  (cd "$wt" && printf '' | KIMI_CODE_HOME="$kimi_home" bash "$hook")
  assert_present "$target" "kimi hook did not fall back to its own cwd without a payload"
  pass "kimi global hook requires a firstmate registry token"
}

test_kimi_config_append_is_idempotent_and_brief_is_pasted() {
  local rec case_dir home proj wt fakebin kimi_home id out status count log
  rec=$(make_spawn_case idempotent)
  IFS='|' read -r case_dir home proj wt fakebin kimi_home id <<EOF
$rec
EOF
  log="$case_dir/tmux.log"
  : > "$log"
  out=$(FM_FAKE_TMUX_LOG="$log" run_kimi_spawn "$home" "$proj" "$wt" "$fakebin" "$kimi_home" "$id")
  status=$?
  expect_code 0 "$status" "first kimi spawn should succeed: $out"
  grep -q 'load-buffer' "$log" || fail "kimi brief was not staged with tmux load-buffer"
  grep -q 'paste-buffer' "$log" || fail "kimi brief was not delivered with tmux paste-buffer"
  grep -q 'paste-buffer.*-p' "$log" || fail "kimi brief paste was not bracketed (-p)"

  rm -f "$home/state/$id.meta" "$home/state/$id.kimi-turnend-token"
  out=$(run_kimi_spawn "$home" "$proj" "$wt" "$fakebin" "$kimi_home" "$id" 2>&1) || true
  count=$(grep -c 'hooks/fm-turn-end.sh' "$kimi_home/config.toml")
  [ "$count" -eq 1 ] || fail "config.toml hook append is not idempotent (found $count entries)"
  pass "kimi config append is idempotent and the brief goes over as a bracketed paste"
}

test_kimi_doctor_failure_restores_config_and_aborts() {
  local rec case_dir home proj wt fakebin kimi_home id out status
  rec=$(make_spawn_case doctor-fail)
  IFS='|' read -r case_dir home proj wt fakebin kimi_home id <<EOF
$rec
EOF
  out=$(FM_FAKE_KIMI_DOCTOR_EXIT=1 run_kimi_spawn "$home" "$proj" "$wt" "$fakebin" "$kimi_home" "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "kimi spawn should abort when kimi doctor rejects the config append"
  assert_contains "$out" "config restored from backup" "doctor failure did not report the restore"
  assert_no_grep 'hooks/fm-turn-end.sh' "$kimi_home/config.toml" "rejected hook append was left in config.toml"
  assert_absent "$kimi_home/config.toml.fm-prehook-backup" "config backup file was left behind"
  pass "kimi doctor failure restores config.toml and aborts the spawn"
}

test_kimi_teardown_removes_pointer_and_token() {
  local rec case_dir home proj wt fakebin kimi_home id out status token
  rec=$(make_spawn_case teardown)
  IFS='|' read -r case_dir home proj wt fakebin kimi_home id <<EOF
$rec
EOF
  out=$(run_kimi_spawn "$home" "$proj" "$wt" "$fakebin" "$kimi_home" "$id")
  status=$?
  expect_code 0 "$status" "kimi spawn should succeed before teardown: $out"
  token=$(sed -n 's/^token=//p' "$wt/.fm-kimi-turnend")

  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    KIMI_CODE_HOME="$kimi_home" PATH="$fakebin:$PATH" \
    "$TEARDOWN" "$id" --force >/dev/null 2>&1 \
    || fail "kimi teardown failed"

  assert_absent "$wt/.fm-kimi-turnend" "kimi pointer survived teardown"
  assert_absent "$kimi_home/hooks/fm-turn-end.d/$token" "kimi auth token survived teardown"
  assert_absent "$home/state/$id.kimi-turnend-token" "kimi state token survived teardown"
  pass "kimi teardown removes pointer and token state"
}

test_kimi_secondmate_spawn_is_refused() {
  local rec case_dir home proj wt fakebin kimi_home id out status
  rec=$(make_spawn_case secondmate)
  IFS='|' read -r case_dir home proj wt fakebin kimi_home id <<EOF
$rec
EOF
  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" \
    KIMI_CODE_HOME="$kimi_home" PATH="$fakebin:$PATH" \
    "$SPAWN" "$id" kimi --secondmate 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "a kimi --secondmate spawn must be refused"
  assert_contains "$out" "crewmate/scout duty only" "kimi secondmate refusal message missing"
  pass "kimi --secondmate spawn is refused loudly"
}

test_kimi_non_tmux_backend_is_refused() {
  local rec case_dir home proj wt fakebin kimi_home id out status
  rec=$(make_spawn_case backend)
  IFS='|' read -r case_dir home proj wt fakebin kimi_home id <<EOF
$rec
EOF
  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" \
    KIMI_CODE_HOME="$kimi_home" PATH="$fakebin:$PATH" \
    "$SPAWN" "$id" "$proj" kimi --backend zellij 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "a kimi spawn on a non-tmux backend must be refused"
  assert_contains "$out" "tmux backend only" "kimi non-tmux refusal message missing"
  pass "kimi spawn on a non-tmux backend is refused loudly"
}

test_kimi_hook_survives_shellcheck_shape() {
  local rec case_dir home proj wt fakebin kimi_home id out status
  rec=$(make_spawn_case hookshape)
  IFS='|' read -r case_dir home proj wt fakebin kimi_home id <<EOF
$rec
EOF
  out=$(run_kimi_spawn "$home" "$proj" "$wt" "$fakebin" "$kimi_home" "$id")
  status=$?
  expect_code 0 "$status" "kimi spawn should succeed: $out"
  bash -n "$kimi_home/hooks/fm-turn-end.sh" || fail "generated kimi hook script does not parse"
  pass "generated kimi hook script parses cleanly"
}

test_kimi_hook_requires_registered_token
test_kimi_config_append_is_idempotent_and_brief_is_pasted
test_kimi_doctor_failure_restores_config_and_aborts
test_kimi_teardown_removes_pointer_and_token
test_kimi_secondmate_spawn_is_refused
test_kimi_non_tmux_backend_is_refused
test_kimi_hook_survives_shellcheck_shape
