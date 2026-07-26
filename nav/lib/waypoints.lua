--[[ The waypoint store.

     Three ways a waypoint gets created, all of which end up here:

       1. a predefined library, edited off-craft and carried on a floppy
       2. MARK -- from the craft's current position
       3. manual coordinates, typed in

     THE MARK PATH IS THE ONE WITH TEETH. It stores the last real position FIX, never the
     dead-reckoned estimate, and refuses when the fix is stale or low quality. A landing pad you
     cannot trust is worse than no pad at all: you would fly to it and find open air.

     Storage is `textutils.serialise` at a protected path, so the Suite never deletes it and a
     bad write cannot take the previous file with it -- saves go through a staged rename.
]]

local Waypoints = {}
Waypoints.__index = Waypoints

--- What a waypoint is FOR, which decides what the autopilot may do with it.
Waypoints.KINDS = {
  nav = "waypoint",       -- a point to fly to
  pad = "landing pad",    -- autoland-capable
  home = "home",          -- return-to-base target
}

local MAX_NAME = 24

function Waypoints.new(path, log)
  local self = setmetatable({}, Waypoints)
  self.path = path or "/eh_waypoints.tbl"
  self.log = log
  self.list = {}
  return self
end

-- ---------------------------------------------------------------- validation

--- Returns ok, error. Kept separate from adding so the UI can validate as you type.
function Waypoints.validate(entry)
  if type(entry) ~= "table" then return false, "not a waypoint" end
  local name = entry.name
  if type(name) ~= "string" or name:gsub("%s", "") == "" then
    return false, "a waypoint needs a name"
  end
  if #name > MAX_NAME then
    return false, ("name is longer than %d characters"):format(MAX_NAME)
  end
  for _, axis in ipairs({ "x", "y", "z" }) do
    local v = entry[axis]
    if type(v) ~= "number" then return false, axis .. " must be a number" end
    -- NaN is not equal to itself; it survives a type check and poisons every later comparison
    if v ~= v then return false, axis .. " is not a number" end
    if math.abs(v) > 3e7 then return false, axis .. " is outside the world" end
  end
  if entry.kind ~= nil and Waypoints.KINDS[entry.kind] == nil then
    return false, "unknown kind: " .. tostring(entry.kind)
  end
  return true
end

--- Names are the handle the UI and the autopilot use, so they must be unique. Compared
--- case-insensitively: "Home Pad" and "home pad" being different entries is a trap.
function Waypoints:findIndex(name)
  if type(name) ~= "string" then return nil end
  local wanted = name:lower()
  for i, entry in ipairs(self.list) do
    if entry.name:lower() == wanted then return i end
  end
  return nil
end

function Waypoints:get(name)
  local index = self:findIndex(name)
  return index and self.list[index] or nil
end

function Waypoints:count()
  return #self.list
end

function Waypoints:all()
  return self.list
end

-- ------------------------------------------------------------------- editing

