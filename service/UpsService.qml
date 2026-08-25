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

  // ---- Auto-shutdown, opt-in ----
  // Off by default on purpose: a widget that powers the machine off without
  // being asked is a footgun. See README for the upsmon caveat.
  readonly property var shutdownConfig: {
    var v = entryValue("autoShutdown", null)
    return v && typeof v === "object" ? v : ({})
  }

  function shutdownOption(name, fallback) {
    var v = shutdownConfig[name]
    return v === undefined || v === null ? fallback : v
  }

  readonly property bool autoShutdownEnabled: shutdownOption("enabled", false) === true
  readonly property string shutdownAction: String(shutdownOption("action", "shutdown"))
  // Escape hatch for a custom action, and what the test harness points at so a
  // test run cannot power the machine off.
  readonly property string shutdownCommand: String(shutdownOption("command", ""))
  // Seconds of remaining runtime at or below which we act. 0 disables.
  readonly property int shutdownRuntimeBelow: Number(shutdownOption("runtimeBelow", 300))
  // Battery percent at or below which we act. 0 disables.
  readonly property int shutdownChargeBelow: Number(shutdownOption("chargeBelow", 0))
  // Also act on the UPS's own low-battery flag, whatever the numbers say.
  readonly property bool shutdownOnLowBattery: shutdownOption("onLowBattery", true) === true
  // Consecutive polls that must agree before arming. Guards against a single
  // bogus reading (a spurious runtime of 0) powering the machine off.
  readonly property int shutdownConfirmPolls: Math.max(1, Number(shutdownOption("confirmPolls", 2)))
  // Cancellable countdown once armed.
  readonly property int shutdownGraceSeconds: Math.max(0, Number(shutdownOption("graceSeconds", 60)))

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

  // Auto-shutdown state machine: counting -> armed -> fired.
  property int shutdownConfirmations: 0
  property bool shutdownArmed: false
  property int shutdownRemaining: 0
  property bool shutdownFired: false
  // Set by a manual cancel: without it the trigger is still true on the next
  // poll and the countdown simply starts again a few seconds later, which makes
  // cancelling by hand useless. Cleared when mains power comes back.
  property bool shutdownSuppressed: false
  property string hibernateSupported: "unknown"   // yes | no | unknown

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

  // Does the current reading warrant shutting down? Only ever true while we can
  // actually see the UPS and it is running on battery.
  readonly property bool shutdownConditionMet: {
    if (!autoShutdownEnabled || !reachable || !onBattery) return false
    // FSD is upsd explicitly commanding a shutdown; it is not advisory.
    if (shutdownPending) return true
    if (shutdownOnLowBattery && lowBattery) return true
    if (shutdownRuntimeBelow > 0 && runtime >= 0 && runtime <= shutdownRuntimeBelow) return true
    if (shutdownChargeBelow > 0 && charge >= 0 && charge <= shutdownChargeBelow) return true
    return false
  }

  readonly property string shutdownReason: {
    if (shutdownPending) return "UPS commanded shutdown"
    if (shutdownOnLowBattery && lowBattery) return "battery low"
    if (shutdownRuntimeBelow > 0 && runtime >= 0 && runtime <= shutdownRuntimeBelow)
      return fmtRuntime(runtime) + " runtime left"
    if (shutdownChargeBelow > 0 && charge >= 0 && charge <= shutdownChargeBelow)
      return Math.round(charge) + "% battery left"
    return "threshold reached"
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

  // ---- Auto-shutdown state machine ----

  function evaluateShutdown() {
    if (!autoShutdownEnabled) {
      if (shutdownArmed) cancelShutdown("auto-shutdown turned off")
      shutdownConfirmations = 0
      return
    }

    // Mains back: stand down, even mid-countdown, and re-arm for next time.
    if (reachable && !onBattery) {
      if (shutdownArmed) cancelShutdown("mains power restored")
      shutdownConfirmations = 0
      shutdownFired = false
      shutdownSuppressed = false
      return
    }

    // A manual cancel means "not during this outage".
    if (shutdownSuppressed) {
      shutdownConfirmations = 0
      return
    }

    // Once the countdown owns the decision, polling stops second-guessing it.
    // Note this deliberately keeps counting down when upsd becomes unreachable
    // mid-outage: we cannot tell a network blip from a dead UPS, and shutting
    // down cleanly is the safer of the two mistakes.
    if (shutdownArmed || shutdownFired) return

    if (!shutdownConditionMet) {
      shutdownConfirmations = 0
      return
    }

    // FSD is upsd commanding a shutdown now, not a threshold we inferred, so it
    // skips the debounce entirely: waiting confirmPolls x interval seconds to
    // believe it could be most of the time the UPS had left. The configured
    // grace period still applies.
    if (shutdownPending) {
      shutdownConfirmations = shutdownConfirmPolls
      armShutdown()
      return
    }

    shutdownConfirmations = shutdownConfirmations + 1
    if (shutdownConfirmations >= shutdownConfirmPolls) armShutdown()
  }

  function armShutdown() {
    if (shutdownArmed || shutdownFired) return
    shutdownArmed = true
    shutdownRemaining = shutdownGraceSeconds

    var verb = plannedAction() === "hibernate" ? "Hibernating" : "Shutting down"
    if (shutdownGraceSeconds <= 0) {
      notifySend("critical", verb + " now", "UPS: " + shutdownReason)
      fireShutdown()
      return
    }
    notifySend("critical", verb + " in " + shutdownGraceSeconds + "s",
               "UPS: " + shutdownReason + ". Cancel: omarchy-shell omarchy-community.ups cancelShutdown")
    graceTimer.start()
  }

  // Cancel and stay cancelled until mains power returns.
  function suppressShutdown() {
    var was = cancelShutdown("cancelled by hand")
    shutdownSuppressed = true
    return was
  }

  function resumeShutdown() {
    shutdownSuppressed = false
    shutdownConfirmations = 0
  }

  function cancelShutdown(why) {
    var wasArmed = shutdownArmed
    shutdownArmed = false
    shutdownRemaining = 0
    shutdownConfirmations = 0
    graceTimer.stop()
    if (wasArmed) notifySend("normal", "UPS shutdown cancelled", why)
    return wasArmed
  }

  // Resolve "hibernate" against what logind says this machine can actually do,
  // so a box with no swap large enough to hibernate to still shuts down safely
  // instead of doing nothing.
  function plannedAction() {
    if (shutdownCommand !== "") return "command"
    if (shutdownAction === "hibernate" && hibernateSupported !== "yes") return "shutdown"
    return shutdownAction === "hibernate" ? "hibernate" : "shutdown"
  }

  function fireShutdown() {
    if (shutdownFired) return
    shutdownFired = true
    shutdownArmed = false
    graceTimer.stop()

    var action = plannedAction()
    if (action === "command") {
      notifySend("critical", "UPS running shutdown command", shutdownCommand)
      Quickshell.execDetached(["bash", "-lc", shutdownCommand])
      return
    }
    if (shutdownAction === "hibernate" && action === "shutdown")
      notifySend("critical", "Hibernation unavailable - powering off instead",
                 "logind reports hibernate unsupported on this machine.")
    if (action === "hibernate") Quickshell.execDetached(["systemctl", "hibernate"])
    else Quickshell.execDetached(["systemctl", "poweroff"])
  }

  Timer {
    id: graceTimer
    interval: 1000
    repeat: true
    onTriggered: {
      root.shutdownRemaining = root.shutdownRemaining - 1
      // Re-warn on the way down, so a screen that was locked when we armed
      // still shows something before the machine goes.
      if (root.shutdownRemaining === 30 || root.shutdownRemaining === 10)
        root.notifySend("critical", "UPS shutdown in " + root.shutdownRemaining + "s", root.shutdownReason)
      if (root.shutdownRemaining <= 0) root.fireShutdown()
    }
  }

  // One-shot capability probe; "hibernate" is resolved against this at fire time.
  Process {
    id: hibernateProbe
    running: true
    command: ["busctl", "call", "org.freedesktop.login1", "/org/freedesktop/login1",
              "org.freedesktop.login1.Manager", "CanHibernate"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.hibernateSupported = String(text || "").indexOf("yes") !== -1 ? "yes" : "no"
      }
    }
  }

  IpcHandler {
    target: "omarchy-community.ups"

    function refresh(): void {
      root.refresh()
    }

    function cancelShutdown(): string {
      var was = root.suppressShutdown()
      return (was ? "cancelled" : "nothing armed")
        + "; auto-shutdown suppressed until mains power returns"
    }

    function resumeAutoShutdown(): string {
      root.resumeShutdown()
      return "auto-shutdown re-armed"
    }

    function shutdownStatus(): string {
      if (!root.autoShutdownEnabled) return "auto-shutdown disabled"
      return "action=" + root.plannedAction()
        + " armed=" + root.shutdownArmed
        + " remaining=" + root.shutdownRemaining
        + " confirmations=" + root.shutdownConfirmations + "/" + root.shutdownConfirmPolls
        + " fired=" + root.shutdownFired
        + " suppressed=" + root.shutdownSuppressed
        + " hibernateSupported=" + root.hibernateSupported
        + " conditionMet=" + root.shutdownConditionMet
        + (root.shutdownConditionMet ? " reason=" + root.shutdownReason : "")
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
        root.evaluateShutdown()
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
