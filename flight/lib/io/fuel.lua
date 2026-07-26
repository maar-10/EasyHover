--[[ Fuel / energy sensing across the thruster fleet.

     Propulsion gives each thruster family a different fuel API, and the peripheral type
     tells us which one to use:

       fluid   (thruster, liquid_vector_thruster, vector_thruster) getFuelAmountMb / Capacity
       solid   (solid_fuel_thruster)                              getFuelAmount + burn time
       energy  (ion_thruster)                                     getEnergyAmountFe / Capacity

     We detect by METHOD PRESENCE rather than by type string, because a type we have not
     seen yet should still work if it exposes a known fuel API.

     What we report is a fraction and a worst-case, never an endurance estimate: burn rate
     depends on throttle history we do not have, and a wrong endurance number is worse than
     no endurance number.
]]

local Util = require("lib.util")

local Fuel = {}
Fuel.__index = Fuel

function Fuel.new(peripherals, cfg, log, state)
  local self = setmetatable({}, Fuel)
  self.per = peripherals
  self.cfg = cfg
  self.log = log
  self.state = state
  self.kinds = {}   -- id -> "fluid" | "solid" | "energy" | "unknown"
  return self
end

local function has(dev, method)
  return type(dev[method]) == "function"
end

local function call(dev, method)
  local fn = dev[method]
  if type(fn) ~= "function" then return nil end
  local ok, v = pcall(fn)
  if ok then return v end
  return nil
end

--- Cached per-thruster classification; the hardware does not change type at runtime.
function Fuel:kindOf(id, dev)
  local cached = self.kinds[id]
  if cached then return cached end
  local kind = "unknown"
  if has(dev, "getFuelAmountMb") then
    kind = "fluid"
  elseif has(dev, "getBurnTimeRemaining") or has(dev, "getFuelAmount") then
    kind = "solid"
  elseif has(dev, "getEnergyAmountFe") then
    kind = "energy"
  end
  self.kinds[id] = kind
  if kind == "unknown" then
    self.log:warn("thruster %s exposes no known fuel API -- fuel display will be blank", id)
  end
  return kind
end

--- Per-thruster fuel rows plus an aggregate. Getters are not mainThread, so cheap.
function Fuel:read()
  local rows, worst, worstId = {}, nil, nil
  local anyBurning, unknowns = false, 0

  for _, entry in ipairs(self.per:thrusterList()) do
    local dev, id = entry.dev, entry.id
    local kind = self:kindOf(id, dev)
    local row = { id = id, kind = kind, group = entry.spec.group }

    if kind == "fluid" then
      row.amount = call(dev, "getFuelAmountMb")
      row.capacity = call(dev, "getFuelCapacityMb")
      row.unit = "mB"
    elseif kind == "solid" then
      row.amount = call(dev, "getFuelAmount")
      row.capacity = call(dev, "getFuelCapacity")
      row.burnTime = call(dev, "getBurnTimeRemaining")
      row.burning = call(dev, "isBurning") and true or false
      row.unit = "item"
      if row.burning then anyBurning = true end
    elseif kind == "energy" then
      row.amount = call(dev, "getEnergyAmountFe")
      row.capacity = call(dev, "getEnergyCapacityFe")
      row.unit = "FE"
    else
      unknowns = unknowns + 1
    end

    if type(row.amount) == "number" and type(row.capacity) == "number" and row.capacity > 0 then
      row.fraction = Util.clamp(row.amount / row.capacity, 0, 1)
      -- lift thrusters decide the worst case: a dry lateral thruster is an
      -- inconvenience, a dry lift thruster is a landing
      if row.group == "lift" and (worst == nil or row.fraction < worst) then
        worst, worstId = row.fraction, id
      end
    end
    rows[id] = row
  end

  local aggregate = {
    worstFraction = worst,
    worstId = worstId,
    anyBurning = anyBurning,
    unknowns = unknowns,
    count = self.per:count(),
  }

  if self.state then
    self.state:set("fuel.rows", rows)
    self.state:set("fuel.worstFraction", worst)
    self.state:set("fuel.worstId", worstId)
  end
  return rows, aggregate
end

--- Alarm thresholds are the caller's policy; this just classifies.
function Fuel.level(fraction, caution, warning)
  if type(fraction) ~= "number" then return "unknown" end
  if fraction <= (warning or 0.10) then return "warning" end
  if fraction <= (caution or 0.25) then return "caution" end
  return "ok"
end

return Fuel
