// Engine logic tests, run under node by tests/run.sh.
"use strict"

const path = process.argv[2]
if (!path) { console.error("usage: node model.test.js <Model.js>"); process.exit(2) }
const M = require(require("path").resolve(path))

let pass = 0
let fail = 0
function ok(name, cond, detail) {
  if (cond) { pass++; console.log("  ok   " + name) }
  else { fail++; console.log("  FAIL " + name + (detail !== undefined ? " — " + detail : "")) }
}
function eq(name, expected, actual) {
  ok(name, JSON.stringify(expected) === JSON.stringify(actual),
     "expected " + JSON.stringify(expected) + " got " + JSON.stringify(actual))
}

// ---- domains
ok("domain: plain ok", M.validDomain("reddit.com"))
ok("domain: subdomain ok", M.validDomain("news.ycombinator.com"))
ok("domain: uppercase handled by caller list parse", M.parseSiteList("Reddit.COM").valid[0] === "reddit.com")
ok("domain: ip rejected", !M.validDomain("192.168.1.1"))
ok("domain: localhost rejected", !M.validDomain("localhost"))
ok("domain: sub.localhost rejected", !M.validDomain("evil.localhost"))
ok("domain: .local rejected", !M.validDomain("nas.local"))
ok("domain: injection rejected", !M.validDomain("a.com 0.0.0.0 evil.com"))
ok("domain: bare tld rejected", !M.validDomain("com"))
ok("domain: overlong label rejected", !M.validDomain("a".repeat(64) + ".com"))

const parsed = M.parseSiteList("reddit.com, BAD_HOST\nreddit.com x.com")
eq("site list: dedupe across separators", ["reddit.com", "x.com"], parsed.valid)
eq("site list: invalid reported", ["bad_host"], parsed.invalid)

// ---- classes
eq("class list: parse", ["discord", "org.telegram.desktop"], M.parseClassList("discord, org.telegram.desktop\ndiscord"))
ok("class: shell meta rejected", M.parseClassList("bad;class").length === 0)

// ---- modes
const modes = M.sanitizeModes(null)
ok("defaults: three modes", modes.length === 3)
ok("defaults: deep-focus present", !!M.modeById(modes, "deep-focus"))
ok("defaults: deep focus glyphs", M.actionGlyphs(M.modeById(modes, "deep-focus")).length >= 3)

const evil = M.sanitizeModes({ modes: [
  { id: "x", name: "Ok", actions: { blockSites: { enabled: true, list: ["good.com", "bad host", "127.0.0.1"] }, theme: { enabled: true, name: "-rf" } } },
  { id: "x", name: "Dup id", actions: {} },
  { name: "", actions: {} },
  { name: "Long".repeat(100), actions: {} }
]})
eq("sanitize: bad sites dropped", ["good.com"], evil[0].actions.blockSites.list)
ok("sanitize: option-injection theme dropped", evil[0].actions.theme.enabled === false)
ok("sanitize: duplicate id renamed", evil[1].id !== "x")
ok("sanitize: nameless mode dropped, long name truncated", evil.length === 3 && evil[2].name.length <= 40)

// ---- journal
const mode = M.modeById(modes, "deep-focus")
const t0 = 1700000000000
const j = M.newJournal(mode, 50, t0)
ok("journal: endsAt set", j.endsAt === t0 + 50 * 60000)
ok("journal: no timer -> null endsAt", M.newJournal(mode, 0, t0).endsAt === null)
ok("journal: roundtrip", M.parseJournal(JSON.stringify(j)).modeId === "deep-focus")
ok("journal: garbage -> null", M.parseJournal("{nope") === null)
ok("journal: wrong version -> null", M.parseJournal(JSON.stringify({ v: 99, modeId: "x" })) === null)
ok("journal: not expired mid-run", !M.journalExpired(j, t0 + 10 * 60000))
ok("journal: expired after end", M.journalExpired(j, t0 + 51 * 60000))
eq("journal: remaining", 40 * 60000, M.remainingMs(j, t0 + 10 * 60000))
ok("journal: untimed remaining -1", M.remainingMs(M.newJournal(mode, 0, t0), t0) === -1)

