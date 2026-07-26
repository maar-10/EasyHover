--[[ The oscillation detector -- the direct answer to "no oscillation that escalates itself".

     The loop watches its own error signal per axis and counts sign changes. Sustained
     high-frequency sign flipping is what divergence looks like before it becomes visible,
     so above a threshold we do not wait and hope:

       trip 1..n-1  -> cut that axis's gain (gain scheduling) and annunciate
       trip n       -> shouldDamp() goes true, and the caller drops to DAMPED HOVER

     Recovery is stepwise and slow: after a quiet period the gain is restored one step at a
     time. An instant restore would just re-provoke the oscillation that caused the cut.

     Errors below errorEpsilon are ignored. Near the setpoint, sign flips are just noise,
     and counting them would trip a perfectly healthy loop that is simply sitting on target.
]]

local Util = require("lib.util")

local Oscillation = {}
Oscillation.__index = Oscillation

function Oscillation.new(cfg, log)
  local self = setmetatable({}, Oscillation)
  self.cfg = cfg.control.oscillation
  self.log = log
  self.axes = {}
  return self
end

function Oscillation:_axis(name)
  local axis = self.axes[name]
  if not axis then
    axis = { lastSign = 0, flips = {}, gainScale = 1.0, trips = 0, lastTripAt = nil, lastEventAt = nil }
    self.axes[name] = axis
  end
  return axis
end

--- Feed the loop error for an axis once per cycle. Returns true on a NEW trip.
function Oscillation:update(name, err, now)
  now = now or os.epoch("utc")
  local c = self.cfg
  local axis = self:_axis(name)

  if type(err) ~= "number" then return false end

  -- sign, with a dead zone around the setpoint
  local sign = 0
  if err > c.errorEpsilon then sign = 1
  elseif err < -c.errorEpsilon then sign = -1 end

  if sign ~= 0 then
    if axis.lastSign ~= 0 and sign ~= axis.lastSign then
      axis.flips[#axis.flips + 1] = now
    end
    axis.lastSign = sign
  end

  -- drop flips that have aged out of the window
  local cutoff = now - c.windowMs
  local kept = {}
  for _, t in ipairs(axis.flips) do
    if t >= cutoff then kept[#kept + 1] = t end
  end
  axis.flips = kept

  -- trip?
  if #axis.flips >= c.signFlipsToTrip then
    axis.trips = axis.trips + 1
    axis.gainScale = math.max(c.minGainScale, axis.gainScale * c.gainCutFactor)
    axis.lastTripAt = now
    axis.flips = {}
    axis.lastSign = 0
    self.log:warn("oscillation on %s: trip %d, gain scaled to %.2f",
      name, axis.trips, axis.gainScale)
    return true
  end

  -- stepwise recovery after a quiet period
  if axis.lastTripAt and axis.gainScale < 1.0
    and (now - axis.lastTripAt) > c.recoverMs and #axis.flips == 0 then
    axis.gainScale = math.min(1.0, axis.gainScale / c.gainCutFactor)
    axis.lastTripAt = now
    self.log:info("oscillation on %s: quiet, gain restored to %.2f", name, axis.gainScale)
  end

  return false
end

--- Multiply an axis's PID output by this. 1.0 when healthy.
function Oscillation:gainScale(name)
  return self:_axis(name).gainScale
end

function Oscillation:trips(name)
  return self:_axis(name).trips
end

--- Has any axis tripped often enough that we should stop steering and just hover?
function Oscillation:shouldDamp()
  for name, axis in pairs(self.axes) do
    if axis.trips >= self.cfg.tripsToDamped then return true, name end
  end
  return false
end

--- Called once the caller has actually entered DAMPED HOVER, so the trip count does not
--- immediately re-trigger it on the way out.
function Oscillation:acknowledgeDamped()
  for _, axis in pairs(self.axes) do
    axis.trips = 0
    axis.flips = {}
    axis.lastSign = 0
  end
end

function Oscillation:reset(name)
  if name then
    self.axes[name] = nil
  else
    self.axes = {}
  end
end

--- Snapshot for telemetry and the PFD's health strip.
function Oscillation:status()
  local out = {}
  for _, name in ipairs(Util.sortedKeys(self.axes)) do
    local axis = self.axes[name]
    out[name] = {
      gainScale = axis.gainScale,
      trips = axis.trips,
      flipsInWindow = #axis.flips,
      degraded = axis.gainScale < 1.0,
    }
  end
  return out
end

return Oscillation
