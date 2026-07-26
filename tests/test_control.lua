--[[ Phase 3a: PID discipline, envelope, oscillation detector, velocity vector ]]

local T = require("tests.util")
local Config = require("lib.config")
local State = require("lib.state")
local Log = require("lib.log")
local Peripherals = require("lib.peripherals")
local Sensors = require("lib.io.sensors")
local PID = require("lib.control.pid")
local Envelope = require("lib.control.envelope")
local Oscillation = require("lib.control.oscillation")

local mock = dofile("/tests/mocks/peripherals.lua")

local function quietLog()
  return Log.new({ level = "error", capacity = 50 })
end

-- ------------------------------------------------------------------ pid

T.suite("pid")

T.it("proportional term is straightforward", function()
  local pid = PID.new({ p = 2 })
  local out = pid:update(1, 0, 0.1)
  T.near(out, 2, 1e-9, "p * error")
end)

T.it("integral accumulates over time", function()
  local pid = PID.new({ p = 0, i = 1, iClamp = 10 })
  T.near(pid:update(1, 0, 0.1), 0.1, 1e-9, "after one cycle")
  T.near(pid:update(1, 0, 0.1), 0.2, 1e-9, "after two")
end)

T.it("integral is clamped", function()
  local pid = PID.new({ p = 0, i = 1, iClamp = 0.15 })
  pid:update(1, 0, 0.1)
  pid:update(1, 0, 0.1)
  pid:update(1, 0, 0.1)
  T.near(pid:update(1, 0, 0.1), 0.15, 1e-9, "clamped")
end)

T.it("saturation freezes the integral but still lets it unwind", function()
  local pid = PID.new({ p = 0, i = 1, iClamp = 10 })
  pid:update(1, 0, 0.1)                                   -- integral 0.1
  local out, dbg = pid:update(1, 0, 0.1, { saturated = true })
  T.near(out, 0.1, 1e-9, "did not grow into the stop")
  T.isTrue(dbg.integralFrozen, "reported as frozen")
  local out2 = pid:update(-1, 0, 0.1, { saturated = true })
  T.near(out2, 0, 1e-9, "unwinding toward zero is still allowed")
end)

T.it("a dt spike falls back to proportional only -- no kick", function()
  local pid = PID.new({ p = 1, i = 1, d = 1, iClamp = 10 }, { dtMaxMs = 250 })
  pid:update(1, 0, 0.1)
  local integralBefore = pid.integral
  local out, dbg = pid:update(1, 5, 2.0)                  -- 2 s: a stalled cycle
  T.isTrue(dbg.dtSkipped, "flagged as skipped")
  T.near(pid.integral, integralBefore, 1e-9, "integral untouched")
  T.near(dbg.d, 0, 1e-9, "no derivative from a stalled dt")
  T.near(out, 1 * (1 - 5) + integralBefore, 1e-9, "output is P + existing I only")
end)

T.it("derivative acts on the measurement, not the error", function()
  local pid = PID.new({ p = 0, d = 1, dAlpha = 1.0 })
  pid:update(0, 0, 0.1)                                   -- seed lastMeasurement
  local _, dbg = pid:update(0, 1, 0.1)                    -- measurement rose 1 in 0.1 s
  T.near(dbg.d, -10, 1e-6, "opposes the measurement's motion")
end)

T.it("a setpoint step produces NO derivative kick", function()
  local pid = PID.new({ p = 1, d = 1, dAlpha = 1.0 })
  pid:update(0, 0, 0.1)
  local _, dbg = pid:update(50, 0, 0.1)                   -- huge setpoint jump, still measurement
  T.near(dbg.d, 0, 1e-9, "derivative unmoved by the setpoint")
  T.near(dbg.p, 50, 1e-9, "only P responds")
end)

T.it("gain scaling scales the whole output", function()
  local pid = PID.new({ p = 2 })
  pid:setGainScale(0.5)
  T.near(pid:update(1, 0, 0.1), 1, 1e-9, "halved")
  pid:setGainScale(0)
  T.near(pid:update(1, 0, 0.1), 0, 1e-9, "authority removed")
end)

