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

--- CTRL+T MUST STILL WORK. Every thruster setter is mainThread, so the call yields, and a
--- terminate arriving mid-yield surfaces as an ordinary error inside callDevice's pcall. Catching
--- it made Ctrl+T a no-op: one call dies, the loop starts the next, and the pilot has to hit it
--- once per thruster before the program stops. Reported from the craft as a row of
--- "setVector() failed: Terminated" lines, one per press.
T.it("does not swallow a terminate", function()
  mock.reset()
  _G.peripheral = mock.install()
  local r = rig()
  local th = Thrusters.new(r.per, r.cfg, r.log, r.state)
  r.per.thrusters["lift_fl"].dev.setVector = function() error("Terminated", 0) end

  local ok, err = pcall(function()
    th:apply({ lift_fl = { thrust = 0.5, defX = 0.4, defZ = 0 } })
  end)
  T.isFalse(ok, "the terminate propagated instead of being absorbed")
  T.isTrue(tostring(err):find("Terminated") ~= nil, "and it is the terminate: " .. tostring(err))
end)

T.it("but a real device fault is still caught and counted", function()
  mock.reset()
  _G.peripheral = mock.install()
  local r = rig()
  local th = Thrusters.new(r.per, r.cfg, r.log, r.state)
  r.per.thrusters["lift_fl"].dev.setVector = function() error("no such method", 0) end
  local ok = pcall(function()
    th:apply({ lift_fl = { thrust = 0.5, defX = 0.4, defZ = 0 } })
  end)
  T.isTrue(ok, "an ordinary hardware fault does not take the loop down")
  T.isTrue(th.stats.errors > 0, "and is counted")
end)

T.it("write-on-change: repeating a command costs nothing", function()
  mock.reset()
  _G.peripheral = mock.install()
  local r = rig()
  local th = Thrusters.new(r.per, r.cfg, r.log, r.state)
  -- A NONZERO deflection, so the first apply genuinely has something to say. Asking for the
  -- centre a nozzle already sits at is not a write worth making, and "unchanged" is now judged
  -- from the block rather than from our own record -- see the re-assert test below.
  local cmd = { lift_fl = { thrust = 0.5, defX = 0.4, defZ = 0 },
                lift_fr = { thrust = 0.5, defX = 0.4, defZ = 0 } }
  local first = th:apply(cmd)
  T.eq(first, 4, "first apply writes vector+thrust for both")
  T.eq(th:apply(cmd), 0, "identical command writes nothing")
end)

