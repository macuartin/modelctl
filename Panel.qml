import QtQuick
import QtQuick.Controls
import Quickshell
import qs.Commons
import qs.Ui
import "Model.js" as Model

Panel {
  id: root
  moduleName: "macuartin.modelctl"
  ipcTarget: "macuartin.modelctl"

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  readonly property string home: Quickshell.env("HOME")
  readonly property var snap: service.view
  readonly property bool alarming: service.hasData && Model.alarming(snap)

  // Confirmation is deferred, not skipped: these hold the action waiting on it.
  property string confirmAction: ""
  property string confirmModel: ""

  function pathFromUrl(url) {
    var value = String(url || "")
    if (value.indexOf("file://") === 0) return decodeURIComponent(value.substring(7))
    return value
  }

  function act(action, modelId, force) {
    service.runAction(action, modelId, force)
  }

  function requestAction(model) {
    var loaded = model.state === "loaded"
    if (loaded && model.protected) {
      root.confirmAction = "unload"
      root.confirmModel = model.id
      confirm.message = "'" + model.id + "' is protected (" + model.protectedReason +
                        "). Unloading it takes down whatever depends on it."
      confirm.opened = true
      return
    }
    if (!loaded && Model.loadEvicts(snap)) {
      root.confirmAction = "load"
      root.confirmModel = model.id
      confirm.message = snap.loadedCount + " of " + snap.modelsMax +
                        " slots are in use. Loading '" + model.id + "' evicts another model."
      confirm.opened = true
      return
    }
    root.act(loaded ? "unload" : "load", model.id, false)
  }

  onOpenedChanged: if (!opened) confirm.opened = false

  Service {
    id: service
    settings: root.settings
    panelOpen: root.opened
    helperPath: root.pathFromUrl(Qt.resolvedUrl("scripts/modelctl"))
  }

  // The Panel base is a bare Item: without propagating the button's implicit
  // size the widget measures 0x0 and the bar draws nothing at all.
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󰧑"
    active: root.alarming
    onPressed: function (buttonCode) {
      if (buttonCode === Qt.MiddleButton) service.refresh()
      else root.toggle()
    }

    // Hover only: NoButton lets every click fall through to the button below.
    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      acceptedButtons: Qt.NoButton
      onEntered: if (root.bar) root.bar.showTooltip(root, Model.barText(snap))
      onExited: if (root.bar) root.bar.hideTooltip(root)
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(360))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(560))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent

      onActivateRequested: service.refresh()
      onCloseRequested: root.close()
      onTabRequested: function (direction) { root.switchPanel(direction) }
      onTextKey: function (t) { if (t === "r" || t === "R") service.refresh() }

      Flickable {
        id: flick
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
          width: flick.width
          spacing: Style.space(10)

          PanelHero {
            width: parent.width
            foreground: root.foreground
            fontFamily: root.fontFamily
            title: "Router :8080"
            meta: snap.reachable ? Model.slotsText(snap) : "no response"
            detail: snap.reachable ? Model.memText(snap) : "not responding"
          }

          // Memory meter. The pool every model competes for, so it earns the only
          // graphic in the panel.
          Rectangle {
            width: parent.width
            height: Style.space(6)
            radius: height / 2
            color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.12)
            visible: snap.reachable && snap.memTotalMiB > 0

            Rectangle {
              height: parent.height
              radius: parent.radius
              width: parent.width * Math.min(1, snap.memPercent / 100)
              color: snap.memPercent >= 90 ? root.urgent : root.foreground
              Behavior on width { NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }
            }
          }

          Text {
            width: parent.width
            visible: service.collectorError !== "" || service.actionError !== ""
            text: service.actionError !== "" ? service.actionError : service.collectorError
            color: root.urgent
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }

          PanelSectionHeader {
            width: parent.width
            text: "Models"
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          Repeater {
            model: snap.models

            Item {
              required property var modelData
              width: column.width
              height: Style.space(30)

              Text {
                id: mark
                anchors.verticalCenter: parent.verticalCenter
                text: Model.stateMark(modelData.state)
                color: modelData.state === "failed" ? root.urgent
                     : modelData.state === "loaded" ? root.foreground : root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
              }

              Column {
                anchors.left: mark.right
                anchors.leftMargin: Style.space(8)
                anchors.right: action.left
                anchors.rightMargin: Style.space(8)
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(1)

                Text {
                  width: parent.width
                  text: modelData.id
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  elide: Text.ElideRight
                }
                Text {
                  width: parent.width
                  text: Model.stateLabel(modelData) +
                        (modelData.protected ? "  ·  " + modelData.protectedReason : "")
                  color: modelData.state === "failed" ? root.urgent : root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  elide: Text.ElideRight
                }

                // Only while the router is actually reporting progress: a
                // stuck bar is worse than no bar.
                Rectangle {
                  width: parent.width
                  height: Style.space(3)
                  radius: height / 2
                  visible: modelData.progress !== null && modelData.progress !== undefined
                  color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.15)

                  Rectangle {
                    height: parent.height
                    radius: parent.radius
                    width: parent.width * Math.max(0, Math.min(1, modelData.progress || 0))
                    color: root.foreground
                    Behavior on width { NumberAnimation { duration: 160 } }
                  }
                }
              }

              PanelActionButton {
                id: action
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                foreground: root.foreground
                fontFamily: root.fontFamily
                enabled: !service.busy && snap.reachable
                opacity: enabled ? 1 : 0.35
                iconText: modelData.state === "loaded" ? "󰅖" : "󰐊"
                tooltipText: modelData.state === "loaded" ? "Unload" : "Load"
                onClicked: root.requestAction(modelData)
              }
            }
          }

          // The file the router discovers models from, straight from its own
          // command line. Click to edit it; adding a model needs a restart.
          Item {
            width: parent.width
            height: Style.space(26)
            visible: Model.sourceLabel(snap, root.home) !== ""

            Text {
              id: sourceIcon
              anchors.verticalCenter: parent.verticalCenter
              text: "󱁻"
              color: sourceArea.containsMouse ? root.foreground : root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
            }

            Text {
              anchors.left: sourceIcon.right
              anchors.leftMargin: Style.space(8)
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              text: Model.sourceLabel(snap, root.home)
              color: sourceArea.containsMouse ? root.foreground : root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              elide: Text.ElideMiddle
            }

            MouseArea {
              id: sourceArea
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onEntered: if (root.bar) root.bar.showTooltip(parent, "Edit the model presets")
              onExited: if (root.bar) root.bar.hideTooltip(parent)
              onClicked: {
                if (!root.bar) return
                root.bar.run("omarchy-launch-editor " +
                             root.bar.shellQuote(snap.presetFile || snap.modelsDir))
                root.close()
              }
            }
          }

          Text {
            width: parent.width
            visible: snap.reachable && Model.failedModels(snap).length > 0
            text: Model.retryHint(snap)
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }
        }
      }

      ConfirmDialog {
        id: confirm
        z: 10
        anchors.fill: parent
        foreground: root.foreground
        fontFamily: root.fontFamily
        cancelText: "Cancel"
        confirmText: "Continue"
        onConfirmed: {
          confirm.opened = false
          root.act(root.confirmAction, root.confirmModel, root.confirmAction === "unload")
          root.confirmAction = ""
          root.confirmModel = ""
        }
        onCanceled: {
          confirm.opened = false
          root.confirmAction = ""
          root.confirmModel = ""
        }
      }
    }
  }
}
