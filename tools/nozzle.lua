--[[ nozzle -- does this computer move that nozzle? Nothing else.

     Run on the FLIGHT COMPUTER:  nozzle

     No config, no flight controller, no self test, no mixer. It finds every vector thruster on
     the network, commands each one hard over, reads back what the block says it holds, and
     centres it again. Ten seconds, one screen, and it separates the two possibilities that have
     been impossible to tell apart from the cockpit:

       * the command never arrives     -> ASKED but the target never changes
       * the command arrives, no motion-> target follows, actual stays at 0

     Verified against the Propulsion source: `setVector(x, y)` writes four redstone signals via
     round(x * 15), `tick()` tweens the nozzle toward that target EVERY tick with no dependency on
     power, fuel or throttle, and the renderer tilts the model by vector * 30 degrees. So a
     healthy block moves 18 degrees for the 0.6 commanded here, cold, with an empty tank.
]]

local AIM = 0.6
local SETTLE = 1.5          -- TWEEN_SPEED is 0.2 per tick, so ~1.5 s reaches the target

local VECTOR_TYPES = {
  vector_thruster = true,
  liquid_vector_thruster = true,
  creative_vector_thruster = true,
}

local function typeOf(name)
  local ok, t = pcall(peripheral.getType, name)
  return ok and t or "?"
end

--- Every peripheral that offers setVector, whatever it calls itself. Going by METHOD rather than
--- by type name on purpose: a type this list has not heard of still gets tested, and a type that
--- looks right but exposes no nozzle is reported as such rather than silently skipped.
local function nozzles()
  local out = {}
  for _, name in ipairs(peripheral.getNames()) do
    local dev = peripheral.wrap(name)
    if dev then
      out[#out + 1] = {
        name = name,
        ptype = typeOf(name),
        dev = dev,
        canVector = type(dev.setVector) == "function",
      }
    end
  end
  return out
end

local function num(v)
  if type(v) ~= "number" then return "  --  " end
  return ("%+6.3f"):format(v)
end

local function read(dev, method)
  local fn = dev[method]
  if type(fn) ~= "function" then return nil, "no method" end
  local ok, v = pcall(fn)
  if not ok then return nil, tostring(v) end
  return v
end

term.clear()
term.setCursorPos(1, 1)
print("nozzle -- direct setVector test")
print("")

local found = nozzles()
local vectors = {}
for _, entry in ipairs(found) do
  if VECTOR_TYPES[entry.ptype] or entry.canVector then vectors[#vectors + 1] = entry end
end

if #vectors == 0 then
  print("No peripheral on this network offers setVector.")
  print("")
  print("Peripherals seen:")
  for _, entry in ipairs(found) do print(("  %s  %s"):format(entry.name, entry.ptype)) end
  print("")
  print("If the thrusters are on a wired network, check the modem is ON (right-click it):")
  print("a modem that is off shows no peripherals at all.")
  return
end

print(("%d vector thruster(s). Commanding %.2f, then %.2f."):format(#vectors, AIM, -AIM))
print("Watch the craft. Each nozzle should tilt about 18 degrees.")
print("")

local results = {}

local function commandAll(value)
  for _, entry in ipairs(vectors) do
    if entry.canVector then
      local ok, err = pcall(entry.dev.setVector, value, 0)
      if not ok then entry.writeError = tostring(err) end
    end
  end
end

--- One pass: command, wait for the slew, read back.
local function pass(value, key)
  commandAll(value)
  sleep(SETTLE)
  for _, entry in ipairs(vectors) do
    entry[key] = {
      target = read(entry.dev, "getTargetVectorX"),
      actual = read(entry.dev, "getVectorX"),
    }
  end
end

pass(AIM, "plus")
pass(-AIM, "minus")
commandAll(0)
sleep(0.5)
commandAll(0)

print("name                      asked  target  actual")
for _, entry in ipairs(vectors) do
  if not entry.canVector then
    print(("%-24s  NO setVector (%s)"):format(entry.name:sub(1, 24), entry.ptype))
    results[#results + 1] = "nonozzle"
  elseif entry.writeError then
    print(("%-24s  WRITE ERROR: %s"):format(entry.name:sub(1, 24), entry.writeError))
    results[#results + 1] = "error"
  else
    local p = entry.plus or {}
    print(("%-24s %s %s %s"):format(entry.name:sub(1, 24), num(AIM), num(p.target), num(p.actual)))
    local tookIt = type(p.target) == "number" and math.abs(p.target - AIM) < 0.08
    local moved = type(p.actual) == "number" and math.abs(p.actual) > 0.05
    results[#results + 1] = (tookIt and moved) and "ok" or (tookIt and "stuck" or "ignored")
  end
end

local tally = {}
for _, r in ipairs(results) do tally[r] = (tally[r] or 0) + 1 end

print("")
print("VERDICT")
if (tally.ok or 0) == #results then
  print("  All nozzles took the command and moved.")
  print("  The blocks are fine -- the fault is in what EasyHover commands.")
elseif (tally.ignored or 0) > 0 then
  print(("  %d ignored it: the target never changed."):format(tally.ignored))
  print("  The write is not reaching the block. Suspect a stale peripheral")
  print("  handle -- reboot this computer, and re-check after any contraption")
  print("  assemble or disassemble.")
elseif (tally.stuck or 0) > 0 then
  print(("  %d accepted the target but did not slew to it."):format(tally.stuck))
  print("  The block has the command and is not acting on it. That is a mod-side")
  print("  condition, not a command problem -- note it and report it.")
end
if (tally.nonozzle or 0) > 0 then
  print(("  %d have no setVector at all."):format(tally.nonozzle))
end
if (tally.error or 0) > 0 then
  print(("  %d threw on the write -- the message above is the reason."):format(tally.error))
end
print("")
print("Nozzles were re-centred. Thrust was never touched.")
