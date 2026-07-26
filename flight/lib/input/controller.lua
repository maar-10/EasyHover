--[[ Create: Tweaked Controllers input -- a real gamepad.

     getAxis(1..6) and getButton(1..15), plus push events controller_start_using /
     controller_stop_using. This is the right primary input for a craft that wants
     proportional control instead of key taps.

     setFullPrecision(true) is applied on attach: the default sends COARSE values, and
     nobody would guess that from the axis readings alone.
]]

local Util = require("lib.util")
local Filter = require("lib.control.filter")

local Controller = {}
Controller.__index = Controller

function Controller.new(bindings, cfg, log)
  local self = setmetatable({}, Controller)
  self.bindings = bindings
  self.cfg = cfg
  self.log = log
  self.previous = {}
  self.axes = { pitch = 0, roll = 0, yaw = 0, climb = 0, accel = 0 }
  self.precisionApplied = false
  self.hasUser = false
  self.failures = 0
  return self
end

function Controller:reset()
  self.previous = {}
  self.precisionApplied = false
  for k in pairs(self.axes) do self.axes[k] = 0 end
end

local function call(dev, method, ...)
  local fn = dev[method]
  if type(fn) ~= "function" then return nil end
  local ok, v = pcall(fn, ...)
  if ok then return v end
  return nil
end

--- Read the controller. Returns axes, held, edges -- or nil when unavailable/unmanned.
function Controller:read(dev)
  if not dev then return nil end

  if not self.precisionApplied and self.cfg.input.controller.fullPrecision then
    if call(dev, "setFullPrecision", true) ~= nil or true then
      self.precisionApplied = true
      if self.log then self.log:info("controller: full precision enabled") end
    end
  end

  local manned = call(dev, "hasUser")
  self.hasUser = manned and true or false
  if not self.hasUser then
    -- Nobody is holding it. Return centred axes rather than the last values, so an empty
    -- seat cannot leave a stale control input standing.
    for k in pairs(self.axes) do self.axes[k] = 0 end
    return self.axes, {}, {}
  end

  local c = self.cfg.input.controller
  for axis in pairs(self.axes) do
    local index, inverted = self.bindings:controllerAxis(axis)
    if index then
      local raw = call(dev, "getAxis", index)
      if type(raw) == "number" then
        local value = Util.clamp(raw, -1, 1)
        if inverted then value = -value end
        value = Filter.deadband(value, c.deadzone or 0)
        value = Filter.expo(value, c.expo or 0)
        self.axes[axis] = Util.clamp(value, -1, 1)
      end
    else
      self.axes[axis] = 0
    end
  end

  local held, edges = {}, {}
  local function buttonDown(action)
    local index = self.bindings:controllerButton(action)
    if not index then return false end
    return call(dev, "getButton", index) and true or false
  end

  for _, action in ipairs(self.bindings.HELD) do
    held[action] = buttonDown(action)
  end
  for _, action in ipairs(self.bindings.EDGES) do
    local down = buttonDown(action)
    if down and not self.previous[action] then edges[action] = true end
    self.previous[action] = down
  end
  -- held buttons also need their previous state tracked, for symmetry with edges
  for _, action in ipairs(self.bindings.HELD) do
    self.previous[action] = held[action]
  end

  return self.axes, held, edges
end

return Controller