T.it("reset clears integrator, history and gain scale", function()
  local pid = PID.new({ p = 1, i = 1, iClamp = 10 })
  pid:update(1, 0, 0.1)
  pid:setGainScale(0.5)
  pid:reset()
  T.near(pid.integral, 0, 1e-9, "integral")
  T.isNil(pid.lastMeasurement, "history")
  T.near(pid.gainScale, 1.0, 1e-9, "gain scale")
end)

T.it("live retuning clamps an already-large integral", function()
  local pid = PID.new({ p = 0, i = 1, iClamp = 10 })
  for _ = 1, 20 do pid:update(1, 0, 0.1) end
  T.isTrue(pid.integral > 1, "integral grew")
  pid:setGains({ iClamp = 0.5 })
  T.near(pid.integral, 0.5, 1e-9, "clamped down immediately")
end)

-- ------------------------------------------------------------------ envelope

T.suite("envelope")

local function envCfg()
  return Config.withDefaults({})
end

T.it("angles and yaw rate are clamped, and the clip is reported", function()
  local env = Envelope.new(envCfg())
  local out, clipped = env:apply({ pitch = 90, roll = -90, yawRate = 500 })
  T.near(out.pitch, 20, 1e-9, "pitch")
  T.near(out.roll, -20, 1e-9, "roll")
  T.near(out.yawRate, 45, 1e-9, "yaw rate")
  T.containsMatch(clipped, "pitch", "clip list")
  T.containsMatch(clipped, "roll", "clip list")
  T.containsMatch(clipped, "yawRate", "clip list")
end)

T.it("vertical speed limits are asymmetric", function()
  local env = Envelope.new(envCfg())
  local up = env:apply({ verticalSpeed = 50 })
  T.near(up.verticalSpeed, 6, 1e-9, "climb limit")
  local down = env:apply({ verticalSpeed = -50 })
  T.near(down.verticalSpeed, -4, 1e-9, "sink limit is tighter")
end)

T.it("altitude targets are held inside floor and ceiling", function()
  local env = Envelope.new(envCfg())
  local low, clippedLow = env:apply({ altitudeTarget = -100 })
  T.near(low.altitudeTarget, 0, 1e-9, "floor")
  T.containsMatch(clippedLow, "altitudeTarget", "reported")
  local high = env:apply({ altitudeTarget = 9999 })
  T.near(high.altitudeTarget, 300, 1e-9, "ceiling")
end)

T.it("brake tilt gets its own tighter cap", function()
  local env = Envelope.new(envCfg())
  local out, clipped = env:apply({ brakeTilt = 45 })
  T.near(out.brakeTilt, 12, 1e-9, "brake cap, not the 20 deg pitch cap")
  T.containsMatch(clipped, "brakeTilt", "reported")
end)

T.it("apply does not mutate the caller's demand", function()
  local env = Envelope.new(envCfg())
  local demand = { pitch = 90 }
  env:apply(demand)
  T.near(demand.pitch, 90, 1e-9, "input untouched")
end)

T.it("brake tilt is proportional to speed with a dead zone", function()
  local cfg = envCfg()
  local env = Envelope.new(cfg)
  T.near(env:brakeTiltForSpeed(0.1), 0, 1e-9, "below minSpeed: no braking at all")
  T.near(env:brakeTiltForSpeed(cfg.brake.speedForFullTilt), 12, 1e-9, "full tilt at full speed")
  local mid = env:brakeTiltForSpeed((cfg.brake.speedForFullTilt + cfg.brake.minSpeed) / 2)
  T.near(mid, 6, 0.01, "half speed, half tilt")
  T.near(env:brakeTiltForSpeed(999), 12, 1e-9, "never beyond the cap")
end)

