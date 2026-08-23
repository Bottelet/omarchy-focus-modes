// Mode model, apply/revert planning, journal and session log for focus modes.
//
// Everything here is pure and node-testable (tests/model.test.js). The QML
// layer owns processes and timers; this file owns what to run and how to
// interpret it. The engine contract:
//
//   activate  = capture current state per enabled module -> apply -> journal
//   deactivate = walk journal.applied in reverse -> revert each token
//
// The journal is written to disk before the first apply step and updated
// after every step, so a crash at any point leaves a file that says exactly
// what needs undoing (see adoptJournal / startup in Panel.qml).

var JOURNAL_VERSION = 1
var MAX_MODES = 24
var MAX_SITES = 200
var MAX_CLASSES = 50
var MAX_SESSIONS = 500

// ------------------------------------------------------------ default modes

// Off is implicit — no entry here. Users can edit or delete all of these.
function defaultModes() {
  return [
    {
      id: "deep-focus",
      name: "Deep Focus",
      icon: "", // nf-fa-crosshairs
      actions: {
        dnd: { enabled: true, allowCritical: true },
        blockSites: { enabled: true, list: ["twitter.com", "x.com", "reddit.com", "news.ycombinator.com", "youtube.com"] },
        quarantineApps: { enabled: true, classes: ["discord", "org.telegram.desktop"], action: "move" },
        theme: { enabled: false, name: "" },
        keepAwake: { enabled: false },
        muteAudio: { enabled: false },
        hooks: { onEnter: "", onExit: "" }
      },
      defaultDurationMin: 50
    },
    {
      id: "work",
      name: "Work",
      icon: "", // nf-fa-briefcase
      actions: {
        dnd: { enabled: true, allowCritical: true },
        blockSites: { enabled: true, list: ["twitter.com", "x.com", "reddit.com"] },
        quarantineApps: { enabled: false, classes: [], action: "move" },
        theme: { enabled: false, name: "" },
        keepAwake: { enabled: false },
        muteAudio: { enabled: false },
        hooks: { onEnter: "", onExit: "" }
      },
      defaultDurationMin: 0
    },
    {
      id: "meeting",
      name: "Meeting",
      icon: "", // nf-fa-video_camera
      actions: {
        dnd: { enabled: true, allowCritical: true },
        blockSites: { enabled: false, list: [] },
        quarantineApps: { enabled: false, classes: [], action: "move" },
        theme: { enabled: false, name: "" },
        keepAwake: { enabled: true },
        muteAudio: { enabled: false },
        hooks: { onEnter: "", onExit: "" }
      },
      defaultDurationMin: 0
    }
  ]
}

// Icons the editor offers (nerd-font glyphs render on every Omarchy theme,
// unlike color emoji in the bar font).
function iconChoices() {
  return ["", "", "", "", "", "", "", "", "", "", "", ""]
}

// -------------------------------------------------------------- validation

// Mirror of the helper's per-label check. The helper re-validates as root —
// this copy exists so the editor can flag a bad line before pkexec is ever
// invoked.
function validDomain(d) {
  var s = String(d || "").toLowerCase()
  if (s.length < 3 || s.length > 253) return false
  if (s.indexOf(".") === -1) return false
  if (s[0] === "." || s[s.length - 1] === "." || s.indexOf("..") !== -1) return false
  var labels = s.split(".")
  for (var i = 0; i < labels.length; i++) {
    if (!/^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$/.test(labels[i])) return false
  }
  var tld = labels[labels.length - 1]
  if (!/[a-z]/.test(tld)) return false // all-numeric TLD = IPv4 in disguise
  if (s === "localhost" || /\.localhost$/.test(s)) return false
  if (/\.local$/.test(s) || /\.localdomain$/.test(s)) return false
  return true
}

