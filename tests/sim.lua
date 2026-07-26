--[[ Synthetic plant model for offline control verification.

     This is NOT an attempt to replicate Sable's physics. It is a deliberately simple rigid
     body that reproduces the three properties which actually threaten the control loops:

       1. the 16-STEP THRUST QUANTISER, exactly as ThrusterComputerHelpers does it;
       2. FIRST-ORDER NOZZLE SLEW LAG, so commanded deflection is not achieved deflection;
       3. optional dt JITTER and SENSOR NOISE.

     Force is applied per thruster at its own position, so moments come out of `r x F` the
     same way they do in game -- which means the mixer's central claim (that toeing a pair
     inward produces lift change with NO net horizontal force) is genuinely tested here
     rather than assumed.

     Units are synthetic and self-consistent: thrust in arbitrary force units, distances in
     blocks, angles in degrees.
]]

local Sim = {}

-- ---------------------------------------------------------------- fake peripherals

--- Minimal stand-in for lib/peripherals, so the mixer can be driven without CC.
function Sim.fakePeripherals(specs)
  local entries = {}
  for _, spec in ipairs(specs) do
    entries[#entries + 1] = { id = spec.id, name = spec.id, dev = {}, spec = spec }
  end
  return {
    thrusterList = function() return entries end,
    count = function() return #entries end,
  }
end

--- The default four-corner lift layout plus a main and two yaw thrusters.
function Sim.defaultLayout()
  return {
    { id = "lift_fl", group = "lift", pos = { x = -1.5, y = 0, z = 2.0 }, thrustAxis = "down",
      vectorMap = { x = "x", y = "z" }, maxVector = 0.8, enabled = true },
    { id = "lift_fr", group = "lift", pos = { x = 1.5, y = 0, z = 2.0 }, thrustAxis = "down",
      vectorMap = { x = "x", y = "z" }, maxVector = 0.8, enabled = true },
    { id = "lift_rl", group = "lift", pos = { x = -1.5, y = 0, z = -2.0 }, thrustAxis = "down",
      vectorMap = { x = "x", y = "z" }, maxVector = 0.8, enabled = true },
    { id = "lift_rr", group = "lift", pos = { x = 1.5, y = 0, z = -2.0 }, thrustAxis = "down",
      vectorMap = { x = "x", y = "z" }, maxVector = 0.8, enabled = true },
    { id = "main", group = "main", pos = { x = 0, y = 0, z = -2.5 }, thrustAxis = "forward",
      vectorMap = { x = "x", y = "z" }, maxVector = 0.2, enabled = true },
    { id = "yaw_l", group = "lateral", pos = { x = -1.2, y = 0, z = 2.0 }, thrustAxis = "right",
      yawAuthority = true, vectorMap = { x = "x", y = "z" }, maxVector = 0.2, enabled = true },
    { id = "yaw_r", group = "lateral", pos = { x = 1.2, y = 0, z = 2.0 }, thrustAxis = "left",
      yawAuthority = true, vectorMap = { x = "x", y = "z" }, maxVector = 0.2, enabled = true },
    { id = "rear_l", group = "lateral", pos = { x = -1.2, y = 0, z = -2.0 }, thrustAxis = "right",
      precisionOnly = true, vectorMap = { x = "x", y = "z" }, maxVector = 0.2, enabled = true },
    { id = "rear_r", group = "lateral", pos = { x = 1.2, y = 0, z = -2.0 }, thrustAxis = "left",
      precisionOnly = true, vectorMap = { x = "x", y = "z" }, maxVector = 0.2, enabled = true },
  }
end

-- ---------------------------------------------------------------- plant

local Plant = {}
Plant.__index = Plant

local STEPS = 15

--- Exactly the mod's quantiser: floor(n * 15).
function Sim.quantise(normalized)
  local clamped = math.max(0, math.min(1, normalized or 0))
  return math.floor(clamped * STEPS + 1e-6) / STEPS
end

function Sim.newPlant(opts)
  opts = opts or {}
  local self = setmetatable({}, Plant)
  self.specs = opts.specs or Sim.defaultLayout()
  self.mass = opts.mass or 1.0
  self.gravity = opts.gravity or 9.8
  -- Thrust-to-weight about 1.54, so hover sits near collective 0.65. Deliberately not
  -- higher: see docs/CONTROL_LAWS.md section 4a -- a high thrust-to-weight ratio puts hover
  -- low in the throttle range, which makes each of the 16 steps a bigger lurch.
  self.maxThrust = opts.maxThrust or (self.mass * self.gravity / (4 * 0.65))
  self.maxNozzleDeg = opts.maxNozzleDeg or 30
  self.slewTau = opts.slewTau or 0.15        -- s; the probe will measure the real one
  self.momentGain = opts.momentGain or 8.0   -- deg/s^2 per (force * block)
  self.angularDamping = opts.angularDamping or 1.2
  self.linearDamping = opts.linearDamping or 0.08
  self.groundY = opts.groundY or 64
  self.noise = opts.noise or 0

  self.y = opts.altitude or 70
  self.vy = 0
  self.pitch, self.roll = opts.pitch or 0, opts.roll or 0
  self.pitchRate, self.rollRate = 0, 0
  self.vx, self.vz = 0, 0

  self.nozzle = {}
  for _, spec in ipairs(self.specs) do
    self.nozzle[spec.id] = { x = 0, z = 0 }
  end
  self.lastForces = {}
  return self
end

local function seeded(self)
  -- deterministic pseudo-noise: reproducible test failures matter more than realism
  self._n = ((self._n or 12345) * 1103515245 + 12345) % 2147483648
  return (self._n / 2147483648) * 2 - 1
end

--- Advance the plant. `commands` is what the mixer produced.
function Plant:step(commands, dt)
  local totalUp, totalX, totalZ = 0, 0, 0
  local pitchMoment, rollMoment = 0, 0
  self.lastForces = {}

  -- nozzle lag: first-order approach to the commanded deflection
  local lag = (self.slewTau > 0) and math.min(1, dt / self.slewTau) or 1

  for _, spec in ipairs(self.specs) do
    local cmd = commands[spec.id] or { thrust = 0, defX = 0, defZ = 0 }
    local nozzle = self.nozzle[spec.id]
    local limit = spec.maxVector or 1
    local targetX = math.max(-limit, math.min(limit, cmd.defX or 0))
    local targetZ = math.max(-limit, math.min(limit, cmd.defZ or 0))
    nozzle.x = nozzle.x + (targetX - nozzle.x) * lag
    nozzle.z = nozzle.z + (targetZ - nozzle.z) * lag

    local T = Sim.quantise(cmd.thrust) * self.maxThrust
    local ax = math.rad(nozzle.x * self.maxNozzleDeg)
    local az = math.rad(nozzle.z * self.maxNozzleDeg)

    local up, fx, fz = 0, 0, 0
    if spec.group == "lift" then
      up = T * math.cos(ax) * math.cos(az)
      fx = T * math.sin(ax)
      fz = T * math.sin(az)
      pitchMoment = pitchMoment + spec.pos.z * up
      rollMoment = rollMoment - spec.pos.x * up
    elseif spec.group == "main" then
      fz = T
    else
      -- lateral thrusters push along their axis
      local axisX = (spec.thrustAxis == "right") and 1 or ((spec.thrustAxis == "left") and -1 or 0)
      local axisZ = (spec.thrustAxis == "forward") and 1 or ((spec.thrustAxis == "back") and -1 or 0)
      fx = T * axisX
      fz = T * axisZ
    end

    totalUp = totalUp + up
    totalX = totalX + fx
    totalZ = totalZ + fz
    self.lastForces[spec.id] = { up = up, x = fx, z = fz, thrust = T }
  end

  self.netUp, self.netX, self.netZ = totalUp, totalX, totalZ

  -- linear
  local ay = (totalUp - self.mass * self.gravity) / self.mass
  self.vy = self.vy + ay * dt
  self.vy = self.vy * (1 - self.linearDamping * dt)
  self.y = self.y + self.vy * dt

  self.vx = (self.vx + (totalX / self.mass) * dt) * (1 - self.linearDamping * dt)
  self.vz = (self.vz + (totalZ / self.mass) * dt) * (1 - self.linearDamping * dt)

  -- angular, in degrees
  self.pitchRate = (self.pitchRate + pitchMoment * self.momentGain * dt)
    * (1 - self.angularDamping * dt)
  self.rollRate = (self.rollRate + rollMoment * self.momentGain * dt)
    * (1 - self.angularDamping * dt)
  self.pitch = self.pitch + self.pitchRate * dt
  self.roll = self.roll + self.rollRate * dt

  -- ground
  self.onGround = false
  if self.y <= self.groundY then
    self.y = self.groundY
    if self.vy < 0 then self.vy = 0 end
    self.onGround = true
    self.pitchRate, self.rollRate = 0, 0
  end

  return self
end

--- What the sensors would report.
function Plant:sense()
  local n = self.noise
  return {
    altitude = self.y + (n > 0 and seeded(self) * n or 0),
    verticalSpeed = self.vy + (n > 0 and seeded(self) * n * 0.5 or 0),
    pitch = self.pitch + (n > 0 and seeded(self) * n or 0),
    roll = self.roll + (n > 0 and seeded(self) * n or 0),
    groundContact = self.onGround and math.abs(self.vy) < 0.15,
  }
end

-- ---------------------------------------------------------------- run harness

--[[ Run the real control loops against the plant.
     opts = {
       cfg, seconds, hz, target = {altitude=}, attitudeDemand = {pitch=,roll=},
       plant = {...}, dtSpikeAt = seconds, dtSpikeSize = seconds,
       mode = "angle"|"rate", groundHoldSeconds = n,
     }
     Returns a trace: { { t, altitude, vs, pitch, roll, collective, trim, step, ... }, ... }
]]
function Sim.run(modules, opts)
  local cfg = opts.cfg
  local hz = opts.hz or cfg.tuning.attitudeHz
  local dt = 1 / hz
  local steps = math.floor((opts.seconds or 20) * hz)
  local plant = opts.plantObject or Sim.newPlant(opts.plant)
  local trace = {}

  local attitudeEvery = math.max(1, math.floor(hz / cfg.tuning.altitudeHz))

  local lastAltOut = { collective = 0, verticalTrim = 0 }
  local lastAltDbg = {}

  for i = 1, steps do
    local t = i * dt
    local thisDt = dt
    if opts.dtSpikeAt and math.abs(t - opts.dtSpikeAt) < dt / 2 then
      thisDt = opts.dtSpikeSize or 2.0
    end

    local measured = plant:sense()
    if opts.groundHoldSeconds and t <= opts.groundHoldSeconds then
      measured.groundContact = true
    end

    -- outer loop at its own, slower rate
    if i % attitudeEvery == 1 or attitudeEvery == 1 then
      lastAltOut, lastAltDbg = modules.altitude:update(opts.target or {}, measured,
        thisDt * attitudeEvery)
    end

    local attDemand = opts.attitudeDemand or { pitch = 0, roll = 0, yawRate = 0 }
    if opts.demandAt then attDemand = opts.demandAt(t) or attDemand end
    local torques = modules.attitude:update(attDemand, measured, thisDt)

    local commands = modules.mixer:mix({
      collective = lastAltOut.collective,
      verticalTrim = lastAltOut.verticalTrim,
      pitchTorque = torques.pitchTorque,
      rollTorque = torques.rollTorque,
      yawTorque = torques.yawTorque,
      translateX = opts.translateX or 0,
      translateZ = opts.translateZ or 0,
      mainThrust = opts.mainThrust or 0,
      allowPrecision = opts.allowPrecision or false,
    })

    plant:step(commands, thisDt)

    trace[#trace + 1] = {
      t = t,
      altitude = plant.y,
      vs = plant.vy,
      pitch = plant.pitch,
      roll = plant.roll,
      collective = lastAltOut.collective,
      trim = lastAltOut.verticalTrim,
      step = lastAltDbg.step,
      residual = lastAltDbg.residual,
      trimSaturated = lastAltDbg.trimSaturated,
      netX = plant.netX,
      netZ = plant.netZ,
      commands = commands,
    }
  end

  return trace, plant
end

-- ---------------------------------------------------------------- analysis

--- Peak-to-peak spread of a field over the last `seconds` of a trace.
function Sim.peakToPeak(trace, field, seconds)
  if #trace == 0 then return 0 end
  local cutoff = trace[#trace].t - (seconds or 5)
  local lo, hi
  for _, row in ipairs(trace) do
    if row.t >= cutoff then
      local v = row[field]
      if type(v) == "number" then
        lo = (lo == nil or v < lo) and v or lo
        hi = (hi == nil or v > hi) and v or hi
      end
    end
  end
  if lo == nil then return 0 end
  return hi - lo
end

--- Is the oscillation envelope shrinking? Compares the first and second half of a window.
function Sim.isConverging(trace, field, seconds)
  if #trace < 20 then return false end
  local endT = trace[#trace].t
  local start = endT - (seconds or 10)
  local mid = start + (seconds or 10) / 2
  local function spread(from, to)
    local lo, hi
    for _, row in ipairs(trace) do
      if row.t >= from and row.t <= to then
        local v = row[field]
        if type(v) == "number" then
          lo = (lo == nil or v < lo) and v or lo
          hi = (hi == nil or v > hi) and v or hi
        end
      end
    end
    if lo == nil then return 0 end
    return hi - lo
  end
  local first, second = spread(start, mid), spread(mid, endT)
  -- allow a small tolerance so a perfectly settled trace (both ~0) still counts
  return second <= first + 1e-6
end

function Sim.last(trace, field)
  if #trace == 0 then return nil end
  return trace[#trace][field]
end

function Sim.maxAbs(trace, field)
  local worst = 0
  for _, row in ipairs(trace) do
    local v = row[field]
    if type(v) == "number" then worst = math.max(worst, math.abs(v)) end
  end
  return worst
end

function Sim.anyTrue(trace, field)
  for _, row in ipairs(trace) do
    if row[field] then return true end
  end
  return false
end

return Sim
