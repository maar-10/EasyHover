--[[ Vehicle systems: the portable-engine master, disk config transfer, and the gauges. ]]

local T = require("tests.util")
local Config = require("lib.config")
local State = require("lib.state")
local Log = require("lib.log")
local Peripherals = require("lib.peripherals")
local Engine = require("lib.io.engine")
local Disk = require("lib.io.disk")
local Fuel = require("lib.io.fuel")

local mock = dofile("/tests/mocks/peripherals.lua")

local function quietLog() return Log.new({ level = "error", capacity = 50 }) end

local function vehicleCfg(overrides)
  local cfg = Config.withDefaults({
    hardware = {
      thrusters = {
        { id = "lift_fl", peripheral = "vector_thruster_0", group = "lift" },
      },
      engine = { relay = "redstone_relay_0", side = "top" },
      tanks = { { peripheral = "fluid_tank_0", label = "Main fuel", capacityMb = 0 } },
      vaults = { { peripheral = "item_vault_0", label = "Engine fuel", item = "" } },
    },
    engine = { enabled = true, pulseMs = 400, intervalMs = 60000 },
  })
  if overrides then cfg = require("lib.util").deepMerge(cfg, overrides) end
  return cfg
end

local function rig(cfg)
  cfg = cfg or vehicleCfg()
  local log = quietLog()
  local state = State.new({})
  local per = Peripherals.new(cfg, log):scan()
  return { cfg = cfg, log = log, state = state, per = per }
end

--- What the engine relay's output actually is right now.
local function relaySignal(side)
  local dev = peripheral.wrap("redstone_relay_0")
  return dev.getOutput(side or "top")
end

-- ---------------------------------------------------------------- engine

T.suite("engine master")

T.it("boots with the funnel BLOCKED, and the master off", function()
  mock.reset()
  _G.peripheral = mock.install()
  local r = rig()
  local engine = Engine.new(r.per, r.cfg, r.log, r.state)
  T.isTrue(engine:available(), "engine relay resolved")
  T.isFalse(engine.master, "master off at boot")
  engine:blockNow()
  -- the funnel passes items while UNPOWERED, so blocked means signal HIGH
  T.isTrue(relaySignal(), "signal HIGH: funnel blocked, nothing feeds a cold engine")
end)

T.it("turning the master ON pulses once immediately to kickstart", function()
  mock.reset()
  _G.peripheral = mock.install()
  local r = rig()
  local engine = Engine.new(r.per, r.cfg, r.log, r.state)
  engine:blockNow()
  local now = 100000
  engine:setMaster(true, now)
  T.isFalse(relaySignal(), "signal dropped: one item passes")
  T.isTrue(engine.feeding, "reported as feeding")
  T.eq(engine.pulses, 1, "exactly one pulse so far")
end)

T.it("the kickstart pulse ends after pulseMs and re-blocks", function()
  mock.reset()
  _G.peripheral = mock.install()
  local r = rig()
  local engine = Engine.new(r.per, r.cfg, r.log, r.state)
  local now = 100000
  engine:setMaster(true, now)
  engine:tick(now + 100)
  T.isFalse(relaySignal(), "still feeding part way through the pulse")
  engine:tick(now + r.cfg.engine.pulseMs + 1)
  T.isTrue(relaySignal(), "blocked again once the pulse is over")
  T.isFalse(engine.feeding, "no longer feeding")
end)

T.it("while running it re-feeds one item every intervalMs", function()
  mock.reset()
  _G.peripheral = mock.install()
  local r = rig()
  local engine = Engine.new(r.per, r.cfg, r.log, r.state)
  local now = 100000
  engine:setMaster(true, now)
  engine:tick(now + r.cfg.engine.pulseMs + 1)          -- end the kickstart
  T.eq(engine.pulses, 1, "one pulse so far")

  -- nothing happens until the interval elapses
  engine:tick(now + 2000)
  T.isTrue(relaySignal(), "still blocked mid-interval")
  T.eq(engine.pulses, 1, "no extra pulse")

  local due = now + r.cfg.engine.pulseMs + 1 + r.cfg.engine.intervalMs
  engine:tick(due + 1)
  T.isFalse(relaySignal(), "interval elapsed: feeding again")
  T.eq(engine.pulses, 2, "second pulse")
end)

