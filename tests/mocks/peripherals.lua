--[[ Mock peripheral network for headless tests.

     Real mod peripherals do not exist in CraftOS-PC, so we fake the shapes verified from
     mod source (docs/MOD_API_RESEARCH.md). Methods take NO self arg, exactly like wrapped
     CC peripherals -- getting that wrong makes tests pass against an API that does not
     exist.

     The thruster mock reproduces the 16-step throttle quantiser on purpose, so any code
     that assumes continuous thrust fails here rather than in the air.

     Usage:
       local mock = dofile("/tests/mocks/peripherals.lua")
       _G.peripheral = mock.install()               -- default network
       _G.peripheral = mock.install{ devices = {...}, replace = true }
]]

local M = {}

-- Shared fake vehicle state so sensors and thrusters tell a consistent story.
-- Tests mutate this directly.
local vehicle = {
  altitude   = 74.5,
  pressure   = 0.9832,
  pitch      = 1.5,
  roll       = -0.75,
  yaw        = 132.0,
  angles     = nil,   -- set to override the gimbal return outright
  speed      = 0.0,   -- read by velocity_sensor_0 (craft +z / forward = medial)
  lateralSpeed = 0.0, -- read by velocity_sensor_1 (craft +x / right = lateral front)
  lateralRearSpeed = 0.0, -- read by velocity_sensor_2 (craft +x / right = lateral rear)
  groundDist = 2.5,
  groundBlock = "minecraft:grass_block",
  tick       = 0,
}
M.vehicle = vehicle

function M.reset()
  vehicle.altitude = 74.5
  vehicle.pressure = 0.9832
  vehicle.pitch = 1.5
  vehicle.roll = -0.75
  vehicle.yaw = 132.0
  vehicle.angles = nil
  vehicle.speed = 0.0
  vehicle.lateralSpeed = 0.0
  vehicle.groundDist = 2.5
  vehicle.groundBlock = "minecraft:grass_block"
  vehicle.tick = 0
end

-- ---------------------------------------------------------------- factories

--- Vector thruster with quantised throttle and a slewing nozzle.
-- opts.slewPerCall: how far the reported vector moves toward target per getVectorX call
-- opts.autoSlew=false: the nozzle reports its target immediately (simpler for unit tests)
--- Test scaffolding, not a mod method: cut the fuel to a thruster. A real unfuelled thruster
--- keeps whatever throttle it was told to hold and produces NO thrust, which is the difference
--- between `getPower` (a read-back of setPower) and `getCurrentThrustKN` (physics). Deriving one
--- from the other made the mock unable to express a parked craft with the engine off.
local function fuelSwitch(dev, thrustKeys)
  local fuelled = true
  dev.__setFuelled = function(v) fuelled = v and true or false end
  for _, key in ipairs(thrustKeys) do
    local inner = dev[key]
    if type(inner) == "function" then
      dev[key] = function(...) if not fuelled then return 0 end return inner(...) end
    end
  end
  return dev
end

M.fuelSwitch = fuelSwitch

