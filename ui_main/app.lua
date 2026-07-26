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
local Log = require("shared.log")

local basalt = require("basalt")

local App = {}
App.__index = App

local CONFIG_PATH = "/eh_ui_main_config.tbl"

--- How often to re-evaluate staleness when the craft has gone quiet.
local STALE_POLL_SECONDS = 0.5

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
    setAltitude = function(value) link:send({ cmd = "setAltitude", value = value }) end,
    configSet = function(path, value) link:send({ cmd = "configSet", path = path, value = value }) end,
    setEngineRelay = function(peripheral, side)
      link:send({ cmd = "setEngineRelay", peripheral = peripheral or "", side = side or "top" })
    end,
    setTank = function(peripheral) link:send({ cmd = "setTank", peripheral = peripheral or "" }) end,
    setVault = function(peripheral) link:send({ cmd = "setVault", peripheral = peripheral or "" }) end,
    configSave = function() link:send({ cmd = "configSave" }) end,
    diskSave = function() link:send({ cmd = "diskSave" }) end,
    diskLoad = function() link:send({ cmd = "diskLoad" }) end,
  }
end

-- ---------------------------------------------------------------- panels

function App:panelOptions()
  return {
    cfg = self.cfg,
    actions = self.actions,
    monitors = self.monitors,
    log = self.log,
    lastAck = function() return self.link.lastAck end,
    savePanels = function()
      local ok, err = UiConfig.save(self.configPath, self.cfg)
      if not ok then self.log:error("could not save panel assignment: %s", tostring(err)) end
      self.rebuildPending = true
    end,
  }
end

--- The builder for each live panel.
function App:builders()
  local options = self:panelOptions()
  return {
    overhead = function(frame) return Overhead.build(frame, options) end,
    config = function(frame) return ConfigPanel.build(frame, options) end,
  }
end

--- Reconcile the frames against the configured assignment, touching only what changed.
---
--- Incremental on purpose: a full teardown meant reassigning one monitor rebuilt every panel
--- and threw you back to the home page of the very screen you were configuring from.
function App:syncPanels()
  local changed = self.monitors:sync(self:builders())

  -- The bootstrap case: with no monitor assigned to the config panel there would be no way to
  -- assign one. So the config panel is also built on this computer's own terminal, which is
  -- always available. Re-evaluated on every sync, because assigning (or unassigning) the config
  -- panel is exactly when this changes.
  local wantTerminal = (self.monitors:count("config") == 0)
  if wantTerminal and not self.terminalPanel then
    local frame = basalt.createFrame()
    frame:setTerm(term.current())
    local ok, instance = pcall(ConfigPanel.build, frame, self:panelOptions())
    if ok then
      self.terminalFrame = frame
      self.terminalPanel = instance
      self.log:warn("no monitor assigned to the config panel: showing it on the terminal")
    else
      self.log:error("terminal config panel failed to build: %s", tostring(instance))
    end
  elseif not wantTerminal and self.terminalPanel then
    -- A monitor now owns the config panel, so give the terminal back.
    pcall(function() basalt.setActiveFrame(self.terminalFrame, false) end)
    self.terminalFrame, self.terminalPanel = nil, nil
    pcall(function()
      term.setBackgroundColour(colours.black)
      term.clear()
      term.setCursorPos(1, 1)
      print("EasyHover ui_main -- config panel is on a monitor")
    end)
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
  self:refresh()
  self.staleTimer = os.startTimer(STALE_POLL_SECONDS)
  return true
end

--- Push the latest model into every panel, including the terminal fallback.
function App:refresh()
  local model = self.link:model()
  self.monitors:update(model)
  if self.terminalPanel and self.terminalPanel.update then
    pcall(self.terminalPanel.update, model)
  end
end

-- ---------------------------------------------------------------- run

function App:boot()
  self.log:info("EasyHover ui_main booting (config %s)",
    self.configExisted and "loaded" or "defaults")
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
    local kind = self.link:onMessage(sender, message, protocol)
    if kind then self:refresh() end
  end)

  -- A heartbeat, so "NO DATA" appears when the flight computer goes quiet rather than the
  -- panels freezing on their last good frame. Guarded on the id -- see App:onTimer.
  basalt.onEvent("timer", function(id) self:onTimer(id) end)

  -- Rebuilding on a peripheral change means plugging a monitor in just works.
  basalt.onEvent("peripheral", function() self.rebuildPending = true end)
  basalt.onEvent("peripheral_detach", function() self.rebuildPending = true end)

  self.staleTimer = os.startTimer(STALE_POLL_SECONDS)
  basalt.run()
end

return App
