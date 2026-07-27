--[[ What this computer thinks it has installed, read ONCE AT BOOT.

     The point is not the version number. The point is that it is read when the program STARTS,
     so what you see on screen is the record as it stood when the running code was loaded --
     not as it stands now.

     That difference is the whole reason this file exists. Lua loads at boot; updating files
     under a running program changes nothing until it restarts. "The Suite says it updated and
     nothing changed" has exactly two causes and they need different fixes:

       screen version == manifest version   the new code IS running; the fault is in the code
       screen version <  manifest version   the files updated and this program did not restart

     Without this, both look identical from the pilot's seat, and several rounds of debugging
     can go into the wrong one.
]]

local Install = {}

Install.PATH = "/easyhover_install.txt"

--- Returns { version, role, schema, at }, with `version = "?"` when there is no record --
--- a hand-copied install, or one from before the Suite existed. Never throws: a diagnostic that
--- can crash the program it is diagnosing is worse than no diagnostic.
function Install.read(path)
  path = path or Install.PATH
  local out = { version = "?", role = "?", schema = nil, at = nil }
  if not fs or not fs.exists or not fs.exists(path) then return out end

  local ok, handle = pcall(fs.open, path, "r")
  if not ok or not handle then return out end
  local body = handle.readAll() or ""
  handle.close()

  out.version = body:match("version=([%w%.%-_]+)") or "?"
  out.role = body:match("role=([%w_]+)") or "?"
  out.schema = tonumber(body:match("schema=(%d+)"))
  out.at = body:match("at=([^\n]+)")
  return out
end

--- "ui_main a30a9d88" -- short enough for a 15-column footer.
function Install.stamp(record)
  record = record or Install.read()
  return ("%s %s"):format(tostring(record.role), tostring(record.version))
end

return Install
