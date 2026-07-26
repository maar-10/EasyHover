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

--- Is any thruster producing power? A sweep with live thrust would move the craft.
function SelfTest:anyPowered()
  for _, entry in ipairs(self.per:thrusterList()) do
    local fn = entry.dev.getPower
    if type(fn) == "function" then
      local ok, v = pcall(fn)
      if ok and type(v) == "number" and v > 0.001 then return true, entry.id, v end
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
function SelfTest:start(opts)
  opts = opts or {}
  if self.run then return false, "a self test is already running" end
  if not opts.allowed then
    return false, "the self test only runs on the ground, with the engine off"
  end
  local powered, id, value = self:anyPowered()
  if powered then
    return false, ("%s is producing thrust (%.2f) -- cut the engine first"):format(
      tostring(id), value)
  end

  self.run = {
    startedAt = opts.now or os.epoch("utc"),
    step = 1,
    findings = {},
    lastPowerCheck = opts.now or os.epoch("utc"),
  }
  self.log:info("self test started")
  self:publish()
  return true
end

function SelfTest:abort(reason)
  if not self.run then return false end
  -- Centre everything we touched, whatever else happens.
  self.thrusters:neutralVectors()
  self.log:info("self test %s", reason or "aborted")
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

  -- Re-check power about once a second. If thrust has appeared, something is feeding the
  -- thrusters and the craft may be about to move: stop, centre, and say so.
  if now - self.run.lastPowerCheck >= 1000 then
    self.run.lastPowerCheck = now
    local powered, id = self:anyPowered()
    if powered then
      self:abort(("aborted: %s started producing thrust"):format(tostring(id)))
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
    elseif #plain > 0 then
      self.log:info("self test: %d %s thruster(s) have no nozzle (thrust only): %s",
        #plain, step.group, table.concat(plain, ", "))
    end
  end

  -- One full sine cycle across the phase: 0 -> + -> 0 -> - -> 0. That covers the whole range
  -- of the axis and, because a sine passes through zero, it is obvious which way it went first.
  local fraction = p.intoPhaseMs / p.phaseMs
  local wave = math.sin(fraction * 2 * math.pi)

  for _, entry in ipairs(members) do
    if entry.canVector then
      local limit = Util.clamp(entry.spec.maxVector or 0.6, 0, 1)
      local value = wave * limit
      local nx = (p.axis == "x") and value or 0
      local ny = (p.axis == "y") and value or 0
      -- Deliberately RAW: the point is to see the nozzle's own axes, not the craft-frame
      -- mapping the mixer would apply. A mirrored mounting is invisible through the mapping.
      self.thrusters:setVectorRaw(entry.id, nx, ny)
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
    self.state:set("selfTest", {
      running = true,
      step = p.step, steps = p.steps, label = p.label, watch = p.watch,
      phase = p.phase,
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
      findings = last and last.findings or nil,
    })
  end
end

SelfTest.STEP_MS = STEP_MS

return SelfTest
