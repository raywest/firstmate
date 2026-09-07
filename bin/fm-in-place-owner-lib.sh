# shellcheck shell=bash
# In-place directory ownership, scoped to one firstmate home. Two homes pointed
# at the same directory are not coordinated. Fresh ACQUIRE requires the task-set
# lock and refuses every existing claimant, including the same task ID; only
# guarded relaunch under the task metadata lock may replace an agent-free
# endpoint. Publication keeps a private copy
# in state/.in-place-owners, so removing ordinary metadata cannot free a live
# directory. RELEASE requires positive endpoint-absence evidence before removing
# either record, including under --force. Unknown presence fails closed.
# Lifecycle record publication,
# removal and close-marker recovery enter here through fm-backlog-transition-lib.

FM_IN_PLACE_OWNER_LIB_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

fm_in_place_owner_load_backend() {
  if ! declare -F fm_backend_endpoint_confirmed_gone >/dev/null 2>&1; then
    # shellcheck source=bin/fm-backend.sh
    . "$FM_IN_PLACE_OWNER_LIB_DIR/fm-backend.sh"
  fi
}

fm_in_place_owner_directory() {
  local state=$1 dir="$1/.in-place-owners"
  if [ -L "$dir" ] || { [ -e "$dir" ] && [ ! -d "$dir" ]; }; then
    FM_BACKLOG_TRANSITION_ERROR="unsafe in-place ownership directory $dir"
    return 1
  fi
  fm_backlog_directory_present "$state" "state directory"
}

fm_in_place_owner_same_endpoint() {
  local left=$1 right=$2 generation=${3:-1} key
  for key in workspace worktree project backend window endpoint_task_id herdr_session herdr_pane_id spawn_gen; do
    [ "$key:$generation" != spawn_gen:0 ] || continue
    [ "$(fm_meta_get "$left" "$key")" = "$(fm_meta_get "$right" "$key")" ] || return 1
  done
}

fm_in_place_owner_endpoint_gone() (
  local meta=$1 state=$2 home current_state
  current_state=${FM_STATE_OVERRIDE:-${FM_HOME:-${FM_ROOT:-}}/state}
  if [ "$(cd "$state" && pwd -P)" != "$(cd "$current_state" 2>/dev/null && pwd -P)" ]; then
    home=$(cd "$state/.." && pwd -P) || return 1
    unset FM_ROOT_OVERRIDE
    # shellcheck disable=SC2030 # Deliberate: this function body is a subshell, so the child-home env never leaks to the caller.
    export FM_HOME="$home" FM_ROOT="$home" FM_STATE_OVERRIDE="$state"
    export FM_CONFIG_OVERRIDE="$home/config" FM_DATA_OVERRIDE="$home/data"
  fi
  fm_in_place_owner_load_backend || return 1
  fm_backend_validate_task_endpoint "$meta" "$(basename "$meta" .meta)" >/dev/null || return 1
  fm_backend_endpoint_confirmed_gone "$(fm_backend_of_meta "$meta")" \
    "$(fm_backend_target_of_meta "$meta")" "fm-$(basename "$meta" .meta)"
)

fm_in_place_owner_check() {
  local meta=$1 state=$2 record owned="$2/.in-place-owners/${1##*/}"
  fm_in_place_owner_directory "$state" || return 1
  fm_in_place_owner_load_backend || return 1
  for record in "$owned" "$meta"; do
    [ ! -L "$record" ] || { FM_BACKLOG_TRANSITION_ERROR="unsafe ownership record $record"; return 1; }
    [ -e "$record" ] || continue
    if [ "$record" = "$owned" ] || [ "$(fm_meta_get "$record" workspace)" = in-place ]; then
      if ! fm_in_place_owner_endpoint_gone "$record" "$state"; then
        FM_BACKLOG_TRANSITION_ERROR="endpoint termination is not confirmed; retaining in-place task $(basename "$meta" .meta) and its directory ownership records"
        return 1
      fi
    fi
  done
}

