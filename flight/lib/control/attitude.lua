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
  return self
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

--- Live retune from the config UI without losing integrator state.
function Attitude:applyGains(cfg)
  self.cfg = cfg
  for _, axis in ipairs({ "pitch", "roll", "yaw" }) do
    self.pidAngle[axis]:setGains(cfg.control.attitude[axis])
    self.pidRate[axis]:setGains(cfg.control.attitudeRate[axis])
  end
end

return Attitude
