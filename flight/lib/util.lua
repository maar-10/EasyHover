--[[ Small pure helpers. No peripherals, no state -- safe to require anywhere. ]]

local Util = {}

function Util.clamp(v, lo, hi)
  if v < lo then return lo end
  if v > hi then return hi end
  return v
end

function Util.round(v)
  return math.floor(v + 0.5)
end

--- Is this table a sequence (list) rather than a map?
-- Empty tables count as maps on purpose: it lets deep-merge fill defaults into an
-- empty user table instead of leaving it bare.
function Util.isList(t)
  return type(t) == "table" and t[1] ~= nil
end

function Util.deepCopy(v)
  if type(v) ~= "table" then return v end
  local out = {}
  for k, val in pairs(v) do out[k] = Util.deepCopy(val) end
  return out
end

--- Merge `src` over a copy of `dst`. Scalars from src win. Maps recurse.
-- Lists are REPLACED wholesale, never merged element-wise -- merging a list of
-- thrusters positionally would silently blend two different layouts.
function Util.deepMerge(dst, src)
  local out = Util.deepCopy(dst)
  if type(src) ~= "table" then return out end
  for k, v in pairs(src) do
    if type(v) == "table" and type(out[k]) == "table"
      and not Util.isList(v) and not Util.isList(out[k]) then
      out[k] = Util.deepMerge(out[k], v)
    else
      out[k] = Util.deepCopy(v)
    end
  end
  return out
end

function Util.approx(a, b, tol)
  return math.abs(a - b) <= (tol or 1e-6)
end

--- Wrap an angle to (-180, 180]. Used everywhere headings are compared.
function Util.wrapDeg(deg)
  deg = deg % 360
  if deg > 180 then deg = deg - 360 end
  return deg
end

--- Shortest signed difference from `from` to `to`, in degrees.
function Util.angleDelta(from, to)
  return Util.wrapDeg(to - from)
end

function Util.now()
  return os.epoch("utc")
end

function Util.count(t)
  local n = 0
  for _ in pairs(t) do n = n + 1 end
  return n
end

--- Sorted key list, so iteration order is deterministic (tests, UI, logs).
function Util.sortedKeys(t)
  local keys = {}
  for k in pairs(t) do keys[#keys + 1] = k end
  table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
  return keys
end

return Util
