--[[ Phase 4: bindings, typewriter polling, controller, and the pilot aggregator.
     Plus an end-to-end smoke test of the flight computer against mocked hardware.
]]

local T = require("tests.util")
local Config = require("lib.config")
local Log = require("lib.log")
local Bindings = require("lib.input.bindings")
local Typewriter = require("lib.input.typewriter")
local Controller = require("lib.input.controller")
local Pilot = require("lib.input.pilot")

local mock = dofile("/tests/mocks/peripherals.lua")

local function quietLog() return Log.new({ level = "error", capacity = 50 }) end

local function baseCfg(overrides)
  local cfg = Config.withDefaults({
    hardware = {
      thrusters = {
        { id = "lift_fl", peripheral = "vector_thruster_0", group = "lift",
          pos = { x = -1.5, y = 0, z = 2 } },
        { id = "lift_fr", peripheral = "vector_thruster_1", group = "lift",
          pos = { x = 1.5, y = 0, z = 2 } },
        { id = "lift_rl", peripheral = "vector_thruster_2", group = "lift",
          pos = { x = -1.5, y = 0, z = -2 } },
        { id = "lift_rr", peripheral = "vector_thruster_3", group = "lift",
          pos = { x = 1.5, y = 0, z = -2 } },
      },
      relays = {
        { peripheral = "redstone_relay_0", side = "top", purpose = "aux", label = "lights" },
      },
      sensors = { velocityVector = {
        { peripheral = "velocity_sensor_0", axis = "z" },
        { peripheral = "velocity_sensor_1", axis = "x" },
      } },
    },
  })
  if overrides then cfg = require("lib.util").deepMerge(cfg, overrides) end
  return cfg
end

-- ------------------------------------------------------------------ bindings

T.suite("bindings")

