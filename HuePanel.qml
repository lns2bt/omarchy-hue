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
  property string statusMessage: ""
  property string actionNotice: ""
  property string infoText: ""
  property string tab: "all"
  property string chosenGroup: ""
  property string chosenLight: ""
  property string chosenColor: "#ffac4b"
  property real pickerHue: 0.083
  property real pickerSaturation: 0.71
  property real pickerValue: 1
  readonly property string previewHex: hsvToHex(pickerHue, pickerSaturation, pickerValue)
  property bool settingUp: false
  property bool pairing: false
  property int pairAttempts: 0
  property int actionGeneration: 0
  readonly property bool busy: !!actionProc && actionProc.running
  readonly property bool connected: state.paired === true
  readonly property bool online: connected && state.offline !== true
  readonly property var groups: state.groups || []
  readonly property var lights: state.lights || []
  readonly property var scenes: state.scenes || []
  readonly property var favorites: state.favorites || []
  readonly property var favoriteRows: favorites.map(function(f) {
    const item = (f.kind === "scene" ? scenes : groups).find(function(x) { return x.id === f.id })
    return item ? {kind: f.kind, item: item} : null
  }).filter(function(f) { return f !== null })

  function isFavorite(kind, id) {
    return favorites.some(function(f) { return f.kind === kind && f.id === id })
  }
  function toggleFavorite(kind, id) {
    if (online && !busy) run("favorite", [kind, id, String(!isFavorite(kind, id))])
  }
  function activateScene(id) {
    if (online && !busy) run("recall", [id])
  }
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

  function clamp01(value) { return Math.max(0, Math.min(1, value)) }

  function validHex(value) { return /^#[0-9a-fA-F]{6}$/.test(value) }

  function hsvToHex(hue, saturation, value) {
    const h = ((hue % 1) + 1) % 1 * 6
    const chroma = value * saturation
    const secondary = chroma * (1 - Math.abs(h % 2 - 1))
    const offset = value - chroma
    let rgb
    if (h < 1) rgb = [chroma, secondary, 0]
    else if (h < 2) rgb = [secondary, chroma, 0]
    else if (h < 3) rgb = [0, chroma, secondary]
    else if (h < 4) rgb = [0, secondary, chroma]
    else if (h < 5) rgb = [secondary, 0, chroma]
    else rgb = [chroma, 0, secondary]
    return "#" + rgb.map(function(channel) {
      return Math.round(255 * (channel + offset)).toString(16).padStart(2, "0")
    }).join("")
  }

  function setPickerFromHex(hex) {
    if (!validHex(hex)) return false
    const r = parseInt(hex.slice(1, 3), 16) / 255
    const g = parseInt(hex.slice(3, 5), 16) / 255
    const b = parseInt(hex.slice(5, 7), 16) / 255
    const maximum = Math.max(r, g, b)
    const minimum = Math.min(r, g, b)
    const delta = maximum - minimum
    let hue = pickerHue
    if (delta > 0) {
      if (maximum === r) hue = ((g - b) / delta) % 6
      else if (maximum === g) hue = (b - r) / delta + 2
      else hue = (r - g) / delta + 4
      hue = (hue / 6 + 1) % 1
    }
    pickerHue = hue
    pickerSaturation = maximum === 0 ? 0 : delta / maximum
    pickerValue = maximum
    return true
  }

  function updateColorArea(x, y, width, height) {
    pickerSaturation = clamp01(x / width)
    pickerValue = Math.max(0.01, 1 - clamp01(y / height))
    hexInput.text = previewHex
  }

  function updateHue(x, width) {
    pickerHue = clamp01(x / width)
    hexInput.text = previewHex
  }

  function applyPickerColor() {
    chosenColor = previewHex
    hexInput.text = previewHex
    setLight("color", chosenColor)
  }

  function applyHexColor() {
    const hex = hexInput.text.trim()
    if (!setPickerFromHex(hex)) {
      errorText = "Invalid color. Use #RRGGBB."
      return
    }
    chosenColor = hex.toLowerCase()
    hexInput.text = chosenColor
    setLight("color", chosenColor)
  }

  function applyState(next) {
    if (next.error) { errorText = next.error; return }
    if (next.offline) {
      state = Object.assign({}, state, {paired: true, offline: true, ip: next.ip || state.ip})
      statusMessage = next.message || "Bridge unavailable."
      return
    }
    if (!next.ip && state.ip) next.ip = state.ip
    state = next
    statusMessage = next.authError ? next.message : ""
    if (!groups.some(function(g) { return g.id === chosenGroup }))
      chosenGroup = groups.length ? groups[0].id : ""
    if (!lights.some(function(l) { return l.id === chosenLight }))
      chosenLight = lights.length ? lights[0].id : ""
    if (next.ip && !ipInput.activeFocus) ipInput.text = next.ip
    if (next.message) infoText = next.message
  }

  function run(kind, args) {
    if (actionProc.running) return
    if (kind === "set" || kind === "recall" || kind === "favorite") actionGeneration++
    errorText = ""
    actionNotice = ""
    actionProc.kind = kind
    actionProc.command = ["python3", helper, kind].concat(args || [])
    actionProc.running = true
  }

  function setLight(operation, value, scopeName, id) {
    if (!online || busy || !(id || target)) return
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
  Component.onCompleted: {
    setPickerFromHex(chosenColor)
    hexInput.text = chosenColor
    status.running = true
  }

  Process {
    id: status
    property int generation: -1
    command: ["python3", root.helper, "status"]
    onStarted: generation = root.actionGeneration
    onExited: if (generation !== root.actionGeneration) Qt.callLater(root.refresh)
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        if (status.generation !== root.actionGeneration) return
        const result = root.readResult(text)
        if (result.error) {
          if (root.connected) root.applyState({paired: true, offline: true, ip: root.state.ip, message: result.error})
          else root.statusMessage = result.error
        }
        else if (!root.busy && !root.pairing && !root.settingUp) root.applyState(result)
      }
    }
  }

  Process {
    id: actionProc
    property string kind: ""
    onExited: {
      if (kind === "set" || kind === "recall" || kind === "pair" || kind === "trust") Qt.callLater(root.refresh)
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
        } else if (actionProc.kind === "set" || actionProc.kind === "recall" || actionProc.kind === "favorite") {
          if (result.state) root.applyState(result.state)
          if (result.warning) root.actionNotice = result.warning
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
    running: root.opened && (root.connected || !!root.state.trusted)
    onTriggered: if (!status.running) root.refresh()
  }

  BarIconButton {
    id: icon
    anchors.fill: parent
    bar: root.bar
    text: "\uf0eb"
    tooltipText: "Hue · " + (root.connected ? (root.online ? "Connected" : "Offline") : "Set up")
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
          meta: root.connected
            ? (root.online ? (root.lights.length + " lights · " + root.groups.length + " groups") : "BRIDGE OFFLINE")
            : (root.state.authError ? "BRIDGE ACCESS DENIED" : "CONNECT LOCAL BRIDGE")
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
        Text {
          visible: root.statusMessage !== ""
          width: parent.width
          text: root.statusMessage
          textFormat: Text.PlainText
          wrapMode: Text.WordWrap
          color: root.bar ? root.bar.urgent : Color.urgent
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
              model: [ {key: "all", label: "All"}, {key: "groups", label: "Groups"}, {key: "lights", label: "Lights"}, {key: "scenes", label: "Scenes"} ]
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

          Column {
            visible: root.favoriteRows.length > 0
            width: parent.width
            spacing: Style.space(4)
            PanelSectionHeader { text: "FAVORITES"; foreground: root.foreground; fontFamily: root.fontFamily }
            Flickable {
              id: favoriteList
              width: parent.width
              height: Math.min(Style.space(90), favoriteColumn.implicitHeight)
              contentWidth: width
              contentHeight: favoriteColumn.implicitHeight
              clip: true
              boundsBehavior: Flickable.StopAtBounds
              Controls.ScrollBar.vertical: Controls.ScrollBar { policy: Controls.ScrollBar.AsNeeded }
              Column {
                id: favoriteColumn
                width: favoriteList.width - Style.space(9)
                spacing: Style.space(2)
                Repeater {
                  model: root.favoriteRows
                  Button {
                    required property var modelData
                    width: favoriteColumn.width
                    clip: true
                    leftAlign: true
                    fontSize: Style.font.bodySmall
                    text: "★ " + modelData.item.name + (modelData.kind === "scene" ? " · " + modelData.item.groupName : "")
                    tooltipText: text
                    foreground: root.foreground
                    fontFamily: root.fontFamily
                    enabled: !root.busy && (modelData.kind !== "scene" || root.online)
                    onClicked: {
                      if (modelData.kind === "scene") root.activateScene(modelData.item.id)
                      else { root.chosenGroup = modelData.item.id; root.tab = "groups" }
                    }
                  }
                }
              }
            }
          }
          Flickable {
            id: sceneList
            visible: root.tab === "scenes"
            width: parent.width
            height: Math.min(Style.space(300), sceneColumn.implicitHeight)
            contentWidth: width
            contentHeight: sceneColumn.implicitHeight
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            Controls.ScrollBar.vertical: Controls.ScrollBar { policy: Controls.ScrollBar.AsNeeded }
            Column {
              id: sceneColumn
              width: sceneList.width - Style.space(9)
              spacing: Style.space(3)
              Repeater {
                model: root.scenes
                Row {
                  required property var modelData
                  width: sceneColumn.width
                  spacing: Style.space(4)
                  Button {
                    width: parent.width - sceneStar.implicitWidth - parent.spacing
                    clip: true
                    leftAlign: true
                    fontSize: Style.font.bodySmall
                    text: modelData.groupName + " · " + modelData.name
                    tooltipText: text
                    selected: modelData.active !== "inactive"
                    foreground: root.foreground
                    fontFamily: root.fontFamily
                    enabled: root.online && !root.busy
                    onClicked: root.activateScene(modelData.id)
                  }
                  Button {
                    id: sceneStar
                    text: root.isFavorite("scene", modelData.id) ? "★" : "☆"
                    tooltipText: "Toggle favorite"
                    foreground: root.foreground
                    fontFamily: root.fontFamily
                    enabled: root.online && !root.busy
                    onClicked: root.toggleFavorite("scene", modelData.id)
                  }
                }
              }
            }
          }
          Text {
            visible: root.tab === "scenes" && root.scenes.length === 0
            text: "No scenes found on this bridge."
            color: root.foreground
            font.family: root.fontFamily
          }
          Text {
            visible: root.tab === "scenes" && (root.errorText !== "" || root.actionNotice !== "")
            width: parent.width
            text: root.errorText || root.actionNotice
            textFormat: Text.PlainText
            wrapMode: Text.WordWrap
            color: root.foreground
            font.family: root.fontFamily
          }
          Text {
            visible: root.tab !== "scenes"
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
                    enabled: root.online && !root.busy
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
            visible: root.tab !== "scenes" && (root.tab === "all" || root.selected !== null)
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
                enabled: root.online && !root.busy && !!root.target
                onClicked: root.setLight("on", !(root.selected && root.selected.on))
              }
            }
            Button {
              visible: root.tab === "groups" && root.group !== null
              text: root.isFavorite("group", root.chosenGroup) ? "★ Unpin group" : "☆ Pin group"
              foreground: root.foreground
              fontFamily: root.fontFamily
              enabled: root.online && !root.busy
              onClicked: root.toggleFavorite("group", root.chosenGroup)
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
              enabled: root.online && !root.busy
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
            Text {
              visible: root.actionNotice !== ""
              width: parent.width
              text: root.actionNotice
              textFormat: Text.PlainText
              wrapMode: Text.WordWrap
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }
            PanelSectionHeader {
              visible: root.canColor
              text: "COLOR · COLOR-CAPABLE LIGHTS ONLY"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }
            Column {
              visible: root.canColor
              width: parent.width
              spacing: Style.space(7)

              Rectangle {
                id: colorArea
                width: parent.width
                height: Style.space(98)
                radius: Style.cornerRadius
                clip: true
                color: Qt.hsva(root.pickerHue, 1, 1, 1)
                border.width: 1
                border.color: root.foreground

                Rectangle {
                  anchors.fill: parent
                  gradient: Gradient {
                    orientation: Gradient.Horizontal
                    GradientStop { position: 0; color: "white" }
                    GradientStop { position: 1; color: "#00ffffff" }
                  }
                }
                Rectangle {
                  anchors.fill: parent
                  gradient: Gradient {
                    GradientStop { position: 0; color: "transparent" }
                    GradientStop { position: 1; color: "black" }
                  }
                }
                Rectangle {
                  x: root.pickerSaturation * (colorArea.width - width)
                  y: (1 - root.pickerValue) * (colorArea.height - height)
                  width: Style.space(12)
                  height: width
                  radius: width / 2
                  color: "transparent"
                  border.width: 2
                  border.color: "white"
                  Rectangle {
                    anchors.fill: parent
                    anchors.margins: 2
                    radius: width / 2
                    color: "transparent"
                    border.width: 1
                    border.color: "#222222"
                  }
                }
                MouseArea {
                  anchors.fill: parent
                  enabled: root.online && !root.busy
                  cursorShape: Qt.CrossCursor
                  onPressed: function(mouse) { root.updateColorArea(mouse.x, mouse.y, width, height) }
                  onPositionChanged: function(mouse) {
                    if (pressed) root.updateColorArea(mouse.x, mouse.y, width, height)
                  }
                  onReleased: root.applyPickerColor()
                }
              }

              Rectangle {
                id: hueStrip
                width: parent.width
                height: Style.space(18)
                radius: Style.cornerRadius
                clip: true
                border.width: 1
                border.color: root.foreground
                gradient: Gradient {
                  orientation: Gradient.Horizontal
                  GradientStop { position: 0; color: "#ff0000" }
                  GradientStop { position: 0.1667; color: "#ffff00" }
                  GradientStop { position: 0.3333; color: "#00ff00" }
                  GradientStop { position: 0.5; color: "#00ffff" }
                  GradientStop { position: 0.6667; color: "#0000ff" }
                  GradientStop { position: 0.8333; color: "#ff00ff" }
                  GradientStop { position: 1; color: "#ff0000" }
                }
                Rectangle {
                  x: root.pickerHue * (hueStrip.width - width)
                  width: Style.space(7)
                  height: parent.height
                  radius: Style.space(2)
                  color: "transparent"
                  border.width: 2
                  border.color: "white"
                }
                MouseArea {
                  anchors.fill: parent
                  enabled: root.online && !root.busy
                  cursorShape: Qt.PointingHandCursor
                  onPressed: function(mouse) { root.updateHue(mouse.x, width) }
                  onPositionChanged: function(mouse) {
                    if (pressed) root.updateHue(mouse.x, width)
                  }
                  onReleased: root.applyPickerColor()
                }
              }
            }
            Row {
              visible: root.canColor
              width: parent.width
              spacing: Style.space(8)
              Rectangle {
                width: hexInput.height
                height: hexInput.height
                radius: Style.cornerRadius
                color: root.previewHex
                border.width: 1
                border.color: root.foreground
              }
              Controls.TextField {
                id: hexInput
                width: parent.width - colorButton.implicitWidth - height - parent.spacing * 2
                placeholderText: "#RRGGBB"
                color: root.foreground
                font.family: root.fontFamily
                selectByMouse: true
                onTextEdited: root.setPickerFromHex(text.trim())
                onAccepted: root.applyHexColor()
              }
              Button {
                id: colorButton
                text: "Set color"
                bordered: true
                foreground: root.foreground
                fontFamily: root.fontFamily
                enabled: root.online && !root.busy
                onClicked: root.applyHexColor()
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
