import QtQuick
import QtQuick.Controls as Controls
import Quickshell
import Quickshell.Io
import qs.Ui
import qs.Commons

Panel {
  id: root
  moduleName: "local.hue"
  ipcTarget: "local.hue"

  readonly property string helper: (Quickshell.env("XDG_CONFIG_HOME") || (Quickshell.env("HOME") + "/.config")) + "/omarchy/plugins/local.hue/hue.py"
  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  property var state: ({paired: false, trusted: false, lights: [], groups: []})
  property var discovered: []
  property string candidateIp: ""
  property string candidateFingerprint: ""
  property string errorText: ""
  property string infoText: ""
  property string tab: "all"
  property string chosenGroup: ""
  property string chosenLight: ""
  property string chosenColor: "#ffac4b"
  property bool settingUp: false
  property bool pairing: false
  property int pairAttempts: 0
  readonly property bool busy: !!actionProc && actionProc.running
  readonly property bool connected: state.paired === true
  readonly property var groups: state.groups || []
  readonly property var lights: state.lights || []
  readonly property var group: groups.find(function(g) { return g.id === chosenGroup }) || null
  readonly property var light: lights.find(function(l) { return l.id === chosenLight }) || null
  readonly property string scope: tab === "all" ? "all" : tab === "groups" ? "group" : "light"
  readonly property string target: tab === "all" ? "home" : tab === "groups" ? chosenGroup : chosenLight
  readonly property var selected: tab === "all" ? state : tab === "groups" ? group : light
  readonly property bool canColor: selected ? selected.color === true : false
  readonly property real brightness: selected && selected.brightness != null ? selected.brightness : 100

  implicitWidth: icon.implicitWidth
  implicitHeight: icon.implicitHeight

  function refresh() {
    if (!busy && !pairing && !settingUp) status.running = true
  }

  function readResult(raw) {
    try { return JSON.parse(raw) }
    catch (e) { return {error: "Invalid response from the Hue helper."} }
  }

  function applyState(next) {
    if (next.error) { errorText = next.error; return }
    state = next
    if (!groups.some(function(g) { return g.id === chosenGroup }))
      chosenGroup = groups.length ? groups[0].id : ""
    if (!lights.some(function(l) { return l.id === chosenLight }))
      chosenLight = lights.length ? lights[0].id : ""
    if (next.ip && !ipInput.activeFocus) ipInput.text = next.ip
    if (next.message) infoText = next.message
  }

  function run(kind, args) {
    if (actionProc.running) return
    errorText = ""
    actionProc.kind = kind
    actionProc.command = ["python3", helper, kind].concat(args || [])
    actionProc.running = true
  }

  function setLight(operation, value, scopeName, id) {
    if (!connected || busy || !(id || target)) return
    run("set", [scopeName || scope, id || target, operation, String(value)])
  }

  function startPair() {
    if (busy || !state.trusted) return
    pairing = true
    pairAttempts = 0
    infoText = "Press the button on your Hue Bridge …"
    run("pair", [])
  }

  onOpenedChanged: {
    if (opened) refresh()
    else { pairing = false; settingUp = false }
  }
  Component.onCompleted: status.running = true

  Process {
    id: status
    command: ["python3", root.helper, "status"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        const result = root.readResult(text)
        if (result.error) root.errorText = result.error
        else if (!root.busy && !root.pairing && !root.settingUp) root.applyState(result)
      }
    }
  }

  Process {
    id: actionProc
    property string kind: ""
    onExited: {
      if (kind === "set" || kind === "pair" || kind === "trust") Qt.callLater(root.refresh)
    }
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        const result = root.readResult(text)
        if (result.error) {
          root.errorText = result.error
          root.pairing = false
          root.settingUp = false
          return
        }
        if (actionProc.kind === "discover") {
          root.discovered = result.bridges || []
          if (root.discovered.length && !ipInput.text) ipInput.text = root.discovered[0].ip
          root.infoText = root.discovered.length ? "Bridge found. Check the address and connect." : "No bridge found. Enter its local IP address."
        } else if (actionProc.kind === "probe") {
          root.candidateIp = result.ip
          root.candidateFingerprint = result.fingerprint
          root.settingUp = false
          root.infoText = "Check and confirm the bridge certificate."
        } else if (actionProc.kind === "trust") {
          root.candidateFingerprint = ""
          root.settingUp = false
          root.applyState({paired: result.paired, trusted: true, ip: root.candidateIp, lights: [], groups: []})
          root.infoText = result.paired ? "Bridge connected." : "Press the bridge button, then pair."
          if (result.paired) Qt.callLater(root.refresh)
        } else if (actionProc.kind === "pair") {
          if (result.paired) {
            root.pairing = false
            root.infoText = "Pairing complete."
            Qt.callLater(root.refresh)
          } else if (result.waiting) {
            root.pairAttempts++
            if (root.pairAttempts >= 22) {
              root.pairing = false
              root.errorText = "Pairing timed out. Try again and press the bridge button."
            } else pairRetry.restart()
          }
        } else if (actionProc.kind === "set") {
          root.applyState(result)
        }
      }
    }
  }

  Timer {
    id: pairRetry
    interval: 2000
    onTriggered: if (root.pairing && !root.busy) root.run("pair", [])
  }
  Timer {
    interval: 5000
    repeat: true
    running: root.opened && root.connected
    onTriggered: if (!status.running) root.refresh()
  }

  BarIconButton {
    id: icon
    anchors.fill: parent
    bar: root.bar
    text: "\uf0eb"
    tooltipText: "Hue · " + (root.connected ? "Connected" : "Set up")
    onPressed: root.toggle()
  }

  KeyboardPanel {
    id: popup
    anchorItem: icon
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keys
    contentWidth: popup.fittedContentWidth(Style.space(380))
    contentHeight: popup.fittedContentHeight(content.implicitHeight)

    PanelKeyCatcher {
      id: keys
      anchors.fill: parent
      blocked: ipInput.activeFocus || hexInput.activeFocus
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Column {
        id: content
        width: parent.width
        spacing: Style.space(12)

        PanelHero {
          title: "Philips Hue"
          meta: root.connected ? (root.lights.length + " lights · " + root.groups.length + " groups") : "CONNECT LOCAL BRIDGE"
          foreground: root.foreground
          fontFamily: root.fontFamily
          iconComponent: Text {
            text: "\uf0eb"
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.display
          }
        }

        Text {
          visible: root.errorText !== "" && !root.connected
          width: parent.width
          text: root.errorText
          textFormat: Text.PlainText
          wrapMode: Text.WordWrap
          color: root.bar ? root.bar.urgent : Color.urgent
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
        }
        Text {
          visible: root.infoText !== "" && !root.connected
          width: parent.width
          text: root.infoText
          textFormat: Text.PlainText
          wrapMode: Text.WordWrap
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
        }

        Column {
          visible: !root.connected || root.settingUp
          width: parent.width
          spacing: Style.space(10)
          PanelSeparator { width: parent.width; foreground: root.foreground }
          PanelSectionHeader { text: "BRIDGE"; foreground: root.foreground; fontFamily: root.fontFamily }
          Controls.TextField {
            id: ipInput
            width: parent.width
            placeholderText: "Bridge IP, e.g. 192.168.1.15"
            color: root.foreground
            font.family: root.fontFamily
            selectByMouse: true
            onAccepted: root.run("probe", [text.trim()])
          }
          Row {
            width: parent.width
            spacing: Style.space(8)
            Button {
              text: "Discover"
              bordered: true
              foreground: root.foreground
              fontFamily: root.fontFamily
              enabled: !root.busy
              onClicked: root.run("discover", [])
            }
            Button {
              text: "Connect"
              bordered: true
              foreground: root.foreground
              fontFamily: root.fontFamily
              enabled: !root.busy && ipInput.text.trim() !== ""
              onClicked: root.run("probe", [ipInput.text.trim()])
            }
          }
          Column {
            visible: root.candidateFingerprint !== ""
            width: parent.width
            spacing: Style.space(8)
            Text {
              width: parent.width
              text: "Certificate from " + root.candidateIp + " (SHA-256):\n" + root.candidateFingerprint
              textFormat: Text.PlainText
              wrapMode: Text.WrapAnywhere
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }
            Button {
              text: "Trust bridge"
              bordered: true
              foreground: root.foreground
              fontFamily: root.fontFamily
              enabled: !root.busy
              onClicked: root.run("trust", [root.candidateIp, root.candidateFingerprint])
            }
          }
          Button {
            visible: !!root.state.trusted && !root.candidateFingerprint && !root.connected
            text: root.pairing ? "Waiting for button press …" : "Press button & pair"
            bordered: true
            foreground: root.foreground
            fontFamily: root.fontFamily
            enabled: !root.pairing && !root.busy
            onClicked: root.startPair()
          }
        }

        Column {
          visible: root.connected && !root.settingUp
          width: parent.width
          spacing: Style.space(12)

          PanelSeparator { width: parent.width; foreground: root.foreground }
          Row {
            width: parent.width
            spacing: Style.space(6)
            Repeater {
              model: [ {key: "all", label: "All"}, {key: "groups", label: "Groups"}, {key: "lights", label: "Lights"} ]
              Button {
                required property var modelData
                text: modelData.label
                bordered: true
                hasCursor: root.tab === modelData.key
                foreground: root.foreground
                fontFamily: root.fontFamily
                onClicked: root.tab = modelData.key
              }
            }
          }

          Text {
            width: parent.width
            text: root.tab === "all" ? "ALL LIGHTS" : root.tab === "groups" ? "ROOMS & ZONES" : "INDIVIDUAL LIGHTS"
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            font.bold: true
          }

          Grid {
            visible: root.tab === "groups"
            width: parent.width
            columns: 2
            columnSpacing: Style.space(6)
            rowSpacing: Style.space(4)
            Repeater {
              model: root.groups
              Button {
                required property var modelData
                width: (content.width - Style.space(6)) / 2
                clip: true
                leftAlign: true
                horizontalPadding: Style.space(6)
                fontSize: Style.font.bodySmall
                text: modelData.kind + " · " + modelData.name
                tooltipText: text
                bordered: true
                selected: root.chosenGroup === modelData.id
                foreground: root.foreground
                fontFamily: root.fontFamily
                onClicked: root.chosenGroup = modelData.id
              }
            }
          }

          Flickable {
            id: lightList
            visible: root.tab === "lights"
            width: parent.width
            height: Math.min(Style.space(190), lightRows.implicitHeight)
            contentWidth: width
            contentHeight: lightRows.implicitHeight
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            interactive: contentHeight > height

            Controls.ScrollBar.vertical: Controls.ScrollBar { policy: Controls.ScrollBar.AsNeeded }

            Column {
              id: lightRows
              width: lightList.width - (lightList.contentHeight > lightList.height ? Style.space(9) : 0)
              spacing: Style.space(2)
              Repeater {
                model: root.lights
                Row {
                  required property var modelData
                  width: lightRows.width
                  spacing: Style.space(5)
                  Button {
                    width: parent.width - lightSwitch.implicitWidth - parent.spacing
                    clip: true
                    leftAlign: true
                    horizontalPadding: Style.space(6)
                    fontSize: Style.font.bodySmall
                    text: modelData.name
                    tooltipText: text
                    selected: root.chosenLight === modelData.id
                    foreground: root.foreground
                    fontFamily: root.fontFamily
                    onClicked: root.chosenLight = modelData.id
                  }
                  Button {
                    id: lightSwitch
                    text: modelData.on ? "On" : "Off"
                    bordered: true
                    foreground: root.foreground
                    fontFamily: root.fontFamily
                    enabled: !root.busy
                    onClicked: root.setLight("on", !modelData.on, "light", modelData.id)
                  }
                }
              }
            }
          }

          Text {
            visible: root.tab === "groups" && root.groups.length === 0 || root.tab === "lights" && root.lights.length === 0
            text: "No entries found on the bridge."
            color: root.foreground
            font.family: root.fontFamily
          }

          Column {
            visible: root.tab === "all" || root.selected !== null
            width: parent.width
            spacing: Style.space(8)
            PanelSeparator { width: parent.width; foreground: root.foreground }
            Row {
              width: parent.width
              spacing: Style.space(8)
              Text {
                width: parent.width - scopeToggle.implicitWidth - parent.spacing
                text: root.tab === "all" ? "Entire home" : root.selected ? root.selected.name : ""
                elide: Text.ElideRight
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.title
              }
              Button {
                id: scopeToggle
                text: root.selected && root.selected.on ? "Turn off" : "Turn on"
                bordered: true
                foreground: root.foreground
                fontFamily: root.fontFamily
                enabled: !root.busy && !!root.target
                onClicked: root.setLight("on", !(root.selected && root.selected.on))
              }
            }
            Text {
              visible: root.selected && root.selected.brightness != null
              text: "BRIGHTNESS · " + Math.round(brightnessSlider.value) + "%"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
            Controls.Slider {
              id: brightnessSlider
              visible: root.selected && root.selected.brightness != null
              width: parent.width
              from: 1
              to: 100
              value: root.brightness
              enabled: !root.busy
              onPressedChanged: if (!pressed) root.setLight("brightness", Math.round(value))
            }
            Text {
              visible: root.errorText !== ""
              width: parent.width
              text: root.errorText
              textFormat: Text.PlainText
              wrapMode: Text.WordWrap
              color: root.bar ? root.bar.urgent : Color.urgent
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }
            PanelSectionHeader {
              visible: root.canColor
              text: "COLOR · COLOR-CAPABLE LIGHTS ONLY"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }
            Grid {
              visible: root.canColor
              width: parent.width
              columns: 6
              spacing: Style.space(8)
              Repeater {
                model: ["#ffac4b", "#ff654e", "#ff4977", "#cd57ef", "#7259f6", "#487bff",
                        "#42beee", "#51d9ab", "#91db57", "#eedb61", "#ffffff", "#f4bc86"]
                Rectangle {
                  required property string modelData
                  width: (parent.width - parent.spacing * 5) / 6
                  height: Style.space(30)
                  radius: Style.space(5)
                  color: modelData
                  border.width: root.chosenColor === modelData ? 2 : 1
                  border.color: root.foreground
                  MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: { root.chosenColor = modelData; root.setLight("color", modelData) }
                  }
                }
              }
            }
            Row {
              visible: root.canColor
              width: parent.width
              spacing: Style.space(8)
              Controls.TextField {
                id: hexInput
                width: parent.width - colorButton.implicitWidth - parent.spacing
                placeholderText: "#RRGGBB"
                color: root.foreground
                font.family: root.fontFamily
                selectByMouse: true
                onAccepted: colorButton.clicked()
              }
              Button {
                id: colorButton
                text: "Set color"
                bordered: true
                foreground: root.foreground
                fontFamily: root.fontFamily
                enabled: !root.busy
                onClicked: { root.chosenColor = hexInput.text.trim(); root.setLight("color", root.chosenColor) }
              }
            }
          }
          Button {
            text: "Change bridge"
            foreground: root.foreground
            fontFamily: root.fontFamily
            onClicked: { root.settingUp = true; root.candidateFingerprint = "" }
          }
        }
      }
    }
  }
}
