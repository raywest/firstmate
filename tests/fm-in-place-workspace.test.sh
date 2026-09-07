#!/usr/bin/env bash
# Behavior tests for the declared in-place workspace contract: a project whose
# data/projects.md entry carries +in-place runs its workers directly in the
# project's real directory, with no scratch worktree and no isolation
# assertion, because the real work location is outside projects/ and the
# directory itself is the product.
#
# The contract under test spans five owners:
#   bin/fm-project-mode.sh   --workspace query for the +in-place registry token
#   bin/fm-brief.sh          --in-place scaffolds and their fixed
#                            "Workspace contract: in-place" line
#   bin/fm-spawn.sh          --in-place launch: three-way agreement (registry,
#                            flag, brief), structural preconditions, the
#                            single-worker rule, and the skipped treehouse/
#                            freshen path
#   bin/fm-merge-local.sh    landing an in-place local-only task from its own
#                            task branch
#   bin/fm-teardown.sh       in-place cleanup that preserves the directory,
#                            plus the record cross-check hardening
# bin/fm-claude-trust.sh's --in-place scope test is covered here too.
#
# The safety property throughout: everything in-place is opt-in three times
# over, and every path stays exactly as strict as before wherever the flag,
# declaration, and brief do not all agree.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/fixtures.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
fm_git_identity

SPAWN="$ROOT/bin/fm-spawn.sh"
BRIEF="$ROOT/bin/fm-brief.sh"
PROJECT_MODE="$ROOT/bin/fm-project-mode.sh"
MERGE_LOCAL="$ROOT/bin/fm-merge-local.sh"
TEARDOWN="$ROOT/bin/fm-teardown.sh"
CLAUDE_TRUST="$ROOT/bin/fm-claude-trust.sh"
TMP_ROOT=$(fm_test_tmproot fm-in-place-workspace)

# --- fixtures ---------------------------------------------------------------

# A home plus a real project repo OUTSIDE the home's projects/ root (the
# in-place shape: the real work location is elsewhere). Registers the project
# with the given registry annotation ('' = unregistered). Echoes
# "<home>|<project>|<fakebin>".
make_world() {  # <name> [<registry-annotation>]
  local name=$1 annotation=${2-} home proj fakebin
  home="$TMP_ROOT/$name/home"
  proj="$TMP_ROOT/$name/volume/proj"
  fakebin="$TMP_ROOT/$name/fakebin"
  mkdir -p "$home/data" "$home/state" "$home/config" "$home/projects" "$fakebin"
  printf 'codex\n' > "$home/config/crew-harness"
  touch "$home/state/.last-watcher-beat"
  fm_git_init_commit "$proj"
  fm_test_fake_tmux_spawn "$fakebin"
  fm_fake_exit0 "$fakebin" treehouse
  if [ -n "$annotation" ]; then
    printf -- '- proj %s - in-place test project (added 2026-09-07)\n' "$annotation" \
      > "$home/data/projects.md"
  fi
  printf '%s\n' "$home|$proj|$fakebin"
}

read_world() {
  IFS='|' read -r W_HOME W_PROJ W_FAKEBIN <<EOF
$1
EOF
}

scaffold_brief() {  # <home> <id> <args...>
  local home=$1 id=$2
  shift 2
  FM_ROOT_OVERRIDE='' FM_HOME="$home" "$BRIEF" "$id" proj "$@" >/dev/null \
    || fail "could not scaffold brief for $id"
  fm_test_fill_brief "$home/data/$id/brief.md"
}

