--[[ Phase 3b: mixer, attitude loop, altitude loop -- verified against the plant model.

     These are the tests CONTROL_LAWS.md section 6 demands. Nothing flies until they pass.
]]

local T = require("tests.util")
local Config = require("lib.config")
local Log = require("lib.log")
local Mixer = require("lib.control.mixer")
local Attitude = require("lib.control.attitude")
local Altitude = require("lib.control.altitude")
local Oscillation = require("lib.control.oscillation")
local Sim = dofile("/tests/sim.lua")

local function quietLog()
  return Log.new({ level = "error", capacity = 50 })
end

--- Config with gains that work against the synthetic plant. Real gains come from in-game
--- tuning once the probe has measured the nozzle slew rate.
local function simConfig(overrides)
  local cfg = Config.withDefaults({
    hardware = { thrusters = Sim.defaultLayout() },
    tuning = { attitudeHz = 20, altitudeHz = 5 },
    control = {
      attitude = {
        pitch = { p = 0.055, i = 0.008, d = 0.020, iClamp = 0.1, dAlpha = 0.4 },
        roll  = { p = 0.055, i = 0.008, d = 0.020, iClamp = 0.1, dAlpha = 0.4 },
        yaw   = { p = 0.015, i = 0.003, d = 0.004, iClamp = 0.1, dAlpha = 0.3 },
      },
      attitudeRate = {
        pitch = { p = 0.060, i = 0.060, d = 0.004, iClamp = 0.3, dAlpha = 0.4 },
        roll  = { p = 0.060, i = 0.060, d = 0.004, iClamp = 0.3, dAlpha = 0.4 },
        yaw   = { p = 0.020, i = 0.020, d = 0.002, iClamp = 0.3, dAlpha = 0.4 },
      },
      -- Gains found by grid search against the plant (docs/CONTROL_LAWS.md section 4a).
      -- Note the scale of the rate loop: its output is a thrust FRACTION.
      altitude = {
        pos = { p = 0.40, i = 0.0, d = 0.0, iClamp = 0.5, dAlpha = 0.3 },
        rate = { p = 0.050, i = 0.008, d = 0.004, iClamp = 0.20, dAlpha = 0.3 },
        hoverTrim = 0.62,          -- as if already learned; true hover is ~0.65
        trimLearnRate = 0.004,
        vectorTrimAuthority = 0,   -- 0 = derive from the toe geometry
        minAirborneCollective = 0.20,
      },
    },
  })
  if overrides then cfg = require("lib.util").deepMerge(cfg, overrides) end
  return cfg
end

local function build(cfg)
  local log = quietLog()
  local osc = Oscillation.new(cfg, log)
  local per = Sim.fakePeripherals(cfg.hardware.thrusters)
  return {
    cfg = cfg,
    log = log,
    osc = osc,
    mixer = Mixer.new(cfg, per),
    attitude = Attitude.new(cfg, log, osc),
    altitude = Altitude.new(cfg, log, osc, { steps = 15 }),
  }
end

-- ------------------------------------------------------------------ mixer

T.suite("mixer")

T.it("layout is classified from config geometry", function()
  local m = build(simConfig())
  local caps = m.mixer:capabilities()
  T.eq(caps.lift, 4, "lift count")
  T.eq(caps.main, 1, "main count")
  T.eq(caps.lateral, 4, "lateral count")
  T.isTrue(caps.pitch, "pitch pairs present")
  T.isTrue(caps.roll, "roll pairs present")
  T.isTrue(caps.yaw, "yaw authority present")
  T.eq(caps.precisionThrusters, 2, "rear pair is precision-only")
end)

