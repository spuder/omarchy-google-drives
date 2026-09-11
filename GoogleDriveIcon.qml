import QtQuick
import qs.Commons

// A plain uppercase "G" — deliberately not Google's actual triangular Drive
// logo, just a distinct glyph for the bar. Same reasoning as the sister
// Proton Drive plugin's ProtonDriveIcon.qml: Google's brand guidelines
// don't grant unaffiliated third-party apps a license to use the Drive
// mark, and a glyph that's clearly not the real logo is itself part of not
// looking official.
Item {
  id: root

  property real iconSize: Style.font.icon
  property color color: Color.foreground

  width: iconSize
  height: iconSize
  implicitWidth: iconSize
  implicitHeight: iconSize

  Text {
    anchors.centerIn: parent
    text: "G"
    color: root.color
    font.family: Style.font.family
    font.pixelSize: root.iconSize
    font.bold: true
    renderType: Text.NativeRendering
  }
}
