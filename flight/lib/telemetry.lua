--[[ Telemetry out, commands in -- over WIRED rednet.

     The flight computer publishes a compact snapshot at `tuning.telemetryHz` and accepts a
     small, whitelisted set of commands. Everything else on the craft is a client of this.

     Three rules, all of them structural rather than conventional:

       1. FLIGHT NEVER WAITS FOR A REPLY. Publishing is a broadcast and nothing is expected
          back. If every UI computer is gone, the loop does not notice and does not care.
       2. COMMANDS ARE WHITELISTED AND TYPE-CHECKED HERE, before they reach anything that can
          move the craft. An unknown command, a wrong type or a flood is dropped and logged.
       3. THIS MODULE HAS NO SIDE EFFECTS on the vehicle. It parses and validates; app.lua
          decides what to do. That is what makes the validation testable without a craft.

     Wired only. The ender-modem link (telemetry OUT only, never commands) is a separate
     module and is not part of this one.
]]

local Util = require("lib.util")

local Telemetry = {}
Telemetry.__index = Telemetry

--- The command surface. `nil` means the field is optional; anything else is a required type.
--- "enum:a,b,c" restricts a string. "any" accepts any non-nil value.
local COMMANDS = {
  ping          = {},
  engineMaster  = { value = "boolean" },
  -- Hardware assignment. Dedicated commands rather than configSet, because these have to
  -- CREATE a list entry (hardware.tanks starts empty) and configSet deliberately refuses to
  -- invent keys.
  setEngineRelay = { peripheral = "string", side = "string" },
  setTank        = { peripheral = "string" },
  setVault       = { peripheral = "string" },
  -- One command for every "which peripheral fills this named role" question the config
  -- screens ask -- thrusters, velocity axes, the altimeter, the gimbal and the laser rays.
  -- `kind` says which family, `key` which slot inside it. An empty peripheral UNASSIGNS.
  setSlot        = { kind = "enum:lift,main,lateral,velocity,altitude,gimbal,optical",
                     key = "string", peripheral = "string" },
  engineFeed    = {},
  setAux        = { label = "string", value = "boolean" },
  setFeel       = { value = "enum:cruise,rate,stutter" },
  setLateral    = { value = "enum:flight,precision" },
  setAssist     = { value = "boolean" },
  setAltitude   = { value = "number" },
  identify      = { id = "string" },
  configSet     = { path = "string", value = "any" },
  configSave    = {},
  diskSave      = {},
  diskLoad      = {},
}

Telemetry.COMMANDS = COMMANDS

--- The config values the UI panels display and edit.
---
--- Deliberately an explicit list rather than the whole config tree: the wire format is an
--- interface, the tree is large, and a UI that could see everything would be tempted to edit
--- everything. Anything a panel needs gets added here on purpose.
local function configView(cfg)
  return {
    enginePulseMs = cfg.engine.pulseMs,
    engineIntervalMs = cfg.engine.intervalMs,
    engineInvert = cfg.engine.invert,
    engineEnabled = cfg.engine.enabled,
    tankCapacityMb = (cfg.hardware.tanks[1] or {}).capacityMb,
    -- what is assigned right now, so the UI can show it next to the choices
    engineRelay = cfg.hardware.engine.relay,
    engineSide = cfg.hardware.engine.side,
    tankPeripheral = (cfg.hardware.tanks[1] or {}).peripheral,
    tankLabel = (cfg.hardware.tanks[1] or {}).label,
    vaultPeripheral = (cfg.hardware.vaults[1] or {}).peripheral,
    vaultLabel = (cfg.hardware.vaults[1] or {}).label,

    attitudeHz = cfg.tuning.attitudeHz,
    altitudeHz = cfg.tuning.altitudeHz,
    maxBankDeg = cfg.envelope.maxBankDeg,
    maxPitchDeg = cfg.envelope.maxPitchDeg,
    maxClimbRate = cfg.envelope.maxClimbRate,
    maxSinkRate = cfg.envelope.maxSinkRate,
    maxYawRateDps = cfg.envelope.maxYawRateDps,
    climbRate = cfg.modes.climbRate,
    brakeMaxTiltDeg = cfg.brake.maxTiltDeg,
    assistEnabled = cfg.assist.enabled,
    assistGain = cfg.assist.gain,
    feelDefault = cfg.modes.default,
    lateralDefault = cfg.modes.lateralDefault,
    holdAltitude = cfg.failsafe.holdAltitude,
  }
end

