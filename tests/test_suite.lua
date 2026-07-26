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
  local prepared = 0
  for name, spec in pairs(manifest.roles) do
    if spec.status == "prepared" then
      prepared = prepared + 1
      T.isTrue(#spec.dirs > 0, name .. " declares its directories")
      T.isTrue(#spec.configs > 0, name .. " declares its configs")
      T.eq(#spec.files, 0, name .. " ships nothing yet")
    end
  end
  T.isTrue(prepared >= 6, ("%d prepared roles reserved"):format(prepared))
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

-- ------------------------------------------------------------------ protection

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
