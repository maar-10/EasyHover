--[[ Outer loop: altitude and vertical speed. The slow one.

     This is where the 16-step thrust quantiser is confronted directly (docs/CONTROL_LAWS.md
     sections 1 and 1a):

       total demand  =  learned hover trim  +  rate-loop output
       committed step = hysteresis(demand * 15)          <- coarse, sticky, 16 levels
       verticalTrim   = (demand - step/15) / trimAuthority  <- continuous, via nozzle toe

     The residual after quantisation is at most one step (1/15 = 6.7%), and the toe trim
     authority is configured larger than that, so the continuous axis can ALWAYS cover the
     quantisation gap. That property is what removes the limit cycle, and there is a test
     asserting it rather than a comment hoping for it.

     Ground handling matters as much as the maths: while on the ground the integrators are
     held at zero. A wound-up integrator on a craft sitting on its skids is the classic
     "vehicle leaps into the air on takeoff" bug.
]]

local Util = require("lib.util")
local Filter = require("lib.control.filter")
local PID = require("lib.control.pid")
local Config = require("lib.config")

local Altitude = {}
Altitude.__index = Altitude

function Altitude.new(cfg, log, oscillation, opts)
  opts = opts or {}
  local self = setmetatable({}, Altitude)
  self.cfg = cfg
  self.log = log
  self.osc = oscillation
  self.steps = opts.steps or 15          -- thrust resolution of the hardware
  self.stepSize = 1 / self.steps

  local pidOpts = { dtMaxMs = cfg.tuning.dtMaxMs }
  self.posPid = PID.new(cfg.control.altitude.pos, pidOpts)
  self.ratePid = PID.new(cfg.control.altitude.rate, pidOpts)

  self.hysteresis = Filter.hysteresis(
    cfg.tuning.thrustHysteresisSteps,
    cfg.tuning.thrustHoldSamples,
    0)

  self.hoverTrim = cfg.control.altitude.hoverTrim or 0
  self.trimLearned = self.hoverTrim > 0
  self.saturated = false
  self:refreshTrimAuthority()
  return self
end

--- How much lift the toe trim can actually deliver. Derived from the geometry rather than
--- assumed, and optionally capped by config. Warns once if it cannot cover the quantiser's
--- residual, because then altitude carries a small ripple by physics, not by bug.
function Altitude:refreshTrimAuthority()
  local derived = Config.derivedTrimAuthority(self.cfg)
  local configured = self.cfg.control.altitude.vectorTrimAuthority or 0
  self.trimAuthority = (configured > 0) and math.min(configured, derived) or derived
  self.residualBound = Config.residualBound(self.cfg)
  if self.trimAuthority < self.residualBound and not self._warnedAuthority then
    self._warnedAuthority = true
    self.log:warn("toe trim authority %.3f < quantiser residual %.3f: expect a small "
      .. "altitude ripple until mixer.toeBase / maxNozzleDeg are calibrated",
      self.trimAuthority, self.residualBound)
  end
end

function Altitude:reset(keepTrim)
  self.posPid:reset()
  self.ratePid:reset()
  self.hysteresis:reset(0)
  self.saturated = false
  if not keepTrim then
    self.hoverTrim = self.cfg.control.altitude.hoverTrim or 0
  end
end

--- On the ground: everything to zero and held there, so nothing can wind up.
function Altitude:groundHold()
  self.posPid:reset(true)
  self.ratePid:reset(true)
  self.hysteresis:reset(0)
  return { collective = 0, verticalTrim = 0 }, { grounded = true }
end

