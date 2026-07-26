--[[ In-computer probe for tests/run_suite_e2e.sh.

     Runs one phase against the real Suite, fetching from the localhost mirror, and asserts on
     FILESYSTEM OUTCOMES rather than on printed output -- what matters is what ended up on
     disk, and that survives any wording change.

     The phase name is read from /pc_phase.txt; results are written to /pc_result.txt.
]]

local phase = (function()
  local f = fs.open("/pc_phase.txt", "r")
  if not f then return "?" end
  local s = f.readAll()
  f.close()
  return (s or ""):gsub("%s+$", "")
end)()

local lines = {}
local failed = 0

local function ok(msg) lines[#lines + 1] = "  ok   " .. msg end
local function fail(msg)
  lines[#lines + 1] = "  FAIL " .. msg
  failed = failed + 1
end
local function check(condition, msg, detail)
  if condition then ok(msg) else fail(msg .. (detail and ("  -- " .. detail) or "")) end
end

local function read(path)
  if not fs.exists(path) or fs.isDir(path) then return nil end
  local f = fs.open(path, "r")
  if not f then return nil end
  local s = f.readAll()
  f.close()
  return s
end

local function write(path, content)
  local f = fs.open(path, "w")
  f.write(content)
  f.close()
end

local function runSuite(...)
  local args = { ... }
  local before = os.epoch("utc")
  shell.run("/easyhover_suite.lua", table.unpack(args))
  return os.epoch("utc") - before
end

--- Every file under the backup root, flattened.
local function backupFiles()
  local out = {}
  local function walk(dir)
    if not fs.exists(dir) then return end
    for _, name in ipairs(fs.list(dir)) do
      local path = fs.combine(dir, name)
      if fs.isDir(path) then walk(path) else out[#out + 1] = "/" .. path end
    end
  end
  walk("/easyhover_backup")
  return out
end

local function anyBackupMatching(pattern)
  for _, path in ipairs(backupFiles()) do
    if path:find(pattern) then return path end
  end
  return nil
end

--- Search backup CONTENTS, not names. Earlier phases leave their own backups behind, so
--- matching on the filename alone can find the wrong generation of the same config.
local function anyBackupContaining(pattern)
  for _, path in ipairs(backupFiles()) do
    local body = read(path)
    if body and body:find(pattern) then return path end
  end
  return nil
end

local function stateField(field)
  local raw = read("/easyhover_install.txt") or ""
  return raw:match(field .. "=([^\n]+)")
end

local function manifestVersion()
  local body = read("/mirror_manifest.lua")
  if not body then return nil end
  local m = textutils.unserialise(body)
  return m and m.version or nil
end

local function noStagingLeftBehind()
  local leftovers = {}
  local function walk(dir)
    for _, name in ipairs(fs.list(dir)) do
      local path = fs.combine(dir, name)
      if fs.isDir(path) then
        if path ~= "rom" then walk(path) end
      elseif path:find("%.ehnew$") then
        leftovers[#leftovers + 1] = path
      end
    end
  end
  walk("/")
  return leftovers
end

-- A hand-written config that is deliberately MISSING most fields, with one distinctive value.
local HAND_CONFIG = textutils.serialise({
  tuning = { attitudeHz = 13 },
  envelope = { maxBankDeg = 7.5 },
})

-- ---------------------------------------------------------------- phases

if phase == "install" then
  runSuite("flight")
  check(fs.exists("/startup.lua"), "launcher installed as /startup.lua")
  check(fs.exists("/flight/app.lua"), "role files installed")
  check(fs.exists("/flight/lib/control/mixer.lua"), "nested role files installed")
  check(stateField("role") == "flight", "install record names the role",
    tostring(stateField("role")))
  check(stateField("version") == manifestVersion(), "install record matches the release",
    tostring(stateField("version")) .. " vs " .. tostring(manifestVersion()))
  local launcher = read("/startup.lua") or ""
  check(launcher:find("shell%.run"), "launcher uses shell.run")
  check(not launcher:find("App%.new"), "launcher is not a copy of the entry point")
  check(#noStagingLeftBehind() == 0, "no .ehnew staging files left behind")

elseif phase == "current" then
  local versionBefore = stateField("version")
  runSuite()
  check(stateField("version") == versionBefore, "still at the same version")
  check(#backupFiles() == 0, "an up-to-date run backs nothing up",
    table.concat(backupFiles(), ", "))
  check(#noStagingLeftBehind() == 0, "no staging files")

elseif phase == "configkeep" then
  write("/eh_flight_config.tbl", HAND_CONFIG)
  -- force the update path even though the version matches
  runSuite("--repair")

  local body = read("/eh_flight_config.tbl") or ""
  local cfg = textutils.unserialise(body)
  check(type(cfg) == "table", "config still parses")
  if type(cfg) == "table" then
    check(cfg.tuning and cfg.tuning.attitudeHz == 13,
      "MY value survived (attitudeHz = 13)", tostring(cfg.tuning and cfg.tuning.attitudeHz))
    check(cfg.envelope and cfg.envelope.maxBankDeg == 7.5,
      "MY second value survived (maxBankDeg = 7.5)")
    check(cfg.envelope and cfg.envelope.maxPitchDeg ~= nil,
      "a field my file never had was ADDED (envelope.maxPitchDeg)")
    check(cfg.modes ~= nil and cfg.brake ~= nil and cfg.mixer ~= nil,
      "whole sections were added (modes, brake, mixer)")
    check(cfg.tuning and cfg.tuning.altitudeHz ~= nil,
      "sibling defaults filled in alongside my value")
  end
  check(anyBackupMatching("eh_flight_config") ~= nil, "the config was backed up first")

elseif phase == "repair" then
  write("/eh_flight_config.tbl", HAND_CONFIG)
  -- corrupt a role file the way a half-finished download or a chunk unload would
  write("/flight/app.lua", "-- CORRUPTED\n")
  local extra = "/flight/lib/leftover_from_old_release.lua"
  write(extra, "-- stale file from an older release\n")

  runSuite()

  local restored = read("/flight/app.lua") or ""
  check(#restored > 1000, "the corrupt file was replaced with the real one",
    ("%d bytes"):format(#restored))
  check(restored:find("flight computer"), "and it is the real content")
  check(not fs.exists(extra), "a stale file inside the role directory was cleared")
  check(fs.exists("/eh_flight_config.tbl"), "MY CONFIG SURVIVED THE REPAIR")
  local cfg = textutils.unserialise(read("/eh_flight_config.tbl") or "")
  check(type(cfg) == "table" and cfg.tuning and cfg.tuning.attitudeHz == 13,
    "and it still holds my value")
  check(anyBackupMatching("eh_flight_config") ~= nil, "config backed up before the repair")
  check(stateField("version") == manifestVersion(), "back at the release version")

elseif phase == "badconfig" then
  write("/eh_flight_config.tbl", "this is not a lua table at all {{{")
  runSuite("--repair")

  local body = read("/eh_flight_config.tbl") or ""
  local cfg = textutils.unserialise(body)
  check(type(cfg) == "table", "the unparseable config was replaced with a valid one")
  if type(cfg) == "table" then
    check(cfg.tuning ~= nil and cfg.envelope ~= nil, "and it holds real defaults")
  end
  local kept = anyBackupContaining("not a lua table")
  check(kept ~= nil, "the broken original was backed up, not just discarded",
    "no backup contains the broken bytes")
  if kept then check(kept:find("eh_flight_config"), "backed up under its own name", kept) end

elseif phase == "detect" then
  -- The install record is what the Suite normally trusts; without it, it must work out the
  -- role from the files on disk rather than asking (asking would hang a headless run).
  fs.delete("/easyhover_install.txt")
  write("/eh_flight_config.tbl", HAND_CONFIG)
  runSuite("--verify")
  check(stateField("role") == "flight", "role re-detected from the files on disk",
    tostring(stateField("role")))
  check(fs.exists("/eh_flight_config.tbl"), "config untouched by the recovery")

elseif phase == "protect" then
  -- Anything the operator owns must survive the most destructive path the Suite has.
  write("/eh_flight_config.tbl", HAND_CONFIG)
  write("/eh_waypoints.tbl", textutils.serialise({ { name = "Home", x = 1, y = 2, z = 3 } }))
  write("/probe_report.txt", "my probe output")
  fs.makeDir("/easyhover_backup/manual")
  write("/easyhover_backup/manual/keepme.txt", "hand-made backup")

  runSuite("--repair")

  check(fs.exists("/eh_flight_config.tbl"), "config survived --repair")
  check(fs.exists("/eh_waypoints.tbl"), "waypoints survived --repair")
  check((read("/eh_waypoints.tbl") or ""):find("Home"), "waypoints unchanged")
  check(read("/probe_report.txt") == "my probe output", "probe output untouched")
  check(read("/easyhover_backup/manual/keepme.txt") == "hand-made backup",
    "a hand-made backup was not swept away")

elseif phase == "check" then
  -- --check must be a true dry run.
  write("/flight/app.lua", "-- CORRUPTED AGAIN\n")
  local before = read("/flight/app.lua")
  runSuite("--check")
  check(read("/flight/app.lua") == before, "--check wrote nothing, even to a corrupt file")
  check(#noStagingLeftBehind() == 0, "--check staged nothing")

elseif phase == "prepared" then
  local out = runSuite("nav")
  check(not fs.exists("/nav"), "a prepared role installs nothing")
  check(stateField("role") == "flight", "and does not overwrite the current role record",
    tostring(stateField("role")))

elseif phase == "uimain" then
  -- A FRESH install of the other released role, on a bare computer. Nothing else here covers
  -- ui_main, and it is structurally unlike flight: two source trees (ui_main and shared) land
  -- on the computer, plus a 300 KB vendored Basalt that gets RENAMED on the way in.
  runSuite("ui_main")
  check(stateField("role") == "ui_main", "install record names the role",
    tostring(stateField("role")))
  check(fs.exists("/startup.lua"), "launcher installed as /startup.lua")
  check(fs.exists("/ui_main/app.lua"), "role files installed")
  check(fs.exists("/ui_main/ui/slots.lua"), "nested ui files installed")
  check(fs.exists("/ui_main/lib/monitors.lua"), "nested lib files installed")
  check(fs.exists("/shared/util.lua"), "the SECOND source tree landed too")

  -- vendor/basalt-full.lua is installed as /basalt.lua, because that is where require("basalt")
  -- looks. A rename in the manifest is the kind of thing that silently stops working.
  check(fs.exists("/basalt.lua"), "Basalt installed under the name require() expects")
  local basalt = read("/basalt.lua") or ""
  check(#basalt > 200000, "and it is the FULL build, not a truncated download",
    ("%d bytes"):format(#basalt))
  check(basalt:find("createFrame"), "and it is really Basalt")

  -- The launcher must start the UI role, not the flight role.
  local launcher = read("/startup.lua") or ""
  check(launcher:find("ui_main"), "the launcher starts the UI role", launcher)
  check(#noStagingLeftBehind() == 0, "no .ehnew staging files left behind")

  -- No flight files on a UI computer: this is a cockpit screen, not a spare flight computer.
  check(not fs.exists("/flight/app.lua"), "no flight files on a UI computer")

  -- And re-running is a no-op, the same as it is for flight.
  local versionBefore = stateField("version")
  runSuite()
  check(stateField("version") == versionBefore, "an up-to-date re-run changes nothing",
    tostring(stateField("version")))

elseif phase == "beacon" then
  -- The third released role, on a BARE computer. A beacon is a standalone box in the world, so
  -- nothing about the craft's install applies to it.
  runSuite("gps_beacon")
  check(stateField("role") == "gps_beacon", "install record names the role",
    tostring(stateField("role")))
  check(fs.exists("/startup.lua"), "launcher installed")
  check(fs.exists("/gps_beacon/app.lua"), "role files installed")
  check(fs.exists("/gps_beacon/lib/host.lua"), "the GPS host is there")
  check(fs.exists("/gps_beacon/lib/geometry.lua"), "and the constellation maths")
  check(fs.exists("/gps_beacon/ui/panel.lua"), "and its screen")
  check(fs.exists("/shared/log.lua"), "the shared tree landed")
  check(fs.exists("/basalt.lua"), "Basalt installed for the terminal UI")
  check(not fs.exists("/flight/app.lua"), "no flight files on a beacon")
  check(#noStagingLeftBehind() == 0, "no staging files left behind")

  -- It must be RUNNABLE, not merely present: load the entry chain and see it resolve.
  local ok, err = pcall(function()
    local env = setmetatable({ require = require, package = package }, { __index = _G })
    package.path = "/gps_beacon/?.lua;/gps_beacon/?/init.lua;" .. package.path
    local Config = require("lib.config")
    local cfg = Config.withDefaults({ position = { x = 1, y = 2, z = 3 } })
    local Geometry = require("lib.geometry")
    local a = Geometry.assess({ cfg.position })
    return a ~= nil
  end)
  check(ok, "the installed modules load and run", tostring(err))

else
  fail("unknown phase: " .. tostring(phase))
end

-- ---------------------------------------------------------------- report

local header = ("=== %s === %s"):format(phase, failed == 0 and "PASS" or "FAIL")
table.insert(lines, 1, header)
write("/pc_result.txt", table.concat(lines, "\n") .. "\n")

-- SHUT THE COMPUTER DOWN. Without this the probe finishes, CraftOS-PC drops to its shell and
-- sits there until the runner's `timeout 180` kills it -- every phase paying the full 180s
-- even though its work took about a second. Nine phases turned a half-minute suite into 27
-- minutes, and since pc_result.txt was already written by then the runner still reported PASS,
-- so nothing ever pointed at the cause.
os.shutdown()
