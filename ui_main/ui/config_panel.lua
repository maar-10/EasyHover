--[[ The config panel -- the upward-facing monitor, bottom right.

     Its MAIN page is reserved for values worth having on screen for the whole flight, so it
     shows live flight state now and gains more as later phases land. Everything you configure
     lives in a submenu:

       MONITORS  assign which UI renders on which monitor (including this one)
       DISK      save and load every config to a floppy
       FLIGHT    the flight-control settings

     The monitor assignment page is the bootstrap problem solved: it is reachable from this
     panel AND from the computer's own terminal, so a cockpit with nothing assigned yet is
     never a dead end.
]]

local Theme = require("ui.theme")
local Util = require("shared.util")
local UiConfig = require("lib.config")

local ConfigPanel = {}

local MIN_WIDTH, MIN_HEIGHT = 18, 10

--- opts = { cfg, actions, monitors, log, savePanels }
--- actions = { configSet, configSave, diskSave, diskLoad, setFeel, setLateral, setAssist }
function ConfigPanel.build(frame, opts)
  local cfg, actions = opts.cfg, opts.actions
  local width, height = frame:getWidth(), frame:getHeight()
  frame:setBackground(Theme.bg)

  if width < MIN_WIDTH or height < MIN_HEIGHT then
    Theme.line(frame, 1, width, "TOO SMALL", Theme.warning)
    Theme.line(frame, 2, width, ("%dx%d"):format(width, height), Theme.dim)
    return { update = function() end }
  end

  local pages = {}
  local function page()
    local p = frame:addFrame({ x = 1, y = 1, width = width, height = height,
      background = Theme.bg })
    p:setVisible(false)
    pages[#pages + 1] = p
    return p
  end

  local function show(target)
    for _, p in ipairs(pages) do p:setVisible(p == target) end
  end

  local home = page()
  local monitorPage = page()
  local diskPage = page()
  local flightPage = page()
  home:setVisible(true)

  local function backButton(parent)
    return Theme.button(parent, 1, height, 6, "BACK", function() show(home) end)
  end

  -- ---------------------------------------------------------------- home

  local y = 1
  Theme.line(home, y, width, Theme.centre("EASYHOVER  CONFIG", width), Theme.accent); y = y + 1
  local homeStale = Theme.staleBanner(home, y, width)
  local homeStatus = Theme.line(home, y, width, "", Theme.dim); y = y + 1
  Theme.rule(home, y, width); y = y + 1

  -- Live values worth having up the whole flight. More arrive with later phases.
  local liveLines = {}
  for _ = 1, math.min(5, height - 6) do
    liveLines[#liveLines + 1] = Theme.line(home, y, width, "", Theme.fg)
    y = y + 1
  end

  local alarmLine = Theme.line(home, math.min(y, height - 2), width, "", Theme.dim)

  local buttonRow = height - 1
  local third = math.max(6, math.floor((width - 2) / 3))
  Theme.button(home, 1, buttonRow, third, "MONITORS", function() show(monitorPage) end)
  Theme.button(home, third + 2, buttonRow, math.min(6, third), "DISK", function() show(diskPage) end)
  Theme.button(home, math.min(width - 6, third * 2 + 3), buttonRow, 7, "FLIGHT",
    function() show(flightPage) end)

  -- ---------------------------------------------------------------- monitors

  Theme.line(monitorPage, 1, width, Theme.centre("MONITOR ASSIGNMENT", width), Theme.accent)
  Theme.rule(monitorPage, 2, width)
  Theme.line(monitorPage, 3, width, "tap to cycle panel", Theme.dim)

  local monitorRows = {}
  local rowStart = 4
  local maxRows = math.max(1, height - rowStart - 2)
  -- The click handler is registered ONCE here, not in refreshMonitorRows(). Basalt appends
  -- callbacks rather than replacing them, so re-registering on every refresh accumulated
  -- handlers and a single tap cycled the assignment several times. It reads row.name, which
  -- refresh updates, instead of closing over the name it happened to have at build time.
  local cycleAssignment
  for index = 1, maxRows do
    local rowY = rowStart + index - 1
    local label = Theme.line(monitorPage, rowY, width - 8, "", Theme.fg)
    local row = { label = label, name = nil }
    row.button = Theme.button(monitorPage, width - 7, rowY, 8, "--", function()
      if row.name then cycleAssignment(row.name) end
    end)
    monitorRows[index] = row
  end

  --- Cycle a monitor through: unassigned -> overhead -> config -> pfd -> autopilot -> nav ->
  --- unassigned. Saving happens immediately, because a half-made assignment that is lost on
  --- reboot is worse than one you have to undo.
  local CYCLE = { "overhead", "config", "pfd", "autopilot", "nav" }
  function cycleAssignment(monitorName)
    local current = UiConfig.panelFor(cfg, monitorName)
    local nextPanel = CYCLE[1]
    if current then
      for i, name in ipairs(CYCLE) do
        if name == current then
          nextPanel = CYCLE[i + 1]      -- nil past the end = unassign
          break
        end
      end
    end
    if nextPanel == nil then
      UiConfig.unassign(cfg, monitorName)
    else
      UiConfig.assign(cfg, nextPanel, monitorName)
    end
    opts.savePanels()
  end

  local function refreshMonitorRows()
    local available = opts.monitors:available()
    for index, row in ipairs(monitorRows) do
      local entry = available[index]
      if entry then
        row.name = entry.name
        local size = (entry.width and entry.height)
          and ("%dx%d"):format(entry.width, entry.height) or "?"
        row.label:setText(Theme.fit(("%s %s"):format(entry.name, size), width - 9))
        local panel = UiConfig.panelFor(cfg, entry.name) or "none"
        row.button:setText(Theme.fit(panel, 8))
        row.button:setBackground(panel == "none" and Theme.buttonBg or Theme.accent)
        row.button:setForeground(panel == "none" and Theme.buttonFg or colours.black)
        row.button:setVisible(true)
        row.label:setVisible(true)
      else
        row.name = nil
        row.label:setVisible(false)
        row.button:setVisible(false)
      end
    end
  end
  refreshMonitorRows()

  Theme.button(monitorPage, width - 8, height, 9, "RESCAN", function()
    refreshMonitorRows()
  end)
  backButton(monitorPage)

  -- ---------------------------------------------------------------- disk

  Theme.line(diskPage, 1, width, Theme.centre("CONFIG DISK", width), Theme.accent)
  Theme.rule(diskPage, 2, width)
  local diskStatus = Theme.line(diskPage, 3, width, "--", Theme.dim)
  local diskLocal = Theme.line(diskPage, 4, width, "", Theme.dim)
  local diskResult = Theme.line(diskPage, 6, width, "", Theme.fg)

  Theme.button(diskPage, 1, height - 2, math.min(10, width - 2), "SAVE ALL", function()
    diskResult:setText("saving...")
    actions.diskSave()
  end)
  Theme.button(diskPage, 1, height - 1, math.min(10, width - 2), "LOAD ALL", function()
    diskResult:setText("loading...")
    actions.diskLoad()
  end)
  backButton(diskPage)

  -- ---------------------------------------------------------------- flight

  Theme.line(flightPage, 1, width, Theme.centre("FLIGHT CONTROL", width), Theme.accent)
  Theme.rule(flightPage, 2, width)

  local fy = 3
  local rows = {}
  --- One tunable per row: name, live value, and -/+ that send a configSet to the craft.
  local function tunable(label, path, step, minimum, maximum, decimals)
    if fy > height - 3 then return nil end
    local nameLabel = Theme.line(flightPage, fy, math.max(1, width - 12), label, Theme.dim)
    local valueLabel = frame and Theme.line(flightPage, fy, width - 12, "", Theme.fg) or nil
    valueLabel:setText("")
    local row = { path = path, value = nil, decimals = decimals or 0 }
    local function nudge(delta)
      if type(row.value) ~= "number" then return end
      local next = Util.clamp(row.value + delta, minimum, maximum)
      if next ~= row.value then actions.configSet(path, next) end
    end
    Theme.button(flightPage, width - 11, fy, 4, "-", function() nudge(-step) end)
    Theme.button(flightPage, width - 6, fy, 4, "+", function() nudge(step) end)
    row.display = nameLabel
    row.name = label
    row.set = function(value)
      row.value = value
      nameLabel:setText(Theme.fit(("%s %s"):format(label,
        type(value) == "number" and Util.num(value, row.decimals) or "--"), width - 12))
    end
    fy = fy + 1
    rows[#rows + 1] = row
    return row
  end

  local bankRow = tunable("bank", "envelope.maxBankDeg", 1, 1, 45, 0)
  local pitchRow = tunable("pitch", "envelope.maxPitchDeg", 1, 1, 45, 0)
  local climbRow = tunable("climb", "envelope.maxClimbRate", 0.5, 0.5, 20, 1)
  local sinkRow = tunable("sink", "envelope.maxSinkRate", 0.5, 0.5, 20, 1)
  local yawRow = tunable("yaw", "envelope.maxYawRateDps", 5, 5, 180, 0)
  local brakeRow = tunable("brake tilt", "brake.maxTiltDeg", 1, 1, 45, 0)

  Theme.button(flightPage, width - 9, height, 10, "SAVE CFG", function()
    actions.configSave()
  end)
  backButton(flightPage)

  -- ---------------------------------------------------------------- update

  local function update(model)
    local t = model.telemetry
    homeStale:setVisible(model.stale)
    homeStatus:setVisible(not model.stale)

    if model.stale then
      homeStale:setText(Theme.centre(model.ageMs == math.huge and "NO LINK" or "NO DATA", width))
      for _, line in ipairs(liveLines) do line:setText("") end
      alarmLine:setText("")
    else
      homeStatus:setText(Theme.fit(("%s  %s/%s"):format(tostring(t.mode or "--"),
        tostring((t.modes or {}).feel or "-"), tostring((t.modes or {}).lateral or "-")), width))

      local altitude = t.altitude or {}
      local attitude = t.attitude or {}
      local velocity = t.velocity or {}
      local values = {
        ("ALT  %s  VS %s"):format(Util.num(altitude.baro, 1), Util.num(altitude.vs, 1)),
        ("PIT  %s  ROL %s"):format(Util.num(attitude.pitch, 1), Util.num(attitude.roll, 1)),
        ("SPD  %s"):format(Util.num(velocity.horizontal or velocity.scalar, 1)),
        ("THR  %s"):format(Util.num(((t.modes or {}).throttle or 0) * 100, 0) .. "%"),
        ("FUEL %s"):format(Util.pct((t.fuel or {}).worstTank) and
          (Util.pct((t.fuel or {}).worstTank) .. "%") or "--"),
      }
      for index, line in ipairs(liveLines) do
        line:setText(Theme.fit(values[index] or "", width))
      end

      local alarms = t.alarms or {}
      if #alarms > 0 then
        alarmLine:setText(Theme.fit(("! " .. tostring(alarms[1].msg or alarms[1].key)), width))
        alarmLine:setForeground(alarms[1].level == "warning" and Theme.warning or Theme.caution)
      else
        alarmLine:setText("")
      end

      -- disk page
      local disk = t.disk or {}
      diskStatus:setText(Theme.fit(disk.diskPresent
        and ("disk: " .. tostring(disk.label or "unlabelled")) or "no disk in drive", width))
      diskStatus:setForeground(disk.diskPresent and Theme.ok or Theme.dim)
      diskLocal:setText(Theme.fit(("on disk %s / here %s")
        :format(tostring(disk.onDisk or 0), tostring(disk.localConfigs or 0)), width))

      -- flight page mirrors the craft's live config
      local liveCfg = t.config or {}
      if bankRow then bankRow.set(liveCfg.maxBankDeg) end
      if pitchRow then pitchRow.set(liveCfg.maxPitchDeg) end
      if climbRow then climbRow.set(liveCfg.maxClimbRate) end
      if sinkRow then sinkRow.set(liveCfg.maxSinkRate) end
      if yawRow then yawRow.set(liveCfg.maxYawRateDps) end
      if brakeRow then brakeRow.set(liveCfg.brakeMaxTiltDeg) end
    end

    -- an acknowledgement from the craft, shown on whichever page asked for it
    if opts.lastAck and opts.lastAck() then
      local ack = opts.lastAck()
      if ack.cmd == "diskSave" or ack.cmd == "diskLoad" then
        local detail = ack.detail or {}
        local text
        if ack.ack then
          text = ("%d saved %d loaded"):format(#(detail.saved or {}), #(detail.loaded or {}))
        else
          text = tostring(detail.reason or detail.error or "failed")
        end
        diskResult:setText(Theme.fit(text, width))
        diskResult:setForeground(ack.ack and Theme.ok or Theme.warning)
      end
    end
  end

  return {
    update = update,
    refreshMonitors = refreshMonitorRows,
    show = show,
    pages = { home = home, monitors = monitorPage, disk = diskPage, flight = flightPage },
    elements = {
      status = homeStatus, stale = homeStale, live = liveLines, alarm = alarmLine,
      diskStatus = diskStatus, diskLocal = diskLocal, diskResult = diskResult,
      monitorRows = monitorRows, bank = bankRow, pitch = pitchRow,
    },
  }
end

return ConfigPanel
