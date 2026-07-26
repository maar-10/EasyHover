--[[ Phase 6: the ui_main role.

     Runs in its OWN CraftOS instance (tests/run_ui.sh) with package.path pointing at
     /ui_main/. That is not fussiness: both roles have a `lib/config.lua`, so sharing a Lua
     state with the flight suites would make `require("lib.config")` ambiguous -- and it would
     resolve to the wrong one.

     The panels are built against REAL Basalt, rendering into real `window` objects, so this
     exercises the actual framework rather than a stand-in.
]]

local T = require("tests.util")
local UiConfig = require("lib.config")
local Link = require("lib.link")
local Monitors = require("lib.monitors")
local Overhead = require("ui.overhead")
local ConfigPanel = require("ui.config_panel")
local Slots = require("ui.slots")
local Terminal = require("ui.terminal")
local Theme = require("ui.theme")
local Log = require("shared.log")
local basalt = require("basalt")

local mock = dofile("/tests/mocks/peripherals.lua")

local function quietLog() return Log.new({ level = "error", capacity = 50 }) end

--- A telemetry payload shaped exactly like the one flight/lib/telemetry.lua builds.
local function telemetry(overrides)
  local payload = {
    proto = "eh1", seq = 1, t = os.epoch("utc"), role = "flight", mode = "HOVER",
    modes = { feel = "cruise", lateral = "flight", assist = true, throttle = 0.35 },
    attitude = { pitch = 2.5, roll = -1.5 },
    altitude = { baro = 82.5, vs = -0.25, radar = 3.0 },
    velocity = { horizontal = 4.5, capability = "vector" },
    ground = { distance = 3.0, contact = false },
    engine = { available = true, master = true, feeding = false, pulses = 4, nextFeedInMs = 4200 },
    fuel = {
      worstFraction = 0.5, worstTank = 0.375, vaultEmpty = false,
      tanks = { { label = "Main fuel", amount = 6000, capacity = 16000, fraction = 0.375 } },
      vaults = { { label = "Engine fuel", count = 96, empty = false } },
    },
    config = {
      enginePulseMs = 400, engineIntervalMs = 60000, engineInvert = false,
      tankCapacityMb = 0, maxBankDeg = 20, maxPitchDeg = 20,
      maxClimbRate = 6, maxSinkRate = 4, maxYawRateDps = 45, brakeMaxTiltDeg = 12,
    },
    disk = { diskPresent = true, label = "EH configs", onDisk = 2, localConfigs = 1 },
    candidates = {
      relays = { "redstone_relay_0", "redstone_relay_1" },
      tanks = { "create:fluid_tank_0" },
      vaults = { "create:item_vault_0" },
      monitors = { "monitor_0", "monitor_1", "monitor_2" },
    },
    alarms = {},
  }
  if overrides then
    for k, v in pairs(overrides) do payload[k] = v end
  end
  return payload
end

local function model(overrides)
  local m = { connected = true, stale = false, ageMs = 100, flightId = 3,
              telemetry = telemetry() }
  if overrides then
    for k, v in pairs(overrides) do m[k] = v end
  end
  return m
end

--- Click an element for real, through Basalt's own hit test.
---
--- isInBounds() compares against the element's x/y in its PARENT's coordinate space, so that
--- is where the click has to land. Dispatching at (1,1) silently misses.
---
--- NO DELAY between calls, deliberately. Basalt coalesces two clicks on one element within
--- 0.4 s into `mouse_double_click` INSTEAD OF a second `mouse_click`, so a button that only
--- listens for `mouse_click` throws away every rapid second tap -- which is exactly what made
--- the hardware picker look dead in the cockpit. Tests used to sleep past the threshold, which
--- hid the bug. Now they tap as fast as an impatient pilot.
local function click(element)
  return element:dispatchEvent("mouse_click", "left", element:getX(), element:getY())
end

--- A tap the way CC actually delivers one: `monitor_touch` on the FRAME, in the monitor's own
--- absolute coordinates. BaseFrame matches the peripheral name, then calls mouse_click(1, x, y).
--- `pageY` is the y of the element's containing sub-frame, for panels that use pages.
local function tap(frame, element, pageY)
  local absY = element:getY() + (pageY or 1) - 1
  return frame:dispatchEvent("monitor_touch", frame._peripheralName, element:getX(), absY)
end

