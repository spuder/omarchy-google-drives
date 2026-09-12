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

  // Absolute, trusted path rather than a bare "python3" resolved through
  // whatever PATH this shell process happened to inherit — this Item is
  // instantiated by the long-lived omarchy-shell process, so pinning where
  // its child processes come from matters the same way it does for the
  // systemd-launched mount (see bin/googledrive-mount's own comment).
  // "-I" (isolated mode) additionally makes the interpreter ignore
  // PYTHONPATH/PYTHONHOME/user site-packages and inherited *.pth files —
  // an absolute path alone still lets inherited Python/loader environment
  // variables influence what runs at startup, which -I closes off. The
  // launched processes also run under clearEnvironment (see below), so
  // the executable's own identity and its environment are both pinned.
  readonly property string python3: "/usr/bin/python3"
  readonly property string trustedPath: "/usr/bin:/usr/local/bin"

  // Every process below runs with clearEnvironment: true — the environment
  // isn't just PATH-restricted, it's rebuilt from nothing and only these
  // four passed through: PATH to our own trusted value (never the
  // system/session one), and HOME/XDG_RUNTIME_DIR/DBUS_SESSION_BUS_ADDRESS
  // (null = "pass the system value through", per Quickshell's
  // clearEnvironment semantics) because googledrive-status/-accountctl
  // need them (Path.home(), and systemctl --user's session addressing)
  // and none of the three are secret — they're session-location info any
  // process in this login session already has. Everything else (LD_PRELOAD,
  // PYTHONPATH, etc.) is simply absent rather than inherited.
  readonly property var minimalEnvironment: ({
    PATH: root.trustedPath,
    HOME: null,
    XDG_RUNTIME_DIR: null,
    DBUS_SESSION_BUS_ADDRESS: null
  })

  // Defensive cap on how much output either helper is allowed to produce,
  // enforced incrementally as bytes arrive (BoundedCollector below, a thin
  // SplitParser with splitMarker "" so every read() chunk reaches onRead
  // immediately rather than being searched for a delimiter first) —
  // exceeding it kills the process outright rather than just truncating
  // what gets kept afterward. Neither helper script is expected to ever
  // approach this; it exists for the case where one is somehow replaced or
  // malfunctioning, not for a normal run.
  readonly property int maxCollectedChars: 65536

  // Absolute ceiling on how long either helper may run at all, independent
  // of output size — a process that's hung rather than noisy has nothing
  // for the size cap above to catch. Both scripts already bound every
  // individual rclone/systemctl call they make with their own short
  // timeouts (3-30s), so this external deadline is a backstop for the
  // outer python3 process itself, not the normal case.
  readonly property int hardDeadlineMs: 30000

  component BoundedCollector: SplitParser {
    id: collector
    property Process proc: null
    property string text: ""
    property bool killedForSize: false
    splitMarker: ""
    onRead: function(data) {
      if (collector.killedForSize) return
      collector.text += data
      if (collector.text.length > root.maxCollectedChars) {
        collector.text = collector.text.substring(0, root.maxCollectedChars) + "…[truncated, process killed]"
        collector.killedForSize = true
        if (collector.proc) collector.proc.signal(9)
      }
    }
    function reset() {
      collector.text = ""
      collector.killedForSize = false
    }
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
    statusStdout.reset()
    statusStderr.reset()
    statusProcess.command = [root.python3, "-I", root.pluginDir + "bin/googledrive-status"]
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
    controlStdout.reset()
    controlStderr.reset()
    controlProcess.command = [root.python3, "-I", root.pluginDir + "bin/googledrive-accountctl"].concat(command)
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
    clearEnvironment: true
    environment: root.minimalEnvironment
    stdout: BoundedCollector { id: statusStdout; proc: statusProcess }
    stderr: BoundedCollector { id: statusStderr; proc: statusProcess }
    onExited: function(exitCode) {
      if (exitCode === 0) root.applyStatus(statusStdout.text)
      else root.lastError = root.elide(statusStderr.text || statusStdout.text || "Could not read Google Drives status")
    }
  }

  Timer {
    // Backstop for a hung (not just noisy) status check — see hardDeadlineMs.
    interval: root.hardDeadlineMs
    running: statusProcess.running
    repeat: false
    onTriggered: statusProcess.signal(9)
  }

  Process {
    id: controlProcess
    running: false
    command: []
    clearEnvironment: true
    environment: root.minimalEnvironment
    stdout: BoundedCollector { id: controlStdout; proc: controlProcess }
    stderr: BoundedCollector { id: controlStderr; proc: controlProcess }
    onExited: function(exitCode) {
      if (exitCode !== 0) {
        root.lastError = root.elide(controlStderr.text || controlStdout.text || "Google Drives command failed")
        root.actionStatus = root.lastError
        actionStatusTimer.restart()
      }
      delayedRefresh.restart()
    }
  }

  Timer {
    interval: root.hardDeadlineMs
    running: controlProcess.running
    repeat: false
    onTriggered: controlProcess.signal(9)
  }
}
