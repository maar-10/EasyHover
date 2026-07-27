--[[ Thruster actuation -- the only module allowed to command thrust.

     Two facts from the mod source drive everything here (docs/MOD_API_RESEARCH.md):

     1. Every setter is mainThread = true, so each call costs a server-tick slot. The
        mod dedups internally, but the CALL still costs, so our own write-on-change is
        what protects the budget.
     2. setThrustNormalized quantises to 16 steps: floor(n * 15). So thrust is a
        stepped axis and the control layer must know it -- hence the quantiser helpers
        being public.

     Commands arrive in the CRAFT frame (defX = deflect toward craft +x/right,
     defZ = toward +z/forward) and this module maps them onto each nozzle's own X/Y
     using that thruster's vectorMap/invert config. Mount quirks stop here; nothing
     upstream should know a nozzle's axes are rotated.
]]

local Util = require("lib.util")

local Thrusters = {}
Thrusters.__index = Thrusters

local STEPS = 15  -- thrust resolution: 0..15 inclusive, i.e. 16 levels

-- ---------------------------------------------------------------- quantiser

--- The integer step the mod will actually land on for a normalised demand.
function Thrusters.thrustStep(normalized)
  if type(normalized) ~= "number" then return 0 end
  local clamped = Util.clamp(normalized, 0, 1)
  return Util.clamp(math.floor(clamped * STEPS + 1e-6), 0, STEPS)
end

--- The normalised thrust a given step actually produces.
function Thrusters.stepToNormalized(step)
  return Util.clamp(step, 0, STEPS) / STEPS
end

--- Size of one step, as a fraction of full thrust. The control layer needs this to
--- size its hysteresis band and to know what it cannot resolve with thrust alone.
function Thrusters.stepSize()
  return 1 / STEPS
end

-- ---------------------------------------------------------------- construction

function Thrusters.new(peripherals, cfg, log, state)
  local self = setmetatable({}, Thrusters)
  self.per = peripherals
  self.cfg = cfg
  self.log = log
  self.state = state
  self.last = {}        -- id -> { step, nx, ny }
  self.failures = {}    -- id -> consecutive failure count
  self.identify = nil   -- active identify sweep
  self.stats = { calls = 0, writes = 0, errors = 0 }
  return self
end

--- Forget every cached write, so the next apply re-asserts all values.
-- Called after a rescan or a mode change: the cache describes what we believe the
-- hardware holds, and after a detach that belief is void.
function Thrusters:invalidate()
  self.last = {}
  -- The slow readout cache is keyed by thruster id, and a rebuild can put a DIFFERENT block
  -- behind the same id. A stale obstruction reading against a new thruster is worse than none.
  self.slowCache = nil
  self.slowAt = 0
  self.slowCursor = 0
end

-- ---------------------------------------------------------------- mapping

local function pickAxis(cmd, axis)
  if axis == "x" then return cmd.defX or 0 end
  if axis == "y" then return cmd.defY or 0 end
  if axis == "z" then return cmd.defZ or 0 end
  return 0
end

--- Craft-frame deflection -> this thruster's nozzle X/Y, clamped to its authority.
function Thrusters.mapVector(spec, cmd)
  local map = spec.vectorMap or { x = "x", y = "z" }
  local nx = pickAxis(cmd, map.x)
  local ny = pickAxis(cmd, map.y)
  if spec.invertVectorX then nx = -nx end
  if spec.invertVectorY then ny = -ny end
  local limit = Util.clamp(spec.maxVector or 1, 0, 1)
  return Util.clamp(nx, -limit, limit), Util.clamp(ny, -limit, limit)
end

-- ---------------------------------------------------------------- apply

local function callDevice(self, id, dev, method, ...)
  local fn = dev[method]
  if type(fn) ~= "function" then
    self.log:throttled("nomethod:" .. id .. method, 5000, "error",
      "thruster %s has no %s()", id, method)
    return false
  end
  local ok, err = pcall(fn, ...)
  self.stats.calls = self.stats.calls + 1
  if not ok then
    self.stats.errors = self.stats.errors + 1
    self.failures[id] = (self.failures[id] or 0) + 1
    self.log:throttled("callfail:" .. id, 2000, "error",
      "thruster %s %s() failed: %s", id, method, tostring(err))
    return false
  end
  self.failures[id] = 0
  return true
end

