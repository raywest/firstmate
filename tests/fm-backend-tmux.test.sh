#!/usr/bin/env bash
# tests/fm-backend-tmux.test.sh - unit tests for the tmux session-provider
# adapter's per-home default session name (bin/backends/tmux.sh,
# fm_backend_tmux_session_name / fm_backend_tmux_container_ensure).
#
# Context (data/fm-killsweep-scout-s3/report.md, referenced from AGENTS.md
# section 1): every firstmate home used to fall back to one hardcoded detached
# session name ("firstmate", and before that the even more generic "default"),
# a soft target for an unrelated tool's ambient `tmux kill-session` sharing the
# same tmux server, and a real collision when two homes on one machine both
# fell back to it. The fix derives a stable, home-unique default from
# bin/fm-backend-hometag-lib.sh (already shared with the cmux/zellij
# adapters), with FM_TMUX_SESSION as an explicit operator escape hatch.
#
# This suite is fake-tmux-CLI unit tests only (mirroring
# tests/fm-backend-zellij.test.sh's fakebin/command-log convention); the real
# tmux smoke test lives in tests/fm-backend-tmux-smoke.test.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$ROOT/bin/fm-backend.sh"

TMP_ROOT=$(fm_test_tmproot fm-backend-tmux-tests)

# tmux_expected_root_hash / tmux_expected_hometag: bash-only reimplementations
# of bin/fm-backend-hometag-lib.sh's fm_backend_hometag, mirroring
# tests/fm-backend-zellij.test.sh's identical zellij_expected_* helpers.
tmux_expected_root_hash() {  # <root>
  local root real
  root=$1
  real=$(cd "$root" && pwd -P) || return 1
  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$real" | shasum -a 256 | awk '{print substr($1,1,8)}'
  elif command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$real" | sha256sum | awk '{print substr($1,1,8)}'
  else
    printf '%s' "$real" | cksum | awk '{printf "%08x", $1}'
  fi
}

tmux_expected_hometag() {  # [home] [root]
  local home=${1:-$ROOT} root=${2:-$ROOT} marker id prefix
  marker="$home/.fm-secondmate-home"
  if [ -f "$marker" ]; then
    id=$(tr -d '[:space:]' < "$marker" 2>/dev/null)
    if [ -n "$id" ]; then
      prefix="2ndmate-$id"
    else
      prefix="firstmate"
    fi
  else
    prefix="firstmate"
  fi
  printf '%s-%s' "$prefix" "$(tmux_expected_root_hash "$root")"
}

tmux_expected_session_name() {  # [home] [root]
  printf 'fm-%s' "$(tmux_expected_hometag "${1:-}" "${2:-}")"
}

# make_tmux_fakebin: a `tmux` stub that logs every invocation (one line,
# unit-separated args, to $FM_TMUX_LOG) and reports session "$FM_TMUX_EXISTING"
# as already alive for has-session, so container_ensure's create-vs-reuse
# branch is directly observable. display-message -p '#S' answers with
# $FM_TMUX_CURRENT_SESSION (simulating "already inside tmux").
make_tmux_fakebin() {  # <dir> -> echoes fakebin dir
  local dir=$1 fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
LOG="${FM_TMUX_LOG:?}"
{
  for a in "$@"; do printf '\x1f%s' "$a"; done
  printf '\n'
} >> "$LOG"

case "${1:-}" in
  has-session)
    # args: has-session -t <name>
    [ "$3" = "${FM_TMUX_EXISTING:-}" ] && [ -n "${FM_TMUX_EXISTING:-}" ]
    exit $?
    ;;
  new-session)
    exit 0
    ;;
  display-message)
    printf '%s\n' "${FM_TMUX_CURRENT_SESSION:-}"
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"
  printf '%s' "$fb"
}

# --- fm_backend_tmux_session_name: determinism + home-uniqueness -----------

test_session_name_deterministic_for_same_home() {
  local dir out1 out2 expected
  dir="$TMP_ROOT/det-home"; mkdir -p "$dir"
  expected=$(tmux_expected_session_name "$dir")
  out1=$( FM_HOME="$dir" bash -c '. "$0/bin/fm-backend.sh"; fm_backend_source tmux; fm_backend_tmux_session_name' "$ROOT" )
  out2=$( FM_HOME="$dir" bash -c '. "$0/bin/fm-backend.sh"; fm_backend_source tmux; fm_backend_tmux_session_name' "$ROOT" )
  [ "$out1" = "$expected" ] || fail "session name should be $expected, got '$out1'"
  [ "$out1" = "$out2" ] || fail "session name must be deterministic across repeated calls for the same home (got '$out1' then '$out2')"
  pass "fm_backend_tmux_session_name: deterministic fm-<hometag> for the same FM_HOME, matching a fresh independent computation"
}

