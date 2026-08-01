--[[ PID with the discipline from docs/CONTROL_LAWS.md baked in, not bolted on.

     Three rules this implementation enforces structurally, because every one of them is a
     way a naive PID turns into an oscillator:

     1. DERIVATIVE ON MEASUREMENT, FILTERED. The D term differentiates the measurement, not
        the error, so a setpoint step produces no derivative kick. The result is low-passed
        because gimbal angles are noisy and differentiation amplifies exactly that noise.

     2. dt DISCIPLINE. A cycle that overran (a mainThread stall, a chunk hiccup) does not
        get integrated or differentiated over its huge dt -- it falls back to proportional
        only for that cycle. A dt spike through an undisciplined PID is a guaranteed kick.

     3. CONDITIONAL INTEGRATION. While the output is saturated, the integrator may only move
        toward zero, never further into the stop. That is anti-windup without a magic
        constant.
]]

local Util = require("lib.util")
local Filter = require("lib.control.filter")

local PID = {}
PID.__index = PID

--- gains: { p, i, d, iClamp, dAlpha }
--- opts:  { dtMaxMs, name }
function PID.new(gains, opts)
  gains = gains or {}
  opts = opts or {}
  local self = setmetatable({}, PID)
  self.p = gains.p or 0
  self.i = gains.i or 0
  self.d = gains.d or 0
  self.iClamp = gains.iClamp or 1.0
  self.dFilter = Filter.lpf(gains.dAlpha or 0.3, 0)
  self.dtMax = (opts.dtMaxMs or 250) / 1000
  self.name = opts.name or "pid"
  self.gainScale = 1.0
  self.integral = 0
  self.lastMeasurement = nil
  self.stats = { dtSkips = 0, freezes = 0, updates = 0 }
  return self
end

--- setpoint, measurement, dt (seconds), flags { saturated }
-- Returns output, debug.
function PID:update(setpoint, measurement, dt, flags)
  flags = flags or {}
  local err = (setpoint or 0) - (measurement or 0)
  self.stats.updates = self.stats.updates + 1

  local dtOk = type(dt) == "number" and dt > 0 and dt <= self.dtMax
  if not dtOk then self.stats.dtSkips = self.stats.dtSkips + 1 end

  -- integral: only on a good dt, and never further into saturation
  local frozen = false
  if dtOk and self.i ~= 0 then
    local candidate = self.integral + err * dt * self.i
    if flags.saturated and math.abs(candidate) > math.abs(self.integral) then
      frozen = true
      self.stats.freezes = self.stats.freezes + 1
    else
      self.integral = Util.clamp(candidate, -self.iClamp, self.iClamp)
    end
  end

  -- derivative on MEASUREMENT (hence the minus), filtered
  local dTerm = 0
  if dtOk and self.lastMeasurement ~= nil and self.d ~= 0 then
    local rate = ((measurement or 0) - self.lastMeasurement) / dt
    dTerm = -self.d * self.dFilter:update(rate)
  end
  -- always advance the measurement history, even on a skipped cycle, so the next
  -- derivative covers one interval rather than two
  self.lastMeasurement = measurement

  local pTerm = self.p * err
  local output = (pTerm + self.integral + dTerm) * self.gainScale

  return output, {
    error = err,
    p = pTerm,
    i = self.integral,
    d = dTerm,
    output = output,
    dt = dt,
    dtSkipped = not dtOk,
    integralFrozen = frozen,
    gainScale = self.gainScale,
  }
end

--- Read the accumulated integral without disturbing it. CoM leveling proposes a feedforward from
--- the steady load the loop is holding, and must do so before the pilot has accepted anything.
function PID:getIntegral()
  return self.integral
end

--- Zero the integral, keeping every other part of the state. Used when a feedforward has taken
--- over the steady load the integral was carrying, so that load is never applied twice.
function PID:clearIntegral()
  self.integral = 0
end

--- Gain scheduling hook for the oscillation detector. 1.0 = full authority.
function PID:setGainScale(scale)
  self.gainScale = Util.clamp(scale or 1.0, 0.0, 1.0)
end

function PID:reset(keepGainScale)
  self.integral = 0
  self.lastMeasurement = nil
  self.dFilter:reset(0)
  if not keepGainScale then self.gainScale = 1.0 end
end

--- Rebuild gains from config without losing integrator state -- live retuning from the UI.
function PID:setGains(gains)
  if gains.p ~= nil then self.p = gains.p end
  if gains.i ~= nil then self.i = gains.i end
  if gains.d ~= nil then self.d = gains.d end
  if gains.iClamp ~= nil then
    self.iClamp = gains.iClamp
    self.integral = Util.clamp(self.integral, -self.iClamp, self.iClamp)
  end
  if gains.dAlpha ~= nil then self.dFilter.alpha = Util.clamp(gains.dAlpha, 0.001, 1.0) end
end

return PID