// Editor field (domains separated by commas/whitespace) -> {valid, invalid}.
function parseSiteList(text) {
  var lines = String(text || "").split(/[\s,]+/)
  var valid = []
  var invalid = []
  var seen = {}
  for (var i = 0; i < lines.length; i++) {
    var s = lines[i].replace(/^\s+|\s+$/g, "").toLowerCase()
    if (s === "" || s[0] === "#") continue
    if (!validDomain(s)) { invalid.push(s); continue }
    if (seen[s]) continue
    seen[s] = true
    if (valid.length < MAX_SITES) valid.push(s)
  }
  return { valid: valid, invalid: invalid }
}

// Window classes as hyprctl reports them (org.telegram.desktop, discord, …).
function validClass(c) {
  return /^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$/.test(String(c || ""))
}

function parseClassList(text) {
  var parts = String(text || "").split(/[\n,]/)
  var out = []
  var seen = {}
  for (var i = 0; i < parts.length; i++) {
    var s = parts[i].replace(/^\s+|\s+$/g, "")
    if (s === "" || !validClass(s)) continue
    var key = s.toLowerCase()
    if (seen[key]) continue
    seen[key] = true
    if (out.length < MAX_CLASSES) out.push(s)
  }
  return out
}

// Theme names come from `omarchy theme list` output or the user's editor
// choice; they end up as a single argv element, so the only hard rule is
// "no option injection" (leading dash) and sane length.
function validThemeName(name) {
  var s = String(name || "")
  return s.length > 0 && s.length <= 64 && /^[A-Za-z0-9]/.test(s) && !/[\/\n\r]/.test(s)
}

// ----------------------------------------------------- mode sanitization

function slugify(name) {
  var s = String(name || "").toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "")
  return s.slice(0, 40) || "mode"
}

function sanitizeActions(a) {
  var src = a && typeof a === "object" ? a : {}
  var dnd = src.dnd || {}
  var sites = src.blockSites || {}
  var apps = src.quarantineApps || {}
  var theme = src.theme || {}
  var hooks = src.hooks || {}
  var siteList = []
  var rawSites = sites.list
  if (typeof rawSites === "string") siteList = parseSiteList(rawSites).valid
  else if (rawSites && typeof rawSites.length === "number") siteList = parseSiteList(rawSites.join("\n")).valid
  var classes = []
  var rawClasses = apps.classes
  if (typeof rawClasses === "string") classes = parseClassList(rawClasses)
  else if (rawClasses && typeof rawClasses.length === "number") classes = parseClassList(rawClasses.join("\n"))
  return {
    dnd: { enabled: dnd.enabled === true, allowCritical: dnd.allowCritical !== false },
    blockSites: { enabled: sites.enabled === true, list: siteList },
    quarantineApps: { enabled: apps.enabled === true, classes: classes, action: apps.action === "close" ? "close" : "move" },
    theme: { enabled: theme.enabled === true && validThemeName(theme.name), name: validThemeName(theme.name) ? String(theme.name) : "" },
    keepAwake: { enabled: !!(src.keepAwake && src.keepAwake.enabled === true) },
    muteAudio: { enabled: !!(src.muteAudio && src.muteAudio.enabled === true) },
    hooks: {
      onEnter: typeof hooks.onEnter === "string" ? hooks.onEnter.slice(0, 1000) : "",
      onExit: typeof hooks.onExit === "string" ? hooks.onExit.slice(0, 1000) : ""
    }
  }
}

function sanitizeMode(m) {
  if (!m || typeof m !== "object") return null
  var name = String(m.name || "").replace(/[\n\r]/g, " ").slice(0, 40)
  if (name.replace(/\s/g, "") === "") return null
  var id = /^[a-z0-9-]{1,40}$/.test(String(m.id || "")) ? String(m.id) : slugify(name)
  var dur = parseInt(m.defaultDurationMin, 10)
  if (isNaN(dur) || dur < 0) dur = 0
  if (dur > 24 * 60) dur = 24 * 60
  return {
    id: id,
    name: name,
    icon: typeof m.icon === "string" && m.icon.length > 0 ? m.icon.slice(0, 8) : "",
    actions: sanitizeActions(m.actions),
    defaultDurationMin: dur
  }
}

