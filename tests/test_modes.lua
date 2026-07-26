--[[ Phase 3c: feel modes, the signed throttle, the brake key, the state machine.

     These test the pilot's specification in docs/MODES.md literally.
]]

local T = require("tests.util")
local Config = require("lib.config")
local Log = require("lib.log")
local Modes = require("lib.modes")
local Envelope = require("lib.control.envelope")
local Brake = require("lib.control.brake")
local Assist = require("lib.control.assist")

local function quietLog() return Log.new({ level = "error", capacity = 50 }) end

local function cfgFor(overrides)
  local cfg = Config.withDefaults({
    hardware = { thrusters = { { id = "l", peripheral = "p", group = "lift" } } },
  })
  if overrides then cfg = require("lib.util").deepMerge(cfg, overrides) end
  return cfg
end

local function modesFor(overrides)
  local cfg = cfgFor(overrides)
  return Modes.new(cfg, quietLog()), cfg
end

-- ------------------------------------------------------------------ throttle

T.suite("throttle semantics")

T.it("cruise: accelerating ramps the throttle, releasing HOLDS it", function()
  local m, cfg = modesFor()
  local now = 1000
  for _ = 1, 10 do m:updateThrottle(1, 0.1, now) end
  local held = m.throttle
  T.isTrue(held > 0.2, ("throttle ramped up (got %.3f)"):format(held))
  for _ = 1, 20 do m:updateThrottle(0, 0.1, now) end
  T.near(m.throttle, held, 1e-9, "released throttle holds its level")
end)

T.it("stutter: releasing DECAYS the throttle to zero", function()
  local m = modesFor({ modes = { default = "stutter" } })
  m:setFeel("stutter")
  local now = 1000
  for _ = 1, 10 do m:updateThrottle(1, 0.1, now) end
  T.isTrue(m.throttle > 0.2, "ramped up")
  for _ = 1, 40 do m:updateThrottle(0, 0.1, now) end
  T.near(m.throttle, 0, 1e-9, "decayed to zero")
end)

T.it("stutter ramps up faster than cruise", function()
  local cruise = modesFor()
  local stutter = modesFor()
  stutter:setFeel("stutter")
  for _ = 1, 5 do
    cruise:updateThrottle(1, 0.1, 1000)
    stutter:updateThrottle(1, 0.1, 1000)
  end
  T.isTrue(stutter.throttle > cruise.throttle,
    ("stutter %.3f > cruise %.3f"):format(stutter.throttle, cruise.throttle))
end)

T.it("stutter decay never runs through zero into reverse", function()
  local m = modesFor()
  m:setFeel("stutter")
  for _ = 1, 5 do m:updateThrottle(1, 0.1, 1000) end
  for _ = 1, 100 do m:updateThrottle(0, 0.1, 1000) end
  T.near(m.throttle, 0, 1e-9, "stops at zero")
end)

T.it("decelerating to zero DWELLS there, so brake mode is not blown past", function()
  local m, cfg = modesFor()
  local now = 1000
  for _ = 1, 10 do m:updateThrottle(1, 0.1, now) end
  -- decelerate until it lands on zero
  local guard = 0
  while m.throttle > 0 and guard < 200 do
    m:updateThrottle(-1, 0.1, now)
    guard = guard + 1
  end
  T.near(m.throttle, 0, 1e-9, "parked at zero")
  T.isTrue(m.dwellUntil ~= nil, "dwell armed")
  -- more deceleration inside the dwell must NOT go negative
  for _ = 1, 3 do m:updateThrottle(-1, 0.05, now + 100) end
  T.near(m.throttle, 0, 1e-9, "still zero during the dwell")
end)

T.it("decelerating past the dwell enters reverse", function()
  local m, cfg = modesFor()
  local now = 1000
  for _ = 1, 10 do m:updateThrottle(1, 0.1, now) end
  local guard = 0
  while m.throttle > 0 and guard < 200 do
    m:updateThrottle(-1, 0.1, now)
    guard = guard + 1
  end
  -- past the dwell window
  now = now + cfg.modes.zeroDwellMs + 50
  for _ = 1, 5 do m:updateThrottle(-1, 0.1, now) end
  T.isTrue(m.throttle < 0, ("throttle went negative (got %.3f)"):format(m.throttle))
end)

