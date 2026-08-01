--[[ Control feel, the signed throttle axis, and the flight-state machine.

     This module turns raw pilot axes into the demand the control loops consume. It is the
     executable form of docs/MODES.md, and the throttle semantics are the interesting part:

       throttle > 0   FLIGHT   main thrusters push forward
       throttle = 0   BRAKE    (when the assistant is engaged) brake and hold position
       throttle < 0   REVERSE  nose pitches UP so the lift thrusters push backwards,
                               angle proportional to how far past zero you are

     Decelerating from positive throttle lands on zero and DWELLS there for zeroDwellMs, so
     brake mode is passed through deliberately rather than blown past on the way to reverse.

     The brake key does two different things by design:
       TAP  (< brakeTapMs)  -> throttle to zero and brake mode NOW
       HOLD                 -> brake for as long as it is held

     Feel modes differ in how the axes behave on release -- and note the deliberate
     asymmetry: releasing the stick levels the craft, it does not stop it.
       cruise   angles return to neutral, throttle HOLDS its level
       rate     axes command rotation rates, attitude is held, throttle HOLDS
       stutter  angles return to neutral, throttle DECAYS to zero, and ramps up faster
]]

local Util = require("lib.util")

local Modes = {}
Modes.__index = Modes

local STATES = {
  BOOT = true, GROUND = true, HOVER = true, FLIGHT = true,
  BRAKE = true, REVERSE = true, DAMPED = true, FAILSAFE = true,
}

function Modes.new(cfg, log)
  local self = setmetatable({}, Modes)
  self.cfg = cfg
  self.log = log

  self.feel = cfg.modes.default or "cruise"
  self.lateral = cfg.modes.lateralDefault or "flight"
  self.assistEnabled = cfg.assist.enabled ~= false

  -- FLIGHT CONTROL ARM. A master switch, OFF at boot: the mixer (the PID) may run only when the
  -- pilot has deliberately ENGAGED flight control. Preflight -- SELF TEST, AXIS MAP,
  -- just standing on the pad with the engine warming -- happens with this OFF, so the controller
  -- provably never steers until you say so. Not persisted: a reboot comes up SAFE, on purpose.
  self.armed = false

  self.throttle = 0
  self.dwellUntil = nil        -- while set, the throttle is parked at zero
  self.state = "BOOT"

  self.brakeDown = false
  self.brakeSince = nil
  self.brakeHold = false       -- brake key held long enough to count as a hold
  self.brakeLatched = false    -- a tap latched brake mode on
  self.altitudeTarget = nil

  return self
end

-- ---------------------------------------------------------------- mode switching

function Modes:setFeel(mode)
  if mode ~= "cruise" and mode ~= "rate" and mode ~= "stutter" then return false end
  if mode == self.feel then return true end
  self.feel = mode
  self.log:info("feel mode -> %s", mode)
  return true
end

