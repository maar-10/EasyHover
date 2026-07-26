--[[ The brake law: tilt the lift thrusters into the direction of motion.

     Physics, and the sign convention that follows from it (same as a quadcopter):
       pitch DOWN  -> thrust vector tilts forward  -> accelerates FORWARD
       pitch UP    -> accelerates BACKWARD          <- this is also how REVERSE works
       roll RIGHT  -> accelerates RIGHT

     So to brake we tilt *against* the velocity vector: moving forward means pitching up,
     drifting right means rolling left.

     Every constraint from docs/MODES.md section 5 is enforced here:
       * proportional to speed, with a dead zone, so the slightest drift causes nothing;
       * hard tilt cap (envelope owns the number);
       * rate-limited tilt-in, so braking cannot step-excite the airframe;
       * and the result still passes through the envelope afterwards, like every demand.

     DEGRADED MODE: without a velocity vector we do not know which way we are moving
     (docs/MODES.md section 6). Braking then assumes forward motion and pitches up, which is
     right for the throttle-driven case (you were going forward) and merely ineffective, not
     dangerous, when drifting sideways. It annunciates either way.
]]

local Util = require("lib.util")
local Filter = require("lib.control.filter")

local Brake = {}
Brake.__index = Brake

function Brake.new(cfg, envelope, log)
  local self = setmetatable({}, Brake)
  self.cfg = cfg
  self.envelope = envelope
  self.log = log
  self.pitchRate = Filter.rateLimit(cfg.brake.tiltRateDps, 0)
  self.rollRate = Filter.rateLimit(cfg.brake.tiltRateDps, 0)
  return self
end

function Brake:reset()
  self.pitchRate:reset(0)
  self.rollRate:reset(0)
end

--[[ velocity: { x = right, z = forward, horizontal = magnitude } or nil
     capability: "vector" | "partial" | "scalar" | "none"
     scalarSpeed: fallback magnitude when there is no vector
     Returns { pitch, roll, active, degraded, speed }, in degrees.
]]
function Brake:demand(velocity, capability, scalarSpeed, dt)
  local b = self.cfg.brake
  local haveVector = capability == "vector" and velocity ~= nil
    and velocity.x ~= nil and velocity.z ~= nil

  local speed
  if haveVector then
    speed = velocity.horizontal or math.sqrt(velocity.x ^ 2 + velocity.z ^ 2)
  else
    speed = math.abs(scalarSpeed or 0)
  end

  local tilt = self.envelope:brakeTiltForSpeed(speed)
  if tilt <= 0 then
    -- below the dead zone: unwind smoothly rather than snapping to level
    return {
      pitch = self.pitchRate:update(0, dt),
      roll = self.rollRate:update(0, dt),
      active = false,
      degraded = not haveVector,
      speed = speed,
    }
  end

  local pitchTarget, rollTarget
  if haveVector and speed > 1e-6 then
    -- oppose the velocity vector: unit components scale the tilt between the two axes
    local ux, uz = velocity.x / speed, velocity.z / speed
    pitchTarget = tilt * uz      -- moving forward (+z) -> pitch up (+)
    rollTarget = -tilt * ux      -- drifting right (+x) -> roll left (-)
  else
    pitchTarget = tilt           -- assume forward motion
    rollTarget = 0
  end

  return {
    pitch = self.pitchRate:update(pitchTarget, dt),
    roll = self.rollRate:update(rollTarget, dt),
    active = true,
    degraded = not haveVector,
    speed = speed,
  }
end

--- Reverse is the same mechanism as braking, driven by negative throttle instead of speed:
--- pitch nose up so the lift thrusters push the craft backwards. The pitch angle -- and so
--- the acceleration -- scales with how far past zero the throttle has been pushed.
function Brake:reverseDemand(throttle, dt)
  local amount = Util.clamp(-(throttle or 0), 0, 1)
  local maxPitch = math.min(self.cfg.modes.reverse.maxPitchDeg, self.cfg.envelope.maxPitchDeg)
  local target = amount * maxPitch
  return {
    pitch = self.pitchRate:update(target, dt),
    roll = self.rollRate:update(0, dt),
    active = amount > 0,
    amount = amount,
  }
end

function Brake:applyGains(cfg)
  self.cfg = cfg
  self.pitchRate.max = math.abs(cfg.brake.tiltRateDps)
  self.rollRate.max = math.abs(cfg.brake.tiltRateDps)
end

return Brake