// ---- sessions
let sessions = []
sessions = M.appendSession(sessions, j, t0 + 50 * 60000)
ok("sessions: appended", sessions.length === 1)
sessions = M.appendSession(sessions, M.newJournal(mode, 0, t0), t0 + 30000)
ok("sessions: sub-minute session dropped", sessions.length === 1)
const totals = M.weekTotals(sessions, t0 + 86400000)
eq("sessions: week total", [{ modeId: "deep-focus", name: "Deep Focus", minutes: 50 }], totals)
ok("sessions: old sessions age out", M.weekTotals(sessions, t0 + 9 * 86400000).length === 0)

// ---- formatting
eq("format: remaining m:ss", "49:59", M.formatRemaining(49 * 60000 + 59000))
eq("format: remaining h:mm:ss", "1:05:00", M.formatRemaining(65 * 60000))
eq("format: minutes", "1h 30m", M.formatMinutes(90))

// ---- command builders
ok("theme: set builds argv", Array.isArray(M.themeSetCommand("tokyo-night")))
ok("theme: option injection blocked", M.themeSetCommand("-rf") === null)
ok("theme: newline blocked", M.themeSetCommand("a\nb") === null)

const hosts = M.hostsSetArgv(["reddit.com", "bad host", "x.com"])
eq("hosts: only valid domains in argv",
   ["timeout", "120", "pkexec", "/usr/local/bin/focus-modes-hosts", "--set", "reddit.com", "x.com"], hosts)
ok("hosts: all-invalid -> null", M.hostsSetArgv(["bad host"]) === null)
ok("hosts: only the system path is ever invoked",
   M.hostsClearArgv().indexOf("/usr/local/bin/focus-modes-hosts") === 3 && M.systemHelperPath() === "/usr/local/bin/focus-modes-hosts")

const clients = JSON.stringify([
  { address: "0xabc123", class: "discord", initialClass: "discord", workspace: { id: 2, name: "2" } },
  { address: "0xdef456", class: "Slack", initialClass: "Slack", workspace: { id: 3, name: "3" } },
  { address: "0x999", class: "discord", initialClass: "discord", workspace: { id: -98, name: "special:scratch" } },
  { address: "not-an-address", class: "discord", workspace: { id: 4, name: "4" } }
])
const targets = M.quarantineTargets(clients, ["discord"])
eq("quarantine: matches class on regular ws only", [{ address: "0xabc123", workspace: 2 }], targets)
eq("quarantine: move argv", ["hyprctl", "eval",
  'hl.dispatch(hl.dsp.window.move({ window = "address:0xabc123", workspace = "special:quarantine", silent = true }))'],
  M.moveToQuarantineArgv("0xabc123"))
eq("quarantine: move back argv", ["hyprctl", "eval",
  'hl.dispatch(hl.dsp.window.move({ window = "address:0xabc123", workspace = "2", silent = true }))'],
  M.moveBackArgv("0xabc123", 2))
ok("quarantine: bad address -> null", M.moveToQuarantineArgv("evil,exec:rm") === null)
ok("quarantine: bad workspace -> null", M.moveBackArgv("0xabc123", "special:x") === null)

ok("audio: muted parse", M.parseAudioMuted("Volume: 0.55 [MUTED]"))
ok("audio: unmuted parse", !M.parseAudioMuted("Volume: 0.55"))

eq("hook: wrapped with timeout", ["timeout", "10", "sh", "-c", "echo hi"], M.hookCommand("echo hi"))
ok("hook: empty -> null", M.hookCommand("   ") === null)

console.log("model.js: passed " + pass + ", failed " + fail)
process.exit(fail === 0 ? 0 : 1)
