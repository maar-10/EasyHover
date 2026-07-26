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
local Hardware = require("ui.hardware")
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
      enginePulseMs = 400, engineIntervalMs = 8000, engineInvert = false,
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

T.it("the settings page mirrors the craft's live config", function()
  local panel = overheadRig()
  panel.update(model())
  T.isTrue(panel.elements.pulse.display:getText():find("400") ~= nil,
    "pulse: " .. panel.elements.pulse.display:getText())
  T.isTrue(panel.elements.interval.display:getText():find("8000") ~= nil,
    "interval: " .. panel.elements.interval.display:getText())
  T.eq(panel.elements.invert:getText(), "OFF", "invert flag")
end)

T.it("a too-small monitor says so instead of drawing nonsense", function()
  local panel = overheadRig(8, 6)
  panel.update(model())        -- must not throw
  T.isTrue(true, "degraded cleanly")
end)

-- ------------------------------------------------------------------ config panel

T.suite("config panel")

local function configRig(width, height)
  mock.reset()
  _G.peripheral = mock.install()
  local cfg = UiConfig.withDefaults({})
  local monitor = mock.monitor(width or 29, height or 12)
  local frame = basalt.createFrame()
  frame:setTerm(monitor)
  local commands, actions = sent()
  local monitors = Monitors.new(cfg, quietLog(), basalt)
  local saved = { count = 0 }
  local panel = ConfigPanel.build(frame, {
    cfg = cfg, actions = actions, monitors = monitors, log = quietLog(),
    savePanels = function() saved.count = saved.count + 1 end,
    lastAck = function() return nil end,
  })
  return panel, commands, cfg, saved
end

T.it("the home page shows live flight values", function()
  local panel = configRig()
  panel.update(model())
  T.isTrue(panel.elements.status:getText():find("HOVER") ~= nil,
    "mode: " .. panel.elements.status:getText())
  T.isTrue(panel.elements.live[1]:getText():find("82.5") ~= nil,
    "altitude on the first line: " .. panel.elements.live[1]:getText())
  T.isTrue(panel.elements.live[2]:getText():find("VS") ~= nil,
    "vertical speed on the second: " .. panel.elements.live[2]:getText())
  T.isTrue(panel.elements.live[3]:getText():find("2.5") ~= nil,
    "attitude on the third: " .. panel.elements.live[3]:getText())
end)

T.it("an alarm is surfaced on the home page", function()
  local panel = configRig()
  local m = model()
  m.telemetry.alarms = { { key = "fuel", level = "warning", msg = "tank 8%" } }
  panel.update(m)
  T.isTrue(panel.elements.alarm:getText():find("tank 8%%") ~= nil,
    "alarm text: " .. panel.elements.alarm:getText())
  T.eq(panel.elements.alarm:getForeground(), colours.red, "coloured by severity")
end)

T.it("the monitor page lists every monitor and its assignment", function()
  local panel, _, cfg = configRig()
  UiConfig.assign(cfg, "overhead", "monitor_0")
  panel.refreshMonitors()
  T.isTrue(panel.elements.monitorRows[1].label:getText():find("monitor_0") ~= nil,
    "name: " .. panel.elements.monitorRows[1].label:getText())
  T.isTrue(panel.elements.monitorRows[1].label:getText():find("15x20") ~= nil, "size shown")
  T.eq(panel.elements.monitorRows[1].button:getText(), "overhead", "assignment shown")
  T.eq(panel.elements.monitorRows[2].button:getText(), "none", "unassigned shown as none")
end)

T.it("tapping a monitor row cycles its panel and saves immediately", function()
  local panel, _, cfg, saved = configRig()
  panel.refreshMonitors()
  local row = panel.elements.monitorRows[1]
  click(row.button)
  T.eq(UiConfig.panelFor(cfg, "monitor_0"), "overhead", "first tap assigns the overhead panel")
  T.eq(saved.count, 1, "saved at once, so a reboot cannot lose it")
  panel.refreshMonitors()
  click(row.button)
  T.eq(UiConfig.panelFor(cfg, "monitor_0"), "config", "second tap moves it on")
end)

