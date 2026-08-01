--[[ Configuration: defaults, backward-additive merge, validation, persistence.

     Backward-additive is the rule (DriveByWire v5 lesson): an old config file must load
     and silently gain any new fields. So nothing reads the file directly -- everything
     goes through withDefaults(), which merges the file over a FRESH default tree.

     Lists are replaced wholesale rather than merged (see Util.deepMerge), so each entry
     of hardware.thrusters / hardware.relays is then merged over its own template. That
     is how a thruster entry written months ago picks up a field added today.
]]

local Util = require("lib.util")

local Config = {}

local THRUST_AXES = { down = true, up = true, forward = true, back = true, left = true, right = true }
local GROUPS = { lift = true, main = true, lateral = true }
local FEEL_MODES = { cruise = true, rate = true, stutter = true }
local AXES = { x = true, y = true, z = true }
--- Where an optical sensor points. "down" is the radar altimeter; the rest are proximity.
local OPTICAL_DIRECTIONS =
  { down = true, forward = true, back = true, left = true, right = true }
Config.OPTICAL_DIRECTIONS = OPTICAL_DIRECTIONS

--- The slot key a thruster fills, as the config screens address it.
---
--- Ids used to carry their group ("lift_fl"); the screens address the bare corner ("fl"),
--- because the group is already the page you are on. Rather than RENAME existing ids -- the
--- mixer addresses thrusters by id, so a rename reaches much further than a display fix -- both
--- spellings resolve to the same slot. An old craft therefore shows its four lift thrusters on
--- the LIFT page without anything on disk changing.
function Config.slotKey(thruster)
  local id, group = thruster.id, thruster.group
  if type(id) ~= "string" or type(group) ~= "string" then return id end
  return id:match("^" .. group .. "_(.+)$") or id
end

--- A single thruster's defaults. Every configured thruster is merged over this.
local function thrusterTemplate()
  return {
    id = "",              -- stable logical id; the mixer and UI address this, never the peripheral name
    peripheral = "",      -- wired-modem peripheral name; changes when the network is rebuilt
    -- "lift"    = down-facing, vectored: lift/hover/pitch/roll AND braking
    -- "main"    = main forward thrust for high speed
    -- "lateral" = yaw and translation (see the two flags below)
    group = "lift",
    -- lateral only: does this thruster contribute to yaw?
    yawAuthority = false,
    -- lateral only: idle in normal flight, used ONLY in Precision mode or by the
    -- Flight Assistant. This is the rear pair.
    precisionOnly = false,
    -- Geometry in the CRAFT frame, blocks from the centre of mass.
    -- x = right, y = up, z = forward. Used for moment arms -- signs matter.
    pos = { x = 0, y = 0, z = 0 },
    -- WHERE THE THRUSTER FACES -- the direction its exhaust goes, which is how you describe
    -- the craft when you look at it: lift faces "down", accelerators "back", laterals "left"
    -- or "right". THE FORCE IS THE OPPOSITE (exhaust down pushes the craft up); the mixer
    -- negates it once, in build(). See docs/CONTROL_LAWS.md.
    thrustAxis = "down",
    -- How the nozzle's own X/Y map onto craft axes for this mounting.
    vectorMap = { x = "x", y = "z" },
    invertVectorX = false,
    invertVectorY = false,
    maxVector = 0.6,      -- deflection authority limit, 0..1
    enabled = true,
  }
end

local function relayTemplate()
  return {
    peripheral = "",
    side = "top",     -- NB: a redstone relay's "face" is its BACK (DriveByWire v6)
    level = 0,        -- analog level, for an aux output that wants one
    purpose = "aux",  -- "aux" only; the "failsafe" purpose was scrapped
    label = "",
  }
end

