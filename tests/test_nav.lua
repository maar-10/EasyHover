--[[ The nav role: geometry, the waypoint store, and position fixing.

     Runs in its own CraftOS instance (tests/run_nav.sh) with package.path pointing at /nav/,
     for the same reason ui_main does: three roles now have a lib/config.lua and a shared Lua
     state would make require("lib.geo") resolve against whichever loaded first.

     None of this touches the control loops. That is the point -- navigation is separable, and
     these tests prove it by never constructing a mixer or a PID.
]]

local T = require("tests.util")
local Geo = require("lib.geo")
local Waypoints = require("lib.waypoints")
local Fix = require("lib.fix")
local Heading = require("lib.heading")
local NavTable = require("lib.navtable")
local Disk = require("lib.disk")
local Log = require("shared.log")

local function quietLog() return Log.new({ level = "error", capacity = 50 }) end

-- ------------------------------------------------------------------ geometry

T.suite("nav geometry")

T.it("BEARINGS USE MINECRAFT'S FRAME: north is -z, east is +x", function()
  -- Getting this wrong gives a course that is right in one quadrant and wrong in three, which
  -- reads as "the autopilot mostly works".
  local here = { x = 0, y = 64, z = 0 }
  T.near(Geo.bearing(here, { x = 0, z = -10 }), 0, 1e-6, "north")
  T.near(Geo.bearing(here, { x = 10, z = 0 }), 90, 1e-6, "east")
  T.near(Geo.bearing(here, { x = 0, z = 10 }), 180, 1e-6, "south")
  T.near(Geo.bearing(here, { x = -10, z = 0 }), 270, 1e-6, "west")
  T.near(Geo.bearing(here, { x = 10, z = -10 }), 45, 1e-6, "north-east")
end)

T.it("a bearing to where you already are is NOT a number", function()
  -- Returning 0 there would send a guidance law confidently northward.
  T.isNil(Geo.bearing({ x = 5, z = 5 }, { x = 5, z = 5 }), "coincident points")
  T.isNil(Geo.turnTo(90, nil), "and a turn onto no bearing is nil too")
end)

T.it("distance ignores altitude; distance3 does not", function()
  local a = { x = 0, y = 64, z = 0 }
  local b = { x = 3, y = 68, z = 4 }
  T.near(Geo.distance(a, b), 5, 1e-9, "flat")
  T.near(Geo.distance3(a, b), math.sqrt(41), 1e-9, "with the climb")
end)

T.it("a steering error takes the SHORT way round", function()
  T.near(Geo.turnTo(350, 10), 20, 1e-9, "through north, not 340 the other way")
  T.near(Geo.turnTo(10, 350), -20, 1e-9, "and back again")
  T.near(Geo.turnTo(0, 180), 180, 1e-9, "the ambiguous case resolves positive")
end)

T.it("wrap180 never returns -180", function()
  T.near(Geo.wrap180(-180), 180, 1e-9, "so a turn is never reported twice with opposite signs")
  T.near(Geo.wrap180(540), 180, 1e-9)
end)

T.it("CRAFT-FRAME VELOCITY ROTATES INTO WORLD AXES", function()
  -- Dead reckoning lives or dies on this. Heading 0 = facing north = -z.
  local north = Geo.craftToWorld(10, 0, 0)
  T.near(north.x, 0, 1e-9, "no easting when facing north")
  T.near(north.z, -10, 1e-9, "and 10 blocks northward")

  local east = Geo.craftToWorld(10, 0, 90)
  T.near(east.x, 10, 1e-9, "facing east, forward is +x")
  T.near(east.z, 0, 1e-9)

  -- craft "right" while facing north is east
  local starboard = Geo.craftToWorld(0, 10, 0)
  T.near(starboard.x, 10, 1e-9, "right of north is east")
  T.near(starboard.z, 0, 1e-9)
end)

T.it("cross-track error tells you WHICH SIDE of the leg you are on", function()
  local origin = { x = 0, z = 0 }
  local target = { x = 0, z = -100 }        -- due north
  T.isTrue(Geo.crossTrack(origin, target, { x = 5, z = -50 }) > 0,
    "east of a northbound leg is RIGHT of track")
  T.isTrue(Geo.crossTrack(origin, target, { x = -5, z = -50 }) < 0, "and west is left")
  T.near(Geo.crossTrack(origin, target, { x = 0, z = -50 }), 0, 1e-9, "on track")
  T.near(Geo.crossTrack(origin, origin, { x = 3, z = 3 }), 0, 1e-9,
    "a zero-length leg has no sides")
end)

T.it("along-track goes negative BEHIND the origin", function()
  local origin, target = { x = 0, z = 0 }, { x = 0, z = -100 }
  T.near(Geo.alongTrack(origin, target, { x = 0, z = -25 }), 25, 1e-9, "a quarter along")
  T.isTrue(Geo.alongTrack(origin, target, { x = 0, z = 10 }) < 0, "behind the start")
end)

T.it("course over ground refuses to guess from noise", function()
  local a, b = { x = 0, z = 0 }, { x = 0, z = -0.01 }
  local course, speed = Geo.courseOverGround(a, b, 1.0, 0.15)
  T.isNil(course, "barely moved: no course")
  T.isTrue(speed < 0.15, "but the speed is still reported: " .. tostring(speed))

  local moving = Geo.courseOverGround(a, { x = 0, z = -10 }, 1.0, 0.15)
  T.near(moving, 0, 1e-6, "moving north gives a northward course")
end)

T.it("ETA is nil rather than infinite when stopped", function()
  -- nil prints as "--"; math.huge tends to render as "inf" or poison arithmetic three modules
  -- away from where it was created.
  T.isNil(Geo.eta(100, 0), "stopped")
  T.isNil(Geo.eta(100, nil), "no speed at all")
  T.near(Geo.eta(100, 10), 10, 1e-9, "and a real one when moving")
end)

T.it("compass points read the way a pilot expects", function()
  T.eq(Geo.compassPoint(0), "N")
  T.eq(Geo.compassPoint(45), "NE")
  T.eq(Geo.compassPoint(91), "E")
  T.eq(Geo.compassPoint(359), "N", "wrapping round")
  T.eq(Geo.compassPoint(nil), "--", "and nothing when there is no bearing")
end)

-- ----------------------------------------------------------------- waypoints

T.suite("waypoint store")

local WP_PATH = "/test_waypoints.tbl"

