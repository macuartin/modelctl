// Pure helpers over the modelctl snapshot. No QML types, no side effects, so
// the panel and the service can both reason about state the same way.
.pragma library

function emptySnapshot() {
  return {
    ok: false,
    reachable: false,
    modelsMax: 0,
    loadedCount: 0,
    presetFile: "",
    modelsDir: "",
    memPool: "",
    memUsedMiB: 0,
    memTotalMiB: 0,
    memPercent: 0,
    models: [],
    error: ""
  }
}

function parseSnapshot(text) {
  var snap = emptySnapshot()
  if (!text) {
    snap.error = "modelctl returned nothing"
    return snap
  }
  var raw
  try {
    raw = JSON.parse(text)
  } catch (e) {
    snap.error = "unreadable modelctl output"
    return snap
  }
  var router = raw.router || {}
  var mem = raw.memory || {}
  snap.ok = true
  snap.reachable = !!router.reachable
  snap.modelsMax = router.modelsMax || 0
  snap.loadedCount = router.loadedCount || 0
  var sources = router.sources || {}
  snap.presetFile = sources.presetFile || ""
  snap.modelsDir = sources.modelsDir || ""
  snap.memPool = mem.pool || ""
  snap.memUsedMiB = mem.usedMiB || 0
  snap.memTotalMiB = mem.totalMiB || 0
  snap.memPercent = mem.percent || 0
  snap.models = Array.isArray(raw.models) ? raw.models : []
  return snap
}

function gib(mib) {
  return (mib / 1024).toFixed(1)
}

function shortName(id) {
  // Bar real estate is scarce: drop the parameter-count tail that every id
  // carries and that never distinguishes two loaded models in practice.
  return String(id || "").replace(/-[0-9.]+b(-a[0-9.]+b)?$/i, "")
}

function failedModels(snap) {
  return snap.models.filter(function (m) { return m.state === "failed" })
}

function loadedModels(snap) {
  return snap.models.filter(function (m) { return m.state === "loaded" })
}

// What the bar button says. The failure count wins over the model name: a
// silent failed model is the thing this widget exists to surface.
function barText(snap) {
  if (!snap.ok || !snap.reachable) return "router?"
  var failed = failedModels(snap)
  if (failed.length > 0) return failed.length + " failed"
  var loaded = loadedModels(snap)
  if (loaded.length === 0) return "no models"
  if (loaded.length === 1) return shortName(loaded[0].id)
  return loaded.length + " models"
}

function alarming(snap) {
  if (!snap.ok || !snap.reachable) return true
  return failedModels(snap).length > 0
}

function stateMark(state) {
  if (state === "loaded") return "●"
  if (state === "sleeping") return "◌"
  if (state === "failed") return "⚠"
  if (state === "loading" || state === "unloading") return "◐"
  return "○"
}

function stateLabel(model) {
  if (model.state === "loaded") return "loaded"
  if (model.state === "failed") return "failed (exit " + (model.exitCode === null ? "?" : model.exitCode) + ")"
  if (model.state === "loading") {
    if (model.progress === null || model.progress === undefined) return "loading..."
    var stage = model.stage ? model.stage.replace(/_/g, " ") + " " : ""
    return "loading " + stage + Math.round(model.progress * 100) + "%"
  }
  if (model.state === "unloading") return "unloading..."
  if (model.state === "sleeping") return "sleeping"
  return "unloaded"
}

// modelsMax 0 means the cap could not be read, so say nothing about it rather
// than inventing one.
function slotsText(snap) {
  if (snap.modelsMax > 0) return snap.loadedCount + " of " + snap.modelsMax + " slots"
  return snap.loadedCount + (snap.loadedCount === 1 ? " model loaded" : " models loaded")
}

// Empty when the machine exposes no readable pool (plain NVIDIA), so the panel
// omits the meter instead of drawing a convincing 0,0 / 0,0.
function memText(snap) {
  if (!snap.memTotalMiB) return ""
  return snap.memPool + " " + gib(snap.memUsedMiB) + " / " + gib(snap.memTotalMiB) +
         " GiB  (" + snap.memPercent + "%)"
}

// A load that would exceed --models-max evicts somebody else. Worth a
// confirmation before the click, not an apology after it.
function loadEvicts(snap) {
  return snap.modelsMax > 0 && snap.loadedCount >= snap.modelsMax
}

// restore reloads only the startup set. Telling someone to run it for a
// model it will skip is worse than saying nothing.
function retryHint(snap) {
  var failed = failedModels(snap)
  if (failed.length === 0) return ""
  var startup = failed.filter(function (m) { return m.protectedReason === "load-on-startup" })
  if (startup.length === failed.length) return "Retry the failed ones with: modelctl restore"
  if (startup.length === 0) return "Retry with the button, or check journalctl -u llama-server"
  return "Startup ones: modelctl restore. The rest, with the button."
}

// Where the router discovers models. The preset file is the common case; a
// --models-dir setup reports the directory instead.
function sourceLabel(snap, home) {
  var path = snap.presetFile || snap.modelsDir
  if (!path) return ""
  if (home && path.indexOf(home) === 0) path = "~" + path.substring(home.length)
  return path
}

function actionErrorText(text) {
  var line = String(text || "").trim().split("\n").filter(function (l) { return l.trim() })
  return line.length ? line[line.length - 1].trim() : ""
}