fm_test_fill_brief() {  # <file>
  local file=$1 content
  content=$(cat "$file")
  content=${content//'{TASK}'/Exercise the in-place workspace contract.}
  content=${content//'{FIRSTMATE_SPEC}'/Verify the declared in-place behavior.}
  printf '%s\n' "$content" > "$file"
}

run_spawn() {  # <home> <fakebin> <pane-path> <launch-log> <spawn-args...>
  local home=$1 fakebin=$2 pane_path=$3 launch_log=$4
  shift 4
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_BACKEND=tmux TMUX="fake,1,0" \
    FM_FAKE_PANE_PATH="$pane_path" FM_FAKE_LAUNCH_LOG="$launch_log" \
    FM_SPAWN_SETTLE_POLLS=2 FM_SPAWN_SETTLE_POLL_INTERVAL=0 \
    PATH="$fakebin:$PATH" \
    "$SPAWN" "$@" 2>&1
}

# --- registry parsing -------------------------------------------------------

test_project_mode_workspace_query() {
  local home
  home="$TMP_ROOT/mode/home"
  mkdir -p "$home/data"
  cat > "$home/data/projects.md" <<'EOF'
- flagged [local-only +yolo +in-place] - runs on the volume (added 2026-09-07)
- plain [direct-PR] - ordinary project (added 2026-09-07)
- flagsonly [+in-place] - annotation with no mode (added 2026-09-07)
EOF
  [ "$(FM_HOME="$home" "$PROJECT_MODE" --workspace flagged)" = in-place ] \
    || fail "--workspace did not read +in-place"
  [ "$(FM_HOME="$home" "$PROJECT_MODE" --workspace plain)" = isolated ] \
    || fail "--workspace did not default an undeclared project to isolated"
  [ "$(FM_HOME="$home" "$PROJECT_MODE" --workspace absent)" = isolated ] \
    || fail "--workspace did not treat a missing project as isolated"
  [ "$(FM_HOME="$TMP_ROOT/mode/no-such-home" "$PROJECT_MODE" --workspace flagged)" = isolated ] \
    || fail "--workspace did not treat a missing registry as isolated"
  [ "$(FM_HOME="$home" "$PROJECT_MODE" flagged)" = "local-only on" ] \
    || fail "+in-place changed the default two-word mode output"
  [ "$(FM_HOME="$home" "$PROJECT_MODE" flagsonly 2>/dev/null)" = "no-mistakes off" ] \
    || fail "a flags-only annotation did not keep the default mode"
  pass "fm-project-mode: +in-place parses via --workspace and never changes the mode output"
}

# --- brief scaffolds --------------------------------------------------------

test_brief_in_place_scaffolds() {
  local home out
  home="$TMP_ROOT/brief/home"
  mkdir -p "$home/data"

  FM_ROOT_OVERRIDE='' FM_HOME="$home" "$BRIEF" b-ship proj --mode local-only --in-place >/dev/null \
    || fail "in-place ship scaffold failed"
  assert_grep 'Workspace contract: in-place' "$home/data/b-ship/brief.md" \
    "in-place ship brief lacks the fixed workspace line"
  assert_no_grep 'Verify isolation before anything else' "$home/data/b-ship/brief.md" \
    "in-place ship brief still carries the worktree-isolation assertion"
  assert_grep 'NEVER run `git clean`' "$home/data/b-ship/brief.md" \
    "in-place ship brief lacks the git-clean ban protecting gitignored product data"

  FM_ROOT_OVERRIDE='' FM_HOME="$home" "$BRIEF" b-scout proj --scout --in-place >/dev/null \
    || fail "in-place scout scaffold failed"
  assert_grep 'Workspace contract: in-place' "$home/data/b-scout/brief.md" \
    "in-place scout brief lacks the fixed workspace line"
  assert_grep 'NOT a laboratory' "$home/data/b-scout/brief.md" \
    "in-place scout brief still reads as a scratch laboratory"

  FM_ROOT_OVERRIDE='' FM_HOME="$home" "$BRIEF" b-plain proj --mode no-mistakes >/dev/null \
    || fail "plain ship scaffold failed"
  assert_no_grep 'Workspace contract' "$home/data/b-plain/brief.md" \
    "a plain ship brief gained a workspace line"
  assert_grep 'Verify isolation before anything else' "$home/data/b-plain/brief.md" \
    "a plain ship brief lost its isolation assertion"

  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$home" "$BRIEF" b-sm --secondmate --no-projects --in-place 2>&1) \
    && fail "--secondmate --in-place should be refused"
  assert_contains "$out" "--in-place applies only to ship and scout briefs" \
    "secondmate scaffold did not refuse --in-place"
  pass "fm-brief: in-place scaffolds carry the workspace contract and plain scaffolds are unchanged"
}

# --- spawn agreement refusals ----------------------------------------------

test_spawn_refuses_flag_without_declaration() {
  local rec out
  rec=$(make_world flag-no-decl)
  read_world "$rec"
  scaffold_brief "$W_HOME" a1 --mode local-only --in-place
  out=$(run_spawn "$W_HOME" "$W_FAKEBIN" "$W_PROJ" "$TMP_ROOT/flag-no-decl/launch.log" \
    a1 "$W_PROJ" --mode local-only --yolo off --in-place) \
    && fail "--in-place without a registry declaration should refuse"
  assert_contains "$out" "not declared for project" \
    "refusal did not name the missing registry declaration"
  assert_absent "$W_HOME/state/a1.meta" "refused spawn wrote task metadata"
  pass "fm-spawn: --in-place without the registry declaration is refused before anything exists"
}

test_spawn_refuses_declaration_without_flag() {
  local rec out
  rec=$(make_world decl-no-flag '[local-only +in-place]')
  read_world "$rec"
  scaffold_brief "$W_HOME" a2 --mode local-only
  out=$(run_spawn "$W_HOME" "$W_FAKEBIN" "$W_PROJ" "$TMP_ROOT/decl-no-flag/launch.log" \
    a2 "$W_PROJ" --mode local-only --yolo off) \
    && fail "a declared in-place project spawned without --in-place should refuse"
  assert_contains "$out" "declared +in-place" \
    "refusal did not name the standing declaration"
  assert_absent "$W_HOME/state/a2.meta" "refused spawn wrote task metadata"
  pass "fm-spawn: a declared in-place project refuses a spawn that omits --in-place"
}

test_spawn_refuses_brief_drift_both_directions() {
  local rec out
  rec=$(make_world brief-drift '[local-only +in-place]')
  read_world "$rec"
  # Flag passed, but the brief was scaffolded without --in-place.
  scaffold_brief "$W_HOME" a3 --mode local-only
  out=$(run_spawn "$W_HOME" "$W_FAKEBIN" "$W_PROJ" "$TMP_ROOT/brief-drift/launch.log" \
    a3 "$W_PROJ" --mode local-only --yolo off --in-place) \
    && fail "--in-place with a plain brief should refuse"
  assert_contains "$out" "carries no 'Workspace contract: in-place' line" \
    "refusal did not name the missing brief line"
  assert_absent "$W_HOME/state/a3.meta" "refused spawn wrote task metadata"

  # In-place brief, but the spawn omits the flag (project undeclared, so the
  # registry gate passes and the brief gate must catch it).
  rec=$(make_world brief-drift-rev)
  read_world "$rec"
  scaffold_brief "$W_HOME" a4 --mode local-only --in-place
  out=$(run_spawn "$W_HOME" "$W_FAKEBIN" "$W_PROJ" "$TMP_ROOT/brief-drift-rev/launch.log" \
    a4 "$W_PROJ" --mode local-only --yolo off) \
    && fail "an in-place brief without --in-place should refuse"
  assert_contains "$out" "did not pass --in-place" \
    "refusal did not name the flag/brief drift"
  assert_absent "$W_HOME/state/a4.meta" "refused spawn wrote task metadata"
  pass "fm-spawn: brief/flag workspace drift refuses in both directions"
}

test_spawn_refuses_in_place_on_wrong_targets() {
  local rec out clone
  rec=$(make_world wrong-target '[local-only +in-place]')
  read_world "$rec"

  out=$(run_spawn "$W_HOME" "$W_FAKEBIN" "$W_PROJ" "$TMP_ROOT/wrong-target/launch.log" \
    a5 "$W_PROJ" --in-place --secondmate) \
    && fail "--secondmate --in-place should refuse"
  assert_contains "$out" "--in-place applies only to ship and scout spawns" \
    "secondmate spawn did not refuse --in-place"

  out=$(run_spawn "$W_HOME" "$W_FAKEBIN" "$W_PROJ" "$TMP_ROOT/wrong-target/launch.log" \
    a5 --relaunch --in-place) \
    && fail "--relaunch --in-place should refuse"
  assert_contains "$out" "--relaunch reuses the task's recorded workspace" \
    "relaunch did not refuse --in-place"

  # A clone under this home's projects/ root is exactly what scratch copies
  # protect, so declaring it in-place is refused structurally.
  clone="$W_HOME/projects/proj"
  fm_git_init_commit "$clone"
  scaffold_brief "$W_HOME" a6 --mode local-only --in-place
  out=$(run_spawn "$W_HOME" "$W_FAKEBIN" "$clone" "$TMP_ROOT/wrong-target/launch.log" \
    a6 "$clone" --mode local-only --yolo off --in-place) \
    && fail "--in-place under the projects/ clone root should refuse"
  assert_contains "$out" "projects/ clone root" \
    "refusal did not name the forbidden location"
  assert_absent "$W_HOME/state/a6.meta" "refused spawn wrote task metadata"

  # A subdirectory of a repo is not a worktree root (declared in the registry
  # so the structural refusal, not the declaration gate, is what fires).
  mkdir -p "$W_PROJ/subdir"
  printf -- '- subdir [local-only +in-place] - structural-check fixture (added 2026-09-07)\n' \
    >> "$W_HOME/data/projects.md"
  scaffold_brief "$W_HOME" a7 --mode local-only --in-place
  out=$(run_spawn "$W_HOME" "$W_FAKEBIN" "$W_PROJ/subdir" "$TMP_ROOT/wrong-target/launch.log" \
    a7 "$W_PROJ/subdir" --mode local-only --yolo off --in-place) \
    && fail "--in-place on a non-root directory should refuse"
  assert_contains "$out" "not a git worktree root" \
    "refusal did not name the missing repository root"
  pass "fm-spawn: --in-place refuses secondmates, relaunch overrides, projects/ clones, and non-root directories"
}

# --- successful in-place spawn and the single-worker rule -------------------

test_flagged_project_spawns_in_place_and_refuses_a_second_worker() {
  local rec out launch_log
  rec=$(make_world spawn-ok '[local-only +in-place]')
  read_world "$rec"
  launch_log="$TMP_ROOT/spawn-ok/launch.log"
  scaffold_brief "$W_HOME" ok1 --mode local-only --in-place

  out=$(run_spawn "$W_HOME" "$W_FAKEBIN" "$W_PROJ" "$launch_log" \
    ok1 "$W_PROJ" --mode local-only --yolo off --in-place) \
    || fail "in-place spawn failed: $out"
  assert_contains "$out" "spawned ok1" "spawn did not report success"
  assert_contains "$out" "workspace=in-place" "success line did not record the workspace"
  assert_grep 'workspace=in-place' "$W_HOME/state/ok1.meta" \
    "meta did not record workspace=in-place"
  assert_grep "worktree=$W_PROJ" "$W_HOME/state/ok1.meta" \
    "meta worktree is not the project directory"
  assert_grep "project=$W_PROJ" "$W_HOME/state/ok1.meta" \
    "meta project is not the project directory"
  # No scratch copy was ever requested: the pane never received `treehouse get`
  # (the launch log captures every literal line sent to the pane), and the
  # spawn succeeded although the project has NO origin remote, which proves the
  # fetch-and-reset freshen step never ran against the real directory.
  ! grep -q 'treehouse get' "$launch_log" \
    || fail "in-place spawn sent 'treehouse get' to the pane"
  git -C "$W_PROJ" remote get-url origin >/dev/null 2>&1 \
    && fail "fixture invariant broken: the in-place project gained an origin"

  # Second worker on the same directory: refused while the first task's record
  # exists, whatever the endpoint is doing.
  scaffold_brief "$W_HOME" ok2 --mode local-only --in-place
  out=$(run_spawn "$W_HOME" "$W_FAKEBIN" "$W_PROJ" "$launch_log" \
    ok2 "$W_PROJ" --mode local-only --yolo off --in-place) \
    && fail "a second concurrent in-place worker should refuse"
  assert_contains "$out" "task 'ok1' already occupies" \
    "refusal did not name the occupying task"
  assert_contains "$out" "one worker at a time" \
    "refusal did not state the single-worker rule"
  assert_absent "$W_HOME/state/ok2.meta" "refused second spawn wrote task metadata"
  pass "fm-spawn: a flagged project spawns in place once and refuses a second concurrent worker"
}

test_unflagged_project_still_requires_isolation() {
  local rec out
  rec=$(make_world unflagged)
  read_world "$rec"
  scaffold_brief "$W_HOME" iso1 --mode local-only
  # The pane never leaves the project directory (no treehouse in this world can
  # move it), so the unflagged spawn must keep polling for an isolated worktree
  # and fail its settle window rather than adopt the project directory.
  out=$(run_spawn "$W_HOME" "$W_FAKEBIN" "$W_PROJ" "$TMP_ROOT/unflagged/launch.log" \
    iso1 "$W_PROJ" --mode local-only --yolo off) \
    && fail "an unflagged spawn whose pane stays in the project should fail"
  assert_contains "$out" "never observed a settled worktree" \
    "unflagged spawn did not enforce the isolation requirement"
  assert_absent "$W_HOME/state/iso1.meta" "failed spawn wrote task metadata"
  pass "fm-spawn: without the flag the isolation requirement is exactly as strict as before"
}

# --- merge-local ------------------------------------------------------------

# An in-place world with committed work on fm/<id>. Sets W_* plus the meta.
make_merge_case() {  # <name> <id>
  local name=$1 id=$2 rec
  rec=$(make_world "$name" '[local-only +in-place]')
  read_world "$rec"
  git -C "$W_PROJ" checkout -q -b "fm/$id"
  printf 'work\n' > "$W_PROJ/work.txt"
  git -C "$W_PROJ" add work.txt
  git -C "$W_PROJ" -c user.name=t -c user.email=t@t commit -qm "task work"
  fm_write_meta "$W_HOME/state/$id.meta" \
    "window=firstmate:fm-$id" \
    "endpoint_task_id=$id" \
    "worktree=$W_PROJ" \
    "project=$W_PROJ" \
    "kind=ship" \
    "mode=local-only" \
    "workspace=in-place" \
    "spawn_gen=in-place-test-$id"
}

run_merge_local() {  # <home> <id>
  local home=$1 id=$2
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    "$MERGE_LOCAL" "$id" 2>&1
}

test_merge_local_lands_in_place_from_task_branch() {
  local out tip
  make_merge_case merge-ok m1
  tip=$(git -C "$W_PROJ" rev-parse "fm/m1")
  out=$(run_merge_local "$W_HOME" m1) \
    || fail "in-place merge from the task branch failed: $out"
  assert_contains "$out" "merged fm/m1" "merge did not report the landing"
  [ "$(git -C "$W_PROJ" symbolic-ref --short HEAD)" = main ] \
    || fail "project was not left on its default branch"
  [ "$(git -C "$W_PROJ" rev-parse HEAD)" = "$tip" ] \
    || fail "default branch did not fast-forward to the task branch tip"
  pass "fm-merge-local: an in-place task lands from its own checked-out task branch onto the default branch"
}

test_merge_local_in_place_still_refuses_unsafe_states() {
  local out
  make_merge_case merge-dirty m2
  printf 'wip\n' >> "$W_PROJ/work.txt"
  out=$(run_merge_local "$W_HOME" m2) \
    && fail "a dirty in-place tree should refuse the merge"
  assert_contains "$out" "dirty working tree" "dirty refusal missing"
  git -C "$W_PROJ" checkout -q -- work.txt

  make_merge_case merge-branch m3
  git -C "$W_PROJ" checkout -q -b unrelated
  out=$(run_merge_local "$W_HOME" m3) \
    && fail "an unrelated checked-out branch should refuse the merge"
  assert_contains "$out" "expected default branch 'main' or the task branch" \
    "unrelated-branch refusal missing"

  # Control: WITHOUT workspace=in-place the task-branch checkout stays refused.
  make_merge_case merge-iso m4
  grep -v '^workspace=' "$W_HOME/state/m4.meta" > "$W_HOME/state/m4.meta.tmp"
  mv "$W_HOME/state/m4.meta.tmp" "$W_HOME/state/m4.meta"
  out=$(run_merge_local "$W_HOME" m4) \
    && fail "a non-in-place merge from the task branch should refuse"
  assert_contains "$out" "expected default branch 'main'" \
    "isolated-task strictness was lost"
  pass "fm-merge-local: in-place landing refuses dirty trees and wrong branches, and isolated tasks stay as strict as before"
}

# --- teardown ---------------------------------------------------------------

# Teardown fixture for an in-place task: fakebin stubs for the post-check
# steps, with treehouse invocations logged so a test can prove the real
# directory was never returned to any pool.
make_teardown_case() {  # <name> <id>
  local name=$1 id=$2
  make_merge_case "$name" "$id"
  cat > "$W_FAKEBIN/treehouse" <<SH
#!/usr/bin/env bash
printf 'treehouse %s\n' "\$*" >> "$TMP_ROOT/$name/treehouse.log"
exit 0
SH
  chmod +x "$W_FAKEBIN/treehouse"
  fm_fake_exit0 "$W_FAKEBIN" gh
  cat > "$W_FAKEBIN/gh-axi" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "pr list") printf '%s\n' "count: 0 (showing first 0)" "pull_requests[]: []"; exit 0 ;;
  "pr view") echo "error: pull request not found" >&2; exit 1 ;;
esac
exit 0
SH
  chmod +x "$W_FAKEBIN/gh-axi"
  cat > "$W_FAKEBIN/no-mistakes" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$W_FAKEBIN/no-mistakes"
}

