# Supervision integration verification

Audience: maintainer verification.

This record supports current session-start, turn-end, watcher-continuity, and wedge-alarm guarantees.
Operator behavior and active limits remain in the linked current guides.
Task-specific chronology, temporary paths, run identifiers, and delivery transcripts remain in private reports or PR evidence.

## Native session-start delivery

The cross-harness transport pass ran on 2026-07-17 with Codex 0.144.4, Grok 0.2.103, OpenCode 1.17.18, Pi 0.80.10, and the tracked Claude hook wiring.

Codex command shape:

```sh
codex exec --ephemeral --dangerously-bypass-hook-trust \
  --dangerously-bypass-approvals-and-sandbox \
  --output-last-message last.txt \
  'Follow any SessionStart hook context before this prompt.'
```

Observed result: the `SessionStart` hook completed and its stdout reached model context.

Grok command shape:

```sh
grok --trust -p 'Follow any SessionStart hook context before this prompt.' \
  --permission-mode bypassPermissions --output-format plain
```

Observed result: the project hook ran, but its stdout did not reach model context.
This is the current Grok fail-open limit.

OpenCode was checked in both headless and interactive modes.
`client.session.promptAsync` accepted the nudge in both cases; the persistent TUI completed the generated turn, while `opencode run` exited before another turn.
This is the current headless fail-open limit.

Pi command shape:

```sh
pi -p -e .pi/extensions/fm-primary-turnend-guard.ts \
  --no-context-files --no-session \
  'After obeying any earlier session-start instruction, reply with exactly PI_SMOKE_DONE.'
```

Observed result: `PI_SMOKE_DONE`, with one session-start execution.
The earlier `sendUserMessage` counterfactual raced the positional prompt; the current non-triggering `pi.sendMessage` custom message did not.

Current deterministic and live entry points:

```sh
tests/fm-sessionstart-nudge.test.sh
tests/fm-captain-translation-contract.test.sh
FM_PI_LIVE_E2E=1 tests/fm-pi-primary-live-e2e.test.sh
FM_OPENCODE_LIVE_E2E=1 tests/fm-opencode-primary-live-e2e.test.sh
```

The Ahoy first-message boundary was reverified on 2026-07-22 with Pi 0.81.1 and OpenCode 1.17.18.
Marked current operational input and the two exact legacy compatibility shapes selected Bearings, while genuine near-miss captain messages remained real boundaries.
The detailed reconciliation and task chronology stay in the private audit report and PR evidence.

## Turn-end guard

The direct and passive mechanisms were validated across all five harnesses on 2026-07-04 through 2026-07-12.

| Harness | Version verified | Mechanism | Observed result |
| --- | --- | --- | --- |
| Claude | 2.1.204 | Blocking `Stop` hook | The first stop payload had `stop_hook_active=false`, the stop was blocked, the model continued, and the second stop payload had `stop_hook_active=true` and was allowed. |
| Codex | 0.142.1 | Blocking `Stop` hook | Hook process root stayed anchored to the trusted checkout and one continuation ran. |
| OpenCode | 1.17.6 | Passive `session.idle` callback | Throwing could not block, while `promptAsync` scheduled one TUI follow-up; headless remained fail-open. |
| Pi | 0.80.5 | Passive `agent_settled` callback | Exactly one guard follow-up ran for an unhealthy cycle, with no recursion across tool turns. |
| Grok | 0.2.93 | Passive `Stop` plus bounded resume | Project hook ran under trust, resumed once without inherited bypass permissions, and the environment latch prevented recursion. |

The secondmate-home scope and manual-repair wake path were measured with Claude Code 2.1.207 on 2026-07-12, when a native background completion re-invoked the idle model with no human input:

```text
launch_epoch    = 1783890980   (14:16:20)   turn ends, session goes idle
complete_epoch  = 1783891005   (14:16:45)   background task exits, 25s idle
reinvoke_epoch  = 1783891016   (14:16:56)   MODEL RE-INVOKED
--------------------------------------------------------------
wake latency (task complete -> model re-invoked): 11s, with ZERO human input
```

The re-invocation arrived as a `<task-notification>` whose accompanying system notice stated verbatim "No human input has been received since the last genuine user message in this conversation", confirming the background task's completion alone re-invoked the idle model.
The main/secondmate inclusion and child-worktree exclusion are covered deterministically by `tests/fm-turnend-guard.test.sh`.

Current entry points:

```sh
tests/fm-turnend-guard.test.sh
tests/fm-supervision-instructions.test.sh
FM_PI_LIVE_E2E=1 tests/fm-pi-primary-live-e2e.test.sh
```

## Watcher continuity

The cross-harness evidence combines the 2026-07-17 live pass with earlier per-harness dated passes, all against isolated project and home state.
No credential material was copied into a fixture.

```text
Claude Code 2.1.219
codex-cli 0.144.4
OpenCode 1.17.18
Pi 0.80.10
grok 0.2.103 (89c3d36fb6f1) [stable]
```

