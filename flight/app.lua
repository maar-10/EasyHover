--[[ The flight computer.

     One loop, one clock, no UI, no speaker, no HTTP (docs/WIRING.md). Everything else in the
     system is a client of the telemetry this produces.

     `App:cycle(dt)` is deliberately a plain function of its inputs so it can be driven by
     tests as well as by the event loop.
]]

local Util = require("lib.util")
local Config = require("lib.config")
local Log = require("lib.log")
local State = require("lib.state")
local Peripherals = require("lib.peripherals")
local Sensors = require("lib.io.sensors")
local Thrusters = require("lib.io.thrusters")
local Fuel = require("lib.io.fuel")
local Relays = require("lib.io.relays")
local Engine = require("lib.io.engine")
local Disk = require("lib.io.disk")
local Mixer = require("lib.control.mixer")
local Attitude = require("lib.control.attitude")
local Altitude = require("lib.control.altitude")
local Envelope = require("lib.control.envelope")
local Oscillation = require("lib.control.oscillation")
local Assist = require("lib.control.assist")
local Brake = require("lib.control.brake")
local Modes = require("lib.modes")
local Pilot = require("lib.input.pilot")
local Telemetry = require("lib.telemetry")

local App = {}
App.__index = App

local CONFIG_PATH = "/eh_flight_config.tbl"

function App.new(opts)
  opts = opts or {}
  local self = setmetatable({}, App)

  local cfg, existed = Config.load(opts.configPath or CONFIG_PATH)
  self.configPath = opts.configPath or CONFIG_PATH
  self.cfg = cfg
  self.configExisted = existed

  self.log = Log.new({
    level = cfg.log.level, capacity = cfg.log.capacity,
    path = cfg.log.path, echo = opts.echo,
  })
  self.state = State.new({ staleMs = cfg.sensors.staleMs })

  local ok, errors, warnings = Config.validate(cfg)
  self.configValid = ok
  for _, e in ipairs(errors) do self.log:error("config: %s", e) end
  for _, warning in ipairs(warnings) do self.log:warn("config: %s", warning) end

  self.per = Peripherals.new(cfg, self.log)
  self.sensors = Sensors.new(self.per, cfg, self.log, self.state)
  self.thrusters = Thrusters.new(self.per, cfg, self.log, self.state)
  self.fuel = Fuel.new(self.per, cfg, self.log, self.state)
  self.relays = Relays.new(self.per, cfg, self.log, self.state)
  self.engine = Engine.new(self.per, cfg, self.log, self.state)
  self.disk = Disk.new(self.per, cfg, self.log, self.state)

  self.envelope = Envelope.new(cfg)
  self.osc = Oscillation.new(cfg, self.log)
  self.mixer = Mixer.new(cfg, self.per)
  self.attitude = Attitude.new(cfg, self.log, self.osc)
  self.altitude = Altitude.new(cfg, self.log, self.osc, { steps = 15 })
  self.assist = Assist.new(cfg, self.log)
  self.brake = Brake.new(cfg, self.envelope, self.log)
  self.modes = Modes.new(cfg, self.log)
  self.pilot = Pilot.new(cfg, self.log)
  self.telemetry = Telemetry.new(cfg, self.log, self.state)

  self.altitudeAccumulator = 0
  self.lastCycleAt = nil
  self.cycles = 0
  self.trimAtLastSave = self.cfg.control.altitude.hoverTrim or 0
  self.running = false
  return self
end

-- ---------------------------------------------------------------- boot

