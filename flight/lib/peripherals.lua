--[[ Peripheral resolution and presence tracking.

     Wired-modem peripheral names are attach-ordered and NOT stable across a rebuild, so
     config maps logical id -> peripheral name, and nothing else in the codebase ever
     mentions a peripheral name. This module is the only place that touches
     peripheral.wrap.

     Peripheral loss is a normal, recoverable state -- assembling or disassembling the
     craft reboots the computers and re-attaches everything. So: never cache a device
     across a rescan, never assume presence, and let the control layer ask.
]]

local Util = require("lib.util")

local Peripherals = {}
Peripherals.__index = Peripherals

--- Set of every type a peripheral reports. Generic peripherals report several.
local function typesOf(name)
  local set = {}
  local ok, first, second = pcall(peripheral.getType, name)
  if not ok or first == nil then return set end
  set[first] = true
  if second then set[second] = true end
  -- CC also exposes hasType; use it when present for the multi-type cases
  return set
end

local function hasType(name, ptype)
  if peripheral.hasType then
    local ok, result = pcall(peripheral.hasType, name, ptype)
    if ok then return result and true or false end
  end
  return typesOf(name)[ptype] == true
end

local function safeWrap(name)
  if type(name) ~= "string" or name == "" then return nil end
  local ok, dev = pcall(peripheral.wrap, name)
  if not ok then return nil end
  return dev
end

function Peripherals.new(cfg, log)
  local self = setmetatable({}, Peripherals)
  self.cfg = cfg
  self.log = log
  self.thrusters = {}   -- id -> { id, name, dev, spec }
  self.order = {}       -- stable, sorted thruster ids
  self.sensors = {}     -- role -> dev  (optical is a list)
  self.inputs = {}
  self.relays = {}      -- list of { spec, dev }
  self.missing = {}
  self.scanCount = 0
  return self
end

--- Every peripheral name currently on the network, sorted.
function Peripherals.names()
  local ok, names = pcall(peripheral.getNames)
  if not ok or type(names) ~= "table" then return {} end
  table.sort(names)
  return names
end

