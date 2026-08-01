--[[ SELF AXIS CONFIG BIP -- discover each nozzle's craft-frame mapping by MEASURING it.

     The problem this automates is the one AXIS MAP solves by hand: which way does the craft move
     when the software deflects a given nozzle? AXIS MAP answers it by latching one nozzle, walking
     outside, and naming the direction. This does the same thing with sensors instead of eyes.

     WHY IT NEEDS TO FLY. A deflected nozzle only produces a force while the thruster is making
     thrust, and that force only produces measurable motion while the craft is light on its
     constraints. So -- unlike the SELF TEST, which never commands thrust -- this BIP floats the
     craft a little way off the ground (roped, as the pilot secures it) and reads the response. The
     pilot asked for exactly this: "the craft needs to actually take off" to get feedback.

     THE MEASUREMENT. Create: Simulated's velocity sensors are SIGNED (verified from source, see
     docs/MOD_API_RESEARCH.md): each returns the dot of craft velocity onto its facing axis, with a
     ~0.05 m/s deadband. Three of them give a signed craft-frame velocity VECTOR. So for each
     nozzle axis we: settle to a baseline, deflect the nozzle, and watch which craft axis the
     velocity grows along and with what sign. That direction IS the mapping -- fed straight into the
     same AxisMap.assign that the manual screen uses, so the plane rules live in one place.

     WHAT IT WRITES. Nothing, until the pilot accepts. The run produces a PROPOSAL -- one
     {vectorMap, invertVectorX, invertVectorY} per thruster, with a confidence flag -- and publishes
     it for review. Accepting applies it to config and saves; discarding drops it. No optimistic
     write, here least of all: a wrong mapping is the exact divergence the whole control design
     exists to prevent.

     SCOPE (v1). This discovers the nozzle vectoring map only. A thruster's GROUP and QUADRANT are
     left as configured -- the craft already flies with them. Discovering the quadrant from a
     differential-thrust bump is a later extension; the phase machine below leaves room for it.

     Like the self test, it is driven entirely from the flight loop's clock via tick(); it never
     sleeps, the loop hands it the thrusters instead of the mixer while it runs, and it disarms the
     moment anything goes past a safety limit.
]]

local Util = require("lib.util")
local Thrusters = require("lib.io.thrusters")
local AxisMap = require("lib.control.axismap")

local SelfConfig = {}
SelfConfig.__index = SelfConfig

--- Longer than any plausible loop period; short enough a pilot notices a wedged run. Same reason
--- and value as the self test: three seconds without a tick is stopped, not slow.
local STALL_MS = 3000

function SelfConfig.new(thrusters, peripherals, cfg, log, state)
  local self = setmetatable({}, SelfConfig)
  self.thrusters = thrusters
  self.per = peripherals
  self.cfg = cfg
  self.log = log
  self.state = state
  self.run = nil
  self.lastRun = nil
  return self
end

function SelfConfig:params()
  return self.cfg.selfConfig or {}
end

function SelfConfig:isRunning()
  return self.run ~= nil
end

--- Every vector-capable thruster, sorted, with the two craft axes its nozzle can address.
function SelfConfig:probeTargets()
  local out = {}
  for _, entry in ipairs(self.per:thrusterList()) do
    if entry.canVector == nil then
      entry.canVector = type(entry.dev.setVector) == "function"
    end
    if entry.canVector then
      out[#out + 1] = {
        id = entry.id,
        group = entry.spec.group,
        plane = AxisMap.planeFor(entry.spec),   -- e.g. { "x", "z" }
      }
    end
  end
  table.sort(out, function(a, b) return a.id < b.id end)
  return out
end

-- ---------------------------------------------------------------- prerequisites