T.it("turning the master OFF blocks immediately and cancels a pulse in flight", function()
  mock.reset()
  _G.peripheral = mock.install()
  local r = rig()
  local engine = Engine.new(r.per, r.cfg, r.log, r.state)
  local now = 100000
  engine:setMaster(true, now)
  T.isFalse(relaySignal(), "mid-kickstart")
  engine:setMaster(false, now + 50)
  T.isTrue(relaySignal(), "blocked at once, without waiting for the pulse to finish")
  T.isNil(engine.pulseEndsAt, "pulse cancelled")
  T.isNil(engine.nextPulseAt, "no feed scheduled")
end)

T.it("with the master off it keeps re-asserting the block", function()
  mock.reset()
  _G.peripheral = mock.install()
  local r = rig()
  local engine = Engine.new(r.per, r.cfg, r.log, r.state)
  engine:blockNow()
  -- something else moved the output; a rescan or a relay reboot would look like this
  peripheral.wrap("redstone_relay_0").setOutput("top", false)
  engine:invalidate()
  engine:tick(100000)
  T.isTrue(relaySignal(), "re-asserted, so a stray unblock cannot drain the vault")
end)

T.it("invert flips the polarity for a build wired the other way", function()
  mock.reset()
  _G.peripheral = mock.install()
  local r = rig(vehicleCfg({ engine = { invert = true } }))
  local engine = Engine.new(r.per, r.cfg, r.log, r.state)
  engine:blockNow()
  T.isFalse(relaySignal(), "blocked is now signal LOW")
  engine:setMaster(true, 100000)
  T.isTrue(relaySignal(), "and feeding is signal HIGH")
end)

T.it("kickstart can be turned off, deferring the first feed", function()
  mock.reset()
  _G.peripheral = mock.install()
  local r = rig(vehicleCfg({ engine = { kickstart = false } }))
  local engine = Engine.new(r.per, r.cfg, r.log, r.state)
  local now = 100000
  engine:setMaster(true, now)
  T.isTrue(relaySignal(), "no immediate pulse")
  T.eq(engine.pulses, 0, "nothing fed yet")
  engine:tick(now + r.cfg.engine.intervalMs + 1)
  T.isFalse(relaySignal(), "first feed once the interval elapses")
end)

T.it("feedNow primes on demand, but only while the master is on", function()
  mock.reset()
  _G.peripheral = mock.install()
  local r = rig()
  local engine = Engine.new(r.per, r.cfg, r.log, r.state)
  local ok, err = engine:feedNow(100000)
  T.isFalse(ok, "refused with the master off")
  T.isTrue(tostring(err):find("master is off") ~= nil, "and says why")
  engine:setMaster(true, 100000)
  engine:tick(100000 + 500)
  T.isTrue(engine:feedNow(100100), "allowed while running")
end)

T.it("with no relay configured it is unavailable and harmless", function()
  mock.reset()
  _G.peripheral = mock.install()
  local cfg = vehicleCfg()
  cfg.hardware.engine.relay = ""
  cfg.engine.enabled = false
  local r = rig(cfg)
  local engine = Engine.new(r.per, r.cfg, r.log, r.state)
  T.isFalse(engine:available(), "unavailable")
  engine:tick(100000)          -- must not throw
  engine:setMaster(true, 100000)
  T.isTrue(engine.master, "the switch still tracks intent for the UI")
end)

T.it("status reports what the cockpit needs", function()
  mock.reset()
  _G.peripheral = mock.install()
  local r = rig()
  local engine = Engine.new(r.per, r.cfg, r.log, r.state)
  local now = 100000
  engine:setMaster(true, now)
  engine:tick(now + r.cfg.engine.pulseMs + 1)
  local status = engine:status(now + r.cfg.engine.pulseMs + 1)
  T.isTrue(status.master, "master")
  T.isTrue(status.available, "available")
  T.notNil(status.nextFeedInMs, "countdown to the next feed")
  T.eq(status.relay, "redstone_relay_0", "relay named")
  engine:publish(now)
  T.isTrue(r.state:get("engine.master"), "published to state")
end)

T.it("config rejects a pulse longer than the interval", function()
  local cfg = vehicleCfg({ engine = { pulseMs = 9000, intervalMs = 8000 } })
  local ok, errors = Config.validate(cfg)
  T.isFalse(ok, "rejected")
  T.containsMatch(errors, "never be blocked", "explains the consequence")
end)

T.it("config rejects enabling the engine with no relay named", function()
  local cfg = vehicleCfg()
  cfg.hardware.engine.relay = ""
  local ok, errors = Config.validate(cfg)
  T.isFalse(ok, "rejected")
  T.containsMatch(errors, "names no peripheral", "error")
end)

-- ---------------------------------------------------------------- gauges

T.suite("gauges")

