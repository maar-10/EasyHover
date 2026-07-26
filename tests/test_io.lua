--[[ Phase 2: peripherals, thrusters, sensors, fuel, relays ]]

local T = require("tests.util")
local Config = require("lib.config")
local State = require("lib.state")
local Log = require("lib.log")
local Peripherals = require("lib.peripherals")
local Thrusters = require("lib.io.thrusters")
local Sensors = require("lib.io.sensors")
local Fuel = require("lib.io.fuel")
local Relays = require("lib.io.relays")

local mock = dofile("/tests/mocks/peripherals.lua")

local function quietLog()
  return Log.new({ level = "error", capacity = 50 })
end

--- Config wired to the mock network, with filters set to passthrough so assertions are
--- about the code under test rather than about filter settling.
local function testConfig(overrides)
  local cfg = Config.withDefaults({
    hardware = {
      thrusters = {
        { id = "lift_fl", peripheral = "vector_thruster_0", group = "lift",
          pos = { x = -1, y = 0, z = 1 } },
        { id = "lift_fr", peripheral = "vector_thruster_1", group = "lift",
          pos = { x = 1, y = 0, z = 1 }, invertVectorY = true },
      },
      relays = {
        { peripheral = "redstone_relay_0", side = "top", purpose = "aux", label = "lights" },
      },
    },
    sensors = {
      gimbal = { filterAlpha = 1.0 },
      altitude = { filterAlpha = 1.0, vsFilterAlpha = 1.0 },
      velocity = { filterAlpha = 1.0 },
      optical = { filterAlpha = 1.0 },
    },
  })
  if overrides then cfg = require("lib.util").deepMerge(cfg, overrides) end
  return cfg
end

local function rig(cfg)
  cfg = cfg or testConfig()
  local log = quietLog()
  local state = State.new({ staleMs = cfg.sensors.staleMs })
  local per = Peripherals.new(cfg, log):scan()
  return { cfg = cfg, log = log, state = state, per = per }
end

-- ------------------------------------------------------------ peripherals

T.suite("peripherals")

mock.reset()
_G.peripheral = mock.install()

T.it("configured thrusters resolve by name", function()
  local r = rig()
  T.eq(r.per:count(), 2, "count")
  T.notNil(r.per:thruster("lift_fl"), "device")
  T.eq(r.per.thrusters["lift_fl"].name, "vector_thruster_0", "name")
end)

T.it("a missing thruster is reported, not fatal", function()
  local cfg = testConfig()
  cfg.hardware.thrusters[2].peripheral = "does_not_exist"
  local r = rig(cfg)
  T.eq(r.per:count(), 1, "only the present one loads")
  T.containsMatch(r.per.missing, "does_not_exist", "missing list")
  T.isFalse(r.per:isComplete(), "incomplete")
end)

T.it("blank sensor names auto-pick by type", function()
  local r = rig()
  T.notNil(r.per.sensors.altitude, "altitude auto-picked")
  T.notNil(r.per.sensors.gimbal, "gimbal auto-picked")
  T.notNil(r.per.sensors.velocity, "velocity auto-picked")
end)

