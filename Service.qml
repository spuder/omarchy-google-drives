import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import "Model.js" as Model

// Owns all Google Drive account state for the panel. Talks to two helper
// scripts shipped in bin/: `googledrive-status` (read-only, one JSON object
// describing every configured account) and `googledrive-accountctl`
// (add/remove/pause/resume, each a single subcommand). Neither script is
// this plugin's transport — that's rclone mount, supervised by the
// per-account `omarchy-google-drive-mount@<id>.service` systemd user unit.
// See PLAN.md for why the daemon lives outside the QML process, and for
// why this is a mount rather than a full local sync (rclone bisync has no
// way to bound local disk usage, so it can't safely handle a Drive account
// bigger than free local disk — a mount's VFS cache can).
Item {
  id: root

  property var settings: ({})
  readonly property string pluginDir: Qt.resolvedUrl(".").toString().replace("file://", "")

  property bool rcloneInstalled: false
  property var accounts: []
  property string lastError: ""
  property string actionStatus: ""

  // Optimistic per-account pause/resume, same idea as the Dropbox plugin's
  // single `_desired` flag but keyed by account id since several accounts
  // can be mid-toggle at once.
  property var _desiredActive: ({})

  readonly property string aggregateState: Model.aggregateState(accounts)
  readonly property string aggregateStatusText: Model.aggregateSummary(accounts)
  readonly property double totalUsedBytes: Model.totalUsedBytes(accounts)
  readonly property bool busy: statusProcess.running || controlProcess.running

  readonly property int refreshIntervalSec: intSetting("refreshIntervalSec", 30, 5, 600)

  property string _statusOutput: ""
  property string _statusError: ""
  property string _controlOutput: ""
  property string _controlError: ""

  // Absolute, trusted path rather than a bare "python3" resolved through
  // whatever PATH this shell process happened to inherit — this Item is
  // instantiated by the long-lived omarchy-shell process, so pinning where
  // its child processes come from matters the same way it does for the
  // systemd-launched mount (see bin/googledrive-mount's own comment).
  readonly property string python3: "/usr/bin/python3"

  // Defensive cap on what a StdioCollector's finished text is allowed to
  // propagate into this Item's own properties. Quickshell's StdioCollector
  // buffers the complete stream internally before onStreamFinished ever
  // fires, so this bounds what we retain and pass along, not the collector's
  // own peak memory while reading — a true pre-buffer cap would mean
  // reading the stream in chunks instead of collecting it whole, which
  // isn't warranted here: both helper scripts only ever print a small,
  // bounded amount (one JSON status object, or a short status line), so
  // this exists as a defensive ceiling against the unexpected, not because
  // either script is expected to approach it.
  readonly property int maxCollectedChars: 65536

  function capText(text) {
    text = String(text || "")
    return text.length > root.maxCollectedChars
      ? text.substring(0, root.maxCollectedChars) + "…[truncated]"
      : text
  }

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

  function displayActive(account) {
    var desired = root._desiredActive[account.id]
    return desired === undefined ? account.active : desired
  }

  function refresh() {
    if (statusProcess.running) return
    _statusOutput = ""
    _statusError = ""
    statusProcess.command = [root.python3, root.pluginDir + "bin/googledrive-status"]
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
      var desired = root._desiredActive[a.id]
      if (desired !== undefined && desired !== a.active) next[a.id] = desired
    }
    root._desiredActive = next
  }

  function elide(text) {
    var value = String(text || "").replace(/\s+/g, " ").trim()
    return value.length > 140 ? value.substring(0, 137) + "…" : value
  }

  function toggleAccount(id) {
    var account = accounts.find(function(a) { return a.id === id })
    if (!account || controlProcess.running) return
    var desired = !displayActive(account)
    var next = Object.assign({}, root._desiredActive)
    next[id] = desired
    root._desiredActive = next
    runControl([desired ? "resume" : "pause", id])
  }

  // Unmounts and forgets the account (googledrive-accountctl remove keeps
  // its local mount folder and rclone config on disk — see the CLI's own
  // messaging — this only removes it from the panel and stops syncing).
  // Confirmation lives in Panel.qml (a second click/keypress within a few
  // seconds), not here — this function fires the moment it's called.
  function removeAccount(id) {
    if (controlProcess.running) return
    runControl(["remove", id])
  }

  // Deliberately not hardcoded to a specific file manager — Omarchy is not
  // tied to one desktop environment, so there's no single "the" file
  // manager to assume the way macOS can assume Finder. `xdg-open` resolves
  // to whatever the current session has actually registered as its default
  // folder handler (Nautilus, Dolphin, Thunar, Nemo, PCManFM-Qt, ...)
  // without this plugin needing to know or enumerate them. The mount
  // itself needs no such resolution at all — it's a real directory, and
  // any file manager (or terminal, or app) can browse it like any other
  // folder with zero integration work.
  function openMountFolder(account) {
    if (!account || !account.mountPath) return
    Quickshell.execDetached(["uwsm-app", "--", "xdg-open", account.mountPath])
  }

  // Google's OAuth sign-in is a browser hand-off, not a password this
  // plugin ever needs to see — `rclone config create ... drive` prints or
  // opens the consent URL itself and blocks until you approve it. So
  // "Add account" opens a real terminal running googledrive-accountctl,
  // rather than an in-panel form (contrast the Proton Drive plugin, which
  // *does* need a form: Proton has no OAuth hand-off, rclone's protondrive
  // backend does its own SRP login and needs the actual password).
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
    controlProcess.command = [root.python3, root.pluginDir + "bin/googledrive-accountctl"].concat(command)
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
    stdout: StdioCollector { id: statusStdout; waitForEnd: true; onStreamFinished: root._statusOutput = root.capText(text) }
    stderr: StdioCollector { id: statusStderr; waitForEnd: true; onStreamFinished: root._statusError = root.capText(text) }
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
    stdout: StdioCollector { id: controlStdout; waitForEnd: true; onStreamFinished: root._controlOutput = root.capText(text) }
    stderr: StdioCollector { id: controlStderr; waitForEnd: true; onStreamFinished: root._controlError = root.capText(text) }
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