T.it("accelerating out of reverse clears the dwell and the brake latch", function()
  local m = modesFor()
  m.throttle = -0.5
  m.brakeLatched = true
  m.dwellUntil = 99999
  m:updateThrottle(1, 0.1, 1000)
  T.isNil(m.dwellUntil, "dwell cleared")
  T.isFalse(m.brakeLatched, "latch cleared")
  T.isTrue(m.throttle > -0.5, "throttle rising")
end)

T.it("throttle stays inside -1..1", function()
  local m = modesFor()
  local now = 1000
  for _ = 1, 500 do
    now = now + 100
    m:updateThrottle(1, 0.1, now)
  end
  T.near(m.throttle, 1, 1e-9, "clamped high")
  -- the clock must advance, or the zero dwell legitimately parks us at 0 forever
  for _ = 1, 2000 do
    now = now + 100
    m:updateThrottle(-1, 0.1, now)
  end
  T.near(m.throttle, -1, 1e-9, "clamped low")
end)

-- ------------------------------------------------------------------ brake key

T.suite("brake key")

T.it("a TAP zeroes the throttle and latches brake mode", function()
  local m, cfg = modesFor()
  for _ = 1, 10 do m:updateThrottle(1, 0.1, 1000) end
  T.isTrue(m.throttle > 0, "moving")
  local now = 2000
  m:updateBrakeKey(true, now)
  local tapped = m:updateBrakeKey(false, now + 100)   -- released quickly
  T.isTrue(tapped, "recognised as a tap")
  T.near(m.throttle, 0, 1e-9, "throttle zeroed")
  T.isTrue(m:brakeCommanded(), "brake latched")
end)

T.it("a HOLD brakes only while held", function()
  local m, cfg = modesFor()
  local now = 2000
  m:updateBrakeKey(true, now)
  T.isFalse(m:brakeCommanded(), "not yet a hold")
  m:updateBrakeKey(true, now + cfg.modes.brakeTapMs + 10)
  T.isTrue(m:brakeCommanded(), "hold recognised")
  local tapped = m:updateBrakeKey(false, now + cfg.modes.brakeTapMs + 200)
  T.isFalse(tapped, "a hold is not a tap")
  T.isFalse(m:brakeCommanded(), "released")
end)

T.it("a hold does not zero the throttle", function()
  local m, cfg = modesFor()
  for _ = 1, 10 do m:updateThrottle(1, 0.1, 1000) end
  local before = m.throttle
  local now = 2000
  m:updateBrakeKey(true, now)
  m:updateBrakeKey(true, now + cfg.modes.brakeTapMs + 10)
  T.near(m.throttle, before, 1e-9, "throttle untouched by a hold")
end)

T.it("deliberate input releases a latched brake", function()
  local m = modesFor()
  m:updateBrakeKey(true, 1000)
  m:updateBrakeKey(false, 1050)
  T.isTrue(m:brakeCommanded(), "latched")
  T.isTrue(m:clearBrakeLatch(), "cleared")
  T.isFalse(m:brakeCommanded(), "no longer braking")
end)

-- ------------------------------------------------------------------ states

T.suite("flight state machine")

local function stateFor(m, facts)
  return m:updateState(facts or {
    healthy = true, hardwareOk = true, shouldDamp = false,
    groundContact = false, climbInput = false,
  })
end

T.it("GROUND when on the skids with no throttle and no climb demand", function()
  local m = modesFor()
  T.eq(stateFor(m, { healthy = true, hardwareOk = true, groundContact = true }), "GROUND")
end)

T.it("climb input on the ground leaves GROUND", function()
  local m = modesFor()
  local state = stateFor(m, { healthy = true, hardwareOk = true,
    groundContact = true, climbInput = true })
  T.isFalse(state == "GROUND", "not GROUND any more (got " .. state .. ")")
end)

