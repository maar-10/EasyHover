--[[ Nozzle direction mapping, established by LOOKING at the craft.

     The problem this solves is the one nothing can work out for itself. The mixer turns a wanted
     craft-frame force into a nozzle deflection through each thruster's `vectorMap` and its two
     invert flags -- and those default to the identity. A thruster mounted rotated or mirrored is
     therefore pushed the WRONG WAY, the attitude loop sees the error grow and pushes harder, and
     that is the escalating divergence the whole control design exists to prevent.

     THE FLOW: latch one nozzle at full deflection on one of its own axes, walk outside, see
     which way it actually points, and name it -- LEFT, RIGHT, FORWARD, BACK (or UP/DOWN for the
     rear-facing accelerators, whose nozzles steer in the vertical plane instead). Naming it
     writes the mapping. No abstraction, no guessing.

     WHY IT IS A LATCH AND NOT A HELD SWITCH: CC gives a monitor `monitor_touch` and NOTHING for
     the release -- there is no touch-up event in the API at all. Press-and-hold on a monitor is
     therefore impossible, so a tap latches and a second tap releases, with a watchdog so a
     forgotten deflection cannot be left standing.

     WHAT THE MODEL ALREADY SUPPORTED: nothing about the maths changes. A nozzle's two axes lie
     on two craft axes with a sign each, which is exactly `vectorMap` + the invert flags, and
     Thrusters.mapVector already reads x, y OR z. This module is a better way to SET them.
]]

local Util = require("lib.util")

local AxisMap = {}
AxisMap.__index = AxisMap

--- The craft-frame plane each thruster group's nozzle steers in.
---
--- A down-facing lift thruster tilts fore/aft and left/right. A rear-facing accelerator tilts
--- up/down and left/right -- its nozzle cannot point "forward", so offering that would invite a
--- mapping the geometry cannot hold.
AxisMap.PLANES = {
  lift    = { "x", "z" },
  lateral = { "x", "z" },
  main    = { "x", "y" },
}

--- What each craft axis and sign is CALLED, from the pilot's seat.
AxisMap.NAMES = {
  x = { [1] = "RIGHT", [-1] = "LEFT" },
  y = { [1] = "UP",    [-1] = "DOWN" },
  z = { [1] = "FWD",   [-1] = "BACK" },
}

--- The reassignment keys, and what they mean per plane. a/d are left/right everywhere; w/s are
--- forward/back on a lift or lateral thruster and up/down on an accelerator.
AxisMap.KEYS = {
  a = { axis = "x", sign = -1 },
  d = { axis = "x", sign = 1 },
  w = { z = { axis = "z", sign = 1 },  y = { axis = "y", sign = 1 } },
  s = { z = { axis = "z", sign = -1 }, y = { axis = "y", sign = -1 } },
}

--- Which craft direction the system currently believes a nozzle deflection points.
--- `nozzleAxis` is "x" or "y" -- the nozzle's own axis -- and `sign` is +1 or -1.
function AxisMap.believedDirection(spec, nozzleAxis, sign)
  local map = spec.vectorMap or { x = "x", y = "z" }
  local craftAxis = map[nozzleAxis]
  if craftAxis == nil then return nil end
  local inverted = (nozzleAxis == "x") and spec.invertVectorX or spec.invertVectorY
  local craftSign = inverted and -sign or sign
  local names = AxisMap.NAMES[craftAxis]
  return names and names[craftSign] or nil
end

--- Rewrite one nozzle axis so that `sign` on it points along `craftAxis`/`craftSign`.
---
--- The OTHER nozzle axis is forced onto the remaining axis of the plane, keeping its own sign.
--- Both nozzle axes lying on the same craft axis is geometrically impossible, so allowing it
--- would let the pilot save a mapping the mixer could never satisfy.
function AxisMap.assign(spec, nozzleAxis, sign, craftAxis, craftSign)
  local plane = AxisMap.PLANES[spec.group] or { "x", "z" }
  local isInPlane = false
  for _, axis in ipairs(plane) do if axis == craftAxis then isInPlane = true end end
  if not isInPlane then
    return false, ("a %s thruster's nozzle cannot point along %s"):format(
      tostring(spec.group), tostring(craftAxis))
  end

  local other = (plane[1] == craftAxis) and plane[2] or plane[1]
  local map = { x = nil, y = nil }
  local otherNozzle = (nozzleAxis == "x") and "y" or "x"
  map[nozzleAxis] = craftAxis
  map[otherNozzle] = other

  -- nozzle `sign` must come out as craftSign, so invert when they disagree
  local invert = (sign ~= craftSign)
  spec.vectorMap = map
  if nozzleAxis == "x" then
    spec.invertVectorX = invert
  else
    spec.invertVectorY = invert
  end
  return true
end

-- ---------------------------------------------------------------- the latch