T.it("THE KEY PROPERTY: pure vertical trim makes no net horizontal force", function()
  local m = build(simConfig())
  local plant = Sim.newPlant({})
  -- toe-only demand: collective plus a trim change, nothing else
  local commands = m.mixer:mix({ collective = 0.5, verticalTrim = -1 })
  -- step twice with a long dt so the nozzles reach their targets
  plant:step(commands, 1.0)
  plant:step(commands, 1.0)
  T.near(plant.netX, 0, 1e-6, "no net side force from toe")
  T.near(plant.netZ, 0, 1e-6, "no net fore/aft force from toe")
  T.isTrue(plant.netUp > 0, "still lifting")
end)

T.it("vertical trim actually changes lift, continuously", function()
  local m = build(simConfig())
  local function liftFor(trim)
    local plant = Sim.newPlant({})
    local commands = m.mixer:mix({ collective = 0.5, verticalTrim = trim })
    plant:step(commands, 1.0)
    plant:step(commands, 1.0)
    return plant.netUp
  end
  local low, mid, high = liftFor(-1), liftFor(0), liftFor(1)
  T.isTrue(high > mid, "trim up gives more lift")
  T.isTrue(mid > low, "trim down gives less lift")
  -- and continuously: a small trim change gives a small lift change
  local nudge = liftFor(0.1)
  T.isTrue(nudge > mid and (nudge - mid) < (high - mid), "intermediate values are distinct")
end)

T.it("pitch demand produces a pitch moment and no net side force", function()
  local m = build(simConfig())
  local plant = Sim.newPlant({})
  local commands = m.mixer:mix({ collective = 0.5, pitchTorque = 0.4 })
  plant:step(commands, 1.0)
  local frontUp = plant.lastForces.lift_fl.up + plant.lastForces.lift_fr.up
  local rearUp = plant.lastForces.lift_rl.up + plant.lastForces.lift_rr.up
  T.isTrue(frontUp > rearUp, "nose-up demand sheds lift at the REAR")
  T.near(plant.netX, 0, 1e-6, "pitch toe cancels sideways")
end)

T.it("roll demand sheds lift on the correct side", function()
  local m = build(simConfig())
  local plant = Sim.newPlant({})
  local commands = m.mixer:mix({ collective = 0.5, rollTorque = 0.4 })
  plant:step(commands, 1.0)
  local leftUp = plant.lastForces.lift_fl.up + plant.lastForces.lift_rl.up
  local rightUp = plant.lastForces.lift_fr.up + plant.lastForces.lift_rr.up
  T.isTrue(leftUp > rightUp, "roll-right demand sheds lift on the RIGHT")
  T.near(plant.netZ, 0, 1e-6, "roll toe cancels fore/aft")
end)

T.it("attitude demand stays continuous until toe authority runs out", function()
  local m = build(simConfig())
  local cfg = m.cfg
  -- within toeShare: no differential thrust at all
  local small = m.mixer:mix({ collective = 0.5, pitchTorque = cfg.mixer.toeShare * 0.5 })
  T.near(small.lift_fl.thrust, small.lift_rl.thrust, 1e-9,
    "no differential thrust while toe can cope")
  -- beyond it: differential thrust appears
  local large = m.mixer:mix({ collective = 0.5, pitchTorque = 1.0 })
  T.isTrue(math.abs(large.lift_fl.thrust - large.lift_rl.thrust) > 1e-6,
    "differential thrust takes the excess")
end)

T.it("translation deflects every nozzle the same way, deliberately", function()
  local m = build(simConfig())
  local commands = m.mixer:mix({ collective = 0.5, translateX = 1.0 })
  local plant = Sim.newPlant({})
  plant:step(commands, 1.0)
  plant:step(commands, 1.0)
  T.isTrue(plant.netX > 0.1, "net side force produced")
end)

