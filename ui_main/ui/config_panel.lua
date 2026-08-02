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

--- A group's corners plus a SECOND ring of boosters at the SAME corners, so a craft that one
--- ring can't lift can take another. The extra keeps its position in the label ("FL" -> "FL2")
--- because that is exactly what the pilot needs to know when bolting on a spare -- the flight
--- side gives "x<corner>" the same geometry as "<corner>", so FL2 doubles the front-left. Every
--- extra key here must be one the flight computer's EXTRA_GEOMETRY (flight/app.lua) recognises,
--- or setSlot refuses it.
local function withSecondRing(kind, corners)
  local slots = {}
  for _, c in ipairs(corners) do
    slots[#slots + 1] = { kind = kind, key = c.key, label = c.label, title = c.title,
      hint = c.hint }
  end
  for _, c in ipairs(corners) do
    slots[#slots + 1] = { kind = kind, key = "x" .. c.key, label = c.label .. "2",
      title = c.title .. " 2", hint = c.hint }
  end
  return slots
end

--- The ACCEL group has no corners -- every accelerator faces back from the centreline -- so its
--- extras are just numbered further (M5..M8), keyed x1..x4 to match EXTRA_GEOMETRY.main.
local function accelSlots()
  local slots = {}
  for i = 1, 4 do
    slots[#slots + 1] = { kind = "main", key = tostring(i), label = "M" .. i,
      title = "ACCEL " .. i }
  end
  for i = 1, 4 do
    slots[#slots + 1] = { kind = "main", key = "x" .. i, label = "M" .. (i + 4),
      title = "ACCEL " .. (i + 4) }
  end
  return slots
end

