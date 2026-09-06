#!/usr/bin/env bash
# Regression test for the fm-spawn.sh treehouse-get worktree-detection settle
# loop (bin/fm-spawn.sh, the `for _ in $(seq 1 "$settle_polls")` loop after
# `treehouse get`).
#
# On some tmux/WSL setups a brand-new window's pane_current_path transiently
# reports a stale, unrelated-but-real path on the very first poll, before the
# pane actually settles into the worktree treehouse get moved it to. A naive
# single-read loop would accept that on sight, so the loop requires two
# consecutive reads to agree before accepting a candidate - covered by
# test_single_stale_first_read_is_not_accepted and
# test_already_settled_pane_costs_one_confirm_sleep below.
#
# Two agreeing reads are not sufficient on their own: while treehouse get's
# own fetch runs, the pane can report a transient git subprocess's cwd for
# longer than the one-second poll interval, so two reads can agree on a path
# that is still not the settled worktree - the live 2026-09-05 UBP incident,
# where the pane read the project's own .git directory on both reads while
# its SMB-hosted origin fetched slowly. Nor does validate_spawn_worktree catch
# a bad acceptance here: it confirms the candidate is A real, distinct
# worktree root, never that it is a worktree of the SAME repo, so a stale read
# landing in some other real checkout would pass it too - the more dangerous
# near-miss, where the recorded worktree would be a real but unrelated repo.
# spawn_candidate_is_primary_worktree adds that positive test, and
# test_repeated_project_dotgit_is_not_accepted and
# test_repeated_separate_repo_is_not_accepted below cover both cases. A pane
# that never settles at all must time out with its own distinct message
# rather than silently accepting anything - test_never_settling_pane_times_out_with_distinct_message.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-worktree-settle)

# make_settle_fakebin <dir> builds a fake tmux whose `#{pane_current_path}`
# query returns FM_FAKE_PANE_STALE for the first FM_FAKE_PANE_STALE_READS
# calls, then FM_FAKE_PANE_PATH forever after - reproducing a pane that
# transiently reports a stale cwd before settling into the real worktree.
make_settle_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*)
    countfile="${FM_FAKE_PANE_COUNTFILE:?FM_FAKE_PANE_COUNTFILE unset}"
    n=0
    [ -f "$countfile" ] && n=$(cat "$countfile")
    n=$((n + 1))
    printf '%s\n' "$n" > "$countfile"
    if [ "$n" -le "${FM_FAKE_PANE_STALE_READS:-0}" ]; then
      printf '%s\n' "${FM_FAKE_PANE_STALE:-}"
    else
      printf '%s\n' "${FM_FAKE_PANE_PATH:-}"
    fi
    exit 0
    ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|kill-window) exit 0 ;;
  send-keys) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  printf '%s\n' "$fakebin"
}

# make_settle_case <name> <id> <stale_reads> [stale_kind] builds a home, a
# primary project with a real worktree (the eventual settled path), and a
# stale path the pane transiently reports before settling. <stale_kind>
# selects what the stale path is:
#   separate-repo (default) - a real checkout of something else entirely,
#     distinct from both the project and the worktree - mirroring the
#     dangerous near-miss where the stale read is another real repo's worktree.
#   project-dotgit - the primary project's own .git directory, mirroring the
#     live 2026-09-05 UBP incident where treehouse get's own fetch subprocess
#     left the pane sitting in the project's .git while its origin (an SMB
#     volume) was slow.
make_settle_case() {
  local name=$1 id=$2 stale_reads=$3 stale_kind=${4:-separate-repo}
  local case_dir home proj wt stale fakebin countfile
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  countfile="$case_dir/pane-call-count"
  fakebin=$(make_settle_fakebin "$case_dir/fake")
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  printf 'codex\n' > "$home/config/crew-harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  case "$stale_kind" in
    project-dotgit) stale="$proj/.git" ;;
    separate-repo)
      stale="$case_dir/stale-other-checkout"
      fm_git_init_commit "$stale"
      # A reachable origin so a pre-fix acceptance of this path runs all the
      # way through freshen_spawn_worktree_base instead of dying early on
      # "could not fetch origin" - the fixture must fail on the assertion the
      # near-miss case exists to pin (a real-but-wrong repo recorded as the
      # worktree), not on an unrelated missing-origin error.
      fm_git_add_origin "$stale" "$stale.origin.git"
      ;;
    *) echo "make_settle_case: unknown stale_kind '$stale_kind'" >&2; return 1 ;;
  esac
  mkdir -p "$home/data/$id"
  cat > "$home/data/$id/brief.md" <<EOF
