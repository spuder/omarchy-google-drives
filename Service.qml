import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import "Model.js" as Model

// Owns all Google Drive account state for the panel. Talks to two helper
// scripts shipped in bin/: `googledrive-status` (read-only, one JSON object
// describing every configured account) and `googledrive-accountctl`
// (add/remove/pause/resume/sync-now, each a single subcommand). Neither
// script is this plugin's sync engine — that's rclone bisync, run
// periodically by the per-account `omarchy-google-drive-bisync@<id>.timer`
// systemd user unit. See PLAN.md for why the daemon lives outside the QML
// process, same reasoning as the sister Proton Drive plugin.
Item {
  id: root

  property var settings: ({})
  readonly property string pluginDir: Qt.resolvedUrl(".").toString().replace("file://", "")

  property bool rcloneInstalled: false
  property var accounts: []
  property string lastError: ""
  property string actionStatus: ""

  // Optimistic per-account pause/resume, same idea as the Proton Drive
  // plugin's `_desiredActive`, but keyed by account id since several
  // accounts can be mid-toggle at once.
  property var _desiredEnabled: ({})

  readonly property string aggregateState: Model.aggregateState(accounts)
  readonly property string aggregateStatusText: Model.aggregateSummary(accounts)
  readonly property double totalUsedBytes: Model.totalUsedBytes(accounts)
  readonly property bool busy: statusProcess.running || controlProcess.running

  readonly property int refreshIntervalSec: intSetting("refreshIntervalSec", 30, 5, 600)

  property string _statusOutput: ""
  property string _statusError: ""
  property string _controlOutput: ""
  property string _controlError: ""

  function setting(name, fallback) {
    var value = settings ? settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }

  function intSetting(name, fallback, min, max) {
    var n = parseInt(String(setting(name, fallback)), 10)
    if (!isFinite(n)) n = fallback
    if (n < min) n = min
    if (n > max) n = max
    return n
  }

  function displayEnabled(account) {
    var desired = root._desiredEnabled[account.id]
    return desired === undefined ? account.timerEnabled : desired
  }

  function statusFor(account) {
    return Model.statusText(account, Math.floor(Date.now() / 1000))
  }

  function refresh() {
    if (statusProcess.running) return
    _statusOutput = ""
    _statusError = ""
    statusProcess.command = ["python3", root.pluginDir + "bin/googledrive-status"]
    statusProcess.running = true
  }

  function applyStatus(raw) {
    var parsed = Model.parseAccounts(raw)
    if (!parsed.ok) {
      lastError = parsed.lastError || "Failed to read Google Drives status"
      return
    }
    rcloneInstalled = parsed.rcloneInstalled === true
    accounts = parsed.accounts
    lastError = ""
    // Reality caught up to any pending pause/resume — stop overriding.
    var next = {}
    for (var i = 0; i < accounts.length; i++) {
      var a = accounts[i]
      var desired = root._desiredEnabled[a.id]
      if (desired !== undefined && desired !== a.timerEnabled) next[a.id] = desired
    }
    root._desiredEnabled = next
  }

  function elide(text) {
    var value = String(text || "").replace(/\s+/g, " ").trim()
    return value.length > 140 ? value.substring(0, 137) + "…" : value
  }

  function toggleAccount(id) {
    var account = accounts.find(function(a) { return a.id === id })
    if (!account || controlProcess.running) return
    var desired = !displayEnabled(account)
    var next = Object.assign({}, root._desiredEnabled)
    next[id] = desired
    root._desiredEnabled = next
    runControl([desired ? "resume" : "pause", id])
  }

  function syncNow(id) {
    if (controlProcess.running) return
    runControl(["sync-now", id])
  }

  function openSyncFolder(account) {
    if (!account || !account.syncPath) return
    Quickshell.execDetached(["uwsm-app", "--", "nautilus", account.syncPath])
  }

  // Google's OAuth sign-in is a browser hand-off, not a password this
  // plugin ever needs to see — `rclone config create ... drive` prints or
  // opens the consent URL itself and blocks until you approve it. So
  // "Add account" opens a real terminal running googledrive-accountctl,
  // the same launcher pattern used by other rclone-based Omarchy cloud
  // plugins for their own interactive sign-ins, rather than an in-panel
  // form (contrast the Proton Drive plugin, which *does* need a form:
  // Proton has no OAuth hand-off, rclone's protondrive backend does its
  // own SRP login and needs the actual password).
  function beginAddAccount() {
    Quickshell.execDetached([
      "omarchy-launch-floating-terminal-with-presentation",
      root.pluginDir + "bin/googledrive-accountctl", "add"
    ])
    delayedRefresh.restart()
  }

  function runControl(command) {
    _controlOutput = ""
    _controlError = ""
    controlProcess.command = ["python3", root.pluginDir + "bin/googledrive-accountctl"].concat(command)
    controlProcess.running = true
  }

  Timer {
    id: refreshTimer
    interval: root.refreshIntervalSec * 1000
    repeat: true
    running: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  Timer {
    id: delayedRefresh
    interval: 800
    repeat: false
    onTriggered: root.refresh()
  }

  Timer {
    id: actionStatusTimer
    interval: 2200
    repeat: false
    onTriggered: root.actionStatus = ""
  }

  Process {
    id: statusProcess
    running: false
    command: []
    stdout: StdioCollector { id: statusStdout; waitForEnd: true; onStreamFinished: root._statusOutput = text }
    stderr: StdioCollector { id: statusStderr; waitForEnd: true; onStreamFinished: root._statusError = text }
    onExited: function(exitCode) {
      var stdout = String(statusStdout.text || root._statusOutput || "")
      var stderr = String(statusStderr.text || root._statusError || "")
      if (exitCode === 0) root.applyStatus(stdout)
      else root.lastError = root.elide(stderr || stdout || "Could not read Google Drives status")
    }
  }

  Process {
    id: controlProcess
    running: false
    command: []
    stdout: StdioCollector { id: controlStdout; waitForEnd: true; onStreamFinished: root._controlOutput = text }
    stderr: StdioCollector { id: controlStderr; waitForEnd: true; onStreamFinished: root._controlError = text }
    onExited: function(exitCode) {
      var stdout = String(controlStdout.text || root._controlOutput || "")
      var stderr = String(controlStderr.text || root._controlError || "")
      if (exitCode !== 0) {
        root.lastError = root.elide(stderr || stdout || "Google Drives command failed")
        root.actionStatus = root.lastError
        actionStatusTimer.restart()
      }
      delayedRefresh.restart()
    }
  }
}
