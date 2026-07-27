--[[ nozzle -- does this computer's writes reach that block? Nothing else.

     Run on the FLIGHT COMPUTER:

       wget run https://raw.githubusercontent.com/maar-10/EasyHover/main/tools/nozzle.lua

     No config, no flight controller, no self test, no mixer.

     Settled from the Propulsion source, so it is not what is being tested here: a vector nozzle
     tweens toward its target EVERY tick with no gate on power, fuel, isWorking() or ControlMode,
     and the renderer tilts it by vector * 30 degrees with no throttle term. A healthy block moves
     ~18 degrees for the 0.6 commanded here, cold, with an empty tank.

     WHAT THIS SPLITS APART, now that "target never changed" is the known symptom:

       immediate read 0.6, later read 0  -> the write landed and something reverted it
       immediate read 0 too              -> the write never took effect at all
       getPower() nonzero                -> OTHER writes from this computer do land, so the
                                            problem is specific to vectoring
       getPower() zero everywhere        -> no write from this computer lands, and the handle is
                                            almost certainly pointing at a block entity that is
                                            no longer the live one

     That last case is the one to expect on a Create: Simulated contraption. Assembling moves the
     blocks into a physics sub-level and rebuilds their block entities; a peripheral wrapped
     before that still answers reads from the object it captured, so it looks perfectly healthy
     and silently discards every write.
]]

local AIM = 0.6
local SETTLE = 1.5          -- TWEEN_SPEED is 0.2 per tick, so ~1.5 s reaches the target

local function typeOf(name)
  local ok, t = pcall(peripheral.getType, name)
  return ok and t or "?"
end

local function read(dev, method)
  local fn = dev[method]
  if type(fn) ~= "function" then return nil end
  local ok, v = pcall(fn)
  if not ok then return nil end
  return v
end

local function num(v, width)
  if type(v) ~= "number" then return (" "):rep((width or 6) - 2) .. "--" end
  return ("%+.3f"):format(v)
end

--- Found by METHOD, not by type name: an unfamiliar type is still tested, and a familiar one
--- that exposes no nozzle is reported rather than skipped.
local found, vectors = {}, {}
for _, name in ipairs(peripheral.getNames()) do
  local dev = peripheral.wrap(name)
  if dev then
    local entry = { name = name, ptype = typeOf(name), dev = dev }
    found[#found + 1] = entry
    if type(dev.setVector) == "function" then vectors[#vectors + 1] = entry end
  end
end

term.clear()
term.setCursorPos(1, 1)
print("nozzle -- do this computer's writes reach the block?")
print("")

if #vectors == 0 then
  print("Nothing here offers setVector.")
  for _, entry in ipairs(found) do print(("  %s  %s"):format(entry.name, entry.ptype)) end
  return
end

-- ---- 1. do OTHER writes from this computer land? A pure read: the flight controller commands
-- throttle continuously, so a live handle shows it. Nothing is commanded here.
local poweredCount = 0
for _, entry in ipairs(vectors) do
  entry.power = read(entry.dev, "getPower")
  if type(entry.power) == "number" and entry.power > 0.001 then poweredCount = poweredCount + 1 end
end

-- ---- 2. write, read back AT ONCE, then again after the slew
for _, entry in ipairs(vectors) do
  entry.before = read(entry.dev, "getTargetVectorX")
  local ok, err = pcall(entry.dev.setVector, AIM, 0)
  entry.threw = (not ok) and tostring(err) or nil
  entry.immediate = read(entry.dev, "getTargetVectorX")
end
sleep(SETTLE)
for _, entry in ipairs(vectors) do
  entry.later = read(entry.dev, "getTargetVectorX")
  entry.actual = read(entry.dev, "getVectorX")
end

-- ---- 3. put everything back
for _, entry in ipairs(vectors) do pcall(entry.dev.setVector, 0, 0) end
sleep(0.3)
for _, entry in ipairs(vectors) do pcall(entry.dev.setVector, 0, 0) end

print(("%d vector thruster(s). Asked for %+.2f on X."):format(#vectors, AIM))
print("")
print("name                 pwr    now   +1.5s  angle")
local landed, reverted, ignored, threw = 0, 0, 0, 0
for _, entry in ipairs(vectors) do
  local short = entry.name:gsub("^liquid_", "l_"):gsub("^creative_", "c_"):sub(1, 20)
  if entry.threw then
    threw = threw + 1
    print(("%-20s THREW: %s"):format(short, entry.threw:sub(1, 28)))
  else
    print(("%-20s %s %s %s %s"):format(short, num(entry.power), num(entry.immediate),
      num(entry.later), num(entry.actual)))
    local tookIt = type(entry.immediate) == "number" and math.abs(entry.immediate - AIM) < 0.08
    local held = type(entry.later) == "number" and math.abs(entry.later - AIM) < 0.08
    if tookIt and held then landed = landed + 1
    elseif tookIt then reverted = reverted + 1
    else ignored = ignored + 1 end
  end
end

print("")
print("VERDICT")
if landed == #vectors then
  print("  Every write landed and held. The blocks are fine.")
elseif reverted > 0 then
  print(("  %d took the value then LOST it within 1.5 s."):format(reverted))
  print("  Something is writing these nozzles as well as this computer.")
elseif ignored > 0 then
  print(("  %d never took the value at all."):format(ignored))
  if poweredCount > 0 then
    print(("  BUT %d report throttle from this computer, so writes DO land."):format(poweredCount))
    print("  Reads and throttle work while vectoring does not -- that is a")
    print("  mod-side condition worth reporting upstream.")
  else
    print("  And NONE reports any throttle, though the flight controller")
    print("  commands it constantly. So no write from this computer lands:")
    print("  these handles answer reads from a block entity that is no longer")
    print("  the live one.")
    print("")
    print("  On a Create: Simulated craft, assembling rebuilds the block")
    print("  entities. REBOOT THE FLIGHT COMPUTER while the craft is in the")
    print("  state you will fly it in, and run this again.")
  end
end
if threw > 0 then print(("  %d threw on the write."):format(threw)) end
print("")
print("Nozzles re-centred. Thrust was never touched.")