T.it("optical sensors are auto-discovered as a list", function()
  local r = rig()
  T.eq(#r.per.sensors.optical, 1, "one laser")
  T.eq(r.per.sensors.optical[1].name, "optical_sensor_0", "name")
end)

T.it("findByType only returns matching peripherals", function()
  local found = Peripherals.findByType("vector_thruster")
  T.eq(#found, 4, "four vector thrusters in the mock net")
  T.eq(#Peripherals.findByType("nonexistent_type"), 0, "none")
end)

T.it("summary counts groups and relays", function()
  local r = rig()
  local s = r.per:summary()
  T.eq(s.thrusters, 2, "thrusters")
  T.eq(s.lift, 2, "lift")
  T.eq(s.relays, 1, "relays")
  T.isTrue(s.complete, "complete")
end)

T.it("a peripheral event triggers a rescan", function()
  local r = rig()
  local before = r.per.scanCount
  T.isTrue(r.per:onEvent("peripheral_detach", "vector_thruster_0"), "handled")
  T.eq(r.per.scanCount, before + 1, "rescanned")
  T.isFalse(r.per:onEvent("timer", 1), "unrelated event ignored")
end)

-- ------------------------------------------------------------ thrusters

T.suite("thrusters")

T.it("thrustStep reproduces the mod's 16-step quantiser", function()
  T.eq(Thrusters.thrustStep(0), 0, "zero")
  T.eq(Thrusters.thrustStep(1), 15, "full")
  T.eq(Thrusters.thrustStep(0.37), 5, "0.37 -> 5 (not 5.55)")
  -- the trap: just short of full is NOT full
  T.eq(Thrusters.thrustStep(0.9999), 14, "0.9999 -> 14")
  T.near(Thrusters.stepToNormalized(5), 1 / 3, 1e-6, "5 -> 0.3333")
  T.near(Thrusters.stepSize(), 1 / 15, 1e-9, "step size")
end)

T.it("mapVector honours axis mapping, inversion and authority limit", function()
  local spec = { vectorMap = { x = "x", y = "z" }, invertVectorY = true, maxVector = 0.5 }
  local nx, ny = Thrusters.mapVector(spec, { defX = 0.8, defZ = -0.9 })
  T.near(nx, 0.5, 1e-9, "x clamped to authority")
  T.near(ny, 0.5, 1e-9, "z inverted then clamped")

  local spec2 = { vectorMap = { x = "z", y = "x" }, maxVector = 1.0 }
  local nx2, ny2 = Thrusters.mapVector(spec2, { defX = 0.25, defZ = -0.4 })
  T.near(nx2, -0.4, 1e-9, "swapped axes: nozzle x follows craft z")
  T.near(ny2, 0.25, 1e-9, "swapped axes: nozzle y follows craft x")
end)

T.it("write-on-change: repeating a command costs nothing", function()
  mock.reset()
  _G.peripheral = mock.install()
  local r = rig()
  local th = Thrusters.new(r.per, r.cfg, r.log, r.state)
  local cmd = { lift_fl = { thrust = 0.5, defX = 0, defZ = 0 },
                lift_fr = { thrust = 0.5, defX = 0, defZ = 0 } }
  local first = th:apply(cmd)
  T.eq(first, 4, "first apply writes vector+thrust for both")
  T.eq(th:apply(cmd), 0, "identical command writes nothing")
end)

T.it("a sub-step thrust change writes nothing; crossing a step writes", function()
  mock.reset()
  _G.peripheral = mock.install()
  local r = rig()
  local th = Thrusters.new(r.per, r.cfg, r.log, r.state)
  th:apply({ lift_fl = { thrust = 0.20 } })            -- step 3
  T.eq(th:apply({ lift_fl = { thrust = 0.21 } }), 0, "same step 3, no write")
  T.eq(th:apply({ lift_fl = { thrust = 0.27 } }), 1, "step 4, one write")
end)

T.it("vector deadband suppresses noise but not real movement", function()
  mock.reset()
  _G.peripheral = mock.install()
  local r = rig()
  local th = Thrusters.new(r.per, r.cfg, r.log, r.state)
  th:apply({ lift_fl = { thrust = 0, defX = 0.10, defZ = 0 } })
  T.eq(th:apply({ lift_fl = { thrust = 0, defX = 0.1005, defZ = 0 } }), 0, "under deadband")
  T.eq(th:apply({ lift_fl = { thrust = 0, defX = 0.15, defZ = 0 } }), 1, "over deadband")
end)

T.it("invalidate forces a full re-assert after a rescan", function()
  mock.reset()
  _G.peripheral = mock.install()
  local r = rig()
  local th = Thrusters.new(r.per, r.cfg, r.log, r.state)
  local cmd = { lift_fl = { thrust = 0.5 } }
  th:apply(cmd)
  th:invalidate()
  T.eq(th:apply(cmd), 2, "vector and thrust both re-written")
end)

T.it("neutralVectors keeps the thrust step (damped hover, not engine cut)", function()
  mock.reset()
  _G.peripheral = mock.install()
  local r = rig()
  local th = Thrusters.new(r.per, r.cfg, r.log, r.state)
  th:apply({ lift_fl = { thrust = 0.5, defX = 0.4, defZ = 0.3 },
             lift_fr = { thrust = 0.5, defX = 0.4, defZ = 0.3 } })
  local stepBefore = Thrusters.thrustStep(0.5)
  th:neutralVectors()
  local back = th:readback()
  T.eq(back.lift_fl.commandedStep, stepBefore, "step preserved")
  T.near(back.lift_fl.targetX, 0, 1e-9, "nozzle centred")
end)

T.it("allStop zeroes everything", function()
  mock.reset()
  _G.peripheral = mock.install()
  local r = rig()
  local th = Thrusters.new(r.per, r.cfg, r.log, r.state)
  th:apply({ lift_fl = { thrust = 0.8 }, lift_fr = { thrust = 0.8 } })
  th:allStop()
  local back = th:readback()
  T.eq(back.lift_fl.commandedStep, 0, "step zero")
  T.near(back.lift_fl.power, 0, 1e-9, "power zero")
end)

T.it("liftCommanded averages the lift group after quantisation", function()
  mock.reset()
  _G.peripheral = mock.install()
  local r = rig()
  local th = Thrusters.new(r.per, r.cfg, r.log, r.state)
  th:apply({ lift_fl = { thrust = 0.5 }, lift_fr = { thrust = 0.5 } })
  local avg, count = th:liftCommanded()
  T.eq(count, 2, "counted both")
  T.near(avg, Thrusters.stepToNormalized(7), 1e-9, "quantised average")
end)

T.it("identify is refused unless the caller proves we are on the ground", function()
  mock.reset()
  _G.peripheral = mock.install()
  local r = rig()
  local th = Thrusters.new(r.per, r.cfg, r.log, r.state)
  local ok, err = th:startIdentify("lift_fl", { allowed = false })
  T.isFalse(ok, "refused")
  T.isTrue(tostring(err):find("ground") ~= nil, "reason mentions ground")
end)

T.it("identify is refused on a thruster that is producing thrust", function()
  mock.reset()
  _G.peripheral = mock.install()
  local r = rig()
  local th = Thrusters.new(r.per, r.cfg, r.log, r.state)
  th:apply({ lift_fl = { thrust = 0.5 } })
  local ok, err = th:startIdentify("lift_fl", { allowed = true })
  T.isFalse(ok, "refused")
  T.isTrue(tostring(err):find("thrust") ~= nil, "reason mentions thrust")
end)

T.it("identify sweeps then ends on its own", function()
  mock.reset()
  _G.peripheral = mock.install()
  local r = rig()
  local th = Thrusters.new(r.per, r.cfg, r.log, r.state)
  T.isTrue(th:startIdentify("lift_fl", { allowed = true, durationMs = 120, periodMs = 60 }))
  T.isTrue(th:isIdentifying(), "running")
  T.isTrue(th:tickIdentify(), "ticks while running")
  sleep(0.25)
  T.isFalse(th:tickIdentify(), "finished")
  T.isFalse(th:isIdentifying(), "cleared")
end)

T.it("an unknown id is refused", function()
  local r = rig()
  local th = Thrusters.new(r.per, r.cfg, r.log, r.state)
  local ok = th:startIdentify("nope", { allowed = true })
  T.isFalse(ok, "refused")
end)

-- ------------------------------------------------------------ sensors

T.suite("sensors")

T.it("attitude is normalised from the configured gimbal indices", function()
  mock.reset()
  _G.peripheral = mock.install()
  mock.vehicle.pitch = 5
  mock.vehicle.roll = -3
  local r = rig()
  local sensors = Sensors.new(r.per, r.cfg, r.log, r.state)
  sensors:read(0.05)
  T.near(r.state:get("attitude.pitch"), 5, 1e-6, "pitch")
  T.near(r.state:get("attitude.roll"), -3, 1e-6, "roll")
end)

T.it("inversion and scale are applied", function()
  mock.reset()
  _G.peripheral = mock.install()
  mock.vehicle.pitch = 4
  local cfg = testConfig({ sensors = { gimbal = { pitchInvert = true, scale = 2.0 } } })
  local r = rig(cfg)
  local sensors = Sensors.new(r.per, r.cfg, r.log, r.state)
  sensors:read(0.05)
  T.near(r.state:get("attitude.pitch"), -8, 1e-6, "inverted and scaled")
end)

T.it("yaw appears only when the gimbal actually provides it", function()
  mock.reset()
  _G.peripheral = mock.install()
  local r = rig()
  local sensors = Sensors.new(r.per, r.cfg, r.log, r.state)
  sensors:read(0.05)
  T.isNil(r.state:get("attitude.yaw"), "no yaw with a 2-element gimbal")

  mock.vehicle.angles = { 1, 2, 90 }
  local cfg = testConfig({ sensors = { gimbal = { yawIndex = 3, filterAlpha = 1.0 } } })
  local r2 = rig(cfg)
  local sensors2 = Sensors.new(r2.per, r2.cfg, r2.log, r2.state)
  sensors2:read(0.05)
  T.near(r2.state:get("attitude.yaw"), 90, 1e-6, "yaw read from index 3")
end)

T.it("a short gimbal reply leaves attitude stale rather than wrong", function()
  mock.reset()
  _G.peripheral = mock.install()
  mock.vehicle.angles = { 1 }         -- rollIndex 2 is missing
  local r = rig()
  local sensors = Sensors.new(r.per, r.cfg, r.log, r.state)
  sensors:read(0.05)
  T.isNil(r.state:get("attitude.pitch"), "nothing published")
  T.eq(r.state:age("attitude.pitch"), math.huge, "channel never written")
end)

T.it("vertical speed is differentiated from altitude", function()
  mock.reset()
  _G.peripheral = mock.install()
  mock.vehicle.altitude = 100
  local r = rig()
  local sensors = Sensors.new(r.per, r.cfg, r.log, r.state)
  sensors:read(0.1)
  T.near(r.state:get("altitude.vs"), 0, 1e-9, "first sample has no derivative")
  mock.vehicle.altitude = 101
  sensors:read(0.1)
  T.near(r.state:get("altitude.vs"), 10, 1e-6, "1 block in 0.1 s = 10 b/s")
  mock.vehicle.altitude = 100.5
  sensors:read(0.1)
  T.near(r.state:get("altitude.vs"), -5, 1e-6, "descent is negative")
end)

T.it("a dt spike does NOT produce a vertical-speed kick", function()
  mock.reset()
  _G.peripheral = mock.install()
  mock.vehicle.altitude = 100
  local r = rig()
  local sensors = Sensors.new(r.per, r.cfg, r.log, r.state)
  sensors:read(0.1)
  mock.vehicle.altitude = 101
  sensors:read(0.1)
  local before = r.state:get("altitude.vs")
  mock.vehicle.altitude = 130          -- huge jump...
  sensors:read(2.0)                    -- ...with a stalled dt beyond dtMaxMs
  T.near(r.state:get("altitude.vs"), before, 1e-9, "derivative skipped on overrun")
end)

T.it("ground contact needs BOTH proximity and near-zero vertical speed", function()
  mock.reset()
  _G.peripheral = mock.install()
  mock.vehicle.altitude = 70
  mock.vehicle.groundDist = 0.5
  local r = rig()
  local sensors = Sensors.new(r.per, r.cfg, r.log, r.state)
  sensors:read(0.1)                    -- establishes altitude, vs = 0
  sensors:read(0.1)
  T.isTrue(r.state:get("ground.contact"), "close and still = contact")

  mock.vehicle.altitude = 70.5         -- now descending fast past the ground
  sensors:read(0.1)
  T.isFalse(r.state:get("ground.contact"), "a low fast pass is not a landing")
end)

T.it("pad whitelist rejects anything not listed", function()
  mock.reset()
  _G.peripheral = mock.install()
  local r = rig()
  local sensors = Sensors.new(r.per, r.cfg, r.log, r.state)
  T.isTrue(sensors:padBlockAllowed("minecraft:stone"), "listed")
  T.isFalse(sensors:padBlockAllowed("minecraft:grass_block"), "not listed")
  T.isFalse(sensors:padBlockAllowed(nil), "nil")
end)

T.it("isHealthy reflects what the loops can trust", function()
  mock.reset()
  _G.peripheral = mock.install()
  local r = rig()
  local sensors = Sensors.new(r.per, r.cfg, r.log, r.state)
  sensors:read(0.05)
  local ok, detail = sensors:isHealthy()
  T.isTrue(ok, "healthy after a good read")
  T.isTrue(detail.attitude, "attitude ok")
  T.isFalse(detail.heading, "no heading from a 2-element gimbal")
end)

-- ------------------------------------------------------------ fuel

T.suite("fuel")

T.it("fuel kind is detected from the methods present", function()
  mock.reset()
  _G.peripheral = mock.install()
  local cfg = testConfig()
  cfg.hardware.thrusters = {
    { id = "fluid_one", peripheral = "vector_thruster_0", group = "lift", maxVector = 0.6,
      pos = { x = 0, y = 0, z = 0 }, vectorMap = { x = "x", y = "z" }, enabled = true },
    { id = "solid_one", peripheral = "solid_fuel_thruster_0", group = "lift", maxVector = 0.6,
      pos = { x = 0, y = 0, z = 0 }, vectorMap = { x = "x", y = "z" }, enabled = true },
    { id = "ion_one", peripheral = "ion_thruster_0", group = "lateral", maxVector = 0.6,
      pos = { x = 0, y = 0, z = 0 }, vectorMap = { x = "x", y = "z" }, enabled = true },
  }
  local r = rig(cfg)
  local fuel = Fuel.new(r.per, r.cfg, r.log, r.state)
  local rows = fuel:read()
  T.eq(rows.fluid_one.kind, "fluid", "fluid")
  T.eq(rows.solid_one.kind, "solid", "solid")
  T.eq(rows.ion_one.kind, "energy", "ion")
  T.near(rows.fluid_one.fraction, 0.5, 1e-9, "4000/8000")
  T.eq(rows.solid_one.burning, true, "burn flag")
  T.notNil(rows.solid_one.burnTime, "burn time")
end)

T.it("the worst case considers lift thrusters only", function()
  mock.reset()
  _G.peripheral = mock.install({ devices = {
    -- a nearly dry LATERAL thruster must not become the reported worst case
    ion_thruster_0 = { type = "ion_thruster", dev = mock.ionThruster({ energy = 1000 }) },
  } })
  local cfg = testConfig()
  cfg.hardware.thrusters = {
    { id = "lift_one", peripheral = "vector_thruster_0", group = "lift", maxVector = 0.6,
      pos = { x = 0, y = 0, z = 0 }, vectorMap = { x = "x", y = "z" }, enabled = true },
    { id = "lat_one", peripheral = "ion_thruster_0", group = "lateral", maxVector = 0.6,
      pos = { x = 0, y = 0, z = 0 }, vectorMap = { x = "x", y = "z" }, enabled = true },
  }
  local r = rig(cfg)
  local fuel = Fuel.new(r.per, r.cfg, r.log, r.state)
  local _, agg = fuel:read()
  T.eq(agg.worstId, "lift_one", "worst is the lift thruster")
  T.near(agg.worstFraction, 0.5, 1e-9, "its fraction")
end)

T.it("level classifies against the thresholds", function()
  T.eq(Fuel.level(0.05), "warning", "warning")
  T.eq(Fuel.level(0.20), "caution", "caution")
  T.eq(Fuel.level(0.80), "ok", "ok")
  T.eq(Fuel.level(nil), "unknown", "unknown")
end)

-- ------------------------------------------------------------ relays
T.suite("relays (aux only -- the hardware failsafe was scrapped)")

T.it("the failsafe API is gone, deliberately", function()
  mock.reset()
  _G.peripheral = mock.install()
  local r = rig()
  local relays = Relays.new(r.per, r.cfg, r.log, r.state)
  -- Scrapped 2026-07-26: a relay per thruster cost too much space and weight. If this ever
  -- comes back it must come back wired, not as a half-version that only looks safe.
  T.isNil(relays.applyFailsafe, "applyFailsafe removed")
  T.isNil(relays.applyDerivedFailsafe, "applyDerivedFailsafe removed")
  T.isNil(relays.testFailsafe, "testFailsafe removed")
end)

T.it("aux outputs are addressed by label", function()
  mock.reset()
  _G.peripheral = mock.install({ devices = {
    redstone_relay_1 = { type = "redstone_relay", dev = mock.relay() },
  } })
  local cfg = testConfig()
  table.insert(cfg.hardware.relays, {
    peripheral = "redstone_relay_1", side = "left", level = 0,
    purpose = "aux", label = "lights",
  })
  cfg = Config.withDefaults(cfg)
  local r = rig(cfg)
  local relays = Relays.new(r.per, r.cfg, r.log, r.state)
  T.isTrue(relays:setAux("lights", true), "set")
  T.isTrue(r.state:get("aux.lights"), "state updated")
  T.containsMatch(relays:auxLabels(), "lights", "label listed")
  T.isFalse(relays:setAux("nonexistent", true), "unknown label refused")
end)

T.it("toggleAux flips and reports the new value", function()
  mock.reset()
  _G.peripheral = mock.install()
  local cfg = testConfig()
  cfg.hardware.relays = {
    { peripheral = "redstone_relay_0", side = "top", purpose = "aux", label = "gear" },
  }
  cfg = Config.withDefaults(cfg)
  local r = rig(cfg)
  local relays = Relays.new(r.per, r.cfg, r.log, r.state)
  T.eq(relays:toggleAux("gear"), true, "off -> on")
  T.eq(relays:toggleAux("gear"), false, "on -> off")
end)

T.it("an analog aux output is clamped to the legal range", function()
  mock.reset()
  _G.peripheral = mock.install()
  local cfg = testConfig()
  cfg.hardware.relays = {
    { peripheral = "redstone_relay_0", side = "top", purpose = "aux", label = "dimmer" },
  }
  cfg = Config.withDefaults(cfg)
  local r = rig(cfg)
  local relays = Relays.new(r.per, r.cfg, r.log, r.state)
  T.isTrue(relays:setAuxLevel("dimmer", 99), "set")
  T.eq(r.state:get("aux.dimmer.level"), 15, "clamped high")
  relays:setAuxLevel("dimmer", -4)
  T.eq(r.state:get("aux.dimmer.level"), 0, "clamped low")
end)

T.it("a write failure is caught rather than thrown", function()
  mock.reset()
  _G.peripheral = mock.install({ devices = {
    redstone_relay_0 = { type = "redstone_relay", dev = mock.relay({ failWrites = true }) },
  } })
  local cfg = testConfig()
  cfg.hardware.relays = {
    { peripheral = "redstone_relay_0", side = "top", purpose = "aux", label = "lights" },
  }
  cfg = Config.withDefaults(cfg)
  local r = rig(cfg)
  local relays = Relays.new(r.per, r.cfg, r.log, r.state)
  local ok = relays:setAux("lights", true)
  T.isFalse(ok, "reported as a failure, not an exception")
end)

T.it("readback lists every relay for the UI", function()
  mock.reset()
  _G.peripheral = mock.install()
  local cfg = testConfig()
  cfg.hardware.relays = {
    { peripheral = "redstone_relay_0", side = "top", purpose = "aux", label = "lights" },
  }
  cfg = Config.withDefaults(cfg)
  local r = rig(cfg)
  local relays = Relays.new(r.per, r.cfg, r.log, r.state)
  relays:setAux("lights", true)
  local rows = relays:readback()
  T.eq(#rows, 1, "one relay")
  T.eq(rows[1].label, "lights", "label")
  T.isTrue(rows[1].digital, "state read back")
end)

return true
