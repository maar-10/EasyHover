--[[ Helpers shared by every role.

     NOTE ON DUPLICATION: flight/lib/util.lua predates this file and is byte-identical in
     behaviour. It is deliberately left alone for now -- it is covered by 243 passing tests and
     collapsing it into this one is churn with no functional gain. The follow-up is to make
     flight/lib/util.lua a one-line re-export of this module; until then, any change here must
     be mirrored there. Both roles ship `shared/`, and `require("shared.util")` resolves because
     every role's startup adds "/?.lua" to package.path.
]]

local Util = {}

function Util.clamp(v, lo, hi)
  if v < lo then return lo end
  if v > hi then return hi end
  return v
end

function Util.round(v)
  return math.floor(v + 0.5)
end

function Util.isList(t)
  return type(t) == "table" and t[1] ~= nil
end

function Util.deepCopy(v)
  if type(v) ~= "table" then return v end
  local out = {}
  for k, val in pairs(v) do out[k] = Util.deepCopy(val) end
  return out
end

--- Merge `src` over a copy of `dst`. Scalars from src win, maps recurse, LISTS ARE REPLACED.
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

function Util.sortedKeys(t)
  local keys = {}
  for k in pairs(t) do keys[#keys + 1] = k end
  table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
  return keys
end

function Util.now()
  return os.epoch("utc")
end

--- Format a number for a narrow display, without ever printing "nil".
function Util.num(v, decimals, fallback)
  if type(v) ~= "number" then return fallback or "--" end
  return string.format("%." .. tostring(decimals or 0) .. "f", v)
end

--- Percentage for a gauge, or nil when there is nothing honest to show.
function Util.pct(fraction)
  if type(fraction) ~= "number" then return nil end
  return Util.clamp(Util.round(fraction * 100), 0, 100)
end

return Util
