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
local SelfTest = require("lib.control.selftest")
local SelfConfig = require("lib.control.selfconfig")
local AxisMap = require("lib.control.axismap")
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
  self.selfTest = SelfTest.new(self.thrusters, self.per, cfg, self.log, self.state)
  self.selfConfig = SelfConfig.new(self.thrusters, self.per, cfg, self.log, self.state)
  self.axisMap = AxisMap.new(self.thrusters, self.per, cfg, self.log, self.state)
  -- A remap changes the mixer's matrix, so it must be rebuilt and saved the moment it happens.
  self.axisMap.onAssigned = function()
    self.thrusters:invalidate()
    self.mixer:build()
    self:publishThrusterAxes()
  -- The hardware set moved, so push the slow half of the payload out at once rather than letting
  -- the screens wait up to a second for it.
  if self.telemetry and self.telemetry.markSlowDirty then self.telemetry:markSlowDirty() end
    Config.save(self.configPath, self.cfg)
  end

  self.altitudeAccumulator = 0
  self.lastCycleAt = nil
  self.cycles = 0
  self.trimAtLastSave = self.cfg.control.altitude.hoverTrim or 0
  self.running = false
  return self
end

-- ---------------------------------------------------------------- boot

function App:boot()
  -- SAID FIRST, before anything else can go wrong. Lua loads at boot, so this is the record as it
  -- stood when THIS code was loaded -- if it lags the release, the files updated and this computer
  -- was never restarted, and nothing else in the log means what it appears to.
  do
    local okInstall, Install = pcall(require, "shared.install")
    if okInstall and Install then
      local record = Install.read()
      self.log:info("EasyHover %s build %s (installed %s)", tostring(record.role),
        tostring(record.version), tostring(record.at or "?"))
    end
  end
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

  -- PUBLISH THE THRUSTER AXIS MAP AT BOOT. It was only ever published on a remap (onAssigned),
  -- inside rebuildHardware, or in setAxes -- never on a plain start. So a craft booted with a
  -- saved config had `thrusterAxes` nil in its telemetry, and the AXIS MAP and THR AXES screens
  -- read "no thrusters assigned" until the pilot happened to re-pick a slot. The thrusters were
  -- assigned, listed and swept correctly the whole time; only this one publish was missing.
  self:publishThrusterAxes()

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
  self.state:set("candidates", self.per:candidates())

  return self.configValid
end

-- ---------------------------------------------------------------- one cycle

--- Is the craft POSITIVELY KNOWN to be off the ground?
---
--- Only a down-facing laser can answer that, and it is one of the LAST things a pilot assigns --
--- so `groundContact` is nil on exactly the craft that needs the pre-flight screens most.
---
--- THE FLIGHT MODE IS NOT A SUBSTITUTE. With no ground sensor and no altitude sensor the mode
--- machine settles on BRAKE, which every "is it airborne" list counts as flying. Gating the sweep
--- on that produced a refusal the pilot could not satisfy from either end: they cannot make the
--- mode GROUND without fitting the laser, and they cannot stop the thrust because this computer is
--- the thing commanding it. A previous version of this gate also enumerated FLIGHT/HOVER/REVERSE
--- and silently omitted BRAKE, DAMPED and FAILSAFE -- so the list was both too strict and too
--- lax, which is what a proxy for a measurement usually is.
---
--- So refuse only on POSITIVE EVIDENCE: `groundContact == false` is a sensor saying we are up.
--- nil is not evidence, it is the absence of a sensor -- and the pilot, who is standing next to
--- the craft reading GROUND ONLY on the screen, is a better authority than a guess.
function App:knownAirborne()
  local measured = self.state:get("measured") or {}
  return measured.groundContact == false
