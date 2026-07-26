--[[ Redstone relays: the hardware failsafe, and aux outputs.

     THE FAILSAFE, in one paragraph. Attaching a computer puts a thruster into
     ControlMode.PERIPHERAL and adjacent redstone stops driving thrust. On detach -- the
     computer broken, unloaded, or rebooting -- the thruster reverts to NORMAL and reads
     getBestNeighborSignal(). Relay outputs PERSIST when their owning computer dies. So a
     level written once at boot is already sitting there the moment authority reverts, and
     the craft settles instead of falling.

     It is open loop. There is no sensor and no computer in that path, so it cannot HOLD an
     altitude -- the craft will still drift slowly with mass and fuel. Do not describe it
     to the pilot as an altitude hold. (The software degraded-hold reference is a separate
     setting, failsafe.holdAltitude.)

     Wiring note (DriveByWire v6): a redstone relay's "face" is its BACK. Sides in config
     are the relay's own sides, and getting this wrong looks exactly like a code bug.
]]

local Util = require("lib.util")

local Relays = {}
Relays.__index = Relays

function Relays.new(peripherals, cfg, log, state)
  local self = setmetatable({}, Relays)
  self.per = peripherals
  self.cfg = cfg
  self.log = log
  self.state = state
  self.appliedLevel = nil
  self.lastVerify = nil
  return self
end

local function call(dev, method, ...)
  local fn = dev[method]
  if type(fn) ~= "function" then return false, "no method " .. method end
  local ok, v = pcall(fn, ...)
  if not ok then return false, tostring(v) end
  return true, v
end

function Relays:failsafeRelays()
  local out = {}
  for _, item in ipairs(self.per.relays or {}) do
    if item.spec.purpose == "failsafe" then out[#out + 1] = item end
  end
  return out
end

--- Write the failsafe level to every failsafe relay and verify the readback.
-- Returns ok, report. Verification matters: an unverified failsafe is a belief, not a
-- failsafe, and this is the one number that must be right before a crewed flight.
function Relays:applyFailsafe(level)
  level = Util.clamp(math.floor((level or self.cfg.failsafe.redstoneLevel or 0) + 0.5), 0, 15)
  local report = { level = level, relays = {}, ok = true, count = 0 }

  local targets = self:failsafeRelays()
  if #targets == 0 then
    self.log:warn("no failsafe relay configured -- a computer failure will drop the craft")
    report.ok = false
    report.reason = "no failsafe relay configured"
    if self.state then self.state:set("failsafe.applied", false) end
    return false, report
  end

  for _, item in ipairs(targets) do
    local row = { name = item.name, side = item.spec.side, requested = level }
    local ok, err = call(item.dev, "setAnalogOutput", item.spec.side, level)
    if not ok then
      row.ok, row.error = false, err
      report.ok = false
      self.log:error("failsafe relay %s (%s): write failed: %s", item.name, item.spec.side, tostring(err))
    else
      row.ok = true
      if self.cfg.failsafe.verifyRelays then
        local okRead, readback = call(item.dev, "getAnalogOutput", item.spec.side)
        row.readback = okRead and readback or nil
        if not okRead or readback ~= level then
          row.ok = false
          report.ok = false
          self.log:error("failsafe relay %s (%s): readback %s, expected %d",
            item.name, item.spec.side, tostring(row.readback), level)
        end
      end
    end
    if row.ok then report.count = report.count + 1 end
    report.relays[#report.relays + 1] = row
  end

  self.appliedLevel = report.ok and level or nil
  self.lastVerify = os.epoch("utc")
  if self.state then
    self.state:set("failsafe.applied", report.ok)
    self.state:set("failsafe.level", level)
    self.state:set("failsafe.report", report)
  end
  if report.ok then
    self.log:info("failsafe level %d applied and verified on %d relay(s)", level, report.count)
  end
  return report.ok, report
end

--- Apply the level derived from the learned hover trim, if config asks for that.
function Relays:applyDerivedFailsafe(configModule)
  local level, derived = configModule.deriveFailsafeLevel(self.cfg)
  if derived then
    self.log:info("failsafe level %d derived from learned hover trim %.3f (+%d step bias)",
      level, self.cfg.control.altitude.hoverTrim or 0, self.cfg.failsafe.biasSteps or 0)
  end
  return self:applyFailsafe(level)
end

--- Ground-only test: write the level and report what the thrusters actually produce,
--- so the number can be validated before it is ever needed.
function Relays:testFailsafe(level, thrusters, allowed)
  if not allowed then
    return false, { ok = false, reason = "failsafe test is only permitted on the ground" }
  end
  local ok, report = self:applyFailsafe(level)
  report.thrusters = thrusters and thrusters:readback() or nil
  report.hoverTrim = self.cfg.control.altitude.hoverTrim
  return ok, report
end

-- ---------------------------------------------------------------- aux

--- Digital aux output by label (lights, doors, gear -- phase 10).
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
  return out
end

return Relays