function AxisMap.new(thrusters, peripherals, cfg, log, state)
  local self = setmetatable({}, AxisMap)
  self.thrusters = thrusters
  self.per = peripherals
  self.cfg = cfg
  self.log = log
  self.state = state
  self.hold = nil
  self.timeoutMs = 45000
  return self
end

function AxisMap:isHolding()
  return self.hold ~= nil
end

--- Latch one nozzle at full deflection. `allowed` is the caller's policy decision, as with the
--- self test: this module never decides for itself whether the craft is flyable.
function AxisMap:latch(id, nozzleAxis, sign, opts)
  opts = opts or {}
  if not opts.allowed then
    return false, "nozzle mapping only runs on the ground, with the engine off"
  end
  if nozzleAxis ~= "x" and nozzleAxis ~= "y" then
    return false, "nozzle axis must be x or y"
  end
  local entry = self.per.thrusters[id]
  if not entry then return false, "no such thruster: " .. tostring(id) end
  if entry.canVector == nil then
    entry.canVector = type(entry.dev.setVector) == "function"
  end
  if not entry.canVector then
    return false, ("%s has no nozzle -- nothing to point"):format(id)
  end

  self.hold = {
    id = id,
    axis = nozzleAxis,
    sign = (sign or 1) >= 0 and 1 or -1,
    startedAt = opts.now or os.epoch("utc"),
    lastKeys = {},
  }
  self.log:info("axis map: holding %s nozzle %s%s", id, self.hold.sign > 0 and "+" or "-",
    nozzleAxis)
  self:publish()
  return true
end

function AxisMap:release(reason)
  if not self.hold then return false end
  local id = self.hold.id
  self.thrusters:setVectorRaw(id, 0, 0)
  self.log:info("axis map: released %s (%s)", id, reason or "by the pilot")
  self.hold = nil
  self:publish()
  return true
end

--- Hold the nozzle where it was told to, and watch for a reassignment key.
---
--- `pressed` is a set of key CODES currently down, straight from the typewriter poll. The normal
--- bindings are silenced by the caller while this is active, so a/d/s/w cannot also fly the
--- craft -- which would be an unpleasant surprise while standing next to it.
function AxisMap:tick(now, pressed)
  if not self.hold then return false end
  now = now or os.epoch("utc")

  if now - self.hold.startedAt > self.timeoutMs then
    self:release("timed out")
    return false
  end

  local entry = self.per.thrusters[self.hold.id]
  if not entry then
    self.hold = nil
    self:publish()
    return false
  end

  local spec = entry.spec
  local limit = Util.clamp(spec.maxVector or 0.6, 0, 1)
  local value = self.hold.sign * limit
  local nx = (self.hold.axis == "x") and value or 0
  local ny = (self.hold.axis == "y") and value or 0
  -- RAW: the whole point is the nozzle's own axes. Going through the mapping would let a wrong
  -- mapping cancel against itself and look right.
  self.thrusters:setVectorRaw(self.hold.id, nx, ny)

  self:handleKeys(spec, pressed or {})
  self:publish()
  return true
end

--- Apply a/d/s/w on the EDGE of the press, so holding a key does not rewrite repeatedly.
function AxisMap:handleKeys(spec, pressed)
  local plane = AxisMap.PLANES[spec.group] or { "x", "z" }
  local vertical = (plane[2] == "y") and "y" or "z"

  for name, meaning in pairs(AxisMap.KEYS) do
    local code = keys[name]
    local down = code ~= nil and pressed[code] and true or false
    local was = self.hold.lastKeys[name] and true or false
    self.hold.lastKeys[name] = down

    if down and not was then
      local target = meaning.axis and meaning or meaning[vertical]
      if target then
        local ok, err = AxisMap.assign(spec, self.hold.axis, self.hold.sign,
          target.axis, target.sign)
        if ok then
          self.hold.assigned = AxisMap.believedDirection(spec, self.hold.axis, self.hold.sign)
          self.log:info("axis map: %s nozzle %s%s is now %s", self.hold.id,
            self.hold.sign > 0 and "+" or "-", self.hold.axis, tostring(self.hold.assigned))
          if self.onAssigned then self.onAssigned(self.hold.id) end
        else
          self.hold.error = err
          self.log:warn("axis map: %s", tostring(err))
        end
      end
    end
  end
end

--- What the UI needs: which nozzle is held, and what the system believes it points at.
function AxisMap:publish()
  if not self.state then return end
  if not self.hold then
    self.state:set("axisMap", { holding = false })
    return
  end
  local entry = self.per.thrusters[self.hold.id]
  local spec = entry and entry.spec
  self.state:set("axisMap", {
    holding = true,
    id = self.hold.id,
    axis = self.hold.axis,
    sign = self.hold.sign,
    direction = spec and AxisMap.believedDirection(spec, self.hold.axis, self.hold.sign) or nil,
    group = spec and spec.group or nil,
    error = self.hold.error,
    remainingMs = math.max(0, self.timeoutMs - (os.epoch("utc") - self.hold.startedAt)),
  })
end

return AxisMap
