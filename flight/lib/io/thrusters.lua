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
      if entry.canVector
        and (last.nx == nil or last.ny == nil
          or math.abs(nx - last.nx) > deadband
          or math.abs(ny - last.ny) > deadband) then
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
function Thrusters:setVectorRaw(id, nx, ny)
  local entry = self.per.thrusters[id]
  if not entry then return false, "no such thruster: " .. tostring(id) end
  if type(entry.dev.setVector) ~= "function" then return false, "no nozzle" end
  callDevice(self, id, entry.dev, "setVector", nx, ny)
  self.last[id] = nil          -- our cached belief no longer holds
  return true
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

--- Actual hardware state.
---
--- NOT CHEAP. This said "getters are NOT mainThread, so this is cheap" and that is wrong: every
--- @LuaFunction on ThrusterPeripheral is declared `mainThread = true`, getters included
--- (getPower, getCurrentThrustPN/KN, getObstruction, the fuel readouts -- all of them), so each
--- call waits on a server tick. Verified against the Propulsion source, not inferred.
function Thrusters:readback()
  local out = {}
  for _, entry in ipairs(self.per:thrusterList()) do
    local dev, id = entry.dev, entry.id
    local row = { id = id, group = entry.spec.group, ok = true }
    local function read(method, key)
      local fn = dev[method]
      if type(fn) ~= "function" then return end
      local ok, v = pcall(fn)
      if ok then row[key] = v else row.ok = false end
    end
    read("getPower", "power")
    read("getVectorX", "vecX")
    read("getVectorY", "vecY")
    read("getTargetVectorX", "targetX")
    read("getTargetVectorY", "targetY")
    read("getObstruction", "obstruction")
    read("getCurrentThrustKN", "thrustKN")
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
