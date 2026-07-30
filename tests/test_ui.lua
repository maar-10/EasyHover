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
local Nav = require("ui.nav")
local App = require("app")
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
    selfTest = function(action) out[#out + 1] = { cmd = "selfTest", action = action } end,
    selfConfig = function(action) out[#out + 1] = { cmd = "selfConfig", action = action } end,
    dayNight = function() out[#out + 1] = { cmd = "dayNight" } end,
    vectorHold = function(action, id, axis, sign)
      out[#out + 1] = { cmd = "vectorHold", action = action, id = id, axis = axis, sign = sign }
    end,
    setAxes = function(id, swap, ix, iy)
      out[#out + 1] = { cmd = "setAxes", id = id, swap = swap, invertX = ix, invertY = iy }
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
  -- Every panel is enabled, including the unwritten ones. Whether a panel EXISTS is decided by
  -- app.lua's builder table, not by a flag in the operator's config file -- see Config.migrate.
  for _, name in ipairs(UiConfig.PANEL_ORDER) do
    T.isTrue(cfg.panels[name].enabled, name .. " is enabled; the code decides what is built")
  end
end)

--- THE BLACK-SCREEN BUG, exactly as it reached the craft.
---
--- The first ui_main release shipped `nav = { enabled = false }`, so every computer that ran it
--- saved that into its config. When the nav panel went live the new `enabled = true` default
--- lost to the saved `false` -- because config is extend-never-replace, which is right. The
--- panel could still be assigned, the detach pass blanked the monitor, and no frame was ever
--- built: a permanently black screen, no error, every other panel fine.
T.it("a config saved when nav was reserved gets nav back", function()
  local onDisk = {
    version = 1,
    panels = {
      overhead = { monitors = { "monitor_0" }, textScale = 0.5, enabled = true },
      config = { monitors = { "monitor_2" }, textScale = 0.5, enabled = true },
      nav = { monitors = { "monitor_1" }, textScale = 0.5, enabled = false },
      pfd = { monitors = {}, textScale = 0.5, enabled = false },
      autopilot = { monitors = {}, textScale = 0.5, enabled = false },
    },
  }
  local cfg = UiConfig.withDefaults(onDisk)
  T.isTrue(cfg.panels.nav.enabled, "nav is enabled again, so a frame gets built for it")
  T.eq(cfg.panels.nav.monitors[1], "monitor_1", "and the assignment it already had survived")
  T.eq(cfg.panels.overhead.monitors[1], "monitor_0", "every other assignment untouched")
  T.eq(cfg.version, 2, "and the file records that it has been migrated")
end)

T.it("migration is idempotent and leaves a current config alone", function()
  local first = UiConfig.withDefaults({ version = 1, panels = { nav = { enabled = false } } })
  local again = UiConfig.withDefaults(first)
  T.isTrue(again.panels.nav.enabled, "still enabled")
  T.eq(again.version, 2, "still version 2")
  local _, changed = UiConfig.migrate(again)
  T.isFalse(changed, "a version 2 config needs no further migration")
end)

T.it("migration keeps the monitor assignments of a disabled panel", function()
  -- The reason it re-enables rather than clearing: the operator may have assigned the panel
  -- BEFORE it went live, and that assignment is a real choice worth keeping.
  local cfg = UiConfig.withDefaults({
    version = 1,
    panels = { autopilot = { monitors = { "monitor_2" }, enabled = false } },
  })
  T.eq(cfg.panels.autopilot.monitors[1], "monitor_2", "assignment survived the migration")
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
  -- Disabled EXPLICITLY. No panel ships disabled any more: `enabled` is still the mechanism for
  -- switching a screen off, but it stopped being the marker for "not written yet" -- storing
  -- that in a config file is what left nav permanently black.
  UiConfig.assign(cfg, "pfd", "monitor_0")
  cfg.panels.pfd.enabled = false
  local monitors = Monitors.new(cfg, quietLog(), basalt)
  local instances = monitors:buildPanel("pfd", function() return { update = function() end } end)
  T.eq(#instances, 0, "nothing built for a disabled panel")
  monitors:clear()
end)

T.it("sync builds a frame for every implemented panel it is given", function()
  mock.reset()
  _G.peripheral = mock.install()
  local cfg = UiConfig.withDefaults({})
  UiConfig.assign(cfg, "nav", "monitor_0")
  local monitors = Monitors.new(cfg, quietLog(), basalt)
  local built = {}
  local builders = {}
  for _, name in ipairs(App.implementedPanels()) do
    builders[name] = function() built[name] = true; return { update = function() end } end
  end
  monitors:sync(builders)
  T.eq(monitors:count("nav"), 1, "nav got its frame -- this is the black-screen regression")
  T.isTrue(built.nav, "and its builder really ran")
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
                   "ALT+GIMBAL", "FUEL TANK", "OPTICAL", "THR AXES", "KEYS", "DISK" }
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

T.it("velocity axes are named by WHAT THEY MEASURE, not by a letter", function()
  -- x/y/z depends on whose convention you use and which way the sensor is bolted on. The keys
  -- stay x/y/z because the control code reads velocity.x and velocity.z.
  local byKey = {}
  for _, slot in ipairs(ConfigPanel.SECTION_SLOTS.velocity.slots) do byKey[slot.key] = slot end
  T.eq(byKey.z.label, "MEDIAL", "forward/back is medial")
  T.eq(byKey.z.hint, "forward / back", "and says so")
  T.eq(byKey.x.label, "LATERAL", "sideways is lateral")
  T.eq(byKey.x.hint, "left / right", "and says so")
  T.eq(byKey.y.label, "VERTICAL", "spelled in full -- an abbreviation reads as a typo")
  T.eq(byKey.y.hint, "up / down", "and vertical says so")
  T.eq(ConfigPanel.SECTION_SLOTS.velocity.slots[1].key, "z",
    "medial is offered first -- it is the one the brake law needs most")
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


-- ----------------------------------------------------------- thruster axes

T.suite("thruster orientation")

local function axesRig(rows)
  local panel, commands = configRig()
  local m = model()
  m.telemetry.thrusterAxes = rows or {
    { index = 1, id = "lift_fl", group = "lift", key = "fl",
      swap = false, invertX = false, invertY = false },
    { index = 2, id = "lift_fr", group = "lift", key = "fr",
      swap = true, invertX = false, invertY = true },
  }
  panel.update(m)
  return panel, commands
end

T.it("lists each thruster with its current nozzle mapping", function()
  local panel = axesRig()
  local rows = panel.elements.axesRows
  T.isTrue(rows[1].label:getText():find("LIFFL") ~= nil,
    "names the slot: " .. rows[1].label:getText())
  T.eq(rows[1].swap:getBackground(), Theme.buttonBg, "not swapped")
  T.eq(rows[2].swap:getBackground(), Theme.accent, "swapped, and it shows")
  T.eq(rows[2].invY:getBackground(), Theme.accent, "Y inverted, and it shows")
  T.eq(rows[2].invX:getBackground(), Theme.buttonBg, "X is not")
end)

T.it("SWP sends setAxes for that thruster, toggling only the swap", function()
  local panel, commands = axesRig()
  click(panel.elements.axesRows[1].swap)
  T.eq(commands[1].cmd, "setAxes", "the right command")
  T.eq(commands[1].id, "lift_fl", "addressed BY ID, not by list index")
  T.eq(commands[1].swap, true, "swap toggled on")
  T.eq(commands[1].invertX, false, "and the sign flips left alone")
  T.eq(commands[1].invertY, false)
end)

T.it("-X and -Y each toggle only themselves", function()
  local panel, commands = axesRig()
  click(panel.elements.axesRows[1].invX)
  T.eq(commands[1].invertX, true, "X flipped")
  T.eq(commands[1].swap, false, "swap untouched")

  click(panel.elements.axesRows[1].invY)
  T.eq(commands[2].invertY, true, "Y flipped")
  T.eq(commands[2].invertX, false, "and X is back to what the craft reports")
end)

T.it("toggling OFF an already-set flag turns it off", function()
  local panel, commands = axesRig()
  click(panel.elements.axesRows[2].invY)     -- row 2 has invertY = true
  T.eq(commands[1].invertY, false, "turned off, not blindly set")
end)

T.it("says so when nothing is configured yet", function()
  local panel = axesRig({})
  T.isTrue(panel.elements.axesFooter:getText():find("no thrusters") ~= nil,
    "footer: " .. panel.elements.axesFooter:getText())
  T.isFalse(panel.elements.axesRows[1].label:getVisible(), "and draws no rows")
end)

T.it("pages when there are more thrusters than rows", function()
  local many = {}
  for i = 1, 40 do
    many[i] = { index = i, id = "lift_" .. i, group = "lift", key = tostring(i),
                swap = false, invertX = false, invertY = false }
  end
  local panel = axesRig(many)
  T.isTrue(panel.elements.axesFooter:getText():find("pg 1/") ~= nil,
    "page indicator: " .. panel.elements.axesFooter:getText())
end)

-- ------------------------------------------------------------ typewriter keys

T.suite("typewriter keybinds")

local function keysRig(bindings)
  local panel, commands = configRig()
  local m = model()
  m.telemetry.config.typewriterBindings = bindings or {
    pitchUp = "s", pitchDown = "w", rollLeft = "a", rollRight = "d",
    yawLeft = "q", yawRight = "e", climb = "space", descend = "leftShift",
    accelerate = "r", decelerate = "f", brake = "b",
    cycleFeel = "m", toggleLateral = "n", toggleAssist = "h",
    gear = "g", lights = "l", engineMaster = "z",
  }
  panel.update(m)
  return panel, commands, panel.sections.keys
end

T.it("the KEYS menu entry opens the keybind page", function()
  local panel = configRig()
  panel.update(model())
  T.notNil(panel.pages.keys, "the page is exposed")
  click(menuRowFor(panel, "KEYS"))
  T.isTrue(panel.pages.keys:getVisible(), "and the menu entry reaches it")
end)

T.it("lists every remappable action with the key it is bound to", function()
  local panel, _, keys = keysRig()
  T.eq(keys.elements.title:getText(), "TYPEWRITER", "title")
  T.eq(#ConfigPanel.TYPEWRITER_ACTIONS, 17, "every action the bindings table holds")
  local shown = {}
  for _, row in ipairs(keys.rows) do
    if row.button:getVisible() then shown[#shown + 1] = row.button:getText() end
  end
  T.isTrue(#shown > 0, "rows drawn")
  T.isTrue(shown[1]:find("PITCH%+") ~= nil, "first action: " .. shown[1])
  T.isTrue(shown[1]:find("s") ~= nil, "with its key")
end)

T.it("every action name matches a real binding field", function()
  -- A typo here is a control that silently never remaps, so it is worth asserting against the
  -- flight side's own default set rather than trusting the two lists to stay in step.
  local defaults = {
    pitchUp = true, pitchDown = true, rollLeft = true, rollRight = true,
    yawLeft = true, yawRight = true, climb = true, descend = true,
    accelerate = true, decelerate = true, brake = true, cycleFeel = true,
    toggleLateral = true, toggleAssist = true, gear = true, lights = true,
    engineMaster = true,
  }
  for _, action in ipairs(ConfigPanel.TYPEWRITER_ACTIONS) do
    T.isTrue(defaults[action.key], "bindings has a field named " .. action.key)
    defaults[action.key] = nil
  end
  local leftover = {}
  for name in pairs(defaults) do leftover[#leftover + 1] = name end
  T.eq(#leftover, 0, "and none is missing from the page: " .. table.concat(leftover, ", "))
end)

T.it("picking a key sends configSet for that action's binding", function()
  local panel, commands, keys = keysRig()
  click(keys.rows[1].button)                    -- PITCH+
  T.eq(keys.page(), "candidates", "opened the key list")
  T.eq(keys.elements.title:getText(), "PITCH UP", "for the action tapped")

  local target
  for _, row in ipairs(keys.rows) do
    if row.button:getVisible() and row.name == "space" then target = row.button end
  end
  T.notNil(target, "space is offered")
  click(target)
  T.eq(commands[1].cmd, "configSet", "sends configSet")
  T.eq(commands[1].path, "input.typewriter.bindings.pitchUp", "for the right binding")
  T.eq(commands[1].value, "space", "with the key that was tapped")
end)

T.it("offers the keys a pilot reaches for, and keeps their HEAD when truncating", function()
  local _, _, keys = keysRig()
  local offered = {}
  for _, name in ipairs(ConfigPanel.KEY_NAMES) do offered[name] = true end
  for _, name in ipairs({ "space", "leftShift", "rightShift", "leftCtrl", "a", "z",
                          "one", "up", "f1" }) do
    T.isTrue(offered[name], name .. " is offered")
  end
  -- leftShift and rightShift differ at the FRONT; tail-truncating would render them alike.
  T.isTrue(#ConfigPanel.KEY_NAMES > 50, "a usable range of keys")
end)

T.it("SHOWS A CONFLICT when two actions share one key", function()
  -- The craft reports this as a keybind "problem" and flies on. The pilot should see it on the
  -- screen where they caused it, not discover it in the air.
  local panel, _, keys = keysRig({
    pitchUp = "s", pitchDown = "s",         -- the same key twice
    rollLeft = "a", rollRight = "d",
  })
  local subtitle = keys.elements.subtitle:getText()
  T.isTrue(subtitle:find("s:") ~= nil, "names the key: " .. subtitle)
  T.eq(keys.elements.subtitle:getForeground(), Theme.warning, "and flags it as a problem")
end)

T.it("says how many are bound when there is no conflict", function()
  local _, _, keys = keysRig()
  T.eq(keys.elements.subtitle:getText(), "17 of 17 set", "all bound")
  T.eq(keys.elements.subtitle:getForeground(), Theme.ok, "and says so calmly")
end)

T.it("an unbound action reads as unset rather than as blank", function()
  local _, _, keys = keysRig({ pitchUp = "s" })
  T.eq(keys.elements.subtitle:getText(), "1 of 17 set", "counts what is bound")
end)


-- ------------------------------------------------------------------ nav

T.suite("nav panel and the pre-flight tests")

local navAck = nil

local function navRig(width, height)
  mock.reset()
  _G.peripheral = mock.install()
  navAck = nil
  local cfg = UiConfig.withDefaults({})
  local monitor = mock.monitor(width or 29, height or 19)
  local frame = basalt.createFrame()
  frame:setTerm(monitor)
  local commands, actions = sent()
  local panel = Nav.build(frame, {
    cfg = cfg, actions = actions, log = quietLog(),
    lastAck = function() return navAck end,
  })
  return panel, commands
end

--- Telemetry with pilot state and an optional self-test block.
local function navModel(pilot, selfTest)
  local m = model()
  m.telemetry.pilot = pilot or {
    axes = { pitch = 0, roll = 0, yaw = 0, climb = 0, accel = 0 },
    brake = false, controller = false, typewriter = true,
  }
  m.telemetry.selfTest = selfTest or { running = false }
  return m
end

T.it("says so when there is no nav link rather than drawing decoration", function()
  local panel = navRig()
  panel.update(navModel())
  T.isTrue(panel.elements.placeholder:getText():find("no nav link") ~= nil,
    "says so rather than drawing decoration: " .. panel.elements.placeholder:getText())
end)

--- THE STANDARD SINGLE MONITOR: one block at text scale 0.5 is 15x10, and the panel's floor was
--- 14x12 -- so the default cockpit screen showed "TOO SMALL" and nothing else.
T.it("fits the standard single monitor, 15x10", function()
  local panel = navRig(15, 10)
  panel.update(navModel())
  T.notNil(panel.pages.nav, "the nav page exists rather than a TOO SMALL notice")
  T.isTrue(panel.pages.nav:getVisible(), "and it is the page on show")
end)

--- The dangerous one. The bar loop stopped at `height - 5`, so a 10-row monitor drew three bars
--- and silently dropped roll and yaw -- a dead roll input would have passed the very test that
--- exists to catch it.
T.it("shows every flight axis at every size, or none at all", function()
  for _, size in ipairs({ { 15, 10 }, { 15, 12 }, { 29, 12 }, { 29, 19 }, { 51, 19 } }) do
    local panel = navRig(size[1], size[2])
    panel.update(navModel({
      axes = { accel = 0.5, climb = -0.5, pitch = 0.25, roll = -0.75, yaw = 0.1 },
      brake = false, controller = false, typewriter = true,
    }))
    for _, axis in ipairs(Nav.AXES) do
      T.notNil(panel.bars[axis.key],
        ("%dx%d: %s has no bar -- a dead input would pass unnoticed"):format(
          size[1], size[2], axis.label))
    end
  end
end)

--- The four screens now live in the BIT/CONF menu, stacked one per row, so every full label fits
--- and none hangs past the edge -- the failure that made "FCS T SELFT AXI" on a narrow monitor.
T.it("the BIT/CONF menu entries stay readable and on-screen at every width", function()
  for _, size in ipairs({ { 15, 20 }, { 18, 16 }, { 25, 19 }, { 26, 19 }, { 29, 19 }, { 51, 19 } }) do
    local width = size[1]
    local panel = navRig(width, size[2])
    panel.update(navModel())
    local labels = { ["FCS TEST"] = false, ["SELF TEST"] = false,
      ["AXIS MAP"] = false, ["SELF CONFIG"] = false }
    for _, button in ipairs(panel.buttons or {}) do
      local text = button:getText()
      T.notNil(labels[text], ("%dx%d: %q is not a full label"):format(width, size[2], text))
      labels[text] = true
      local right = button:getX() + button:getWidth() - 1
      T.isTrue(right <= width,
        ("%dx%d: %s ends at %d, past the edge"):format(width, size[2], text, right))
    end
    for name, seen in pairs(labels) do
      T.isTrue(seen, ("%dx%d: %s missing"):format(width, size[2], name))
    end
    -- The nav view itself carries just the one door to them.
    T.eq(panel.bitButton:getText(), "BIT/CONF", ("%dx%d: nav has BIT/CONF"):format(width, size[2]))
  end
end)

T.it("BIT/CONF opens a menu, and each entry replaces the nav view", function()
  local panel = navRig()
  panel.update(navModel())
  T.isTrue(panel.pages.nav:getVisible(), "nav is up first")

  panel.show(panel.pages.bit)
  T.isTrue(panel.pages.bit:getVisible(), "the BIT/CONF menu opens")
  T.isFalse(panel.pages.nav:getVisible(), "nav is hidden behind it")

  panel.show(panel.pages.fcs)
  T.isTrue(panel.pages.fcs:getVisible(), "FCS TEST replaces it")

  panel.show(panel.pages.config)
  T.isTrue(panel.pages.config:getVisible(), "SELF CONFIG too")
  T.isFalse(panel.pages.fcs:getVisible(), "one at a time")
end)

-- --------------------------------------------------------------- self axis config BIP

T.it("SELF CONFIG shows the prereq verdict and only offers ACCEPT with a proposal", function()
  local panel = navRig()
  local m = navModel()

  m.telemetry.selfConfigPrereqs = { ok = false, missing = { "ENGINE OFF", "NO FUEL" }, nozzles = 0 }
  panel.update(m)
  T.isTrue(panel.elements.cfgStatus:getText():find("NO GO") ~= nil, "NO GO! is shown")
  T.isFalse(panel.elements.cfgAccept:getVisible(), "no ACCEPT without a proposal")

  m.telemetry.selfConfigPrereqs = { ok = true, missing = {}, nozzles = 4 }
  panel.update(m)
  T.isTrue(panel.elements.cfgStatus:getText():find("READY") ~= nil, "READY! is shown")

  m.telemetry.selfConfig = { running = true, phase = "probe", index = 2, total = 4, current = "lift_fr" }
  panel.update(m)
  T.eq(panel.elements.cfgStart:getText(), "STOP", "START becomes STOP while running")

  m.telemetry.selfConfig = { running = false, complete = true, proposed = 1,
    proposal = { lift_fl = { id = "lift_fl", vectorMap = { x = "z", y = "x" },
      invertVectorX = false, invertVectorY = true } } }
  panel.update(m)
  T.isTrue(panel.elements.cfgStatus:getText():find("PROPOSED") ~= nil, "the proposal is announced")
  T.isTrue(panel.elements.cfgAccept:getVisible(), "ACCEPT is offered")
  T.isTrue(panel.elements.cfgDiscard:getVisible(), "so is DISCARD")
end)

T.it("SELF CONFIG buttons send the right commands", function()
  local panel, commands = navRig()
  panel.update(navModel())

  click(panel.elements.cfgCheck)
  T.eq(commands[#commands].cmd, "selfConfig", "CHECK sends a selfConfig command")
  T.eq(commands[#commands].action, "checkPrereqs", "with the checkPrereqs action")

  click(panel.elements.cfgStart)
  T.eq(commands[#commands].action, "start", "START sends start")

  -- While running, the same button aborts.
  local m = navModel()
  m.telemetry.selfConfig = { running = true, phase = "float", index = 1, total = 4 }
  panel.update(m)
  click(panel.elements.cfgStart)
  T.eq(commands[#commands].action, "abort", "STOP sends abort while running")
end)

-- --------------------------------------------------------------- heading tape

T.it("the compass is the aviation standard: N at 0, clockwise", function()
  T.eq(Nav.cardinal(0), "N", "000 is north")
  T.eq(Nav.cardinal(90), "E", "090 is east")
  T.eq(Nav.cardinal(180), "S", "180 is south")
  T.eq(Nav.cardinal(270), "W", "270 is west")
  T.eq(Nav.cardinal(45), "NE", "045 is north-east")
  T.eq(Nav.cardinal(360), "N", "360 wraps to north")
end)

T.it("headings read 001..360, north as 360 not 000", function()
  T.eq(Nav.disp3(0), "360", "north shows as 360")
  T.eq(Nav.disp3(360), "360", "so does 360")
  T.eq(Nav.disp3(5), "005", "zero-padded")
  T.eq(Nav.disp3(271), "271", "an exact heading")
end)

T.it("the heading tape centres the exact heading with its cardinal", function()
  local tape = Nav.headingTape(270, 48)
  T.eq(#tape, 48, "exactly the monitor width")
  T.isTrue(tape:find("|270W|", 1, true) ~= nil, "the box shows 270W: " .. tape)
  T.isTrue(tape:find("265", 1, true) ~= nil, "a lower tick is visible")
  T.isTrue(tape:find("275", 1, true) ~= nil, "a higher tick is visible")

  -- The centre box lands in the middle of the tape, not off to one side.
  local at = tape:find("|270W|", 1, true)
  T.isTrue(at > 15 and at < 30, "the box is centred, at column " .. at)
end)

T.it("the tape scrolls as the heading changes, and blanks with no heading", function()
  T.isTrue(Nav.headingTape(270, 29) ~= Nav.headingTape(275, 29), "different headings differ")
  T.isTrue(Nav.headingTape(271, 29):find("|271", 1, true) ~= nil, "shows the exact heading 271")
  T.eq(Nav.headingTape(nil, 15), ("-"):rep(15), "no heading -> dashes, full width")
end)

T.it("the two clocks format as hh:mm, and say so when there is no time", function()
  T.eq(Nav.clockText(6.5), "06:30", "6.5 hours is half past six")
  T.eq(Nav.clockText(0), "00:00", "midnight")
  T.eq(Nav.clockText(13.25), "13:15", "quarter past one")
  T.eq(Nav.clockText(nil), "--:--", "no time source")
end)

-- --------------------------------------------------------------- nav view

--- A model carrying a nav fix and the two clocks, as the app assembles it.
local function navFixModel(nav, clock)
  local m = navModel()
  m.nav = nav
  m.clock = clock or { irl = 14.5, mc = 6.0, day = 3 }
  return m
end

T.it("the nav view shows the tape, position and clocks from the nav fix", function()
  local panel = navRig(51, 19)
  panel.update(navFixModel({
    stale = false, heading = 271, headingSource = "navtable",
    position = { x = 128, y = 74, z = -344, source = "gps" }, waypointCount = 2,
  }))
  T.isTrue(panel.elements.headingTape:getText():find("|271", 1, true) ~= nil, "tape shows 271")
  T.isTrue(panel.elements.headingDetail:getText():find("true N") ~= nil, "source is true north")
  T.isTrue(panel.elements.navPos:getText():find("128") ~= nil, "position x is shown")
  T.isTrue(panel.elements.times:getText():find("14:30") ~= nil, "IRL clock")
  T.isTrue(panel.elements.times:getText():find("06:00") ~= nil, "MC clock")
end)

T.it("a stale nav fix says so instead of showing a frozen heading", function()
  local panel = navRig(51, 19)
  panel.update(navFixModel({ stale = true, heading = 271,
    position = { x = 1, y = 2, z = 3 } }))
  T.eq(panel.elements.headingTape:getText(), ("-"):rep(51), "tape blanks when the fix is stale")
  T.isTrue(panel.elements.headingDetail:getText():find("STALE") ~= nil, "and says STALE")
end)

T.it("the DAY/NGT button reflects the mode and toggling it re-themes", function()
  Theme.setMode("day")
  local panel, commands = navRig()
  panel.update(navFixModel(nil))
  T.eq(panel.elements.dayNight:getText(), "DAY", "shows the current mode")
  click(panel.elements.dayNight)
  T.eq(commands[#commands].cmd, "dayNight", "the button fires the day/night action")

  Theme.setMode("night")
  panel.update(navFixModel(nil))
  T.eq(panel.elements.dayNight:getText(), "NGT", "night mode shows NGT")
  Theme.setMode("day")     -- leave the shared Theme as we found it
end)

-- --------------------------------------------------------------- FCS test

T.it("draws every pilot axis from the craft's OWN state", function()
  local panel = navRig()
  panel.update(navModel({
    axes = { pitch = 0.5, roll = -1, yaw = 0, climb = 0.25, accel = -0.75 },
    brake = false, typewriter = true,
  }))
  T.eq(panel.bars.accel.value:getText(), "-0.75", "throttle in reverse")
  T.eq(panel.bars.roll.value:getText(), "-1.00", "full left roll")
  T.eq(panel.bars.climb.value:getText(), " 0.25", "a quarter climb")
  T.eq(panel.bars.yaw.value:getText(), " 0.00", "and a centred axis reads zero")
end)

T.it("the throttle bar is SIGNED, so reverse cannot look like neutral", function()
  local panel = navRig()
  panel.update(navModel({ axes = { accel = -1, pitch = 0, roll = 0, yaw = 0, climb = 0 } }))
  local reverse = panel.bars.accel.bar:getText()
  panel.update(navModel({ axes = { accel = 0, pitch = 0, roll = 0, yaw = 0, climb = 0 } }))
  local neutral = panel.bars.accel.bar:getText()
  panel.update(navModel({ axes = { accel = 1, pitch = 0, roll = 0, yaw = 0, climb = 0 } }))
  local forward = panel.bars.accel.bar:getText()
  T.isFalse(reverse == neutral, "full reverse does not look like neutral")
  T.isFalse(forward == reverse, "nor like full forward")
  T.isTrue(neutral:find("|") ~= nil, "and the centre is marked")
end)

T.it("shows the brake as HELD only when the craft says it is", function()
  local panel = navRig()
  panel.update(navModel({ axes = {}, brake = false }))
  T.isTrue(panel.elements.brake:getText():find("off") ~= nil, "off")
  panel.update(navModel({ axes = {}, brake = true }))
  T.isTrue(panel.elements.brake:getText():find("HELD") ~= nil, "held")
  T.eq(panel.elements.brake:getForeground(), Theme.warning, "and stands out")
end)

T.it("names which input device the craft is actually hearing", function()
  -- A dead typewriter looks exactly like a pilot not touching anything, until you can see this.
  local panel = navRig()
  panel.update(navModel({ axes = {}, controller = false, typewriter = false }))
  T.isTrue(panel.elements.source:getText():find("no input") ~= nil,
    "says when nothing is connected: " .. panel.elements.source:getText())
  T.eq(panel.elements.source:getForeground(), Theme.warning, "and flags it")
  panel.update(navModel({ axes = {}, controller = true, typewriter = true }))
  T.isTrue(panel.elements.source:getText():find("ctrl") ~= nil, "and lists both when both are")
end)

T.it("BLANKS the bars when the link is down, rather than freezing them", function()
  local panel = navRig()
  panel.update(navModel({ axes = { accel = 0.9, pitch = 0, roll = 0, yaw = 0, climb = 0 } }))
  T.eq(panel.bars.accel.value:getText(), " 0.90", "live")
  panel.update({ stale = true, ageMs = math.huge, telemetry = nil })
  T.eq(panel.bars.accel.value:getText(), "  --", "blanked, not left at the last good value")
  T.isTrue(panel.elements.fcsStale:getText():find("NO DATA") ~= nil, "and says why")
end)

-- -------------------------------------------------------------- self test

T.it("START asks the craft to run the sweep", function()
  local panel, commands = navRig()
  panel.update(navModel())
  click(panel.elements.start)
  T.eq(commands[1].cmd, "selfTest", "sends the command")
  T.eq(commands[1].action, "start", "to start")
end)

T.it("lists the three steps and marks progress through them", function()
  local panel = navRig()
  panel.update(navModel(nil, { running = true, step = 2, steps = 3,
    label = "LATERAL THRUSTERS", phase = "X sweep", stepRemainingMs = 7000,
    watch = "front pair, then rear" }))
  T.isTrue(panel.elements.steps[1]:getText():find("^%+") ~= nil,
    "step 1 is done: " .. panel.elements.steps[1]:getText())
  T.isTrue(panel.elements.steps[2]:getText():find("^>") ~= nil,
    "step 2 is running: " .. panel.elements.steps[2]:getText())
  T.eq(panel.elements.steps[2]:getForeground(), Theme.accent, "and highlighted")
  T.isTrue(panel.elements.steps[3]:getText():find("^  ") ~= nil, "step 3 is still to come")
end)

T.it("shows the phase and a countdown for the step", function()
  local panel = navRig()
  panel.update(navModel(nil, { running = true, step = 1, steps = 3,
    label = "LIFT THRUSTERS", phase = "Y sweep", stepRemainingMs = 7400,
    watch = "all four lift nozzles" }))
  T.isTrue(panel.elements.timer:getText():find("Y sweep") ~= nil,
    "which axis is sweeping: " .. panel.elements.timer:getText())
  T.isTrue(panel.elements.timer:getText():find("7s") ~= nil, "and the seconds left")
  T.isTrue(panel.elements.watch:getText():find("lift nozzles") ~= nil, "and what to look at")
  T.eq(panel.elements.start:getText(), "RUNNING", "the start button reflects it")
end)

T.it("reports which thrusters could actually be swept", function()
  -- A group whose thrusters have no nozzle is the interesting answer, so it is the reported one.
  local panel = navRig()
  panel.update(navModel(nil, { running = false, complete = true, findings = {
    lift = { count = 4, vectoring = { "a", "b", "c", "d" }, plain = {} },
    lateral = { count = 4, vectoring = { "a", "b" }, plain = { "c", "d" } },
    main = { count = 4, vectoring = {}, plain = { "a", "b", "c", "d" } },
  } }))
  local text = panel.elements.result:getText()
  T.isTrue(text:find("lif 4/4") ~= nil, "all four lift nozzles moved: " .. text)
  T.isTrue(text:find("mai 0/4") ~= nil, "and none of the accelerators have nozzles: " .. text)
  T.eq(panel.elements.status:getText(), "complete", "and the run is reported complete")
end)

T.it("SHOWS THE CRAFT'S REFUSAL -- only it knows whether it is airborne", function()
  local panel = navRig(51, 19)
  panel.update(navModel())
  navAck = { ack = false, cmd = "selfTest",
             detail = { error = "on the ground only, with the engine off",
                        errorShort = "ON GROUND ONLY" } }
  panel.update(navModel())
  T.isTrue(panel.elements.status:getText():find("engine off") ~= nil,
    "the craft's own words where they fit: " .. panel.elements.status:getText())
  T.eq(panel.elements.status:getForeground(), Theme.warning, "flagged as a refusal")
end)

--- THE ONE THAT REACHED THE CRAFT. Tail-fitting "<id> is producing thrust (0.40) -- cut the
--- engine first" to a 15-column monitor produced "he engine first", which reads as an instruction
--- to START the engine -- the exact opposite of the interlock, on a test that must run with the
--- engine off and no thrust at all. A refusal that inverts under truncation is worse than none.
T.it("never truncates a refusal into its own opposite", function()
  for _, size in ipairs({ { 15, 10 }, { 22, 12 }, { 29, 19 }, { 51, 19 } }) do
    local panel = navRig(size[1], size[2])
    panel.update(navModel())
    navAck = { ack = false, cmd = "selfTest",
               detail = { error = "lift_fl is making thrust (0.40) -- cut the engine",
                          errorShort = "CUT THE ENGINE" } }
    panel.update(navModel())
    local long = "lift_fl is making thrust (0.40) -- cut the engine"
    local text = panel.elements.status:getText()
    T.isTrue(#text <= size[1], ("%dx%d: %q overflows"):format(size[1], size[2], text))
    -- PIN THE MECHANISM, not a keyword. Asserting `text:find("cut")` passed even with the old
    -- tail-fit restored, because the tail of this particular sentence happens to contain "cut" --
    -- a false green that hid the regression it was written for. When the long form does not fit,
    -- the text must be the craft's SHORT form, never a substring of the long one.
    if #long > size[1] then
      T.eq(text, Theme.fit("CUT THE ENGINE", size[1]),
        ("%dx%d: showed a cut of the long form instead of the short one"):format(
          size[1], size[2]))
    else
      T.eq(text, Theme.fit(long, size[1]), "it fits, so show all of it")
    end
  end
end)

--- "LIFT THRUSTERS" names the group but never says a test is under way, so a stopped screen and a
--- running one read almost the same.
T.it("SAYS it is testing, and which of the three", function()
  for _, size in ipairs({ { 15, 10 }, { 29, 19 }, { 51, 19 } }) do
    local panel = navRig(size[1], size[2])
    panel.update(navModel(nil, { running = true, step = 2, steps = 3, label = "LATERAL THRUSTERS",
      phase = "X sweep", stepRemainingMs = 9000, remainingMs = 24000, moving = 4, groupCount = 4,
      writeFails = 0 }))
    local text = panel.elements.status:getText()
    T.isTrue(text:find("TESTING") ~= nil, ("%dx%d: %q"):format(size[1], size[2], text))
    T.isTrue(text:find("2/3") ~= nil, "and which step: " .. text)
    T.isTrue(#text <= size[1], "within the width")
  end
end)

T.it("counts down the step AND the whole run, at every width", function()
  for _, size in ipairs({ { 15, 10 }, { 29, 19 }, { 51, 19 } }) do
    local panel = navRig(size[1], size[2])
    local function at(stepMs, allMs)
      panel.update(navModel(nil, { running = true, step = 1, steps = 3, label = "LIFT THRUSTERS",
        phase = "X sweep", stepRemainingMs = stepMs, remainingMs = allMs, moving = 4,
        groupCount = 4, writeFails = 0 }))
      return panel.elements.timer:getText()
    end
    local first = at(12000, 42000)
    local later = at(6000, 36000)
    T.isTrue(#first <= size[1], ("%dx%d overflows: %q"):format(size[1], size[2], first))
    T.isTrue(first ~= later, "the countdown changes as time passes")
    -- BOTH numbers survive: a countdown truncated to one cannot say whether the run is nearly over
    T.isTrue(first:find("12") ~= nil, "step seconds shown: " .. first)
    T.isTrue(first:find("42") ~= nil, "total seconds shown: " .. first)
  end
end)

T.it("says STALLED rather than counting down over a run nothing is driving", function()
  local panel = navRig(15, 10)
  panel.update(navModel(nil, { running = true, step = 1, steps = 3, label = "LIFT THRUSTERS",
    phase = "X sweep", stepRemainingMs = 9000, remainingMs = 30000, moving = 4, groupCount = 4,
    writeFails = 0, sinceTickMs = 12000 }))
  T.eq(panel.elements.status:getText(), Theme.fit("STALLED", 15),
    "got: " .. panel.elements.status:getText())
  T.eq(panel.elements.status:getForeground(), Theme.warning, "flagged")
end)

--- The stamp beside BACK was answering the wrong question: nav.lua runs on the UI computer, so it
--- named the UI's build while the page drives a FLIGHT-computer function. The craft's build now
--- rides in every telemetry frame.
T.it("shows the CRAFT's build, and flags a mismatch", function()
  local panel = navRig(29, 19)
  local m = navModel()
  m.telemetry.build = "deadbeef"
  panel.update(m)
  T.notNil(panel.buildStamp, "the stamp exists at this width")
  T.eq(panel.buildStamp:getText(), "deadbeef", "and shows the CRAFT's build")
  T.eq(panel.buildStamp:getForeground(), Theme.warning,
    "flagged, because it differs from this computer's")

  -- matching builds are not flagged
  local same = navModel()
  same.telemetry.build = panel.buildStamp:getText()
  local panel2 = navRig(29, 19)
  local m2 = navModel()
  m2.telemetry.build = nil
  panel2.update(m2)
  T.notNil(panel2.buildStamp:getText(), "and with no craft build it still shows this computer's")
end)

T.it("says an aborted run was aborted, and why", function()
  local panel = navRig()
  panel.update(navModel(nil, { running = false, aborted = "aborted: the craft is flying" }))
  T.isTrue(panel.elements.status:getText():find("flying") ~= nil,
    "status: " .. panel.elements.status:getText())
  T.eq(panel.elements.start:getText(), "START", "and it can be started again")
end)

T.it("still builds on a small screen, and says so when it cannot", function()
  local panel = navRig(15, 20)
  T.notNil(panel.elements.start, "a 1x2 screen still gets the pages")
  panel.update(navModel())            -- must not throw
  local tiny = navRig(10, 6)
  T.isNil(tiny.elements.start, "a genuinely unusable screen says so instead")
  tiny.update(navModel())
end)

T.it("warns on the page that this is a ground-only procedure", function()
  local panel = navRig()
  T.isTrue(panel.elements.warn:getText():find("GROUND ONLY") ~= nil,
    "warning: " .. panel.elements.warn:getText())
end)


-- ---------------------------------------------------- nav: nozzle axis map

T.suite("nozzle axis map screen")

--- Two thrusters IN THE SAME GROUP by default, because the axis map pages per group -- a lift
--- and a main are no longer on the same page, which is the point of paging that way.
local function axisNavRig(hold, rows, width, height)
  local panel, commands = navRig(width, height)
  local m = navModel()
  m.telemetry.thrusterAxes = rows or {
    { index = 1, id = "lift_fl", group = "lift", key = "fl",
      swap = false, invertX = false, invertY = false },
    { index = 2, id = "lift_fr", group = "lift", key = "fr",
      swap = false, invertX = false, invertY = false },
  }
  m.telemetry.axisMap = hold or { holding = false }
  panel.update(m)
  return panel, commands
end

--- A full craft: four of each group, which is what the pilot actually has.
local function twelveThrusters()
  local out = {}
  local keys = { lift = { "fl", "fr", "bl", "br" }, lateral = { "l1", "l2", "r1", "r2" },
    main = { "m1", "m2", "m3", "m4" } }
  for _, group in ipairs({ "lift", "lateral", "main" }) do
    for _, key in ipairs(keys[group]) do
      out[#out + 1] = { index = #out + 1, id = group .. "_" .. key, group = group, key = key,
        swap = false, invertX = false, invertY = false }
    end
  end
  return out
end

T.it("is the third button on the nav border, and replaces the nav view", function()
  local panel = axisNavRig()
  panel.show(panel.pages.axisMap)
  T.isTrue(panel.pages.axisMap:getVisible(), "up")
  T.isFalse(panel.pages.nav:getVisible(), "and the nav view is not")
end)

T.it("offers all four nozzle deflections for every thruster", function()
  local panel = axisNavRig()
  local row = panel.axisRows[1]
  T.eq(#row.buttons, 4, "X+, X-, Y+, Y-")
  T.eq(row.buttons[1]:getText(), "X+")
  T.eq(row.buttons[4]:getText(), "Y-")
  -- "LIF:FL" where there is room for it, the bare key "FL" where there is not -- see the
  -- narrow-screen test below for why the group cannot simply always be included.
  T.isTrue(row.label:getText():find("FL") ~= nil, "named: " .. row.label:getText())
end)

--- Both lift rows used to read "LIF": the label was group..key fitted into the three columns a
--- 15-wide monitor can spare, so `fl` and `fr` were indistinguishable on the one screen whose
--- job is telling you which nozzle just moved.
T.it("distinguishes thrusters in the same group on a narrow screen", function()
  local panel = axisNavRig(nil, nil, 15, 10)
  local first = panel.axisRows[1].label:getText()
  local second = panel.axisRows[2].label:getText()
  T.isTrue(first ~= second, ("both rows read %q"):format(first))
  T.isTrue(first:find("FL") ~= nil, "the first is fl: " .. first)
  T.isTrue(second:find("FR") ~= nil, "the second is fr: " .. second)
end)

T.it("tapping a deflection LATCHES that nozzle", function()
  local panel, commands = axisNavRig()
  click(panel.axisRows[1].buttons[3])          -- Y+
  T.eq(commands[1].cmd, "vectorHold", "the right command")
  T.eq(commands[1].action, "latch", "latches")
  T.eq(commands[1].id, "lift_fl", "the thruster tapped")
  T.eq(commands[1].axis, "y", "on its Y axis")
  T.eq(commands[1].sign, 1, "positive")
end)

T.it("tapping the LATCHED one again releases it", function()
  -- There is no touch-release event on a monitor, so a second tap is the only way to let go.
  local panel, commands = axisNavRig({ holding = true, id = "lift_fl", axis = "y", sign = 1,
    direction = "FWD", group = "lift" })
  click(panel.axisRows[1].buttons[3])          -- the same Y+
  T.eq(commands[1].action, "release", "releases rather than re-latching")
end)

T.it("tapping a DIFFERENT deflection latches that one instead", function()
  local panel, commands = axisNavRig({ holding = true, id = "lift_fl", axis = "y", sign = 1,
    direction = "FWD", group = "lift" })
  click(panel.axisRows[1].buttons[1])          -- X+
  T.eq(commands[1].action, "latch", "latches the new one")
  T.eq(commands[1].axis, "x")
end)

T.it("LIGHTS UP with the direction the system currently believes", function()
  local panel = axisNavRig({ holding = true, id = "lift_fl", axis = "x", sign = 1,
    direction = "RIGHT", group = "lift" })
  local text = panel.elements.axisHolding:getText()
  T.isTrue(text:find("lift_fl") ~= nil, "names the thruster: " .. text)
  T.isTrue(text:find("%+X") ~= nil, "and the deflection")
  T.isTrue(text:find("RIGHT") ~= nil, "and what it is currently called")
  T.eq(panel.elements.axisHolding:getForeground(), Theme.ok, "lit")
end)

--- NOTHING EVER CHANGED THE PAGE. axisPageIndex was clamped and read but never written, so on a
--- 10-row monitor -- four rows to a page -- only the first four of twelve thrusters could be
--- reached. The footer said "pg 1/3" and there was no way to get to 2 or 3.
T.it("can reach every thruster on a screen too short to list them all", function()
  local panel = axisNavRig(nil, twelveThrusters(), 15, 10)
  T.notNil(panel.elements.axisNext, "there is a way forward")

  local seen, guard = {}, 0
  repeat
    for _, row in ipairs(panel.axisRows) do
      if row.entry then seen[row.entry.id] = true end
    end
    click(panel.elements.axisNext)
    guard = guard + 1
  until guard >= 12

  for _, entry in ipairs(twelveThrusters()) do
    T.isTrue(seen[entry.id], entry.id .. " is reachable")
  end
end)

T.it("pages by group, so bare keys are never ambiguous", function()
  -- The craft really does have a lift `fl` and a lateral `fl`; the row label is the key alone.
  local panel = axisNavRig(nil, twelveThrusters(), 15, 10)
  for _ = 1, 3 do
    local groups = {}
    for _, row in ipairs(panel.axisRows) do
      if row.entry then groups[row.entry.group] = true end
    end
    local count = 0
    for _ in pairs(groups) do count = count + 1 end
    T.eq(count, 1, "exactly one group on the page")
    T.isTrue(panel.elements.axisFooter:getText():len() > 0, "and it is named in the footer")
    click(panel.elements.axisNext)
  end
end)

T.it("hides the paging buttons when everything fits on one page", function()
  local panel = axisNavRig(nil, {
    { index = 1, id = "lift_fl", group = "lift", key = "fl" },
  }, 29, 19)
  T.isFalse(panel.elements.axisNext:getVisible(), "no paging needed, so no paging offered")
end)

T.it("marks the held deflection on the grid", function()
  local panel = axisNavRig({ holding = true, id = "lift_fl", axis = "x", sign = -1,
    direction = "LEFT", group = "lift" })
  T.eq(panel.axisRows[1].buttons[2]:getBackground(), Theme.warning, "X- is held")
  T.eq(panel.axisRows[1].buttons[1]:getBackground(), Theme.buttonBg, "X+ is not")
  T.eq(panel.axisRows[2].buttons[2]:getBackground(), Theme.buttonBg,
    "and neither is the same deflection on another thruster")
end)

T.it("shows THE CRAFT'S key legend rather than one of its own", function()
  -- The plane rule lives on the craft. A panel that hardcoded "a/d = left/right" would be
  -- lying on all four lateral thrusters, whose nozzles cannot point sideways at all.
  local panel = axisNavRig({ holding = true, id = "lateral_fl", axis = "x", sign = 1,
    direction = "DOWN", group = "lateral", legend = "a/d DOWN/UP w/s FWD/BACK" })
  T.isTrue(panel.elements.axisHint:getText():find("DOWN/UP") ~= nil,
    "a/d are down/up on a lateral: " .. panel.elements.axisHint:getText())

  panel = axisNavRig({ holding = true, id = "main_1", axis = "y", sign = 1,
    direction = "UP", group = "main", legend = "a/d LEFT/RIGHT w/s UP/DOWN" })
  T.isTrue(panel.elements.axisHint:getText():find("UP/DOWN") ~= nil,
    "and w/s are up/down on an accelerator: " .. panel.elements.axisHint:getText())
end)

T.it("goes quiet when nothing is held", function()
  local panel = axisNavRig({ holding = false })
  T.eq(panel.elements.axisHolding:getText(), "", "no lit panel")
  T.isTrue(panel.elements.axisHint:getText():find("tap a nozzle") ~= nil, "back to the prompt")
end)

T.it("BACK releases whatever is held rather than walking away from it", function()
  local panel, commands = axisNavRig({ holding = true, id = "lift_fl", axis = "x", sign = 1,
    direction = "RIGHT", group = "lift" })
  panel.show(panel.pages.axisMap)
  -- the BACK button is the first one on the page's bottom row
  click(panel.elements.axisRelease)
  T.eq(commands[1].action, "release", "RELEASE lets go")
end)

T.it("shows the craft's refusal instead of pretending it latched", function()
  local panel = axisNavRig({ holding = false,
    error = "lift_fl has no nozzle -- nothing to point" }, nil, 51, 19)
  T.isTrue(panel.elements.axisHolding:getText():find("nothing to point") ~= nil,
    "the craft's own words: " .. panel.elements.axisHolding:getText())
  T.eq(panel.elements.axisHolding:getForeground(), Theme.warning, "flagged")
end)

--- Same inversion as the self test: "nozzle mapping only runs on the ground, with the engine off"
--- tail-fitted to 15 columns read "with the engine".
T.it("keeps the ground-only refusal readable on a narrow screen", function()
  local panel = axisNavRig({ holding = false,
    error = "on the ground only, with the engine off",
    errorShort = "ON GROUND ONLY" }, nil, 15, 10)
  local text = panel.elements.axisHolding:getText()
  T.isTrue(#text <= 15, ("%q overflows"):format(text))
  T.eq(text, Theme.fit("ON GROUND ONLY", 15),
    "the craft's short form, not a cut of the long one: " .. text)
end)

T.it("says so when no thrusters are assigned yet", function()
  local panel = axisNavRig(nil, {})
  T.isTrue(panel.elements.axisFooter:getText():find("no thrusters") ~= nil,
    "footer: " .. panel.elements.axisFooter:getText())
end)

-- ------------------------------------------------------------ terminal panel

--- THE FOSSIL REFUSAL. lastAck was set on arrival and never cleared, so one "ALREADY RUNNING"
--- stayed on screen in red indefinitely -- long after the run behind it had ended. A pilot
--- pressing START then reads the fossil of an older press as the answer to this one, which is how
--- a working command and a refused one became indistinguishable.
T.it("sending a command clears the previous answer", function()
  local link = Link.new(UiConfig.withDefaults({}), quietLog())
  link.modem = "modem_0"
  local proto = link.cfg.comms.commandProtocol

  link:onMessage(7, { ack = false, cmd = "selfTest", error = "a self test is already running" },
    proto)
  T.notNil(link.lastAck, "the refusal was recorded")

  link:send({ cmd = "selfTest", action = "start" })
  T.isNil(link.lastAck, "and asking again clears it -- the screen goes quiet until the craft answers")
  T.eq(link.pending.cmd, "selfTest", "while recording what we are waiting on")

  link:onMessage(7, { ack = true, cmd = "selfTest" }, proto)
  T.isTrue(link.lastAck.ack, "the NEW answer lands")
  T.isNil(link.pending, "and nothing is outstanding")
end)

T.suite("build stamp")

--- "The Suite says it updated and nothing changed" has two causes that look identical from the
--- pilot's seat and need opposite fixes: the new code is running and the fault is in the code, or
--- the files updated and the program was never restarted. Lua loads at boot, so a running program
--- is unaffected by files changing under it. The stamp is read AT LOAD TIME, which is what makes
--- it able to tell those apart.
T.it("reads the install record", function()
  local Install = require("shared.install")
  local path = "/test_install_record.txt"
  local h = fs.open(path, "w")
  -- A long string: the record really is multi-line, and writing it this way keeps the test
  -- readable without escape sequences.
  h.write([[version=a30a9d88
schema=1
role=ui_main
at=2026-07-28T10:00:00
]])
  h.close()
  local record = Install.read(path)
  T.eq(record.version, "a30a9d88", "version")
  T.eq(record.role, "ui_main", "role")
  T.eq(record.schema, 1, "schema")
  T.eq(Install.stamp(record), "ui_main a30a9d88", "and a stamp that fits a narrow footer")
  fs.delete(path)
end)

T.it("never throws on a missing or unreadable record", function()
  -- A diagnostic that can crash the program it is diagnosing is worse than no diagnostic.
  local Install = require("shared.install")
  local record = Install.read("/definitely_not_here.txt")
  T.eq(record.version, "?", "unknown, not an error")
  T.eq(record.role, "?", "same for the role")
  T.notNil(Install.stamp(record), "and it still produces a stamp")
end)

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
    panelNames = App.implementedPanels(),
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
  for _ = 1, #App.implementedPanels() + 1 do click(panel.rows[1].button) end
  T.isNil(UiConfig.panelFor(cfg, "monitor_0"), "back to unassigned")
end)

--- The bug this pair exists for: a monitor could be cycled onto `pfd` or `autopilot`, which
--- nothing builds, and the screen went black with nothing in the log to say why.
T.it("only ever offers panels that something actually builds", function()
  local panel, cfg = terminalRig()
  panel.refresh()
  local seen = {}
  for _ = 1, #UiConfig.PANEL_ORDER + 2 do
    click(panel.rows[1].button)
    local assigned = UiConfig.panelFor(cfg, "monitor_0")
    if assigned then seen[assigned] = true end
  end
  for _, name in ipairs({ "pfd", "autopilot" }) do
    T.isNil(seen[name], name .. " has no builder, so it must never be offered")
  end
  T.isTrue(seen.nav, "nav does have one, so it must be reachable")
end)

T.it("a monitor left on an unimplemented panel cycles forward instead of sticking", function()
  local panel, cfg = terminalRig()
  -- exactly what an old config, or one from a newer release, leaves behind
  UiConfig.assign(cfg, "pfd", "monitor_0")
  panel.refresh()
  click(panel.rows[1].button)
  local now = UiConfig.panelFor(cfg, "monitor_0")
  T.eq(now, App.implementedPanels()[1], "moved to a panel that draws, rather than staying stuck")
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

--- THE COCKPIT THAT NEEDED TWO TO FIVE PRESSES PER BUTTON. Telemetry arrives at telemetryHz --
--- 10 a second -- and every frame used to trigger a full redraw of every assigned monitor. When a
--- redraw takes longer than the gap between frames, events arrive faster than they are consumed,
--- CC's 256-event queue fills, and it discards events: monitor_touch among them. The panels then
--- show state from seconds ago, so a test that HAD started looked like one that never did.
T.it("absorbing telemetry does NOT draw -- drawing is the timer's job alone", function()
  local App = require("app")
  local draws = 0
  local parsed = 0
  local app = setmetatable({
    staleTimer = os.startTimer(9999),
    rebuildPending = false,
    link = { onMessage = function() parsed = parsed + 1; return "telemetry" end },
    refresh = function() draws = draws + 1 end,
    syncPanels = function() end,
  }, { __index = App })

  for _ = 1, 40 do app:onTelemetry(1, {}, "eh_telemetry") end
  T.eq(parsed, 40, "every frame was absorbed")
  T.eq(draws, 0, "and not one of them drew")

  app:onTimer(app.staleTimer)
  T.eq(draws, 1, "the timer draws, once")
end)

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

--- THE "NO THRUSTERS" BUG. The craft sends the big, slow-changing half of the payload only about
--- once a second. Storing each frame wholesale meant every fast frame in between ERASED
--- thrusterAxes, candidates and layout -- so the AXIS MAP and THR AXES screens, which read
--- thrusterAxes, said "no thrusters" while the LIFT/ACCEL/LAT config pages, reading a different
--- field, listed them correctly. Two screens disagreeing about the same craft.
T.it("a frame that omits a field does not erase it", function()
  local link = Link.new(UiConfig.withDefaults({}), quietLog())
  local proto = link.cfg.comms.telemetryProtocol

  link:onMessage(7, { proto = "eh1", mode = "GROUND",
    thrusterAxes = { { id = "lift_fl", group = "lift", key = "fl" } },
    candidates = { thrusters = { "vector_thruster_0" } } }, proto)
  T.eq(#link.latest.thrusterAxes, 1, "the slow frame landed")

  -- ten fast frames with no slow half, exactly as the craft now sends them
  for i = 1, 10 do
    link:onMessage(7, { proto = "eh1", mode = "GROUND", cycle = { n = i } }, proto)
  end
  T.notNil(link.latest.thrusterAxes, "still known after ten fast frames")
  T.eq(#link.latest.thrusterAxes, 1, "and intact")
  T.notNil(link.latest.candidates, "so is the peripheral inventory")
  T.eq(link.latest.cycle.n, 10, "while the fast fields DID update")
end)

T.it("but a field the craft actually emptied does empty", function()
  local link = Link.new(UiConfig.withDefaults({}), quietLog())
  local proto = link.cfg.comms.telemetryProtocol
  link:onMessage(7, { proto = "eh1", alarms = { "one", "two" } }, proto)
  T.eq(#link.latest.alarms, 2, "two alarms")
  link:onMessage(7, { proto = "eh1", alarms = {} }, proto)
  T.eq(#link.latest.alarms, 0, "cleared, not merged into the old list")
end)

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