function M.vectorThruster(opts)
  opts = opts or {}
  local n = { x = 0, y = 0, tx = 0, ty = 0, power = 0, slewPerCall = opts.slewPerCall or 0.25 }
  local autoSlew = opts.autoSlew ~= false
  local dev
  dev = {
    getVectorY = function() return n.y end,
    getTargetVectorX = function() return n.tx end,
    getTargetVectorY = function() return n.ty end,
    setVectorX = function(x) n.tx = math.max(-1, math.min(1, x)) end,
    setVectorY = function(y) n.ty = math.max(-1, math.min(1, y)) end,
    setVector = function(x, y)
      n.tx = math.max(-1, math.min(1, x))
      n.ty = math.max(-1, math.min(1, y))
      if not autoSlew then n.x, n.y = n.tx, n.ty end
      n.setVectorCalls = (n.setVectorCalls or 0) + 1
    end,
    setThrust = function(p)
      local clamped = math.max(0, math.min(15, math.floor(p)))
      n.power = clamped / 15
      n.setThrustCalls = (n.setThrustCalls or 0) + 1
    end,
    setThrustNormalized = function(p)
      -- the real helper: floor(n * 15), i.e. 16 discrete levels
      local step = math.floor(math.max(0, math.min(1, p)) * 15 + 1e-6)
      n.power = step / 15
    end,
    getThrust = function() return math.floor(n.power * 15 + 0.5) end,
    getPower = function() return n.power end,
    getObstruction = function() return opts.obstruction or 0 end,
    getCurrentThrustKN = function() return n.power * (opts.maxKN or 120) end,
    getCurrentThrustPN = function() return n.power * (opts.maxKN or 120) * 1000 end,
    getDisplayedThrustKN = function() return n.power * (opts.maxKN or 120) end,
    getAirflowMs = function() return 12.5 * n.power end,
    getFuelAmountMb = function() return opts.fuel or 4000 end,
    getFuelCapacityMb = function() return opts.fuelCapacity or 8000 end,
  }
  dev.setPower = dev.setThrust
  dev.setPowerNormalized = dev.setThrustNormalized
  if autoSlew then
    dev.getVectorX = function()
      local d = n.tx - n.x
      if math.abs(d) <= n.slewPerCall then n.x = n.tx
      else n.x = n.x + (d > 0 and n.slewPerCall or -n.slewPerCall) end
      return n.x
    end
  else
    dev.getVectorX = function() return n.x end
  end
  dev._nozzle = n
  return fuelSwitch(dev, { "getCurrentThrustKN", "getCurrentThrustPN", "getDisplayedThrustKN", "getDisplayedThrustPN", "getAirflowMs" })
end

function M.solidThruster(opts)
  opts = opts or {}
  local power = 0
  local dev = {
    setThrust = function(p) power = math.max(0, math.min(15, math.floor(p))) / 15 end,
    setPower = function(p) power = math.max(0, math.min(15, math.floor(p))) / 15 end,
    setThrustNormalized = function(p) power = math.floor(math.max(0, math.min(1, p)) * 15 + 1e-6) / 15 end,
    getPower = function() return power end,
    getObstruction = function() return 0 end,
    getCurrentThrustKN = function() return power * 60 end,
    getFuelAmount = function() return opts.fuel == nil and 1 or opts.fuel end,
    getFuelCapacity = function() return 1 end,
    getBurnTimeRemaining = function() return opts.burnTime or 340 end,
    isBurning = function() return opts.burning ~= false end,
  }
  return fuelSwitch(dev, { "getCurrentThrustKN", "getCurrentThrustPN", "getDisplayedThrustKN" })
end

function M.ionThruster(opts)
  opts = opts or {}
  local power = 0
  local dev = {
    setThrust = function(p) power = math.max(0, math.min(15, math.floor(p))) / 15 end,
    setPower = function(p) power = math.max(0, math.min(15, math.floor(p))) / 15 end,
    getPower = function() return power end,
    getObstruction = function() return 0 end,
    getCurrentThrustKN = function() return power * 40 end,
    getEnergyAmountFe = function() return opts.energy or 20000 end,
    getEnergyCapacityFe = function() return opts.energyCapacity or 100000 end,
  }
  return fuelSwitch(dev, { "getCurrentThrustKN", "getCurrentThrustPN", "getDisplayedThrustKN" })
end

--- Redstone relay. opts.lie = an offset added to every readback, to test verification.
function M.relay(opts)
  opts = opts or {}
  local analog, digital = {}, {}
  return {
    setAnalogOutput = function(side, level)
      if opts.failWrites then error("relay offline", 0) end
      analog[side] = level
    end,
    getAnalogOutput = function(side)
      local v = analog[side] or 0
      return v + (opts.lie or 0)
    end,
    setOutput = function(side, on)
      if opts.failWrites then error("relay offline", 0) end
      digital[side] = on and true or false
    end,
    getOutput = function(side) return digital[side] or false end,
    _analog = analog,
    _digital = digital,
  }
