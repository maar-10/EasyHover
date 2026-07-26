--[[ Navigation geometry. Pure functions, no peripherals, no state.

     Minecraft's frame, which is not the one a navigator expects:

       +x = EAST, +z = SOUTH, +y = UP.

     So a compass bearing is measured from -z (north) toward +x (east), which makes it
     `atan2(dx, -dz)` and NOT the `atan2(dy, dx)` of ordinary maths. Getting that wrong gives a
     course that is right in one quadrant and wrong in the other three, which is the kind of
     error that looks like "the autopilot mostly works".

     Everything here is flat-earth 2D on the x/z plane with altitude carried separately, because
     that is what the craft actually flies: horizontal guidance and a vertical channel.
]]

local Geo = {}

--- Wrap degrees into [0, 360).
function Geo.wrap360(degrees)
  local d = degrees % 360
  if d < 0 then d = d + 360 end
  return d
end

--- Wrap degrees into (-180, 180] -- the form a steering error must take, so that turning
--- through 359 degrees is expressed as -1 rather than as the long way round.
function Geo.wrap180(degrees)
  local d = Geo.wrap360(degrees + 180) - 180
  if d <= -180 then d = d + 360 end
  return d
end

--- Horizontal distance between two points, ignoring altitude.
function Geo.distance(from, to)
  local dx = (to.x or 0) - (from.x or 0)
  local dz = (to.z or 0) - (from.z or 0)
  return math.sqrt(dx * dx + dz * dz)
end

--- Straight-line distance including altitude.
function Geo.distance3(from, to)
  local dy = (to.y or 0) - (from.y or 0)
  local flat = Geo.distance(from, to)
  return math.sqrt(flat * flat + dy * dy)
end

--- Compass bearing from one point to another, in degrees: 0 = north, 90 = east.
---
--- In Minecraft north is -z and east is +x, so this is atan2(dx, -dz). Returns nil when the two
--- points coincide -- a bearing to where you already are is not a number, and returning 0 there
--- would send a guidance law confidently northward.
function Geo.bearing(from, to)
  local dx = (to.x or 0) - (from.x or 0)
  local dz = (to.z or 0) - (from.z or 0)
  if math.abs(dx) < 1e-9 and math.abs(dz) < 1e-9 then return nil end
  return Geo.wrap360(math.deg(math.atan2(dx, -dz)))
end

--- Signed turn needed to get from `heading` onto `bearing`: + = turn right.
function Geo.turnTo(heading, bearing)
  if heading == nil or bearing == nil then return nil end
  return Geo.wrap180(bearing - heading)
end

--- Unit vector along a compass bearing, in world axes.
function Geo.unitFor(bearing)
  local rad = math.rad(bearing or 0)
  return { x = math.sin(rad), z = -math.cos(rad) }
end

--- Course over ground and speed from a displacement over `dt` seconds.
---
--- Returns nil when the craft has barely moved: a course computed from sensor noise is worse
--- than admitting you do not know which way you are pointing.
function Geo.courseOverGround(from, to, dt, minSpeed)
  if dt == nil or dt <= 0 then return nil end
  local d = Geo.distance(from, to)
  local speed = d / dt
  if speed < (minSpeed or 0.15) then return nil, speed end
  return Geo.bearing(from, to), speed
end

--- Rotate a CRAFT-frame horizontal vector into WORLD axes, given a heading.
---
--- Needed because the velocity sensors read along the craft's own axes (forward / right), and
--- dead reckoning has to add displacement in world axes. Without a heading this cannot be done
--- at all -- which is why heading is a hard dependency of dead reckoning, not a nicety.
function Geo.craftToWorld(forward, right, heading)
  local rad = math.rad(heading or 0)
  local sin, cos = math.sin(rad), math.cos(rad)
  -- craft forward points along the heading; craft right is 90 degrees clockwise of it
  return {
    x = forward * sin + right * cos,
    z = -forward * cos + right * sin,
  }
end

--- Cross-track error: how far off the direct line from `origin` to `target` the craft is.
--- Positive = right of the intended track.
function Geo.crossTrack(origin, target, position)
  local legX = (target.x or 0) - (origin.x or 0)
  local legZ = (target.z or 0) - (origin.z or 0)
  local legLength = math.sqrt(legX * legX + legZ * legZ)
  if legLength < 1e-9 then return 0 end
  local toX = (position.x or 0) - (origin.x or 0)
  local toZ = (position.z or 0) - (origin.z or 0)
  -- 2D cross product, normalised: sign gives the side
  return (legX * toZ - legZ * toX) / legLength
end

--- How far ALONG the leg the craft has travelled, in blocks. Negative = behind the origin.
function Geo.alongTrack(origin, target, position)
  local legX = (target.x or 0) - (origin.x or 0)
  local legZ = (target.z or 0) - (origin.z or 0)
  local legLength = math.sqrt(legX * legX + legZ * legZ)
  if legLength < 1e-9 then return 0 end
  local toX = (position.x or 0) - (origin.x or 0)
  local toZ = (position.z or 0) - (origin.z or 0)
  return (legX * toX + legZ * toZ) / legLength
end

--- Seconds to cover `distance` at `speed`, or nil when it would never arrive.
---
--- nil rather than infinity on purpose: a UI can print "--" for nil, whereas math.huge tends to
--- render as "inf" or to poison an arithmetic chain three modules away.
function Geo.eta(distance, speed)
  if type(speed) ~= "number" or speed <= 0.05 then return nil end
  return distance / speed
end

--- The 16-point compass name for a bearing, for a display too narrow for numbers.
local POINTS = { "N", "NNE", "NE", "ENE", "E", "ESE", "SE", "SSE",
                 "S", "SSW", "SW", "WSW", "W", "WNW", "NW", "NNW" }

function Geo.compassPoint(bearing)
  if type(bearing) ~= "number" then return "--" end
  local index = math.floor(Geo.wrap360(bearing) / 22.5 + 0.5) % 16
  return POINTS[index + 1]
end

return Geo