--[[ target:   { altitude = y } or { verticalSpeed = v } (verticalSpeed wins if present)
     measured: { altitude = y, verticalSpeed = v, groundContact = bool }
     Returns { collective = 0..1, verticalTrim = -1..1 }, debug.
]]
function Altitude:update(target, measured, dt)
  local ac = self.cfg.control.altitude

  if measured.groundContact then
    if target.ignoreGround then
      -- TAKEOFF RAMP. A craft that has never hovered has hoverTrim 0, and the rate loop's authority
      -- (p*err + iClamp ~= 0.5) tops out below the thrust a heavy craft needs to leave the ground --
      -- so a climb command sat at partial thrust forever (the reported bug). While grounded and
      -- commanded UP, ramp the collective open-loop toward full, exactly as SELF CONFIG's float does
      -- (which is why SELF CONFIG lifts the craft when normal flight could not).
      --
      -- ...but FREEZE the ramp the instant the craft actually breaks free of the skids. The thrust
      -- that just started it rising is ~hover, and that is what seeds the feedforward at the handoff
      -- below. Left ramping to full past liftoff it seeded an inflated hover trim, and the craft
      -- launched at the ceiling and hung there (reported: "hold the throttle a little too long and it
      -- lifts me into the ropes"). Once rising, the pilot's vertical-authority feedforward gives the
      -- climb its punch; the ramp's only job was to get the wheels off the ground.
      local floor = ac.minAirborneCollective or 0.20
      local rising = (measured.verticalSpeed or 0) > (ac.takeoffLiftoffVs or 0.10)
      if rising then
        self.takeoffCollective = self.takeoffCollective or floor
      else
        local ramp = (ac.takeoffRamp or 0.5) * math.max(dt or 0, 0)
        self.takeoffCollective = Util.clamp((self.takeoffCollective or floor) + ramp, floor, 1)
      end
      -- Hold integrators at zero: the ramp is the command, not the PID, so nothing may wind up.
      -- hoverTrim is NOT touched here -- a ramp that never lifts (an underpowered craft held at
      -- full) must not persist a runaway hover estimate. It is seeded at the liftoff moment below.
      self.posPid:reset(true)
      self.ratePid:reset(true)
      return { collective = self.takeoffCollective, verticalTrim = 0 },
        { takeoff = true, collective = self.takeoffCollective }
    end
    self.takeoffCollective = nil
    return self:groundHold()
  end

  local e = self.cfg.envelope
  local dbg = {}

  -- LIFTOFF HANDOFF. We were ramping open-loop and the craft has just left the ground. Seed the
  -- hover feedforward with the thrust that actually lifted it, so the rate loop takes over from a
  -- real operating point instead of snapping back to a zero-trim PID (which would drop the craft).
  if self.takeoffCollective ~= nil then
    self.hoverTrim = self.takeoffCollective
    self.trimLearned = true
    self.takeoffCollective = nil
  end

  -- ---- outer: altitude -> vertical-speed demand
  -- A direct command is the pilot actively asking for a climb/sink RATE (vs. holding an altitude);
  -- it is what earns the vertical-authority feedforward below.
  local directCommand = type(target.verticalSpeed) == "number"
  local vsDemand
  if directCommand then
    vsDemand = target.verticalSpeed
    dbg.direct = true
  else
    if self.osc then self.posPid:setGainScale(self.osc:gainScale("altitude")) end
    local raw, info = self.posPid:update(target.altitude or measured.altitude,
      measured.altitude, dt, { saturated = self.saturated })
    vsDemand = raw
    dbg.pos = info
    if self.osc then self.osc:update("altitude", info.error, nil) end
  end
  -- the envelope owns the vertical-speed limits, asymmetrically
  vsDemand = Util.clamp(vsDemand, -e.maxSinkRate, e.maxClimbRate)
  dbg.vsDemand = vsDemand

  -- ---- inner: vertical speed -> thrust demand, biased by the learned hover trim
  local rawRate, rateInfo = self.ratePid:update(vsDemand, measured.verticalSpeed or 0, dt,
    { saturated = self.saturated })
  dbg.rate = rateInfo

  -- ---- pilot vertical AUTHORITY (feedforward)
  -- The rate loop's gains are tiny (tuned for gentle altitude HOLD, +/-0.1 blocks), so its output
  -- can only nudge thrust ~0.4 from the hover trim. On a craft whose hover sits high, a descend
  -- command then barely sinks it and a climb command barely lifts it -- the reported "it won't come
  -- down". So when the pilot is ACTIVELY commanding a vertical speed, add a direct feedforward
  -- proportional to how hard they are asking: full command moves the collective by verticalAuthority
  -- immediately, and the rate PID trims around it. Released (altitude hold), directCommand is false,
  -- the feedforward is zero, and the gentle hold behaviour is exactly as before.
  local ff = 0
  if directCommand then
    local refRate = (vsDemand >= 0) and (e.maxClimbRate or 6) or (e.maxSinkRate or 4)
    ff = (ac.verticalAuthority or 0.6) * Util.clamp(vsDemand / math.max(refRate, 1e-6), -1, 1)
  end
  dbg.ff = ff

  -- Floor the collective while airborne: a saturating rate loop commanding zero thrust is
  -- not a descent, it is free fall. Found by tests/sim.lua, not by inspection.
  local floor = ac.minAirborneCollective or 0
  local demand = self.hoverTrim + rawRate + ff
  self.saturated = demand <= floor or demand >= 1
  demand = Util.clamp(demand, floor, 1)
  dbg.demand = demand
  dbg.floored = demand <= floor

  -- ---- coarse: sticky quantised step
  local idealStep = demand * self.steps
  local step = self.hysteresis:update(idealStep)
  step = Util.clamp(math.floor(step + 0.5), 0, self.steps)
  local collective = step * self.stepSize
  dbg.idealStep = idealStep
  dbg.step = step

  -- ---- fine: continuous toe trim covers whatever quantisation left behind
  local residual = demand - collective
  local authority = math.max(self.trimAuthority or 0, 1e-6)
  local verticalTrim = Util.clamp(residual / authority, -1, 1)
  dbg.residual = residual
  dbg.trimAuthority = authority
  dbg.trimSaturated = math.abs(residual) > authority

  -- ---- hover trim learning: track the operating point while genuinely settled
  -- Learn toward the thrust that is actually holding the craft, but only when it is nearly still AND
  -- barely demanding vertical speed. This is stable -- it low-passes the (already damped) demand, it
  -- adds no position integral -- which is why it does not limit-cycle in the hold.
  local settled = math.abs(vsDemand) < 0.25
    and math.abs((measured.verticalSpeed or 0)) < 0.25
    and not rateInfo.dtSkipped
  if settled then
    local rate = ac.trimLearnRate or 0
    self.hoverTrim = Util.clamp(self.hoverTrim + (demand - self.hoverTrim) * rate, 0, 1)
    self.trimLearned = true
  end

  -- ---- anti-pin: un-stick an inflated trim that the gentle hold cannot overcome
  -- The settled learner above is blind to one case: a craft pinned ABOVE its hold target by a
  -- mooring rope is dead still (settled) yet is holding NO altitude -- the rope is, at a thrust well
  -- over hover. A tap-down just sagged and sprang back to the ceiling (the reported bug), because the
  -- trim stayed inflated and the rate loop is far too gentle to fight it. So when we are HOLDING and
  -- sitting clearly above the target while not descending, bleed the trim DOWN until the craft can
  -- come down. One-directional (it never adds lift), gated on being still so it can never fight an
  -- in-progress descent into a limit cycle, and it stops the moment the craft is back within the band.
  -- The rate loop's integral is the honest tell. At a real pin the loop is asking for LESS thrust to
  -- descend and cannot (integral wound negative); a windup overshoot on the way to a hold has the
  -- integral still POSITIVE (unwinding from the earlier undershoot), and bleeding there would fight
  -- the settled learner's convergence. So only bleed when the loop itself wants down.
  local pinnedNow = (not directCommand) and type(target.altitude) == "number"
    and type(measured.altitude) == "number" and not rateInfo.dtSkipped
    and (measured.altitude - target.altitude) > (ac.trimUnstickBand or 0.5)
    and math.abs(measured.verticalSpeed or 0) < (ac.trimUnstickStill or 0.20)
    and (rateInfo.i or 0) <= 0
  if pinnedNow then
    -- Require the pin to PERSIST before bleeding, so a transient overshoot above the target on the
    -- way to a hold (which the settled learner is legitimately correcting) is not mistaken for a rope
    -- pin and fought. A real pin dwells; an overshoot passes through in well under a second.
    self.pinnedElapsed = (self.pinnedElapsed or 0) + math.max(dt or 0, 0)
    if self.pinnedElapsed > (ac.trimUnstickDwell or 1.0) then
      self.hoverTrim = Util.clamp(self.hoverTrim - (ac.trimUnstickRate or 0.05) * math.max(dt or 0, 0),
        0, 1)
      self.trimLearned = true
    end
  else
    self.pinnedElapsed = 0
  end
  dbg.hoverTrim = self.hoverTrim
  dbg.settled = settled

  return { collective = collective, verticalTrim = verticalTrim }, dbg
end

--- Persist-worthy learned value; the failsafe redstone level is derived from it.
function Altitude:learnedTrim()
  return self.hoverTrim, self.trimLearned
end

function Altitude:applyGains(cfg)
  self.cfg = cfg
  self.posPid:setGains(cfg.control.altitude.pos)
  self.ratePid:setGains(cfg.control.altitude.rate)
  self.hysteresis.threshold = cfg.tuning.thrustHysteresisSteps
  self.hysteresis.holdSamples = math.max(1, cfg.tuning.thrustHoldSamples)
  self._warnedAuthority = nil
  self:refreshTrimAuthority()
end

return Altitude
