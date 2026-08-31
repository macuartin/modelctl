// Run with: deno run --allow-read tests/model.test.js
// Model.js is a .pragma library with no exports, so it is evaluated here
// rather than imported. Same technique as omarchy-pods' test suite.

const source = Deno.readTextFileSync(new URL("../Model.js", import.meta.url))
const Model = new Function(
  source.replace(".pragma library", "") +
  "; return { SCHEMA_VERSION, emptySnapshot, parseSnapshot, gib, shortName," +
  " failedModels, loadedModels, barText, alarming, stateMark, stateLabel," +
  " slotsText, routerLabel, ctxText, detailLine, memText, loadEvicts," +
  " retryHint, sourceLabel, actionErrorText }"
)()

let failures = 0

function check(name, actual, expected) {
  const ok = JSON.stringify(actual) === JSON.stringify(expected)
  if (!ok) {
    failures++
    console.log("FAIL " + name + "\n  expected " + JSON.stringify(expected) + "\n  got      " + JSON.stringify(actual))
  }
}

// Trimmed from a real `modelctl status --json` on the box, 2026-08-31.
const live = JSON.stringify({
  schemaVersion: 1,
  updatedAt: "2026-08-31T14:51:02+0200",
  router: {
    reachable: true,
    url: "http://127.0.0.1:8080",
    modelsMax: 12,
    sources: { presetFile: "/home/macuartin/.config/llama-models.ini", modelsDir: "" },
    loadedCount: 4,
  },
  memory: { pool: "GTT", usedMiB: 54269, totalMiB: 128082, percent: 42 },
  models: [
    { id: "ornith1.5-35b-a3b", state: "loaded", protected: true, protectedReason: "load-on-startup", exitCode: null, contextSize: 524288, progress: null, stage: null },
    { id: "qwen3-embedding-0.6b", state: "loaded", protected: true, protectedReason: "embeddings", exitCode: null, contextSize: 32768, progress: null, stage: null },
    { id: "apodex1.1-mini", state: "unloaded", protected: false, protectedReason: null, exitCode: null, contextSize: 262144, progress: null, stage: null },
  ],
})

const good = Model.parseSnapshot(live)
check("live line parses", good.ok, true)
check("live reachable", good.reachable, true)
check("live slots", [good.loadedCount, good.modelsMax], [4, 12])
check("live preset file", good.presetFile, "/home/macuartin/.config/llama-models.ini")
check("live memory", [good.memPool, good.memPercent], ["GTT", 42])
check("live models count", good.models.length, 3)
check("live error is empty", good.error, "")

// The shapes that bite: nothing, garbage, and a JSON missing its sections.
const empty = Model.parseSnapshot("")
check("empty input errors", empty.error, "modelctl returned nothing")
check("empty input not ok", empty.ok, false)

const garbage = Model.parseSnapshot("router exploded\n")
check("non-JSON errors", garbage.error, "unreadable modelctl output")

const bare = Model.parseSnapshot("{}")
check("bare object parses", bare.ok, true)
check("bare object unreachable", bare.reachable, false)
check("bare object has no models", bare.models, [])

// A helper newer than this file refuses cleanly instead of half-rendering.
const future = Model.parseSnapshot(JSON.stringify({ schemaVersion: Model.SCHEMA_VERSION + 1 }))
check("future schema not ok", future.ok, false)
check("future schema names the version",
  future.error, "modelctl speaks schema v2, reload or update the widget")
// A helper older than the stamp carries no schemaVersion at all and still reads.
const unstamped = Model.parseSnapshot(JSON.stringify({ router: { reachable: true } }))
check("unstamped line still parses", unstamped.ok, true)

// barText: the failure count wins over everything, silence only when down.
function snapWith(models, reachable) {
  return Model.parseSnapshot(JSON.stringify({
    schemaVersion: 1, router: { reachable: reachable !== false }, models: models,
  }))
}
check("barText router down", Model.barText(snapWith([], false)), "router?")
check("barText no models", Model.barText(snapWith([])), "no models")
check("barText one loaded uses the short name",
  Model.barText(snapWith([{ id: "ornith1.5-35b-a3b", state: "loaded" }])), "ornith1.5")
check("barText failed wins over loaded",
  Model.barText(snapWith([
    { id: "a-7b", state: "loaded" },
    { id: "b-7b", state: "failed" },
  ])), "1 failed")
check("barText counts several loaded",
  Model.barText(snapWith([
    { id: "a-7b", state: "loaded" },
    { id: "b-7b", state: "loaded" },
  ])), "2 models")

check("shortName drops the parameter tail", Model.shortName("qwen3.6-35b-a3b"), "qwen3.6")
check("shortName leaves plain names alone", Model.shortName("apodex1.1-mini"), "apodex1.1-mini")

// retryHint: its three branches depend on who in the failed set is startup.
const startupFail = { id: "a", state: "failed", protectedReason: "load-on-startup" }
const plainFail = { id: "b", state: "failed", protectedReason: null }
check("retryHint all startup",
  Model.retryHint(snapWith([startupFail])), "Retry the failed ones with: modelctl restore")
check("retryHint none startup",
  Model.retryHint(snapWith([plainFail])),
  "Retry with the button, or check journalctl -u llama-server")
check("retryHint mixed",
  Model.retryHint(snapWith([startupFail, plainFail])),
  "Startup ones: modelctl restore. The rest, with the button.")
check("retryHint quiet with no failures", Model.retryHint(snapWith([])), "")

// loadEvicts only once the cap is known and met.
const full = Model.parseSnapshot(JSON.stringify(
  { schemaVersion: 1, router: { reachable: true, modelsMax: 2, loadedCount: 2 } }))
const room = Model.parseSnapshot(JSON.stringify(
  { schemaVersion: 1, router: { reachable: true, modelsMax: 2, loadedCount: 1 } }))
check("loadEvicts at the cap", Model.loadEvicts(full), true)
check("loadEvicts with room", Model.loadEvicts(room), false)
check("loadEvicts with unknown cap", Model.loadEvicts(snapWith([])), false)

// memText renders nothing rather than a convincing 0/0 (plain NVIDIA case).
check("memText without a pool", Model.memText(snapWith([])), "")
check("memText with the pool", Model.memText(good), "GTT 53.0 / 125.1 GiB  (42%)")

check("routerLabel local", Model.routerLabel(good), "Router :8080")
check("routerLabel remote host", Model.routerLabel(
  Model.parseSnapshot(JSON.stringify(
    { schemaVersion: 1, router: { url: "http://framework.lan:9090" } }))),
  "Router framework.lan:9090")
check("routerLabel garbage", Model.routerLabel(snapWith([])), "Router")

check("sourceLabel shortens home", Model.sourceLabel(good, "/home/macuartin"),
  "~/.config/llama-models.ini")

check("actionErrorText keeps the last line",
  Model.actionErrorText("progress...\nerror: model not found\n"), "error: model not found")
check("actionErrorText of nothing", Model.actionErrorText(""), "")

if (failures > 0) {
  console.log(failures + " failing")
  Deno.exit(1)
}
console.log("all checks passed")