run_teardown() {  # <home> <fakebin> <id> [args...]
  local home=$1 fakebin=$2 id=$3
  shift 3
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" \
    PATH="$fakebin:$PATH" \
    "$TEARDOWN" "$id" "$@" 2>&1
}

test_teardown_preserves_landed_in_place_directory() {
  local out
  make_teardown_case td-landed t1
  run_merge_local "$W_HOME" t1 >/dev/null || fail "could not land t1 before teardown"
  mkdir -p "$W_PROJ/.claude"
  printf '{}\n' > "$W_PROJ/.claude/settings.local.json"

  out=$(run_teardown "$W_HOME" "$W_FAKEBIN" t1) \
    || fail "teardown of a landed in-place task failed: $out"
  [ -f "$W_PROJ/work.txt" ] || fail "teardown removed the project's files"
  [ -d "$W_PROJ/.git" ] || fail "teardown removed the project's repository"
  [ "$(git -C "$W_PROJ" symbolic-ref --short HEAD)" = main ] \
    || fail "teardown moved the project off its default branch"
  git -C "$W_PROJ" rev-parse --verify --quiet refs/heads/fm/t1 >/dev/null \
    && fail "teardown left the landed task branch behind"
  [ "$(cat "$W_PROJ/.claude/settings.local.json")" = '{}' ] \
    || fail "teardown changed pre-existing project settings"
  [ ! -e "$TMP_ROOT/td-landed/treehouse.log" ] \
    || fail "teardown invoked treehouse against the real project directory"
  assert_absent "$W_HOME/state/t1.meta" "teardown did not retire the task record"
  pass "fm-teardown: a landed in-place task cleans its own traces and leaves the real directory intact"
}

