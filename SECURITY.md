# Security posture

## What this plugin does and does not do

- **No network access.** The plugin never opens a socket and fetches nothing.
  Fully local is the point: your focus habits stay on your machine.
- **One privileged operation, tightly boxed.** Site blocking edits
  `/etc/hosts`, which needs root. That is done exclusively by
  `helpers/focus-modes-hosts`, invoked through `pkexec` (polkit prompts for
  authorization). Nothing else in the plugin runs privileged — DND, theme,
  windows, audio and hooks are all unprivileged user-session calls.
- **Writes outside its own state are enumerable:** the marker block in
  `/etc/hosts` (via the helper), the widget's own entry in
  `~/.config/omarchy/shell.json`, and
  `~/.local/state/omarchy-focus-modes/`. Everything it changes on your
  system — theme, DND, mute, window workspaces — is recorded in a journal
  first and restored when the mode ends, crashes included.

## The hosts helper — the trust boundary

`helpers/focus-modes-hosts` is ~120 lines of bash you can read in one sitting.
Its only capabilities are: replace the content between its two marker lines
(`# >>> bottelet.focus-modes >>>` / `# <<< bottelet.focus-modes <<<`) with
validated `0.0.0.0` entries, or remove the block. By construction it cannot
touch anything outside the markers; if the markers are damaged or duplicated
it refuses and tells you to fix the file by hand. Writes are
temp-file + atomic rename, so a crash can never leave `/etc/hosts`
half-written.

Validation happens **in the helper**, as root, not just in the UI:

- per-label RFC-shaped domain check (the per-label loop also avoids the
  exponential-backtracking trap a single nested-quantifier regex has in
  glibc's ERE engine — a hostile 250-char "domain" must fail fast, not hang
  a root process);
- rejects IP addresses (an all-numeric TLD is an IPv4 in disguise), so the
  block list can only name public-DNS-shaped hosts;
- rejects `localhost`, `*.localhost`, `*.local`, `*.localdomain` and this
  machine's own hostname — **local development can never be broken**, no
  matter what is typed in the editor;
- rejects whitespace, comments and anything that could smuggle a second
  hosts entry onto a line (`example.com 0.0.0.0 evil.marker` is one invalid
  token, not three);
- caps the list at 200 domains and dedupes the emitted hostnames.

The `--clear` path runs on every mode revert and is in the README removal
section; `grep focus-modes /etc/hosts` is empty after revert, disable and
uninstall.

## Untrusted input and where it goes

Mode names, site lists, app classes and theme names are user input; window
addresses and classes come from the compositor. They are data everywhere:

| Sink | Handling |
| --- | --- |
| Shell | No `eval`, no string-built `sh -c`. Every external call is an argv array. |
| `/etc/hosts` | Only via the helper above; the QML side pre-validates, the helper re-validates as root. |
| herdr Lua IPC | Window addresses must match `^0x[0-9a-f]+$` and workspace ids must be integers before they are spliced into a fixed Lua template — nothing else is interpolated. |
| `omarchy-theme-set` | Theme names must start alphanumeric (no option injection), no slashes or newlines, ≤ 64 chars, single argv element. |
| The panel | Every `Text` showing stored data sets `textFormat: Text.PlainText`. |
| State files | `JSON.stringify`/`JSON.parse` round-trips; a broken file falls back to defaults, never to code. |

## Hooks are the user's own commands

`onEnter`/`onExit` hooks run the user's typed command line through their
shell (`timeout 10 sh -c <exactly what they typed>`) — configuring your own
machine is the feature. Hook text is never concatenated with plugin-generated
strings, hooks are bounded by a 10-second timeout, and a failing hook logs an
issue in the panel instead of blocking the mode.

## Resource bounds

- Site list ≤ 200 domains, ≤ 253 chars each; app classes ≤ 50; modes ≤ 24;
  mode names ≤ 40 chars; hooks ≤ 1000 chars.
- Session log capped at 500 entries; journal is a single small JSON object.
- pkexec calls wrapped in `timeout 120`; hooks in `timeout 10`; the engine
  runs one external command at a time.
- Never SIGKILLs anything: quarantine "close" asks the window to close
  politely via the compositor.

## Reporting

Open an issue at https://github.com/Bottelet/omarchy-focus-modes/issues.
