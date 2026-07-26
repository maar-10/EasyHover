--[[ Ring-buffer logger.

     The flight computer has no screen, so logs are the only forensic record. Kept in
     memory (cheap, always available to telemetry) with an optional file sink.

     Never blocks and never throws: a logging failure must not take down the loop.
]]

local Log = {}
Log.__index = Log

local LEVELS = { debug = 10, info = 20, warn = 30, error = 40 }

function Log.new(opts)
  opts = opts or {}
  local self = setmetatable({}, Log)
  self.capacity = opts.capacity or 200
  self.minLevel = LEVELS[opts.level or "info"] or LEVELS.info
  self.path = opts.path           -- nil = memory only
  self.echo = opts.echo or false  -- print as well (tests, ground station)
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
    -- best effort only; a full or missing disk must never break flight
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

--- Most recent `n` entries, oldest first.
function Log:recent(n)
  n = math.min(n or self.count, self.count)
  local out = {}
  for i = self.count - n + 1, self.count do
    out[#out + 1] = self.entries[(self.first + i - 2) % self.capacity + 1]
  end
  return out
end

--- Log a message at most once per `intervalMs` for a given key. Stops a failing
-- peripheral from filling the buffer with the same line 20 times a second.
function Log:throttled(key, intervalMs, level, fmt, ...)
  self._last = self._last or {}
  local now = os.epoch("utc")
  local last = self._last[key]
  if last and (now - last) < intervalMs then return end
  self._last[key] = now
  emit(self, level, fmt, ...)
end

return Log