// modes.json content -> valid mode list (never empty ids, never duplicates).
// A missing/broken file falls back to the defaults.
function sanitizeModes(parsed) {
  var list = parsed && parsed.modes && typeof parsed.modes.length === "number" ? parsed.modes : null
  if (!list) return defaultModes().map(function(m) { return sanitizeMode(m) })
  var out = []
  var seen = {}
  for (var i = 0; i < list.length && out.length < MAX_MODES; i++) {
    var m = sanitizeMode(list[i])
    if (!m) continue
    var base = m.id
    var n = 2
    while (seen[m.id]) m.id = base + "-" + n++
    seen[m.id] = true
    out.push(m)
  }
  return out
}

function modeById(modes, id) {
  for (var i = 0; i < modes.length; i++) if (modes[i].id === id) return modes[i]
  return null
}

// Small glyph summary shown on mode cards: one symbol per enabled action.
function actionGlyphs(mode) {
  var a = mode.actions
  var out = []
  if (a.dnd.enabled) out.push({ glyph: "", label: "notifications off" })          // bell-slash
  if (a.blockSites.enabled && a.blockSites.list.length) out.push({ glyph: "", label: a.blockSites.list.length + " sites blocked" })
  if (a.quarantineApps.enabled && a.quarantineApps.classes.length) out.push({ glyph: "", label: "apps quarantined" })
  if (a.theme.enabled) out.push({ glyph: "", label: "theme " + a.theme.name })
  if (a.keepAwake.enabled) out.push({ glyph: "", label: "screen stays awake" })   // coffee
  if (a.muteAudio.enabled) out.push({ glyph: "", label: "audio muted" })
  if (a.hooks.onEnter !== "" || a.hooks.onExit !== "") out.push({ glyph: "", label: "hooks" })
  return out
}

// ------------------------------------------------------------------ journal

function newJournal(mode, durationMin, nowMs) {
  var dur = parseInt(durationMin, 10)
  if (isNaN(dur) || dur < 0) dur = 0
  return {
    v: JOURNAL_VERSION,
    modeId: mode.id,
    modeName: mode.name,
    icon: mode.icon,
    startedAt: nowMs,
    endsAt: dur > 0 ? nowMs + dur * 60000 : null,
    applied: []
  }
}

function parseJournal(raw) {
  var text = String(raw || "").replace(/^\s+|\s+$/g, "")
  if (text === "") return null
  var j
  try { j = JSON.parse(text) } catch (e) { return null }
  if (!j || j.v !== JOURNAL_VERSION || typeof j.modeId !== "string") return null
  if (!j.applied || typeof j.applied.length !== "number") j.applied = []
  return j
}

function journalExpired(journal, nowMs) {
  return !!(journal && journal.endsAt && nowMs >= journal.endsAt)
}

function remainingMs(journal, nowMs) {
  if (!journal || !journal.endsAt) return -1
  return Math.max(0, journal.endsAt - nowMs)
}

function elapsedMs(journal, nowMs) {
  if (!journal) return 0
  return Math.max(0, nowMs - journal.startedAt)
}

// -------------------------------------------------------------- session log

function parseSessions(raw) {
  try {
    var list = JSON.parse(String(raw || ""))
    return list && typeof list.length === "number" ? list : []
  } catch (e) { return [] }
}

function appendSession(sessions, journal, endMs) {
  var out = sessions.slice()
  if (journal && endMs - journal.startedAt >= 60000) {
    out.push({ modeId: journal.modeId, name: journal.modeName, start: journal.startedAt, end: endMs })
  }
  if (out.length > MAX_SESSIONS) out = out.slice(out.length - MAX_SESSIONS)
  return out
}

