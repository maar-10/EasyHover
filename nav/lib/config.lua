--[[ The navigation computer's config. Extend-never-replace, like every other role.

     This computer's job is narrow: work out where the craft is, and tell the rest of the craft.
     Everything here serves one of those two, and the two modems are the load-bearing settings --
     see relay.lua for why they are deliberately separate.
]]

local Config = {}

--- LISTS ARE REPLACED WHOLESALE, not merged element by element. shared/util.lua already gets
--- this right, so it is used rather than hand-rolled a third time -- my own version merged them
--- and therefore could not empty a list at all: `positionSources = {}` in a config silently kept
--- the default, and a shorter list inherited the tail of the longer default.
local Util = require("shared.util")

local deepMerge = Util.deepMerge

Config.deepMerge = deepMerge

function Config.defaults()
  return {
    version = 1,

    --- Which position sources to try, in order. Names must match nav/lib/sources.lua; an unknown
    --- one is REPORTED rather than skipped, because a typo here would otherwise leave navigation
    --- with no sources and no explanation.
    positionSources = { "gps" },

    --- gps.locate() BLOCKS for up to this long. Two seconds is CC's own default and is plenty
    --- for four hosts on a wired-speed server; raising it costs wall time on every failed fix.
    gpsTimeout = 2,

    --- How often to take a fix. GPS costs no server tick, only wall time on this computer, so
    --- this is a wall-clock budget rather than a server-load one -- but each attempt still
    --- blocks this computer, so 2 Hz is a sane ceiling rather than a limitation.
    fixEverySeconds = 1,

    --- Older than this and the fix is stale: guidance falls back to dead reckoning, marked.
    fixStaleMs = 1500,

    --- How long a dead-reckoned estimate is worth anything. Its quality decays to zero across
    --- this window, so a consumer can see the difference between half a second of reckoning and
    --- eight seconds of it.
    reckonUsefulMs = 8000,

    --- TWO MODEMS, TWO JOBS. Blank = auto-pick.
    ---   enderModem  the radio: GPS and the beacon mesh. Receive-only as far as control goes.
    ---   wiredModem  the craft's cable: where the fix is published, and where flight telemetry
    ---               arrives from.
    --- Keeping them apart is what keeps the control surface off the air -- see docs/WIRING.md.
    enderModem = "",
    wiredModem = "",

    --- Protocols. navFixProtocol matches the flight computer's comms.navFixProtocol, which has
    --- carried this name since phase 5, so nothing on the craft needs changing to listen.
    navFixProtocol = "eh_navfix",
    telemetryProtocol = "eh_telemetry",
    --- Commands FROM the UI computer (heading source, which nav table, sign flips, SELF ALIGN).
    --- WIRED ONLY, like the flight computer's command channel -- the radio never carries a command
    --- (docs/WIRING.md). Whitelisted and type-checked in lib/navcommand.lua before anything applies.
    navCommandProtocol = "eh_navcmd",

    --- Where the waypoint and route files live. Both are PROTECTED paths, so the Suite never
    --- deletes them and an update cannot cost the operator a waypoint set.
    waypointsPath = "/eh_waypoints.tbl",
    routesPath = "/eh_routes.tbl",

    --- A marked waypoint must come from a fix this fresh and this good. A pad you cannot trust
    --- is worse than no pad: you would fly to it and find open air.
    markMaxAgeMs = 3000,
    markMinQuality = 0.5,

    --- HEADING. The navigation table is an absolute reference -- aim it at true north with a
    --- magnet -- and the gimbal yaw from telemetry carries the heading between reads. See
    --- lib/heading.lua for the model and lib/navtable.lua for the peripheral.
    ---   headingSource  "navtable" -- table, with the gimbal as the Backup basic heading
    ---                  "gimbal"   -- telemetry yaw only; NO true-north reference (relative)
    ---                  "auto"     -- navtable if one is present, else gimbal
    ---   navTable       peripheral name of the table; "" auto-picks the first found
    ---   navSign        +1 or -1, flips the table angle if it reads backwards in-game
    ---   gimbalSign     +1 or -1, flips the gimbal yaw likewise
    ---   navHeadingStaleMs  a table reading older than this falls back to the Backup basic heading
    headingSource = "auto",
    navTable = "",
    navSign = 1,
    gimbalSign = 1,
    navHeadingStaleMs = 3000,
  }