T.it("precisionOnly thrusters stay idle unless precision is allowed", function()
  local m = build(simConfig())
  local off = m.mixer:mix({ collective = 0.5, translateX = 1.0, allowPrecision = false })
  T.near(off.rear_l.thrust, 0, 1e-9, "rear pair idle in normal flight")
  T.near(off.rear_r.thrust, 0, 1e-9, "both of them")

  -- Only the member that can PUSH THAT WAY fires. rear_l faces right, so it pushes left and
  -- has nothing to contribute to a rightward demand -- its opposed partner serves it.
  local on = m.mixer:mix({ collective = 0.5, translateX = 1.0, allowPrecision = true })
  T.isTrue(on.rear_r.thrust > 0, "the rear thruster that pushes RIGHT engages")
  T.near(on.rear_l.thrust, 0, 1e-9, "the one that pushes left stays out of it")

  local left = m.mixer:mix({ collective = 0.5, translateX = -1.0, allowPrecision = true })
  T.isTrue(left.rear_l.thrust > 0, "and they swap for the other direction")
  T.near(left.rear_r.thrust, 0, 1e-9)
end)

T.it("yaw uses the opposed pair, one side at a time", function()
  local m = build(simConfig())
  local right = m.mixer:mix({ collective = 0.5, yawTorque = 1.0 })
  -- yaw_l pushes right from a forward position, yaw_r pushes left: only one serves +yaw
  T.isTrue((right.yaw_l.thrust > 0) ~= (right.yaw_r.thrust > 0), "exactly one side fires")
  local left = m.mixer:mix({ collective = 0.5, yawTorque = -1.0 })
  T.isTrue((left.yaw_l.thrust > 0) ~= (left.yaw_r.thrust > 0), "and the other for -yaw")
  T.isFalse((right.yaw_l.thrust > 0) == (left.yaw_l.thrust > 0), "opposite sides")
end)

T.it("thrust commands never leave 0..1", function()
  local m = build(simConfig())
  local commands = m.mixer:mix({
    collective = 1.5, verticalTrim = 5, pitchTorque = 9, rollTorque = -9,
    yawTorque = 9, translateX = 9, translateZ = -9, mainThrust = 9, allowPrecision = true,
  })
  for id, cmd in pairs(commands) do
    T.isTrue(cmd.thrust >= 0 and cmd.thrust <= 1, "thrust in range for " .. id)
  end
end)

-- ------------------------------------------------------------------ altitude

T.suite("altitude loop")

T.it("the craft climbs to the target and settles", function()
  local m = build(simConfig())
  local trace = Sim.run(m, {
    cfg = m.cfg, seconds = 30,
    target = { altitude = 80 },
    plant = { altitude = 70 },
  })
  local final = Sim.last(trace, "altitude")
  T.near(final, 80, 1.5, "settled near the target")
end)

T.it("NO LIMIT CYCLE once settled", function()
  local m = build(simConfig())
  local trace = Sim.run(m, {
    cfg = m.cfg, seconds = 40,
    target = { altitude = 80 },
    plant = { altitude = 78 },
  })
  local spread = Sim.peakToPeak(trace, "altitude", 8)
  T.isTrue(spread < 1.0, ("altitude spread over the last 8 s was %.3f (want < 1.0)"):format(spread))
  T.isTrue(Sim.isConverging(trace, "altitude", 16), "oscillation envelope is not growing")
end)

T.it("THE KEY PROPERTY: in steady state, toe trim covers the quantisation gap", function()
  local m = build(simConfig())
  local trace = Sim.run(m, {
    cfg = m.cfg, seconds = 40,
    target = { altitude = 85 },
    plant = { altitude = 70 },
  })
  -- During a big transient the demand legitimately pins to a rail, so the claim is about
  -- the SETTLED state: once tracking, the continuous axis must be able to absorb whatever
  -- the 16-step quantiser leaves behind.
  local saturatedInTail = false
  for _, row in ipairs(trace) do
    if row.t > 25 and row.trimSaturated then saturatedInTail = true end
  end
  T.isFalse(saturatedInTail,
    "the continuous axis never ran out of authority to cover a thrust step once settled")
end)

