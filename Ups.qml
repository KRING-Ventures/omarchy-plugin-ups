import QtQuick
import qs.Commons
import qs.Ui

// Presentation only. Everything stateful lives in Service.qml, which the shell
// mounts exactly once regardless of how many monitors show this widget.
BarWidget {
  id: root
  moduleName: "omarchy-community.ups"

  readonly property var service: bar?.shell?.serviceFor("omarchy-community.ups")

  // What the label shows on mains power: load | charge | runtime | power | none.
  // On battery this is overridden with runtime, which is the only number that
  // matters during an outage.
  readonly property string metric: String(setting("display", "load"))
  readonly property bool onlyWhenInteresting: setting("hideWhenOnline", false) === true

  readonly property bool ready: service !== null && service !== undefined
  readonly property bool reachable: ready && service.reachable

  // Nerd Font codepoints, written as escapes rather than literal glyphs so they
  // survive editors and patches that do not handle the private use area.
  readonly property string glyphPlug: ""      // plug
  readonly property string glyphWarn: ""      // warning triangle
  readonly property string glyphOffline: ""   // broken link
  readonly property var batteryGlyphs: [
    "", // empty
    "", // quarter
    "", // half
    "", // three quarters
    ""  // full
  ]

  function fmtCountdown(seconds) {
    var s = Math.max(0, seconds)
    return Math.floor(s / 60) + ":" + (s % 60 < 10 ? "0" : "") + (s % 60)
  }

  function batteryGlyph() {
    var charge = service.charge
    if (charge < 0) return batteryGlyphs[0]
    if (charge >= 90) return batteryGlyphs[4]
    if (charge >= 65) return batteryGlyphs[3]
    if (charge >= 40) return batteryGlyphs[2]
    if (charge >= 15) return batteryGlyphs[1]
    return batteryGlyphs[0]
  }

  readonly property string glyph: {
    if (ready && service.shutdownArmed) return glyphWarn
    if (!reachable) return glyphOffline
    if (service.lowBattery || service.replaceBattery || service.shutdownPending) return glyphWarn
    if (service.onBattery) return batteryGlyph()
    return glyphPlug
  }

  readonly property string metricText: {
    if (ready && service.shutdownArmed) return fmtCountdown(service.shutdownRemaining)
    if (!reachable) return "UPS?"
    if (service.onBattery) return service.fmtRuntime(service.runtime)
    switch (metric) {
    case "none": return ""
    case "charge": return service.charge < 0 ? "--" : Math.round(service.charge) + "%"
    case "runtime": return service.fmtRuntime(service.runtime)
    case "power": return service.realpower < 0 ? "--" : Math.round(service.realpower) + "W"
    default: return service.load < 0 ? "--" : Math.round(service.load) + "%"
    }
  }

  readonly property string tooltip: {
    if (!ready) return "UPS: starting up"
    if (service.shutdownArmed)
      return "UPS: " + service.shutdownReason
        + "\n" + (service.plannedAction() === "hibernate" ? "Hibernating" : "Powering off")
        + " in " + fmtCountdown(service.shutdownRemaining)
        + "\nCancel: omarchy-shell omarchy-community.ups cancelShutdown"
    if (!reachable) return "UPS unreachable\n" + service.host + ":" + service.port + "\n" + service.errorText

    var mfr = String(service.value("ups.mfr", "")).trim()
    var model = String(service.value("ups.model", "")).trim().replace(/_/g, " ")
    var lines = []
    lines.push((mfr + " " + model).trim() || ("UPS " + service.upsId))
    lines.push("Status:    " + service.statusLabel)
    if (service.charge >= 0) lines.push("Battery:   " + Math.round(service.charge) + "%")
    if (service.runtime >= 0) lines.push("Runtime:   " + service.fmtRuntime(service.runtime))
    if (service.load >= 0) {
      var watts = service.realpower >= 0 ? "  (" + Math.round(service.realpower) + " W)" : ""
      lines.push("Load:      " + Math.round(service.load) + "%" + watts)
    }
    if (service.inputVoltage >= 0) lines.push("Input:     " + service.inputVoltage.toFixed(1) + " V")
    if (service.temperature >= 0) lines.push("Temp:      " + service.temperature.toFixed(1) + " °C")
    var test = String(service.value("ups.test.result", "")).trim()
    if (test !== "") {
      var when = String(service.value("ups.test.date", "")).trim()
      lines.push("Self-test: " + test + (when !== "" ? " (" + when + ")" : ""))
    }
    return lines.join("\n")
  }

  visible: onlyWhenInteresting ? (ready && service.alarming) : true
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.metricText === "" ? root.glyph : root.glyph + "  " + root.metricText
    fontSize: Style.font.bodySmall
    active: root.ready && (root.service.alarming || root.service.shutdownArmed)
    dimmed: !root.reachable
    tooltipText: root.tooltip

    onPressed: function (b) {
      if (!root.ready) return
      if (b === Qt.MiddleButton) root.service.refresh()
      else root.service.notifySend("normal", "UPS — " + root.service.statusLabel, root.tooltip)
    }
  }
}
