import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model

// Non-visual half of the widget: every Process, every Timer, every mutable
// property. Panel.qml only draws what lands here.
QtObject {
  id: root

  property var settings: ({})
  property bool panelOpen: false
  property string helperPath: ""

  property var snapshot: Model.emptySnapshot()
  property int dataVersion: 0
  property bool loading: false
  property string collectorError: ""

  // modelctl load blocks while it polls the router, so an action can run for
  // minutes. These carry the optimistic state until the snapshot catches up.
  property string pendingModel: ""
  property string pendingAction: ""
  property string actionError: ""
  property bool actionExited: false

  property var knownFailed: ({})

  function setting(key, fallback) {
    var v = settings ? settings[key] : undefined
    return (v === undefined || v === null || v === "") ? fallback : v
  }

  // Ships inside the plugin, so it works on a machine that never installed the
  // CLI. The setting still wins for anyone pointing at their own build.
  readonly property string helper: setting("modelctlPath",
    root.helperPath !== "" ? root.helperPath : "modelctl")
  readonly property bool notifyFailed: setting("notifyFailed", true)
  readonly property string routerUrl: setting("routerUrl", "")
  readonly property string apiKeyFile: setting("apiKeyFile", "")

  // Prefix shared by every invocation, so the panel and the actions always
  // talk to the same router.
  function helperArgv() {
    var argv = [root.helper]
    if (root.routerUrl !== "") argv.push("--router", root.routerUrl)
    if (root.apiKeyFile !== "") argv.push("--api-key-file", root.apiKeyFile)
    return argv
  }

  readonly property bool busy: pendingModel !== ""

  // Until the first collect returns, an empty snapshot looks exactly like a
  // dead router. Painting the bar red for that half second cries wolf on the
  // one signal that has to mean something.
  readonly property bool hasData: dataVersion > 0

  // The snapshot with the in-flight action painted over it.
  readonly property var view: {
    var snap = root.snapshot
    if (root.pendingModel === "") return snap
    var copy = JSON.parse(JSON.stringify(snap))
    for (var i = 0; i < copy.models.length; i++) {
      if (copy.models[i].id === root.pendingModel)
        copy.models[i].state = root.pendingAction === "load" ? "loading" : "unloading"
    }
    return copy
  }

  function refresh() {
    if (collectProc.running) return
    root.loading = true
    collectProc.command = root.helperArgv().concat(["status", "--json"])
    collectProc.running = true
  }

  function runAction(action, modelId, force) {
    if (root.busy) return
    root.actionError = ""
    root.actionExited = false
    root.pendingAction = action
    root.pendingModel = modelId
    var argv = root.helperArgv()
    if (force) argv.push("--force")
    argv.push(action, modelId)
    actionProc.command = argv
    actionProc.running = true
  }

  function handleOutput(text) {
    var snap = Model.parseSnapshot(text)
    root.collectorError = snap.error
    root.snapshot = snap
    root.dataVersion++
    if (root.notifyFailed) root.checkFailures(snap)
  }

  // Only announce a model the first time it fails. Re-announcing every poll
  // would turn one bad boot into a notification storm.
  function checkFailures(snap) {
    var seen = {}
    var fresh = []
    var failed = Model.failedModels(snap)
    for (var i = 0; i < failed.length; i++) {
      seen[failed[i].id] = true
      if (!root.knownFailed[failed[i].id]) fresh.push(failed[i].id)
    }
    root.knownFailed = seen
    if (fresh.length > 0) {
      notifyProc.command = ["notify-send", "-u", "critical", "-a", "modelctl",
                            "Model down in the router",
                            fresh.join(", ") + " failed to load. Try: modelctl restore"]
      notifyProc.running = true
    }
  }

  property Process collectProc: Process {
    running: false
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.handleOutput(text)
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: { if (text) root.collectorError = Model.actionErrorText(text) }
    }
    onRunningChanged: {
      if (running) return
      // Quickshell fires neither exited() nor streamEnded() when a process
      // fails to spawn, only runningChanged(). Clearing here is what stops
      // `loading` from sticking true forever on a bad helper path.
      root.loading = false
    }
  }

  property Process actionProc: Process {
    running: false
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: { if (text) root.actionError = Model.actionErrorText(text) }
    }
    onExited: function (code, status) {
      root.actionExited = true
      if (code !== 0 && root.actionError === "")
        root.actionError = "modelctl exited with code " + code
    }
    onRunningChanged: {
      if (running) return
      // Same spawn-failure trap as the collector: without this the panel would
      // stay disabled forever behind a pending action that never started.
      if (!root.actionExited && root.pendingModel !== "")
        root.actionError = "Could not run modelctl"
      root.pendingModel = ""
      root.pendingAction = ""
      root.refresh()
    }
  }

  property Process notifyProc: Process { running: false }

  // The router pushes its whole lifecycle over SSE, so the widget follows a
  // long-lived stream instead of spawning a process every N seconds. Failures
  // land the instant they happen and a slow load reports real progress.
  property Process watchProc: Process {
    running: false
    stdout: SplitParser {
      onRead: function (line) {
        if (String(line || "").trim() === "") return
        root.handleOutput(line)
      }
    }
    stderr: SplitParser {
      onRead: function (line) { if (line) root.collectorError = Model.actionErrorText(line) }
    }
    onRunningChanged: {
      if (running) return
      // Same spawn-failure trap as everywhere else: without clearing here a bad
      // helper path would leave the panel waiting on data that never comes.
      root.loading = false
    }
  }

  // Restarts the stream if it dies: helper crash, router restart, or a
  // watch that exits on its own. Cheap enough to run forever.
  property Timer watchdog: Timer {
    interval: 5000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: {
      if (watchProc.running) return
      root.loading = true
      watchProc.command = root.helperArgv().concat(["watch"])
      watchProc.running = true
    }
  }
}
