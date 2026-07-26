--[[ The config panel -- the upward-facing monitor, bottom right.

     Its MAIN page carries values worth having on screen for the whole flight; everything you
     configure lives in a submenu:

       MON    assign which UI renders on which monitor (including this one)
       HW     assign the engine relay, the fuel tank and the engine vault
       DISK   save and load every config to a floppy
       FLT    the flight-control limits

     IT HAS TO FIT A 1x1 MONITOR. At text scale 0.5 that is 15x10 characters, which is what the
     first dry run actually had assigned -- and the old 18x10 minimum meant every screen just
     said TOO SMALL. So the layout is computed from the real size: buttons stack into a grid,
     labels shorten, and the live-value block takes whatever rows are left.

     Monitor assignment is reachable from this panel AND from the computer's own terminal, so a
     cockpit with nothing assigned yet is never a dead end.
]]

local Theme = require("ui.theme")
local Util = require("shared.util")
local UiConfig = require("lib.config")
local Hardware = require("ui.hardware")

local ConfigPanel = {}

-- A 1x1 monitor at scale 0.5 is 15x10. Anything smaller genuinely cannot carry a menu.
local MIN_WIDTH, MIN_HEIGHT = 14, 9

--- opts = { cfg, actions, monitors, log, savePanels, lastAck }
function ConfigPanel.build(frame, opts)
  local cfg, actions = opts.cfg, opts.actions
  local width, height = frame:getWidth(), frame:getHeight()
  frame:setBackground(Theme.bg)

  if width < MIN_WIDTH or height < MIN_HEIGHT then
    Theme.line(frame, 1, width, "SCREEN TOO", Theme.warning)
    Theme.line(frame, 2, width, "SMALL", Theme.warning)
    Theme.line(frame, 3, width, ("%dx%d"):format(width, height), Theme.dim)
    Theme.line(frame, 4, width, ("need %dx%d"):format(MIN_WIDTH, MIN_HEIGHT), Theme.dim)
    return { update = function() end, elements = {} }
  end

  local narrow = width < 26

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
  local hardwarePage = page()
  local diskPage = page()
  local flightPage = page()
  home:setVisible(true)

  local function backButton(parent)
    return Theme.button(parent, 1, height, math.min(6, width), "BACK", function() show(home) end)
  end

  -- ---------------------------------------------------------------- home

  local y = 1
  Theme.line(home, y, width, Theme.centre(narrow and "CONFIG" or "EASYHOVER CONFIG", width),
    Theme.accent)
  y = y + 1
  local homeStale = Theme.staleBanner(home, y, width)
  local homeStatus = Theme.line(home, y, width, "", Theme.dim); y = y + 1

  -- Buttons occupy the bottom. Two rows of two when narrow, one row of four when there is room.
  local buttonRows = narrow and 2 or 1
  local liveRowCount = math.max(1, height - y - buttonRows - 1)
  local liveLines = {}
  for _ = 1, math.min(liveRowCount, 6) do
    liveLines[#liveLines + 1] = Theme.line(home, y, width, "", Theme.fg)
    y = y + 1
  end
  local alarmLine = Theme.line(home, math.min(y, height - buttonRows), width, "", Theme.dim)

  local menu = {
    { label = narrow and "MON" or "MONITORS", target = monitorPage },
    { label = narrow and "HW" or "HARDWARE", target = hardwarePage },
    { label = "DISK", target = diskPage },
    { label = narrow and "FLT" or "FLIGHT", target = flightPage },
  }
  if narrow then
    local half = math.floor((width - 1) / 2)
    for index, entry in ipairs(menu) do
      local col = (index - 1) % 2
      local rowOffset = math.floor((index - 1) / 2)
      Theme.button(home, 1 + col * (half + 1), height - 1 + rowOffset, half,
        entry.label, function() show(entry.target) end)
    end
  else
    local quarter = math.max(6, math.floor((width - 3) / 4))
    for index, entry in ipairs(menu) do
      Theme.button(home, 1 + (index - 1) * (quarter + 1), height, quarter,
        entry.label, function() show(entry.target) end)
    end
  end

  -- ---------------------------------------------------------------- monitors

  Theme.line(monitorPage, 1, width, Theme.centre(narrow and "MONITORS" or "MONITOR ASSIGNMENT",
    width), Theme.accent)
  Theme.line(monitorPage, 2, width, "tap to cycle", Theme.dim)

  local monitorRows = {}
  local rowStart = 3
  local maxRows = math.max(1, height - rowStart - 1)
  local tag = narrow and 7 or 9

  -- The click handler is registered ONCE here, not in refreshMonitorRows(). Basalt APPENDS
  -- callbacks rather than replacing them, so re-registering on every refresh accumulated
  -- handlers and one tap cycled the assignment several times. It reads row.name, which refresh
  -- updates, instead of closing over whatever name the row had at build time.
  local cycleAssignment
  local refreshMonitorRows
  for index = 1, maxRows do
    local rowY = rowStart + index - 1
    local label = Theme.line(monitorPage, rowY, math.max(1, width - tag - 1), "", Theme.fg)
    local row = { label = label, name = nil }
    row.button = Theme.button(monitorPage, width - tag, rowY, tag, "--", function()
      if row.name then cycleAssignment(row.name) end
    end)
    monitorRows[index] = row
  end

  --- none -> overhead -> config -> pfd -> autopilot -> nav -> none.
  --- Saves immediately: a half-made assignment lost on reboot is worse than one you undo.
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
    -- Redraw the rows NOW. The frames are reconciled a moment later by the app, but the label
    -- under your finger has to change on the tap -- the first dry run only saw it update when
    -- RESCAN was pressed, which is exactly what this fixes.
    refreshMonitorRows()
    opts.savePanels()
  end

  function refreshMonitorRows()
    local available = opts.monitors:available()
    for index, row in ipairs(monitorRows) do
      local entry = available[index]
      if entry then
        row.name = entry.name
        local size = (entry.width and entry.height)
          and ("%dx%d"):format(entry.width, entry.height) or "?"
        local shown = narrow and entry.name:gsub("^monitor_", "m") or entry.name
        row.label:setText(Theme.fit(("%s %s"):format(shown, size), width - tag - 1))
        local panel = UiConfig.panelFor(cfg, entry.name) or "none"
        row.button:setText(Theme.fit(panel, tag))
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

  Theme.button(monitorPage, math.max(1, width - 7), height, 8, "RESCAN", function()
    refreshMonitorRows()
  end)
  backButton(monitorPage)

  -- ---------------------------------------------------------------- hardware

  Theme.line(hardwarePage, 1, width, Theme.centre("HARDWARE", width), Theme.accent)
  local hardware = Hardware.build(hardwarePage, 1, 2, width, height - 2, opts)
  backButton(hardwarePage)

  -- ---------------------------------------------------------------- disk

  Theme.line(diskPage, 1, width, Theme.centre(narrow and "DISK" or "CONFIG DISK", width),
    Theme.accent)
  local diskStatus = Theme.line(diskPage, 2, width, "--", Theme.dim)
  local diskLocal = Theme.line(diskPage, 3, width, "", Theme.dim)
  local diskResult = Theme.line(diskPage, 4, width, "", Theme.fg)
  Theme.line(diskPage, 5, width, "all eh_*.tbl", Theme.dim)

  local diskButtonWidth = math.min(10, width - 1)
  Theme.button(diskPage, 1, height - 2, diskButtonWidth, "SAVE ALL", function()
    diskResult:setText("saving...")
    actions.diskSave()
  end)
  Theme.button(diskPage, 1, height - 1, diskButtonWidth, "LOAD ALL", function()
    diskResult:setText("loading...")
    actions.diskLoad()
  end)
  backButton(diskPage)

  -- ---------------------------------------------------------------- flight

  Theme.line(flightPage, 1, width, Theme.centre(narrow and "LIMITS" or "FLIGHT CONTROL", width),
    Theme.accent)

  local fy = 2
  local rows = {}
  --- One tunable per row: "name value" on the left, -/+ on the right. The buttons send a
  --- configSet, which the craft re-validates and can refuse.
  local function tunable(label, path, step, minimum, maximum, decimals)
    if fy > height - 1 then return nil end
    local buttonWidth = narrow and 3 or 4
    local textWidth = math.max(1, width - buttonWidth * 2 - 1)
    local nameLabel = Theme.line(flightPage, fy, textWidth, label, Theme.fg)
    local row = { path = path, value = nil, decimals = decimals or 0, display = nameLabel }
    local function nudge(delta)
      if type(row.value) ~= "number" then return end
      local next = Util.clamp(row.value + delta, minimum, maximum)
      if next ~= row.value then actions.configSet(path, next) end
    end
    Theme.button(flightPage, textWidth + 1, fy, buttonWidth, "-", function() nudge(-step) end)
    Theme.button(flightPage, textWidth + buttonWidth + 1, fy, buttonWidth, "+",
      function() nudge(step) end)
    row.set = function(value)
      row.value = value
      nameLabel:setText(Theme.fit(("%s %s"):format(label,
        type(value) == "number" and Util.num(value, row.decimals) or "--"), textWidth))
    end
    fy = fy + 1
    rows[#rows + 1] = row
    return row
  end

  local bankRow = tunable("bank", "envelope.maxBankDeg", 1, 1, 45, 0)
  local pitchRow = tunable("ptch", "envelope.maxPitchDeg", 1, 1, 45, 0)
  local climbRow = tunable("clmb", "envelope.maxClimbRate", 0.5, 0.5, 20, 1)
  local sinkRow = tunable("sink", "envelope.maxSinkRate", 0.5, 0.5, 20, 1)
  local yawRow = tunable("yaw", "envelope.maxYawRateDps", 5, 5, 180, 0)
  local brakeRow = tunable("brake", "brake.maxTiltDeg", 1, 1, 45, 0)

  Theme.button(flightPage, math.max(1, width - 5), height, 6, "SAVE", function()
    actions.configSave()
  end)
  backButton(flightPage)

  -- ---------------------------------------------------------------- update

  local function update(model)
    local t = model.telemetry
    homeStale:setVisible(model.stale)
    homeStatus:setVisible(not model.stale)
    hardware.update(model)

    if model.stale then
      homeStale:setText(Theme.centre(model.ageMs == math.huge and "NO LINK" or "NO DATA", width))
      for _, line in ipairs(liveLines) do line:setText("") end
      alarmLine:setText("")
      return
    end

    homeStatus:setText(Theme.fit(("%s %s/%s"):format(tostring(t.mode or "--"),
      tostring((t.modes or {}).feel or "-"):sub(1, 3),
      tostring((t.modes or {}).lateral or "-"):sub(1, 4)), width))

    local altitude = t.altitude or {}
    local attitude = t.attitude or {}
    local velocity = t.velocity or {}
    local values = {
      ("ALT %s"):format(Util.num(altitude.baro, 1)),
      ("VS  %s"):format(Util.num(altitude.vs, 1)),
      ("P%s R%s"):format(Util.num(attitude.pitch, 1), Util.num(attitude.roll, 1)),
      ("SPD %s"):format(Util.num(velocity.horizontal or velocity.scalar, 1)),
      ("THR %s%%"):format(Util.num(((t.modes or {}).throttle or 0) * 100, 0)),
      ("FUEL %s"):format(Util.pct((t.fuel or {}).worstTank)
        and (Util.pct((t.fuel or {}).worstTank) .. "%") or "--"),
    }
    for index, line in ipairs(liveLines) do
      line:setText(Theme.fit(values[index] or "", width))
    end

    local alarms = t.alarms or {}
    if #alarms > 0 then
      alarmLine:setText(Theme.fit("! " .. tostring(alarms[1].msg or alarms[1].key), width))
      alarmLine:setForeground(alarms[1].level == "warning" and Theme.warning or Theme.caution)
    else
      alarmLine:setText("")
    end

    local disk = t.disk or {}
    diskStatus:setText(Theme.fit(disk.diskPresent
      and ("disk " .. tostring(disk.label or "unnamed")) or "no disk", width))
    diskStatus:setForeground(disk.diskPresent and Theme.ok or Theme.dim)
    diskLocal:setText(Theme.fit(("disk %s here %s")
      :format(tostring(disk.onDisk or 0), tostring(disk.localConfigs or 0)), width))

    local liveCfg = t.config or {}
    if bankRow then bankRow.set(liveCfg.maxBankDeg) end
    if pitchRow then pitchRow.set(liveCfg.maxPitchDeg) end
    if climbRow then climbRow.set(liveCfg.maxClimbRate) end
    if sinkRow then sinkRow.set(liveCfg.maxSinkRate) end
    if yawRow then yawRow.set(liveCfg.maxYawRateDps) end
    if brakeRow then brakeRow.set(liveCfg.brakeMaxTiltDeg) end

    local ack = opts.lastAck and opts.lastAck()
    if ack and (ack.cmd == "diskSave" or ack.cmd == "diskLoad") then
      local detail = ack.detail or {}
      local text
      if ack.ack then
        text = ("%d sv %d ld"):format(#(detail.saved or {}), #(detail.loaded or {}))
      else
        text = tostring(detail.reason or detail.error or "failed")
      end
      diskResult:setText(Theme.fit(text, width))
      diskResult:setForeground(ack.ack and Theme.ok or Theme.warning)
    end
  end

  return {
    update = update,
    refreshMonitors = refreshMonitorRows,
    show = show,
    narrow = narrow,
    hardware = hardware,
    pages = { home = home, monitors = monitorPage, hardware = hardwarePage,
              disk = diskPage, flight = flightPage },
    elements = {
      status = homeStatus, stale = homeStale, live = liveLines, alarm = alarmLine,
      diskStatus = diskStatus, diskLocal = diskLocal, diskResult = diskResult,
      monitorRows = monitorRows, bank = bankRow, pitch = pitchRow,
    },
  }
end

return ConfigPanel