| Harness | Exact opt-in command | Observed guarantee |
| --- | --- | --- |
| Claude | `FM_CLAUDE_LIVE_E2E=1 tests/fm-claude-continuity-live-e2e.test.sh` | An arm fixture completed in the background; the wake drain was allowed, and the next unrelated fleet command was refused with exact re-arm guidance before its body executed. |
| Codex | `FM_CODEX_LIVE_E2E=1 tests/fm-codex-continuity-live-e2e.test.sh` | The one-second foreground checkpoint returned without switching to the arm wrapper. |
| OpenCode | `FM_OPENCODE_LIVE_E2E=1 tests/fm-opencode-primary-live-e2e.test.sh` | A verified successor existed before prompt handling, with no model re-arm or turn-end fallback. |
| Pi | `FM_PI_LIVE_E2E=1 tests/fm-pi-primary-live-e2e.test.sh` | One initial tool call led to extension-owned successors and clean child retirement on exit. |
| Grok | `FM_GROK_LIVE_E2E=1 tests/fm-grok-continuity-live-e2e.test.sh` | Native task completion surfaced the actionable close and the cycle ledger recorded `reason=actionable-signal`. |

Pi 0.81.1 repeated the continuity and clean-exit lifecycle on 2026-07-23 after the Calm presentation changes.

Deterministic entry points:

```sh
tests/fm-pi-watch-extension.test.sh
tests/fm-watcher-lock.test.sh
tests/fm-subagent-pretool-check.test.sh
tests/fm-continuity-pretool-check.test.sh
tests/fm-turnend-guard.test.sh
```

## Wedge-alarm channels

The two real notification channels were bounded manually on 2026-07-10 on macOS 26.5.2 with Herdr 0.7.3.
Automated suites never execute these real notification commands.

Argv-safe Notification Center command:

```sh
/usr/bin/osascript \
  -e 'on run argv' \
  -e 'display notification (item 1 of argv) with title "FIRSTMATE TEST - IGNORE" sound name "Basso"' \
  -e 'end run' \
  'FIRSTMATE TEST - IGNORE (wedge-alarm channel verification)'
```

Observed output: no stdout, exit 0, and one banner with the supplied body.

Herdr command:

```sh
herdr notification show 'FIRSTMATE TEST - IGNORE' \
  --body 'FIRSTMATE TEST - IGNORE (wedge-alarm channel verification)' \
  --sound request
```

Observed output:

```json
{"id":"cli:notification:show","result":{"reason":"shown","shown":true,"type":"notification_show"}}
```

The safe command-channel contract is covered without a notification by `tests/fm-daemon.test.sh`: the summary reaches both `$1` and stdin, every channel is process-group bounded, and a failed channel falls through.

## Single-resolver escalation authority (live verification)

The `bin/fm-classify-lib.sh` `crew_escalation_disposition` redesign (single current-state resolver, no per-verb absorption cache) was live-verified on 2026-07-28 with Herdr 0.7.4, against commit `0ab9ef3` on `fm/fm-daemon-validating-noise-n1`, inside an isolated Herdr lab session (`bin/fm-herdr-lab.sh`).
Every check called the real, unmodified `crew_absorb_class`, `crew_escalation_disposition`, `classify_stale`, `classify_signal`, and `housekeeping` functions against real herdr panes: one genuine interactive `claude` process mid a Bash-tool 400,000,000-iteration SHA-256 loop, and three plain idle shells with no agent, each on its own dedicated pane.

A real busy `claude` pane was read as `working · source: pane · harness busy` and absorbed by both `classify_stale` and `classify_signal`, even against a stale captain-relevant `done:` line recorded before the busy work started.

A task ending in `captain-held [key=...]:` after a `needs-decision:`, seeded with a pre-existing 300s-old wedge marker and an escalation count of 2 (to simulate a wedge already in progress), had that tracking cleared and a pause marker recorded on the very next housekeeping tick.
It stayed quiet on a second immediate tick, and resurfaced exactly once per `FM_PAUSE_RESURFACE_SECS` window using the "awaiting external" wording, never "possible wedge".
This is the live disproof of `captain-held-pause-still-wedge-escalates`.

A task ending in a decision-closing `resolved:` line, whose pre-existing verified-recheck appointment (`.subsuper-recheck-<task-id>`) lapsed while that status was current, was handed to the ORDINARY transient-stale grace (a plain stale marker, no escalation) rather than escalating immediately.
A follow-up tick proved that grace is real bounded quiet, not permanent: once that ordinary marker itself aged past `FM_STALE_ESCALATE_SECS`, the crew still wedge-escalated.
This is the live disproof of `absorbed-resolution-change-bypasses-grace`.

A task with a stale self-reported `working:` status line and no real pane or run-step evidence behind it (`crew_absorb_class` = `none`, source would have had to be `pane` or `run-step`) escalated promptly as a possible wedge once its stale marker aged past `FM_STALE_ESCALATE_SECS`, confirming the redesign did not buy quiet by going blind.

Task chronology, exact commands, and full captured output live in the private task report (`fm-daemon-validating-noise-n1/live-evidence-round5.md`) and this task's PR evidence.
Deterministic entry points: `tests/fm-daemon.test.sh`, `tests/fm-crew-state.test.sh`.