--- commands: { [id] = { thrust = 0..1, defX = -1..1, defZ = -1..1 } }
-- Missing ids are left exactly as they are -- silence means "no change", not "stop".
function Thrusters:apply(commands)
  local wrote = 0
  local deadband = self.cfg.tuning.vectorDeadband or 0.01

  for _, entry in ipairs(self.per:thrusterList()) do
    local cmd = commands[entry.id]
    if cmd then
      local spec = entry.spec
      local dev = entry.dev
      local step = Thrusters.thrustStep(cmd.thrust or 0)
      local nx, ny = Thrusters.mapVector(spec, cmd)

      local last = self.last[entry.id]
      if last == nil then
        last = {}
        self.last[entry.id] = last
      end

      -- Not every thruster has a nozzle: a plain or main thruster has thrust only. Check
      -- once rather than calling a method that does not exist every cycle.
      if entry.canVector == nil then
        entry.canVector = type(dev.setVector) == "function"
        if not entry.canVector then
          self.log:info("thruster %s has no vector control (thrust only)", entry.id)
        end
      end

      -- Vector first: on a craft that is already lifting, changing direction before
      -- changing magnitude is the gentler ordering.
      --
      -- COMPARED AGAINST THE BLOCK, NOT AGAINST MEMORY. `last` is what we believe we commanded,
      -- and believing it is only safe while nothing else writes these nozzles. Something does:
      -- every vector thruster carries four Create redstone-link RECEIVERS which default to the
      -- blank frequency and join that network unconditionally, and they re-apply the network
      -- value -- 0, with no transmitter -- whenever `newPosition` is set, which a moving
      -- contraption sets constantly. Trusting our own memory there means noticing nothing and
      -- never re-asserting: the nozzle sits at zero for ever while the log says it was commanded.
      --
      -- getTargetVectorX/Y are plain @LuaFunction on the vector peripherals, so asking the block
      -- what it actually holds costs no server tick.
      local heldX, heldY = last.nx, last.ny
      if entry.canVector and type(dev.getTargetVectorX) == "function" then
        local okX, tx = pcall(dev.getTargetVectorX)
        local okY, ty = pcall(dev.getTargetVectorY)
        if okX and type(tx) == "number" then heldX = tx end
        if okY and type(ty) == "number" then heldY = ty end
      end

      if entry.canVector
        and (heldX == nil or heldY == nil
          or math.abs(nx - heldX) > deadband
          or math.abs(ny - heldY) > deadband) then
        if callDevice(self, entry.id, dev, "setVector", nx, ny) then
          last.nx, last.ny = nx, ny
          wrote = wrote + 1
        end
      end

      if last.step == nil or last.step ~= step then
        if callDevice(self, entry.id, dev, "setThrust", step) then
          last.step = step
          wrote = wrote + 1
        end
      end
    end
  end

  self.stats.writes = self.stats.writes + wrote
  if self.state then
    self.state:set("thrusters.writes", wrote)
    self.state:set("thrusters.calls", self.stats.calls)
    self.state:set("thrusters.errors", self.stats.errors)
  end
  return wrote
end

--- Neutral nozzles, thrust untouched. This is the DAMPED HOVER actuator state: stop
--- steering, keep flying.
--- Command one thruster's nozzle in its OWN axes, bypassing the craft-frame mapping.
---
--- Only the self test uses this, and only on the ground. The mapping is exactly what is under
--- test there: pushing a sweep through mapVector() would hide a mirrored or rotated mounting,
--- because the wrong mapping would cancel against itself and look correct.
--- Nozzle aim resolution. The mod does NOT store a float: `setVectorCoordinates` converts the
--- pair into four redstone signals with `Math.round(x * 15)`, so aim lives on a 15-step grid per
--- direction. Commanding 0.0005 therefore commands exactly zero, which is how a sine sweep leaving
--- the origin can move nothing at all.
Thrusters.VECTOR_STEPS = 15

--- Put a deflection on the grid the mod will store anyway, so what is commanded is what happens --
--- and so two consecutive samples landing on the same step can be recognised as one write and
--- skipped. Every setVector is `mainThread = true` and costs a server tick.
---
--- TOWARDS ZERO, NOT NEAREST. Rounding to nearest turned a maxVector of 0.30 into 0.33 and
--- silently exceeded a configured authority limit -- and because the mod rounds too, the limit is
--- only ever achievable at a grid point, so the choice is which side to miss it on. Under. Always
--- under: maxVector exists to leave the attitude loop room, and the caller asked for "no more
--- than this".
function Thrusters.quantiseVector(v)
  if type(v) ~= "number" then return 0 end
  v = math.max(-1, math.min(1, v))
  local steps = Thrusters.VECTOR_STEPS
  local sign = v < 0 and -1 or 1
  return sign * math.floor(math.abs(v) * steps) / steps
end

