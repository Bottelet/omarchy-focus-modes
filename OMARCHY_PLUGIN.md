# Focus Modes — Omarchy plugin

`bottelet.focus-modes` — iOS-style Focus modes for the Omarchy desktop. A mode
applies a set of actions atomically (DND, site blocking, app quarantine, theme,
keep-awake, mute, user hooks) and reverts exactly what it applied when it ends.

## Install

Copy to `~/.config/omarchy/plugins/bottelet.focus-modes/`, then
`omarchy plugin enable bottelet.focus-modes`, then
`omarchy bar put bottelet.focus-modes --after <some-widget>`.

## IPC

`IpcHandler` target `bottelet.focus-modes` exposes `open`, `close`, `show`,
`hide`, `toggle`, plus the keybinding surface:

- `omarchy-shell bottelet.focus-modes activate deep-focus` — start a mode
  (uses its default duration)
- `omarchy-shell bottelet.focus-modes off` — end the active mode
- `omarchy-shell bottelet.focus-modes status` — `off` or `<id> [mm:ss]`

## M0 integration recon (found routes)

- **DND** — the Quattro shell's own notifications service
  (`plugins/notifications/Service.qml`). Reached in-process:
  `bar.shell.firstPartyServiceFor("omarchy.notifications")`, reactive property
  `doNotDisturb`, setter `setDoNotDisturb(bool)`. State is persisted by the
  service itself (`~/.local/state/omarchy/notifications.json`), so DND
  survives shell restarts on its own — our journal records the pre-mode value
  and restores it on revert.
  *Urgency allowlist is not feasible:* the service's DND bypass is hardcoded
  to `app_name == "omarchy-action"` (any urgency) or `app_name == "notify-send"
  && urgency == critical`. A Discord/Slack "critical" is silenced like
  everything else. Documented as all-or-nothing; `allowCritical` is therefore
  not surfaced in the editor.
- **Theme** — `omarchy-theme-current` / `omarchy-theme-list` /
  `omarchy-theme-set <name>`. Names can contain spaces ("Catppuccin Latte");
  they travel as a single argv element. Previous theme is captured before the
  switch and restored from the journal token.
- **Keep-awake** — `systemd-inhibit --what=idle:sleep --mode=block sleep
  infinity` held as a child process. Chosen over the shell's stay-awake state
  file because a child process can never leak: if the shell dies, the
  inhibitor dies with it. The hold is a declarative binding on journal state,
  so every widget instance releases its own hold the moment the journal
  clears, no matter which instance ended the mode.
- **Window management** — Omarchy Quattro's compositor (herdr) rejects the
  classic `hyprctl dispatch movetoworkspacesilent` syntax; the platform API is
  the Lua IPC used by omarchy's own scripts:
  `hyprctl eval 'hl.dispatch(hl.dsp.window.move({ window = "address:0x…",
  workspace = "special:quarantine", silent = true }))'`. Window addresses are
  validated `^0x[0-9a-f]+$` before being spliced into the fixed Lua template.
  New windows of a quarantined class are caught by a 3-second `hyprctl -j
  clients` poll while the mode is active (dependency-free; an event socket
  subscription can replace it in v2).
- **Audio** — `wpctl get-volume @DEFAULT_AUDIO_SINK@` (captures `[MUTED]`
  flag) / `wpctl set-mute @DEFAULT_AUDIO_SINK@ 1|0`.
- **Hosts** — see SECURITY.md; privileged helper + pkexec. The Quattro shell
  registers its own polkit agent ("omarchy polkit agent registered" in its
  log), so the auth dialog renders natively.

## Decisions worth knowing

**One engine, many widget instances.** The bar mounts the widget once per
screen, all in one Quickshell process, and `bar` is a shared object — the
per-screen identity comes from the `QsWindow.window` attached property in
BarWidget.qml. All instances mirror the same state files (`watchChanges`);
any instance may run a user-initiated transition (the one the user clicked),
but automatic work — startup rollback, timer expiry, quarantine sweeps — runs
only on the elected owner (the instance on `Quickshell.screens[0]`), so it
happens exactly once.

**The journal is written before anything is applied** and rewritten after
every step. Each applied entry carries its own revert token (`prev` theme,
`prevMuted`, window origin workspaces). On startup the journal is the truth:
an expired or orphaned journal is rolled back by the owner instance —
verified by killing the shell mid-mode and by letting a timed mode expire
while the shell was down; hosts blocks, theme, DND, mute and windows all came
back, and the onExit hook still ran.

**Sequential step runner.** One external command at a time
(`Process` + `StdioCollector`, both exit and stream-finish awaited before the
next step). Pure-JS steps interleave for journal writes and service calls.
pkexec steps are wrapped in `timeout 120` so an abandoned auth dialog can
never wedge the queue.

**Sessions under one minute are not logged** — a mis-click is not a focus
session. The week view sums the trailing 7 days per mode.

**BorderSurface is a plain Rectangle that defaults to white.** Every card
sets its own `color`; the first build shipped glaring white cards on dark
themes because of exactly this.

**Editor lists are comma/space-separated single-line fields** (qs.Ui
TextField is single-line). The invalid remainder is shown live under the
sites field, and the helper re-validates everything anyway.

## Settings vs state

- Manifest `barWidget.schema`: `showLabel`, `scrollCycles`,
  `notifyOnAutoRevert` (booleans in the widget's `shell.json` entry).
- Modes, journal and session log live in
  `~/.local/state/omarchy-focus-modes/{modes,journal,sessions}.json` —
  nested per-mode config exceeds what the settings schema can express, and
  the journal must survive shell restarts byte-exactly.

## Tests

`tests/run.sh` — offline: 49 checks against the hosts helper (validation,
marker surgery, injection attempts, damaged-marker refusal) on a scratch
hosts file, plus 51 `Model.js` engine checks under node (journal lifecycle,
revert planning, sanitization, command builders).

Live-verified on a 2-monitor Quattro box: activate/deactivate for every
module, shell restart mid-mode (re-adoption), expired-journal rollback on
startup, timer expiry with notification, quarantine spawn-sweep and
restore-to-origin-workspace, hosts block/unblock via pkexec.

## Not here yet (v2 candidates)

- Schedule triggers (the mode model deliberately leaves room for a
  `triggers` key without migration).
- Hyprland/herdr event-socket subscription instead of the 3 s quarantine poll.
- Per-mode wallpaper / bar-widget hiding.
- Calendar-aware Meeting detection.
