# Watcher continuity

The watcher remains intentionally one-shot: one actionable reason closes one watcher cycle.
Must-work continuity now lives above that process boundary instead of depending on the model remembering a re-arm step.
This document owns the per-wake watcher protocols; the supported Claude or Codex tmux/herdr always-on daemon path is documented in [`alwayson-triage.md`](alwayson-triage.md).

## Ownership

Pi's `.pi/extensions/fm-primary-pi-watch.ts` and OpenCode's `.opencode/plugins/fm-primary-watch-arm.js` own continuous re-arm after an actionable child close.
Each adapter starts the next arm before delivering the wake prompt, checks current session-lock ownership at launch, preserves one child or scheduled retry at a time, and applies bounded exponential retry after an unexpected or failed close.
A failed follow-up never cancels continuity restoration.

## Actionable wake ordering

After an actionable Pi or OpenCode child close, the adapter starts and verifies one singleton successor before it delivers the original wake.
It waits at most one readiness timeout per attempt, then sends TERM and waits a bounded retirement confirmation before the next lock-verified exponential retry.
If the unready arm does not retire within that bound, the adapter keeps ownership, starts no overlapping retry, and delivers the typed fallback immediately.
When that retained arm later closes, its actual close is classified as a new supervised event without replaying the earlier fallback.
After the configured retry bound is exhausted, it delivers the original wake with a typed continuity-restoration failure even if every successor arm hung without reporting readiness.
This is deliberate Option B ordering: the fleet is protected before the model handles the wake whenever restoration succeeds, but the model is never left blind when it does not.

Unflipped Claude harness/backend combinations retain the native tracked background-task completion path.
Its PreToolUse continuity gate allows wake drain, watcher arm recovery, daemon launch recovery, and independently fail-closed teardown, but refuses only other fleet commands while tasks are in flight and neither an identity-matched live watcher nor a live daemon holds the home lock.
Allowing an ordinary literal teardown prevents a terminal wake from creating a recovery circle: forced or dynamically constructed teardown remains blocked, ordinary teardown itself still refuses dirty, unlanded, incomplete-scout, and unresolved-decision cases, and the turn-end guard continues to require supervision for any tasks left in flight.
Codex retains its bounded foreground checkpoint protocol on backends other than tmux or herdr.
Grok retains its tracked background-task notification protocol.
No adapter starts a replacement with shell `&`.

The turn-end guard implementation and adapters remain the final backstop rather than the normal continuity mechanism.
On a supported Claude or Codex tmux/herdr setup, its live-daemon satisfier bridges the expected gap between one-shot watcher children.

## Arm-layer cycle contract

`bin/fm-watch-arm.sh` never returns a clean empty success.
An actionable child output returns that reason normally.
A zero/empty child return rechecks the home lock and beacon, and attaches to a verified healthy successor when one exists.
An attached arm follows verified identity-matched successors the same way.

When neither an owned child's output nor a verified successor explains a cycle's end, the arm layer does not assume nothing happened.
Immediately before forking a watcher or attempting to attach to one, the arm snapshots `state/.wake-queue.seq` under the queue lock.
`cycle_begin` receives that snapshot rather than reading the queue itself, and replacement watchers retain the original cycle baseline.
At cycle end, a valid `state/.wake-queue` row with a later sequence proves a real wake landed durably even though this process could not see its reason text (an attached arm never captures the owning watcher's stdout, and an owned child can die between a successful `fm_wake_append` and its own `wake()` call).
That case reports `watcher: cycle ended - N wake(s) already queued ...` and exits nonzero (re-arm is still needed - no watcher is running) but is never the literal `watcher: FAILED` text, so a caller keying on that exact string does not treat it as an alarm.
Only a cycle with no valid queue row after its sequence snapshot still emits the typed `watcher: FAILED - cycle ended without an actionable reason` result.

The arm layer appends one tab-separated record per observed cycle to `state/.watch-cycle-exits.log`.
Each record includes arm and watcher PIDs, start and end timestamps, exit code and signal, classified reason, beacon age, lock identity before and after close, and successor disposition.
The file is size-capped through `FM_WATCH_CYCLE_LOG_MAX_BYTES` and `FM_WATCH_CYCLE_LOG_KEEP_LINES`.
`state/.watch-triage.log` remains only the watcher's bounded absorbed-wake debug log and carries no lifecycle semantics.
It is never an operational dependency and is safe to delete.

The default 300-second grace is unchanged.
Only the watcher process touches `state/.last-watcher-beat`; no helper process can make a wedged watcher appear healthy.

## Regression coverage

`tests/fm-pi-watch-extension.test.sh` checks Pi's first-cycle-or-explicit-repair tool metadata and ownership-based redundant-call no-ops, then simulates actionable and empty child closes against the actual Pi and OpenCode close handlers, blocks prompt delivery to prove the successor launches first, verifies single-flight behavior, changes the session lock before close to prove ownership is rechecked, and hangs each successor arm to prove bounded fallback delivery includes the typed restoration failure.
`tests/fm-watcher-lock.test.sh` covers verified-successor attach, the typed self-eviction failure, bounded and successor-linked lifecycle rows, a SIGSTOP counterfactual that distinguishes a live PID from a stale beacon before classifying termination, and the already-queued-wake report (both the owned and attached shapes) alongside the still-covered genuinely-empty FAILED case.
`tests/fm-continuity-pretool-check.test.sh` proves the Claude gate rejects only non-recovery fleet execution in the precise unhealthy state and preserves the existing Stop registration.
`tests/fm-subagent-pretool-check.test.sh` proves Claude retains only the non-status Bash seatbelts.
`tests/fm-turnend-guard.test.sh` covers the turn-end guard.

## Active limits and verification

The goal is continuity without a Pi or OpenCode model-memory re-arm step.
No zero-latency guarantee is claimed because lock verification, watcher startup, and bounded retry delays remain deliberate safety work.
OpenCode support targets persistent TUI sessions rather than headless `opencode run`.
Claude depends on the native tracked background-task completion path (or the always-on daemon on a supported tmux/herdr combination), Grok retains native background-completion notifications, and Codex retains bounded foreground checkpoints.

[`verification/supervision.md`](verification/supervision.md#watcher-continuity) records the current five-harness live evidence and exact opt-in commands.