test_teardown_refuses_unlanded_in_place_work() {
  local out
  make_teardown_case td-unlanded t2
  out=$(run_teardown "$W_HOME" "$W_FAKEBIN" t2) \
    && fail "teardown of unlanded in-place work should refuse"
  assert_contains "$out" "REFUSED" "unlanded in-place work was not refused"
  [ -f "$W_HOME/state/t2.meta" ] || fail "refused teardown removed the task record"
  git -C "$W_PROJ" rev-parse --verify --quiet refs/heads/fm/t2 >/dev/null \
    || fail "refused teardown deleted the unlanded task branch"
  pass "fm-teardown: unlanded in-place work is refused exactly like any other unlanded work"
}

test_teardown_record_crosschecks_fail_closed() {
  local out
  # An ordinary record whose worktree resolves to its project directory must
  # never reach the scratch-copy return path.
  make_teardown_case td-corrupt t3
  run_merge_local "$W_HOME" t3 >/dev/null || fail "could not land t3"
  grep -v '^workspace=' "$W_HOME/state/t3.meta" > "$W_HOME/state/t3.meta.tmp"
  mv "$W_HOME/state/t3.meta.tmp" "$W_HOME/state/t3.meta"
  out=$(run_teardown "$W_HOME" "$W_FAKEBIN" t3) \
    && fail "a project-directory worktree without workspace=in-place should refuse"
  assert_contains "$out" "does not say workspace=in-place" \
    "record cross-check did not fire for the missing declaration"
  [ ! -e "$TMP_ROOT/td-corrupt/treehouse.log" ] \
    || fail "the corrupt record still reached treehouse"

  # An in-place record whose worktree is NOT its project directory is corrupt.
  make_teardown_case td-mismatch t4
  fm_git_init_commit "$TMP_ROOT/td-mismatch/elsewhere"
  sed "s|^worktree=.*|worktree=$TMP_ROOT/td-mismatch/elsewhere|" \
    "$W_HOME/state/t4.meta" > "$W_HOME/state/t4.meta.tmp"
  mv "$W_HOME/state/t4.meta.tmp" "$W_HOME/state/t4.meta"
  out=$(run_teardown "$W_HOME" "$W_FAKEBIN" t4) \
    && fail "an in-place record with a foreign worktree should refuse"
  assert_contains "$out" "does not resolve to its project directory" \
    "record cross-check did not fire for the mismatched identity"

  # An unreachable in-place directory cannot be inspected for unlanded work.
  make_teardown_case td-missing t5
  rm -rf "$TMP_ROOT/td-missing/volume"
  out=$(run_teardown "$W_HOME" "$W_FAKEBIN" t5) \
    && fail "an unreachable in-place directory should refuse"
  assert_contains "$out" "unreachable" \
    "missing-directory refusal did not explain itself"
  pass "fm-teardown: in-place record cross-checks and the unreachable-directory guard fail closed"
}

