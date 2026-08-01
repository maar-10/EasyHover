--[[ Vehicle systems: the portable-engine master, disk config transfer, and the gauges. ]]

local T = require("tests.util")
local Config = require("lib.config")
local State = require("lib.state")
local Log = require("lib.log")
local Peripherals = require("lib.peripherals")
local Engine = require("lib.io.engine")
local Disk = require("lib.io.disk")
local Fuel = require("lib.io.fuel")
local Thrusters = require("lib.io.thrusters")
local SelfTest = require("lib.control.selftest")

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

T.it("takes a SECOND lift booster at a corner, with that corner's moment arm", function()
  -- The reason they exist: if four nozzles cannot lift the craft, the fix is more nozzles. A
  -- booster keyed "xfl" doubles the FRONT-LEFT -- same geometry -- so the pilot who bolts a spare
  -- there gets more lift AND more roll/pitch authority, and the screen can label it by position.
  local app, path = appRig({ hardware = { thrusters = {} } })
  for _, key in ipairs({ "fl", "fr", "rl", "rr" }) do
    app:handleCommand({ cmd = "setSlot", kind = "lift", key = key,
      peripheral = "vector_thruster_" .. ({ fl = 0, fr = 1, rl = 2, rr = 3 })[key] })
  end
  T.isTrue((app:handleCommand({ cmd = "setSlot", kind = "lift", key = "xfl",
    peripheral = "vector_thruster_4" })), "a fifth lift thruster is accepted")

  local extra, primary
  for _, t in ipairs(app.cfg.hardware.thrusters) do
    if Config.slotKey(t) == "xfl" then extra = t end
    if Config.slotKey(t) == "fl" then primary = t end
  end
  T.notNil(extra, "the booster slot was created")
  T.eq(extra.id, "lift_xfl", "group-qualified id, unique across the craft")
  T.eq(extra.group, "lift", "still a lift thruster")
  T.eq(extra.thrustAxis, "down", "faces down like the corner")
  T.eq(extra.pos.x, primary.pos.x, "same x arm as the front-left it doubles")
  T.eq(extra.pos.z, primary.pos.z, "same z arm -> shares the front-left's pitch/roll authority")
  T.eq(#app.cfg.hardware.thrusters, 5, "four corners plus one booster")
  fs.delete(path)
end)

T.it("a corner booster shares its corner's mixer geometry, so attitude scales", function()
  local app, path = appRig({ hardware = { thrusters = {} } })
  app:handleCommand({ cmd = "setSlot", kind = "lift", key = "fl", peripheral = "vector_thruster_0" })
  app:handleCommand({ cmd = "setSlot", kind = "lift", key = "xfl", peripheral = "vector_thruster_1" })
  local primary, booster
  for _, item in ipairs(app.mixer:ensureLayout().lift) do
    if item.id == "lift_fl" then primary = item end
    if item.id == "lift_xfl" then booster = item end
  end
  T.notNil(booster, "the booster is in the mixer's lift group")
  T.eq(booster.sx, primary.sx, "same roll sign as the front-left")
  T.eq(booster.sz, primary.sz, "same pitch sign as the front-left")
  fs.delete(path)
end)

T.it("refuses an extra booster slot the flight side does not recognise", function()
  local app, path = appRig({ hardware = { thrusters = {} } })
  app:handleCommand({ cmd = "setSlot", kind = "lift", key = "fl", peripheral = "vector_thruster_0" })
  local ok, detail = app:handleCommand({ cmd = "setSlot", kind = "lift", key = "xzz",
    peripheral = "vector_thruster_1" })
  T.isFalse(ok, "an unknown booster key is refused")
  T.containsMatch((detail or {}).errors or {}, "unknown lift slot",
    "and says so: " .. table.concat((detail or {}).errors or {}, "; "))
  fs.delete(path)
end)

T.it("also takes a second LATERAL corner and extra MAIN accelerators", function()
  local app, path = appRig({ hardware = { thrusters = {} } })
  app:handleCommand({ cmd = "setSlot", kind = "lift", key = "fl", peripheral = "vector_thruster_0" })
  -- Main has no corners, so its extras are just numbered further (x1 -> M5).
  T.isTrue((app:handleCommand({ cmd = "setSlot", kind = "main", key = "x1",
    peripheral = "vector_thruster_1" })), "extra main accepted")
  -- A second front-left lateral mirrors the primary front-left: it steers.
  T.isTrue((app:handleCommand({ cmd = "setSlot", kind = "lateral", key = "xfl",
    peripheral = "vector_thruster_2" })), "extra lateral accepted")
  local byId = {}
  for _, t in ipairs(app.cfg.hardware.thrusters) do byId[t.id] = t end
  T.eq(byId["main_x1"].thrustAxis, "back", "an extra accelerator still faces back")
  T.eq(byId["lateral_xfl"].thrustAxis, "right", "a second front-left lateral keeps its facing")
  T.isTrue(byId["lateral_xfl"].yawAuthority, "and steers, exactly like the front-left it doubles")
  T.isFalse(byId["lateral_xfl"].precisionOnly, "so it is used in normal flight, not just precision")
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
  local published = app.telemetry:build(nil, true).config.typewriterBindings
  T.notNil(published, "reported")
  T.eq(published.brake, "b", "with each action's key name")
  T.eq(published.climb, "space", "including the ones with long names")
  fs.delete(path)
end)



-- ---------------------------------------------------------------- self test

T.suite("flight control self test")

--- The mock offers vector_thruster_0..3 plus a solid_fuel and an ion thruster, so the layout
--- here is what those can actually express: three lift, one lateral, and one main WITHOUT a
--- nozzle -- which is also the realistic case for an accelerator.
local function fullCraft()
  return { hardware = { thrusters = {
    { id = "lift_fl", peripheral = "vector_thruster_0", group = "lift" },
    { id = "lift_fr", peripheral = "vector_thruster_1", group = "lift" },
    { id = "lift_rl", peripheral = "vector_thruster_2", group = "lift" },
    { id = "lateral_fl", peripheral = "vector_thruster_3", group = "lateral",
      yawAuthority = true, thrustAxis = "right" },
    { id = "main_1", peripheral = "solid_fuel_thruster_0", group = "main", thrustAxis = "back" },
  } } }
end

--- THE "NO THRUSTERS" BUG on the AXIS MAP and THR AXES screens. thrusterAxes was only ever
--- published on a remap, inside rebuildHardware, or in setAxes -- never on a plain boot. So a
--- craft started with a saved config sent nil for it, and both screens read "no thrusters
--- assigned" while the thrusters were assigned, listed and swept correctly everywhere else.
T.it("publishes the thruster axis map at boot", function()
  local app, path = appRig(fullCraft())     -- appRig boots
  local axes = app.state:get("thrusterAxes")
  T.notNil(axes, "thrusterAxes is set at boot, not only after a remap")
  T.eq(#axes, #app.cfg.hardware.thrusters, "one entry per configured thruster")
  T.notNil(axes[1].id, "each entry names its thruster")
  T.notNil(axes[1].key, "and its slot key, which the screen shows")

  -- and it must ride in the slow telemetry frame the screens actually read
  local payload = app.telemetry:build(nil, true)
  T.notNil(payload.thrusterAxes, "carried in the slow telemetry")
  T.eq(#payload.thrusterAxes, #axes, "all of them")
  fs.delete(path)
end)

T.it("REFUSES to run on a craft that is flying under power", function()
  local app, path = appRig(fullCraft())
  app.state:set("measured", { groundContact = false })
  app.engine.master = true
  app.per.thrusters["lift_fl"].dev.getCurrentThrustKN = function() return 40.0 end
  local ok, detail = app:handleCommand({ cmd = "selfTest", action = "start" })
  T.isFalse(ok, "refused in the air with the engine running")
  T.isTrue(tostring((detail or {}).error):find("flying") ~= nil,
    "and says why: " .. tostring((detail or {}).error))
  fs.delete(path)
end)

--- THE TRAP THIS GUARD FELL INTO TWICE. What makes silencing the throttles unsafe is the craft
--- being HELD UP BY THRUST, and the flight MODE is not a usable proxy for that: with no ground
--- sensor and no altitude sensor the mode machine settles on BRAKE. Gating on the mode therefore
--- produced a refusal the pilot could not satisfy from either end -- no laser means the mode never
--- reads GROUND, and the thrust is this computer's own command.
T.it("a craft with NO ground sensor is not assumed airborne", function()
  local app, path = appRig(fullCraft())
  app.engine.master = false
  for _ = 1, 20 do app:cycle(0.05) end
  -- exactly the state a craft being wired up for the first time sits in
  T.eq((app.state:get("measured") or {}).groundContact, nil, "no laser, so no ground reading")
  T.isFalse(app:knownAirborne(), "absence of a sensor is not evidence of being airborne")
  T.isTrue((app:handleCommand({ cmd = "selfTest", action = "start" })),
    "and the sweep runs, whatever the mode machine settled on (" .. tostring(app.state.mode) .. ")")
  fs.delete(path)
end)

T.it("a laser POSITIVELY reporting no ground contact does block it, with thrust", function()
  local app, path = appRig(fullCraft())
  app.engine.master = false
  app.state:set("measured", { groundContact = false })
  app.per.thrusters["lift_fl"].dev.getCurrentThrustKN = function() return 40.0 end
  local ok, detail = app:handleCommand({ cmd = "selfTest", action = "start" })
  T.isFalse(ok, "refused on real evidence")
  T.isTrue(tostring((detail or {}).error):find("flying") ~= nil,
    "and says why: " .. tostring((detail or {}).error))
  fs.delete(path)
end)

T.it("airborne with NO thrust is allowed -- nothing can be held up by nothing", function()
  local app, path = appRig(fullCraft())
  app.engine.master = false
  app.state:set("measured", { groundContact = false })
  for _, entry in ipairs(app.per:thrusterList()) do
    if entry.dev.__setFuelled then entry.dev.__setFuelled(false) end
  end
  local ok, detail = app:handleCommand({ cmd = "selfTest", action = "start" })
  T.isTrue(ok, "permitted: " .. tostring((detail or {}).error))
  fs.delete(path)
end)

T.it("but ALLOWS it with the engine off, whatever the ground sensor believes", function()
  -- GROUND depends on a down-facing laser being assigned. Requiring it would deny the
  -- pre-flight test to exactly the half-configured craft that most needs it -- and a craft
  -- whose thrusters produce nothing is not holding itself up regardless.
  local app, path = appRig(fullCraft())
  app.state:set("measured", { groundContact = false })
  app.engine.master = false
  for _, entry in ipairs(app.per:thrusterList()) do
    if entry.dev.__setFuelled then entry.dev.__setFuelled(false) end
  end
  T.isTrue((app:handleCommand({ cmd = "selfTest", action = "start" })), "permitted")
  fs.delete(path)
end)

--- The pilot's premise, stated plainly: neither the engine nor the thrusters may be active. This
--- used to be allowed -- `GROUND or engine off` passed a craft parked with the engine RUNNING so
--- long as no thruster happened to read thrust at the instant the button was pressed.
T.it("refuses on the ground while the engine is RUNNING, even with nothing firing", function()
  local app, path = appRig(fullCraft())
  app.state.mode = "GROUND"
  app.engine.master = true
  for _, entry in pairs(app.per.thrusters) do
    entry.dev.getPower = function() return 0 end     -- idle: the old gate let this through
  end
  local ok, detail = app:handleCommand({ cmd = "selfTest", action = "start" })
  T.isFalse(ok, "refused: a running engine can put thrust on a nozzle a tick later")
  T.isTrue(tostring((detail or {}).error):find("engine") ~= nil,
    "and says why: " .. tostring((detail or {}).error))
  fs.delete(path)
end)

--- Thrust on a PARKED craft does not refuse the sweep: the throttle behind it is almost always
--- this computer's own, and the sweep retracts it with allStop. Thrust that SURVIVES that is being
--- fed by something else, and only then does the run abort -- with a message naming fuel rather
--- than an engine switch that does not control the tank.
T.it("aborts if thrust OUTLIVES the throttles it zeroed, and blames fuel not the engine", function()
  local app, path = appRig(fullCraft())
  app.state.mode = "GROUND"
  app.engine.master = false
  T.isTrue((app:handleCommand({ cmd = "selfTest", action = "start" })), "started")

  -- something keeps feeding it, whatever we commanded
  app.per.thrusters["lift_fl"].dev.getCurrentThrustKN = function() return 12.0 end

  local started = app.selfTest.run.startedAt
  -- 1500 ms, NOT 500: the thrust check only runs once a second, so a tick at 500 ms proves
  -- nothing about the settle window -- it would be skipped either way. This has to land after the
  -- 1 Hz gate but before the settle deadline, or the test passes with the settle deleted.
  app.selfTest:tick(started + 1500)
  T.isTrue(app.selfTest:isRunning(), "not judged during the settle window -- thrust has to fade")

  app.selfTest:tick(started + 4000)
  T.isFalse(app.selfTest:isRunning(), "aborted once the reading outlived the settle")
  local st = app.state:get("selfTest")
  T.isTrue(tostring(st.aborted):find("fuel") ~= nil, "blames fuel: " .. tostring(st.aborted))
  T.eq(st.abortedShort, "STILL FUELLED", "and has a 15-column form")
  fs.delete(path)
end)

T.it("does NOT abort for thrust that fades once the throttles are zeroed", function()
  local app, path = appRig(fullCraft())
  app.state.mode = "GROUND"
  app.engine.master = false
  for _ = 1, 10 do app:cycle(0.05) end       -- the mixer commands lift, as it always does
  T.isTrue((app:handleCommand({ cmd = "selfTest", action = "start" })), "started")
  local started = app.selfTest.run.startedAt
  for at = 0, 8000, 250 do app.selfTest:tick(started + at) end
  T.isTrue(app.selfTest:isRunning(), "still sweeping: allStop really did silence them")
  fs.delete(path)
end)

--- The self test is a GROUND, ENGINE-OFF procedure, which is exactly the disarmed state. It must
--- be permitted there. (This used to also assert that the mixer was holding a throttle with the
--- engine off -- the old bug -- which the disarm removes: a disarmed controller does not steer,
--- so there is no stray throttle to command in the first place.)
T.it("ALLOWS the sweep on a parked, disarmed craft", function()
  local app, path = appRig(fullCraft())
  app.engine.master = false         -- disarmed
  app.state.mode = "GROUND"
  for _, entry in ipairs(app.per:thrusterList()) do
    if entry.dev.__setFuelled then entry.dev.__setFuelled(false) end
  end
  for _ = 1, 10 do app:cycle(0.05) end
  T.eq(app.per.thrusters["lift_fl"].dev.getCurrentThrustKN(), 0, "nothing is firing")

  local ok, detail = app:handleCommand({ cmd = "selfTest", action = "start" })
  T.isTrue(ok, "permitted: " .. tostring((detail or {}).error))
  fs.delete(path)
end)

--- THE ENGINE-ON-IS-NOT-FLYING RULE. Starting the pump so the thrusters CAN fire must not, on its
--- own, hand the craft to the mixer -- the PID would then steer a parked craft and fire thrusters on
--- the pad with no takeoff ever commanded. The craft stays DISARMED until it is positively airborne
--- or the pilot gives a climb input.
local function noPilotInput(app)
  -- The test rig's mock controller feeds a live oscillating stick, so silence the pilot to isolate
  -- the arming logic: nobody is touching the controls.
  app.pilot.read = function() return { pitch = 0, roll = 0, yaw = 0, climb = 0, accel = 0 }, {}, {} end
end

T.it("engine ON but landed and hands-off stays DISARMED -- nothing fires on the pad", function()
  local app, path = appRig(fullCraft())
  noPilotInput(app)
  mock.vehicle.groundDist = 1.0             -- landed: ~1 block under the down laser
  app.engine.master = true                  -- engine started (pump running) -- NOT a takeoff
  for _ = 1, 20 do app:cycle(0.05) end
  T.eq(app._lastOwner, "disarmed",
    "landed + engine on + hands-off = disarmed, not mixer")
  for _, entry in ipairs(app.per:thrusterList()) do
    T.eq(entry.dev.getCurrentThrustKN(), 0, tostring(entry.id) .. " is not firing on the ground")
  end
  fs.delete(path)
end)

--- A positively-airborne craft with the engine on IS the mixer's to fly -- otherwise it could never
--- hold itself up. Proved with NO pilot input, so the airborne evidence alone is what arms it.
T.it("positively airborne, ENGAGED, engine on hands control to the mixer", function()
  local app, path = appRig(fullCraft())
  noPilotInput(app)
  mock.vehicle.groundDist = 10.0            -- well off the ground: the laser reads airborne
  app.engine.master = true
  app.modes:setArmed(true)
  for _ = 1, 5 do app:cycle(0.05) end
  T.eq(app._lastOwner, "mixer", "airborne + engaged + engine on = the mixer flies it, hands-off")
  fs.delete(path)
end)

--- The MASTER SWITCH. Disengaged, the mixer never runs -- not airborne, not with the engine on,
--- not with a stick input. This is what makes preflight provably safe.
T.it("DISENGAGED stays disarmed even airborne with the engine on", function()
  local app, path = appRig(fullCraft())
  noPilotInput(app)
  mock.vehicle.groundDist = 10.0            -- airborne
  app.engine.master = true
  -- flight control NOT armed (the boot default)
  for _ = 1, 5 do app:cycle(0.05) end
  T.eq(app._lastOwner, "disarmed", "flight control off -> disarmed no matter what")
  fs.delete(path)
end)

--- Takeoff: ENGAGED, on the ground, a climb input commits to flight and hands the mixer control.
T.it("a climb input while ENGAGED arms the mixer -- that is the takeoff", function()
  local app, path = appRig(fullCraft())
  mock.vehicle.groundDist = 1.0                                  -- on the ground
  app.pilot.read = function() return { climb = 1 }, {}, {} end   -- pilot pulls up
  app.engine.master = true
  app.modes:setArmed(true)
  for _ = 1, 5 do app:cycle(0.05) end
  T.eq(app._lastOwner, "mixer", "engaged + pulling up on the ground = takeoff")
  fs.delete(path)
end)

--- LANDING AUTHORITY. The rate loop's gentle hold gains can only shave ~0.4 off the hover trim, so
--- on a craft that hovers near full thrust a held descend command barely sinks it -- the reported
--- "it won't come down". The pilot-authority feedforward must pull the collective firmly down (to
--- the floor at full descend) so the craft actually lands.
T.it("airborne, holding descend pulls the collective down to the floor to land", function()
  local app, path = appRig(fullCraft())
  mock.vehicle.groundDist = 10.0                                  -- airborne
  app.pilot.read = function() return { climb = -1 }, {}, {} end   -- holding DESCEND (leftShift)
  app.engine.master = true
  app.modes:setArmed(true)
  app.altitude.hoverTrim = 0.9                                    -- a heavy craft's learned hover
  app.altitude.trimLearned = true
  local floor = app.cfg.control.altitude.minAirborneCollective
  for _ = 1, 40 do app:cycle(0.05) end
  T.eq(app._lastOwner, "mixer", "the mixer is flying it")
  local c = (app.lastAltitudeOut or {}).collective
  T.isTrue(type(c) == "number" and c <= floor + 1e-6,
    "full descend drives the collective to the floor, got " .. tostring(c))
  fs.delete(path)
end)

--- The mirror case: releasing the stick must NOT get the authority feedforward -- it holds altitude
--- at the hover trim, unchanged, or the craft would sink on its own the moment you let go.
T.it("airborne, hands off, holds altitude at the hover trim (no authority feedforward)", function()
  local app, path = appRig(fullCraft())
  mock.vehicle.groundDist = 10.0
  app.pilot.read = function() return { climb = 0, accel = 0 }, {}, {} end  -- hands off
  app.engine.master = true
  app.modes:setArmed(true)
  app.altitude.hoverTrim = 0.7
  app.altitude.trimLearned = true
  for _ = 1, 20 do app:cycle(0.05) end
  local c = (app.lastAltitudeOut or {}).collective
  -- Holds near the hover trim (0.7), not driven to a floor or a ceiling by any feedforward.
  T.isTrue(type(c) == "number" and c > 0.55 and c < 0.85,
    "hands-off holds near the 0.7 hover, got " .. tostring(c))
  fs.delete(path)
end)

--- THE TAKEOFF DEADLOCK. The altitude loop zeroes collective while groundContact is true (so
--- integrators cannot wind up on the skids), but groundContact only clears AFTER the craft lifts.
--- So a climb command handed the mixer control yet made NO lift -- the craft could never leave the
--- ground. A commanded climb must make lift THROUGH the ground guard.
T.it("a climb command from the pad actually makes lift, not a deadlock", function()
  local app, path = appRig(fullCraft())
  mock.vehicle.groundDist = 1.0                                  -- still on the ground
  app.pilot.read = function() return { climb = 1 }, {}, {} end   -- pull up
  app.engine.master = true
  app.modes:setArmed(true)
  for _ = 1, 60 do app:cycle(0.05) end
  T.eq(app._lastOwner, "mixer", "the mixer owns it")
  -- The whole point: the ramp must climb PAST the rate loop's ~0.5 authority ceiling toward full,
  -- or a craft that needs more than half thrust to lift (like the reported one) never leaves the pad.
  T.isTrue((app.lastAltitudeOut or {}).collective > 0.5,
    "the collective ramps past the rate loop's cap: " .. tostring((app.lastAltitudeOut or {}).collective))
  local anyLift = false
  for _, entry in ipairs(app.per:thrusterList()) do
    if entry.spec.group == "lift" and entry.dev.getCurrentThrustKN() > 0 then anyLift = true end
  end
  T.isTrue(anyLift, "and the lift thrusters actually fire")
  fs.delete(path)
end)

--- The ground guard still does its job for the case it exists for: grounded WITHOUT the takeoff
--- flag, collective stays zero so nothing winds up on the skids. Tested on the loop directly, since
--- that contract is what the app leans on -- otherwise this fix would re-open the leap-on-takeoff bug.
T.it("the altitude loop: lift for a climb through the ground guard, zero without it", function()
  local Altitude = require("lib.control.altitude")
  local alt = Altitude.new(vehicleCfg(), quietLog(), nil)
  local grounded = { altitude = 74.5, verticalSpeed = 0, groundContact = true }

  local held = alt:update({ verticalSpeed = 0 }, grounded, 0.1)
  T.eq(held.collective, 0, "grounded and NOT taking off -> zero collective, nothing winds up")

  local lifting
  for _ = 1, 10 do
    lifting = alt:update({ verticalSpeed = 2, ignoreGround = true }, grounded, 0.1)
  end
  T.isTrue(lifting.collective > 0, "a climb command with the takeoff flag MAKES lift on the ground")
end)

--- The ramp must climb PAST what the rate loop alone can command (~0.5 with hoverTrim 0), or a heavy
--- craft never leaves the pad. And it must not persist a hover estimate until the craft truly lifts.
T.it("takeoff ramp climbs toward full, and seeds hoverTrim only at liftoff", function()
  local Altitude = require("lib.control.altitude")
  local alt = Altitude.new(vehicleCfg(), quietLog(), nil)
  local grounded = { altitude = 74.5, verticalSpeed = 0, groundContact = true }

  local ramped
  for _ = 1, 30 do
    ramped = alt:update({ verticalSpeed = 4, ignoreGround = true }, grounded, 0.1)
  end
  T.isTrue(ramped.collective > 0.5,
    "the open-loop ramp climbs past the rate loop's ~0.5 ceiling: " .. ramped.collective)
  T.eq(select(1, alt:learnedTrim()), 0,
    "but a ramp that has not lifted seeds NO hover trim (no runaway persist)")

  -- Now it leaves the ground: the hover feedforward is seeded from the thrust that lifted it.
  local airborne = { altitude = 76.5, verticalSpeed = 1, groundContact = false }
  alt:update({ verticalSpeed = 4, ignoreGround = true }, airborne, 0.1)
  T.eq(select(1, alt:learnedTrim()), ramped.collective,
    "liftoff seeds hoverTrim = the collective that actually lifted the craft")
end)

--- The ramp must STOP the moment the craft breaks free of the skids, so it seeds ~hover and not
--- something near full. Left ramping to full past liftoff it flung the craft at the hangar ceiling
--- and hung it there (the reported "hold the throttle a little too long and it lifts me into the
--- ropes"). Once the craft is rising, the ramp holds and the pilot's authority feedforward flies it.
T.it("the takeoff ramp freezes the instant the craft starts rising", function()
  local Altitude = require("lib.control.altitude")
  local alt = Altitude.new(vehicleCfg(), quietLog(), nil)
  local climb = { verticalSpeed = 4, ignoreGround = true }

  -- dead still on the skids: the ramp builds thrust toward full
  local a, b
  for _ = 1, 5 do a = alt:update(climb, { altitude = 74.5, verticalSpeed = 0, groundContact = true }, 0.1) end
  b = alt:update(climb, { altitude = 74.5, verticalSpeed = 0, groundContact = true }, 0.1)
  T.isTrue(b.collective > a.collective, "still ramping while dead still on the skids")

  -- now it is rising (broken free, but the ground laser still reads contact for a moment): freeze
  local c = alt:update(climb, { altitude = 74.6, verticalSpeed = 0.3, groundContact = true }, 0.1)
  local d = alt:update(climb, { altitude = 74.7, verticalSpeed = 0.3, groundContact = true }, 0.1)
  T.near(d.collective, c.collective, 1e-9,
    ("frozen once rising -- no further ramp toward full (%.3f -> %.3f)"):format(c.collective, d.collective))
end)

--- The pre-flight THROUGHPUT check: the loop must report how long a cycle takes to run (which
--- includes the mainThread thruster writes -- the suspected bottleneck), the achieved control period,
--- and the writes per cycle. Read on the ground, this tells us whether we are throughput-bound before
--- we spend fuel tuning gains.
T.it("publishes loop-timing diagnostics after each cycle", function()
  local app, path = appRig(fullCraft())
  for _ = 1, 5 do app:cycle(0.05) end
  local loop = app.state:get("loop")
  T.notNil(loop, "loop stats are published")
  T.eq(type(loop.execMs), "number", "exec time (ms) is a number")
  T.eq(type(loop.execMaxMs), "number", "windowed max exec is a number")
  T.eq(type(loop.periodMs), "number", "achieved period (ms) is a number")
  T.eq(type(loop.writes), "number", "writes-per-cycle is a number")
  T.isTrue(loop.targetMs > 0, "the target period is reported for comparison")
  fs.delete(path)
end)

--- A silent-but-engaged craft must be explainable: the loop publishes WHY the mixer is holding, so
--- the cockpit can tell "ready, give it a climb" from "the engine is off" from "actually broken".
T.it("publishes WHY the mixer is holding, so an engaged-but-silent craft is explained", function()
  local app, path = appRig(fullCraft())
  noPilotInput(app)
  mock.vehicle.groundDist = 1.0                      -- on the ground

  -- Engaged, engine OFF: held for the engine.
  app.modes:setArmed(true)
  app.engine.master = false
  for _ = 1, 3 do app:cycle(0.05) end
  T.eq(app.state:get("flight.owner"), "disarmed", "owner is disarmed")
  T.eq(app.state:get("flight.hold"), "ENGINE OFF", "and names the off engine")

  -- Engine ON, still parked, hands-off: ready, held on the ground for a climb command.
  app.engine.master = true
  for _ = 1, 3 do app:cycle(0.05) end
  T.eq(app.state:get("flight.hold"), "ON GROUND", "engine on + parked = held on the ground")

  -- A climb input commits to flight: the mixer takes it and there is no hold.
  app.pilot.read = function() return { climb = 1 }, {}, {} end
  for _ = 1, 3 do app:cycle(0.05) end
  T.eq(app.state:get("flight.owner"), "mixer", "climb hands it to the mixer")
  T.isNil(app.state:get("flight.hold"), "no hold once actually flying")

  -- Disengaged entirely: held DISENGAGED regardless of the stick.
  app.modes:setArmed(false)
  for _ = 1, 3 do app:cycle(0.05) end
  T.eq(app.state:get("flight.hold"), "DISENGAGED", "SAFE reports disengaged")
  fs.delete(path)
end)

T.it("the flightArm command engages and disengages flight control", function()
  local app, path = appRig(fullCraft())
  T.isFalse(app.modes:isArmed(), "SAFE at boot -- flight control off by default")
  local ok, detail = app:handleCommand({ cmd = "flightArm", value = true })
  T.isTrue(ok and detail.armed, "engaged by command")
  T.isTrue(app.modes:isArmed(), "and the modes reflect it")
  app:handleCommand({ cmd = "flightArm", value = false })
  T.isFalse(app.modes:isArmed(), "disengaged again")
  fs.delete(path)
end)

--- THE CRASH: App:cycle built the BIP's context as if `measured` were the nested sensors:read
--- result (measured.altitude.baro, measured.attitude, measured.velocity), but the cycle's local
--- `measured` is FLAT -- altitude is the baro NUMBER -- so `measured.altitude.baro` indexed a number
--- and threw every cycle, on any craft with an altitude sensor. It killed the whole loop: telemetry
--- stopped, the run never ticked, and the panel just said ALREADY RUNNING. The unit tests missed it
--- because they call SelfConfig:tick directly; only driving it through App:cycle catches it.
T.it("App:cycle drives a running SELF CONFIG without crashing on the real measured shape", function()
  local app, path = appRig(fullCraft())      -- an altitude sensor auto-assigns -> measured.altitude
  app.engine.master = true                   -- is a NUMBER, which is what made the old code throw
  mock.vehicle.groundDist = 1.0
  local started = app.selfConfig:start({ engineOn = true, fuelled = true, onGround = true,
    velocityVector = "vector" }, { now = os.epoch("utc"), altitude = 74.5 })
  T.isTrue(started, "the BIP started")

  for _ = 1, 10 do app:cycle(0.05) end        -- would have thrown at app.lua:388 before the fix

  T.eq(app._lastOwner, "selfConfig", "the cycle handed control to the BIP")
  T.isTrue(app.selfConfig:isRunning(), "and it is still running -- no cycle error killed it")
  fs.delete(path)
end)

T.it("takes any standing throttle to zero when the sweep starts", function()
  -- However a nonzero throttle got onto the hardware, the sweep's allStop must clear it before it
  -- owns the thrusters -- otherwise it would stand for the whole 45 seconds, ready to become real
  -- thrust the moment someone opens the fuel valve.
  local app, path = appRig(fullCraft())
  app.engine.master = false
  app.state.mode = "GROUND"
  -- a stale throttle sitting on the hardware, set directly (the mixer no longer does this)
  for _, entry in ipairs(app.per:thrusterList()) do entry.dev.setThrust(8) end
  T.isTrue(app.per.thrusters["lift_fl"].dev.getPower() > 0.001, "a throttle is standing")

  T.isTrue((app:handleCommand({ cmd = "selfTest", action = "start" })), "started")
  for _, entry in ipairs(app.per:thrusterList()) do
    T.eq(entry.dev.getPower(), 0, entry.id .. " throttle is zero while the sweep runs")
  end
  fs.delete(path)
end)

--- THE BUG THAT REACHED THE CRAFT, pinned where the wording is produced.
---
--- The panel tail-fitted the refusal, so "<id> is producing thrust (0.40) -- cut the engine
--- first" arrived on a 15-column monitor as "he engine first" -- which reads as an instruction to
--- START the engine, the exact opposite of an interlock for a test that must run cold. The UI
--- tests could not catch it alone: they asserted hand-written strings, which is how a UI test
--- passes against wording the craft never sends.
---
--- So the contract lives here: EVERY refusal returns a third value, and it fits the narrowest
--- monitor that exists. A new refusal without one fails this test rather than shipping and
--- inverting itself in the field.
local NARROW = 15                       -- one monitor block at text scale 0.5

T.it("every self-test refusal carries a form that fits the narrowest monitor", function()
  local cases = {
    { name = "airborne under thrust", setup = function(app)
        app.state:set("measured", { groundContact = false })
        app.per.thrusters["lift_fl"].dev.getCurrentThrustKN = function() return 40.0 end
      end },
    { name = "engine master on", setup = function(app)
        app.state.mode = "GROUND"; app.engine.master = true
      end },
  }
  for _, case in ipairs(cases) do
    local app, path = appRig(fullCraft())
    case.setup(app)
    local ok, detail = app:handleCommand({ cmd = "selfTest", action = "start" })
    T.isFalse(ok, case.name .. " is refused")
    local short = (detail or {}).errorShort
    T.notNil(short, case.name .. " has a short form")
    T.isTrue(#short <= NARROW,
      ("%s: %q is %d columns, over %d"):format(case.name, short, #short, NARROW))
    -- and it must not be a prefix-free fragment: the reader has to be able to act on it
    T.isTrue(short:find("%a") ~= nil, case.name .. ": short form says something")
    fs.delete(path)
  end
end)

T.it("the self test never commands thrust, only nozzle deflection", function()
  -- The whole premise: it checks that the slot you assigned is the thruster that moves. Thrust
  -- would make the craft move, which is why the interlock demands the engine off -- so the sweep
  -- itself must never ask for any.
  local app, path = appRig(fullCraft())
  app.state.mode = "GROUND"
  -- Zero IS commanded, on purpose, once at the start: that is allStop taking the mixer last
  -- throttle down. What must never appear is a NONZERO request.
  local nonzero = {}
  for id, entry in pairs(app.per.thrusters) do
    local record = function(v)
      if type(v) == "number" and v > 0 then nonzero[#nonzero + 1] = id .. "=" .. tostring(v) end
    end
    entry.dev.setThrust = record
    entry.dev.setThrustNormalized = record
    entry.dev.setPower = record
  end
  -- setVector is deliberately left ALONE: the sweep now decides whether to write by reading the
  -- block back, so a stub that swallows the write would make every sample look stale and turn
  -- this into a test of the stub.
  T.isTrue((app:handleCommand({ cmd = "selfTest", action = "start" })), "started")
  local started = app.selfTest.run.startedAt
  for at = 0, 44000, 500 do app.selfTest:tick(started + at) end
  T.eq(#nonzero, 0, "no thrust was ever commanded: " .. table.concat(nonzero, " "))
  fs.delete(path)
end)

T.it("runs three 15-second steps, in the order the pilot was told", function()
  local app, path = appRig(fullCraft())
  app.state.mode = "GROUND"
  T.isTrue((app:handleCommand({ cmd = "selfTest", action = "start" })), "started")

  local started = app.selfTest.run.startedAt
  local seen = {}
  for _, at in ipairs({ 0, 7600, 15100, 22000, 30100, 40000 }) do
    local p = app.selfTest:progress(started + at)
    seen[#seen + 1] = ("%d:%s"):format(p.step, p.phase)
  end
  T.eq(seen[1], "1:X sweep", "step 1 starts on the X axis")
  T.eq(seen[2], "1:Y sweep", "and moves to Y half way through")
  T.eq(seen[3], "2:X sweep", "step 2 after 15 s")
  T.eq(seen[5], "3:X sweep", "step 3 after 30 s")
  T.eq(app.selfTest:progress(started).totalMs, 45000, "45 s in total")
  fs.delete(path)
end)

T.it("MOVES THE NOZZLES, and only the group under test", function()
  local app, path = appRig(fullCraft())
  app.state.mode = "GROUND"
  app:handleCommand({ cmd = "selfTest", action = "start" })
  local started = app.selfTest.run.startedAt

  local commanded = {}
  for _, entry in ipairs(app.per:thrusterList()) do
    local id = entry.id
    entry.dev.setVector = function(x, y) commanded[id] = { x = x, y = y } end
  end

  app.selfTest:tick(started + 1875)
  T.notNil(commanded["lift_fl"], "a lift thruster moved")
  T.isTrue(commanded["lift_fl"].x > 0.1, "on its X axis: " .. tostring(commanded["lift_fl"].x))
  T.eq(commanded["lift_fl"].y, 0, "and not on Y during the X sweep")
  T.isNil(commanded["lateral_fl"], "the lateral group is NOT moving during step 1")
  T.isNil(commanded["main_1"], "nor the accelerators")

  commanded = {}
  app.selfTest:tick(started + 15000 + 1875)
  T.notNil(commanded["lateral_fl"], "the lateral thruster moved in step 2")
  T.isNil(commanded["lift_fl"], "and the lift group has stopped")
  fs.delete(path)
end)

T.it("sweeps the FULL range of an axis, both directions", function()
  local app, path = appRig(fullCraft())
  app.state.mode = "GROUND"
  app:handleCommand({ cmd = "selfTest", action = "start" })
  local started = app.selfTest.run.startedAt
  local seenX = {}
  for _, entry in ipairs(app.per:thrusterList()) do
    local id = entry.id
    entry.dev.setVector = function(x) if id == "lift_fl" then seenX[#seenX + 1] = x end end
  end
  for offset = 0, 7400, 200 do app.selfTest:tick(started + offset) end
  local lo, hi = math.huge, -math.huge
  for _, v in ipairs(seenX) do lo = math.min(lo, v); hi = math.max(hi, v) end
  T.isTrue(hi > 0.5, "reached a positive deflection: " .. tostring(hi))
  T.isTrue(lo < -0.5, "and a negative one: " .. tostring(lo))
  fs.delete(path)
end)

--- WHY THE PILOT SAW NOTHING MOVE. The mod stores nozzle aim as four redstone signals via
--- `Math.round(x * 15)`, so aim lives on a 15-step grid and anything under 1/30 of full scale
--- rounds to ZERO. The sweep was a sine leaving the origin, so its opening samples commanded
--- literal nothing -- and a sine spends most of its life away from the extremes, which on a slow
--- control loop (every thruster @LuaFunction is mainThread) is most of the samples you get.
T.it("commands a deflection the mod can actually represent, not one that rounds to zero", function()
  local app, path = appRig(fullCraft())
  app.state.mode = "GROUND"
  app:handleCommand({ cmd = "selfTest", action = "start" })
  local started = app.selfTest.run.startedAt

  local seen = {}
  for _, entry in ipairs(app.per:thrusterList()) do
    local id = entry.id
    entry.dev.setVector = function(x, y)
      if id == "lift_fl" then seen[#seen + 1] = math.max(math.abs(x), math.abs(y)) end
    end
  end
  for offset = 0, 7400, 100 do app.selfTest:tick(started + offset) end

  T.isTrue(#seen > 0, "the nozzle was commanded at all")
  local visible, zeroish = 0, 0
  for _, v in ipairs(seen) do
    -- one grid step is 1/15; below half of one the mod stores nothing at all
    if v * 15 >= 1 then visible = visible + 1 end
    if v > 0 and v * 15 < 0.5 then zeroish = zeroish + 1 end
  end
  T.eq(zeroish, 0, "no command that the mod would round away to zero")
  T.isTrue(visible > 0, "and real, representable deflections were commanded")
  fs.delete(path)
end)

--- A sine spends most of its time near the middle. A pilot standing in the bay needs the nozzle
--- to GO somewhere and STAY there long enough to see which one moved and which way.
T.it("holds full deflection rather than passing through it", function()
  local held = 0
  for i = 0, 100 do
    if math.abs(SelfTest.waveAt(i / 100)) > 0.999 then held = held + 1 end
  end
  T.isTrue(held >= 30,
    ("only %d%% of the phase is at full deflection"):format(held))
  -- and it still covers the whole range, which is what a sweep is for
  local lo, hi = 1, -1
  for i = 0, 100 do
    local v = SelfTest.waveAt(i / 100)
    lo = math.min(lo, v); hi = math.max(hi, v)
  end
  T.isTrue(hi > 0.999, "reaches the positive extreme")
  T.isTrue(lo < -0.999, "and the negative one")
  T.eq(SelfTest.waveAt(1), 0, "and ends centred, so the next axis starts from a known place")
end)

T.it("quantising never exceeds what was asked for", function()
  -- Rounding to NEAREST turned a maxVector of 0.30 into 0.33 and broke a configured limit.
  for _, v in ipairs({ 0.3, 0.6, 0.99, 0.05, 1.0, -0.3, -0.99, 0 }) do
    local q = Thrusters.quantiseVector(v)
    T.isTrue(math.abs(q) <= math.abs(v) + 1e-9,
      ("%s quantised UP to %s"):format(tostring(v), tostring(q)))
    T.eq(q * 15, math.floor(q * 15 + 0.5), tostring(v) .. " landed off the grid: " .. tostring(q))
  end
end)

--- Every setVector is mainThread and costs a server tick, so the sweep was slowing the very loop
--- that advances it -- while re-sending values the mod already had.
T.it("does not re-send a deflection the nozzle is already holding", function()
  local app, path = appRig(fullCraft())
  app.state.mode = "GROUND"
  app:handleCommand({ cmd = "selfTest", action = "start" })
  local started = app.selfTest.run.startedAt
  -- Count writes WITHOUT swallowing them: the sweep asks the block what it holds before writing,
  -- so a stub that drops the write would make every sample stale and defeat the dedupe under test.
  local writes = 0
  for _, entry in ipairs(app.per:thrusterList()) do
    local inner = entry.dev.setVector
    if type(inner) == "function" then
      entry.dev.setVector = function(x, y) writes = writes + 1; return inner(x, y) end
    end
  end
  -- 200 ticks across one phase; the pattern holds still for most of it
  for offset = 0, 7400, 37 do app.selfTest:tick(started + offset) end
  T.isTrue(writes > 0, "it did command the nozzles")
  T.isTrue(writes < 200, "but did not write on every tick: " .. tostring(writes))
  fs.delete(path)
end)

--- READBACK COST. The cheap getters (vector angles, throttle) are plain @LuaFunction on the
--- vector peripherals and can run every cycle. getObstruction and getCurrentThrustKN are
--- mainThread wherever they exist and feed nothing in the control path, so they are refreshed on
--- a slow timer, ONE THRUSTER PER PASS -- doing all of them at once would turn a slow loop into a
--- periodically stalling one, which is worse.
T.it("does not pay for the mainThread readouts on every cycle", function()
  local app, path = appRig(fullCraft())
  local costly = 0
  for _, entry in ipairs(app.per:thrusterList()) do
    for _, method in ipairs({ "getObstruction", "getCurrentThrustKN" }) do
      if type(entry.dev[method]) == "function" then
        local inner = entry.dev[method]
        entry.dev[method] = function(...) costly = costly + 1; return inner(...) end
      end
    end
  end
  app.thrusters:invalidate()
  app.thrusters:readback()            -- first pass primes every cache entry
  local afterPrime = costly
  for _ = 1, 30 do app.thrusters:readback() end
  T.eq(costly, afterPrime,
    ("%d costly reads in 30 passes -- the slow timer had not expired"):format(
      costly - afterPrime))
  fs.delete(path)
end)

T.it("still reports a real value for the slow readouts, with its age", function()
  local app, path = appRig(fullCraft())
  app.thrusters:invalidate()
  local out = app.thrusters:readback()
  local row = out["lift_fl"]
  T.notNil(row, "the thruster is reported")
  T.notNil(row.slowAgeMs, "and says how old the slow readings are")
  T.isTrue(row.slowAgeMs >= 0, "a real age, not a hole")
  fs.delete(path)
end)

T.it("forgets the slow cache when the hardware set changes", function()
  local app, path = appRig(fullCraft())
  app.thrusters:readback()
  T.notNil(app.thrusters.slowCache, "primed")
  app.thrusters:invalidate()
  T.isNil(app.thrusters.slowCache, "a rebuild can put a different block behind the same id")
  fs.delete(path)
end)

--- A SWEEP MUST PROVE ITSELF. setVectorRaw returns false with a reason and the sweep used to
--- discard it, so a run whose every write was refused still counted down and reported RUNNING
--- while nothing moved -- indistinguishable, from the cockpit, from a working test.
T.it("counts writes the hardware refused instead of discarding them", function()
  local app, path = appRig(fullCraft())
  app.state.mode = "GROUND"
  app:handleCommand({ cmd = "selfTest", action = "start" })
  -- every nozzle refuses
  for _, entry in ipairs(app.per:thrusterList()) do
    entry.dev.setVector = function() error("nope") end
  end
  local started = app.selfTest.run.startedAt
  for at = 0, 3000, 250 do app.selfTest:tick(started + at) end
  local st = app.state:get("selfTest")
  T.isTrue((st.writeFails or 0) > 0, "the refusals were counted, not swallowed")
  fs.delete(path)
end)

T.it("reports what the nozzle actually holds, not only what was asked", function()
  local app, path = appRig(fullCraft())
  app.state.mode = "GROUND"
  app:handleCommand({ cmd = "selfTest", action = "start" })
  local started = app.selfTest.run.startedAt
  for at = 0, 2000, 250 do app.selfTest:tick(started + at) end
  local st = app.state:get("selfTest")
  T.notNil(st.witness, "a witness nozzle is named")
  T.eq(type(st.aimCommanded), "number", "and what it was told")
  T.eq(type(st.aimActual), "number", "and what it reads back")
  T.eq(st.writeFails, 0, "with no refusals on healthy hardware")
  fs.delete(path)
end)

--- The sweep needs the same property as the mixer, for the same reason: the redstone-link
--- receivers on every vector thruster can zero a nozzle at any moment, so a sweep that skips a
--- write because it REMEMBERS sending one never notices and never re-asserts.
T.it("the sweep re-asserts a nozzle that was zeroed behind its back", function()
  local app, path = appRig(fullCraft())
  app.state.mode = "GROUND"
  app:handleCommand({ cmd = "selfTest", action = "start" })
  local started = app.selfTest.run.startedAt
  -- far enough in to be asking for a real deflection, and settled there
  for at = 0, 2500, 100 do app.selfTest:tick(started + at) end

  local dev = app.per.thrusters["lift_fl"].dev
  local held = dev.getTargetVectorX()
  T.isTrue(math.abs(held) > 0.05, "precondition: the nozzle is deflected (" .. tostring(held) .. ")")

  -- something else centres it
  dev.setVector(0, 0)
  T.eq(dev.getTargetVectorX(), 0, "it really was zeroed")

  app.selfTest:tick(started + 2600)
  T.isTrue(math.abs(dev.getTargetVectorX()) > 0.05,
    "the sweep put it back: " .. tostring(dev.getTargetVectorX()))
  fs.delete(path)
end)

--- THE NOZZLES END WHERE THEY STARTED. Commanded outright rather than through apply(), which
--- decides by comparing against the block: right during a sweep, wrong at the end of one. A
--- readback that lies, or a competing writer caught mid-revert, would otherwise leave a nozzle
--- hard over with nothing scheduled to correct it.
T.it("centres every nozzle when the run finishes", function()
  local app, path = appRig(fullCraft())
  app.state.mode = "GROUND"
  app:handleCommand({ cmd = "selfTest", action = "start" })
  local started = app.selfTest.run.startedAt
  for at = 0, 2500, 100 do app.selfTest:tick(started + at) end
  T.isTrue(math.abs(app.per.thrusters["lift_fl"].dev.getTargetVectorX()) > 0.05,
    "precondition: deflected mid-run")

  for at = 0, 46000, 500 do app.selfTest:tick(started + at) end
  T.isFalse(app.selfTest:isRunning(), "the run finished")
  for _, entry in ipairs(app.per:thrusterList()) do
    local n = entry.dev._nozzle
    if n then
      T.eq(n.tx, 0, entry.id .. " X centred")
      T.eq(n.ty, 0, entry.id .. " Y centred")
    end
  end
  fs.delete(path)
end)

T.it("centres them even if something insists they are already centred", function()
  -- apply() would skip the write here; centreNozzles must not.
  local app, path = appRig(fullCraft())
  app.state.mode = "GROUND"
  app:handleCommand({ cmd = "selfTest", action = "start" })
  local started = app.selfTest.run.startedAt
  for at = 0, 2500, 100 do app.selfTest:tick(started + at) end

  local dev = app.per.thrusters["lift_fl"].dev
  dev.getTargetVectorX = function() return 0 end       -- lies: says already centred
  dev.getTargetVectorY = function() return 0 end
  local wrote = false
  local inner = dev.setVector
  dev.setVector = function(x, y) wrote = true; return inner(x, y) end

  app:handleCommand({ cmd = "selfTest", action = "abort" })
  T.isTrue(wrote, "the centring command was sent regardless of the readback")
  fs.delete(path)
end)

T.it("publishes a countdown for the step AND for the whole run", function()
  local app, path = appRig(fullCraft())
  app.state.mode = "GROUND"
  app:handleCommand({ cmd = "selfTest", action = "start" })
  local started = app.selfTest.run.startedAt
  app.selfTest:tick(started + 3000)
  local a = app.state:get("selfTest")
  T.eq(type(a.stepRemainingMs), "number", "step countdown published")
  T.eq(type(a.remainingMs), "number", "whole-run countdown published")

  app.selfTest:tick(started + 9000)
  local b = app.state:get("selfTest")
  T.isTrue(b.remainingMs < a.remainingMs, "and it ticks DOWN")
  T.isTrue(b.step >= a.step, "advancing through the steps")
  fs.delete(path)
end)

--- THE TRAP THE PILOT HIT: "ALREADY RUNNING", for ever. A run lives in self.run and ends only
--- when tick() carries it past its own duration. If nothing ever drives it -- App:cycle taking
--- another branch, the loop wedged, a reboot leaving a saved intent -- it never ends, and every
--- later START is refused BY IT. The screen meant to diagnose the craft becomes the thing that
--- needs diagnosing.
T.it("START takes over a stalled run instead of being refused by it", function()
  local app, path = appRig(fullCraft())
  app.state.mode = "GROUND"
  T.isTrue((app:handleCommand({ cmd = "selfTest", action = "start" })), "first run starts")

  -- nothing drives it: no tick at all
  local runAt = app.selfTest.run.startedAt
  app.selfTest.run.lastTickAt = runAt - 30000        -- half a minute with no tick
  T.isTrue(app.selfTest:isStalled(), "it is stalled, not running")

  local ok, detail = app:handleCommand({ cmd = "selfTest", action = "start" })
  T.isTrue(ok, "START takes it over: " .. tostring((detail or {}).error))
  T.isFalse(app.selfTest:isStalled(), "and the new run is live")
  fs.delete(path)
end)

T.it("but a run that IS being driven is still protected", function()
  local app, path = appRig(fullCraft())
  app.state.mode = "GROUND"
  app:handleCommand({ cmd = "selfTest", action = "start" })
  -- Ticked WELL PAST the stall window, so this only passes if each tick records that it ran.
  -- Ticking at +100ms would pass even with the timestamp never updated, since the run would still
  -- be within STALL_MS of its own start.
  local started = app.selfTest.run.startedAt
  for at = 0, 8000, 500 do app.selfTest:tick(started + at) end
  T.isFalse(app.selfTest:isStalled(started + 8200), "being ticked, 8 s in")
  local ok, detail = app:handleCommand({ cmd = "selfTest", action = "start" })
  T.isFalse(ok, "a healthy run is not interrupted")
  T.eq((detail or {}).errorShort, "ALREADY RUNNING", "and says so")
  fs.delete(path)
end)

T.it("publishes how long since the run was last driven", function()
  local app, path = appRig(fullCraft())
  app.state.mode = "GROUND"
  app:handleCommand({ cmd = "selfTest", action = "start" })
  app.selfTest:tick(app.selfTest.run.startedAt + 100)
  local st = app.state:get("selfTest")
  T.eq(type(st.sinceTickMs), "number", "so the panel can say STALLED rather than count down")
  fs.delete(path)
end)

--- THE BUG 401 TESTS DID NOT SEE. The DAMPED/FAILSAFE branch returns early from App:cycle, and
--- the sweep was serviced BELOW it. So a craft in either state never ticked its run: it could
--- never finish, every later START was refused with "a self test is already running" for ever,
--- and neutralVectors() re-centred the nozzles on every cycle, cancelling whatever the sweep had
--- managed to command.
---
--- FAILSAFE means "sensors unhealthy", which is exactly where a half-configured craft sits --
--- gimbal and laser not assigned yet, because assigning them is what the pilot is doing. That is
--- precisely when this test is needed, and precisely when it could not run.
T.it("the sweep runs in DAMPED, where nothing else steers", function()
  local app, path = appRig(fullCraft())
  app.state.mode = "GROUND"
  T.isTrue((app:handleCommand({ cmd = "selfTest", action = "start" })), "started")

  -- force the damped path: oscillation detected, so the mixer must not steer
  app.osc.shouldDamp = function() return true end

  local moved = 0
  for _, entry in ipairs(app.per:thrusterList()) do
    local inner = entry.dev.setVector
    if type(inner) == "function" then
      entry.dev.setVector = function(x, y) moved = moved + 1; return inner(x, y) end
    end
  end

  local started = app.selfTest.run.startedAt
  for at = 0, 3000, 100 do app.selfTest:tick(started + at) end   -- past the ramp
  for _ = 1, 10 do app:cycle(0.05) end

  T.eq(app.state.mode, "DAMPED", "the craft really is in the damped state")
  T.isTrue(app.selfTest:isRunning(), "and the sweep is still running")
  T.isTrue(moved > 0, "and the nozzles were commanded through App:cycle")
  fs.delete(path)
end)

T.it("and the damped path does not re-centre a nozzle the sweep owns", function()
  -- Asserts the MECHANISM rather than a resulting angle: App:cycle ticks the sweep on the real
  -- clock, so a test that pre-ticks it with synthetic times just finds it back at the start of its
  -- ramp, commanding zero, and proves nothing about who centred it.
  local app, path = appRig(fullCraft())
  app.state.mode = "GROUND"
  app:handleCommand({ cmd = "selfTest", action = "start" })

  local neutralled = 0
  local inner = app.thrusters.neutralVectors
  app.thrusters.neutralVectors = function(...) neutralled = neutralled + 1; return inner(...) end

  app.osc.shouldDamp = function() return true end
  for _ = 1, 10 do app:cycle(0.05) end

  T.eq(app.state.mode, "DAMPED", "the damped path is the one being taken")
  T.isTrue(app.selfTest:isRunning(), "the sweep still owns the thrusters")
  T.eq(neutralled, 0, "and nothing re-centred them behind its back")
  fs.delete(path)
end)

--- SILENCE IS THE WORST ANSWER. onMessage is pcall'd by the run loop, so an error thrown inside
--- handleCommand went nowhere: no reply reached the cockpit, the pilot saw NOTHING happen, and
--- anything the handler had already changed stayed changed. Press again and the craft reports the
--- action as already under way, while the reason never left the flight computer.
T.it("a command that throws still answers, with the reason", function()
  local app, path = appRig(fullCraft())
  app.state.mode = "GROUND"
  local replied = nil
  app.telemetry.reply = function(_, _, payload) replied = payload end
  -- reply(sender, payload) -- capture whichever argument carries the table
  app.telemetry.reply = function(_, a, b) replied = (type(a) == "table") and a or b end

  app.selfTest.start = function() error("boom inside the handler") end
  app:onMessage(7, { cmd = "selfTest", action = "start" }, app.cfg.comms.commandProtocol)

  T.notNil(replied, "the cockpit got an answer rather than silence")
  T.isFalse(replied.ack, "reported as a refusal")
  T.isTrue(tostring((replied.detail or {}).error):find("boom") ~= nil,
    "carrying the real reason: " .. tostring((replied.detail or {}).error))
  T.eq((replied.detail or {}).errorShort, "CMD ERROR", "and a form that fits a narrow monitor")
  fs.delete(path)
end)

--- THE TESTING GAP THIS SUITE HAD. Every other test calls app:cycle() directly, so nothing
--- exercised App:run() -- the event loop that decides whether cycle is called at all. A control
--- loop that never runs is indistinguishable, from every unit test here, from one that runs
--- perfectly.
T.it("App:run drives the control cycle AND the sweep", function()
  local app, path = appRig(fullCraft())
  app.telemetry.publish = function() return true end

  local armed = 1000
  local realStart, realPull, realEpoch = os.startTimer, os.pullEvent, os.epoch
  os.startTimer = function() armed = armed + 1; return armed end
  -- A CLOCK THAT MOVES. The cycle is deadline-driven now, so a frozen os.epoch means one cycle
  -- and no more -- which says nothing about the loop and everything about the harness.
  local clock = realEpoch("utc")
  os.epoch = function(kind) if kind == "utc" then return clock end return realEpoch(kind) end
  local fed = 0
  os.pullEvent = function()
    fed = fed + 1
    clock = clock + 60
    if fed == 5 then
      return "rednet_message", 7, { cmd = "selfTest", action = "start" },
        app.cfg.comms.commandProtocol
    end
    if fed > 30 then return "terminate" end
    return "timer", armed
  end

  local ticks = 0
  local innerTick = app.selfTest.tick
  app.selfTest.tick = function(self, t) ticks = ticks + 1; return innerTick(self, t) end

  local ok, err = pcall(function() app:run() end)
  os.startTimer, os.pullEvent, os.epoch = realStart, realPull, realEpoch
  T.isTrue(ok, "the loop ran without error: " .. tostring(err))

  T.isTrue((app.cycles or 0) > 10, "cycles actually ran: " .. tostring(app.cycles))
  T.isTrue(app.selfTest:isRunning(), "the sweep was started through the loop")
  T.isTrue(ticks > 5, "and DRIVEN by it: " .. tostring(ticks) .. " ticks")
  fs.delete(path)
end)

--- THE ROOT CAUSE. The cycle used to run only inside `event == "timer" and p1 == timer`, and
--- re-arm only there, so the single outstanding timer was the loop's ONLY heartbeat. Lose that
--- one event and the control cycle never runs again -- while rednet keeps answering from its own
--- branch, so the craft still replies "already running" and looks alive.
---
--- And it was easy to lose: SelfTest:start calls allStop(), 12 setVector plus 12 setThrust, every
--- one mainThread at a server tick each -- about 1.2 s inside one rednet handler with
--- os.pullEvent not being called. The craft reported sinceTick=1.4s.
T.it("a LOST timer event does not stop the control loop", function()
  local app, path = appRig(fullCraft())
  app.telemetry.publish = function() return true end

  local armed = 1000
  local realStart, realPull, realEpoch = os.startTimer, os.pullEvent, os.epoch
  os.startTimer = function() armed = armed + 1; return armed end
  local clock = realEpoch("utc")
  os.epoch = function(kind) if kind == "utc" then return clock end return realEpoch(kind) end

  local fed = 0
  os.pullEvent = function()
    fed = fed + 1
    clock = clock + 60
    if fed > 25 then return "terminate" end
    -- NEVER deliver the timer the loop armed. Only other events arrive -- exactly what a queue
    -- that dropped the timer looks like.
    return "rednet_message", 7, { cmd = "ping" }, app.cfg.comms.commandProtocol
  end

  local ok = pcall(function() app:run() end)
  os.startTimer, os.pullEvent, os.epoch = realStart, realPull, realEpoch
  T.isTrue(ok, "the loop ran")
  T.isTrue((app.cycles or 0) > 0,
    "cycles ran anyway: " .. tostring(app.cycles) .. " -- the deadline, not the timer, drives it")
  fs.delete(path)
end)

--- The loop must not eat the pilot's terminate either. Fixing it in callDevice only moved the
--- swallow one level up, into the pcall around cycle -- the craft still printed a row of
--- "cycle error: Terminated" lines, one per press, instead of stopping.
T.it("a terminate inside the cycle stops the program", function()
  local app, path = appRig(fullCraft())
  app.telemetry.publish = function() return true end
  local realStart, realPull, realEpoch = os.startTimer, os.pullEvent, os.epoch
  local armed = 1000
  os.startTimer = function() armed = armed + 1; return armed end
  local clock = realEpoch("utc")
  os.epoch = function(kind) if kind == "utc" then return clock end return realEpoch(kind) end
  os.pullEvent = function() clock = clock + 60; return "timer", armed end

  app.cycle = function() error("Terminated", 0) end
  local ok, err = pcall(function() app:run() end)
  os.startTimer, os.pullEvent, os.epoch = realStart, realPull, realEpoch

  T.isFalse(ok, "the terminate left the loop instead of being logged and ignored")
  T.isTrue(tostring(err):find("Terminated") ~= nil, "and it is the terminate: " .. tostring(err))
  fs.delete(path)
end)

--- THE TWITCHING NOZZLES. The mixer ran every cycle in every state, so on the ground with the
--- engine off the attitude and altitude PIDs turned sensor noise into nozzle angles and wrote
--- them -- a nozzle twitching continuously, others frozen at odd angles. Engine master off now
--- means DISARMED: the controller holds neutral and does not steer.
T.it("DISARMED: engine off holds neutral and does not run the mixer", function()
  local app, path = appRig(fullCraft())
  app.engine.master = false
  mock.vehicle.groundDist = 12        -- even off the ground: engine off is engine off
  local mixed, reset = 0, 0
  local innerMix = app.mixer.mix
  app.mixer.mix = function(...) mixed = mixed + 1; return innerMix(...) end
  local innerReset = app.attitude.reset
  app.attitude.reset = function(...) reset = reset + 1; return innerReset(...) end

  for _ = 1, 10 do app:cycle(0.05) end

  T.eq(mixed, 0, "the mixer never ran with the engine off")
  T.isTrue(reset > 0, "and the loops were reset each cycle, so they cannot wind up")
  local back = app.thrusters:readback()
  T.near(back.lift_fl.targetX, 0, 1e-6, "the nozzle is held at neutral, not a PID angle")
  T.eq(back.lift_fl.power or 0, 0, "and thrust is zero")
  fs.delete(path)
end)

T.it("ENGAGED and flying: the closed loop runs", function()
  local app, path = appRig(fullCraft())
  app.engine.master = true
  app.modes:setArmed(true)            -- flight control engaged
  mock.vehicle.groundDist = 12
  app.modes.throttle = 0.6
  local mixed = 0
  local innerMix = app.mixer.mix
  app.mixer.mix = function(...) mixed = mixed + 1; return innerMix(...) end
  for _ = 1, 10 do app:cycle(0.05) end
  T.isTrue(mixed > 0, "the mixer runs when armed")
  fs.delete(path)
end)

T.it("the self test still runs on a disarmed craft -- it owns the thrusters", function()
  local app, path = appRig(fullCraft())
  app.engine.master = false           -- disarmed, and the self test requires exactly this
  app.state.mode = "GROUND"
  T.isTrue((app:handleCommand({ cmd = "selfTest", action = "start" })), "started")

  local ticks, mixed = 0, 0
  local it = app.selfTest.tick
  app.selfTest.tick = function(sv, t) ticks = ticks + 1; return it(sv, t) end
  local innerMix = app.mixer.mix
  app.mixer.mix = function(...) mixed = mixed + 1; return innerMix(...) end

  for _ = 1, 6 do app:cycle(0.05) end

  T.isTrue(app.selfTest:isRunning(), "still running")
  T.isTrue(ticks > 0, "the sweep is ticked (owner=selfTest, checked before disarmed)")
  T.eq(mixed, 0, "and the mixer never runs while the sweep owns the thrusters")
  fs.delete(path)
end)

T.it("respects each thruster's own maxVector limit", function()
  local cfg = fullCraft()
  cfg.hardware.thrusters[1].maxVector = 0.3
  local app, path = appRig(cfg)
  app.state.mode = "GROUND"
  app:handleCommand({ cmd = "selfTest", action = "start" })
  local started = app.selfTest.run.startedAt
  local peak = 0
  for _, entry in ipairs(app.per:thrusterList()) do
    local id = entry.id
    entry.dev.setVector = function(x)
      if id == "lift_fl" then peak = math.max(peak, math.abs(x)) end
    end
  end
  for offset = 0, 7400, 100 do app.selfTest:tick(started + offset) end
  T.isTrue(peak <= 0.3001, "never exceeded its limit: " .. tostring(peak))
  T.isTrue(peak > 0.25, "but did use it: " .. tostring(peak))
  fs.delete(path)
end)

T.it("THE MIXER DOES NOT FIGHT THE SWEEP", function()
  -- The attitude loop wants those same nozzles. Both writing would spoil the test and, worse,
  -- is the one thing this craft must never do.
  local app, path = appRig(fullCraft())
  app.state.mode = "GROUND"
  app:handleCommand({ cmd = "selfTest", action = "start" })
  local applied = 0
  local realApply = app.thrusters.apply
  app.thrusters.apply = function(...) applied = applied + 1; return realApply(...) end
  app:cycle(0.05)
  T.eq(applied, 0, "the mixer's commands were not applied while the sweep owns the thrusters")
  T.isTrue(app.selfTest:isRunning(), "and the sweep is still the one in charge")
  fs.delete(path)
end)

T.it("ABORTS ITSELF if the craft leaves the ground mid-test", function()
  local app, path = appRig(fullCraft())
  app.state.mode = "GROUND"
  app:handleCommand({ cmd = "selfTest", action = "start" })
  T.isTrue(app.selfTest:isRunning(), "running")
  -- force ACTIVE flight, which is what aborts it. The state machine is stubbed because the
  -- mock craft has no ground sensor, so a real cycle would land in FAILSAFE, not FLIGHT.
  app.modes.updateState = function() return "FLIGHT", true end
  app:cycle(0.05)
  T.isFalse(app.selfTest:isRunning(), "stopped the moment it was flying")
  T.isTrue(tostring(app.state:get("selfTest").aborted):find("flying") ~= nil,
    "and said why: " .. tostring(app.state:get("selfTest").aborted))
  fs.delete(path)
end)

T.it("the pilot can abort it, and the nozzles are centred", function()
  local app, path = appRig(fullCraft())
  app.state.mode = "GROUND"
  app:handleCommand({ cmd = "selfTest", action = "start" })
  -- Run far enough in to actually DEFLECT something, otherwise this asserts nothing: apply()
  -- elides a write that would not change anything, so an abort one tick after the start has no
  -- centring left to do. Asserting the WRITE rather than the STATE is what made this look broken
  -- once allStop began centring the nozzles up front.
  local started = app.selfTest.run.startedAt
  for at = 0, 4000, 250 do app.selfTest:tick(started + at) end
  local deflected = false
  for _, entry in ipairs(app.per:thrusterList()) do
    local n = entry.dev._nozzle
    if n and (math.abs(n.tx or 0) > 0.01 or math.abs(n.ty or 0) > 0.01) then deflected = true end
  end
  T.isTrue(deflected, "precondition: the sweep really moved a nozzle")

  T.isTrue((app:handleCommand({ cmd = "selfTest", action = "abort" })), "aborted")
  T.isFalse(app.selfTest:isRunning(), "stopped")
  for _, entry in ipairs(app.per:thrusterList()) do
    local n = entry.dev._nozzle
    if n then
      T.eq(n.tx, 0, entry.id .. " nozzle X is centred")
      T.eq(n.ty, 0, entry.id .. " nozzle Y is centred")
    end
  end
  fs.delete(path)
end)

T.it("REPORTS A GROUP WITH NO NOZZLES rather than pretending it swept", function()
  -- A main thruster often has thrust only. Saying "tested" would be a lie the pilot would
  -- believe right up until the first flight.
  local app, path = appRig(fullCraft())
  app.state.mode = "GROUND"
  app:handleCommand({ cmd = "selfTest", action = "start" })
  local started = app.selfTest.run.startedAt
  app.selfTest:tick(started + 30100)
  local findings = app.state:get("selfTest").findings
  T.notNil(findings.main, "step 3 recorded what it saw")
  T.eq(#findings.main.plain, 1, "one thruster with no nozzle")
  T.eq(findings.main.plain[1], "main_1", "named")
  fs.delete(path)
end)

T.it("publishes progress the UI can draw a timer from", function()
  local app, path = appRig(fullCraft())
  app.state.mode = "GROUND"
  app:handleCommand({ cmd = "selfTest", action = "start" })
  app.selfTest:tick(app.selfTest.run.startedAt + 5000)
  local st = app.state:get("selfTest")
  T.isTrue(st.running, "running")
  T.eq(st.step, 1, "step")
  T.eq(st.steps, 3, "of three")
  T.isTrue(st.stepRemainingMs > 9000 and st.stepRemainingMs <= 10000,
    "ten seconds left in the step: " .. tostring(st.stepRemainingMs))
  T.notNil(st.watch, "and what to look at")
  fs.delete(path)
end)

T.it("the whole pilot input state is published for the FCS page", function()
  local app, path = appRig(fullCraft())
  app:cycle(0.05)
  local payload = app.telemetry:build()
  T.notNil(payload.pilot, "pilot state reported")
  T.notNil(payload.pilot.axes, "with its axes")
  for _, axis in ipairs({ "pitch", "roll", "yaw", "climb", "accel" }) do
    T.eq(type(payload.pilot.axes[axis]), "number", axis .. " is a number")
  end
  T.eq(type(payload.pilot.brake), "boolean", "and whether the brake is held")
  fs.delete(path)
end)


-- ------------------------------------------------------------- axis mapping

T.suite("nozzle direction mapping")

local AxisMap = require("lib.control.axismap")

T.it("names what the system currently believes each deflection points at", function()
  local spec = { group = "lift", vectorMap = { x = "x", y = "z" },
                 invertVectorX = false, invertVectorY = false }
  -- craft x is RIGHT, craft z is FORWARD (see the thruster template)
  T.eq(AxisMap.believedDirection(spec, "x", 1), "RIGHT")
  T.eq(AxisMap.believedDirection(spec, "x", -1), "LEFT")
  T.eq(AxisMap.believedDirection(spec, "y", 1), "FWD")
  T.eq(AxisMap.believedDirection(spec, "y", -1), "BACK")
end)

T.it("an invert flag flips what a deflection is called", function()
  local spec = { group = "lift", vectorMap = { x = "x", y = "z" },
                 invertVectorX = true, invertVectorY = false }
  T.eq(AxisMap.believedDirection(spec, "x", 1), "LEFT", "inverted X reads the other way")
  T.eq(AxisMap.believedDirection(spec, "y", 1), "FWD", "Y is unaffected")
end)

T.it("an accelerator's nozzle steers UP and DOWN, not fore and aft", function()
  -- A rear-facing thruster cannot point its nozzle "forward"; its plane is left/right and
  -- up/down. Offering fore/aft would invite a mapping the geometry cannot hold.
  local spec = { group = "main", vectorMap = { x = "x", y = "y" },
                 invertVectorX = false, invertVectorY = false }
  T.eq(AxisMap.believedDirection(spec, "y", 1), "UP")
  T.eq(AxisMap.believedDirection(spec, "y", -1), "DOWN")
end)

T.it("A NOZZLE DEFLECTS PERPENDICULAR TO ITS OWN THRUST", function()
  -- The rule comes from thrustAxis, not from the group. A sideways-pointing lateral thruster
  -- CANNOT deflect its thrust sideways -- that is the direction it already points -- so its
  -- nozzle steers up/down and fore/aft.
  T.eq(table.concat(AxisMap.planeFor({ thrustAxis = "down", group = "lift" }), ""), "xz",
    "a down-facing lift thruster: left/right and fore/aft")
  T.eq(table.concat(AxisMap.planeFor({ thrustAxis = "back", group = "main" }), ""), "xy",
    "a rear-facing accelerator: left/right and up/down")
  T.eq(table.concat(AxisMap.planeFor({ thrustAxis = "right", group = "lateral" }), ""), "yz",
    "a sideways lateral thruster: up/down and fore/aft")
  T.eq(table.concat(AxisMap.planeFor({ thrustAxis = "left", group = "lateral" }), ""), "yz",
    "and the same on the other side")
end)

T.it("the KEYS mean what the pilot said they mean, per thruster kind", function()
  -- lift:    a=left  d=right  s=back  w=forward
  -- main:    a=left  d=right  s=down  w=up
  -- lateral: a=down  d=up     s=back  w=forward
  local function legend(spec)
    local plan = AxisMap.keyPlan(spec)
    local out = {}
    for _, k in ipairs({ "a", "d", "s", "w" }) do
      out[k] = AxisMap.NAMES[plan[k].axis][plan[k].sign]
    end
    return out
  end

  local lift = legend({ thrustAxis = "down", group = "lift" })
  T.eq(lift.a, "LEFT"); T.eq(lift.d, "RIGHT")
  T.eq(lift.s, "BACK"); T.eq(lift.w, "FWD")

  local main = legend({ thrustAxis = "back", group = "main" })
  T.eq(main.a, "LEFT"); T.eq(main.d, "RIGHT")
  T.eq(main.s, "DOWN"); T.eq(main.w, "UP")

  local lateral = legend({ thrustAxis = "right", group = "lateral" })
  T.eq(lateral.a, "DOWN", "a is DOWN on a lateral thruster, not left")
  T.eq(lateral.d, "UP", "and d is UP")
  T.eq(lateral.s, "BACK"); T.eq(lateral.w, "FWD")
end)

T.it("a lateral nozzle REFUSES to be called left or right", function()
  local spec = { group = "lateral", thrustAxis = "right",
                 vectorMap = { x = "y", y = "z" }, invertVectorX = false, invertVectorY = false }
  local ok, err = AxisMap.assign(spec, "x", 1, "x", 1)
  T.isFalse(ok, "sideways is the one direction it cannot point")
  T.isTrue(tostring(err):find("cannot point") ~= nil, "and says so: " .. tostring(err))
end)

T.it("ASSIGNING a direction writes the map and the sign", function()
  local spec = { group = "lift", vectorMap = { x = "x", y = "z" },
                 invertVectorX = false, invertVectorY = false, maxVector = 0.6 }
  -- "this nozzle's +X points LEFT"
  T.isTrue((AxisMap.assign(spec, "x", 1, "x", -1)), "accepted")
  T.eq(spec.vectorMap.x, "x", "nozzle X lies on the craft's left-right axis")
  T.isTrue(spec.invertVectorX, "and is inverted, because +X came out as LEFT")
  T.eq(AxisMap.believedDirection(spec, "x", 1), "LEFT", "which is what it now reads")
end)

T.it("assigning one nozzle axis forces the OTHER onto the remaining craft axis", function()
  -- Both nozzle axes on the same craft axis is geometrically impossible, so it must not be
  -- expressible -- the mixer could never satisfy it.
  local spec = { group = "lift", vectorMap = { x = "x", y = "z" },
                 invertVectorX = false, invertVectorY = false }
  AxisMap.assign(spec, "x", 1, "z", 1)          -- nozzle +X now points FORWARD
  T.eq(spec.vectorMap.x, "z", "X took fore/aft")
  T.eq(spec.vectorMap.y, "x", "so Y was pushed onto left/right")
  T.isFalse(spec.vectorMap.x == spec.vectorMap.y, "never both on one axis")
end)

T.it("REFUSES a direction the geometry cannot hold", function()
  local spec = { group = "main", vectorMap = { x = "x", y = "y" } }
  local ok, err = AxisMap.assign(spec, "y", 1, "z", 1)
  T.isFalse(ok, "an accelerator cannot point forward")
  T.isTrue(tostring(err):find("cannot point") ~= nil, "and says so: " .. tostring(err))
end)

T.it("all eight orientations are reachable by naming BOTH nozzle axes", function()
  -- One assignment fixes one nozzle axis and leaves the other's sign alone, so a single naming
  -- reaches six of the eight. Naming both -- which is the actual workflow, since the pilot
  -- deflects and names each axis in turn -- reaches all of them.
  local seen = {}
  for _, xCraft in ipairs({ "x", "z" }) do
    for _, xSign in ipairs({ 1, -1 }) do
      for _, ySign in ipairs({ 1, -1 }) do
        local spec = { group = "lift", vectorMap = { x = "x", y = "z" },
                       invertVectorX = false, invertVectorY = false }
        local yCraft = (xCraft == "x") and "z" or "x"
        AxisMap.assign(spec, "x", 1, xCraft, xSign)
        AxisMap.assign(spec, "y", 1, yCraft, ySign)
        seen[("%s%s%s%s"):format(spec.vectorMap.x, spec.vectorMap.y,
          tostring(spec.invertVectorX), tostring(spec.invertVectorY))] = true
      end
    end
  end
  local count = 0
  for _ in pairs(seen) do count = count + 1 end
  T.eq(count, 8, "all eight distinct mappings, got " .. count)
end)

T.it("naming the second axis does not undo the first", function()
  local spec = { group = "lift", vectorMap = { x = "x", y = "z" },
                 invertVectorX = false, invertVectorY = false }
  AxisMap.assign(spec, "x", 1, "x", -1)            -- +X is LEFT
  T.eq(AxisMap.believedDirection(spec, "x", 1), "LEFT")
  AxisMap.assign(spec, "y", 1, "z", -1)            -- +Y is BACK
  T.eq(AxisMap.believedDirection(spec, "y", 1), "BACK", "the second naming took")
  T.eq(AxisMap.believedDirection(spec, "x", 1), "LEFT", "and the first still holds")
end)

-- ------------------------------------------------------------ the live latch

local function axisRig()
  local app, path = appRig({ hardware = { thrusters = {
    { id = "lift_fl", peripheral = "vector_thruster_0", group = "lift" },
    { id = "lift_fr", peripheral = "vector_thruster_1", group = "lift" },
    { id = "main_1", peripheral = "solid_fuel_thruster_0", group = "main", thrustAxis = "back" },
  } } })
  app.state.mode = "GROUND"
  return app, path
end

T.it("every nozzle-mapping refusal carries a form that fits the narrowest monitor", function()
  local cases = {
    { name = "airborne", id = "lift_fl", axis = "x", prep = function(app)
        app.state.mode = "HOVER"; app.engine.master = true
      end },
    { name = "bad axis", id = "lift_fl", axis = "q" },
    { name = "unknown id", id = "no_such_thruster", axis = "x" },
    { name = "no nozzle", id = "main_1", axis = "x" },
  }
  for _, case in ipairs(cases) do
    local app, path = axisRig()
    if case.prep then case.prep(app) end
    local ok, detail = app:handleCommand({ cmd = "vectorHold", action = "latch",
      id = case.id, axis = case.axis, sign = 1 })
    T.isFalse(ok, case.name .. " is refused")
    local short = (detail or {}).errorShort
    T.notNil(short, case.name .. " has a short form")
    T.isTrue(#short <= 15,
      ("%s: %q is %d columns"):format(case.name, tostring(short), #tostring(short)))
    fs.delete(path)
  end
end)

--- A held nozzle OUTRANKS the sweep in App:cycle, so a latch left over from the axis map let the
--- sweep start, report RUNNING and never once be ticked -- the panel counting down against a
--- craft where nothing moved. vectorHold already refused while the sweep ran; this was the
--- missing half of that guard.
T.it("a held nozzle does not silently stop the sweep from ever ticking", function()
  local app, path = axisRig()
  app.engine.master = false
  T.isTrue((app:handleCommand({ cmd = "vectorHold", action = "latch", id = "lift_fl",
    axis = "x", sign = 1 })), "latched")
  T.isTrue(app.axisMap:isHolding(), "and it is holding")

  T.isTrue((app:handleCommand({ cmd = "selfTest", action = "start" })), "the sweep starts")
  T.isFalse(app.axisMap:isHolding(), "and the latch gave way, so cycle reaches the sweep")

  -- prove it: the real loop must actually tick it
  local moved = 0
  for _, entry in ipairs(app.per:thrusterList()) do
    local inner = entry.dev.setVector
    if type(inner) == "function" then
      entry.dev.setVector = function(x, y) moved = moved + 1; return inner(x, y) end
    end
  end
  -- Far enough in that the pattern is asking for a real deflection: the opening of a phase asks
  -- for the centre, which a centred nozzle already holds, so nothing needs writing there.
  local started = app.selfTest.run.startedAt
  for at = 0, 2500, 100 do app.selfTest:tick(started + at) end
  for _ = 1, 5 do app:cycle(0.05) end
  T.isTrue(app.selfTest:isRunning(), "still running")
  T.isTrue(moved > 0, "and the nozzles were commanded through App:cycle")
  fs.delete(path)
end)

T.it("nozzle mapping refuses with the engine running, same as the sweep", function()
  local app, path = axisRig()
  app.state.mode = "GROUND"
  app.engine.master = true
  local ok = app:handleCommand({ cmd = "vectorHold", action = "latch", id = "lift_fl",
    axis = "x", sign = 1 })
  T.isFalse(ok, "it moves the same nozzles, so it wants the same silence")
  fs.delete(path)
end)

T.it("latching HOLDS the nozzle at its full deflection", function()
  local app, path = axisRig()
  T.isTrue((app:handleCommand({ cmd = "vectorHold", action = "latch", id = "lift_fl",
    axis = "x", sign = 1 })), "latched")
  local commanded
  app.per.thrusters["lift_fl"].dev.setVector = function(x, y) commanded = { x = x, y = y } end
  app.axisMap:tick(os.epoch("utc"), {})
  T.notNil(commanded, "the nozzle was commanded")
  T.isTrue(commanded.x > 0.5, "to full deflection on X: " .. tostring(commanded.x))
  T.eq(commanded.y, 0, "and nothing on Y")
  fs.delete(path)
end)

T.it("HOLDING 'a' renames the held deflection to LEFT", function()
  local app, path = axisRig()
  app:handleCommand({ cmd = "vectorHold", action = "latch", id = "lift_fl", axis = "x", sign = 1 })
  T.eq(app.state:get("axisMap").direction, "RIGHT", "it starts believing +X is RIGHT")

  app.axisMap:tick(os.epoch("utc"), { [keys.a] = true })
  T.eq(app.state:get("axisMap").direction, "LEFT", "and now believes it is LEFT")
  local spec = app.per.thrusters["lift_fl"].spec
  T.eq(AxisMap.believedDirection(spec, "x", 1), "LEFT", "the config was rewritten")
  fs.delete(path)
end)

T.it("w and s mean FWD/BACK on a lift thruster", function()
  local app, path = axisRig()
  app:handleCommand({ cmd = "vectorHold", action = "latch", id = "lift_fl", axis = "y", sign = 1 })
  app.axisMap:tick(os.epoch("utc"), { [keys.s] = true })
  T.eq(app.state:get("axisMap").direction, "BACK", "s is BACK on a lift thruster")
  fs.delete(path)
end)

T.it("PUBLISHES THE KEY LEGEND, so the panel never has to guess", function()
  -- A screen showing "a/d = left/right" on a lateral nozzle would be a lie: that nozzle cannot
  -- point sideways. The rule lives on the craft, so the legend is computed there and sent.
  local app, path = axisRig()
  app:handleCommand({ cmd = "vectorHold", action = "latch", id = "lift_fl", axis = "x", sign = 1 })
  local legend = app.state:get("axisMap").legend
  T.isTrue(legend:find("LEFT/RIGHT") ~= nil, "lift: " .. tostring(legend))
  T.isTrue(legend:find("FWD/BACK") ~= nil, "and fore/aft on w/s: " .. tostring(legend))
  fs.delete(path)
end)

T.it("a lateral thruster's legend says a/d are DOWN and UP", function()
  local app, path = appRig({ hardware = { thrusters = {
    { id = "lift_fl", peripheral = "vector_thruster_0", group = "lift" },
    { id = "lateral_fl", peripheral = "vector_thruster_1", group = "lateral",
      thrustAxis = "right", yawAuthority = true },
  } } })
  app.state.mode = "GROUND"
  app:handleCommand({ cmd = "vectorHold", action = "latch", id = "lateral_fl",
    axis = "x", sign = 1 })
  local legend = app.state:get("axisMap").legend
  T.isTrue(legend:find("a/d DOWN/UP") ~= nil, "lateral: " .. tostring(legend))
  fs.delete(path)
end)

T.it("a key rewrite happens ONCE per press, not every cycle it is held", function()
  local app, path = axisRig()
  app:handleCommand({ cmd = "vectorHold", action = "latch", id = "lift_fl", axis = "x", sign = 1 })
  local writes = 0
  local realSave = Config.save
  Config.save = function(...) writes = writes + 1; return realSave(...) end
  for _ = 1, 10 do app.axisMap:tick(os.epoch("utc"), { [keys.a] = true }) end
  Config.save = realSave
  T.eq(writes, 1, "one config write for one press, got " .. writes)
  fs.delete(path)
end)

T.it("SILENCES the normal keybinds while a nozzle is latched", function()
  -- a/d/w/s are naming a direction. Leaving them live would roll and pitch the craft while
  -- someone stands next to it reading nozzle angles.
  local app, path = axisRig()
  app:handleCommand({ cmd = "vectorHold", action = "latch", id = "lift_fl", axis = "x", sign = 1 })
  local before = app.modes.feel
  app.pilot.read = function()
    return { pitch = 1, roll = 1, yaw = 1, climb = 1, accel = 1 },
           { brake = true }, { cycleFeel = true, engineMaster = true }
  end
  app:cycle(0.05)
  T.eq(app.modes.feel, before, "the feel mode was NOT cycled by a naming key")
  T.isFalse(app.engine.master, "and the engine was not switched on")
  fs.delete(path)
end)

T.it("the latch OWNS the thrusters -- the mixer does not write", function()
  local app, path = axisRig()
  app:handleCommand({ cmd = "vectorHold", action = "latch", id = "lift_fl", axis = "x", sign = 1 })
  local applied = 0
  local realApply = app.thrusters.apply
  app.thrusters.apply = function(...) applied = applied + 1; return realApply(...) end
  app:cycle(0.05)
  T.eq(applied, 0, "the mixer stayed out of it")
  fs.delete(path)
end)

T.it("releasing centres the nozzle", function()
  local app, path = axisRig()
  app:handleCommand({ cmd = "vectorHold", action = "latch", id = "lift_fl", axis = "x", sign = 1 })
  local centred = false
  app.per.thrusters["lift_fl"].dev.setVector = function(x, y) centred = (x == 0 and y == 0) end
  T.isTrue((app:handleCommand({ cmd = "vectorHold", action = "release" })), "released")
  T.isTrue(centred, "and the nozzle went back to centre")
  T.isFalse(app.axisMap:isHolding(), "nothing is held")
  fs.delete(path)
end)

T.it("TIMES OUT rather than leaving a nozzle deflected for ever", function()
  local app, path = axisRig()
  app:handleCommand({ cmd = "vectorHold", action = "latch", id = "lift_fl", axis = "x", sign = 1 })
  app.axisMap:tick(app.axisMap.hold.startedAt + app.axisMap.timeoutMs + 1, {})
  T.isFalse(app.axisMap:isHolding(), "a forgotten latch lets go by itself")
  fs.delete(path)
end)

T.it("refuses a thruster with no nozzle, and one that does not exist", function()
  local app, path = axisRig()
  local ok, detail = app:handleCommand({ cmd = "vectorHold", action = "latch",
    id = "main_1", axis = "x", sign = 1 })
  T.isFalse(ok, "a solid-fuel thruster has nothing to point")
  T.isTrue(tostring((detail or {}).error):find("no nozzle") ~= nil,
    "and says so: " .. tostring((detail or {}).error))

  local ok2 = app:handleCommand({ cmd = "vectorHold", action = "latch",
    id = "nope", axis = "x", sign = 1 })
  T.isFalse(ok2, "and an unknown thruster is refused")
  fs.delete(path)
end)

T.it("will not latch while the self test owns the same nozzles", function()
  local app, path = axisRig()
  app:handleCommand({ cmd = "selfTest", action = "start" })
  local ok, detail = app:handleCommand({ cmd = "vectorHold", action = "latch",
    id = "lift_fl", axis = "x", sign = 1 })
  T.isFalse(ok, "refused")
  T.isTrue(tostring((detail or {}).error):find("self test") ~= nil,
    "and says why: " .. tostring((detail or {}).error))
  fs.delete(path)
end)

T.it("latching a second nozzle releases the first", function()
  local app, path = axisRig()
  app:handleCommand({ cmd = "vectorHold", action = "latch", id = "lift_fl", axis = "x", sign = 1 })
  app:handleCommand({ cmd = "vectorHold", action = "latch", id = "lift_fr", axis = "y", sign = -1 })
  T.eq(app.state:get("axisMap").id, "lift_fr", "only the newest is held")
  T.eq(app.state:get("axisMap").axis, "y", "on the axis asked for")
  T.eq(app.state:get("axisMap").sign, -1, "with the sign asked for")
  fs.delete(path)
end)

T.it("a remap REBUILDS the mixer, so it applies without a reboot", function()
  local app, path = axisRig()
  app:handleCommand({ cmd = "vectorHold", action = "latch", id = "lift_fl", axis = "x", sign = 1 })
  local rebuilt = 0
  local realBuild = app.mixer.build
  app.mixer.build = function(...) rebuilt = rebuilt + 1; return realBuild(...) end
  app.axisMap:tick(os.epoch("utc"), { [keys.a] = true })
  T.eq(rebuilt, 1, "the mixer picked up the new mapping immediately")
  fs.delete(path)
end)

-- ---------------------------------------------------------------- SELF AXIS CONFIG BIP

local SelfConfig = require("lib.control.selfconfig")

T.suite("self axis config BIP")

--- A two-lift-thruster craft, with fast BIP timings so the phase machine converges in a test loop.
local function scRig(scOverrides)
  mock.reset()
  _G.peripheral = mock.install()
  local cfg = vehicleCfg({
    hardware = { thrusters = {
      { id = "lift_fl", peripheral = "vector_thruster_0", group = "lift",
        thrustAxis = "down", maxVector = 0.6 },
      { id = "lift_fr", peripheral = "vector_thruster_1", group = "lift",
        thrustAxis = "down", maxVector = 0.6 },
    } },
    selfConfig = require("lib.util").deepMerge({
      hoverHeight = 2.0, hoverTolerance = 0.6, maxCollective = 1.0,
      -- Float gains for the tests: quick to converge against the momentum sim, damped enough not to
      -- oscillate around the (close) target. The in-game defaults (config.lua) are gentler still.
      approachSpeed = 0.5, approachGain = 0.6, hoverLearn = 0.6, velP = 0.35, maxCorrection = 0.35,
      settleMs = 300, settleSpeed = 0.1, probeMs = 500, counterMs = 250, floatSettleMs = 1500,
      probeDeflection = 0.6, minResponse = 0.1, landRamp = 0.6, maxTiltDeg = 45,
    }, scOverrides or {}),
  })
  local log = quietLog()
  local state = State.new({})
  local per = Peripherals.new(cfg, log):scan()
  local thrusters = Thrusters.new(per, cfg, log, state)
  local sc = SelfConfig.new(thrusters, per, cfg, log, state)
  return { cfg = cfg, log = log, state = state, per = per, thrusters = thrusters, sc = sc }
end

--- The TRUE nozzle mounting the sim enforces -- deliberately rotated and mirrored -- which the BIP
--- must recover from the velocity response ALONE, never seeing this table.
local TRUE_MOUNT = {
  lift_fl = { x = { axis = "z", sign = 1 },  y = { axis = "x", sign = -1 } },
  lift_fr = { x = { axis = "x", sign = 1 },  y = { axis = "z", sign = 1 } },
}

--- Vertical plant for the float sim: a real DOUBLE INTEGRATOR (thrust -> accel -> velocity ->
--- altitude), so the height controller's damping actually matters. The old sim made altitude an
--- INSTANTANEOUS function of collective, which is exactly why it could never reproduce the
--- overshoot-and-collapse the pilot reported. `hoverCollective` is the throttle that exactly holds
--- altitude; below it the craft sinks, above it climbs.
local SIM = { hoverCollective = 0.45, liftGain = 11.0, drag = 1.6, ground = 74.5 }

local function liftCollective(per)
  local sum, n = 0, 0
  for _, e in ipairs(per:thrusterList()) do
    if e.spec.group == "lift" then sum = sum + (e.dev._nozzle.power or 0); n = n + 1 end
  end
  return (n > 0) and (sum / n) or 0
end

--- Craft-frame horizontal velocity from whatever nozzles are deflected (mapped through the true
--- mounting). Gain is kept below the BIP's runaway cap so a good probe never trips the envelope.
local function horizontalVel(per)
  local vx, vz = 0, 0
  for id, mount in pairs(TRUE_MOUNT) do
    local n = per.thrusters[id].dev._nozzle
    for _, nozzleAxis in ipairs({ "x", "y" }) do
      local defl = (nozzleAxis == "x") and n.tx or n.ty
      local m = mount[nozzleAxis]
      if m.axis == "x" then vx = vx + m.sign * defl * 2.0
      elseif m.axis == "z" then vz = vz + m.sign * defl * 2.0 end
    end
  end
  return vx, vz
end

--- Advance the vertical state one step under the current lift collective.
local function stepVertical(per, vst, dt)
  local accel = SIM.liftGain * (liftCollective(per) - SIM.hoverCollective) - SIM.drag * vst.vy
  vst.vy = vst.vy + accel * dt
  vst.alt = vst.alt + vst.vy * dt
  if vst.alt <= SIM.ground then vst.alt = SIM.ground; if vst.vy < 0 then vst.vy = 0 end end
  return vst
end

--- Drive the BIP from a fresh float to its end. `ctxTweak(ctx, now)` can jam a fault in.
local function runBip(sc, per, ctxTweak)
  local now = 100000
  local ok = sc:start({ engineOn = true, fuelled = true, onGround = true,
    velocityVector = "vector" }, { now = now, altitude = 74.5 })
  T.isTrue(ok, "the BIP started with prerequisites met")
  local vx, vz = 0, 0
  local vst = { alt = 74.5, vy = 0 }
  for _ = 1, 4000 do
    now = now + 100
    local ctx = {
      now = now, altitude = vst.alt,
      attitude = { pitch = 0, roll = 0, yaw = 0 },
      velocity = { x = vx, y = vst.vy, z = vz },
      groundContact = vst.alt <= 74.8, engineOn = true,
    }
    if ctxTweak then ctxTweak(ctx, now) end
    local alive = sc:tick(ctx)
    stepVertical(per, vst, 0.1)
    vx, vz = horizontalVel(per)
    if not alive then break end
  end
end

T.it("recovers each nozzle's craft-frame mapping from the velocity response", function()
  local r = scRig()
  runBip(r.sc, r.per)
  T.isFalse(r.sc:isRunning(), "the run completed")
  local proposal = r.sc:pendingProposal()
  T.isTrue(type(proposal) == "table", "a proposal was produced")

  local fl = proposal.lift_fl
  T.isTrue(type(fl) == "table", "lift_fl was mapped")
  T.eq(fl.vectorMap.x, "z", "fl nozzle x drives craft z")
  T.eq(fl.vectorMap.y, "x", "fl nozzle y drives craft x")
  T.isFalse(fl.invertVectorX, "fl x not inverted (nozzle x+ -> craft z+)")
  T.isTrue(fl.invertVectorY, "fl y IS inverted (nozzle y+ -> craft x-)")

  local fr = proposal.lift_fr
  T.eq(fr.vectorMap.x, "x", "fr nozzle x drives craft x")
  T.eq(fr.vectorMap.y, "z", "fr nozzle y drives craft z")
  T.isFalse(fr.invertVectorX, "fr x not inverted")
  T.isFalse(fr.invertVectorY, "fr y not inverted")
end)

--- THE FIX for a SELF CONFIG that ran at ~1 Hz: holdFloat used to re-command every lift thruster
--- unconditionally EVERY tick, and each setThrust/setVector is a mainThread call costing ~a server
--- tick -- ~17 a cycle dragged the loop to 1 Hz, so the float could not hold and the probes read
--- garbage. It is now write-on-change: a steady collective and centred nozzles re-command NOTHING.
T.it("holdFloat is write-on-change: a steady hover re-commands no thrusters", function()
  local r = scRig()
  r.sc:start({ engineOn = true, fuelled = true, onGround = true, velocityVector = "vector" },
    { now = 100000, altitude = 74.5 })
  r.sc.run.collective = 0.6

  r.sc:holdFloat()                                  -- first pass commands the lift thrusters
  local afterFirst = r.thrusters.stats.calls
  T.isTrue(afterFirst > 0, "the first pass does command them")

  r.sc:holdFloat()                                  -- same collective, same centred nozzles
  T.eq(r.thrusters.stats.calls, afterFirst, "an unchanged hover makes ZERO further thruster calls")

  r.sc.run.collective = 0.9                          -- a real change must still be written
  r.sc:holdFloat()
  T.isTrue(r.thrusters.stats.calls > afterFirst, "but a changed collective is re-commanded")
end)

T.it("checkPrereqs refuses with the engine off, and names what is missing", function()
  local r = scRig()
  local check = r.sc:checkPrereqs({ engineOn = false, fuelled = true,
    onGround = true, velocityVector = "vector" })
  T.isFalse(check.ok, "not ready with the engine off")
  local named = false
  for _, m in ipairs(check.missing) do if m == "ENGINE OFF" then named = true end end
  T.isTrue(named, "the missing engine is listed")
end)

T.it("the off-ground refusal shows the reading against its threshold, to tune", function()
  local r = scRig()
  local check = r.sc:checkPrereqs({ engineOn = true, fuelled = true, onGround = false,
    groundDist = 3.4, groundThreshold = 2.0, velocityVector = "vector" })
  T.isFalse(check.ok, "not ready off the ground")
  local shown = false
  for _, m in ipairs(check.missing) do if m == "GND 3.4>2.0" then shown = true end end
  T.isTrue(shown, "the reading and threshold are shown so the pilot can raise it: "
    .. table.concat(check.missing, ", "))
  T.eq(check.groundDist, 3.4, "and the raw reading rides the result")
end)

T.it("refuses to start without a signed velocity vector", function()
  local r = scRig()
  local ok, _, short = r.sc:start({ engineOn = true, fuelled = true,
    onGround = true, velocityVector = "partial" }, { now = 1, altitude = 74.5 })
  T.isFalse(ok, "no start without a real velocity vector")
  T.eq(short, "NO VEL VECTOR", "and it says why")
end)

T.it("aborts and centres when the craft tilts past the safety cap", function()
  local r = scRig()
  runBip(r.sc, r.per, function(ctx)
    if r.sc.run and r.sc.run.phase ~= "float" then ctx.attitude.pitch = 90 end
  end)
  T.isFalse(r.sc:isRunning(), "the run stopped")
  T.isTrue(r.sc.lastRun ~= nil and r.sc.lastRun.aborted ~= nil, "it aborted")
  T.eq(r.sc.lastRun.abortedShort, "OVER TILT", "for the tilt limit")
  T.isTrue(r.sc:pendingProposal() == nil, "an aborted run proposes nothing")
end)

T.it("aborts if the engine is switched off mid-run", function()
  local r = scRig()
  runBip(r.sc, r.per, function(ctx)
    if r.sc.run and r.sc.run.phase ~= "float" then ctx.engineOn = false end
  end)
  T.isFalse(r.sc:isRunning(), "the run stopped")
  T.eq(r.sc.lastRun.abortedShort, "ENGINE OFF", "and names the engine")
end)

--- The float must ramp all the way to FULL power to try to lift, and declare WONT LIFT only after
--- HOLDING full power a while -- not the instant it caps out. A craft that never rises exercises it.
T.it("float ramps to full power and only declares WONT LIFT after holding it", function()
  local r = scRig({ maxCollective = 1.0, hoverLearn = 3.0, fullPowerDwellMs = 1000 })
  local now = 100000
  r.sc:start({ engineOn = true, fuelled = true, onGround = true, velocityVector = "vector" },
    { now = now, altitude = 74.5 })
  local function tickAt(t)   -- altitude never rises: the craft cannot lift
    r.sc:tick({ now = t, altitude = 74.5, attitude = { pitch = 0, roll = 0 },
      velocity = { x = 0, y = 0, z = 0 }, engineOn = true })
  end

  for _ = 1, 10 do now = now + 100; tickAt(now) end   -- the hover estimate climbs to full power
  T.isTrue(r.sc:isRunning(), "at full power but still trying -- not given up during the dwell")
  T.eq(r.sc.run.phase, "float", "still in the float phase")
  T.isTrue(r.sc.run.collective >= 1.0 - 1e-9, "and the collective reached FULL power")

  now = now + 1500; tickAt(now)                       -- held full power past the dwell
  T.isFalse(r.sc:isRunning(), "WONT LIFT only after holding full power a while")
  T.eq(r.sc.lastRun.abortedShort, "WONT LIFT", "and says why")
end)

--- Climbing above the target is not a fault on a roped craft: the float must THROTTLE DOWN toward
--- the band, never abort. This is the reported bug -- an overshoot tripped a "TOO HIGH" abort.
T.it("float throttles DOWN when too high, and never aborts for it", function()
  local r = scRig({ hoverHeight = 2.0, hoverTolerance = 0.5, collectiveRamp = 0.5,
    maxCollective = 1.0 })
  local now = 100000
  r.sc:start({ engineOn = true, fuelled = true, onGround = true, velocityVector = "vector" },
    { now = now, altitude = 74.5 })
  r.sc.run.collective = 0.9                            -- came up too hard
  local before = r.sc.run.collective
  local function tickHigh()                            -- 6 blocks up: above even the OLD 5.0 ceiling
    now = now + 100
    r.sc:tick({ now = now, altitude = 74.5 + 6.0, attitude = { pitch = 0, roll = 0 },
      velocity = { x = 0, y = 0, z = 0 }, engineOn = true })
  end
  for _ = 1, 8 do tickHigh() end
  T.isTrue(r.sc:isRunning(), "still running -- too high is not an abort, even past the old ceiling")
  T.eq(r.sc.run.phase, "float", "still floating, neither settled nor aborted")
  T.isTrue(r.sc.run.collective < before, "and it eased the throttle down: "
    .. before .. " -> " .. r.sc.run.collective)
end)

--- THE FIX for the reported limit cycle (lifts too high, slams back down): the float regulation is
--- velocity-DAMPED. Below the target but already rising faster than the gentle approach speed, it
--- must EASE the collective OFF so the craft glides into the band -- the old bang-bang ramped up
--- regardless of how fast it was rising and sailed straight past into an overshoot. The sim's
--- altitude is instantaneous (no momentum), so this is unit-tested on regulateHeight directly.
T.it("float regulation is velocity-damped: below target but rising fast eases the collective off", function()
  local r = scRig({ hoverHeight = 2.0, hoverTolerance = 0.5,
    approachSpeed = 0.4, approachGain = 0.5, hoverLearn = 0.15, velP = 0.3, maxCorrection = 0.25 })
  local now = 100000
  r.sc:start({ engineOn = true, fuelled = true, onGround = true, velocityVector = "vector" },
    { now = now, altitude = 74.5 })
  r.sc.run.collective = 0.6
  r.sc.run.lastRegAt = now
  local before = r.sc.run.collective
  -- 1 block up but climbing at 1.5 m/s -- far over the 0.4 approach speed, so it must ease off.
  r.sc:regulateHeight({ altitude = 74.5 + 1.0, velocity = { x = 0, y = 1.5, z = 0 } }, now + 100)
  T.isTrue(r.sc.run.collective < before,
    "eased off despite being below target: " .. before .. " -> " .. r.sc.run.collective)
end)

T.it("float regulation still adds lift when below target and not yet climbing", function()
  local r = scRig({ hoverHeight = 2.0, hoverTolerance = 0.5,
    approachSpeed = 0.4, approachGain = 0.5, hoverLearn = 0.15, velP = 0.3, maxCorrection = 0.25 })
  local now = 100000
  r.sc:start({ engineOn = true, fuelled = true, onGround = true, velocityVector = "vector" },
    { now = now, altitude = 74.5 })
  r.sc.run.collective = 0.6
  r.sc.run.lastRegAt = now
  local before = r.sc.run.collective
  -- On the ground, not moving: it must add lift to get airborne.
  r.sc:regulateHeight({ altitude = 74.5, velocity = { x = 0, y = 0, z = 0 } }, now + 100)
  T.isTrue(r.sc.run.collective > before,
    "adds lift to start rising: " .. before .. " -> " .. r.sc.run.collective)
end)

--- The reported LEAP: a DISTANT target (a 5-10 block hover, a long rope) must NOT slam the throttle
--- to full and fling the craft into the rope. The capped approach speed means a far target is
--- approached no harder than a near one. Contrast a 1-block gap with an 8-block gap: the collective
--- move must be essentially the same, not 8x.
T.it("a distant hover target does NOT over-drive the throttle (no rope-leaping)", function()
  local function moveFor(gap)
    local r = scRig({ hoverHeight = gap, hoverTolerance = 0.5,
      approachSpeed = 0.4, approachGain = 0.5, hoverLearn = 0.3, velP = 0.3, maxCorrection = 0.25 })
    local now = 100000
    r.sc:start({ engineOn = true, fuelled = true, onGround = true, velocityVector = "vector" },
      { now = now, altitude = 74.5 })
    r.sc.run.lastRegAt = now
    r.sc:regulateHeight({ altitude = 74.5, velocity = { x = 0, y = 0, z = 0 } }, now + 100)
    return r.sc.run.collective
  end
  local near, far = moveFor(1.0), moveFor(8.0)
  T.isTrue(math.abs(far - near) < 1e-9,
    "8-block target commands the same gentle throttle as a 1-block one: " .. near .. " vs " .. far)
end)

--- THE FIX, end to end against a plant WITH momentum (a heavy craft, hover at 0.7 -- the reported
--- case) and a DISTANT target (7 blocks, the reported 5-10 block hover): using the GENTLE in-game
--- defaults, the float must GLIDE up and hold, never over-driving to full and leaping high, and
--- never slamming back to the ground. Driven on regulateHeight with a real double-integrator.
T.it("float converges to a distant target in a momentum plant, no leap and no slam", function()
  local r = scRig({ hoverHeight = 7.0, hoverTolerance = 0.8,
    -- the shipping defaults, on purpose: this proves the config we ACTUALLY fly is stable
    approachSpeed = 0.4, approachGain = 0.5, hoverLearn = 0.3, velP = 0.3, maxCorrection = 0.25 })
  local now = 100000
  r.sc:start({ engineOn = true, fuelled = true, onGround = true, velocityVector = "vector" },
    { now = now, altitude = 74.5 })

  local alt, vy = 74.5, 0
  local hoverC, liftGain, drag, ground = 0.7, 10.0, 1.6, 74.5   -- heavy: needs 70% to hover
  local lifted, landedAfterLift, peak = false, false, 0
  for _ = 1, 1500 do                                            -- 150 s of float (distant target)
    now = now + 100
    r.sc.run.lastRegAt = now - 100
    r.sc:regulateHeight({ altitude = alt, velocity = { x = 0, y = vy, z = 0 } }, now)
    local c = r.sc.run.collective
    vy = vy + (liftGain * (c - hoverC) - drag * vy) * 0.1
    alt = alt + vy * 0.1
    if alt <= ground then alt = ground; if vy < 0 then vy = 0 end end
    local h = alt - ground
    if h > 3.0 then lifted = true end
    if lifted then peak = math.max(peak, h); if h < 0.5 then landedAfterLift = true end end
  end
  local finalH = alt - ground
  T.isTrue(finalH > 6.0 and finalH < 8.0, "settles near the 7.0 target, got " .. finalH)
  T.isFalse(landedAfterLift, "never slams back onto the ground after lifting")
  T.isTrue(peak < 8.5, "no leap past the target, peak " .. peak)
end)

--- THE REPORTED COLLAPSE, isolated: the mooring ROPE catches the craft ABOVE the band and holds it
--- there -- it has stopped rising but is not descending, because the rope, not thrust, now fixes its
--- height. The OLD controller kept integrating the hover estimate DOWN against that unmovable error;
--- by the time the rope went slack the throttle was far below hover and the craft dropped out of the
--- sky. Two things must hold: (1) while pinned, the hover estimate must NOT wind down; (2) when the
--- rope is then released, the craft must ease back to the band, never fall to the floor.
T.it("does not wind the hover estimate down while the rope pins it above the target", function()
  local r = scRig({ hoverHeight = 4.0, hoverTolerance = 0.5,
    approachSpeed = 0.4, approachGain = 0.5, hoverLearn = 0.3, velP = 0.3, maxCorrection = 0.25 })
  local now = 100000
  r.sc:start({ engineOn = true, fuelled = true, onGround = true, velocityVector = "vector" },
    { now = now, altitude = 74.5 })

  -- The craft has just overshot and the rope caught it 1.5 blocks above the band top: pinned high,
  -- held still. hoverEstimate sits at the throttle that lifted it there (a hair above true hover).
  local ground, pinnedH = 74.5, 6.0
  r.sc.run.hoverEstimate = 0.90
  r.sc.run.lastRegAt = now
  for _ = 1, 40 do                                              -- 4 s hanging on the rope, dead still
    now = now + 100
    r.sc:regulateHeight({ altitude = ground + pinnedH, velocity = { x = 0, y = 0, z = 0 } }, now)
  end
  T.isTrue(r.sc.run.hoverEstimate > 0.80,
    "the hover estimate held near hover instead of winding down against the rope, got "
    .. r.sc.run.hoverEstimate)

  -- Now the rope goes slack. Run the real momentum plant: the craft must settle back into the band,
  -- not drop to the ground because the estimate had been gutted.
  local alt, vy = ground + pinnedH, 0
  local hoverC, liftGain, drag = 0.85, 10.0, 1.6
  local minH = 99
  for _ = 1, 1500 do
    now = now + 100
    r.sc.run.lastRegAt = now - 100
    r.sc:regulateHeight({ altitude = alt, velocity = { x = 0, y = vy, z = 0 } }, now)
    local c = r.sc.run.collective
    vy = vy + (liftGain * (c - hoverC) - drag * vy) * 0.1
    alt = alt + vy * 0.1
    if alt <= ground then alt = ground; if vy < 0 then vy = 0 end end
    minH = math.min(minH, alt - ground)
  end
  T.isTrue(minH > 2.0,
    "after the rope released it eased down to the band, never dropping to the floor, min " .. minH)
  T.isTrue((alt - ground) > 3.0 and (alt - ground) < 5.0,
    "and held near the 4.0 target, got " .. (alt - ground))
end)

T.it("after easing down into the band, the float settles and proceeds", function()
  local r = scRig({ hoverHeight = 2.0, hoverTolerance = 0.5 })
  local now = 100000
  r.sc:start({ engineOn = true, fuelled = true, onGround = true, velocityVector = "vector" },
    { now = now, altitude = 74.5 })
  r.sc.run.collective = 0.9
  for _ = 1, 3 do                                      -- too high for a few ticks
    now = now + 100
    r.sc:tick({ now = now, altitude = 74.5 + 4.0, attitude = { pitch = 0, roll = 0 },
      velocity = { x = 0, y = 0, z = 0 }, engineOn = true })
  end
  T.eq(r.sc.run.phase, "float", "still regulating while too high")

  now = now + 100                                       -- now in the band (2.0) and slow
  r.sc:tick({ now = now, altitude = 74.5 + 2.0, attitude = { pitch = 0, roll = 0 },
    velocity = { x = 0, y = 0, z = 0 }, engineOn = true })
  T.eq(r.sc.run.phase, "settle", "in the band and slow -> settles and moves on")
end)

--- The probe run bleeds a little lift each cycle (a deflected lift nozzle tilts its thrust off
--- vertical), so the craft must be flown back up to height before every nozzle. If it CANNOT climb
--- back -- the reported symptom, the front touching down late in the run -- it must abort rather
--- than silently probe from the ground.
T.it("aborts LOST HEIGHT if it sinks mid-run and cannot climb back", function()
  local r = scRig()
  runBip(r.sc, r.per, function(ctx)
    -- Once past the float, jam the altitude to the ground so no amount of collective regains height.
    if r.sc.run and r.sc.run.phase ~= "float" then ctx.altitude = 74.5 end
  end)
  T.isFalse(r.sc:isRunning(), "the run stopped")
  T.eq(r.sc.lastRun.abortedShort, "LOST HEIGHT", "and says it lost height")
  T.isTrue(r.sc:pendingProposal() == nil, "an aborted run proposes nothing")
end)

--- A nozzle measured while the craft is touching down reads a suppressed response (the ground
--- arrests the motion), so the run must FLAG it low-confidence rather than trust it -- this is why
--- the reported ground-touch could have compromised the late nozzles' proposed mappings.
T.it("flags a nozzle probed while touching the ground as low confidence", function()
  local r = scRig()
  runBip(r.sc, r.per, function(ctx)
    if r.sc.run and r.sc.run.phase == "probe" then ctx.groundContact = true end
  end)
  T.isFalse(r.sc:isRunning(), "the run completed")
  local proposal = r.sc:pendingProposal()
  T.isTrue(type(proposal) == "table", "a proposal was still produced")
  local checked = 0
  for id, entry in pairs(proposal) do
    T.eq(entry.confidence, "low", id .. " probed on the ground must be low confidence")
    checked = checked + 1
  end
  T.isTrue(checked > 0, "at least one mapping was proposed and checked")
end)

return true