--- Add, or replace an entry of the same name when `replace` is set.
function Waypoints:add(entry, replace)
  local ok, err = Waypoints.validate(entry)
  if not ok then return false, err end

  local record = {
    name = entry.name,
    x = entry.x, y = entry.y, z = entry.z,
    kind = entry.kind or "nav",
    note = entry.note or "",
    source = entry.source or "manual",
    at = entry.at or os.epoch("utc"),
  }

  local index = self:findIndex(record.name)
  if index then
    if not replace then return false, "a waypoint called that already exists" end
    self.list[index] = record
  else
    self.list[#self.list + 1] = record
  end
  return true, nil, record
end

function Waypoints:remove(name)
  local index = self:findIndex(name)
  if not index then return false, "no such waypoint" end
  table.remove(self.list, index)
  return true
end

function Waypoints:rename(from, to)
  local index = self:findIndex(from)
  if not index then return false, "no such waypoint" end
  local clash = self:findIndex(to)
  if clash and clash ~= index then return false, "that name is taken" end
  local candidate = {}
  for k, v in pairs(self.list[index]) do candidate[k] = v end
  candidate.name = to
  local ok, err = Waypoints.validate(candidate)
  if not ok then return false, err end
  self.list[index] = candidate
  return true
end

--- MARK: create a waypoint from the craft's current position.
---
--- `fix` is a position fix, not a guess. This refuses a fix that is stale, low quality, or
--- dead-reckoned, because the whole point of a marked pad is that you can come back to it.
function Waypoints:mark(name, fix, opts)
  opts = opts or {}
  if type(fix) ~= "table" or fix.x == nil then
    return false, "no position fix"
  end
  if fix.source == "estimate" or fix.dead then
    return false, "position is a dead-reckoned estimate, not a fix"
  end
  local maxAge = opts.maxAgeMs or 3000
  if type(fix.ageMs) == "number" and fix.ageMs > maxAge then
    return false, ("fix is %.1fs old -- wait for a fresh one"):format(fix.ageMs / 1000)
  end
  if type(fix.quality) == "number" and fix.quality < (opts.minQuality or 0.5) then
    return false, "fix quality is too low to mark a waypoint"
  end

  return self:add({
    name = name,
    x = math.floor(fix.x + 0.5), y = math.floor(fix.y + 0.5), z = math.floor(fix.z + 0.5),
    kind = opts.kind or "nav",
    note = opts.note or "",
    source = "mark:" .. tostring(fix.source or "?"),
  }, opts.replace)
end

-- ----------------------------------------------------------------- ordering

--- Every waypoint with its distance and bearing from a point, nearest first.
--- `Geo` is passed in so this module stays free of requires and testable on its own.
function Waypoints:nearest(Geo, from, kind)
  local out = {}
  for _, entry in ipairs(self.list) do
    if kind == nil or entry.kind == kind then
      out[#out + 1] = {
        waypoint = entry,
        distance = Geo.distance(from, entry),
        bearing = Geo.bearing(from, entry),
      }
    end
  end
  table.sort(out, function(a, b)
    if a.distance == b.distance then return a.waypoint.name < b.waypoint.name end
    return a.distance < b.distance
  end)
  return out
end

-- --------------------------------------------------------------- persistence

function Waypoints:load()
  if not fs.exists(self.path) then
    self.list = {}
    return true, 0
  end
  local handle = fs.open(self.path, "r")
  if not handle then return false, "cannot open " .. self.path end
  local body = handle.readAll()
  handle.close()

  local parsed = textutils.unserialise(body or "")
  if type(parsed) ~= "table" then
    -- Do NOT clobber it. A file we cannot read might still be recoverable by hand, and the
    -- operator's waypoints are exactly the kind of thing that is painful to retype.
    if self.log then self.log:error("waypoint file will not parse; leaving it alone") end
    self.list = {}
    return false, "waypoint file will not parse"
  end

  local kept, dropped = {}, 0
  for _, entry in ipairs(parsed.waypoints or parsed) do
    if Waypoints.validate(entry) then
      kept[#kept + 1] = entry
    else
      dropped = dropped + 1
    end
  end
  self.list = kept
  if dropped > 0 and self.log then
    self.log:warn("%d waypoint(s) in the file were invalid and were not loaded", dropped)
  end
  return true, #kept, dropped
end

--- Staged write: build the new file beside the old one and rename only once it reads back.
--- A half-written waypoint file is the one thing worse than an out-of-date one.
function Waypoints:save()
  local body = textutils.serialise({ version = 1, waypoints = self.list })
  local stage = self.path .. ".new"

  local handle = fs.open(stage, "w")
  if not handle then return false, "cannot write " .. stage end
  handle.write(body)
  handle.close()

  local check = fs.open(stage, "r")
  local readBack = check and check.readAll() or nil
  if check then check.close() end
  if readBack ~= body then
    if fs.exists(stage) then fs.delete(stage) end
    return false, "staged file did not read back intact"
  end

  if fs.exists(self.path) then fs.delete(self.path) end
  fs.move(stage, self.path)
  return true
end

return Waypoints