--- Names of every peripheral matching a type, sorted. Used by the config UI and by
--- the "" auto-pick below.
function Peripherals.findByType(ptype)
  local out = {}
  for _, name in ipairs(Peripherals.names()) do
    if hasType(name, ptype) then out[#out + 1] = name end
  end
  return out
end

--- Resolve a configured name, or auto-pick the first of `ptype` when it is blank.
-- Blank config is convenience for single-sensor installs; anything with more than one
-- of a type must be named explicitly, and we warn when we had to guess among several.
function Peripherals:resolve(name, ptype, label)
  if type(name) == "string" and name ~= "" then
    local dev = safeWrap(name)
    if not dev then
      self.missing[#self.missing + 1] = ("%s (%s: not present)"):format(label, name)
      return nil, name
    end
    if ptype and not hasType(name, ptype) then
      self.log:warn("%s: '%s' is not a %s", label, name, ptype)
    end
    return dev, name
  end

  if not ptype then
    self.missing[#self.missing + 1] = ("%s (not configured)"):format(label)
    return nil, nil
  end

  local candidates = Peripherals.findByType(ptype)
  if #candidates == 0 then
    self.missing[#self.missing + 1] = ("%s (no %s on the network)"):format(label, ptype)
    return nil, nil
  end
  if #candidates > 1 then
    self.log:warn("%s: %d peripherals of type %s; auto-picked '%s'. Name it in config.",
      label, #candidates, ptype, candidates[1])
  end
  return safeWrap(candidates[1]), candidates[1]
end

--- (Re)build the whole device map from config. Safe to call at any time.
function Peripherals:scan()
  local cfg = self.cfg
  self.thrusters, self.order, self.sensors, self.inputs, self.relays = {}, {}, {}, {}, {}
  self.missing = {}
  self.scanCount = self.scanCount + 1

  -- thrusters: always by explicit name, never auto-picked. Guessing which physical
  -- thruster is which would produce a craft that flies inverted.
  for _, spec in ipairs(cfg.hardware.thrusters or {}) do
    if spec.enabled ~= false then
      local dev = safeWrap(spec.peripheral)
      if dev then
        self.thrusters[spec.id] = { id = spec.id, name = spec.peripheral, dev = dev, spec = spec }
        self.order[#self.order + 1] = spec.id
      else
        self.missing[#self.missing + 1] =
          ("thruster %s (%s: not present)"):format(spec.id, tostring(spec.peripheral))
      end
    end
  end
  table.sort(self.order)

  -- sensors
  local hs = cfg.hardware.sensors or {}
  self.sensors.altitude = self:resolve(hs.altitude, "altitude_sensor", "altitude sensor")
  self.sensors.gimbal = self:resolve(hs.gimbal, "gimbal_sensor", "gimbal sensor")
  self.sensors.velocity = self:resolve(hs.velocity, "velocity_sensor", "velocity sensor")

  -- velocity VECTOR: several sensors, each mapped to a craft axis. Without it the
  -- flight assistant and the brake law have no direction to work with.
  self.sensors.velocityVector = {}
  for i, entry in ipairs(hs.velocityVector or {}) do
    local dev = safeWrap(entry.peripheral)
    if dev then
      self.sensors.velocityVector[#self.sensors.velocityVector + 1] = {
        name = entry.peripheral, dev = dev, axis = entry.axis, invert = entry.invert and true or false,
      }
    else
      self.missing[#self.missing + 1] =
        ("velocity axis %s (%s: not present)"):format(tostring(entry.axis), tostring(entry.peripheral))
      self.log:warn("velocityVector[%d] (%s) missing", i, tostring(entry.peripheral))
    end
  end
  if hs.navTable and hs.navTable ~= "" then
    self.sensors.navTable = self:resolve(hs.navTable, "navigation_table", "nav table")
  end

  -- optical sensors are a list; index 1 is by convention the down-facing altimeter
  self.sensors.optical = {}
  local opticalNames = hs.optical or {}
  if #opticalNames == 0 then
    -- auto-discover, deterministic order, so a single-laser install just works
    opticalNames = Peripherals.findByType("optical_sensor")
    if #opticalNames > 0 then
      self.log:info("auto-discovered %d optical sensor(s); first is the altimeter", #opticalNames)
    end
  end
  for i, name in ipairs(opticalNames) do
    local dev = safeWrap(name)
    if dev then
      self.sensors.optical[#self.sensors.optical + 1] = { name = name, dev = dev, index = i }
    else
      self.missing[#self.missing + 1] = ("optical sensor %d (%s)"):format(i, name)
    end
  end

  -- inputs
  local hi = cfg.hardware.inputs or {}
  self.inputs.controller = self:resolve(hi.controller, "tweaked_controller", "controller")
  self.inputs.typewriter = self:resolve(hi.typewriter, "linked_typewriter", "typewriter")

  -- gauges: fluid tanks and item vaults
  self.tanks = {}
  for i, tank in ipairs(cfg.hardware.tanks or {}) do
    local dev = safeWrap(tank.peripheral)
    if dev then
      self.tanks[#self.tanks + 1] = { spec = tank, dev = dev, name = tank.peripheral }
    else
      self.missing[#self.missing + 1] =
        ("tank %s (%s)"):format(tank.label ~= "" and tank.label or tostring(i), tostring(tank.peripheral))
    end
  end

  self.vaults = {}
  for i, vault in ipairs(cfg.hardware.vaults or {}) do
    local dev = safeWrap(vault.peripheral)
    if dev then
      self.vaults[#self.vaults + 1] = { spec = vault, dev = dev, name = vault.peripheral }
    else
      self.missing[#self.missing + 1] =
        ("vault %s (%s)"):format(vault.label ~= "" and vault.label or tostring(i), tostring(vault.peripheral))
    end
  end

  -- the engine relay: gates the funnel above the portable engine
  self.engine = nil
  local engineSpec = cfg.hardware.engine or {}
  if engineSpec.relay and engineSpec.relay ~= "" then
    local dev = safeWrap(engineSpec.relay)
    if dev then
      self.engine = { dev = dev, name = engineSpec.relay, side = engineSpec.side or "top" }
    else
      self.missing[#self.missing + 1] = ("engine relay (%s: not present)"):format(engineSpec.relay)
    end
  end

  -- disk drives, for saving and loading configs
  self.drives = {}
  for _, name in ipairs(Peripherals.findByType("drive")) do
    local dev = safeWrap(name)
    if dev then self.drives[#self.drives + 1] = { name = name, dev = dev } end
  end

  -- relays
  for _, spec in ipairs(cfg.hardware.relays or {}) do
    local dev = safeWrap(spec.peripheral)
    if dev then
      self.relays[#self.relays + 1] = { spec = spec, dev = dev, name = spec.peripheral }
    else
      self.missing[#self.missing + 1] =
        ("relay %s (%s: not present)"):format(spec.label ~= "" and spec.label or spec.purpose,
          tostring(spec.peripheral))
    end
  end

  if #self.missing > 0 then
    self.log:warn("scan #%d: %d missing -> %s", self.scanCount, #self.missing,
      table.concat(self.missing, "; "))
  else
    self.log:info("scan #%d: all configured hardware present (%d thrusters)",
      self.scanCount, #self.order)
  end

  return self
end

function Peripherals:thruster(id)
  local entry = self.thrusters[id]
  return entry and entry.dev or nil
end

function Peripherals:thrusterList()
  local out = {}
  for _, id in ipairs(self.order) do out[#out + 1] = self.thrusters[id] end
  return out
end

function Peripherals:count()
  return #self.order
end

function Peripherals:isComplete()
  return #self.missing == 0
end

--- Feed peripheral attach/detach events here; returns true when a rescan happened.
function Peripherals:onEvent(event, name)
  if event ~= "peripheral" and event ~= "peripheral_detach" then return false end
  self.log:info("%s: %s -> rescanning", event, tostring(name))
  self:scan()
  return true
end

--- Grouped counts for telemetry/UI.
function Peripherals:summary()
  local lift, lateral = 0, 0
  for _, entry in pairs(self.thrusters) do
    if entry.spec.group == "lift" then lift = lift + 1 else lateral = lateral + 1 end
  end
  return {
    thrusters = #self.order,
    lift = lift,
    lateral = lateral,
    optical = #(self.sensors.optical or {}),
    relays = #self.relays,
    tanks = #(self.tanks or {}),
    vaults = #(self.vaults or {}),
    drives = #(self.drives or {}),
    engine = self.engine ~= nil,
    missing = Util.deepCopy(self.missing),
    complete = #self.missing == 0,
    scans = self.scanCount,
  }
end

return Peripherals
