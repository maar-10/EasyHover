--[[ The mixer: unitless control demands -> per-thruster commands.

     This is the only module that knows the craft's physical layout, and it is driven
     entirely by config geometry, so a layout change never touches code.

     Read docs/CONTROL_LAWS.md section 1a first. The short version:

       * A thruster's moment is r x F, so pitch/roll come from DIFFERENTIAL VERTICAL THRUST
         between pairs -- the quantised axis -- not from deflection.
       * But toeing a pair inward cancels their horizontal forces while costing both the
         same continuous fraction of lift. That gives continuous pitch, roll and vertical
         trim with no net side force.
       * So attitude is served by toe up to mixer.toeShare, and only the excess spills into
         quantised differential thrust. Steady state therefore never sees quantisation.

     Frame: x = right, y = up, z = forward. Positive pitch = nose up, positive roll = right
     wing down, positive yaw = nose right.

     TWO SIGN CONVENTIONS, AND THEY ARE OPPOSITE. Getting these confused is the single most
     dangerous mistake available in this file, so they are stated once, here:

       * `thrustAxis` is WHERE A THRUSTER FACES -- where its exhaust goes. A lift thruster
         faces "down", an accelerator faces "back", a lateral faces "left" or "right". That is
         how a pilot describes their craft, and it is what the config records.
       * THE FORCE IS THE OPPOSITE. Exhaust down pushes the craft up; that is the only reason
         a lift thruster lifts. So force = -AXIS_VECTORS[thrustAxis], computed once in build().
       * `defX` / `defY` / `defZ` in a command are likewise AIM directions -- where the nozzle
         is pointed, in the craft frame -- because that is what setVector() takes and what the
         pilot names in AXIS MAP. A positive defX therefore produces force in -x.

     Consequence: any demand expressed as a FORCE ("push right") must be NEGATED on its way
     into a deflection. `translateX`/`translateZ` are forces. The toe terms are not -- they are
     deflections already, and their sign is arbitrary anyway because a pair cancels either way.

     Which way a real nozzle deflects for a positive setVector is still not documented by the
     mod; the per-thruster invertVectorX/Y flags fix that per craft, and AXIS MAP sets them by
     observation. That is a HARDWARE correction and is separate from the convention above.
]]

local Util = require("lib.util")

local Mixer = {}
Mixer.__index = Mixer

--- Unit vector for a named direction. `thrustAxis` names where a thruster FACES, so the force
--- it produces is the NEGATION of its entry here -- see the header.
local AXIS_VECTORS = {
  right   = { x = 1, y = 0, z = 0 },
  left    = { x = -1, y = 0, z = 0 },
  up      = { x = 0, y = 1, z = 0 },
  down    = { x = 0, y = -1, z = 0 },
  forward = { x = 0, y = 0, z = 1 },
  back    = { x = 0, y = 0, z = -1 },
}

function Mixer.new(cfg, peripherals)
  local self = setmetatable({}, Mixer)
  self.cfg = cfg
  self.per = peripherals
  self.layout = nil
  return self
end

local function sign(v)
  if v > 1e-9 then return 1 end
  if v < -1e-9 then return -1 end
  return 0
end