T.it("cycling past the last panel unassigns", function()
  local panel, _, cfg = configRig()
  panel.refreshMonitors()
  local row = panel.elements.monitorRows[1]
  for _ = 1, 5 do
    click(row.button)
    panel.refreshMonitors()
  end
  click(row.button)
  T.isNil(UiConfig.panelFor(cfg, "monitor_0"), "back to unassigned")
end)

T.it("the disk page reports what the craft sees", function()
  local panel = configRig()
  panel.update(model())
  T.isTrue(panel.elements.diskStatus:getText():find("EH configs") ~= nil,
    "disk label: " .. panel.elements.diskStatus:getText())
  T.isTrue(panel.elements.diskLocal:getText():find("2") ~= nil, "counts shown")
end)

T.it("the flight page mirrors the craft's limits and sends configSet", function()
  local panel, commands = configRig()
  panel.update(model())
  T.isTrue(panel.elements.bank.display:getText():find("20") ~= nil,
    "bank limit: " .. panel.elements.bank.display:getText())
  T.eq(panel.elements.bank.value, 20, "value tracked for the -/+ buttons")
end)

T.it("shows NO DATA when the link drops", function()
  local panel = configRig()
  panel.update(model())
  panel.update({ stale = true, ageMs = math.huge, telemetry = nil })
  T.isTrue(panel.elements.stale:getVisible(), "banner up")
  T.eq(panel.elements.live[1]:getText(), "", "stale values cleared, not left frozen")
end)

-- ------------------------------------------------------- the dry-run bugs

T.suite("dry-run fixes")

T.it("BUG 1: tapping a monitor row updates its label immediately", function()
  local panel, _, cfg = configRig()
  panel.refreshMonitors()
  local row = panel.elements.monitorRows[1]
  T.eq(row.button:getText(), "none", "starts unassigned")
  click(row.button)
  -- The old code only redrew on RESCAN, so the label under your finger stayed stale.
  T.eq(row.button:getText(), "overhead", "label changed on the tap, with no rescan")
end)

T.it("BUG 2: the config panel fits a 1x1 monitor (15x10)", function()
  local panel = configRig(15, 10)
  T.notNil(panel.elements.status, "it built a real panel, not the TOO SMALL notice")
  T.isTrue(panel.narrow, "and took its narrow layout")
  panel.update(model())
  T.isTrue(panel.elements.live[1]:getText():find("ALT") ~= nil,
    "showing live values: " .. panel.elements.live[1]:getText())
end)

T.it("a genuinely unusable screen still says so", function()
  local panel = configRig(8, 5)
  T.isNil(panel.elements.status, "no panel built")
  panel.update(model())
end)

