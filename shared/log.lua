--[[ Ring-buffer logger, shared by every role.

     NOTE ON DUPLICATION: flight/lib/log.lua predates this file and behaves identically. It is
     left alone on purpose -- it is covered by passing tests and collapsing the two is churn
     with no functional gain. The follow-up is to make flight/lib/log.lua a one-line re-export
     of this module; until then, mirror any change.

     Never blocks and never throws: a logging failure must not take down a UI or a control loop.
]]

local Log = {}
Log.__index = Log

local LEVELS = { debug = 10, info = 20, warn = 30, error = 40 }

function Log.new(opts)
  opts = opts or {}
  local self = setmetatable({}, Log)
  self.capacity = opts.capacity or 200
  self.minLevel = LEVELS[opts.level or "info"] or LEVELS.info
  self.path = opts.path
  self.echo = opts.echo or false
  self.entries = {}
  self.first = 1
  self.count = 0
  self.dropped = 0
  return self
end

function Log:_push(level, msg)
  local entry = { t = os.epoch("utc"), level = level, msg = msg }
  if self.count < self.capacity then
    self.entries[(self.first + self.count - 1) % self.capacity + 1] = entry
    self.count = self.count + 1
  else
    self.entries[self.first] = entry
    self.first = self.first % self.capacity + 1
    self.dropped = self.dropped + 1
  end
  if self.echo then print(("[%s] %s"):format(level, msg)) end
  if self.path then
    pcall(function()
      local f = fs.open(self.path, "a")
      if f then
        f.writeLine(("%d [%s] %s"):format(entry.t, level, msg))
        f.close()
      end
    end)
  end
end

local function emit(self, level, fmt, ...)
  if LEVELS[level] < self.minLevel then return end
  local msg
  if select("#", ...) > 0 then
    local ok, formatted = pcall(string.format, fmt, ...)
    msg = ok and formatted or (tostring(fmt) .. " <format error>")
  else
    msg = tostring(fmt)
  end
  self:_push(level, msg)
end

function Log:debug(fmt, ...) emit(self, "debug", fmt, ...) end
function Log:info(fmt, ...) emit(self, "info", fmt, ...) end
function Log:warn(fmt, ...) emit(self, "warn", fmt, ...) end
function Log:error(fmt, ...) emit(self, "error", fmt, ...) end

function Log:recent(n)
  n = math.min(n or self.count, self.count)
  local out = {}
  for i = self.count - n + 1, self.count do
    out[#out + 1] = self.entries[(self.first + i - 2) % self.capacity + 1]
  end
  return out
end

--- At most one message per key per interval, so a failing peripheral cannot fill the buffer.
function Log:throttled(key, intervalMs, level, fmt, ...)
  self._last = self._last or {}
  local now = os.epoch("utc")
  local last = self._last[key]
  if last and (now - last) < intervalMs then return end
  self._last[key] = now
  emit(self, level, fmt, ...)
end

return Log
