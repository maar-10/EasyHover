--[[ EasyHover hardware probe
     Run on the flight computer, wired to the thrusters and sensors.

     SAFETY: run this ON THE GROUND. The probe never commands thrust -- it only moves
     nozzles, and it refuses to run if any thruster reports non-zero power. Ideally
     defuel the thrusters first.

     Writes probe_report.txt next to the program. ASCII output only (the in-game font
     is not CraftOS-PC's font).
]]

-- Timings can be shortened by the headless test harness; in-game they are the defaults.
local cfg = _G.EASYHOVER_PROBE or {}

local REPORT        = cfg.REPORT or "probe_report.txt"
local SAMPLES       = cfg.SAMPLES or 40         -- sensor samples
local INTERVAL      = cfg.INTERVAL or 0.05      -- seconds between samples
local SLEW_TIMEOUT  = cfg.SLEW_TIMEOUT or 3.0   -- seconds to wait for a nozzle to reach target
local CALL_COUNT    = cfg.CALL_COUNT or 20      -- setVector calls used to time mainThread cost
local SETTLE        = cfg.SETTLE or 1.0         -- seconds to let a centred nozzle settle
local CONTROLLER_MS = cfg.CONTROLLER_MS or 6000 -- axis-mapping capture window
local TYPEWRITER_MS = cfg.TYPEWRITER_MS or 4000 -- key capture window
local YAW_MS        = cfg.YAW_MS or 15000       -- attitude/heading identification window
local GPS_TIMEOUT   = cfg.GPS_TIMEOUT or 2      -- seconds to wait for a GPS fix

-- ---------------------------------------------------------------- reporting

local out = {}
local function w(fmt, ...)
  local line = select("#", ...) > 0 and string.format(fmt, ...) or fmt
  out[#out + 1] = line
  print(line)
end
local function section(title)
  w("")
  w("=== %s ===", title)
end

--- The decision-critical answers, one short line each.
---
--- The full report is ~130 lines, which is fine as a FILE and useless if the only way off the
--- computer is a screenshot -- which is the case on a server, where nobody has the world save.
--- So the run ends with a digest that fits on one screen.
local briefs = {}

--- A CC terminal is 51 columns and the digest is printed with a two-space indent, so a line
--- has 49 to play with. EVERY line is wrapped, not just the ones that looked long: an
--- over-wide line does not error, it silently becomes two and pushes the top of the digest off
--- the screen -- which on a server is the only copy anyone can read.
local BRIEF_TEXT = 38          -- 2 indent + 9 prefix + 38 = 49
local BRIEF_PREFIX = 9

local function brief(fmt, ...)
  local line = select("#", ...) > 0 and string.format(fmt, ...) or fmt
  local prefix, rest = line:sub(1, BRIEF_PREFIX), line:sub(BRIEF_PREFIX + 1)
  if #rest <= BRIEF_TEXT then
    briefs[#briefs + 1] = line
    return
  end
  local indent = (" "):rep(BRIEF_PREFIX)
  local current = nil
  for word in rest:gmatch("[^ ]+") do
    if current == nil then
      current = word
    elseif #current + 1 + #word <= BRIEF_TEXT then
      current = current .. " " .. word
    else
      briefs[#briefs + 1] = prefix .. current
      prefix, current = indent, word
    end
  end
  if current then briefs[#briefs + 1] = prefix .. current end
end

--- Kept for callers that build the prefix separately.
local function briefWrapped(prefix, text) brief("%s%s", prefix, text) end

--- One line per sensor TYPE, not per instance: four identical thrusters would otherwise push
--- everything else off the screen.
local reportedType = {}

local function fmt(v)
  if v == nil then return "nil" end
  local t = type(v)
  if t == "number" then
    if v == math.floor(v) and math.abs(v) < 1e9 then return tostring(v) end
    return string.format("%.5f", v)
  end
  if t == "table" then
    local parts = {}
    for i = 1, #v do parts[#parts + 1] = fmt(v[i]) end
    -- non-array keys too, so we learn the real shape
    local named = {}
    for k, val in pairs(v) do
      if type(k) ~= "number" then named[#named + 1] = tostring(k) .. "=" .. fmt(val) end
    end
    table.sort(named)
    for _, s in ipairs(named) do parts[#parts + 1] = s end
    return "{" .. table.concat(parts, ", ") .. "}"
  end
  return tostring(v)
end

-- Call a peripheral method safely; returns ok, value-or-error
local function try(dev, method, ...)
  if type(dev[method]) ~= "function" then return false, "no such method" end
  local res = { pcall(dev[method], ...) }
  if not res[1] then return false, tostring(res[2]) end
  if #res == 2 then return true, res[2] end
  local vals = {}
  for i = 2, #res do vals[#vals + 1] = res[i] end
  return true, vals
end

-- ---------------------------------------------------------------- inventory

section("environment")
w("computer id   : %s", tostring(os.getComputerID()))
-- getComputerLabel() returns ZERO values when unlabelled, so `or` is required to
-- adjust it to a single value before tostring().
w("label         : %s", tostring(os.getComputerLabel() or "(none)"))
w("lua version   : %s", tostring(_VERSION))
w("epoch utc     : %s", tostring(os.epoch("utc")))
brief("lua      %s", tostring(_VERSION))

section("peripheral inventory")

local byType, names = {}, peripheral.getNames()
table.sort(names)
if #names == 0 then w("NO PERIPHERALS FOUND -- is the wired modem on this computer active?") end
for _, name in ipairs(names) do
  local ptype = peripheral.getType(name)
  w("%-28s %s", name, tostring(ptype))
  byType[ptype] = byType[ptype] or {}
  table.insert(byType[ptype], name)
end

-- A per-type census is what I need at a glance; the full name list is in the file.
local censusParts = {}
for ptype, list in pairs(byType) do
  censusParts[#censusParts + 1] = ("%s x%d"):format(ptype, #list)
end
table.sort(censusParts)
briefWrapped("periph   ", #censusParts > 0 and table.concat(censusParts, " ") or "NONE FOUND")

section("method lists")
-- One representative per type; that is what we need to confirm the API surface.
local seen = {}
for _, name in ipairs(names) do
  local ptype = peripheral.getType(name)
  if not seen[ptype] then
    seen[ptype] = true
    local ok, methods = pcall(peripheral.getMethods, name)
    if ok and methods then
      table.sort(methods)
      w("%s  (%s)", ptype, name)
      w("   %s", table.concat(methods, ", "))
    else
      w("%s  (%s)  -- getMethods failed", ptype, name)
    end
  end
end

-- Helper: first peripheral of any of the given types
local function firstOf(...)
  for _, t in ipairs({ ... }) do
    if byType[t] and byType[t][1] then return byType[t][1], t end
  end
  return nil
end

-- ---------------------------------------------------------------- sensors

-- type -> zero-arg methods worth sampling
local SENSOR_METHODS = {
  altitude_sensor   = { "getHeight", "getAirPressure" },
  gimbal_sensor     = { "getAngles" },
  velocity_sensor   = { "getVelocity" },
  optical_sensor    = { "getDistance", "getBlock" },
  navigation_table  = { "getRelativeAngle" },
  docking_connector = { "getConnectedName" },
  directional_link  = { "getClosestAngle" },
  modulating_link   = { "getClosestDistance" },
  swivel_bearing    = { "getTargetAngle" },
  torsion_spring    = { "getAngle", "getLimit", "isRunning" },
}

section("sensor sampling")
w("%d samples, %.0f ms apart. Tilt / move the craft by hand during this if you can --", SAMPLES, INTERVAL * 1000)
w("it is the only way to learn the axis order and sign of gimbal_sensor.getAngles().")
w("")

local sampled = false
for ptype, methods in pairs(SENSOR_METHODS) do
  if byType[ptype] then
    for _, name in ipairs(byType[ptype]) do
      sampled = true
      local dev = peripheral.wrap(name)
      w("-- %s (%s)", name, ptype)
      local liveMethods, deadMethods = {}, {}
      local series = {}
      for _, m in ipairs(methods) do series[m] = {} end
      for _ = 1, SAMPLES do
        for _, m in ipairs(methods) do
          local ok, v = try(dev, m)
          table.insert(series[m], ok and v or ("ERR:" .. tostring(v)))
        end
        sleep(INTERVAL)
      end
      for _, m in ipairs(methods) do
        local s = series[m]
        w("   %-18s first=%s  last=%s", m, fmt(s[1]), fmt(s[#s]))
        -- numeric range, when it is numeric
        local lo, hi
        for _, v in ipairs(s) do
          if type(v) == "number" then
            lo = (lo == nil or v < lo) and v or lo
            hi = (hi == nil or v > hi) and v or hi
          end
        end
        if lo then
          w("   %-18s min=%s  max=%s  span=%s", "", fmt(lo), fmt(hi), fmt(hi - lo))
          liveMethods[#liveMethods + 1] = m
        elseif type(s[1]) == "table" then
          liveMethods[#liveMethods + 1] = m .. "[]"
        else
          deadMethods[#deadMethods + 1] = m
        end
        -- for table returns, report the element count so we learn the shape
        if type(s[1]) == "table" then
          w("   %-18s element count=%d  sample=%s", "", #s[1], fmt(s[1]))
        end
      end
      if not reportedType[ptype] then
        reportedType[ptype] = true
        local short = ptype:gsub("_sensor$", ""):gsub("^create_?", "")
        briefWrapped(("%-8s "):format(short:sub(1, 8)),
          (#liveMethods > 0 and table.concat(liveMethods, ",") or "NO DATA")
          .. (#deadMethods > 0 and ("  dead:" .. table.concat(deadMethods, ",")) or ""))
      end
    end
  end
end
if not sampled then
  w("No known Simulated sensors found on the network.")
  brief("sensors  NONE of the known Simulated types are on the network")
end

-- ------------------------------------------------- attitude / heading identity

-- Tracks min/max of a numeric series and keeps a downsampled trace.
local function tracker()
  local t = { lo = nil, hi = nil, trace = {}, n = 0 }
  function t.put(v)
    if type(v) ~= "number" then return end
    t.n = t.n + 1
    if t.lo == nil or v < t.lo then t.lo = v end
    if t.hi == nil or v > t.hi then t.hi = v end
    if t.n % 5 == 1 and #t.trace < 14 then t.trace[#t.trace + 1] = string.format("%.2f", v) end
  end
  function t.report(label)
    if t.lo == nil then
      w("   %-22s no numeric samples", label)
    else
      w("   %-22s min=%s max=%s span=%s", label, fmt(t.lo), fmt(t.hi), fmt(t.hi - t.lo))
      w("   %-22s trace: %s", "", table.concat(t.trace, " "))
    end
  end
  return t
end

section("attitude + heading identification")

local gimbalName = firstOf("gimbal_sensor")
local navTableName = firstOf("navigation_table")
local dirLinkName = firstOf("directional_link")

if not gimbalName then
  w("SKIPPED -- no gimbal_sensor on the network.")
else
  w("During the next %.1f seconds move the craft through THREE motions, about 3 s each,", YAW_MS / 1000)
  w("pausing between them. Simulated's Physics Staff is the easy way to nudge it:")
  w("   1) pitch nose UP      2) roll RIGHT      3) yaw RIGHT")
  w("")
  w("This tells us which element of getAngles() is which axis, and whether YAW exists")
  w("at all -- the entire nav design depends on that one answer.")
  w("")

  local gdev = peripheral.wrap(gimbalName)
  local navDev = navTableName and peripheral.wrap(navTableName) or nil
  local dirDev = dirLinkName and peripheral.wrap(dirLinkName) or nil

  local elems, navT, dirT = {}, tracker(), tracker()
  local deadline = os.epoch("utc") + YAW_MS
  while os.epoch("utc") < deadline do
    local ok, angles = try(gdev, "getAngles")
    if ok and type(angles) == "table" then
      for i = 1, #angles do
        elems[i] = elems[i] or tracker()
        elems[i].put(angles[i])
      end
    end
    if navDev then
      local okn, v = try(navDev, "getRelativeAngle")
      if okn then navT.put(v) end
    end
    if dirDev then
      local okd, v = try(dirDev, "getClosestAngle")
      if okd then dirT.put(v) end
    end
    sleep(0.1)
  end

  w("gimbal_sensor.getAngles() -- %d element(s):", #elems)
  for i = 1, #elems do elems[i].report("element " .. i) end
  if #elems < 3 then
    w("   >> Fewer than 3 elements: this sensor probably reports PITCH and ROLL only.")
    w("   >> Absolute heading must then come from a nav fallback (see docs/NAVIGATION.md).")
  end
  -- Which elements actually MOVED is the whole answer; a static one tells us nothing.
  local moved = {}
  for i = 1, #elems do
    local t = elems[i]
    local span = (t.hi and t.lo) and (t.hi - t.lo) or 0
    if span > 1 then moved[#moved + 1] = ("e%d span %.1f"):format(i, span) end
  end
  if #moved == 0 then
    brief("gimbal   %d elem, NONE MOVED: axes unresolved", #elems)
  else
    briefWrapped("gimbal   ", ("%d element(s); moved: %s"):format(#elems, table.concat(moved, " ")))
  end

  if navDev then
    w("navigation_table.getRelativeAngle():")
    navT.report("relative angle")
  end
  if dirDev then
    w("directional_link.getClosestAngle():")
    dirT.report("closest angle")
  end
end

-- ---------------------------------------------------------------- navigation

section("navigation sources -- where does position come from?")

-- 1) vanilla CC GPS
local gx, gy, gz
local gpsOk = pcall(function() gx, gy, gz = gps.locate(GPS_TIMEOUT) end)
if gpsOk and type(gx) == "number" then
  w("gps.locate    : FIX  x=%s y=%s z=%s", fmt(gx), fmt(gy), fmt(gz))
  w("                -> GPS is viable as the primary position source.")
else
  w("gps.locate    : no fix")
  w("                Needs a wireless or ender modem on THIS computer plus 4+ GPS")
  w("                hosts in range. Not an error if you have not built one yet.")
end

-- 2) Create: Radar reports its own world position
local radarName, radarType = firstOf("plane_radar", "radar")
if radarName then
  local rdev = peripheral.wrap(radarName)
  local _, pos = try(rdev, "getPosition")
  local _, range = try(rdev, "getRange")
  local okTracks, tracks = try(rdev, "getTracks")
  w("%s (%s)", radarName, tostring(radarType))
  w("   getPosition  : %s", fmt(pos))
  w("   getRange     : %s", fmt(range))
  w("   getTracks    : %s", okTracks and (type(tracks) == "table"
      and (#tracks .. " track(s); first=" .. fmt(tracks[1])) or fmt(tracks))
    or ("ERR " .. tostring(tracks)))
  w("   -> Radar is viable as position source AND gives traffic awareness.")
else
  w("radar         : none on the network (no on-board position source from Radar)")
end

-- 3) beacon navigation via Redstone Links
local modLinkName = firstOf("modulating_link")
if modLinkName or dirLinkName then
  w("beacons       : link peripherals present -- beacon nav (bearing+range) is possible")
  if modLinkName then
    local _, d = try(peripheral.wrap(modLinkName), "getClosestDistance")
    w("   modulating_link.getClosestDistance = %s  (note the usable range!)", fmt(d))
  end
else
  w("beacons       : no directional_link / modulating_link found")
end

-- 4) downward laser: the autoland altitude reference
if byType["optical_sensor"] then
  w("laser alt     : %d optical_sensor(s) -- required for AUTOLAND flare",
    #byType["optical_sensor"])
else
  w("laser alt     : NONE -- autoland has no precise ground reference without one")
end

-- ---------------------------------------------------------------- thrusters

local VECTOR_TYPES = { "vector_thruster", "liquid_vector_thruster", "creative_vector_thruster" }
local ALL_THRUSTER_TYPES = { "vector_thruster", "liquid_vector_thruster", "creative_vector_thruster",
                             "thruster", "solid_fuel_thruster", "ion_thruster", "creative_thruster" }

section("thruster state")
local thrusterNames = {}
for _, t in ipairs(ALL_THRUSTER_TYPES) do
  for _, name in ipairs(byType[t] or {}) do table.insert(thrusterNames, { name = name, ptype = t }) end
end

local unsafe = false
for _, entry in ipairs(thrusterNames) do
  local dev = peripheral.wrap(entry.name)
  local _, power = try(dev, "getPower")
  local _, obstruction = try(dev, "getObstruction")
  local _, thrustKn = try(dev, "getCurrentThrustKN")
  local _, airflow = try(dev, "getAirflowMs")
  w("%-28s %-24s power=%s  thrustKN=%s  obstruction=%s  airflow=%s",
    entry.name, entry.ptype, fmt(power), fmt(thrustKn), fmt(obstruction), fmt(airflow))
  if type(power) == "number" and power > 0.001 then unsafe = true end
end
if #thrusterNames == 0 then w("No thrusters found.") end

-- ---------------------------------------------------------------- slew + cost

local vecName, vecType = firstOf(table.unpack(VECTOR_TYPES))

section("nozzle slew rate  (THE number that sets attitude-loop bandwidth)")

if not vecName then
  w("SKIPPED -- no vector thruster on the network.")
  brief("slew     SKIPPED: no vector thruster")
elseif unsafe then
  w("SKIPPED -- a thruster reports non-zero power. Land, cut throttle, and re-run.")
  brief("slew     SKIPPED: thruster powered -- re-run with the engine OFF")
else
  w("Using %s (%s). Thrust is never commanded; only the nozzle moves.", vecName, vecType)
  local dev = peripheral.wrap(vecName)

  -- centre first, and let it settle
  try(dev, "setVector", 0, 0)
  sleep(SETTLE)
  local _, startX = try(dev, "getVectorX")
  w("centred:  getVectorX=%s", fmt(startX))

  -- command full deflection and time the response
  local t0 = os.epoch("utc")
  try(dev, "setVector", 1, 0)
  local reached, elapsed, ticks = false, 0, 0
  local trace = {}
  while elapsed < SLEW_TIMEOUT * 1000 do
    sleep(0.05)
    ticks = ticks + 1
    local ok, x = try(dev, "getVectorX")
    elapsed = os.epoch("utc") - t0
    if ok and type(x) == "number" then
      if #trace < 12 then trace[#trace + 1] = string.format("%dms:%.3f", elapsed, x) end
      if x >= 0.98 then
        reached = true
        break
      end
    end
  end
  local _, finalX = try(dev, "getVectorX")
  local _, targetX = try(dev, "getTargetVectorX")

  w("trace:    %s", table.concat(trace, "  "))
  if reached then
    w("RESULT:   0 -> 1 in %d ms  (~%d polls)", elapsed, ticks)
    w("          full-scale rate ~= %.3f per second", 1000 / math.max(elapsed, 1))
    w("          => attitude loop should run at or below ~1/5 of that bandwidth")
    brief("SLEW     0->1 in %d ms = %.2f full-scale/s", elapsed, 1000 / math.max(elapsed, 1))
  else
    w("RESULT:   did NOT reach 0.98 within %d ms. final=%s target=%s",
      elapsed, fmt(finalX), fmt(targetX))
    brief("SLEW     did not reach full deflection in %d ms (final %s)", elapsed, fmt(finalX))
    w("          If final is stuck at 0, the nozzle may need thrust to move, or the")
    w("          peripheral did not take authority. Check for another attached computer.")
  end

  -- return to centre
  try(dev, "setVector", 0, 0)
  sleep(0.5)

  section("mainThread call cost")
  local c0 = os.epoch("utc")
  for i = 1, CALL_COUNT do
    try(dev, "setVector", (i % 2 == 0) and 0.02 or -0.02, 0)
  end
  local c1 = os.epoch("utc")
  w("%d setVector calls in %d ms  => %.2f ms/call", CALL_COUNT, c1 - c0, (c1 - c0) / CALL_COUNT)
  brief("CALL     %.2f ms per setVector call", (c1 - c0) / CALL_COUNT)
  w("(mainThread calls yield to the server thread; this is the per-cycle budget input)")
  try(dev, "setVector", 0, 0)
end

-- ---------------------------------------------------------------- inputs

section("pilot inputs")

local ctrlName = firstOf("tweaked_controller")
if ctrlName then
  local dev = peripheral.wrap(ctrlName)
  local _, hasUser = try(dev, "hasUser")
  local _, fullPrec = try(dev, "isFullPrecision")
  w("%s  hasUser=%s  fullPrecision=%s", ctrlName, fmt(hasUser), fmt(fullPrec))
  try(dev, "setFullPrecision", true)
  w("setFullPrecision(true) applied for this capture.")
  w("Move ONE stick/trigger at a time for the next %.1f seconds so we can map the axes.",
    CONTROLLER_MS / 1000)
  local lo, hi = {}, {}
  for i = 1, 6 do lo[i], hi[i] = 0, 0 end
  local btnSeen = {}
  local deadline = os.epoch("utc") + CONTROLLER_MS
  while os.epoch("utc") < deadline do
    for i = 1, 6 do
      local ok, v = try(dev, "getAxis", i)
      if ok and type(v) == "number" then
        if v < lo[i] then lo[i] = v end
        if v > hi[i] then hi[i] = v end
      end
    end
    for b = 1, 15 do
      local ok, v = try(dev, "getButton", b)
      if ok and v then btnSeen[b] = true end
    end
    sleep(0.05)
  end
  for i = 1, 6 do w("   axis %d  min=%s  max=%s", i, fmt(lo[i]), fmt(hi[i])) end
  local pressed = {}
  for b = 1, 15 do if btnSeen[b] then pressed[#pressed + 1] = b end end
  w("   buttons pressed during capture: %s",
    #pressed > 0 and table.concat(pressed, ",") or "none")
  local live = {}
  for i = 1, 6 do
    if (hi[i] - lo[i]) > 0.05 then
      live[#live + 1] = ("a%d[%.2f..%.2f]"):format(i, lo[i], hi[i])
    end
  end
  briefWrapped("ctrl     ", ("fullPrec=%s axes:%s btns:%s"):format(fmt(fullPrec),
    #live > 0 and table.concat(live, " ") or "NONE",
    #pressed > 0 and table.concat(pressed, ",") or "none"))
else
  w("No tweaked_controller found.")
  brief("ctrl     no tweaked_controller on the network")
end

local twName = firstOf("linked_typewriter")
if twName then
  local dev = peripheral.wrap(twName)
  w("%s found. Hold a few keys for the next %.1f seconds to confirm polling works.",
    twName, TYPEWRITER_MS / 1000)
  local codes = {}
  local deadline = os.epoch("utc") + TYPEWRITER_MS
  while os.epoch("utc") < deadline do
    local ok, list = try(dev, "getPressedKeyCodes")
    if ok and type(list) == "table" then
      for _, c in ipairs(list) do codes[c] = true end
    end
    sleep(0.05)
  end
  local seenCodes = {}
  for c in pairs(codes) do seenCodes[#seenCodes + 1] = c end
  table.sort(seenCodes)
  local labelled = {}
  for _, c in ipairs(seenCodes) do
    labelled[#labelled + 1] = string.format("%d(%s)", c, tostring(keys.getName(c)))
  end
  w("   key codes seen: %s", #labelled > 0 and table.concat(labelled, " ") or "NONE")
  if #labelled == 0 then
    w("   -> nothing polled. Every control key must be BOUND TO A FREQUENCY on the")
    w("      typewriter, or it reports nothing at all.")
    brief("typwrtr  POLLED NOTHING -- bind the keys to a frequency on the typewriter")
  else
    briefWrapped("typwrtr  ", "polls OK: " .. table.concat(labelled, " "))
  end
else
  w("No linked_typewriter found.")
  brief("typwrtr  no linked_typewriter on the network")
end

-- ------------------------------------------------------ unrecognised hardware

section("unrecognised peripherals")

-- Anything we do not already have a plan for. Surprises here are worth knowing about,
-- and generic capabilities are named by BLOCK ID rather than by getType(), so unexpected
-- strings are expected.
local KNOWN = {}
for _, t in ipairs({
  "altitude_sensor", "gimbal_sensor", "velocity_sensor", "optical_sensor", "navigation_table",
  "docking_connector", "directional_link", "modulating_link", "swivel_bearing", "torsion_spring",
  "linked_typewriter", "name_plate", "tweaked_controller",
  "vector_thruster", "liquid_vector_thruster", "creative_vector_thruster",
  "thruster", "solid_fuel_thruster", "ion_thruster", "creative_thruster",
  "tilt_adapter", "redstone_transmission", "stirling_engine", "coral_generator",
  "radar", "plane_radar",
  "modem", "monitor", "speaker", "drive", "printer", "computer", "turtle",
  "redstone_relay", "inventory", "fluid_storage", "energy_storage",
}) do KNOWN[t] = true end

local unknown = 0
for _, name in ipairs(names) do
  local t = peripheral.getType(name)
  if t and not KNOWN[t] then
    unknown = unknown + 1
    w("%-28s %s", name, t)
    local okm, methods = pcall(peripheral.getMethods, name)
    if okm and methods then
      table.sort(methods)
      w("   %s", table.concat(methods, ", "))
    end
  end
end
if unknown == 0 then
  w("None -- every peripheral on the network is a known type.")
else
  brief("unknown  %d unrecognised peripheral type(s)", unknown)
end

-- ---------------------------------------------------------------- write

section("BRIEF -- screenshot this")
for _, line in ipairs(briefs) do w("  " .. line) end

section("done")
w("Nothing was left commanded: all nozzles returned to centre and thrust")
w("was never touched.")
w("")
w("Send the report back EITHER way:")
w("  1. pastebin put " .. REPORT)
w("     ...then hand over the code it prints.")
w("  2. screenshot the BRIEF block above -- it holds the decisions.")

local f = fs.open(REPORT, "w")
f.write(table.concat(out, "\n") .. "\n")
f.close()
print("")
print("Report written to " .. REPORT)
