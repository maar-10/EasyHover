--[[ cfg -- what is ACTUALLY in this computer's config file, and does it match the network?

     Run on the FLIGHT COMPUTER:

       wget run https://raw.githubusercontent.com/maar-10/EasyHover/main/tools/cfg.lua

     Reads the config FILE directly. No flight controller, no telemetry, no panels -- so it
     works whether or not the app is running, and it cannot be confused by a stale screen.

     WHAT IT IS FOR. Several screens read `hardware.thrusters` from this file:

       AXIS MAP and THR AXES    built straight from it -- an empty list reads "no thrusters"
       SELF TEST                sweeps the thrusters IN IT; an empty list sweeps nothing while
                                still counting down, which looks exactly like a broken sweep
       the mixer                commands the thrusters in it, and nothing else

     while the LIFT / ACCEL / LAT config pages also show CANDIDATES -- the peripherals present on
     the network. Those two are different things, and a craft where the candidate list is full and
     the assigned list is empty looks fine on one screen and broken on every other.
]]

local PATH = "/eh_flight_config.tbl"

local function load(path)
  if not fs.exists(path) then return nil, "no config file at " .. path end
  local handle = fs.open(path, "r")
  if not handle then return nil, "cannot open " .. path end
  local body = handle.readAll()
  handle.close()
  local ok, parsed = pcall(textutils.unserialise, body)
  if not ok or type(parsed) ~= "table" then return nil, "config will not parse" end
  return parsed
end

local function present(name)
  if not name or name == "" then return false end
  local ok, dev = pcall(peripheral.wrap, name)
  return ok and dev ~= nil
end

term.clear()
term.setCursorPos(1, 1)

local okInstall, Install = pcall(require, "shared.install")
if okInstall and Install then
  local record = Install.read()
  print(("build: %s %s"):format(tostring(record.role), tostring(record.version)))
end

local cfg, err = load(PATH)
if not cfg then
  print("CONFIG: " .. tostring(err))
  print("")
  print("The flight computer has nothing to fly with. Assign hardware from")
  print("the config screens, or restore a saved config from a disk.")
  return
end

local thrusters = (cfg.hardware or {}).thrusters or {}
print(("config: %s"):format(PATH))
print(("hardware.thrusters: %d entr%s"):format(#thrusters, #thrusters == 1 and "y" or "ies"))
print("")

if #thrusters == 0 then
  print("EMPTY -- and that alone explains all of this:")
  print("  AXIS MAP / THR AXES  read this list, so they say 'no thrusters'")
  print("  SELF TEST            sweeps this list, so it moves nothing while")
  print("                       still counting down")
  print("  the mixer            has nothing to command")
  print("")
  print("The config pages can still look right: they also list CANDIDATES,")
  print("which are the peripherals on the network, not the ones assigned.")
else
  local byGroup, missing = {}, 0
  for _, t in ipairs(thrusters) do
    local group = tostring(t.group or "?")
    byGroup[group] = (byGroup[group] or 0) + 1
    local here = present(t.peripheral)
    if not here then missing = missing + 1 end
    print(("  %-12s %-24s %s"):format(tostring(t.id), tostring(t.peripheral),
      here and "ok" or "NOT ON THIS NETWORK"))
  end
  print("")
  local parts = {}
  for group, n in pairs(byGroup) do parts[#parts + 1] = ("%s %d"):format(group, n) end
  table.sort(parts)
  print("by group: " .. table.concat(parts, "  "))
  if missing > 0 then
    print(("%d assigned thruster(s) are NOT reachable from this computer."):format(missing))
    print("The mixer and the self test address them by peripheral name, so")
    print("those will never move however the nozzles behave.")
  end
end

-- and what IS on the network, so the two lists can be compared at a glance
local seen = 0
for _, name in ipairs(peripheral.getNames()) do
  local ok, t = pcall(peripheral.getType, name)
  if ok and type(t) == "string" and t:find("thruster") then seen = seen + 1 end
end
print("")
print(("thruster peripherals on this network: %d"):format(seen))
if seen > 0 and #thrusters == 0 then
  print("So the hardware is there and nothing is assigned to it.")
end
