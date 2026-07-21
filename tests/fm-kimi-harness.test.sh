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
printf 'tmux %s\n' "$*" >> "$log"
case "${1:-}" in
  capture-pane)
    if [ "${FM_FAKE_KIMI_POST_PASTE_CAPTURE_FAIL:-0}" = 1 ] \
      && [ -n "${FM_FAKE_KIMI_BRIEF_PASTED:-}" ] \
      && [ -e "$FM_FAKE_KIMI_BRIEF_PASTED" ]; then
      exit 1
    fi
    # A ready, empty kimi composer: dark truecolor border + default-fg `>`.
    printf ' \033[38;2;90;90;90m\xe2\x94\x82\033[39m > \033[7m \033[0m  \033[38;2;90;90;90m\xe2\x94\x82\033[39m\n'
    exit 0 ;;
  display-message) printf 'firstmate\n'; exit 0 ;;
  load-buffer) echo "load-buffer $*" >> "$log"; exit 0 ;;
  paste-buffer)
    echo "paste-buffer $*" >> "$log"
    [ -z "${FM_FAKE_KIMI_BRIEF_PASTED:-}" ] || : > "$FM_FAKE_KIMI_BRIEF_PASTED"
    exit 0 ;;
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
  doctor)
    [ -z "${FM_FAKE_KIMI_DOCTOR_LOG:-}" ] || printf 'doctor\n' >> "$FM_FAKE_KIMI_DOCTOR_LOG"
    exit "${FM_FAKE_KIMI_DOCTOR_EXIT:-0}"
    ;;
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

run_raw_kimi_spawn() {
  local home=$1 proj=$2 wt=$3 fakebin=$4 kimi_home=$5 id=$6
  shift 6
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    FM_FAKE_TMUX_LOG="${FM_FAKE_TMUX_LOG:-/dev/null}" \
    KIMI_CODE_HOME="$kimi_home" PATH="$fakebin:$PATH" \
    "$SPAWN" "$id" "$proj" "$@" 2>&1
}

quote_for_shell() {
  printf "'"
  printf '%s' "$1" | sed "s/'/'\\\\''/g"
  printf "'"
}

toml_basic_string_escape() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

