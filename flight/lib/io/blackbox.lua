--[[ Blackbox: a rolling flight recorder.

     One row per control cycle into a fixed ring buffer -- what the sensors reported (RAW gimbal
     elements and the mapped/filtered attitude), what the control loops demanded, and what every
     thruster was actually commanded. A runaway can then be read back frame by frame instead of
     guessed at from a blurred screenshot.

     It ALWAYS records into the ring (cheap: table inserts, no peripheral calls, off the mainThread
     I/O path entirely), so after something happens you just `blackbox save` and the last N cycles
     -- the event included -- are already captured. Save writes CSV; hand that back for analysis.

     The column set is fixed at construction from the craft's own thruster list, so every row lines
     up and the file is a clean table.
]]

local Blackbox = {}
Blackbox.__index = Blackbox

-- The craft-level columns, in order. Thruster columns are appended per thruster at construction.
local BASE_COLUMNS = {
  "t",                       -- ms since the first recorded row
  "g1", "g2", "g3",          -- RAW gimbal elements, before index/sign mapping
  "pitch", "roll", "yaw",    -- mapped, filtered attitude (deg)
  "prate", "rrate",          -- body rates the loop estimated (deg/s)
  "alt", "vs",               -- altitude (m) and vertical speed (m/s)
  "vx", "vz", "vh",          -- velocity vector: craft x, z, horizontal magnitude (m/s)
  "grnd",                    -- ground contact: 1 true, 0 false, -1 unknown/nil
  "ptq", "rtq", "ytq",       -- torque DEMANDS handed to the mixer (-1..1); the loop's answer
  "coll", "vtrim",           -- collective (0..1) and continuous vertical trim (-1..1)
  "mode", "state",           -- feel mode and flight state
}

function Blackbox.new(cfg, thrusterIds)
  local self = setmetatable({}, Blackbox)
  self.cfg = cfg
  local bb = (cfg and cfg.blackbox) or {}
  self.capacity = math.max(1, math.floor(bb.capacity or 300))
  self.enabled = bb.enabled ~= false
  self.rows = {}
  self.head = 0            -- total rows ever recorded (monotonic)
  self.startMs = nil

  -- Fix the column order now: base columns, then per-thruster thrust + nozzle x/y.
  self.thrusterIds = {}
  self.columns = {}
  for _, c in ipairs(BASE_COLUMNS) do self.columns[#self.columns + 1] = c end
  -- Per thruster: commanded thrust (0..1) and craft-frame nozzle deflection (defX/defZ). Roll shows
  -- up as a thrust difference between left and right lift thrusters, so .th is the column to watch.
  for _, id in ipairs(thrusterIds or {}) do
    self.thrusterIds[#self.thrusterIds + 1] = id
    self.columns[#self.columns + 1] = id .. ".th"
    self.columns[#self.columns + 1] = id .. ".dx"
    self.columns[#self.columns + 1] = id .. ".dz"
  end
  return self
end

function Blackbox:setEnabled(on)
  self.enabled = on and true or false
  return self.enabled
end

function Blackbox:clear()
  self.rows = {}
  self.head = 0
  self.startMs = nil
end

--- Record one row. `row` is a flat table keyed by column name; missing keys become blank.
function Blackbox:record(row, nowMs)
  if not self.enabled then return end
  nowMs = nowMs or 0
  self.startMs = self.startMs or nowMs
  row.t = nowMs - self.startMs
  self.head = self.head + 1
  local slot = ((self.head - 1) % self.capacity) + 1
  self.rows[slot] = row
end

--- How many rows are currently retained (<= capacity).
function Blackbox:count()
  return math.min(self.head, self.capacity)
end

--- Retained rows in chronological (oldest-first) order.
function Blackbox:ordered()
  local n = self:count()
  local out = {}
  local firstLogical = self.head - n + 1
  for k = firstLogical, self.head do
    out[#out + 1] = self.rows[((k - 1) % self.capacity) + 1]
  end
  return out
end

local function cell(v)
  if type(v) == "number" then
    if v ~= v then return "nan" end                 -- guard NaN
    return ("%.3f"):format(v)
  end
  if v == nil then return "" end
  return tostring(v)
end

--- Write the buffer to `path` as CSV (header + one line per row). Returns ok, rowCount or err.
function Blackbox:save(path)
  local rows = self:ordered()
  local h = fs.open(path, "w")
  if not h then return false, "could not open " .. tostring(path) end
  h.write(table.concat(self.columns, ",") .. "\n")
  for _, row in ipairs(rows) do
    local cells = {}
    for i, key in ipairs(self.columns) do
      cells[i] = cell(row[key])
    end
    h.write(table.concat(cells, ",") .. "\n")
  end
  h.close()
  return true, #rows
end

return Blackbox