function App:boot()
  self.log:info("EasyHover flight computer booting (config %s)",
    self.configExisted and "loaded" or "defaults")
  self.per:scan()
  self.thrusters:invalidate()
  self.mixer:build()
  self.modes:setFeel(self.cfg.modes.default)
  self.modes:setLateral(self.cfg.modes.lateralDefault)

  -- Engine master FIRST, before anything else touches a relay: assert the funnel BLOCKED.
  -- The vehicle boots off, and an unblocked funnel with no engine running would quietly drain
  -- the vault into a cold engine.
  self.engine:blockNow()
  self.engine:publish()
  if self.engine:available() then
    self.log:info("engine master OFF, funnel blocked (relay %s side %s)",
      tostring(self.per.engine.name), tostring(self.per.engine.side))
  elseif self.cfg.engine.enabled then
    self.log:error("engine.enabled is set but no engine relay is present")
    self.state:raise("engine", "warning", "engine relay missing")
  end

  -- NOTE: there is no hardware thrust failsafe. It was scrapped deliberately -- see
  -- docs/WIRING.md. If this computer dies in flight, the craft falls.

  -- Adopt the first altitude reading as the software hold reference, as specified.
  self.sensors:read(nil)
  local first = self.state:get("altitude.baro")
  if self.cfg.failsafe.holdAltitude == nil and type(first) == "number" then
    self.cfg.failsafe.holdAltitude = first
    self.log:info("software hold altitude adopted from first reading: %.2f", first)
  end
  self.modes.altitudeTarget = self.cfg.failsafe.holdAltitude or first

  local caps = self.mixer:capabilities()
  self.log:info("layout: %d lift, %d main, %d lateral (pitch=%s roll=%s yaw=%s)",
    caps.lift, caps.main, caps.lateral, tostring(caps.pitch), tostring(caps.roll),
    tostring(caps.yaw))
  self.state:set("layout", caps)

  local capability = self.sensors:velocityCapability()
  self.state:set("velocity.capability", capability)
  if capability ~= "vector" then
    self.log:warn("velocity capability is '%s': drift damping and directional braking are "
      .. "degraded (see docs/MODES.md section 6)", capability)
  end

  local problems = self.pilot.bindings.problems
  if #problems > 0 then
    self.state:raise("keybinds", "caution", ("%d keybind problem(s)"):format(#problems))
  end

  self.telemetry:open()

  local diskStatus = self.disk:status()
  self.log:info("disk: %d drive(s), %s, %d config(s) here",
    diskStatus.driveCount, diskStatus.diskPresent and "disk present" or "no disk",
    diskStatus.localConfigs)

  self.fuel:readAll()

  return self.configValid
end

-- ---------------------------------------------------------------- one cycle

function App:devices()
  return {
    controller = self.per.inputs.controller,
    typewriter = self.per.inputs.typewriter,
  }
end

--- Run exactly one control cycle. dt in seconds.
function App:cycle(dt)
  local now = os.epoch("utc")
  self.cycles = self.cycles + 1
  local tuning = self.cfg.tuning

  -- dt discipline: a stalled cycle is clamped and flagged rather than trusted
  local overrun = false
  if type(dt) ~= "number" or dt <= 0 then
    dt = 1 / tuning.attitudeHz
  elseif dt > tuning.dtMaxMs / 1000 then
    overrun = true
    self.state:bump("overruns")
  end

  -- ---- sense
  self.sensors:read(dt)
  local healthy = self.sensors:isHealthy()
  local measured = {
    altitude = self.state:get("altitude.baro"),
    verticalSpeed = self.state:get("altitude.vs") or 0,
    pitch = self.state:get("attitude.pitch") or 0,
    roll = self.state:get("attitude.roll") or 0,
    yaw = self.state:get("attitude.yaw"),
    groundContact = self.state:get("ground.contact") and true or false,
  }
  local velocity = {
    x = self.state:get("velocity.x"),
    z = self.state:get("velocity.z"),
    horizontal = self.state:get("velocity.horizontal"),
  }
  local capability = self.state:get("velocity.capability") or "none"

  -- ---- pilot
  local axes, held, edges = self.pilot:read(self:devices(), dt)
  if edges.cycleFeel then self.modes:cycleFeel() end
  if edges.toggleLateral then self.modes:toggleLateral() end
  if edges.toggleAssist then self.modes:toggleAssist() end
  if edges.engineMaster then self.engine:toggleMaster(now) end
  if edges.lights then self.relays:toggleAux("lights") end
  if edges.gear then self.relays:toggleAux("gear") end
  self.attitude:setMode(self.modes:attitudeMode())

  -- The engine pulse machine runs every cycle, in every flight state including DAMPED and
  -- FAILSAFE: whatever else is wrong, the engine must keep being fed or the pumps stop.
  self.engine:tick(now)

  self.modes:updateBrakeKey(held.brake and true or false, now)
  self.modes:updateThrottle(axes.accel, dt, now)
  -- any deliberate movement input releases a latched brake
  if self.pilot:isCommanding() then
    self.modes:clearBrakeLatch()
    self.assist:noteInput(now)
  end

  -- ---- state
  local shouldDamp = self.osc:shouldDamp()
  local state = self.modes:updateState({
    healthy = healthy,
    hardwareOk = self.per:count() > 0,
    shouldDamp = shouldDamp,
    groundContact = measured.groundContact,
    climbInput = math.abs(axes.climb or 0) > 0.02,
  })
  self.state.mode = state

  -- DAMPED / FAILSAFE: stop steering, keep flying. Vectors to neutral, thrust untouched.
  if state == "DAMPED" or state == "FAILSAFE" then
    self.thrusters:neutralVectors()
    self.state:raise(state == "DAMPED" and "oscillation" or "sensors",
      "warning", state == "DAMPED" and "damped hover: oscillation detected"
      or "damped hover: sensors unhealthy")
    if state == "DAMPED" then self.osc:acknowledgeDamped() end
    self:publish(measured, capability, dt, overrun)
    return state
  end
  self.state:clear("oscillation")
  self.state:clear("sensors")

  -- ---- shape the pilot's demand
  local demand = self.modes:shape(axes, measured, dt, now)

  -- ---- reverse: pitch up so the lift thrusters push us backwards
  if self.modes:isReverse() then
    local reverse = self.brake:reverseDemand(self.modes.throttle, dt)
    demand.pitch = (demand.pitch or 0) + reverse.pitch
    demand.mainThrust = 0
  elseif self.modes:isBraking() then
    -- ---- brake: tilt the lift thrusters into the direction of motion
    local braking = self.brake:demand(velocity, capability, self.state:get("speed.scalar"), dt)
    demand.pitch = (demand.pitch or 0) + braking.pitch
    demand.roll = (demand.roll or 0) + braking.roll
    if braking.degraded then
      self.state:raise("brakeDegraded", "caution", "braking without a velocity vector")
    else
      self.state:clear("brakeDegraded")
    end
  else
    self.brake:reset()
    self.state:clear("brakeDegraded")
  end

  -- ---- flight assistant: damp drift with every lateral thruster
  local assistOut = self.assist:demand({
    enabled = self.modes:assistActive(),
    velocity = velocity,
    capability = capability,
    throttle = self.modes.throttle,
    now = now,
    dt = dt,
  })
  demand.translateX = (demand.translateX or 0) + assistOut.translateX
  demand.translateZ = (demand.translateZ or 0) + assistOut.translateZ
  if assistOut.allowPrecision then demand.allowPrecision = true end

  -- ---- envelope: always wins, and reports what it clipped
  local limited, clipped = self.envelope:apply(demand)
  if #clipped > 0 then
    self.state:set("envelope.clipped", clipped)
  else
    self.state:set("envelope.clipped", nil)
  end

  -- ---- inner loop
  local torques = self.attitude:update(limited, measured, dt)

  -- ---- outer loop, at its own slower rate
  self.altitudeAccumulator = self.altitudeAccumulator + dt
  local altitudePeriod = 1 / self.cfg.tuning.altitudeHz
  if self.altitudeAccumulator >= altitudePeriod or self.lastAltitudeOut == nil then
    local target = {}
    if limited.verticalSpeed ~= nil then
      target.verticalSpeed = limited.verticalSpeed
    else
      target.altitude = limited.altitudeTarget
    end
    self.lastAltitudeOut = self.altitude:update(target, measured, self.altitudeAccumulator)
    self.altitudeAccumulator = 0
  end

  -- ---- mix and actuate
  local commands = self.mixer:mix({
    collective = self.lastAltitudeOut.collective,
    verticalTrim = self.lastAltitudeOut.verticalTrim,
    pitchTorque = torques.pitchTorque,
    rollTorque = torques.rollTorque,
    yawTorque = torques.yawTorque,
    translateX = limited.translateX,
    translateZ = limited.translateZ,
    mainThrust = limited.mainThrust,
    allowPrecision = demand.allowPrecision or (self.modes.lateral == "precision"),
  })

  if self.thrusters:isIdentifying() then
    self.thrusters:tickIdentify()
  else
    self.thrusters:apply(commands)
  end

  self:publish(measured, capability, dt, overrun)
  return state
end

--- Push everything a UI or the annunciator could want into the state store.
function App:publish(measured, capability, dt, overrun)
  self.state:setGroup("modes", self.modes:snapshot())
  self.state:set("pilot", self.pilot:snapshot())
  self.state:set("oscillation", self.osc:status())
  self.state:set("cycle.dt", dt)
  self.state:set("cycle.overrun", overrun)
  self.state:set("cycles", self.cycles)

  local trim = select(1, self.altitude:learnedTrim())
  self.state:set("control.hoverTrim", trim)
  self.state:set("control.trimAuthority", self.altitude.trimAuthority)

  -- envelope violations are for annunciation, not control
  local violations = self.envelope:violations({
    pitch = measured.pitch, roll = measured.roll,
    verticalSpeed = measured.verticalSpeed, altitude = measured.altitude,
  })
  self.state:set("envelope.violations", violations)
  if #violations > 0 then
    local worst = violations[1]
    for _, v in ipairs(violations) do
      if v.level == "warning" then worst = v break end
    end
    self.state:raise("envelope", worst.level, ("%s %.1f (limit %.1f)")
      :format(worst.key, worst.value, worst.limit))
  else
    self.state:clear("envelope")
  end

  self.engine:publish()

  -- fuel, gauges and thruster readback are not needed every cycle
  if self.cycles % 10 == 0 then
    self.thrusters:readback()
    local _, aggregate = self.fuel:readAll()

    local level = Fuel.level(aggregate.worstFraction)
    if level == "warning" or level == "caution" then
      self.state:raise("fuel", level, ("thruster fuel %.0f%% (%s)")
        :format((aggregate.worstFraction or 0) * 100, tostring(aggregate.worstId)))
    else
      self.state:clear("fuel")
    end

    -- The craft's own tank: separate from the per-thruster reading, because a full thruster
    -- and an empty supply tank are very different situations.
    local tankLevel = Fuel.level(aggregate.worstTank)
    if aggregate.worstTank ~= nil and (tankLevel == "warning" or tankLevel == "caution") then
      self.state:raise("tank", tankLevel, ("%s %.0f%%")
        :format(tostring(aggregate.worstTankLabel or "tank"), aggregate.worstTank * 100))
    else
      self.state:clear("tank")
    end

    -- An empty engine vault means the pumps are about to stop, whatever the tanks say.
    if aggregate.vaultEmpty then
      self.state:raise("vault", "caution", "engine fuel vault is empty")
    else
      self.state:clear("vault")
    end

    -- Airborne with the engine off: the pumps are not running, so the thrusters are living on
    -- whatever is already in their lines.
    if self.cfg.engine.warnWhenOffAirborne and self.engine:available()
      and not self.engine.master and not measured.groundContact then
      self.state:raise("engineOff", "warning", "engine master OFF while airborne")
    else
      self.state:clear("engineOff")
    end
  end

  if self.cycles % 100 == 0 then self.disk:status() end

  -- Publish last, so a UI always sees the state the loop just acted on rather than a
  -- half-updated one. Rate-limited internally to telemetryHz.
  self.telemetry:publish(os.epoch("utc"))

  -- Persist the learned hover trim occasionally, so the next boot starts near equilibrium
  -- instead of hunting for it.
  if self.cycles % 600 == 0 then
    if math.abs(trim - self.trimAtLastSave) > 0.02 then
      self.cfg.control.altitude.hoverTrim = trim
      local saved, err = Config.save(self.configPath, self.cfg)
      if saved then
        self.trimAtLastSave = trim
        self.log:info("hover trim %.3f persisted", trim)
      else
        self.log:warn("could not persist hover trim: %s", tostring(err))
      end
    end
  end
end

-- ---------------------------------------------------------------- commands

--- Apply a validated command from a UI computer.
---
--- Telemetry has already whitelisted the name and type-checked the fields, so this is about
--- what the vehicle does, not about whether the message is well formed. Returns ok, detail.
function App:handleCommand(cmd)
  local now = os.epoch("utc")

  if cmd.cmd == "ping" then
    return true, { pong = true, role = "flight", cycles = self.cycles }

  elseif cmd.cmd == "engineMaster" then
    self.engine:setMaster(cmd.value, now)
    return true, { master = self.engine.master }

  elseif cmd.cmd == "engineFeed" then
    local ok, err = self.engine:feedNow(now)
    return ok, { error = err }

  elseif cmd.cmd == "setAux" then
    local ok, err = self.relays:setAux(cmd.label, cmd.value)
    return ok, { error = err }

  elseif cmd.cmd == "setFeel" then
    return self.modes:setFeel(cmd.value), { feel = self.modes.feel }

  elseif cmd.cmd == "setLateral" then
    return self.modes:setLateral(cmd.value), { lateral = self.modes.lateral }

  elseif cmd.cmd == "setAssist" then
    self.modes:setAssist(cmd.value)
    return true, { assist = self.modes.assistEnabled }

  elseif cmd.cmd == "setAltitude" then
    -- through the envelope, like every other demand: a UI cannot command an altitude the
    -- envelope forbids
    local limited = self.envelope:apply({ altitudeTarget = cmd.value })
    self.modes.altitudeTarget = limited.altitudeTarget
    return true, { altitudeTarget = self.modes.altitudeTarget }

  elseif cmd.cmd == "identify" then
    -- Gated on actually being on the ground, not on the sender's say-so.
    local allowed = (self.state.mode == "GROUND")
    local ok, err = self.thrusters:startIdentify(cmd.id, { allowed = allowed })
    return ok, { error = err }

  elseif cmd.cmd == "configSet" then
    local ok, errors, previous = Config.set(self.cfg, cmd.path, cmd.value)
    if not ok then
      self.log:warn("configSet %s rejected: %s", tostring(cmd.path),
        table.concat(errors or {}, "; "))
      return false, { errors = errors }
    end
    self:applyConfig()
    self.log:info("configSet %s: %s -> %s", cmd.path, tostring(previous), tostring(cmd.value))
    return true, { path = cmd.path, value = cmd.value, previous = previous }

  elseif cmd.cmd == "configSave" then
    local ok, err = Config.save(self.configPath, self.cfg)
    return ok, { error = err }

  elseif cmd.cmd == "diskSave" then
    local ok, report = self:saveConfigsToDisk()
    return ok, report

  elseif cmd.cmd == "diskLoad" then
    local ok, report = self:loadConfigsFromDisk()
    return ok, report
  end

  return false, { error = "unhandled command: " .. tostring(cmd.cmd) }
end

--- Push a changed config into the live modules. Most of them hold `cfg` by reference and so
--- see edits immediately; the PIDs and rate limiters need telling.
function App:applyConfig()
  self.attitude:applyGains(self.cfg)
  self.altitude:applyGains(self.cfg)
  self.brake:applyGains(self.cfg)
  self.assist:applyGains(self.cfg)
  self.modes:applyConfig(self.cfg)
  self.pilot:applyConfig(self.cfg)
  self.engine:applyConfig(self.cfg)
  self.mixer.cfg = self.cfg
  self.mixer:build()
  self.state:set("config.appliedAt", os.epoch("utc"))
end

--- Handle one rednet message. Returns true when it was ours.
function App:onMessage(sender, message, protocol)
  if protocol ~= self.cfg.comms.commandProtocol then return false end
  local cmd, err = self.telemetry:parseCommand(message, sender, os.epoch("utc"))
  if not cmd then
    self.telemetry:reply(sender, { ack = false, error = err })
    return true
  end
  local ok, detail = self:handleCommand(cmd)
  self.telemetry:reply(sender, { ack = ok, cmd = cmd.cmd, detail = detail })
  return true
end

-- ---------------------------------------------------------------- disk

--- Save every config on this computer to a floppy. Exposed so the UI and the terminal menu
--- share one implementation.
function App:saveConfigsToDisk()
  return self.disk:saveAll()
end

function App:loadConfigsFromDisk()
  local ok, report = self.disk:loadAll()
  if ok and #report.loaded > 0 then
    self.log:warn("configs loaded from disk; reboot to apply")
    self.state:raise("configReload", "caution", "configs loaded from disk -- reboot to apply")
  end
  return ok, report
end

-- ---------------------------------------------------------------- event loop

function App:onPeripheralChange(event, name)
  if not self.per:onEvent(event, name) then return false end
  self.thrusters:invalidate()
  self.mixer:build()
  self.altitude:reset(true)
  self.attitude:reset()
  self.brake:reset()
  self.assist:reset()
  -- A relay that came back may have lost its output, so re-assert the funnel state rather
  -- than trusting our cached belief about it.
  self.engine:invalidate()
  self.engine:tick(os.epoch("utc"))
  self.disk:status()
  self.log:warn("hardware changed: loops reset, engine output re-asserted")
  return true
end

function App:run()
  self:boot()
  self.running = true
  local period = 1 / self.cfg.tuning.attitudeHz
  local timer = os.startTimer(period)
  self.lastCycleAt = os.epoch("utc")

  while self.running do
    local event, p1, p2, p3 = os.pullEvent()
    if event == "timer" and p1 == timer then
      local now = os.epoch("utc")
      local dt = (now - (self.lastCycleAt or now)) / 1000
      self.lastCycleAt = now
      local ok, err = pcall(function() self:cycle(dt) end)
      if not ok then
        -- A crash in the loop must not leave thrust commanded at whatever it was mid-update.
        self.log:error("cycle error: %s", tostring(err))
        pcall(function() self.thrusters:neutralVectors() end)
        self.state:raise("cycle", "warning", "control cycle error: " .. tostring(err))
      end
      timer = os.startTimer(period)
    elseif event == "peripheral" or event == "peripheral_detach" then
      self:onPeripheralChange(event, p1)
    elseif event == "rednet_message" then
      -- p1 is the sender; pullEvent gave us only two values above, so re-read them
      local sender, message, protocol = p1, p2, p3
      pcall(function() self:onMessage(sender, message, protocol) end)
    elseif event == "disk" or event == "disk_eject" then
      self.per:scan()
      self.disk:status()
    elseif event == "terminate" then
      self.log:warn("terminate received")
      self.running = false
    end
  end

  -- On the way out: nozzles neutral and the funnel blocked. There is no hardware thrust
  -- failsafe (docs/WIRING.md), so land before stopping this program.
  self.log:info("shutting down: nozzles neutral, engine funnel blocked")
  pcall(function() self.thrusters:neutralVectors() end)
  pcall(function() self.engine:blockNow() end)
end

function App:stop()
  self.running = false
end

return App