fm_in_place_owner_acquire() {
  local state=$1 id=$2 worktree=$3 mode=${4:-fresh} record other path lock
  fm_in_place_owner_directory "$state" || return 1
  fm_in_place_owner_load_backend || return 1
  worktree=$(cd "$worktree" && pwd -P) || return 1
  case "$mode" in
    fresh)
      lock=$(fm_task_set_lock_path "$state") || return 1
      if [ "$(cat "$lock/pid" 2>/dev/null)" != "${BASHPID:-$$}" ]; then
        FM_BACKLOG_TRANSITION_ERROR="in-place acquisition requires this process's task-set lock"
        return 1
      fi
      ;;
    relaunch)
      lock=$(fm_meta_lock_path "$state/$id.meta") || return 1
      if [ "$(cat "$lock/pid" 2>/dev/null)" != "${BASHPID:-$$}" ]; then
        FM_BACKLOG_TRANSITION_ERROR="in-place relaunch requires this process's task metadata lock"
        return 1
      fi
      record="$state/$id.meta"
      if [ "$(fm_meta_get "$record" workspace)" != in-place ] \
          || [ "$(fm_backend_agent_state "$(fm_backend_of_meta "$record")" "$(fm_backend_target_of_meta "$record")")" != dead ]; then
        FM_BACKLOG_TRANSITION_ERROR="in-place replacement requires guarded relaunch of an agent-free endpoint"
        return 1
      fi
      ;;
    *) return 1 ;;
  esac
  for record in "$state"/*.meta "$state/.in-place-owners"/*.meta; do
    [ -e "$record" ] || [ -L "$record" ] || continue
    [ -f "$record" ] && [ ! -L "$record" ] || return 1
    other=$(basename "$record" .meta)
    path=$(fm_meta_get "$record" worktree)
    if [ -z "$path" ]; then
      if [ "${record%/*}" = "$state/.in-place-owners" ]; then
        FM_BACKLOG_TRANSITION_ERROR="unreadable in-place ownership record $record"
        return 1
      fi
      continue
    fi
    path=$(cd "$path" 2>/dev/null && pwd -P) || path=$(fm_meta_get "$record" worktree)
    if [ "$other" = "$id" ] || [ "$path" = "$worktree" ]; then
      if [ "$mode" = relaunch ] && [ "$other" = "$id" ] && [ "$path" = "$worktree" ]; then
        fm_in_place_owner_same_endpoint "$record" "$state/$id.meta" 0 || {
          FM_BACKLOG_TRANSITION_ERROR="in-place relaunch identity disagrees with its ownership record"
          return 1
        }
        continue
      fi
      FM_BACKLOG_TRANSITION_ERROR="task '$other' already occupies '$path'; an in-place project takes one worker at a time within one firstmate home (two homes pointing at the same directory are not coordinated) - finish and clean up that task first"
      return 1
    fi
  done
  FM_IN_PLACE_OWNER_ACQUIRED_META="$state/$id.meta"
  FM_IN_PLACE_OWNER_ACQUIRED_WORKTREE=$worktree
}

fm_in_place_owner_publish() {
  local source=$1 target=$2 state=$3 owned="$3/.in-place-owners/${2##*/}" prior tmp worktree lock
  fm_in_place_owner_directory "$state" || return 1
  fm_in_place_owner_load_backend || return 1
  if [ "$(fm_meta_get "$source" workspace)" != in-place ]; then
    if [ -e "$owned" ] || [ "$(fm_meta_get "$target" workspace)" = in-place ]; then
      FM_BACKLOG_TRANSITION_ERROR="cannot replace an in-place ownership record with an isolated task"
      return 1
    fi
    return 0
  fi
  lock=$(fm_meta_lock_path "$target") || return 1
  if [ "$(cat "$lock/pid" 2>/dev/null)" != "${BASHPID:-$$}" ]; then
    FM_BACKLOG_TRANSITION_ERROR="in-place publication requires this process's task metadata lock"
    return 1
  fi
  [ ! -L "$owned" ] || { FM_BACKLOG_TRANSITION_ERROR="unsafe ownership record $owned"; return 1; }
  prior=$target
  [ ! -e "$owned" ] || prior=$owned
  worktree=$(cd "$(fm_meta_get "$source" worktree)" && pwd -P) || return 1
  if [ "${FM_IN_PLACE_OWNER_ACQUIRED_META:-}" != "$target" ] \
      || [ "${FM_IN_PLACE_OWNER_ACQUIRED_WORKTREE:-}" != "$worktree" ]; then
    if [ ! -f "$prior" ] || ! fm_in_place_owner_same_endpoint "$source" "$prior"; then
      FM_BACKLOG_TRANSITION_ERROR="in-place publication requires ownership acquisition or guarded relaunch"
      return 1
    fi
  fi
  if [ ! -e "$prior" ]; then
    fm_in_place_owner_acquire "$state" "$(basename "$target" .meta)" "$worktree" fresh || return 1
  fi
  mkdir -p "$state/.in-place-owners" || return 1
  tmp=$(mktemp "$state/.in-place-owners/.publish.XXXXXX") || return 1
  if ! cat "$source" > "$tmp" || ! mv -f "$tmp" "$owned"; then
    rm -f "$tmp"
    return 1
  fi
}

