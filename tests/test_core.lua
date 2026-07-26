--[[ Phase 1: util, config, state ]]

local T = require("tests.util")
local Util = require("lib.util")
local Config = require("lib.config")
local State = require("lib.state")

-- ------------------------------------------------------------------ util

T.suite("util")

T.it("clamp bounds both ends", function()
  T.eq(Util.clamp(5, 0, 3), 3, "high")
  T.eq(Util.clamp(-5, 0, 3), 0, "low")
  T.eq(Util.clamp(1, 0, 3), 1, "inside")
end)

T.it("deepMerge lets src scalars win and recurses maps", function()
  local merged = Util.deepMerge({ a = 1, nested = { x = 1, y = 2 } }, { a = 9, nested = { y = 5 } })
  T.eq(merged.a, 9, "scalar override")
  T.eq(merged.nested.x, 1, "untouched nested key survives")
  T.eq(merged.nested.y, 5, "nested override")
end)

T.it("deepMerge REPLACES lists instead of blending them", function()
  local merged = Util.deepMerge({ list = { 1, 2, 3 } }, { list = { 9 } })
  T.eq(#merged.list, 1, "list length")
  T.eq(merged.list[1], 9, "list content")
end)

T.it("deepMerge fills defaults into an empty table", function()
  local merged = Util.deepMerge({ nested = { x = 1 } }, { nested = {} })
  T.eq(merged.nested.x, 1, "empty map does not erase defaults")
end)

T.it("deepCopy does not alias nested tables", function()
  local src = { nested = { x = 1 } }
  local copy = Util.deepCopy(src)
  copy.nested.x = 2
  T.eq(src.nested.x, 1, "original unchanged")
end)

T.it("wrapDeg and angleDelta take the short way round", function()
  T.eq(Util.wrapDeg(370), 10, "370 -> 10")
  T.eq(Util.wrapDeg(-190), 170, "-190 -> 170")
  T.eq(Util.angleDelta(350, 10), 20, "across north")
  T.eq(Util.angleDelta(10, 350), -20, "back across north")
end)

-- ------------------------------------------------------------------ config

T.suite("config")

--- A minimal config that should validate cleanly.
local function goodConfig()
  return Config.withDefaults({
    hardware = {
      thrusters = {
        { id = "lift_fl", peripheral = "vector_thruster_0", group = "lift",
          pos = { x = -1, y = 0, z = 1 } },
        { id = "lift_fr", peripheral = "vector_thruster_1", group = "lift",
          pos = { x = 1, y = 0, z = 1 } },
        { id = "lift_rl", peripheral = "vector_thruster_2", group = "lift",
          pos = { x = -1, y = 0, z = -1 } },
        { id = "lift_rr", peripheral = "vector_thruster_3", group = "lift",
          pos = { x = 1, y = 0, z = -1 } },
      },
      relays = {
        { peripheral = "redstone_relay_0", side = "top", level = 8, purpose = "failsafe" },
      },
    },
  })
end

T.it("withDefaults keeps user values and supplies the rest", function()
  local cfg = Config.withDefaults({ tuning = { attitudeHz = 10 } })
  T.eq(cfg.tuning.attitudeHz, 10, "user value")
  T.eq(cfg.tuning.altitudeHz, 5, "default survives")
  T.notNil(cfg.envelope.maxBankDeg, "unrelated section present")
end)

T.it("old thruster entries gain fields added later (backward-additive)", function()
  local cfg = Config.withDefaults({
    hardware = { thrusters = { { id = "a", peripheral = "p", group = "lift" } } },
  })
  local t = cfg.hardware.thrusters[1]
  T.eq(t.id, "a", "id preserved")
  T.eq(t.maxVector, 0.6, "template field added")
  T.eq(t.enabled, true, "template default added")
  T.notNil(t.pos, "pos table added")
  T.eq(t.pos.x, 0, "pos default")
end)

T.it("a good config validates with no errors", function()
  local ok, errors = Config.validate(goodConfig())
  T.isTrue(ok, "valid: " .. table.concat(errors, "; "))
end)

T.it("cascade rate separation is enforced", function()
  local cfg = goodConfig()
  cfg.tuning.attitudeHz = 20
  cfg.tuning.altitudeHz = 10
  local ok, errors = Config.validate(cfg)
  T.isFalse(ok, "should reject")
  T.containsMatch(errors, "altitudeHz", "rate separation error")
end)

T.it("failsafe level must be an integer 0..15", function()
  local cfg = goodConfig()
  cfg.failsafe.redstoneLevel = 16
  local ok, errors = Config.validate(cfg)
  T.isFalse(ok, "16 rejected")
  T.containsMatch(errors, "redstoneLevel", "level error")

  cfg.failsafe.redstoneLevel = 7.5
  local ok2, errors2 = Config.validate(cfg)
  T.isFalse(ok2, "fractional rejected")
  T.containsMatch(errors2, "redstoneLevel", "fractional error")
end)

T.it("duplicate thruster ids are rejected", function()
  local cfg = goodConfig()
  cfg.hardware.thrusters[2].id = cfg.hardware.thrusters[1].id
  local ok, errors = Config.validate(cfg)
  T.isFalse(ok, "should reject")
  T.containsMatch(errors, "duplicated", "duplicate id error")
end)

T.it("a craft with no lift thruster is rejected", function()
  local cfg = goodConfig()
  for _, t in ipairs(cfg.hardware.thrusters) do t.group = "lateral" end
  local ok, errors = Config.validate(cfg)
  T.isFalse(ok, "should reject")
  T.containsMatch(errors, "lift thruster", "lift error")
end)

T.it("attitude control cannot run without pitch and roll indices", function()
  local cfg = goodConfig()
  cfg.sensors.gimbal.rollIndex = 0
  local ok, errors = Config.validate(cfg)
  T.isFalse(ok, "should reject")
  T.containsMatch(errors, "pitchIndex and rollIndex", "gimbal error")
end)

T.it("a missing yaw index warns rather than blocks", function()
  local cfg = goodConfig()
  cfg.sensors.gimbal.yawIndex = 0
  local ok, _, warnings = Config.validate(cfg)
  T.isTrue(ok, "still valid")
  T.containsMatch(warnings, "heading fallback", "yaw warning")
end)

T.it("a craft with no failsafe relay warns loudly", function()
  local cfg = goodConfig()
  cfg.hardware.relays = {}
  local ok, _, warnings = Config.validate(cfg)
  T.isTrue(ok, "legal but unwise")
  T.containsMatch(warnings, "drop the craft", "failsafe warning")
end)

T.it("failsafe level derives from learned hover trim plus bias", function()
  local cfg = goodConfig()
  cfg.control.altitude.hoverTrim = 0.5      -- 0.5 * 15 = 7.5 -> 8, +1 bias
  cfg.failsafe.biasSteps = 1
  local level, derived = Config.deriveFailsafeLevel(cfg)
  T.isTrue(derived, "derived")
  T.eq(level, 9, "level")
end)

T.it("failsafe level falls back to config when trim is unlearned", function()
  local cfg = goodConfig()
  cfg.control.altitude.hoverTrim = 0
  cfg.failsafe.redstoneLevel = 6
  local level, derived = Config.deriveFailsafeLevel(cfg)
  T.isFalse(derived, "not derived")
  T.eq(level, 6, "configured level")
end)

T.it("save then load round-trips, and load verifies", function()
  local path = "/test_cfg.tbl"
  local cfg = goodConfig()
  cfg.tuning.attitudeHz = 17
  local ok, err = Config.save(path, cfg)
  T.isTrue(ok, "save: " .. tostring(err))
  local loaded, existed = Config.load(path)
  T.isTrue(existed, "file existed")
  T.eq(loaded.tuning.attitudeHz, 17, "value survived")
  T.eq(#loaded.hardware.thrusters, 4, "thruster list survived")
  fs.delete(path)
end)

T.it("a missing config file yields defaults, not an error", function()
  local cfg, existed = Config.load("/definitely_not_here.tbl")
  T.isFalse(existed, "reports absence")
  T.eq(cfg.tuning.attitudeHz, 20, "defaults returned")
end)

-- ------------------------------------------------------------------ state

T.suite("state")

T.it("set and get round-trip", function()
  local s = State.new()
  s:set("attitude.pitch", 3.5)
  T.eq(s:get("attitude.pitch"), 3.5, "value")
  T.eq(s:get("nope", "fallback"), "fallback", "default")
end)

T.it("age and freshness track write time", function()
  local s = State.new({ staleMs = 100 })
  s:set("a", 1)
  T.isTrue(s:age("a") < 50, "just written")
  T.isTrue(s:isFresh("a"), "fresh")
  s:set("b", 2, os.epoch("utc") - 1000)
  T.isFalse(s:isFresh("b"), "backdated is stale")
  T.eq(s:age("never"), math.huge, "never written")
end)

T.it("fresh() refuses to hand back a stale value", function()
  local s = State.new({ staleMs = 100 })
  s:set("x", 42, os.epoch("utc") - 1000)
  T.eq(s:get("x"), 42, "raw get still works")
  T.eq(s:fresh("x", -1), -1, "fresh() substitutes the default")
end)

T.it("staleChannels lists exactly the stale ones", function()
  local s = State.new({ staleMs = 100 })
  s:set("fresh_one", 1)
  s:set("old_one", 1, os.epoch("utc") - 5000)
  local stale = s:staleChannels()
  T.containsMatch(stale, "old_one", "stale list")
  T.noMatch(stale, "fresh_one", "stale list")
end)

T.it("setGroup writes a whole prefix at once", function()
  local s = State.new()
  s:setGroup("attitude", { pitch = 1, roll = 2 })
  T.eq(s:get("attitude.pitch"), 1, "pitch")
  T.eq(s:get("attitude.roll"), 2, "roll")
end)

T.it("raise reports only genuinely new alarm events", function()
  local s = State.new()
  T.isTrue(s:raise("fuel", "caution", "low"), "first raise is an event")
  T.isFalse(s:raise("fuel", "caution", "still low"), "same level is not")
  T.isTrue(s:raise("fuel", "warning", "very low"), "escalation is")
  T.isTrue(s:clear("fuel"), "clear")
  T.isFalse(s:clear("fuel"), "clearing twice is not an event")
end)

T.it("worstAlarmLevel ranks correctly", function()
  local s = State.new()
  s:raise("a", "info", "x")
  s:raise("b", "warning", "y")
  s:raise("c", "caution", "z")
  T.eq(s:worstAlarmLevel(), "warning", "worst")
end)

T.it("view() nests dotted keys", function()
  local s = State.new()
  s:set("a.b.c", 7)
  s:set("a.b.d", 8)
  local v = s:view()
  T.eq(v.a.b.c, 7, "deep value")
  T.eq(v.a.b.d, 8, "sibling")
end)

T.it("snapshot carries values, ages and alarms", function()
  local s = State.new()
  s:set("k", 1)
  s:raise("alarm", "caution", "msg")
  s:bump("calls", 3)
  local snap = s:snapshot()
  T.eq(snap.values.k, 1, "value")
  T.notNil(snap.ages.k, "age")
  T.eq(#snap.alarms, 1, "alarm count")
  T.eq(snap.stats.calls, 3, "counter")
end)

return true