T.it("violations distinguish caution from warning", function()
  local env = Envelope.new(envCfg())
  local none = env:violations({ pitch = 2, roll = 1 })
  T.eq(#none, 0, "level flight is fine")

  local caution = env:violations({ pitch = 18 })       -- 90% of 20
  T.eq(caution[1].level, "caution", "approaching the limit")

  local warning = env:violations({ pitch = 25 })
  T.eq(warning[1].level, "warning", "past the limit")

  local sink = env:violations({ verticalSpeed = -10 })
  T.eq(sink[1].key, "sinkRate", "sink rate flagged")
  T.eq(sink[1].level, "warning", "as a warning")
end)

-- ------------------------------------------------------------------ oscillation

T.suite("oscillation")

local function oscRig(overrides)
  local cfg = Config.withDefaults(overrides or {})
  return Oscillation.new(cfg, quietLog()), cfg
end

T.it("a steady error never trips the detector", function()
  local osc = oscRig()
  local now = 1000
  for _ = 1, 100 do
    now = now + 50
    T.isFalse(osc:update("pitch", 5.0, now), "no trip")
  end
  T.near(osc:gainScale("pitch"), 1.0, 1e-9, "full authority retained")
end)

T.it("sustained sign flipping trips and cuts the gain", function()
  local osc, cfg = oscRig()
  local now, tripped = 1000, false
  for i = 1, 40 do
    now = now + 50
    local err = (i % 2 == 0) and 5.0 or -5.0
    if osc:update("pitch", err, now) then tripped = true break end
  end
  T.isTrue(tripped, "detector fired")
  T.near(osc:gainScale("pitch"), cfg.control.oscillation.gainCutFactor, 1e-9, "gain cut")
  T.eq(osc:trips("pitch"), 1, "one trip")
end)

T.it("noise around the setpoint does NOT trip it", function()
  local osc = oscRig()          -- errorEpsilon defaults to 0.25
  local now = 1000
  for i = 1, 60 do
    now = now + 50
    local err = (i % 2 == 0) and 0.1 or -0.1
    T.isFalse(osc:update("roll", err, now), "sub-epsilon flip ignored")
  end
  T.near(osc:gainScale("roll"), 1.0, 1e-9, "healthy loop untouched")
end)

T.it("flips that age out of the window do not accumulate", function()
  local osc = oscRig()
  local now = 1000
  -- one flip every 1.5 s: never 8 within a 2 s window
  for i = 1, 20 do
    now = now + 1500
    local err = (i % 2 == 0) and 5.0 or -5.0
    T.isFalse(osc:update("pitch", err, now), "slow flipping is not oscillation")
  end
end)

T.it("repeated trips lead to DAMPED HOVER", function()
  local osc, cfg = oscRig()
  local now = 1000
  local trips = 0
  while trips < cfg.control.oscillation.tripsToDamped and now < 100000 do
    now = now + 50
    local err = (math.floor(now / 50) % 2 == 0) and 5.0 or -5.0
    if osc:update("pitch", err, now) then trips = trips + 1 end
  end
  T.eq(trips, cfg.control.oscillation.tripsToDamped, "reached the trip count")
  local damp, axis = osc:shouldDamp()
  T.isTrue(damp, "damping demanded")
  T.eq(axis, "pitch", "names the axis")
  osc:acknowledgeDamped()
  T.isFalse(osc:shouldDamp(), "acknowledging clears it")
end)

T.it("gain never falls below the floor", function()
  local osc, cfg = oscRig()
  local now = 1000
  for i = 1, 400 do
    now = now + 50
    osc:update("pitch", (i % 2 == 0) and 5.0 or -5.0, now)
  end
  T.isTrue(osc:gainScale("pitch") >= cfg.control.oscillation.minGainScale - 1e-9,
    "floor respected")
end)

T.it("gain is restored one step at a time after a quiet period", function()
  local osc, cfg = oscRig()
  local now = 1000
  for i = 1, 40 do
    now = now + 50
    if osc:update("pitch", (i % 2 == 0) and 5.0 or -5.0, now) then break end
  end
  T.near(osc:gainScale("pitch"), 0.5, 1e-9, "cut")
  now = now + cfg.control.oscillation.recoverMs + 100
  osc:update("pitch", 0.0, now)                 -- quiet: sub-epsilon, no flips
  T.near(osc:gainScale("pitch"), 1.0, 1e-9, "restored a step")
end)

T.it("axes are tracked independently", function()
  local osc = oscRig()
  local now = 1000
  for i = 1, 40 do
    now = now + 50
    if osc:update("pitch", (i % 2 == 0) and 5.0 or -5.0, now) then break end
  end
  T.isTrue(osc:gainScale("pitch") < 1.0, "pitch degraded")
  T.near(osc:gainScale("roll"), 1.0, 1e-9, "roll unaffected")
  local status = osc:status()
  T.isTrue(status.pitch.degraded, "status reports pitch degraded")
end)

-- ------------------------------------------------------- velocity vector

T.suite("velocity vector")

local function vectorRig(vectorSpec, sensorOverrides)
  mock.reset()
  _G.peripheral = mock.install()
  local cfg = Config.withDefaults({
    hardware = {
      thrusters = {
        { id = "lift_fl", peripheral = "vector_thruster_0", group = "lift" },
      },
      sensors = { velocityVector = vectorSpec or {} },
    },
    sensors = {
      gimbal = { filterAlpha = 1.0 },
      altitude = { filterAlpha = 1.0, vsFilterAlpha = 1.0 },
      velocity = sensorOverrides or { filterAlpha = 1.0 },
      optical = { filterAlpha = 1.0 },
    },
  })
  local log = quietLog()
  local state = State.new({ staleMs = cfg.sensors.staleMs })
  local per = Peripherals.new(cfg, log):scan()
  return Sensors.new(per, cfg, log, state), state, cfg
end

T.it("two axis-mapped sensors assemble into a vector", function()
  local sensors, state = vectorRig({
    { peripheral = "velocity_sensor_0", axis = "z" },
    { peripheral = "velocity_sensor_1", axis = "x" },
  }, { filterAlpha = 1.0 })
  mock.vehicle.speed = 5
  mock.vehicle.lateralSpeed = -2
  sensors:read(0.05)
  T.near(state:get("velocity.z"), 5, 1e-6, "forward axis")
  T.near(state:get("velocity.x"), -2, 1e-6, "right axis")
  T.near(state:get("velocity.horizontal"), math.sqrt(29), 1e-6, "magnitude")
  T.eq(state:get("velocity.capability"), "vector", "full capability")
end)

T.it("the invert flag flips an axis", function()
  local sensors, state = vectorRig({
    { peripheral = "velocity_sensor_0", axis = "z" },
    { peripheral = "velocity_sensor_1", axis = "x", invert = true },
  }, { filterAlpha = 1.0 })
  mock.vehicle.lateralSpeed = 3
  sensors:read(0.05)
  T.near(state:get("velocity.x"), -3, 1e-6, "inverted")
end)

T.it("course is only computed when the sensors are signed", function()
  local sensors, state = vectorRig({
    { peripheral = "velocity_sensor_0", axis = "z" },
    { peripheral = "velocity_sensor_1", axis = "x" },
  }, { filterAlpha = 1.0, signed = true })
  mock.vehicle.speed = 5
  mock.vehicle.lateralSpeed = 5
  sensors:read(0.05)
  T.near(state:get("velocity.course"), 45, 1e-3, "45 degrees right of the nose")

  local sensors2, state2 = vectorRig({
    { peripheral = "velocity_sensor_0", axis = "z" },
    { peripheral = "velocity_sensor_1", axis = "x" },
  }, { filterAlpha = 1.0, signed = false })
  sensors2:read(0.05)
  T.isNil(state2:get("velocity.course"), "no course from unsigned sensors")
  T.eq(state2:get("velocity.capability"), "partial", "degraded capability")
end)

T.it("a single axis is reported as partial, not as a vector", function()
  local sensors, state = vectorRig({
    { peripheral = "velocity_sensor_0", axis = "z" },
  }, { filterAlpha = 1.0 })
  sensors:read(0.05)
  T.eq(state:get("velocity.capability"), "partial", "one axis is not a vector")
end)

T.it("with no vector configured the capability is scalar", function()
  local sensors, state = vectorRig({}, { filterAlpha = 1.0 })
  sensors:read(0.05)
  T.eq(state:get("velocity.capability"), "scalar", "scalar only")
  T.isNil(state:get("velocity.x"), "no axis channels published")
end)

-- ------------------------------------------------- config: modes and layout

T.suite("config: modes, layout, brake")

T.it("the new thruster groups are accepted", function()
  local cfg = Config.withDefaults({
    hardware = { thrusters = {
      { id = "lift1", peripheral = "p1", group = "lift" },
      { id = "main1", peripheral = "p2", group = "main" },
      { id = "yaw_l", peripheral = "p3", group = "lateral", yawAuthority = true },
      { id = "rear_l", peripheral = "p4", group = "lateral", precisionOnly = true },
    } },
  })
  local ok, errors = Config.validate(cfg)
  T.isTrue(ok, "valid: " .. table.concat(errors, "; "))
end)

T.it("an unknown group is rejected", function()
  local cfg = Config.withDefaults({
    hardware = { thrusters = { { id = "x", peripheral = "p", group = "wing" } } },
  })
  local ok, errors = Config.validate(cfg)
  T.isFalse(ok, "rejected")
  T.containsMatch(errors, "lift|main|lateral", "group error")
end)

T.it("brake tilt may not exceed the pitch envelope", function()
  local cfg = Config.withDefaults({
    hardware = { thrusters = { { id = "l", peripheral = "p", group = "lift" } } },
  })
  cfg.brake.maxTiltDeg = 30      -- envelope.maxPitchDeg is 20
  local ok, errors = Config.validate(cfg)
  T.isFalse(ok, "rejected")
  T.containsMatch(errors, "envelope must always win", "brake vs envelope")
end)

T.it("an unknown feel mode is rejected", function()
  local cfg = Config.withDefaults({
    hardware = { thrusters = { { id = "l", peripheral = "p", group = "lift" } } },
  })
  cfg.modes.default = "sport"
  local ok, errors = Config.validate(cfg)
  T.isFalse(ok, "rejected")
  T.containsMatch(errors, "cruise|rate|stutter", "mode error")
end)

T.it("a duplicated or invalid velocity axis is rejected", function()
  local cfg = Config.withDefaults({
    hardware = {
      thrusters = { { id = "l", peripheral = "p", group = "lift" } },
      sensors = { velocityVector = {
        { peripheral = "a", axis = "z" },
        { peripheral = "b", axis = "z" },
      } },
    },
  })
  local ok, errors = Config.validate(cfg)
  T.isFalse(ok, "rejected")
  T.containsMatch(errors, "already mapped", "duplicate axis")

  local cfg2 = Config.withDefaults({
    hardware = {
      thrusters = { { id = "l", peripheral = "p", group = "lift" } },
      sensors = { velocityVector = { { peripheral = "a", axis = "q" } } },
    },
  })
  local ok2, errors2 = Config.validate(cfg2)
  T.isFalse(ok2, "rejected")
  T.containsMatch(errors2, "axis must be x|y|z", "bad axis")
end)

T.it("a missing horizontal velocity vector warns about degraded assist and braking", function()
  local cfg = Config.withDefaults({
    hardware = { thrusters = { { id = "l", peripheral = "p", group = "lift" } } },
  })
  local ok, _, warnings = Config.validate(cfg)
  T.isTrue(ok, "legal")
  T.containsMatch(warnings, "brake law will degrade", "warning present")
end)

T.it("a craft with no main thruster and no yaw authority warns", function()
  local cfg = Config.withDefaults({
    hardware = { thrusters = {
      { id = "l1", peripheral = "p1", group = "lift" },
      { id = "lat", peripheral = "p2", group = "lateral" },
    } },
  })
  local _, _, warnings = Config.validate(cfg)
  T.containsMatch(warnings, "high%-speed forward flight is unavailable", "no main")
  T.containsMatch(warnings, "yaw control will be unavailable", "no yaw authority")
end)

T.it("stutter mode is expected to ramp faster than cruise", function()
  local cfg = Config.withDefaults({
    hardware = { thrusters = { { id = "l", peripheral = "p", group = "lift" } } },
  })
  cfg.modes.stutter.thrustAccelRate = 0.1     -- slower than cruise's 0.25
  local _, _, warnings = Config.validate(cfg)
  T.containsMatch(warnings, "stutter is meant to ramp faster", "warning")
end)

return true