T.it("collective is floored while airborne -- zero thrust is free fall, not descent", function()
  local m = build(simConfig())
  -- demand a violent descent so the rate loop saturates low
  local out = m.altitude:update({ verticalSpeed = -50 },
    { altitude = 90, verticalSpeed = 0, groundContact = false }, 0.2)
  T.isTrue(out.collective >= m.cfg.control.altitude.minAirborneCollective - 1 / 15,
    ("collective %.3f respected the airborne floor"):format(out.collective))
end)

T.it("thrust steps are sticky -- no dithering between adjacent levels", function()
  local m = build(simConfig())
  local trace = Sim.run(m, {
    cfg = m.cfg, seconds = 30,
    target = { altitude = 80 },
    plant = { altitude = 79.5 },
  })
  -- count step changes over the settled tail
  local changes, last = 0, nil
  for _, row in ipairs(trace) do
    if row.t > 15 and type(row.step) == "number" then
      if last ~= nil and row.step ~= last then changes = changes + 1 end
      last = row.step
    end
  end
  T.isTrue(changes <= 6, ("only %d step changes in the settled tail (want <= 6)"):format(changes))
end)

T.it("no integrator windup while sitting on the ground", function()
  local m = build(simConfig())
  local trace = Sim.run(m, {
    cfg = m.cfg, seconds = 30, hz = 20,
    target = { altitude = 85 },
    plant = { altitude = 64, groundY = 64 },
    groundHoldSeconds = 8,      -- held on the skids for 8 s with a climb demand standing
  })
  -- the release must not produce a violent leap
  local peakClimb = 0
  for _, row in ipairs(trace) do
    if row.t > 8 and row.t < 14 then peakClimb = math.max(peakClimb, row.vs) end
  end
  T.isTrue(peakClimb < m.cfg.envelope.maxClimbRate * 1.6,
    ("peak climb after release was %.2f b/s (want < %.2f)"):format(
      peakClimb, m.cfg.envelope.maxClimbRate * 1.6))
end)

T.it("a dt spike produces no thrust kick", function()
  local m = build(simConfig())
  local trace = Sim.run(m, {
    cfg = m.cfg, seconds = 25,
    target = { altitude = 80 },
    plant = { altitude = 80 },
    dtSpikeAt = 12.0, dtSpikeSize = 2.0,
  })
  -- collective either side of the spike should barely differ
  local before, after
  for _, row in ipairs(trace) do
    if row.t < 12.0 then before = row.collective end
    if row.t > 12.4 and not after then after = row.collective end
  end
  T.notNil(before, "sampled before")
  T.notNil(after, "sampled after")
  T.isTrue(math.abs(after - before) <= 2 / 15 + 1e-9,
    ("collective moved %.3f across the stall (want <= 2 steps)"):format(math.abs(after - before)))
end)

T.it("hover trim is learned while settled", function()
  local cfg = simConfig()
  cfg.control.altitude.hoverTrim = 0.50      -- deliberately low; true hover is ~0.65
  cfg.control.altitude.trimLearnRate = 0.02
  local m = build(cfg)
  Sim.run(m, { cfg = cfg, seconds = 40, target = { altitude = 80 }, plant = { altitude = 80 } })
  local trim, learned = m.altitude:learnedTrim()
  T.isTrue(learned, "learning happened")
  T.isTrue(trim > 0.55, ("trim moved toward the true hover value (got %.3f)"):format(trim))
end)

T.it("on the ground the loop commands nothing at all", function()
  local m = build(simConfig())
  local out, dbg = m.altitude:update({ altitude = 100 },
    { altitude = 64, verticalSpeed = 0, groundContact = true }, 0.2)
  T.eq(out.collective, 0, "no collective")
  T.eq(out.verticalTrim, 0, "no trim")
  T.isTrue(dbg.grounded, "reported as grounded")
end)

-- ------------------------------------------------------------------ attitude

T.suite("attitude loop")

