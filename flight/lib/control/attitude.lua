--[[ Inner loop: pitch, roll, yaw. The fast one.

     Two feel modes (docs/MODES.md):
       "angle" (Cruise / Stutter) -- the demand is an ANGLE, and releasing the stick returns
                                     the craft to level.
       "rate"  (Rate mode)       -- the demand is a rotation RATE, and the craft holds
                                     whatever attitude it reached.

     We have no rate gyro. The gimbal reports angles only, so body rates are differentiated
     here, filtered, and never trusted on a stalled cycle. In angle mode the PID's
     D-on-measurement term already provides the rate damping, which is why angle mode needs
     no explicit rate loop.

     Yaw is special: the gimbal may not report yaw at all (probe pending). Without it the
     yaw loop cannot be closed, so it degrades to OPEN LOOP -- the demand is passed through
     as a torque and `dbg.yawClosedLoop` is false. Honest, and visible in telemetry.
]]

local Util = require("lib.util")
local Filter = require("lib.control.filter")
local PID = require("lib.control.pid")

local Attitude = {}
Attitude.__index = Attitude

function Attitude.new(cfg, log, oscillation)
  local self = setmetatable({}, Attitude)
  self.cfg = cfg
  self.log = log
  self.osc = oscillation
  self.mode = "angle"

  local opts = { dtMaxMs = cfg.tuning.dtMaxMs }
  -- Two independent gain sets: angle mode and rate mode invert different plants, so
  -- sharing gains between them would compromise both.
  self.pidAngle = {
    pitch = PID.new(cfg.control.attitude.pitch, opts),
    roll = PID.new(cfg.control.attitude.roll, opts),
    yaw = PID.new(cfg.control.attitude.yaw, opts),
  }
  self.pidRate = {
    pitch = PID.new(cfg.control.attitudeRate.pitch, opts),
    roll = PID.new(cfg.control.attitudeRate.roll, opts),
    yaw = PID.new(cfg.control.attitudeRate.yaw, opts),
  }
  self.pid = self.pidAngle

  -- body-rate estimators: differentiate the measured angles, then filter hard
  local alpha = cfg.sensors.gimbal.filterAlpha
  self.rateFilter = {
    pitch = Filter.lpf(alpha, 0),
    roll = Filter.lpf(alpha, 0),
    yaw = Filter.lpf(alpha, 0),
  }
  self.last = {}
  self.rate = { pitch = 0, roll = 0, yaw = 0 }

  -- CoM feedforward: a steady pitch/roll torque bias that holds the craft level against an
  -- off-centre load, captured by CoM leveling. See loadComTrim / steadyTorque / commitComTrim.
  self.comTrim = { pitch = 0, roll = 0 }
  self:loadComTrim(cfg)
  return self
end

--- Cap on the captured bias, so a feedforward can never on its own drive an axis to saturation.
function Attitude:comTrimLimit()
  return (self.cfg.control.comLevel and self.cfg.control.comLevel.maxTrim) or 0.5
end

--- (Re)load the CoM feedforward from config -- at construction, and whenever the config changes.
function Attitude:loadComTrim(cfg)
  local ct = (cfg.control and cfg.control.comTrim) or {}
  local lim = self:comTrimLimit()
  self.comTrim.pitch = Util.clamp(ct.pitch or 0, -lim, lim)
  self.comTrim.roll = Util.clamp(ct.roll or 0, -lim, lim)
end

function Attitude:setMode(mode)
  if mode ~= "angle" and mode ~= "rate" then return false end
  if mode ~= self.mode then
    -- Reset integrators on a mode change: the two modes' errors mean different things
    -- (degrees vs degrees/second), and carrying an integral across is a transient nobody
    -- asked for.
    self.mode = mode
    self.pid = (mode == "rate") and self.pidRate or self.pidAngle
    for _, pid in pairs(self.pid) do pid:reset(true) end
    self.log:info("attitude mode -> %s", mode)
  end
  return true
end

function Attitude:reset()
  for _, pid in pairs(self.pidAngle) do pid:reset() end
  for _, pid in pairs(self.pidRate) do pid:reset() end
  for _, f in pairs(self.rateFilter) do f:reset(0) end
  self.last = {}
  self.rate = { pitch = 0, roll = 0, yaw = 0 }
end

--- Differentiate the measured angles into filtered body rates.
function Attitude:estimateRates(measured, dt)
  local dtOk = type(dt) == "number" and dt > 0 and dt <= (self.cfg.tuning.dtMaxMs / 1000)
  for _, axis in ipairs({ "pitch", "roll", "yaw" }) do
    local value = measured[axis]
    if type(value) == "number" then
      if self.last[axis] ~= nil and dtOk then
        local delta = (axis == "yaw") and Util.angleDelta(self.last[axis], value)
          or (value - self.last[axis])
        self.rate[axis] = self.rateFilter[axis]:update(delta / dt)
      end
      self.last[axis] = value
    end
  end
  return self.rate