--- Which named slots each hardware section offers. `kind` and `key` address `setSlot`
--- exactly, and `source` names the candidate list in telemetry.
local SECTION_SLOTS = {
  lift = { source = "thrusters", hint = "lift thruster", slots = withSecondRing("lift", {
    { key = "fl", label = "FL", title = "LIFT FRONT L" },
    { key = "fr", label = "FR", title = "LIFT FRONT R" },
    { key = "rl", label = "RL", title = "LIFT REAR L" },
    { key = "rr", label = "RR", title = "LIFT REAR R" },
  }) },
  accel = { source = "thrusters", hint = "main thruster", slots = accelSlots() },
  lateral = { source = "thrusters", hint = "lateral thruster", slots = withSecondRing("lateral", {
    { key = "fl", label = "FL", title = "LAT FRONT L", hint = "steers" },
    { key = "fr", label = "FR", title = "LAT FRONT R", hint = "steers" },
    { key = "rl", label = "RL", title = "LAT REAR L", hint = "precision" },
    { key = "rr", label = "RR", title = "LAT REAR R", hint = "precision" },
  }) },
  -- NAMED BY POSITION, not by an axis letter. The keys are the Config.VELOCITY_ROLES: one MEDIAL
  -- (fore/aft) sensor, and TWO lateral sensors -- front and rear -- whose mean is sideways drift
  -- and whose difference is yaw rate. There is no vertical slot: vertical speed comes from the
  -- barometer, never a velocity sensor. SENSOR CAL is the guided way to fill these; this is the
  -- manual fallback. (SENSOR CAL also fixes each sensor's sign, which this picker leaves alone.)
  velocity = { source = "velocity", hint = "velocity sensor", slots = {
    { kind = "velocity", key = "medial", label = "MEDIAL", title = "MEDIAL VEL",
      hint = "forward / back" },
    { kind = "velocity", key = "lateralFront", label = "LAT FRONT", title = "LAT FRONT VEL",
      hint = "front, left / right" },
    { kind = "velocity", key = "lateralRear", label = "LAT REAR", title = "LAT REAR VEL",
      hint = "rear, left / right" },
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

--- Every action the typewriter can drive, in the order a pilot thinks about them: the flight
--- axes first, then the momentary and toggle controls.
---
--- `key` is the config field under input.typewriter.bindings, so these names must match
--- flight/lib/input/bindings.lua exactly -- a label change is free, a key change is not.
local TYPEWRITER_ACTIONS = {
  { key = "pitchUp",       label = "PITCH+",  title = "PITCH UP",      hint = "nose up" },
  { key = "pitchDown",     label = "PITCH-",  title = "PITCH DOWN",    hint = "nose down" },
  { key = "rollLeft",      label = "ROLL L",  title = "ROLL LEFT" },
  { key = "rollRight",     label = "ROLL R",  title = "ROLL RIGHT" },
  { key = "yawLeft",       label = "YAW L",   title = "YAW LEFT" },
  { key = "yawRight",      label = "YAW R",   title = "YAW RIGHT" },
  { key = "climb",         label = "CLIMB",   title = "CLIMB" },
  { key = "descend",       label = "DESCEND", title = "DESCEND" },
  { key = "accelerate",    label = "ACCEL+",  title = "ACCELERATE",    hint = "forward" },
  { key = "decelerate",    label = "ACCEL-",  title = "DECELERATE",    hint = "then reverse" },
  { key = "brake",         label = "BRAKE",   title = "BRAKE",         hint = "hold, or tap" },
  { key = "cycleFeel",     label = "FEEL",    title = "CYCLE FEEL",    hint = "cruise/rate/stutter" },
  { key = "toggleLateral", label = "LATERAL", title = "LATERAL MODE",  hint = "flight/precision" },
  { key = "toggleAssist",  label = "ASSIST",  title = "FLIGHT ASSIST" },
  { key = "gear",          label = "GEAR",    title = "LANDING GEAR" },
  { key = "lights",        label = "LIGHTS",  title = "LIGHTS" },
  { key = "engineMaster",  label = "ENGINE",  title = "ENGINE MASTER" },
}

ConfigPanel.TYPEWRITER_ACTIONS = TYPEWRITER_ACTIONS

--- The keys offered, most-reachable first. A curated list rather than everything CC's `keys`
--- table holds: a monitor can only be tapped, so every extra entry is another page to wade
--- through, and half of `keys` is unreachable on a typewriter anyway.
---
--- REMEMBER: a key does nothing at all unless it is bound to a frequency ON THE TYPEWRITER.
--- This list is what the software will accept, not what your typewriter actually sends.
local KEY_NAMES = (function()
  local out = {}
  local function add(...) for _, k in ipairs({ ... }) do out[#out + 1] = k end end
  add("space", "leftShift", "leftCtrl", "leftAlt", "tab", "enter", "backspace")
  for c in ("abcdefghijklmnopqrstuvwxyz"):gmatch(".") do add(c) end
  add("one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "zero")
  add("up", "down", "left", "right")
  add("rightShift", "rightCtrl", "rightAlt", "capsLock")
  add("comma", "period", "semicolon", "apostrophe", "minus", "equals", "slash", "backslash")
  add("leftBracket", "rightBracket", "grave")
  add("insert", "delete", "home", "end", "pageUp", "pageDown")
  for i = 1, 12 do add("f" .. i) end
  return out
end)()

ConfigPanel.KEY_NAMES = KEY_NAMES

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

  -- The craft's last reported state. Every page reads THIS, never what it asked for. `nav` is the
  -- NAV computer's broadcast (config + candidate tables), a different source from the flight config.
  local live = { candidates = {}, slots = {}, config = {}, disk = {}, nav = {}, stale = true }

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
  local flightPage, diskPage, tankPage, keysPage = page(), page(), page(), page()
  local axesPage, navPage = page(), page()
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
    { label = "NAV SRC",    page = function() return navPage end },
    { label = "FUEL TANK",  page = function() return tankPage end },
    { label = "OPTICAL",    page = function() return slotPages.optical end },
    { label = "THR AXES",   page = function() return axesPage end },
    { label = "KEYS",       page = function() return keysPage end },
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

  -- ----------------------------------------------------------- thruster axes

  Theme.line(axesPage, 1, width, Theme.centre("THR AXES", width), Theme.accent)
  Theme.line(axesPage, 2, width, "SWP flips X/Z", Theme.dim)
  Theme.rule(axesPage, 3, width)

  --- One row per configured thruster: which nozzle axis drives which craft axis, and the two
  --- sign flips. Nothing can work this out for itself -- a thruster mounted rotated or mirrored
  --- gets pushed the WRONG WAY and the attitude loop answers by pushing harder. Run SELF TEST
  --- on the nav screen to see which way each nozzle actually moves, then fix it here.
  local axesRows = {}
  local axesFooterRow = height - 1
  local axesRowCount = math.max(1, axesFooterRow - 4)
  local axesPage1 = 1
  local refreshAxes

  -- Three 3-wide toggles leave six columns for the label on a 15-column screen. Four-wide
  -- toggles left two, which truncated "LIFFL" to "LI".
  local toggleWidth = 3
  local labelWidth = math.max(3, width - toggleWidth * 3)
  for i = 1, axesRowCount do
    local row = { entry = nil }
    row.label = Theme.line(axesPage, 3 + i, labelWidth, "", Theme.fg)
    --- Toggle ONE field and pass the other two through unchanged.
    ---
    --- Written out rather than with `and`/`or`: that idiom cannot return false, so toggling a
    --- set flag OFF silently left it on. Exactly the bug the test caught.
    local function send(field)
      return function()
        local e = row.entry
        if not e then return end
        local swap, invX, invY = e.swap, e.invertX, e.invertY
        if field == "swap" then swap = not swap
        elseif field == "invertX" then invX = not invX
        else invY = not invY end
        actions.setAxes(e.id, swap, invX, invY)
      end
    end
    row.swap = Theme.button(axesPage, labelWidth + 1, 3 + i, toggleWidth, "SWP", send("swap"))
    row.invX = Theme.button(axesPage, labelWidth + toggleWidth + 1, 3 + i, toggleWidth, "-X",
      send("invertX"))
    row.invY = Theme.button(axesPage, labelWidth + toggleWidth * 2 + 1, 3 + i, toggleWidth, "-Y",
      send("invertY"))
    axesRows[i] = row
  end

  local axesFooter = Theme.line(axesPage, axesFooterRow, width, "", Theme.dim)
  local axesPrev = Theme.button(axesPage, math.max(1, width - 7), axesFooterRow, 3, "^",
    function() axesPage1 = axesPage1 - 1; refreshAxes() end)
  local axesNext = Theme.button(axesPage, math.max(1, width - 3), axesFooterRow, 3, "v",
    function() axesPage1 = axesPage1 + 1; refreshAxes() end)
  backButton(axesPage)

  function refreshAxes()
    local list = live.thrusterAxes or {}
    local pagesTotal = math.max(1, math.ceil(#list / axesRowCount))
    axesPage1 = math.max(1, math.min(axesPage1, pagesTotal))
    for i, row in ipairs(axesRows) do
      local entry = list[(axesPage1 - 1) * axesRowCount + i]
      row.entry = entry
      local show = (entry ~= nil)
      row.label:setVisible(show)
      row.swap:setVisible(show)
      row.invX:setVisible(show)
      row.invY:setVisible(show)
      if entry then
        row.label:setText(Theme.fit(("%s%s"):format(entry.group:sub(1, 3):upper(),
          tostring(entry.key):upper()), labelWidth))
        local function paint(button, on, text)
          button:setText(text)
          button:setBackground(on and Theme.accent or Theme.buttonBg)
          button:setForeground(on and colours.black or Theme.buttonFg)
        end
        paint(row.swap, entry.swap, "SWP")
        paint(row.invX, entry.invertX, "-X")
        paint(row.invY, entry.invertY, "-Y")
      end
    end
    if #list == 0 then
      axesFooter:setText(Theme.fit("no thrusters set", width))
      axesFooter:setForeground(Theme.warning)
    else
      axesFooter:setText(pagesTotal > 1
        and ("pg %d/%d"):format(axesPage1, pagesTotal) or ("%d thrusters"):format(#list))
      axesFooter:setForeground(Theme.dim)
    end
    axesPrev:setVisible(pagesTotal > 1)
    axesNext:setVisible(pagesTotal > 1)
  end
  refreshAxes()

  -- ------------------------------------------------------------ typewriter

  --- Which key each action is bound to, and whether two actions are fighting over one key --
  --- which is the failure a remapping screen exists to prevent. The craft reports it as a
  --- keybind "problem" and flies on; the pilot deserves to see it where they caused it.
  local function bindingOf(action)
    return (live.config.typewriterBindings or {})[action.key] or ""
  end

  local function bindingConflict()
    local byKey = {}
    for _, action in ipairs(TYPEWRITER_ACTIONS) do
      local bound = bindingOf(action)
      if bound ~= "" then
        if byKey[bound] then return bound, byKey[bound], action.label end
        byKey[bound] = action.label
      end
    end
    return nil
  end

  sections.keys = Slots.build(keysPage, 1, 1, width, height - 1, {
    title = "TYPEWRITER",
    slots = TYPEWRITER_ACTIONS,
    candidates = function() return KEY_NAMES end,
    assigned = bindingOf,
    set = function(action, keyName)
      actions.configSet("input.typewriter.bindings." .. action.key, keyName)
    end,
    -- HEAD, not tail: "leftShift" and "rightShift" differ at the front, so truncating the
    -- start would render the two identically -- the opposite of a peripheral name.
    fitValue = "head",
    status = function()
      local key, first, second = bindingConflict()
      if key then
        return ("%s: %s+%s"):format(key, first, second), Theme.warning
      end
      return nil
    end,
    refusedCmd = "configSet",
    lastAck = opts.lastAck,
  })
  backButton(keysPage)

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
  -- On-ground threshold: the down laser reads within this many blocks = landed. Raise it if a
  -- landed physics hull reads "not on ground" (its resting clearance exceeds the default).
  local gndRow = tunable("gnd", "sensors.groundContactDist", 0.5, 0.5, 10, 1)

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

  -- ---------------------------------------------------------------- nav source
  --
  -- The one place a craft setting lives on ANOTHER computer: heading is the nav computer's job, so
  -- these commands go to it (actions.setHeadingSource et al -> Link:sendNav), not to the flight
  -- computer. Everything shown is the nav computer's REPORTED config (live.nav.config), read from
  -- its broadcast -- so a change only appears once the nav computer has actually applied it.

  Theme.line(navPage, 1, width, Theme.centre("NAV SOURCE", width), Theme.accent)
  -- The current heading and what it RESTS on -- the proof a source change took.
  local navHeading = Theme.line(navPage, 2, width, "", Theme.dim)

  local navLabelW = math.max(3, math.min(5, width - 8))
  local navBtnW = math.max(6, width - navLabelW - 1)

  --- Cycle a value through a list. Each tap sends the NEXT one; the display is driven by the
  --- craft's reply, never by the tap -- so a refused change simply does not move.
  local function cycleNext(options, current)
    local index = 1
    for i, option in ipairs(options) do if option == current then index = i end end
    return options[index % #options + 1]
  end

  local HEADING_SOURCES = { "auto", "navtable", "gimbal" }
  Theme.line(navPage, 3, navLabelW, "SRC", Theme.dim)
  local srcButton = Theme.button(navPage, navLabelW + 1, 3, navBtnW, "--", function()
    actions.setHeadingSource(cycleNext(HEADING_SOURCES, (live.nav.config or {}).headingSource or "auto"))
  end)

  Theme.line(navPage, 4, navLabelW, "TBL", Theme.dim)
  local tblButton = Theme.button(navPage, navLabelW + 1, 4, navBtnW, "--", function()
    -- "" is the AUTO choice (first table found); the reported candidates follow it.
    local options = { "" }
    for _, name in ipairs(live.nav.navTables or {}) do options[#options + 1] = name end
    actions.setNavTable(cycleNext(options, (live.nav.config or {}).navTable or ""))
  end)

  -- Sign flips share a row. Each toggles to the opposite of what the nav computer reports.
  local signW = math.max(6, math.floor((width - 1) / 2))
  local navSignBtn = Theme.button(navPage, 1, 5, signW, "NAV +", function()
    actions.setNavSign(((live.nav.config or {}).navSign or 1) < 0 and 1 or -1)
  end)
  local gmbSignBtn = Theme.button(navPage, signW + 2, 5, math.max(6, width - signW - 1), "GMB +",
    function()
      actions.setGimbalSign(((live.nav.config or {}).gimbalSign or 1) < 0 and 1 or -1)
    end)

  local navAckLine = Theme.line(navPage, 6, width, "", Theme.dim)

  local navAlignBtn = Theme.button(navPage, 1, height - 1, math.min(12, width), "SELF ALIGN",
    function() actions.navSelfAlign() end)
  backButton(navPage)

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
  local lastSeenNavAck = nil

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
    live.thrusterAxes = t.thrusterAxes or {}
    live.config = t.config or {}
    live.disk = t.disk or {}
    live.nav = model.nav or {}

    for _, section in pairs(sections) do section.update() end
    refreshAxes()

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
    if gndRow then gndRow.set(live.config.groundContactDist) end

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

    -- ---- nav source section
    local nav = live.nav or {}
    local navCfg = nav.config or {}
    -- The heading readout, and what it currently rests on -- the proof a source change took.
    if type(nav.heading) == "number" and not nav.stale then
      local d = math.floor(nav.heading + 0.5) % 360
      if d == 0 then d = 360 end
      local rests = (nav.headingSource == "navtable" and "true N")
        or (nav.headingSource == "backup" and "backup")
        or (nav.headingSource == "gimbal" and "rel") or ""
      navHeading:setText(Theme.fit(("HDG %03d %s"):format(d, rests), width))
      navHeading:setForeground(Theme.fg)
    else
      navHeading:setText(Theme.fit(nav.stale and "HDG -- nav stale"
        or (nav.config and "HDG -- no fix" or "no nav link"), width))
      navHeading:setForeground(nav.stale and Theme.warning or Theme.dim)
    end

    srcButton:setText(Theme.fit(tostring(navCfg.headingSource or "--"), navBtnW))
    local tbl = navCfg.navTable
    tblButton:setText((tbl == nil or tbl == "") and Theme.fit("auto", navBtnW)
      or Theme.fitEnd(tostring(tbl), navBtnW))
    navSignBtn:setText(("NAV %s"):format((navCfg.navSign or 1) < 0 and "-" or "+"))
    gmbSignBtn:setText(("GMB %s"):format((navCfg.gimbalSign or 1) < 0 and "-" or "+"))

    -- What the nav computer said about the last command sent to it -- its OWN ack, not the flight
    -- one, so a nav refusal shows here rather than being lost.
    local nack = opts.lastNavAck and opts.lastNavAck()
    if nack ~= lastSeenNavAck then
      lastSeenNavAck = nack
      if nack then
        local d = nack.detail or {}
        navAckLine:setText(Theme.fit(nack.ack and tostring(d.detail or "ok")
          or tostring(d.errorShort or d.error or "refused"), width))
        navAckLine:setForeground(nack.ack and Theme.ok or Theme.warning)
      end
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
      disk = diskPage, tank = tankPage, keys = keysPage,
      axes = axesPage, nav = navPage,
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
      yaw = yawRow, brake = brakeRow, gnd = gndRow,
      ackTimes = ackLines[timesPage], ackFlight = ackLines[flightPage],
      ackTank = ackLines[tankPage],
      axesRows = axesRows, axesFooter = axesFooter,
      navHeading = navHeading, navSrc = srcButton, navTable = tblButton,
      navSign = navSignBtn, gmbSign = gmbSignBtn, navAck = navAckLine,
      navAlign = navAlignBtn,
    },
  }
end

return ConfigPanel