--- What is assigned to each named slot right now, keyed exactly as `setSlot` addresses them.
---
--- Flat "kind:key" -> peripheral, because the panels look up one slot at a time and a flat
--- table costs nothing to serialise. An unassigned slot is simply absent.
local function slotView(cfg)
  local slots = {}
  for _, t in ipairs(cfg.hardware.thrusters or {}) do
    if t.id ~= "" and t.peripheral ~= "" then
      -- Config.slotKey, not t.id: an older craft spells the same slot "lift_fl".
      slots[t.group .. ":" .. require("lib.config").slotKey(t)] = t.peripheral
    end
  end
  for _, entry in ipairs(cfg.hardware.sensors.velocityVector or {}) do
    if entry.axis and entry.peripheral ~= "" then
      slots["velocity:" .. entry.axis] = entry.peripheral
    end
  end
  for _, entry in ipairs(cfg.hardware.sensors.optical or {}) do
    local dir = type(entry) == "table" and entry.direction or nil
    local name = type(entry) == "table" and entry.peripheral or entry
    if dir and dir ~= "" and name and name ~= "" then slots["optical:" .. dir] = name end
  end
  if cfg.hardware.sensors.altitude ~= "" then
    slots["altitude:sensor"] = cfg.hardware.sensors.altitude
  end
  if cfg.hardware.sensors.gimbal ~= "" then
    slots["gimbal:sensor"] = cfg.hardware.sensors.gimbal
  end
  return slots
end

Telemetry.slotView = slotView

function Telemetry.new(cfg, log, state)
  local self = setmetatable({}, Telemetry)
  self.cfg = cfg
  self.log = log
  self.state = state
  self.modem = nil
  self.seq = 0
  self.lastPublishAt = 0
  self.received = 0
  self.dropped = 0
  self.recent = {}      -- timestamps, for the rate limit
  return self
end

-- ---------------------------------------------------------------- transport

--- Open rednet on a wired modem. Wired only: a wireless modem here would put the control
--- surface on the air, which the whole topology exists to avoid.
function Telemetry:open()
  local name = self.cfg.comms.modem
  if name == nil or name == "" then
    for _, candidate in ipairs(peripheral.getNames()) do
      local ok, isWireless = pcall(function()
        local dev = peripheral.wrap(candidate)
        if peripheral.hasType and not peripheral.hasType(candidate, "modem") then return nil end
        if dev and dev.isWireless then return dev.isWireless() end
        return nil
      end)
      if ok and isWireless == false then
        name = candidate
        break
      end
    end
  end

  if name == nil or name == "" then
    self.log:warn("no wired modem found: telemetry and the UI computers will be blind")
    return false, "no wired modem"
  end

  local ok, err = pcall(rednet.open, name)
  if not ok then
    self.log:error("could not open rednet on %s: %s", tostring(name), tostring(err))
    return false, tostring(err)
  end
  self.modem = name
  self.log:info("telemetry open on %s (protocol %s)", name, self.cfg.comms.telemetryProtocol)
  return true
end

function Telemetry:close()
  if self.modem then pcall(rednet.close, self.modem) end
  self.modem = nil
end

function Telemetry:isOpen()
  return self.modem ~= nil
end

-- ---------------------------------------------------------------- publish

--- Assemble the payload. Deliberately hand-built rather than dumping the whole state store:
--- the wire format is an interface, and an accidental rename should not silently break a UI.
function Telemetry:build(extra)
  local s = self.state
  self.seq = self.seq + 1

  local payload = {
    proto = "eh1",
    seq = self.seq,
    t = os.epoch("utc"),
    role = "flight",
    mode = s.mode,

    modes = {
      feel = s:get("modes.feel"),
      lateral = s:get("modes.lateral"),
      assist = s:get("modes.assist"),
      assistActive = s:get("modes.assistActive"),
      state = s:get("modes.state"),
      throttle = s:get("modes.throttle"),
      brakeHold = s:get("modes.brakeHold"),
      brakeLatched = s:get("modes.brakeLatched"),
      altitudeTarget = s:get("modes.altitudeTarget"),
    },

    attitude = {
      pitch = s:get("attitude.pitch"),
      roll = s:get("attitude.roll"),
      yaw = s:get("attitude.yaw"),
    },

    altitude = {
      baro = s:get("altitude.baro"),
      radar = s:get("altitude.radar"),
      vs = s:get("altitude.vs"),
      pressure = s:get("altitude.pressure"),
    },

    velocity = {
      scalar = s:get("speed.scalar"),
      x = s:get("velocity.x"),
      z = s:get("velocity.z"),
      horizontal = s:get("velocity.horizontal"),
      capability = s:get("velocity.capability"),
    },

    ground = {
      distance = s:get("ground.distance"),
      contact = s:get("ground.contact"),
      block = s:get("ground.block"),
      padOk = s:get("ground.padOk"),
    },

    engine = {
      available = s:get("engine.available"),
      master = s:get("engine.master"),
      feeding = s:get("engine.feeding"),
      pulses = s:get("engine.pulses"),
      nextFeedInMs = s:get("engine.nextFeedInMs"),
    },

    fuel = {
      worstFraction = s:get("fuel.worstFraction"),
      worstId = s:get("fuel.worstId"),
      worstTank = s:get("fuel.worstTank"),
      vaultEmpty = s:get("fuel.vaultEmpty"),
      tanks = s:get("fuel.tanks"),
      vaults = s:get("fuel.vaults"),
    },

    control = {
      hoverTrim = s:get("control.hoverTrim"),
      trimAuthority = s:get("control.trimAuthority"),
      collective = s:get("thrusters.collective"),
    },

    thrusters = {
      calls = s:get("thrusters.calls"),
      writes = s:get("thrusters.writes"),
      errors = s:get("thrusters.errors"),
      readback = s:get("thrusters.readback"),
    },

    layout = s:get("layout"),
    candidates = s:get("candidates"),
    disk = {
      driveCount = s:get("disk.driveCount"),
      diskPresent = s:get("disk.diskPresent"),
      onDisk = s:get("disk.onDisk"),
      localConfigs = s:get("disk.localConfigs"),
      label = s:get("disk.label"),
    },

    config = configView(self.cfg),
    slots = slotView(self.cfg),
    oscillation = s:get("oscillation"),
    envelopeClipped = s:get("envelope.clipped"),
    alarms = s:activeAlarms(),
    cycle = { dt = s:get("cycle.dt"), overrun = s:get("cycle.overrun"), n = s:get("cycles") },
  }

  if extra then
    for k, v in pairs(extra) do payload[k] = v end
  end
  return payload
