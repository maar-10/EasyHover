--[[ Phase 5: telemetry out, commands in, and config paths.

     The command surface is the flight computer's only exposure to other computers, so the
     validation is tested as an adversary would probe it.
]]

local T = require("tests.util")
local Config = require("lib.config")
local State = require("lib.state")
local Log = require("lib.log")
local Telemetry = require("lib.telemetry")

local function quietLog() return Log.new({ level = "error", capacity = 50 }) end

local function rig()
  local cfg = Config.withDefaults({
    hardware = { thrusters = { { id = "l", peripheral = "p", group = "lift" } } },
  })
  local state = State.new({})
  return cfg, state, Telemetry.new(cfg, quietLog(), state)
end

-- ------------------------------------------------------------------ payload

T.suite("telemetry payload")

T.it("carries a protocol tag and an increasing sequence", function()
  local _, _, tel = rig()
  local first = tel:build()
  T.eq(first.proto, "eh1", "protocol tag, so a UI can reject a foreign message")
  T.eq(first.seq, 1, "first sequence")
  T.eq(tel:build().seq, 2, "increments")
  T.eq(first.role, "flight", "names the sender's role")
end)

T.it("reports whatever the state store holds", function()
  local _, state, tel = rig()
  state.mode = "HOVER"
  state:setGroup("attitude", { pitch = 3.5, roll = -1.25 })
  state:set("altitude.baro", 82.5)
  state:set("altitude.vs", -0.75)
  state:setGroup("engine", { master = true, available = true, nextFeedInMs = 4200 })
  local payload = tel:build()
  T.eq(payload.mode, "HOVER", "mode")
  T.near(payload.attitude.pitch, 3.5, 1e-9, "pitch")
  T.near(payload.altitude.baro, 82.5, 1e-9, "altitude")
  T.near(payload.altitude.vs, -0.75, 1e-9, "vertical speed")
  T.isTrue(payload.engine.master, "engine master")
  T.eq(payload.engine.nextFeedInMs, 4200, "engine countdown")
end)

T.it("includes the config view the panels edit", function()
  local cfg, _, tel = rig()
  cfg.engine.pulseMs = 350
  cfg.envelope.maxBankDeg = 17
  local payload = tel:build()
  T.eq(payload.config.enginePulseMs, 350, "engine pulse")
  T.eq(payload.config.maxBankDeg, 17, "bank limit")
  T.notNil(payload.config.maxClimbRate, "climb limit present")
end)