T.it("a disturbed craft returns to level in angle mode", function()
  local m = build(simConfig())
  local trace = Sim.run(m, {
    cfg = m.cfg, seconds = 25,
    target = { altitude = 80 },
    plant = { altitude = 80, pitch = 8, roll = -6 },
    attitudeDemand = { pitch = 0, roll = 0, yawRate = 0 },
  })
  T.near(Sim.last(trace, "pitch"), 0, 1.5, "pitch levelled")
  T.near(Sim.last(trace, "roll"), 0, 1.5, "roll levelled")
end)

T.it("attitude does not oscillate while levelling", function()
  local m = build(simConfig())
  local trace = Sim.run(m, {
    cfg = m.cfg, seconds = 30,
    target = { altitude = 80 },
    plant = { altitude = 80, pitch = 10 },
  })
  T.isTrue(Sim.isConverging(trace, "pitch", 16), "pitch envelope shrinking")
  local spread = Sim.peakToPeak(trace, "pitch", 8)
  T.isTrue(spread < 1.5, ("pitch spread %.3f deg in the tail (want < 1.5)"):format(spread))
end)

T.it("a commanded bank is held, then released back to level", function()
  local m = build(simConfig())
  local trace = Sim.run(m, {
    cfg = m.cfg, seconds = 40,
    target = { altitude = 80 },
    plant = { altitude = 80 },
    demandAt = function(t)
      if t < 20 then return { pitch = 0, roll = 10, yawRate = 0 } end
      return { pitch = 0, roll = 0, yawRate = 0 }
    end,
  })
  local atHold
  for _, row in ipairs(trace) do
    if row.t > 15 and row.t < 20 then atHold = row.roll end
  end
  T.near(atHold, 10, 2.5, "bank held near the demand")
  T.near(Sim.last(trace, "roll"), 0, 1.5, "released back to level")
end)

T.it("rate mode holds whatever attitude it reached", function()
  local m = build(simConfig())
  m.attitude:setMode("rate")
  local trace = Sim.run(m, {
    cfg = m.cfg, seconds = 30,
    target = { altitude = 80 },
    plant = { altitude = 80 },
    demandAt = function(t)
      if t < 6 then return { pitchRate = 0, rollRate = 6, yawRate = 0 } end
      return { pitchRate = 0, rollRate = 0, yawRate = 0 }   -- stick released
    end,
  })
  local atRelease, atEnd
  for _, row in ipairs(trace) do
    if row.t > 5.5 and row.t < 6.5 then atRelease = row.roll end
    atEnd = row.roll
  end
  T.isTrue(atRelease > 3, ("rate command produced roll (got %.2f)"):format(atRelease))
  -- it should NOT self-level: the attitude reached is roughly held
  T.isTrue(math.abs(atEnd) > math.abs(atRelease) * 0.4,
    ("rate mode held its attitude (release %.2f, end %.2f)"):format(atRelease, atEnd))
end)

T.it("yaw degrades to open loop when the gimbal gives no yaw", function()
  local m = build(simConfig())
  local _, dbg = m.attitude:update({ yawRate = 30 }, { pitch = 0, roll = 0 }, 0.05)
  T.isFalse(dbg.yawClosedLoop, "open loop")
  local out = m.attitude:update({ yawRate = m.cfg.envelope.maxYawRateDps }, { pitch = 0, roll = 0 }, 0.05)
  T.near(out.yawTorque, 1.0, 1e-6, "full demand maps to full torque")
end)

T.it("yaw closes the loop when yaw IS reported", function()
  local m = build(simConfig())
  local _, dbg = m.attitude:update({ yawRate = 10 }, { pitch = 0, roll = 0, yaw = 90 }, 0.05)
  T.isTrue(dbg.yawClosedLoop, "closed loop")
end)

