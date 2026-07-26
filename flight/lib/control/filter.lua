--[[ Pure signal-processing primitives used by the sensor layer and the control laws.

     Deliberately small and stateful-by-object so every filter's memory is explicit --
     hidden filter state is how a controller ends up behaving differently on the second
     flight than the first.
]]

local Util = require("lib.util")

local Filter = {}

-- ------------------------------------------------------------ low-pass

local LPF = {}
LPF.__index = LPF

--- First-order low-pass. alpha in (0,1]: 1 = passthrough, smaller = smoother.
function Filter.lpf(alpha, initial)
  return setmetatable({ alpha = Util.clamp(alpha or 0.3, 0.001, 1.0), value = initial }, LPF)
end

function LPF:update(x)
  if type(x) ~= "number" then return self.value end
  if self.value == nil then
    self.value = x
  else
    self.value = self.value + self.alpha * (x - self.value)
  end
  return self.value
end

function LPF:get() return self.value end
function LPF:reset(v) self.value = v end

-- ------------------------------------------------------------ rate limit

local Rate = {}
Rate.__index = Rate

--- Slew limiter. `perSecond` is the maximum change; dt is in seconds.
function Filter.rateLimit(perSecond, initial)
  return setmetatable({ max = math.abs(perSecond), value = initial }, Rate)
end

function Rate:update(target, dt)
  if type(target) ~= "number" then return self.value end
  if self.value == nil or dt == nil or dt <= 0 then
    self.value = target
    return self.value
  end
  local limit = self.max * dt
  local delta = target - self.value
  if delta > limit then delta = limit elseif delta < -limit then delta = -limit end
  self.value = self.value + delta
  return self.value
end

function Rate:get() return self.value end
function Rate:reset(v) self.value = v end

-- ------------------------------------------------------------ hysteresis

local Hyst = {}
Hyst.__index = Hyst

--- Schmitt trigger on an integer-stepped axis.
-- Holds the current step until the requested step differs by more than `threshold`
-- steps for `holdSamples` consecutive updates. This is what stops the 16-step thrust
-- axis from dithering between two adjacent levels forever.
-- `snap`: a difference this large commits IMMEDIATELY, without waiting for holdSamples.
-- Hysteresis exists to suppress dither near the current value, not to slow down genuine
-- large changes. Without this, a cold start or a reset spends holdSamples cycles at the
-- initial value -- which for a thrust axis means the craft briefly gets nothing.
function Filter.hysteresis(threshold, holdSamples, initial, snap)
  return setmetatable({
    threshold = threshold or 1.5,
    holdSamples = math.max(1, holdSamples or 3),
    snap = snap or math.max(2, (threshold or 1.5) * 3),
    value = initial or 0,
    pending = nil,
    pendingCount = 0,
  }, Hyst)
end

--- `requested` is the ideal (fractional) step. Returns the committed integer step.
function Hyst:update(requested)
  if type(requested) ~= "number" then return self.value end
  if math.abs(requested - self.value) <= self.threshold then
    self.pending, self.pendingCount = nil, 0
    return self.value
  end
  local target = Util.round(requested)
  if target == self.value then
    self.pending, self.pendingCount = nil, 0
    return self.value
  end
  if math.abs(requested - self.value) >= self.snap then
    self.value = target
    self.pending, self.pendingCount = nil, 0
    return self.value
  end
  if self.pending == target then
    self.pendingCount = self.pendingCount + 1
  else
    self.pending, self.pendingCount = target, 1
  end
  if self.pendingCount >= self.holdSamples then
    self.value = target
    self.pending, self.pendingCount = nil, 0
  end
  return self.value
end

function Hyst:get() return self.value end
function Hyst:reset(v)
  self.value = v or 0
  self.pending, self.pendingCount = nil, 0
end

-- ------------------------------------------------------------ median

--- Median of the last n samples. Kills single-sample spikes that an LPF would smear
--- across several cycles instead of rejecting.
local Median = {}
Median.__index = Median

function Filter.median(n)
  return setmetatable({ n = math.max(1, n or 3), buf = {} }, Median)
end

function Median:update(x)
  if type(x) ~= "number" then return self:get() end
  table.insert(self.buf, x)
  if #self.buf > self.n then table.remove(self.buf, 1) end
  return self:get()
end

function Median:get()
  local count = #self.buf
  if count == 0 then return nil end
  local sorted = {}
  for i = 1, count do sorted[i] = self.buf[i] end
  table.sort(sorted)
  if count % 2 == 1 then return sorted[(count + 1) / 2] end
  return (sorted[count / 2] + sorted[count / 2 + 1]) / 2
end

function Median:reset()
  self.buf = {}
end

-- ------------------------------------------------------------ deadband / expo

function Filter.deadband(x, band)
  if math.abs(x) <= band then return 0 end
  -- rescale so the output is continuous at the band edge instead of jumping
  local sign = x > 0 and 1 or -1
  return sign * (math.abs(x) - band) / (1 - band)
end

--- Exponential response curve: 0 = linear, 1 = fully cubic. Keeps fine authority
--- near centre without losing full deflection at the stops.
function Filter.expo(x, amount)
  amount = Util.clamp(amount or 0, 0, 1)
  return (1 - amount) * x + amount * x * x * x
end

return Filter