--- THE PROPERTY THAT MATTERS ON THIS CRAFT. Every vector thruster carries four Create
--- redstone-link RECEIVERS which default to the blank frequency and join that network
--- unconditionally; they re-apply the network value (0, with no transmitter) whenever
--- `newPosition` is set, which a moving contraption sets constantly. So a nozzle can be zeroed
--- behind our back at any moment.
---
--- Deduplicating against our own memory of what we sent means never noticing, and never
--- re-asserting -- the nozzle stays at zero for ever while the log says it was commanded.
T.it("re-asserts a nozzle that something else zeroed behind our back", function()
  mock.reset()
  _G.peripheral = mock.install()
  local r = rig()
  local th = Thrusters.new(r.per, r.cfg, r.log, r.state)
  local cmd = { lift_fl = { thrust = 0.5, defX = 0.4, defZ = 0 } }
  th:apply(cmd)
  T.eq(th:apply(cmd), 0, "settled, so nothing is written")

  -- something else writes the nozzle back to centre
  local dev = r.per.thrusters["lift_fl"].dev
  dev.setVector(0, 0)

  T.eq(th:apply(cmd), 1, "the SAME command is re-sent, because the block no longer holds it")
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
  -- Nonzero, so the vector write is a real one rather than a request for the centre the nozzle
  -- is already at.
  local cmd = { lift_fl = { thrust = 0.5, defX = 0.4, defZ = 0 } }
  th:apply(cmd)
  th:invalidate()
  -- The THRUST step is re-asserted from memory, because a plain thruster has no readback to ask.
  -- The vector is not, because the block still reports the deflection it was given -- and the
  -- block is now the authority on that.
  T.eq(th:apply(cmd), 1, "thrust re-written; the nozzle already holds what we want")
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

--- A thruster with no fuel API at all: a piped Propulsion vector thruster.
local function stripFuelApi(per)
  for _, entry in ipairs(per:thrusterList()) do
    entry.dev.getFuelAmountMb = nil
    entry.dev.getFuelCapacityMb = nil
    entry.dev.getFuelAmount = nil
    entry.dev.getBurnTimeRemaining = nil
    entry.dev.getEnergyAmountFe = nil
  end
end

--- A log that counts what it was told, per level.
local function countingLog()
  local log = Log.new({ level = "info", capacity = 200 })
  local seen = { warn = {}, info = {} }
  for _, level in ipairs({ "warn", "info" }) do
    local real = log[level]
    log[level] = function(self, fmt, ...)
      seen[level][#seen[level] + 1] = string.format(fmt, ...)
      return real(self, fmt, ...)
    end
  end
  return log, seen
end

T.it("a guessed peripheral is announced ONCE, not on every rescan", function()
  -- scan() runs on every hardware assignment now (App:rebuildHardware), so a warning emitted
  -- per scan turns configuring a craft into a wall of identical lines.
  mock.reset()
  _G.peripheral = mock.install()
  local log, seen = countingLog()
  local cfg = Config.withDefaults({
    hardware = { thrusters = { { id = "lift_fl", peripheral = "vector_thruster_0", group = "lift" } } },
  })
  local per = Peripherals.new(cfg, log)
  for _ = 1, 6 do per:scan() end

  local guesses = 0
  for _, line in ipairs(seen.warn) do
    if line:find("auto%-picked") then guesses = guesses + 1 end
  end
  T.eq(guesses, 1, "said once across six scans, got " .. guesses)
end)

T.it("a piped install does NOT claim the fuel display will be blank", function()
  -- Reported from the cockpit: this spammed the flight console once per thruster, and what it
  -- said was false -- the tank gauge was configured and reading correctly the whole time.
  mock.reset()
  _G.peripheral = mock.install()
  local log, seen = countingLog()
  local cfg = Config.withDefaults({
    hardware = {
      thrusters = {
        { id = "lift_fl", peripheral = "vector_thruster_0", group = "lift" },
        { id = "lift_fr", peripheral = "vector_thruster_1", group = "lift" },
        { id = "lift_rl", peripheral = "vector_thruster_2", group = "lift" },
        { id = "lift_rr", peripheral = "vector_thruster_3", group = "lift" },
      },
      tanks = { { peripheral = "fluid_tank_0", label = "Main fuel", capacityMb = 0 } },
    },
  })
  local state = State.new({})
  local per = Peripherals.new(cfg, log):scan()
  stripFuelApi(per)
  local fuel = Fuel.new(per, cfg, log, state)

  for _ = 1, 5 do fuel:readAll() end
  local fuelWarnings = {}
  for _, line in ipairs(seen.warn) do
    if line:find("fuel") or line:find("FUEL") then fuelWarnings[#fuelWarnings + 1] = line end
  end
  T.eq(#fuelWarnings, 0, "no fuel warning at all, because nothing is wrong: "
    .. table.concat(fuelWarnings, " | "))
  local mentions = 0
  for _, line in ipairs(seen.info) do if line:find("no fuel of their own") then mentions = mentions + 1 end end
  T.eq(mentions, 1, "said ONCE across five read cycles, not once per thruster per cycle")

  -- and the thing the old message claimed would be blank
  local tanks = state:get("fuel.tanks") or {}
  T.eq(#tanks, 1, "the tank is read")
  T.near(tanks[1].fraction, 0.375, 1e-9, "and has a real fraction -- nothing is blank")
end)

T.it("clearing the kind cache does not re-announce it", function()
  -- The cache is cleared on every tank and vault assignment, which is how four wrong lines
  -- became a burst of them every time the pilot touched the config screen.
  mock.reset()
  _G.peripheral = mock.install()
  local log, seen = countingLog()
  local cfg = Config.withDefaults({
    hardware = {
      thrusters = { { id = "lift_fl", peripheral = "vector_thruster_0", group = "lift" } },
      tanks = { { peripheral = "fluid_tank_0", label = "Main fuel", capacityMb = 0 } },
    },
  })
  local per = Peripherals.new(cfg, log):scan()
  stripFuelApi(per)
  local fuel = Fuel.new(per, cfg, log, State.new({}))
  fuel:readAll()
  local after = #seen.info
  for _ = 1, 3 do
    fuel.kinds = {}            -- exactly what setTank/setVault does
    fuel:readAll()
  end
  T.eq(#seen.info, after, "re-detecting is fine; re-announcing is not")
end)

T.it("WARNS when there is no fuel reading anywhere -- no API and no tank", function()
  mock.reset()
  _G.peripheral = mock.install()
  local log, seen = countingLog()
  local cfg = Config.withDefaults({
    hardware = {
      thrusters = { { id = "lift_fl", peripheral = "vector_thruster_0", group = "lift" } },
      tanks = {},
    },
  })
  local per = Peripherals.new(cfg, log):scan()
  stripFuelApi(per)
  local fuel = Fuel.new(per, cfg, log, State.new({}))
  fuel:readAll()
  local found = nil
  for _, line in ipairs(seen.warn) do if line:find("NO TANK") then found = line end end
  T.notNil(found, "this one IS worth a warning")
  T.isTrue(found:find("FUEL TANK") ~= nil, "and points at the fix: " .. tostring(found))
end)

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