T.it("angle and rate modes use independent gain sets", function()
  local cfg = simConfig()
  local m = build(cfg)
  T.near(m.attitude.pidAngle.pitch.p, cfg.control.attitude.pitch.p, 1e-9, "angle gains")
  T.near(m.attitude.pidRate.pitch.p, cfg.control.attitudeRate.pitch.p, 1e-9, "rate gains")
  T.isTrue(m.attitude.pid == m.attitude.pidAngle, "angle mode selected by default")
  m.attitude:setMode("rate")
  T.isTrue(m.attitude.pid == m.attitude.pidRate, "rate mode swaps the set")
end)

T.it("switching feel mode clears the new set's integrator", function()
  local m = build(simConfig())
  -- wind up the rate-mode integrator, then leave and come back
  m.attitude:setMode("rate")
  for _ = 1, 20 do
    m.attitude:update({ pitchRate = 20, rollRate = 0, yawRate = 0 }, { pitch = 0, roll = 0 }, 0.05)
  end
  T.isTrue(math.abs(m.attitude.pidRate.pitch.integral) > 0, "integral wound up")
  m.attitude:setMode("angle")
  m.attitude:setMode("rate")
  T.near(m.attitude.pidRate.pitch.integral, 0, 1e-9, "cleared on re-entry")
end)

T.it("the detector re-applies its gain scale every cycle, across mode switches", function()
  local m = build(simConfig())
  -- Trip the pitch axis. Real timestamps, so the detector's recovery timer behaves as it
  -- would in flight rather than instantly deciding the trip was ancient history.
  local now = os.epoch("utc")
  for i = 1, 40 do
    now = now + 50
    if m.osc:update("pitch", (i % 2 == 0) and 5.0 or -5.0, now) then break end
  end
  T.isTrue(m.osc:gainScale("pitch") < 1.0, "detector cut the angle-mode axis")
  -- The cut lives in the DETECTOR, not on the PID, so it survives a mode switch and is
  -- re-applied at the start of the next cycle.
  m.attitude:setMode("rate")
  m.attitude:setMode("angle")
  local expected = m.osc:gainScale("pitch")
  m.attitude:update({ pitch = 5, roll = 0 }, { pitch = 0, roll = 0 }, 0.05)
  T.near(m.attitude.pidAngle.pitch.gainScale, expected, 1e-9,
    "gain scale re-applied from the detector")
end)

-- ------------------------------------------- oscillation, end to end

T.suite("oscillation end to end")

T.it("the detector FIRES on a deliberately over-gained loop", function()
  local cfg = simConfig()
  -- absurd proportional gain with no damping: this must oscillate
  cfg.control.attitude.pitch = { p = 3.0, i = 0, d = 0, iClamp = 0.1, dAlpha = 1.0 }
  local m = build(cfg)
  Sim.run(m, {
    cfg = cfg, seconds = 25,
    target = { altitude = 80 },
    plant = { altitude = 80, pitch = 12, angularDamping = 0.1 },
  })
  T.isTrue(m.osc:trips("pitch") > 0,
    "the detector caught the divergence it was built for")
  T.isTrue(m.osc:gainScale("pitch") < 1.0, "and cut the gain")
end)

T.it("the detector stays quiet on a well-behaved loop", function()
  local cfg = simConfig()
  local m = build(cfg)
  Sim.run(m, {
    cfg = cfg, seconds = 30,
    target = { altitude = 80 },
    plant = { altitude = 78 },
  })
  T.eq(m.osc:trips("pitch"), 0, "no false positive on pitch")
  T.eq(m.osc:trips("altitude"), 0, "no false positive on altitude")
end)

T.it("gain cutting degrades authority rather than removing it", function()
  local cfg = simConfig()
  local m = build(cfg)
  m.osc:update("pitch", 5, 1000)
  m.attitude.pid.pitch:setGainScale(m.osc:gainScale("pitch"))
  local out = m.attitude:update({ pitch = 10, roll = 0 }, { pitch = 0, roll = 0 }, 0.05)
  T.isTrue(math.abs(out.pitchTorque) > 0, "still commanding something")
end)


