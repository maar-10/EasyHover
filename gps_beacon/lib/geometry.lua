--[[ Constellation geometry: is this set of beacons capable of giving a fix at all?

     Every rule here comes from reading CC's own gps.locate() (rom/apis/gps.lua), not from
     guesswork, because the failure modes are silent:

       * It trilaterates from THREE fixes, which yields TWO candidate positions, and then uses a
         FOURTH to narrow them down. It only returns once it has one candidate and not two -- so
         with fewer than four hosts, or with four that cannot disambiguate, locate() returns
         NOTHING. Not a worse fix: nothing.
       * Four COPLANAR hosts cannot disambiguate, because the mirror image of the true position
         through that plane fits every measured distance equally well. Four beacons in a flat
         ring at the same height is the most natural thing to build and it does not work.
       * Two fixes less than 1 block apart REPLACE each other rather than both counting, so two
         beacons in adjacent blocks are one beacon as far as GPS is concerned.

     So the quality figure here is not decoration. It is the difference between a nav system and
     a nav system that silently never answers.
]]

local Geometry = {}

--- CC needs four usable hosts: three to trilaterate, one to resolve the mirror.
Geometry.REQUIRED_HOSTS = 4

--- Fixes closer together than this are merged by gps.locate(), so they count once.
Geometry.MIN_SEPARATION = 1.0

--- Below this, the four are close enough to coplanar that the mirror cannot be resolved
--- reliably. Expressed as the tetrahedron's volume relative to its own scale, so it is
--- dimensionless and does not change meaning when the constellation gets bigger.
Geometry.COPLANAR_LIMIT = 0.02

local function subtract(a, b)
  return { x = a.x - b.x, y = a.y - b.y, z = a.z - b.z }
end

local function cross(a, b)
  return {
    x = a.y * b.z - a.z * b.y,
    y = a.z * b.x - a.x * b.z,
    z = a.x * b.y - a.y * b.x,
  }
end

local function dot(a, b)
  return a.x * b.x + a.y * b.y + a.z * b.z
end

local function length(a)
  return math.sqrt(dot(a, a))
end

function Geometry.distance(a, b)
  return length(subtract(a, b))
end

--- Six times the volume of the tetrahedron formed by four points. Zero means coplanar.
function Geometry.tetraVolume6(a, b, c, d)
  return math.abs(dot(subtract(b, a), cross(subtract(c, a), subtract(d, a))))
end

--- Every pairwise distance, and the smallest of them.
function Geometry.separations(hosts)
  local pairs_, smallest = {}, nil
  for i = 1, #hosts do
    for j = i + 1, #hosts do
      local d = Geometry.distance(hosts[i], hosts[j])
      pairs_[#pairs_ + 1] = { a = i, b = j, distance = d }
      if smallest == nil or d < smallest then smallest = d end
    end
  end
  return pairs_, smallest
end

--- Assess a constellation. `hosts` is a list of { x, y, z, label }.
---
--- Returns a table the beacon UI can show directly:
---   { usable, grade, volume, spread, minSeparation, coplanar, problems, hostCount }
---
--- `grade` is one of "UNUSABLE" | "POOR" | "GOOD" | "EXCELLENT", and `problems` is a list of
--- plain sentences naming what to move. A number nobody can act on is not worth showing.
function Geometry.assess(hosts)
  hosts = hosts or {}
  local out = {
    hostCount = #hosts,
    usable = false,
    grade = "UNUSABLE",
    problems = {},
    volume = 0,
    spread = 0,
    minSeparation = nil,
    coplanar = false,
  }
  local function problem(fmt, ...)
    out.problems[#out.problems + 1] = select("#", ...) > 0 and fmt:format(...) or fmt
  end

  if #hosts < Geometry.REQUIRED_HOSTS then
    problem("only %d of %d beacons -- gps.locate() needs four and returns NOTHING with fewer",
      #hosts, Geometry.REQUIRED_HOSTS)
    return out
  end

  local _, smallest = Geometry.separations(hosts)
  out.minSeparation = smallest
  if smallest < Geometry.MIN_SEPARATION then
    problem("two beacons are %.1f blocks apart; closer than %.0f counts as ONE host",
      smallest, Geometry.MIN_SEPARATION)
  end

  -- Best-conditioned four of however many we have: CC uses the first three plus one to narrow,
  -- but any four non-coplanar hosts will do, so report the best case available.
  local bestVolume, bestScale = 0, 1
  local n = #hosts
  for i = 1, n do
    for j = i + 1, n do
      for k = j + 1, n do
        for l = k + 1, n do
          local volume = Geometry.tetraVolume6(hosts[i], hosts[j], hosts[k], hosts[l])
          -- Scale by the cube of the mean edge length, so the measure is dimensionless.
          local edges = {
            Geometry.distance(hosts[i], hosts[j]), Geometry.distance(hosts[i], hosts[k]),
            Geometry.distance(hosts[i], hosts[l]), Geometry.distance(hosts[j], hosts[k]),
            Geometry.distance(hosts[j], hosts[l]), Geometry.distance(hosts[k], hosts[l]),
          }
          local sum = 0
          for _, e in ipairs(edges) do sum = sum + e end
          local mean = sum / #edges
          local scale = math.max(mean, 1e-6) ^ 3
          if volume / scale > bestVolume / bestScale then
            bestVolume, bestScale = volume, scale
          end
        end
      end
    end
  end

  out.volume = bestVolume / 6
  out.spread = bestVolume / bestScale

  if out.spread < Geometry.COPLANAR_LIMIT then
    out.coplanar = true
    problem("the beacons are effectively COPLANAR -- gps.locate() cannot resolve the mirror "
      .. "position and will return nothing. Move one well above or below the others.")
    return out
  end

  -- Usable from here on; the grade is about how much margin there is.
  out.usable = (#out.problems == 0)
  if not out.usable then
    out.grade = "POOR"
    return out
  end

  if out.spread >= 0.10 then
    out.grade = "EXCELLENT"
  elseif out.spread >= 0.05 then
    out.grade = "GOOD"
  else
    out.grade = "POOR"
    problem("the spread is thin -- a fix will work but is poorly conditioned. "
      .. "Separate the beacons further, especially in height.")
  end
  return out
end

--- A one-line summary for a narrow screen.
function Geometry.summary(assessment)
  if assessment.hostCount < Geometry.REQUIRED_HOSTS then
    return ("%d/%d beacons"):format(assessment.hostCount, Geometry.REQUIRED_HOSTS)
  end
  return ("%s  spread %.3f"):format(assessment.grade, assessment.spread)
end

return Geometry
