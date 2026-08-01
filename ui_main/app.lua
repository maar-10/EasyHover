--[[ The ui_main computer.

     Renders every assigned panel, on every assigned monitor, from one telemetry feed. It has
     no authority of its own: it sends whitelisted commands and the flight computer decides.

     The loop is Basalt's own. `basalt.onEvent("rednet_message", ...)` hooks telemetry into it,
     so there is no second coroutine competing for events -- which is the whole reason this
     work lives on its own computer and not on the flight computer (see docs/WIRING.md).

     Frame rebuilds are DEFERRED to the start of the next event rather than done inside a
     handler: Basalt iterates its active frames while dispatching, and tearing one down
     mid-iteration is asking for trouble.
]]

local UiConfig = require("lib.config")
local Link = require("lib.link")
local Monitors = require("lib.monitors")
local Overhead = require("ui.overhead")
local ConfigPanel = require("ui.config_panel")
local Nav = require("ui.nav")
local Terminal = require("ui.terminal")
local Theme = require("ui.theme")
local Log = require("shared.log")

local basalt = require("basalt")

local App = {}
App.__index = App

local CONFIG_PATH = "/eh_ui_main_config.tbl"

--- How often the panels are redrawn. THIS IS THE ONLY THING THAT DRAWS.
---
--- Telemetry arrives at telemetryHz -- 10 a second by default -- and each frame used to trigger a
--- full model refresh across every assigned monitor. If one of those refreshes takes longer than
--- the gap between frames, events arrive faster than they are consumed, CC's 256-event queue
--- fills, and it starts DISCARDING events. What the pilot sees is a cockpit where a button needs
--- two to five presses and the panels show state from several seconds ago -- which is exactly the
--- failure the timer-storm note below describes, reached by a different road.
---
--- Redrawing on a timer instead makes the two rates independent: messages are absorbed as fast as
--- they arrive because absorbing one is nearly free, and drawing happens at a rate the computer
--- can actually sustain. The timer is re-armed AFTER the redraw, never before, so a slow frame
--- delays the next one rather than queueing another behind it.
local RENDER_POLL_SECONDS = 0.2

function App.new(opts)
  opts = opts or {}
  local self = setmetatable({}, App)
  self.configPath = opts.configPath or CONFIG_PATH

  local cfg, existed = UiConfig.load(self.configPath)
  self.cfg = cfg
  self.configExisted = existed

  self.log = Log.new({ level = "info", capacity = 120, echo = opts.echo })
  self.link = Link.new(cfg, self.log)
  self.monitors = Monitors.new(cfg, self.log, basalt)
  self.rebuildPending = false
  self.instances = {}

  local ok, errors, warnings = UiConfig.validate(cfg)
  self.configValid = ok
  for _, e in ipairs(errors) do self.log:error("config: %s", e) end
  for _, w in ipairs(warnings) do self.log:warn("config: %s", w) end

  self.actions = self:buildActions()
  return self
end

--- Everything a panel is allowed to ask for. Each one is a command the flight computer
--- validates on arrival -- this table is a convenience, not a privilege.
function App:buildActions()
  local link = self.link
  return {
    engineMaster = function(value) link:send({ cmd = "engineMaster", value = value and true or false }) end,
    engineFeed = function() link:send({ cmd = "engineFeed" }) end,
    setAux = function(label, value) link:send({ cmd = "setAux", label = label, value = value }) end,
    setFeel = function(value) link:send({ cmd = "setFeel", value = value }) end,
    setLateral = function(value) link:send({ cmd = "setLateral", value = value }) end,
    setAssist = function(value) link:send({ cmd = "setAssist", value = value }) end,
    flightArm = function(value) link:send({ cmd = "flightArm", value = value and true or false }) end,
    setAltitude = function(value) link:send({ cmd = "setAltitude", value = value }) end,
    configSet = function(path, value) link:send({ cmd = "configSet", path = path, value = value }) end,
    setEngineRelay = function(peripheral, side)
      link:send({ cmd = "setEngineRelay", peripheral = peripheral or "", side = side or "top" })
    end,
    setTank = function(peripheral) link:send({ cmd = "setTank", peripheral = peripheral or "" }) end,
    setVault = function(peripheral) link:send({ cmd = "setVault", peripheral = peripheral or "" }) end,
    setSlot = function(kind, key, peripheral)
      link:send({ cmd = "setSlot", kind = kind, key = key, peripheral = peripheral or "" })
    end,
    selfTest = function(action) link:send({ cmd = "selfTest", action = action or "start" }) end,
    vectorHold = function(action, id, axis, sign)
      link:send({ cmd = "vectorHold", action = action or "latch", id = id or "",
                  axis = axis or "x", sign = sign or 1 })
    end,
    setAxes = function(id, swap, invertX, invertY)
      link:send({ cmd = "setAxes", id = id, swap = swap and true or false,
                  invertX = invertX and true or false, invertY = invertY and true or false })
    end,
    configSave = function() link:send({ cmd = "configSave" }) end,
    diskSave = function() link:send({ cmd = "diskSave" }) end,
    diskLoad = function() link:send({ cmd = "diskLoad" }) end,
    -- UI-LOCAL: re-themes this computer's own monitors for day/night reading. Not a flight command
    -- -- it never leaves this computer -- so it goes straight to the app rather than the link.
    dayNight = function() self:toggleDayNight() end,
    -- Commands to the NAV computer (its own protocol, not the flight command channel).
    setHeadingSource = function(source) link:sendNav({ cmd = "setHeadingSource", source = source }) end,
    setNavTable = function(peripheral)
      link:sendNav({ cmd = "setNavTable", peripheral = peripheral or "" })
    end,
    setNavSign = function(sign) link:sendNav({ cmd = "setNavSign", sign = sign or 1 }) end,
    setGimbalSign = function(sign) link:sendNav({ cmd = "setGimbalSign", sign = sign or 1 }) end,
    navSelfAlign = function() link:sendNav({ cmd = "selfAlign" }) end,
  }