-- ------------------------------------------------------------ sign sanity

T.suite("sign conventions -- the physics, pinned")

--- These exist because two errors cancelled. The mixer treated a nozzle AIM as a force, and
--- the simulator did too, so every translation and drift-damping test passed while the real
--- craft would have been pushed the wrong way. Each test below asserts ONE direction against
--- physics rather than against the other half of the code.

T.it("EXHAUST DOWN PUSHES THE CRAFT UP -- the only reason a lift thruster lifts", function()
  local plant = Sim.newPlant({})
  local commands = {}
  for _, spec in ipairs(Sim.defaultLayout()) do
    commands[spec.id] = { thrust = spec.group == "lift" and 1.0 or 0, defX = 0, defZ = 0 }
  end
  plant:step(commands, 0.05)
  T.isTrue(plant.netUp > 0, "four down-facing thrusters produce UP force: " .. plant.netUp)
end)

T.it("AN ACCELERATOR FACES BACKWARD AND PUSHES FORWARD", function()
  local plant = Sim.newPlant({})
  local commands = {}
  for _, spec in ipairs(Sim.defaultLayout()) do
    commands[spec.id] = { thrust = spec.group == "main" and 1.0 or 0, defX = 0, defZ = 0 }
  end
  plant:step(commands, 0.05)
  T.isTrue(plant.netZ > 0, "net force is FORWARD (+z): " .. plant.netZ)
end)

T.it("A THRUSTER FACING RIGHT PUSHES THE CRAFT LEFT", function()
  local plant = Sim.newPlant({})
  local commands = {}
  for _, spec in ipairs(Sim.defaultLayout()) do
    -- yaw_l faces "right"
    commands[spec.id] = { thrust = (spec.id == "yaw_l") and 1.0 or 0, defX = 0, defZ = 0 }
  end
  plant:step(commands, 0.05)
  T.isTrue(plant.netX < 0, "facing right, pushing left (-x): " .. plant.netX)
end)

T.it("AIMING A LIFT NOZZLE RIGHT PUSHES THE CRAFT LEFT", function()
  -- The one that was backwards. defX is an AIM; the force is opposite it.
  local plant = Sim.newPlant({})
  local commands = {}
  for _, spec in ipairs(Sim.defaultLayout()) do
    commands[spec.id] = { thrust = spec.group == "lift" and 1.0 or 0,
                          defX = spec.group == "lift" and 0.8 or 0, defZ = 0 }
  end
  plant:step(commands, 0.05)
  T.isTrue(plant.netX < 0, "aim +x gives force -x: " .. plant.netX)
  T.isTrue(plant.netUp > 0, "and it is still lifting")
end)

--- Force contributed by the LIFT group alone.
---
--- Isolated deliberately: the lateral thrusters serve the same translation demand and are
--- strong enough to mask a sign error in the lift vectoring entirely. A whole-craft assertion
--- passed with the lift sign inverted, which is worth remembering before trusting a net figure.
local function liftForce(plant)
  local x, z = 0, 0
  for id, f in pairs(plant.lastForces) do
    if id:find("^lift") then x = x + f.x; z = z + f.z end
  end
  return x, z
end

T.it("THE MIXER TURNS 'push right' INTO A RIGHTWARD FORCE, from the lift nozzles alone",
  function()
    local m = build(simConfig())
    local commands = m.mixer:mix({ collective = 0.6, translateX = 1.0 })
    local plant = Sim.newPlant({})
    plant:step(commands, 0.05)
    local x = liftForce(plant)
    T.isTrue(x > 0, "the lift group pushes RIGHT for a rightward demand: " .. x)
  end)

T.it("...and 'push forward' into a forward force, likewise", function()
  local m = build(simConfig())
  local commands = m.mixer:mix({ collective = 0.6, translateZ = 1.0 })
  local plant = Sim.newPlant({})
  plant:step(commands, 0.05)
  local _, z = liftForce(plant)
  T.isTrue(z > 0, "the lift group pushes FORWARD: " .. z)
end)

