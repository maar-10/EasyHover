--[[ Flight-control self test: sweep each thruster group's nozzles, on the ground.

     What it is for: confirming that the thruster you assigned to a slot is the thruster that
     actually moves, that the flight computer can talk to it, and -- the part that matters most
     -- WHICH WAY ITS NOZZLE POINTS when the software deflects it.

     Nothing here commands thrust. Ever. It moves nozzles and refuses to start if any thruster
     is producing power, the same contract as the identify sweep and the hardware probe.

     THREE STEPS OF 15 SECONDS, each split into two 7.5 s phases that sweep one nozzle axis
     through a full sine cycle (0 -> + -> 0 -> - -> 0). A whole group moves together, so the
     pilot can watch four nozzles at once and see which of them disagrees with the others --
     which is exactly how a mirrored or rotated mounting shows itself.

     The sweep is driven from the flight loop's own clock via tick(); it never sleeps, and the
     loop hands it the thrusters instead of the mixer while it runs.
]]

local Util = require("lib.util")
local Thrusters = require("lib.io.thrusters")

local SelfTest = {}
SelfTest.__index = SelfTest

--- Each step names a thruster GROUP and what the pilot should be looking at.
SelfTest.STEPS = {
  { group = "lift",    label = "LIFT THRUSTERS",
    watch = "all four lift nozzles" },
  { group = "lateral", label = "LATERAL THRUSTERS",
    watch = "front pair, then rear" },
  { group = "main",    label = "ACCEL THRUSTERS",
    watch = "all four accelerators" },
}

local STEP_MS = 15000
local PHASES = { { axis = "x", label = "X sweep" }, { axis = "y", label = "Y sweep" } }

--- The deflection pattern across one phase, as a fraction of the nozzle's authority limit.
---
--- THIS WAS A SINE, AND THE PILOT SAW NOTHING MOVE. Two reasons, and they compound:
---
---   * The mod stores nozzle aim as FOUR REDSTONE SIGNALS. `setVectorCoordinates` does
---     `Math.round(x * 15)`, so aim lives on a 15-step grid and anything under 1/30 of full
---     scale rounds to ZERO. A sine leaving the origin spends its first moments below that,
---     commanding literal nothing.
---   * A sine spends most of its time away from its extremes, so on a slow control loop -- and
---     this loop is slow, because every thruster @LuaFunction is mainThread -- the few samples
---     that land in a 7.5 s phase are mostly small deflections. Small, quantised, invisible.
---
--- So: RAMP TO FULL DEFLECTION AND HOLD IT. A held extreme is unmistakable from across the bay,
--- it cannot quantise away, and it does not care where in the phase the loop happens to sample.
--- The full range is still covered, which is what the sweep is for.
---
---   0.00-0.15  ramp out to +1
---   0.15-0.35  HOLD +1
---   0.35-0.50  ramp back through 0 to -1
---   0.50-0.70  HOLD -1
---   0.70-0.85  ramp back to 0
---   0.85-1.00  rest at 0, so the next axis starts from a known centre
function SelfTest.waveAt(fraction)
  fraction = math.max(0, math.min(1, fraction or 0))
  if fraction < 0.15 then return fraction / 0.15 end
  if fraction < 0.35 then return 1 end
  if fraction < 0.50 then return 1 - ((fraction - 0.35) / 0.15) * 2 end
  if fraction < 0.70 then return -1 end
  if fraction < 0.85 then return -1 + ((fraction - 0.70) / 0.15) end
  return 0
end

function SelfTest.new(thrusters, peripherals, cfg, log, state)
  local self = setmetatable({}, SelfTest)
  self.thrusters = thrusters
  self.per = peripherals
  self.cfg = cfg
  self.log = log
  self.state = state
  self.run = nil
  return self
end