test_workspace_hook_ownership() {
  local rec hook state out rel
  rec=$(make_world hook-ownership '[local-only +in-place]')
  read_world "$rec"
  hook="$ROOT/bin/fm-workspace-hooks.py"
  state="$W_HOME/state"
  for rel in .claude/settings.local.json .opencode/plugins/fm-busy-state.js .fm-grok-turnend .fm-kimi-turnend; do
    printf 'owned\n' | python3 "$hook" install "$state" owner "$W_PROJ" "$rel" || fail "hook install failed"
    printf 'foreign\n' | python3 "$hook" install "$state" other "$W_PROJ" "$rel" >/dev/null 2>&1 \
      && fail "another task overwrote an owned hook"
    python3 "$hook" remove "$state" other "$W_PROJ" "$rel" || fail "foreign cleanup failed"
    [ "$(cat "$W_PROJ/$rel")" = owned ] || fail "foreign cleanup deleted the hook"
    printf 'replacement\n' | python3 "$hook" install "$state" owner "$W_PROJ" "$rel" || fail "owned hook replacement failed"
    [ "$(cat "$W_PROJ/$rel")" = replacement ] || fail "owned replacement did not install"
    printf 'captain edit\n' > "$W_PROJ/$rel"
    python3 "$hook" remove "$state" owner "$W_PROJ" "$rel" || fail "edited hook cleanup failed"
    [ "$(cat "$W_PROJ/$rel")" = 'captain edit' ] || fail "cleanup deleted edited settings"
    rm "$W_PROJ/$rel"
    printf 'owned again\n' | python3 "$hook" install "$state" owner "$W_PROJ" "$rel" || fail "reinstall failed"
  done
  python3 "$hook" remove "$state" owner "$W_PROJ" || fail "owned hooks cleanup failed"
  assert_absent "$W_PROJ/.claude/settings.local.json" "owned Claude hook survived cleanup"
  assert_absent "$W_PROJ/.opencode/plugins/fm-busy-state.js" "owned OpenCode hook survived cleanup"
  assert_absent "$state/owner.workspace-hooks.json" "receipt survived complete cleanup"
  rmdir "$W_PROJ/.claude"
  mkdir "$W_HOME/external-config"
  printf 'external\n' > "$W_HOME/external-config/settings.local.json"
  ln -s "$W_HOME/external-config" "$W_PROJ/.claude"
  printf 'hook\n' | python3 "$hook" install "$state" owner "$W_PROJ" .claude/settings.local.json >/dev/null 2>&1 \
    && fail "hook installation followed a project symlink"
  [ "$(cat "$W_HOME/external-config/settings.local.json")" = external ] || fail "symlink target changed"
  pass "workspace hooks preserve unowned, edited, foreign-task and symlinked files"
}

test_claude_spawn_preserves_preexisting_settings() {
  local rec out
  rec=$(make_world claude-existing '[local-only +in-place]')
  read_world "$rec"
  scaffold_brief "$W_HOME" hook-existing --mode local-only --in-place
  mkdir -p "$W_PROJ/.claude" "$W_HOME/claude-config"
  printf '{"permissions":{"deny":["Bash(rm:*)"]}}\n' > "$W_PROJ/.claude/settings.local.json"
  cp "$W_PROJ/.claude/settings.local.json" "$W_HOME/original-settings"
  out=$(CLAUDE_CONFIG_DIR="$W_HOME/claude-config" run_spawn "$W_HOME" "$W_FAKEBIN" "$W_PROJ" "$W_HOME/launch.log" \
    hook-existing "$W_PROJ" --mode local-only --yolo off --in-place --harness claude) \
    && fail "Claude overwrote pre-existing project settings"
  assert_contains "$out" "without task ownership" "Claude did not refuse the unowned settings"
  cmp -s "$W_HOME/original-settings" "$W_PROJ/.claude/settings.local.json" || fail "Claude changed pre-existing settings"
  pass "Claude spawn refuses unowned settings without changing them"
}

test_in_place_relaunch_preserves_unowned_hooks() {
  local rec out
  rec=$(make_world relaunch-hooks '[local-only +in-place]')
  read_world "$rec"
  scaffold_brief "$W_HOME" relaunch-hooks --mode local-only --in-place
  fm_write_meta "$W_HOME/state/relaunch-hooks.meta" "window=firstmate:fm-relaunch-hooks" \
    "endpoint_task_id=relaunch-hooks" "worktree=$W_PROJ" "project=$W_PROJ" \
    "kind=ship" "mode=local-only" "yolo=off" "workspace=in-place" "harness=claude"
  mkdir -p "$W_PROJ/.claude"
  printf '{"captain":true}\n' > "$W_PROJ/.claude/settings.local.json"
  mv "$W_FAKEBIN/tmux" "$W_FAKEBIN/tmux-base"
  cat > "$W_FAKEBIN/tmux" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *pane_current_command*) echo zsh; exit 0 ;;
  list-windows*) echo fm-relaunch-hooks; exit 0 ;;
esac
exec "${0%/*}/tmux-base" "$@"
SH
  chmod +x "$W_FAKEBIN/tmux"
  out=$(run_spawn "$W_HOME" "$W_FAKEBIN" "$W_PROJ" "$W_HOME/relaunch.log" \
    relaunch-hooks --relaunch --harness codex) || fail "in-place relaunch failed: $out"
  [ "$(cat "$W_PROJ/.claude/settings.local.json")" = '{"captain":true}' ] || fail "relaunch removed unowned prior settings"
  assert_grep 'harness=codex' "$W_HOME/state/relaunch-hooks.meta" "relaunch did not publish replacement"
  pass "in-place relaunch preserves unowned project settings when switching harnesses"
}

test_completion_untracked_scope() {
  local out wt
  make_teardown_case completion-untracked untracked
  printf 'product image\n' > "$W_PROJ/image.png"
  out=$(run_merge_local "$W_HOME" untracked) || fail "untracked product blocked in-place merge: $out"
  printf 'wip\n' >> "$W_PROJ/work.txt"
  out=$(run_teardown "$W_HOME" "$W_FAKEBIN" untracked) && fail "tracked changes passed in-place teardown"
  assert_contains "$out" "uncommitted changes" "teardown did not identify tracked changes"
  git -C "$W_PROJ" checkout -q -- work.txt
  out=$(run_teardown "$W_HOME" "$W_FAKEBIN" untracked) || fail "untracked product blocked in-place cleanup: $out"
  [ "$(cat "$W_PROJ/image.png")" = 'product image' ] || fail "cleanup changed the product image"

  make_teardown_case completion-isolated isolated
  git -C "$W_PROJ" checkout -q main
  wt="$TMP_ROOT/completion-isolated/scratch"
  git -C "$W_PROJ" worktree add -q "$wt" fm/isolated
  fm_write_meta "$W_HOME/state/isolated.meta" "window=firstmate:fm-isolated" "endpoint_task_id=isolated" \
    "worktree=$wt" "project=$W_PROJ" "kind=ship" "mode=local-only"
  printf 'untracked\n' > "$W_PROJ/image.png"
  out=$(run_merge_local "$W_HOME" isolated) && fail "isolated merge allowed an untracked file"
  assert_contains "$out" "dirty working tree" "isolated merge lost its untracked guard"
  rm "$W_PROJ/image.png"
  run_merge_local "$W_HOME" isolated >/dev/null || fail "could not land isolated task"
  printf 'untracked\n' > "$wt/image.png"
  out=$(run_teardown "$W_HOME" "$W_FAKEBIN" isolated) && fail "isolated cleanup allowed an untracked file"
  assert_contains "$out" "uncommitted changes" "isolated teardown lost its untracked guard"
  pass "completion permits untracked files only for in-place tasks and still blocks tracked edits"
}

