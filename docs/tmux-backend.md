# tmux runtime backend

tmux is Firstmate's verified reference runtime backend and the fully supported baseline for secondmate homes.
[`configuration.md`](configuration.md#runtime-backend-configbackend--fm_backend) owns shared backend selection and metadata semantics.

## Setup

Install tmux with `brew install tmux` or your platform package manager.
The universal harness and toolchain requirements are in [`configuration.md`](configuration.md#toolchain).

tmux is the hard default when no explicit setting or runtime auto-detection selects another backend.
Select it explicitly with local `config/backend` containing `tmux`, with `FM_BACKEND=tmux` for one launch, or by asking Firstmate to use tmux.
An explicit selection is also the opt-out from Herdr or cmux runtime auto-detection.

No provisioning is required before the first task.

## Watching the crew

For the best visible experience, launch the primary harness inside a tmux session:

```sh
tmux new -s firstmate
```

Nothing to provision up front.
The first crewmate spawn creates whatever tmux session and window it needs.

## Run inside tmux for the best experience

Launch your harness from inside a tmux session (for example, `tmux new -s my-firstmate`, then start your agent).
Without an `FM_TMUX_SESSION` override, every crewmate window then lands in that same session, where you can watch the crew work in real time or type into any window to intervene.
When following the commands below, use that session's actual name.
Inside tmux, `tmux display-message -p '#S'` prints it.

## Outside tmux: the detached, home-unique session

If you launch your harness outside of tmux, crewmate windows land in a detached session created on first use, named `fm-<hometag>` - a short, deterministic tag derived from this installation's own path (`fm_backend_tmux_session_name` in [`bin/backends/tmux.sh`](../bin/backends/tmux.sh); the tag itself is `bin/fm-backend-hometag-lib.sh`, shared with the cmux and zellij adapters).
After spawning a task, use its recorded target to print this firstmate home's exact session name.
Run these commands from the firstmate repository root when `FM_HOME` is unset, or set `FM_HOME` to the active operational home:

```sh
sed -n 's/^window=\([^:]*\):.*/\1/p' "${FM_HOME:-"$PWD"}/state/<task-id>.meta"
```

Attach to the recorded session with:

```sh
tmux attach -t "$(sed -n 's/^window=\([^:]*\):.*/\1/p' "${FM_HOME:-"$PWD"}/state/<task-id>.meta")"
```

Set `FM_TMUX_SESSION` to pin an exact literal instead of the derived default (an explicit operator choice always wins, whether firstmate is running inside tmux or not); that literal is the session to attach to.

Before this per-home naming, every installation on a machine shared one hardcoded session name (`firstmate`, and before that the even more generic `default`) - a soft target for an unrelated tool's ambient `tmux kill-session` sharing the same tmux server, and a real collision when two homes on one machine both fell back to it (`data/fm-killsweep-scout-s3/report.md`, referenced from `AGENTS.md` section 1).
Existing windows recorded under `firstmate:` or `default:` continue to resolve from their metadata without state-file migration.
Without `FM_TMUX_SESSION`, new spawns outside tmux use the home-unique default.

## Watching and typing into crew windows

Once attached, each crewmate is its own window named `fm-<id>`:

```sh
tmux list-windows -t <session-name>          # see every crew window
tmux select-window -t <session-name>:fm-<id> # jump to one, or use ctrl-b <n>
```

Use the recorded session described above.
Typing directly into an attached window is authoritative direct intervention - the first mate treats it the same as any other captain instruction and reconciles at the next heartbeat.
You do not need to attach at all for routine supervision: from an active firstmate session, the first mate reads crew windows itself with `bin/fm-peek.sh fm-<id>` (a bounded, read-only capture) and steers a crew with `FM_HOME=<this-firstmate-home> bin/fm-send.sh fm-<id> "<text>"` unless `FM_HOME` is already set to the active firstmate home.

## Verifying it works

Ask the first mate for any small piece of work, or spawn a trivial scout task, and confirm a new window shows up:

```sh
tmux list-windows -t <session-name>
tmux select-window -t <session-name>:fm-<id>
```

Use the recorded session described above.
You should see a `fm-<id>` window for the task, live and updating as the crewmate works.

Verify setup by spawning a small task and confirming its `fm-<id>` window appears in the selected session.

## Current behavior and safety

A target-existence check proves only that the pane exists.
The deeper tmux agent-liveness probe first verifies exact window membership, then reads `#{pane_current_command}` to distinguish a running harness process from a bare idle shell.
It classifies recognized Claude, Codex, OpenCode, Grok, and Kimi process names as `alive`, common shells as `dead`, an authoritatively absent window as `missing`, unreadable state as `unreadable`, and every other process as `ambiguous`.
Only `dead` and `missing` authorize recovery because a false dead result could launch a duplicate agent.

Pi runs through a generic `node` process name and cannot be attributed confidently from the tmux foreground-process field.
An existing Pi pane is therefore reported as ambiguous rather than auto-healed, while an authoritatively missing Pi window can be relaunched safely.
This is the active tmux liveness limitation.

Agent liveness and composer safety are separate checks.
For a bordered composer, the tmux reader locates the complete box structurally and classifies every content row through the shared ANSI and ghost handling in `bin/fm-composer-lib.sh`.
Real text on any content row is pending, while only an unambiguous box with every row empty is proven empty.
Unreadable, incomplete, or structurally ambiguous boxes fail closed, and panes without a bordered composer retain the compatible cursor-row classification.
The shared classifier accepts a shell glyph as an empty agent composer only inside a verified bordered composer.
A bare shell prompt is `unknown`, so away-mode escalation is never injected into a dead shell.

Rendered busy detection is also harness-scoped.
Task metadata selects only that harness's verified signature, so output from one harness cannot make another harness appear busy.
The exact selection contract and safety rationale live in [architecture](architecture.md#runtime-session-backends), while the signatures live in [the harness-adapters skill](../.agents/skills/harness-adapters/SKILL.md).

`bin/fm-tmux-lib.sh` owns exact type-and-submit mechanics.
It types a message once and retries Enter only until the composer clears.
Only a proven empty composer is a positive delivery acknowledgement.
Text left in established structure remains `pending`, text in ambiguous structure remains unproven, and unreadable or unsafe state remains unknown.
`fm-send.sh` reports every unconfirmed verdict as a failure instead of retyping or assuming delivery.

OpenCode 1.18.4 has one busy-queue exception.
While OpenCode is mid-turn, Enter queues the message but leaves its text visible until the turn completes.
After the normal retry budget, only structurally proven pending text in a provably busy pane is accepted as queued, while an idle pane remains `pending` as a genuine swallowed Enter.
Ambiguous pending text never receives the busy-queue conversion.
`tests/fm-tmux-submit-busy.test.sh` covers busy and idle panes with proven, ambiguous, and cleared composers.

## Limits and regression entry points

- tmux is the reference path and supports secondmate homes.
- Existing Pi agent-process liveness is inconclusive, while an authoritatively missing Pi window can trigger recovery.
- The OpenCode busy-queue exception is tmux-specific; Herdr retains its separately documented gap.

```sh
tests/fm-backend-tmux-smoke.test.sh
tests/fm-composer-ghost.test.sh
tests/fm-kimi-harness.test.sh
tests/fm-tmux-submit-busy.test.sh
tests/fm-bootstrap.test.sh
```

[`verification/runtime-backends.md`](verification/runtime-backends.md#tmux) records the active foreground-process and submit evidence.