--- Every thruster in a group, with whether it can actually vector.
function SelfTest:groupMembers(group)
  local out = {}
  for _, entry in ipairs(self.per:thrusterList()) do
    if entry.spec.group == group then
      if entry.canVector == nil then
        entry.canVector = type(entry.dev.setVector) == "function"
      end
      out[#out + 1] = entry
    end
  end
  table.sort(out, function(a, b) return a.id < b.id end)
  return out
end

--- Anything above this in kN counts as firing. Not zero: a mod readout that jitters at the
--- fourth decimal would make the interlock unpassable, which is its own kind of broken.
local THRUST_EPSILON_KN = 0.05

--- Is any thruster ACTUALLY PRODUCING THRUST? Physics, not the commanded throttle.
---
--- Used only AFTER the sweep has zeroed the throttles and let them fade, so anything still
--- reading here is being fed by something other than this computer.
---
--- getCurrentThrustKN is the physical output: in the Propulsion source it is getCurrentThrustPN
--- scaled, and getCurrentThrustPN returns thrusterData.getThrust(), which updateThrust only ever
--- sets nonzero when `isWorking() && currentPower > 0` with fuel actually being consumed.
---
--- getDisplayedThrust* is NOT usable here: it returns getDisplayedThrustPnForTooltip(), a display
--- figure, not what the nozzle is doing now.
---
--- Only kN is read. PN exists for every thruster too, but mixing units to gain a fallback is how
--- an epsilon silently becomes a thousand times too large.
---
--- AND NO getPower FALLBACK. getPower is the read-back of our own setPower, so falling back to it
--- hands the interlock the flight computer's own command as though it were evidence -- the exact
--- false positive this function exists to avoid. A thruster exposing no thrust readout is covered
--- by the engine gate and by allStop, both of which run first.
function SelfTest:anyPowered()
  for _, entry in ipairs(self.per:thrusterList()) do
    local reader = entry.dev.getCurrentThrustKN
    if type(reader) == "function" then
      local ok, kn = pcall(reader)
      if ok and type(kn) == "number" and kn > THRUST_EPSILON_KN then
        return true, entry.id, kn, "kN"
      end
    end
  end
  return false
end

--- opts.allowed must be true -- the caller owns the policy decision, exactly as it does for
--- the identify sweep, so this module cannot be tricked into running airborne.
---
--- THE HARD INTERLOCK IS POWER, NOT THE FLIGHT STATE. A craft whose thrusters produce nothing
--- is not flying, whatever any sensor believes -- and the GROUND state depends on
--- `groundContact`, which depends on a down-facing laser being assigned. Gating solely on that
--- would make the pre-flight test unavailable on exactly the half-configured craft that needs
--- it most. So power is re-checked while the sweep runs, and the sweep stops if any appears.
--- Every refusal returns ok, long, SHORT. The short form exists because a cockpit monitor can be
--- 15 columns wide, and the panel used to tail-fit the long one: "... cut the engine first"
--- arrived as "he engine first", which reads as an instruction to START the engine -- the exact
--- opposite of the interlock's meaning. An interlock whose message inverts under truncation is
--- worse than one with no message, so the wording is now the craft's responsibility, at both
--- lengths, rather than something the UI improvises with a substring.
--- How long thrust is given to decay after the throttles go to zero, before a reading counts
--- against the sweep. A liquid thruster has a fade envelope (AbstractThrusterBlockEntity
--- getEnvelopePower/fadePower), so it does not stop the tick you stop asking.
local SETTLE_MS = 2500

function SelfTest:start(opts)
  opts = opts or {}
  if self.run then return false, "a self test is already running", "ALREADY RUNNING" end

  -- Wording lives HERE rather than in app.lua so both lengths of every refusal stay in one file.
  --
  -- WHAT MAKES SILENCING THE THROTTLES UNSAFE is the craft being held up by thrust -- so that is
  -- what is tested, rather than a list of mode names. Mode alone is not enough in either
  -- direction: the airborne set is easy to get wrong (BRAKE, DAMPED and FAILSAFE are airborne
  -- too, and an earlier version of this listed only FLIGHT/HOVER/REVERSE), and requiring GROUND
  -- denies the test to a craft whose down-facing laser is not assigned yet -- which is exactly
  -- the half-configured craft that needs it. A craft producing no thrust cannot be holding itself
  -- up, whatever any sensor believes.
  if opts.airborne and self:anyPowered() then
    return false, "not while the craft is flying under thrust", "IN FLIGHT"
  end
  if opts.engineOn then
    return false, "engine master must be off first", "ENGINE IS ON"
  end

  -- ---- take OUR OWN throttles to zero, and do it BEFORE judging anything
  --
  -- This used to refuse when any thruster read thrust, which was unsatisfiable in the one
  -- situation that matters. `Thrusters:apply` runs every control cycle whatever the engine master
  -- says, so the altitude loop holds the lift thrusters at ~20% on a parked craft -- and the fuel
  -- TANK feeds those nozzles directly, so the engine master being off does not make them cold.
  -- The pilot was told to "cut the engine" about thrust the flight computer itself had commanded,
  -- from a source the engine switch does not control. There was no action that would clear it.
  --
  -- A commanded throttle is ours to retract, so retract it. What we may NOT do is retract it on a
  -- craft that is holding itself up -- which is why `flying` is refused above, before this line.
  self.thrusters:allStop()

  local now = opts.now or os.epoch("utc")
  self.run = {
    startedAt = now,
    step = 1,
    findings = {},
    lastPowerCheck = now,
    -- Nothing is judged until the fade envelope has had time to reach zero.
    settleUntil = now + SETTLE_MS,
    -- Last quantised aim per thruster, so an unchanged write is skipped.
    commanded = {},
  }
  self.log:info("self test started")
  self:publish()
  return true
end

--- `short` is the 15-column form, for the same reason as the refusals in start().
function SelfTest:abort(reason, short)
  if not self.run then return false end
  -- Centre everything we touched, whatever else happens.
  self.thrusters:neutralVectors()
  self.log:info("self test %s", reason or "aborted")
  self.run.abortedShort = short
  self.run.aborted = reason or "aborted"
  self.run.finishedAt = os.epoch("utc")
  local finished = self.run
  self.run = nil
  self.lastRun = finished
  self:publish()
  return true
end

function SelfTest:isRunning()
  return self.run ~= nil
end

--- Where the sweep is right now: step index, phase, and how long is left.
function SelfTest:progress(now)
  if not self.run then return nil end
  now = now or os.epoch("utc")
  local elapsed = now - self.run.startedAt
  local total = #SelfTest.STEPS * STEP_MS
  local stepIndex = math.min(#SelfTest.STEPS, math.floor(elapsed / STEP_MS) + 1)
  local intoStep = elapsed - (stepIndex - 1) * STEP_MS
  local phaseMs = STEP_MS / #PHASES
  local phaseIndex = math.min(#PHASES, math.floor(intoStep / phaseMs) + 1)
  return {
    step = stepIndex,
    steps = #SelfTest.STEPS,
    label = SelfTest.STEPS[stepIndex].label,
    watch = SelfTest.STEPS[stepIndex].watch,
    phase = PHASES[phaseIndex].label,
    axis = PHASES[phaseIndex].axis,
    stepRemainingMs = math.max(0, STEP_MS - intoStep),
    remainingMs = math.max(0, total - elapsed),
    elapsedMs = elapsed,
    totalMs = total,
    intoPhaseMs = intoStep - (phaseIndex - 1) * phaseMs,
    phaseMs = phaseMs,
  }
end

--- Drive one loop's worth. Returns true while the test owns the thrusters.
function SelfTest:tick(now)
  if not self.run then return false end
  now = now or os.epoch("utc")
  local p = self:progress(now)
  if p.elapsedMs >= p.totalMs then
    self:finish()
    return false
  end

  -- Re-check thrust about once a second, but not until the throttles we zeroed at the start have
  -- had time to fade. Thrust surviving the settle window is not ours: something is feeding those
  -- nozzles, the craft may be about to move, so stop, centre, and say what is actually wrong --
  -- which is fuel reaching a thruster, not an engine switch.
  if now >= (self.run.settleUntil or 0) and now - self.run.lastPowerCheck >= 1000 then
    self.run.lastPowerCheck = now
    local powered, id, value, unit = self:anyPowered()
    if powered then
      self:abort(("aborted: %s is still making thrust (%.2f %s) -- fuel is reaching it"):format(
        tostring(id), value or 0, tostring(unit)), "STILL FUELLED")
      return false
    end
  end

  local step = SelfTest.STEPS[p.step]
  local members = self:groupMembers(step.group)

  -- Record what this step found, once, on entering it.
  local key = step.group
  if self.run.findings[key] == nil then
    local vectoring, plain = {}, {}
    for _, entry in ipairs(members) do
      if entry.canVector then vectoring[#vectoring + 1] = entry.id
      else plain[#plain + 1] = entry.id end
    end
    self.run.findings[key] = {
      group = step.group, count = #members,
      vectoring = vectoring, plain = plain,
    }
    if #members == 0 then
      self.log:warn("self test: no %s thrusters are assigned", step.group)
    elseif #vectoring == 0 then
      -- EVERY thruster in this group is thrust-only, so nothing will move for the next 15
      -- seconds while the screen counts down as though it were testing something. Only the
      -- VECTOR peripherals expose setVector; a plain `thruster` has no nozzle at all.
      self.log:warn("self test: NO %s thruster has a nozzle -- nothing will move", step.group)
    elseif #plain > 0 then
      self.log:info("self test: %d %s thruster(s) have no nozzle (thrust only): %s",
        #plain, step.group, table.concat(plain, ", "))
    end
  end

  local wave = SelfTest.waveAt(p.intoPhaseMs / p.phaseMs)

  for _, entry in ipairs(members) do
    if entry.canVector then
      local limit = Util.clamp(entry.spec.maxVector or 0.6, 0, 1)
      -- Quantised to the grid the mod actually stores, so what is commanded is what happens.
      local value = Thrusters.quantiseVector(wave * limit)
      local nx = (p.axis == "x") and value or 0
      local ny = (p.axis == "y") and value or 0

      -- SKIP AN UNCHANGED WRITE. setVector is `mainThread = true`, so every call waits on a
      -- server tick -- and on the quantised grid consecutive samples are usually identical, so
      -- most of those calls were buying nothing while slowing the loop that drives the sweep.
      local key = entry.id
      local last = self.run.commanded[key]
      if last == nil or last.nx ~= nx or last.ny ~= ny then
        self.run.commanded[key] = { nx = nx, ny = ny }
        -- Deliberately RAW: the point is to see the nozzle's own axes, not the craft-frame
        -- mapping the mixer would apply. A mirrored mounting is invisible through the mapping.
        self.thrusters:setVectorRaw(entry.id, nx, ny)
      end
    end
  end

  self:publish(p)
  return true
end

function SelfTest:finish()
  if not self.run then return false end
  self.thrusters:neutralVectors()
  self.run.finishedAt = os.epoch("utc")
  self.run.complete = true
  local finished = self.run
  self.run = nil
  self.lastRun = finished
  self.log:info("self test complete")
  self:publish()
  return true
end

--- Everything the UI needs, in the state store.
function SelfTest:publish(progress)
  if not self.state then return end
  if self.run then
    local p = progress or self:progress()
    -- `moving` is how many nozzles this step can actually sweep. Zero is the answer to "it says
    -- running but nothing moves", and it belongs on the screen, not only in the log.
    local current = self.run.findings[SelfTest.STEPS[p.step].group]
    self.state:set("selfTest", {
      running = true,
      step = p.step, steps = p.steps, label = p.label, watch = p.watch,
      phase = p.phase,
      moving = current and #(current.vectoring or {}) or nil,
      groupCount = current and current.count or nil,
      stepRemainingMs = p.stepRemainingMs,
      remainingMs = p.remainingMs,
      findings = self.run.findings,
    })
  else
    local last = self.lastRun
    self.state:set("selfTest", {
      running = false,
      complete = last and last.complete or false,
      aborted = last and last.aborted or nil,
      abortedShort = last and last.abortedShort or nil,
      findings = last and last.findings or nil,
    })
  end
end

SelfTest.STEP_MS = STEP_MS

return SelfTest