T.it("throttle zero with the assistant ON is BRAKE, with it OFF is HOVER", function()
  local m = modesFor()
  m:setAssist(true)
  T.eq(stateFor(m), "BRAKE", "assistant engaged, no forward thrust")
  m:setAssist(false)
  T.eq(stateFor(m), "HOVER", "assistant off")
end)

T.it("positive throttle is FLIGHT, negative is REVERSE", function()
  local m = modesFor()
  m.throttle = 0.5
  T.eq(stateFor(m), "FLIGHT")
  m.throttle = -0.5
  T.eq(stateFor(m), "REVERSE")
end)

T.it("the brake key wins over FLIGHT", function()
  local m = modesFor()
  m.throttle = 0.5
  m.brakeLatched = true
  T.eq(stateFor(m), "BRAKE")
end)

T.it("oscillation forces DAMPED, unhealthy sensors force FAILSAFE", function()
  local m = modesFor()
  m.throttle = 0.5
  T.eq(stateFor(m, { healthy = true, hardwareOk = true, shouldDamp = true }), "DAMPED")
  T.eq(stateFor(m, { healthy = false, hardwareOk = true }), "FAILSAFE")
  T.eq(stateFor(m, { healthy = true, hardwareOk = false }), "FAILSAFE")
end)

T.it("rate mode force-disables the flight assistant", function()
  local m = modesFor()
  m:setAssist(true)
  T.isTrue(m:assistActive(), "on in cruise")
  m:setFeel("rate")
  T.isFalse(m:assistActive(), "off in rate mode")
  T.isTrue(m.assistEnabled, "but the switch itself is still on")
  m:setFeel("cruise")
  T.isTrue(m:assistActive(), "back on when leaving rate mode")
end)

T.it("cycling feel visits every mode", function()
  local m = modesFor()
  local seen = { [m.feel] = true }
  for _ = 1, 3 do
    m:cycleFeel()
    seen[m.feel] = true
  end
  T.isTrue(seen.cruise and seen.rate and seen.stutter, "all three modes reachable")
end)

-- ------------------------------------------------------------------ shaping

T.suite("demand shaping")

T.it("flight mode banks and coordinates the turn", function()
  local m, cfg = modesFor()
  local demand = m:shape({ roll = 1, pitch = 0, yaw = 0, climb = 0 }, { altitude = 80 }, 0.05, 1000)
  T.near(demand.roll, cfg.envelope.maxBankDeg, 1e-9, "full bank")
  T.isTrue(demand.yawRate > 0, "turn coordination yaws into the roll")
  T.near(demand.yawRate,
    cfg.modes.flight.turnCoordination * cfg.envelope.maxYawRateDps, 1e-9, "coordination amount")
end)

T.it("rudder adds on top of coordination", function()
  local m, cfg = modesFor()
  local coordinated = m:shape({ roll = 1, yaw = 0 }, { altitude = 80 }, 0.05, 1000).yawRate
  local withRudder = m:shape({ roll = 1, yaw = 1 }, { altitude = 80 }, 0.05, 1000).yawRate
  T.isTrue(withRudder > coordinated, "rudder adds")
  T.isTrue(withRudder <= cfg.envelope.maxYawRateDps + 1e-9, "still inside the envelope")
end)

T.it("precision mode translates and stays level", function()
  local m, cfg = modesFor()
  m:setLateral("precision")
  local demand = m:shape({ roll = 1, pitch = -1, yaw = 0 }, { altitude = 80 }, 0.05, 1000)
  T.near(demand.translateX, cfg.modes.precision.maxTranslate, 1e-9, "stick translates right")
  T.near(demand.translateZ, -cfg.modes.precision.maxTranslate, 1e-9, "and back")
  T.near(demand.pitch, 0, 1e-9, "attitude stays level")
  T.near(demand.roll, 0, 1e-9, "attitude stays level")
  T.isTrue(demand.allowPrecision, "rear thrusters released for use")
end)

