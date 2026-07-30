--[[ Heading: one true-north-referenced bearing for the craft, from two very different inputs.

     NAVIGATION TABLE  `navigation_table.getRelativeAngle()` -> the craft's angle to the table's
                       configured target. With a magnet in the table that target is TRUE NORTH,
                       so this is an ABSOLUTE heading. But it is a boxed Float and can return nil
                       (no target in range / not configured), and it is only as current as the
                       last poll. It is free to call -- not mainThread -- so polling is cheap.

     GIMBAL YAW        the flight computer's `attitude.yaw`, over telemetry. CONTINUOUS and fast,
                       but RELATIVE: its zero is wherever the gimbal happened to boot, and it
                       drifts. On its own it cannot tell you which way is north.

     THE MODEL. The nav table is the truth whenever it answers. Each time it does, we also record
     the OFFSET between it and the gimbal yaw at that instant. When the table is silent, heading =
     gimbal yaw + that offset -- the "Backup basic heading". So the fast gimbal carries the
     bearing moment to moment, and the table keeps it honest against true north.

     SELF ALIGN is just a forced, immediate version of that calibration: read the table now, and
     if it answers, reset the offset from it. It exists because a pilot who has bumped the craft
     or watched the heading drift wants to re-true it on demand rather than wait for the next poll.

     CONVENTIONS ARE CONFIGURABLE, because the source does not pin them down. Simulated's bytecode
     does not fix the SIGN or ZERO of getRelativeAngle, and the gimbal's axis order and sign are
     equally unstated (docs/MOD_API_RESEARCH.md). So both carry a sign and an offset in config,
     defaulted to the obvious choice and meant to be trued in-game -- which SELF ALIGN makes easy.
]]

local Heading = {}
Heading.__index = Heading

--- Normalise to [0, 360).
local function wrap360(deg)
  deg = deg % 360
  if deg < 0 then deg = deg + 360 end
  return deg
end

--- Smallest signed difference a - b, in (-180, 180]. Used so "drift" is reported honestly across
--- the 0/360 seam rather than as a 359-degree jump.
local function angleDelta(a, b)
  local d = wrap360(a - b)
  if d > 180 then d = d - 360 end
  return d
end

Heading.wrap360 = wrap360
Heading.angleDelta = angleDelta

--- opts (all optional):
---   navSign     +1 or -1, applied to the nav table angle (default +1)
---   gimbalSign  +1 or -1, applied to the gimbal yaw (default +1)
---   staleMs     a nav-table reading older than this is not trusted as "current" (default 3000)
---   rawGimbalOk when there is no table calibration, return the RAW gimbal yaw as a relative
---              heading (source "gimbal") rather than nil. This is what "gimbal" and "auto" mode
---              rely on; "navtable" mode leaves it false so an un-aligned craft honestly has no
---              true-north heading rather than a plausible-looking wrong one.
function Heading.new(opts)
  opts = opts or {}
  local self = setmetatable({}, Heading)
  self.navSign = (opts.navSign == -1) and -1 or 1
  self.gimbalSign = (opts.gimbalSign == -1) and -1 or 1
  self.staleMs = opts.staleMs or 3000
  self.rawGimbalOk = opts.rawGimbalOk and true or false

  self.readTable = nil       -- function() -> angle|nil ; injected, so this is testable
  self.gimbalYaw = nil       -- last yaw from telemetry
  self.offset = nil          -- degrees to add to (gimbal yaw) to get a north-referenced heading
  self.lastTable = nil       -- last non-nil nav-table heading (already sign-applied, wrapped)
  self.lastTableAt = nil
  self.alignedAt = nil       -- when the offset was last set from the table
  return self
end

--- Inject the nav-table reader. `fn` returns the raw getRelativeAngle() value, or nil.
function Heading:setSource(fn)
  self.readTable = fn
end

--- Flip which way the table angle counts. The mod does not pin the sign down, so if the heading
--- runs BACKWARDS as the craft turns, this is the fix -- and the offset must be re-aligned after,
--- because it was computed against the old sign.
function Heading:setNavSign(sign)
  self.navSign = (sign == -1) and -1 or 1
  self.offset = nil          -- the old calibration was against the old sign; force a re-align
end