end

--- A fake monitor. Built on CC's own `window`, so it implements the entire term API for real
--- rather than approximating it -- Basalt renders into this exactly as it would a monitor.
function M.monitor(width, height)
  local win = window.create(term.current(), 1, 1, width or 15, height or 20, false)
  win.setTextScale = function(_) end
  win.getTextScale = function() return 0.5 end
  return win
end

function M.altitudeSensor()
  return {
    getHeight = function() return vehicle.altitude end,
    getAirPressure = function() return vehicle.pressure end,
  }
end

function M.gimbalSensor()
  return {
    getAngles = function()
      if vehicle.angles then return vehicle.angles end
      return { vehicle.pitch, vehicle.roll }
    end,
  }
end

function M.opticalSensor()
  return {
    getDistance = function() return vehicle.groundDist end,
    getBlock = function() return vehicle.groundBlock end,
  }
end

-- ---------------------------------------------------------------- default net

local function defaultDevices()
  local d = {}
  d["vector_thruster_0"] = { type = "vector_thruster", dev = M.vectorThruster() }
  d["vector_thruster_1"] = { type = "vector_thruster", dev = M.vectorThruster() }
  d["vector_thruster_2"] = { type = "vector_thruster", dev = M.vectorThruster() }
  d["vector_thruster_3"] = { type = "vector_thruster", dev = M.vectorThruster() }
  d["solid_fuel_thruster_0"] = { type = "solid_fuel_thruster", dev = M.solidThruster() }
  d["ion_thruster_0"] = { type = "ion_thruster", dev = M.ionThruster() }

  d["altitude_sensor_0"] = { type = "altitude_sensor", dev = M.altitudeSensor() }
  d["gimbal_sensor_0"] = { type = "gimbal_sensor", dev = M.gimbalSensor() }
  -- three velocity sensors: a medial (fore/aft) and two lateral (front + rear), which is what the
  -- role-based velocity VECTOR needs -- the lateral pair gives both sideways drift and yaw rate.
  d["velocity_sensor_0"] = { type = "velocity_sensor", dev = {
    getVelocity = function() return vehicle.speed end,
  } }
  d["velocity_sensor_1"] = { type = "velocity_sensor", dev = {
    getVelocity = function() return vehicle.lateralSpeed end,
  } }
  d["velocity_sensor_2"] = { type = "velocity_sensor", dev = {
    getVelocity = function() return vehicle.lateralRearSpeed end,
  } }
  d["optical_sensor_0"] = { type = "optical_sensor", dev = M.opticalSensor() }
  d["navigation_table_0"] = { type = "navigation_table", dev = {
    getRelativeAngle = function() return vehicle.yaw end,
  } }

  d["redstone_relay_0"] = { type = "redstone_relay", dev = M.relay() }

  -- Monitors: two identical 1x2 portrait screens (the mirrored overhead pair) and one wider
  -- upward-facing screen for the config panel.
  d["monitor_0"] = { type = "monitor", dev = M.monitor(15, 20) }
  d["monitor_1"] = { type = "monitor", dev = M.monitor(15, 20) }
  d["monitor_2"] = { type = "monitor", dev = M.monitor(29, 12) }

  -- vehicle systems: the fuel tank, the engine-fuel vault, and a disk drive
  d["fluid_tank_0"] = { type = "fluid_storage", dev = {
    tanks = function()
      return { { name = "create:diesel", amount = 6000, capacity = 16000 } }
    end,
  } }
  d["item_vault_0"] = { type = "inventory", dev = {
    list = function()
      return {
        [1] = { name = "minecraft:coal", count = 64 },
        [5] = { name = "minecraft:charcoal", count = 32 },
      }
    end,
  } }
  -- The mount path is a real directory in the computer's own filesystem, so disk operations
  -- genuinely read and write rather than being faked at the API boundary.
  d["drive_0"] = { type = "drive", dev = {
    isDiskPresent = function() return true end,
    hasData = function() return true end,
    getDiskLabel = function() return "EH configs" end,
    setDiskLabel = function(_) end,
    getMountPath = function()
      if not fs.exists("/mockdisk") then fs.makeDir("/mockdisk") end
      return "/mockdisk"
    end,
    ejectDisk = function() end,
  } }

  -- position source: Create: Radar reports its own world position
  d["plane_radar_0"] = { type = "plane_radar", dev = {
    getPosition = function() return { x = 128.5, y = vehicle.altitude, z = -344.5 } end,
    getRange = function() return 128 end,
    getTracks = function()
      return { {
        id = "mock-track-1",
        position = { x = 160.0, y = 80.0, z = -300.0 },
        velocity = { x = 0.1, y = 0.0, z = -0.2 },
        category = "unknown",
        entityType = "minecraft:pig",
        scannedTime = 12345,
      } }
    end,
  } }

  -- beacon navigation primitives
  d["directional_link_0"] = { type = "directional_link", dev = {
    getClosestAngle = function() return 42.0 end,
  } }
  d["modulating_link_0"] = { type = "modulating_link", dev = {
    getClosestDistance = function() return 17.5 end,
  } }

  d["tweaked_controller_0"] = { type = "tweaked_controller", dev = {
    hasUser = function() return true end,
    getUserUUID = function() return "0000-mock" end,
    isFullPrecision = function() return false end,
    setFullPrecision = function(_) end,
    getAxis = function(i)
      vehicle.tick = vehicle.tick + 1
      if i == 1 then return math.sin(vehicle.tick / 10) end
      return 0
    end,
    getButton = function(b) return b == 3 end,
  } }

  d["linked_typewriter_0"] = { type = "linked_typewriter", dev = {
    getPressedKeyCodes = function() return { keys.w, keys.a } end,
  } }

  -- a generic capability: named by BLOCK ID, not by getType(). Left in so the probe's
  -- "unrecognised peripherals" path stays exercised.
  d["vista:view_finder_0"] = { type = "vista:view_finder", dev = {
    getYaw = function() return 12.5 end,
    setYaw = function(_) end,
    getPitch = function() return -3.0 end,
    setPitch = function(_) end,
    getZoom = function() return 1 end,
    setZoom = function(_) end,
  } }

  return d
