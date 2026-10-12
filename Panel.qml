import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Grok Bot weekly usage.
// Bar: Grok Bot face + remaining meter, same slot and meter geometry as
// omarchy-grok-cursor-usage (Style.bar.iconSlot wide, meter 55% of it).
// Popup: charts only — this week's REMAINING curve (100% → 0%) against one
// even-pace line, drawn like omarchy-grok-cursor-usage; the last N weeks
// overlay is optional (off by default).
// No progress bars in the popup.
Panel {
  id: root
  moduleName: "songlairui.grokbot-usage"
  ipcTarget: "songlairui.grokbot-usage"
  manageIpc: false

  // ------------------------------------------------------------- theme
  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property color warn: Qt.tint(foreground, alpha(urgent, 0.55))
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property bool vertical: bar ? bar.vertical : false
  readonly property string barPosition: bar ? String(bar.position) : "top"

  // ------------------------------------------------------------- settings
  readonly property int refreshIntervalSec: Math.max(60, Number(setting("refreshIntervalSec", 300)))
  readonly property int historyWeeks: Math.max(2, Math.min(12, Number(setting("historyWeeks", 6))))
  readonly property bool historyDefault: String(setting("showHistory", "Off")) === "On"
  property bool historyShown: historyDefault
  onHistoryDefaultChanged: historyShown = historyDefault
  // Tray layout. compact (default): exactly omarchy-grok-cursor-usage's slot
  // (Style.bar.iconSlot wide, meter 55% of it). wide: face + "24% · 4d"
  // label, meter as wide as the content, with an even-pace tick.
  readonly property bool trayWide: String(setting("trayWide", "Off")) === "On"
  readonly property bool showCursor: String(setting("showCursor", "On")) === "On"
  readonly property bool showSuperGrok: String(setting("showSuperGrok", "On")) === "On"
  readonly property string barLabel: {
    var v = String(setting("barLabel", "percent-reset"))
    return (v === "percent" || v === "icon") ? v : "percent-reset"
  }
  // Right-click menu: a small PopupCard with action rows.
  property bool menuOpen: false
  property bool feedbackOpen: false
  property string pluginVersion: ""
  property bool pluginBehind: false
  onOpenedChanged: if (opened) menuOpen = false
  onMenuOpenChanged: {
    if (!menuOpen) feedbackOpen = false
    else checkPluginUpdate()
  }
  function setTrayWide(on) { persistSettings({ trayWide: on ? "On" : "Off" }) }
  function setShowCursor(on) { persistSettings({ showCursor: on ? "On" : "Off" }) }
  function setShowSuperGrok(on) { persistSettings({ showSuperGrok: on ? "On" : "Off" }) }

  function barText() {
    if (barLabel === "icon" || usedPct < 0) return ""
    if (barLabel === "percent" || !isFinite(periodEndMs)) return usedPct + "%"
    return usedPct + "% · " + shortDuration(periodEndMs - nowMs)
  }

  // Chart x-axis, identical to omarchy-grok-cursor-usage: "days" is a 2-day
  // span (now-1.8d .. now+0.2d, snapped to quarter-hours, with the same
  // start/end specials); "cycle" is first sample .. reset.
  readonly property string remainingAxis: {
    var value = String(setting("remainingAxis", "days")).trim().toLowerCase()
    if (value === "cycle" || value === "window" || value === "period" || value === "quota") return "cycle"
    return "days"
  }
  function persistSettings(values) {
    var entry = { id: root.moduleName }
    for (var existing in root.settings) if (existing !== "id") entry[existing] = root.settings[existing]
    for (var key in values) entry[key] = values[key]
    root.settings = entry
    if (root.bar && root.bar.shell && typeof root.bar.shell.updateEntryInline === "function")
      root.bar.shell.updateEntryInline(root.moduleName, entry)
  }
  function setRemainingAxis(value) {
    var next = String(value) === "cycle" ? "cycle" : "days"
    if (next !== root.remainingAxis) persistSettings({ remainingAxis: next })
  }

  // Same box as Bar.qml's openPanelIndicator and the reference widget.
  readonly property int remainingMeterThickness: Style.space(2)
  readonly property int remainingMeterInset: Style.space(2)
  readonly property real remainingMeterLength: {
    var slot = vertical ? implicitHeight : implicitWidth
    if (!(slot > 0)) slot = Style.bar.iconSlot
    return Math.max(Style.space(10), Math.round(slot * 0.55))
  }

  // ------------------------------------------------------------- data
  readonly property string stateHome: Quickshell.env("XDG_STATE_HOME") || ((Quickshell.env("HOME") || "") + "/.local/state")
  readonly property string dataDir: stateHome + "/omarchy/grokbot-usage"

  property var record: ({})
  property var historyPoints: []
  property double nowMs: Date.now()
  property bool collecting: collectProc.running

  readonly property var sand: (record && record.sand) ? record.sand : null
  readonly property var cursor: (record && record.cursor) ? record.cursor : null
  readonly property var supergrok: (record && record.supergrok) ? record.supergrok : null
  readonly property var app: (record && record.app) ? record.app : null
  readonly property var update: (record && record.update) ? record.update : null
  readonly property var usage: sand
  readonly property bool hasUsage: !!sand && sand.used !== null && sand.used !== undefined && sand.used !== "" && isFinite(Number(sand.used))
  readonly property bool signedOut: !!sand && sand.state === "signed-out"
  readonly property bool stale: !!sand && sand.state === "stale"
  readonly property bool empty: !sand || sand.state === "empty"
  readonly property bool loading: collecting && empty
  readonly property bool fresh: !!sand && sand.ok === true
  readonly property bool appOffline: !!app && app.running === false
  readonly property bool updateAvailable: !!update && update.available === true
  readonly property real faceOpacity: (stale ? 0.55 : 1) * (appOffline ? 0.5 : 1)
  readonly property real used: hasUsage ? clamp(Number(sand.used), 0, 1) : -1
  readonly property real remaining: used >= 0 ? 1 - used : -1
  readonly property int usedPct: used >= 0 ? Math.round(used * 100) : -1
  readonly property double periodEndMs: hasUsage && sand.resetsAt ? new Date(sand.resetsAt).getTime() : NaN
  readonly property double periodStartMs: {
    if (!hasUsage) return NaN
    var s = sand.periodStart ? new Date(sand.periodStart).getTime() : NaN
    if (isFinite(s)) return s
    return isFinite(periodEndMs) ? periodEndMs - 7 * 86400000 : NaN
  }
  readonly property real elapsed: (periodEndMs > periodStartMs)
    ? clamp((nowMs - periodStartMs) / (periodEndMs - periodStartMs), 0, 1) : -1
  // >0 means spending faster than an even burn.
  readonly property real paceDelta: (used >= 0 && elapsed >= 0) ? used - elapsed : 0
  readonly property string paceState: {
    if (used < 0) return "none"
    if (used >= 0.95 || paceDelta > 0.10) return "ahead"
    if (paceDelta > 0.02) return "near"
    return "ok"
  }
  readonly property color paceColor: paceState === "ahead" ? urgent : (paceState === "near" ? warn : foreground)

  readonly property var grokPoints: pointsOfSeries(historyPoints, "grokbot")
  readonly property var currentPoints: pointsForPeriod(grokPoints, hasUsage ? sand.resetsAt : "")
  readonly property var weekGroups: groupWeeks(grokPoints, historyWeeks, periodEndMs)
  readonly property var grokChartSeries: chartSeries(historyPoints, [["grokbot", "Grok Bot"]])
  readonly property var cursorChartSeries: chartSeries(historyPoints, [["cursor-auto", "Auto (included)"], ["cursor-api", "Third-party API"]])
  function superGrokName() {
    var tier = supergrok && supergrok.tierLabel ? String(supergrok.tierLabel).trim() : ""
    if (!tier) return "SuperGrok"
    if (tier.indexOf("SuperGrok") === 0) return tier
    return "SuperGrok " + tier
  }
  readonly property var supergrokChartSeries: chartSeries(historyPoints, [["supergrok", superGrokName()]])

  // ------------------------------------------------------------- helpers
  function clamp(v, lo, hi) { return Math.max(lo, Math.min(hi, v)) }
  function alpha(c, a) { return Qt.rgba(c.r, c.g, c.b, a) }
  function css(c, a) {
    var o = a === undefined ? c.a : a
    return "rgba(" + Math.round(c.r * 255) + "," + Math.round(c.g * 255) + "," + Math.round(c.b * 255) + "," + o + ")"
  }
  function colorHex(c) {
    function byte(n) { var h = Math.max(0, Math.min(255, Math.round(n * 255))).toString(16); return h.length < 2 ? "0" + h : h }
    return "#" + byte(c.r) + byte(c.g) + byte(c.b)
  }
  // Grok Bot app mark (round face, two slanted oval eyes) as a one-colour
  // symbolic icon; the eyes are even-odd holes so the bar shows through.
  function grokSvg(c, style) {
    var hex = colorHex(c)
    var svg
    if (style === "outline") {
      svg = '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none">'
        + '<circle cx="12" cy="12" r="10.2" stroke="' + hex + '" stroke-width="1.4"/>'
        + '<path stroke="' + hex + '" stroke-width="1.2" stroke-linecap="round" d="M11.20 8.89 L12.60 12.29 M14.80 7.19 L16.20 10.59"/>'
        + '</svg>'
    } else {
      svg = '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24">'
        + '<path fill="' + hex + '" fill-rule="evenodd" d="M12 1.5 A10.5 10.5 0 1 1 11.99 1.5 Z M11.20 8.89 L12.60 12.29 A1.3 1.3 0 0 0 15.00 11.31 L13.60 7.91 A1.3 1.3 0 0 0 11.20 8.89 Z M14.80 7.19 L16.20 10.59 A1.3 1.3 0 0 0 18.60 9.61 L17.20 6.21 A1.3 1.3 0 0 0 14.80 7.19 Z"/>'
        + '</svg>'
    }
    return "data:image/svg+xml;utf8," + encodeURIComponent(svg)
  }

  function collectPath() {
    var url = Qt.resolvedUrl("collect.py").toString()
    if (url.indexOf("file://") === 0) return decodeURIComponent(url.substring(7))
    return url
  }
  function runCollect(force) {
    if (collectProc.running) return
    collectProc.command = force
      ? ["python3", collectPath(), "usage", "--force"]
      : ["python3", collectPath(), "usage", "--due", String(Math.max(30, root.refreshIntervalSec - 20))]
    collectProc.running = true
  }
  function runTick() {
    if (tickProc.running) return
    tickProc.command = ["python3", collectPath(), "tick"]
    tickProc.running = true
  }
  function launchApp() {
    launchProc.command = ["python3", collectPath(), "launch"]
    launchProc.running = true
    tickSoon.restart()
  }
  function refreshNow() { runCollect(true) }
  function openDashboard() {
    var url = hasUsage && sand.dashboardUrl ? String(sand.dashboardUrl) : "https://cursor.com/dashboard/spending"
    Quickshell.execDetached(["xdg-open", url])
  }
  function siblingFile(name) {
    var path = collectPath()
    var slash = path.lastIndexOf("/")
    return (slash >= 0 ? path.substring(0, slash + 1) : "") + name
  }
  function updateScript() { return siblingFile("update-grok-bot.sh") }
  function openIssuePage() {
    Quickshell.execDetached(["xdg-open", "https://github.com/songlairui/omarchy-grokbot-usage/issues/new?template=feedback.yml"])
  }
  function draftFeedback() {
    var script = siblingFile("feedback-via-agent.sh").replace(/'/g, "'\\''")
    if (root.bar) root.bar.run("omarchy-launch-floating-terminal-with-presentation '" + script + "'")
  }
  function checkPluginUpdate() {
    if (pluginCheck.running) return
    pluginCheck.command = ["bash", siblingFile("check-plugin-update.sh")]
    pluginCheck.running = true
  }
  function updatePlugin() {
    if (root.bar) root.bar.run("omarchy-launch-floating-terminal-with-presentation 'omarchy plugin update songlairui.grokbot-usage --yes'")
  }
  function openUpdate() {
    var script = updateScript().replace(/'/g, "'\\''")
    if (root.bar) root.bar.run("omarchy-launch-floating-terminal-with-presentation '" + script + "'")
  }

  function parseRecord(text) {
    try {
      var parsed = JSON.parse(String(text || ""))
      root.record = parsed && typeof parsed === "object" ? parsed : ({})
    } catch (e) { /* keep the last good record on a torn read */ }
  }
  function parseHistory(text) {
    try {
      var parsed = JSON.parse(String(text || ""))
      root.historyPoints = parsed && parsed.points && parsed.points.length !== undefined ? parsed.points : []
    } catch (e) { }
  }

  function pointsOfSeries(points, id) {
    var out = []
    for (var i = 0; i < points.length; i++) {
      var p = points[i]
      if (String(p.series || "grokbot") === id) out.push(p)
    }
    return out
  }
  // Reference-format series: { id, title, points:[{t, until, remaining, startsAt, resetsAt}] }
  function chartSeries(points, defs) {
    var list = []
    for (var d = 0; d < defs.length; d++) {
      var src = pointsOfSeries(points, defs[d][0])
      if (!src.length) continue
      var pts = []
      for (var i = 0; i < src.length; i++)
        pts.push({ t: src[i].t, until: src[i].until, remaining: 1 - Number(src[i].used),
                   startsAt: src[i].periodStart, resetsAt: src[i].resetsAt })
      list.push({ id: defs[d][0], title: defs[d][1], points: pts })
    }
    return list
  }

  function pointsForPeriod(points, resetsAt) {
    var out = []
    if (!resetsAt) return out
    var key = new Date(resetsAt).getTime()
    for (var i = 0; i < points.length; i++) {
      var p = points[i]
      if (new Date(p.resetsAt).getTime() !== key) continue
      out.push({ t: new Date(p.t).getTime(), until: new Date(p.until || p.t).getTime(), used: Number(p.used) })
    }
    out.sort(function(a, b) { return a.t - b.t })
    return out
  }

  // [{ key, start, end, points:[{t,until,used}] (absolute ms), last, current }]
  function groupWeeks(points, limit, currentEnd) {
    var map = {}
    var order = []
    for (var i = 0; i < points.length; i++) {
      var p = points[i]
      var end = new Date(p.resetsAt).getTime()
      if (!isFinite(end)) continue
      if (!map[end]) {
        var start = p.periodStart ? new Date(p.periodStart).getTime() : NaN
        if (!isFinite(start)) start = end - 7 * 86400000
        map[end] = { key: end, start: start, end: end, points: [], last: 0, current: false }
        order.push(end)
      }
      map[end].points.push({ t: new Date(p.t).getTime(), until: new Date(p.until || p.t).getTime(), used: Number(p.used) })
    }
    order.sort(function(a, b) { return a - b })
    var groups = []
    for (var j = 0; j < order.length; j++) {
      var g = map[order[j]]
      g.points.sort(function(a, b) { return a.t - b.t })
      g.last = g.points.length ? g.points[g.points.length - 1].used : 0
      g.current = isFinite(currentEnd) && g.end === currentEnd
      groups.push(g)
    }
    return groups.slice(Math.max(0, groups.length - limit))
  }

  function usedAt(points, t) {
    var v = NaN
    for (var i = 0; i < points.length; i++) {
      if (points[i].t > t) break
      v = points[i].used
    }
    return v
  }

  function formatDuration(ms) {
    if (!(ms > 0)) return "now"
    var m = Math.floor(ms / 60000), h = Math.floor(m / 60), d = Math.floor(h / 24)
    if (d >= 1) return d + "d " + (h - d * 24) + "h"
    if (h >= 1) return h + "h " + (m - h * 60) + "m"
    return Math.max(1, m) + "m"
  }
  function shortDuration(ms) {
    if (!(ms > 0)) return "0m"
    var m = Math.floor(ms / 60000), h = Math.floor(m / 60), d = Math.floor(h / 24)
    if (d >= 1) return d + "d"
    if (h >= 1) return h + "h"
    return Math.max(1, m) + "m"
  }
  function pad(n) { return n < 10 ? "0" + n : "" + n }
  function clock(ms) {
    if (!isFinite(ms)) return "—"
    var d = new Date(ms)
    return (d.getMonth() + 1) + "/" + d.getDate() + " " + pad(d.getHours()) + ":" + pad(d.getMinutes())
  }
  function weekdayShort(ms) { return ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"][new Date(ms).getDay()] }

  function resetText() {
    if (!isFinite(periodEndMs)) return ""
    return "resets in " + formatDuration(periodEndMs - nowMs) + " · " + weekdayShort(periodEndMs) + " " + clock(periodEndMs)
  }
  function paceText() {
    if (used < 0) return ""
    if (elapsed < 0.03) return "Week just started"
    var diff = Math.round(Math.abs(paceDelta) * 100)
    var head = diff < 2 ? "On even pace" : (paceDelta > 0 ? diff + "% below even pace" : diff + "% above even pace")
    return head
  }
  function tooltip() {
    if (signedOut) return "Grok Bot usage: " + ((sand && sand.error) ? sand.error : "signed out")
    if (!hasUsage) return (sand && sand.error) ? "Grok Bot usage: " + sand.error : "Grok Bot usage: loading…"
    var t = "Grok Bot · " + (100 - usedPct) + "% left (" + usedPct + "% used) · " + resetText()
    if (stale) t += "\nLast reading " + clock(new Date(sand.fetchedAt).getTime()) + " (" + (sand.error || "refresh failed") + ")"
    if (appOffline) t += "\nGrok Bot is not running. Click, then Start."
    if (updateAvailable && update && update.latest) t += "\nUpdate " + update.latest + " available"
    return t
  }
  function footerText() {
    return sand && sand.fetchedAt ? "updated " + clock(new Date(sand.fetchedAt).getTime()) : ""
  }
  function planText() {
    if (!hasUsage) return ""
    var bits = []
    if (sand.planLabel) bits.push(sand.planLabel)
    if (sand.cursorPlan) bits.push("Cursor " + sand.cursorPlan)
    if (sand.billingBrand && String(sand.billingBrand).indexOf("GROK") >= 0) bits.push("via SuperGrok")
    return bits.join(" · ")
  }
  function formatTokens(n) {
    var v = Number(n)
    if (v >= 1e9) return (v / 1e9).toFixed(1) + "B"
    if (v >= 1e6) return (v / 1e6).toFixed(1) + "M"
    if (v >= 1e3) return (v / 1e3).toFixed(1) + "k"
    return String(Math.round(v))
  }

  // ------------------------------------------------------------- io
  FileView {
    path: root.dataDir + "/usage.json"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.parseRecord(text())
  }
  FileView {
    path: root.dataDir + "/history.json"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.parseHistory(text())
  }

  Timer {
    interval: root.opened ? 1000 : 30000
    running: true
    repeat: true
    onTriggered: root.nowMs = Date.now()
  }
  Timer {
    interval: root.refreshIntervalSec * 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.runCollect(false)
  }
  Timer {
    interval: 10000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.runTick()
  }
  Timer {
    id: tickSoon
    interval: 1500
    repeat: false
    onTriggered: root.runTick()
  }
  Process {
    id: collectProc
    running: false
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: if (text.trim() !== "") console.warn("grokbot-usage", text.trim())
    }
  }
  Process {
    id: tickProc
    running: false
  }
  Process {
    id: launchProc
    running: false
  }
  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function toggle(): void { root.toggle() }
    function menu(): string { root.close(); root.menuOpen = !root.menuOpen; return root.menuOpen ? "open" : "closed" }
    function toggleWide(): string { var next = !root.trayWide; root.setTrayWide(next); return next ? "wide" : "compact" }
    function refresh(): string { root.refreshNow(); return "ok" }
    function launch(): string { root.launchApp(); return "ok" }
    function toggleHistory(): string { root.historyShown = !root.historyShown; return root.historyShown ? "on" : "off" }
    function toggleCursor(): string { var next = !root.showCursor; root.setShowCursor(next); return next ? "on" : "off" }
    function toggleSuperGrok(): string { var next = !root.showSuperGrok; root.setShowSuperGrok(next); return next ? "on" : "off" }
  }

  // ------------------------------------------------------------- bar
  implicitWidth: button.visible ? button.implicitWidth : 0
  implicitHeight: button.visible ? button.implicitHeight : 0

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    labelVisible: false
    hasVisualContent: true
    active: root.paceState === "ahead"
    dimmed: root.empty && !root.collecting
    tooltipText: root.tooltip()
    horizontalMargin: 6
    clip: true
    fixedWidth: root.vertical ? -1
      : (root.trayWide ? Math.max(Style.bar.iconSlot, barRow.implicitWidth + Style.space(12)) : Style.bar.iconSlot)
    fixedHeight: root.vertical && root.trayWide ? Style.bar.iconSlot + Style.space(6) : -1
    onPressed: function(code) {
      if (code === Qt.MiddleButton) { root.refreshNow(); return }
      if (code === Qt.RightButton) {
        root.close()
        root.menuOpen = !root.menuOpen
        return
      }
      root.menuOpen = false
      root.toggle()
    }

    // compact
    Item {
      visible: !root.trayWide
      anchors.centerIn: parent
      width: Style.bar.iconCanvas
      height: Style.bar.iconCanvas
      Image {
        anchors.fill: parent
        sourceSize.width: 64
        sourceSize.height: 64
        fillMode: Image.PreserveAspectFit
        smooth: true
        cache: false
        opacity: root.faceOpacity
        source: root.grokSvg(root.paceState === "ahead" ? root.urgent : root.foreground, root.signedOut ? "outline" : "solid")
      }
      Rectangle {
        visible: root.appOffline
        width: parent.width * 0.55
        height: 1.5
        radius: 1
        rotation: -38
        anchors.centerIn: parent
        color: root.foreground
        opacity: 0.85
      }
      Rectangle {
        visible: root.updateAvailable
        width: 7
        height: 7
        radius: 4
        anchors.bottom: parent.bottom
        anchors.left: parent.left
        color: root.urgent
        border.width: 1
        border.color: root.bar ? root.bar.background : root.foreground
      }
    }

    // wide
    Row {
      id: barRow
      visible: root.trayWide
      anchors.centerIn: parent
      spacing: Style.space(5)
      Item {
        anchors.verticalCenter: parent.verticalCenter
        width: Style.bar.iconCanvas - 2
        height: width
        Image {
          anchors.fill: parent
          sourceSize.width: 64
          sourceSize.height: 64
          fillMode: Image.PreserveAspectFit
          smooth: true
          cache: false
          opacity: root.faceOpacity
          source: root.grokSvg(root.paceState === "ahead" ? root.urgent : root.foreground, root.signedOut ? "outline" : "solid")
        }
        Rectangle {
          visible: root.appOffline
          width: parent.width * 0.55
          height: 1.5
          radius: 1
          rotation: -38
          anchors.centerIn: parent
          color: root.foreground
          opacity: 0.85
        }
        Rectangle {
          visible: root.updateAvailable
          width: 7
          height: 7
          radius: 4
          anchors.bottom: parent.bottom
          anchors.left: parent.left
          color: root.urgent
          border.width: 1
          border.color: root.bar ? root.bar.background : root.foreground
        }
      }
      Text {
        visible: !root.vertical && text !== ""
        anchors.verticalCenter: parent.verticalCenter
        text: root.barText()
        color: root.paceState === "ahead" ? root.urgent : root.foreground
        opacity: root.faceOpacity
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        renderType: Text.NativeRendering
      }
    }

    // Remaining meter: same geometry and colours as the reference widget's
    // logo-on-bar meter; the fill follows pace (amber / red when ahead).
    Item {
      id: meter
      readonly property real leftover: root.remaining
      readonly property color leftColor: (leftover >= 0 && leftover <= 0.1) ? root.urgent : root.paceColor
      visible: opacity > 0 && leftover >= 0 && !root.signedOut
      opacity: root.opened ? 0 : 1
      readonly property real length: root.trayWide && !root.vertical
        ? Math.max(Style.space(12), Math.round(barRow.implicitWidth))
        : root.remainingMeterLength
      width: root.vertical ? root.remainingMeterThickness : length
      height: root.vertical ? length : root.remainingMeterThickness
      x: root.vertical
        ? (root.barPosition === "left" ? parent.width - width - root.remainingMeterInset : root.remainingMeterInset)
        : Math.round((parent.width - width) / 2)
      y: root.vertical
        ? Math.round((parent.height - height) / 2)
        : (root.barPosition === "top" ? parent.height - height - root.remainingMeterInset : root.remainingMeterInset)
      Behavior on opacity { NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }
      readonly property real radius: Math.min(width, height) / 2

      Rectangle { anchors.fill: parent; radius: meter.radius; color: root.alpha(root.foreground, 0.22) }
      Rectangle {
        anchors.left: parent.left; anchors.top: parent.top; anchors.bottom: parent.bottom
        width: Math.max(0, parent.width * Math.max(0, meter.leftover))
        radius: meter.radius
        color: meter.leftColor
        opacity: root.stale ? 0.55 : 1
      }
      Rectangle {
        anchors.left: parent.left; anchors.top: parent.top; anchors.bottom: parent.bottom
        width: 1; radius: meter.radius > 0 ? 1 : 0; color: meter.leftColor
      }
      Rectangle {
        anchors.right: parent.right; anchors.top: parent.top; anchors.bottom: parent.bottom
        width: 1; radius: meter.radius > 0 ? 1 : 0
        color: meter.leftover >= 1 ? meter.leftColor : root.alpha(root.foreground, 0.55)
      }
      // wide only: even-pace tick, where "remaining" would sit at an even burn
      Rectangle {
        visible: root.trayWide && root.elapsed >= 0.03
        color: root.alpha(root.foreground, 0.85)
        width: root.vertical ? meter.width + 2 : 1
        height: root.vertical ? 1 : meter.height + 2
        x: root.vertical ? -1 : meter.width * (1 - root.elapsed)
        y: root.vertical ? meter.height * root.elapsed : -1
      }
    }
  }

  // ------------------------------------------------------------- popup
  PopupCard {
    id: menuPopup
    anchorItem: button
    // Own owner so an outside click / another popout closes only the menu.
    owner: QtObject { function close() { root.menuOpen = false } }
    bar: root.bar
    open: root.menuOpen
    padding: Style.space(6)
    contentWidth: menuPopup.fittedContentWidth(Style.space(260))
    contentHeight: menuPopup.fittedContentHeight(menuColumn.implicitHeight)

    Column {
      id: menuColumn
      anchors.fill: parent
      spacing: 0

      MenuRow { label: root.appOffline ? "Start Grok Bot" : "Open Grok Bot"; onTriggered: root.launchApp() }
      MenuRow { label: "Open Cursor spending page"; onTriggered: root.openDashboard() }
      MenuRow {
        label: root.collecting ? "Refreshing…" : "Refresh"
        enabled: !root.collecting
        onTriggered: root.refreshNow()
      }
      MenuRow {
        label: "Show Cursor"
        checkable: true
        checked: root.showCursor
        onTriggered: root.setShowCursor(!root.showCursor)
      }
      MenuRow {
        label: "Show " + root.superGrokName()
        checkable: true
        checked: root.showSuperGrok
        onTriggered: root.setShowSuperGrok(!root.showSuperGrok)
      }
      MenuRow {
        label: "Wide tray"
        checkable: true
        checked: root.trayWide
        onTriggered: root.setTrayWide(!root.trayWide)
      }
      PanelSeparator { foreground: root.foreground }
      MenuRow {
        label: root.feedbackOpen ? "Feedback" : "Feedback…"
        closes: false
        onTriggered: root.feedbackOpen = !root.feedbackOpen
      }
      MenuRow {
        visible: root.feedbackOpen
        label: "Open issue page"
        indent: Style.space(14)
        onTriggered: root.openIssuePage()
      }
      MenuRow {
        visible: root.feedbackOpen
        label: "Draft with agent"
        indent: Style.space(14)
        onTriggered: root.draftFeedback()
      }
      MenuRow {
        visible: root.pluginBehind
        label: "Update plugin"
        onTriggered: root.updatePlugin()
      }
      Text {
        width: menuColumn.width
        leftPadding: Style.space(10)
        topPadding: Style.space(4)
        bottomPadding: Style.space(2)
        text: root.pluginVersion !== "" ? ("v" + root.pluginVersion + (root.pluginBehind ? " · update available" : "")) : ""
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }
    }
  }

  FileView {
    id: manifestView
    path: root.siblingFile("manifest.json")
    onLoaded: {
      try {
        var parsed = JSON.parse(text())
        if (parsed && parsed.version) root.pluginVersion = String(parsed.version)
      } catch (e) {}
    }
  }
  Process {
    id: pluginCheck
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.pluginBehind = text.trim() === "behind"
    }
  }

  component MenuRow: Item {
    id: menuRow
    property string label: ""
    property bool enabled: true
    property bool checkable: false
    property bool checked: false
    property bool closes: true
    property int indent: 0
    signal triggered()

    width: menuColumn.width
    implicitHeight: visible ? Style.space(30) : 0
    height: implicitHeight
    opacity: enabled ? 1 : 0.45

    Rectangle {
      anchors.fill: parent
      radius: Math.max(2, Style.cornerRadius)
      color: menuMouse.containsMouse && menuRow.enabled ? root.alpha(root.foreground, 0.08) : "transparent"
    }
    Text {
      anchors.verticalCenter: parent.verticalCenter
      anchors.left: parent.left
      anchors.leftMargin: Style.space(10) + menuRow.indent
      anchors.right: menuCheck.left
      text: menuRow.label
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      elide: Text.ElideRight
    }
    Text {
      id: menuCheck
      anchors.verticalCenter: parent.verticalCenter
      anchors.right: parent.right
      anchors.rightMargin: Style.space(10)
      visible: menuRow.checkable
      text: menuRow.checked ? "On" : "Off"
      color: menuRow.checked ? root.foreground : root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }
    MouseArea {
      id: menuMouse
      anchors.fill: parent
      hoverEnabled: true
      enabled: menuRow.enabled
      cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
      onClicked: {
        menuRow.triggered()
        if (menuRow.closes) root.menuOpen = false
      }
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(440))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onActivateRequested: root.refreshNow()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (t === "r" || t === "R") root.refreshNow()
        if (t === "o" || t === "O") root.openDashboard()
        if (t === "h" || t === "H") root.historyShown = !root.historyShown
      }

      Flickable {
        id: flick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: column
          width: flick.width
          spacing: Style.space(8)

          // Hero ------------------------------------------------------
          Item {
            width: parent.width
            implicitHeight: Math.max(heroLeft.implicitHeight, heroRight.implicitHeight)

            Row {
              id: heroLeft
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(10)
              Image {
                anchors.verticalCenter: parent.verticalCenter
                width: Style.font.display
                height: width
                sourceSize.width: 96
                sourceSize.height: 96
                fillMode: Image.PreserveAspectFit
                source: root.grokSvg(root.foreground, root.signedOut ? "outline" : "solid")
              }
              Column {
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(2)
                Text {
                  text: "Grok Bot"
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.title
                }
                Text {
                  text: root.planText() || "Weekly usage"
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }
              }
            }

            Column {
              id: heroRight
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(2)
              Text {
                anchors.right: parent.right
                text: root.usedPct >= 0 ? (100 - root.usedPct) + "%" : "—"
                color: root.paceColor
                font.family: root.fontFamily
                font.pixelSize: Style.font.displayLarge
              }
              Text {
                anchors.right: parent.right
                text: root.usedPct >= 0 ? "left · " + root.usedPct + "% used" : ""
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
            }
          }

          Rectangle {
            visible: root.appOffline
            width: parent.width
            height: startLabel.implicitHeight + Style.space(10)
            radius: 4
            color: startArea.containsMouse ? root.alpha(root.foreground, 0.14) : root.alpha(root.foreground, 0.08)
            border.width: 1
            border.color: root.alpha(root.foreground, startArea.containsMouse ? 0.55 : 0.35)
            Text {
              id: startLabel
              anchors.centerIn: parent
              text: "Start Grok Bot"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }
            MouseArea {
              id: startArea
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.launchApp()
            }
          }

          Rectangle {
            visible: root.updateAvailable
            width: parent.width
            height: updateLabel.implicitHeight + Style.space(10)
            radius: 4
            color: updateArea.containsMouse ? root.alpha(root.urgent, 0.22) : root.alpha(root.urgent, 0.12)
            border.width: 1
            border.color: root.alpha(root.urgent, updateArea.containsMouse ? 0.7 : 0.45)
            Text {
              id: updateLabel
              anchors.centerIn: parent
              text: "Update Grok Bot" + (root.update && root.update.latest ? " to " + root.update.latest : "")
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }
            MouseArea {
              id: updateArea
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.openUpdate()
            }
          }

          Column {
            width: parent.width
            spacing: Style.space(3)
            visible: root.hasUsage
            Text {
              width: parent.width
              text: root.resetText()
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.WordWrap
            }
            Text {
              width: parent.width
              text: root.paceText()
              color: root.paceState === "ok" ? root.dim : root.paceColor
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.WordWrap
            }
          }

          Text {
            visible: !root.hasUsage || root.stale || root.signedOut
            width: parent.width
            wrapMode: Text.WordWrap
            color: root.stale ? root.warn : root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            text: root.signedOut
              ? ((root.sand && root.sand.error) ? root.sand.error : "Sign in to Cursor.")
                + (root.hasUsage && root.sand && root.sand.fetchedAt
                   ? " Last reading before sign-out · " + root.clock(new Date(root.sand.fetchedAt).getTime())
                   : "")
              : (root.stale
                ? "Showing the last good reading. " + ((root.sand && root.sand.error) || "Refresh failed.")
                : (root.loading ? "Fetching Grok Bot usage…" : ((root.sand && root.sand.error) || "No data yet.")))
          }

          // Chart range (2 days / Cycle), same control as the reference ----
          Item {
            width: parent.width
            implicitHeight: Math.max(axisLabel.implicitHeight, axisGroup.implicitHeight)
            Text {
              id: axisLabel
              text: "Chart range"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
            }
            ButtonGroup {
              id: axisGroup
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              foreground: root.foreground
              fontFamily: root.fontFamily
              fontSize: Style.font.caption
              focusable: false
              value: root.remainingAxis
              options: [
                { value: "days", label: "2 days" },
                { value: "cycle", label: "Cycle" }
              ]
              onChanged: function(v) { root.setRemainingAxis(v) }
            }
          }

          // Grok Bot weekly ------------------------------------------
          RemainingChart {
            width: parent.width
            visible: root.grokChartSeries.length > 0
            series: root.grokChartSeries
            title: "Grok Bot remaining"
            hint: "Steeper drop = faster spend"
          }

          RemainingChart {
            width: parent.width
            visible: root.showSuperGrok && root.supergrokChartSeries.length > 0
            series: root.supergrokChartSeries
            title: root.superGrokName() + " remaining"
            hint: root.supergrok && root.supergrok.authProblem ? String(root.supergrok.error || "Run grok login") : ""
          }

          RemainingChart {
            width: parent.width
            visible: root.showCursor && root.cursorChartSeries.length > 0
            series: root.cursorChartSeries
            title: "Cursor" + (root.hasUsage && root.sand.cursorPlan ? " " + root.sand.cursorPlan : "") + " remaining"
            hint: root.cursorSummary()
          }

          // Chart 2: weeks overlaid ---------------------------------
          Text {
            visible: root.weekGroups.length > 1
            text: (root.historyShown ? "▾ Hide" : "▸ Show") + " last " + root.weekGroups.length + " weeks"
            color: histToggle.containsMouse ? root.foreground : root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            MouseArea {
              id: histToggle
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.historyShown = !root.historyShown
            }
          }
          SectionTitle {
            visible: root.historyShown && root.weekGroups.length > 1
            title: "Last " + root.weekGroups.length + " weeks"
            hint: "remaining by day of the week"
          }
          HistoryChart { width: parent.width; height: Style.space(84); visible: root.historyShown && root.weekGroups.length > 1 }
          Flow {
            visible: root.historyShown && root.weekGroups.length > 1
            width: parent.width
            spacing: Style.space(10)
            Repeater {
              model: root.weekGroups.slice().reverse()
              Row {
                required property var modelData
                required property int index
                spacing: Style.space(4)
                Rectangle {
                  anchors.verticalCenter: parent.verticalCenter
                  width: Style.space(10); height: 2; radius: 1
                  color: modelData.current ? root.foreground
                    : root.alpha(root.foreground, root.historyAlpha(index - (root.weekGroups.length > 0 && root.weekGroups[root.weekGroups.length - 1].current ? 1 : 0), root.weekGroups.length))
                }
                Text {
                  text: (modelData.current ? "this week" : root.weekLabel(modelData)) + " " + Math.round((1 - modelData.last) * 100) + "% left"
                  color: modelData.current ? root.foreground : root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }
              }
            }
          }

          // Optional: grok-bot-* rows from Cursor usage events -------
          Column {
            visible: !!(root.sand && root.sand.categories && root.sand.categories.length > 0)
            width: parent.width
            spacing: Style.space(3)
            SectionTitle { title: "Usage rows"; hint: "Cursor events · grok-bot-*" }
            Repeater {
              model: (root.sand && root.sand.categories) || []
              Item {
                required property var modelData
                width: column.width
                implicitHeight: catName.implicitHeight
                Text {
                  id: catName
                  text: String(modelData.id).replace("grok-bot-", "")
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }
                Text {
                  anchors.right: parent.right
                  text: root.formatTokens(modelData.tokens) + " tok · $" + (Number(modelData.cents) / 100).toFixed(2)
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }
              }
            }
          }

          // Footer: last update time + the one refresh button. The interval
          // timer keeps refreshing in the background as a fallback.
          Item {
            width: parent.width
            implicitHeight: Math.max(updatedText.implicitHeight, refreshButton.height) + Style.space(2)
            Text {
              id: updatedText
              anchors.left: parent.left
              anchors.verticalCenter: refreshButton.verticalCenter
              text: root.footerText()
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
            Rectangle {
              id: refreshButton
              anchors.right: parent.right
              anchors.bottom: parent.bottom
              width: refreshLabel.implicitWidth + Style.space(16)
              height: refreshLabel.implicitHeight + Style.space(8)
              radius: 4
              color: refreshArea.containsMouse && !root.collecting ? root.alpha(root.foreground, 0.14) : "transparent"
              border.width: 1
              border.color: root.alpha(root.foreground, refreshArea.containsMouse ? 0.5 : 0.28)
              Text {
                id: refreshLabel
                anchors.centerIn: parent
                text: root.collecting ? "Refreshing…" : "Refresh"
                color: root.collecting ? root.dim : root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
              MouseArea {
                id: refreshArea
                anchors.fill: parent
                hoverEnabled: true
                enabled: !root.collecting
                cursorShape: Qt.PointingHandCursor
                onClicked: root.refreshNow()
              }
            }
          }
        }
      }
    }
  }


  function cursorSummary() {
    if (!cursor) return ""
    var bits = []
    if (cursor.autoUsed !== null && cursor.autoUsed !== undefined) bits.push("Auto " + Math.round((1 - cursor.autoUsed) * 100) + "%")
    if (cursor.apiUsed !== null && cursor.apiUsed !== undefined) bits.push("API " + Math.round((1 - cursor.apiUsed) * 100) + "%")
    var end = cursor.resetsAt ? new Date(cursor.resetsAt).getTime() : NaN
    if (isFinite(end)) bits.push("resets " + clock(end))
    return bits.join(" · ")
  }

  // ---- ported verbatim from omarchy-grok-cursor-usage (plugin/Panel.qml) ----
  function remainingParseMs(value) {
    var text = String(value || "").trim()
    if (text === "") return NaN
    text = text.replace(/(\.\d{3})\d+/, "$1")
    text = text.replace(/([+-]\d{2}):(\d{2})$/, "$1$2")
    var ms = Date.parse(text)
    if (isFinite(ms)) return ms
    var d = new Date(String(value || ""))
    return isNaN(d.getTime()) ? NaN : d.getTime()
  }

  function remainingExpand(entry, nowMs) {
    var pts = []
    var raw = entry && entry.points ? entry.points : []
    if (!isFinite(nowMs)) nowMs = Date.now()
    for (var i = 0; i < raw.length; i++) {
      var p = raw[i] || {}
      var t = remainingParseMs(p.t)
      var y = Number(p.remaining)
      if (!isFinite(t) || !isFinite(y) || t > nowMs) continue
      y = root.clamp(y, 0, 1)
      var winStart = remainingParseMs(p.startsAt)
      var winReset = remainingParseMs(p.resetsAt)
      pts.push({ t: t, y: y, startsAt: winStart, resetsAt: winReset })
      var until = remainingParseMs(p.until)
      if (isFinite(until) && until > t) {
        if (until > nowMs) until = nowMs
        if (until > t) pts.push({ t: until, y: y, startsAt: winStart, resetsAt: winReset })
      }
    }
    if (pts.length === 0) return pts
    if (pts[pts.length - 1].t < nowMs)
      pts.push({
        t: nowMs,
        y: pts[pts.length - 1].y,
        startsAt: pts[pts.length - 1].startsAt,
        resetsAt: pts[pts.length - 1].resetsAt
      })
    return pts
  }

  function remainingClipToWindow(pts, tMin, tMax) {
    if (!pts || pts.length === 0) return []
    if (!(tMax > tMin)) return pts
    var out = []
    var hold = null
    for (var i = 0; i < pts.length; i++) {
      var t = pts[i].t
      var y = pts[i].y
      if (t < tMin) {
        var reset = pts[i].resetsAt
        var start = pts[i].startsAt
        var covers = (!isFinite(reset) || reset > tMin) && (!isFinite(start) || start <= tMin)
        if (covers) hold = y
        continue
      }
      if (t > tMax) {
        if (out.length === 0 && hold !== null)
          out.push({ t: tMin, y: hold })
        if (out.length > 0 && out[out.length - 1].t < tMax)
          out.push({ t: tMax, y: out[out.length - 1].y })
        else if (out.length === 0 && hold !== null)
          out.push({ t: tMax, y: hold })
        return out
      }
      if (out.length === 0 && hold !== null && t > tMin)
        out.push({ t: tMin, y: hold })
      out.push({ t: t, y: y })
    }
    if (out.length === 0 && hold !== null) {
      out.push({ t: tMin, y: hold })
      if (tMax > tMin) out.push({ t: tMax, y: hold })
    }
    return out
  }

  function remainingSnapQuarter(ms, ceil) {
    var d = new Date(ms)
    if (isNaN(d.getTime())) return ms
    var remainder = d.getMinutes() * 60000 + d.getSeconds() * 1000 + d.getMilliseconds()
    var q = 15 * 60000
    var hourStart = d.getTime() - remainder
    if (ceil) return remainder === 0 ? hourStart : hourStart + Math.ceil(remainder / q) * q
    return hourStart + Math.floor(remainder / q) * q
  }

  function remainingCurrentWindow(series, nowMs) {
    if (!isFinite(nowMs)) nowMs = Date.now()
    var start = NaN, reset = NaN
    var list = series || []
    for (var s = 0; s < list.length; s++) {
      var raw = list[s] && list[s].points ? list[s].points : []
      for (var i = 0; i < raw.length; i++) {
        var p = raw[i] || {}
        var winStart = remainingParseMs(p.startsAt)
        var winReset = remainingParseMs(p.resetsAt)
        if (!isFinite(winStart) || winStart > nowMs) continue
        if (!isFinite(start) || winStart >= start) {
          start = winStart
          if (isFinite(winReset)) reset = winReset
        }
      }
    }
    return { start: start, reset: reset }
  }

  function remainingSoonestReset(series, nowMs) {
    var window = remainingCurrentWindow(series, nowMs)
    return isFinite(window.reset) ? window.reset : NaN
  }

  function remainingFirstValueMs(series, afterMs, nowMs) {
    if (!isFinite(nowMs)) nowMs = Date.now()
    if (!isFinite(afterMs)) afterMs = -Infinity
    var first = Infinity
    var list = series || []
    for (var s = 0; s < list.length; s++) {
      var raw = list[s] && list[s].points ? list[s].points : []
      for (var i = 0; i < raw.length; i++) {
        var t = remainingParseMs(raw[i] && raw[i].t)
        if (!isFinite(t) || t < afterMs || t > nowMs) continue
        if (t < first) first = t
      }
    }
    return isFinite(first) ? first : NaN
  }

  function remainingBounds(series, nowMs, mode) {
    if (!isFinite(nowMs)) nowMs = Date.now()
    var window = remainingCurrentWindow(series, nowMs)
    var first = remainingFirstValueMs(series, window.start, nowMs)
    var day = 86400000
    if (mode === "cycle") {
      // Cycle = this series' own quota period: period start -> reset
      // (Grok Bot: currentPeriodStart -> nextResetTimestampUtc, weekly;
      // Cursor: billingCycleStart -> billingCycleEnd, monthly). Each chart
      // passes only its own series, so ranges and ticks are independent.
      // Falls back to the first sample only when the period start is unknown.
      var cMin = isFinite(window.start) ? window.start
        : (isFinite(first) ? remainingSnapQuarter(first, false) : nowMs - 3600 * 1000)
      var cMax = isFinite(window.reset) && window.reset > cMin
        ? window.reset
        : Math.max(nowMs, cMin + 3600 * 1000)
      if (cMax < nowMs) cMax = nowMs
      return { min: cMin, max: cMax }
    }
    var tMin0 = remainingSnapQuarter(nowMs - 1.8 * day, false)
    var tMax0 = remainingSnapQuarter(nowMs + 0.2 * day, true)
    var startSpecial = isFinite(window.start) && window.start > tMin0 && window.start <= nowMs
    var endSpecial = isFinite(window.reset) && window.reset > nowMs && window.reset - nowMs < 2 * day
    var edge = remainingSnapQuarter(isFinite(first) ? first : window.start, false)
    var tMin, tMax
    if (startSpecial && endSpecial) {
      tMin = isFinite(edge) ? edge : tMin0
      tMax = window.reset
    } else if (startSpecial) {
      tMin = isFinite(edge) ? edge : tMin0
      tMax = tMin + 2 * day
    } else if (endSpecial) {
      tMax = window.reset
      tMin = remainingSnapQuarter(tMax - 2 * day, false)
    } else {
      tMin = tMin0
      tMax = tMax0
    }
    if (!(tMax > tMin)) tMax = tMin + 15 * 60000
    if (tMax < nowMs) tMax = remainingSnapQuarter(nowMs, true)
    return { min: tMin, max: tMax }
  }

  function remainingTick(ms) {
    var d = new Date(ms)
    if (isNaN(d.getTime())) return ""
    function pad(n) { return n < 10 ? "0" + n : "" + n }
    return (d.getMonth() + 1) + "/" + d.getDate() + " " + pad(d.getHours()) + ":" + pad(d.getMinutes())
  }

  function remainingValueAt(entry, targetMs, nowMs, bounds) {
    if (!entry || !bounds || !isFinite(targetMs) || !isFinite(nowMs)) return null
    var dataMax = Math.min(nowMs, Number(bounds.max))
    if (targetMs > dataMax || targetMs < Number(bounds.min)) return null
    var pts = remainingClipToWindow(remainingExpand(entry, nowMs), Number(bounds.min), dataMax)
    if (pts.length === 0 || targetMs < pts[0].t) return null
    var prev = pts[0]
    for (var i = 1; i < pts.length; i++) {
      var next = pts[i]
      if (targetMs > next.t) {
        prev = next
        continue
      }
      if (next.t <= prev.t)
        return { y: next.y, estimated: false }
      var ratio = root.clamp((targetMs - prev.t) / (next.t - prev.t), 0, 1)
      return {
        y: prev.y + (next.y - prev.y) * ratio,
        estimated: Math.abs(next.y - prev.y) > 0.00005 && ratio > 0 && ratio < 1
      }
    }
    return targetMs <= prev.t ? { y: prev.y, estimated: false } : null
  }

  function remainingValuesAt(series, targetMs, nowMs, bounds) {
    var values = []
    var list = series || []
    for (var i = 0; i < list.length; i++) {
      var value = remainingValueAt(list[i], targetMs, nowMs, bounds)
      if (!value) continue
      values.push({
        series: i,
        title: String((list[i] && (list[i].title || list[i].id)) || ("Limit " + (i + 1))),
        y: value.y,
        estimated: value.estimated
      })
    }
    return values
  }

  function remainingPercentText(value) {
    var pct = Math.round(root.clamp(Number(value), 0, 1) * 1000) / 10
    return Math.abs(pct - Math.round(pct)) < 0.05 ? Math.round(pct) + "%" : pct.toFixed(1) + "%"
  }

  // Reference layout, minus the now / reset markers (user request): per
  // series a polyline + fill, plus one even-burn pace line over the window.
  function remainingPlotLayout(series, width, height, nowMs, mode) {
    var w = Math.max(1, Number(width) || 1)
    var h = Math.max(1, Number(height) || 1)
    var left = 36, right = 8, top = 10, bottom = 10
    var plotW = Math.max(1, w - left - right)
    var plotH = Math.max(1, h - top - bottom)
    var yZero = top + plotH
    if (!isFinite(nowMs)) nowMs = Date.now()
    var bounds = remainingBounds(series, nowMs, mode)
    var span = bounds.max - bounds.min
    if (!(span > 0)) span = 1
    function mapX(t) { return left + plotW * ((t - bounds.min) / span) }
    function mapY(y) { return top + plotH * (1 - y) }
    var xNow = mapX(Math.min(Math.max(nowMs, bounds.min), bounds.max))
    var dataMax = Math.min(nowMs, bounds.max)
    var polys = []
    var list = series || []
    for (var s = 0; s < list.length; s++) {
      var pts = remainingClipToWindow(remainingExpand(list[s], nowMs), bounds.min, dataMax)
      if (pts.length === 1)
        pts = [pts[0], { t: Math.min(nowMs, dataMax), y: pts[0].y }]
      if (pts.length === 0) continue
      var xy = []
      for (var i = 0; i < pts.length; i++)
        xy.push({ x: Math.min(mapX(pts[i].t), xNow), y: mapY(pts[i].y) })
      if (xy.length >= 2 && Math.abs(xy[xy.length - 1].x - xy[0].x) < 0.8)
        xy = [xy[0], { x: Math.max(xy[0].x + 0.8, xNow), y: xy[0].y }]
      polys.push({ series: s, points: xy })
    }
    var resetX = -1
    var resetAt = remainingSoonestReset(series, nowMs)
    if (isFinite(resetAt) && resetAt >= bounds.min && resetAt <= bounds.max)
      resetX = Math.min(Math.max(mapX(resetAt), left), left + plotW - 1)
    var pace = null
    var win = remainingCurrentWindow(series, nowMs)
    if (isFinite(win.start) && isFinite(win.reset) && win.reset > win.start) {
      var tPace0 = Math.max(bounds.min, win.start)
      var tPace1 = Math.min(bounds.max, win.reset)
      if (tPace1 > tPace0) {
        pace = {
          x0: mapX(tPace0), y0: mapY(root.clamp(1 - (tPace0 - win.start) / (win.reset - win.start), 0, 1)),
          x1: mapX(tPace1), y1: mapY(root.clamp(1 - (tPace1 - win.start) / (win.reset - win.start), 0, 1)),
          t0: tPace0, t1: tPace1
        }
      }
    }
    return { polys: polys, yZero: yZero, nowX: xNow, resetX: resetX, pace: pace }
  }
  // ---- end of port ----

  function historyAlpha(ageIndex, count) {
    // ageIndex 0 = newest past week
    return Math.max(0.16, 0.55 - ageIndex * (0.39 / Math.max(1, count - 1)))
  }
  function weekLabel(g) {
    var d = new Date(g.start)
    return (d.getMonth() + 1) + "/" + d.getDate()
  }

  // ------------------------------------------------------------- components
  component SectionTitle: Item {
    property string title: ""
    property string hint: ""
    width: column.width
    implicitHeight: Math.max(stTitle.implicitHeight, stHint.implicitHeight)
    Text {
      id: stTitle
      text: parent.title
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
    }
    Text {
      id: stHint
      anchors.right: parent.right
      anchors.verticalCenter: stTitle.verticalCenter
      text: parent.hint
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }
  }

  // Remaining-over-time chart. Axis bounds, ticks, y range, margins, fills,
  // line weights, pace dashes and hover read-out follow
  // omarchy-grok-cursor-usage's RemainingChart. Left out on request: the
  // now / reset markers and any projection ray.
  component RemainingChart: Column {
    id: chart
    property var series: []
    property string title: "Remaining"
    property string hint: ""
    spacing: Style.space(2)

    Item {
      width: parent.width
      implicitHeight: Math.max(rcTitle.implicitHeight, rcHint.implicitHeight)
      Text {
        id: rcTitle
        text: chart.title
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
      }
      Text {
        id: rcHint
        text: chart.hint
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
      }
    }

    Item {
      id: plot
      width: parent.width
      height: Style.space(68)
      clip: true
      readonly property real plotLeft: 36
      readonly property real plotRight: 8
      readonly property real plotTop: 10
      readonly property real plotBottom: 10
      readonly property var plotLayout: root.remainingPlotLayout(chart.series, width, height, root.nowMs, root.remainingAxis)
      readonly property var hoverBounds: root.remainingBounds(chart.series, root.nowMs, root.remainingAxis)
      readonly property bool hoverActive: chartHover.containsMouse
        && chartHover.mouseX >= plotLeft && chartHover.mouseX <= width - plotRight
      readonly property real hoverX: hoverActive ? chartHover.mouseX : -1
      readonly property real hoverTimeMs: {
        if (!hoverActive) return NaN
        var span = Number(hoverBounds.max) - Number(hoverBounds.min)
        var ratio = root.clamp((hoverX - plotLeft) / Math.max(1, width - plotLeft - plotRight), 0, 1)
        return Number(hoverBounds.min) + ratio * span
      }
      readonly property var hoverValues: hoverActive
        ? root.remainingValuesAt(chart.series, hoverTimeMs, root.nowMs, hoverBounds) : []
      readonly property bool hoverHasValues: hoverValues.length > 0

      function yForHover(value) {
        return plotTop + Math.max(1, height - plotTop - plotBottom) * (1 - root.clamp(Number(value), 0, 1))
      }
      function labelYForHover(index, labelHeight) {
        if (index < 0 || index >= hoverValues.length) return plotTop
        var gap = Style.space(4)
        var lineY = yForHover(hoverValues[index].y)
        var y = lineY - labelHeight - gap
        if (y < plotTop) y = lineY + gap
        y = root.clamp(y, plotTop, height - plotBottom - labelHeight)
        if (index > 0) {
          var previousY = labelYForHover(index - 1, labelHeight)
          if (Math.abs(y - previousY) < labelHeight) {
            var below = lineY + gap
            y = below + labelHeight <= height - plotBottom ? below : Math.max(plotTop, previousY - labelHeight)
          }
        }
        return y
      }

      Rectangle {
        anchors.fill: parent
        radius: 4
        color: root.alpha(root.foreground, 0.08)
      }

      Repeater {
        model: [0, 0.5, 1]
        Rectangle {
          required property var modelData
          width: plot.width - 44
          height: 1
          x: 36
          y: 10 + (plot.height - 20) * (1 - Number(modelData))
          color: root.alpha(root.foreground, 0.18)
        }
      }
      Text { text: "100%"; x: 2; y: 2; color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption }
      Text { text: "50%"; x: 2; anchors.verticalCenter: parent.verticalCenter; color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption }
      Text { text: "0%"; x: 2; anchors.bottom: parent.bottom; anchors.bottomMargin: 2; color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption }

      Canvas {
        anchors.fill: parent
        renderStrategy: Canvas.Cooperative
        readonly property var layoutData: plot.plotLayout
        onLayoutDataChanged: requestPaint()
        onWidthChanged: requestPaint()
        onHeightChanged: requestPaint()

        onPaint: {
          var ctx = getContext("2d")
          ctx.reset()
          ctx.clearRect(0, 0, width, height)
          var L = layoutData || {}
          var fg = root.foreground
          var polys = L.polys || []
          var yZero = Number(L.yZero)
          // fills (series 0 stronger)
          for (var s = 0; s < polys.length; s++) {
            var pts = polys[s].points
            if (pts.length < 2) continue
            ctx.beginPath()
            ctx.moveTo(pts[0].x, yZero)
            for (var i = 0; i < pts.length; i++) ctx.lineTo(pts[i].x, pts[i].y)
            ctx.lineTo(pts[pts.length - 1].x, yZero)
            ctx.closePath()
            ctx.fillStyle = root.css(fg, polys[s].series === 0 ? 0.12 : 0.06)
            ctx.fill()
          }
          // even-burn pace: red 4/3 dashes fading along the line and after now
          var P = L.pace
          if (P) {
            var dx = P.x1 - P.x0, dy = P.y1 - P.y0
            var plen = Math.sqrt(dx * dx + dy * dy)
            ctx.lineWidth = 1
            for (var pos = 0; plen >= 2 && pos < plen; pos += 7) {
              var seg = Math.min(4, plen - pos)
              if (seg < 0.8) continue
              var along = (pos + seg / 2) / plen
              var tDash = P.t0 + along * (P.t1 - P.t0)
              var aAlong = 0.9 * (1 - along) + 0.16 * along
              var aFuture = 1
              if (tDash > root.nowMs && P.t1 > root.nowMs)
                aFuture = 0.28 + 0.72 * (1 - (tDash - root.nowMs) / (P.t1 - root.nowMs))
              ctx.strokeStyle = root.css(root.urgent, root.clamp(aAlong * aFuture, 0.1, 0.92))
              ctx.beginPath()
              ctx.moveTo(P.x0 + dx / plen * pos, P.y0 + dy / plen * pos)
              ctx.lineTo(P.x0 + dx / plen * (pos + seg), P.y0 + dy / plen * (pos + seg))
              ctx.stroke()
            }
          }
          // lines + step dots
          for (var k = 0; k < polys.length; k++) {
            var q = polys[k].points
            var col = polys[k].series === 0 ? root.css(fg, 1) : root.css(fg, 0.62)
            ctx.strokeStyle = col
            ctx.fillStyle = col
            ctx.lineWidth = 1
            ctx.beginPath()
            ctx.moveTo(q[0].x, q[0].y)
            for (var j = 1; j < q.length; j++) ctx.lineTo(q[j].x, q[j].y)
            ctx.stroke()
            for (var d = 0; d < q.length; d++) {
              if (d === 0 || d === q.length - 1 || q[d].y !== q[d - 1].y) {
                ctx.beginPath(); ctx.arc(q[d].x, q[d].y, 0.6, 0, Math.PI * 2); ctx.fill()
              }
            }
          }
        }
      }

      Rectangle {
        visible: plot.hoverActive && plot.hoverHasValues
        x: Math.round(plot.hoverX)
        y: plot.plotTop
        width: 1
        height: plot.height - plot.plotTop - plot.plotBottom
        color: root.alpha(root.foreground, 0.58)
      }
      Repeater {
        model: plot.hoverValues
        Rectangle {
          required property var modelData
          width: Style.space(5)
          height: width
          radius: width / 2
          x: plot.hoverX - width / 2
          y: plot.yForHover(modelData.y) - height / 2
          color: Number(modelData.series) === 0 ? root.foreground : root.alpha(root.foreground, 0.7)
          border.width: 1
          border.color: Color.background
        }
      }
      MouseArea {
        id: chartHover
        anchors.fill: parent
        hoverEnabled: true
        acceptedButtons: Qt.NoButton
        cursorShape: plot.hoverActive ? Qt.CrossCursor : Qt.ArrowCursor
      }
      Repeater {
        model: plot.hoverValues
        Text {
          required property var modelData
          required property int index
          visible: plot.hoverActive && plot.hoverHasValues
          text: (modelData.estimated ? "~" : "") + root.remainingPercentText(modelData.y)
          color: Number(modelData.series) === 0 ? root.foreground : root.alpha(root.foreground, 0.72)
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          font.bold: true
          x: {
            var gap = Style.space(6)
            var beside = plot.hoverX + gap
            if (beside + implicitWidth > plot.width - plot.plotRight)
              beside = plot.hoverX - implicitWidth - gap
            return Math.max(plot.plotLeft, beside)
          }
          y: plot.labelYForHover(index, implicitHeight)
        }
      }
    }

    // X-axis ticks, as in the reference: window start, "now", "reset", end.
    Item {
      width: parent.width
      implicitHeight: Style.font.caption + 2
      Text {
        id: startTick
        text: root.remainingTick(root.remainingBounds(chart.series, root.nowMs, root.remainingAxis).min)
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        anchors.left: parent.left
        visible: !(plot.hoverActive && nowTick.overlapsStart)
      }
      Text {
        id: nowTick
        readonly property real nowX: plot.plotLayout && plot.plotLayout.nowX ? Number(plot.plotLayout.nowX) : -1
        readonly property real gap: Style.space(8)
        readonly property bool overlapsStart: nowX >= 0 && (nowX - implicitWidth / 2) < (startTick.implicitWidth + gap)
        readonly property bool overlapsEnd: nowX >= 0 && (nowX + implicitWidth / 2) > (parent.width - endTick.implicitWidth - gap)
        readonly property bool clearOfEnds: nowX > 0 && !overlapsStart && !overlapsEnd
        visible: nowX > 0 && (plot.hoverActive || clearOfEnds)
        text: "now"
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        x: nowX - implicitWidth / 2
      }
      Text {
        readonly property real resetX: plot.plotLayout && plot.plotLayout.resetX > 0 ? Number(plot.plotLayout.resetX) : -1
        readonly property real nowX: plot.plotLayout && plot.plotLayout.nowX ? Number(plot.plotLayout.nowX) : -1
        visible: resetX > 72 && resetX < parent.width - 80 && Math.abs(resetX - nowX) > 48 && !(plot.hoverActive && nowTick.overlapsEnd)
        text: "reset"
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        x: resetX - implicitWidth / 2
      }
      Text {
        id: endTick
        text: root.remainingTick(root.remainingBounds(chart.series, root.nowMs, root.remainingAxis).max)
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        anchors.right: parent.right
        visible: !(plot.hoverActive && nowTick.overlapsEnd)
      }
    }

    Flow {
      visible: !!(chart.series && chart.series.length > 1)
      width: parent.width
      spacing: Style.space(10)
      Repeater {
        model: chart.series
        Row {
          required property var modelData
          required property int index
          spacing: Style.space(4)
          Rectangle {
            width: Style.space(12)
            height: 1
            anchors.verticalCenter: parent.verticalCenter
            color: index === 0 ? root.foreground : root.alpha(root.foreground, 0.5)
          }
          Text {
            text: String((modelData && modelData.title) || "")
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }
      }
    }
  }

  component HistoryChart: Item {
    id: hc
    readonly property real padL: 36
    readonly property real padR: 8
    readonly property real padT: 10
    readonly property real padB: 10
    readonly property real plotW: Math.max(1, width - padL - padR)
    readonly property real plotH: Math.max(1, height - padT - padB)
    readonly property double span: 7 * 86400000

    Rectangle {
      anchors.fill: parent
      radius: 4
      color: root.alpha(root.foreground, 0.08)
    }
    Repeater {
      model: [0, 0.5, 1]
      Rectangle {
        required property var modelData
        x: hc.padL
        y: hc.padT + hc.plotH * (1 - Number(modelData))
        width: hc.plotW
        height: 1
        color: root.alpha(root.foreground, 0.18)
      }
    }
    Text { text: "100%"; x: 2; y: 2; color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption }
    Text { text: "50%"; x: 2; anchors.verticalCenter: parent.verticalCenter; color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption }
    Text { text: "0%"; x: 2; anchors.bottom: parent.bottom; anchors.bottomMargin: 2; color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption }

    Canvas {
      anchors.fill: parent
      renderStrategy: Canvas.Cooperative
      readonly property var groups: root.weekGroups
      readonly property double tick: Math.floor(root.nowMs / 300000)
      onGroupsChanged: requestPaint()
      onTickChanged: requestPaint()
      onWidthChanged: requestPaint()
      onHeightChanged: requestPaint()

      onPaint: {
        var ctx = getContext("2d")
        ctx.reset()
        ctx.clearRect(0, 0, width, height)
        var fg = root.foreground
        function X(rel) { return hc.padL + hc.plotW * root.clamp(rel / hc.span, 0, 1) }
        function Y(r) { return hc.padT + hc.plotH * (1 - root.clamp(r, 0, 1)) }

        // even-burn pace, red dashes 4/3 fading along the week
        var x0 = X(0), y0 = Y(1), x1 = X(hc.span), y1 = Y(0)
        var dx = x1 - x0, dy = y1 - y0, plen = Math.sqrt(dx * dx + dy * dy)
        ctx.lineWidth = 1
        for (var pos = 0; pos < plen; pos += 7) {
          var seg = Math.min(4, plen - pos)
          if (seg < 0.8) continue
          var along = (pos + seg / 2) / plen
          ctx.strokeStyle = root.css(root.urgent, root.clamp(0.9 * (1 - along) + 0.16 * along, 0.1, 0.92))
          ctx.beginPath()
          ctx.moveTo(x0 + dx / plen * pos, y0 + dy / plen * pos)
          ctx.lineTo(x0 + dx / plen * (pos + seg), y0 + dy / plen * (pos + seg))
          ctx.stroke()
        }

        var list = groups || []
        var lastCurrent = list.length > 0 && list[list.length - 1].current
        for (var g = 0; g < list.length; g++) {
          var grp = list[g]
          var pts = grp.points
          if (!pts.length) continue
          var age = list.length - 1 - g - (lastCurrent ? 1 : 0)
          var col = grp.current ? root.css(fg, 1) : root.css(fg, root.historyAlpha(Math.max(0, age), list.length))
          ctx.strokeStyle = col
          ctx.lineWidth = 1
          ctx.beginPath()
          ctx.moveTo(X(pts[0].t - grp.start), Y(1 - pts[0].used))
          for (var k = 0; k < pts.length; k++) {
            if (k > 0) ctx.lineTo(X(pts[k].t - grp.start), Y(1 - pts[k].used))
            var until = (grp.current && k === pts.length - 1 && root.fresh) ? Math.max(pts[k].until, root.nowMs) : pts[k].until
            ctx.lineTo(X(until - grp.start), Y(1 - pts[k].used))
          }
          ctx.stroke()
        }
      }
    }
  }
}