function Thrusters:setVectorRaw(id, nx, ny)
  local entry = self.per.thrusters[id]
  if not entry then return false, "no such thruster: " .. tostring(id) end
  if type(entry.dev.setVector) ~= "function" then return false, "no nozzle" end
  -- THE RESULT IS PROPAGATED. This called callDevice and then returned `true` regardless, so a
  -- device that threw on every write was invisible to the caller -- and the self test, which also
  -- discarded the return, counted down over a craft where nothing could move. Two layers each
  -- dropping the same error is how a fault becomes a mystery.
  local ok = callDevice(self, id, entry.dev, "setVector", nx, ny)
  self.last[id] = nil          -- our cached belief no longer holds, successful or not
  if not ok then return false, "the thruster refused setVector" end
  return true
end

--- What one nozzle is ACTUALLY doing: target (what the block accepted) and current (where the
--- nozzle has slewed to). Both getters are plain @LuaFunction on the vector peripherals, so this
--- costs no server tick and can run every cycle.
---
--- Exists so a sweep can prove itself. Commanding a nozzle and never reading it back is how
--- "RUNNING" and "nothing is moving" coexist for an hour.
function Thrusters:nozzleAim(id)
  local entry = self.per.thrusters[id]
  if not entry then return nil end
  local dev = entry.dev
  local out = {}
  local function read(method, key)
    local fn = dev[method]
    if type(fn) ~= "function" then return end
    local ok, v = pcall(fn)
    if ok and type(v) == "number" then out[key] = v end
  end
  read("getTargetVectorX", "targetX")
  read("getTargetVectorY", "targetY")
  read("getVectorX", "actualX")
  read("getVectorY", "actualY")
  return out
end

function Thrusters:neutralVectors()
  local commands = {}
  for _, entry in ipairs(self.per:thrusterList()) do
    local last = self.last[entry.id]
    commands[entry.id] = {
      thrust = Thrusters.stepToNormalized(last and last.step or 0),
      defX = 0, defZ = 0,
    }
  end
  return self:apply(commands)
end

--- Everything to zero. Only safe on the ground.
function Thrusters:allStop()
  local commands = {}
  for _, entry in ipairs(self.per:thrusterList()) do
    commands[entry.id] = { thrust = 0, defX = 0, defZ = 0 }
  end
  return self:apply(commands)
end

-- ---------------------------------------------------------------- readback

--- WHICH GETTERS COST A SERVER TICK, from the Propulsion source rather than assumption.
---
--- There is no shared base: `ThrusterPeripheralBase` declares no @LuaFunctions at all, so every
--- peripheral lists its own and they do NOT agree.
---
---   VectorThrusterPeripheral / LiquidVectorThrusterPeripheral
---     getVectorX/Y, getTargetVectorX/Y, getThrust, getPower  -- plain @LuaFunction, CHEAP.
---     Only the setters (and the fluid passthroughs) are mainThread.
---     They do not implement getCurrentThrust*, getObstruction or the fuel readouts AT ALL.
---
---   ThrusterPeripheral / solid / ion  (the plain, non-vector blocks)
---     EVERYTHING is `mainThread = true`, getters included.
---
--- So the cost is not uniform, and the correction matters: an earlier comment here claimed the
--- getters were never mainThread, and I then over-corrected to claiming they always are. Neither
--- is true. What follows splits them.
local CHEAP_READS = {
  { "getVectorX", "vecX" },
  { "getVectorY", "vecY" },
  { "getTargetVectorX", "targetX" },
  { "getTargetVectorY", "targetY" },
  { "getPower", "power" },
}

--- mainThread everywhere they exist, and none of them feeds a control loop: obstruction changes
--- when the craft is rebuilt, and thrust readout is for display and the pre-flight interlock.
local COSTLY_READS = {
  { "getObstruction", "obstruction" },
  { "getCurrentThrustKN", "thrustKN" },
}

--- How often the costly ones are refreshed. Two seconds is far inside the rate at which an
--- obstruction or a fuel state changes, and nothing in the control path reads them.
Thrusters.SLOW_READ_MS = 2000