end

-- ---------------------------------------------------------------- install

function M.install(opts)
  opts = opts or {}
  local devices = opts.replace and {} or defaultDevices()
  for name, entry in pairs(opts.devices or {}) do devices[name] = entry end
  M.devices = devices

  local api = {}

  function api.getNames()
    local out = {}
    for name in pairs(devices) do out[#out + 1] = name end
    table.sort(out)
    return out
  end

  function api.getType(name)
    local d = devices[name]
    return d and d.type or nil
  end

  function api.hasType(name, ptype)
    local d = devices[name]
    if not d then return nil end
    return d.type == ptype
  end

  function api.isPresent(name) return devices[name] ~= nil end

  function api.getMethods(name)
    local d = devices[name]
    if not d then return nil end
    local out = {}
    for k, v in pairs(d.dev) do
      if type(v) == "function" and k:sub(1, 1) ~= "_" then out[#out + 1] = k end
    end
    table.sort(out)
    return out
  end

  --- Reverse lookup. Basalt's BaseFrame calls peripheral.getName(term) to work out which
  --- monitor a frame belongs to, which is how touch events get routed per screen.
  function api.getName(dev)
    for name, entry in pairs(devices) do
      if entry.dev == dev then return name end
    end
    return nil
  end

  function api.wrap(name)
    local d = devices[name]
    return d and d.dev or nil
  end

  function api.find(ptype)
    for _, name in ipairs(api.getNames()) do
      if devices[name].type == ptype then return devices[name].dev, name end
    end
    return nil
  end

  function api.call(name, method, ...)
    local d = devices[name]
    if not d then error("No such peripheral: " .. tostring(name), 2) end
    return d.dev[method](...)
  end

  return api
end

return M