end

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
  -- While a nozzle is latched for mapping, the pilot's keys are NAMING a direction, not flying.
  -- Leaving them live would have a/d/s/w roll and pitch the craft while someone stands next to
  -- it reading nozzle angles.
  if self.axisMap:isHolding() then
    axes = { pitch = 0, roll = 0, yaw = 0, climb = 0, accel = 0 }
    held = {}
    edges = {}
  end
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

  -- ---- WHO OWNS THE THRUSTERS?
  --
  -- Asked BEFORE the DAMPED/FAILSAFE return below, and that ordering is the whole point.
  --
  -- A pre-flight sweep owns the thrusters exclusively while it runs, and it has to be serviced in
  -- ANY flight state -- FAILSAFE above all. FAILSAFE means "sensors unhealthy", which is exactly
  -- where a half-configured craft sits: the gimbal and the laser are not assigned yet, because
  -- assigning them is what the pilot is in the middle of doing. That is precisely when the sweep
  -- is needed, and it was precisely when it could not run.
  --
  -- With this branch below the early return, a craft in FAILSAFE never ticked its sweep. The run
  -- could therefore never finish, so every later START was refused with "a self test is already
  -- running" -- for ever -- while neutralVectors() re-centred the nozzles on every single cycle,
  -- cancelling any deflection the sweep managed to command. Nothing moved, nothing could be
  -- started, and nothing said why.
  --
  -- Applying the mixer's commands as well would have the attitude loop fighting the sweep for the
  -- same nozzles: both spoils the test and is the one thing this vehicle must never do. So an
  -- owner returns early, and the mixer does not run at all.
  -- WHICH ARM DID WE TAKE? Logged once a second whenever anything claims to own the thrusters,
  -- because the console shows the mixer writing nozzles (a mix of lift and lateral ids, which
  -- only the mixer produces -- the sweep does one group at a time) while handleCommand insists a
  -- sweep is running. Both cannot be true of the same object, and nothing so far distinguishes
  -- them. This line names the arm, from inside the branch, once per second.
  --   axisMap / selfTest / selfConfig / identify   a tool has taken exclusive control (handled
  --                                    ABOVE the DAMPED/FAILSAFE return, so it runs in any state)
  --   disarmed                        NOT FLYING: engine off, or on the ground and not commanded to
  --                                    take off. The controller must not steer, and NOTHING fires.
  --   mixer                           the real closed-loop flight controller (the PID) -- runs ONLY
  --                                    when actually flying
  --
  -- WHEN MAY THE MIXER RUN? Only when the craft is ACTUALLY FLYING. Engine ON is NOT flying:
  -- starting the pump so the thrusters CAN make thrust is a separate act from committing to flight.
  -- Before this, the owner fell straight from "engine on" to "mixer", so the PID began steering a
  -- parked craft the instant the engine started -- thrusters firing on the pad with no takeoff ever
  -- commanded. Now the craft is DISARMED (neutral nozzles, zero thrust, loops reset, nothing fires)
  -- unless the engine is on AND either it is POSITIVELY airborne (the down laser says it is off the
  -- ground) OR the pilot is giving a climb input (a deliberate takeoff). On the ground with no climb
  -- command, the mixer never runs and no thruster fires.
  --
  -- POSITIVE evidence only, and from the RAW channel. `ground.contact` is true | false | nil, where
  -- false means the laser SAYS we are off the ground and nil means no/unassigned laser -> UNKNOWN.
  -- The local `measured.groundContact` above coerces nil -> false, so it CANNOT be used here: it
  -- would read a missing laser as "airborne" and fire on the pad. A craft that cannot see the ground
  -- stays disarmed until a climb input rather than being assumed in flight.
  -- FLIGHT CONTROL must be ENGAGED by the pilot first (modes:isArmed) -- a master switch, OFF at
  -- boot. Then, and only then, the mixer runs when actually flying. So the full gate is: engaged AND
  -- engine on AND (airborne OR climb). Disengaged, the craft is disarmed no matter what the engine,
  -- sensors or stick say -- which is what makes preflight provably safe.
  local flightInput = (axes.climb or 0) > 0.02
  local flying = self.modes:isArmed() and self.engine.master
    and ((self.state:get("ground.contact") == false) or flightInput)
  local owner = (self.axisMap:isHolding() and "axisMap")
    or (self.selfTest:isRunning() and "selfTest")
    or (self.selfConfig:isRunning() and "selfConfig")
    or (self.thrusters:isIdentifying() and "identify")
    or ((not flying) and "disarmed")
    or "mixer"
  -- Log on every CHANGE (unmissable), and a slow heartbeat while a non-mixer owner holds so the
  -- console proves the loop is alive without burying everything else. 3 s filled the screen in half
  -- a minute; 30 s is a heartbeat, not a flood.
  if self._lastOwner ~= owner then
    self.log:info("cycle owner: %s (state %s)", owner, tostring(state))
    self._ownerLoggedAt = now
  elseif owner ~= "mixer" and (now - (self._ownerLoggedAt or 0)) >= 30000 then
    self.log:info("cycle owner: %s (state %s)", owner, tostring(state))
    self._ownerLoggedAt = now
  end
  self._lastOwner = owner

  -- Publish the arbitration so the cockpit can explain a SILENT-BUT-ENGAGED craft. Flipping ENGAGE
  -- is not the same as firing: the mixer still holds until the engine is on AND the craft is either
  -- airborne or being commanded to climb. Without this the pilot sees "ENGAGED" and a dead throttle
  -- with no reason -- the reported symptom. `hold` is WHY the mixer is not actuating (nil when it
  -- actually is); it is only meaningful when no preflight owner has the thrusters.
  local hold
  if owner == "disarmed" then
    if not self.modes:isArmed() then
      hold = "DISENGAGED"
    elseif not self.engine.master then
      hold = "ENGINE OFF"
    else
      -- Armed and the engine is running, but parked and no climb command: the pad-safety gate. The
      -- craft is READY; a climb input lifts it off. Nothing is wrong -- it just will not fire itself.
      hold = "ON GROUND"
    end
  end
  self.state:set("flight.owner", owner)
  self.state:set("flight.hold", hold)

  local activelyFlying = (state == "FLIGHT" or state == "HOVER" or state == "REVERSE")
  if owner == "axisMap" then
    if activelyFlying then
      self.axisMap:release("the craft is flying")
    else
      self.axisMap:tick(now, (self.state:get("pilot") or {}).pressedCodes)
    end
    self:publish(measured, capability, dt, overrun)
    return state
  elseif owner == "selfTest" then
    -- Only ACTIVE flight aborts. DAMPED and FAILSAFE are not flight -- they are a craft whose
    -- sensors this test exists to help set up.
    if activelyFlying then
      self.selfTest:abort("aborted: the craft is flying")
    else
      self.selfTest:tick(now)
    end
    self:publish(measured, capability, dt, overrun)
    return state
  elseif owner == "selfConfig" then
    -- The BIP DELIBERATELY FLIES the craft -- a deflected nozzle only reads if it is making thrust
    -- and the craft is light on its ropes. So there is no activelyFlying abort here as there is for
    -- the self test: its own safety envelope (tilt, height, runaway speed, engine-off) is what stops
    -- it, checked inside tick every cycle. It owns thrust AND nozzles at the raw level, which is why
    -- it must run above the mixer -- two writers on the same nozzles is the one thing to never do.
    -- Build the BIP's context from the cycle's FLAT `measured` (altitude is the baro NUMBER, and
    -- pitch/roll/yaw sit directly on it -- there is no `.attitude`/`.velocity`/`.altitude.baro`).
    -- The velocity VECTOR, including its vertical (y) component, comes straight from state.
    self.selfConfig:tick({
      now = now,
      attitude = { pitch = measured.pitch, roll = measured.roll, yaw = measured.yaw },
      velocity = {
        x = self.state:get("velocity.x"),
        y = self.state:get("velocity.y"),
        z = self.state:get("velocity.z"),
      },
      altitude = measured.altitude,
      groundContact = measured.groundContact,
      engineOn = self.engine.master and true or false,
    })
    self:publish(measured, capability, dt, overrun)
    return state
  elseif owner == "identify" then
    self.thrusters:tickIdentify()
    self:publish(measured, capability, dt, overrun)
    return state
  elseif owner == "disarmed" then
    -- DISARMED. The funnel is blocked and no thrust can be produced, so there is nothing to
    -- balance -- yet the attitude and altitude PIDs still turn sensor noise into nozzle angles and
    -- write them every cycle. On the craft that is a nozzle twitching continuously while parked,
    -- others frozen at odd angles, and integrators winding UP against a vehicle that cannot
    -- respond -- so the instant the engine came on, the controller would lunge.
    --
    -- Hold every nozzle at neutral, cut thrust, and reset the loops so they resume clean when
    -- armed. allStop is cheap after the first cycle (the block already holds zero, so nothing is
    -- re-written). The pre-flight sweep and the axis map are unaffected: they are owners above,
    -- and both require the engine off anyway.
    self.thrusters:allStop()
    self.attitude:reset()
    self.altitude:reset()
    self.assist:reset()
    self:publish(measured, capability, dt, overrun)
    return state
  end

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

  self.thrusters:apply(commands)

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

  if self.cycles % 100 == 0 then
    self.disk:status()
    -- What the pilot could assign. Cheap, but not free, so not every cycle.
    self.state:set("candidates", self.per:candidates())
  end

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
--- Where each named thruster slot sits, in the CRAFT frame (x = right, y = up, z = forward).
---
--- The config screens ask "which peripheral is the front-left lift thruster", not "what are its
--- coordinates" -- but the mixer needs a moment arm, and a thruster at 0,0,0 produces no pitch
--- or roll at all. THE SIGNS ARE WHAT MATTER: they decide which way the craft rotates when a
--- corner pushes harder. The magnitudes are a sane unit default and can be tuned in the config
--- file for an unusual frame; they scale gains, they do not change stability.
local SLOT_GEOMETRY = {
  lift = {
    fl = { pos = { x = -1, y = 0, z =  1 }, thrustAxis = "down" },
    fr = { pos = { x =  1, y = 0, z =  1 }, thrustAxis = "down" },
    rl = { pos = { x = -1, y = 0, z = -1 }, thrustAxis = "down" },
    rr = { pos = { x =  1, y = 0, z = -1 }, thrustAxis = "down" },
  },
  main = {
    -- FACES backward, so the force is forward -- which is what accelerates the craft. Mounted
    -- in a block, so they carry no roll authority and their lateral offset is deliberately zero.
    ["1"] = { pos = { x = 0, y = 0, z = -1 }, thrustAxis = "back" },
    ["2"] = { pos = { x = 0, y = 0, z = -1 }, thrustAxis = "back" },
    ["3"] = { pos = { x = 0, y = 0, z = -1 }, thrustAxis = "back" },
    ["4"] = { pos = { x = 0, y = 0, z = -1 }, thrustAxis = "back" },
  },
  lateral = {
    -- FACING, not force: a left-side thruster faces right and therefore pushes the craft LEFT.
    -- Front pair steers (yaw); the rear pair idles in normal flight and is used only by
    -- Precision mode and the Flight Assistant -- see docs/MODES.md.
    fl = { pos = { x = -1, y = 0, z =  1 }, thrustAxis = "right", yawAuthority = true },
    fr = { pos = { x =  1, y = 0, z =  1 }, thrustAxis = "left",  yawAuthority = true },
    rl = { pos = { x = -1, y = 0, z = -1 }, thrustAxis = "right", precisionOnly = true },
    rr = { pos = { x =  1, y = 0, z = -1 }, thrustAxis = "left",  precisionOnly = true },
  },
}