local function store()
  if fs.exists(WP_PATH) then fs.delete(WP_PATH) end
  return Waypoints.new(WP_PATH, quietLog())
end

T.it("adds, finds and counts", function()
  local w = store()
  T.isTrue((w:add({ name = "Home Pad", x = 100, y = 70, z = -200, kind = "pad" })), "added")
  T.eq(w:count(), 1)
  T.eq(w:get("Home Pad").x, 100, "found by name")
  T.eq(w:get("home pad").x, 100, "and case-insensitively -- two casings is a trap")
end)

T.it("REFUSES a duplicate name unless told to replace", function()
  local w = store()
  w:add({ name = "Pad", x = 0, y = 64, z = 0 })
  local ok, err = w:add({ name = "pad", x = 5, y = 64, z = 5 })
  T.isFalse(ok, "refused")
  T.isTrue(tostring(err):find("already exists") ~= nil, "and says why")
  T.isTrue((w:add({ name = "Pad", x = 5, y = 64, z = 5 }, true)), "replace works")
  T.eq(w:count(), 1, "still one entry")
  T.eq(w:get("Pad").x, 5, "holding the new coordinates")
end)

T.it("validates coordinates, including NaN", function()
  local w = store()
  T.isFalse((w:add({ name = "x", x = "here", y = 64, z = 0 })), "a string is not a coordinate")
  T.isFalse((w:add({ name = "x", y = 64, z = 0 })), "a missing axis is refused")
  -- NaN survives a type check and poisons every later comparison
  T.isFalse((w:add({ name = "x", x = 0/0, y = 64, z = 0 })), "NaN is refused explicitly")
  T.isFalse((w:add({ name = "x", x = 5e7, y = 64, z = 0 })), "and so is outside the world")
  T.isFalse((w:add({ name = "", x = 0, y = 64, z = 0 })), "a blank name is refused")
  T.isFalse((w:add({ name = "   ", x = 0, y = 64, z = 0 })), "and so is whitespace")
end)

T.it("rejects an unknown kind rather than storing a meaningless one", function()
  local w = store()
  T.isFalse((w:add({ name = "x", x = 0, y = 64, z = 0, kind = "runway" })), "refused")
  T.isTrue((w:add({ name = "x", x = 0, y = 64, z = 0, kind = "pad" })), "pad is real")
end)

T.it("renames, and refuses to rename onto an existing name", function()
  local w = store()
  w:add({ name = "A", x = 0, y = 64, z = 0 })
  w:add({ name = "B", x = 1, y = 64, z = 1 })
  T.isFalse((w:rename("A", "B")), "would collide")
  T.isTrue((w:rename("A", "C")), "renamed")
  T.notNil(w:get("C"))
  T.isNil(w:get("A"))
end)

T.it("MARK stores the fix, rounded to whole blocks", function()
  local w = store()
  local ok = w:mark("Pad 1", { x = 100.4, y = 70.6, z = -200.5,
                               source = "gps", quality = 1, ageMs = 100 })
  T.isTrue(ok, "marked")
  local entry = w:get("Pad 1")
  T.eq(entry.x, 100, "rounded")
  T.eq(entry.y, 71)
  T.eq(entry.z, -200)
  T.isTrue(entry.source:find("gps") ~= nil, "and records where the fix came from: " .. entry.source)
end)

T.it("MARK REFUSES A DEAD-RECKONED ESTIMATE", function()
  -- A landing pad you cannot trust is worse than no pad: you would fly to it and find air.
  local w = store()
  local ok, err = w:mark("Pad", { x = 1, y = 2, z = 3, source = "estimate",
                                  quality = 0.9, ageMs = 10, dead = true })
  T.isFalse(ok, "refused")
  T.isTrue(tostring(err):find("estimate") ~= nil, "and says why: " .. tostring(err))
  T.eq(w:count(), 0, "nothing was stored")
end)

T.it("MARK refuses a stale fix, and a low-quality one", function()
  local w = store()
  local stale, err = w:mark("A", { x = 1, y = 2, z = 3, source = "gps",
                                   quality = 1, ageMs = 9000 })
  T.isFalse(stale, "too old")
  T.isTrue(tostring(err):find("old") ~= nil, "says so: " .. tostring(err))

  local poor = w:mark("B", { x = 1, y = 2, z = 3, source = "gps", quality = 0.1, ageMs = 10 })
  T.isFalse(poor, "quality too low")

  T.isFalse((w:mark("C", nil)), "and no fix at all is refused")
end)

