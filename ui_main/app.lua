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

--- (Re)build every frame from the current assignment.
function App:buildPanels()
  self.monitors:clear()
  local options = self:panelOptions()

  self.monitors:buildPanel("overhead", function(frame)
    return Overhead.build(frame, options)
  end)
  self.monitors:buildPanel("config", function(frame)
    return ConfigPanel.build(frame, options)
  end)

  -- The bootstrap case: with no monitor assigned to the config panel there would be no way to
  -- assign one. So the config panel is also built on this computer's own terminal, which is
  -- always available.
  self.terminalPanel = nil
  if self.monitors:count("config") == 0 then
    local frame = basalt.createFrame()
    frame:setTerm(term.current())
    local ok, instance = pcall(ConfigPanel.build, frame, options)
    if ok then
      self.terminalPanel = instance
      self.log:warn("no monitor assigned to the config panel: showing it on the terminal")
    else
      self.log:error("terminal config panel failed to build: %s", tostring(instance))
    end
  end

  self.rebuildPending = false
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
  -- panels freezing on their last good frame.
  basalt.onEvent("timer", function()
    if self.rebuildPending then self:buildPanels() end
    self:refresh()
    self.staleTimer = os.startTimer(0.5)
  end)

  -- Rebuilding on a peripheral change means plugging a monitor in just works.
  basalt.onEvent("peripheral", function() self.rebuildPending = true end)
  basalt.onEvent("peripheral_detach", function() self.rebuildPending = true end)

  self.staleTimer = os.startTimer(0.5)
  basalt.run()
end

return App
