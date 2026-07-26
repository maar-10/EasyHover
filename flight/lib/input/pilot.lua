--[[ Pilot input aggregator: merges the controller and the typewriter into one action set.

     Both can be live at once (config `input.source = "both"`, or "auto" which uses whatever
     is present). Merge rules, chosen so two live inputs can never cancel each other into
     mush:

       axes    -- whichever source is further from centre wins. A hand on the stick
                  therefore beats a key that is ramping back to centre, and vice versa,
                  without either being ignored.
       held    -- OR. Either device can hold the brake.
       edges   -- OR. Either device can toggle a mode.
]]

local Bindings = require("lib.input.bindings")
local Typewriter = require("lib.input.typewriter")
local Controller = require("lib.input.controller")

local Pilot = {}
Pilot.__index = Pilot

function Pilot.new(cfg, log)
  local self = setmetatable({}, Pilot)
  self.cfg = cfg
  self.log = log
  self.bindings = Bindings.new(cfg, log)
  self.typewriter = Typewriter.new(self.bindings, cfg, log)
  self.controller = Controller.new(self.bindings, cfg, log)
  self.axes = { pitch = 0, roll = 0, yaw = 0, climb = 0, accel = 0 }
  self.held = {}
  self.edges = {}
  self.sources = { controller = false, typewriter = false }
  return self
end

function Pilot:reset()
  self.typewriter:reset()
  self.controller:reset()
  for k in pairs(self.axes) do self.axes[k] = 0 end
  self.held, self.edges = {}, {}
end

local function wants(source, which)
  if source == "both" or source == "auto" then return true end
  return source == which
end

--- Read every enabled source and merge. `devices` = { controller = dev, typewriter = dev }.
function Pilot:read(devices, dt)
  local source = self.cfg.input.source or "auto"
  local merged = { pitch = 0, roll = 0, yaw = 0, climb = 0, accel = 0 }
  local held, edges = {}, {}
  self.sources.controller, self.sources.typewriter = false, false

  local function fold(axes, heldIn, edgesIn)
    if axes then
      for axis, value in pairs(axes) do
        if math.abs(value) > math.abs(merged[axis] or 0) then merged[axis] = value end
      end
    end
    for action, down in pairs(heldIn or {}) do
      held[action] = held[action] or down
    end
    for action, fired in pairs(edgesIn or {}) do
      edges[action] = edges[action] or fired
    end
  end

  if wants(source, "controller") and devices.controller then
    local axes, heldIn, edgesIn = self.controller:read(devices.controller)
    if axes then
      self.sources.controller = self.controller.hasUser
      fold(axes, heldIn, edgesIn)
    end
  end

  if wants(source, "typewriter") and devices.typewriter then
    local axes, heldIn, edgesIn = self.typewriter:poll(devices.typewriter, dt)
    if axes then
      self.sources.typewriter = true
      fold(axes, heldIn, edgesIn)
    end
  end

  self.axes, self.held, self.edges = merged, held, edges
  return merged, held, edges
end

--- Is the pilot actively commanding movement? The flight assistant uses this to stay out of
--- the way, so it deliberately ignores mode toggles and counts only movement axes.
function Pilot:isCommanding(deadzone)
  deadzone = deadzone or 0.02
  for _, axis in ipairs({ "pitch", "roll", "yaw", "climb", "accel" }) do
    if math.abs(self.axes[axis] or 0) > deadzone then return true end
  end
  return false
end

function Pilot:anyInputPresent()
  return self.sources.controller or self.sources.typewriter
end

function Pilot:snapshot()
  return {
    axes = { pitch = self.axes.pitch, roll = self.axes.roll, yaw = self.axes.yaw,
             climb = self.axes.climb, accel = self.axes.accel },
    brake = self.held.brake and true or false,
    controller = self.sources.controller,
    typewriter = self.sources.typewriter,
    unbound = self.bindings:unbound(),
    pressedCodes = self.typewriter.pressedCodes,
    keybindProblems = self.bindings.problems,
  }
end

function Pilot:applyConfig(cfg)
  self.cfg = cfg
  self.bindings.cfg = cfg
  self.bindings:resolve()
  self.typewriter.cfg = cfg
  self.controller.cfg = cfg
  self.controller.precisionApplied = false
end

return Pilot