end

--- Broadcast, rate-limited to telemetryHz. Returns true when it actually sent.
function Telemetry:publish(now, extra)
  if not self.modem then return false end
  now = now or os.epoch("utc")
  local period = 1000 / math.max(self.cfg.tuning.telemetryHz, 1)
  if (now - self.lastPublishAt) < period then return false end
  self.lastPublishAt = now

  local payload = self:build(extra)
  local ok, err = pcall(rednet.broadcast, payload, self.cfg.comms.telemetryProtocol)
  if not ok then
    self.log:throttled("telemetry", 5000, "warn", "telemetry broadcast failed: %s", tostring(err))
    return false
  end
  return true
end

--- Send a direct reply to one computer, for command acknowledgements.
function Telemetry:reply(recipient, payload)
  if not self.modem or recipient == nil then return false end
  local ok = pcall(rednet.send, recipient, payload, self.cfg.comms.commandProtocol)
  return ok
end

-- ---------------------------------------------------------------- commands

local function typeMatches(spec, value)
  if spec == "any" then return value ~= nil end
  if spec:sub(1, 5) == "enum:" then
    if type(value) ~= "string" then return false end
    for option in spec:sub(6):gmatch("[^,]+") do
      if value == option then return true end
    end
    return false
  end
  return type(value) == spec
end

--- Is this computer allowed to send another command right now?
function Telemetry:rateLimited(now)
  local limit = self.cfg.comms.commandRateLimit or 20
  local cutoff = now - 1000
  local kept = {}
  for _, t in ipairs(self.recent) do
    if t >= cutoff then kept[#kept + 1] = t end
  end
  self.recent = kept
  return #self.recent >= limit
end

--- Validate an incoming command. Returns cmd, err.
---
--- No side effects: this only decides whether app.lua should be handed the message. Anything
--- that can move the craft is checked here first, on the flight side, because a UI is not a
--- trusted peer -- it is just another computer on the wire.
function Telemetry:parseCommand(message, sender, now)
  now = now or os.epoch("utc")
  self.received = self.received + 1

  if type(message) ~= "table" then
    self.dropped = self.dropped + 1
    return nil, "not a table"
  end
  local name = message.cmd
  if type(name) ~= "string" then
    self.dropped = self.dropped + 1
    return nil, "no cmd field"
  end
  local spec = COMMANDS[name]
  if spec == nil then
    self.dropped = self.dropped + 1
    self.log:throttled("badcmd", 2000, "warn", "unknown command '%s' from %s",
      name, tostring(sender))
    return nil, "unknown command: " .. name
  end

  if self:rateLimited(now) then
    self.dropped = self.dropped + 1
    self.log:throttled("cmdflood", 2000, "warn", "command rate limit hit; dropping")
    return nil, "rate limited"
  end
  self.recent[#self.recent + 1] = now

  for field, expected in pairs(spec) do
    if not typeMatches(expected, message[field]) then
      self.dropped = self.dropped + 1
      self.log:warn("command %s: field '%s' expects %s", name, field, expected)
      return nil, ("field '%s' expects %s"):format(field, expected)
    end
  end

  local cmd = { cmd = name, sender = sender }
  for field in pairs(spec) do cmd[field] = message[field] end
  return cmd
end

function Telemetry:stats()
  return {
    open = self.modem ~= nil,
    modem = self.modem,
    published = self.seq,
    received = self.received,
    dropped = self.dropped,
  }
end

return Telemetry