function Config.defaults()
  return {
    version = 2,

    hardware = {
      thrusterTemplate = thrusterTemplate(),
      relayTemplate = relayTemplate(),
      -- Empty by default: the layout is the pilot's, and a guessed layout is worse
      -- than none. Populated by the config UI or the identify flow.
      thrusters = {},
      relays = {},
      sensors = {
        -- peripheral names; "" means "auto-pick the first of that type"
        altitude = "",
        gimbal = "",
        velocity = "",          -- scalar speed (legacy / single-sensor installs)
        -- A velocity VECTOR assembled from several sensors, each mapped to a craft axis.
        -- Required for drift damping and for the brake law -- see docs/MODES.md section 6.
        -- e.g. { { peripheral = "velocity_sensor_0", axis = "z" },
        --        { peripheral = "velocity_sensor_1", axis = "x", invert = true } }
        velocityVector = {},
        navTable = "",
        -- Optical (laser) sensors, each pointed at a named direction:
        --   down = the radar altimeter, forward/back/left/right = proximity rays.
        -- e.g. { { peripheral = "optical_sensor_0", direction = "down" }, ... }
        -- A bare string is accepted for configs written before directions existed; the first
        -- one becomes "down" (the old convention) and the rest are left unassigned.
        optical = {},
      },
      inputs = {
        controller = "",
        typewriter = "",
      },
      -- Fluid gauges. Create's fluid tanks answer the generic `fluid_storage` methods, so
      -- tanks() gives amount and (usually) capacity. When the mod does not report a
      -- capacity, set capacityMb so the gauge has a scale.
      tanks = {
        -- { peripheral = "", label = "Main fuel", capacityMb = 0 }
      },
      -- Item gauges: the vault feeding the portable engine, so the cockpit can see how much
      -- engine fuel is left. `item` filters to one id; blank counts everything.
      vaults = {
        -- { peripheral = "", label = "Engine fuel", item = "" }
      },
      -- The relay whose output gates the funnel above the portable engine.
      engine = { relay = "", side = "top" },
    },

    -- Portable-engine master control.
    --
    -- The funnel above the engine passes items only while it is UNPOWERED, so the signal is
    -- inverted by nature: holding it HIGH blocks the funnel, and dropping it briefly lets
    -- exactly one item through. Therefore:
    --
    --   master OFF -> signal held HIGH forever (funnel blocked, engine starves, vehicle off)
    --   master ON  -> one immediate interrupt pulse to kickstart, then a periodic interrupt
    --                 to feed one more item and keep the engine alive
    --
    -- Set `invert = true` if your wiring is the other way round (signal LOW blocks).
    engine = {
      enabled = false,      -- turns on once hardware.engine.relay is set
      pulseMs = 400,        -- how long the signal drops -- long enough for ONE item
      -- Gap between interrupt pulses. THIS MUST ROUGHLY MATCH THE BURN TIME OF ONE FUEL UNIT.
      -- Feed faster and the engine hoards a whole stack, which means it keeps running for over
      -- an hour after the master switch goes off and burns the lot whether or not the craft
      -- needs it. Matched to the burn time it takes only what it needs, and a shutdown costs
      -- at most one unit. Blaze cake is minutes, hence the range up to a full hour.
      intervalMs = 60000,   -- 1 minute
      kickstart = true,     -- pulse immediately when the master switch goes on
      masterDefault = false,-- the vehicle boots OFF, as a vehicle should
      invert = false,       -- flip if HIGH lets items through on your build
      warnWhenOffAirborne = true,
    },

    -- Sensor normalisation. Every raw read passes through here, so a probe surprise
    -- is a config change rather than a code change.
    sensors = {
      gimbal = {
        pitchIndex = 1, rollIndex = 2, yawIndex = 0, -- 0 = not provided by this sensor
        pitchInvert = false, rollInvert = false, yawInvert = false,
        scale = 1.0,        -- multiply raw -> degrees
        filterAlpha = 0.35, -- first-order LPF on attitude
      },
      altitude = {
        offset = 0.0,       -- added to getHeight() to reach world Y, if needed
        filterAlpha = 0.30,
        -- vertical speed is DIFFERENTIATED from altitude (velocity_sensor is scalar
        -- and gives no sign), so it needs its own, heavier filter
        vsFilterAlpha = 0.20,
      },
      velocity = {
        scale = 1.0,
        filterAlpha = 0.30,
        -- getVelocity() is SIGNED along the sensor's axis -- VERIFIED from source: it is the
        -- dot of craft velocity onto the sensor's facing normal (+ along it, - against), with
        -- a ~0.05 m/s deadband. See docs/MOD_API_RESEARCH.md. Left configurable only so an
        -- oddly-behaving install can degrade the assistant rather than push the wrong way.
        signed = true,
        -- Readings whose magnitude is <= this are the sensor's own deadband reporting 0, not a
        -- true zero -- a within-deadband response counts as "no movement seen".
        deadband = 0.05,
      },
      optical = {
        maxRange = 32.0,
        filterAlpha = 0.50,
        -- blocks a pad may be made of; autoland refuses anything else
        padWhitelist = { "minecraft:stone", "minecraft:smooth_stone", "minecraft:iron_block" },
      },
      staleMs = 500,        -- a channel older than this is not trusted
      -- ON THE GROUND when the down-facing laser reads within this many blocks of a surface. With
      -- roughly one block of clearance under a landed craft the laser reads ~1, so 2.0 leaves margin
      -- for the exact reading while still flagging airborne once the craft is well clear. Tune this
      -- to your own hull: lower it if the craft reads "grounded" while hovering low.
      groundContactDist = 2.0,
      -- DEPRECATED: ground contact no longer uses vertical speed (differentiated baro jittered and
      -- made a still, landed craft read as airborne). Kept so older configs still load.
      groundVsEpsilon = 0.15,
    },

    tuning = {
      attitudeHz = 20,     -- inner loop
      altitudeHz = 5,      -- outer loop: must stay <= attitudeHz/3
      inputHz = 20,
      telemetryHz = 5,      -- UI/NAV redraw at ~5 Hz; sending faster only floods their event queues
      dtMinMs = 20,
      dtMaxMs = 250,       -- beyond this the cycle is treated as a stall
      -- write-on-change thresholds: what the thruster module considers "moved"
      vectorDeadband = 0.01,
      -- Thrust steps are 1/15 apart. This threshold trades step dithering against how much
      -- residual the continuous toe trim has to absorb: the residual can reach
      -- max(threshold, 0.5) steps, and toe must be able to cover that or altitude gains a
      -- small steady-state ripple. Config validation checks the relationship.
      thrustHysteresisSteps = 0.5,
      thrustHoldSamples = 2,
      -- Issue the cycle's mainThread peripheral calls (sensor reads, thruster writes) CONCURRENTLY
      -- via parallel.waitForAll instead of one-at-a-time. Each such call yields for a server tick,
      -- so in series a dozen of them cost a dozen ticks and pin the loop near ~2 Hz; batched, the
      -- server drains them within its per-computer budget in ~one tick. Left as a flag so a craft
      -- whose thrusters misbehave under concurrent writes can fall back to the serial path in flight.
      parallelIO = true,
    },

    control = {
      -- ANGLE mode (Cruise / Stutter): error is degrees. The small integral is what removes
      -- the couple of degrees of residual bank that a pure PD leaves behind -- noticeable
      -- as a slow drift in a vehicle meant to feel composed.
      attitude = {
        pitch = { p = 0.020, i = 0.004, d = 0.006, iClamp = 0.10, dAlpha = 0.30 },
        roll  = { p = 0.020, i = 0.004, d = 0.006, iClamp = 0.10, dAlpha = 0.30 },
        yaw   = { p = 0.015, i = 0.003, d = 0.004, iClamp = 0.10, dAlpha = 0.30 },
      },
      -- RATE mode: error is degrees/second, a different plant inversion entirely, so it
      -- gets its own gains. Holding a constant rate against airframe damping needs steady
      -- torque, which is why the integral matters more here than in angle mode.
      attitudeRate = {
        pitch = { p = 0.030, i = 0.030, d = 0.002, iClamp = 0.30, dAlpha = 0.40 },
        roll  = { p = 0.030, i = 0.030, d = 0.002, iClamp = 0.30, dAlpha = 0.40 },
        yaw   = { p = 0.020, i = 0.020, d = 0.002, iClamp = 0.30, dAlpha = 0.40 },
      },
      altitude = {
        -- outer loop produces a vertical-speed demand...
        pos = { p = 0.40, i = 0.0, d = 0.0, iClamp = 0.5, dAlpha = 0.30 },
        -- ...which this turns into a thrust/vector-trim demand.
        --
        -- NOTE THE SCALE. These gains are in THRUST FRACTION per (block/second), and the
        -- usable band around hover is only a few percent wide -- with a thrust-to-weight
        -- ratio R, hover sits near collective 1/R. Gains an order of magnitude larger slam
        -- the demand to the rails, and at demand 0 the craft is in FREE FALL. Verified in
        -- tests/sim.lua: p = 0.05 holds altitude to ~0.1 blocks; p = 0.24 diverges.
        rate = { p = 0.050, i = 0.008, d = 0.004, iClamp = 0.20, dAlpha = 0.25 },
        -- Floor on commanded collective while airborne. The sim found that a saturating
        -- rate loop can command zero thrust, which is not "descend" -- it is free fall.
        -- Descent authority is plenty below this; the envelope limits sink rate anyway.
        minAirborneCollective = 0.20,
        hoverTrim = 0.0,   -- LEARNED and persisted; 0 = never learned yet
        -- TAKEOFF. Until the craft has hovered, hoverTrim is 0 and the rate loop's authority
        -- (p*err + iClamp ~= 0.5) tops out below the thrust a heavy craft needs to leave the ground,
        -- so a climb command would sit at partial thrust forever. On the ground with a climb
        -- commanded, the collective ramps open-loop toward full at this rate (per second) until the
        -- craft is airborne, then the rate loop takes over.
        takeoffRamp = 0.5,
        -- Pilot vertical authority. The rate loop's gains are tiny (gentle altitude hold), so on
        -- their own a climb/descend command barely moves a craft whose hover sits near full thrust.
        -- While the pilot is actively commanding a vertical speed, the collective is fed forward by
        -- up to this fraction (full sink -> -this, full climb -> +this), so descent and climb have
        -- real, immediate authority. Zero the instant the stick is released (altitude hold).
        verticalAuthority = 0.6,
        trimLearnRate = 0.002,
        -- ANTI-PIN. A craft held above its target by a mooring rope reads as "settled" but is not
        -- hovering, so the learner above cannot correct the over-thrust. When holding, sitting more
        -- than trimUnstickBand blocks above the target while sinking slower than trimUnstickStill,
        -- bleed the hover trim down at trimUnstickRate (fraction/second) until the craft can descend.
        trimUnstickBand = 0.5,
        trimUnstickStill = 0.20,
        trimUnstickRate = 0.05,
        trimUnstickDwell = 1.0,   -- seconds the pin must persist before the bleed starts
        -- share of vertical authority given to symmetric nozzle trim (the continuous
        -- axis) rather than the 16-step thrust axis
        vectorTrimAuthority = 0.15,
      },
      translation = { p = 0.30, i = 0.0, d = 0.05, iClamp = 0.3, dAlpha = 0.30 },

      -- CoM feedforward: a steady pitch/roll torque bias that holds the craft LEVEL against an
      -- off-centre centre of mass, so the attitude PID integral does not have to carry it. -1..1
      -- in the same units as the attitude loop's torque output, and applied in both feel modes
      -- because a CoM offset is a physical bias, not a mode. Captured ONCE per loading by CoM
      -- LEVELING; a fresh craft (comTrim 0) simply flies on the integral as before.
      comTrim = { pitch = 0.0, roll = 0.0 },
      -- CoM LEVELING watches the running flight loop until the craft is hovering dead level and
      -- still, then folds the steady torque it is holding into comTrim above. The tolerances are
      -- what "settled" means; the craft must stay inside all of them, airborne, for dwellSec before
      -- the reading is trusted. maxTrim caps the captured bias so it can never alone saturate an axis.
      comLevel = {
        angleTolDeg = 1.5,   -- |pitch| and |roll| this close to level
        rateTolDps = 2.0,    -- turning slower than this on both axes
        vsTolMps = 0.3,      -- holding altitude this tightly
        dwellSec = 4.0,      -- for this long, continuously
        maxTrim = 0.5,       -- clamp on the captured feedforward
      },
      oscillation = {
        windowMs = 2000,
        signFlipsToTrip = 8,   -- flips per window that count as oscillation
        gainCutFactor = 0.5,
        minGainScale = 0.25,   -- never cut below this; below it, damp instead
        tripsToDamped = 3,     -- consecutive trips before dropping to DAMPED HOVER
        recoverMs = 5000,      -- quiet time before gains are restored a step
        errorEpsilon = 0.25,   -- errors smaller than this do not count as sign flips
      },
    },

    -- How demands become per-thruster commands. See docs/CONTROL_LAWS.md section 1a --
    -- "toe" is opposed deflection within a pair: continuous lift trim with no net
    -- horizontal force, which is what makes continuous attitude control possible at all.
    mixer = {
      -- Nozzle angle at vector = 1.0. ASSUMED until the probe measures it, and it sets how
      -- much lift toe can actually trim: a toe of `v` costs 1 - cos(v * maxNozzleDeg).
      maxNozzleDeg = 30.0,
      toeBase = 0.30,               -- baseline toe, so vertical trim can go BOTH ways
      toeAuthority = 0.20,          -- extra toe available for attitude trim
      toeShare = 0.6,               -- fraction of attitude demand served continuously by toe;
                                    -- only the excess spills into quantised thrust steps
      differentialAuthority = 0.25, -- ceiling on collective spent as differential thrust
      translateAuthority = 0.6,     -- ceiling on lift-thruster deflection used to translate
      yawAuthority = 0.6,           -- ceiling on lateral thrust spent on yaw
    },

    -- Control feel. See docs/MODES.md -- the asymmetry is deliberate: releasing the
    -- stick levels the craft, it does not stop it.
    modes = {
      default = "cruise",           -- cruise | rate | stutter
      lateralDefault = "flight",    -- flight | precision
      climbRate = 4.0,              -- blocks/s commanded at full climb deflection
      -- Throttle is a SIGNED axis: + = main thrusters forward, 0 = brake, - = reverse.
      -- Decelerating to zero pauses here for this long before reverse engages, so passing
      -- through brake mode is deliberate rather than something you blow past.
      zeroDwellMs = 500,
      brakeTapMs = 250,             -- a brake press shorter than this is a TAP
      reverse = {
        -- Reverse pitches the nose UP so the lift thrusters push the craft backwards.
        -- The angle -- and so the acceleration -- scales with how far past zero you are.
        maxPitchDeg = 12.0,
      },
      flight = {
        -- Bank-to-turn coordination: a fraction of the bank demand is fed to yaw so the
        -- craft turns into the roll like an aircraft rather than sliding sideways.
        turnCoordination = 0.5,
      },
      cruise = {
        angleReturnRate = 60.0,     -- deg/s back to neutral when the stick is released
        thrustHold = true,          -- throttle keeps its level
        thrustAccelRate = 0.25,     -- per second while accelerating
        thrustDecelRate = 0.35,
      },
      rate = {
        maxRateDps = 60.0,          -- full stick deflection = this rotation rate
        thrustHold = true,
        thrustAccelRate = 0.25,
        thrustDecelRate = 0.35,
        forceAssistOff = true,      -- holding an attitude is the point of this mode
      },
      stutter = {
        angleReturnRate = 90.0,
        thrustHold = false,         -- decays to zero on release
        thrustAccelRate = 0.60,     -- deliberately faster than the other modes
        thrustDecayRate = 1.20,
      },
      precision = {
        maxTranslate = 0.8,         -- fraction of lateral authority available directly
        autoOnLanding = true,       -- landing and autoland always use precision
      },
    },

    -- Flight Assistant: drift damping using ALL directional thrusters, including the
    -- rear pair normal flight leaves idle. Needs a velocity VECTOR (docs/MODES.md s6).
    assist = {
      enabled = true,
      driftDeadband = 0.25,     -- blocks/s of lateral drift left alone
      gain = 0.35,
      maxAuthority = 0.6,       -- ceiling on lateral thrust spent damping
      inputSuppressMs = 400,    -- hold-off after any deliberate input
      requireVelocityVector = true, -- degrade + annunciate rather than guess a direction
    },

    -- Braking by tilting the lift thrusters into the direction of motion.
    brake = {
      maxTiltDeg = 12.0,        -- hard cap: never command an attitude the loop can't hold calmly
      speedForFullTilt = 8.0,   -- blocks/s at which maxTilt is reached
      minSpeed = 0.4,           -- below this, no braking at all -- no twitching
      tiltRateDps = 25.0,       -- rate limit on tilting in
      holdPosition = true,      -- brake mode also holds position once stopped
    },

    envelope = {
      maxBankDeg = 20.0,
      maxPitchDeg = 20.0,
      maxYawRateDps = 45.0,
      maxClimbRate = 6.0,      -- blocks/s
      maxSinkRate = 4.0,
      altFloor = 0.0,          -- world Y; hard floor regardless of route
      altCeil = 300.0,
      maxGroundSpeed = 12.0,
    },

    -- The HARDWARE failsafe -- a relay per lift thruster holding an open-loop hover thrust
    -- level -- was SCRAPPED 2026-07-26. One relay plus cabling and a modem per thruster cost
    -- too much space and weight for something that, with wired-only controls, should never
    -- fire. The accepted consequence is recorded in docs/WIRING.md: if the flight computer is
    -- destroyed, unloaded or rebooted in flight, the thrusters revert to redstone control,
    -- see no signal, and the craft falls. What remains is the software reference below.
    failsafe = {
      -- Degraded-hold altitude: where the loop holds when it is alive but has lost inputs or
      -- nav. nil = adopt the first altitude read at boot.
      holdAltitude = nil,
    },

    input = {
      source = "auto",         -- "auto" | "controller" | "typewriter" | "both"
      controller = {
        deadzone = 0.08,
        expo = 0.25,           -- 0 = linear; keeps fine authority near centre
        fullPrecision = true,  -- MUST be set: the default sends coarse values
        -- action = axis index 1..6. A NEGATIVE index means the axis is inverted.
        axes = { roll = 1, pitch = 2, climb = 3, yaw = 4, accel = 5 },
        -- action = button index 1..15
        buttons = {
          brake = 1, cycleFeel = 2, toggleLateral = 3, toggleAssist = 4,
          gear = 5, lights = 6, engineMaster = 7,
        },
      },
      typewriter = {
        -- Every action is remappable. Values are `keys.*` names, resolved at load.
        -- REMINDER: a key must be bound to a frequency ON THE TYPEWRITER, or it reports
        -- nothing at all -- and the peripheral only offers polling, no events.
        bindings = {
          pitchUp = "s", pitchDown = "w",
          rollLeft = "a", rollRight = "d",
          yawLeft = "q", yawRight = "e",
          climb = "space", descend = "leftShift",
          accelerate = "r", decelerate = "f",
          brake = "b",
          cycleFeel = "m", toggleLateral = "n", toggleAssist = "h",
          gear = "g", lights = "l", engineMaster = "z",
        },
        rate = 2.0,            -- how fast a held key ramps its axis, per second
        centreRate = 3.0,      -- how fast an axis returns to centre when released
      },
    },

    comms = {
      -- Blank = auto-pick the first WIRED modem. Never a wireless one: the control surface
      -- must not be on the air (docs/WIRING.md).
      modem = "",
      telemetryProtocol = "eh_telemetry",
      commandProtocol = "eh_command",
      configProtocol = "eh_config",
      navFixProtocol = "eh_navfix",
      commandRateLimit = 20,   -- messages/second accepted before dropping
      ender = {
        enabled = false,
        modem = "",
        key = "",              -- pre-shared; telemetry OUT only, never commands
        maxSkew = 5000,
      },
    },

    nav = {
      -- phase 11+. Listed now so the schema is stable.
      positionSources = { "gps", "radar" },
      fixStaleMs = 1500,
      gpsTimeout = 1.0,
    },

    log = { level = "info", capacity = 200, path = nil },
  }
