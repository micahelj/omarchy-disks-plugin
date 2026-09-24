import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// "This PC"-style disk overview: one card per mounted drive with a usage bar.
// Clicking a drive expands it into its largest folders; clicking a folder
// drills into it. Strictly read-only — the helper only runs findmnt, lsblk
// and du.
Panel {
  id: root
  moduleName: "athesias.disks"
  ipcTarget: "athesias.disks"

  readonly property string helperPath: decodeURIComponent(String(Qt.resolvedUrl("disk-usage.py")).replace(/^file:\/\//, ""))
  readonly property int folderRows: setting("folderRows", 10)
  readonly property real warnAt: setting("warnPercent", 90) / 100
  // Folder scans are reused for this long before a revisit rescans them.
  readonly property int scanMaxAgeMs: 5 * 60 * 1000

  readonly property string glyphFolder: String.fromCodePoint(0xF024B)
  readonly property string glyphFile: String.fromCodePoint(0xF0214)
  readonly property string glyphExpand: String.fromCodePoint(0xF0142)
  readonly property string glyphCollapse: String.fromCodePoint(0xF0140)

  property var drives: []
  property string expandedDevice: ""
  property string currentPath: ""
  property var scanCache: ({})
  property string activeScanPath: ""
  property string queuedScanPath: ""

  readonly property var currentScan: scanCache[currentPath] || null
  readonly property bool scanning: scanProc.running && activeScanPath === currentPath
  readonly property var listing: Model.visibleEntries(currentScan, folderRows)
  readonly property color fg: root.bar ? root.bar.foreground : Color.foreground

  function usageColor(drive) {
    return Model.usedFraction(drive) >= root.warnAt ? Color.urgent : root.fg
  }

  function refreshDrives() {
    if (!drivesProc.running) drivesProc.running = true
  }

  function toggleDrive(drive) {
    if (expandedDevice === drive.device) {
      expandedDevice = ""
      return
    }
    expandedDevice = drive.device
    browse(drive.mount)
  }

  function browse(path) {
    currentPath = path
    var cached = scanCache[path]
    if (!cached || Date.now() - cached.scannedAt > scanMaxAgeMs) startScan(path)
  }

  function startScan(path) {
    if (scanProc.running) {
      if (activeScanPath === path) return
      // Kill the stale scan; onExited starts the queued one.
      queuedScanPath = path
      scanProc.running = false
      return
    }
    activeScanPath = path
    scanProc.command = ["python3", root.helperPath, "scan", path]
    scanProc.running = true
  }

  function storeScan(raw) {
    var data
    try { data = JSON.parse(raw) } catch (e) { return }
    if (!data || data.path !== activeScanPath) return
    data.scannedAt = Date.now()
    var next = Object.assign({}, scanCache)
    next[data.path] = data
    scanCache = next
  }

  onOpenedChanged: if (opened) refreshDrives()

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  Process {
    id: drivesProc
    command: ["python3", root.helperPath, "drives"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var list = JSON.parse(text)
          if (Array.isArray(list) && list.length > 0) root.drives = list
        } catch (e) {}
      }
    }
  }

  Process {
    id: scanProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: if (root.queuedScanPath === "") root.storeScan(text)
    }
    onExited: {
      if (root.queuedScanPath === "") return
      var next = root.queuedScanPath
      root.queuedScanPath = ""
      Qt.callLater(function() { root.startScan(next) })
    }
  }

  Timer {
    interval: 15000
    running: root.opened
    repeat: true
    onTriggered: root.refreshDrives()
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: Model.driveGlyph(null)
    tooltipText: ""
    onPressed: function(b) { root.toggle() }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(420))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Flickable {
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        interactive: contentHeight > height
        boundsBehavior: Flickable.StopAtBounds
        clip: true

        Column {
          id: column
          width: parent.width
          spacing: Style.space(12)

          PanelHero {
            foreground: root.fg
            fontFamily: root.bar.fontFamily
            title: "Disks"
            meta: root.drives.length === 1 ? "1 drive" : root.drives.length + " drives"
            iconComponent: Component {
              Text {
                textFormat: Text.PlainText
                text: Model.driveGlyph(null)
                color: root.fg
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.display
              }
            }
          }

          Repeater {
            model: root.drives

            Column {
              id: driveBlock
              required property var modelData
              readonly property bool expanded: root.expandedDevice === modelData.device

              width: column.width
              spacing: Style.space(8)

              PanelSeparator { foreground: root.fg }

              // ---------- Drive card ----------
              Item {
                width: parent.width
                implicitHeight: driveCard.implicitHeight + Style.space(12)

                Rectangle {
                  anchors.fill: parent
                  radius: Style.cornerRadius
                  color: driveMouse.containsMouse ? Style.hoverFillFor(root.fg, Color.accent, Color.urgent) : "transparent"
                  Behavior on color { ColorAnimation { duration: 120 } }
                }

                Column {
                  id: driveCard
                  anchors.left: parent.left
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  anchors.leftMargin: Style.space(6)
                  anchors.rightMargin: Style.space(6)
                  spacing: Style.space(6)

                  Item {
                    width: parent.width
                    implicitHeight: Math.max(driveIcon.implicitHeight, driveNames.implicitHeight)

                    Text {
                      id: driveIcon
                      textFormat: Text.PlainText
                      text: Model.driveGlyph(driveBlock.modelData)
                      color: root.fg
                      font.family: root.bar.fontFamily
                      font.pixelSize: Style.font.iconLarge
                      anchors.left: parent.left
                      anchors.verticalCenter: parent.verticalCenter
                    }

                    Column {
                      id: driveNames
                      anchors.left: driveIcon.right
                      anchors.leftMargin: Style.space(10)
                      anchors.right: drivePercent.left
                      anchors.rightMargin: Style.space(8)
                      anchors.verticalCenter: parent.verticalCenter
                      spacing: Style.space(1)

                      Text {
                        width: parent.width
                        textFormat: Text.PlainText
                        text: driveBlock.modelData.label
                        color: root.fg
                        font.family: root.bar.fontFamily
                        font.pixelSize: Style.font.subtitle
                        font.bold: true
                        elide: Text.ElideRight
                      }

                      Text {
                        width: parent.width
                        textFormat: Text.PlainText
                        text: Model.driveSubtitle(driveBlock.modelData)
                        visible: text !== ""
                        color: Qt.darker(root.fg, 1.4)
                        font.family: root.bar.fontFamily
                        font.pixelSize: Style.font.caption
                        elide: Text.ElideRight
                      }
                    }

                    Text {
                      id: drivePercent
                      textFormat: Text.PlainText
                      text: Model.percent(driveBlock.modelData) + "%"
                      color: root.usageColor(driveBlock.modelData)
                      font.family: root.bar.fontFamily
                      font.pixelSize: Style.font.heading
                      font.bold: true
                      anchors.right: chevron.left
                      anchors.rightMargin: Style.space(8)
                      anchors.verticalCenter: parent.verticalCenter
                    }

                    Text {
                      id: chevron
                      textFormat: Text.PlainText
                      text: driveBlock.expanded ? root.glyphCollapse : root.glyphExpand
                      color: Qt.darker(root.fg, 1.4)
                      font.family: root.bar.fontFamily
                      font.pixelSize: Style.font.icon
                      anchors.right: parent.right
                      anchors.verticalCenter: parent.verticalCenter
                    }
                  }

                  UsageBar {
                    width: parent.width
                    fraction: Model.usedFraction(driveBlock.modelData)
                    fillColor: root.usageColor(driveBlock.modelData)
                  }

                  Text {
                    width: parent.width
                    textFormat: Text.PlainText
                    text: Model.formatBytes(driveBlock.modelData.avail) + " free of " + Model.formatBytes(driveBlock.modelData.size)
                    color: Qt.darker(root.fg, 1.4)
                    font.family: root.bar.fontFamily
                    font.pixelSize: Style.font.bodySmall
                    elide: Text.ElideRight
                  }
                }

                MouseArea {
                  id: driveMouse
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.toggleDrive(driveBlock.modelData)
                }
              }

              // ---------- Folder breakdown ----------
              Column {
                visible: driveBlock.expanded
                width: parent.width
                spacing: Style.space(4)

                // Breadcrumb: each segment jumps back up to that folder.
                Flow {
                  width: parent.width
                  spacing: Style.space(2)

                  Repeater {
                    model: driveBlock.expanded ? Model.crumbs(driveBlock.modelData, root.currentPath) : []

                    Row {
                      required property var modelData
                      required property int index
                      spacing: Style.space(2)

                      Text {
                        visible: index > 0
                        textFormat: Text.PlainText
                        text: "›"
                        color: Qt.darker(root.fg, 1.6)
                        font.family: root.bar.fontFamily
                        font.pixelSize: Style.font.bodySmall
                      }

                      Text {
                        readonly property bool isCurrent: modelData.path === root.currentPath
                        textFormat: Text.PlainText
                        text: modelData.name
                        color: isCurrent ? root.fg : Qt.darker(root.fg, crumbMouse.containsMouse ? 1.1 : 1.4)
                        font.family: root.bar.fontFamily
                        font.pixelSize: Style.font.bodySmall
                        font.bold: isCurrent
                        font.underline: !isCurrent && crumbMouse.containsMouse

                        MouseArea {
                          id: crumbMouse
                          anchors.fill: parent
                          enabled: !parent.isCurrent
                          hoverEnabled: true
                          cursorShape: Qt.PointingHandCursor
                          onClicked: root.browse(modelData.path)
                        }
                      }
                    }
                  }

                  Text {
                    visible: root.scanning && root.currentScan !== null
                    textFormat: Text.PlainText
                    text: "  updating…"
                    color: Qt.darker(root.fg, 1.6)
                    font.family: root.bar.fontFamily
                    font.pixelSize: Style.font.caption
                  }
                }

                Text {
                  id: measuringText
                  visible: root.scanning && root.currentScan === null
                  width: parent.width
                  topPadding: Style.space(6)
                  bottomPadding: Style.space(6)
                  textFormat: Text.PlainText
                  text: "Measuring folders…"
                  color: Qt.darker(root.fg, 1.4)
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.bodySmall

                  SequentialAnimation on opacity {
                    running: measuringText.visible
                    loops: Animation.Infinite
                    NumberAnimation { from: 1.0; to: 0.4; duration: 700; easing.type: Easing.InOutSine }
                    NumberAnimation { from: 0.4; to: 1.0; duration: 700; easing.type: Easing.InOutSine }
                  }
                }

                Text {
                  visible: !root.scanning && root.currentScan !== null && root.listing.rows.length === 0
                  width: parent.width
                  topPadding: Style.space(6)
                  bottomPadding: Style.space(6)
                  textFormat: Text.PlainText
                  text: root.currentScan && root.currentScan.error ? root.currentScan.error : "Empty"
                  color: Qt.darker(root.fg, 1.4)
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.bodySmall
                }

                Repeater {
                  model: driveBlock.expanded ? root.listing.rows : []

                  FolderRow {
                    required property var modelData
                    width: parent.width
                    entry: modelData
                    total: root.currentScan ? root.currentScan.total : 0
                  }
                }

                Text {
                  visible: driveBlock.expanded && root.listing.restCount > 0
                  width: parent.width
                  leftPadding: Style.space(8)
                  textFormat: Text.PlainText
                  text: "+ " + root.listing.restCount + " smaller item" + (root.listing.restCount === 1 ? "" : "s")
                    + (root.listing.restSize > 0 ? " · " + Model.formatBytes(root.listing.restSize) : "")
                  color: Qt.darker(root.fg, 1.6)
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.caption
                }

                Text {
                  visible: driveBlock.expanded && root.currentScan !== null && root.currentScan.denied > 0
                  width: parent.width
                  leftPadding: Style.space(8)
                  wrapMode: Text.WordWrap
                  textFormat: Text.PlainText
                  text: "Some system folders need admin access to measure, so totals here may be a little low."
                  color: Qt.darker(root.fg, 1.6)
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.caption
                }
              }
            }
          }
        }
      }
    }
  }

  component UsageBar: Item {
    property real fraction: 0
    property color fillColor: root.fg
    property real thickness: Style.space(8)

    implicitHeight: thickness

    Rectangle {
      id: track
      anchors.fill: parent
      radius: height / 2
      color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.12)
    }

    Rectangle {
      anchors.left: track.left
      anchors.verticalCenter: track.verticalCenter
      height: track.height
      radius: track.radius
      color: parent.fillColor
      width: parent.fraction > 0 ? Math.max(track.height, track.width * parent.fraction) : 0

      Behavior on width { NumberAnimation { duration: 320; easing.type: Easing.OutCubic } }
      Behavior on color { ColorAnimation { duration: 220 } }
    }
  }

  // One folder/file line: a faint proportional bar behind the name shows its
  // share of the current folder at a glance.
  component FolderRow: Item {
    id: row
    property var entry: ({})
    property real total: 0
    readonly property real share: total > 0 ? Math.min(1, entry.size / total) : 0
    readonly property bool browsable: entry.dir === true

    implicitHeight: Style.spacing.popupRowHeight

    Rectangle {
      anchors.fill: parent
      radius: Style.cornerRadius
      color: rowMouse.containsMouse && row.browsable ? Style.hoverFillFor(root.fg, Color.accent, Color.urgent) : "transparent"
    }

    Rectangle {
      anchors.left: parent.left
      anchors.top: parent.top
      anchors.bottom: parent.bottom
      width: parent.width * row.share
      radius: Style.cornerRadius
      color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.10)
      Behavior on width { NumberAnimation { duration: 260; easing.type: Easing.OutCubic } }
    }

    Text {
      id: rowIcon
      textFormat: Text.PlainText
      text: row.browsable ? root.glyphFolder : root.glyphFile
      color: Qt.darker(root.fg, 1.3)
      font.family: root.bar.fontFamily
      font.pixelSize: Style.font.icon
      anchors.left: parent.left
      anchors.leftMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
    }

    Text {
      textFormat: Text.PlainText
      text: Model.displayName(row.entry)
      color: root.fg
      font.family: root.bar.fontFamily
      font.pixelSize: Style.font.body
      elide: Text.ElideMiddle
      anchors.left: rowIcon.right
      anchors.leftMargin: Style.space(8)
      anchors.right: rowSize.left
      anchors.rightMargin: Style.space(10)
      anchors.verticalCenter: parent.verticalCenter
    }

    Text {
      id: rowSize
      textFormat: Text.PlainText
      text: Model.formatBytes(row.entry.size)
      color: root.fg
      font.family: root.bar.fontFamily
      font.pixelSize: Style.font.body
      font.bold: true
      anchors.right: rowChevron.left
      anchors.rightMargin: Style.space(6)
      anchors.verticalCenter: parent.verticalCenter
    }

    Text {
      id: rowChevron
      textFormat: Text.PlainText
      text: root.glyphExpand
      opacity: row.browsable ? 1 : 0
      color: Qt.darker(root.fg, 1.5)
      font.family: root.bar.fontFamily
      font.pixelSize: Style.font.bodySmall
      anchors.right: parent.right
      anchors.rightMargin: Style.space(6)
      anchors.verticalCenter: parent.verticalCenter
    }

    MouseArea {
      id: rowMouse
      anchors.fill: parent
      hoverEnabled: true
      enabled: row.browsable
      cursorShape: row.browsable ? Qt.PointingHandCursor : Qt.ArrowCursor
      onClicked: root.browse(row.entry.path)
    }
  }
}