test_failed_dispatch_retains_in_place_ownership() {
  local rec out real
  command -v tasks-axi >/dev/null 2>&1 || { fail "tasks-axi required for dispatch regression"; }
  real=$(command -v tasks-axi)
  rec=$(make_world dispatch-ownership '[local-only +in-place]')
  read_world "$rec"
  printf '%s\n' '# Backlog' '' '## In flight' '' '## Queued' '' '## Done' > "$W_HOME/data/backlog.md"
  tasks-axi add failed-owner 'Failed dispatch owner' --kind ship --file "$W_HOME/data/backlog.md" >/dev/null || fail "could not add dispatch fixture"
  scaffold_brief "$W_HOME" failed-owner --mode local-only --in-place
  scaffold_brief "$W_HOME" next-owner --mode local-only --in-place
  cat > "$W_FAKEBIN/tasks-axi" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = start ]; then
  echo 'error: forced dispatch failure' >&2
  exit 1
fi
exec "$real" "\$@"
SH
  chmod +x "$W_FAKEBIN/tasks-axi"
  out=$(run_spawn "$W_HOME" "$W_FAKEBIN" "$W_PROJ" "$W_HOME/launch.log" \
    failed-owner "$W_PROJ" --mode local-only --yolo off --in-place) && fail "failed dispatch reported success"
  assert_contains "$out" "retaining in-place task" "failed dispatch did not explain retained ownership"
  assert_grep 'codex ' "$W_HOME/launch.log" "failure did not occur after launch delivery"
  assert_present "$W_HOME/state/failed-owner.meta" "failed dispatch released directory ownership"
  out=$(run_spawn "$W_HOME" "$W_FAKEBIN" "$W_PROJ" "$W_HOME/second-launch.log" \
    next-owner "$W_PROJ" --mode local-only --yolo off --in-place) && fail "a second worker entered after failed dispatch"
  assert_contains "$out" "already occupies" "retained ownership did not block a second worker"
  assert_absent "$W_HOME/state/next-owner.meta" "second worker acquired a record"
  pass "failed dispatch keeps directory ownership after launch and refuses a second worker"
}

test_forced_secondmate_preserves_in_place_child() {
  local out child_home parent_home proj fakebin
  make_teardown_case forced-child child
  child_home="$W_HOME"
  proj="$W_PROJ"
  fakebin="$W_FAKEBIN"
  parent_home="$TMP_ROOT/forced-child/parent"
  mkdir -p "$parent_home/state" "$parent_home/data" "$parent_home/config"
  printf 'mate\n' > "$child_home/.fm-secondmate-home"
  fm_write_meta "$parent_home/state/mate.meta" "window=firstmate:fm-mate" "endpoint_task_id=mate" \
    "worktree=$child_home" "home=$child_home" "project=$child_home" "kind=secondmate"
  printf 'product image\n' > "$proj/image.png"
  mkdir -p "$proj/.claude"
  printf '{"captain":true}\n' > "$proj/.claude/settings.local.json"
  printf 'owned\n' | python3 "$ROOT/bin/fm-workspace-hooks.py" install "$child_home/state" child "$proj" .opencode/plugins/fm-busy-state.js \
    || fail "could not install child-owned hook"
  cp "$child_home/state/child.meta" "$child_home/state/child.saved"
  sed '/^workspace=/d' "$child_home/state/child.saved" > "$child_home/state/child.meta"
  out=$(run_teardown "$parent_home" "$fakebin" mate --force) && fail "forced cleanup accepted an unflagged primary checkout"
  assert_contains "$out" "real project directory" "child preflight did not reject a primary checkout"
  assert_present "$child_home/state/child.meta" "refused child preflight removed ownership"
  mv "$child_home/state/child.saved" "$child_home/state/child.meta"
  out=$(run_teardown "$parent_home" "$fakebin" mate --force) || fail "forced secondmate cleanup failed: $out"
  [ "$(cat "$proj/image.png")" = 'product image' ] || fail "forced cleanup lost product data"
  [ "$(cat "$proj/.claude/settings.local.json")" = '{"captain":true}' ] || fail "forced cleanup lost project settings"
  assert_absent "$proj/.opencode/plugins/fm-busy-state.js" "forced cleanup left owned child hook"
  [ "$(git -C "$proj" symbolic-ref --short HEAD)" = fm/child ] || fail "forced cleanup changed the child's branch"
  assert_absent "$TMP_ROOT/forced-child/treehouse.log" "forced cleanup returned the real project"
  assert_absent "$parent_home/state/mate.meta" "forced cleanup retained parent metadata"
  pass "forced secondmate cleanup preserves the in-place child's project and unowned settings"
}

test_landing_preserves_ignored_collisions() {
  local rec out tip
  rec=$(make_world landing-ignored-checkout '[local-only +in-place]')
  read_world "$rec"
  printf 'old tracked image\n' > "$W_PROJ/image.png"
  git -C "$W_PROJ" add image.png
  git -C "$W_PROJ" commit -qm 'track original image'
  git -C "$W_PROJ" checkout -qb fm/collision
  git -C "$W_PROJ" rm -q image.png
  printf 'image.png\n' > "$W_PROJ/.gitignore"
  git -C "$W_PROJ" add .gitignore
  git -C "$W_PROJ" commit -qm 'keep product image outside git'
  printf 'precious replacement\n' > "$W_PROJ/image.png"
  fm_write_meta "$W_HOME/state/collision.meta" "project=$W_PROJ" "mode=local-only" "workspace=in-place"
  tip=$(git -C "$W_PROJ" rev-parse HEAD)
  out=$(run_merge_local "$W_HOME" collision) && fail "landing overwrote an ignored image during checkout"
  [ "$(cat "$W_PROJ/image.png")" = 'precious replacement' ] || fail "checkout changed the ignored image"
  [ "$(git -C "$W_PROJ" rev-parse HEAD)" = "$tip" ] || fail "refused checkout moved HEAD"

  rec=$(make_world landing-ignored-merge '[local-only +in-place]')
  read_world "$rec"
  printf 'image.png\n' > "$W_PROJ/.gitignore"
  git -C "$W_PROJ" add .gitignore
  git -C "$W_PROJ" commit -qm 'ignore product images'
  git -C "$W_PROJ" checkout -qb fm/collision
  printf 'task image\n' > "$W_PROJ/image.png"
  git -C "$W_PROJ" add -f image.png
  git -C "$W_PROJ" commit -qm 'track task image'
  git -C "$W_PROJ" checkout -q main
  printf 'precious main image\n' > "$W_PROJ/image.png"
  fm_write_meta "$W_HOME/state/collision.meta" "project=$W_PROJ" "mode=local-only" "workspace=in-place"
  tip=$(git -C "$W_PROJ" rev-parse HEAD)
  out=$(run_merge_local "$W_HOME" collision) && fail "landing overwrote an ignored image during merge"
  [ "$(cat "$W_PROJ/image.png")" = 'precious main image' ] || fail "merge changed the ignored image"
  [ "$(git -C "$W_PROJ" rev-parse HEAD)" = "$tip" ] || fail "refused merge moved HEAD"
  pass "landing refuses ignored-file collisions at checkout and merge without changing product data"
}