end

--[[ demand (angle mode): { pitch = deg, roll = deg, yawRate = dps }
     demand (rate mode):  { pitchRate = dps, rollRate = dps, yawRate = dps }
     measured:            { pitch = deg, roll = deg, yaw = deg|nil }
     Returns { pitchTorque, rollTorque, yawTorque } each -1..1, plus debug.
]]
function Attitude:update(demand, measured, dt)
  self:estimateRates(measured, dt)

  local out, dbg = {}, { mode = self.mode, rates = { pitch = self.rate.pitch, roll = self.rate.roll } }

  local function axis(name, setpoint, measurement, oscKey)
    local pid = self.pid[name]
    if self.osc then pid:setGainScale(self.osc:gainScale(oscKey)) end
    local raw, info = pid:update(setpoint or 0, measurement or 0, dt,
      { saturated = self._saturated and self._saturated[name] })
    local clamped = Util.clamp(raw, -1, 1)
    self._saturated = self._saturated or {}
    self._saturated[name] = math.abs(raw) >= 1
    if self.osc then self.osc:update(oscKey, info.error, nil) end
    dbg[name] = info
    return clamped
  end

  if self.mode == "rate" then
    out.pitchTorque = axis("pitch", demand.pitchRate, self.rate.pitch, "pitchRate")
    out.rollTorque = axis("roll", demand.rollRate, self.rate.roll, "rollRate")
  else
    out.pitchTorque = axis("pitch", demand.pitch, measured.pitch, "pitch")
    out.rollTorque = axis("roll", demand.roll, measured.roll, "roll")
  end

  -- CoM feedforward. A steady bias that holds the craft level against an off-centre load, so the
  -- PID integral does not have to. Added to the loop's own output and clamped to the same rails;
  -- applied in BOTH feel modes because the offset is physical, not a mode. dbg carries it so a UI
  -- can show the craft is trimmed rather than fighting.
  out.pitchTorque = Util.clamp(out.pitchTorque + self.comTrim.pitch, -1, 1)
  out.rollTorque = Util.clamp(out.rollTorque + self.comTrim.roll, -1, 1)
  dbg.comTrim = { pitch = self.comTrim.pitch, roll = self.comTrim.roll }

  -- Yaw is always a rate demand. Closed loop only if the gimbal gives us yaw.
  if type(measured.yaw) == "number" then
    out.yawTorque = axis("yaw", demand.yawRate, self.rate.yaw, "yawRate")
    dbg.yawClosedLoop = true
  else
    local maxRate = math.max(self.cfg.envelope.maxYawRateDps, 1e-6)
    out.yawTorque = Util.clamp((demand.yawRate or 0) / maxRate, -1, 1)
    dbg.yawClosedLoop = false
  end

  return out, dbg
end

--- The steady pitch/roll torque the craft is CURRENTLY holding to stay level: the feedforward
--- already applied plus whatever the angle-mode integral has wound up to carry on top of it. At a
--- settled level hover the P and D terms are ~0, so this is the whole CoM load -- which is exactly
--- the value CoM leveling proposes as the new feedforward. Read-only; nothing is committed here.
function Attitude:steadyTorque()
  local lim = self:comTrimLimit()
  return {
    pitch = Util.clamp(self.comTrim.pitch + self.pidAngle.pitch:getIntegral(), -lim, lim),
    roll = Util.clamp(self.comTrim.roll + self.pidAngle.roll:getIntegral(), -lim, lim),
  }
end

--- Adopt a captured feedforward: set it, and ZERO the angle-mode integrals that were carrying the
--- load, so the hand-off is bump-less -- the total torque is unchanged, it has just moved from the
--- integral to the feedforward. Returns the applied (clamped) value.
function Attitude:commitComTrim(pitch, roll)
  local lim = self:comTrimLimit()
  self.comTrim.pitch = Util.clamp(pitch or 0, -lim, lim)
  self.comTrim.roll = Util.clamp(roll or 0, -lim, lim)
  self.pidAngle.pitch:clearIntegral()
  self.pidAngle.roll:clearIntegral()
  self.log:info("CoM trim committed: pitch %.3f roll %.3f", self.comTrim.pitch, self.comTrim.roll)
  return { pitch = self.comTrim.pitch, roll = self.comTrim.roll }
end

function Attitude:getComTrim()
  return { pitch = self.comTrim.pitch, roll = self.comTrim.roll }
end

--- Live retune from the config UI without losing integrator state.
function Attitude:applyGains(cfg)
  self.cfg = cfg
  for _, axis in ipairs({ "pitch", "roll", "yaw" }) do
    self.pidAngle[axis]:setGains(cfg.control.attitude[axis])
    self.pidRate[axis]:setGains(cfg.control.attitudeRate[axis])
  end
  -- comTrim can also change from the config UI (or a fresh config after accept); keep it in step.
  self:loadComTrim(cfg)
end

return Attitude
