--[[ The Flight Assistant: drift damping using ALL lateral thrusters.

     Spec in docs/MODES.md section 4. Default ON, switchable off, force-disabled in Rate mode
     because holding an attitude is the point of that mode.

     What it damps depends on what you are asking for:
       * throttle non-zero (you want to go somewhere) -> damp only LATERAL drift, so the
         craft settles onto flying straight ahead after a turn without fighting your speed;
       * throttle zero (brake / hover)                -> damp BOTH axes, i.e. hold position.

     Two hard rules:
       1. It never fights deliberate input. Any steering or thrust input suppresses it, plus
          a hold-off afterwards so it does not lurch the moment you let go.
       2. It needs a velocity VECTOR. With only an unsigned scalar there is no direction to
          push against, so it disables itself and says so rather than guessing
          (docs/MODES.md section 6).

     It engages the precisionOnly (rear) thrusters, which is the whole reason they exist.
]]

local Util = require("lib.util")
local Filter = require("lib.control.filter")

local Assist = {}
Assist.__index = Assist

function Assist.new(cfg, log)
  local self = setmetatable({}, Assist)
  self.cfg = cfg
  self.log = log
  self.lastInputAt = 0
  self.xFilter = Filter.lpf(0.4, 0)
  self.zFilter = Filter.lpf(0.4, 0)
  self.reason = "idle"
  return self
end

function Assist:reset()
  self.xFilter:reset(0)
  self.zFilter:reset(0)
  self.lastInputAt = 0
end

--- Tell the assistant the pilot is doing something. Call whenever a steering or thrust axis
--- is away from centre.
function Assist:noteInput(now)
  self.lastInputAt = now or os.epoch("utc")
end

function Assist:suppressed(now)
  now = now or os.epoch("utc")
  return (now - self.lastInputAt) < (self.cfg.assist.inputSuppressMs or 0)
end

--[[ opts = {
       enabled     -- master switch (already accounting for Rate mode)
       velocity    -- { x, z, horizontal } in the craft frame, or nil
       capability  -- sensors:velocityCapability()
       throttle    -- signed -1..1; zero means "hold position"
       now         -- epoch ms
       dt
     }
     Returns { translateX, translateZ, active, reason, allowPrecision }.
]]
function Assist:demand(opts)
  local a = self.cfg.assist
  local out = { translateX = 0, translateZ = 0, active = false, allowPrecision = false }

  if not opts.enabled then
    self.reason = "off"
    out.reason = self.reason
    return out
  end

  if a.requireVelocityVector and opts.capability ~= "vector" then
    self.reason = "no velocity vector"
    out.reason = self.reason
    return out
  end

  local v = opts.velocity
  if not v or v.x == nil then
    self.reason = "no velocity data"
    out.reason = self.reason
    return out
  end

  if self:suppressed(opts.now) then
    -- unwind rather than snapping off, so releasing the stick is smooth
    self.xFilter:update(0)
    self.zFilter:update(0)
    self.reason = "pilot input"
    out.reason = self.reason
    return out
  end

  local holdPosition = math.abs(opts.throttle or 0) < 1e-6

  local function damp(value, filter)
    local drift = Filter.deadband(value, a.driftDeadband)
    if drift == 0 then
      filter:update(0)
      return 0
    end
    -- push against the drift, capped
    local command = Util.clamp(-drift * a.gain, -a.maxAuthority, a.maxAuthority)
    return filter:update(command)
  end

  out.translateX = damp(v.x, self.xFilter)
  out.translateZ = holdPosition and damp(v.z or 0, self.zFilter) or self.zFilter:update(0)

  out.active = math.abs(out.translateX) > 1e-4 or math.abs(out.translateZ) > 1e-4
  -- the rear pair exists for exactly this
  out.allowPrecision = out.active
  self.reason = holdPosition and "holding position" or "damping lateral drift"
  out.reason = self.reason
  return out
end

--- Is the assistant available at all right now? For the UI and the annunciator.
function Assist:status(capability, enabled)
  if not enabled then return "OFF", "switched off" end
  if self.cfg.assist.requireVelocityVector and capability ~= "vector" then
    return "UNAVAIL", "needs a velocity vector (see docs/MODES.md)"
  end
  return "ON", self.reason
end

function Assist:applyGains(cfg)
  self.cfg = cfg
end

return Assist
