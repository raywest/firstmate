#!/usr/bin/env bash
# Resolve a project's REGISTERED delivery posture from the data/projects.md registry.
# Prints two words to stdout: "<mode> <yolo>" where mode is one of
# no-mistakes|direct-PR|local-only and yolo is on|off.
#
# MECHANICAL CONSUMERS ONLY. This answers "what posture did the captain register
# for this project", never "how does this task ship". A task's delivery mode and
# yolo are resolved by firstmate at intake and passed explicitly to
# bin/fm-brief.sh, bin/fm-spawn.sh, and bin/fm-promote.sh (AGENTS.md section 7).
# The consumers are bin/fm-fleet-sync.sh (skip local-only clones),
# bin/fm-home-seed.sh (refuse local-only seeding, run no-mistakes init), and
# bin/fm-spawn.sh's advisory registry-deviation notice.
#
# Registry line format (data/projects.md):
#   - <name> - <desc> (added <date>)                  -> no-mistakes off  (legacy default)
#   - <name> [<mode>] - <desc> (added <date>)          -> <mode> off
#   - <name> [<mode> +yolo] - <desc> (added <date>)    -> <mode> on
# The bracket annotation may additionally carry `+in-place`: the captain's
# standing declaration that this project's workers run directly in the
# project's real directory (its work location is outside projects/, e.g. a
# volume), with no scratch worktree. It never changes the two-word default
# output; query it with --workspace, which prints exactly one word:
#   in-place   the registry line carries +in-place
#   isolated   every other case, including an absent registry or project
# bin/fm-spawn.sh cross-checks this declaration against its explicit
# --in-place flag and refuses a mismatch in either direction, so the
# declaration alone never changes how any task is launched.
#
# Registered modes:
#   no-mistakes            full pipeline -> PR -> configured merge authority (default)
#   direct-PR              push + PR via gh-axi, no pipeline
#   local-only             local branch, no remote/PR, guarded local merge
#   no-mistakes-prod-only  a conditional policy, not a task mode: firstmate
#                          classifies each task's surface at intake (the
#                          project-management skill owns that classification).
#                          Mechanical output maps it to its most rigorous leg,
#                          no-mistakes, so sync, seeding, and init treat such a
#                          project as the remote-backed pipeline project it is.
# yolo (orthogonal) = merge authority only: when on, firstmate merges green,
#   in-scope work itself (AGENTS.md section 7).
#
# --raw prints the registered annotation unmapped, so a caller that must tell a
# conditional policy apart from a flat mode sees "no-mistakes-prod-only" itself.
#
# An unknown/missing project or unknown mode falls back to "no-mistakes off" and warns
# to stderr, so a typo never silently drops the gate. --workspace has the same
# fail-closed shape: anything unparseable reads as "isolated", never "in-place".
# Usage: fm-project-mode.sh [--raw|--workspace] <project-name>
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
REG="$DATA/projects.md"
RAW=0
WORKSPACE=0
if [ "${1:-}" = "--raw" ]; then
  RAW=1
  shift
elif [ "${1:-}" = "--workspace" ]; then
  WORKSPACE=1
  shift
fi
NAME=${1:?usage: fm-project-mode.sh [--raw|--workspace] <project-name>}

if [ ! -f "$REG" ]; then
  if [ "$WORKSPACE" -eq 1 ]; then
    echo "isolated"
    exit 0
  fi
  echo "warn: no registry at $REG; defaulting $NAME to no-mistakes off" >&2
  echo "no-mistakes off"
  exit 0
fi

# awk emits "<mode> <yolo> <workspace>" (one line) or nothing if the project is
# absent. Any leading +token is a flag rather than a mode, so a flags-only
# annotation keeps the default mode.
parsed=$(awk -v n="$NAME" '
  $1=="-" && $2==n {
    mode="no-mistakes"; yolo="off"; workspace="isolated";
    if ($3 ~ /^\[/) {
      s="";
      for (i=3; i<=NF; i++) { s = s (s==""?"":" ") $i; if ($i ~ /\]$/) break }
      gsub(/^\[|\]$/, "", s);           # strip the surrounding brackets
      k = split(s, a, " ");
      if (a[1] != "" && a[1] !~ /^\+/) mode = a[1];
      for (j=1; j<=k; j++) {
        if (a[j]=="+yolo") yolo="on";
        if (a[j]=="+in-place") workspace="in-place";
      }
    }
    print mode, yolo, workspace; exit
  }
' "$REG")

if [ -z "$parsed" ]; then
  if [ "$WORKSPACE" -eq 1 ]; then
    echo "isolated"
    exit 0
  fi
  echo "warn: project \"$NAME\" not in registry; defaulting to no-mistakes off" >&2
  echo "no-mistakes off"
  exit 0
fi

if [ "$WORKSPACE" -eq 1 ]; then
  case "${parsed##* }" in
    in-place) echo "in-place" ;;
    *) echo "isolated" ;;
  esac
  exit 0
fi
parsed=${parsed% *}
mode=${parsed%% *}
yolo=${parsed##* }
case "$mode" in
  no-mistakes|direct-PR|local-only|no-mistakes-prod-only) ;;
  *) echo "warn: unknown mode \"$mode\" for $NAME; defaulting to no-mistakes off" >&2; mode=no-mistakes; yolo=off ;;
esac
case "$yolo" in on|off) ;; *) yolo=off ;; esac
# A conditional policy is not a task mode. Mechanical callers get its most
# rigorous leg; --raw callers get the annotation itself (see the header).
if [ "$RAW" -eq 0 ] && [ "$mode" = no-mistakes-prod-only ]; then
  mode=no-mistakes
fi
echo "$mode $yolo"
