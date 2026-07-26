--[[ Portable-engine master control: the vehicle's on/off switch.

     THE INVERSION IS THE WHOLE POINT. The funnel above the engine passes items only while it
     is UNPOWERED, so holding the redstone HIGH blocks it and dropping the signal briefly lets
     exactly one item through. That inverts everything you would expect:

       master OFF -> signal held HIGH, continuously. Funnel blocked, nothing feeds the engine,
                     the vehicle is off. This is also the state at boot, and the state we fall
                     back to on any error -- an engine that will not start is a much better
                     failure than a funnel that empties the whole vault into it.
       master ON  -> one interrupt pulse immediately (the kickstart), then an interrupt every
                     `intervalMs` to feed one more item and keep it running.

     Timings are configurable because they depend on the build: `pulseMs` must be long enough
     for one item to pass and short enough that a second cannot follow, and `intervalMs` must
     be shorter than the engine's burn time.

     `invert` flips the polarity for a build wired the other way round. Everything below is
     written in terms of "blocked" and "feeding" rather than high and low, so the inversion
     lives in exactly one place.
]]

local Engine = {}
Engine.__index = Engine

function Engine.new(peripherals, cfg, log, state)
  local self = setmetatable({}, Engine)
  self.per = peripherals
  self.cfg = cfg
  self.log = log
  self.state = state

  self.master = cfg.engine.masterDefault and true or false
  self.feeding = false          -- true while the funnel is being allowed to pass an item
  self.pulseEndsAt = nil
  self.nextPulseAt = nil
  self.pulses = 0
  self.lastWritten = nil        -- what we last told the relay, for write-on-change
  self.failures = 0
  return self
end

function Engine:available()
  return self.cfg.engine.enabled and self.per.engine ~= nil
end

--- Write the physical output. `feeding` true means "let an item through".
-- The single place the inversion is applied.
function Engine:_write(feeding)
  if not self:available() then return false end
  if self.lastWritten == feeding then return true end

  local signal = not feeding            -- blocked = signal HIGH, by default
  if self.cfg.engine.invert then signal = not signal end

  local item = self.per.engine
  local fn = item.dev.setOutput
  if type(fn) ~= "function" then
    self.log:throttled("engine_nomethod", 10000, "error",
      "engine relay %s has no setOutput()", tostring(item.name))
    return false
  end
  local ok, err = pcall(fn, item.side, signal)
  if not ok then
    self.failures = self.failures + 1
    self.log:throttled("engine_write", 2000, "error",
      "engine relay write failed (%d): %s", self.failures, tostring(err))
    return false
  end
  self.failures = 0
  self.lastWritten = feeding
  self.feeding = feeding
  return true
end

--- Turn the vehicle on or off. Returns the new master state.
function Engine:setMaster(on, now)
  now = now or os.epoch("utc")
  on = on and true or false
  if on == self.master then return self.master end
  self.master = on

  if not on then
    -- Off: block the funnel and hold it blocked. No pending pulse survives.
    self.pulseEndsAt, self.nextPulseAt = nil, nil
    self:_write(false)
    self.log:info("engine master OFF: funnel blocked")
  else
    if self.cfg.engine.kickstart then
      self:_startPulse(now)
      self.log:info("engine master ON: kickstart pulse")
    else
      self:_write(false)
      self.nextPulseAt = now + self.cfg.engine.intervalMs
      self.log:info("engine master ON: first feed in %d ms", self.cfg.engine.intervalMs)
    end
  end
  self:publish()
  return self.master
end

function Engine:toggleMaster(now)
  return self:setMaster(not self.master, now)
end

function Engine:_startPulse(now)
  self.pulseEndsAt = now + self.cfg.engine.pulseMs
  self.nextPulseAt = nil
  self.pulses = self.pulses + 1
  self:_write(true)
end

--- Call once per control cycle. Drives the pulse state machine.
function Engine:tick(now)
  now = now or os.epoch("utc")
  if not self:available() then return end

  if not self.master then
    -- Held blocked. Re-assert rather than assume: a rescan or a relay reboot could have
    -- dropped the output, and an unblocked funnel with the master off would quietly drain
    -- the vault.
    self:_write(false)
    return
  end

  if self.pulseEndsAt then
    if now >= self.pulseEndsAt then
      self.pulseEndsAt = nil
      self.nextPulseAt = now + self.cfg.engine.intervalMs
      self:_write(false)
    end
    return
  end

  if self.nextPulseAt and now >= self.nextPulseAt then
    self:_startPulse(now)
    return
  end

  if not self.nextPulseAt then
    self.nextPulseAt = now + self.cfg.engine.intervalMs
  end
  self:_write(false)
end

--- Force a feed now, without waiting for the interval. For a manual "prime" button.
function Engine:feedNow(now)
  now = now or os.epoch("utc")
  if not self:available() then return false, "no engine relay configured" end
  if not self.master then return false, "engine master is off" end
  self:_startPulse(now)
  return true
end

--- Put the output back to blocked. Called on shutdown and on hardware change.
function Engine:blockNow()
  self.pulseEndsAt, self.nextPulseAt = nil, nil
  self.lastWritten = nil          -- force the write
  return self:_write(false)
end

function Engine:invalidate()
  self.lastWritten = nil
end

function Engine:status(now)
  now = now or os.epoch("utc")
  local remaining = nil
  if self.master and self.nextPulseAt then
    remaining = math.max(0, self.nextPulseAt - now)
  end
  return {
    available = self:available(),
    master = self.master,
    feeding = self.feeding,
    pulses = self.pulses,
    nextFeedInMs = remaining,
    intervalMs = self.cfg.engine.intervalMs,
    pulseMs = self.cfg.engine.pulseMs,
    relay = self.per.engine and self.per.engine.name or nil,
    side = self.per.engine and self.per.engine.side or nil,
  }
end

function Engine:publish(now)
  if not self.state then return end
  local status = self:status(now)
  self.state:setGroup("engine", {
    available = status.available,
    master = status.master,
    feeding = status.feeding,
    pulses = status.pulses,
    nextFeedInMs = status.nextFeedInMs,
  })
end

function Engine:applyConfig(cfg)
  self.cfg = cfg
  self.lastWritten = nil
end

return Engine