T.it("default bindings resolve to real key codes", function()
  local b = Bindings.new(baseCfg(), quietLog())
  T.eq(#b.problems, 0, "no problems: " .. table.concat(b.problems, "; "))
  T.eq(b:keyForAction("pitchUp"), keys.s, "pitchUp -> s")
  T.eq(b:actionForKey(keys.space), "climb", "space -> climb")
end)

T.it("an invalid key name is reported, not silently ignored", function()
  local cfg = baseCfg()
  cfg.input.typewriter.bindings.brake = "not_a_key"
  local b = Bindings.new(cfg, quietLog())
  T.containsMatch(b.problems, "not a valid key name", "reported")
end)

T.it("binding one key to two actions is reported", function()
  local cfg = baseCfg()
  cfg.input.typewriter.bindings.brake = "w"      -- already pitchDown
  local b = Bindings.new(cfg, quietLog())
  T.containsMatch(b.problems, "bound to both", "collision reported")
end)

T.it("controller axes support inversion by a negative index", function()
  local cfg = baseCfg()
  cfg.input.controller.axes.pitch = -2
  local b = Bindings.new(cfg, quietLog())
  local index, inverted = b:controllerAxis("pitch")
  T.eq(index, 2, "index")
  T.isTrue(inverted, "inverted")
end)

T.it("unbound actions are enumerable for the config UI", function()
  local cfg = baseCfg()
  cfg.input.typewriter.bindings.yawLeft = nil
  local b = Bindings.new(cfg, quietLog())
  T.containsMatch(b:unbound(), "yawLeft", "listed as unbound")
end)

-- ------------------------------------------------------------------ typewriter

T.suite("typewriter (polled)")

local function twRig(pressed)
  mock.reset()
  local codes = pressed or {}
  _G.peripheral = mock.install({ devices = {
    linked_typewriter_0 = { type = "linked_typewriter", dev = {
      getPressedKeyCodes = function() return codes end,
    } },
  } })
  local cfg = baseCfg()
  local b = Bindings.new(cfg, quietLog())
  local tw = Typewriter.new(b, cfg, quietLog())
  return tw, peripheral.wrap("linked_typewriter_0"), codes, cfg
end

T.it("a held key ramps its axis rather than slamming it", function()
  local tw, dev, _, cfg = twRig({ keys.s })      -- pitchUp
  local axes = tw:poll(dev, 0.1)
  T.near(axes.pitch, cfg.input.typewriter.rate * 0.1, 1e-9, "one step of ramp")
  for _ = 1, 20 do axes = tw:poll(dev, 0.1) end
  T.near(axes.pitch, 1, 1e-9, "reaches full deflection")
end)

T.it("releasing returns the axis to centre at its own rate", function()
  local tw, dev, codes, cfg = twRig({ keys.s })
  for _ = 1, 20 do tw:poll(dev, 0.1) end
  T.near(tw.axes.pitch, 1, 1e-9, "deflected")
  for i = #codes, 1, -1 do codes[i] = nil end     -- release everything
  local axes = tw:poll(dev, 0.1)
  T.near(axes.pitch, 1 - cfg.input.typewriter.centreRate * 0.1, 1e-9, "centring")
  for _ = 1, 20 do axes = tw:poll(dev, 0.1) end
  T.near(axes.pitch, 0, 1e-9, "back to centre")
end)

T.it("opposite keys cancel", function()
  local tw, dev = twRig({ keys.a, keys.d })       -- rollLeft + rollRight
  for _ = 1, 20 do tw:poll(dev, 0.1) end
  T.near(tw.axes.roll, 0, 1e-9, "net zero")
end)

T.it("the accel axis is NOT ramped -- modes integrates it", function()
  local tw, dev = twRig({ keys.r })               -- accelerate
  local axes = tw:poll(dev, 0.1)
  T.eq(axes.accel, 1, "discrete, full value immediately")
end)

T.it("edge actions fire once per press", function()
  local tw, dev, codes = twRig({ keys.m })        -- cycleFeel
  local _, _, edges = tw:poll(dev, 0.05)
  T.isTrue(edges.cycleFeel, "fired")
  local _, _, again = tw:poll(dev, 0.05)
  T.isFalse(again.cycleFeel, "does not repeat while held")
  for i = #codes, 1, -1 do codes[i] = nil end
  tw:poll(dev, 0.05)
  codes[1] = keys.m
  local _, _, third = tw:poll(dev, 0.05)
  T.isTrue(third.cycleFeel, "fires again on the next press")
end)

T.it("held actions report while down", function()
  local tw, dev, codes = twRig({ keys.b })        -- brake
  local _, held = tw:poll(dev, 0.05)
  T.isTrue(held.brake, "brake held")
  for i = #codes, 1, -1 do codes[i] = nil end
  local _, released = tw:poll(dev, 0.05)
  T.isFalse(released.brake, "released")
end)

T.it("a failing peripheral returns nil instead of throwing", function()
  local tw, _ = twRig({})
  local bad = { getPressedKeyCodes = function() error("gone", 0) end }
  T.isNil(tw:poll(bad, 0.05), "nil on failure")
  T.isNil(tw:poll(nil, 0.05), "nil with no device")
end)

-- ------------------------------------------------------------------ controller

T.suite("controller")

local function ctrlRig(axisValues, buttons, overrides)
  mock.reset()
  local values = axisValues or {}
  local pressed = buttons or {}
  local precision = { applied = false }
  _G.peripheral = mock.install({ devices = {
    tweaked_controller_0 = { type = "tweaked_controller", dev = {
      hasUser = function() return values.manned ~= false end,
      getUserUUID = function() return "mock" end,
      isFullPrecision = function() return precision.applied end,
      setFullPrecision = function(v) precision.applied = v and true or false end,
      getAxis = function(i) return values[i] or 0 end,
      getButton = function(b) return pressed[b] and true or false end,
    } },
  } })
  local cfg = baseCfg(overrides)
  local b = Bindings.new(cfg, quietLog())
  return Controller.new(b, cfg, quietLog()), peripheral.wrap("tweaked_controller_0"),
    precision, cfg
end

T.it("full precision is applied on first read -- the default is coarse", function()
  local c, dev, precision = ctrlRig({ [1] = 0 })
  c:read(dev)
  T.isTrue(precision.applied, "setFullPrecision(true) was called")
end)

T.it("axes map through the configured indices", function()
  local c, dev = ctrlRig({ [1] = 0.8, [2] = -0.6 })   -- roll = 1, pitch = 2
  local axes = c:read(dev)
  T.isTrue(axes.roll > 0.5, "roll from axis 1")
  T.isTrue(axes.pitch < -0.3, "pitch from axis 2")
end)

T.it("the dead zone suppresses stick slop", function()
  local c, dev, _, cfg = ctrlRig({ [1] = cfg and 0 or 0.03 })
  local axes = c:read(dev)
  T.near(axes.roll, 0, 1e-9, "inside the dead zone")
end)

T.it("inversion is honoured", function()
  local c, dev = ctrlRig({ [2] = 0.9 }, nil, { input = { controller = { axes = { pitch = -2 } } } })
  local axes = c:read(dev)
  T.isTrue(axes.pitch < 0, "inverted")
end)

T.it("an unmanned controller centres its axes", function()
  local c, dev = ctrlRig({ [1] = 0.9, manned = false })
  local axes = c:read(dev)
  T.near(axes.roll, 0, 1e-9, "an empty seat cannot leave an input standing")
  T.isFalse(c.hasUser, "reported unmanned")
end)

T.it("buttons produce held state and one-shot edges", function()
  local c, dev = ctrlRig({}, { [1] = true, [2] = true })   -- brake, cycleFeel
  local _, held, edges = c:read(dev)
  T.isTrue(held.brake, "brake held")
  T.isTrue(edges.cycleFeel, "edge fired")
  local _, _, again = c:read(dev)
  T.isFalse(again.cycleFeel, "not repeated")
end)

-- ------------------------------------------------------------------ pilot

T.suite("pilot aggregator")

T.it("the source further from centre wins", function()
  mock.reset()
  _G.peripheral = mock.install({ devices = {
    tweaked_controller_0 = { type = "tweaked_controller", dev = {
      hasUser = function() return true end,
      isFullPrecision = function() return true end,
      setFullPrecision = function() end,
      getAxis = function(i) return (i == 1) and 0.9 or 0 end,   -- roll hard right
      getButton = function() return false end,
    } },
    linked_typewriter_0 = { type = "linked_typewriter", dev = {
      getPressedKeyCodes = function() return { keys.a } end,     -- rollLeft, ramping
    } },
  } })
  local cfg = baseCfg()
  local pilot = Pilot.new(cfg, quietLog())
  local devices = {
    controller = peripheral.wrap("tweaked_controller_0"),
    typewriter = peripheral.wrap("linked_typewriter_0"),
  }
  local axes = pilot:read(devices, 0.05)
  T.isTrue(axes.roll > 0.5, "the hard controller deflection wins over a ramping key")
end)

T.it("either device can hold the brake", function()
  mock.reset()
  _G.peripheral = mock.install({ devices = {
    linked_typewriter_0 = { type = "linked_typewriter", dev = {
      getPressedKeyCodes = function() return { keys.b } end,
    } },
  } })
  local pilot = Pilot.new(baseCfg(), quietLog())
  local _, held = pilot:read({ typewriter = peripheral.wrap("linked_typewriter_0") }, 0.05)
  T.isTrue(held.brake, "brake from the keyboard")
end)

T.it("isCommanding ignores mode toggles and reports movement only", function()
  mock.reset()
  _G.peripheral = mock.install({ devices = {
    linked_typewriter_0 = { type = "linked_typewriter", dev = {
      getPressedKeyCodes = function() return { keys.m } end,     -- cycleFeel only
    } },
  } })
  local pilot = Pilot.new(baseCfg(), quietLog())
  pilot:read({ typewriter = peripheral.wrap("linked_typewriter_0") }, 0.05)
  T.isFalse(pilot:isCommanding(), "a mode toggle is not a movement command")
end)

-- ------------------------------------------------------- app smoke test

T.suite("flight computer end to end")

T.it("boots against mocked hardware and flies cycles", function()
  mock.reset()
  _G.peripheral = mock.install()
  local App = require("app")

  local path = "/test_app_config.tbl"
  Config.save(path, baseCfg())
  local app = App.new({ configPath = path })
  local valid = app:boot()
  T.isTrue(valid, "config validated")
  T.notNil(app.modes.altitudeTarget, "hold altitude adopted from the first reading")

  for _ = 1, 40 do app:cycle(0.05) end
  T.isTrue(app.cycles >= 40, "cycles ran")
  T.notNil(app.state:get("thrusters.calls"), "thrusters were commanded")
  T.notNil(app.state:get("layout"), "layout published")
  T.eq(app.state:get("velocity.capability"), "vector", "velocity vector available")

  fs.delete(path)
end)

T.it("a full-throttle cycle commands the main thrusters and lift together", function()
  mock.reset()
  _G.peripheral = mock.install()
  local App = require("app")
  local cfg = baseCfg()
  table.insert(cfg.hardware.thrusters, {
    id = "main", peripheral = "solid_fuel_thruster_0", group = "main",
    pos = { x = 0, y = 0, z = -2.5 }, thrustAxis = "forward",
  })
  local path = "/test_app_config2.tbl"
  Config.save(path, Config.withDefaults(cfg))
  local app = App.new({ configPath = path })
  app:boot()
  -- lift off the ground first, then open the throttle
  mock.vehicle.groundDist = 12
  app.modes.throttle = 0.8
  for _ = 1, 20 do app:cycle(0.05) end
  local back = app.thrusters:readback()
  T.notNil(back.main, "main thruster present")
  T.isTrue((back.main.power or 0) > 0, "main thruster commanded forward thrust")
  T.eq(app.state.mode, "FLIGHT", "state is FLIGHT with the throttle open")
  fs.delete(path)
end)

T.it("DAMPED hover neutralises the nozzles and holds thrust", function()
  mock.reset()
  _G.peripheral = mock.install()
  local App = require("app")
  local path = "/test_app_config3.tbl"
  Config.save(path, baseCfg())
  local app = App.new({ configPath = path })
  app:boot()
  mock.vehicle.groundDist = 12
  app.modes.throttle = 0.5
  for _ = 1, 10 do app:cycle(0.05) end

  -- force the detector into the damping state
  local now = os.epoch("utc")
  for i = 1, 400 do
    now = now + 50
    app.osc:update("pitch", (i % 2 == 0) and 5.0 or -5.0, now)
    if app.osc:shouldDamp() then break end
  end
  T.isTrue(app.osc:shouldDamp(), "detector demands damping")
  local state = app:cycle(0.05)
  T.eq(state, "DAMPED", "entered damped hover")
  local back = app.thrusters:readback()
  T.near(back.lift_fl.targetX, 0, 1e-6, "nozzles centred")
  T.isTrue((back.lift_fl.commandedStep or 0) > 0, "thrust held, not cut")
  fs.delete(path)
end)

T.it("assigning hardware from a command creates the entry and enables the engine", function()
  mock.reset()
  _G.peripheral = mock.install()
  local App = require("app")
  local path = "/test_app_hw.tbl"
  Config.save(path, baseCfg())
  local app = App.new({ configPath = path })
  app:boot()

  -- nothing configured yet: hardware.tanks starts EMPTY, which is why these get their own
  -- commands instead of going through configSet
  T.eq(#app.cfg.hardware.tanks, 0, "no tank configured")
  T.isFalse(app.engine:available(), "and no engine relay")

  local ok = app:handleCommand({ cmd = "setEngineRelay", peripheral = "redstone_relay_0",
    side = "top" })
  T.isTrue(ok, "relay assigned")
  T.eq(app.cfg.hardware.engine.relay, "redstone_relay_0", "recorded")
  T.isTrue(app.cfg.engine.enabled, "and the engine subsystem was switched on with it")
  T.isTrue(app.engine:available(), "the engine can now act")

  local okTank = app:handleCommand({ cmd = "setTank", peripheral = "fluid_tank_0" })
  T.isTrue(okTank, "tank assigned")
  T.eq(app.cfg.hardware.tanks[1].peripheral, "fluid_tank_0", "entry created")
  T.notNil(app.cfg.hardware.tanks[1].label, "with a default label")

  local okVault = app:handleCommand({ cmd = "setVault", peripheral = "item_vault_0" })
  T.isTrue(okVault, "vault assigned")
  T.eq(app.cfg.hardware.vaults[1].peripheral, "item_vault_0", "entry created")

  -- and the gauges start reading it
  local _, aggregate = app.fuel:readAll()
  T.notNil(aggregate.worstTank, "the tank gauge now has a reading")

  fs.delete(path)
end)

T.it("unassigning hardware removes the entry again", function()
  mock.reset()
  _G.peripheral = mock.install()
  local App = require("app")
  local path = "/test_app_hw2.tbl"
  Config.save(path, baseCfg())
  local app = App.new({ configPath = path })
  app:boot()
  app:handleCommand({ cmd = "setTank", peripheral = "fluid_tank_0" })
  T.eq(#app.cfg.hardware.tanks, 1, "assigned")
  app:handleCommand({ cmd = "setTank", peripheral = "" })
  T.eq(#app.cfg.hardware.tanks, 0, "removed, so a wrong pick is undoable")
  fs.delete(path)
end)

T.it("the candidate list is published for the UI to choose from", function()
  mock.reset()
  _G.peripheral = mock.install()
  local App = require("app")
  local path = "/test_app_hw3.tbl"
  Config.save(path, baseCfg())
  local app = App.new({ configPath = path })
  app:boot()
  local candidates = app.state:get("candidates")
  T.notNil(candidates, "published at boot")
  T.containsMatch(candidates.relays, "redstone_relay_0", "the relay is offered")
  T.containsMatch(candidates.tanks, "fluid_tank_0", "the tank is offered")
  T.containsMatch(candidates.vaults, "item_vault_0", "the vault is offered")
  T.isTrue(#candidates.monitors >= 3, "and the monitors")
  fs.delete(path)
end)

return true