fm_in_place_owner_remove() {
  local meta=$1 state=$2 label=${3:-task record} owned="$2/.in-place-owners/${1##*/}" lock acquired=0 rc=0
  fm_in_place_owner_directory "$state" || return 1
  fm_in_place_owner_load_backend || return 1
  if [ -e "$owned" ] || [ "$(fm_meta_get "$meta" workspace)" = in-place ]; then
    if ! declare -F fm_lock_try_acquire >/dev/null 2>&1; then
      # shellcheck source=bin/fm-wake-lib.sh
      . "$FM_IN_PLACE_OWNER_LIB_DIR/fm-wake-lib.sh"
    fi
    lock=$(fm_meta_lock_path "$meta") || return 1
    if [ "$(cat "$lock/pid" 2>/dev/null)" != "${BASHPID:-$$}" ]; then
      fm_lock_try_acquire "$lock" || {
        FM_BACKLOG_TRANSITION_ERROR="in-place ownership is locked by another task operation"
        return 1
      }
      acquired=1
    fi
  fi
  if fm_in_place_owner_check "$meta" "$state"; then
    if ! rm -f "$meta" || [ -e "$meta" ] || [ -L "$meta" ] \
        || ! rm -f "$owned" || [ -e "$owned" ] || [ -L "$owned" ]; then
      FM_BACKLOG_TRANSITION_ERROR="$label could not be removed completely for $meta"
      rc=1
    fi
  else
    rc=1
  fi
  [ "$acquired" = 0 ] || fm_lock_release "$lock"
  return "$rc"
}

fm_in_place_owner_close_marker() {
  local phase=$1 state=$2 id=$3 in_place=0
  shift 3
  fm_in_place_owner_load_backend || return 1
  if [ -e "$state/.in-place-owners/$id.meta" ] || [ "$(fm_meta_get "$state/$id.meta" workspace)" = in-place ]; then
    in_place=1
  fi
  case "$phase:$in_place" in
    before:0|after:1) fm_backlog_close_marker_write "$state" "$id" "$@" ;;
    before:1|after:0) return 0 ;;
    *) return 1 ;;
  esac
}

fm_in_place_owner_recovery_record() {
  local meta=$1 state=$2 owned="$2/.in-place-owners/${1##*/}"
  fm_in_place_owner_directory "$state" || return 1
  if [ -e "$owned" ] || [ -L "$owned" ]; then
    printf '%s\n' "$owned"
  else
    printf '%s\n' "$meta"
  fi
}

fm_in_place_owner_home_ready() {
  local state=$1 phase=$2 record
  [ -d "$state" ] || return 0
  fm_in_place_owner_directory "$state" || return 1
  for record in "$state/.in-place-owners"/*.meta; do
    [ -e "$record" ] || [ -L "$record" ] || continue
    if [ "$phase" = remove ] || [ ! -f "$state/${record##*/}" ]; then
      # shellcheck disable=SC2034 # Output global, read by the sourcing caller.
      FM_BACKLOG_TRANSITION_ERROR="in-place ownership remains at $record; reconcile the task before removing its home"
      return 1
    fi
  done
}
