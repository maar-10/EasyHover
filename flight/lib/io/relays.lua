--[[ Redstone relays: auxiliary outputs.

     HISTORY, because the absence is deliberate: this module used to arm a HARDWARE FAILSAFE --
     a relay beside each lift thruster holding an open-loop hover thrust level, so that if the
     computer died the thrusters would revert to redstone control and see a level that settled
     the craft instead of dropping it.

     That was SCRAPPED 2026-07-26 at the pilot's decision: a relay, cabling and a modem per
     thruster cost too much space and weight for something that, with wired-only controls,
     should never fire. The accepted consequence is in docs/WIRING.md -- if the flight computer
     is destroyed, unloaded or rebooted in flight, the craft falls. Do not quietly reintroduce
     a half-version of it; either it is wired or it is not.

     What is left is aux actuation: lights, doors, landing gear.

     Wiring note (DriveByWire v6): a redstone relay's "face" is its BACK. Sides in config are
     the relay's own sides, and getting this wrong looks exactly like a code bug.
]]

local Relays = {}
Relays.__index = Relays

function Relays.new(peripherals, cfg, log, state)
  local self = setmetatable({}, Relays)
  self.per = peripherals
  self.cfg = cfg
  self.log = log
  self.state = state
  return self
end

local function call(dev, method, ...)
  local fn = dev[method]
  if type(fn) ~= "function" then return false, "no method " .. method end
  local ok, v = pcall(fn, ...)
  if not ok then return false, tostring(v) end
  return true, v
end

--- Digital aux output by label (lights, doors, gear).
function Relays:setAux(label, value)
  for _, item in ipairs(self.per.relays or {}) do
    if item.spec.purpose == "aux" and item.spec.label == label then
      local ok, err = call(item.dev, "setOutput", item.spec.side, value and true or false)
      if not ok then
        self.log:error("aux relay %s: %s", label, tostring(err))
        return false, err
      end
      if self.state then self.state:set("aux." .. label, value and true or false) end
      return true
    end
  end
  return false, "no aux relay labelled " .. tostring(label)
end

--- Toggle an aux output, returning the new value.
function Relays:toggleAux(label)
  local current = self.state and self.state:get("aux." .. label) or false
  local ok, err = self:setAux(label, not current)
  if not ok then return nil, err end
  return not current
end

--- Analog aux output, for anything that wants a level rather than on/off.
function Relays:setAuxLevel(label, level)
  level = math.max(0, math.min(15, math.floor((level or 0) + 0.5)))
  for _, item in ipairs(self.per.relays or {}) do
    if item.spec.purpose == "aux" and item.spec.label == label then
      local ok, err = call(item.dev, "setAnalogOutput", item.spec.side, level)
      if not ok then
        self.log:error("aux relay %s: %s", label, tostring(err))
        return false, err
      end
      if self.state then self.state:set("aux." .. label .. ".level", level) end
      return true
    end
  end
  return false, "no aux relay labelled " .. tostring(label)
end

function Relays:auxLabels()
  local out = {}
  for _, item in ipairs(self.per.relays or {}) do
    if item.spec.purpose == "aux" and item.spec.label ~= "" then out[#out + 1] = item.spec.label end
  end
  table.sort(out)
  return out
end

--- Current readback of every relay, for the UI.
function Relays:readback()
  local out = {}
  for _, item in ipairs(self.per.relays or {}) do
    local okA, analog = call(item.dev, "getAnalogOutput", item.spec.side)
    local okD, digital = call(item.dev, "getOutput", item.spec.side)
    out[#out + 1] = {
      name = item.name,
      side = item.spec.side,
      purpose = item.spec.purpose,
      label = item.spec.label,
      analog = okA and analog or nil,
      digital = okD and digital or nil,
    }
  end
  if self.state then self.state:set("aux.readback", out) end
  return out
end

return Relays
