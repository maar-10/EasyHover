--[[ The GPS beacon computer.

     One of four standalone boxes in the world that let the craft know where it is. Each one:

       * answers gps.locate()'s pings on CC's own channel, with its configured coordinates
       * announces itself to the other three on a separate rednet protocol, so every beacon can
         show link status and assess the whole constellation
       * periodically checks its OWN coordinates against what the constellation says, because a
         typo'd beacon answers confidently and quietly poisons every fix in the world

     THE MODEM MUST BE WIRELESS -- an ender modem is ideal: unlimited range within a dimension,
     which is what makes beacon placement free. gps.locate() only considers modems whose
     isWireless() is true, and it discards any reply that arrives without a distance, which is
     what a cross-dimension message does. So: same dimension as the craft, always.

     The loop is Basalt's own, with modem and rednet traffic hooked into it -- the same shape as
     the ui_main computer, and for the same reason: one event loop, no competing coroutines.
]]

local Config = require("lib.config")
local Host = require("lib.host")
local Mesh = require("lib.mesh")
local Panel = require("ui.panel")
local Log = require("shared.log")

local basalt = require("basalt")

local App = {}
App.__index = App

local CONFIG_PATH = "/eh_gps_beacon_config.tbl"

--- The heartbeat interval. Guarded on the timer id -- basalt.onEvent("timer") fires for EVERY
--- timer including Basalt's own, and an unguarded handler that re-arms itself spawns a new
--- self-sustaining chain out of each one (see docs/UI.md, "the event-queue trap").
local TICK_SECONDS = 1

function App.new(opts)
  opts = opts or {}
  local self = setmetatable({}, App)
  self.configPath = opts.configPath or CONFIG_PATH

  local cfg, existed = Config.load(self.configPath)
  self.cfg = cfg
  self.configExisted = existed
  self.log = Log.new({ level = "info", capacity = 120, echo = opts.echo })

  local ok, errors = Config.validate(cfg)
  self.configValid = ok
  for _, e in ipairs(errors or {}) do self.log:error("config: %s", e) end

  self.host = Host.new(cfg, self.log)
  self.mesh = Mesh.new(cfg, self.log)
  self.lastAnnounceAt = 0
  self.lastSelfCheckAt = 0
  return self
end

function App:save()
  local ok, err = Config.save(self.configPath, self.cfg)
  if not ok then self.log:error("could not save config: %s", tostring(err)) end
  return ok
end

function App:boot()
  self.log:info("EasyHover GPS beacon '%s' booting (config %s)", tostring(self.cfg.label),
    self.configExisted and "loaded" or "defaults")

  local ok = self.host:open()
  if ok then
    -- Same modem for both: the mesh is rednet on top of the very modem GPS is using, so there
    -- is nothing extra to wire and nothing to get out of step.
    self.mesh:open(self.host.modemName)
  end

  if not Config.hasPosition(self.cfg) then
    self.log:warn("no position set -- this beacon will NOT answer pings. Set it on the screen.")
  end
  return ok
end

--- What the screen needs: our status plus the constellation's verdict.
function App:model(now)
  return {
    status = self.host:status(),
    assessment = self.mesh:assess(now),
  }
end

--- One heartbeat: announce, re-check ourselves occasionally, and redraw.
function App:tick(now)
  now = now or os.epoch("utc")

  if now - self.lastAnnounceAt >= (self.cfg.announceEverySeconds or 5) * 1000 then
    self.lastAnnounceAt = now
    self.mesh.served = self.host.served
    self.mesh:announce(now)
  end

  local checkEvery = (self.cfg.selfCheckEverySeconds or 120) * 1000
  if Config.hasPosition(self.cfg) and now - self.lastSelfCheckAt >= checkEvery then
    self.lastSelfCheckAt = now
    -- Only worth attempting once the constellation could possibly answer: below four hosts
    -- gps.locate() returns nothing, and a "no fix" every two minutes is just noise.
    local assessment = self.mesh:assess(now)
    if assessment.hostCount >= 4 then
      self.host:verify(gps.locate, self.cfg.gpsTimeout)
    end
  end

  if self.panel then self.panel.update(self:model(now)) end
end

function App:run()
  self:boot()

  local frame = basalt.createFrame()
  frame:setTerm(term.current())
  self.panel = Panel.build(frame, {
    cfg = self.cfg,
    save = function() self:save() end,
    host = self.host,
    mesh = self.mesh,
    log = self.log,
  })

  basalt.setRenderThrottleTime(1 / math.max(self.cfg.ui.refreshHz or 4, 1))

  -- A ping must be answered promptly; this is the whole job.
  basalt.onEvent("modem_message", function(side, channel, replyChannel, message)
    if self.host:onModemMessage(side, channel, replyChannel, message) then
      if self.panel then self.panel.update(self:model()) end
    end
  end)

  basalt.onEvent("rednet_message", function(sender, message, protocol)
    if self.mesh:onMessage(sender, message, protocol) then
      if self.panel then self.panel.update(self:model()) end
    end
  end)

  self.timer = os.startTimer(TICK_SECONDS)
  basalt.onEvent("timer", function(id)
    if id ~= self.timer then return end          -- see TICK_SECONDS
    self:tick()
    self.timer = os.startTimer(TICK_SECONDS)
  end)

  self:tick()
  basalt.run()
end

return App