test_in_place_scout_tracked_changes() {
  local out wt
  make_teardown_case scout-dirty scout-dirty
  sed 's/^kind=ship$/kind=scout/' "$W_HOME/state/scout-dirty.meta" > "$W_HOME/state/scout-dirty.tmp"
  mv "$W_HOME/state/scout-dirty.tmp" "$W_HOME/state/scout-dirty.meta"
  mkdir -p "$W_HOME/data/scout-dirty"
  printf 'Investigation complete.\n' > "$W_HOME/data/scout-dirty/report.md"
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$W_HOME" "$ROOT/bin/fm-captain-hold.sh" complete scout-dirty --none >/dev/null || fail "could not complete scout inventory"
  printf 'tracked edit\n' >> "$W_PROJ/work.txt"
  printf 'product image\n' > "$W_PROJ/image.png"
  out=$(run_teardown "$W_HOME" "$W_FAKEBIN" scout-dirty) && fail "in-place scout cleanup allowed tracked edits"
  assert_contains "$out" "uncommitted changes to tracked files" "scout tracked-change guard did not run"
  assert_present "$W_HOME/state/scout-dirty.meta" "scout refusal removed directory ownership"
  git -C "$W_PROJ" checkout -q -- work.txt
  out=$(run_teardown "$W_HOME" "$W_FAKEBIN" scout-dirty) || fail "untracked content blocked scout cleanup: $out"
  [ "$(cat "$W_PROJ/image.png")" = 'product image' ] || fail "scout cleanup removed untracked content"

  make_teardown_case scout-force scout-force
  sed 's/^kind=ship$/kind=scout/' "$W_HOME/state/scout-force.meta" > "$W_HOME/state/scout-force.tmp"
  mv "$W_HOME/state/scout-force.tmp" "$W_HOME/state/scout-force.meta"
  printf 'tracked edit\n' >> "$W_PROJ/work.txt"
  out=$(run_teardown "$W_HOME" "$W_FAKEBIN" scout-force --force) || fail "explicit force could not complete scout cleanup: $out"
  assert_grep 'tracked edit' "$W_PROJ/work.txt" "forced in-place cleanup discarded tracked content"

  make_teardown_case scout-isolated scout-isolated
  git -C "$W_PROJ" checkout -q main
  wt="$TMP_ROOT/scout-isolated/scratch"
  git -C "$W_PROJ" worktree add -q "$wt" fm/scout-isolated
  fm_write_meta "$W_HOME/state/scout-isolated.meta" "window=firstmate:fm-scout-isolated" \
    "endpoint_task_id=scout-isolated" "worktree=$wt" "project=$W_PROJ" "kind=scout"
  mkdir -p "$W_HOME/data/scout-isolated"
  printf 'Investigation complete.\n' > "$W_HOME/data/scout-isolated/report.md"
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$W_HOME" "$ROOT/bin/fm-captain-hold.sh" complete scout-isolated --none >/dev/null || fail "could not complete isolated scout inventory"
  printf 'scratch edit\n' >> "$wt/work.txt"
  out=$(run_teardown "$W_HOME" "$W_FAKEBIN" scout-isolated) || fail "isolated scout lost its scratch exemption: $out"
  assert_absent "$W_HOME/state/scout-isolated.meta" "isolated scout did not complete"
  pass "in-place scouts refuse tracked edits, allow untracked files and force, and isolated scouts keep their exemption"
}

test_direct_teardown_retains_unconfirmed_endpoint() {
  local out mode
  make_teardown_case endpoint-retained endpoint-retained
  run_merge_local "$W_HOME" endpoint-retained >/dev/null || fail "could not land endpoint fixture"
  mv "$W_FAKEBIN/tmux" "$W_FAKEBIN/tmux-base"
  cat > "$W_FAKEBIN/tmux" <<'SH'
#!/usr/bin/env bash
case "$*" in
  list-windows*)
    case "${FM_TEST_ENDPOINT_MODE:-live}" in
      live) echo fm-endpoint-retained ;;
      unreadable) exit 1 ;;
      gone) : ;;
    esac
    exit 0 ;;
  *pane_current_command*) echo codex; exit 0 ;;
  kill-window*) exit 1 ;;
esac
exec "${0%/*}/tmux-base" "$@"
SH
  chmod +x "$W_FAKEBIN/tmux"
  for mode in live unreadable; do
    out=$(FM_TEST_ENDPOINT_MODE="$mode" run_teardown "$W_HOME" "$W_FAKEBIN" endpoint-retained --force) \
      && fail "teardown released a $mode endpoint"
    assert_contains "$out" "endpoint termination" "teardown did not refuse unconfirmed termination"
    assert_present "$W_HOME/state/endpoint-retained.meta" "teardown released directory ownership"
  done
  out=$(FM_TEST_ENDPOINT_MODE=gone run_teardown "$W_HOME" "$W_FAKEBIN" endpoint-retained) || fail "confirmed absence could not complete teardown: $out"
  assert_absent "$W_HOME/state/endpoint-retained.meta" "confirmed absence did not release ownership"
  pass "direct teardown retains ownership on live and unreadable endpoints, including under force"
}