T.it("rate mode commands rotation rates instead of angles", function()
  local m, cfg = modesFor()
  m:setFeel("rate")
  local demand = m:shape({ pitch = 1, roll = -1 }, { altitude = 80 }, 0.05, 1000)
  T.near(demand.pitchRate, cfg.modes.rate.maxRateDps, 1e-9, "pitch rate")
  T.near(demand.rollRate, -cfg.modes.rate.maxRateDps, 1e-9, "roll rate")
  T.isNil(demand.pitch, "no angle demand")
end)

T.it("the climb axis commands vertical speed, and releasing it holds the altitude", function()
  local m, cfg = modesFor()
  local climbing = m:shape({ climb = 1 }, { altitude = 80 }, 0.05, 1000)
  T.isTrue(climbing.verticalSpeed > 0, "climb commanded")
  T.isNil(climbing.altitudeTarget, "no hold target while climbing")
  local held = m:shape({ climb = 0 }, { altitude = 92 }, 0.05, 1000)
  T.near(held.altitudeTarget, 80, 1e-9,
    "holds the altitude captured when the axis was last active")
  T.isNil(held.verticalSpeed, "no rate demand when holding")
end)

T.it("positive throttle drives the main thrusters, negative does not", function()
  local m = modesFor()
  m.throttle = 0.7
  T.near(m:shape({}, { altitude = 80 }, 0.05, 1000).mainThrust, 0.7, 1e-9, "forward")
  m.throttle = -0.7
  T.near(m:shape({}, { altitude = 80 }, 0.05, 1000).mainThrust, 0, 1e-9,
    "reverse uses pitch, not the main thrusters")
end)

-- ------------------------------------------------------- reverse + brake law

T.suite("reverse and brake law")

T.it("reverse pitches the nose UP, proportional to how far past zero", function()
  local cfg = cfgFor()
  local brake = Brake.new(cfg, Envelope.new(cfg), quietLog())
  local half = brake:reverseDemand(-0.5, 10)     -- long dt so the rate limiter is not the cap
  local full = brake:reverseDemand(-1.0, 10)
  T.isTrue(half.pitch > 0, "nose up")
  T.isTrue(full.pitch > half.pitch, "more reverse, more pitch")
  T.near(full.pitch, math.min(cfg.modes.reverse.maxPitchDeg, cfg.envelope.maxPitchDeg), 1e-6,
    "full reverse reaches the configured angle")
end)

T.it("the brake tilts against the direction of motion", function()
  local cfg = cfgFor()
  local brake = Brake.new(cfg, Envelope.new(cfg), quietLog())
  -- moving forward and to the right
  local out = brake:demand({ x = 4, z = 4, horizontal = math.sqrt(32) }, "vector", nil, 10)
  T.isTrue(out.active, "braking")
  T.isTrue(out.pitch > 0, "pitches UP against forward motion")
  T.isTrue(out.roll < 0, "rolls LEFT against rightward drift")
  T.isFalse(out.degraded, "full capability")
end)

T.it("the brake does nothing below the dead zone", function()
  local cfg = cfgFor()
  local brake = Brake.new(cfg, Envelope.new(cfg), quietLog())
  local out = brake:demand({ x = 0, z = 0.1, horizontal = 0.1 }, "vector", nil, 10)
  T.isFalse(out.active, "no braking for a crawl")
  T.near(out.pitch, 0, 1e-9, "level")
end)

T.it("the brake respects the tilt cap", function()
  local cfg = cfgFor()
  local brake = Brake.new(cfg, Envelope.new(cfg), quietLog())
  local out = brake:demand({ x = 0, z = 999, horizontal = 999 }, "vector", nil, 10)
  T.near(out.pitch, cfg.brake.maxTiltDeg, 1e-6, "capped")
end)

T.it("the brake tilt is rate-limited, not stepped in", function()
  local cfg = cfgFor()
  local brake = Brake.new(cfg, Envelope.new(cfg), quietLog())
  local out = brake:demand({ x = 0, z = 999, horizontal = 999 }, "vector", nil, 0.05)
  T.isTrue(out.pitch < cfg.brake.maxTiltDeg,
    ("first cycle only reached %.2f deg"):format(out.pitch))
  T.near(out.pitch, cfg.brake.tiltRateDps * 0.05, 1e-6, "exactly the rate limit")
end)