test_session_name_differs_for_distinct_homes() {
  local home root_one root_two out_one out_two
  home="$TMP_ROOT/two-homes"; mkdir -p "$home"
  root_one="$TMP_ROOT/root-one"; mkdir -p "$root_one"
  root_two="$TMP_ROOT/root-two"; mkdir -p "$root_two"
  out_one=$( FM_HOME="$home" FM_ROOT_OVERRIDE="$root_one" bash -c '. "$0/bin/fm-backend.sh"; fm_backend_source tmux; fm_backend_tmux_session_name' "$ROOT" )
  out_two=$( FM_HOME="$home" FM_ROOT_OVERRIDE="$root_two" bash -c '. "$0/bin/fm-backend.sh"; fm_backend_source tmux; fm_backend_tmux_session_name' "$ROOT" )
  [ "$out_one" != "$out_two" ] || fail "two distinct FM_ROOT paths must not derive the same session name"
  pass "fm_backend_tmux_session_name: two homes on one machine derive distinct session names (no shared namespace)"
}

test_session_name_secondmate_prefix() {
  local dir out expected
  dir="$TMP_ROOT/secondmate-home"; mkdir -p "$dir"
  printf 'sm-one\n' > "$dir/.fm-secondmate-home"
  expected=$(tmux_expected_session_name "$dir")
  out=$( FM_HOME="$dir" bash -c '. "$0/bin/fm-backend.sh"; fm_backend_source tmux; fm_backend_tmux_session_name' "$ROOT" )
  [ "$out" = "$expected" ] || fail "secondmate session name should be $expected, got '$out'"
  case "$out" in
    fm-2ndmate-sm-one-*) : ;;
    *) fail "secondmate session name should carry the 2ndmate- prefix, got '$out'" ;;
  esac
  pass "fm_backend_tmux_session_name: a secondmate home's name carries its own 2ndmate-<id> tag"
}

# --- explicit operator override wins ----------------------------------------

test_session_name_honors_explicit_override() {
  local dir out
  dir="$TMP_ROOT/override-home"; mkdir -p "$dir"
  out=$( FM_HOME="$dir" FM_TMUX_SESSION=fm-pinned-name bash -c '. "$0/bin/fm-backend.sh"; fm_backend_source tmux; fm_backend_tmux_session_name' "$ROOT" )
  [ "$out" = fm-pinned-name ] || fail "FM_TMUX_SESSION override was not honored, got '$out'"
  pass "fm_backend_tmux_session_name: FM_TMUX_SESSION explicit override wins over the derived default"
}

# --- container_ensure: create-vs-reuse + override precedence over creation --

test_container_ensure_creates_derived_session_when_absent() {
  local dir fb log out expected
  dir="$TMP_ROOT/ensure-create"; mkdir -p "$dir"
  fb=$(make_tmux_fakebin "$dir")
  log="$dir/tmux.log"
  expected=$(tmux_expected_session_name "$dir")
  out=$( PATH="$fb:$PATH" FM_TMUX_LOG="$log" FM_HOME="$dir" \
    bash -c '. "$0/bin/fm-backend.sh"; fm_backend_source tmux; fm_backend_tmux_container_ensure' "$ROOT" )
  [ "$out" = "$expected" ] || fail "container_ensure should print $expected, got '$out'"
  assert_contains "$(cat "$log")" $'\x1f'"new-session"$'\x1f' "container_ensure did not create the derived session when none existed"
  assert_contains "$(cat "$log")" "$expected" "the create call did not name the derived session"
  pass "fm_backend_tmux_container_ensure: creates the derived fm-<hometag> session when absent, outside tmux"
}

