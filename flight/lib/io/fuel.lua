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

-- ---------------------------------------------------------------- gauges

--- Fluid tanks: the craft's own fuel supply, read through the generic `fluid_storage`
--- methods that Create's tanks answer.
---
--- CC does not guarantee a capacity in every tanks() entry, so `capacityMb` in config is the
--- fallback. Without either we report the amount and no fraction, rather than inventing a
--- scale -- a gauge with a made-up maximum is worse than a bare number.
function Fuel:readTanks()
  local rows = {}
  for index, item in ipairs(self.per.tanks or {}) do
    local row = {
      index = index,
      name = item.name,
      label = (item.spec.label ~= "" and item.spec.label) or item.name,
    }
    local contents = call(item.dev, "tanks")
    if type(contents) == "table" then
      local total, fluid, reported = 0, nil, nil
      for _, tank in ipairs(contents) do
        if type(tank) == "table" then
          total = total + (tonumber(tank.amount) or 0)
          fluid = fluid or tank.name
          if tonumber(tank.capacity) then reported = (reported or 0) + tonumber(tank.capacity) end
        end
      end
      row.amount = total
      row.fluid = fluid
      row.capacity = reported or ((tonumber(item.spec.capacityMb) or 0) > 0
        and tonumber(item.spec.capacityMb) or nil)
      if row.capacity and row.capacity > 0 then
        row.fraction = Util.clamp(row.amount / row.capacity, 0, 1)
      end
      row.unit = "mB"
    else
      row.error = "tanks() unavailable"
    end
    rows[#rows + 1] = row
  end
  if self.state then self.state:set("fuel.tanks", rows) end
  return rows
end

--- Item vaults: what is left to feed the portable engine. `item` filters to one id; blank
--- counts everything in the container.
function Fuel:readVaults()
  local rows = {}
  for index, entry in ipairs(self.per.vaults or {}) do
    local row = {
      index = index,
      name = entry.name,
      label = (entry.spec.label ~= "" and entry.spec.label) or entry.name,
      filter = (entry.spec.item ~= "" and entry.spec.item) or nil,
    }
    local contents = call(entry.dev, "list")
    if type(contents) == "table" then
      local count, slots = 0, 0
      for _, stack in pairs(contents) do
        if type(stack) == "table" then
          if not row.filter or stack.name == row.filter then
            count = count + (tonumber(stack.count) or 0)
            slots = slots + 1
          end
        end
      end
      row.count = count
      row.slots = slots
      row.empty = (count == 0)
    else
      row.error = "list() unavailable"
    end
    rows[#rows + 1] = row
  end
  if self.state then self.state:set("fuel.vaults", rows) end
  return rows
end

--- Everything the cockpit gauges need, in one call.
function Fuel:readAll()
  local thrusters, aggregate = self:read()
  local tanks = self:readTanks()
  local vaults = self:readVaults()

  -- The worst tank is what the fuel gauge should show, and an empty engine vault is worth a
  -- caution of its own: the thrusters may be full while the engine that drives the pumps is
  -- about to stop.
  local worstTank, worstTankLabel
  for _, row in ipairs(tanks) do
    if row.fraction and (worstTank == nil or row.fraction < worstTank) then
      worstTank, worstTankLabel = row.fraction, row.label
    end
  end
  local vaultEmpty = false
  for _, row in ipairs(vaults) do
    if row.empty then vaultEmpty = true end
  end

  aggregate.worstTank = worstTank
  aggregate.worstTankLabel = worstTankLabel
  aggregate.vaultEmpty = vaultEmpty
  if self.state then
    self.state:set("fuel.worstTank", worstTank)
    self.state:set("fuel.vaultEmpty", vaultEmpty)
  end
  return thrusters, aggregate, tanks, vaults
end

--- Alarm thresholds are the caller's policy; this just classifies.
function Fuel.level(fraction, caution, warning)
  if type(fraction) ~= "number" then return "unknown" end
  if fraction <= (warning or 0.10) then return "warning" end
  if fraction <= (caution or 0.25) then return "caution" end
  return "ok"
end

return Fuel