test_kimi_preflight_refuses_before_task_resources() {
  local rec case_dir home proj wt fakebin kimi_home id out status log
  rec=$(make_spawn_case preflight-cli)
  IFS='|' read -r case_dir home proj wt fakebin kimi_home id <<EOF
$rec
EOF
  log="$case_dir/tmux.log"
  : > "$log"
  rm -f "$fakebin/kimi"
  out=$(PATH="$fakebin:/usr/bin:/bin:/usr/sbin:/sbin" FM_FAKE_TMUX_LOG="$log" run_kimi_spawn "$home" "$proj" "$wt" "$fakebin" "$kimi_home" "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "a kimi spawn without the CLI must be refused"
  assert_contains "$out" "kimi is not on PATH" "missing kimi CLI refusal message missing"
  assert_absent "$home/state/$id.meta" "missing kimi CLI wrote task metadata"
  assert_no_grep 'new-window' "$log" "missing kimi CLI created a tmux task window"

  rec=$(make_spawn_case preflight-config)
  IFS='|' read -r case_dir home proj wt fakebin kimi_home id <<EOF
$rec
EOF
  log="$case_dir/tmux.log"
  : > "$log"
  rm -f "$kimi_home/config.toml"
  out=$(FM_FAKE_TMUX_LOG="$log" run_kimi_spawn "$home" "$proj" "$wt" "$fakebin" "$kimi_home" "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "a kimi spawn without config.toml must be refused"
  assert_contains "$out" "kimi is not initialized" "missing kimi config refusal message missing"
  assert_absent "$home/state/$id.meta" "missing kimi config wrote task metadata"
  assert_no_grep 'new-window' "$log" "missing kimi config created a tmux task window"
  pass "kimi preflight refuses missing CLI and config before task resources"
}

test_kimi_creates_missing_state_before_metadata() {
  local rec case_dir home proj wt fakebin kimi_home id out status
  rec=$(make_spawn_case missing-state)
  IFS='|' read -r case_dir home proj wt fakebin kimi_home id <<EOF
$rec
EOF
  rm -rf "$home/state"
  out=$(run_kimi_spawn "$home" "$proj" "$wt" "$fakebin" "$kimi_home" "$id")
  status=$?
  expect_code 0 "$status" "kimi spawn should create a missing state directory: $out"
  assert_present "$home/state/$id.meta" "kimi spawn did not persist metadata in a new state directory"
  pass "kimi creates the state directory before writing metadata"
}

test_kimi_hook_requires_registered_token() {
  local rec case_dir home proj wt fakebin kimi_home canonical_kimi_home id out status hook token target evil evil_target
  rec=$(make_spawn_case hook-auth)
  IFS='|' read -r case_dir home proj wt fakebin kimi_home id <<EOF
$rec
EOF
  canonical_kimi_home=$(cd "$kimi_home" && pwd -P)
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
  assert_grep "kimi_home=$canonical_kimi_home" "$home/state/$id.meta" "kimi meta did not record its resolved home"

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
  local rec case_dir home proj wt second_wt fakebin kimi_home id second_id out status count log
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

  second_id="${id%x1}x2"
  second_wt="$case_dir/wt-second"
  mkdir -p "$home/data/$second_id"
  printf 'brief line one\nbrief line two\n' > "$home/data/$second_id/brief.md"
  git -C "$proj" worktree add --quiet -b "fm/$second_id" "$second_wt"
  out=$(run_kimi_spawn "$home" "$proj" "$second_wt" "$fakebin" "$kimi_home" "$second_id")
  status=$?
  expect_code 0 "$status" "second kimi spawn should succeed: $out"
  count=$(grep -c 'hooks/fm-turn-end.sh' "$kimi_home/config.toml")
  [ "$count" -eq 1 ] || fail "config.toml hook append is not idempotent (found $count entries)"
  pass "kimi config append is idempotent and the brief goes over as a bracketed paste"
}

test_kimi_hook_detection_requires_active_firstmate_stanza() {
  local rec case_dir home proj wt fakebin kimi_home id doctor_log out status hook_count
  rec=$(make_spawn_case hook-detection)
  IFS='|' read -r case_dir home proj wt fakebin kimi_home id <<EOF
$rec
EOF
  doctor_log="$case_dir/kimi-doctor.log"
  cat >> "$kimi_home/config.toml" <<'EOF'
# historical reference: hooks/fm-turn-end.sh
[[hooks]]
event = "Stop"
command = "bash /tmp/other/hooks/fm-turn-end.sh"
timeout = 5
EOF
  out=$(FM_FAKE_KIMI_DOCTOR_LOG="$doctor_log" run_kimi_spawn "$home" "$proj" "$wt" "$fakebin" "$kimi_home" "$id")
  status=$?
  expect_code 0 "$status" "kimi spawn should install its hook after unrelated references: $out"
  hook_count=$(grep -c '^\[\[hooks\]\]$' "$kimi_home/config.toml")
  [ "$hook_count" -eq 2 ] || fail "kimi config detection treated a comment or unrelated hook as its active hook"
  assert_grep '# firstmate-owned turn-end hook:' "$kimi_home/config.toml" "kimi did not append its owned hook stanza"
  grep -qx 'doctor' "$doctor_log" || fail "kimi did not validate the appended owned hook stanza"
  pass "kimi hook detection requires an active firstmate hook stanza"
}

test_kimi_hook_command_escapes_toml() {
  local rec case_dir home proj wt fakebin kimi_home canonical_kimi_home id special_kimi_home out status command expected
  rec=$(make_spawn_case quoted-home)
  IFS='|' read -r case_dir home proj wt fakebin kimi_home id <<EOF
$rec
EOF
  special_kimi_home="${kimi_home}'\"quoted"
  mv "$kimi_home" "$special_kimi_home"
  kimi_home=$special_kimi_home
  canonical_kimi_home=$(cd "$kimi_home" && pwd -P)
  out=$(run_kimi_spawn "$home" "$proj" "$wt" "$fakebin" "$kimi_home" "$id")
  status=$?
  expect_code 0 "$status" "kimi spawn should support quote characters in KIMI_CODE_HOME: $out"
  command="bash $(quote_for_shell "$canonical_kimi_home/hooks/fm-turn-end.sh")"
  expected=$(printf 'command = "%s"' "$(toml_basic_string_escape "$command")")
  assert_grep "$expected" "$kimi_home/config.toml" "kimi hook command was not TOML-escaped"
  pass "kimi hook command escapes quote characters for TOML"
}

test_kimi_pointer_symlink_is_refused() {
  local rec case_dir home proj wt fakebin kimi_home id sentinel out status
  rec=$(make_spawn_case pointer-symlink)
  IFS='|' read -r case_dir home proj wt fakebin kimi_home id <<EOF
$rec
EOF
  sentinel="$case_dir/sentinel"
  printf 'preserved\n' > "$sentinel"
  ln -s "$sentinel" "$wt/.fm-kimi-turnend"
  out=$(run_kimi_spawn "$home" "$proj" "$wt" "$fakebin" "$kimi_home" "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "kimi spawn must refuse a symlinked token pointer"
  assert_contains "$out" "worktree pointer must not be a symlink" "kimi did not identify the unsafe pointer"
  assert_grep 'preserved' "$sentinel" "kimi spawn overwrote the symlink target"
  pass "kimi refuses symlinked worktree token pointers"
}

test_kimi_relative_home_is_canonicalized_for_launch() {
  local rec case_dir home proj wt fakebin kimi_home canonical_kimi_home quoted_kimi_home id relative_home log out status
  rec=$(make_spawn_case relative-home)
  IFS='|' read -r case_dir home proj wt fakebin kimi_home id <<EOF
$rec
EOF
  canonical_kimi_home=$(cd "$kimi_home" && pwd -P)
  quoted_kimi_home=$(quote_for_shell "$canonical_kimi_home")
  relative_home=kimi
  log="$case_dir/tmux.log"
  : > "$log"
  out=$(cd "$case_dir" && FM_FAKE_TMUX_LOG="$log" run_kimi_spawn "$home" "$proj" "$wt" "$fakebin" "$relative_home" "$id")
  status=$?
  expect_code 0 "$status" "kimi spawn should accept a relative KIMI_CODE_HOME: $out"
  assert_grep "kimi_home=$canonical_kimi_home" "$home/state/$id.meta" "kimi metadata did not record the canonical home"
  assert_grep "KIMI_CODE_HOME=$quoted_kimi_home" "$log" "kimi launch did not receive the canonical home"
  pass "kimi canonicalizes a relative home before launch"
}

test_kimi_config_append_redirection_failure_aborts_with_recovery_metadata() {
  local rec case_dir home proj wt fakebin kimi_home id out status
  rec=$(make_spawn_case config-append-redirection)
  IFS='|' read -r case_dir home proj wt fakebin kimi_home id <<EOF
$rec
EOF
  chmod 444 "$kimi_home/config.toml"
  out=$(run_kimi_spawn "$home" "$proj" "$wt" "$fakebin" "$kimi_home" "$id")
  status=$?
  chmod 600 "$kimi_home/config.toml"
  [ "$status" -ne 0 ] || fail "kimi spawn should abort when config.toml cannot be appended: $out"
  assert_contains "$out" "config backup retained after restoration failed" "kimi config append failure did not retain its backup after restoration failed"
  assert_not_contains "$out" "spawned $id" "kimi reported spawn success after a config append redirection failure"
  assert_present "$home/state/$id.meta" "kimi config append redirection failure did not preserve task metadata for teardown"
  pass "kimi config append redirection failure aborts with recovery metadata"
}

test_kimi_doctor_failure_restores_config_and_aborts() {
  local rec case_dir home proj wt fakebin kimi_home id target backup out status token
  rec=$(make_spawn_case doctor-fail)
  IFS='|' read -r case_dir home proj wt fakebin kimi_home id <<EOF
$rec
EOF
  target="$kimi_home/managed-config.toml"
  mv "$kimi_home/config.toml" "$target"
  ln -s "${target##*/}" "$kimi_home/config.toml"
  out=$(FM_FAKE_KIMI_DOCTOR_EXIT=1 run_kimi_spawn "$home" "$proj" "$wt" "$fakebin" "$kimi_home" "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "kimi spawn should abort when kimi doctor rejects the config append"
  assert_contains "$out" "config restored from backup" "doctor failure did not report the restore"
  [ -L "$kimi_home/config.toml" ] || fail "doctor failure replaced the managed config.toml symlink"
  assert_no_grep 'hooks/fm-turn-end.sh' "$target" "rejected hook append was left in config.toml"
  backup=$(find "$kimi_home" -maxdepth 1 -type f -name 'config.toml.fm-prehook.*' -print -quit)
  [ -z "$backup" ] || fail "config backup file was left behind"
  assert_present "$home/state/$id.meta" "doctor failure did not preserve task metadata for teardown"
  token=$(cat "$home/state/$id.kimi-turnend-token")
  env -u KIMI_CODE_HOME FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    PATH="$fakebin:$PATH" "$TEARDOWN" "$id" --force >/dev/null 2>&1 \
    || fail "kimi doctor failure metadata could not be torn down"
  assert_absent "$kimi_home/hooks/fm-turn-end.d/$token" "doctor failure token survived metadata-based teardown"
  pass "kimi doctor failure restores a managed config.toml symlink with recoverable state"
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

  env -u KIMI_CODE_HOME FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    PATH="$fakebin:$PATH" \
    "$TEARDOWN" "$id" --force >/dev/null 2>&1 \
    || fail "kimi teardown failed"

  assert_absent "$wt/.fm-kimi-turnend" "kimi pointer survived teardown"
  assert_absent "$kimi_home/hooks/fm-turn-end.d/$token" "kimi auth token survived teardown"
  assert_absent "$home/state/$id.kimi-turnend-token" "kimi state token survived teardown"
  pass "kimi teardown removes pointer and token state"
}

test_kimi_unverified_brief_submission_aborts() {
  local rec case_dir home proj wt fakebin kimi_home id out status pasted
  rec=$(make_spawn_case brief-unknown)
  IFS='|' read -r case_dir home proj wt fakebin kimi_home id <<EOF
$rec
EOF
  pasted="$case_dir/brief-pasted"
  out=$(FM_FAKE_KIMI_POST_PASTE_CAPTURE_FAIL=1 FM_FAKE_KIMI_BRIEF_PASTED="$pasted" \
    run_kimi_spawn "$home" "$proj" "$wt" "$fakebin" "$kimi_home" "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "an unverified kimi brief submission must abort the spawn"
  assert_contains "$out" "brief submission could not be verified" "kimi did not report an unverified brief"
  assert_contains "$out" "inspect window" "kimi unverified brief message omitted the window"
  assert_not_contains "$out" "spawned $id" "kimi reported spawn success after an unverified brief"
  pass "kimi aborts when the pasted brief cannot be verified"
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
  assert_contains "$out" "bracketed paste to arrive as one atomic turn" "kimi non-tmux refusal message missing"
  assert_contains "$out" "backend=zellij" "kimi non-tmux refusal did not name the offending backend"
  pass "kimi spawn on a non-tmux backend is refused loudly"
}

test_raw_kimi_secondmate_scope_is_exempt_but_backend_gate_is_not() {
  local rec case_dir home proj wt fakebin kimi_home id out status
  rec=$(make_spawn_case raw-scope)
  IFS='|' read -r case_dir home proj wt fakebin kimi_home id <<EOF
$rec
EOF
  out=$(run_raw_kimi_spawn "$home" "$proj" "$wt" "$fakebin" "$kimi_home" "$id" "kimi --yolo")
  status=$?
  expect_code 0 "$status" "a raw kimi launch should retain kimi hook and brief behavior: $out"
  assert_contains "$out" "spawned $id harness=kimi" "raw kimi launch did not report success"
  assert_grep 'hooks/fm-turn-end.sh' "$kimi_home/config.toml" "raw kimi launch did not install the turn-end hook"

  rec=$(make_spawn_case raw-secondmate)
  IFS='|' read -r case_dir home proj wt fakebin kimi_home id <<EOF
$rec
EOF
  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" \
    KIMI_CODE_HOME="$kimi_home" PATH="$fakebin:$PATH" \
    "$SPAWN" "$id" "kimi --yolo" --secondmate 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "raw kimi --secondmate should proceed to normal secondmate validation"
  assert_contains "$out" "no firstmate home supplied or registered" "raw kimi --secondmate did not reach normal validation"
  assert_not_contains "$out" "crewmate/scout duty only" "raw kimi --secondmate hit the template-only scope gate"

  rec=$(make_spawn_case raw-backend)
  IFS='|' read -r case_dir home proj wt fakebin kimi_home id <<EOF
$rec
EOF
  out=$(run_raw_kimi_spawn "$home" "$proj" "$wt" "$fakebin" "$kimi_home" "$id" "kimi --yolo" --backend zellij)
  status=$?
  [ "$status" -ne 0 ] || fail "raw kimi on a non-tmux backend must still be refused - the brief-delivery gate is not scope-exempt"
  assert_contains "$out" "bracketed paste to arrive as one atomic turn" "raw kimi on zellij did not hit the backend brief-delivery gate"
  assert_contains "$out" "backend=zellij" "raw kimi on zellij refusal did not name the offending backend"
  pass "raw kimi launches bypass only the secondmate-scope gate, never the backend brief-delivery gate"
}

test_kimi_config_lock_waits_and_reclaims_stale_locks() {
  local rec case_dir home proj wt fakebin kimi_home id lock out_file pid status dead
  rec=$(make_spawn_case config-lock-held)
  IFS='|' read -r case_dir home proj wt fakebin kimi_home id <<EOF
$rec
EOF
  lock="$kimi_home/config.toml.fm-prehook.lock"
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" . "$ROOT/bin/fm-wake-lib.sh"
  fm_lock_try_acquire "$lock" || fail "could not hold the kimi config lock"
  out_file="$case_dir/locked.out"
  run_kimi_spawn "$home" "$proj" "$wt" "$fakebin" "$kimi_home" "$id" > "$out_file" &
  pid=$!
  sleep 0.2
  assert_no_grep 'hooks/fm-turn-end.sh' "$kimi_home/config.toml" "kimi wrote config.toml while its lock was held"
  fm_lock_release "$lock"
  wait "$pid"
  status=$?
  expect_code 0 "$status" "kimi spawn should continue after the config lock releases: $(cat "$out_file")"
  assert_absent "$lock" "kimi config lock was left after a successful append"

  rec=$(make_spawn_case config-lock-stale)
  IFS='|' read -r case_dir home proj wt fakebin kimi_home id <<EOF
$rec
EOF
  lock="$kimi_home/config.toml.fm-prehook.lock"
  dead=999999
  while kill -0 "$dead" 2>/dev/null; do
    dead=$((dead + 1))
  done
  mkdir "$lock"
  printf '%s\n' "$dead" > "$lock/pid"
  touch -t 200001010000 "$lock"
  out=$(run_kimi_spawn "$home" "$proj" "$wt" "$fakebin" "$kimi_home" "$id")
  status=$?
  expect_code 0 "$status" "kimi spawn should reclaim a stale config lock: $out"
  assert_absent "$lock" "kimi stale config lock was not reclaimed and released"
  pass "kimi config append waits for live locks and reclaims stale locks"
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

test_kimi_preflight_refuses_before_task_resources
test_kimi_creates_missing_state_before_metadata
test_kimi_hook_requires_registered_token
test_kimi_config_append_is_idempotent_and_brief_is_pasted
test_kimi_hook_detection_requires_active_firstmate_stanza
test_kimi_hook_command_escapes_toml
test_kimi_pointer_symlink_is_refused
test_kimi_relative_home_is_canonicalized_for_launch
test_kimi_config_append_redirection_failure_aborts_with_recovery_metadata
test_kimi_doctor_failure_restores_config_and_aborts
test_kimi_teardown_removes_pointer_and_token
test_kimi_unverified_brief_submission_aborts
test_kimi_secondmate_spawn_is_refused
test_kimi_non_tmux_backend_is_refused
test_raw_kimi_secondmate_scope_is_exempt_but_backend_gate_is_not
test_kimi_config_lock_waits_and_reclaims_stale_locks
test_kimi_hook_survives_shellcheck_shape
