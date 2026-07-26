--[[ Action <-> hardware binding resolution.

     Everything downstream speaks in ACTIONS ("pitchUp", "brake"), never in key codes or
     axis indices. That is what makes the bindings fully remappable from the UI without
     touching a line of control code.

     Key names in config are `keys.*` names ("space", "leftShift", "w"). They are resolved
     once, here, and an unknown name is reported rather than silently ignored -- a typo in a
     keybind that fails quietly is a control that mysteriously does nothing.
]]

local Bindings = {}
Bindings.__index = Bindings

--- Axis actions and the two key actions that drive each one, as (positive, negative).
Bindings.AXES = {
  pitch = { "pitchUp", "pitchDown" },
  roll = { "rollRight", "rollLeft" },
  yaw = { "yawRight", "yawLeft" },
  climb = { "climb", "descend" },
  accel = { "accelerate", "decelerate" },
}

--- Momentary actions (held).
Bindings.HELD = { "brake" }

--- Edge-triggered actions (fire once per press).
Bindings.EDGES = {
  "cycleFeel", "toggleLateral", "toggleAssist", "gear", "lights", "engineMaster",
}

function Bindings.new(cfg, log)
  local self = setmetatable({}, Bindings)
  self.cfg = cfg
  self.log = log
  self.keyToAction = {}
  self.actionToKey = {}
  self.problems = {}
  self:resolve()
  return self
end

--- Every action, in a FIXED order: the axis pairs as declared, then held, then edges, then
--- anything else alphabetically.
---
--- The order matters because of what happens on a conflict. When two actions share a key, the
--- first one resolved keeps it and the second is left with NO binding -- so iterating with
--- pairs() meant a duplicate binding disabled an ARBITRARY one of the two, and a different one
--- on each boot. Same config, same behaviour, every time.
function Bindings:actionOrder()
  local order, seen = {}, {}
  local function add(name)
    if name and not seen[name] then seen[name] = true; order[#order + 1] = name end
  end
  for _, axis in ipairs({ "pitch", "roll", "yaw", "climb", "accel" }) do
    local pair = Bindings.AXES[axis]
    if pair then add(pair[1]); add(pair[2]) end
  end
  for _, name in ipairs(Bindings.HELD) do add(name) end
  for _, name in ipairs(Bindings.EDGES) do add(name) end

  -- anything the config holds that the lists above do not name
  local extra = {}
  for action in pairs(self.cfg.input.typewriter.bindings or {}) do
    if not seen[action] then extra[#extra + 1] = action end
  end
  table.sort(extra)
  for _, name in ipairs(extra) do add(name) end
  return order
end

function Bindings:resolve()
  self.keyToAction, self.actionToKey, self.problems = {}, {}, {}
  local bind = self.cfg.input.typewriter.bindings or {}

  for _, action in ipairs(self:actionOrder()) do
    local keyName = bind[action]
    if type(keyName) ~= "string" or keyName == "" then
      self.problems[#self.problems + 1] = ("%s: not bound"):format(action)
    else
      local code = keys[keyName]
      if type(code) ~= "number" then
        self.problems[#self.problems + 1] =
          ("%s: '%s' is not a valid key name"):format(action, keyName)
      elseif self.keyToAction[code] and self.keyToAction[code] ~= action then
        self.problems[#self.problems + 1] =
          ("key '%s' is bound to both %s and %s"):format(keyName, self.keyToAction[code], action)
      else
        self.keyToAction[code] = action
        self.actionToKey[action] = code
      end
    end
  end

  if #self.problems > 0 and self.log then
    for _, problem in ipairs(self.problems) do self.log:warn("keybind: %s", problem) end
  end
  return #self.problems == 0, self.problems
end

function Bindings:actionForKey(code)
  return self.keyToAction[code]
end

function Bindings:keyForAction(action)
  return self.actionToKey[action]
end

--- Controller axis index and inversion for an axis action. A negative index in config means
--- inverted, which is how a stick that reads backwards gets fixed without code.
function Bindings:controllerAxis(action)
  local raw = self.cfg.input.controller.axes[action]
  if type(raw) ~= "number" or raw == 0 then return nil end
  return math.abs(math.floor(raw)), raw < 0
end

function Bindings:controllerButton(action)
  local raw = self.cfg.input.controller.buttons[action]
  if type(raw) ~= "number" or raw < 1 then return nil end
  return math.floor(raw)
end

--- Every action name the system understands, for the config UI to enumerate.
function Bindings.allActions()
  local out = {}
  for _, pair in pairs(Bindings.AXES) do
    out[#out + 1] = pair[1]
    out[#out + 1] = pair[2]
  end
  for _, a in ipairs(Bindings.HELD) do out[#out + 1] = a end
  for _, a in ipairs(Bindings.EDGES) do out[#out + 1] = a end
  table.sort(out)
  return out
end

--- Which understood actions have no key bound? The UI shows these as gaps.
function Bindings:unbound()
  local out = {}
  for _, action in ipairs(Bindings.allActions()) do
    if not self.actionToKey[action] then out[#out + 1] = action end
  end
  return out
end

return Bindings