local function sent()
  local out = {}
  return out, {
    engineMaster = function(v) out[#out + 1] = { cmd = "engineMaster", value = v } end,
    engineFeed = function() out[#out + 1] = { cmd = "engineFeed" } end,
    configSet = function(p, v) out[#out + 1] = { cmd = "configSet", path = p, value = v } end,
    configSave = function() out[#out + 1] = { cmd = "configSave" } end,
    diskSave = function() out[#out + 1] = { cmd = "diskSave" } end,
    diskLoad = function() out[#out + 1] = { cmd = "diskLoad" } end,
    setFeel = function(v) out[#out + 1] = { cmd = "setFeel", value = v } end,
    setLateral = function(v) out[#out + 1] = { cmd = "setLateral", value = v } end,
    setAssist = function(v) out[#out + 1] = { cmd = "setAssist", value = v } end,
    setAltitude = function(v) out[#out + 1] = { cmd = "setAltitude", value = v } end,
    setAux = function(l, v) out[#out + 1] = { cmd = "setAux", label = l, value = v } end,
    setEngineRelay = function(pe, side)
      out[#out + 1] = { cmd = "setEngineRelay", peripheral = pe, side = side }
    end,
    setTank = function(pe) out[#out + 1] = { cmd = "setTank", peripheral = pe } end,
    setVault = function(pe) out[#out + 1] = { cmd = "setVault", peripheral = pe } end,
    setSlot = function(kind, key, pe)
      out[#out + 1] = { cmd = "setSlot", kind = kind, key = key, peripheral = pe }
    end,
  }
end

-- ------------------------------------------------------------------ config

T.suite("ui config")

T.it("defaults declare every panel, including the reserved ones", function()
  local cfg = UiConfig.withDefaults({})
  for _, name in ipairs(UiConfig.PANEL_ORDER) do
    T.notNil(cfg.panels[name], name .. " declared")
    T.eq(type(cfg.panels[name].monitors), "table", name .. " has a monitor list")
  end
  T.isTrue(cfg.panels.overhead.enabled, "overhead is live")
  T.isFalse(cfg.panels.pfd.enabled, "pfd is reserved for a later phase")
end)

T.it("an old config gains fields added later", function()
  local cfg = UiConfig.withDefaults({ panels = { overhead = { monitors = { "monitor_0" } } } })
  T.eq(cfg.panels.overhead.monitors[1], "monitor_0", "my assignment survived")
  T.near(cfg.panels.overhead.textScale, 0.5, 1e-9, "template field added")
  T.notNil(cfg.comms.telemetryProtocol, "whole sections added")
end)

T.it("assigning a monitor moves it off whatever panel had it", function()
  local cfg = UiConfig.withDefaults({})
  UiConfig.assign(cfg, "overhead", "monitor_0")
  T.eq(UiConfig.panelFor(cfg, "monitor_0"), "overhead", "assigned")
  UiConfig.assign(cfg, "config", "monitor_0")
  T.eq(UiConfig.panelFor(cfg, "monitor_0"), "config", "moved")
  T.eq(#cfg.panels.overhead.monitors, 0, "and removed from the old panel")
end)

T.it("a panel can hold TWO monitors -- that is how mirroring is expressed", function()
  local cfg = UiConfig.withDefaults({})
  UiConfig.assign(cfg, "overhead", "monitor_0")
  UiConfig.assign(cfg, "overhead", "monitor_1")
  T.eq(#cfg.panels.overhead.monitors, 2, "both sides of the cockpit")
  local ok, errors = UiConfig.validate(cfg)
  T.isTrue(ok, "and that is valid: " .. table.concat(errors, "; "))
end)

T.it("assigning the same monitor twice is idempotent", function()
  local cfg = UiConfig.withDefaults({})
  UiConfig.assign(cfg, "overhead", "monitor_0")
  UiConfig.assign(cfg, "overhead", "monitor_0")
  T.eq(#cfg.panels.overhead.monitors, 1, "not duplicated")
end)

T.it("one monitor cannot show two panels", function()
  local cfg = UiConfig.withDefaults({})
  cfg.panels.overhead.monitors = { "monitor_0" }
  cfg.panels.config.monitors = { "monitor_0" }
  local ok, errors = UiConfig.validate(cfg)
  T.isFalse(ok, "rejected")
  T.containsMatch(errors, "assigned to both", "reason")
end)

T.it("no assignment warns rather than blocks", function()
  local cfg = UiConfig.withDefaults({})
  local ok, _, warnings = UiConfig.validate(cfg)
  T.isTrue(ok, "still valid -- you have to be able to boot to assign anything")
  T.containsMatch(warnings, "overhead panel", "warned about the overhead panel")
end)

T.it("unassign removes a monitor from every panel", function()
  local cfg = UiConfig.withDefaults({})
  UiConfig.assign(cfg, "overhead", "monitor_0")
  T.eq(UiConfig.unassign(cfg, "monitor_0"), "overhead", "reports where it was")
  T.isNil(UiConfig.panelFor(cfg, "monitor_0"), "gone")
end)

T.it("save and load round-trip", function()
  local path = "/test_ui_cfg.tbl"
  local cfg = UiConfig.withDefaults({})
  UiConfig.assign(cfg, "overhead", "monitor_7")
  T.isTrue(UiConfig.save(path, cfg), "saved")
  local loaded, existed = UiConfig.load(path)
  T.isTrue(existed, "existed")
  T.eq(loaded.panels.overhead.monitors[1], "monitor_7", "assignment survived")
  fs.delete(path)
end)

-- ------------------------------------------------------------------ monitors

T.suite("monitor manager")

T.it("lists every monitor on the network with its size", function()
  mock.reset()
  _G.peripheral = mock.install()
  local cfg = UiConfig.withDefaults({})
  local monitors = Monitors.new(cfg, quietLog(), basalt)
  local available = monitors:available()
  T.eq(#available, 3, "three monitors in the mock cockpit")
  T.eq(available[1].name, "monitor_0", "sorted")
  T.eq(available[1].width, 15, "width read from the monitor")
  T.eq(available[1].height, 20, "height read from the monitor")
end)

T.it("builds ONE frame per assigned monitor -- mirroring is two frames", function()
  mock.reset()
  _G.peripheral = mock.install()
  local cfg = UiConfig.withDefaults({})
  UiConfig.assign(cfg, "overhead", "monitor_0")
  UiConfig.assign(cfg, "overhead", "monitor_1")
  local monitors = Monitors.new(cfg, quietLog(), basalt)
  local built = 0
  local instances = monitors:buildPanel("overhead", function(frame)
    built = built + 1
    T.eq(frame:getWidth(), 15, "the frame took the monitor's width")
    return { update = function() end }
  end)
  T.eq(built, 2, "built for both monitors")
  T.eq(#instances, 2, "two instances")
  T.eq(monitors:count("overhead"), 2, "counted")
  monitors:clear()
end)

T.it("a missing monitor is reported, not fatal", function()
  mock.reset()
  _G.peripheral = mock.install()
  local cfg = UiConfig.withDefaults({})
  UiConfig.assign(cfg, "overhead", "monitor_0")
  UiConfig.assign(cfg, "overhead", "monitor_does_not_exist")
  local monitors = Monitors.new(cfg, quietLog(), basalt)
  local instances = monitors:buildPanel("overhead", function() return { update = function() end } end)
  T.eq(#instances, 1, "the present one still built")
  T.containsMatch(monitors.missing, "monitor_does_not_exist", "the absent one reported")
  monitors:clear()
end)

T.it("a disabled panel builds nothing", function()
  mock.reset()
  _G.peripheral = mock.install()
  local cfg = UiConfig.withDefaults({})
  UiConfig.assign(cfg, "pfd", "monitor_0")       -- pfd is reserved / disabled
  local monitors = Monitors.new(cfg, quietLog(), basalt)
  local instances = monitors:buildPanel("pfd", function() return { update = function() end } end)
  T.eq(#instances, 0, "nothing built for a reserved panel")
  monitors:clear()
end)

T.it("update feeds the SAME model to every mirrored instance", function()
  mock.reset()
  _G.peripheral = mock.install()
  local cfg = UiConfig.withDefaults({})
  UiConfig.assign(cfg, "overhead", "monitor_0")
  UiConfig.assign(cfg, "overhead", "monitor_1")
  local monitors = Monitors.new(cfg, quietLog(), basalt)
  local seen = {}
  monitors:buildPanel("overhead", function()
    return { update = function(m) seen[#seen + 1] = m.telemetry.altitude.baro end }
  end)
  monitors:update(model())
  T.eq(#seen, 2, "both instances updated")
  T.eq(seen[1], seen[2], "with identical data -- the screens cannot disagree")
  monitors:clear()
end)

T.it("a panel that throws does not take the UI down", function()
  mock.reset()
  _G.peripheral = mock.install()
  local cfg = UiConfig.withDefaults({})
  UiConfig.assign(cfg, "overhead", "monitor_0")
  local monitors = Monitors.new(cfg, quietLog(), basalt)
  monitors:buildPanel("overhead", function()
    return { update = function() error("panel bug", 0) end }
  end)
  monitors:update(model())      -- must not propagate
  T.isTrue(true, "survived a throwing panel")
  monitors:clear()
end)

-- ------------------------------------------------------------------ overhead

T.suite("overhead panel")

local function overheadRig(width, height)
  mock.reset()
  _G.peripheral = mock.install()
  local cfg = UiConfig.withDefaults({})
  local monitor = mock.monitor(width or 15, height or 20)
  local frame = basalt.createFrame()
  frame:setTerm(monitor)
  local commands, actions = sent()
  local panel = Overhead.build(frame, { cfg = cfg, actions = actions, log = quietLog() })
  return panel, commands, frame
end

T.it("shows the engine running, with a countdown to the next feed", function()
  local panel = overheadRig()
  panel.update(model())
  T.eq(panel.elements.engineState:getText(), "RUNNING", "engine state")
  T.eq(panel.elements.engineButton:getText(), "STOP", "the button offers the opposite action")
  T.isTrue(panel.elements.engineFeed:getText():find("feed 4.2s") ~= nil,
    "countdown: " .. panel.elements.engineFeed:getText())
end)

T.it("shows the engine off, and offers START", function()
  local panel = overheadRig()
  local m = model()
  m.telemetry.engine = { available = true, master = false, pulses = 0 }
  panel.update(m)
  T.eq(panel.elements.engineState:getText(), "OFF", "state")
  T.eq(panel.elements.engineButton:getText(), "START", "action")
end)

T.it("says NO RELAY when the engine has no relay configured", function()
  local panel = overheadRig()
  local m = model()
  m.telemetry.engine = { available = false, master = false }
  panel.update(m)
  T.eq(panel.elements.engineState:getText(), "NO RELAY", "honest about the hardware")
end)

T.it("draws the liquid fuel gauge from the tank reading", function()
  local panel = overheadRig()
  panel.update(model())
  T.eq(panel.elements.tankBar:getProgress(), 38, "37.5% rounds to 38")
  T.isTrue(panel.elements.tankValue:getText():find("6000/16000") ~= nil,
    "amount and capacity: " .. panel.elements.tankValue:getText())
end)

T.it("shows a raw amount and NO bar fill when capacity is unknown", function()
  local panel = overheadRig()
  local m = model()
  m.telemetry.fuel.tanks = { { label = "Main", amount = 2500 } }
  panel.update(m)
  T.eq(panel.elements.tankBar:getProgress(), 0, "no invented scale")
  T.isTrue(panel.elements.tankValue:getText():find("2500 mB") ~= nil,
    "raw amount shown: " .. panel.elements.tankValue:getText())
end)

T.it("shows the solid fuel count from the vault", function()
  local panel = overheadRig()
  panel.update(model())
  T.isTrue(panel.elements.vault:getText():find("96 items") ~= nil,
    "vault count: " .. panel.elements.vault:getText())
end)

T.it("warns when the vault is empty", function()
  local panel = overheadRig()
  local m = model()
  m.telemetry.fuel.vaults = { { label = "Engine fuel", count = 0, empty = true } }
  panel.update(m)
  T.eq(panel.elements.vault:getForeground(), colours.red, "coloured as a warning")
end)

T.it("shows NO DATA when telemetry stops, instead of a stale number", function()
  local panel = overheadRig()
  panel.update(model())
  panel.update({ stale = true, ageMs = 9000, telemetry = telemetry() })
  T.isTrue(panel.elements.stale:getVisible(), "stale banner up")
  T.eq(panel.elements.engineState:getText(), "?", "engine state no longer claims to know")
  T.eq(panel.elements.tankBar:getProgress(), 0, "gauge emptied rather than frozen")
end)

T.it("the engine button sends the OPPOSITE of the reported state", function()
  local panel, commands = overheadRig()
  panel.update(model())                       -- master = true
  click(panel.elements.engineButton)
  T.eq(#commands, 1, "one command sent")
  T.eq(commands[1].cmd, "engineMaster", "the right command")
  T.eq(commands[1].value, false, "asks to stop, because it is running")
end)

T.it("a too-small monitor says so instead of drawing nonsense", function()
  local panel = overheadRig(8, 6)
  panel.update(model())        -- must not throw
  T.isTrue(true, "degraded cleanly")
end)
-- ------------------------------------------------------------------ config panel

T.suite("config panel")

local configAck = nil

local function configRig(width, height)
  mock.reset()
  _G.peripheral = mock.install()
  configAck = nil
  local cfg = UiConfig.withDefaults({})
  local monitor = mock.monitor(width or 15, height or 20)
  local frame = basalt.createFrame()
  frame:setTerm(monitor)
  local commands, actions = sent()
  local monitors = Monitors.new(cfg, quietLog(), basalt)
  local saved = { count = 0 }
  local panel = ConfigPanel.build(frame, {
    cfg = cfg, actions = actions, monitors = monitors, log = quietLog(),
    savePanels = function() saved.count = saved.count + 1 end,
    lastAck = function() return configAck end,
  })
  return panel, commands, cfg, saved
end

--- The menu labels currently drawn on the home page.
local function menuLabels(panel)
  local out = {}
  for _, row in ipairs(panel.menuRows) do
    if row.button:getVisible() then out[#out + 1] = row.button:getText() end
  end
  return out
end

local function menuRowFor(panel, label)
  for _, row in ipairs(panel.menuRows) do
    if row.button:getVisible() and row.entry and row.entry.label == label then
      return row.button
    end
  end
  return nil
end

T.it("the home page is a MENU and nothing else -- no flight values", function()
  -- Flight information belongs on the screens you read while flying. This is the screen you
  -- read while setting the craft up, and mixing the two made both worse.
  local panel = configRig()
  panel.update(model())
  local labels = menuLabels(panel)
  T.isTrue(#labels > 0, "the menu is drawn")
  for _, label in ipairs(labels) do
    T.isFalse(label:find("ALT ") ~= nil, "no altitude on the menu: " .. label)
    T.isFalse(label:find("82") ~= nil, "no live numbers on the menu: " .. label)
  end
  T.isNil(panel.elements.live, "and there is no live-value block at all")
end)

T.it("offers every config section the craft has", function()
  local panel = configRig()
  local wanted = { "ENGINE", "LIMITS", "LIFT THR", "ACCEL THR", "LAT THR", "VELOCITY",
                   "ALT+GIMBAL", "FUEL TANK", "OPTICAL", "DISK" }
  for _, label in ipairs(wanted) do
    local found = false
    for _, entry in ipairs(panel.menu) do if entry.label == label then found = true end end
    T.isTrue(found, "menu has " .. label)
  end
  T.eq(#panel.menu, #wanted, "and nothing else")
end)

T.it("MONITOR ASSIGNMENT IS NOT HERE -- it belongs to the UI computer", function()
  local panel = configRig()
  for _, entry in ipairs(panel.menu) do
    T.isFalse(entry.label:find("MON") ~= nil, "no monitor page: " .. entry.label)
  end
  T.isNil(panel.pages.monitors, "and no such page exists")
end)

T.it("pages the menu rather than dropping entries off a short screen", function()
  local panel = configRig(15, 10)
  local shown = menuLabels(panel)
  T.isTrue(#shown >= 1, "entries fit")
  T.isTrue(#shown < #panel.menu, "not all of them, on a screen this short")
  T.isTrue(panel.elements.menuFooter:getText():find("pg 1/") ~= nil,
    "so it pages: " .. panel.elements.menuFooter:getText())
end)

T.it("tapping a menu entry opens its page", function()
  local panel = configRig()
  panel.update(model())
  click(menuRowFor(panel, "LIMITS"))
  T.isTrue(panel.pages.flight:getVisible(), "the limits page is up")
  T.isFalse(panel.pages.home:getVisible(), "and the menu is not")
end)

T.it("the disk page reports what the craft sees", function()
  local panel = configRig()
  panel.update(model())
  T.isTrue(panel.elements.diskStatus:getText():find("EH configs") ~= nil,
    "disk label: " .. panel.elements.diskStatus:getText())
  T.isTrue(panel.elements.diskLocal:getText():find("2") ~= nil, "counts shown")
end)

T.it("the limits page mirrors the craft and sends configSet", function()
  local panel, commands = configRig()
  panel.update(model())
  T.isTrue(panel.elements.bank.display:getText():find("20") ~= nil,
    "bank limit: " .. panel.elements.bank.display:getText())
  click(panel.elements.bank.plus)
  T.eq(commands[1].cmd, "configSet", "a nudge sends configSet")
  T.eq(commands[1].path, "envelope.maxBankDeg", "for the right path")
  T.eq(commands[1].value, 21, "one step up")
end)

T.it("shows NO DATA when the link drops", function()
  local panel = configRig()
  panel.update(model())
  panel.update({ stale = true, ageMs = math.huge, telemetry = nil })
  T.isTrue(panel.elements.stale:getVisible(), "banner up")
end)

T.it("still says so when the screen is genuinely unusable", function()
  local panel = configRig(8, 5)
  T.isNil(panel.elements.stale, "no panel built")
  panel.update(model())
end)

-- ------------------------------------------------------------ engine timings

T.suite("engine feed timings")

T.it("shows the interval in minutes and seconds, not milliseconds", function()
  -- A blaze cake burns for minutes. "60000ms" is unreadable at a glance and, worse, invites
  -- the pilot to think in the wrong unit.
  local panel = configRig()
  panel.update(model())
  T.eq(panel.elements.interval:getText(), "1m 00s", "one minute")

  local m = model()
  m.telemetry.config.engineIntervalMs = 135000
  panel.update(m)
  T.eq(panel.elements.interval:getText(), "2m 15s", "two and a quarter minutes")

  m.telemetry.config.engineIntervalMs = 45000
  panel.update(m)
  T.eq(panel.elements.interval:getText(), "45s", "under a minute needs no minute field")
end)

T.it("steps by 1 SECOND and by 15 SECONDS, so an hour is reachable and a second is landable",
  function()
    local panel, commands = configRig()
    panel.update(model())
    T.eq(#panel.elements.intervalSteps, 4, "four step buttons")

    click(panel.elements.intervalSteps[4])          -- +15
    T.eq(commands[1].path, "engine.intervalMs", "path")
    T.eq(commands[1].value, 75000, "+15 s from one minute")

    click(panel.elements.intervalSteps[3])          -- +1
    T.eq(commands[2].value, 61000, "+1 s from one minute")

    click(panel.elements.intervalSteps[1])          -- -15
    T.eq(commands[3].value, 45000, "-15 s")

    click(panel.elements.intervalSteps[2])          -- -1
    T.eq(commands[4].value, 59000, "-1 s")
  end)

T.it("clamps to the 15 s floor and the 1 hour ceiling", function()
  local panel, commands = configRig()
  local m = model()
  m.telemetry.config.engineIntervalMs = 15000
  panel.update(m)
  click(panel.elements.intervalSteps[1])           -- -15 from the floor
  T.eq(#commands, 0, "already at the floor, so nothing is sent")

  m.telemetry.config.engineIntervalMs = 3600000
  panel.update(m)
  click(panel.elements.intervalSteps[4])           -- +15 from the ceiling
  T.eq(#commands, 0, "already at the ceiling")
end)

T.it("pulse stays in milliseconds, because that is the unit it lives in", function()
  local panel = configRig()
  panel.update(model())
  T.eq(panel.elements.pulse:getText(), "400ms", "shown in ms")
end)

T.it("SHOWS WHAT THE CRAFT SAID when a configSet is refused", function()
  -- A refused command used to change nothing and say nothing, which is indistinguishable from
  -- a dead button -- and is exactly how it got reported twice.
  local panel = configRig()
  panel.update(model())
  T.eq(panel.elements.ackFlight:getText(), "", "quiet until something happens")

  configAck = { ack = false, cmd = "configSet",
                detail = { errors = { "engine.intervalMs must be >= 15000" } } }
  panel.update(model())
  T.isTrue(panel.elements.ackTimes:getText():find("15000") ~= nil,
    "the craft's own reason is shown: " .. panel.elements.ackTimes:getText())
  T.eq(panel.elements.ackTimes:getForeground(), Theme.warning, "and coloured as a refusal")
end)

T.it("confirms an accepted configSet too, so silence never means success", function()
  local panel = configRig()
  panel.update(model())
  configAck = { ack = true, cmd = "configSet", detail = {} }
  panel.update(model())
  T.eq(panel.elements.ackFlight:getText(), "applied", "said so")
  T.eq(panel.elements.ackFlight:getForeground(), Theme.ok, "and coloured as success")
end)

-- ------------------------------------------------------------------ slots

T.suite("slot pickers")

local slotAck = nil

local function slotsRig(spec, width, height)
  mock.reset()
  _G.peripheral = mock.install()
  slotAck = nil
  local monitor = mock.monitor(width or 15, height or 20)
  local frame = basalt.createFrame()
  frame:setTerm(monitor)
  local commands, actions = sent()
  local assigned = {}
  local widget = Slots.build(frame, 1, 1, frame:getWidth(), frame:getHeight(), {
    title = spec.title,
    slots = spec.slots,
    candidates = function() return spec.candidates end,
    assigned = function(slot) return assigned[slot.kind .. ":" .. slot.key] or "" end,
    set = function(slot, peripheral)
      actions.setSlot(slot.kind, slot.key, peripheral)
    end,
    refusedCmd = "setSlot",
    lastAck = function() return slotAck end,
  })
  return widget, commands, assigned
end

local LIFT = {
  title = "LIFT THRUSTERS",
  slots = ConfigPanel.SECTION_SLOTS.lift.slots,
  candidates = { "vector_thruster_0", "vector_thruster_1", "vector_thruster_2" },
}

local function visibleRows(widget)
  local out = {}
  for _, row in ipairs(widget.rows) do
    if row.button:getVisible() then out[#out + 1] = row.button:getText() end
  end
  return out
end

local function rowLabelled(widget, prefix)
  for _, row in ipairs(widget.rows) do
    if row.button:getVisible() and row.button:getText():sub(1, #prefix) == prefix then
      return row.button
    end
  end
  return nil
end

local function candidateRow(widget, name)
  for _, row in ipairs(widget.rows) do
    if row.button:getVisible() and row.name == name then return row.button end
  end
  return nil
end

T.it("lists every slot with what fills it, and how many are done", function()
  local widget, _, assigned = slotsRig(LIFT)
  assigned["lift:fl"] = "vector_thruster_0"
  widget.update()
  T.eq(widget.elements.title:getText(), "LIFT THRUSTERS", "title")
  T.eq(widget.elements.subtitle:getText(), "1 of 4 set", "progress, so you can see what is left")
  local rows = visibleRows(widget)
  T.eq(#rows, 4, "four corners: " .. table.concat(rows, " | "))
  T.isTrue(rows[1]:find("FL") ~= nil, "labelled by corner: " .. rows[1])
  T.isTrue(rows[1]:find("thruster_0") ~= nil, "and shows its peripheral: " .. rows[1])
  T.isTrue(rows[2]:find("--") ~= nil, "an empty slot says so: " .. rows[2])
  -- Every row spans the width, so an empty one does not sit centred among filled ones.
  for _, text in ipairs(rows) do T.eq(#text, 15, "row fills the width: " .. text) end
end)

T.it("tapping a slot opens the candidates, and tapping one assigns THAT slot", function()
  local widget, commands = slotsRig(LIFT)
  widget.update()
  click(rowLabelled(widget, "RL"))
  T.eq(widget.page(), "candidates", "moved to the candidate list")
  T.eq(widget.elements.title:getText(), "LIFT REAR L", "for the slot that was tapped")

  click(candidateRow(widget, "vector_thruster_2"))
  T.eq(#commands, 1, "one command")
  T.eq(commands[1].cmd, "setSlot", "the right command")
  T.eq(commands[1].kind, "lift", "kind")
  T.eq(commands[1].key, "rl", "the slot that was chosen")
  T.eq(commands[1].peripheral, "vector_thruster_2", "the candidate that was tapped")
  T.eq(widget.page(), "slots", "and it returns to the slot list")
end)

T.it("offers (none) first, so an assignment is always undoable", function()
  local widget, commands, assigned = slotsRig(LIFT)
  assigned["lift:fl"] = "vector_thruster_0"
  widget.update()
  click(rowLabelled(widget, "FL"))
  click(candidateRow(widget, ""))
  T.eq(commands[1].peripheral, "", "cleared")
end)

T.it("NEVER shows an assignment the craft has not confirmed", function()
  local widget, commands, assigned = slotsRig(LIFT)
  widget.update()
  click(rowLabelled(widget, "FL"))
  click(candidateRow(widget, "vector_thruster_0"))
  T.eq(#commands, 1, "the command went out")
  widget.update()
  T.eq(widget.elements.subtitle:getText(), "0 of 4 set", "still nothing confirmed")
  T.isTrue(widget.elements.footer:getText():find("waiting") ~= nil,
    "and it says it is waiting: " .. widget.elements.footer:getText())

  assigned["lift:fl"] = "vector_thruster_0"       -- the craft reports it
  widget.update()
  T.eq(widget.elements.subtitle:getText(), "1 of 4 set", "NOW it counts")
  T.isFalse(widget.elements.footer:getText():find("waiting") ~= nil, "and stops waiting")
end)

T.it("shows a refusal instead of silently doing nothing", function()
  local widget = slotsRig(LIFT)
  widget.update()
  slotAck = { ack = false, cmd = "setSlot", detail = {} }
  widget.update()
  T.isTrue(widget.elements.footer:getText():find("REFUSED") ~= nil,
    "footer: " .. widget.elements.footer:getText())
end)

T.it("says so when the craft can see no candidates at all", function()
  local widget = slotsRig({ title = "LIFT", slots = ConfigPanel.SECTION_SLOTS.lift.slots,
                            candidates = {} })
  widget.update()
  click(rowLabelled(widget, "FL"))
  T.isTrue(widget.elements.footer:getText():find("none on network") ~= nil,
    "footer: " .. widget.elements.footer:getText())
end)

T.it("pages a long candidate list rather than hiding the tail", function()
  local many = {}
  for i = 1, 30 do many[i] = "vector_thruster_" .. i end
  local widget = slotsRig({ title = "LIFT", slots = ConfigPanel.SECTION_SLOTS.lift.slots,
                            candidates = many }, 15, 12)
  widget.update()
  click(rowLabelled(widget, "FL"))
  T.isTrue(widget.elements.next:getVisible(), "paging offered")
  T.isTrue(widget.elements.footer:getText():find("pg 1/") ~= nil,
    "page indicator: " .. widget.elements.footer:getText())
end)

T.it("the lateral page names which pair steers and which is precision-only", function()
  local slots = ConfigPanel.SECTION_SLOTS.lateral.slots
  local byKey = {}
  for _, slot in ipairs(slots) do byKey[slot.key] = slot end
  T.eq(byKey.fl.hint, "steers", "the front pair steers")
  T.eq(byKey.rr.hint, "precision", "the rear pair is precision-only")
end)

T.it("the down-facing laser lives with ALTITUDE, not with the proximity rays", function()
  -- It is the radar altimeter. Grouping it with the forward/back/left/right rays would put it
  -- on the page about obstacles rather than the page about height.
  local attitude = ConfigPanel.SECTION_SLOTS.attitude.slots
  local found = false
  for _, slot in ipairs(attitude) do
    if slot.kind == "optical" and slot.key == "down" then found = true end
  end
  T.isTrue(found, "the radar is on the altitude page")
  for _, slot in ipairs(ConfigPanel.SECTION_SLOTS.optical.slots) do
    T.isFalse(slot.key == "down", "and not on the optical page")
  end
end)

-- ------------------------------------------------ config panel slot sections

T.suite("config panel hardware pages")

T.it("every hardware section is wired to the craft's candidate lists", function()
  local panel = configRig()
  panel.update(model())
  for _, name in ipairs({ "lift", "accel", "lateral", "velocity", "attitude", "optical",
                          "engine", "tank" }) do
    T.notNil(panel.sections[name], "section " .. name .. " exists")
  end
end)

T.it("a thruster page offers the thrusters the craft reported", function()
  local panel, commands = configRig()
  local m = model()
  m.telemetry.candidates.thrusters = { "vector_thruster_0", "vector_thruster_1" }
  panel.update(m)
  local section = panel.sections.lift
  click(section.rows[1].button)                   -- FL
  local names = {}
  for _, row in ipairs(section.rows) do
    if row.button:getVisible() then names[#names + 1] = row.name end
  end
  T.isTrue(#names >= 3, "(none) plus both thrusters, got " .. #names)
  click(section.rows[2].button)                   -- the first real candidate
  T.eq(commands[1].cmd, "setSlot", "sends setSlot")
  T.eq(commands[1].kind, "lift", "for a lift thruster")
end)

T.it("the engine page assigns the relay and the vault with their own commands", function()
  local panel, commands = configRig()
  panel.update(model())
  local section = panel.sections.engine
  click(section.rows[1].button)                   -- RLY
  click(section.rows[2].button)                   -- first candidate
  T.eq(commands[1].cmd, "setEngineRelay", "the relay has its own command")

  section.showSlots()
  click(section.rows[2].button)                   -- VLT
  click(section.rows[2].button)                   -- first candidate
  T.eq(commands[2].cmd, "setVault", "and so does the vault")
end)

T.it("the tank page assigns the tank and edits its scale", function()
  local panel, commands = configRig()
  panel.update(model())
  T.eq(panel.elements.capacity:getText(), "max auto", "0 means trust the tank")
  click(panel.elements.capacityPlus)
  T.eq(commands[1].cmd, "configSet", "a nudge sends configSet")
  T.eq(commands[1].path, "hardware.tanks.1.capacityMb", "for the tank scale")
end)

T.it("the tank scale says SET A TANK rather than showing dead buttons", function()
  local panel, commands = configRig()
  local m = model()
  m.telemetry.config.tankCapacityMb = nil
  panel.update(m)
  T.isTrue(panel.elements.capacity:getText():find("set a tank") ~= nil,
    "says what is missing: " .. panel.elements.capacity:getText())
  click(panel.elements.capacityPlus)
  T.eq(#commands, 0, "and the buttons genuinely have nothing to send")
end)

-- ------------------------------------------------------------ terminal panel

T.suite("terminal monitor assignment")

local function terminalRig(width, height)
  mock.reset()
  _G.peripheral = mock.install()
  local cfg = UiConfig.withDefaults({})
  local monitor = mock.monitor(width or 51, height or 19)
  local frame = basalt.createFrame()
  frame:setTerm(monitor)
  local monitors = Monitors.new(cfg, quietLog(), basalt)
  local saved = { count = 0 }
  local panel = Terminal.build(frame, {
    cfg = cfg, monitors = monitors, log = quietLog(),
    savePanels = function() saved.count = saved.count + 1 end,
  })
  return panel, cfg, saved
end

T.it("lists every monitor on the network with its size and assignment", function()
  local panel, cfg = terminalRig()
  UiConfig.assign(cfg, "overhead", "monitor_0")
  panel.refresh()
  T.isTrue(panel.rows[1].label:getText():find("monitor_0") ~= nil,
    "name: " .. panel.rows[1].label:getText())
  T.isTrue(panel.rows[1].label:getText():find("15x20") ~= nil, "size shown")
  T.eq(panel.rows[1].button:getText(), "overhead", "assignment shown")
  T.eq(panel.rows[2].button:getText(), "none", "unassigned shown as none")
end)

T.it("tapping cycles the assignment, saves at once, and redraws on the tap", function()
  local panel, cfg, saved = terminalRig()
  panel.refresh()
  local button = panel.rows[1].button
  T.eq(button:getText(), "none", "starts unassigned")
  click(button)
  T.eq(UiConfig.panelFor(cfg, "monitor_0"), "overhead", "first tap assigns the overhead panel")
  T.eq(saved.count, 1, "saved at once, so a reboot cannot lose it")
  T.eq(button:getText(), "overhead", "and the label changed under the finger")
  click(button)
  T.eq(UiConfig.panelFor(cfg, "monitor_0"), "config", "second tap moves it on")
end)

T.it("cycling past the last panel unassigns", function()
  local panel, cfg = terminalRig()
  panel.refresh()
  for _ = 1, #UiConfig.PANEL_ORDER + 1 do click(panel.rows[1].button) end
  T.isNil(UiConfig.panelFor(cfg, "monitor_0"), "back to unassigned")
end)

-- ---------------------------------------------------- overhead, config gone

T.suite("overhead panel")

T.it("with no relay the engine button says CONFIG and sends nothing", function()
  local panel, commands = overheadRig()
  local m = model()
  m.telemetry.engine = { available = false, master = false }
  panel.update(m)
  T.eq(panel.elements.engineState:getText(), "NO RELAY", "state")
  T.eq(panel.elements.engineButton:getText(), "CONFIG", "the button says where to go")
  click(panel.elements.engineButton)
  T.eq(#commands, 0, "no pointless command sent")
end)

T.it("the manual feed button is labelled for what it does", function()
  local panel, commands = overheadRig()
  T.eq(panel.elements.feed:getText(), "FEED 1", "not PRIME")
  panel.update(model())
  click(panel.elements.feed)
  T.eq(commands[1].cmd, "engineFeed", "and it feeds one item")
end)

T.it("an unconfigured tank and vault point at the fix", function()
  local panel = overheadRig()
  local m = model()
  m.telemetry.fuel.tanks = {}
  m.telemetry.fuel.vaults = {}
  panel.update(m)
  T.isTrue(panel.elements.tankValue:getText():find("CFG") ~= nil,
    "tank: " .. panel.elements.tankValue:getText())
  T.isTrue(panel.elements.vault:getText():find("CFG") ~= nil,
    "vault: " .. panel.elements.vault:getText())
end)

T.it("HAS NO CONFIG PAGE -- every setting moved to the config monitor", function()
  local panel = overheadRig()
  T.isNil(panel.settings, "no settings frame")
  T.isNil(panel.hardware, "no hardware picker")
  T.isNil(panel.elements.pulse, "no timing rows")
  T.isNil(panel.elements.capacity, "no tank scale row")
end)
-- ------------------------------------------------------- incremental sync

T.suite("monitor sync")

T.it("reassigning one monitor leaves the other frames alone", function()
  mock.reset()
  _G.peripheral = mock.install()
  local cfg = UiConfig.withDefaults({})
  UiConfig.assign(cfg, "overhead", "monitor_0")
  UiConfig.assign(cfg, "config", "monitor_2")
  local monitors = Monitors.new(cfg, quietLog(), basalt)
  local builds = 0
  local builders = {
    overhead = function() builds = builds + 1; return { update = function() end } end,
    config = function() builds = builds + 1; return { update = function() end } end,
  }
  monitors:sync(builders)
  T.eq(builds, 2, "two frames built")

  UiConfig.assign(cfg, "overhead", "monitor_1")
  local changed = monitors:sync(builders)
  T.eq(changed, 1, "only the new monitor was touched")
  T.eq(builds, 3, "and only one new frame was built")
  T.eq(monitors:count("overhead"), 2, "overhead now mirrored")
  T.eq(monitors:count("config"), 1, "config untouched")
  monitors:clear()
end)

T.it("unassigning tears down just that frame", function()
  mock.reset()
  _G.peripheral = mock.install()
  local cfg = UiConfig.withDefaults({})
  UiConfig.assign(cfg, "overhead", "monitor_0")
  UiConfig.assign(cfg, "overhead", "monitor_1")
  local monitors = Monitors.new(cfg, quietLog(), basalt)
  local builders = { overhead = function() return { update = function() end } end }
  monitors:sync(builders)
  T.eq(monitors:count("overhead"), 2, "both built")

  UiConfig.unassign(cfg, "monitor_1")
  local changed = monitors:sync(builders)
  T.eq(changed, 1, "one frame removed")
  T.eq(monitors:count("overhead"), 1, "one left")
  monitors:clear()
end)

T.it("moving a monitor between panels rebuilds only it", function()
  mock.reset()
  _G.peripheral = mock.install()
  local cfg = UiConfig.withDefaults({})
  UiConfig.assign(cfg, "overhead", "monitor_0")
  local monitors = Monitors.new(cfg, quietLog(), basalt)
  local built = {}
  local builders = {
    overhead = function() built[#built + 1] = "overhead"; return { update = function() end } end,
    config = function() built[#built + 1] = "config"; return { update = function() end } end,
  }
  monitors:sync(builders)
  UiConfig.assign(cfg, "config", "monitor_0")
  monitors:sync(builders)
  T.eq(monitors:count("overhead"), 0, "left the overhead panel")
  T.eq(monitors:count("config"), 1, "and joined the config panel")
  T.eq(built[#built], "config", "rebuilt as the config panel")
  monitors:clear()
end)

T.it("sync is a no-op when nothing changed", function()
  mock.reset()
  _G.peripheral = mock.install()
  local cfg = UiConfig.withDefaults({})
  UiConfig.assign(cfg, "overhead", "monitor_0")
  local monitors = Monitors.new(cfg, quietLog(), basalt)
  local builders = { overhead = function() return { update = function() end } end }
  monitors:sync(builders)
  T.eq(monitors:sync(builders), 0, "second sync changes nothing")
  monitors:clear()
end)

-- ------------------------------------------------------------------ link

-- ------------------------------------------------------- the heartbeat timer

T.suite("stale heartbeat")

--- A stand-in for App's timer bookkeeping, exercised without basalt.run(). The real method is
--- App:onTimer; this rig gives it the two fields it touches.
local function timerRig()
  local App = require("app")
  local refreshes = 0
  local app = setmetatable({
    staleTimer = os.startTimer(9999),
    rebuildPending = false,
    refresh = function() refreshes = refreshes + 1 end,
    syncPanels = function() end,
  }, { __index = App })
  return app, function() return refreshes end
end

T.it("IGNORES a timer that is not its own -- the cockpit-wide sluggishness bug", function()
  -- Basalt runs timers of its own: a lazy-element pass every 0.2 s and a sleep(0.1) after
  -- EVERY monitor_touch. An unguarded handler re-arms itself on each of them, so every stray
  -- timer spawns another permanent 0.5 s refresh chain. They accumulate several times a
  -- second until CC's event queue overflows and starts dropping touches and telemetry.
  local app, refreshes = timerRig()
  local mine = app.staleTimer
  for i = 1, 50 do
    local handled = app:onTimer(mine + 1000 + i)     -- 50 timers belonging to Basalt
    T.isFalse(handled, "a foreign timer is not ours")
  end
  T.eq(refreshes(), 0, "and none of them caused a refresh")
  T.eq(app.staleTimer, mine, "nor re-armed the heartbeat -- no new chain was spawned")
end)

T.it("handles its OWN timer, and re-arms exactly once", function()
  local app, refreshes = timerRig()
  local first = app.staleTimer
  T.isTrue(app:onTimer(first), "ours")
  T.eq(refreshes(), 1, "refreshed once")
  T.isFalse(app.staleTimer == first, "re-armed with a new id")

  -- The old id must now be foreign: a late duplicate cannot start a second chain.
  T.isFalse(app:onTimer(first), "the previous timer is no longer ours")
  T.eq(refreshes(), 1, "so it does not refresh again")
end)

T.it("a pending rebuild is applied on the heartbeat, not on every stray timer", function()
  local app, _ = timerRig()
  local syncs = 0
  app.syncPanels = function() syncs = syncs + 1 end
  app.rebuildPending = true
  app:onTimer(app.staleTimer + 77)
  T.eq(syncs, 0, "a foreign timer does not trigger a rebuild")
  app:onTimer(app.staleTimer)
  T.eq(syncs, 1, "ours does")
end)

T.suite("telemetry link")

T.it("accepts a telemetry payload and tracks its age", function()
  local cfg = UiConfig.withDefaults({})
  local link = Link.new(cfg, quietLog())
  T.eq(link:age(), math.huge, "nothing yet")
  T.isTrue(link:isStale(), "so it is stale")
  local kind = link:onMessage(3, telemetry(), cfg.comms.telemetryProtocol)
  T.eq(kind, "telemetry", "recognised")
  T.isTrue(link:age() < 500, "fresh")
  T.isFalse(link:isStale(), "not stale")
  T.eq(link.flightId, 3, "remembers who is flying")
end)

T.it("ignores a foreign or malformed payload", function()
  local cfg = UiConfig.withDefaults({})
  local link = Link.new(cfg, quietLog())
  T.isNil(link:onMessage(3, { proto = "other" }, cfg.comms.telemetryProtocol), "wrong protocol tag")
  T.isNil(link:onMessage(3, "hello", cfg.comms.telemetryProtocol), "not a table")
  T.isNil(link:onMessage(3, telemetry(), "some_other_protocol"), "wrong rednet protocol")
  T.isTrue(link:isStale(), "nothing was accepted")
end)

T.it("records a command acknowledgement", function()
  local cfg = UiConfig.withDefaults({})
  local link = Link.new(cfg, quietLog())
  local kind = link:onMessage(3, { ack = true, cmd = "diskSave", detail = { saved = { "a" } } },
    cfg.comms.commandProtocol)
  T.eq(kind, "ack", "recognised")
  T.isTrue(link.lastAck.ack, "stored")
end)

T.it("the model always says whether its numbers can be trusted", function()
  local cfg = UiConfig.withDefaults({})
  local link = Link.new(cfg, quietLog())
  local empty = link:model()
  T.isFalse(empty.connected, "not connected before anything arrives")
  T.isTrue(empty.stale, "and stale")
  T.isNil(empty.telemetry, "with no payload")
  link:onMessage(3, telemetry(), cfg.comms.telemetryProtocol)
  local live = link:model()
  T.isTrue(live.connected, "connected")
  T.notNil(live.telemetry, "payload present")
end)

return true
