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

     TWO COROUTINES, and the split is not cosmetic. `read()` blocks whichever loop it runs in, so
     typing a coordinate on one beacon would stop it answering pings for as long as the typing
     took -- and a craft's gps.locate() gives up after two seconds. The service loop therefore
     owns the radio and the clock, the UI loop owns the keyboard, and `parallel` runs both.

     ONLY THE UI DRAWS. If the service loop painted a status line while the UI was waiting at a
     prompt, it would scribble over what the operator was typing.
]]

local Config = require("lib.config")
local Host = require("lib.host")
local Mesh = require("lib.mesh")
local Console = require("ui.console")
local Log = require("shared.log")

local App = {}
App.__index = App

local CONFIG_PATH = "/eh_gps_beacon_config.tbl"
local TICK_SECONDS = 1

function App.new(opts)
  opts = opts or {}
  local self = setmetatable({}, App)
  self.configPath = opts.configPath or CONFIG_PATH

  local cfg, existed = Config.load(self.configPath)
  self.cfg = cfg
  self.configExisted = existed
  -- echo = false: the log must not print over the screen. Problems reach the operator through
  -- the screen itself, which is where they can act on them.
  self.log = Log.new({ level = "info", capacity = 120, echo = false })

  local ok, errors = Config.validate(cfg)
  self.configValid = ok
  for _, e in ipairs(errors or {}) do self.log:error("config: %s", e) end

  self.host = Host.new(cfg, self.log)
  self.mesh = Mesh.new(cfg, self.log)
  self.lastAnnounceAt = 0
  self.lastSelfCheckAt = 0
  self.running = false
  self.dirty = true
  return self
end

function App:save()
  local ok, err = Config.save(self.configPath, self.cfg)
  if not ok then self.log:error("could not save config: %s", tostring(err)) end
  return ok
end

function App:boot()
  self.log:info("GPS beacon '%s' booting (config %s)", tostring(self.cfg.label),
    self.configExisted and "loaded" or "defaults")

  local ok = self.host:open()
  if ok then
    -- Same modem for both: the mesh is rednet on top of the very modem GPS is using, so there
    -- is nothing extra to wire and nothing to get out of step.
    self.mesh:open(self.host.modemName)
  end
  return ok
end

function App:model(now)
  return {
    status = self.host:status(),
    assessment = self.mesh:assess(now),
  }
end

function App:redraw()
  local width, height = term.getSize()
  Console.draw(Console.render(self.cfg, self:model(), width, height), width, height)
  self.dirty = false
end

--- One heartbeat: announce, and occasionally re-check our own coordinates.
function App:tick(now)
  now = now or os.epoch("utc")

  if now - self.lastAnnounceAt >= (self.cfg.announceEverySeconds or 5) * 1000 then
    self.lastAnnounceAt = now
    self.mesh.served = self.host.served
    self.mesh:announce(now)
    self.dirty = true
  end

  local checkEvery = (self.cfg.selfCheckEverySeconds or 120) * 1000
  if Config.hasPosition(self.cfg) and now - self.lastSelfCheckAt >= checkEvery then
    self.lastSelfCheckAt = now
    -- Only worth attempting once the constellation could possibly answer: below four hosts
    -- gps.locate() returns nothing, and a "no fix" every two minutes is just noise.
    if self.mesh:assess(now).hostCount >= 4 then
      self:verify()
    end
  end
end

--- Check our coordinates against the constellation, now.
function App:verify()
  local before = self.host.selfCheck.state
  self.host:verify(gps.locate, self.cfg.gpsTimeout)
  self.dirty = true
  return self.host.selfCheck, before
end

-- ---------------------------------------------------------------- the loops

--- Radio and clock. Never draws.
function App:service()
  self.timer = os.startTimer(TICK_SECONDS)
  while self.running do
    local event = { os.pullEvent() }
    local name = event[1]

    if name == "modem_message" then
      if self.host:onModemMessage(event[2], event[3], event[4], event[5]) then
        self.dirty = true
      end
    elseif name == "rednet_message" then
      if self.mesh:onMessage(event[2], event[3], event[4]) then self.dirty = true end
    elseif name == "timer" and event[2] == self.timer then
      self:tick()
      self.timer = os.startTimer(TICK_SECONDS)
      -- Redraw from HERE, between prompts, so a status update never lands on top of typing.
      if self.dirty and not self.prompting then self:redraw() end
    end
  end
end

--- Keyboard. Owns the screen.
function App:ui()
  self:redraw()
  while self.running do
    local _, key = os.pullEvent("char")
    local action = Console.actionFor(key)

    if action == "quit" then
      self.running = false
    elseif action == "toggleEnabled" then
      self.cfg.enabled = not self.cfg.enabled
      self:save()
      self.log:info("beacon %s", self.cfg.enabled and "enabled" or "disabled")
      self:redraw()
    elseif action == "verify" then
      self:redraw()
      term.setCursorPos(1, select(2, term.getSize()))
      term.write("checking against the constellation...")
      self:verify()
      self:redraw()
    elseif action == "setPosition" then
      self:promptPosition()
      self:redraw()
    end
  end
end

--- The coordinate prompt. Sets `prompting` so the service loop leaves the screen alone.
function App:promptPosition()
  self.prompting = true
  term.setBackgroundColour(colours.black)
  term.clear()
  term.setCursorPos(1, 1)
  for _, line in ipairs(Console.positionHeader()) do print(line) end

  local wanted, err = Console.readPosition(read, self.cfg.position)
  if wanted == nil then
    print(err)
    print("")
    print("Press any key.")
    os.pullEvent("char")
    self.prompting = false
    return false
  end

  local previous = { x = self.cfg.position.x, y = self.cfg.position.y, z = self.cfg.position.z }
  self.cfg.position.x, self.cfg.position.y, self.cfg.position.z = wanted.x, wanted.y, wanted.z

  local ok, errors = Config.validate(self.cfg)
  if not ok then
    self.cfg.position.x, self.cfg.position.y, self.cfg.position.z =
      previous.x, previous.y, previous.z
    print(tostring(errors[1]))
    print("")
    print("Press any key.")
    os.pullEvent("char")
    self.prompting = false
    return false
  end

  self:save()
  -- A coordinate change invalidates the previous verdict; leaving a stale "OK" on screen after
  -- moving a beacon would be the most misleading thing it could say.
  self.host.selfCheck = { state = "unchecked" }
  self.log:info("position set to %d %d %d", wanted.x, wanted.y, wanted.z)
  self.prompting = false
  return true
end

function App:run()
  self:boot()
  self.running = true
  parallel.waitForAny(function() self:service() end, function() self:ui() end)

  self.host:close()
  self.mesh:close()
  term.setBackgroundColour(colours.black)
  term.clear()
  term.setCursorPos(1, 1)
  print("GPS beacon stopped. Run it again with: " .. tostring(shell and "startup" or "startup"))
end

return App
