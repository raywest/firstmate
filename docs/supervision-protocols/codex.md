Mode: Codex always-on triage (rendered only on a supported combination: codex on tmux or herdr).

The always-on triage daemon (`bin/fm-supervise-daemon.sh`) is the PERMANENT wake
consumer - it is already running, started and kept alive by the session-start
bootstrap sweep, never by this turn. There is no foreground checkpoint loop and
no tracked background task for ordinary supervision:
1. Escalations arrive as a sentinel-marked message typed directly into this pane.
   A message that starts with the marker is an internal escalation, never a real
   captain message.
2. Ordinary wake: drain queued wakes first with `bin/fm-wake-drain.sh`, handle the
   escalation, then end the turn freely.
   The daemon's own watcher child keeps running independently of this turn, so
   nothing here needs to stay alive or be re-armed, and no foreground checkpoint
   needs to be started.
3. Never run `bin/fm-watch-checkpoint.sh` for ordinary supervision; it is retired
   entirely on this combination.
   A marked injection is a real typed message, not a background-task completion,
   so it reaches Codex exactly the way a captain's own message would - the
   foreground-checkpoint workaround for "Codex cannot reason while a foreground
   tool call is running" no longer applies.
4. Never run `bin/fm-watch-arm.sh` for ordinary supervision; it is a recovery-only
   probe for a home whose daemon has genuinely gone down (see the repair line
   above), not the ordinary wake mechanism.
5. Never use shell `&` to manage the daemon.
6. The turn-end guard allows a live daemon through its
   `daemon_lock_held_by_live_daemon` predicate, alongside the pre-existing
   watcher-lock predicate; neither predicate replaces the other, and the
   turn-end guard remains the final backstop.
   The Codex Stop hook still pipes through `bin/fm-turnend-guard.sh` unchanged.
7. Recovery only: if the repair line above fires (the daemon is down), ensure it
   with `bin/fm-daemon-launch.sh start` - never a harness-tracked background task
   for the daemon itself, and never shell `&`.
8. Do not send idle progress while the daemon owns supervision.

Away mode (`/afk`) only changes the daemon's delivery STYLE (batching cadence,
wedge-alert channel) - it never starts, stops, or gates the daemon, and the
sentinel-marker contract is identical in both styles.
See [`../alwayson-triage.md`](../alwayson-triage.md) for the full mechanism and
[`../architecture.md`](../architecture.md) for how it fits the rest of the fleet.
