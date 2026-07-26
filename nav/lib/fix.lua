--[[ Position fixing: turn whatever sources this craft has into one honest answer.

     Nothing in Create: Simulated reports absolute position -- there is no getPosition() on any
     of its peripherals -- so a fix comes from outside it, and which source is available depends
     on the world the craft is flying in. This module therefore knows about NO source directly.
     Sources are registered, tried in priority order, and each returns { x, y, z } or nil.

     WHAT MAKES THIS MODULE WORTH HAVING is not the sourcing, it is the honesty:

       * every fix carries its AGE, its SOURCE and a QUALITY, so guidance can refuse a stale one
       * dead reckoning fills the gaps but is MARKED as an estimate, and the mark survives into
         the waypoint store, which refuses to mark a pad from one
       * a source that fails is backed off rather than retried every cycle -- a blocking
         gps.locate() that times out costs a whole second, and calling it 20 times a second
         because it is "primary" would stall the computer entirely

     Dead reckoning needs a HEADING to rotate craft-frame velocity into world axes. Without one
     it cannot run at all, and says so rather than integrating garbage.
]]

local Geo = require("lib.geo")

local Fix = {}
Fix.__index = Fix

--- How long a source is left alone after it fails, so a dead source costs one attempt not all.
local DEFAULT_BACKOFF_MS = 4000

function Fix.new(cfg, log)
  local self = setmetatable({}, Fix)
  self.cfg = cfg or {}
  self.log = log
  self.sources = {}
  self.last = nil          -- last real fix
  self.estimate = nil      -- dead-reckoned position, when we have one
  self.attempts, self.failures = 0, 0
  return self
end

--- Register a source. Lower `priority` is tried first.
---
---   name      "gps" | "radar" | "beacon" | anything
---   priority  number
---   quality   0..1, how much a fix from here is worth
---   locate    function() -> x, y, z  (or nil)  -- MAY BLOCK; never called from a control loop
---   costMs    rough wall cost, for the diagnostics page
function Fix:addSource(spec)
  self.sources[#self.sources + 1] = {
    name = spec.name,
    priority = spec.priority or 50,
    quality = spec.quality or 1.0,
    locate = spec.locate,
    costMs = spec.costMs or 0,
    failedAt = nil,
    backoffMs = spec.backoffMs or DEFAULT_BACKOFF_MS,
    ok = 0, bad = 0,
  }
  table.sort(self.sources, function(a, b) return a.priority < b.priority end)
  return self
end

function Fix:sourceNames()
  local out = {}
  for _, source in ipairs(self.sources) do out[#out + 1] = source.name end
  return out
end

--- Try each source in turn until one answers. Returns the fix, or nil with a reason.
function Fix:acquire(now)
  now = now or os.epoch("utc")
  if #self.sources == 0 then return nil, "no position source configured" end

  local skipped = 0
  for _, source in ipairs(self.sources) do
    local backedOff = source.failedAt ~= nil and (now - source.failedAt) < source.backoffMs
    if backedOff then
      skipped = skipped + 1
    else
      self.attempts = self.attempts + 1
      local ok, x, y, z = pcall(source.locate)
      if ok and type(x) == "number" and type(y) == "number" and type(z) == "number" then
        source.ok = source.ok + 1
        source.failedAt = nil
        local fix = {
          x = x, y = y, z = z,
          source = source.name,
          quality = source.quality,
          at = now,
          ageMs = 0,
        }
        -- A new fix is the truth; the estimate restarts from it rather than drifting on.
        self.last = fix
        self.estimate = { x = x, y = y, z = z, at = now }
        return fix
      end
      source.bad = source.bad + 1
      source.failedAt = now
      self.failures = self.failures + 1
      if self.log then
        self.log:throttled("fix:" .. source.name, 10000, "warn",
          "position source '%s' gave nothing; backing off %d ms", source.name, source.backoffMs)
      end
    end
  end

  if skipped == #self.sources then return nil, "every source is backed off" end
  return nil, "no source answered"
end

--- Advance the dead-reckoned estimate by one step of craft-frame velocity.
---
--- `forward` and `right` are metres per second along the craft's own axes; `heading` is degrees.
--- Returns the estimate, or nil and a reason -- WITHOUT a heading this is not possible, and
--- guessing one would produce a position that looks plausible and is wrong.
function Fix:reckon(dt, forward, right, heading, now)
  if self.estimate == nil then return nil, "no fix to reckon from" end
  if type(heading) ~= "number" then return nil, "no heading" end
  if type(dt) ~= "number" or dt <= 0 then return nil, "no dt" end

  local delta = Geo.craftToWorld(forward or 0, right or 0, heading)
  self.estimate.x = self.estimate.x + delta.x * dt
  self.estimate.z = self.estimate.z + delta.z * dt
  self.estimate.at = now or os.epoch("utc")
  self.estimate.reckoned = true
  return self.estimate
end

--- The best position available right now, and what it is worth.
---
--- Returns a table that ALWAYS says where it came from:
---   { x, y, z, source, quality, ageMs, dead }
--- `dead = true` means dead-reckoned. Callers that must not act on an estimate check that flag;
--- the waypoint store's MARK is one of them.
function Fix:position(now, altitude)
  now = now or os.epoch("utc")

  if self.last == nil then
    return nil, "no fix yet"
  end

  local age = now - self.last.at
  local maxAge = self.cfg.fixStaleMs or 1500

  -- Fresh enough to use directly.
  if age <= maxAge then
    return {
      x = self.last.x, y = altitude or self.last.y, z = self.last.z,
      source = self.last.source, quality = self.last.quality,
      ageMs = age, dead = false,
    }
  end

  -- Stale. Fall back to the estimate if we have one that has been advanced since the fix.
  if self.estimate and self.estimate.reckoned then
    -- Quality decays with how long we have been reckoning: an estimate five seconds old is not
    -- worth what one half a second old is, and guidance should be able to see the difference.
    local reckonedFor = now - self.last.at
    local decay = math.max(0, 1 - reckonedFor / (self.cfg.reckonUsefulMs or 8000))
    return {
      x = self.estimate.x, y = altitude or self.last.y, z = self.estimate.z,
      source = "estimate", quality = (self.last.quality or 1) * decay,
      ageMs = age, dead = true,
    }
  end

  -- Nothing but an old fix. Hand it over, clearly labelled, rather than nil: a stale position
  -- with its age attached is usable for a map; nil is not.
  return {
    x = self.last.x, y = altitude or self.last.y, z = self.last.z,
    source = self.last.source, quality = 0,
    ageMs = age, dead = false, stale = true,
  }
end

--- Per-source counters for the diagnostics page.
function Fix:stats()
  local out = { attempts = self.attempts, failures = self.failures, sources = {} }
  for _, source in ipairs(self.sources) do
    out.sources[#out.sources + 1] = {
      name = source.name, priority = source.priority,
      ok = source.ok, bad = source.bad,
      backedOff = source.failedAt ~= nil,
      costMs = source.costMs,
    }
  end
  return out
end

return Fix