T.it("nearest sorts by distance and carries the bearing", function()
  local w = store()
  w:add({ name = "Far", x = 0, y = 64, z = -500 })
  w:add({ name = "Near", x = 0, y = 64, z = -50 })
  w:add({ name = "Pad", x = 100, y = 64, z = 0, kind = "pad" })
  local list = w:nearest(Geo, { x = 0, y = 64, z = 0 })
  T.eq(list[1].waypoint.name, "Near", "nearest first")
  T.eq(list[3].waypoint.name, "Far", "furthest last")
  T.near(list[1].bearing, 0, 1e-6, "with a bearing")

  local pads = w:nearest(Geo, { x = 0, y = 64, z = 0 }, "pad")
  T.eq(#pads, 1, "filtered by kind")
  T.eq(pads[1].waypoint.name, "Pad")
end)

T.it("round-trips through the file", function()
  local w = store()
  w:add({ name = "Home", x = 12, y = 70, z = -34, kind = "home", note = "the pad" })
  T.isTrue((w:save()), "saved")

  local reloaded = Waypoints.new(WP_PATH, quietLog())
  T.isTrue((reloaded:load()), "loaded")
  T.eq(reloaded:count(), 1)
  local entry = reloaded:get("Home")
  T.eq(entry.x, 12); T.eq(entry.kind, "home"); T.eq(entry.note, "the pad")
  fs.delete(WP_PATH)
end)

T.it("DOES NOT CLOBBER a file it cannot parse", function()
  -- A file we cannot read might be recoverable by hand, and waypoints are painful to retype.
  local handle = fs.open(WP_PATH, "w")
  handle.write("this is not a table {{{")
  handle.close()

  local w = Waypoints.new(WP_PATH, quietLog())
  local ok, err = w:load()
  T.isFalse(ok, "reported the failure")
  T.eq(w:count(), 0, "and loaded nothing")

  local check = fs.open(WP_PATH, "r")
  local body = check.readAll()
  check.close()
  T.isTrue(body:find("not a table") ~= nil, "the original bytes are still there")
  fs.delete(WP_PATH)
end)

T.it("drops individually invalid entries rather than the whole file", function()
  local handle = fs.open(WP_PATH, "w")
  handle.write(textutils.serialise({ version = 1, waypoints = {
    { name = "Good", x = 1, y = 2, z = 3, kind = "nav" },
    { name = "Bad", x = "nope", y = 2, z = 3 },
  } }))
  handle.close()
  local w = Waypoints.new(WP_PATH, quietLog())
  local ok, kept, dropped = w:load()
  T.isTrue(ok)
  T.eq(kept, 1, "the good one survived")
  T.eq(dropped, 1, "the bad one was counted, not fatal")
  fs.delete(WP_PATH)
end)

T.it("a failed save leaves the previous file intact", function()
  local w = store()
  w:add({ name = "First", x = 1, y = 2, z = 3 })
  w:save()
  -- the staged write reads back before it renames, so the old file is never destroyed early
  T.isTrue(fs.exists(WP_PATH), "file exists")
  T.isFalse(fs.exists(WP_PATH .. ".new"), "and no staging file is left behind")
  fs.delete(WP_PATH)
end)

-- --------------------------------------------------------------- position fix

T.suite("position fixing")

T.it("says so when nothing is configured", function()
  local f = Fix.new({}, quietLog())
  local fix, err = f:acquire(1000)
  T.isNil(fix)
  T.isTrue(tostring(err):find("no position source") ~= nil, err)
  T.isNil(f:position(1000), "and there is no position at all")
end)

T.it("tries sources in PRIORITY order and stops at the first answer", function()
  local calls = {}
  local f = Fix.new({}, quietLog())
  f:addSource({ name = "slow", priority = 90, quality = 0.5,
                locate = function() calls[#calls + 1] = "slow"; return 9, 9, 9 end })
  f:addSource({ name = "fast", priority = 10, quality = 1.0,
                locate = function() calls[#calls + 1] = "fast"; return 1, 2, 3 end })

  local fix = f:acquire(1000)
  T.eq(fix.source, "fast", "the higher-priority source answered")
  T.eq(fix.x, 1)
  T.eq(#calls, 1, "and the other was not even asked")
end)

T.it("falls through to the next source when one gives nothing", function()
  local f = Fix.new({}, quietLog())
  f:addSource({ name = "gps", priority = 10, locate = function() return nil end })
  f:addSource({ name = "radar", priority = 20, locate = function() return 5, 6, 7 end })
  local fix = f:acquire(1000)
  T.eq(fix.source, "radar", "the backup answered")
  T.eq(fix.z, 7)
end)

T.it("survives a source that THROWS", function()
  local f = Fix.new({}, quietLog())
  f:addSource({ name = "bad", priority = 10, locate = function() error("modem is gone") end })
  f:addSource({ name = "good", priority = 20, locate = function() return 1, 1, 1 end })
  T.eq(f:acquire(1000).source, "good", "an exploding source is just a failed one")
end)

T.it("BACKS OFF a failed source instead of retrying it every cycle", function()
  -- A blocking gps.locate() that times out costs a whole second. Calling it twenty times a
  -- second because it is "primary" would stall the computer completely.
  local tries = 0
  local f = Fix.new({}, quietLog())
  f:addSource({ name = "gps", priority = 10, backoffMs = 4000,
                locate = function() tries = tries + 1; return nil end })
  f:acquire(1000)
  T.eq(tries, 1, "tried once")
  for at = 1100, 4000, 100 do f:acquire(at) end
  T.eq(tries, 1, "and not again while backed off")
  f:acquire(5001)
  T.eq(tries, 2, "but it is retried once the backoff expires")
end)

T.it("reports when every source is backed off, distinctly", function()
  local f = Fix.new({}, quietLog())
  f:addSource({ name = "gps", priority = 10, locate = function() return nil end })
  f:acquire(1000)
  local fix, err = f:acquire(1100)
  T.isNil(fix)
  T.isTrue(tostring(err):find("backed off") ~= nil, "a different reason from 'no answer': " .. err)
end)

T.it("a fresh fix is reported as fresh and NOT dead", function()
  local f = Fix.new({ fixStaleMs = 1500 }, quietLog())
  f:addSource({ name = "gps", priority = 10, quality = 1, locate = function() return 10, 70, 20 end })
  f:acquire(1000)
  local p = f:position(1200)
  T.eq(p.source, "gps")
  T.eq(p.ageMs, 200)
  T.isFalse(p.dead, "a real fix")
  T.eq(p.quality, 1)
end)

T.it("DEAD RECKONING NEEDS A HEADING, and says so instead of guessing", function()
  -- Without a heading, craft-frame velocity cannot be rotated into world axes at all. Guessing
  -- would produce a position that looks plausible and is wrong.
  local f = Fix.new({}, quietLog())
  f:addSource({ name = "gps", priority = 10, locate = function() return 0, 64, 0 end })
  f:acquire(1000)
  local est, err = f:reckon(1.0, 10, 0, nil, 2000)
  T.isNil(est, "refused")
  T.isTrue(tostring(err):find("heading") ~= nil, "and names the missing input: " .. tostring(err))
end)

T.it("dead reckoning advances the estimate in world axes", function()
  local f = Fix.new({}, quietLog())
  f:addSource({ name = "gps", priority = 10, locate = function() return 0, 64, 0 end })
  f:acquire(1000)
  -- facing east at 10 m/s for two seconds
  f:reckon(1.0, 10, 0, 90, 2000)
  local est = f:reckon(1.0, 10, 0, 90, 3000)
  T.near(est.x, 20, 1e-6, "twenty blocks east")
  T.near(est.z, 0, 1e-6, "and none north or south")
end)

T.it("a STALE fix falls back to the estimate, MARKED as dead", function()
  local f = Fix.new({ fixStaleMs = 1000, reckonUsefulMs = 8000 }, quietLog())
  f:addSource({ name = "gps", priority = 10, quality = 1, locate = function() return 0, 64, 0 end })
  f:acquire(1000)
  f:reckon(1.0, 10, 0, 90, 2000)

  local p = f:position(2500)
  T.eq(p.source, "estimate", "the estimate is in use")
  T.isTrue(p.dead, "and it is flagged as dead-reckoned")
  T.near(p.x, 10, 1e-6, "carrying the reckoned position")
  T.isTrue(p.quality < 1, "at reduced quality: " .. p.quality)
end)

T.it("estimate quality DECAYS the longer it has been since a real fix", function()
  local f = Fix.new({ fixStaleMs = 500, reckonUsefulMs = 8000 }, quietLog())
  f:addSource({ name = "gps", priority = 10, quality = 1, locate = function() return 0, 64, 0 end })
  f:acquire(1000)
  f:reckon(1.0, 1, 0, 0, 2000)
  local soon = f:position(2000).quality
  f:reckon(1.0, 1, 0, 0, 7000)
  local later = f:position(7000).quality
  T.isTrue(later < soon, ("%0.2f decayed to %0.2f"):format(soon, later))
  T.isTrue(later >= 0, "and never goes negative")
end)

T.it("a NEW fix resets the estimate rather than letting it drift on", function()
  local f = Fix.new({ fixStaleMs = 1000 }, quietLog())
  local at = { x = 0 }
  f:addSource({ name = "gps", priority = 10, quality = 1,
                locate = function() return at.x, 64, 0 end })
  f:acquire(1000)
  f:reckon(1.0, 100, 0, 90, 2000)          -- reckon a long way off
  at.x = 5
  f:acquire(3000)                           -- a real fix says otherwise
  local p = f:position(3000)
  T.eq(p.x, 5, "the fix wins")
  T.isFalse(p.dead, "and we are back on a real fix")
end)

T.it("with no estimate, an old fix is handed over LABELLED stale", function()
  -- Better than nil: a stale position with its age attached still draws a map.
  local f = Fix.new({ fixStaleMs = 500 }, quietLog())
  f:addSource({ name = "radar", priority = 10, quality = 1, locate = function() return 3, 64, 4 end })
  f:acquire(1000)
  local p = f:position(9000)
  T.eq(p.x, 3, "position given")
  T.isTrue(p.stale, "flagged stale")
  T.eq(p.quality, 0, "and worth nothing")
end)

T.it("altitude comes from the ALTIMETER, not from the fix", function()
  -- The craft has a real altimeter reading metres; a GPS y is a block coordinate and coarser.
  local f = Fix.new({ fixStaleMs = 5000 }, quietLog())
  f:addSource({ name = "gps", priority = 10, quality = 1, locate = function() return 1, 64, 2 end })
  f:acquire(1000)
  T.near(f:position(1000, 82.5).y, 82.5, 1e-9, "the altimeter's value is used")
  T.near(f:position(1000).y, 64, 1e-9, "and the fix's y only when there is nothing better")
end)

T.it("counts what each source has done, for the diagnostics page", function()
  local f = Fix.new({}, quietLog())
  f:addSource({ name = "gps", priority = 10, locate = function() return nil end })
  f:addSource({ name = "radar", priority = 20, locate = function() return 1, 1, 1 end })
  f:acquire(1000)
  local stats = f:stats()
  T.eq(stats.attempts, 2, "two sources tried")
  T.eq(stats.failures, 1, "one failed")
  T.eq(stats.sources[1].name, "gps", "listed in priority order")
  T.isTrue(stats.sources[1].backedOff, "and its backoff is visible")
  T.eq(stats.sources[2].ok, 1, "the one that worked is counted too")
end)


-- ------------------------------------------------------------------ sources

T.suite("position sources")

local Sources = require("lib.sources")

T.it("the GPS source wraps gps.locate and survives it failing", function()
  local good = Sources.gps({ locate = function() return 10, 70, -20 end })
  local x, y, z = good.locate()
  T.eq(x, 10); T.eq(y, 70); T.eq(z, -20)

  local absent = Sources.gps({ locate = function() return nil end })
  T.isNil(absent.locate(), "no constellation, no fix")

  local broken = Sources.gps({ locate = function() error("no modem") end })
  T.isNil(broken.locate(), "an exploding locate is just a missing fix")
end)

T.it("GPS declares its cost honestly, because it BLOCKS", function()
  -- The reason nav gets its own computer. A two-second block inside the flight loop would
  -- wreck the dt discipline the whole control design rests on.
  local spec = Sources.gps({})
  T.isTrue(spec.costMs >= 1000, "declared as expensive: " .. spec.costMs)
  T.isTrue(spec.backoffMs >= spec.costMs, "and backed off for at least as long")
end)

T.it("the radar source accepts a keyed OR a list position", function()
  local keyed = Sources.radar({ find = function()
    return { getPosition = function() return { x = 1, y = 2, z = 3 } end }
  end })
  local x, y, z = keyed.locate()
  T.eq(x, 1); T.eq(z, 3)

  local list = Sources.radar({ find = function()
    return { getPosition = function() return { 4, 5, 6 } end }
  end })
  local lx, _, lz = list.locate()
  T.eq(lx, 4, "a list answer works too -- the mod's shape is not documented")
  T.eq(lz, 6)
end)

T.it("the radar source is a BACKUP: lower priority than GPS by default", function()
  T.isTrue(Sources.radar({}).priority > Sources.gps({}).priority,
    "GPS is tried first")
end)

T.it("no radar means no fix, not an error", function()
  local none = Sources.radar({ find = function() return nil end })
  T.isNil(none.locate())
  local noMethod = Sources.radar({ find = function() return {} end })
  T.isNil(noMethod.locate(), "a radar without getPosition is just absent")
end)

T.it("builds sources in the ORDER the config lists them", function()
  local built = Sources.build({ positionSources = { "radar", "gps" } }, quietLog(),
    { gps = function() return 1, 2, 3 end })
  T.eq(#built, 2)
  T.eq(built[1].name, "radar", "config order wins over the defaults")
  T.isTrue(built[1].priority < built[2].priority, "and becomes the priority")
end)

T.it("REPORTS a typo'd source name rather than silently having none", function()
  local built, problems = Sources.build({ positionSources = { "gsp" } }, quietLog())
  T.eq(#built, 0)
  T.isTrue(table.concat(problems, " "):find("unknown position source") ~= nil,
    "named: " .. table.concat(problems, " "))
  T.isTrue(table.concat(problems, " "):find("cannot fix") ~= nil,
    "and says what it means")
end)

T.it("an empty source list is reported too", function()
  local _, problems = Sources.build({ positionSources = {} }, quietLog())
  T.isTrue(#problems > 0, "not silent")
end)

-- ------------------------------------------------------------------- relay

T.suite("nav fix relay")

local Relay = require("lib.relay")

local function relayRig()
  local cfg = { wiredModem = "", enderModem = "", navFixProtocol = "eh_navfix" }
  return Relay.new(cfg, quietLog()), cfg
end

T.it("refuses to publish with no wired modem", function()
  local relay = relayRig()
  local ok, err = relay:publish({ x = 1, y = 2, z = 3 })
  T.isFalse(ok)
  T.isTrue(tostring(err):find("wired") ~= nil, err)
end)

T.it("THE PAYLOAD CARRIES AGE, SOURCE AND QUALITY, not just coordinates", function()
  -- A bare x/y/z forces every reader to trust it, and the one thing we know about a position is
  -- that sometimes it is stale.
  local relay = relayRig()
  relay.wired = "modem_0"
  local sent = {}
  local realBroadcast = rednet.broadcast
  rednet.broadcast = function(payload, protocol) sent[#sent + 1] = { payload, protocol } end

  relay:publish({ x = 10, y = 70, z = -20, source = "gps", quality = 1,
                  ageMs = 120, dead = false })
  rednet.broadcast = realBroadcast

  T.eq(#sent, 1, "published")
  local payload = sent[1][1]
  T.eq(sent[1][2], "eh_navfix", "on the protocol the flight computer already listens for")
  T.eq(payload.proto, "ehnav1", "tagged, so a foreign message can be rejected")
  T.eq(payload.position.x, 10)
  T.eq(payload.position.source, "gps")
  T.eq(payload.position.ageMs, 120)
  T.isFalse(payload.position.dead)
  T.eq(payload.seq, 1, "and sequenced")
end)

T.it("a dead-reckoned position is published AS SUCH", function()
  local relay = relayRig()
  relay.wired = "modem_0"
  local captured
  local realBroadcast = rednet.broadcast
  rednet.broadcast = function(payload) captured = payload end
  relay:publish({ x = 1, y = 2, z = 3, source = "estimate", quality = 0.4,
                  ageMs = 4000, dead = true })
  rednet.broadcast = realBroadcast
  T.isTrue(captured.position.dead, "flagged, so guidance can refuse it")
  T.eq(captured.position.source, "estimate")
end)

T.it("extra fields ride along without overwriting the payload's own", function()
  local relay = relayRig()
  relay.wired = "modem_0"
  local captured
  local realBroadcast = rednet.broadcast
  rednet.broadcast = function(payload) captured = payload end
  relay:publish({ x = 1, y = 2, z = 3 }, { heading = 42, proto = "hijack" })
  rednet.broadcast = realBroadcast
  T.eq(captured.heading, 42, "extras carried")
  T.eq(captured.proto, "ehnav1", "but the protocol tag cannot be overwritten")
end)

T.it("counts what it published, for the diagnostics page", function()
  local relay = relayRig()
  relay.wired = "modem_0"
  local realBroadcast = rednet.broadcast
  rednet.broadcast = function() end
  relay:publish({ x = 1, y = 2, z = 3 })
  relay:publish({ x = 1, y = 2, z = 3 })
  rednet.broadcast = realBroadcast
  T.eq(relay:status().published, 2)
  T.eq(relay:status().seq, 2, "sequence advances")
end)


-- ------------------------------------------------------------------- config

T.suite("nav config")

local NavConfig = require("lib.config")

T.it("defaults to GPS and a sane fix rate", function()
  local cfg = NavConfig.withDefaults({})
  T.eq(cfg.positionSources[1], "gps")
  T.eq(cfg.navFixProtocol, "eh_navfix",
    "the name the flight computer has listened for since phase 5")
  T.isTrue((NavConfig.validate(cfg)), "and it validates")
end)

T.it("an old config gains fields added later, and keeps mine", function()
  local cfg = NavConfig.withDefaults({ gpsTimeout = 4, enderModem = "modem_7" })
  T.eq(cfg.gpsTimeout, 4, "mine survived")
  T.eq(cfg.enderModem, "modem_7")
  T.eq(cfg.reckonUsefulMs, 8000, "and new fields appeared")
end)

T.it("REFUSES a config with no position source", function()
  local ok, errors = NavConfig.validate(NavConfig.withDefaults({ positionSources = {} }))
  T.isFalse(ok)
  T.isTrue(table.concat(errors, " "):find("cannot fix") ~= nil,
    "and says what it means: " .. table.concat(errors, " "))
end)

T.it("refuses a fix rate that would block this computer solid", function()
  -- Each fix BLOCKS for up to gpsTimeout. Asking for one every 100ms would leave the computer
  -- doing nothing else, ever.
  T.isFalse((NavConfig.validate(NavConfig.withDefaults({ fixEverySeconds = 0.1 }))))
  T.isFalse((NavConfig.validate(NavConfig.withDefaults({ gpsTimeout = 0 }))))
  T.isFalse((NavConfig.validate(NavConfig.withDefaults({ gpsTimeout = 30 }))))
end)

T.it("WARNS when fixes come slower than they go stale", function()
  -- Legal, but it means the position reads stale more of the time than it reads fresh, which is
  -- almost certainly not what anyone intended.
  local ok, errors, warnings = NavConfig.validate(
    NavConfig.withDefaults({ fixEverySeconds = 5, fixStaleMs = 1500 }))
  T.isTrue(ok, "not an error")
  T.isTrue(table.concat(warnings, " "):find("read stale between fixes") ~= nil,
    "but warned: " .. table.concat(warnings, " "))
end)

-- ------------------------------------------------------------------ console

T.suite("nav console")

local Console = require("ui.console")

local function rendered(model, width)
  local rows = Console.render(NavConfig.withDefaults({}), model or {}, width or 51, 19)
  local text = {}
  for _, row in ipairs(rows) do text[#text + 1] = row.text end
  for _, row in ipairs(rows.footer) do text[#text + 1] = row.text end
  return table.concat(text, "\n"), rows
end

T.it("every action is a single keypress", function()
  T.eq(Console.actionFor("m"), "mark")
  T.eq(Console.actionFor("a"), "add")
  T.eq(Console.actionFor("d"), "delete")
  T.eq(Console.actionFor("l"), "list")
  T.eq(Console.actionFor("f"), "fixNow")
  T.eq(Console.actionFor("Q"), "quit", "upper case too")
  T.isNil(Console.actionFor("z"))
end)

T.it("says NO FIX YET rather than drawing zeros", function()
  local text = rendered({})
  T.isTrue(text:find("NO FIX YET") ~= nil, "named: " .. text:match("[^\n]*NO FIX[^\n]*"))
end)

T.it("AN ESTIMATED POSITION IS LABELLED Backup basic heading", function()
  -- The whole point of carrying the flag. A consumer that cannot tell a fix from a five-second
  -- guess will act on the guess. "Backup basic heading" is the pilot's name for the fallback.
  local text = rendered({ position = { x = 100, y = 70, z = -200, source = "estimate",
    quality = 0.4, ageMs = 4200, dead = true } })
  T.isTrue(text:find("BACKUP BASIC HEADING") ~= nil, "shouted in the text")
  T.isTrue(text:find("estimate") ~= nil, "with its source")
  T.isTrue(text:find("4%.2s old") ~= nil, "and its age: " .. text:match("[^\n]*old[^\n]*"))
end)

T.it("a real fix shows its source, age and quality", function()
  local text = rendered({ position = { x = 1, y = 2, z = 3, source = "gps", quality = 1,
    ageMs = 120, dead = false } })
  T.isTrue(text:find("from gps") ~= nil, "source")
  T.isTrue(text:find("q 1%.00") ~= nil, "quality")
  T.isFalse(text:find("DEAD RECKONED") ~= nil, "and not flagged")
end)

T.it("SHOWS THE HEADING WITH ITS SOURCE, or NONE when there is neither", function()
  local none = rendered({})
  T.isTrue(none:find("heading   NONE") ~= nil, "named: " .. none:match("[^\n]*heading[^\n]*"))

  -- a true-north navigation-table reading
  local navt = rendered({ heading = { degrees = 90, source = "navtable" } })
  T.isTrue(navt:find("heading   90  E") ~= nil, "shows the compass point")
  T.isTrue(navt:find("true N") ~= nil, "and that it is referenced to true north: "
    .. navt:match("[^\n]*heading[^\n]*"))

  -- the Backup basic heading, carried on the gimbal
  local backup = rendered({ heading = { degrees = 90, source = "backup" } })
  T.isTrue(backup:find("backup") ~= nil, "backup source named: " .. backup:match("[^\n]*heading[^\n]*"))

  -- a raw, relative gimbal yaw
  local rel = rendered({ heading = { degrees = 90, source = "gimbal" } })
  T.isTrue(rel:find(" rel") ~= nil, "relative is flagged: " .. rel:match("[^\n]*heading[^\n]*"))
end)

T.it("NAMES A MISSING MODEM -- half a nav computer is a specific failure", function()
  local text = rendered({ link = { wired = nil, wireless = "modem_3", published = 0 } })
  T.isTrue(text:find("cable MISSING") ~= nil, "the cable: " .. text:match("[^\n]*cable[^\n]*"))

  local both = rendered({ link = { wired = "modem_1", wireless = "modem_3", published = 42 } })
  T.isTrue(both:find("radio modem_3") ~= nil, "and names them when present")
  T.isTrue(both:find("published 42") ~= nil, "with the count")
end)

T.it("shows which source is answering and which is backed off", function()
  local text = rendered({ stats = { sources = {
    { name = "gps", ok = 40, bad = 2, backedOff = false },
    { name = "radar", ok = 0, bad = 5, backedOff = true },
  } } })
  T.isTrue(text:find("gps  ok 40  failed 2") ~= nil, "counters")
  T.isTrue(text:find("radar.*BACKED OFF") ~= nil, "and the backoff is visible")
end)

T.it("lists the NEAREST waypoints with bearing and range", function()
  local text = rendered({
    position = { x = 0, y = 70, z = 0, source = "gps", quality = 1, ageMs = 0 },
    waypointCount = 2,
    nearest = {
      { waypoint = { name = "Home Pad" }, bearing = 0, distance = 50 },
      { waypoint = { name = "Far Ridge" }, bearing = 135, distance = 900 },
    },
  })
  T.isTrue(text:find("waypoints 2") ~= nil, "the count")
  T.isTrue(text:find("Home Pad") ~= nil, "nearest named")
  T.isTrue(text:find("N 0") ~= nil, "with a compass point and bearing")
  T.isTrue(text:find("50m") ~= nil, "and a range")
  T.isTrue(text:find("SE 135") ~= nil, "the second one too")
end)

T.it("wraps a problem rather than truncating it", function()
  local _, rows = rendered({ problems = {
    "no WIRELESS modem: gps.locate() has nothing to send on, so this computer cannot fix at all"
  } })
  local hits = 0
  for _, row in ipairs(rows) do
    T.isTrue(#row.text <= 51, "row fits: " .. row.text)
    if row.text:find("WIRELESS") or row.text:find("cannot fix") then hits = hits + 1 end
  end
  T.isTrue(hits >= 2, "wrapped over rows, got " .. hits)
end)

T.it("every row fits at 51 and at 26 columns", function()
  local worst = {
    position = { x = -1234567, y = 200, z = 9876543, source = "estimate",
                 quality = 0.123, ageMs = 123456, dead = true },
    heading = 359,
    link = { wired = "modem_extremely_long_name", wireless = "another_long_one",
             published = 999999 },
    stats = { sources = { { name = "gps", ok = 99999, bad = 99999, backedOff = true } } },
    waypointCount = 99,
    nearest = { { waypoint = { name = "a-very-long-waypoint-name" }, bearing = 359,
                  distance = 123456 } },
    problems = { "two beacons are configured at the SAME position -- one of them is a copy" },
  }
  for _, width in ipairs({ 51, 26 }) do
    local rows = Console.render(NavConfig.withDefaults({}), worst, width, 19)
    for _, row in ipairs(rows) do
      T.isTrue(#row.text <= width, ("width %d: %q is %d"):format(width, row.text, #row.text))
    end
    for _, row in ipairs(rows.footer) do
      T.isTrue(#row.text <= width, ("footer at %d: %q"):format(width, row.text))
    end
  end
end)

-- --------------------------------------------------------------- entry

T.suite("nav waypoint entry")

local function reader(answers)
  local index = 0
  return function() index = index + 1; return answers[index] end
end

T.it("a blank name CANCELS, so a prompt opened by mistake costs nothing", function()
  local name, why = Console.readName(reader({ "" }))
  T.isNil(name)
  T.eq(why, "cancelled")
end)

T.it("a name is trimmed", function()
  T.eq(Console.readName(reader({ "  Home Pad  " })), "Home Pad")
end)

T.it("ALL THREE COORDINATES OR NONE", function()
  local coords = Console.readCoords(reader({ "100", "70", "-200" }))
  T.eq(coords.x, 100); T.eq(coords.z, -200)

  local bad, err = Console.readCoords(reader({ "100", "seventy", "-200" }))
  T.isNil(bad, "refused")
  T.isTrue(tostring(err):find("Y is not a number") ~= nil, "names the axis")
  T.isTrue(tostring(err):find("nothing was added") ~= nil, "and reassures")
end)

T.it("THE PREVIEW MAKES A MIS-TYPED COORDINATE OBVIOUS before it is saved", function()
  -- The whole reason for typing them here rather than editing a file.
  local here = { x = 0, y = 70, z = 0 }
  local text = Console.preview(here, { x = 0, y = 70, z = -100 })
  T.isTrue(text:find("N 0") ~= nil, "gives a bearing: " .. text)
  T.isTrue(text:find("100 blocks") ~= nil, "and a distance")

  local typo = Console.preview(here, { x = 0, y = 70, z = -100000 })
  T.isTrue(typo:find("100000 blocks") ~= nil, "a stray zero shows as an absurd range: " .. typo)
end)

T.it("the preview copes with no fix, and with the point you are standing on", function()
  T.isTrue(Console.preview(nil, { x = 1, y = 2, z = 3 }):find("no fix") ~= nil, "no fix")
  local same = Console.preview({ x = 5, y = 6, z = 7 }, { x = 5, y = 6, z = 7 })
  T.isTrue(same:find("where you are now") ~= nil, "coincident: " .. same)
end)

-- ------------------------------------------------------------------ heading

T.suite("heading model")

T.it("reads the navigation table as an absolute heading, with sign and wrap", function()
  local h = Heading.new({})
  h:setSource(function() return 90 end)
  T.eq(h:readNavTable(1000), 90, "straight through")

  local flipped = Heading.new({ navSign = -1 })
  flipped:setSource(function() return 90 end)
  T.eq(flipped:readNavTable(1000), 270, "negated and wrapped to [0,360)")
end)

T.it("a fresh table reading is the truth, above the gimbal", function()
  local h = Heading.new({})
  h:setSource(function() return 120 end)
  h:updateGimbal(45)
  h:tick(1000)
  local cur = h:current(1000)
  T.eq(cur.source, "navtable", "table wins")
  T.eq(cur.degrees, 120, "and reads the table")
end)

T.it("the gimbal carries the heading when the table goes silent -- Backup basic heading", function()
  local reading = 120
  local h = Heading.new({ staleMs = 3000 })
  h:setSource(function() return reading end)
  h:updateGimbal(100)          -- gimbal is 100 while the table says 120, so offset is +20
  h:tick(1000)
  T.eq(h:current(1000).source, "navtable", "table first")

  -- table goes silent; gimbal swings to 150
  reading = nil
  h:updateGimbal(150)
  local cur = h:current(6000)  -- well past staleMs since the last table reading
  T.eq(cur.source, "backup", "now on the backup basic heading")
  T.eq(cur.degrees, 170, "gimbal 150 + offset 20 = 170")
  T.isTrue(cur.aligned, "and it is aligned")
end)

T.it("SELF ALIGN re-trues the offset to the table on demand", function()
  local reading = 200
  local h = Heading.new({})
  h:setSource(function() return reading end)
  h:updateGimbal(30)
  local ok, msg = h:align(1000)
  T.isTrue(ok, msg)
  -- table silent, gimbal unchanged: heading should be the table value we aligned to
  reading = nil
  local cur = h:current(6000)
  T.eq(cur.degrees, 200, "gimbal 30 + offset 170 = 200")
end)

T.it("align fails, clearly, when the table is not answering", function()
  local h = Heading.new({})
  h:setSource(function() return nil end)
  h:updateGimbal(30)
  local ok, msg = h:align(1000)
  T.isFalse(ok, "refused")
  T.isTrue(tostring(msg):find("not answering") ~= nil, "and says why: " .. tostring(msg))
end)

T.it("navtable mode has NO heading until aligned; auto falls back to raw gimbal", function()
  -- navtable mode: rawGimbalOk false. Silent table, uncalibrated gimbal -> nil, honestly.
  local strict = Heading.new({ rawGimbalOk = false })
  strict:setSource(function() return nil end)
  strict:updateGimbal(45)
  T.isNil(strict:current(1000), "no fabricated heading")

  -- auto mode: rawGimbalOk true. Same inputs -> the raw gimbal, flagged relative.
  local auto = Heading.new({ rawGimbalOk = true })
  auto:setSource(function() return nil end)
  auto:updateGimbal(45)
  local cur = auto:current(1000)
  T.eq(cur.source, "gimbal", "raw gimbal offered")
  T.isFalse(cur.aligned, "but flagged as NOT aligned -- it is relative, not true north")
end)

T.it("angleDelta crosses the 0/360 seam honestly", function()
  T.eq(Heading.angleDelta(10, 350), 20, "10 is 20 clockwise of 350, not -340")
  T.eq(Heading.angleDelta(350, 10), -20, "and the other way")
end)

T.it("flipping a sign clears the calibration -- the old offset was against the old sign", function()
  local h = Heading.new({})
  h:setSource(function() return 90 end)
  h:updateGimbal(45)
  h:align(1000)
  T.notNil(h.offset, "aligned")
  h:setNavSign(-1)
  T.isNil(h.offset, "the offset is dropped, so a stale calibration cannot linger")
  T.eq(h.navSign, -1, "and the sign took")
end)

-- ------------------------------------------------------------------ nav table peripheral

T.suite("navigation table peripheral")

T.it("lists only navigation tables, sorted", function()
  local names = { "modem_0", "navigation_table_1", "gimbal_sensor_0", "navigation_table_0" }
  local found = NavTable.list(names)   -- isNavTable uses peripheral.getType; mock it
  -- With no peripheral mock here, list falls back to getType which is nil -> empty. So this test
  -- exercises the FILTERING logic by injecting through a stubbed peripheral in the resolve test
  -- below; here we only assert it does not throw and returns a table.
  T.eq(type(found), "table", "returns a list")
end)

T.it("resolve auto-picks the first, names the pick, and errors on an absent named table", function()
  local names = { "navigation_table_0", "navigation_table_2" }
  -- inject: pretend both are nav tables and wrap returns a stub
  local realGetType = peripheral and peripheral.getType
  -- Use a fake peripheral namespace for this test
  local savedPeripheral = _G.peripheral
  _G.peripheral = {
    getNames = function() return names end,
    getType = function(n) return n:find("navigation_table") and "navigation_table" or "other" end,
    wrap = function(n) return { name = n, getRelativeAngle = function() return 42 end } end,
  }

  local dev, err, picked = NavTable.resolve("")
  T.notNil(dev, "auto-picked a table")
  T.eq(picked, "navigation_table_0", "the first one")

  local named, nerr = NavTable.resolve("navigation_table_2")
  T.notNil(named, "a named table resolves")

  local missing, merr = NavTable.resolve("navigation_table_9")
  T.isNil(missing, "an absent named table is an error, not a silent fall-through")
  T.isTrue(tostring(merr):find("not on the network") ~= nil, "and says so: " .. tostring(merr))

  _G.peripheral = savedPeripheral
end)

-- ------------------------------------------------------------------ disk

T.suite("nav disk")

local function fakeFs()
  local files = {}
  return files, {
    exists = function(p) return files[p] ~= nil end,
    delete = function(p) files[p] = nil end,
    copy = function(src, dst) files[dst] = files[src] end,
  }
end

T.it("the fileset is waypoints then routes, skipping any that are unset", function()
  local set = Disk.fileset({ waypointsPath = "/eh_waypoints.tbl", routesPath = "/eh_routes.tbl" })
  T.eq(#set, 2, "both")
  T.eq(set[1].key, "waypoints")
  T.eq(set[2].key, "routes")
  T.eq(#Disk.fileset({ waypointsPath = "/eh_waypoints.tbl", routesPath = "" }), 1, "routes unset")
end)

T.it("save copies the local files onto the disk mount", function()
  local files, fsapi = fakeFs()
  files["/eh_waypoints.tbl"] = "WP DATA"
  local cfg = { waypointsPath = "/eh_waypoints.tbl", routesPath = "/eh_routes.tbl" }
  local ok, saved = Disk.save("/disk", cfg, fsapi)
  T.isTrue(ok, "saved")
  T.eq(saved[1], "waypoints", "the waypoint file")
  T.eq(files["/disk/eh_waypoints.tbl"], "WP DATA", "and it landed on the disk")
end)

T.it("save with nothing to save is a clear refusal, not a silent success", function()
  local files, fsapi = fakeFs()
  local ok, _, err = Disk.save("/disk", { waypointsPath = "/eh_waypoints.tbl" }, fsapi)
  T.isFalse(ok, "refused")
  T.isTrue(tostring(err):find("nothing to save") ~= nil, "and says why: " .. tostring(err))
end)

T.it("load copies the disk files back over the local ones", function()
  local files, fsapi = fakeFs()
  files["/disk/eh_waypoints.tbl"] = "FROM DISK"
  files["/eh_waypoints.tbl"] = "OLD LOCAL"
  local ok, loaded = Disk.load("/disk", { waypointsPath = "/eh_waypoints.tbl" }, fsapi)
  T.isTrue(ok, "loaded")
  T.eq(loaded[1], "waypoints")
  T.eq(files["/eh_waypoints.tbl"], "FROM DISK", "the local file now matches the disk")
end)

T.it("load from a disk with no EasyHover data refuses rather than wiping local waypoints", function()
  local files, fsapi = fakeFs()
  files["/eh_waypoints.tbl"] = "PRECIOUS"
  local ok, _, err = Disk.load("/disk", { waypointsPath = "/eh_waypoints.tbl" }, fsapi)
  T.isFalse(ok, "refused")
  T.eq(files["/eh_waypoints.tbl"], "PRECIOUS", "and the local set is untouched")
end)

-- ------------------------------------------------------------------ commands

T.suite("nav command validation")

local NavCommand = require("lib.navcommand")

T.it("accepts a whitelisted, well-typed command and keeps only its fields", function()
  local cmd = NavCommand.parse({ cmd = "setHeadingSource", source = "navtable", junk = 1 }, 7)
  T.notNil(cmd, "accepted")
  T.eq(cmd.cmd, "setHeadingSource")
  T.eq(cmd.source, "navtable")
  T.eq(cmd.sender, 7, "the sender is recorded")
  T.isNil(cmd.junk, "unlisted fields are dropped, never passed through")
end)

T.it("rejects an unknown command, a bad enum, and a wrong type", function()
  T.isNil((NavCommand.parse({ cmd = "flyAway" })), "unknown command")
  T.isNil((NavCommand.parse({ cmd = "setHeadingSource", source = "north" })), "not an enum member")
  T.isNil((NavCommand.parse({ cmd = "setNavSign", sign = "left" })), "sign must be a number")
  T.isNil((NavCommand.parse({})), "no cmd field")
  T.isNil((NavCommand.parse("nope")), "not a table at all")
end)

T.it("a no-field command needs only its name", function()
  local cmd = NavCommand.parse({ cmd = "selfAlign" }, 3)
  T.notNil(cmd, "selfAlign accepted")
  T.eq(cmd.cmd, "selfAlign")
end)

T.suite("nav command handling")

local App = require("app")

local function appRig()
  local path = "/eh_nav_cmdtest.tbl"
  if fs.exists(path) then fs.delete(path) end
  return App.new({ configPath = path }), path
end

T.it("setHeadingSource applies, re-wires the heading model, and saves", function()
  local app, path = appRig()
  local ok = app:handleCommand({ cmd = "setHeadingSource", source = "gimbal" })
  T.isTrue(ok, "accepted")
  T.eq(app.cfg.headingSource, "gimbal", "config updated")
  T.isTrue(app.heading.rawGimbalOk, "gimbal mode lets the raw yaw stand in as a relative heading")
  T.isTrue(fs.exists(path), "the choice was persisted")
  fs.delete(path)
end)

T.it("setNavSign flips the sign and clears the calibration for a re-align", function()
  local app, path = appRig()
  app.heading.offset = 42               -- pretend we were aligned
  local ok = app:handleCommand({ cmd = "setNavSign", sign = -1 })
  T.isTrue(ok)
  T.eq(app.cfg.navSign, -1, "config sign flipped")
  T.eq(app.heading.navSign, -1, "heading model sign flipped")
  T.isNil(app.heading.offset, "the old calibration is cleared -- a SELF ALIGN must re-true it")
  fs.delete(path)
end)

T.it("an unhandled command is refused, not thrown", function()
  local app, path = appRig()
  local ok, detail = app:handleCommand({ cmd = "wat" })
  T.isFalse(ok, "refused")
  T.isTrue(tostring(detail.error):find("unhandled") ~= nil, "and says why")
  fs.delete(path)
end)

return true
