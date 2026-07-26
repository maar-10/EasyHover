--[[ The one snapshot store.

     Every module writes here; every reader (control, telemetry, UI) reads from here and
     never from a peripheral directly. That is what keeps peripheral cost proportional to
     the number of sensors rather than the number of consumers.

     Channels are flat dotted keys ("attitude.pitch"), each carrying a timestamp, because
     the interesting question is almost never "what is the value" but "how old is it".
     A control law acting on a silently frozen sensor is the failure mode this prevents.
]]

local Util = require("lib.util")

local State = {}
State.__index = State

function State.new(opts)
  opts = opts or {}
  local self = setmetatable({}, State)
  self.staleMs = opts.staleMs or 500
  self.channels = {}   -- key -> { v = value, t = epoch }
  self.mode = "BOOT"
  self.alarms = {}     -- key -> { level, msg, since }
  self.stats = {}      -- free-form counters (thruster calls, loop overruns, ...)
  return self
end

function State:set(key, value, when)
  local ch = self.channels[key]
  if ch then
    ch.v = value
    ch.t = when or os.epoch("utc")
  else
    self.channels[key] = { v = value, t = when or os.epoch("utc") }
  end
end

--- Write a flat table of values under a prefix: setGroup("attitude", {pitch=1,roll=2}).
function State:setGroup(prefix, values, when)
  when = when or os.epoch("utc")
  for k, v in pairs(values) do
    self:set(prefix .. "." .. k, v, when)
  end
end

function State:get(key, default)
  local ch = self.channels[key]
  if ch == nil then return default end
  return ch.v
end

--- Age in ms, or math.huge if the channel was never written.
function State:age(key)
  local ch = self.channels[key]
  if not ch then return math.huge end
  return os.epoch("utc") - ch.t
end

function State:isFresh(key, ms)
  return self:age(key) <= (ms or self.staleMs)
end

--- Value only if fresh; otherwise `default`. The safe accessor for control code.
function State:fresh(key, default, ms)
  if self:isFresh(key, ms) then return self:get(key, default) end
  return default
end

--- Every channel that should be fresh but isn't.
function State:staleChannels(ms)
  local out = {}
  for _, key in ipairs(Util.sortedKeys(self.channels)) do
    if not self:isFresh(key, ms) then out[#out + 1] = key end
  end
  return out
end

-- ---------------------------------------------------------------- alarms

function State:raise(key, level, msg)
  local existing = self.alarms[key]
  if existing and existing.level == level then
    existing.msg = msg
    return false            -- already up, not a new event
  end
  self.alarms[key] = { level = level, msg = msg, since = os.epoch("utc") }
  return true               -- newly raised: the annunciator should sound
end

function State:clear(key)
  if self.alarms[key] == nil then return false end
  self.alarms[key] = nil
  return true
end

function State:activeAlarms()
  local out = {}
  for _, key in ipairs(Util.sortedKeys(self.alarms)) do
    local a = self.alarms[key]
    out[#out + 1] = { key = key, level = a.level, msg = a.msg, since = a.since }
  end
  return out
end

function State:worstAlarmLevel()
  local order = { info = 1, caution = 2, warning = 3 }
  local worst, name = 0, nil
  for _, a in pairs(self.alarms) do
    local rank = order[a.level] or 0
    if rank > worst then worst, name = rank, a.level end
  end
  return name
end

-- ---------------------------------------------------------------- counters

function State:bump(key, by)
  self.stats[key] = (self.stats[key] or 0) + (by or 1)
end

function State:resetStats()
  self.stats = {}
end

-- ---------------------------------------------------------------- output

--- Flat snapshot with ages -- what telemetry puts on the wire.
function State:snapshot()
  local now = os.epoch("utc")
  local values, ages = {}, {}
  for key, ch in pairs(self.channels) do
    values[key] = ch.v
    ages[key] = now - ch.t
  end
  return {
    t = now,
    mode = self.mode,
    values = values,
    ages = ages,
    alarms = self:activeAlarms(),
    stats = Util.deepCopy(self.stats),
  }
end

--- Nested view for UIs: "attitude.pitch" becomes view.attitude.pitch.
function State:view()
  local root = {}
  for key, ch in pairs(self.channels) do
    local node = root
    local parts = {}
    for part in string.gmatch(key, "[^.]+") do parts[#parts + 1] = part end
    for i = 1, #parts - 1 do
      if type(node[parts[i]]) ~= "table" then node[parts[i]] = {} end
      node = node[parts[i]]
    end
    node[parts[#parts]] = ch.v
  end
  root.mode = self.mode
  return root
end

return State
