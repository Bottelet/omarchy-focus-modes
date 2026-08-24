import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

Panel {
  id: root
  moduleName: "bottelet.focus-modes"
  ipcTarget: "bottelet.focus-modes"
  manageIpc: false

  property var anchorItem: null
  property bool openedFromHotkey: false

  // The bar tracks the widget mounted in its slot — BarWidget.qml — not this
  // nested panel, so everything the bar identifies a panel by must be that
  // widget (popout coordinator, switchPanelFrom).
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  readonly property color fg: bar ? bar.foreground : Color.foreground
  readonly property color dim: Qt.darker(fg, 1.4)
  readonly property string fontName: bar ? bar.fontFamily : Style.font.family

  // ------------------------------------------------------------ engine state

  readonly property string stateDir:
    (Quickshell.env("XDG_STATE_HOME") || (Quickshell.env("HOME") + "/.local/state")) + "/omarchy-focus-modes"

  property var modes: Model.sanitizeModes(null)
  property var journal: null          // active journal object, or null = Off
  property var sessions: []
  property var issues: []             // human-readable problems from the last transition
  property real nowMs: Date.now()

  // The bar mounts one widget instance per screen, all in one process, and
  // they share the same state files. Any instance may run a user-initiated
  // transition; automatic work (startup rollback, timer expiry, quarantine
  // sweeps) runs only on the instance elected owner — the one whose host
  // widget sits on the first screen — so it happens exactly once.
  readonly property bool engineOwner:
    !!(hostWidget && hostWidget.qsWindow && hostWidget.qsWindow.screen
       && Quickshell.screens.length > 0 && hostWidget.qsWindow.screen === Quickshell.screens[0])

  // The DND switch is the shell's own notifications service; direct property
  // access is reactive and survives nothing we need it to (the service
  // persists its own state).
  readonly property var notificationsService:
    bar && bar.shell && typeof bar.shell.firstPartyServiceFor === "function"
      ? bar.shell.firstPartyServiceFor("omarchy.notifications") : null

  // Chip mirror (read by BarWidget.qml).
  readonly property bool modeActive: journal !== null
  readonly property string chipIcon: journal ? journal.icon : ""
  readonly property string chipText: {
    if (!journal) return ""
    var rem = Model.remainingMs(journal, nowMs)
    return rem >= 0 ? journal.modeName + " " + Model.formatRemaining(rem) : journal.modeName
  }

  readonly property bool notifyOnAutoRevert:
    setting("notifyOnAutoRevert", true) === true || setting("notifyOnAutoRevert", true) === "true"

  // UI state
  property int selIndex: 0            // 0 = Off card, 1..modes.length = mode cards
  property bool editMode: false
  property string editModeId: ""      // "" while creating a new mode
  property var themeNames: []
  property var openClasses: []        // editor helper: classes of open windows
  property string customMinutes: ""

  signal enginePhase()                // dummy; keeps qmllint quiet if unused

  // ----------------------------------------------------------- persistence

  FileView {
    id: modesView
    path: root.stateDir + "/modes.json"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: {
      var parsed = null
      try { parsed = JSON.parse(text()) } catch (e) {}
      root.modes = Model.sanitizeModes(parsed)
    }
  }

  FileView {
    id: journalView
    path: root.stateDir + "/journal.json"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.syncJournal(Model.parseJournal(text()))
  }

  FileView {
    id: sessionsView
    path: root.stateDir + "/sessions.json"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: if (!root.busy) root.sessions = Model.parseSessions(text())
  }

  function persistModes() {
    modesView.setText(JSON.stringify({ modes: modes }, null, 2) + "\n")
  }

  function persistJournal() {
    journalView.setText(journal ? JSON.stringify(journal) + "\n" : "")
  }

  function persistSessions() {
    sessionsView.setText(JSON.stringify(sessions) + "\n")
  }

  Component.onCompleted: {
    Quickshell.execDetached(["mkdir", "-p", stateDir])
  }

  // ------------------------------------------------------------ step runner
  //
  // One external command at a time, in order. A step is {argv, cb} or
  // {fn} for pure-JS work; cb(ok, stdout) runs when the command exits and
  // its output is fully collected.

  property var _steps: []
  property bool busy: false

  function enqueue(step) { _steps.push(step) }

  function kick() {
    if (busy) return
    busy = true
    runNext()
  }

  function runNext() {
    if (_steps.length === 0) { busy = false; return }
    var step = _steps.shift()
    if (step.fn) {
      step.fn()
      Qt.callLater(runNext)
      return
    }
    stepProc.cb = step.cb || null
    stepProc.exited = false
    stepProc.outDone = false
    stepProc.code = -1
    stepProc.command = step.argv
    stepProc.running = true
  }

  Process {
    id: stepProc
    property var cb: null
    property bool exited: false
    property bool outDone: false
    property int code: -1

    stdout: StdioCollector {
      id: stepCollector
      waitForEnd: true
      onStreamFinished: { stepProc.outDone = true; stepProc.maybeDone() }
    }

    onExited: function(exitCode, exitStatus) {
      code = exitCode
      exited = true
      maybeDone()
    }

    function maybeDone() {
      if (!exited || !outDone) return
      var f = cb
      cb = null
      if (f) f(code === 0, stepCollector.text)
      Qt.callLater(root.runNext)
    }
  }

  // Failsafe: if an external step wedges (missing binary, stuck IPC), fail
  // the transition instead of the whole engine. Generous — the pkexec step
  // alone may legitimately sit for 120 s waiting on the auth dialog.
  Timer {
    interval: 180000
    running: root.busy
    onTriggered: {
      root.addIssue("A step hung — transition aborted; check the journal state")
      root._steps = []
      stepProc.cb = null
      stepProc.running = false
      root.busy = false
    }
  }

  // The keep-awake hold: declaratively alive exactly while the shared journal
  // says a keepAwake mode runs — every instance holds its own (inhibits
  // refcount) and drops it when the journal clears, however the mode ended.
  // If the shell dies, the child dies with it — the inhibitor can never
  // outlive a crash, which is the journal-friendly failure direction.
  function journalHas(moduleName) {
    if (!journal) return false
    for (var i = 0; i < journal.applied.length; i++) {
      if (journal.applied[i].module === moduleName) return true
    }
    return false
  }

  Process {
    id: inhibitProc
    command: Model.inhibitCommand()
    running: root.journalHas("keepAwake")
  }

  // ---------------------------------------------------------------- engine

  function appendApplied(entry) {
    if (!journal) return
    journal.applied.push(entry)
    journal = journal           // reassign so bindings see the change
    persistJournal()
  }

  function addIssue(text) {
    var next = issues.slice()
    next.push(text)
    issues = next
  }

  // Activate modeId with durationMin (0 = untimed). Any active mode is
  // reverted first; the apply only starts once the revert queue drained.
  function activate(modeId, durationMin) {
    var mode = Model.modeById(modes, modeId)
    if (!mode || busy) return
    issues = []
    if (journal) enqueueRevertSteps("switch")
    enqueueApplySteps(mode, durationMin)
    kick()
  }

  function deactivate(reason) {
    if (!journal || busy) return
    issues = []
    enqueueRevertSteps(reason)
    kick()
  }

  function enqueueApplySteps(mode, durationMin) {
    var a = mode.actions
    enqueue({ argv: ["mkdir", "-p", stateDir] })
    enqueue({ fn: function() {
      root.journal = Model.newJournal(mode, durationMin, Date.now())
      root.persistJournal()
    } })

    if (a.dnd.enabled) enqueue({ fn: function() {
      var svc = root.notificationsService
      if (!svc) { root.addIssue("Notifications service unavailable — DND skipped"); return }
      root.appendApplied({ module: "dnd", prev: svc.doNotDisturb === true })
      svc.setDoNotDisturb(true)
    } })

    if (a.theme.enabled && a.theme.name !== "") {
      var prevTheme = ""
      enqueue({ argv: Model.themeCurrentCommand(), cb: function(ok, out) {
        prevTheme = String(out || "").replace(/^\s+|\s+$/g, "")
      } })
      enqueue({ fn: function() {
        var cmd = Model.themeSetCommand(a.theme.name)
        if (!cmd) return
        root.enqueue({ argv: cmd, cb: function(ok) {
          if (ok) root.appendApplied({ module: "theme", prev: prevTheme })
          else root.addIssue("Theme switch failed")
        } })
      } })
    }

    if (a.muteAudio.enabled) {
      enqueue({ argv: Model.audioStatusCommand(), cb: function(ok, out) {
        var wasMuted = Model.parseAudioMuted(out)
        if (!ok) { root.addIssue("wpctl unavailable — mute skipped"); return }
        root.appendApplied({ module: "muteAudio", prevMuted: wasMuted })
        if (!wasMuted) root.enqueue({ argv: Model.audioMuteCommand(true) })
      } })
    }

    if (a.keepAwake.enabled) enqueue({ fn: function() {
      root.appendApplied({ module: "keepAwake" })
    } })

    if (a.blockSites.enabled && a.blockSites.list.length > 0) {
      // Only the immutable root-owned copy is ever handed to pkexec; the
      // user-writable checkout copy exists solely to be reviewed and
      // installed. Missing helper = one-time setup not done yet.
      enqueue({ argv: Model.helperCheckCommand(), cb: function(present) {
        if (!present) {
          root.addIssue("Site blocking needs one-time setup — see README: sudo install the helper to " + Model.systemHelperPath())
          return
        }
        var argv = Model.hostsSetArgv(a.blockSites.list)
        if (argv) root.enqueue({ argv: argv, cb: function(ok) {
          if (ok) root.appendApplied({ module: "blockSites" })
          else root.addIssue("Site blocking skipped (authorization failed or cancelled)")
        } })
      } })
    }

    if (a.quarantineApps.enabled && a.quarantineApps.classes.length > 0) {
      enqueue({ fn: function() {
        root.appendApplied({ module: "quarantineApps",
                             classes: a.quarantineApps.classes.slice(),
                             action: a.quarantineApps.action,
                             windows: [] })
      } })
      enqueue({ argv: Model.hyprClientsCommand(), cb: function(ok, out) {
        if (ok) root.quarantineFromClients(out)
      } })
    }

    if (a.hooks.onEnter !== "" || a.hooks.onExit !== "") {
      enqueue({ fn: function() {
        root.appendApplied({ module: "hooks", onExit: a.hooks.onExit })
        var cmd = Model.hookCommand(a.hooks.onEnter)
        if (cmd) root.enqueue({ argv: cmd, cb: function(ok) {
          if (!ok) root.addIssue("onEnter hook failed (see journal)")
        } })
      } })
    }
  }

  function quarantineEntry() {
    if (!journal) return null
    for (var i = 0; i < journal.applied.length; i++) {
      if (journal.applied[i].module === "quarantineApps") return journal.applied[i]
    }
    return null
  }

  // Move (or close) every currently-open matching window; record where each
  // one came from so revert can put it back.
  function quarantineFromClients(raw) {
    var q = quarantineEntry()
    if (!q) return
    var targets = Model.quarantineTargets(raw, q.classes)
    var known = {}
    for (var i = 0; i < q.windows.length; i++) known[q.windows[i].address] = true
    var changed = false
    for (var j = 0; j < targets.length; j++) {
      var t = targets[j]
      if (known[t.address]) continue
      if (q.action === "close") {
        var closeCmd = Model.closeWindowArgv(t.address)
        if (closeCmd) enqueue({ argv: closeCmd })
        continue
      }
      var moveCmd = Model.moveToQuarantineArgv(t.address)
      if (!moveCmd) continue
      enqueue({ argv: moveCmd })
      q.windows.push({ address: t.address, workspace: t.workspace })
      changed = true
    }
    if (changed) { journal = journal; persistJournal() }
  }

  function enqueueRevertSteps(reason) {
    var j = journal
    if (!j) return
    var endingJournal = j
    for (var i = j.applied.length - 1; i >= 0; i--) {
      (function(entry) {
        switch (entry.module) {
        case "hooks":
          enqueue({ fn: function() {
            var cmd = Model.hookCommand(entry.onExit)
            if (cmd) root.enqueue({ argv: cmd })
          } })
          break
        case "quarantineApps":
          enqueue({ fn: function() {
            for (var w = 0; w < entry.windows.length; w++) {
              var back = Model.moveBackArgv(entry.windows[w].address, entry.windows[w].workspace)
              if (back) root.enqueue({ argv: back })
            }
          } })
          break
        case "blockSites":
          enqueue({ argv: Model.hostsClearArgv(), cb: function(ok) {
            if (!ok) root.addIssue("Could not clean /etc/hosts — run: pkexec " + Model.systemHelperPath() + " --clear")
          } })
          break
        case "keepAwake":
          break // the inhibit hold is bound to journal state; clearing releases it
        case "muteAudio":
          if (entry.prevMuted !== true) enqueue({ argv: Model.audioMuteCommand(false) })
          break
        case "dnd":
          enqueue({ fn: function() {
            var svc = root.notificationsService
            if (svc) svc.setDoNotDisturb(entry.prev === true)
          } })
          break
        case "theme":
          if (Model.validThemeName(entry.prev)) enqueue({ argv: Model.themeSetCommand(entry.prev) })
          break
        }
      })(j.applied[i])
    }
    enqueue({ fn: function() { root.finishDeactivate(endingJournal, reason) } })
  }

  function finishDeactivate(endedJournal, reason) {
    var end = Date.now()
    sessions = Model.appendSession(sessions, endedJournal, end)
    persistSessions()
    if (journal === endedJournal) journal = null
    persistJournal()
    if (reason === "expired" && notifyOnAutoRevert) {
      var mins = Math.round((end - endedJournal.startedAt) / 60000)
      Quickshell.execDetached(Model.notifyCommand(
        endedJournal.modeName + " done",
        "Focused for " + Model.formatMinutes(Math.max(1, mins)) + " — everything restored."))
    }
  }

  // The journal file is the shared truth: on startup and whenever another
  // instance writes it, this instance mirrors it. Expired or crash-orphaned
  // state is rolled back by the owner instance only — that is the power-loss
  // guarantee: hosts blocks never outlive the mode.
  function syncJournal(j) {
    if (busy) return
    if (JSON.stringify(j) === JSON.stringify(journal)) return
    journal = j
    if (j && engineOwner && Model.journalExpired(j, Date.now())) {
      enqueueRevertSteps("expired")
      kick()
    }
  }

  // Second hand for the chip countdown + expiry watchdog + quarantine sweep.
  Timer {
    interval: 1000
    running: root.journal !== null
    repeat: true
    onTriggered: {
      root.nowMs = Date.now()
      if (root.engineOwner && root.journal && Model.journalExpired(root.journal, root.nowMs) && !root.busy) {
        root.deactivate("expired")
      }
    }
  }

  // New windows of a quarantined class are swept every few seconds while the
  // mode runs. Polling keeps this dependency-free; 3 s is far below the time
  // it takes to get distracted.
  Timer {
    interval: 3000
    running: root.engineOwner && root.journal !== null && root.quarantineEntry() !== null
    repeat: true
    onTriggered: {
      if (root.busy) return
      root.enqueue({ argv: Model.hyprClientsCommand(), cb: function(ok, out) {
        if (ok) root.quarantineFromClients(out)
      } })
      root.kick()
    }
  }

  // ------------------------------------------------------------- UI actions

  function cycleMode(direction) {
    var order = [null].concat(modes.map(function(m) { return m.id }))
    var current = journal ? order.indexOf(journal.modeId) : 0
    if (current < 0) current = 0
    var next = (current + direction + order.length) % order.length
    if (order[next] === null) deactivate("user")
    else {
      var m = Model.modeById(modes, order[next])
      activate(m.id, m.defaultDurationMin)
    }
  }

  function activateSelected(durationMin) {
    if (selIndex === 0) { deactivate("user"); return }
    var mode = modes[selIndex - 1]
    if (!mode) return
    activate(mode.id, durationMin === undefined ? mode.defaultDurationMin : durationMin)
  }

  function openEditor(modeId) {
    var mode = modeId ? Model.modeById(modes, modeId) : null
    editModeId = modeId || ""
    editName.text = mode ? mode.name : "New mode"
    editIcon = mode ? mode.icon : ""
    editDnd = mode ? mode.actions.dnd.enabled : false
    editSites.text = mode ? mode.actions.blockSites.list.join(", ") : ""
    editSitesOn = mode ? mode.actions.blockSites.enabled : false
    editApps.text = mode ? mode.actions.quarantineApps.classes.join(", ") : ""
    editAppsOn = mode ? mode.actions.quarantineApps.enabled : false
    editAppsClose = mode ? mode.actions.quarantineApps.action === "close" : false
    editThemeOn = mode ? mode.actions.theme.enabled : false
    editTheme = mode ? mode.actions.theme.name : ""
    editAwake = mode ? mode.actions.keepAwake.enabled : false
    editMute = mode ? mode.actions.muteAudio.enabled : false
    editHookEnter.text = mode ? mode.actions.hooks.onEnter : ""
    editHookExit.text = mode ? mode.actions.hooks.onExit : ""
    editMinutes.text = mode && mode.defaultDurationMin > 0 ? String(mode.defaultDurationMin) : ""
    editMode = true
    loadEditorContext()
  }

  property string editIcon: ""
  property bool editDnd: false
  property bool editSitesOn: false
  property bool editAppsOn: false
  property bool editAppsClose: false
  property bool editThemeOn: false
  property string editTheme: ""
  property bool editAwake: false
  property bool editMute: false

  function loadEditorContext() {
    enqueue({ argv: Model.themeListCommand(), cb: function(ok, out) {
      if (ok) root.themeNames = Model.parseThemeList(out)
    } })
    enqueue({ argv: Model.hyprClientsCommand(), cb: function(ok, out) {
      if (!ok) return
      var clients
      try { clients = JSON.parse(String(out || "")) } catch (e) { return }
      var seen = {}
      var list = []
      for (var i = 0; i < (clients || []).length; i++) {
        var cls = String(clients[i] && clients[i].class || "")
        if (cls === "" || seen[cls.toLowerCase()] || !Model.validClass(cls)) continue
        seen[cls.toLowerCase()] = true
        list.push(cls)
      }
      root.openClasses = list
    } })
    kick()
  }

  function saveEditor() {
    var dur = parseInt(editMinutes.text, 10)
    var candidate = {
      id: editModeId,
      name: editName.text,
      icon: editIcon,
      actions: {
        dnd: { enabled: editDnd, allowCritical: false },
        blockSites: { enabled: editSitesOn, list: Model.parseSiteList(editSites.text).valid },
        quarantineApps: { enabled: editAppsOn, classes: Model.parseClassList(editApps.text), action: editAppsClose ? "close" : "move" },
        theme: { enabled: editThemeOn, name: editTheme },
        keepAwake: { enabled: editAwake },
        muteAudio: { enabled: editMute },
        hooks: { onEnter: editHookEnter.text, onExit: editHookExit.text }
      },
      defaultDurationMin: isNaN(dur) ? 0 : dur
    }
    var clean = Model.sanitizeMode(candidate)
    if (!clean) return
    var next = modes.slice()
    var replaced = false
    for (var i = 0; i < next.length; i++) {
      if (next[i].id === editModeId && editModeId !== "") { next[i] = clean; replaced = true }
    }
    if (!replaced) next.push(clean)
    modes = Model.sanitizeModes({ modes: next })
    persistModes()
    editMode = false
  }

  function deleteEditedMode() {
    if (editModeId === "") { editMode = false; return }
    if (journal && journal.modeId === editModeId) deactivate("user")
    modes = modes.filter(function(m) { return m.id !== editModeId })
    persistModes()
    editMode = false
  }

  // --------------------------------------------------------- panel plumbing

  // Land the selection on the active mode's card (Off otherwise).
  function syncSelection() {
    if (!journal) { selIndex = 0; return }
    for (var i = 0; i < modes.length; i++) {
      if (modes[i].id === journal.modeId) { selIndex = i + 1; return }
    }
    selIndex = 0
  }

  function open() {
    openedFromHotkey = false
    setCenterHoverRevealSuppressed(false)
    root.controller.show()
    root.nowMs = Date.now()
    syncSelection()
  }

  function openFromHotkey() {
    openedFromHotkey = true
    root.controller.show()
    root.nowMs = Date.now()
    syncSelection()
    Qt.callLater(function() {
      if (root.opened) setCenterHoverRevealSuppressed(true)
    })
  }

  function close() {
    setCenterHoverRevealSuppressed(false)
    editMode = false
    root.controller.hide()
  }

  function openSettings() {
    openFromHotkey()
  }

  function toggle() {
    if (root.opened) root.close()
    else root.openFromHotkey()
  }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }

  function setCenterHoverRevealSuppressed(value) {
    if (root.bar && "centerHoverRevealSuppressed" in root.bar)
      root.bar.centerHoverRevealSuppressed = value
  }

  IpcHandler {
    target: root.ipcTarget

    function open(): void { root.openFromHotkey() }
    function close(): void { root.close() }
    function show(): void { root.openFromHotkey() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }

    // Keybinding surface: `omarchy-shell bottelet.focus-modes activate deep-focus`
    function activate(modeId: string): string {
      var mode = Model.modeById(root.modes, String(modeId))
      if (!mode) return "unknown mode: " + modeId
      root.activate(mode.id, mode.defaultDurationMin)
      return "activating " + mode.name
    }

    function off(): string {
      root.deactivate("user")
      return "off"
    }

    function status(): string {
      if (!root.journal) return "off"
      var rem = Model.remainingMs(root.journal, Date.now())
      return root.journal.modeId + (rem >= 0 ? " " + Model.formatRemaining(rem) : "")
    }
  }

  // ------------------------------------------------------------------- view

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    centerOnBar: true
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(420))
    contentHeight: panel.fittedContentHeight(focusColumn.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: root.editMode || customField.activeFocus

      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onMoveRequested: function(dx, dy) {
        var count = root.modes.length + 1
        var next = root.selIndex + dx + dy * 2
        if (next < 0) next = 0
        if (next >= count) next = count - 1
        root.selIndex = next
      }
      onActivateRequested: root.activateSelected()
      onTextKey: function(text) {
        if (text === "1") root.activateSelected(25)
        else if (text === "2") root.activateSelected(50)
        else if (text === "3") root.activateSelected(90)
        else if (text === "e" && root.selIndex > 0 && root.modes[root.selIndex - 1])
          root.openEditor(root.modes[root.selIndex - 1].id)
        else if (text === "n") root.openEditor("")
      }

      Flickable {
        id: focusScroll
        anchors.fill: parent
        contentWidth: width
        contentHeight: focusColumn.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height

        Column {
          id: focusColumn
          width: focusScroll.width
          spacing: Style.space(12)

          // ---- Header
          Item {
            width: parent.width
            height: Math.max(headerLeft.implicitHeight, headerRight.implicitHeight)

            Row {
              id: headerLeft
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(8)

              Text {
                text: "󰈉"
                color: root.modeActive ? Color.accent : root.fg
                font.family: root.fontName
                font.pixelSize: Style.font.heading
                anchors.verticalCenter: parent.verticalCenter
              }
              Text {
                text: root.editMode ? (root.editModeId === "" ? "NEW MODE" : "EDIT MODE") : "FOCUS"
                color: root.dim
                font.family: root.fontName
                font.pixelSize: Style.font.caption
                font.bold: true
                font.letterSpacing: 1
                anchors.verticalCenter: parent.verticalCenter
              }
            }

            Row {
              id: headerRight
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(8)

              Rectangle {
                visible: !root.editMode
                width: newRow.implicitWidth + Style.space(14)
                height: newRow.implicitHeight + Style.space(8)
                radius: Style.cornerRadius
                color: newArea.containsMouse ? Style.hoverFillFor(root.fg, Color.accent) : "transparent"
                border.width: 1
                border.color: Qt.rgba(root.dim.r, root.dim.g, root.dim.b, 0.45)
                anchors.verticalCenter: parent.verticalCenter

                Row {
                  id: newRow
                  anchors.centerIn: parent
                  spacing: Style.space(5)
                  Text {
                    text: ""
                    color: root.dim
                    font.family: root.fontName
                    font.pixelSize: Style.font.caption
                    anchors.verticalCenter: parent.verticalCenter
                  }
                  Text {
                    text: "new mode"
                    color: root.fg
                    font.family: root.fontName
                    font.pixelSize: Style.font.caption
                    anchors.verticalCenter: parent.verticalCenter
                  }
                }

                MouseArea {
                  id: newArea
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.openEditor("")
                }
              }
            }
          }

          // ---- Issues from the last transition
          Rectangle {
            visible: !root.editMode && root.issues.length > 0
            width: parent.width
            radius: Style.cornerRadius
            color: Qt.rgba(Color.urgent.r, Color.urgent.g, Color.urgent.b, 0.08)
            border.width: 1
            border.color: Qt.rgba(Color.urgent.r, Color.urgent.g, Color.urgent.b, 0.4)
            implicitHeight: issuesColumn.implicitHeight + Style.space(12)

            Column {
              id: issuesColumn
              anchors.centerIn: parent
              width: parent.width - Style.space(16)
              spacing: Style.space(3)

              Repeater {
                model: root.issues
                Text {
                  required property var modelData
                  width: parent.width
                  text: "󰀪 " + modelData
                  textFormat: Text.PlainText
                  color: Color.urgent
                  font.family: root.fontName
                  font.pixelSize: Style.font.caption
                  wrapMode: Text.Wrap
                }
              }
            }
          }

          // ---- Mode cards (Off + user modes)
          Flow {
            visible: !root.editMode
            width: parent.width
            spacing: Style.space(8)

            // Off card
            Rectangle {
              readonly property bool selected: root.selIndex === 0
              readonly property bool current: !root.modeActive
              width: (parent.width - Style.space(8)) / 2
              implicitHeight: offColumn.implicitHeight + Style.space(20)
              radius: Style.cornerRadius
              color: current ? Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.08)
                   : (offArea.containsMouse ? Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.05) : Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.02))
              border.width: 1
              border.color: selected ? Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.7)
                                     : Qt.rgba(root.dim.r, root.dim.g, root.dim.b, 0.3)

              Column {
                id: offColumn
                anchors.centerIn: parent
                spacing: Style.space(4)

                Text {
                  text: "󰈉"
                  anchors.horizontalCenter: parent.horizontalCenter
                  color: root.dim
                  font.family: root.fontName
                  font.pixelSize: Style.font.heading
                }
                Text {
                  text: "Off"
                  anchors.horizontalCenter: parent.horizontalCenter
                  color: root.fg
                  font.family: root.fontName
                  font.pixelSize: Style.font.bodySmall
                  font.bold: !root.modeActive
                }
                Text {
                  visible: !root.modeActive
                  text: "no mode active"
                  anchors.horizontalCenter: parent.horizontalCenter
                  color: root.dim
                  font.family: root.fontName
                  font.pixelSize: Style.font.caption
                }
              }

              MouseArea {
                id: offArea
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: { root.selIndex = 0; root.deactivate("user") }
              }
            }

            Repeater {
              model: root.modes

              Rectangle {
                id: modeCard
                required property var modelData
                required property int index

                readonly property bool selected: root.selIndex === index + 1
                readonly property bool current: root.journal !== null && root.journal.modeId === modelData.id
                readonly property real remMs: current ? Model.remainingMs(root.journal, root.nowMs) : -1

                width: (parent.width - Style.space(8)) / 2
                implicitHeight: cardColumn.implicitHeight + Style.space(20)
                radius: Style.cornerRadius
                color: current ? Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.12)
                     : (cardArea.containsMouse ? Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.05) : Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.02))
                border.width: 1
                border.color: current ? Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.85)
                            : selected ? Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.7)
                                       : Qt.rgba(root.dim.r, root.dim.g, root.dim.b, 0.3)

                Column {
                  id: cardColumn
                  anchors.centerIn: parent
                  spacing: Style.space(4)

                  Text {
                    text: modeCard.modelData.icon
                    textFormat: Text.PlainText
                    anchors.horizontalCenter: parent.horizontalCenter
                    color: modeCard.current ? Color.accent : root.fg
                    font.family: root.fontName
                    font.pixelSize: Style.font.heading
                  }
                  Text {
                    text: modeCard.modelData.name
                    textFormat: Text.PlainText
                    anchors.horizontalCenter: parent.horizontalCenter
                    color: modeCard.current ? Color.accent : root.fg
                    font.family: root.fontName
                    font.pixelSize: Style.font.bodySmall
                    font.bold: modeCard.current
                  }

                  Row {
                    anchors.horizontalCenter: parent.horizontalCenter
                    spacing: Style.space(5)

                    Repeater {
                      model: Model.actionGlyphs(modeCard.modelData)
                      Text {
                        required property var modelData
                        text: modelData.glyph
                        color: root.dim
                        font.family: root.fontName
                        font.pixelSize: Style.font.caption
                      }
                    }
                  }

                  Text {
                    visible: modeCard.current
                    text: modeCard.remMs >= 0
                          ? Model.formatRemaining(modeCard.remMs) + " left"
                          : Model.formatMinutes(Math.max(1, Math.round(Model.elapsedMs(root.journal, root.nowMs) / 60000))) + " in"
                    anchors.horizontalCenter: parent.horizontalCenter
                    color: Color.accent
                    font.family: root.fontName
                    font.pixelSize: Style.font.caption
                  }

                  Row {
                    anchors.horizontalCenter: parent.horizontalCenter
                    spacing: Style.space(8)

                    Text {
                      visible: modeCard.current
                      text: "end now"
                      color: root.dim
                      font.family: root.fontName
                      font.pixelSize: Style.font.caption
                      font.underline: endArea.containsMouse

                      MouseArea {
                        id: endArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.deactivate("user")
                      }
                    }

                    Text {
                      text: ""
                      visible: modeCard.selected || cardArea.containsMouse
                      color: editArea.containsMouse ? root.fg : root.dim
                      font.family: root.fontName
                      font.pixelSize: Style.font.caption

                      MouseArea {
                        id: editArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.openEditor(modeCard.modelData.id)
                      }
                    }
                  }
                }

                MouseArea {
                  id: cardArea
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  z: -1
                  onClicked: {
                    root.selIndex = modeCard.index + 1
                    // Clicking the already-active card is a select, not a restart.
                    if (!modeCard.current)
                      root.activate(modeCard.modelData.id, modeCard.modelData.defaultDurationMin)
                  }
                }
              }
            }
          }

          // ---- Quick timer row for the selected mode
          Row {
            visible: !root.editMode && root.selIndex > 0
            spacing: Style.space(6)

            Text {
              text: "start timed:"
              color: root.dim
              font.family: root.fontName
              font.pixelSize: Style.font.caption
              anchors.verticalCenter: parent.verticalCenter
            }

            Repeater {
              model: [25, 50, 90]

              Rectangle {
                required property var modelData
                width: presetText.implicitWidth + Style.space(14)
                height: presetText.implicitHeight + Style.space(8)
                radius: Style.cornerRadius
                color: presetArea.containsMouse ? Style.hoverFillFor(root.fg, Color.accent) : "transparent"
                border.width: 1
                border.color: Qt.rgba(root.dim.r, root.dim.g, root.dim.b, 0.45)

                Text {
                  id: presetText
                  anchors.centerIn: parent
                  text: parent.modelData + "m"
                  color: root.fg
                  font.family: root.fontName
                  font.pixelSize: Style.font.caption
                }

                MouseArea {
                  id: presetArea
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.activateSelected(parent.modelData)
                }
              }
            }

            TextField {
              id: customField
              width: Style.space(64)
              placeholderText: "min"
              foreground: root.fg
              font.family: root.fontName
              anchors.verticalCenter: parent.verticalCenter

              Keys.onPressed: function(event) {
                if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                  var v = parseInt(text, 10)
                  if (!isNaN(v) && v > 0) root.activateSelected(Math.min(v, 24 * 60))
                  text = ""
                  keyCatcher.forceActiveFocus()
                  event.accepted = true
                } else if (event.key === Qt.Key_Escape) {
                  text = ""
                  keyCatcher.forceActiveFocus()
                  event.accepted = true
                }
              }
            }
          }

          // ---- This week
          Column {
            visible: !root.editMode && Model.weekTotals(root.sessions, root.nowMs).length > 0
            width: parent.width
            spacing: Style.space(4)

            PanelSectionHeader { text: "This week" }

            Repeater {
              model: Model.weekTotals(root.sessions, root.nowMs)

              Item {
                required property var modelData
                width: parent.width
                height: weekName.implicitHeight + Style.space(2)

                Text {
                  id: weekName
                  anchors.left: parent.left
                  text: modelData.name
                  textFormat: Text.PlainText
                  color: root.fg
                  font.family: root.fontName
                  font.pixelSize: Style.font.caption
                }
                Text {
                  anchors.right: parent.right
                  text: Model.formatMinutes(modelData.minutes)
                  color: root.dim
                  font.family: root.fontName
                  font.pixelSize: Style.font.caption
                }
              }
            }
          }

          // ---- Keyboard hint
          Text {
            visible: !root.editMode
            width: parent.width
            text: "←→ select · ↵ start · 1/2/3 = 25/50/90 min · e edit · n new · esc close"
            color: Qt.rgba(root.dim.r, root.dim.g, root.dim.b, 0.7)
            font.family: root.fontName
            font.pixelSize: Style.font.caption
            wrapMode: Text.Wrap
          }

          // ================================================= Editor
          Column {
            visible: root.editMode
            width: parent.width
            spacing: Style.space(10)

            // name + icon
            Row {
              width: parent.width
              spacing: Style.space(8)

              TextField {
                id: editName
                width: parent.width - iconRow.width - Style.space(8)
                placeholderText: "Mode name"
                foreground: root.fg
                font.family: root.fontName
              }

              Row {
                id: iconRow
                spacing: Style.space(2)
                anchors.verticalCenter: parent.verticalCenter

                Repeater {
                  model: Model.iconChoices()

                  Rectangle {
                    required property var modelData
                    width: Style.space(20)
                    height: Style.space(20)
                    radius: Math.min(4, Style.cornerRadius)
                    color: root.editIcon === modelData ? Style.hoverFillFor(root.fg, Color.accent) : "transparent"

                    Text {
                      anchors.centerIn: parent
                      text: parent.modelData
                      color: root.editIcon === parent.modelData ? Color.accent : root.dim
                      font.family: root.fontName
                      font.pixelSize: Style.font.bodySmall
                    }
                    MouseArea {
                      anchors.fill: parent
                      cursorShape: Qt.PointingHandCursor
                      onClicked: root.editIcon = parent.modelData
                    }
                  }
                }
              }
            }

            // default timer
            Row {
              spacing: Style.space(8)
              Text {
                text: "Default timer (min, empty = until turned off)"
                color: root.dim
                font.family: root.fontName
                font.pixelSize: Style.font.caption
                anchors.verticalCenter: parent.verticalCenter
              }
              TextField {
                id: editMinutes
                width: Style.space(64)
                placeholderText: "—"
                foreground: root.fg
                font.family: root.fontName
              }
            }

            PanelSeparator {}

            // DND
            Column {
              width: parent.width
              spacing: Style.space(4)
              ToggleRow { label: "Silence notifications (DND)"; checked: root.editDnd; onToggled: root.editDnd = !root.editDnd }
              Text {
                visible: root.editDnd
                width: parent.width
                text: "Uses the shell's do-not-disturb. All apps are silenced (history still records them); only omarchy system alerts pass through."
                color: root.dim
                font.family: root.fontName
                font.pixelSize: Style.font.caption
                wrapMode: Text.Wrap
              }
            }

            // Sites
            Column {
              width: parent.width
              spacing: Style.space(4)
              ToggleRow { label: "Block distracting sites"; checked: root.editSitesOn; onToggled: root.editSitesOn = !root.editSitesOn }

              TextField {
                id: editSites
                visible: root.editSitesOn
                width: parent.width
                placeholderText: "domains, comma-separated — reddit.com, x.com"
                foreground: root.fg
                font.family: root.fontName
              }

              Text {
                visible: root.editSitesOn && Model.parseSiteList(editSites.text).invalid.length > 0
                width: parent.width
                text: "ignored (not a valid public domain): " + Model.parseSiteList(editSites.text).invalid.join(", ")
                textFormat: Text.PlainText
                color: Color.urgent
                font.family: root.fontName
                font.pixelSize: Style.font.caption
                wrapMode: Text.Wrap
              }

              Text {
                visible: root.editSitesOn
                width: parent.width
                text: "Blocked via /etc/hosts using the root-installed helper (one-time setup in README; polkit asks on each start). localhost, *.local and this machine's own names can never be blocked."
                color: root.dim
                font.family: root.fontName
                font.pixelSize: Style.font.caption
                wrapMode: Text.Wrap
              }
            }

            // Apps
            Column {
              width: parent.width
              spacing: Style.space(4)
              ToggleRow { label: "Quarantine distracting apps"; checked: root.editAppsOn; onToggled: root.editAppsOn = !root.editAppsOn }

              TextField {
                id: editApps
                visible: root.editAppsOn
                width: parent.width
                placeholderText: "window classes — discord, org.telegram.desktop"
                foreground: root.fg
                font.family: root.fontName
              }

              Flow {
                visible: root.editAppsOn && root.openClasses.length > 0
                width: parent.width
                spacing: Style.space(4)

                Text {
                  text: "open now:"
                  color: root.dim
                  font.family: root.fontName
                  font.pixelSize: Style.font.caption
                }

                Repeater {
                  model: root.openClasses

                  Rectangle {
                    required property var modelData
                    width: pickText.implicitWidth + Style.space(10)
                    height: pickText.implicitHeight + Style.space(4)
                    radius: Style.cornerRadius
                    color: pickArea.containsMouse ? Style.hoverFillFor(root.fg, Color.accent) : "transparent"
                    border.width: 1
                    border.color: Qt.rgba(root.dim.r, root.dim.g, root.dim.b, 0.35)

                    Text {
                      id: pickText
                      anchors.centerIn: parent
                      text: parent.modelData
                      textFormat: Text.PlainText
                      color: root.fg
                      font.family: root.fontName
                      font.pixelSize: Style.font.caption
                    }
                    MouseArea {
                      id: pickArea
                      anchors.fill: parent
                      hoverEnabled: true
                      cursorShape: Qt.PointingHandCursor
                      onClicked: {
                        var current = Model.parseClassList(editApps.text)
                        if (current.indexOf(parent.modelData) === -1) {
                          var base = editApps.text.replace(/[,\s]+$/, "")
                          editApps.text = base === "" ? parent.modelData : base + ", " + parent.modelData
                        }
                      }
                    }
                  }
                }
              }

              ToggleRow {
                visible: root.editAppsOn
                label: "Close instead of moving to quarantine workspace"
                checked: root.editAppsClose
                onToggled: root.editAppsClose = !root.editAppsClose
              }
            }

            // Theme
            Column {
              width: parent.width
              spacing: Style.space(4)
              ToggleRow { label: "Switch theme"; checked: root.editThemeOn; onToggled: root.editThemeOn = !root.editThemeOn }

              Flow {
                visible: root.editThemeOn
                width: parent.width
                spacing: Style.space(4)

                Repeater {
                  model: root.themeNames

                  Rectangle {
                    required property var modelData
                    width: themeText.implicitWidth + Style.space(10)
                    height: themeText.implicitHeight + Style.space(4)
                    radius: Style.cornerRadius
                    color: root.editTheme === modelData || themeArea.containsMouse ? Style.hoverFillFor(root.fg, Color.accent) : "transparent"
                    border.width: 1
                    border.color: Qt.rgba(root.dim.r, root.dim.g, root.dim.b, root.editTheme === modelData ? 0.9 : 0.35)

                    Text {
                      id: themeText
                      anchors.centerIn: parent
                      text: parent.modelData
                      textFormat: Text.PlainText
                      color: root.editTheme === parent.modelData ? Color.accent : root.fg
                      font.family: root.fontName
                      font.pixelSize: Style.font.caption
                    }
                    MouseArea {
                      id: themeArea
                      anchors.fill: parent
                      hoverEnabled: true
                      cursorShape: Qt.PointingHandCursor
                      onClicked: root.editTheme = parent.modelData
                    }
                  }
                }
              }
            }

            ToggleRow { label: "Keep screen awake"; checked: root.editAwake; onToggled: root.editAwake = !root.editAwake }
            ToggleRow { label: "Mute audio"; checked: root.editMute; onToggled: root.editMute = !root.editMute }

            PanelSeparator {}

            // Hooks
            Column {
              width: parent.width
              spacing: Style.space(4)

              Text {
                text: "Hooks — your own commands, run on enter/exit (10 s timeout)"
                color: root.dim
                font.family: root.fontName
                font.pixelSize: Style.font.caption
              }
              TextField {
                id: editHookEnter
                width: parent.width
                placeholderText: "on enter — e.g. slack-status focus"
                foreground: root.fg
                font.family: root.fontName
              }
              TextField {
                id: editHookExit
                width: parent.width
                placeholderText: "on exit"
                foreground: root.fg
                font.family: root.fontName
              }
            }

            // actions
            Row {
              anchors.right: parent.right
              spacing: Style.space(8)

              Text {
                visible: root.editModeId !== ""
                text: "delete"
                color: deleteArea.containsMouse ? Color.urgent : root.dim
                font.family: root.fontName
                font.pixelSize: Style.font.bodySmall

                MouseArea {
                  id: deleteArea
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.deleteEditedMode()
                }
              }

              Text {
                text: "cancel"
                color: cancelArea.containsMouse ? root.fg : root.dim
                font.family: root.fontName
                font.pixelSize: Style.font.bodySmall

                MouseArea {
                  id: cancelArea
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.editMode = false
                }
              }

              Rectangle {
                width: saveText.implicitWidth + Style.space(18)
                height: saveText.implicitHeight + Style.space(10)
                radius: Style.cornerRadius
                color: saveArea.containsMouse ? Style.hoverFillFor(root.fg, Color.accent) : "transparent"
                border.width: 1
                border.color: Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.7)

                Text {
                  id: saveText
                  anchors.centerIn: parent
                  text: "save"
                  color: Color.accent
                  font.family: root.fontName
                  font.pixelSize: Style.font.bodySmall
                  font.bold: true
                }
                MouseArea {
                  id: saveArea
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.saveEditor()
                }
              }
            }
          }
        }
      }
    }
  }

  // Small labelled toggle used across the editor.
  component ToggleRow: Item {
    id: toggleRow
    property string label: ""
    property bool checked: false
    signal toggled()

    width: parent ? parent.width : implicitWidth
    height: toggleLabel.implicitHeight + Style.space(6)

    Rectangle {
      id: toggleBox
      width: Style.space(26)
      height: Style.space(14)
      radius: height / 2
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      color: toggleRow.checked ? Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.5) : Qt.rgba(root.dim.r, root.dim.g, root.dim.b, 0.25)

      Rectangle {
        width: parent.height - 4
        height: parent.height - 4
        radius: height / 2
        anchors.verticalCenter: parent.verticalCenter
        x: toggleRow.checked ? parent.width - width - 2 : 2
        color: toggleRow.checked ? Color.accent : root.dim
        Behavior on x { NumberAnimation { duration: 100 } }
      }
    }

    Text {
      id: toggleLabel
      anchors.left: toggleBox.right
      anchors.leftMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
      text: toggleRow.label
      color: root.fg
      font.family: root.fontName
      font.pixelSize: Style.font.bodySmall
    }

    MouseArea {
      anchors.fill: parent
      cursorShape: Qt.PointingHandCursor
      onClicked: toggleRow.toggled()
    }
  }
}
