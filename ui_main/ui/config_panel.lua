--[[ The config panel -- the upward-facing monitor, bottom right of the cockpit.

     EVERY craft setting lives here, and nothing else does. Its home page is a MENU AND NOTHING
     ELSE: one button per section, no flight values. Flight information belongs on the screens
     you look at while flying; this is the screen you look at while setting the vehicle up, and
     mixing the two only made both worse.

       ENGINE      relay, engine vault, and the feed timings
       LIMITS      the flight-control envelope
       LIFT THR    the four lift thrusters
       ACCEL THR   the four main accelerators
       LAT THR     the four lateral thrusters
       VELOCITY    one velocity sensor per craft axis
       ALT+GIMBAL  the altimeter and the attitude gimbal
       FUEL TANK   the liquid fuel tank and its scale
       OPTICAL     the laser rays, one per direction
       DISK        save and load every config to a floppy

     MONITOR ASSIGNMENT IS NOT HERE. Which panel renders on which monitor is a property of the
     UI computer, not of the craft, so it lives on that computer's own terminal (ui/terminal.lua)
     -- which is also the one screen guaranteed to exist before anything has been assigned.

     IT HAS TO FIT A 1x1 MONITOR: 15x10 characters at text scale 0.5. The menu pages itself and
     every section computes its layout from the real size.
]]

local Theme = require("ui.theme")
local Util = require("shared.util")
local Slots = require("ui.slots")

local ConfigPanel = {}

local MIN_WIDTH, MIN_HEIGHT = 14, 9

--- ms -> "1m 00s" / "45s". The feed interval is minutes-long, so milliseconds are unreadable.
local function formatDuration(ms)
  if type(ms) ~= "number" then return "--" end
  local total = math.floor(ms / 1000 + 0.5)
  local minutes = math.floor(total / 60)
  local seconds = total % 60
  if minutes > 0 then return ("%dm %02ds"):format(minutes, seconds) end
  return ("%ds"):format(seconds)
end

ConfigPanel.formatDuration = formatDuration

--- Which named slots each hardware section offers. `kind` and `key` address `setSlot`
--- exactly, and `source` names the candidate list in telemetry.
local SECTION_SLOTS = {
  lift = { source = "thrusters", hint = "lift thruster", slots = {
    { kind = "lift", key = "fl", label = "FL", title = "LIFT FRONT L" },
    { kind = "lift", key = "fr", label = "FR", title = "LIFT FRONT R" },
    { kind = "lift", key = "rl", label = "RL", title = "LIFT REAR L" },
    { kind = "lift", key = "rr", label = "RR", title = "LIFT REAR R" },
  } },
  accel = { source = "thrusters", hint = "main thruster", slots = {
    { kind = "main", key = "1", label = "M1", title = "ACCEL 1" },
    { kind = "main", key = "2", label = "M2", title = "ACCEL 2" },
    { kind = "main", key = "3", label = "M3", title = "ACCEL 3" },
    { kind = "main", key = "4", label = "M4", title = "ACCEL 4" },
  } },
  lateral = { source = "thrusters", hint = "lateral thruster", slots = {
    { kind = "lateral", key = "fl", label = "FL", title = "LAT FRONT L", hint = "steers" },
    { kind = "lateral", key = "fr", label = "FR", title = "LAT FRONT R", hint = "steers" },
    { kind = "lateral", key = "rl", label = "RL", title = "LAT REAR L", hint = "precision" },
    { kind = "lateral", key = "rr", label = "RR", title = "LAT REAR R", hint = "precision" },
  } },
  velocity = { source = "velocity", hint = "velocity sensor", slots = {
    { kind = "velocity", key = "x", label = "X", title = "VEL X", hint = "right" },
    { kind = "velocity", key = "y", label = "Y", title = "VEL Y", hint = "up" },
    { kind = "velocity", key = "z", label = "Z", title = "VEL Z", hint = "forward" },
  } },
  attitude = { hint = "sensor", slots = {
    { kind = "altitude", key = "sensor", label = "ALT", title = "ALTIMETER",
      source = "altimeters" },
    { kind = "gimbal", key = "sensor", label = "GMB", title = "GIMBAL", source = "gimbals" },
    -- The down-facing laser is the RADAR altimeter, so it belongs with altitude rather than
    -- with the proximity rays.
    { kind = "optical", key = "down", label = "RDR", title = "RADAR (DOWN)",
      source = "optical" },
  } },
  optical = { source = "optical", hint = "laser", slots = {
    { kind = "optical", key = "forward", label = "FWD", title = "LASER FWD" },
    { kind = "optical", key = "back", label = "BCK", title = "LASER BACK" },
    { kind = "optical", key = "left", label = "LFT", title = "LASER LEFT" },
    { kind = "optical", key = "right", label = "RGT", title = "LASER RIGHT" },
  } },
  engine = { hint = "peripheral", slots = {
    { kind = "relay", key = "relay", label = "RLY", title = "ENGINE RELAY", source = "relays" },
    { kind = "vault", key = "vault", label = "VLT", title = "ENGINE VAULT", source = "vaults" },
  } },
  tank = { hint = "tank", slots = {
    { kind = "tank", key = "tank", label = "TNK", title = "FUEL TANK", source = "tanks" },
  } },
}