--- Actual hardware state.
---
--- The costly reads are refreshed on a slow timer and ONE THRUSTER PER PASS, round-robin. A craft
--- with twelve thrusters otherwise spends twelve server ticks on readouts nothing is steering by,
--- every time the timer expires -- and doing them all at once turns a smooth loop into a periodic
--- stall, which is worse than a slow one. Their last values are kept and reported, so consumers
--- see a real reading with an age rather than a hole.
function Thrusters:readback()
  local out = {}
  local now = os.epoch("utc")
  self.slowCache = self.slowCache or {}
  self.slowAt = self.slowAt or 0

  -- AT MOST ONE THRUSTER PER CALL, and only when ITS OWN reading has gone stale. Each entry
  -- carries its own timestamp, so the refreshes spread themselves out instead of landing
  -- together -- a periodic stall is worse than a steady cost. A single shared timer got this
  -- wrong: it only reset once the cursor had wrapped, so every call refreshed somebody.
  local list = self.per:thrusterList()
  local refreshIndex = nil
  if #list > 0 then
    self.slowCursor = ((self.slowCursor or 0) % #list) + 1
    local candidate = list[self.slowCursor]
    local cached = candidate and self.slowCache[candidate.id]
    if cached == nil or (now - (cached.at or 0)) >= Thrusters.SLOW_READ_MS then
      refreshIndex = self.slowCursor
    end
  end

  for index, entry in ipairs(list) do
    local dev, id = entry.dev, entry.id
    local row = { id = id, group = entry.spec.group, ok = true }
    local function read(method, key)
      local fn = dev[method]
      if type(fn) ~= "function" then return end
      local ok, v = pcall(fn)
      if ok then row[key] = v else row.ok = false end
    end

    for _, pair in ipairs(CHEAP_READS) do read(pair[1], pair[2]) end

    local cached = self.slowCache[id]
    if index == refreshIndex or cached == nil then
      cached = { at = now }
      for _, pair in ipairs(COSTLY_READS) do
        local fn = dev[pair[1]]
        if type(fn) == "function" then
          local ok, v = pcall(fn)
          if ok then cached[pair[2]] = v end
        end
      end
      self.slowCache[id] = cached
    end
    for _, pair in ipairs(COSTLY_READS) do row[pair[2]] = cached[pair[2]] end
    row.slowAgeMs = now - (cached.at or now)

    row.commandedStep = (self.last[id] or {}).step
    row.failures = self.failures[id] or 0
    out[id] = row
  end
  if self.state then self.state:set("thrusters.readback", out) end
  return out
end


--- Total commanded thrust across the lift group, normalised. The altitude loop's
--- feedback on what it actually achieved after quantisation.
function Thrusters:liftCommanded()
  local total, count = 0, 0
  for _, entry in ipairs(self.per:thrusterList()) do
    if entry.spec.group == "lift" then
      local last = self.last[entry.id]
      total = total + Thrusters.stepToNormalized(last and last.step or 0)
      count = count + 1
    end
  end
  if count == 0 then return 0, 0 end
  return total / count, count
end

-- ---------------------------------------------------------------- identify

--- Start a nozzle-only identify sweep so the pilot can see which physical unit a
--- config slot refers to. Nozzle only, thrust untouched, and the caller must prove
--- we are on the ground -- an identify sweep in the air is a control input.
function Thrusters:startIdentify(id, opts)
  opts = opts or {}
  if not opts.allowed then
    return false, "identify is only permitted on the ground"
  end
  local entry = self.per.thrusters[id]
  if not entry then return false, "no such thruster: " .. tostring(id) end

  local power = 0
  local fn = entry.dev.getPower
  if type(fn) == "function" then
    local ok, v = pcall(fn)
    if ok and type(v) == "number" then power = v end
  end
  if power > 0.001 then
    return false, ("thruster %s is producing thrust (%.2f) -- refusing to sweep"):format(id, power)
  end

  self.identify = {
    id = id,
    started = os.epoch("utc"),
    durationMs = opts.durationMs or 4000,
    periodMs = opts.periodMs or 1000,
    amplitude = Util.clamp(opts.amplitude or 0.8, 0, 1),
  }
  self.log:info("identify sweep started on %s", id)
  return true
end

function Thrusters:cancelIdentify()
  if not self.identify then return false end
  local entry = self.per.thrusters[self.identify.id]
  if entry then
    callDevice(self, self.identify.id, entry.dev, "setVector", 0, 0)
    self.last[self.identify.id] = nil
  end
  self.log:info("identify sweep ended on %s", self.identify.id)
  self.identify = nil
  return true
end

--- Call once per loop while an identify is active. Returns true while running.
function Thrusters:tickIdentify()
  local ident = self.identify
  if not ident then return false end
  local elapsed = os.epoch("utc") - ident.started
  if elapsed >= ident.durationMs then
    self:cancelIdentify()
    return false
  end
  local entry = self.per.thrusters[ident.id]
  if not entry then
    self.identify = nil
    return false
  end
  local phase = (elapsed % ident.periodMs) / ident.periodMs
  local nx = math.sin(phase * 2 * math.pi) * ident.amplitude
  callDevice(self, ident.id, entry.dev, "setVector", nx, 0)
  self.last[ident.id] = nil  -- the sweep invalidates our cached belief
  return true
end

function Thrusters:isIdentifying()
  return self.identify ~= nil
end

return Thrusters