# Task
## Captain's intent
Exercise settled-worktree detection for $id.

## Firstmate spec
Record only the pane's stable worktree.
EOF
  touch "$home/state/.last-watcher-beat"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$stale|$fakebin|$countfile|$stale_reads"
}

read_settle_record() {
  IFS='|' read -r _ HOME_DIR PROJ_DIR WT_DIR STALE_DIR FAKEBIN_DIR COUNTFILE STALE_READS <<EOF
$1
EOF
}

# <id> [settle_polls] [settle_interval]: settle_polls/settle_interval are
# forwarded as FM_SPAWN_SETTLE_POLLS/FM_SPAWN_SETTLE_POLL_INTERVAL even when
# empty - fm-spawn.sh's own `${FM_SPAWN_SETTLE_POLLS:-60}` fallback already
# treats an empty value the same as unset, so this stays a plain assignment
# word rather than a conditional `${var:+NAME=value}` expansion, which bash
# does not recognize as an assignment prefix when empty (it falls out of the
# prefix run entirely and the literal PATH= word after it is read as the
# command name instead of an assignment - a real failure mode hit while
# writing this test, not a hypothetical one).
run_settle_spawn() {
  local id=$1 settle_polls=${2:-} settle_interval=${3:-}
  FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" \
    FM_FAKE_PANE_PATH="$WT_DIR" FM_FAKE_PANE_STALE="$STALE_DIR" \
    FM_FAKE_PANE_STALE_READS="$STALE_READS" FM_FAKE_PANE_COUNTFILE="$COUNTFILE" \
    FM_SPAWN_SETTLE_POLLS="$settle_polls" FM_SPAWN_SETTLE_POLL_INTERVAL="$settle_interval" \
    PATH="$FAKEBIN_DIR:$PATH" \
    "$SPAWN" "$id" "$PROJ_DIR" --mode no-mistakes --yolo off 2>&1
}

# A single stale first read (the exact incident) must not be accepted: the
# loop should keep polling until two consecutive reads agree, landing on the
# real settled worktree instead.
test_single_stale_first_read_is_not_accepted() {
  local rec id out status
  id=settle-single-stale-z1
  rec=$(make_settle_case settle-single "$id" 1)
  read_settle_record "$rec"

  out=$(run_settle_spawn "$id")
  status=$?
  expect_code 0 "$status" "spawn should succeed once the pane settles"
  assert_contains "$out" "spawned $id" "spawn did not report success"
  assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$id.meta" \
    "meta did not record the settled worktree"
  assert_no_grep "worktree=$STALE_DIR" "$HOME_DIR/state/$id.meta" \
    "meta wrongly recorded the transient stale path as the worktree"
  pass "a single transient stale pane_current_path read is not accepted as the worktree"
}

# A pane that reports the real worktree from the very first read still only
# costs the loop's existing one-second inter-poll sleep to confirm - not an
# extra full cycle on top of that.
test_already_settled_pane_costs_one_confirm_sleep() {
  local rec id out status start end elapsed
  id=settle-already-settled-z2
  rec=$(make_settle_case settle-already-settled "$id" 0)
  read_settle_record "$rec"

  start=$(date +%s)
  out=$(run_settle_spawn "$id")
  status=$?
  end=$(date +%s)
  elapsed=$((end - start))
  expect_code 0 "$status" "spawn should succeed when the pane is already settled"
  assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$id.meta" \
    "meta did not record the already-settled worktree"
  [ "$elapsed" -le 5 ] || fail "already-settled pane took ${elapsed}s to confirm - expected close to the single inter-poll sleep"
  pass "an already-settled pane confirms via the existing inter-poll sleep, not an extra full cycle"
}

# The live 2026-09-05 UBP incident: the pane reports the primary project's own
# .git directory (where treehouse get's fetch subprocess sat while its SMB
# origin was slow) on two consecutive reads - enough to satisfy the existing
# repeat rule on its own. Before the fix this was accepted as WT and then
# correctly refused by validate_spawn_worktree ("did not yield an isolated
# worktree"), reproducing the reported total-dispatch-block symptom. The fix
# must keep polling past it and settle on the real worktree instead.
test_repeated_project_dotgit_is_not_accepted() {
  local rec id out status
  id=settle-live-incident-z3
  rec=$(make_settle_case settle-live-incident "$id" 2 project-dotgit)
  read_settle_record "$rec"

  out=$(run_settle_spawn "$id")
  status=$?
  expect_code 0 "$status" "spawn should succeed past the repeated .git-directory read"
  assert_contains "$out" "spawned $id" "spawn did not report success"
  assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$id.meta" \
    "meta did not record the settled worktree"
  assert_no_grep "worktree=$STALE_DIR" "$HOME_DIR/state/$id.meta" \
    "meta wrongly recorded the project's own .git directory as the worktree"
  pass "a repeated pane read of the primary project's own .git directory is not accepted as the worktree"
}

