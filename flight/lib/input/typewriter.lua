--[[ Linked Typewriter input -- POLLED, never event-driven.

     This is the hard-won lesson from DriveByWire v9, and the peripheral's own API confirms
     it structurally: LinkedTypewriterPeripheral exposes exactly ONE method,
     getPressedKeyCodes(). There are no key events to listen for. Anything built on
     `key`/`key_up` will work in CraftOS-PC and do nothing in game.

     Reminder for the pilot, not the code: a key must be bound to a frequency on the
     typewriter itself, or it reports nothing at all.

     Held keys RAMP their axis rather than slamming it, and release returns the axis to
     centre at its own rate -- a keyboard is a digital device driving an analogue control,
     and ramping is what makes that feel like flying instead of switching.
]]

local Util = require("lib.util")

local Typewriter = {}
Typewriter.__index = Typewriter

function Typewriter.new(bindings, cfg, log)
  local self = setmetatable({}, Typewriter)
  self.bindings = bindings
  self.cfg = cfg
  self.log = log
  self.down = {}          -- action -> true while held
  self.previous = {}      -- for edge detection
  self.axes = { pitch = 0, roll = 0, yaw = 0, climb = 0, accel = 0 }
  self.failures = 0
  return self
end

function Typewriter:reset()
  self.down, self.previous = {}, {}
  for k in pairs(self.axes) do self.axes[k] = 0 end
end

--- Poll the peripheral. Returns axes, held, edges -- or nil when unavailable.
function Typewriter:poll(dev, dt)
  if not dev then return nil end
  local fn = dev.getPressedKeyCodes
  if type(fn) ~= "function" then return nil end
  local ok, codes = pcall(fn)
  if not ok or type(codes) ~= "table" then
    self.failures = self.failures + 1
    if self.log then
      self.log:throttled("twfail", 2000, "warn",
        "typewriter poll failed (%d): %s", self.failures, tostring(codes))
    end
    return nil
  end
  self.failures = 0

  -- The RAW codes as well as the resolved actions. The nozzle-mapping screen needs a/d/s/w by
  -- key rather than by action -- they are being used to NAME a direction, not to fly.
  local raw = {}
  for _, code in ipairs(codes) do raw[code] = true end
  self.pressedCodes = raw

  local down = {}
  for _, code in ipairs(codes) do
    local action = self.bindings:actionForKey(code)
    if action then down[action] = true end
  end

  local tw = self.cfg.input.typewriter
  local rate, centreRate = tw.rate or 2.0, tw.centreRate or 3.0

  -- ramp the continuous axes toward what the keys ask for
  for axis, pair in pairs(self.bindings.AXES) do
    local positive, negative = pair[1], pair[2]
    local target = 0
    if down[positive] then target = target + 1 end
    if down[negative] then target = target - 1 end

    if axis == "accel" then
      -- The accel axis is not ramped: modes.lua integrates it into the throttle, so
      -- ramping here would be a second integrator in series with that one.
      self.axes[axis] = target
    else
      local current = self.axes[axis]
      local step = ((target == 0) and centreRate or rate) * dt
      if target > current then
        self.axes[axis] = math.min(target, current + step)
      elseif target < current then
        self.axes[axis] = math.max(target, current - step)
      end
      self.axes[axis] = Util.clamp(self.axes[axis], -1, 1)
    end
  end

  -- edges: fired once per press
  local edges = {}
  for _, action in ipairs(self.bindings.EDGES) do
    if down[action] and not self.previous[action] then edges[action] = true end
  end

  local held = {}
  for _, action in ipairs(self.bindings.HELD) do
    held[action] = down[action] and true or false
  end

  self.previous = down
  self.down = down
  return self.axes, held, edges
end

--- Which bound keys are currently reaching us? The UI shows this so a key that is not
--- bound to a frequency on the typewriter is immediately obvious.
function Typewriter:activeActions()
  local out = {}
  for action in pairs(self.down) do out[#out + 1] = action end
  table.sort(out)
  return out
end

return Typewriter