end

--- Merge a loaded table over fresh defaults, then normalise list entries.
function Config.withDefaults(loaded)
  local cfg = Util.deepMerge(Config.defaults(), loaded or {})

  local tTemplate = cfg.hardware.thrusterTemplate or thrusterTemplate()
  for i, entry in ipairs(cfg.hardware.thrusters or {}) do
    cfg.hardware.thrusters[i] = Util.deepMerge(tTemplate, entry)
  end

  local rTemplate = cfg.hardware.relayTemplate or relayTemplate()
  for i, entry in ipairs(cfg.hardware.relays or {}) do
    cfg.hardware.relays[i] = Util.deepMerge(rTemplate, entry)
  end

  -- Optical sensors used to be a plain list of names with "index 1 is the altimeter" as the
  -- only convention. Normalise to { peripheral, direction } so the UI can address them by
  -- where they point, and honour the old convention for a config written before that.
  local optical = cfg.hardware.sensors.optical or {}
  for i, entry in ipairs(optical) do
    if type(entry) == "string" then
      optical[i] = { peripheral = entry, direction = (i == 1) and "down" or "" }
    else
      entry.peripheral = entry.peripheral or ""
      entry.direction = entry.direction or ((i == 1) and "down" or "")
    end
  end

  Config.migrate(cfg)
  return cfg