--- Precompute per-thruster geometry. Call after any peripheral rescan.
function Mixer:build()
  local lift, lateral, main = {}, {}, {}
  for _, entry in ipairs(self.per:thrusterList()) do
    local spec = entry.spec
    local pos = spec.pos or { x = 0, y = 0, z = 0 }
    local item = {
      id = spec.id,
      spec = spec,
      sx = sign(pos.x),
      sz = sign(pos.z),
      pos = pos,
    }
    if spec.group == "lift" then
      lift[#lift + 1] = item
    elseif spec.group == "main" then
      main[#main + 1] = item
    else
      -- FACING -> FORCE. A thruster facing right pushes the craft LEFT. Using the facing
      -- vector directly here would translate and yaw the craft backwards, and with the flight
      -- assistant on that is positive feedback: it would push WITH the drift, not against it.
      local facing = AXIS_VECTORS[spec.thrustAxis] or AXIS_VECTORS.right
      local force = { x = -facing.x, y = -facing.y, z = -facing.z }
      item.facing = facing
      item.force = force
      -- Yaw moment coefficient about +y: M = r_z * F_x - r_x * F_z, per unit thrust.
      item.yawCoeff = pos.z * force.x - pos.x * force.z
      item.yawAuthority = spec.yawAuthority and true or false
      item.precisionOnly = spec.precisionOnly and true or false
      lateral[#lateral + 1] = item
    end
  end

  -- Normalise yaw coefficients so yawTorque = 1 means "full available yaw", regardless of
  -- how far from the centre the yaw thrusters happen to sit.
  local maxYaw = 0
  for _, item in ipairs(lateral) do
    if item.yawAuthority then maxYaw = math.max(maxYaw, math.abs(item.yawCoeff)) end
  end
  for _, item in ipairs(lateral) do
    item.yawUnit = (item.yawAuthority and maxYaw > 1e-9) and (item.yawCoeff / maxYaw) or 0
  end

  self.layout = { lift = lift, lateral = lateral, main = main, maxYaw = maxYaw }
  return self.layout
end

function Mixer:ensureLayout()
  if not self.layout then self:build() end
  return self.layout
end

--- Split an attitude demand into the continuous toe part and the quantised excess.
-- Returns toeFraction (-1..1 of toe authority) and diffFraction (-1..1 of differential).
function Mixer:splitAttitude(torque)
  local share = self.cfg.mixer.toeShare
  local t = Util.clamp(torque or 0, -1, 1)
  local toeFraction = Util.clamp(t / share, -1, 1)
  local excess = math.abs(t) - share
  local diffFraction = 0
  if excess > 0 then
    diffFraction = (t > 0 and 1 or -1) * Util.clamp(excess / math.max(1 - share, 1e-6), 0, 1)
  end
  return toeFraction, diffFraction
end

--[[ demand fields, all unitless:
       collective    0..1   base lift thrust
       verticalTrim  -1..1  continuous fine lift trim (+1 = maximum lift)
       pitchTorque   -1..1  +1 = nose up
       rollTorque    -1..1  +1 = roll right
       yawTorque     -1..1  +1 = nose right
       translateX    -1..1  +1 = push right
       translateZ    -1..1  +1 = push forward
       mainThrust    0..1   main forward thruster(s)
       allowPrecision bool  may the precisionOnly thrusters be used?
]]
function Mixer:mix(demand)
  local layout = self:ensureLayout()
  local m = self.cfg.mixer
  local commands = {}

  local collective = Util.clamp(demand.collective or 0, 0, 1)
  local verticalTrim = Util.clamp(demand.verticalTrim or 0, -1, 1)
  local pitchToe, pitchDiff = self:splitAttitude(demand.pitchTorque)
  local rollToe, rollDiff = self:splitAttitude(demand.rollTorque)
  local translateX = Util.clamp(demand.translateX or 0, -1, 1)
  local translateZ = Util.clamp(demand.translateZ or 0, -1, 1)

  -- ---------------------------------------------------------------- lift group

  -- Baseline toe, reduced by positive vertical trim so trim has authority both ways:
  -- trim +1 -> no toe -> maximum lift; trim -1 -> double toe -> minimum lift.
  local baseToe = m.toeBase * (1 - verticalTrim)

  for _, item in ipairs(layout.lift) do
    -- Pitch: nose up means the REAR pair sheds lift. Roll right means the RIGHT pair does.
    local pitchExtra = 0
    if item.sz > 0 then
      pitchExtra = math.max(0, -pitchToe) * m.toeAuthority   -- nose down -> front sheds
    elseif item.sz < 0 then
      pitchExtra = math.max(0, pitchToe) * m.toeAuthority    -- nose up   -> rear sheds
    end

    local rollExtra = 0
    if item.sx > 0 then
      rollExtra = math.max(0, rollToe) * m.toeAuthority      -- roll right -> right sheds
    elseif item.sx < 0 then
      rollExtra = math.max(0, -rollToe) * m.toeAuthority     -- roll left  -> left sheds
    end

    -- Toe deflects TOWARD the craft centre, so the pair's horizontal forces cancel.
    -- Pitch toe uses the x axis (cancels across left/right), roll toe uses z
    -- (cancels across front/rear). The baseline toe uses both.
    local toeX = -item.sx * (baseToe + pitchExtra)
    local toeZ = -item.sz * (baseToe + rollExtra)

    -- Translation is deliberately uniform: every nozzle the same way, so it adds up.
    --
    -- NEGATED, because translateX/Z are FORCES and defX/defZ are AIM directions. Aiming the
    -- exhaust right pushes the craft left. Without this the flight assistant damps drift by
    -- pushing WITH it -- positive feedback, and exactly the runaway this design exists to
    -- prevent. Tested in tests/test_loops.lua ("damping opposes the drift").
    local defX = toeX - translateX * m.translateAuthority
    local defZ = toeZ - translateZ * m.translateAuthority

    -- Differential thrust only for the excess attitude demand beyond toe authority.
    local diff = 0
    if item.sz > 0 then diff = diff + pitchDiff * m.differentialAuthority
    elseif item.sz < 0 then diff = diff - pitchDiff * m.differentialAuthority end
    if item.sx > 0 then diff = diff - rollDiff * m.differentialAuthority
    elseif item.sx < 0 then diff = diff + rollDiff * m.differentialAuthority end

    commands[item.id] = {
      thrust = Util.clamp(collective + diff, 0, 1),
      defX = defX,
      defZ = defZ,
    }
  end

  -- ------------------------------------------------------------- lateral group

  local yawTorque = Util.clamp(demand.yawTorque or 0, -1, 1)
  for _, item in ipairs(layout.lateral) do
    if item.precisionOnly and not demand.allowPrecision then
      commands[item.id] = { thrust = 0, defX = 0, defZ = 0 }
    else
      -- How much of the translation demand this thruster can serve. A thruster can only push
      -- along its own force axis, so the opposed unit of the pair handles the other sign.
      local translate = translateX * item.force.x + translateZ * item.force.z
      local yaw = yawTorque * item.yawUnit * self.cfg.mixer.yawAuthority
      commands[item.id] = {
        thrust = Util.clamp(translate + yaw, 0, 1),
        defX = 0,
        defZ = 0,
      }
    end
  end

  -- ---------------------------------------------------------------- main group

  local mainThrust = Util.clamp(demand.mainThrust or 0, 0, 1)
  for _, item in ipairs(layout.main) do
    commands[item.id] = { thrust = mainThrust, defX = 0, defZ = 0 }
  end

  return commands
end

--- What the layout can actually do, for the UI and for honest degradation.
function Mixer:capabilities()
  local layout = self:ensureLayout()
  local pitchPairs, rollPairs = false, false
  local front, rear, left, right = 0, 0, 0, 0
  for _, item in ipairs(layout.lift) do
    if item.sz > 0 then front = front + 1 elseif item.sz < 0 then rear = rear + 1 end
    if item.sx > 0 then right = right + 1 elseif item.sx < 0 then left = left + 1 end
  end
  pitchPairs = front > 0 and rear > 0
  rollPairs = left > 0 and right > 0

  local yaw, translate, precision = false, false, 0
  for _, item in ipairs(layout.lateral) do
    if item.yawAuthority then yaw = true end
    if item.precisionOnly then precision = precision + 1 else translate = true end
  end

  return {
    lift = #layout.lift,
    lateral = #layout.lateral,
    main = #layout.main,
    pitch = pitchPairs,
    roll = rollPairs,
    yaw = yaw,
    translate = translate,
    precisionThrusters = precision,
  }
end

return Mixer