// Totals per mode for the trailing 7 days: [{modeId, name, minutes}], most
// focused first.
function weekTotals(sessions, nowMs) {
  var cutoff = nowMs - 7 * 86400000
  var byMode = {}
  var order = []
  for (var i = 0; i < sessions.length; i++) {
    var s = sessions[i]
    if (!s || typeof s.start !== "number" || typeof s.end !== "number") continue
    if (s.end <= cutoff) continue
    var start = Math.max(s.start, cutoff)
    var mins = Math.round((s.end - start) / 60000)
    if (mins <= 0) continue
    if (byMode[s.modeId] === undefined) {
      byMode[s.modeId] = { modeId: s.modeId, name: String(s.name || s.modeId), minutes: 0 }
      order.push(s.modeId)
    }
    byMode[s.modeId].minutes += mins
  }
  var out = order.map(function(id) { return byMode[id] })
  out.sort(function(a, b) { return b.minutes - a.minutes })
  return out
}

function formatMinutes(mins) {
  if (mins < 60) return mins + "m"
  var h = Math.floor(mins / 60)
  var m = mins % 60
  return m === 0 ? h + "h" : h + "h " + m + "m"
}

// Chip countdown: "49:12", or "1:03:44" past the hour.
function formatRemaining(ms) {
  var total = Math.max(0, Math.ceil(ms / 1000))
  var s = total % 60
  var m = Math.floor(total / 60) % 60
  var h = Math.floor(total / 3600)
  var mm = (m < 10 ? "0" : "") + m
  var ss = (s < 10 ? "0" : "") + s
  return h > 0 ? h + ":" + mm + ":" + ss : m + ":" + ss
}

// ------------------------------------------------------- command builders
//
// Every command is a full argv array; nothing user-influenced is ever pasted
// into a shell line. Commands that need a pipeline use jq-free plain output
// parsed here instead.

function themeListCommand() { return ["omarchy-theme-list"] }
function themeCurrentCommand() { return ["omarchy-theme-current"] }

function themeSetCommand(name) {
  if (!validThemeName(name)) return null
  return ["omarchy-theme-set", String(name)]
}

function parseThemeList(raw) {
  var lines = String(raw || "").split("\n")
  var out = []
  for (var i = 0; i < lines.length; i++) {
    var s = lines[i].replace(/^\s+|\s+$/g, "")
    if (s !== "" && validThemeName(s)) out.push(s)
  }
  return out
}

// DND — finalized after M0 recon (see OMARCHY_PLUGIN.md).
function dndSetCommand(on) {
  return null
}

// pkexec waits forever on an unanswered auth dialog; the engine runs steps
// sequentially, so an abandoned prompt would wedge every later transition.
// 120 s is plenty to type a password and finite enough to self-heal.
function hostsSetArgv(helperPath, domains) {
  var args = ["timeout", "120", "pkexec", helperPath, "--set"]
  for (var i = 0; i < domains.length && i < MAX_SITES; i++) {
    if (validDomain(domains[i])) args.push(String(domains[i]).toLowerCase())
  }
  return args.length > 5 ? args : null
}

function hostsClearArgv(helperPath) {
  return ["timeout", "120", "pkexec", helperPath, "--clear"]
}

function hyprClientsCommand() { return ["hyprctl", "-j", "clients"] }

// hyprctl clients -> windows to quarantine: only real windows on regular
// workspaces (special:* stays put) whose class matches a quarantined class.
function quarantineTargets(raw, classes) {
  var clients
  try { clients = JSON.parse(String(raw || "")) } catch (e) { return [] }
  if (!clients || typeof clients.length !== "number") return []
  var wanted = {}
  for (var i = 0; i < classes.length; i++) wanted[String(classes[i]).toLowerCase()] = true
  var out = []
  for (var j = 0; j < clients.length; j++) {
    var c = clients[j]
    if (!c || !c.address || !c.workspace) continue
    var cls = String(c.class || "").toLowerCase()
    var init = String(c.initialClass || "").toLowerCase()
    if (!wanted[cls] && !wanted[init]) continue
    if (typeof c.workspace.id !== "number" || c.workspace.id < 1) continue
    if (!/^0x[0-9a-f]+$/i.test(String(c.address))) continue
    out.push({ address: String(c.address), workspace: c.workspace.id })
  }
  return out
}