end

function Config.withDefaults(loaded)
  return deepMerge(Config.defaults(), loaded or {})
end

--- Returns ok, errors, warnings.
function Config.validate(cfg)
  local errors, warnings = {}, {}
  local function err(fmt, ...) errors[#errors + 1] = fmt:format(...) end
  local function warn(fmt, ...) warnings[#warnings + 1] = fmt:format(...) end

  if type(cfg.positionSources) ~= "table" or #cfg.positionSources == 0 then
    err("positionSources must list at least one source -- navigation cannot fix without one")
  end
  if type(cfg.gpsTimeout) ~= "number" or cfg.gpsTimeout <= 0 or cfg.gpsTimeout > 10 then
    err("gpsTimeout must be between 0 and 10 seconds")
  end
  if type(cfg.fixEverySeconds) ~= "number" or cfg.fixEverySeconds < 0.5 then
    err("fixEverySeconds must be at least 0.5 -- each fix blocks this computer")
  end
  if type(cfg.fixStaleMs) ~= "number" or cfg.fixStaleMs < 200 then
    err("fixStaleMs must be at least 200")
  end
  if type(cfg.reckonUsefulMs) ~= "number" or cfg.reckonUsefulMs <= 0 then
    err("reckonUsefulMs must be positive")
  end
  for _, key in ipairs({ "navFixProtocol", "telemetryProtocol", "navCommandProtocol",
    "waypointsPath", "routesPath" }) do
    if type(cfg[key]) ~= "string" or cfg[key] == "" then err("%s must be set", key) end
  end
  if type(cfg.markMinQuality) ~= "number" or cfg.markMinQuality < 0
    or cfg.markMinQuality > 1 then
    err("markMinQuality must be between 0 and 1")
  end

  local HEADING_SOURCES = { navtable = true, gimbal = true, auto = true }
  if not HEADING_SOURCES[cfg.headingSource] then
    err("headingSource must be 'navtable', 'gimbal' or 'auto'")
  end
  if type(cfg.navTable) ~= "string" then err("navTable must be a peripheral name or \"\"") end
  if cfg.navSign ~= 1 and cfg.navSign ~= -1 then err("navSign must be +1 or -1") end
  if cfg.gimbalSign ~= 1 and cfg.gimbalSign ~= -1 then err("gimbalSign must be +1 or -1") end
  if type(cfg.navHeadingStaleMs) ~= "number" or cfg.navHeadingStaleMs < 200 then
    err("navHeadingStaleMs must be at least 200")
  end

  -- A fix taken less often than it goes stale means the position is stale more of the time than
  -- it is fresh, which is legal but almost certainly not intended.
  if type(cfg.fixEverySeconds) == "number" and type(cfg.fixStaleMs) == "number"
    and cfg.fixEverySeconds * 1000 > cfg.fixStaleMs then
    warn("fixEverySeconds (%.1fs) is longer than fixStaleMs (%dms): the position will read "
      .. "stale between fixes", cfg.fixEverySeconds, cfg.fixStaleMs)
  end

  return #errors == 0, errors, warnings
end

function Config.load(path)
  if not fs.exists(path) then return Config.withDefaults({}), false end
  local handle = fs.open(path, "r")
  if not handle then return Config.withDefaults({}), false end
  local body = handle.readAll()
  handle.close()
  local ok, parsed = pcall(textutils.unserialise, body)
  if not ok or type(parsed) ~= "table" then
    return Config.withDefaults({}), false, "config will not parse"
  end
  return Config.withDefaults(parsed), true
end

function Config.save(path, cfg)
  local stage = path .. ".new"
  local handle = fs.open(stage, "w")
  if not handle then return false, "cannot write " .. stage end
  handle.write(textutils.serialise(cfg))
  handle.close()
  if fs.exists(path) then fs.delete(path) end
  fs.move(stage, path)
  return true
end

return Config