T.it("carries alarms so a panel can annunciate them", function()
  local _, state, tel = rig()
  state:raise("fuel", "caution", "thruster fuel 20%")
  local payload = tel:build()
  T.eq(#payload.alarms, 1, "one alarm")
  T.eq(payload.alarms[1].level, "caution", "level")
end)

T.it("is serialisable -- it has to survive rednet", function()
  local _, state, tel = rig()
  state:set("fuel.tanks", { { label = "Main", amount = 6000, capacity = 16000, fraction = 0.375 } })
  local payload = tel:build()
  local text = textutils.serialise(payload)
  local back = textutils.unserialise(text)
  T.notNil(back, "round-trips through serialisation")
  T.near(back.fuel.tanks[1].fraction, 0.375, 1e-9, "nested values survive")
end)

-- ------------------------------------------------------------------ commands

T.suite("command validation")

T.it("accepts a well-formed command and passes the fields through", function()
  local _, _, tel = rig()
  local cmd, err = tel:parseCommand({ cmd = "engineMaster", value = true }, 7, 1000)
  T.notNil(cmd, "accepted: " .. tostring(err))
  T.eq(cmd.cmd, "engineMaster", "name")
  T.eq(cmd.value, true, "value")
  T.eq(cmd.sender, 7, "sender recorded")
end)

T.it("rejects an unknown command", function()
  local _, _, tel = rig()
  local cmd, err = tel:parseCommand({ cmd = "selfDestruct" }, 7, 1000)
  T.isNil(cmd, "rejected")
  T.isTrue(tostring(err):find("unknown command") ~= nil, "reason")
end)

T.it("rejects anything that is not a table with a cmd field", function()
  local _, _, tel = rig()
  T.isNil(tel:parseCommand("engineMaster", 7, 1000), "a bare string")
  T.isNil(tel:parseCommand(nil, 7, 1000), "nil")
  T.isNil(tel:parseCommand({ value = true }, 7, 1000), "no cmd field")
  T.isNil(tel:parseCommand({ cmd = 42 }, 7, 1000), "cmd not a string")
end)

T.it("type-checks every field", function()
  local _, _, tel = rig()
  T.isNil(tel:parseCommand({ cmd = "engineMaster", value = "yes" }, 7, 1000), "string for boolean")
  T.isNil(tel:parseCommand({ cmd = "setAltitude", value = "high" }, 7, 1001), "string for number")
  T.isNil(tel:parseCommand({ cmd = "setAux", label = "lights" }, 7, 1002), "missing value")
  T.notNil(tel:parseCommand({ cmd = "setAux", label = "lights", value = true }, 7, 1003), "complete")
end)

T.it("enforces enums, so a mode can never be a typo", function()
  local _, _, tel = rig()
  T.isNil(tel:parseCommand({ cmd = "setFeel", value = "sport" }, 7, 1000), "not a feel mode")
  T.notNil(tel:parseCommand({ cmd = "setFeel", value = "stutter" }, 7, 1001), "is a feel mode")
  T.isNil(tel:parseCommand({ cmd = "setLateral", value = "hover" }, 7, 1002), "not a lateral mode")
  T.notNil(tel:parseCommand({ cmd = "setLateral", value = "precision" }, 7, 1003), "is one")
end)

T.it("rate-limits a flood instead of acting on it", function()
  local cfg, _, tel = rig()
  cfg.comms.commandRateLimit = 5
  local accepted = 0
  for i = 1, 20 do
    if tel:parseCommand({ cmd = "ping" }, 7, 5000 + i) then accepted = accepted + 1 end
  end
  T.eq(accepted, 5, "only the allowance got through")
  -- a second later the window has moved on
  T.notNil(tel:parseCommand({ cmd = "ping" }, 7, 7000), "allowed again after the window")
end)

T.it("counts what it dropped, for the diagnostics page", function()
  local _, _, tel = rig()
  tel:parseCommand({ cmd = "nope" }, 7, 1000)
  tel:parseCommand({ cmd = "ping" }, 7, 1001)
  local stats = tel:stats()
  T.eq(stats.received, 2, "received")
  T.eq(stats.dropped, 1, "dropped")
end)

-- ------------------------------------------------------------------ config paths

T.suite("config paths")

T.it("reads nested values, including inside lists", function()
  local cfg = Config.withDefaults({
    hardware = { thrusters = { { id = "a", peripheral = "p", group = "lift", maxVector = 0.42 } } },
  })
  T.eq(Config.get(cfg, "engine.pulseMs"), cfg.engine.pulseMs, "scalar")
  T.near(Config.get(cfg, "hardware.thrusters.1.maxVector"), 0.42, 1e-9, "list index")
  T.isNil(Config.get(cfg, "nope.not.here"), "missing path is nil, not an error")
end)

T.it("writes a valid value and reports the previous one", function()
  local cfg = Config.withDefaults({
    hardware = { thrusters = { { id = "a", peripheral = "p", group = "lift" } } },
  })
  local ok, errors, previous = Config.set(cfg, "engine.intervalMs", 6000)
  T.isTrue(ok, "accepted: " .. table.concat(errors or {}, "; "))
  T.eq(cfg.engine.intervalMs, 6000, "written")
  T.eq(previous, 8000, "previous value returned")
end)

T.it("refuses an unknown path rather than inventing a setting", function()
  local cfg = Config.withDefaults({})
  local ok, errors = Config.set(cfg, "engine.turboBoost", 11)
  T.isFalse(ok, "refused")
  T.containsMatch(errors, "no such config key", "reason")
  T.isNil(cfg.engine.turboBoost, "nothing was created")
end)

T.it("refuses a type change", function()
  local cfg = Config.withDefaults({})
  local ok, errors = Config.set(cfg, "engine.pulseMs", "fast")
  T.isFalse(ok, "refused")
  T.containsMatch(errors, "expects a number", "reason")
end)

T.it("REVERTS a change that would make the config invalid", function()
  local cfg = Config.withDefaults({
    hardware = { thrusters = { { id = "a", peripheral = "p", group = "lift" } } },
  })
  local before = cfg.engine.pulseMs
  -- a pulse longer than the interval would leave the funnel never blocked
  local ok, errors = Config.set(cfg, "engine.pulseMs", 99999)
  T.isFalse(ok, "refused")
  T.containsMatch(errors, "never be blocked", "the validator's reason came back")
  T.eq(cfg.engine.pulseMs, before, "and the old value was put back")
end)

T.it("a UI cannot break the cascade rate separation", function()
  local cfg = Config.withDefaults({
    hardware = { thrusters = { { id = "a", peripheral = "p", group = "lift" } } },
  })
  local ok = Config.set(cfg, "tuning.altitudeHz", 19)   -- attitudeHz is 20
  T.isFalse(ok, "refused")
  T.eq(cfg.tuning.altitudeHz, 5, "unchanged")
end)

return true