test_cmux_teardown_confirms_child_home_close() {
  local axis out child_home parent_home target_home target_id title mode code_root
  for axis in direct child; do
    make_teardown_case "cmux-$axis" cmux-owner
    child_home="$W_HOME"
    run_merge_local "$child_home" cmux-owner >/dev/null || fail "could not land cmux task"
    fm_write_meta "$child_home/state/cmux-owner.meta" "backend=cmux" "window=workspace-id:surface-id" \
      "endpoint_task_id=cmux-owner" "cmux_workspace_id=workspace-id" "cmux_surface_id=surface-id" \
      "worktree=$W_PROJ" "project=$W_PROJ" "kind=ship" "mode=local-only" "workspace=in-place"
    target_home=$child_home
    target_id=cmux-owner
    if [ "$axis" = child ]; then
      parent_home="$TMP_ROOT/cmux-$axis/parent"
      mkdir -p "$parent_home/state" "$parent_home/data" "$parent_home/config"
      printf 'mate\n' > "$child_home/.fm-secondmate-home"
      fm_write_meta "$parent_home/state/mate.meta" "window=firstmate:fm-mate" "endpoint_task_id=mate" \
        "worktree=$child_home" "home=$child_home" "project=$child_home" "kind=secondmate"
      target_home=$parent_home
      target_id=mate
    fi
    code_root=$ROOT
    [ "$axis" != child ] || code_root=$child_home
    title=$(FM_HOME="$child_home" FM_ROOT="$code_root" bash -c '. "$1/bin/fm-backend.sh"; fm_backend_source cmux; fm_backend_cmux_scoped_title fm-cmux-owner' _ "$ROOT")
    printf '%s\n' "$title" > "$W_FAKEBIN/cmux-title"
    cat > "$W_FAKEBIN/cmux" <<'SH'
#!/usr/bin/env bash
base=${0%/*}
case "$*" in
  list-windows*)
    if [ -e "$base/cmux-closed" ] && [ "${FM_TEST_CMUX_CLOSE:-}" = malformed ]; then
      echo '{}'
    else
      echo '[{"id":"window-id"}]'
    fi ;;
  'workspace list'*)
    if [ -e "$base/cmux-closed" ] && [ "${FM_TEST_CMUX_CLOSE:-}" = gone ]; then
      echo '{"workspaces":[]}'
    else
      printf '{"workspaces":[{"id":"workspace-id","title":"%s"},{"id":"sibling","title":"other"}]}\n' "$(cat "$base/cmux-title")"
    fi ;;
  list-panes*) echo '{"panes":[{"surface_ids":["surface-id"]}]}' ;;
  close-workspace*)
    printf '%s\n' "$FM_HOME" >> "$base/cmux-close-homes"
    [ "${FM_TEST_CMUX_CLOSE:-}" = error ] && exit 1
    : > "$base/cmux-closed" ;;
esac
exit 0
SH
    chmod +x "$W_FAKEBIN/cmux"
    for mode in live malformed error; do
      rm -f "$W_FAKEBIN/cmux-closed"
      out=$(FM_TEST_CMUX_CLOSE="$mode" run_teardown "$target_home" "$W_FAKEBIN" "$target_id" --force) \
        && fail "cmux $axis teardown released an unconfirmed $mode endpoint"
      assert_contains "$out" "endpoint termination" "cmux $axis did not refuse unconfirmed termination"
      assert_present "$child_home/state/cmux-owner.meta" "cmux $axis lost directory ownership"
      [ "$(tail -1 "$W_FAKEBIN/cmux-close-homes")" = "$child_home" ] || fail "cmux close used the wrong owning home"
    done
    out=$(FM_TEST_CMUX_CLOSE=gone run_teardown "$target_home" "$W_FAKEBIN" "$target_id" --force) || fail "cmux $axis teardown failed after confirmed close: $out"
    assert_absent "$target_home/state/$target_id.meta" "confirmed cmux $axis close retained task ownership"
    assert_present "$W_PROJ/work.txt" "cmux cleanup deleted the real project"
  done
  pass "cmux direct and child cleanup use the owning home and retain records until confirmed closure"
}

test_zellij_endpoint_confirmation() {
  local rec response
  rec=$(make_world zellij-confirmation)
  read_world "$rec"
  cat > "$W_FAKEBIN/zellij" <<'SH'
#!/usr/bin/env bash
[ ! -e "${0%/*}/unreadable" ] || exit 1
cat "${0%/*}/panes.json"
SH
  chmod +x "$W_FAKEBIN/zellij"
  for response in '{}' '[{"id":17,"is_plugin":false}]' '[{"id":18}]'; do
    printf '%s\n' "$response" > "$W_FAKEBIN/panes.json"
    PATH="$W_FAKEBIN:$PATH" bash -c '. "$1/bin/fm-backend.sh"; fm_backend_endpoint_confirmed_gone zellij firstmate:17' _ "$ROOT" \
      && fail "Zellij accepted present or unverified endpoint inventory: $response"
  done
  printf '%s\n' '[{"id":18,"is_plugin":false}]' > "$W_FAKEBIN/panes.json"
  PATH="$W_FAKEBIN:$PATH" bash -c '. "$1/bin/fm-backend.sh"; fm_backend_endpoint_confirmed_gone zellij firstmate:17' _ "$ROOT" \
    || fail "Zellij refused a successful inventory omitting the exact endpoint"
  touch "$W_FAKEBIN/unreadable"
  PATH="$W_FAKEBIN:$PATH" bash -c '. "$1/bin/fm-backend.sh"; fm_backend_endpoint_confirmed_gone zellij firstmate:17' _ "$ROOT" \
    && fail "Zellij treated an unreadable inventory as confirmed termination"
  pass "Zellij termination requires a valid successful inventory omitting the exact pane"
}

# --- claude trust -----------------------------------------------------------

test_claude_trust_in_place_scope() {
  local proj other out config
  proj="$TMP_ROOT/trust/proj"
  other="$TMP_ROOT/trust/other"
  config="$TMP_ROOT/trust/claude-config"
  fm_git_init_commit "$proj"
  fm_git_init_commit "$other"
  mkdir -p "$config"

  out=$(CLAUDE_CONFIG_DIR="$config" "$CLAUDE_TRUST" --in-place "$proj" "$proj" 2>&1) \
    || fail "--in-place trust for the project directory failed: $out"
  assert_contains "$out" "trusted:" "trust registration did not report success"

  out=$(CLAUDE_CONFIG_DIR="$config" "$CLAUDE_TRUST" --in-place "$other" "$proj" 2>&1) \
    && fail "--in-place trust for a different directory should refuse"
  assert_contains "$out" "requires the worktree and project to be the same directory" \
    "--in-place scope refusal missing"

  # Without the flag, a primary checkout is refused exactly as before.
  out=$(CLAUDE_CONFIG_DIR="$config" "$CLAUDE_TRUST" "$proj" "$proj" 2>&1) \
    && fail "a primary checkout without --in-place should refuse"
  assert_contains "$out" "is a primary checkout, not an isolated worktree" \
    "the primary-checkout refusal was lost"
  pass "fm-claude-trust: --in-place trusts exactly the declared project directory and nothing else changed"
}

test_project_mode_workspace_query
test_brief_in_place_scaffolds
test_spawn_refuses_flag_without_declaration
test_spawn_refuses_declaration_without_flag
test_spawn_refuses_brief_drift_both_directions
test_spawn_refuses_in_place_on_wrong_targets
test_flagged_project_spawns_in_place_and_refuses_a_second_worker
test_unflagged_project_still_requires_isolation
test_merge_local_lands_in_place_from_task_branch
test_merge_local_in_place_still_refuses_unsafe_states
test_teardown_preserves_landed_in_place_directory
test_teardown_refuses_unlanded_in_place_work
test_teardown_record_crosschecks_fail_closed
test_claude_trust_in_place_scope

test_workspace_hook_ownership
test_claude_spawn_preserves_preexisting_settings
test_completion_untracked_scope
test_failed_dispatch_retains_in_place_ownership
test_forced_secondmate_preserves_in_place_child

test_in_place_relaunch_preserves_unowned_hooks

test_landing_preserves_ignored_collisions
test_in_place_scout_tracked_changes
test_direct_teardown_retains_unconfirmed_endpoint
test_cmux_teardown_confirms_child_home_close

test_zellij_endpoint_confirmation