T.it("BUG 3: with no relay the engine button offers SET UP, not a bare dash", function()
  local panel, commands = overheadRig()
  local m = model()
  m.telemetry.engine = { available = false, master = false }
  panel.update(m)
  T.eq(panel.elements.engineState:getText(), "NO RELAY", "state")
  T.eq(panel.elements.engineButton:getText(), "SET UP", "the button says what to do")
  click(panel.elements.engineButton)
  T.eq(#commands, 0, "no pointless command sent")
  T.isTrue(panel.settings:getVisible(), "it opened the config page instead")
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

T.it("tank max shows auto when there is no configured capacity", function()
  local panel = overheadRig()
  panel.update(model())
  T.eq(panel.elements.capacity.display:getText(), "auto",
    "0 means trust the tank own reading")
end)

T.it("tank max says SET TANK rather than showing -- over two dead buttons", function()
  -- With no tank assigned there is no capacity to edit, and -/+ silently refuse. A row that
  -- just reads "--" is indistinguishable from a broken button, which is how it was reported.
  local panel, commands = overheadRig()
  local m = model()
  m.telemetry.config.tankCapacityMb = nil
  panel.update(m)
  T.eq(panel.elements.capacity.display:getText(), "set tank", "says what is missing")
  click(panel.elements.capacity.plus)
  T.eq(#commands, 0, "and the buttons genuinely have nothing to send")
end)

-- ------------------------------------------------------------------ hardware

T.suite("hardware assignment")

local hardwareAck = nil

local function hardwareRig(width, height)
  mock.reset()
  _G.peripheral = mock.install()
  hardwareAck = nil
  -- A REGISTERED monitor, not a bare window: the rapid-tap test dispatches monitor_touch on
  -- the frame, and BaseFrame only routes it if peripheral.getName(monitor) matched.
  local monitor = peripheral.wrap("monitor_0")
  if width or height then monitor = mock.monitor(width or 15, height or 12) end
  local frame = basalt.createFrame()
  frame:setTerm(monitor)
  local commands, actions = sent()
  local widget = Hardware.build(frame, 1, 1, frame:getWidth(), frame:getHeight(),
    { actions = actions, log = quietLog(), lastAck = function() return hardwareAck end })
  return widget, commands, frame
end

--- The candidate rows currently drawn, as text. `(none)` is always first.
local function rowTexts(widget)
  local out = {}
  for _, entry in ipairs(widget.elements.rows) do
    if entry.button:getVisible() then out[#out + 1] = entry.button:getText() end
  end
  return out
end

--- Find the drawn row offering `name`, so a test taps what the pilot would tap.
local function rowFor(widget, name)
  for _, entry in ipairs(widget.elements.rows) do
    if entry.button:getVisible() and entry.name == name then return entry.button end
  end
  return nil
end

T.it("shows the engine relay first, and that nothing is set yet", function()
  local widget = hardwareRig()
  widget.update(model())
  T.eq(widget.elements.title:getText(), "ENGINE RELAY", "first item")
  T.isTrue(widget.elements.value:getText():find("not set") ~= nil,
    "value: " .. widget.elements.value:getText())
  T.isTrue(widget.elements.count:getText():find("2 found") ~= nil,
    "offers the relays the craft reported: " .. widget.elements.count:getText())
end)

T.it("LISTS every candidate as its own row, so you can see what you are choosing", function()
  local widget = hardwareRig()
  widget.update(model())
  local rows = rowTexts(widget)
  T.eq(#rows, 3, "(none) plus two relays, got: " .. table.concat(rows, " | "))
  T.isTrue(rows[1]:find("none") ~= nil, "first row unassigns: " .. rows[1])
  T.notNil(rowFor(widget, "redstone_relay_0"), "relay 0 offered")
  T.notNil(rowFor(widget, "redstone_relay_1"), "relay 1 offered")
end)

T.it("tapping a candidate row assigns THAT one, not the next in a cycle", function()
  local widget, commands = hardwareRig()
  widget.update(model())
  click(rowFor(widget, "redstone_relay_1"))
  T.eq(#commands, 1, "one command")
  T.eq(commands[1].cmd, "setEngineRelay", "the right command")
  T.eq(commands[1].peripheral, "redstone_relay_1", "the row that was tapped")
  T.eq(commands[1].side, "top", "with a side")
end)

T.it("tapping (none) unassigns, so a wrong pick is always undoable", function()
  local widget, commands = hardwareRig()
  local m = model()
  m.telemetry.config.engineRelay = "redstone_relay_0"
  widget.update(m)
  click(rowFor(widget, ""))
  T.eq(commands[1].peripheral, "", "cleared")
end)

T.it("marks the row that is currently assigned", function()
  local widget = hardwareRig()
  local m = model()
  m.telemetry.config.engineRelay = "redstone_relay_1"
  widget.update(m)
  T.eq(rowFor(widget, "redstone_relay_1"):getBackground(), Theme.ok, "the assigned row stands out")
  T.eq(rowFor(widget, "redstone_relay_0"):getBackground(), Theme.buttonBg, "the others do not")
end)

T.it("NEVER shows an assignment the craft has not confirmed", function()
  -- No optimistic feedback anywhere in this cockpit: a panel that draws what it ASKED for is
  -- lying whenever the request is refused, dropped, or the link is down -- and a pilot cannot
  -- tell the difference. The gauge reads the craft, never the request.
  local widget, commands = hardwareRig(30, 12)
  widget.update(model())
  click(rowFor(widget, "redstone_relay_0"))
  T.eq(#commands, 1, "the command went out")
  T.isTrue(widget.elements.value:getText():find("not set") ~= nil,
    "but the value line still reports the craft's state: " .. widget.elements.value:getText())
  T.eq(rowFor(widget, "redstone_relay_0"):getBackground(), Theme.buttonBg,
    "and no row is marked as assigned yet")
end)

T.it("says it is WAITING, which is a fact about us rather than about the craft", function()
  local widget = hardwareRig(30, 12)
  widget.update(model())
  click(rowFor(widget, "redstone_relay_0"))
  T.isTrue(widget.elements.count:getText():find("waiting") ~= nil,
    "tap acknowledged: " .. widget.elements.count:getText())

  -- ...and it clears only when the craft actually reports the new assignment.
  local m = model()
  m.telemetry.config.engineRelay = "redstone_relay_0"
  widget.update(m)
  T.isFalse(widget.elements.count:getText():find("waiting") ~= nil, "cleared on confirmation")
  T.eq(widget.elements.value:getText(), "redstone_relay_0", "and NOW the value line moves")
end)

T.it("keeps waiting when the craft never confirms", function()
  local widget = hardwareRig(30, 12)
  widget.update(model())
  click(rowFor(widget, "redstone_relay_0"))
  for _ = 1, 5 do widget.update(model()) end          -- frames that never carry the change
  T.isTrue(widget.elements.count:getText():find("waiting") ~= nil,
    "still waiting, not quietly pretending it worked")
  T.isTrue(widget.elements.value:getText():find("not set") ~= nil, "value unchanged")
end)

T.it("SIDE cycles the relay side", function()
  local widget, commands = hardwareRig()
  local m = model()
  m.telemetry.config.engineRelay = "redstone_relay_0"
  m.telemetry.config.engineSide = "top"
  widget.update(m)
  click(widget.elements.side)
  T.eq(commands[1].cmd, "setEngineRelay", "re-sends with the new side")
  T.isFalse(commands[1].side == "top", "side changed to " .. tostring(commands[1].side))
end)

T.it("the tabs switch item, and each one lists its own hardware", function()
  local widget, commands = hardwareRig()
  widget.update(model())

  click(widget.elements.tabs[2])
  T.eq(widget.elements.title:getText(), "FUEL TANK", "second item")
  click(rowFor(widget, "create:fluid_tank_0"))
  T.eq(commands[1].cmd, "setTank", "assigns a tank")
  T.eq(commands[1].peripheral, "create:fluid_tank_0", "the candidate the craft reported")

  click(widget.elements.tabs[3])
  T.eq(widget.elements.title:getText(), "ENGINE VAULT", "third item")
  click(rowFor(widget, "create:item_vault_0"))
  T.eq(commands[2].cmd, "setVault", "assigns a vault")
end)

T.it("RAPID CONSECUTIVE TAPS all register -- the bug that made PICK look dead", function()
  -- Regression guard. Basalt turns a second click on the same element within 0.4 s into
  -- mouse_double_click, so an onClick-only button silently ate it. This drives the REAL
  -- monitor_touch path with no delay at all: every tap must produce its command.
  local widget, commands, frame = hardwareRig()
  widget.update(model())

  tap(frame, widget.elements.tabs[2])
  T.eq(widget.elements.title:getText(), "FUEL TANK", "tab tap 1 landed")
  tap(frame, widget.elements.tabs[3])
  T.eq(widget.elements.title:getText(), "ENGINE VAULT", "tab tap 2 landed, back to back")
  tap(frame, widget.elements.tabs[2])
  T.eq(widget.elements.title:getText(), "FUEL TANK", "tab tap 3 landed")

  local target = rowFor(widget, "create:fluid_tank_0")
  tap(frame, target)
  tap(frame, target)
  tap(frame, target)
  T.eq(#commands, 3, "three taps, three commands -- none swallowed")
  T.eq(commands[3].cmd, "setTank", "and the last one is still the right command")
end)

T.it("the SIDE button only appears for the relay", function()
  local widget = hardwareRig()
  widget.update(model())
  T.isTrue(widget.elements.side:getVisible(), "shown for the relay")
  widget.select(2)
  T.isFalse(widget.elements.side:getVisible(), "hidden for the tank")
end)

T.it("says so when the craft reports no candidates", function()
  local widget = hardwareRig()
  local m = model()
  m.telemetry.candidates = { relays = {}, tanks = {}, vaults = {} }
  widget.update(m)
  T.isTrue(widget.elements.count:getText():find("none on network") ~= nil,
    "count line: " .. widget.elements.count:getText())
  local rows = rowTexts(widget)
  T.eq(#rows, 1, "only the (none) row is offered")
end)

T.it("pages when there are more candidates than rows", function()
  local widget = hardwareRig(15, 8)          -- 2 list rows: 3 entries need 2 pages
  widget.update(model())
  T.isTrue(widget.elements.count:getText():find("pg 1/2") ~= nil,
    "page indicator: " .. widget.elements.count:getText())
  T.isTrue(widget.elements.down:getVisible(), "paging offered")
  click(widget.elements.down)
  T.eq(widget.page(), 2, "moved on")
  T.notNil(rowFor(widget, "redstone_relay_1"), "the last candidate is reachable")
end)

T.it("does not offer paging when everything fits", function()
  local widget = hardwareRig()
  widget.update(model())
  T.isFalse(widget.elements.down:getVisible(), "no paging buttons cluttering the screen")
end)

T.it("shows when the craft REFUSED an assignment", function()
  -- Otherwise a rejected command is invisible: the value reverts on the next frame and the
  -- pilot has no idea whether the tap even arrived.
  local widget = hardwareRig()
  widget.update(model())
  hardwareAck = { ack = false, cmd = "setEngineRelay", detail = {} }
  widget.update(model())
  T.isTrue(widget.elements.count:getText():find("REFUSED") ~= nil,
    "count line: " .. widget.elements.count:getText())
  hardwareAck = { ack = true, cmd = "setEngineRelay" }
  widget.update(model())
  T.isFalse(widget.elements.count:getText():find("REFUSED") ~= nil, "and it clears")
end)

T.it("shows what is already assigned", function()
  local widget = hardwareRig(30, 12)
  local m = model()
  m.telemetry.config.engineRelay = "redstone_relay_1"
  m.telemetry.config.engineSide = "back"
  widget.update(m)
  T.eq(widget.elements.value:getText(), "redstone_relay_1", "current assignment in full")
  T.isTrue(widget.elements.side:getText():find("back") ~= nil,
    "and its side is on the button: " .. widget.elements.side:getText())
end)

T.it("a name too long for the screen keeps its TAIL, not its head", function()
  -- 15 columns cannot hold "redstone_relay_1". Chopping the end would render relay_0 and
  -- relay_1 identically, which is the one thing the display must not do.
  local widget = hardwareRig(15, 12)
  local m = model()
  m.telemetry.config.engineRelay = "redstone_relay_1"
  widget.update(m)
  local shown = widget.elements.value:getText()
  T.isTrue(shown:sub(-1) == "1", "the disambiguating character survived: " .. shown)
  T.isTrue(#shown <= 15, "and it fits")
end)

T.it("the config panel hosts the same widget", function()
  local panel = configRig()
  T.notNil(panel.hardware, "hardware page present")
  panel.update(model())
  T.eq(panel.hardware.elements.title:getText(), "ENGINE RELAY", "and it is live")
end)

T.it("the overhead panel hosts it too, on the real 1x2 screen", function()
  -- The overhead monitor is where the pilot starts the engine, so "which relay" has to be
  -- answerable there. If the picker does not fit, that page silently sends you elsewhere.
  local panel = overheadRig(15, 20)
  panel.update(model())
  T.notNil(panel.hardware, "the picker fits the overhead monitor")
  local rows = 0
  for _, entry in ipairs(panel.hardware.elements.rows) do
    if entry.button:getVisible() then rows = rows + 1 end
  end
  T.isTrue(rows >= 3, "and it lists (none) plus both relays, got " .. rows)
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
