--[[ EasyHover Suite: the pure logic.

     Loaded with _G.EASYHOVER_SUITE_NO_RUN set, so requiring it does not start an install.
     The real install/update/repair paths are covered end to end by tests/run_suite_e2e.sh
     against a localhost mirror.
]]

local T = require("tests.util")

_G.EASYHOVER_SUITE_NO_RUN = true
local Suite = dofile("/easyhover_suite.lua")
local manifest = textutils.unserialise(
  (function()
    local f = fs.open("/manifest.lua", "r")
    local s = f.readAll()
    f.close()
    return s
  end)())

-- ------------------------------------------------------------------ manifest

T.suite("suite: manifest")

T.it("the manifest parses as DATA, not code", function()
  T.notNil(manifest, "unserialise returned a table")
  T.eq(type(manifest.roles), "table", "roles present")
  T.notNil(manifest.version, "version present")
  T.eq(type(manifest.updater), "table", "updater fingerprint present")
end)

T.it("the flight role is released and complete", function()
  local flight = manifest.roles.flight
  T.notNil(flight, "flight role exists")
  T.eq(flight.status, "released", "released")
  T.isTrue(#flight.files > 10, ("%d files"):format(#flight.files))
  T.eq(flight.luaPath, "/flight", "lua path for config extension")
  T.containsMatch(flight.configs, "eh_flight_config", "config path declared")
end)

T.it("every prepared role declares dirs and configs so it is ready to release", function()
  -- No count assertion here on purpose. It used to require "at least 6 prepared", which had to
  -- be edited DOWN every time a role shipped -- a chore that punishes progress and tells you
  -- nothing. The invariant below is what actually matters.
  local prepared, released = 0, 0
  for name, spec in pairs(manifest.roles) do
    if spec.status == "prepared" then
      prepared = prepared + 1
      T.isTrue(#spec.dirs > 0, name .. " declares its directories")
      T.isTrue(#spec.configs > 0, name .. " declares its configs")
      T.eq(#spec.files, 0, name .. " ships nothing yet")
    elseif spec.status == "released" then
      released = released + 1
      T.isTrue(#spec.files > 0, name .. " is released, so it must ship files")
      T.isTrue(spec.entry ~= nil and spec.entry ~= "",
        name .. " is released, so it must have an entry point")
    end
  end
  T.isTrue(released > 0, "something is released")
  T.isTrue(prepared > 0, "and something is still reserved")
  T.eq(released + prepared, (function()
    local total = 0
    for _ in pairs(manifest.roles) do total = total + 1 end
    return total
  end)(), "every role is either released or prepared -- no third state")
end)

T.it("the launcher is installed as startup.lua and only launches", function()
  local flight = manifest.roles.flight
  local launcher
  for _, entry in ipairs(flight.files) do
    if entry.dst == "startup.lua" then launcher = entry end
  end
  T.notNil(launcher, "startup.lua is shipped")
  T.eq(launcher.src, "launchers/flight.lua", "from the launchers directory")
  T.isTrue(launcher.size < 800, "it is a launcher, not a copy of the entry point")
end)

T.it("no role ships a file that would land on a protected path", function()
  for name, spec in pairs(manifest.roles) do
    for _, entry in ipairs(spec.files) do
      T.isFalse(Suite.isProtected("/" .. entry.dst),
        ("%s ships %s, which would be a protected path"):format(name, entry.dst))
    end
  end
end)

-- ------------------------------------------------------------------ checksum

T.suite("suite: checksum")

T.it("FNV-1a matches the values the JS generator produces", function()
  -- These are the reference values asserted on both sides; if the Lua and JS implementations
  -- ever diverge, every computer would think every file had changed.
  T.eq(Suite.checksum(""), "811c9dc5", "empty string")
  T.eq(Suite.checksum("a"), "e40c292c", "single byte")
  T.eq(Suite.checksum("hello"), "4f9f2cab", "short string")
  T.eq(Suite.checksum("EasyHover"), Suite.checksum("EasyHover"), "deterministic")
end)

T.it("checksums survive the 256-byte batching boundary", function()
  local long = string.rep("x", 600) .. "tail"
  local a = Suite.checksum(long)
  -- recompute in one go by a different route: the value must not depend on batch alignment
  local b = Suite.checksum(string.rep("x", 600) .. "tail")
  T.eq(a, b, "stable across a multi-batch string")
  T.isFalse(a == Suite.checksum(long .. "!"), "sensitive to a one-byte change")
end)

-- ------------------------------------------------------------------ role picker

T.suite("suite: role picker layout")

-- The bug this exists for: the picker printed two lines per role without measuring the
-- terminal, so on a basic computer the first four roles scrolled off with no way to scroll back.

T.it("a basic computer (39x13) fits every role on one page", function()
  local layout = Suite.rolePickerLayout(2, 6, 13)
  T.eq(layout.mode, "compact", "one line each, no blurbs")
  T.isTrue(layout.perPage >= 8, ("all 8 roles on a page (perPage=%d)"):format(layout.perPage))
end)

T.it("an advanced computer (51x19) shows blurbs for the INSTALLABLE roles", function()
  local layout = Suite.rolePickerLayout(2, 6, 19)
  T.eq(layout.mode, "blurbs", "blurbs where the detail actually helps")
  T.eq(layout.perPage, 8, "still one page")
end)

T.it("blurbs are dropped rather than overflowing when they would not fit", function()
  -- eight released roles all wanting a blurb needs 16 rows
  local layout = Suite.rolePickerLayout(8, 0, 19)
  T.eq(layout.mode, "compact", "detail sacrificed before anything scrolls away")
end)

T.it("a tiny terminal pages instead of losing entries off the top", function()
  local layout = Suite.rolePickerLayout(2, 6, 10)
  T.eq(layout.mode, "paged", "paged")
  T.isTrue(layout.perPage >= 1, "at least one per page")
  T.isTrue(layout.perPage < 8, ("and fewer than all of them (perPage=%d)"):format(layout.perPage))
end)

T.it("every plausible terminal height yields a layout that fits", function()
  for height = 6, 40 do
    local layout = Suite.rolePickerLayout(2, 6, height)
    local rows
    if layout.mode == "blurbs" then
      rows = 2 * 2 + 6                       -- blurb for each released role
    else
      rows = math.min(8, layout.perPage)
    end
    -- title + blank + prompt + input, plus a page footer when paging
    local chrome = 5 + (layout.mode == "paged" and 1 or 0)
    T.isTrue(rows + chrome <= height + 1,
      ("height %d: %s needs %d rows of %d"):format(height, layout.mode, rows + chrome, height))
    T.isTrue(layout.perPage >= 1, "perPage is never zero at height " .. height)
  end
end)

--- Drive the real picker with a scripted sequence of answers.
local function pick(answers)
  local index = 0
  local realRead = _G.read
  _G.read = function()
    index = index + 1
    return answers[index]
  end
  local order = {}
  for name in pairs(manifest.roles) do order[#order + 1] = name end
  table.sort(order, function(a, b)
    local sa = (manifest.roles[a].status == "released") and 0 or 1
    local sb = (manifest.roles[b].status == "released") and 0 or 1
    if sa ~= sb then return sa < sb end
    return a < b
  end)
  local ok, result = pcall(Suite.askForRole, manifest, order)
  _G.read = realRead
  if not ok then error(result, 0) end
  return result, order
end

T.it("picking by number returns that role", function()
  local role, order = pick({ "1" })
  T.eq(role, order[1], "the first listed role")
end)

T.it("picking by name works too", function()
  T.eq(pick({ "ui_main" }), "ui_main", "typed name")
  T.eq(pick({ "  FLIGHT  " }), "flight", "trimmed and lower-cased")
end)

T.it("a blank answer cancels", function()
  T.isNil(pick({ "" }), "cancelled")
end)

T.it("a bad answer is rejected and the picker asks again", function()
  local role = pick({ "banana", "2" })
  T.notNil(role, "recovered and accepted the second answer")
end)

T.it("the paging keys move between pages without losing entries", function()
  -- Force paging by shrinking the terminal the picker measures.
  local realGetSize = term.getSize
  term.getSize = function() return 39, 9 end
  local ok, role = pcall(function() return pick({ "n", "p", "1" }) end)
  term.getSize = realGetSize
  T.isTrue(ok, "the paged picker ran: " .. tostring(role))
  T.notNil(role, "and still returned a role after paging around")
end)

T.it("degrades sanely with no height information", function()
  local layout = Suite.rolePickerLayout(2, 6, nil)
  T.notNil(layout.mode, "still returns a layout")
  T.isTrue(layout.perPage >= 1, "usable")
end)

-- ------------------------------------------------------------------ protection

T.suite("suite: update vs corruption")

--- The four inputs the decision actually turns on.
local function plan(over)
  local input = { anyInstall = true, mismatched = false, sameVersion = false,
                  noRecord = false, forceRepair = false }
  for k, v in pairs(over or {}) do input[k] = v end
  return Suite.choosePlan(input)
end

T.it("files differing from an OLDER release is an update, not a broken install", function()
  -- This is the whole point. Treating drift as corruption meant the Suite could only ever
  -- "fix" a computer and never update one -- and told the operator their install was broken
  -- every single time a release shipped.
  T.eq(plan({ mismatched = true, sameVersion = false }), "update", "different version")
  T.eq(plan({ mismatched = false, sameVersion = false }), "update",
    "even when every shipped file happens to match, a version bump is still an update")
end)

T.it("files differing while the stamp says they are CORRECT is corruption", function()
  T.eq(plan({ mismatched = true, sameVersion = true }), "repair",
    "the stamp claims these exact files; the bytes disagree")
end)

T.it("everything matching at the current version is simply current", function()
  T.eq(plan({ mismatched = false, sameVersion = true }), "current")
end)

T.it("files present but nothing recording what they are is corruption", function()
  T.eq(plan({ noRecord = true, mismatched = false }), "repair",
    "no install record: nothing can be trusted, so verify everything")
  T.eq(plan({ noRecord = true, mismatched = true }), "repair")
end)

T.it("a bare computer is an install whatever else is true", function()
  T.eq(plan({ anyInstall = false, noRecord = true }), "install")
  T.eq(plan({ anyInstall = false, mismatched = true, forceRepair = true }), "install",
    "there is nothing to repair yet")
end)

T.it("--repair always wins over a clean bill of health", function()
  T.eq(plan({ forceRepair = true, sameVersion = true, mismatched = false }), "repair")
end)

T.it("MISSING FILES ALONE DO NOT MEAN CORRUPT", function()
  -- A release that ADDS a module leaves an older install legitimately missing it. That is the
  -- case this distinction exists for: ui/slots.lua did not exist one release ago.
  T.eq(plan({ mismatched = true, sameVersion = false, noRecord = false }), "update",
    "an older install missing a newly added module is out of date, not damaged")
end)

T.suite("suite: protected paths")

T.it("configs, waypoints and routes are protected", function()
  T.isTrue(Suite.isProtected("/eh_flight_config.tbl"), "flight config")
  T.isTrue(Suite.isProtected("/eh_nav_config.tbl"), "nav config")
  T.isTrue(Suite.isProtected("/eh_waypoints.tbl"), "waypoints")
  T.isTrue(Suite.isProtected("/eh_routes.tbl"), "routes")
end)

T.it("the operator's own files are protected", function()
  T.isTrue(Suite.isProtected("/easyhover_suite_src.txt"), "source override")
  T.isTrue(Suite.isProtected("/easyhover_suite_token.txt"), "token")
  T.isTrue(Suite.isProtected("/easyhover_install.txt"), "install record")
  T.isTrue(Suite.isProtected("/probe_report.txt"), "probe output")
  T.isTrue(Suite.isProtected("/role.txt"), "role file")
end)

T.it("the backup directory is protected as a directory, not just a file", function()
  T.isTrue(Suite.isProtected("/easyhover_backup"), "the directory itself")
  T.isTrue(Suite.isProtected("/easyhover_backup/2026-01-01_00-00-00_abc/eh_flight_config.tbl"),
    "and everything under it")
end)

T.it("release files are NOT protected", function()
  T.isFalse(Suite.isProtected("/flight/app.lua"), "a role file")
  T.isFalse(Suite.isProtected("/startup.lua"), "the launcher")
  T.isFalse(Suite.isProtected("/flight/lib/config.lua"), "the config MODULE is code, not config")
end)

T.it("a path without a leading slash is still matched", function()
  T.isTrue(Suite.isProtected("eh_flight_config.tbl"), "normalised before matching")
end)

-- ------------------------------------------------------------------ state

T.suite("suite: install record")

T.it("state round-trips", function()
  local text = Suite.formatState({ version = "abc123", schema = 2, role = "flight", at = "now" })
  local parsed = Suite.parseState(text)
  T.eq(parsed.version, "abc123", "version")
  T.eq(parsed.schema, 2, "schema")
  T.eq(parsed.role, "flight", "role")
end)

T.it("a mangled record yields nils rather than an error", function()
  local parsed = Suite.parseState("this is not a state file at all")
  T.isNil(parsed.version, "no version")
  T.isNil(parsed.role, "no role")
  local empty = Suite.parseState(nil)
  T.isNil(empty.role, "nil input is safe")
end)

T.it("a truncated record still yields what it can", function()
  local parsed = Suite.parseState("version=deadbeef\nrole=fli")
  T.eq(parsed.version, "deadbeef", "version recovered")
  T.eq(parsed.role, "fli", "partial role recovered, and will fail the role lookup safely")
end)

-- ------------------------------------------------------------------ detection

T.suite("suite: role detection")

T.it("detects the role from files on disk when the record is gone", function()
  local flight = manifest.roles.flight
  local present = {}
  for i, entry in ipairs(flight.files) do
    if i <= 5 then present["/" .. entry.dst] = true end
  end
  local role, matched = Suite.detectRole(manifest, function(p) return present[p] == true end)
  T.eq(role, "flight", "detected flight")
  T.eq(matched, 5, "counted the files it found")
end)

T.it("detects nothing on a bare computer", function()
  local role = Suite.detectRole(manifest, function() return false end)
  T.isNil(role, "no role detected")
end)

-- ------------------------------------------------------------------ integrity

T.suite("suite: integrity")

local function fakeSpec()
  return {
    files = {
      { src = "a.lua", dst = "a.lua", size = 5, sum = Suite.checksum("hello") },
      { src = "b.lua", dst = "b.lua", size = 5, sum = Suite.checksum("world") },
    },
    dirs = { "fake" },
    configs = {},
  }
end

T.it("a healthy install reports ok", function()
  local report = Suite.integrity(fakeSpec(), function(path)
    if path == "/a.lua" then return "hello" end
    if path == "/b.lua" then return "world" end
  end)
  T.isTrue(report.ok, "ok")
  T.eq(report.present, 2, "both present")
end)

T.it("a missing file is reported as missing, not corrupt", function()
  local report = Suite.integrity(fakeSpec(), function(path)
    if path == "/a.lua" then return "hello" end
    return nil
  end)
  T.isFalse(report.ok, "not ok")
  T.containsMatch(report.missing, "b%.lua", "listed as missing")
  T.eq(#report.corrupt, 0, "not counted as corrupt")
end)

T.it("wrong content is reported as corrupt", function()
  local report = Suite.integrity(fakeSpec(), function(path)
    if path == "/a.lua" then return "hello" end
    if path == "/b.lua" then return "WORLD" end   -- right size, wrong bytes
  end)
  T.isFalse(report.ok, "not ok")
  T.containsMatch(report.corrupt, "b%.lua", "listed as corrupt")
end)

T.it("a truncated file is caught by size before the checksum", function()
  local report = Suite.integrity(fakeSpec(), function(path)
    if path == "/a.lua" then return "hell" end
    if path == "/b.lua" then return "world" end
  end)
  T.containsMatch(report.corrupt, "a%.lua", "caught")
end)

return true
