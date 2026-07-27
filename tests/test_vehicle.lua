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

T.it("REFUSES to run on a craft that is flying under power", function()
  local app, path = appRig(fullCraft())
  app.state.mode = "HOVER"
  app.engine.master = true
  local ok, detail = app:handleCommand({ cmd = "selfTest", action = "start" })
  T.isFalse(ok, "refused in the air with the engine running")
  T.isTrue(tostring((detail or {}).error):find("ground") ~= nil,
    "and says why: " .. tostring((detail or {}).error))
  fs.delete(path)
end)

T.it("but ALLOWS it with the engine off, whatever the ground sensor believes", function()
  -- GROUND depends on a down-facing laser being assigned. Requiring it would deny the
  -- pre-flight test to exactly the half-configured craft that most needs it -- and a craft
  -- whose thrusters have no fuel is not holding itself up regardless.
  local app, path = appRig(fullCraft())
  app.state.mode = "HOVER"
  app.engine.master = false
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

T.it("refuses while a thruster is producing thrust", function()
  local app, path = appRig(fullCraft())
  app.state.mode = "GROUND"
  -- ACTUAL thrust, which is what the interlock is about. Stubbing getPower here used to be
  -- enough, and that was the bug: getPower is the throttle the flight computer last asked for.
  app.per.thrusters["lift_fl"].dev.getCurrentThrustKN = function() return 12.0 end
  local ok, detail = app:handleCommand({ cmd = "selfTest", action = "start" })
  T.isFalse(ok, "refused")
  T.isTrue(tostring((detail or {}).error):find("thrust") ~= nil,
    "and says why: " .. tostring((detail or {}).error))
  fs.delete(path)
end)

--- THE FALSE POSITIVE THE PILOT HIT. Engine off, nothing burning, and the sweep still said
--- "CUT THE ENGINE" -- with no way to comply, because the reading came from the flight computer
--- own command rather than from the engine.
---
--- `Thrusters:apply` runs every control cycle regardless of the engine master, so the altitude
--- loop keeps asking the lift thrusters for lift while the craft sits on the ground. getPower
--- read that back as about 0.2 and the interlock called it thrust.
T.it("ALLOWS the sweep on a parked craft whose throttles are commanded but unfuelled", function()
  local app, path = appRig(fullCraft())
  app.engine.master = false
  app.state.mode = "GROUND"

  -- no fuel is reaching anything: throttle holds, physics reads zero
  for _, entry in ipairs(app.per:thrusterList()) do
    if entry.dev.__setFuelled then entry.dev.__setFuelled(false) end
  end
  -- let the control loop command lift, exactly as it does in game
  for _ = 1, 10 do app:cycle(0.05) end

  local commanded = app.per.thrusters["lift_fl"].dev.getPower()
  T.isTrue(commanded > 0.001,
    "precondition: the mixer really is holding a throttle (" .. tostring(commanded) .. ")")
  T.eq(app.per.thrusters["lift_fl"].dev.getCurrentThrustKN(), 0, "but nothing is firing")

  local ok, detail = app:handleCommand({ cmd = "selfTest", action = "start" })
  T.isTrue(ok, "permitted: " .. tostring((detail or {}).error))
  fs.delete(path)
end)

T.it("and takes those commanded throttles to zero once it owns the thrusters", function()
  -- Otherwise the mixer last command stands for the whole 45 seconds, ready to become real
  -- thrust the moment someone opens the fuel valve.
  local app, path = appRig(fullCraft())
  app.engine.master = false
  app.state.mode = "GROUND"
  for _, entry in ipairs(app.per:thrusterList()) do
    if entry.dev.__setFuelled then entry.dev.__setFuelled(false) end
  end
  for _ = 1, 10 do app:cycle(0.05) end
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
    { name = "airborne under power", setup = function(app)
        app.state.mode = "HOVER"; app.engine.master = true
      end },
    { name = "a thruster making thrust", setup = function(app)
        app.state.mode = "GROUND"
        app.per.thrusters["lift_fl"].dev.getCurrentThrustKN = function() return 9.0 end
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

return true