ConfigPanel.SECTION_SLOTS = SECTION_SLOTS

--- opts = { cfg, actions, monitors, log, savePanels, lastAck }
function ConfigPanel.build(frame, opts)
  local actions = opts.actions
  local width, height = frame:getWidth(), frame:getHeight()
  frame:setBackground(Theme.bg)

  if width < MIN_WIDTH or height < MIN_HEIGHT then
    Theme.line(frame, 1, width, "SCREEN TOO", Theme.warning)
    Theme.line(frame, 2, width, "SMALL", Theme.warning)
    Theme.line(frame, 3, width, ("%dx%d"):format(width, height), Theme.dim)
    Theme.line(frame, 4, width, ("need %dx%d"):format(MIN_WIDTH, MIN_HEIGHT), Theme.dim)
    return { update = function() end, elements = {}, pages = {} }
  end

  -- The craft's last reported state. Every page reads THIS, never what it asked for.
  local live = { candidates = {}, slots = {}, config = {}, disk = {}, stale = true }

  local pages = {}
  local function page()
    local p = frame:addFrame({ x = 1, y = 1, width = width, height = height,
      background = Theme.bg })
    p:setVisible(false)
    pages[#pages + 1] = p
    return p
  end

  local home = page()
  local enginePage, timesPage = page(), page()
  local flightPage, diskPage, tankPage = page(), page(), page()
  local slotPages = {}
  for _, name in ipairs({ "lift", "accel", "lateral", "velocity", "attitude", "optical" }) do
    slotPages[name] = page()
  end
  home:setVisible(true)

  local function show(target)
    for _, p in ipairs(pages) do p:setVisible(p == target) end
  end

  local function backButton(parent, target)
    return Theme.button(parent, 1, height, math.min(6, width), "BACK",
      function() show(target or home) end)
  end

  -- ---------------------------------------------------------------- the menu

  local MENU = {
    { label = "ENGINE",     page = function() return enginePage end },
    { label = "LIMITS",     page = function() return flightPage end },
    { label = "LIFT THR",   page = function() return slotPages.lift end },
    { label = "ACCEL THR",  page = function() return slotPages.accel end },
    { label = "LAT THR",    page = function() return slotPages.lateral end },
    { label = "VELOCITY",   page = function() return slotPages.velocity end },
    { label = "ALT+GIMBAL", page = function() return slotPages.attitude end },
    { label = "FUEL TANK",  page = function() return tankPage end },
    { label = "OPTICAL",    page = function() return slotPages.optical end },
    { label = "DISK",       page = function() return diskPage end },
  }

  Theme.line(home, 1, width, Theme.centre("CONFIG", width), Theme.accent)
  local menuFooterRow = height
  local menuRowCount = math.max(1, menuFooterRow - 2)
  local menuPage = 1
  local menuRows = {}
  local refreshMenu

  for i = 1, menuRowCount do
    local slot = { entry = nil }
    slot.button = Theme.button(home, 1, i + 1, width, "", function()
      if slot.entry then show(slot.entry.page()) end
    end)
    menuRows[i] = slot
  end

  local menuFooter = Theme.line(home, menuFooterRow, width, "", Theme.dim)
  local menuPrev = Theme.button(home, math.max(1, width - 7), menuFooterRow, 3, "^", function()
    menuPage = menuPage - 1; refreshMenu()
  end)
  local menuNext = Theme.button(home, math.max(1, width - 3), menuFooterRow, 3, "v", function()
    menuPage = menuPage + 1; refreshMenu()
  end)

  function refreshMenu()
    local total = math.max(1, math.ceil(#MENU / menuRowCount))
    menuPage = math.max(1, math.min(menuPage, total))
    for i, slot in ipairs(menuRows) do
      local entry = MENU[(menuPage - 1) * menuRowCount + i]
      slot.entry = entry
      if entry then
        slot.button:setText(Theme.fit(entry.label, width))
        slot.button:setVisible(true)
      else
        slot.button:setVisible(false)
      end
    end
    menuFooter:setText(total > 1 and ("pg %d/%d"):format(menuPage, total) or "")
    menuPrev:setVisible(total > 1)
    menuNext:setVisible(total > 1)
  end
  refreshMenu()

  -- ------------------------------------------------------------ slot sections

  --- Build one hardware section from SECTION_SLOTS. All of them are the same widget; only the
  --- slot list and the candidate source differ.
  local function slotSection(parent, title, spec, back)
    return Slots.build(parent, 1, 1, width, height - 1, {
      title = title,
      slots = spec.slots,
      candidates = function(slot)
        return live.candidates[slot.source or spec.source] or {}
      end,
      assigned = function(slot)
        if slot.kind == "relay" then return live.config.engineRelay or "" end
        if slot.kind == "vault" then return live.config.vaultPeripheral or "" end
        if slot.kind == "tank" then return live.config.tankPeripheral or "" end
        return (live.slots or {})[slot.kind .. ":" .. slot.key] or ""
      end,
      set = function(slot, peripheral)
        if slot.kind == "relay" then
          actions.setEngineRelay(peripheral, live.config.engineSide or "top")
        elseif slot.kind == "vault" then
          actions.setVault(peripheral)
        elseif slot.kind == "tank" then
          actions.setTank(peripheral)
        else
          actions.setSlot(slot.kind, slot.key, peripheral)
        end
      end,
      refusedCmd = "setSlot",
      lastAck = opts.lastAck,
    }), backButton(parent, back)
  end

  local sections = {}
  sections.lift = slotSection(slotPages.lift, "LIFT THRUSTERS", SECTION_SLOTS.lift)
  sections.accel = slotSection(slotPages.accel, "ACCEL THRUSTERS", SECTION_SLOTS.accel)
  sections.lateral = slotSection(slotPages.lateral, "LATERAL THR", SECTION_SLOTS.lateral)
  sections.velocity = slotSection(slotPages.velocity, "VELOCITY SENS", SECTION_SLOTS.velocity)
  sections.attitude = slotSection(slotPages.attitude, "ALT + GIMBAL", SECTION_SLOTS.attitude)
  sections.optical = slotSection(slotPages.optical, "OPTICAL SENS", SECTION_SLOTS.optical)

  -- ---------------------------------------------------------------- engine

  local engineRows = math.max(Slots.rows(), height - 3)
  sections.engine = Slots.build(enginePage, 1, 1, width, engineRows, {
    title = "ENGINE HW",
    slots = SECTION_SLOTS.engine.slots,
    candidates = function(slot) return live.candidates[slot.source] or {} end,
    assigned = function(slot)
      if slot.kind == "relay" then return live.config.engineRelay or "" end
      return live.config.vaultPeripheral or ""
    end,
    set = function(slot, peripheral)
      if slot.kind == "relay" then
        actions.setEngineRelay(peripheral, live.config.engineSide or "top")
      else
        actions.setVault(peripheral)
      end
    end,
    refusedCmd = "setEngineRelay",
    lastAck = opts.lastAck,
  })
  local sideButton = Theme.button(enginePage, 1, height - 1, math.min(9, width), "side --",
    function()
      local SIDES = { "top", "bottom", "left", "right", "front", "back" }
      local current, index = live.config.engineSide or "top", 1
      for i, s in ipairs(SIDES) do if s == current then index = i end end
      local wanted = SIDES[index % #SIDES + 1]
      -- Only the craft can change this; if no relay is assigned there is nothing to send to.
      if (live.config.engineRelay or "") ~= "" then
        actions.setEngineRelay(live.config.engineRelay, wanted)
      end
    end)
  Theme.button(enginePage, math.max(1, width - 6), height - 1, 7, "TIMES", function()
    show(timesPage)
  end)
  backButton(enginePage)

  -- ---------------------------------------------------------------- timings

  Theme.line(timesPage, 1, width, Theme.centre("FEED TIMES", width), Theme.accent)
  Theme.rule(timesPage, 2, width)

  Theme.line(timesPage, 3, width, "pulse", Theme.dim)
  local pulseValue = Theme.line(timesPage, 4, width, "--", Theme.fg)
  local pulseState = { value = nil }
  local function nudgePulse(delta)
    if type(pulseState.value) ~= "number" then return end
    local next = Util.clamp(pulseState.value + delta, 50, 5000)
    if next ~= pulseState.value then actions.configSet("engine.pulseMs", next) end
  end
  Theme.button(timesPage, math.max(1, width - 6), 4, 3, "-", function() nudgePulse(-50) end)
  Theme.button(timesPage, math.max(1, width - 2), 4, 3, "+", function() nudgePulse(50) end)

  Theme.line(timesPage, 5, width, "interval", Theme.dim)
  local intervalValue = Theme.line(timesPage, 6, width, "--", Theme.fg)
  local intervalState = { value = nil }
  --- The interval has to match ONE FUEL UNIT'S BURN TIME, which is minutes for blaze cake.
  --- Two step sizes, because 15 s steps get you across an hour and 1 s steps land on the
  --- number -- and a single step size cannot do both.
  local function nudgeInterval(deltaSeconds)
    if type(intervalState.value) ~= "number" then return end
    local next = Util.clamp(intervalState.value + deltaSeconds * 1000, 15000, 3600000)
    if next ~= intervalState.value then actions.configSet("engine.intervalMs", next) end
  end
  local stepWidth = math.max(3, math.floor((width - 3) / 4))
  local steps = { { "-15", -15 }, { "-1", -1 }, { "+1", 1 }, { "+15", 15 } }
  local stepButtons = {}
  for i, step in ipairs(steps) do
    stepButtons[i] = Theme.button(timesPage, 1 + (i - 1) * (stepWidth + 1), 7, stepWidth,
      step[1], function() nudgeInterval(step[2]) end)
  end
  Theme.line(timesPage, 8, width, "15s to 1h", Theme.dim)

  Theme.button(timesPage, math.max(1, width - 5), height, 6, "SAVE", function()
    actions.configSave()
  end)
  backButton(timesPage, enginePage)

  -- ---------------------------------------------------------------- tank

  -- height - 4: the picker's own footer must not land on the ack line below it.
  sections.tank = Slots.build(tankPage, 1, 1, width, height - 4, {
    title = "FUEL TANK",
    slots = SECTION_SLOTS.tank.slots,
    candidates = function() return live.candidates.tanks or {} end,
    assigned = function() return live.config.tankPeripheral or "" end,
    set = function(_, peripheral) actions.setTank(peripheral) end,
    refusedCmd = "setTank",
    lastAck = opts.lastAck,
  })
  local capacityLine = Theme.line(tankPage, height - 2, width, "max --", Theme.dim)
  local capacityState = { value = nil }
  local function nudgeCapacity(delta)
    if type(capacityState.value) ~= "number" then return end
    local next = Util.clamp(capacityState.value + delta, 0, 1000000)
    if next ~= capacityState.value then
      actions.configSet("hardware.tanks.1.capacityMb", next)
    end
  end
  local capMinus = Theme.button(tankPage, math.max(1, width - 6), height - 2, 3, "-",
    function() nudgeCapacity(-1000) end)
  local capPlus = Theme.button(tankPage, math.max(1, width - 2), height - 2, 3, "+",
    function() nudgeCapacity(1000) end)
  Theme.line(tankPage, height - 1, width, "0 = auto scale", Theme.dim)
  backButton(tankPage)

  -- ---------------------------------------------------------------- flight

  Theme.line(flightPage, 1, width, Theme.centre("FLT LIMITS", width), Theme.accent)

  local narrow = width < 26
  local fy = 2
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
    row.minus = Theme.button(flightPage, textWidth + 1, fy, buttonWidth, "-",
      function() nudge(-step) end)
    row.plus = Theme.button(flightPage, textWidth + buttonWidth + 1, fy, buttonWidth, "+",
      function() nudge(step) end)
    row.set = function(value)
      row.value = value
      nameLabel:setText(Theme.fit(("%s %s"):format(label,
        type(value) == "number" and Util.num(value, row.decimals) or "--"), textWidth))
    end
    fy = fy + 1
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

  -- ---------------------------------------------------------------- update

  local staleBanner = Theme.staleBanner(frame, 1, width)

  --- A refused command used to be INVISIBLE: the value simply did not move, which is
  --- indistinguishable from a dead button -- and that is exactly how it got reported. Every
  --- page that sends configSet carries this line, and it reports what the CRAFT said.
  local ackLines = {
    [timesPage] = Theme.line(timesPage, 9, width, "", Theme.dim),
    [flightPage] = Theme.line(flightPage, height - 1, width, "", Theme.dim),
    [tankPage] = Theme.line(tankPage, height - 3, width, "", Theme.dim),
  }
  local lastSeenAck = nil

  local function update(model)
    local t = model.telemetry or {}
    live.stale = model.stale
    staleBanner:setVisible(model.stale)
    if model.stale then
      staleBanner:setText(Theme.centre(
        model.ageMs == math.huge and "NO LINK" or "NO DATA", width))
    end

    live.candidates = t.candidates or {}
    live.slots = t.slots or {}
    live.config = t.config or {}
    live.disk = t.disk or {}

    for _, section in pairs(sections) do section.update() end

    sideButton:setText(Theme.fit("side " .. tostring(live.config.engineSide or "--"),
      math.min(9, width)))

    pulseState.value = live.config.enginePulseMs
    pulseValue:setText(type(pulseState.value) == "number"
      and (tostring(pulseState.value) .. "ms") or "--")
    intervalState.value = live.config.engineIntervalMs
    intervalValue:setText(formatDuration(intervalState.value))

    capacityState.value = live.config.tankCapacityMb
    if capacityState.value == nil then
      capacityLine:setText(Theme.fit("set a tank", width))
      capacityLine:setForeground(Theme.dim)
    elseif capacityState.value == 0 then
      capacityLine:setText(Theme.fit("max auto", width))
      capacityLine:setForeground(Theme.fg)
    else
      capacityLine:setText(Theme.fit("max " .. tostring(capacityState.value), width))
      capacityLine:setForeground(Theme.fg)
    end

    if bankRow then bankRow.set(live.config.maxBankDeg) end
    if pitchRow then pitchRow.set(live.config.maxPitchDeg) end
    if climbRow then climbRow.set(live.config.maxClimbRate) end
    if sinkRow then sinkRow.set(live.config.maxSinkRate) end
    if yawRow then yawRow.set(live.config.maxYawRateDps) end
    if brakeRow then brakeRow.set(live.config.brakeMaxTiltDeg) end

    local disk = live.disk
    diskStatus:setText(Theme.fit(disk.diskPresent
      and ("disk " .. tostring(disk.label or "unnamed")) or "no disk", width))
    diskStatus:setForeground(disk.diskPresent and Theme.ok or Theme.dim)
    diskLocal:setText(Theme.fit(("disk %s here %s")
      :format(tostring(disk.onDisk or 0), tostring(disk.localConfigs or 0)), width))

    local ack = opts.lastAck and opts.lastAck()

    -- configSet is the command every tunable on every page sends, so its verdict belongs
    -- wherever the pilot is standing when it comes back.
    if ack ~= lastSeenAck then
      lastSeenAck = ack
      if ack and ack.cmd == "configSet" then
        local text, colour
        if ack.ack then
          text, colour = "applied", Theme.ok
        else
          -- The TAIL of a validator message carries the constraint ("must be >= 15000");
          -- the head is the path, which the pilot already knows -- they are standing on it.
          local errors = (ack.detail or {}).errors or {}
          text, colour = Theme.fitEnd(tostring(errors[1] or "REFUSED"), width), Theme.warning
        end
        for _, line in pairs(ackLines) do
          line:setText(text)
          line:setForeground(colour)
        end
      end
    end

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
    show = show,
    narrow = narrow,
    sections = sections,
    menu = MENU,
    menuRows = menuRows,
    pages = {
      home = home, engine = enginePage, times = timesPage, flight = flightPage,
      disk = diskPage, tank = tankPage,
      lift = slotPages.lift, accel = slotPages.accel, lateral = slotPages.lateral,
      velocity = slotPages.velocity, attitude = slotPages.attitude,
      optical = slotPages.optical,
    },
    elements = {
      stale = staleBanner, menuFooter = menuFooter,
      pulse = pulseValue, interval = intervalValue, side = sideButton,
      intervalSteps = stepButtons, capacity = capacityLine,
      capacityMinus = capMinus, capacityPlus = capPlus,
      diskStatus = diskStatus, diskLocal = diskLocal, diskResult = diskResult,
      bank = bankRow, pitch = pitchRow, climb = climbRow, sink = sinkRow,
      yaw = yawRow, brake = brakeRow,
      ackTimes = ackLines[timesPage], ackFlight = ackLines[flightPage],
      ackTank = ackLines[tankPage],
    },
  }
end

return ConfigPanel