--- Likewise for the gimbal yaw.
function Heading:setGimbalSign(sign)
  self.gimbalSign = (sign == -1) and -1 or 1
  self.offset = nil
  self.gimbalYaw = nil        -- next telemetry re-applies the new sign
end

--- The nav table's own heading right now, sign-applied and wrapped -- or nil if it is silent.
--- Kept separate from the model so SELF ALIGN and the poll share exactly one reading path.
function Heading:readNavTable(now)
  if type(self.readTable) ~= "function" then return nil end
  local ok, raw = pcall(self.readTable)
  if not ok or type(raw) ~= "number" then return nil end
  local h = wrap360(raw * self.navSign)
  self.lastTable = h
  self.lastTableAt = now or os.epoch("utc")
  return h
end

--- Feed the continuous gimbal yaw (telemetry). Sign-applied on the way in.
function Heading:updateGimbal(yaw)
  if type(yaw) ~= "number" then return end
  self.gimbalYaw = wrap360(yaw * self.gimbalSign)
end

--- Set the offset so that (gimbal yaw + offset) equals the given absolute heading. Silently does
--- nothing without a gimbal yaw to anchor to -- there is nothing to offset FROM yet.
function Heading:calibrate(absolute, now)
  if type(self.gimbalYaw) ~= "number" then return false end
  self.offset = angleDelta(absolute, self.gimbalYaw)
  self.alignedAt = now or os.epoch("utc")
  return true
end

--- SELF ALIGN: read the table NOW and calibrate from it. Returns ok, reason.
function Heading:align(now)
  now = now or os.epoch("utc")
  local h = self:readNavTable(now)
  if h == nil then return false, "the navigation table is not answering" end
  if type(self.gimbalYaw) ~= "number" then
    -- With no gimbal we cannot maintain heading between reads, but the table alone is still a
    -- valid absolute heading, so this is not a hard failure -- it just means no backup.
    return true, "aligned to the table (no gimbal: heading holds only while the table answers)"
  end
  self:calibrate(h, now)
  return true, "aligned to true north"
end

--- The routine per-tick update: read the table when able and keep the calibration fresh, so a
--- pilot who never presses SELF ALIGN still gets a trued heading. Cheap: the table read is free.
function Heading:tick(now)
  now = now or os.epoch("utc")
  local h = self:readNavTable(now)
  if h ~= nil and type(self.gimbalYaw) == "number" then
    self:calibrate(h, now)
  end
end

--- The best heading available, and what it rests on:
---   { degrees, source = "navtable"|"backup"|nil, ageMs, aligned = bool }
---   source "navtable"  a current table reading
---   source "backup"    gimbal + offset (the Backup basic heading); the table is silent
---   nil                no heading at all -- no table reading and no calibrated gimbal
function Heading:current(now)
  now = now or os.epoch("utc")

  -- A current table reading is the truth.
  if self.lastTable ~= nil and self.lastTableAt ~= nil
    and (now - self.lastTableAt) <= self.staleMs then
    return {
      degrees = self.lastTable,
      source = "navtable",
      ageMs = now - self.lastTableAt,
      aligned = self.alignedAt ~= nil,
    }
  end

  -- Otherwise, the gimbal carried forward from the last alignment: the Backup basic heading.
  if type(self.gimbalYaw) == "number" and self.offset ~= nil then
    return {
      degrees = wrap360(self.gimbalYaw + self.offset),
      source = "backup",
      ageMs = self.alignedAt and (now - self.alignedAt) or nil,
      aligned = true,
    }
  end

  -- Never aligned, table silent. If raw gimbal is permitted, hand it over -- but as source
  -- "gimbal", not "backup", and aligned = false, because it is RELATIVE: consistent, but its zero
  -- is arbitrary, so world positions reckoned from it are rotated by an unknown amount. That flag
  -- is how the screen tells the pilot the difference.
  if self.rawGimbalOk and type(self.gimbalYaw) == "number" then
    return { degrees = self.gimbalYaw, source = "gimbal", ageMs = nil, aligned = false }
  end

  return nil
end

--- Just the number, for callers (like dead reckoning) that only need degrees or nil.
function Heading:degrees(now)
  local h = self:current(now)
  return h and h.degrees or nil
end

return Heading