end

--- Bring a config saved by an OLDER release inside the current limits.
---
--- Configs are only ever extended, never replaced -- but a tightened limit can leave a value
--- that was legal when it was written and is not any more, and validate() would then refuse to
--- start the craft over a setting the pilot never chose. Clamping the one offending field keeps
--- everything else the pilot set, which is the whole point of the extend-only rule.
---
--- Returns the list of changes, so the caller can say what it did rather than change the
--- vehicle's behaviour silently.
function Config.migrate(cfg)
  local changes = {}

  local engine = cfg.engine
  if type(engine) == "table" and type(engine.intervalMs) == "number" then
    -- The feed interval used to allow 200 ms. It must now match a fuel unit's burn time, so
    -- the floor is 15 s -- see the comment on the default.
    if engine.intervalMs < 15000 then
      changes[#changes + 1] = ("engine.intervalMs %d -> 15000 (below the new minimum)")
        :format(engine.intervalMs)
      engine.intervalMs = 15000
    elseif engine.intervalMs > 3600000 then
      changes[#changes + 1] = ("engine.intervalMs %d -> 3600000 (above the new maximum)")
        :format(engine.intervalMs)
      engine.intervalMs = 3600000
    end
  end

  -- v2: the control loop used to be capped near 1 Hz by a mainThread-timer bug, so telemetryHz = 10
  -- was never actually reached. With that fixed the loop genuinely sends ~10 Hz, which floods the UI
  -- and NAV computers and drops their clicks. 5 Hz matches the UI's render rate. One-time and
  -- version-gated, so a pilot who deliberately raises it after the upgrade keeps their choice.
  if (cfg.version or 1) < 2 then
    if type(cfg.tuning) == "table" and cfg.tuning.telemetryHz == 10 then
      changes[#changes + 1] = "tuning.telemetryHz 10 -> 5 (10 Hz floods the UI now the loop runs at rate)"
      cfg.tuning.telemetryHz = 5
    end
    cfg.version = 2
  end
  return changes
end

--- Structural validation. Returns ok, errors, warnings.
-- Errors block startup. Warnings are things that are legal but probably not intended.
function Config.validate(cfg)
  local errors, warnings = {}, {}
  local function err(fmt, ...) errors[#errors + 1] = string.format(fmt, ...) end
  local function warn(fmt, ...) warnings[#warnings + 1] = string.format(fmt, ...) end

  local function num(v, path, lo, hi)
    if type(v) ~= "number" then
      err("%s must be a number (got %s)", path, type(v))
      return false
    end
    if lo and v < lo then err("%s must be >= %s (got %s)", path, lo, v) return false end
    if hi and v > hi then err("%s must be <= %s (got %s)", path, hi, v) return false end
    return true
  end

  -- tuning
  num(cfg.tuning.attitudeHz, "tuning.attitudeHz", 1, 40)
  num(cfg.tuning.altitudeHz, "tuning.altitudeHz", 1, 40)
  num(cfg.tuning.inputHz, "tuning.inputHz", 1, 40)
  if type(cfg.tuning.attitudeHz) == "number" and type(cfg.tuning.altitudeHz) == "number" then
    if cfg.tuning.altitudeHz * 3 > cfg.tuning.attitudeHz then
      err("tuning.altitudeHz (%s) must be <= attitudeHz/3 (%s) -- cascade loops need rate separation",
        cfg.tuning.altitudeHz, cfg.tuning.attitudeHz / 3)
    end
  end
  num(cfg.tuning.dtMinMs, "tuning.dtMinMs", 1)
  num(cfg.tuning.dtMaxMs, "tuning.dtMaxMs", 1)
  if type(cfg.tuning.dtMaxMs) == "number" and type(cfg.tuning.dtMinMs) == "number"
    and cfg.tuning.dtMaxMs <= cfg.tuning.dtMinMs then
    err("tuning.dtMaxMs must exceed dtMinMs")
  end
  num(cfg.tuning.vectorDeadband, "tuning.vectorDeadband", 0, 0.5)

  -- envelope
  num(cfg.envelope.maxBankDeg, "envelope.maxBankDeg", 0, 89)
  num(cfg.envelope.maxPitchDeg, "envelope.maxPitchDeg", 0, 89)
  num(cfg.envelope.maxClimbRate, "envelope.maxClimbRate", 0)
  num(cfg.envelope.maxSinkRate, "envelope.maxSinkRate", 0)
  if type(cfg.envelope.altCeil) == "number" and type(cfg.envelope.altFloor) == "number"
    and cfg.envelope.altCeil <= cfg.envelope.altFloor then
    err("envelope.altCeil must be above altFloor")
  end

  -- failsafe (software only; the hardware failsafe was scrapped -- see the defaults above)
  if cfg.failsafe.holdAltitude ~= nil then
    num(cfg.failsafe.holdAltitude, "failsafe.holdAltitude")
  end

  -- sensors
  local g = cfg.sensors.gimbal
  for _, key in ipairs({ "pitchIndex", "rollIndex", "yawIndex" }) do
    local v = g[key]
    if type(v) ~= "number" or v < 0 or v ~= math.floor(v) then
      err("sensors.gimbal.%s must be a non-negative integer (0 = absent)", key)
    end
  end
  if g.pitchIndex == 0 or g.rollIndex == 0 then
    err("sensors.gimbal needs pitchIndex and rollIndex -- attitude control cannot run without them")
  end
  if g.yawIndex == 0 then
    warn("sensors.gimbal.yawIndex is 0: no yaw from the gimbal, so nav needs a heading fallback")
  end
  num(g.filterAlpha, "sensors.gimbal.filterAlpha", 0.01, 1.0)
  num(cfg.sensors.altitude.filterAlpha, "sensors.altitude.filterAlpha", 0.01, 1.0)
  num(cfg.sensors.altitude.vsFilterAlpha, "sensors.altitude.vsFilterAlpha", 0.01, 1.0)

  -- modes
  if not FEEL_MODES[cfg.modes.default] then
    err("modes.default must be cruise|rate|stutter (got %s)", tostring(cfg.modes.default))
  end
  if cfg.modes.lateralDefault ~= "flight" and cfg.modes.lateralDefault ~= "precision" then
    err("modes.lateralDefault must be flight|precision (got %s)", tostring(cfg.modes.lateralDefault))
  end
  num(cfg.modes.cruise.angleReturnRate, "modes.cruise.angleReturnRate", 0)
  num(cfg.modes.rate.maxRateDps, "modes.rate.maxRateDps", 0)
  num(cfg.modes.stutter.thrustAccelRate, "modes.stutter.thrustAccelRate", 0)
  if type(cfg.modes.stutter.thrustAccelRate) == "number"
    and type(cfg.modes.cruise.thrustAccelRate) == "number"
    and cfg.modes.stutter.thrustAccelRate <= cfg.modes.cruise.thrustAccelRate then
    warn("modes.stutter.thrustAccelRate should exceed cruise's -- stutter is meant to ramp faster")
  end
  num(cfg.modes.precision.maxTranslate, "modes.precision.maxTranslate", 0, 1)

  -- mixer
  num(cfg.mixer.toeBase, "mixer.toeBase", 0, 0.5)
  num(cfg.mixer.toeAuthority, "mixer.toeAuthority", 0, 1)
  num(cfg.mixer.toeShare, "mixer.toeShare", 0.05, 1.0)
  num(cfg.mixer.differentialAuthority, "mixer.differentialAuthority", 0, 1)
  num(cfg.mixer.translateAuthority, "mixer.translateAuthority", 0, 1)
  num(cfg.mixer.yawAuthority, "mixer.yawAuthority", 0, 1)
  num(cfg.mixer.maxNozzleDeg, "mixer.maxNozzleDeg", 1, 90)

  -- The load-bearing relationship: can the continuous toe trim absorb what the 16-step
  -- quantiser leaves behind? If not, altitude gains a small steady-state ripple. This is
  -- physics, not a bug, and it depends on mixer.maxNozzleDeg -- which is a GUESS until the
  -- probe measures it, so this is a warning rather than an error.
  if type(cfg.mixer.maxNozzleDeg) == "number" and type(cfg.mixer.toeBase) == "number" then
    local authority = Config.derivedTrimAuthority(cfg)
    local residual = Config.residualBound(cfg)
    if authority < residual then
      warn(("toe trim can move %.1f%% of thrust but the quantiser can leave %.1f%% behind: "
        .. "expect a small altitude ripple. Raise mixer.toeBase, lower "
        .. "tuning.thrustHysteresisSteps, or correct mixer.maxNozzleDeg after the probe.")
        :format(authority * 100, residual * 100))
    end
  end

  if type(cfg.mixer.toeBase) == "number" and type(cfg.mixer.toeAuthority) == "number" then
    local peak = cfg.mixer.toeBase * 2 + cfg.mixer.toeAuthority
    for _, t in ipairs(cfg.hardware.thrusters or {}) do
      if t.group == "lift" and type(t.maxVector) == "number" and peak > t.maxVector then
        warn("thruster %s: maxVector %.2f is below the peak toe demand %.2f -- toe will clip "
          .. "and attitude trim will lose authority", tostring(t.id), t.maxVector, peak)
        break
      end
    end
  end

  -- CoM feedforward + leveling
  local ct = cfg.control.comTrim
  if type(ct) == "table" then
    num(ct.pitch, "control.comTrim.pitch", -1, 1)
    num(ct.roll, "control.comTrim.roll", -1, 1)
  end
  local cl = cfg.control.comLevel
  if type(cl) == "table" then
    num(cl.angleTolDeg, "control.comLevel.angleTolDeg", 0)
    num(cl.rateTolDps, "control.comLevel.rateTolDps", 0)
    num(cl.vsTolMps, "control.comLevel.vsTolMps", 0)
    num(cl.dwellSec, "control.comLevel.dwellSec", 0)
    num(cl.maxTrim, "control.comLevel.maxTrim", 0, 1)
  end

  -- engine
  num(cfg.engine.pulseMs, "engine.pulseMs", 50, 5000)
  num(cfg.engine.intervalMs, "engine.intervalMs", 15000, 3600000)
  if type(cfg.engine.pulseMs) == "number" and type(cfg.engine.intervalMs) == "number"
    and cfg.engine.pulseMs >= cfg.engine.intervalMs then
    err("engine.pulseMs (%s) must be shorter than engine.intervalMs (%s), or the funnel would "
      .. "never be blocked", cfg.engine.pulseMs, cfg.engine.intervalMs)
  end
  if cfg.engine.enabled and (cfg.hardware.engine.relay == "" or cfg.hardware.engine.relay == nil) then
    err("engine.enabled is set but hardware.engine.relay names no peripheral")
  end
  if (cfg.hardware.engine.relay or "") ~= "" and not cfg.engine.enabled then
    warn("an engine relay is configured but engine.enabled is false -- the master switch will do nothing")
  end

  -- gauges
  for i, tank in ipairs(cfg.hardware.tanks or {}) do
    if type(tank.peripheral) ~= "string" or tank.peripheral == "" then
      err("hardware.tanks[%d].peripheral is required", i)
    end
  end
  for i, vault in ipairs(cfg.hardware.vaults or {}) do
    if type(vault.peripheral) ~= "string" or vault.peripheral == "" then
      err("hardware.vaults[%d].peripheral is required", i)
    end
  end

  -- assist + brake
  num(cfg.assist.driftDeadband, "assist.driftDeadband", 0)
  num(cfg.assist.gain, "assist.gain", 0)
  num(cfg.assist.maxAuthority, "assist.maxAuthority", 0, 1)
  num(cfg.brake.maxTiltDeg, "brake.maxTiltDeg", 0, 45)
  num(cfg.brake.speedForFullTilt, "brake.speedForFullTilt", 0.1)
  num(cfg.brake.minSpeed, "brake.minSpeed", 0)
  num(cfg.brake.tiltRateDps, "brake.tiltRateDps", 0.1)
  if type(cfg.brake.maxTiltDeg) == "number" and type(cfg.envelope.maxPitchDeg) == "number"
    and cfg.brake.maxTiltDeg > cfg.envelope.maxPitchDeg then
    err("brake.maxTiltDeg (%s) exceeds envelope.maxPitchDeg (%s) -- the envelope must always win",
      cfg.brake.maxTiltDeg, cfg.envelope.maxPitchDeg)
  end

  -- velocity vector: needed by drift damping and the brake law
  local axesSeen = {}
  for i, entry in ipairs(cfg.hardware.sensors.velocityVector or {}) do
    local where = ("hardware.sensors.velocityVector[%d]"):format(i)
    if type(entry.peripheral) ~= "string" or entry.peripheral == "" then
      err("%s.peripheral is required", where)
    end
    if not AXES[entry.axis] then
      err("%s.axis must be x|y|z (got %s)", where, tostring(entry.axis))
    elseif axesSeen[entry.axis] then
      err("%s: axis %s is already mapped", where, entry.axis)
    else
      axesSeen[entry.axis] = true
    end
  end
  if not (axesSeen.x and axesSeen.z) then
    warn("no horizontal velocity vector configured (need axes x and z): "
      .. "the flight assistant and the brake law will degrade -- see docs/MODES.md section 6")
  end

  -- optical sensors: one direction each, at most one per direction
  local dirSeen = {}
  for i, entry in ipairs(cfg.hardware.sensors.optical or {}) do
    local where = ("hardware.sensors.optical[%d]"):format(i)
    if type(entry.peripheral) ~= "string" or entry.peripheral == "" then
      err("%s.peripheral is required", where)
    end
    local dir = entry.direction
    if dir ~= nil and dir ~= "" then
      if not OPTICAL_DIRECTIONS[dir] then
        err("%s.direction must be down|forward|back|left|right (got %s)", where, tostring(dir))
      elseif dirSeen[dir] then
        err("%s: direction %s is already taken", where, dir)
      else
        dirSeen[dir] = true
      end
    end
  end

  -- thrusters
  local seenId, seenPeripheral, lift, lateral = {}, {}, 0, 0
  local main, yawCapable, precisionOnly = 0, 0, 0
  for i, t in ipairs(cfg.hardware.thrusters or {}) do
    local where = ("hardware.thrusters[%d]"):format(i)
    if type(t.id) ~= "string" or t.id == "" then
      err("%s.id is required", where)
    elseif seenId[t.id] then
      err("%s.id '%s' is duplicated", where, t.id)
    else
      seenId[t.id] = true
    end
    if type(t.peripheral) ~= "string" or t.peripheral == "" then
      err("%s.peripheral is required (id '%s')", where, tostring(t.id))
    elseif seenPeripheral[t.peripheral] then
      -- One nozzle, two slots: the mixer would command it twice with different values and
      -- fight itself. Physically impossible, so it is an error rather than a warning.
      err("%s: %s is already assigned to '%s'", where, t.peripheral, seenPeripheral[t.peripheral])
    else
      seenPeripheral[t.peripheral] = t.id
    end
    if not GROUPS[t.group] then
      err("%s.group must be lift|main|lateral (got %s)", where, tostring(t.group))
    elseif t.group == "lift" then
      lift = lift + 1
    elseif t.group == "main" then
      main = main + 1
    else
      lateral = lateral + 1
      if t.yawAuthority then yawCapable = yawCapable + 1 end
      if t.precisionOnly then precisionOnly = precisionOnly + 1 end
    end
    if t.group ~= "lateral" and (t.yawAuthority or t.precisionOnly) then
      warn("%s: yawAuthority/precisionOnly only apply to lateral thrusters", where)
    end
    if not THRUST_AXES[t.thrustAxis] then
      err("%s.thrustAxis is invalid: %s", where, tostring(t.thrustAxis))
    end
    for _, ax in ipairs({ "x", "y", "z" }) do
      if type(t.pos[ax]) ~= "number" then err("%s.pos.%s must be a number", where, ax) end
    end
    num(t.maxVector, where .. ".maxVector", 0, 1)
  end
  if #(cfg.hardware.thrusters or {}) == 0 then
    warn("no thrusters configured -- run the identify flow before flight")
  elseif lift == 0 then
    err("at least one lift thruster is required")
  elseif lift < 3 then
    warn("only %d lift thruster(s): pitch, roll and braking authority will be limited", lift)
  end
  if #(cfg.hardware.thrusters or {}) > 0 then
    if main == 0 then
      warn("no main thruster: high-speed forward flight is unavailable")
    end
    if lateral > 0 and yawCapable == 0 then
      warn("no lateral thruster has yawAuthority: yaw control will be unavailable")
    end
    if precisionOnly > 0 and lateral == precisionOnly then
      warn("every lateral thruster is precisionOnly: normal flight has no lateral authority at all")
    end
  end

  -- typewriter bindings: a name that `keys` does not know is a control that will silently do
  -- nothing, so refuse it here rather than let it become a runtime "problem".
  for action, keyName in pairs(cfg.input.typewriter.bindings or {}) do
    if type(keyName) ~= "string" then
      err("input.typewriter.bindings.%s must be a key name string", tostring(action))
    elseif keyName ~= "" and type(keys) == "table" and type(keys[keyName]) ~= "number" then
      err("input.typewriter.bindings.%s: '%s' is not a key name", tostring(action), keyName)
    end
  end

  -- relays
  for i, r in ipairs(cfg.hardware.relays or {}) do
    local where = ("hardware.relays[%d]"):format(i)
    if type(r.peripheral) ~= "string" or r.peripheral == "" then
      err("%s.peripheral is required", where)
    end
    if type(r.side) ~= "string" or r.side == "" then err("%s.side is required", where) end
    if type(r.level) ~= "number" or r.level < 0 or r.level > 15 then
      err("%s.level must be 0..15", where)
    end
  end
  return #errors == 0, errors, warnings
end

function Config.load(path)
  if not fs.exists(path) then
    return Config.withDefaults({}), false
  end
  local f = fs.open(path, "r")
  if not f then return Config.withDefaults({}), false end
  local text = f.readAll()
  f.close()
  local ok, parsed = pcall(textutils.unserialise, text)
  if not ok or type(parsed) ~= "table" then
    return Config.withDefaults({}), false, "config file is not a valid table"
  end
  return Config.withDefaults(parsed), true
end

function Config.save(path, cfg)
  local ok, text = pcall(textutils.serialise, cfg)
  if not ok then return false, "could not serialise config" end
  local f = fs.open(path, "w")
  if not f then return false, "could not open " .. tostring(path) end
  f.write(text)
  f.close()
  -- verify readback: a half-written config is worse than none
  local reread = fs.open(path, "r")
  if not reread then return false, "could not reopen for verify" end
  local back = reread.readAll()
  reread.close()
  if back ~= text then return false, "verify readback mismatch" end
  return true
end

--- How much lift the toe trim can ACTUALLY move, as a fraction of thrust.
--
-- A corner thruster toes on BOTH axes at once (x for pitch pairs, z for roll pairs), and
-- the vertical component is cos(ax) * cos(az). So the lift lost at full toe is 1 - cos^2,
-- not 1 - cos. Getting this wrong is not harmless: the altitude loop divides the
-- quantisation residual by this number, so UNDER-estimating it makes the trim
-- over-correct and ring. We therefore use the two-axis (larger) figure, which biases the
-- estimate in the safe direction -- over-estimating merely makes trim sluggish.
--
-- The true value depends on mixer.maxNozzleDeg, which is a guess until the probe measures
-- it, and on the layout. Treat this as a starting point to calibrate, not as truth.
function Config.derivedTrimAuthority(cfg)
  local m = cfg.mixer
  local peakToe = math.min(2 * (m.toeBase or 0), 1.0)
  local rad = math.rad(peakToe * (m.maxNozzleDeg or 30))
  local cos = math.cos(rad)
  return 1 - cos * cos
end

--- The largest residual the quantiser can leave behind, as a fraction of thrust.
function Config.residualBound(cfg)
  return math.max(cfg.tuning.thrustHysteresisSteps or 0.5, 0.5) / 15
end


-- ---------------------------------------------------------------- paths

--- Split a dotted config path. Numeric segments become array indices, so
--- "hardware.thrusters.1.maxVector" addresses the first thruster's authority limit.
local function splitPath(path)
  local parts = {}
  for segment in tostring(path):gmatch("[^.]+") do
    parts[#parts + 1] = tonumber(segment) or segment
  end
  return parts
end

--- Read a value by dotted path. Returns nil (and no error) for a path that does not exist.
function Config.get(cfg, path)
  local node = cfg
  for _, key in ipairs(splitPath(path)) do
    if type(node) ~= "table" then return nil end
    node = node[key]
  end
  return node
end

--- Write a value by dotted path, then re-validate.
---
--- If the result would not validate, the old value is PUT BACK and the errors are returned. A
--- UI that can talk the flight computer into an invalid config is a UI that can ground the
--- craft, so the config is never left in a state validate() rejects.
---
--- Refuses to create new keys, and refuses to change a value's type: a typo'd path is a
--- mistake, not a new setting.
function Config.set(cfg, path, value)
  local parts = splitPath(path)
  if #parts == 0 then return false, { "empty path" } end

  local node = cfg
  for i = 1, #parts - 1 do
    local key = parts[i]
    if type(node[key]) ~= "table" then
      return false, { ("no such config path: %s"):format(tostring(path)) }
    end
    node = node[key]
  end

  local last = parts[#parts]
  local previous = node[last]
  if previous == nil then
    return false, { ("no such config key: %s"):format(tostring(path)) }
  end
  if type(previous) ~= type(value) then
    return false, { ("%s expects a %s, got %s"):format(tostring(path), type(previous), type(value)) }
  end

  node[last] = value
  local ok, errors = Config.validate(cfg)
  if not ok then
    node[last] = previous
    return false, errors
  end
  return true, nil, previous
end

return Config