end

--- Flip day/night, persist the choice, and rebuild every panel so the new colours take (panels
--- capture Theme's colours when they build). Returns the mode now in effect.
function App:toggleDayNight()
  local next = (Theme.mode == "night") and "day" or "night"
  Theme.setMode(next)
  self.cfg.ui.dayNight = next
  local ok, err = UiConfig.save(self.configPath, self.cfg)
  if not ok then self.log:warn("could not save day/night: %s", tostring(err)) end
  self.rebuildPending = true          -- syncPanels on the next timer rebuilds with the new colours
  self.log:info("display mode -> %s", next)
  return next
end

-- ---------------------------------------------------------------- panels

function App:panelOptions()
  return {
    cfg = self.cfg,
    actions = self.actions,
    monitors = self.monitors,
    log = self.log,
    lastAck = function() return self.link.lastAck end,
    -- The nav computer answers on its own channel; a panel that commands nav reads THIS ack.
    lastNavAck = function() return self.link.lastNavAck end,
    --- Which panels the terminal may cycle a monitor through. Derived from the builder table,
    --- never hand-listed.
    panelNames = App.implementedPanels(),
    savePanels = function()
      local ok, err = UiConfig.save(self.configPath, self.cfg)
      if not ok then self.log:error("could not save panel assignment: %s", tostring(err)) end
      self.rebuildPending = true
    end,
  }
end

--- EVERY PANEL THIS RELEASE ACTUALLY IMPLEMENTS. One table, two jobs: it builds the frames,
--- and it is what the terminal offers when you cycle a monitor. Those must not be allowed to
--- drift -- a monitor assigned to a panel with no builder here goes black and stays black,
--- which is indistinguishable from a broken screen. A panel declared in Config.PANEL_ORDER but
--- absent here is simply not offered.
local PANEL_BUILDERS = {
  overhead = Overhead.build,
  config = ConfigPanel.build,
  nav = Nav.build,
}

--- The implemented panels, in PANEL_ORDER order, which is the order the terminal cycles.
function App.implementedPanels()
  local out = {}
  for _, name in ipairs(UiConfig.PANEL_ORDER) do
    if PANEL_BUILDERS[name] then out[#out + 1] = name end
  end
  return out
end

--- The builder for each live panel.
function App:builders()
  local options = self:panelOptions()
  local out = {}
  for name, build in pairs(PANEL_BUILDERS) do
    out[name] = function(frame) return build(frame, options) end
  end
  return out
end

--- Reconcile the frames against the configured assignment, touching only what changed.
---
--- Incremental on purpose: a full teardown meant reassigning one monitor rebuilt every panel
--- and threw you back to the home page of the very screen you were configuring from.
function App:syncPanels()
  local changed = self.monitors:sync(self:builders())

  -- This computer's own terminal ALWAYS runs the monitor-assignment screen. Which panel shows
  -- on which monitor is a property of this computer rather than of the craft, and the terminal
  -- is the one screen that exists before anything has been assigned -- so it is both the right
  -- home for that setting and the only possible bootstrap.
  if not self.terminalPanel then
    local frame = basalt.createFrame()
    frame:setTerm(term.current())
    local ok, instance = pcall(Terminal.build, frame, self:panelOptions())
    if ok then
      self.terminalFrame = frame
      self.terminalPanel = instance
    else
      self.log:error("terminal panel failed to build: %s", tostring(instance))
    end
  elseif self.terminalPanel.refresh then
    -- A monitor may have appeared or been reassigned; the list has to follow.
    pcall(self.terminalPanel.refresh)
  end

  self.rebuildPending = false
  return changed
end

--- Full rebuild, for boot and for a hardware change that may have replaced monitors wholesale.
function App:buildPanels()
  self.monitors:clear()
  self.terminalFrame, self.terminalPanel = nil, nil
  return self:syncPanels()
end

--- The stale-check heartbeat.
---
--- THE TIMER ID MUST BE CHECKED. Basalt runs timers of its own -- a lazy-element pass every
--- 0.2 s, and a `sleep(0.1)` after every single monitor_touch -- and `basalt.onEvent("timer")`
--- fires for all of them. An unguarded handler that re-arms its own timer therefore spawns a
--- NEW self-sustaining 0.5 s refresh chain out of every stray timer event, several times a
--- second, none of which ever stop. Within a minute hundreds of chains are each doing a full
--- model refresh across every monitor, CC's 256-event queue overflows, and it starts DROPPING
--- monitor_touch and rednet_message events: the cockpit goes sluggish and buttons stop working.
---
--- Returns true when this was our heartbeat, so the behaviour is testable without basalt.run().
function App:onTimer(id)
  if id ~= self.staleTimer then return false end
  if self.rebuildPending then self:syncPanels() end
  -- MEASURED, not guessed. Two attempts at the cockpit's sluggishness have failed to shift it,
  -- which means the model behind them was wrong. A redraw that takes longer than the gap between
  -- redraws leaves no room for anything else -- touches included -- and this is the number that
  -- says whether that is what is happening. It is shown on this computer's own terminal.
  local startedAt = os.epoch("utc")
  self:refresh()
  self.lastRefreshMs = os.epoch("utc") - startedAt
  -- Re-armed AFTER the redraw. A slow frame therefore delays the next one instead of stacking a
  -- second timer behind it, so the draw rate degrades to whatever the computer can sustain rather
  -- than running the event queue out of room.
  self.staleTimer = os.startTimer(RENDER_POLL_SECONDS)
  return true
end

--- ABSORB, DO NOT DRAW. Feeding the link is nearly free; drawing every monitor is not, and doing
--- it here would tie the redraw rate to whatever rate the craft chooses to talk at -- which at
--- telemetryHz 10, across three monitors, is how the event queue fills and touches get dropped.
---
--- Returns the message kind, so the caller can tell telemetry from an ack without re-parsing.
function App:onTelemetry(sender, message, protocol)
  return self.link:onMessage(sender, message, protocol)
end

--- Push the latest model into every panel, including the terminal fallback.
function App:refresh()
  local model = self.link:model()
  -- Last frame's cost, for the terminal to display. Last frame's rather than this one's, because
  -- this one is not finished yet -- and a number that is one frame stale still answers the
  -- question being asked of it.
  model.refreshMs = self.lastRefreshMs
  -- The two clocks the nav monitor shows, read HERE (not in the panel) so the render stays a pure
  -- function of its model and the tests can drive any time they like. os.time returns hours 0..24.
  model.clock = {
    mc = os.time("ingame"),
    irl = os.time("local"),
    day = os.day("ingame"),
  }
  self.monitors:update(model)
  if self.terminalPanel and self.terminalPanel.update then
    pcall(self.terminalPanel.update, model)
  end
end

-- ---------------------------------------------------------------- run

function App:boot()
  self.log:info("EasyHover ui_main booting (config %s)",
    self.configExisted and "loaded" or "defaults")
  -- Apply the saved day/night choice BEFORE any panel builds, so the first frame is already in the
  -- right colours rather than flashing day and rebuilding to night.
  Theme.setMode(self.cfg.ui.dayNight)
  self.link:open()
  self:buildPanels()

  local summary = self.monitors:summary()
  for _, name in ipairs(UiConfig.PANEL_ORDER) do
    local entry = summary[name]
    if entry and entry.assigned > 0 then
      self.log:info("panel %s: %d assigned, %d live", name, entry.assigned, entry.live)
    end
  end
  self:refresh()
  return self.configValid
end

function App:run()
  self:boot()

  basalt.setRenderThrottleTime(1 / math.max(self.cfg.ui.refreshHz, 1))

  basalt.onEvent("rednet_message", function(sender, message, protocol)
    self:onTelemetry(sender, message, protocol)
  end)

  -- A heartbeat, so "NO DATA" appears when the flight computer goes quiet rather than the
  -- panels freezing on their last good frame. Guarded on the id -- see App:onTimer.
  basalt.onEvent("timer", function(id) self:onTimer(id) end)

  -- Rebuilding on a peripheral change means plugging a monitor in just works.
  basalt.onEvent("peripheral", function() self.rebuildPending = true end)
  basalt.onEvent("peripheral_detach", function() self.rebuildPending = true end)

  self.staleTimer = os.startTimer(RENDER_POLL_SECONDS)
  basalt.run()
end

return App