# The dangerous near-miss: the stale path is a real, separate git checkout -
# a genuine worktree root, just not one of the primary's repo - repeated on
# two consecutive reads. validate_spawn_worktree does not catch this (it only
# checks "is A distinct worktree root", never "of the SAME repo"), so before
# the fix this was silently accepted and recorded as the task's worktree: the
# worst outcome this code can produce, since a worker would then edit a
# random other real checkout instead of its isolated copy. The fix must
# reject it and keep polling to the real settled worktree.
test_repeated_separate_repo_is_not_accepted() {
  local rec id out status
  id=settle-near-miss-z4
  rec=$(make_settle_case settle-near-miss "$id" 2 separate-repo)
  read_settle_record "$rec"

  out=$(run_settle_spawn "$id")
  status=$?
  expect_code 0 "$status" "spawn should succeed past the repeated separate-repo read"
  assert_contains "$out" "spawned $id" "spawn did not report success"
  assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$id.meta" \
    "meta did not record the settled worktree"
  assert_no_grep "worktree=$STALE_DIR" "$HOME_DIR/state/$id.meta" \
    "meta wrongly recorded a real but unrelated repo's worktree as the task's worktree"
  pass "a repeated pane read of a real, separate repo's worktree is not accepted as the task's worktree"
}

# A pane that never settles into any worktree of the primary repo must time
# out with a message that says exactly that, distinct from
# validate_spawn_worktree's "did not yield an isolated worktree" refusal,
# which means something different (a worktree WAS accepted but failed
# isolation). FM_SPAWN_SETTLE_POLLS/FM_SPAWN_SETTLE_POLL_INTERVAL shrink the
# wait so this case does not cost the real 60s window.
test_never_settling_pane_times_out_with_distinct_message() {
  local rec id out status
  id=settle-never-z5
  # stale_reads deliberately outlasts the shrunk poll budget below, so every
  # read in this test sees the project's own .git directory: a pane that
  # never leaves the transient path.
  rec=$(make_settle_case settle-never "$id" 999999 project-dotgit)
  read_settle_record "$rec"

  out=$(run_settle_spawn "$id" 3 0.05)
  status=$?
  expect_code 1 "$status" "spawn should fail when the pane never settles into a worktree of the primary"
  assert_contains "$out" "never observed a settled worktree" \
    "timeout error did not use the never-observed-a-worktree wording"
  assert_not_contains "$out" "did not yield an isolated worktree" \
    "timeout error must not read like validate_spawn_worktree's isolation-assertion failure"
  assert_absent "$HOME_DIR/state/$id.meta" \
    "a never-settled pane must not leave behind a worktree= record"
  pass "a pane that never settles into a primary-repo worktree times out with its own distinct message"
}

test_inherited_cdpath_does_not_affect_worktree_detection() {
  local variant cdpath rec id out status
  mkdir -p "$TMP_ROOT/cdpath-shadow/.git"
  for variant in dot shadow; do
    case "$variant" in
      dot) cdpath=. ;;
      shadow) cdpath="$TMP_ROOT/cdpath-shadow" ;;
    esac
    id="settle-cdpath-$variant"
    rec=$(make_settle_case "$id" "$id" 2 project-dotgit)
    read_settle_record "$rec"

    out=$(export CDPATH="$cdpath"; run_settle_spawn "$id" 4 0.05)
    status=$?
    expect_code 0 "$status" "spawn should succeed with inherited CDPATH=$cdpath"
    assert_contains "$out" "spawned $id" "spawn did not report success"
    assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$id.meta" \
      "meta did not record the settled worktree with inherited CDPATH"
    [ "$(cat "$COUNTFILE")" -eq 4 ] || fail "spawn did not reject the transient path and confirm the real worktree"
    pass "inherited CDPATH=$variant does not affect worktree detection"
  done
}

test_single_stale_first_read_is_not_accepted
test_already_settled_pane_costs_one_confirm_sleep
test_repeated_project_dotgit_is_not_accepted
test_repeated_separate_repo_is_not_accepted
test_never_settling_pane_times_out_with_distinct_message
test_inherited_cdpath_does_not_affect_worktree_detection

echo "# all fm-spawn-worktree-settle tests passed"
