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
local Mixer = require("lib.control.mixer")
local Attitude = require("lib.control.attitude")
local Altitude = require("lib.control.altitude")
local Envelope = require("lib.control.envelope")
local Oscillation = require("lib.control.oscillation")
local Assist = require("lib.control.assist")
local Brake = require("lib.control.brake")
local Modes = require("lib.modes")
local Pilot = require("lib.input.pilot")

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

  self.envelope = Envelope.new(cfg)
  self.osc = Oscillation.new(cfg, self.log)
  self.mixer = Mixer.new(cfg, self.per)
  self.attitude = Attitude.new(cfg, self.log, self.osc)
  self.altitude = Altitude.new(cfg, self.log, self.osc, { steps = 15 })
  self.assist = Assist.new(cfg, self.log)
  self.brake = Brake.new(cfg, self.envelope, self.log)
  self.modes = Modes.new(cfg, self.log)
  self.pilot = Pilot.new(cfg, self.log)

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

  -- Hardware failsafe FIRST, before anything can command thrust. A relay holds its output
  -- when its computer dies, so this level is already standing by if we are ever gone.
  local ok, report = self.relays:applyDerivedFailsafe(Config)
  if not ok then
    self.log:error("FAILSAFE NOT ARMED: %s", tostring(report.reason or "verification failed"))
    self.state:raise("failsafe", "warning", "failsafe not armed")
  else
    self.state:clear("failsafe")
  end

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
  self.attitude:setMode(self.modes:attitudeMode())

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

  -- fuel and thruster readback are not needed every cycle
  if self.cycles % 10 == 0 then
    self.thrusters:readback()
    local _, aggregate = self.fuel:read()
    local level = require("lib.io.fuel").level(aggregate.worstFraction)
    if level == "warning" or level == "caution" then
      self.state:raise("fuel", level, ("lift fuel %.0f%% (%s)")
        :format((aggregate.worstFraction or 0) * 100, tostring(aggregate.worstId)))
    else
      self.state:clear("fuel")
    end
  end

  -- Persist the learned hover trim occasionally, and re-derive the failsafe level from it.
  -- This is what closes the loop on the hardware failsafe actually being the right number.
  if self.cycles % 600 == 0 then
    if math.abs(trim - self.trimAtLastSave) > 0.02 then
      self.cfg.control.altitude.hoverTrim = trim
      local saved, err = Config.save(self.configPath, self.cfg)
      if saved then
        self.trimAtLastSave = trim
        self.log:info("hover trim %.3f persisted; re-deriving failsafe level", trim)
        self.relays:applyDerivedFailsafe(Config)
      else
        self.log:warn("could not persist hover trim: %s", tostring(err))
      end
    end
  end
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
  self.relays:applyDerivedFailsafe(Config)
  self.log:warn("hardware changed: loops reset and failsafe re-armed")
  return true
end

function App:run()
  self:boot()
  self.running = true
  local period = 1 / self.cfg.tuning.attitudeHz
  local timer = os.startTimer(period)
  self.lastCycleAt = os.epoch("utc")

  while self.running do
    local event, p1 = os.pullEvent()
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
    elseif event == "terminate" then
      self.log:warn("terminate received")
      self.running = false
    end
  end

  -- On the way out, leave the craft in the hands of the hardware failsafe.
  self.log:info("shutting down: nozzles neutral, failsafe holds")
  pcall(function() self.thrusters:neutralVectors() end)
end

function App:stop()
  self.running = false
end

return App