--- The go/no-go gate. Returns { ok, missing = { ... } }. The BIP has to actually FLY the craft, so
--- its prerequisites are the opposite of the self test's: the engine MUST be on and fuel MUST be
--- reaching the thrusters, because a probe with no thrust reads nothing.
---
---   facts (supplied by the app, which owns the policy reads):
---     engineOn        engine master is on
---     fuelled         the thruster supply has fuel (app checks the fuel model)
---     onGround        a down-facing laser positively reports ground contact
---     velocityVector  velocity capability is "vector" (three signed axes)
function SelfConfig:checkPrereqs(facts)
  facts = facts or {}
  local missing = {}
  if not facts.engineOn then missing[#missing + 1] = "ENGINE OFF" end
  if not facts.fuelled then missing[#missing + 1] = "NO FUEL" end
  if facts.onGround == false then
    -- Show the actual laser reading against its threshold, not a bare "NOT ON GROUND": on a physics
    -- hull that rests with clearance, the fix is to raise the threshold to match, and the pilot
    -- can only do that if they can SEE the number. e.g. "GND 3.4>2.0" -- reads 3.4, must be <= 2.0.
    local d, t = facts.groundDist, facts.groundThreshold
    missing[#missing + 1] = (type(d) == "number" and type(t) == "number")
      and ("GND %.1f>%.1f"):format(d, t)
      or "NOT ON GROUND"
  end
  if self:isRunning() then missing[#missing + 1] = "BIP RUNNING" end
  if facts.otherBip then missing[#missing + 1] = "TEST RUNNING" end
  if facts.velocityVector ~= "vector" then missing[#missing + 1] = "NO VEL VECTOR" end

  local targets = self:probeTargets()
  if #targets == 0 then missing[#missing + 1] = "NO NOZZLES" end

  local ok = #missing == 0
  self:publishPrereqs(ok, missing, #targets, facts)
  return { ok = ok, missing = missing, nozzles = #targets,
    groundDist = facts.groundDist, groundThreshold = facts.groundThreshold }
end

function SelfConfig:publishPrereqs(ok, missing, nozzles, facts)
  if not self.state then return end
  facts = facts or {}
  self.state:set("selfConfig.prereqs", {
    ok = ok, missing = missing or {}, nozzles = nozzles or 0,
    -- The ground reading, so the pilot can SEE how far off the "on ground" check is and tune the
    -- threshold (sensors.groundContactDist) to their hull rather than guess.
    groundDist = facts.groundDist,
    groundThreshold = facts.groundThreshold,
    checkedAt = os.epoch("utc"),
  })
end

-- ---------------------------------------------------------------- lifecycle

--- Begin. `facts` is the same table checkPrereqs takes; start REFUSES on any missing item, so the
--- decision is made once, from the craft's own reads, rather than trusted from the UI.
--- `ctx` carries the first sensor snapshot so the ground-altitude reference is taken at rest.
function SelfConfig:start(facts, ctx)
  local now = (ctx and ctx.now) or os.epoch("utc")
  if self.run then
    if self:isStalled(now) then
      self.log:warn("self config: taking over a stalled run (no tick for %.1fs)",
        (now - (self.run.lastTickAt or now)) / 1000)
      self:abort("aborted: the previous run stalled", "PREV STALLED")
    else
      return false, "a self config is already running", "ALREADY RUNNING"
    end
  end

  local check = self:checkPrereqs(facts)
  if not check.ok then
    local first = check.missing[1] or "NOT READY"
    return false, "prerequisites not met: " .. table.concat(check.missing, ", "), first
  end

  local p = self:params()
  local groundRef = ctx and ctx.altitude
  self.run = {
    startedAt = now,
    lastTickAt = now,
    phase = "float",
    phaseSince = now,
    groundRef = groundRef,          -- baro altitude at rest; height is measured against this
    targets = self:probeTargets(),
    index = 1,                      -- which target
    axisStep = 1,                   -- 1 = nozzle x, 2 = nozzle y
    collective = p.baseCollective or 0,
    findings = {},                  -- id -> { x = {...}, y = {...} }
    proposal = {},                  -- id -> { vectorMap, invertVectorX, invertVectorY, confidence }
    baseline = nil,                 -- craft-frame velocity at the last settle
    peak = nil,                     -- largest velocity delta seen during the current probe
    beats = 0,
  }
  self.log:info("self config started: %d nozzle(s) to map", #self.run.targets)
  self:publish()
  return true
end

--- Stop now, safely: everything to zero, nozzles centred, and remember why for the screen.
function SelfConfig:abort(reason, short)
  if not self.run then return false end
  self.thrusters:allStop()
  self.thrusters:centreNozzles()
  self.log:warn("self config %s", reason or "aborted")
  self.run.aborted = reason or "aborted"
  self.run.abortedShort = short
  self.run.finishedAt = os.epoch("utc")
  local finished = self.run
  self.run = nil
  self.lastRun = finished
  self:publish()
  return true
end

--- Reached the end and produced a proposal. Thrust is already zero (the land phase); centre once
--- more, unconditionally, and keep the proposal for review.
function SelfConfig:finish()
  if not self.run then return false end
  self.thrusters:allStop()
  self.thrusters:centreNozzles()
  self.run.finishedAt = os.epoch("utc")
  self.run.complete = true
  local finished = self.run
  self.run = nil
  self.lastRun = finished
  self.log:info("self config complete: %d mapping(s) proposed", self:proposalCount(finished))
  self:publish()
  return true
end

function SelfConfig:proposalCount(run)
  run = run or self.lastRun
  if not run or not run.proposal then return 0 end
  local n = 0
  for _ in pairs(run.proposal) do n = n + 1 end
  return n
end

--- The proposal from the last completed run, for the app to apply on accept. nil if the last run
--- did not complete (aborted runs propose nothing).
function SelfConfig:pendingProposal()
  if self.lastRun and self.lastRun.complete then return self.lastRun.proposal end
  return nil
end

--- The pilot discarded the proposal. Nothing was written; just forget it so the screen clears.
function SelfConfig:discard()
  if self.lastRun then self.lastRun.proposal = nil; self.lastRun.discarded = true end
  self:publish()
end

function SelfConfig:isStalled(now)
  if not self.run then return false end
  now = now or os.epoch("utc")
  return (now - (self.run.lastTickAt or self.run.startedAt or now)) > STALL_MS
end

-- ---------------------------------------------------------------- the run

--- height above the ground reference taken at start, or nil if we cannot tell.
function SelfConfig:height(ctx)
  if not self.run or self.run.groundRef == nil then return nil end
  if not ctx or type(ctx.altitude) ~= "number" then return nil end
  return ctx.altitude - self.run.groundRef
end

--- Craft-frame speed magnitude from the velocity vector, or nil.
local function speedOf(vel)
  if type(vel) ~= "table" then return nil end
  local x, y, z = vel.x or 0, vel.y or 0, vel.z or 0
  return math.sqrt(x * x + y * y + z * z)
end

--- The safety envelope, checked every tick regardless of phase. Any breach aborts. Returns a short
--- reason when it trips, nil when all clear.
function SelfConfig:safetyBreach(ctx)
  local p = self:params()
  local att = ctx and ctx.attitude
  if type(att) == "table" then
    if type(att.pitch) == "number" and math.abs(att.pitch) > (p.maxTiltDeg or 20) then
      return ("TILT %d deg"):format(math.floor(math.abs(att.pitch))), "OVER TILT"
    end
    if type(att.roll) == "number" and math.abs(att.roll) > (p.maxTiltDeg or 20) then
      return ("ROLL %d deg"):format(math.floor(math.abs(att.roll))), "OVER TILT"
    end
  end
  -- NO height ceiling here, deliberately. Climbing above the target is not a fault on a roped
  -- craft -- the float REGULATES it back down (tickFloat), it does not abort. What IS dangerous is
  -- fast motion (a rope letting go), and that is caught by the speed cap below regardless of height.
  --
  -- Except during LAND: cutting thrust to set the craft down is a deliberate descent, and a hull
  -- dropping the last couple of blocks legitimately passes the cap on the way to the pad. Aborting
  -- there would just leave the craft in the air. The tilt cap still applies -- a landing that TIPS
  -- is a real fault -- but the speed cap is a float/probe guard, not a landing one.
  if self.run and self.run.phase ~= "land" then
    local speed = speedOf(ctx and ctx.velocity)
    if type(speed) == "number" and speed > (p.maxSpeed or 3.0) then
      return ("SPEED %.1f"):format(speed), "RUNAWAY"
    end
  end
  return nil
end

--- WRITE-ON-CHANGE raw thrust. Every setThrust is a mainThread call costing ~a server tick, and the
--- float re-commanded all eight lift thrusters EVERY tick -- ~17 writes a cycle dragged the loop to
--- ~1 Hz (exec ~900 ms), which is why the float could not hold altitude and the probes read garbage.
--- Skip the write when the quantised step has not moved since we last wrote it. Compared on the step
--- the mod actually stores, so a demand that jitters within a step costs nothing.
function SelfConfig:cmdThrust(id, value)
  self.run.cmd = self.run.cmd or {}
  local c = self.run.cmd[id]; if not c then c = {}; self.run.cmd[id] = c end
  local step = Thrusters.thrustStep(value)
  if c.step ~= step then
    self.thrusters:setThrustRaw(id, value)
    c.step = step
  end
end

--- WRITE-ON-CHANGE raw nozzle. `force` re-asserts a deflection every tick: the vector redstone links
--- zero a nozzle whenever the contraption moves (docs/NOZZLE_LUA_API.md), so a PROBED deflection must
--- be re-sent each tick or it silently reverts to 0 and the probe measures nothing. A centred nozzle
--- (0,0) needs no re-assert -- 0 is what the competing writer sets anyway -- so it is cached.
function SelfConfig:cmdVector(id, nx, ny, force)
  self.run.cmd = self.run.cmd or {}
  local c = self.run.cmd[id]; if not c then c = {}; self.run.cmd[id] = c end
  local qx, qy = Thrusters.quantiseVector(nx), Thrusters.quantiseVector(ny)
  if force or c.nx ~= qx or c.ny ~= qy then
    self.thrusters:setVectorRaw(id, nx, ny)
    c.nx, c.ny = qx, qy
  end
end

--- CoM LEVELING. Drive the gimbal's pitch and roll to zero with differential LIFT THRUST (not nozzle
--- vectoring), so the float hovers LEVEL and the probes read a clean response instead of one
--- contaminated by a forward-centre-of-mass nose-down. Differential thrust is geometry-only -- which
--- corner is front/rear/left/right is known from each thruster's pos -- so unlike toe trim it needs
--- NO nozzle axis map, and can therefore run while SELF CONFIG is still discovering them.
---
--- The slow integral (pitchTrim/rollTrim) converges to the bias that holds level: that IS the craft's
--- CoM offset, kept for the FCS to feed forward later. A proportional term damps the live tilt on top.
function SelfConfig:updateLevel(ctx, now)
  local att = ctx and ctx.attitude
  local p = self:params()
  local dt = math.max((now - (self.run.lastLevelAt or now)) / 1000, 0)
  self.run.lastLevelAt = now
  if type(att) ~= "table" then return end          -- no gimbal: fall back to equal lift
  local pitch = tonumber(att.pitch) or 0            -- + = nose up
  local roll = tonumber(att.roll) or 0              -- + = roll right
  local maxT = p.levelMaxTrim or 1.0
  -- Integrate toward the bias that zeros the tilt. Nose-DOWN (pitch<0) needs a nose-UP bias
  -- (pitchTrim up); a RIGHT roll (roll>0) needs a left bias (rollTrim down).
  self.run.pitchTrim = Util.clamp((self.run.pitchTrim or 0) - (p.levelGain or 0.02) * pitch * dt, -maxT, maxT)
  self.run.rollTrim = Util.clamp((self.run.rollTrim or 0) - (p.levelGain or 0.02) * roll * dt, -maxT, maxT)
  -- What we actually apply: the learned trim plus proportional damping on the current tilt.
  local kp = p.levelP or 0.03
  self.run.applyPitch = Util.clamp((self.run.pitchTrim or 0) - kp * pitch, -maxT, maxT)
  self.run.applyRoll = Util.clamp((self.run.rollTrim or 0) - kp * roll, -maxT, maxT)
end

--- The per-thruster lift bias that levels the craft, from its corner geometry. Signs match the mixer
--- (docs/CONTROL_LAWS.md): front (pos.z>0) takes +pitch, right (pos.x>0) takes -roll.
function SelfConfig:levelDelta(spec)
  local p = self:params()
  local pos = spec.pos or {}
  local sz = ((pos.z or 0) > 0) and 1 or (((pos.z or 0) < 0) and -1 or 0)
  local sx = ((pos.x or 0) > 0) and 1 or (((pos.x or 0) < 0) and -1 or 0)
  local d = ((self.run.applyPitch or 0) * sz - (self.run.applyRoll or 0) * sx) * (p.levelAuthority or 0.3)
  local cap = p.levelMaxDelta or 0.4
  return Util.clamp(d, -cap, cap)
end

--- Command the float: every LIFT thruster at the current collective, biased to hold level, nozzles
--- centred. The probed thruster's own thrust and nozzle are overridden by the caller AFTER this, so
--- ordering matters. Write-on-change (cmdThrust/cmdVector): a steady, level hover re-writes nothing.
function SelfConfig:holdFloat(exceptId)
  for _, entry in ipairs(self.per:thrusterList()) do
    if entry.spec.group == "lift" then
      self:cmdThrust(entry.id, self.run.collective + self:levelDelta(entry.spec))
      if entry.id ~= exceptId then
        self:cmdVector(entry.id, 0, 0)
      end
    end
  end
end

--- Drive one loop's worth. ctx = { now, altitude, attitude = {pitch,roll,yaw}, velocity = {x,y,z},
--- groundContact, engineOn }. Returns true while the BIP owns the thrusters.
function SelfConfig:tick(ctx)
  if not self.run then return false end
  local now = (ctx and ctx.now) or os.epoch("utc")
  self.run.lastTickAt = now
  local p = self:params()

  -- The engine going off mid-run removes the thrust the whole measurement depends on -- and is the
  -- pilot's most likely "stop now". Treat it as an abort, not a silent stall.
  if ctx and ctx.engineOn == false then
    self:abort("aborted: the engine was switched off", "ENGINE OFF")
    return false
  end

  -- The envelope wins over every phase.
  local breach, breachShort = self:safetyBreach(ctx)
  if breach then
    self:abort("aborted: safety limit -- " .. breach, breachShort)
    return false
  end

  self:heartbeat(now)
  self:updateLevel(ctx, now)     -- keep the craft level (differential lift) so probes read clean

  local phase = self.run.phase
  if phase == "float" then
    self:tickFloat(ctx, now)
  elseif phase == "settle" then
    self:tickSettle(ctx, now)
  elseif phase == "probe" then
    self:tickProbe(ctx, now)
  elseif phase == "counter" then
    self:tickCounter(ctx, now)
  elseif phase == "land" then
    self:tickLand(ctx, now)
  end

  self:publish()
  return self.run ~= nil
end

function SelfConfig:enter(phase, now)
  self.run.phase = phase
  self.run.phaseSince = now
end

function SelfConfig:heartbeat(now)
  self.run.beats = (self.run.beats or 0) + 1
  if (now - (self.run.lastBeatAt or 0)) >= 1000 then
    self.run.lastBeatAt = now
    local target = self.run.targets[self.run.index]
    self.log:info("self config tick %d: phase %s, nozzle %d/%d (%s)", self.run.beats,
      self.run.phase, self.run.index, #self.run.targets, target and target.id or "-")
  end
end

--- Move the shared lift collective ONE tick toward a gentle hover. Used both to get airborne (float)
--- and to HOLD height across the long probe run (settle) -- a frozen collective was an earlier bug:
--- probing deflects a lift nozzle, which tilts its thrust off vertical and bleeds lift, so over many
--- nozzles the craft crept down until the front touched.
---
--- CASCADED and ANCHORED. Two failure modes had to be designed out at once:
---
---   * OVER-DRIVE on a distant target. Driving the throttle straight from the height error means a
---     high target (a 5-10 block hover, a long rope) starts with a huge error and slams the collective
---     to FULL in a second -- the craft leaps into the rope and thrashes. So the height error first
---     becomes a CAPPED desired vertical speed: no matter how far below, the craft only ever tries to
---     rise at approachSpeed. A far target and a near one approach at the same gentle pace.
---   * COLLAPSE to the ground. Driving the collective purely from the error also let it fall with no
---     lower bound when above the band, so the craft slammed down and rebuilt thrust from scratch. So
---     the collective is ANCHORED at a slow integral estimate of the hover throttle, plus a small
---     BOUNDED correction -- it settles at hover and cannot collapse or slam to full.
---
---   desiredVy = clamp(approachGain * (target - h), +/- approachSpeed)   -- gentle, capped approach
---   vErr      = desiredVy - vy
---   hoverEstimate += hoverLearn * vErr * dt     -- learns hover throttle from the BOUNDED vErr, so a
---                                                  distant target cannot wind it up to full
---   correction = clamp(velP * vErr, +/- maxCorrection)
---   collective = hoverEstimate + correction
---
--- Returns the height (or nil) and whether it is below / above the band, so callers can layer
--- their own policy (float's WONT-LIFT dwell, settle's baseline gate) on top.
function SelfConfig:regulateHeight(ctx, now)
  local p = self:params()
  local dt = math.max((now - (self.run.lastRegAt or now)) / 1000, 0)
  self.run.lastRegAt = now
  local maxC = p.maxCollective or 1.0
  local h = self:height(ctx)

  if type(h) ~= "number" then
    -- No altimeter: fall back to a slow open-loop ramp so a sensorless craft still tries to rise.
    -- It cannot regulate or leave the float on its own, but it can still reach WONT LIFT.
    self.run.collective = Util.clamp(self.run.collective + (p.collectiveRamp or 0.1) * dt, 0, maxC)
    return h, true, false
  end

  local target = p.hoverHeight or 2.0
  local tol = p.hoverTolerance or 0.5
  local vy = (ctx and ctx.velocity and ctx.velocity.y) or 0
  local above = h > target + tol

  -- Outer: height error -> a gentle, CAPPED desired vertical speed. The cap is what stops a distant
  -- target from over-driving the throttle to full and leaping the craft into the rope.
  local approach = p.approachSpeed or 0.4
  local desiredVy = Util.clamp((p.approachGain or 0.5) * (target - h), -approach, approach)
  local vErr = desiredVy - vy

  -- Inner: an anchored integral learns the hover throttle from the BOUNDED velocity error (so it can
  -- never wind up to full on a big height gap), plus a small bounded proportional correction.
  local corr = Util.clamp((p.velP or 0.3) * vErr, -(p.maxCorrection or 0.25), (p.maxCorrection or 0.25))

  -- ANTI-WINDUP against the mooring rope. When the craft overshoots and the rope catches it, it stops
  -- rising but does NOT descend either: it hangs STILL above the band while the controller keeps
  -- asking it down. Height there is fixed by the rope, not by thrust, so integrating the hover
  -- estimate down against that unmovable error is pure windup -- and the moment the rope goes slack
  -- the throttle is far below hover and the craft drops out of the sky (the reported "it just falls
  -- back to the ground"). Detect the pin by its signature -- above the band, wanting down, yet
  -- essentially stationary -- and freeze the DOWNWARD integration while it lasts. A craft that is
  -- genuinely rising past the target (|vy| large) is NOT pinned, so the estimate still trims to
  -- arrest a free overshoot; only the rope-held hang is frozen. Textbook conditional integration,
  -- with the rope as the saturating constraint the plant cannot answer.
  local pinned = above and vErr < 0 and math.abs(vy) < (p.settleSpeed or 0.1)
  local di = (p.hoverLearn or 0.3) * vErr * dt
  if pinned and di < 0 then di = 0 end
  self.run.hoverEstimate = Util.clamp((self.run.hoverEstimate or self.run.collective or 0) + di, 0, maxC)

  self.run.collective = Util.clamp(self.run.hoverEstimate + corr, 0, maxC)
  return h, (h < target - tol), above
end

--- FLOAT: get airborne and hold the hover band, then settle. Regulation is shared with settle
--- (regulateHeight); float layers on the WONT-LIFT dwell and the transition into the probe run.
---
--- WONT LIFT is declared only after HOLDING full power a while and STILL being below the band --
--- a liquid thruster ramps its thrust, so full power needs a moment to mean full thrust, and at
--- that point the answer is more thrust (fuel upgrades / more nozzles), not more time.
function SelfConfig:tickFloat(ctx, now)
  local p = self:params()
  local maxC = p.maxCollective or 1.0
  local _, below, above = self:regulateHeight(ctx, now)

  if below then
    self.run.bandSince = nil
    if self.run.collective >= maxC then
      self.run.atMaxSince = self.run.atMaxSince or now
      if (now - self.run.atMaxSince) > (p.fullPowerDwellMs or 5000) then
        self:abort("aborted: full thrust and still on the ground", "WONT LIFT")
        return
      end
    else
      self.run.atMaxSince = nil
    end
  elseif above then
    self.run.bandSince = nil
    self.run.atMaxSince = nil
  else
    -- In the band. Settle once slow, or once we have held the band long enough (quantised thrust
    -- never lets it sit perfectly still).
    self.run.atMaxSince = nil
    self.run.bandSince = self.run.bandSince or now
    local vy = (ctx and ctx.velocity and ctx.velocity.y) or 0
    local slow = math.abs(vy) <= (p.settleSpeed or 0.1)
    local waited = (now - self.run.bandSince) >= (p.floatSettleMs or 3000)
    if slow or waited then
      self:holdFloat()
      self:enter("settle", now)
      return
    end
  end

  self:holdFloat()
end

--- SETTLE: re-establish the hover height (the probe run bleeds a little lift each cycle, so the
--- craft must be flown back UP to the band before every nozzle, or it creeps down onto the ground),
--- then wait for the craft-frame speed to fall below the settle threshold and record the baseline.
---
--- The baseline is only taken once the craft is BOTH back at height AND slow. A craft that cannot
--- regain height within the settle window -- sinking, out of thrust -- must NOT silently probe from
--- the ground (that reads garbage); it aborts with LOST HEIGHT instead, which is the abort the
--- pilot expected when the front touched down.
function SelfConfig:tickSettle(ctx, now)
  local p = self:params()
  local target = self.run.targets[self.run.index]
  if not target then self:enter("land", now); return end

  -- Hold height across the run: climb back if the last probe cycle let the craft sink.
  local h = self:regulateHeight(ctx, now)

  -- Ensure the probed thruster is firing at its probe thrust with a CENTRED nozzle. For a lift
  -- thruster that is just the float; for a lateral/main it spins the thruster up so the coming
  -- deflection has thrust to steer.
  self:holdFloat(target.id)
  local probeThrust = (target.group == "lift") and self.run.collective or (p.probeThrust or 0.4)
  self:cmdThrust(target.id, probeThrust)
  self:cmdVector(target.id, 0, 0)

  local hoverH = p.hoverHeight or 2.0
  local tol = p.hoverTolerance or 0.5
  local atHeight = (type(h) ~= "number") or (h >= hoverH - tol)
  local speed = speedOf(ctx and ctx.velocity)
  local settled = type(speed) == "number" and speed <= (p.settleSpeed or 0.1)
  local waited = (now - self.run.phaseSince) >= (p.settleMs or 2000)

  if atHeight and (settled or waited) then
    self.run.baseline = self:velCopy(ctx and ctx.velocity)
    self.run.peak = nil
    self.run.probeGrounded = false     -- track whether THIS probe ever touches the ground
    self:enter("probe", now)
  elseif not atHeight and waited then
    -- Had the whole settle window and still cannot get back to height: stop rather than probe low.
    self:abort("aborted: lost height mid-run and could not climb back", "LOST HEIGHT")
  end
end

function SelfConfig:velCopy(vel)
  if type(vel) ~= "table" then return { x = 0, y = 0, z = 0 } end
  return { x = vel.x or 0, y = vel.y or 0, z = vel.z or 0 }
end

--- PROBE: deflect the current nozzle axis to the probe deflection and hold it, tracking the LARGEST
--- velocity delta from baseline (the transient, before the ropes arrest it). When the window ends,
--- decide the direction and move on.
function SelfConfig:tickProbe(ctx, now)
  local p = self:params()
  local target = self.run.targets[self.run.index]
  if not target then self:enter("land", now); return end

  self:holdFloat(target.id)
  local probeThrust = (target.group == "lift") and self.run.collective or (p.probeThrust or 0.4)
  self:cmdThrust(target.id, probeThrust)

  -- Deflect the current nozzle axis, quantised to the grid the block stores, capped by authority.
  local spec = self.per.thrusters[target.id].spec
  local limit = Util.clamp(spec.maxVector or 0.6, 0, 1)
  local mag = math.min(p.probeDeflection or 0.6, limit)
  local value = Thrusters.quantiseVector(mag)
  local nx = (self.run.axisStep == 1) and value or 0
  local ny = (self.run.axisStep == 2) and value or 0
  self:cmdVector(target.id, nx, ny, true)   -- force: a moving contraption's links zero a probed nozzle

  -- If the craft is on the ground during the probe, the ground arrests the very motion we are
  -- trying to measure -- so the reading understates (or misses) the response. Remember it, so the
  -- finding can be flagged low-confidence rather than trusted like a clean airborne probe.
  if ctx and ctx.groundContact == true then self.run.probeGrounded = true end

  -- Track the peak velocity delta on the two plane axes.
  local base = self.run.baseline or { x = 0, y = 0, z = 0 }
  local vel = self:velCopy(ctx and ctx.velocity)
  local a1, a2 = target.plane[1], target.plane[2]
  local d1 = (vel[a1] or 0) - (base[a1] or 0)
  local d2 = (vel[a2] or 0) - (base[a2] or 0)
  local mag2 = d1 * d1 + d2 * d2
  if not self.run.peak or mag2 > self.run.peak.mag2 then
    self.run.peak = { mag2 = mag2, d1 = d1, d2 = d2, a1 = a1, a2 = a2 }
  end

  if (now - self.run.phaseSince) >= (p.probeMs or 1500) then
    self:recordProbe(target, ctx)
    self:enter("counter", now)
  end
end

--- Turn the peak velocity delta into a measured direction for this nozzle axis, and stash it.
function SelfConfig:recordProbe(target, ctx)
  local p = self:params()
  local peak = self.run.peak or { d1 = 0, d2 = 0, a1 = target.plane[1], a2 = target.plane[2] }
  local nozzleAxis = (self.run.axisStep == 1) and "x" or "y"

  local m1, m2 = math.abs(peak.d1), math.abs(peak.d2)
  local response = math.sqrt(m1 * m1 + m2 * m2)
  -- Probed while touching the ground: the reading cannot be trusted like a clean airborne one.
  local grounded = self.run.probeGrounded and true or false
  local finding = { nozzleAxis = nozzleAxis, response = response, grounded = grounded }

  if response < (p.minResponse or 0.15) then
    -- Nothing moved enough to trust. Leave the mapping alone for this axis; the pilot is told.
    finding.result = "no-response"
  else
    local dominant, other, craftAxis, craftSign
    if m1 >= m2 then
      dominant, other, craftAxis, craftSign = m1, m2, peak.a1, (peak.d1 >= 0) and 1 or -1
    else
      dominant, other, craftAxis, craftSign = m2, m1, peak.a2, (peak.d2 >= 0) and 1 or -1
    end
    finding.result = "ok"
    finding.craftAxis = craftAxis
    finding.craftSign = craftSign
    -- Two comparable axes means a diagonal mounting the one-axis-per-nozzle model cannot represent
    -- cleanly. Record it so the proposal can flag low confidence rather than commit a coin toss.
    -- A grounded probe is likewise untrustworthy, so it too counts as weak.
    finding.ambiguous = grounded
      or ((dominant > 0) and (other / dominant) > (p.ambiguityRatio or 0.5))
  end

  self.run.findings[target.id] = self.run.findings[target.id] or {}
  self.run.findings[target.id][nozzleAxis] = finding
  self.log:info("self config: %s nozzle %s -> %s%s", target.id, nozzleAxis,
    finding.result == "ok"
      and ("%s%s%s"):format(finding.craftSign > 0 and "+" or "-", tostring(finding.craftAxis),
        finding.ambiguous and " (weak)" or "")
      or "no response",
    grounded and " [grounded]" or "")
end

--- COUNTER: deflect the opposite way briefly to cancel the velocity the probe built up, so the
--- next settle starts from near rest rather than fighting a drift. Then advance.
function SelfConfig:tickCounter(ctx, now)
  local p = self:params()
  local target = self.run.targets[self.run.index]
  if not target then self:enter("land", now); return end

  self:holdFloat(target.id)
  local probeThrust = (target.group == "lift") and self.run.collective or (p.probeThrust or 0.4)
  self:cmdThrust(target.id, probeThrust)

  local spec = self.per.thrusters[target.id].spec
  local limit = Util.clamp(spec.maxVector or 0.6, 0, 1)
  local mag = math.min(p.probeDeflection or 0.6, limit)
  local value = -Thrusters.quantiseVector(mag)     -- opposite of the probe
  local nx = (self.run.axisStep == 1) and value or 0
  local ny = (self.run.axisStep == 2) and value or 0
  self:cmdVector(target.id, nx, ny, true)          -- force: re-assert against the zeroing links

  if (now - self.run.phaseSince) >= (p.counterMs or 1200) then
    self:cmdVector(target.id, 0, 0)
    self:advance(now)
  end
end

--- Move to the next nozzle axis, then the next thruster; when both are exhausted, build the
--- proposal and land.
function SelfConfig:advance(now)
  if self.run.axisStep == 1 then
    self.run.axisStep = 2
    self:enter("settle", now)
    return
  end
  -- Both axes of this thruster are done: turn the two findings into a proposed mapping.
  self:buildProposalFor(self.run.targets[self.run.index])
  self.run.axisStep = 1
  self.run.index = self.run.index + 1
  if self.run.index > #self.run.targets then
    self:enter("land", now)
  else
    self:enter("settle", now)
  end
end

--- Fold this thruster's two axis findings into a {vectorMap, invert flags} proposal, reusing
--- AxisMap.assign on a SCRATCH spec so the plane rules are applied in exactly one place and the
--- live config is never touched mid-run.
function SelfConfig:buildProposalFor(target)
  if not target then return end
  local found = self.run.findings[target.id] or {}
  local spec = self.per.thrusters[target.id].spec
  local scratch = {
    group = spec.group,
    thrustAxis = spec.thrustAxis,
    vectorMap = { x = (spec.vectorMap or {}).x, y = (spec.vectorMap or {}).y },
    invertVectorX = spec.invertVectorX,
    invertVectorY = spec.invertVectorY,
  }

  local applied, weak, failed = 0, false, {}
  for _, nozzleAxis in ipairs({ "x", "y" }) do
    local f = found[nozzleAxis]
    if f and f.result == "ok" then
      local ok = AxisMap.assign(scratch, nozzleAxis, 1, f.craftAxis, f.craftSign)
      if ok then
        applied = applied + 1
        if f.ambiguous then weak = true end
      else
        failed[#failed + 1] = nozzleAxis
      end
    else
      failed[#failed + 1] = nozzleAxis
    end
  end

  if applied == 0 then
    -- Learned nothing about this nozzle. Do not propose a change for it.
    return
  end
  self.run.proposal[target.id] = {
    id = target.id,
    group = spec.group,
    vectorMap = scratch.vectorMap,
    invertVectorX = scratch.invertVectorX,
    invertVectorY = scratch.invertVectorY,
    confidence = (weak or #failed > 0) and "low" or "ok",
    partial = #failed > 0,
  }
end

--- LAND: ramp the collective down and centre nozzles; when thrust is essentially gone, finish.
function SelfConfig:tickLand(ctx, now)
  local p = self:params()
  local dt = ((now - (self.run.lastLandAt or now)) / 1000)
  self.run.lastLandAt = now
  self.run.collective = math.max(0, self.run.collective - (p.landRamp or 0.15) * math.max(dt, 0))

  for _, entry in ipairs(self.per:thrusterList()) do
    self:cmdVector(entry.id, 0, 0)
    if entry.spec.group == "lift" then
      self:cmdThrust(entry.id, self.run.collective)
    else
      self:cmdThrust(entry.id, 0)
    end
  end

  local h = self:height(ctx)
  local downEnough = (type(h) ~= "number") or h <= (p.landedHeight or 0.4)
  if self.run.collective <= 1e-6 and (downEnough or (now - self.run.phaseSince) > 6000) then
    self:finish()
  end
end

-- ---------------------------------------------------------------- publish

function SelfConfig:publish()
  if not self.state then return end
  if self.run then
    local target = self.run.targets[self.run.index]
    self.state:set("selfConfig", {
      running = true,
      phase = self.run.phase,
      index = self.run.index,
      total = #self.run.targets,
      current = target and target.id or nil,
      axisStep = self.run.axisStep,
      collective = self.run.collective,
      proposed = self:proposalCount(self.run),
      sinceTickMs = math.max(0, os.epoch("utc") - (self.run.lastTickAt or self.run.startedAt)),
    })
  else
    local last = self.lastRun
    self.state:set("selfConfig", {
      running = false,
      complete = last and last.complete or false,
      aborted = last and last.aborted or nil,
      abortedShort = last and last.abortedShort or nil,
      discarded = last and last.discarded or false,
      proposal = last and last.complete and last.proposal or nil,
      proposed = last and last.complete and self:proposalCount(last) or nil,
    })
  end
end

SelfConfig.STALL_MS = STALL_MS

return SelfConfig