function Modes:cycleFeel()
  local order = { "cruise", "rate", "stutter" }
  for i, name in ipairs(order) do
    if name == self.feel then
      return self:setFeel(order[i % #order + 1])
    end
  end
  return self:setFeel("cruise")
end

function Modes:setLateral(mode)
  if mode ~= "flight" and mode ~= "precision" then return false end
  if mode ~= self.lateral then
    self.lateral = mode
    self.log:info("lateral mode -> %s", mode)
  end
  return true
end

function Modes:toggleLateral()
  return self:setLateral(self.lateral == "flight" and "precision" or "flight")
end

function Modes:setAssist(on)
  self.assistEnabled = on and true or false
  self.log:info("flight assistant -> %s", self.assistEnabled and "ON" or "OFF")
end

function Modes:toggleAssist()
  self:setAssist(not self.assistEnabled)
end

--- Engage or disengage flight control. Engaging does NOT take off -- it only permits the mixer to
--- run once the craft is actually flying (airborne, or a climb input). Disengaging is a hard cut:
--- the mixer will not run whatever the sensors or the stick say.
function Modes:setArmed(on)
  self.armed = on and true or false
  self.log:info("flight control -> %s", self.armed and "ENGAGED" or "SAFE")
end

function Modes:toggleArmed()
  self:setArmed(not self.armed)
end

function Modes:isArmed()
  return self.armed
end

--- Rate mode force-disables the assistant: holding an attitude is the point of it.
function Modes:assistActive()
  if self.feel == "rate" and self.cfg.modes.rate.forceAssistOff then return false end
  return self.assistEnabled
end

function Modes:attitudeMode()
  return (self.feel == "rate") and "rate" or "angle"
end

-- ---------------------------------------------------------------- throttle

function Modes:feelParams()
  return self.cfg.modes[self.feel] or self.cfg.modes.cruise
end

--- Integrate the accel axis into the signed throttle.
-- accel: -1..1 (positive = accelerate, negative = decelerate)
function Modes:updateThrottle(accel, dt, now)
  local p = self:feelParams()
  accel = Util.clamp(accel or 0, -1, 1)
  local before = self.throttle

  if accel > 0 then
    -- accelerating always clears a dwell and a latched brake
    self.dwellUntil = nil
    self.brakeLatched = false
    self.throttle = self.throttle + accel * (p.thrustAccelRate or 0.25) * dt
  elseif accel < 0 then
    local rate = p.thrustDecelRate or p.thrustDecayRate or 0.35
    self.throttle = self.throttle + accel * rate * dt
    -- crossing zero downwards: park at zero for the dwell, so brake mode gets its moment
    if before > 0 and self.throttle <= 0 then
      self.throttle = 0
      self.dwellUntil = now + (self.cfg.modes.zeroDwellMs or 0)
    elseif self.dwellUntil and now < self.dwellUntil then
      self.throttle = 0
    elseif self.dwellUntil and now >= self.dwellUntil then
      self.dwellUntil = nil
    end
  else
    -- released
    if not p.thrustHold then
      -- stutter: decay toward zero, but never through it into reverse
      local decay = (p.thrustDecayRate or 1.0) * dt
      if self.throttle > 0 then
        self.throttle = math.max(0, self.throttle - decay)
      elseif self.throttle < 0 then
        self.throttle = math.min(0, self.throttle + decay)
      end
    end
    if self.dwellUntil and now >= self.dwellUntil then self.dwellUntil = nil end
  end

  self.throttle = Util.clamp(self.throttle, -1, 1)
  return self.throttle
end

--- Feed the brake key state. Returns true on a TAP (press shorter than brakeTapMs).
function Modes:updateBrakeKey(down, now)
  local tapped = false
  if down and not self.brakeDown then
    self.brakeDown = true
    self.brakeSince = now
    self.brakeHold = false
  elseif down and self.brakeDown then
    if (now - (self.brakeSince or now)) >= (self.cfg.modes.brakeTapMs or 250) then
      self.brakeHold = true
    end
  elseif (not down) and self.brakeDown then
    local heldFor = now - (self.brakeSince or now)
    self.brakeDown = false
    if heldFor < (self.cfg.modes.brakeTapMs or 250) then
      tapped = true
      -- a tap means: stop asking for speed, and brake, right now
      self.throttle = 0
      self.dwellUntil = nil
      self.brakeLatched = true
      self.log:info("brake tap: throttle zeroed, brake mode latched")
    end
    self.brakeHold = false
  end
  return tapped
end

--- Is the brake being commanded, by key hold or by a latched tap?
function Modes:brakeCommanded()
  return self.brakeHold or self.brakeLatched
end

--- Any deliberate movement input clears a latched brake.
function Modes:clearBrakeLatch()
  if self.brakeLatched then
    self.brakeLatched = false
    return true
  end
  return false
end

-- ---------------------------------------------------------------- state machine

--[[ facts = {
       groundContact, airborne, healthy, shouldDamp, climbInput, hardwareOk
     }
]]
function Modes:updateState(facts)
  local previous = self.state
  local next

  if not facts.healthy or facts.hardwareOk == false then
    next = "FAILSAFE"
  elseif facts.shouldDamp then
    next = "DAMPED"
  elseif facts.groundContact and math.abs(self.throttle) < 1e-6 and not facts.climbInput then
    next = "GROUND"
  elseif self.throttle < 0 then
    next = "REVERSE"
  elseif self:brakeCommanded() then
    next = "BRAKE"
  elseif math.abs(self.throttle) < 1e-6 then
    -- the internal brake mode from docs/MODES.md: assistant engaged AND no forward thrust
    next = self:assistActive() and "BRAKE" or "HOVER"
  else
    next = "FLIGHT"
  end

  if not STATES[next] then next = "HOVER" end
  if next ~= previous then
    self.state = next
    self.log:info("state %s -> %s", previous, next)
  end
  return self.state, next ~= previous
end

function Modes:isBraking()
  return self.state == "BRAKE"
end

function Modes:isReverse()
  return self.state == "REVERSE"
end

-- ---------------------------------------------------------------- demand shaping

--[[ Shape raw pilot axes into a control demand.

     axes = { pitch, roll, yaw, climb, accel }  each -1..1
     measured = { altitude }
     Returns a demand table for the loops.
]]
function Modes:shape(axes, measured, dt, now)
  local e = self.cfg.envelope
  local m = self.cfg.modes
  local demand = {}

  -- altitude: the climb axis commands a vertical SPEED while held; on release the current
  -- altitude becomes the hold target. That is what "set altitude" means in practice.
  local climb = Util.clamp(axes.climb or 0, -1, 1)
  if math.abs(climb) > 0.02 then
    demand.verticalSpeed = climb * (climb > 0 and math.min(m.climbRate, e.maxClimbRate)
      or math.min(m.climbRate, e.maxSinkRate))
    self.altitudeTarget = measured.altitude
  else
    self.altitudeTarget = self.altitudeTarget or measured.altitude
    demand.altitudeTarget = self.altitudeTarget
  end

  local pitchAxis = Util.clamp(axes.pitch or 0, -1, 1)
  local rollAxis = Util.clamp(axes.roll or 0, -1, 1)
  local yawAxis = Util.clamp(axes.yaw or 0, -1, 1)

  if self.lateral == "precision" then
    -- Precision: the stick TRANSLATES and the craft stays level. All four lateral
    -- thrusters are available, including the rear pair.
    demand.translateX = rollAxis * m.precision.maxTranslate
    demand.translateZ = pitchAxis * m.precision.maxTranslate
    demand.allowPrecision = true
    demand.pitch, demand.roll = 0, 0
    demand.yawRate = yawAxis * e.maxYawRateDps
  elseif self.feel == "rate" then
    demand.pitchRate = pitchAxis * m.rate.maxRateDps
    demand.rollRate = rollAxis * m.rate.maxRateDps
    demand.yawRate = yawAxis * e.maxYawRateDps
  else
    -- Flight mode, angle feel: bank to turn, with coordination so the craft turns into the
    -- roll like an aircraft instead of sliding sideways. Rudder adds on top.
    demand.pitch = pitchAxis * e.maxPitchDeg
    demand.roll = rollAxis * e.maxBankDeg
    local coordinated = rollAxis * (m.flight.turnCoordination or 0) * e.maxYawRateDps
    demand.yawRate = Util.clamp(coordinated + yawAxis * e.maxYawRateDps,
      -e.maxYawRateDps, e.maxYawRateDps)
  end

  -- forward propulsion: positive throttle drives the main thrusters
  demand.mainThrust = math.max(0, self.throttle)
  demand.throttle = self.throttle

  return demand
end

function Modes:applyConfig(cfg)
  self.cfg = cfg
end

function Modes:snapshot()
  return {
    feel = self.feel,
    lateral = self.lateral,
    armed = self.armed,
    assist = self.assistEnabled,
    assistActive = self:assistActive(),
    state = self.state,
    throttle = self.throttle,
    brakeHold = self.brakeHold,
    brakeLatched = self.brakeLatched,
    dwelling = self.dwellUntil ~= nil,
    altitudeTarget = self.altitudeTarget,
  }
end

return Modes
