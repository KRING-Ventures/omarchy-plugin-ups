import QtQuick
import Quickshell
import Quickshell.Io

// Single instance per shell process, mounted by omarchy-shell's service loader.
// Bar widgets are instantiated once per monitor, so all polling, state tracking
// and notification lives here: on a four-monitor setup, doing this in the widget
// polls upsd four times and fires four toasts for every power event.
Item {
  id: root

  // Injected by the service loader.
  property var shell: null
  property var manifest: null

  // Configuration is pulled straight out of shell.json rather than pushed in by
  // the bar widget: the service can mount before any widget does, and a service
  // that quietly polls localhost because nobody pushed settings yet is worse
  // than one that reads its own entry. Matches how omarchy.idle reads config.
  readonly property var config: shell && shell.shellConfig ? shell.shellConfig : null
  readonly property var entry: findEntry(config)

  readonly property string host: String(entryValue("host", "127.0.0.1"))
  readonly property int port: Number(entryValue("port", 3493))
  readonly property string upsName: String(entryValue("ups", ""))
  readonly property int intervalSeconds: Math.max(2, Number(entryValue("interval", 10)))
  readonly property bool notifyChanges: entryValue("notifications", true) === true

  // Our own layout entry, wherever the user put the widget.
  function findEntry(cfg) {
    if (!cfg) return null
    var id = "omarchy-community.ups"
    var layout = cfg.bar && cfg.bar.layout ? cfg.bar.layout : null
    var sections = ["left", "center", "right"]
    for (var i = 0; layout && i < sections.length; i++) {
      var list = layout[sections[i]]
      if (!Array.isArray(list)) continue
      for (var j = 0; j < list.length; j++) {
        if (list[j] && String(list[j].id) === id) return list[j]
      }
    }
    if (Array.isArray(cfg.plugins)) {
      for (var k = 0; k < cfg.plugins.length; k++) {
        if (cfg.plugins[k] && String(cfg.plugins[k].id) === id) return cfg.plugins[k]
      }
    }
    return null
  }

  function entryValue(name, fallback) {
    var v = entry ? entry[name] : undefined
    return v === undefined || v === null ? fallback : v
  }

  // ---- Raw state ----
  property bool reachable: false
  property string errorText: ""
  property var vars: ({})
  property string upsId: ""
  // Set after the first completed poll, so logging in during an outage does not
  // announce a "transition" that is really just the initial reading.
  property bool primed: false
  property string lastAlertClass: ""
  property bool lastReplaceBattery: false
  property bool lastOverloaded: false

  // __sourceDir is the plugin root, which is where the helper lives. Preferred
  // over a relative resolvedUrl so the spawned command has no "../" in it.
  readonly property string helperPath: manifest && manifest.__sourceDir
    ? String(manifest.__sourceDir).replace(/\/$/, "") + "/ups-poll"
    : String(Qt.resolvedUrl("../ups-poll")).replace(/^file:\/\//, "")

  // ---- Derived state, shared by the widget and the notifications ----
  // ups.status is a space-separated flag list (OL OB LB CHRG DISCHRG RB ...).
  readonly property var flags: String(value("ups.status", "")).toUpperCase().split(/\s+/).filter(function (f) { return f !== "" })
  readonly property bool onLine: has("OL")
  readonly property bool onBattery: has("OB")
  readonly property bool lowBattery: has("LB")
  readonly property bool charging: has("CHRG")
  readonly property bool replaceBattery: has("RB")
  readonly property bool overloaded: has("OVER")
  readonly property bool shutdownPending: has("FSD")

  readonly property real charge: number("battery.charge", -1)
  readonly property real load: number("ups.load", -1)
  readonly property real runtime: number("battery.runtime", -1)
  readonly property real realpower: number("ups.realpower", -1)
  readonly property real inputVoltage: number("input.voltage", -1)
  readonly property real temperature: number("ups.temperature", -1)

  // Anything other than "plugged in and healthy" earns the bar's accent colour.
  readonly property bool alarming: !reachable || onBattery || lowBattery || replaceBattery || overloaded || shutdownPending

  readonly property string statusLabel: {
    if (!reachable) return "Unreachable"
    if (shutdownPending) return "Shutdown imminent"
    if (lowBattery) return "On battery — LOW"
    if (onBattery) return "On battery"
    if (replaceBattery) return "Replace battery"
    if (overloaded) return "Overloaded"
    if (charging) return "Online, charging"
    if (onLine) return "Online"
    return flags.length ? flags.join(" ") : "Unknown"
  }

  // The single most severe power condition, used for edge detection. Keyed on
  // the condition rather than on the rendered label, so a cosmetic change like
  // OL -> OL CHRG is not mistaken for a power event.
  readonly property string alertClass: {
    if (!reachable) return "unreachable"
    if (shutdownPending) return "shutdown"
    if (lowBattery) return "low"
    if (onBattery) return "battery"
    return "ok"
  }

  function value(key, fallback) {
    var v = vars ? vars[key] : undefined
    return v === undefined || v === null ? fallback : v
  }

  function number(key, fallback) {
    var raw = value(key, "")
    if (raw === "") return fallback
    var parsed = parseFloat(raw)
    return isNaN(parsed) ? fallback : parsed
  }

  function has(flag) {
    return flags.indexOf(flag) !== -1
  }

  function fmtRuntime(seconds) {
    if (seconds < 0) return "--"
    var mins = Math.round(seconds / 60)
    if (mins < 60) return mins + "m"
    return Math.floor(mins / 60) + "h " + (mins % 60) + "m"
  }

  function refresh() {
    if (!poller.running) poller.running = true
  }

  // A list, not a shell string: no quoting to get wrong when a UPS model name
  // contains an apostrophe.
  function notifySend(urgency, title, body) {
    Quickshell.execDetached(["notify-send", "-a", "UPS", "-u", urgency, title, body])
  }

  function reportTransition() {
    if (!notifyChanges || !primed) return

    var body = statusLabel
    if (charge >= 0) body += " \u00b7 " + Math.round(charge) + "%"
    if (onBattery && runtime >= 0) body += " \u00b7 " + fmtRuntime(runtime) + " left"

    // Independent conditions, edge-detected on their own flags: a UPS can need
    // a new battery, or be overloaded, while already on battery, so neither may
    // be masked by the power-state class below.
    if (replaceBattery && !lastReplaceBattery) notifySend("critical", "UPS battery needs replacing", body)
    if (overloaded && !lastOverloaded) notifySend("critical", "UPS overloaded", body)

    if (alertClass === lastAlertClass) return

    switch (alertClass) {
    case "unreachable":
      notifySend("normal", "UPS unreachable", host + ":" + port)
      break
    case "shutdown":
    case "low":
      notifySend("critical", "UPS battery low", body)
      break
    case "battery":
      notifySend("critical", "Power lost \u2014 on UPS battery", body)
      break
    case "ok":
      // Only announce a recovery from something that was actually announced.
      if (lastAlertClass === "battery" || lastAlertClass === "low" || lastAlertClass === "shutdown")
        notifySend("normal", "Mains power restored", body)
      else if (lastAlertClass === "unreachable")
        notifySend("normal", "UPS reachable again", body)
      break
    }
  }

  IpcHandler {
    target: "omarchy-community.ups"

    function refresh(): void {
      root.refresh()
    }

    function status(): string {
      return root.reachable
        ? root.upsId + ": " + root.statusLabel
          + (root.charge >= 0 ? ", battery " + Math.round(root.charge) + "%" : "")
          + (root.runtime >= 0 ? ", " + root.fmtRuntime(root.runtime) + " runtime" : "")
          + (root.load >= 0 ? ", load " + Math.round(root.load) + "%" : "")
        : "unreachable: " + root.errorText
    }
  }

  Process {
    id: poller
    command: ["bash", root.helperPath, root.host, String(root.port), root.upsName]

    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var raw = String(text || "").trim()
        var parsed = null
        if (raw !== "") {
          try {
            parsed = JSON.parse(raw)
          } catch (e) {
            parsed = null
          }
        }

        if (!parsed || parsed.ok !== true) {
          root.reachable = false
          root.errorText = parsed && parsed.error ? String(parsed.error) : "no response from ups-poll"
          root.vars = ({})
        } else {
          root.reachable = true
          root.errorText = ""
          root.vars = parsed.vars || ({})
          root.upsId = String(parsed.name || "")
        }

        root.reportTransition()
        root.lastAlertClass = root.alertClass
        root.lastReplaceBattery = root.replaceBattery
        root.lastOverloaded = root.overloaded
        root.primed = true
      }
    }
  }

  Timer {
    interval: root.intervalSeconds * 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }
}
