--[[ The flight envelope.

     Every demand -- pilot, flight assistant, brake law, autopilot -- passes through here on
     its way to the mixer. The envelope always wins, and nothing may negotiate with it: it
     takes no mode argument and has no bypass. That is the point. An autopilot bug or a
     runaway assistant then cannot command an attitude the attitude loop is unable to hold.

     It reports WHAT it clipped as well as clipping it, because silent clipping looks
     exactly like a broken control law from the cockpit.
]]

local Util = require("lib.util")

local Envelope = {}
Envelope.__index = Envelope

function Envelope.new(cfg)
  local self = setmetatable({}, Envelope)
  self.cfg = cfg
  return self
end

local function limit(value, maxAbs)
  if type(value) ~= "number" then return value, false end
  if value > maxAbs then return maxAbs, true end
  if value < -maxAbs then return -maxAbs, true end
  return value, false
end

--- Clamp a full demand table. Returns a NEW table plus a sorted list of clipped fields.
-- demand: { pitch, roll, yawRate, verticalSpeed, altitudeTarget, groundSpeed, brakeTilt }
function Envelope:apply(demand)
  local e = self.cfg.envelope
  local out, clipped = {}, {}
  for k, v in pairs(demand) do out[k] = v end

  local function clip(field, maxAbs)
    if out[field] == nil then return end
    local v, wasClipped = limit(out[field], maxAbs)
    out[field] = v
    if wasClipped then clipped[#clipped + 1] = field end
  end

  clip("pitch", e.maxPitchDeg)
  clip("roll", e.maxBankDeg)
  clip("yawRate", e.maxYawRateDps)
  clip("groundSpeed", e.maxGroundSpeed)

  -- brake tilt is additionally capped by its own, tighter limit
  if out.brakeTilt ~= nil then
    local v, wasClipped = limit(out.brakeTilt, math.min(self.cfg.brake.maxTiltDeg, e.maxPitchDeg))
    out.brakeTilt = v
    if wasClipped then clipped[#clipped + 1] = "brakeTilt" end
  end

  -- vertical speed is asymmetric: climbing and sinking have different limits
  if out.verticalSpeed ~= nil and type(out.verticalSpeed) == "number" then
    if out.verticalSpeed > e.maxClimbRate then
      out.verticalSpeed = e.maxClimbRate
      clipped[#clipped + 1] = "verticalSpeed"
    elseif out.verticalSpeed < -e.maxSinkRate then
      out.verticalSpeed = -e.maxSinkRate
      clipped[#clipped + 1] = "verticalSpeed"
    end
  end

  if out.altitudeTarget ~= nil and type(out.altitudeTarget) == "number" then
    local clampedAlt = Util.clamp(out.altitudeTarget, e.altFloor, e.altCeil)
    if clampedAlt ~= out.altitudeTarget then
      out.altitudeTarget = clampedAlt
      clipped[#clipped + 1] = "altitudeTarget"
    end
  end

  table.sort(clipped)
  return out, clipped
end

--- Combined pitch+roll magnitude, for a single "how tilted are we" number.
function Envelope.tiltMagnitude(pitch, roll)
  return math.sqrt((pitch or 0) ^ 2 + (roll or 0) ^ 2)
end

--- Is the craft ACTUALLY outside the envelope right now? For annunciation, not control.
-- Returns a list of { key, value, limit, level }.
function Envelope:violations(measured)
  local e = self.cfg.envelope
  local out = {}
  local function check(key, value, maxAbs, cautionFraction)
    if type(value) ~= "number" then return end
    local magnitude = math.abs(value)
    if magnitude > maxAbs then
      out[#out + 1] = { key = key, value = value, limit = maxAbs, level = "warning" }
    elseif magnitude > maxAbs * (cautionFraction or 0.85) then
      out[#out + 1] = { key = key, value = value, limit = maxAbs, level = "caution" }
    end
  end

  check("pitch", measured.pitch, e.maxPitchDeg)
  check("roll", measured.roll, e.maxBankDeg)

  if type(measured.verticalSpeed) == "number" then
    if measured.verticalSpeed < -e.maxSinkRate then
      out[#out + 1] = { key = "sinkRate", value = measured.verticalSpeed,
                        limit = -e.maxSinkRate, level = "warning" }
    elseif measured.verticalSpeed > e.maxClimbRate then
      out[#out + 1] = { key = "climbRate", value = measured.verticalSpeed,
                        limit = e.maxClimbRate, level = "caution" }
    end
  end

  if type(measured.altitude) == "number" then
    if measured.altitude < e.altFloor then
      out[#out + 1] = { key = "altFloor", value = measured.altitude,
                        limit = e.altFloor, level = "warning" }
    elseif measured.altitude > e.altCeil then
      out[#out + 1] = { key = "altCeil", value = measured.altitude,
                        limit = e.altCeil, level = "caution" }
    end
  end

  return out
end

--- The brake law's tilt demand: proportional to speed, capped, and zero below minSpeed
--- so the slightest drift does not produce a lurch.
function Envelope:brakeTiltForSpeed(speed)
  local b = self.cfg.brake
  if type(speed) ~= "number" or speed <= b.minSpeed then return 0 end
  local span = math.max(b.speedForFullTilt - b.minSpeed, 1e-6)
  local fraction = Util.clamp((speed - b.minSpeed) / span, 0, 1)
  return fraction * math.min(b.maxTiltDeg, self.cfg.envelope.maxPitchDeg)
end

return Envelope