T.it("the whole craft agrees, laterals included", function()
  local m = build(simConfig())
  local commands = m.mixer:mix({ collective = 0.6, translateX = 1.0, allowPrecision = true })
  local plant = Sim.newPlant({})
  plant:step(commands, 0.05)
  T.isTrue(plant.netX > 0, "net +x: " .. plant.netX)
end)

T.it("THE ASSISTANT OPPOSES DRIFT RATHER THAN FEEDING IT", function()
  -- The consequence that made this worth hunting. A sign error here is positive feedback: the
  -- assistant pushes WITH the drift, the drift grows, it pushes harder. Runaway.
  local Assist = require("lib.control.assist")
  local Log = require("lib.log")
  local cfg = simConfig()
  local assist = Assist.new(cfg, Log.new({ level = "error", capacity = 20 }))
  local m = build(cfg)

  local out = assist:demand({
    velocity = { x = 2.0, z = 0 },     -- drifting to the RIGHT at 2 m/s
    capability = "vector", enabled = true, feel = "cruise",
    now = 1000, dt = 0.05,
  })
  T.isTrue(out.translateX < 0, "the demand is to push LEFT: " .. tostring(out.translateX))

  local commands = m.mixer:mix({ collective = 0.6, translateX = out.translateX })
  local plant = Sim.newPlant({})
  plant:step(commands, 0.05)
  local x = liftForce(plant)
  T.isTrue(x < 0, "and the lift nozzles push LEFT, against the drift: " .. x)
end)

T.it("drifting left is opposed too, symmetrically", function()
  local Assist = require("lib.control.assist")
  local Log = require("lib.log")
  local cfg = simConfig()
  local assist = Assist.new(cfg, Log.new({ level = "error", capacity = 20 }))
  local m = build(cfg)
  local out = assist:demand({
    velocity = { x = -2.0, z = 0 },
    capability = "vector", enabled = true, feel = "cruise",
    now = 1000, dt = 0.05,
  })
  T.isTrue(out.translateX > 0, "push right")
  local commands = m.mixer:mix({ collective = 0.6, translateX = out.translateX })
  local plant = Sim.newPlant({})
  plant:step(commands, 0.05)
  local x = liftForce(plant)
  T.isTrue(x > 0, "lift nozzles push right: " .. x)
end)

T.it("A YAW DEMAND YAWS THE COMMANDED WAY", function()
  -- +yaw is nose right. The moment about +y is r_z*F_x - r_x*F_z, using the FORCE.
  local m = build(simConfig())
  local right = m.mixer:mix({ collective = 0.5, yawTorque = 1.0 })
  local layout = m.mixer:ensureLayout()
  local moment = 0
  for _, item in ipairs(layout.lateral) do
    local thrust = right[item.id].thrust
    moment = moment + thrust * (item.pos.z * item.force.x - item.pos.x * item.force.z)
  end
  T.isTrue(moment > 0, "nose-right demand gives a positive yaw moment: " .. moment)

  local left = m.mixer:mix({ collective = 0.5, yawTorque = -1.0 })
  local leftMoment = 0
  for _, item in ipairs(layout.lateral) do
    leftMoment = leftMoment + left[item.id].thrust
      * (item.pos.z * item.force.x - item.pos.x * item.force.z)
  end
  T.isTrue(leftMoment < 0, "and the other way for nose-left: " .. leftMoment)
end)

T.it("the mixer's force vector is the NEGATION of the configured facing", function()
  local m = build(simConfig())
  local layout = m.mixer:ensureLayout()
  for _, item in ipairs(layout.lateral) do
    T.eq(item.force.x, -item.facing.x, item.id .. " x")
    T.eq(item.force.z, -item.facing.z, item.id .. " z")
  end
end)

return true
