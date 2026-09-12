import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Bar icon + dropdown panel for Google Drives, covering N accounts.
// Structure mirrors the sister Proton Drive plugin's Panel.qml (itself
// mirroring the first-party Dropbox plugin) — one Panel.qml owning both
// the bar button and the KeyboardPanel, with a repeated account list
// instead of a single account's file list. See PLAN.md.
Panel {
  id: root
  moduleName: "spuder.googledrive"
  ipcTarget: "spuder.googledrive"
  manageIpc: false

  property string focusSection: "add"
  property int accountIndex: 0
  property bool cursorActive: false
  // Id of the account whose remove button/key was just pressed once. A
  // second press within confirmRemoveTimer's window actually removes it;
  // anything else (timeout, closing the panel) drops back to unarmed. Kept
  // here rather than as local state on the (Repeater-recreated) AccountRow
  // delegate so it survives a status refresh mid-confirm.
  property string confirmRemoveId: ""

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property color barIconColor: gdrive.aggregateState === "mounted" ? barForeground : Qt.darker(barForeground, 1.55)

  function ensureCursor() {
    if (gdrive.accounts.length === 0) {
      focusSection = "add"
      accountIndex = 0
      return
    }
    if (focusSection !== "accounts" && focusSection !== "add") focusSection = "accounts"
    if (accountIndex >= gdrive.accounts.length) accountIndex = Math.max(0, gdrive.accounts.length - 1)
    if (accountIndex < 0) accountIndex = 0
  }

  function moveCursor(dx, dy) {
    cursorActive = true
    ensureCursor()
    if (dy === 0) return
    if (focusSection === "add") {
      if (dy > 0 && gdrive.accounts.length > 0) {
        focusSection = "accounts"
        accountIndex = 0
      }
      return
    }
    if (focusSection === "accounts") {
      if (dy < 0 && accountIndex === 0) {
        focusSection = "add"
        return
      }
      accountIndex = Math.max(0, Math.min(gdrive.accounts.length - 1, accountIndex + dy))
    }
  }

  function activateCursor() {
    ensureCursor()
    if (focusSection === "add") gdrive.beginAddAccount()
    else if (focusSection === "accounts") {
      var account = selectedAccount()
      if (account) gdrive.openMountFolder(account)
    }
  }

  function selectedAccount() {
    if (gdrive.accounts.length === 0) return null
    return gdrive.accounts[Math.max(0, Math.min(accountIndex, gdrive.accounts.length - 1))]
  }

  function setAccountCursor(index) {
    cursorActive = true
    focusSection = "accounts"
    accountIndex = index
  }

  // First call arms removal for this account (and starts the timeout that
  // disarms it again); a second call while already armed for the same
  // account actually removes it. Shared by the row's remove button and the
  // 'd' key so both go through the same confirm step.
  function attemptRemove(account) {
    if (!account) return
    if (root.confirmRemoveId === account.id) {
      root.confirmRemoveId = ""
      confirmRemoveTimer.stop()
      gdrive.removeAccount(account.id)
    } else {
      root.confirmRemoveId = account.id
      confirmRemoveTimer.restart()
    }
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onOpenedChanged: if (opened) {
    cursorActive = false
    confirmRemoveId = ""
    gdrive.refresh()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  Timer {
    id: confirmRemoveTimer
    interval: 3000
    repeat: false
    onTriggered: root.confirmRemoveId = ""
  }

  Service {
    id: gdrive
    settings: root.settings
  }

  Connections {
    target: gdrive
    function onAccountsChanged() { root.ensureCursor() }
  }

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): string { gdrive.refresh(); return "ok" }
    function status(): string { return gdrive.aggregateStatusText }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    iconComponent: Component {
      Item {
        GoogleDriveIcon {
          anchors.centerIn: parent
          iconSize: Style.space(12)
          color: root.barIconColor
          opacity: gdrive.aggregateState === "paused" ? 0.6 : 1.0
        }
      }
    }
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.RightButton) gdrive.refresh()
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(380))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(560))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onMoveRequested: function(dx, dy) {
        if (!root.cursorActive) { root.cursorActive = true; return }
        root.moveCursor(dx, dy)
      }
      onActivateRequested: if (root.cursorActive) root.activateCursor()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (t === "r" || t === "R") gdrive.refresh()
        else if (t === "a" || t === "A") gdrive.beginAddAccount()
        else if (t === "o" || t === "O") {
          var account = root.selectedAccount()
          if (account) gdrive.openMountFolder(account)
        }
        else if (t === "d" || t === "D") root.attemptRemove(root.selectedAccount())
      }

      Flickable {
        id: panelFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: column
          width: panelFlick.width
          spacing: Style.space(12)

          PanelHero {
            id: hero
            width: parent.width
            title: "Google Drives"
            meta: gdrive.aggregateStatusText
            foreground: root.foreground
            fontFamily: root.fontFamily
            iconComponent: Component {
              GoogleDriveIcon {
                iconSize: Style.font.display
                color: root.foreground
              }
            }
          }

          Text {
            textFormat: Text.PlainText
            visible: !gdrive.rcloneInstalled
            width: parent.width
            text: "rclone is not installed — run the install script, then add an account."
            color: root.urgent
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          Text {
            textFormat: Text.PlainText
            visible: gdrive.actionStatus !== "" || gdrive.lastError !== ""
            width: parent.width
            text: gdrive.actionStatus !== "" ? gdrive.actionStatus : gdrive.lastError
            color: gdrive.lastError !== "" && gdrive.actionStatus === "" ? root.urgent : root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          AddAccountButton {
            width: parent.width
          }

          PanelSeparator {
            visible: gdrive.accounts.length > 0
            foreground: root.foreground
          }

          Column {
            visible: gdrive.accounts.length > 0
            width: parent.width
            spacing: Style.space(10)

            PanelSectionHeader {
              text: "ACCOUNTS"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Text {
              textFormat: Text.PlainText
              width: parent.width
              text: "Click a drive, or select it and press o, to open its folder. Press d twice to remove one."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }

            Column {
              id: accountColumn
              width: parent.width
              spacing: Style.space(6)

              Repeater {
                model: gdrive.accounts
                AccountRow {
                  required property var modelData
                  required property int index
                  width: accountColumn.width
                  account: modelData
                  rowIndex: index
                }
              }
            }
          }
        }
      }
    }
  }

  component AddAccountButton: CursorSurface {
    id: addButton

    hasCursor: root.cursorActive && root.focusSection === "add"
    foreground: root.foreground

    implicitHeight: addRow.implicitHeight + Style.spacing.rowPaddingX

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onEntered: {
        root.cursorActive = true
        root.focusSection = "add"
      }
      onClicked: gdrive.beginAddAccount()
    }

    RowLayout {
      id: addRow
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(10)
      spacing: Style.space(8)

      ColumnLayout {
        Layout.fillWidth: true
        spacing: Style.space(1)

        Text {
          textFormat: Text.PlainText
          Layout.fillWidth: true
          text: "Add a Google Drive account"
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          elide: Text.ElideRight
        }

        Text {
          textFormat: Text.PlainText
          Layout.fillWidth: true
          text: "Opens a terminal for your email, then Google's own browser sign-in"
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }

      PanelActionButton {
        iconText: "+"
        foreground: root.foreground
        fontFamily: root.fontFamily
        Layout.alignment: Qt.AlignVCenter
        onClicked: gdrive.beginAddAccount()
      }
    }
  }

  component AccountRow: CursorSurface {
    id: accountRow
    property var account: null
    property int rowIndex: 0
    readonly property bool active: account ? gdrive.displayActive(account) : false
    readonly property bool confirmingRemove: account ? root.confirmRemoveId === account.id : false
    // Purple (theme accent) while mounted, white (foreground) paused, red
    // (urgent) errored — accent specifically, not plain foreground, so
    // "mounted and live" reads as the theme's brand color rather than
    // indistinguishable default text color.
    readonly property color statusColor: !account ? root.dim
      : account.lastError !== "" ? root.urgent
      : active ? Color.accent : root.foreground

    hasCursor: root.cursorActive && root.focusSection === "accounts" && root.accountIndex === rowIndex
    foreground: root.foreground

    implicitHeight: accountContent.implicitHeight + Style.spacing.rowPaddingX

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onEntered: root.setAccountCursor(accountRow.rowIndex)
      onClicked: gdrive.openMountFolder(accountRow.account)
    }

    RowLayout {
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(10)
      spacing: Style.space(8)

      Rectangle {
        width: Style.space(8)
        height: width
        radius: width / 2
        color: accountRow.statusColor
        Layout.alignment: Qt.AlignVCenter
      }

      ColumnLayout {
        id: accountContent
        Layout.fillWidth: true
        spacing: Style.space(1)

        Text {
          textFormat: Text.PlainText
          Layout.fillWidth: true
          text: accountRow.account ? accountRow.account.displayName : ""
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          elide: Text.ElideRight
        }

        Text {
          textFormat: Text.PlainText
          Layout.fillWidth: true
          text: !accountRow.account ? ""
            : accountRow.confirmingRemove ? "Click ✕ again, or press d again, to remove — local files are kept"
            : (accountRow.account.lastError !== "" ? accountRow.account.lastError
              : Model.usageText(accountRow.account.usedBytes, accountRow.account.quotaBytes, accountRow.account.quotaKnown))
          color: accountRow.confirmingRemove ? root.urgent
            : (accountRow.account && accountRow.account.lastError !== "" ? root.urgent : root.dim)
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }

      PanelActionButton {
        iconText: "✕"
        foreground: accountRow.confirmingRemove ? root.urgent : root.foreground
        fontFamily: root.fontFamily
        Layout.alignment: Qt.AlignVCenter
        onClicked: root.attemptRemove(accountRow.account)
      }

      ToggleSwitch {
        visible: accountRow.account ? accountRow.account.authenticated : false
        checked: accountRow.active
        busy: gdrive.busy
        hasCursor: false
        foreground: root.foreground
        Layout.alignment: Qt.AlignVCenter
        onToggled: if (accountRow.account) gdrive.toggleAccount(accountRow.account.id)

        PanelToolTip {
          visible: parent.containsMouse
          text: accountRow.active ? "Pause" : "Resume"
          fontFamily: root.fontFamily
        }
      }
    }
  }
}
