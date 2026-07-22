# Always-on triage daemon

Mechanism reference for `bin/fm-supervise-daemon.sh` as the PERMANENT wake
consumer, on a supported claude or codex primary, on tmux or herdr.
[`architecture.md`](architecture.md#event-driven-supervision) carries the
short summary; this document is the complete mechanism.
Design source: the `fm-alwayson-triage-s5` scout report (phases 0-1 landed the
extraction and classifier parity prep; phase 2 flipped the claude primary on
tmux/herdr; this doc now also describes phase 3's codex flip, verified
2026-07-22 on codex-cli 0.144.1 - see "Rollout gates" below for the per-harness
verification record).

## Why

Before this phase, the daemon only ever ran while the captain had explicitly
invoked `/afk`: `inject_msg`'s presence gate refused whenever `state/.afk` was
absent, so a present captain paid a full LLM turn for every routine watcher
wake (drain, handle, re-arm).
The daemon's own classifier already self-handles the large majority of wakes
in bash at effectively zero cost; the only thing standing between "away-mode
savings" and "always-on savings" was that one presence gate.

## Mode model: one daemon, two delivery styles

The daemon is started once (the session-start bootstrap sweep, or a
harness-native/terminal launch path) and runs continuously.
`state/.afk` is a pure delivery-STYLE flag, not a permission gate:

| axis | away (`state/.afk` present) | present (`state/.afk` absent) |
|---|---|---|
| batching | `FM_ESCALATE_BATCH_SECS` (default 90s), one window regardless of urgency | two-tier: an urgent item flushes immediately; a routine-only buffer waits out `FM_ESCALATE_BATCH_SECS_PRESENT` (default 30s) |
| max-defer | `FM_MAX_DEFER_SECS` (default 300s) | `FM_MAX_DEFER_SECS_PRESENT` (default 900s) - a present captain legitimately holds the composer for minutes |
| wedge alert on max-defer | durable marker + log + configured OS-level active alert | durable marker + log only; `bin/fm-guard.sh` surfaces the marker on the next turn instead |
| stopped-crew stale | persistence recheck after `FM_STALE_ESCALATE_SECS` (240s), bounded patience | escalate on first sight, matching the always-on watcher's own present-mode semantics |

Urgent items (always flush immediately regardless of style): `check:` output
(PR merges, X mentions), `failed:`, `needs-decision:`, `blocked:`, `done:`/PR-ready,
and wedge alarms.
Routine items (subject to the style's batch window): a possible-wedge stale
escalation, a declared-pause recheck, and catch-all scan hits.

`/afk` and its return path (`bin/fm-afk-return.sh`) only flip the style flag
via `bin/fm-daemon-launch.sh afk-enter` / `afk-exit` - neither call ever
starts, stops, or restarts the daemon process itself.
The daemon's watcher child is always spawned with `FM_WATCH_DAEMON_OWNED=1`
(unconditionally, not only while `.afk` exists), so it is one-shot
(enqueue + exit on every wake) in both styles; the always-on watcher's own
standalone triage code is dormant whenever a daemon owns it, and is only the
degraded/recovery mode when the daemon is down.

## Delivery channel

Unchanged from away mode: a sentinel-marked message (`FM_INJECT_MARK`, U+2063
INVISIBLE SEPARATOR) typed into the captain's own pane, verified-submit, with
the busy-guard and composer-guard as the real per-injection safety checks in
both styles (see the `/afk` skill for the full injection-hardening list).
`inject_msg` no longer gates on `state/.afk` at all; only the busy-guard and
composer-guard can defer an injection.

## Hosting

The daemon must run in a terminal it owns - a detached tmux session or a
non-visible herdr workspace (`bin/fm-daemon-launch.sh start`) - never a
harness-tracked background task, so a bootstrap bash sweep (which cannot make
an LLM tool call) can start it deterministically at session start.
The harness-native launch path (`bin/fm-daemon-launch.sh start-native`, used
via a harness's own tracked background tool) remains defined for harnesses
without a terminal-owned launch need, but the always-on bootstrap sweep always
uses the terminal-owned path.

## Lifecycle: the session-start bootstrap sweep

`bin/fm-bootstrap.sh`'s `daemon_liveness_sweep()` runs as one of the six
locked-session-only mutating sweeps (AGENTS.md section 3).
It is a no-op unless the detected primary harness is `claude` OR `codex` AND
the detected backend is `tmux` or `herdr` (the daemon's own
`FM_SUPERVISOR_SUPPORTED_BACKENDS`).
On a supported combination:

1. **Daemon dead** - before launching, take over any harness-armed watcher
   singleton left from before the daemon existed (or from an unflipped
   session): if `state/.watch.lock` is held by a live, identity-matched
   watcher of this home that is not the daemon's own child, TERM exactly that
   pid (home-scoped, mirroring `bin/fm-watch-arm.sh --restart`'s own
   home-scoped stop) and wait bounded.
   This is safe by the enqueue-before-suppress contract: `fm-watch.sh`
   advances its `.seen-*` suppression markers only after a wake is surfaced or
   intentionally absorbed, so a TERM'd watcher never loses a wake - the next
   watcher re-detects it.
   Then launch `bin/fm-daemon-launch.sh start`.
2. **Daemon alive, pane retarget** - the daemon persists the supervisor pane it
   resolved at its own launch to `state/.supervisor-target`
   (`<backend>\t<target>`).
   The sweep compares that record against a fresh `discover_supervisor_target`
   / `discover_supervisor_backend` call from its OWN env (this session's
   actual current pane); on a mismatch (the captain's pane moved - new window,
   reboot) it restarts the daemon (`stop` then `start`) so the daemon injects
   into the current pane.
   No recorded target at all (a daemon that predates the record, or a write
   that failed) is treated as nothing to compare against, not a mismatch: the
   daemon is left alone rather than restarted on every sweep.
3. **Daemon alive, pane unchanged** - no-op.

Every action is scoped to this home's own `state/`, never another home's.
Failures print an actionable `DAEMON_LIVENESS:` bootstrap line; success is
silent, matching every other bootstrap sweep's convention.

## Stop conditions

The daemon never stops during normal operation - like a secondmate, an idle
daemon is healthy.
Explicit stops only for: (a) an explicit captain request; (b) a self-update
restart (`/updatefirstmate` restarts it via `bin/fm-daemon-launch.sh stop &&
start` when `bin/` changed and the daemon is alive - `fm-update.sh`'s
`restart-daemon:` action line - because the daemon is a long-lived bash
process that would otherwise keep executing pre-update code); (c) the
pane-retarget restart above.
`bin/fm-daemon-launch.sh stop` never touches `state/.afk`: the style flag is
independent lifecycle state, so a stop-for-restart preserves whichever
delivery style was active.

## Guard predicates: daemon-alive-allows

`bin/fm-turnend-guard.sh`, `bin/fm-continuity-pretool-check.sh`, and
`bin/fm-guard.sh` all gained a `daemon_lock_held_by_live_daemon` satisfier,
inserted alongside (never replacing) the pre-existing watcher-lock predicate:

- **Turn-end guard**: a live daemon lock allows the turn to end even with no
  fresh watcher beacon (the daemon guarantees its child restarts, so the brief
  gap between its own cycles is expected, not unhealthy).
- **Continuity PreToolUse gate**: same satisfier; its deny reason and the
  recovery allowlist (`fm-continuity-command-policy.mjs`) both point at
  `bin/fm-daemon-launch.sh start` on a supported backend (still the legacy
  `bin/fm-watch-arm.sh` wording on an unsupported one), and
  `fm-daemon-launch.sh` joins `fm-wake-drain.sh` / `fm-watch-arm.sh` in the
  allowed recovery set.
- **`fm-guard.sh`**: the same satisfier, plus a distinct louder banner title
  ("THE ALWAYS-ON DAEMON IS DOWN") when a daemon-related record exists for
  this home (`.supervise-daemon.lock`, `.afk-daemon-terminal`, or `.afk`) but
  no live daemon holds the lock - the new primary failure mode, distinct from
  "no daemon was ever part of this home's setup".
  It also surfaces `state/.subsuper-inject-wedged` independently of watcher/
  daemon health, since a present-mode wedge alarm deliberately skips the
  OS-level active alert and relies on this surfacing instead.

None of these predicates are gated on harness/backend: a live daemon lock can
only exist for a home that genuinely has one running, so trusting it needs no
additional scoping.

## Supervision-block rendering

`bin/fm-supervision-instructions.sh` detects the supported combination
(`FM_SUPERVISOR_BACKEND` override, else `fm_backend_detect`) and renders
`docs/supervision-protocols/claude.md` or `codex.md` (the always-on protocol:
"escalations arrive as marked messages; drain, handle, end the turn; do not
arm watchers") instead of `claude-legacy.md` / `codex-legacy.md`
(byte-identical to the pre-flip per-harness protocol, still rendered for that
harness on an unsupported backend).
The "Current state" block gains a `Daemon: running pid=N` / `Daemon: DOWN -
ensure it with bin/fm-daemon-launch.sh start` line, and the repair line
collapses the away/present split into one daemon-ensure instruction on a
supported combination.
Every other harness keeps its own unchanged snippet and repair line - this is
a template swap gated on the supported-combination check, never a behavior
change for an unflipped harness/backend.

## X mode

The daemon's launch command (both the herdr-workspace and detached-tmux
paths in `bin/fm-daemon-launch.sh`) sources `config/x-mode.env` before exec'ing
the daemon entry, exactly like an LLM-armed watcher already does
(`fm-supervision-instructions.sh`'s X-mode current-state line), so the
daemon's watcher child inherits the 30s X-mode cadence when X mode is active.
The sourcing line is a no-op when the file does not exist, so every daemon
launch uses one code path regardless of X-mode state.

## Rollout gates (other harnesses, other backends)

The wake transport is backend-level (tmux/herdr pane primitives), not
harness-level, so flipping another harness only needs its composer verified
injectable.
`fm-supervision-instructions.sh`'s supported-combination check keeps every
unflipped harness, and any flipped harness on a backend other than tmux/herdr,
on today's unchanged per-wake protocol until each is independently verified.

Per-harness status (fm-alwayson-triage-s5 phase 3):

- **codex - FLIPPED, verified 2026-07-22 on codex-cli 0.144.1.** Codex's
  180s foreground-checkpoint tax (`bin/fm-watch-checkpoint.sh`) is retired
  entirely on a supported combination: a marked-message wake is exactly what
  Codex can respond to, since injection is a real typed composer message, not
  a background-task completion. `bin/fm-bootstrap.sh`'s
  `daemon_liveness_sweep()` and `fm-supervision-instructions.sh`'s
  supported-combination check both accept `codex` alongside `claude`.
  No guard-predicate change was needed: the turn-end guard's
  `daemon_lock_held_by_live_daemon` satisfier (phase 2) was already
  harness-agnostic, and codex does not use the claude-only continuity
  PreToolUse gate.
  Live E2E: `tests/fm-codex-alwayson-live-e2e.test.sh`
  (`FM_CODEX_LIVE_E2E=1`), proving a marked injection into a real interactive
  codex session wakes a turn, the turn-end guard stays quiet purely from the
  live daemon lock, and it blocks again once the daemon is stopped.
- **grok - not flipped, unrunnable in this build environment.** Same shape as
  claude (background-notify today); the composer classifier already carries
  verified grok ghost/idle signatures (`tests/fm-composer-ghost.test.sh`,
  `tests/fm-backend-herdr.test.sh`), but the spec requires a live
  composer-injection E2E against a real grok session before the
  supported-combination check may accept `grok`, and the `grok` CLI is not
  installed in this build environment - `command -v grok` fails.
  Ships nothing this phase; stays on today's background-notify protocol until
  a build environment with the grok CLI can run and pass the live E2E.
- **opencode / pi - not flipped, blocked on a prerequisite plugin change plus
  an unrunnable environment.** Their plugins spawn `fm-watch-arm.sh --restart`
  on idle/child-close, which would TERM the daemon's own child watcher (the
  direct conflict this doc's design anticipated) - a plugin/extension
  stand-down (no-op when `daemon_lock_held_by_live_daemon`) must ship first.
  Neither the `opencode` nor `pi` CLI is installed in this build environment
  either, so even the plugin change could not be live-E2E-verified here
  (`FM_OPENCODE_LIVE_E2E` / `FM_PI_LIVE_E2E`).
  Both stay on today's plugin-owned protocol until a build environment with
  the relevant CLI can implement the stand-down and pass its live E2E.

zellij, orca, and cmux cannot host or receive always-on triage until they grow
verified composer/busy/submit primitives and a non-visible launch primitive;
the daemon refuses loudly at startup rather than guessing, exactly as before.

## Safety invariants (carried, mode-aware where noted)

- **Nothing is lost**: the durable wake queue plus `fm-wake-drain.sh` recover
  any missed or crashed injection, in both delivery styles.
- **Bounded wedge detection**: never lossy, only ever a delay.
- **Declared external waits**: rechecked on their own bounded cadence, never
  mislabeled as a wedge.
- **Fail-safe on uncertainty**: an unrecognized wake escalates; a non-wake
  watcher stdout line idles instead of flooding.
- **Injection safety**: the affirmative-empty composer rule and verified
  type-once submit are unchanged and are the PRIMARY defense in present mode
  (the composer-guard was previously belt-and-suspenders for the away-only
  return-race case; it now guards every ordinary turn).
- **Away never expands authority**: unchanged in both styles - merges,
  ask-user findings, and destructive choices keep their configured authority.

## Known caveat: routine-record queue consumption is not implemented

The design report's caveat 4 anticipated that guarded queue-consumption (the
daemon proactively removing its OWN self-handled records from
`state/.wake-queue` so a routine wake self-handled every day does not pile up
and get re-dumped into a captain-facing drain later) might prove hairy in
review, with an explicitly pre-approved fallback: ship without it.
This phase takes that fallback.
The always-on daemon does NOT consume queue records; every wake it
self-handles remains durably queued and is replayed verbatim by the next
`fm-wake-drain.sh` call, exactly like today's away-mode catch-up drain.
Consequence: a present-mode drain can be noisier than the eventual
queue-consuming design (self-handled records reappear in the drain output),
but never unsafe - nothing is lost, and no escalated record is ever
suppressed.
Revisit this once the phase-2 guard/lifecycle surface has real-world mileage.
