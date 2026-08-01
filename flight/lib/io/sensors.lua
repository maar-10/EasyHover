--[[ Sensor acquisition and normalisation.

     Every raw read is normalised here, using config, into a canonical craft frame:
     degrees for angles, blocks for distances, blocks/second for rates, x=right,
     y=up, z=forward. The probe may prove the gimbal's axis order or sign is not what
     we assumed -- when it does, this file's config changes and nothing else moves.

     None of the Simulated sensor getters are mainThread, so reading the whole panel
     every cycle is effectively free. Do that rather than caching cleverly.

     On a failed read we deliberately do NOT write the channel. The value keeps its old
     timestamp, its age grows, and State:isFresh() reports it stale. A control law asking
     for a fresh value therefore cannot be fed a frozen one.
]]

local Util = require("lib.util")
local Filter = require("lib.control.filter")

local Sensors = {}
Sensors.__index = Sensors

function Sensors.new(peripherals, cfg, log, state)
  local self = setmetatable({}, Sensors)
  self.per = peripherals
  self.cfg = cfg
  self.log = log
  self.state = state

  local sc = cfg.sensors
  self.f = {
    pitch = Filter.lpf(sc.gimbal.filterAlpha),
    roll = Filter.lpf(sc.gimbal.filterAlpha),
    yaw = Filter.lpf(sc.gimbal.filterAlpha),
    baro = Filter.lpf(sc.altitude.filterAlpha),
    vs = Filter.lpf(sc.altitude.vsFilterAlpha),
    speed = Filter.lpf(sc.velocity.filterAlpha),
  }
  self.opticalFilters = {}
  self.lastBaro = nil
  self.failures = {}
  self.reads = 0
  return self
end

local function safeCall(self, dev, method, label)
  if not dev then return nil end
  local fn = dev[method]
  if type(fn) ~= "function" then
    self.log:throttled("nomethod:" .. label, 10000, "error", "%s has no %s()", label, method)
    return nil
  end
  local ok, v = pcall(fn)
  if not ok then
    self.failures[label] = (self.failures[label] or 0) + 1
    self.log:throttled("fail:" .. label, 2000, "warn",
      "%s.%s() failed (%d consecutive): %s", label, method, self.failures[label], tostring(v))
    return nil
  end
  self.failures[label] = 0
  return v
end

-- ---------------------------------------------------------------- attitude