App.SLOT_GEOMETRY = SLOT_GEOMETRY

--- Beyond the named slots, each group accepts a SECOND set of boosters -- so a craft that one
--- ring of nozzles cannot lift can take another.
---
--- Why they exist: raw lift (or forward thrust) is just a sum -- if four nozzles cannot get the
--- craft off the ground, the fix is more nozzles, not a redesign.
---
--- Crucially, an extra sits at the SAME PLACE as its primary counterpart, not at the centre. A
--- "x"-prefixed key resolves to the identical geometry -- moment arm, facing and flags -- as the
--- corner it doubles ("xfl" == "fl"). That is what lets the config screen label a booster by
--- position ("FL2") instead of an anonymous number: a second thruster bolted at the front-left
--- doubles the front-left's lift AND its pitch/roll authority, exactly as a pilot expects. The
--- main group has no corners, so its extras are simply more accelerators (x1..x4 -> M5..M8).
local EXTRA_GEOMETRY = {
  lift = {
    xfl = SLOT_GEOMETRY.lift.fl, xfr = SLOT_GEOMETRY.lift.fr,
    xrl = SLOT_GEOMETRY.lift.rl, xrr = SLOT_GEOMETRY.lift.rr,
  },
  lateral = {
    xfl = SLOT_GEOMETRY.lateral.fl, xfr = SLOT_GEOMETRY.lateral.fr,
    xrl = SLOT_GEOMETRY.lateral.rl, xrr = SLOT_GEOMETRY.lateral.rr,
  },
  main = {
    x1 = SLOT_GEOMETRY.main["1"], x2 = SLOT_GEOMETRY.main["2"],
    x3 = SLOT_GEOMETRY.main["3"], x4 = SLOT_GEOMETRY.main["4"],
  },
}