// Window dispatches use Omarchy Quattro's Lua IPC (`hyprctl eval`) — the
// classic `hyprctl dispatch movetoworkspacesilent` syntax is rejected by the
// herdr compositor, and the in-tree omarchy scripts use this form too. The
// address is strictly ^0x[0-9a-f]+$ before it is spliced into the fixed Lua
// template, so nothing user- or window-controlled can escape the string.
function moveWindowEval(address, workspace) {
  return ["hyprctl", "eval",
    'hl.dispatch(hl.dsp.window.move({ window = "address:' + address + '", workspace = "' + workspace + '", silent = true }))']
}

function moveToQuarantineArgv(address) {
  if (!/^0x[0-9a-f]+$/i.test(String(address))) return null
  return moveWindowEval(String(address), "special:quarantine")
}

function moveBackArgv(address, workspaceId) {
  var ws = parseInt(workspaceId, 10)
  if (!/^0x[0-9a-f]+$/i.test(String(address)) || isNaN(ws) || ws < 1) return null
  return moveWindowEval(String(address), String(ws))
}

function closeWindowArgv(address) {
  if (!/^0x[0-9a-f]+$/i.test(String(address))) return null
  return ["hyprctl", "eval",
    'hl.dispatch(hl.dsp.window.close({ window = "address:' + address + '" }))']
}

function inhibitCommand() {
  return ["systemd-inhibit", "--what=idle:sleep", "--who=Focus Modes",
          "--why=focus mode with keep-awake is active", "--mode=block", "sleep", "infinity"]
}

function audioStatusCommand() { return ["wpctl", "get-volume", "@DEFAULT_AUDIO_SINK@"] }

function parseAudioMuted(raw) {
  return /\[MUTED\]/.test(String(raw || ""))
}

function audioMuteCommand(mute) {
  return ["wpctl", "set-mute", "@DEFAULT_AUDIO_SINK@", mute ? "1" : "0"]
}

// Hooks are the user's own command line, run exactly as typed through their
// shell — never concatenated with anything of ours. Bounded so a wedged hook
// cannot block a mode switch.
function hookCommand(cmdline) {
  var s = String(cmdline || "")
  if (s.replace(/\s/g, "") === "") return null
  return ["timeout", "10", "sh", "-c", s]
}

function notifyCommand(title, body) {
  return ["notify-send", "-a", "Focus Modes", "--", String(title), String(body)]
}

if (typeof module !== "undefined") {
  module.exports = {
    JOURNAL_VERSION: JOURNAL_VERSION,
    defaultModes: defaultModes,
    iconChoices: iconChoices,
    validDomain: validDomain,
    parseSiteList: parseSiteList,
    validClass: validClass,
    parseClassList: parseClassList,
    validThemeName: validThemeName,
    slugify: slugify,
    sanitizeMode: sanitizeMode,
    sanitizeModes: sanitizeModes,
    modeById: modeById,
    actionGlyphs: actionGlyphs,
    newJournal: newJournal,
    parseJournal: parseJournal,
    journalExpired: journalExpired,
    remainingMs: remainingMs,
    elapsedMs: elapsedMs,
    parseSessions: parseSessions,
    appendSession: appendSession,
    weekTotals: weekTotals,
    formatMinutes: formatMinutes,
    formatRemaining: formatRemaining,
    themeListCommand: themeListCommand,
    themeCurrentCommand: themeCurrentCommand,
    themeSetCommand: themeSetCommand,
    parseThemeList: parseThemeList,
    dndSetCommand: dndSetCommand,
    hostsSetArgv: hostsSetArgv,
    hostsClearArgv: hostsClearArgv,
    hyprClientsCommand: hyprClientsCommand,
    quarantineTargets: quarantineTargets,
    moveToQuarantineArgv: moveToQuarantineArgv,
    moveBackArgv: moveBackArgv,
    closeWindowArgv: closeWindowArgv,
    inhibitCommand: inhibitCommand,
    audioStatusCommand: audioStatusCommand,
    parseAudioMuted: parseAudioMuted,
    audioMuteCommand: audioMuteCommand,
    hookCommand: hookCommand,
    notifyCommand: notifyCommand
  }
}