function Sensors:readAttitude()
  local dev = self.per.sensors.gimbal
  local angles = safeCall(self, dev, "getAngles", "gimbal")
  if type(angles) ~= "table" then return nil end

  local g = self.cfg.sensors.gimbal
  local function element(index, invert, filter)
    if not index or index < 1 then return nil end
    local raw = angles[index]
    if type(raw) ~= "number" then return nil end
    local value = raw * (g.scale or 1)
    if invert then value = -value end
    return filter:update(value)
  end

  local out = {
    pitch = element(g.pitchIndex, g.pitchInvert, self.f.pitch),
    roll = element(g.rollIndex, g.rollInvert, self.f.roll),
    elements = #angles,
  }
  if g.yawIndex and g.yawIndex >= 1 then
    out.yaw = element(g.yawIndex, g.yawInvert, self.f.yaw)
  end
  if out.pitch == nil or out.roll == nil then
    self.log:throttled("gimbalshape", 5000, "error",
      "gimbal returned %d element(s); config wants pitch=%s roll=%s",
      #angles, tostring(g.pitchIndex), tostring(g.rollIndex))
    return nil
  end
  return out
end

-- ---------------------------------------------------------------- altitude

--- Baro altitude plus a DIFFERENTIATED vertical speed.
-- velocity_sensor returns a scalar with no sign, so it cannot tell climb from descent.
-- Vertical speed therefore comes from d(altitude)/dt, which is why it gets its own
-- heavier filter -- differentiation amplifies exactly the noise we care least about.
function Sensors:readAltitude(dt)
  local dev = self.per.sensors.altitude
  local raw = safeCall(self, dev, "getHeight", "altitude")
  if type(raw) ~= "number" then return nil end

  local ac = self.cfg.sensors.altitude
  local baro = self.f.baro:update(raw + (ac.offset or 0))

  local vs = self.f.vs:get()
  local tuning = self.cfg.tuning
  local dtOk = type(dt) == "number"
    and dt > (tuning.dtMinMs / 1000) * 0.5
    and dt <= (tuning.dtMaxMs / 1000)
  if self.lastBaro ~= nil and dtOk then
    vs = self.f.vs:update((baro - self.lastBaro) / dt)
  elseif self.lastBaro ~= nil and type(dt) == "number" then
    -- overrun or stall: skip the derivative rather than inject a spike
    self.log:throttled("vsdt", 5000, "debug", "skipped vertical-speed update (dt=%.3fs)", dt)
  end
  self.lastBaro = baro

  local pressure = safeCall(self, dev, "getAirPressure", "altitude")
  return { baro = baro, vs = vs or 0, pressure = pressure }
end

-- ---------------------------------------------------------------- speed

function Sensors:readSpeed()
  local dev = self.per.sensors.velocity
  local raw = safeCall(self, dev, "getVelocity", "velocity")
  if type(raw) ~= "number" then return nil end
  return self.f.speed:update(raw * (self.cfg.sensors.velocity.scale or 1))
end

--- Assemble a velocity VECTOR from axis-mapped velocity sensors.
-- The flight assistant and the brake law both need a direction, and one scalar sensor
-- cannot supply one (docs/MODES.md section 6). Returns nil when not configured, so
-- callers degrade instead of inventing a direction.
function Sensors:readVelocityVector()
  local entries = self.per.sensors.velocityVector or {}
  if #entries == 0 then return nil end

  local vc = self.cfg.sensors.velocity
  local vec = {}
  for _, item in ipairs(entries) do
    local label = "velocity_" .. tostring(item.axis)
    local raw = safeCall(self, item.dev, "getVelocity", label)
    if type(raw) == "number" then
      local value = raw * (vc.scale or 1)
      if item.invert then value = -value end
      self.f[label] = self.f[label] or Filter.lpf(vc.filterAlpha)
      vec[item.axis] = self.f[label]:update(value)
    end
  end
  if vec.x == nil and vec.z == nil then return nil end

  vec.horizontal = math.sqrt((vec.x or 0) ^ 2 + (vec.z or 0) ^ 2)
  -- Direction of travel in the craft frame, degrees, 0 = straight ahead (+z).
  -- Only meaningful when the sensors are signed AND both horizontal axes are present.
  if vec.x ~= nil and vec.z ~= nil and vc.signed then
    vec.course = math.deg(math.atan2(vec.x, vec.z))
  end
  return vec
end

--- What the assistant and brake law can actually rely on right now.
--   "vector"   - signed x and z: full drift damping and directional braking
--   "partial"  - some axes, or unsigned: magnitude only, no reliable direction
--   "scalar"   - one unsigned number
--   "none"     - nothing
function Sensors:velocityCapability()
  local entries = self.per.sensors.velocityVector or {}
  local vc = self.cfg.sensors.velocity
  if #entries > 0 then
    local haveX, haveZ = false, false
    for _, item in ipairs(entries) do
      if item.axis == "x" then haveX = true end
      if item.axis == "z" then haveZ = true end
    end
    if haveX and haveZ then
      return vc.signed and "vector" or "partial"
    end
    return "partial"
  end
  if self.per.sensors.velocity then return "scalar" end
  return "none"
end

-- ---------------------------------------------------------------- lasers

--- All optical sensors. Index 1 is the down-facing altimeter by convention; the rest
--- are proximity rays consumed by the proximity UI in phase 8.
function Sensors:readOptical()
  local oc = self.cfg.sensors.optical
  local list = self.per.sensors.optical or {}
  local rays = {}
  for i, item in ipairs(list) do
    local label = "optical" .. i
    local dist = safeCall(self, item.dev, "getDistance", label)
    local block = safeCall(self, item.dev, "getBlock", label)
    if type(dist) == "number" then
      self.opticalFilters[i] = self.opticalFilters[i] or Filter.lpf(oc.filterAlpha)
      local filtered = self.opticalFilters[i]:update(dist)
      rays[i] = {
        index = i,
        name = item.name,
        distance = filtered,
        raw = dist,
        block = type(block) == "string" and block or nil,
        inRange = filtered <= (oc.maxRange or 32),
      }
    end
  end
  return rays
end

--- Is the pad under us made of something we are willing to land on?
function Sensors:padBlockAllowed(block)
  if type(block) ~= "string" then return false end
  for _, allowed in ipairs(self.cfg.sensors.optical.padWhitelist or {}) do
    if block == allowed then return true end
  end
  return false
end

-- ---------------------------------------------------------------- top level

--- Read the whole panel and publish it. dt is the loop interval in seconds.
function Sensors:read(dt)
  self.reads = self.reads + 1
  local now = os.epoch("utc")
  local result = {}

  -- Each read is a burst of mainThread peripheral calls. Run the five families concurrently so
  -- their calls queue together and drain in a few ticks rather than a dozen in series. The
  -- families touch disjoint filters and lastBaro, so they are safe to run as coroutines; the
  -- state-setting below stays synchronous, after they have all returned. (No NESTED parallel:
  -- an inner batch would swallow the outer families' task_complete events -- so the multi-call
  -- families read their own sensors in series within their coroutine, which is fine.)
  local attitude, altitude, speed, vec, rays
  Util.runBatch({
    function() attitude = self:readAttitude() end,
    function() altitude = self:readAltitude(dt) end,
    function() speed = self:readSpeed() end,
    function() vec = self:readVelocityVector() end,
    function() rays = self:readOptical() end,
  }, self.cfg.tuning.parallelIO)
  rays = rays or {}

  if attitude then
    self.state:setGroup("attitude", attitude, now)
    result.attitude = attitude
  end

  if altitude then
    self.state:set("altitude.baro", altitude.baro, now)
    self.state:set("altitude.vs", altitude.vs, now)
    if altitude.pressure ~= nil then
      self.state:set("altitude.pressure", altitude.pressure, now)
    end
    result.altitude = altitude
  end

  if speed ~= nil then
    self.state:set("speed.scalar", speed, now)
    result.speed = speed
  end

  if vec then
    self.state:setGroup("velocity", vec, now)
    result.velocity = vec
  end
  self.state:set("velocity.capability", self:velocityCapability(), now)

  if rays[1] then
    self.state:set("altitude.radar", rays[1].distance, now)
    self.state:set("ground.distance", rays[1].distance, now)
    self.state:set("ground.block", rays[1].block, now)
    self.state:set("ground.padOk", self:padBlockAllowed(rays[1].block), now)
  end
  if next(rays) ~= nil then
    self.state:set("optical.rays", rays, now)
    result.rays = rays
  end

  -- GROUND CONTACT is the DOWN-FACING LASER alone -- the radar altimeter under the hull. Within
  -- `groundContactDist` of a surface is "on the ground".
  --
  -- The near-zero-vertical-speed AND-condition was REMOVED. It existed so a low fast pass would not
  -- read as a landing, but vertical speed here is DIFFERENTIATED baro, which jitters -- so a craft
  -- sitting still on the ground would intermittently show |vs| above the epsilon and be reported
  -- AIRBORNE. That is the exact false positive a preflight ground check must not trip on -- a
  -- landed craft with the thrusters cold. The laser is the honest answer to "is there ground right
  -- under me"; a stuck laser is a far rarer fault than baro jitter, and the pre-flight interlocks
  -- re-check actual thrust before doing anything anyway.
  local sc = self.cfg.sensors
  local groundDist = rays[1] and rays[1].distance or nil
  -- nil, NOT false, when there is no down laser reading: "unknown", not "airborne". The arming
  -- logic (App:cycle) treats an unknown ground state as grounded and keeps the craft disarmed, so a
  -- missing or unassigned radar altimeter can never be misread as "in flight" and left to fire the
  -- thrusters on the pad. true = on the ground, false = the laser positively says we are off it.
  local contact = nil
  if groundDist ~= nil then
    contact = groundDist <= (sc.groundContactDist or 2.0)
  end
  self.state:set("ground.contact", contact, now)
  result.groundContact = contact

  return result
end

--- Can the control loops trust the panel right now?
function Sensors:isHealthy()
  local stale = self.cfg.sensors.staleMs
  local attitudeOk = self.state:isFresh("attitude.pitch", stale)
    and self.state:isFresh("attitude.roll", stale)
  local altitudeOk = self.state:isFresh("altitude.baro", stale)
  return attitudeOk and altitudeOk, {
    attitude = attitudeOk,
    altitude = altitudeOk,
    heading = self.state:isFresh("attitude.yaw", stale),
    ground = self.state:isFresh("ground.distance", stale),
  }
end

return Sensors