--- The geometry for an extra booster slot, or nil if `key` is not one. Same shape SLOT_GEOMETRY
--- entries have, so handleSetSlot treats a named corner and its booster identically.
local function extraGeometry(kind, key)
  return (EXTRA_GEOMETRY[kind] or {})[key]
end

App.EXTRA_GEOMETRY = EXTRA_GEOMETRY

--- Assign (or clear) one named hardware slot, then re-validate the WHOLE config and put the
--- previous state back if the result would be illegal. Same contract as setTank/setVault: the
--- craft never ends up in a config it would refuse to boot from.
function App:handleSetSlot(cmd)
  local kind, key, name = cmd.kind, cmd.key, cmd.peripheral
  local sensors = self.cfg.hardware.sensors

  -- Snapshot exactly what this command can touch, so a rollback is exact.
  local snapshot = textutils.serialise({
    thrusters = self.cfg.hardware.thrusters,
    velocityVector = sensors.velocityVector,
    optical = sensors.optical,
    altitude = sensors.altitude,
    gimbal = sensors.gimbal,
  })

  local function restore()
    local back = textutils.unserialise(snapshot)
    self.cfg.hardware.thrusters = back.thrusters
    sensors.velocityVector = back.velocityVector
    sensors.optical = back.optical
    sensors.altitude = back.altitude
    sensors.gimbal = back.gimbal
  end

  --- Remove whichever entry of `list` matches `field == value`.
  local function dropWhere(list, field, value)
    for i = #list, 1, -1 do
      if list[i][field] == value then table.remove(list, i) end
    end
  end

  if kind == "lift" or kind == "main" or kind == "lateral" then
    local geometry = (SLOT_GEOMETRY[kind] or {})[key] or extraGeometry(kind, key)
    if not geometry then return false, { errors = { "unknown " .. kind .. " slot: " .. tostring(key) } } end
    -- Drop whatever already fills this slot under EITHER spelling. Missing the old one would
    -- leave two entries for the same physical thruster, and the mixer would command it twice.
    for i = #self.cfg.hardware.thrusters, 1, -1 do
      local t = self.cfg.hardware.thrusters[i]
      if t.group == kind and Config.slotKey(t) == key then
        table.remove(self.cfg.hardware.thrusters, i)
      end
    end
    if name ~= "" then
      -- A physical thruster can only be in ONE place. Moving it into this slot has to take it
      -- out of whatever slot it was in, or the mixer would command the same nozzle twice with
      -- two different values and fight itself.
      for i = #self.cfg.hardware.thrusters, 1, -1 do
        if self.cfg.hardware.thrusters[i].peripheral == name then
          table.remove(self.cfg.hardware.thrusters, i)
        end
      end
      -- GROUP-QUALIFIED ID. Slot keys are unique only within their group -- "fl" is a corner of
      -- the lift set AND of the lateral set -- but ids are what the mixer addresses thrusters
      -- by, so they must be unique across the whole craft. Config.slotKey strips the prefix
      -- back off to recover the slot, which is also how a pre-existing "lift_fl" still resolves.
      local entry = Util.deepMerge(self.cfg.hardware.thrusterTemplate or {}, {
        id = kind .. "_" .. key, peripheral = name, group = kind,
        pos = geometry.pos, thrustAxis = geometry.thrustAxis,
        yawAuthority = geometry.yawAuthority or false,
        precisionOnly = geometry.precisionOnly or false,
      })
      self.cfg.hardware.thrusters[#self.cfg.hardware.thrusters + 1] = entry
    end

  elseif kind == "velocity" then
    if key ~= "x" and key ~= "y" and key ~= "z" then
      return false, { errors = { "velocity axis must be x, y or z" } }
    end
    dropWhere(sensors.velocityVector, "axis", key)
    if name ~= "" then
      sensors.velocityVector[#sensors.velocityVector + 1] =
        { peripheral = name, axis = key, invert = false }
    end

  elseif kind == "optical" then
    local Config = require("lib.config")
    if not Config.OPTICAL_DIRECTIONS[key] then
      return false, { errors = { "unknown optical direction: " .. tostring(key) } }
    end
    dropWhere(sensors.optical, "direction", key)
    if name ~= "" then
      sensors.optical[#sensors.optical + 1] = { peripheral = name, direction = key }
    end

  elseif kind == "altitude" then
    sensors.altitude = name

  elseif kind == "gimbal" then
    sensors.gimbal = name

  else
    return false, { errors = { "unknown slot kind: " .. tostring(kind) } }
  end

  local ok, errors = Config.validate(self.cfg)
  if not ok then
    restore()
    return false, { errors = errors }
  end

  self:rebuildHardware()
  Config.save(self.configPath, self.cfg)
  self.log:info("slot %s:%s -> %s", tostring(kind), tostring(key),
    name == "" and "(none)" or name)
  return true, { kind = kind, key = key, peripheral = name }
end

--- Re-derive everything that depends on WHICH hardware is attached.
---
--- A rescan alone is not enough and that gap was real: the mixer builds its matrix once, the
--- thruster layer caches what it last wrote, and the layout and velocity capability are
--- published from boot(). Assigning a thruster from the config screen therefore changed the
--- file and nothing else -- the craft flew on its old mixer until someone rebooted it, which
--- is exactly how it was reported from the cockpit.
---
--- Same list as boot() performs, deliberately: if a hardware change needs it at startup, it
--- needs it now.
function App:rebuildHardware()
  self.per:scan()
  self.thrusters:invalidate()
  self.mixer:build()

  local caps = self.mixer:capabilities()
  self.state:set("layout", caps)
  self.state:set("velocity.capability", self.sensors:velocityCapability())
  self.state:set("candidates", self.per:candidates())
  self:publishThrusterAxes()
  -- The hardware set moved, so push the slow half of the payload out at once rather than letting
  -- the screens wait up to a second for it.
  if self.telemetry and self.telemetry.markSlowDirty then self.telemetry:markSlowDirty() end
  return caps
end

--- How each thruster's nozzle axes map onto the craft, for the orientation screen.
---
--- THIS IS THE ONE THING NOTHING CAN WORK OUT FOR ITSELF. The mixer converts a wanted craft
--- force into a nozzle deflection through vectorMap and the invert flags, and those default to
--- the identity. A thruster mounted rotated or mirrored therefore gets pushed the WRONG WAY,
--- and the attitude loop responds by pushing harder -- which is the divergence this whole
--- design exists to avoid. The self test shows you which way each nozzle really moves; this is
--- what you correct it with.
function App:publishThrusterAxes()
  local rows = {}
  for index, t in ipairs(self.cfg.hardware.thrusters or {}) do
    local map = t.vectorMap or {}
    rows[#rows + 1] = {
      index = index,
      id = t.id,
      group = t.group,
      key = Config.slotKey(t),
      -- "swapped" means nozzle X drives the craft's fore/aft axis instead of left/right
      swap = (map.x == "z"),
      invertX = t.invertVectorX and true or false,
      invertY = t.invertVectorY and true or false,
    }
  end
  self.state:set("thrusterAxes", rows)
  return rows
end

--- The go/no-go facts for the SELF AXIS CONFIG BIP, read from the craft's OWN published state so
--- handleCommand (which runs off a rednet message, not inside the cycle) still decides for itself.
function App:selfConfigFacts()
  local worstTank = self.state:get("fuel.worstTank")
  return {
    engineOn = self.engine.master and true or false,
    -- Lenient: block only on a tank that positively reads empty. A craft fed some other way, or
    -- with no tank configured, is not stopped here -- the float phase times out as "WONT LIFT" if
    -- it genuinely cannot make thrust.
    fuelled = not (type(worstTank) == "number" and worstTank <= 0.001),
    onGround = self.state:get("ground.contact"),
    -- The raw down-laser reading and the threshold it is judged against, so a "NOT ON GROUND" on a
    -- craft that IS landed can show WHY -- almost always the physics hull rests with more clearance
    -- than the threshold allows, and the pilot just needs to raise sensors.groundContactDist.
    groundDist = self.state:get("ground.distance"),
    groundThreshold = self.cfg.sensors.groundContactDist,
    velocityVector = self.state:get("velocity.capability"),
    otherBip = self.selfTest:isRunning() or self.axisMap:isHolding()
      or self.thrusters:isIdentifying() or false,
  }
end

--- Apply the BIP's proposed nozzle mappings to config and save -- the same write path as AXIS MAP:
--- mutate the live spec (shared with cfg.hardware.thrusters, see peripherals.lua), rebuild the
--- mixer, republish, and persist. Only ever called on an explicit pilot ACCEPT.
function App:acceptSelfConfig()
  local proposal = self.selfConfig:pendingProposal()
  if not proposal then
    return false, { error = "no proposal to accept", errorShort = "NO PROPOSAL" }
  end
  local applied = 0
  for id, prop in pairs(proposal) do
    local entry = self.per.thrusters[id]
    if entry and entry.spec then
      entry.spec.vectorMap = prop.vectorMap
      entry.spec.invertVectorX = prop.invertVectorX
      entry.spec.invertVectorY = prop.invertVectorY
      applied = applied + 1
    end
  end
  if applied > 0 then
    self.thrusters:invalidate()
    self.mixer:build()
    self:publishThrusterAxes()
    if self.telemetry and self.telemetry.markSlowDirty then self.telemetry:markSlowDirty() end
    Config.save(self.configPath, self.cfg)
    self.selfConfig:discard()           -- consumed; clear it so the screen does not re-offer it
    self.log:info("self config: applied %d nozzle mapping(s) to config", applied)
  end
  return true, { applied = applied }
end

function App:handleCommand(cmd)
  local now = os.epoch("utc")

  if cmd.cmd == "ping" then
    return true, { pong = true, role = "flight", cycles = self.cycles }

  elseif cmd.cmd == "engineMaster" then
    self.engine:setMaster(cmd.value, now)
    return true, { master = self.engine.master }

  elseif cmd.cmd == "setEngineRelay" then
    -- Assign the funnel relay and turn the engine subsystem on in one step: a relay with
    -- engine.enabled still false would look configured and do nothing.
    local previousRelay = self.cfg.hardware.engine.relay
    local previousSide = self.cfg.hardware.engine.side
    local previousEnabled = self.cfg.engine.enabled
    self.cfg.hardware.engine.relay = cmd.peripheral
    self.cfg.hardware.engine.side = cmd.side
    self.cfg.engine.enabled = (cmd.peripheral ~= "")
    local ok, errors = Config.validate(self.cfg)
    if not ok then
      self.cfg.hardware.engine.relay = previousRelay
      self.cfg.hardware.engine.side = previousSide
      self.cfg.engine.enabled = previousEnabled
      return false, { errors = errors }
    end
    self.per:scan()
    self.engine:applyConfig(self.cfg)
    self.engine:blockNow()          -- assert the funnel blocked on the newly assigned relay
    self.engine:publish()
    Config.save(self.configPath, self.cfg)
    self.log:info("engine relay -> %s side %s", cmd.peripheral, cmd.side)
    return true, { relay = cmd.peripheral, side = cmd.side, enabled = self.cfg.engine.enabled }

  elseif cmd.cmd == "setTank" or cmd.cmd == "setVault" then
    local isTank = (cmd.cmd == "setTank")
    local list = isTank and self.cfg.hardware.tanks or self.cfg.hardware.vaults
    local previous = list[1] and {
      peripheral = list[1].peripheral, label = list[1].label,
      capacityMb = list[1].capacityMb, item = list[1].item,
    } or nil

    if cmd.peripheral == "" then
      list[1] = nil
    else
      -- Create the entry if there is not one yet: hardware.tanks starts empty, which is why
      -- these get their own command instead of going through configSet.
      list[1] = list[1] or {}
      list[1].peripheral = cmd.peripheral
      list[1].label = list[1].label or (isTank and "Main fuel" or "Engine fuel")
      if isTank then
        list[1].capacityMb = list[1].capacityMb or 0
      else
        list[1].item = list[1].item or ""
      end
    end

    local ok, errors = Config.validate(self.cfg)
    if not ok then
      list[1] = previous
      return false, { errors = errors }
    end
    self.per:scan()
    self.fuel.kinds = {}            -- the fuel kind is cached per thruster/gauge; re-detect
    self.fuel:readAll()
    Config.save(self.configPath, self.cfg)
    self.log:info("%s -> %s", cmd.cmd, cmd.peripheral == "" and "(none)" or cmd.peripheral)
    return true, { peripheral = cmd.peripheral }

  elseif cmd.cmd == "vectorHold" then
    if cmd.action == "release" then
      return true, { released = self.axisMap:release("by the pilot") }
    end
    -- Same contract as the self test: it moves the same nozzles, so it wants the same silence.
    local allowed = (not self.engine.master)
      and not (self:knownAirborne() and self.selfTest:anyPowered())
    -- One latch at a time, and never while the sweep owns the same nozzles.
    if self.selfTest:isRunning() then
      return false, { error = "the self test is running" }
    end
    if self.axisMap:isHolding() then self.axisMap:release("switching nozzle") end
    local ok, err, short = self.axisMap:latch(cmd.id, cmd.axis, cmd.sign,
      { allowed = allowed, now = now })
    return ok, { error = err, errorShort = short }

  elseif cmd.cmd == "selfTest" then
    if cmd.action == "abort" then
      local aborted = self.selfTest:abort("aborted by the pilot")
      return true, { running = false, aborted = aborted }
    end
    -- Decided HERE rather than by the sender: a UI is not a trusted peer. Two conditions, and
    -- they guard different things:
    --
    --   airborne  a down-facing laser positively reporting no ground contact. Combined with a
    --             real thrust reading by SelfTest:start, because it is being HELD UP BY THRUST
    --             that makes silencing the throttles unsafe. See App:knownAirborne for why the
    --             flight mode is not used here.
    --   engineOn  the engine master feeds the thruster supply, so leaving it on invites thrust to
    --             appear mid-sweep.
    --
    -- Engine master OFF does NOT mean the thrusters are cold: the fuel TANK feeds the liquid
    -- thrusters directly. That is why the sweep zeroes the throttles itself rather than refusing
    -- when it reads thrust -- see SelfTest:start.
    --
    -- errorShort is the 15-column wording. The craft picks both, because a panel that shortens a
    -- refusal by truncation can invert it: "cut the engine first" became "he engine first".
    -- A HELD NOZZLE OUTRANKS THE SWEEP IN App:cycle, so a latch left over from the axis map
    -- would let the sweep start, report RUNNING, and never once be ticked -- the panel counting
    -- down against a craft where nothing moves. There is a guard the other way (vectorHold
    -- refuses while the sweep runs) and this was its missing half. The pilot pressing SELF TEST
    -- is the newer instruction, so the latch gives way to it.
    if self.axisMap:isHolding() then
      self.axisMap:release("starting the self test")
      self.log:info("self test: released a held nozzle first")
    end
    local ok, err, short = self.selfTest:start({
      airborne = self:knownAirborne(),
      engineOn = self.engine.master and true or false, now = now })
    -- SAID OUT LOUD, ON THIS COMPUTER. Every refusal so far has been read off the cockpit panel,
    -- which shows what the last telemetry frame carried -- so a craft whose telemetry has gone
    -- quiet looks exactly like one that is idle, and the pilot ends up arguing with a photograph.
    -- The flight computer's own console cannot be stale.
    if not ok then
      self.log:warn("self test REFUSED: %s", tostring(err))
      self.log:warn("  running=%s  sinceTick=%.1fs  airborne=%s  engineMaster=%s",
        tostring(self.selfTest:isRunning()),
        (self.selfTest.run and (now - (self.selfTest.run.lastTickAt or now)) or 0) / 1000,
        tostring(self:knownAirborne()), tostring(self.engine.master))
    end
    return ok, { error = err, errorShort = short }

  elseif cmd.cmd == "selfConfig" then
    -- The SELF AXIS CONFIG BIP. Actions: checkPrereqs (go/no-go), start, abort, accept (apply the
    -- proposed mapping to config), discard. Policy facts come from the craft's own state, never the
    -- sender -- a UI is not a trusted peer, exactly as with the self test.
    if cmd.action == "checkPrereqs" then
      return true, self.selfConfig:checkPrereqs(self:selfConfigFacts())
    elseif cmd.action == "abort" then
      local aborted = self.selfConfig:abort("aborted by the pilot", "STOPPED")
      return true, { running = false, aborted = aborted }
    elseif cmd.action == "accept" then
      return self:acceptSelfConfig()
    elseif cmd.action == "discard" then
      self.selfConfig:discard()
      return true, { discarded = true }
    else
      -- A held nozzle outranks the BIP in App:cycle, so release one first -- the same missing half
      -- the self test needed, for the same reason: otherwise the BIP starts, is never ticked, and
      -- locks the screen out.
      if self.axisMap:isHolding() then
        self.axisMap:release("starting self config")
      end
      local ok, err, short = self.selfConfig:start(self:selfConfigFacts(), {
        now = now, altitude = self.state:get("altitude.baro") })
      if not ok then self.log:warn("self config REFUSED: %s", tostring(err)) end
      return ok, { error = err, errorShort = short }
    end

  elseif cmd.cmd == "setAxes" then
    local target
    for _, t in ipairs(self.cfg.hardware.thrusters or {}) do
      if t.id == cmd.id then target = t end
    end
    if not target then return false, { errors = { "no such thruster: " .. tostring(cmd.id) } } end
    local previous = {
      vectorMap = { x = (target.vectorMap or {}).x, y = (target.vectorMap or {}).y },
      invertVectorX = target.invertVectorX, invertVectorY = target.invertVectorY,
    }
    target.vectorMap = cmd.swap and { x = "z", y = "x" } or { x = "x", y = "z" }
    target.invertVectorX = cmd.invertX
    target.invertVectorY = cmd.invertY
    local ok, errors = Config.validate(self.cfg)
    if not ok then
      target.vectorMap = previous.vectorMap
      target.invertVectorX = previous.invertVectorX
      target.invertVectorY = previous.invertVectorY
      return false, { errors = errors }
    end
    -- The mixer holds the mapping, so it has to be rebuilt -- the same live-apply rule as
    -- every other hardware change.
    self.thrusters:invalidate()
    self.mixer:build()
    self:publishThrusterAxes()
  -- The hardware set moved, so push the slow half of the payload out at once rather than letting
  -- the screens wait up to a second for it.
  if self.telemetry and self.telemetry.markSlowDirty then self.telemetry:markSlowDirty() end
    Config.save(self.configPath, self.cfg)
    self.log:info("axes %s: swap=%s invX=%s invY=%s", cmd.id, tostring(cmd.swap),
      tostring(cmd.invertX), tostring(cmd.invertY))
    return true, { id = cmd.id }

  elseif cmd.cmd == "setSlot" then
    return self:handleSetSlot(cmd)

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

  elseif cmd.cmd == "flightArm" then
    -- Engage/disengage flight control. Only permits the mixer -- it never fires a thruster on its
    -- own; the flying gate (airborne or climb) still applies, so engaging on the pad stays silent.
    self.modes:setArmed(cmd.value)
    return true, { armed = self.modes:isArmed() }

  elseif cmd.cmd == "setAltitude" then
    -- through the envelope, like every other demand: a UI cannot command an altitude the
    -- envelope forbids
    local limited = self.envelope:apply({ altitudeTarget = cmd.value })
    self.modes.altitudeTarget = limited.altitudeTarget
    return true, { altitudeTarget = self.modes.altitudeTarget }

  elseif cmd.cmd == "identify" then
    -- Gated on the craft, not on the sender's say-so -- but on EVIDENCE of being airborne rather
    -- than on the mode reading GROUND. Same defect as the self test had: with no down-facing laser
    -- the mode machine settles on BRAKE, so `mode == "GROUND"` made the identify sweep unavailable
    -- on precisely the craft being wired up for the first time. See App:knownAirborne.
    local allowed = not (self:knownAirborne() and self.selfTest:anyPowered())
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
  -- A COMMAND THAT THROWS MUST STILL ANSWER. onMessage is pcall'd by the run loop, so an error in
  -- handleCommand was swallowed there: no reply went back, the cockpit showed nothing at all, and
  -- whatever the handler had already changed stayed changed. Press a button, nothing happens,
  -- press it again and the craft says the thing you asked for is already under way -- with the
  -- reason never leaving this computer.
  --
  -- Now it is caught here, reported to the pilot as a refusal, and logged with the message.
  local caught, ok, detail = pcall(self.handleCommand, self, cmd)
  if not caught then
    local message = tostring(ok)
    self.log:error("command %s FAILED: %s", tostring(cmd.cmd), message)
    self.telemetry:reply(sender, { ack = false, cmd = cmd.cmd,
      detail = { error = message, errorShort = "CMD ERROR" } })
    return true
  end
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
  self.state:set("candidates", self.per:candidates())
  self.log:warn("hardware changed: loops reset, engine output re-asserted")
  return true
end

function App:run()
  self:boot()
  self.running = true
  local period = 1 / self.cfg.tuning.attitudeHz
  local timer = os.startTimer(period)
  self.lastCycleAt = os.epoch("utc")

  -- THE CYCLE RUNS ON A DEADLINE, NOT ON ONE IRREPLACEABLE TIMER.
  --
  -- It used to run only inside `event == "timer" and p1 == timer`, and re-arm only there. So the
  -- single outstanding timer was the loop's only heartbeat: lose that one event and the control
  -- cycle NEVER RUNS AGAIN. The computer stays responsive -- rednet is a different branch, so
  -- commands are still answered -- which is exactly the state the craft was in: "self test
  -- started" logged, "already running" on every later press, and not one cycle after it.
  --
  -- And the event was easy to lose. SelfTest:start calls allStop(), which is 12 setVector plus 12
  -- setThrust, every one of them mainThread at a server tick each: about 1.2 s inside a single
  -- rednet handler, with os.pullEvent not being called. The craft reported sinceTick=1.4s.
  --
  -- Now: any event is a chance to notice the deadline has passed, the timer is only a wake-up for
  -- when nothing else is happening, and it is re-armed on every cycle.
  local nextCycleAt = os.epoch("utc")
  while self.running do
    local event, p1, p2, p3 = os.pullEvent()

    local nowMs = os.epoch("utc")
    if nowMs >= nextCycleAt then
      local dt = (nowMs - (self.lastCycleAt or nowMs)) / 1000
      self.lastCycleAt = nowMs
      nextCycleAt = nowMs + period * 1000
      timer = os.startTimer(period)
      local ok, err = pcall(function() self:cycle(dt) end)
      if not ok then
        -- TERMINATE IS NOT A CYCLE ERROR. The setters yield, so Ctrl+T surfaces here as an
        -- ordinary error; catching it made the loop eat the pilot's terminate one press at a
        -- time. Re-raised, so the shell can stop the program on the first press.
        if tostring(err):find("Terminated") then error(err, 0) end
        -- A crash in the loop must not leave thrust commanded at whatever it was mid-update.
        self.log:error("cycle error: %s", tostring(err))
        pcall(function() self.thrusters:neutralVectors() end)
        self.state:raise("cycle", "warning", "control cycle error: " .. tostring(err))
      end
    end

    if event == "peripheral" or event == "peripheral_detach" then
      self:onPeripheralChange(event, p1)
    elseif event == "rednet_message" then
      -- p1 is the sender; pullEvent gave us only two values above, so re-read them
      local sender, message, protocol = p1, p2, p3
      local okMsg, msgErr = pcall(function() self:onMessage(sender, message, protocol) end)
      -- Same rule as the cycle: a terminate is the pilot, not a fault.
      if not okMsg and tostring(msgErr):find("Terminated") then error(msgErr, 0) end
      if not okMsg then self.log:error("message error: %s", tostring(msgErr)) end
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