test_container_ensure_reuses_existing_derived_session() {
  local dir fb log out expected
  dir="$TMP_ROOT/ensure-reuse"; mkdir -p "$dir"
  expected=$(tmux_expected_session_name "$dir")
  fb=$(make_tmux_fakebin "$dir")
  log="$dir/tmux.log"
  out=$( PATH="$fb:$PATH" FM_TMUX_LOG="$log" FM_TMUX_EXISTING="$expected" FM_HOME="$dir" \
    bash -c '. "$0/bin/fm-backend.sh"; fm_backend_source tmux; fm_backend_tmux_container_ensure' "$ROOT" )
  [ "$out" = "$expected" ] || fail "container_ensure should reuse and print $expected, got '$out'"
  assert_not_contains "$(cat "$log")" $'\x1f'"new-session"$'\x1f' "container_ensure must not create a session that already exists"
  pass "fm_backend_tmux_container_ensure: reuses an already-existing derived session rather than recreating it (respawn/recovery finds the same home)"
}

test_container_ensure_honors_override_over_creation() {
  local dir fb log out
  dir="$TMP_ROOT/ensure-override"; mkdir -p "$dir"
  fb=$(make_tmux_fakebin "$dir")
  log="$dir/tmux.log"
  out=$( PATH="$fb:$PATH" FM_TMUX_LOG="$log" FM_TMUX_SESSION=fm-pinned-ensure FM_HOME="$dir" \
    bash -c '. "$0/bin/fm-backend.sh"; fm_backend_source tmux; fm_backend_tmux_container_ensure' "$ROOT" )
  [ "$out" = fm-pinned-ensure ] || fail "container_ensure should honor FM_TMUX_SESSION and print it, got '$out'"
  assert_contains "$(cat "$log")" "fm-pinned-ensure" "container_ensure did not use the pinned override name"
  pass "fm_backend_tmux_container_ensure: FM_TMUX_SESSION override wins over the derived default when creating a new session"
}

test_container_ensure_reuses_current_session_when_nested() {
  local dir fb log out
  dir="$TMP_ROOT/ensure-nested"; mkdir -p "$dir"
  fb=$(make_tmux_fakebin "$dir")
  log="$dir/tmux.log"
  out=$( PATH="$fb:$PATH" FM_TMUX_LOG="$log" FM_HOME="$dir" TMUX=/tmp/fake-tmux-socket,1,0 FM_TMUX_CURRENT_SESSION=captains-own-session \
    bash -c '. "$0/bin/fm-backend.sh"; fm_backend_source tmux; fm_backend_tmux_container_ensure' "$ROOT" )
  [ "$out" = captains-own-session ] || fail "container_ensure should reuse the current tmux session when nested, got '$out'"
  assert_not_contains "$(cat "$log")" $'\x1f'"new-session"$'\x1f' "container_ensure must not create a session when already nested inside one"
  pass "fm_backend_tmux_container_ensure: unchanged - reuses whatever session firstmate is already nested inside, ignoring the derived default"
}

# --- backward compatibility: an old-recorded target keeps resolving --------

test_old_recorded_target_still_resolves() {
  local state out
  state="$TMP_ROOT/legacy-state"; mkdir -p "$state"
  # A pre-fix task's meta, written back when the shared literal was
  # "firstmate" (and, before that, "default"). fm_backend_resolve_selector
  # must return the recorded target VERBATIM - it never reconstructs the
  # session name via fm_backend_tmux_container_ensure/fm_backend_tmux_session_name.
  fm_write_meta "$state/legacy-task.meta" "window=firstmate:fm-legacy-task"
  out=$(fm_backend_resolve_selector "legacy-task" "$state")
  [ "$out" = "firstmate:fm-legacy-task" ] || fail "resolve_selector should return the recorded legacy target verbatim, got '$out'"
  pass "fm_backend_resolve_selector: an old task recorded under the pre-fix shared session name still resolves unchanged"

  fm_write_meta "$state/legacy-default.meta" "window=default:fm-legacy-default"
  out=$(fm_backend_resolve_selector "legacy-default" "$state")
  [ "$out" = "default:fm-legacy-default" ] || fail "resolve_selector should return the even-older recorded 'default:' target verbatim, got '$out'"
  pass "fm_backend_resolve_selector: a task recorded under the even-older literal 'default' session still resolves unchanged"
}

test_session_name_deterministic_for_same_home
test_session_name_differs_for_distinct_homes
test_session_name_secondmate_prefix
test_session_name_honors_explicit_override
test_container_ensure_creates_derived_session_when_absent
test_container_ensure_reuses_existing_derived_session
test_container_ensure_honors_override_over_creation
test_container_ensure_reuses_current_session_when_nested
test_old_recorded_target_still_resolves