T.it("without a velocity vector the brake degrades and says so", function()
  local cfg = cfgFor()
  local brake = Brake.new(cfg, Envelope.new(cfg), quietLog())
  local out = brake:demand(nil, "scalar", 6.0, 10)
  T.isTrue(out.active, "still brakes")
  T.isTrue(out.degraded, "flagged as degraded")
  T.isTrue(out.pitch > 0, "assumes forward motion")
  T.near(out.roll, 0, 1e-9, "no lateral guess")
end)

-- ------------------------------------------------------------------ assistant

T.suite("flight assistant")

T.it("damps lateral drift and uses the rear thrusters", function()
  local cfg = cfgFor()
  local assist = Assist.new(cfg, quietLog())
  local out = assist:demand({
    enabled = true, capability = "vector",
    velocity = { x = 3, z = 5, horizontal = 5.8 }, throttle = 0.5, now = 100000, dt = 0.05,
  })
  T.isTrue(out.active, "active")
  T.isTrue(out.translateX < 0, "pushes back against rightward drift")
  T.isTrue(out.allowPrecision, "engages the precision-only rear pair")
end)

T.it("does not fight forward motion while the throttle is open", function()
  local cfg = cfgFor()
  local assist = Assist.new(cfg, quietLog())
  local out = assist:demand({
    enabled = true, capability = "vector",
    velocity = { x = 0, z = 8, horizontal = 8 }, throttle = 0.5, now = 100000, dt = 0.05,
  })
  T.near(out.translateZ, 0, 1e-9, "forward velocity left alone")
end)

T.it("holds position when the throttle is closed", function()
  local cfg = cfgFor()
  local assist = Assist.new(cfg, quietLog())
  local out = assist:demand({
    enabled = true, capability = "vector",
    velocity = { x = 0, z = 4, horizontal = 4 }, throttle = 0, now = 100000, dt = 0.05,
  })
  T.isTrue(out.translateZ < 0, "now it damps forward drift too")
end)

T.it("stays out of the way while the pilot is commanding", function()
  local cfg = cfgFor()
  local assist = Assist.new(cfg, quietLog())
  local now = 100000
  assist:noteInput(now)
  local out = assist:demand({
    enabled = true, capability = "vector",
    velocity = { x = 5, z = 0, horizontal = 5 }, throttle = 0.5, now = now + 10, dt = 0.05,
  })
  T.isFalse(out.active, "suppressed")
  T.eq(out.reason, "pilot input", "and says why")
end)

T.it("disables itself without a velocity vector rather than guessing", function()
  local cfg = cfgFor()
  local assist = Assist.new(cfg, quietLog())
  local out = assist:demand({
    enabled = true, capability = "scalar",
    velocity = { x = 5 }, throttle = 0, now = 100000, dt = 0.05,
  })
  T.isFalse(out.active, "inactive")
  T.eq(out.reason, "no velocity vector", "honest about why")
  local status, why = assist:status("scalar", true)
  T.eq(status, "UNAVAIL", "status reflects it")
end)

T.it("ignores drift inside the dead zone", function()
  local cfg = cfgFor()
  local assist = Assist.new(cfg, quietLog())
  local out = assist:demand({
    enabled = true, capability = "vector",
    velocity = { x = 0.05, z = 0, horizontal = 0.05 }, throttle = 0, now = 100000, dt = 0.05,
  })
  T.isFalse(out.active, "no twitching at a crawl")
end)

T.it("authority is capped", function()
  local cfg = cfgFor()
  local assist = Assist.new(cfg, quietLog())
  local out
  for _ = 1, 40 do
    out = assist:demand({
      enabled = true, capability = "vector",
      velocity = { x = 100, z = 0, horizontal = 100 }, throttle = 0, now = 100000, dt = 0.05,
    })
  end
  T.isTrue(math.abs(out.translateX) <= cfg.assist.maxAuthority + 1e-9, "capped")
end)

return true