T.it("a fluid tank reports amount, capacity and fraction", function()
  mock.reset()
  _G.peripheral = mock.install()
  local r = rig()
  local fuel = Fuel.new(r.per, r.cfg, r.log, r.state)
  local tanks = fuel:readTanks()
  T.eq(#tanks, 1, "one tank")
  T.eq(tanks[1].label, "Main fuel", "label")
  T.eq(tanks[1].amount, 6000, "amount from tanks()")
  T.eq(tanks[1].capacity, 16000, "capacity reported by the mod")
  T.near(tanks[1].fraction, 0.375, 1e-9, "fraction")
  T.eq(tanks[1].fluid, "create:diesel", "fluid name")
end)

T.it("a tank that reports no capacity falls back to the configured size", function()
  mock.reset()
  _G.peripheral = mock.install({ devices = {
    fluid_tank_0 = { type = "fluid_storage", dev = {
      tanks = function() return { { name = "create:diesel", amount = 2500 } } end,
    } },
  } })
  local cfg = vehicleCfg()
  cfg.hardware.tanks[1].capacityMb = 10000
  local r = rig(cfg)
  local fuel = Fuel.new(r.per, r.cfg, r.log, r.state)
  local tanks = fuel:readTanks()
  T.eq(tanks[1].capacity, 10000, "configured capacity used")
  T.near(tanks[1].fraction, 0.25, 1e-9, "fraction from it")
end)

T.it("with neither capacity we report the amount and NO invented fraction", function()
  mock.reset()
  _G.peripheral = mock.install({ devices = {
    fluid_tank_0 = { type = "fluid_storage", dev = {
      tanks = function() return { { name = "create:diesel", amount = 2500 } } end,
    } },
  } })
  local r = rig()          -- capacityMb stays 0
  local fuel = Fuel.new(r.per, r.cfg, r.log, r.state)
  local tanks = fuel:readTanks()
  T.eq(tanks[1].amount, 2500, "amount still shown")
  T.isNil(tanks[1].fraction, "no made-up scale")
end)

T.it("the engine vault reports its item count", function()
  mock.reset()
  _G.peripheral = mock.install()
  local r = rig()
  local fuel = Fuel.new(r.per, r.cfg, r.log, r.state)
  local vaults = fuel:readVaults()
  T.eq(#vaults, 1, "one vault")
  T.eq(vaults[1].count, 96, "counted every stack")
  T.isFalse(vaults[1].empty, "not empty")
end)

T.it("a vault filter counts only the configured item", function()
  mock.reset()
  _G.peripheral = mock.install()
  local cfg = vehicleCfg()
  cfg.hardware.vaults[1].item = "minecraft:coal"
  local r = rig(cfg)
  local fuel = Fuel.new(r.per, r.cfg, r.log, r.state)
  local vaults = fuel:readVaults()
  T.eq(vaults[1].count, 64, "only the coal")
  T.eq(vaults[1].filter, "minecraft:coal", "filter reported")
end)

T.it("readAll aggregates the worst tank and an empty vault", function()
  mock.reset()
  _G.peripheral = mock.install({ devices = {
    item_vault_0 = { type = "inventory", dev = { list = function() return {} end } },
  } })
  local r = rig()
  local fuel = Fuel.new(r.per, r.cfg, r.log, r.state)
  local _, aggregate = fuel:readAll()
  T.near(aggregate.worstTank, 0.375, 1e-9, "worst tank fraction")
  T.eq(aggregate.worstTankLabel, "Main fuel", "and which one")
  T.isTrue(aggregate.vaultEmpty, "empty vault flagged")
  T.isTrue(r.state:get("fuel.vaultEmpty"), "published")
end)

-- ---------------------------------------------------------------- disk

T.suite("config disk")

local function diskRig()
  mock.reset()
  _G.peripheral = mock.install()
  local r = rig()
  return r, Disk.new(r.per, r.cfg, r.log, r.state)
end

local function cleanConfigs()
  for _, name in ipairs(fs.list("/")) do
    if name:match("^eh_.*%.tbl$") then fs.delete("/" .. name) end
  end
  if fs.exists("/mockdisk") then fs.delete("/mockdisk") end
  if fs.exists("/easyhover_backup") then fs.delete("/easyhover_backup") end
end

T.it("finds the drive and reports an empty one", function()
  cleanConfigs()
  local r, disk = diskRig()
  local drives = disk:drives()
  T.eq(#drives, 1, "one drive on the network")
  T.eq(drives[1].name, "drive_0", "named")
  T.isTrue(drives[1].present, "the mock has a disk in it")
  T.eq(drives[1].count, 0, "no configs on it yet")
end)

T.it("saves every eh_*.tbl and verifies the readback", function()
  cleanConfigs()
  local r, disk = diskRig()
  local f = fs.open("/eh_flight_config.tbl", "w")
  f.write(textutils.serialise({ tuning = { attitudeHz = 13 } }))
  f.close()
  local f2 = fs.open("/eh_nav_config.tbl", "w")
  f2.write(textutils.serialise({ nav = { fixStaleMs = 999 } }))
  f2.close()

  local ok, report = disk:saveAll()
  T.isTrue(ok, "saved: " .. tostring(report.reason))
  T.eq(#report.saved, 2, "both configs, not just this role's")
  T.eq(#report.failed, 0, "none failed")
  T.eq(#Disk.diskConfigs(report.mount), 2, "present on the disk")
  cleanConfigs()
end)

T.it("refuses to save when the computer has no configs", function()
  cleanConfigs()
  local r, disk = diskRig()
  local ok, report = disk:saveAll()
  T.isFalse(ok, "refused")
  T.isTrue(tostring(report.reason):find("no config files") ~= nil, "and says why")
end)

T.it("loading backs up what it overwrites", function()
  cleanConfigs()
  local r, disk = diskRig()
  local f = fs.open("/eh_flight_config.tbl", "w")
  f.write(textutils.serialise({ tuning = { attitudeHz = 13 } }))
  f.close()
  disk:saveAll()

  -- change the live config, then load the disk copy back over it
  local f2 = fs.open("/eh_flight_config.tbl", "w")
  f2.write(textutils.serialise({ tuning = { attitudeHz = 99 } }))
  f2.close()

  local ok, report = disk:loadAll()
  T.isTrue(ok, "loaded")
  T.eq(#report.loaded, 1, "one config")
  T.eq(#report.backedUp, 1, "the version it replaced was backed up")
  T.notNil(report.backupDir, "backup directory reported")

  local body = fs.open("/eh_flight_config.tbl", "r")
  local restored = textutils.unserialise(body.readAll())
  body.close()
  T.eq(restored.tuning.attitudeHz, 13, "the disk version is now live")

  local kept = fs.open(report.backupDir .. "/eh_flight_config.tbl", "r")
  local backedUp = textutils.unserialise(kept.readAll())
  kept.close()
  T.eq(backedUp.tuning.attitudeHz, 99, "and the overwritten one is recoverable")
  cleanConfigs()
end)

T.it("REFUSES a config on the disk that does not parse", function()
  cleanConfigs()
  local r, disk = diskRig()
  local drive = disk:firstReady()
  local dir = fs.combine(drive.mount, "easyhover")
  fs.makeDir(dir)
  local f = fs.open(fs.combine(dir, "eh_flight_config.tbl"), "w")
  f.write("this is not a table {{{")
  f.close()

  local ok, report = disk:loadAll()
  T.isFalse(ok, "refused")
  T.eq(#report.loaded, 0, "nothing installed")
  T.eq(report.refused[1].reason, "does not parse", "reason given")
  T.isFalse(fs.exists("/eh_flight_config.tbl"), "the live config was left alone")
  cleanConfigs()
end)

T.it("reports honestly when there is no disk", function()
  cleanConfigs()
  mock.reset()
  _G.peripheral = mock.install({ devices = {
    drive_0 = { type = "drive", dev = {
      isDiskPresent = function() return false end,
      hasData = function() return false end,
      getDiskLabel = function() return nil end,
      getMountPath = function() return nil end,
    } },
  } })
  local r = rig()
  local disk = Disk.new(r.per, r.cfg, r.log, r.state)
  T.isNil(disk:firstReady(), "no ready drive")
  local ok, report = disk:saveAll()
  T.isFalse(ok, "save refused")
  T.isTrue(tostring(report.reason):find("no disk") ~= nil, "reason")
  local status = disk:status()
  T.eq(status.driveCount, 1, "the drive is still seen")
  T.isFalse(status.diskPresent, "but no disk in it")
end)

T.it("status summarises for the UI", function()
  cleanConfigs()
  local r, disk = diskRig()
  local f = fs.open("/eh_flight_config.tbl", "w")
  f.write(textutils.serialise({ tuning = { attitudeHz = 13 } }))
  f.close()
  disk:saveAll()
  local status = disk:status()
  T.isTrue(status.diskPresent, "disk present")
  T.eq(status.onDisk, 1, "one config on the disk")
  T.eq(status.localConfigs, 1, "one config here")
  T.isTrue(r.state:get("disk.diskPresent"), "published to state")
  cleanConfigs()
end)

-- ---------------------------------------------------------------- slots

T.suite("slot assignment")

local App = require("app")

--- A booted flight computer with the config on a scratch path, so handleCommand can save.
local function appRig(overrides)
  mock.reset()
  _G.peripheral = mock.install()
  local path = "/test_slot_cfg.tbl"
  Config.save(path, vehicleCfg(overrides))
  local app = App.new({ configPath = path })
  app:boot()
  return app, path
end

T.it("RESOLVES an old group-prefixed id to the slot the screens address", function()
  -- An existing craft has ids like "lift_fl"; the config screens address "fl". Without this the
  -- LIFT page would read "0 of 4 set" with four thrusters assigned. Renaming the id was the
  -- wrong fix: the mixer addresses thrusters BY ID, so a rename reaches far past a display bug.
  T.eq(Config.slotKey({ id = "lift_fl", group = "lift" }), "fl", "the group prefix resolves away")
  T.eq(Config.slotKey({ id = "lateral_rr", group = "lateral" }), "rr", "for every group")
  T.eq(Config.slotKey({ id = "fr", group = "lift" }), "fr", "a new-style id is already the key")
  T.eq(Config.slotKey({ id = "lifter", group = "lift" }), "lifter",
    "and only a group_ PREFIX resolves, not a coincidental start")
end)

T.it("the id on disk is NOT rewritten -- the mixer still addresses what it always did", function()
  local cfg = Config.withDefaults({
    hardware = { thrusters = {
      { id = "lift_fl", peripheral = "vector_thruster_0", group = "lift" },
    } },
  })
  T.eq(cfg.hardware.thrusters[1].id, "lift_fl", "left exactly as written")
end)

T.it("reassigning an old-style slot REPLACES it instead of duplicating the thruster", function()
  local app, path = appRig({ hardware = { thrusters = {
    { id = "lift_fl", peripheral = "vector_thruster_0", group = "lift" },
  } } })
  T.isTrue((app:handleCommand({ cmd = "setSlot", kind = "lift", key = "fl",
    peripheral = "vector_thruster_3" })), "accepted")
  local count = 0
  for _, t in ipairs(app.cfg.hardware.thrusters) do
    if t.group == "lift" and Config.slotKey(t) == "fl" then count = count + 1 end
  end
  T.eq(count, 1, "one entry for the slot, not two -- the mixer must not command it twice")
  fs.delete(path)
end)

T.it("assigns a lift thruster to a named corner, with a real moment arm", function()
  local app, path = appRig()
  local ok = app:handleCommand({ cmd = "setSlot", kind = "lift", key = "fr", peripheral = "vector_thruster_1" })
  T.isTrue(ok, "accepted")

  local entry
  for _, t in ipairs(app.cfg.hardware.thrusters) do
    if t.group == "lift" and Config.slotKey(t) == "fr" then entry = t end
  end
  T.notNil(entry, "the slot was created")
  T.eq(entry.id, "lift_fr", "stored with a group-qualified id, unique across the craft")
  T.eq(entry.peripheral, "vector_thruster_1", "peripheral")
  T.eq(entry.group, "lift", "group")
  T.eq(entry.thrustAxis, "down", "lift thrust points down")
  -- The signs are the whole point: front-right must be +x, +z or the mixer rolls the wrong way.
  T.isTrue(entry.pos.x > 0, "front RIGHT is +x, got " .. tostring(entry.pos.x))
  T.isTrue(entry.pos.z > 0, "FRONT right is +z, got " .. tostring(entry.pos.z))
  fs.delete(path)
end)

T.it("gives the four lift corners opposing arms, so pitch and roll both work", function()
  local app, path = appRig()
  for _, key in ipairs({ "fl", "fr", "rl", "rr" }) do
    app:handleCommand({ cmd = "setSlot", kind = "lift", key = key,
      peripheral = "vector_thruster_" .. ({ fl = 0, fr = 1, rl = 2, rr = 3 })[key] })
  end
  local pos = {}
  for _, t in ipairs(app.cfg.hardware.thrusters) do pos[Config.slotKey(t)] = t.pos end
  T.isTrue(pos.fl.x < 0 and pos.fr.x > 0, "left and right are on opposite sides -> roll")
  T.isTrue(pos.fl.z > 0 and pos.rl.z < 0, "front and rear are opposed -> pitch")
  fs.delete(path)
end)

T.it("makes the lateral FRONT pair steer and the REAR pair precision-only", function()
  local app, path = appRig()
  app:handleCommand({ cmd = "setSlot", kind = "lateral", key = "fl", peripheral = "vector_thruster_1" })
  app:handleCommand({ cmd = "setSlot", kind = "lateral", key = "rr", peripheral = "vector_thruster_2" })
  local byId = {}
  for _, t in ipairs(app.cfg.hardware.thrusters) do byId[Config.slotKey(t)] = t end
  T.isTrue(byId.fl.yawAuthority, "the front pair yaws")
  T.isFalse(byId.fl.precisionOnly, "and is used in normal flight")
  T.isTrue(byId.rr.precisionOnly, "the rear pair is precision/assistant only")
  T.isFalse(byId.rr.yawAuthority, "and does not yaw")
  fs.delete(path)
end)

T.it("REPLACES a slot rather than accumulating duplicates", function()
  local app, path = appRig()
  app:handleCommand({ cmd = "setSlot", kind = "lift", key = "fr", peripheral = "vector_thruster_1" })
  app:handleCommand({ cmd = "setSlot", kind = "lift", key = "fr", peripheral = "vector_thruster_2" })
  local count, found = 0, nil
  for _, t in ipairs(app.cfg.hardware.thrusters) do
    if t.group == "lift" and Config.slotKey(t) == "fr" then
      count = count + 1; found = t.peripheral
    end
  end
  T.eq(count, 1, "one entry for the slot")
  T.eq(found, "vector_thruster_2", "holding the latest choice")
  fs.delete(path)
end)

T.it("an empty peripheral clears the slot", function()
  local app, path = appRig()
  app:handleCommand({ cmd = "setSlot", kind = "lift", key = "fr", peripheral = "vector_thruster_1" })
  app:handleCommand({ cmd = "setSlot", kind = "lift", key = "fr", peripheral = "" })
  for _, t in ipairs(app.cfg.hardware.thrusters) do
    T.isFalse(t.group == "lift" and Config.slotKey(t) == "fr", "the slot is gone")
  end
  fs.delete(path)
end)

T.it("THE SAME CORNER IN TWO GROUPS DOES NOT COLLIDE", function()
  -- Reported from the cockpit: with the lift corners assigned, assigning ANY lateral thruster
  -- came back CRAFT REFUSED. Slot keys are unique only within a group -- "fl" is a corner of
  -- the lift set and of the lateral set -- but ids are what the mixer addresses thrusters by,
  -- and the validator rightly requires those to be unique across the whole craft.
  local app, path = appRig({ hardware = { thrusters = {} } })
  for _, key in ipairs({ "fl", "fr", "rl", "rr" }) do
    T.isTrue((app:handleCommand({ cmd = "setSlot", kind = "lift", key = key,
      peripheral = "vector_thruster_" .. ({ fl = 0, fr = 1, rl = 2, rr = 3 })[key] })),
      "lift " .. key)
  end
  local ok, detail = app:handleCommand({ cmd = "setSlot", kind = "lateral", key = "fl",
    peripheral = "vector_thruster_4" })
  T.isTrue(ok, "lateral fl accepted: " .. table.concat((detail or {}).errors or {}, "; "))
  T.eq(#app.cfg.hardware.thrusters, 5, "five thrusters, no collision")

  local ids = {}
  for _, t in ipairs(app.cfg.hardware.thrusters) do
    T.isNil(ids[t.id], "id " .. t.id .. " is unique across the craft")
    ids[t.id] = true
  end
  T.isTrue(ids["lift_fl"] and ids["lateral_fl"], "the same corner in two groups coexists")
  fs.delete(path)
end)

T.it("assigning a thruster ALREADY IN ANOTHER SLOT moves it rather than doubling it", function()
  -- The cockpit had one nozzle wired into two slots under two ids. The mixer would command it
  -- twice with different values and fight itself, so the assignment has to be a move.
  local app, path = appRig({ hardware = { thrusters = {} } })
  -- Two lift thrusters, so moving one out does not empty the group -- the craft rightly
  -- refuses a config with no lift at all, which is a different rule.
  app:handleCommand({ cmd = "setSlot", kind = "lift", key = "fl", peripheral = "vector_thruster_0" })
  app:handleCommand({ cmd = "setSlot", kind = "lift", key = "fr", peripheral = "vector_thruster_1" })
  T.isTrue((app:handleCommand({ cmd = "setSlot", kind = "lateral", key = "rr",
    peripheral = "vector_thruster_0" })), "accepted")

  local uses, group = 0, nil
  for _, t in ipairs(app.cfg.hardware.thrusters) do
    if t.peripheral == "vector_thruster_0" then uses = uses + 1; group = t.group end
  end
  T.eq(uses, 1, "the nozzle is in exactly one slot")
  T.eq(group, "lateral", "the newest assignment is the one kept")
  fs.delete(path)
end)

T.it("a config with one nozzle in two slots is REFUSED, as a backstop", function()
  local cfg = Config.withDefaults({ hardware = { thrusters = {
    { id = "lift_fl", peripheral = "vector_thruster_0", group = "lift" },
    { id = "lateral_rr", peripheral = "vector_thruster_0", group = "lateral" },
  } } })
  local ok, errors = Config.validate(cfg)
  T.isFalse(ok, "refused")
  T.containsMatch(errors, "already assigned", "and says which: " .. table.concat(errors, "; "))
end)

T.it("assigns velocity axes, the altimeter, the gimbal and a laser direction", function()
  local app, path = appRig()
  T.isTrue((app:handleCommand({ cmd = "setSlot", kind = "velocity", key = "z",
    peripheral = "velocity_sensor_0" })), "velocity z")
  T.isTrue((app:handleCommand({ cmd = "setSlot", kind = "altitude", key = "sensor",
    peripheral = "altitude_sensor_0" })), "altimeter")
  T.isTrue((app:handleCommand({ cmd = "setSlot", kind = "gimbal", key = "sensor",
    peripheral = "gimbal_sensor_0" })), "gimbal")
  T.isTrue((app:handleCommand({ cmd = "setSlot", kind = "optical", key = "forward",
    peripheral = "optical_sensor_0" })), "forward laser")

  T.eq(app.cfg.hardware.sensors.velocityVector[1].axis, "z", "axis recorded")
  T.eq(app.cfg.hardware.sensors.altitude, "altitude_sensor_0", "altimeter recorded")
  T.eq(app.cfg.hardware.sensors.gimbal, "gimbal_sensor_0", "gimbal recorded")
  T.eq(app.cfg.hardware.sensors.optical[1].direction, "forward", "direction recorded")
  fs.delete(path)
end)

T.it("A NEW THRUSTER REACHES THE MIXER WITHOUT A REBOOT", function()
  -- The cockpit report that found this: configure the craft from the UI, and nothing takes
  -- effect until the flight computer is restarted. A rescan alone was not enough -- the mixer
  -- builds its matrix once and the layout is published from boot().
  local app, path = appRig({ hardware = { thrusters = {
    { id = "fl", peripheral = "vector_thruster_0", group = "lift" },
  } } })
  T.eq(app.mixer:capabilities().lift, 1, "one lift thruster to begin with")

  app:handleCommand({ cmd = "setSlot", kind = "lift", key = "fr", peripheral = "vector_thruster_1" })
  T.eq(app.mixer:capabilities().lift, 2, "the mixer knows about the new one IMMEDIATELY")
  T.eq((app.state:get("layout") or {}).lift, 2, "and the published layout agrees")
  fs.delete(path)
end)

T.it("removing a thruster leaves the mixer without it, immediately", function()
  local app, path = appRig({ hardware = { thrusters = {
    { id = "fl", peripheral = "vector_thruster_0", group = "lift" },
    { id = "fr", peripheral = "vector_thruster_1", group = "lift" },
  } } })
  T.eq(app.mixer:capabilities().lift, 2, "two to begin with")
  app:handleCommand({ cmd = "setSlot", kind = "lift", key = "fr", peripheral = "" })
  T.eq(app.mixer:capabilities().lift, 1, "and one after clearing the slot")
  fs.delete(path)
end)

T.it("a velocity sensor assigned from the UI updates the reported capability", function()
  -- Drift damping and the brake law both key off this, and it was published only at boot.
  local app, path = appRig()
  app:handleCommand({ cmd = "setSlot", kind = "velocity", key = "x", peripheral = "velocity_sensor_0" })
  app:handleCommand({ cmd = "setSlot", kind = "velocity", key = "z", peripheral = "velocity_sensor_1" })
  T.eq(app.state:get("velocity.capability"), "vector",
    "a full horizontal vector is recognised without a restart")
  fs.delete(path)
end)

T.it("REFUSES a slot that does not exist rather than inventing one", function()
  local app, path = appRig()
  T.isFalse((app:handleCommand({ cmd = "setSlot", kind = "lift", key = "middle",
    peripheral = "vector_thruster_1" })), "no such lift corner")
  T.isFalse((app:handleCommand({ cmd = "setSlot", kind = "velocity", key = "w",
    peripheral = "velocity_sensor_0" })), "no such axis")
  fs.delete(path)
end)

T.it("PUTS THE OLD ASSIGNMENT BACK when the result would not validate", function()
  local app, path = appRig()
  app:handleCommand({ cmd = "setSlot", kind = "optical", key = "forward", peripheral = "optical_sensor_0" })
  local before = #app.cfg.hardware.sensors.optical
  -- a second sensor on the same direction is illegal
  local ok = app:handleCommand({ cmd = "setSlot", kind = "optical", key = "sideways",
    peripheral = "optical_sensor_1" })
  T.isFalse(ok, "refused")
  T.eq(#app.cfg.hardware.sensors.optical, before, "and nothing was left behind")
  T.eq(app.cfg.hardware.sensors.optical[1].peripheral, "optical_sensor_0", "original intact")
  fs.delete(path)
end)

-- ------------------------------------------------------------ keybinds

T.suite("typewriter rebinding")

T.it("A REBIND TAKES EFFECT WITHOUT A REBOOT", function()
  -- Bindings resolve key NAMES to codes once, at construction. If a remap did not re-resolve,
  -- the config screen would write the file and the control would keep answering the old key --
  -- the same trap the mixer had.
  local app, path = appRig()
  local before = app.pilot.bindings.actionToKey.brake
  T.eq(before, keys.b, "brake starts on B")

  local ok = app:handleCommand({ cmd = "configSet",
    path = "input.typewriter.bindings.brake", value = "x" })
  T.isTrue(ok, "accepted")
  T.eq(app.pilot.bindings.actionToKey.brake, keys.x, "and the LIVE binding moved")
  T.isNil(app.pilot.bindings.keyToAction[keys.b], "the old key no longer triggers brake")
  fs.delete(path)
end)

T.it("A CONFLICT DISABLES THE SAME ACTION EVERY TIME, not an arbitrary one", function()
  -- When two actions share a key the first resolved keeps it and the second gets nothing. With
  -- pairs() iteration that was a coin flip -- a duplicate binding disabled an arbitrary control,
  -- and a different one on each boot. The order is now fixed, so a conflict is reproducible.
  local app, path = appRig()
  local victims = {}
  for _ = 1, 8 do
    app:handleCommand({ cmd = "configSet",
      path = "input.typewriter.bindings.brake", value = "space" })   -- climb already has space
    local losers = {}
    for _, action in ipairs({ "brake", "climb" }) do
      if app.pilot.bindings.actionToKey[action] == nil then losers[#losers + 1] = action end
    end
    victims[table.concat(losers, ",")] = true
    -- put it back and re-resolve, so each pass starts from the same place
    app:handleCommand({ cmd = "configSet",
      path = "input.typewriter.bindings.brake", value = "b" })
  end
  local outcomes = 0
  for _ in pairs(victims) do outcomes = outcomes + 1 end
  T.eq(outcomes, 1, "one outcome across eight resolutions, not two")
  T.isTrue(victims["brake"], "and it is the LATER action that loses, every time")
  fs.delete(path)
end)

T.it("the action order is fixed and covers every bound action", function()
  local app, path = appRig()
  local order = app.pilot.bindings:actionOrder()
  T.eq(order[1], "pitchUp", "axes first, as declared")
  local seen = {}
  for _, name in ipairs(order) do
    T.isNil(seen[name], name .. " appears once")
    seen[name] = true
  end
  for action in pairs(app.cfg.input.typewriter.bindings) do
    T.isTrue(seen[action], action .. " is in the order")
  end
  fs.delete(path)
end)

T.it("REFUSES a key name that does not exist", function()
  -- A typo would otherwise become a control that silently does nothing.
  local app, path = appRig()
  local ok, detail = app:handleCommand({ cmd = "configSet",
    path = "input.typewriter.bindings.brake", value = "bananas" })
  T.isFalse(ok, "refused")
  T.containsMatch((detail or {}).errors or {}, "is not a key name", "and says why")
  T.eq(app.pilot.bindings.actionToKey.brake, keys.b, "the old binding stands")
  fs.delete(path)
end)

T.it("the whole binding map is published so the config screen can show it", function()
  local app, path = appRig()
  local published = app.telemetry:build().config.typewriterBindings
  T.notNil(published, "reported")
  T.eq(published.brake, "b", "with each action's key name")
  T.eq(published.climb, "space", "including the ones with long names")
  fs.delete(path)
end)


return true
