--[[ SENSOR CAL: a guided, operator-driven sensor calibration.

     The gimbal-axis SWAP that made the craft roll over on liftoff was invisible until a full
     blackbox timeline showed it -- the loop's command is always self-consistent with what it
     MEASURES, so a mislabelled axis reads perfectly right up until the craft flips. SELF CONFIG
     tried to prove the wiring by flying probes, which is exactly the manoeuvre a mis-wired craft
     cannot survive. SENSOR CAL inverts that: the OPERATOR moves the craft by hand -- with a
     plunger, another contraption, whatever is precise -- in a fixed sequence, and the system takes
     the DOMINANT sensor change of each move as ground truth for that axis and its sign.

     Like CoM LEVELING and unlike the self test, this owns NOTHING: it never commands a thruster.
     It watches the raw sensor stream and records a mapping. If the operator does the wrong move it
     simply never detects a clean dominant change and will not advance -- the failure mode is
     "nothing happens", never "loss of control". Prerequisites (on the ground, disengaged, sensors
     healthy) are the caller's to check; this module owns the walkthrough and the detection.

     States: idle -> running (a cursor over the STEPS, each watching then detected) -> review ->
     idle (on apply/abort). The learned mapping is handed back for the app to write to config.
]]

local SensorCal = {}
SensorCal.__index = SensorCal

--- The ordered walkthrough. Order is chosen so each step is self-consistent given the ones before:
--- the two attitude axes first (independent of everything), then the lateral pair and the medial
--- sensor (so their signs are known), and yaw LAST -- its rate sign is read from the now-calibrated
--- lateral pair, and its gimbal element from whatever gimbal channels pitch and roll did not claim.
--- Each prompt is DIRECTION-FIRST and kept short enough (<= 15 chars) to survive intact on the
--- narrowest cockpit monitor -- the operator's move IS the calibration, so the one word that says
--- which way (UP / RIGHT / FORWARD ...) must never be the casualty of a Theme.fit truncation. The
--- hint spells out the sign convention the move establishes; it is advisory and may be clipped.
local STEPS = {
  { id = "upright", kind = "upright",
    prompt = "IS IT UPRIGHT?", hint = "the down laser must see the ground" },
  { id = "pitch", kind = "gimbal", axis = "pitch",
    prompt = "PITCH NOSE UP", hint = "nose up = pitch +" },
  { id = "roll", kind = "gimbal", axis = "roll",
    prompt = "DIP RIGHT WING", hint = "right wing down = roll +" },
  { id = "slide", kind = "lateral",
    prompt = "SLIDE RIGHT", hint = "moving right = +x" },
  { id = "fwd", kind = "medial",
    prompt = "MOVE FORWARD", hint = "forward = +z" },
  { id = "yaw", kind = "yaw",
    prompt = "YAW NOSE RIGHT", hint = "nose right = yaw +" },
}
SensorCal.STEPS = STEPS

--- Shortest signed difference into (-180, 180], so a yaw move across the 0/360 seam reads as its
--- true small change rather than a near-360 jump.
local function wrap180(d)
  d = (d + 180) % 360 - 180
  if d <= -180 then d = d + 360 end
  return d
end

function SensorCal.new(cfg, log)
  local self = setmetatable({}, SensorCal)
  self.cfg = cfg
  self.log = log
  self.state = "idle"          -- idle | running | review
  self.index = 0               -- cursor into STEPS while running
  self.cur = nil               -- working data for the current step
  self.result = nil            -- accumulated learned mapping
  self.ready = nil             -- last checkReady verdict { ok, checks }
  self.detail = "idle"
  return self
end

function SensorCal:isRunning() return self.state == "running" end
function SensorCal:isActive() return self.state ~= "idle" end

--- Tunables, with defaults so an older config still calibrates.
function SensorCal:_tuning()
  local t = self.cfg.sensorCal or {}
  return {
    detectDeg = t.detectDeg or 12.0,     -- a gimbal axis must move at least this much to count
    detectVel = t.detectVel or 0.35,     -- a velocity sensor must read at least this (b/s)
    uprightMaxDist = t.uprightMaxDist or 15.0,  -- the down laser must see ground within this
  }
end

--[[ Record the prerequisite verdict. `checks` is a list of { name, ok, detail }; the caller (which
     can see the modes, sensors and hardware) decides each one. Purely advisory: START still refuses
     unless every check passed, but this lets the panel show WHICH one is red. ]]
function SensorCal:checkReady(checks)
  local ok = true
  for _, c in ipairs(checks or {}) do
    if not c.ok then ok = false end
  end
  self.ready = { ok = ok, checks = checks or {}, at = os.epoch("utc") }
  self.detail = ok and "ready -- press START" or "not ready"
  return self.ready
end

--- Begin the walkthrough. Refuses unless the last checkReady passed (and it must be recent-ish --
--- the caller re-runs it right before, so a stale green cannot let a moving craft into calibration).
function SensorCal:start()
  if not (self.ready and self.ready.ok) then
    return false, "run CHECK READY first", "NOT READY"
  end
  self.state = "running"
  self.index = 1
  self.result = { gimbal = {}, velocity = {}, yawRateSign = nil }
  self:_armStep()
  self.log:info("SENSOR CAL: started")
  return true
end

--- Abort from any state.
function SensorCal:abort(reason)
  if self.state == "idle" then return false end
  self.state = "idle"
  self.index = 0
  self.cur = nil
  self.detail = "aborted"
  self.log:info("SENSOR CAL: aborted (%s)", tostring(reason or "operator"))
  return true
end

function SensorCal:_step() return STEPS[self.index] end

--- Arm the current step: clear its detection and baseline so the next observe re-references.
function SensorCal:_armStep()
  local step = self:_step()
  self.cur = { baseline = nil, detected = nil }
  self.detail = step and step.prompt or "?"
end

--- Re-arm the current step -- the operator wants to redo the move (baseline reset).
function SensorCal:retry()
  if self.state ~= "running" then return false end
  self:_armStep()
  return true
end

--[[ One observation. `sample`:
       rawAngles   the gimbal's raw element array (pre-map), or nil
       velRaw      { lateralFront=, lateralRear=, medial= } PRE-invert values, or nil
       groundDist  the down laser distance in blocks, or nil
     Detects the dominant change for the current step and parks it in cur.detected. Advancing is a
     separate, explicit confirm() -- the operator does the move, sees what was detected, THEN locks. ]]
function SensorCal:observe(sample)
  if self.state ~= "running" then return end
  local step = self:_step()
  if not step then return end
  sample = sample or {}
  local tuning = self:_tuning()

  if step.kind == "upright" then
    -- No detection -- just report whether the laser can see the ground, so the operator confirms
    -- against a real reading rather than a claim. The confirm is what sets the reference.
    local d = sample.groundDist
    if type(d) == "number" and d <= tuning.uprightMaxDist then
      self.cur.detected = { ok = true, dist = d }
      self.detail = ("ground seen at %.1f -- confirm UPRIGHT"):format(d)
    else
      self.cur.detected = nil
      self.detail = "no ground below -- put it on the pad"
    end
    return
  end

  if step.kind == "gimbal" or step.kind == "yaw" then
    local angles = sample.rawAngles
    if type(angles) ~= "table" or #angles == 0 then
      self.detail = "no gimbal reading"
      return
    end
    if not self.cur.baseline then
      self.cur.baseline = {}
      for i = 1, #angles do self.cur.baseline[i] = angles[i] or 0 end
    end
    -- Do not re-pick an element pitch or roll already claimed: yaw must land on a fresh channel.
    local used = {}
    for _, r in pairs(self.result.gimbal) do used[r.index] = true end
    local bestI, bestDelta = nil, 0
    for i = 1, #angles do
      if not used[i] then
        local delta = wrap180((angles[i] or 0) - (self.cur.baseline[i] or 0))
        if math.abs(delta) > math.abs(bestDelta) then bestI, bestDelta = i, delta end
      end
    end
    -- Also read the lateral pair under a yaw, so the yaw-rate SIGN can be locked to the same move.
    local yawRateSign
    if step.kind == "yaw" and sample.velRaw then
      local lf, lr = sample.velRaw.lateralFront, sample.velRaw.lateralRear
      if type(lf) == "number" and type(lr) == "number" then
        -- Signs already calibrated (slide step), so + means "reads right". Under a nose-right yaw
        -- the front swings right and the rear left, so (front - rear) > 0 for a positive yaw.
        local diff = lf - lr
        if math.abs(diff) >= tuning.detectVel then yawRateSign = (diff >= 0) and 1 or -1 end
      end
    end
    local haveGimbal = bestI ~= nil and math.abs(bestDelta) >= tuning.detectDeg
    if haveGimbal or yawRateSign ~= nil then
      self.cur.detected = {
        index = haveGimbal and bestI or nil,
        sign = haveGimbal and ((bestDelta >= 0) and 1 or -1) or nil,
        delta = haveGimbal and bestDelta or nil,
        yawRateSign = yawRateSign,
      }
      local parts = {}
      if haveGimbal then parts[#parts + 1] = ("elem %d %+.0f deg"):format(bestI, bestDelta) end
      if yawRateSign then parts[#parts + 1] = "yaw-rate seen" end
      self.detail = table.concat(parts, ", ") .. " -- confirm"
    else
      self.cur.detected = nil
      self.detail = "do the move"
    end
    return
  end

  if step.kind == "lateral" or step.kind == "medial" then
    local v = sample.velRaw or {}
    if step.kind == "lateral" then
      local lf, lr = v.lateralFront, v.lateralRear
      local haveF = type(lf) == "number" and math.abs(lf) >= tuning.detectVel
      local haveR = type(lr) == "number" and math.abs(lr) >= tuning.detectVel
      -- Whichever laterals are present must clearly move; a craft with only one lateral still
      -- calibrates that one. invert is set so the RAW motion reads positive for "slide right".
      if (lf == nil or haveF) and (lr == nil or haveR) and (haveF or haveR) then
        self.cur.detected = {
          lateralFront = (lf ~= nil) and { invert = lf < 0 } or nil,
          lateralRear = (lr ~= nil) and { invert = lr < 0 } or nil,
        }
        self.detail = "lateral seen -- confirm"
      else
        self.cur.detected = nil
        self.detail = step.prompt .. " (" .. step.hint .. ")"
      end
    else
      local m = v.medial
      if type(m) == "number" and math.abs(m) >= tuning.detectVel then
        self.cur.detected = { medial = { invert = m < 0 } }
        self.detail = "medial seen -- confirm"
      else
        self.cur.detected = nil
        self.detail = step.prompt .. " (" .. step.hint .. ")"
      end
    end
    return
  end
end

--[[ Lock the current step's detection into the result and advance. The upright step needs only a
     valid ground reading; every motion step needs a detection to exist. Returns ok, err, short. ]]
function SensorCal:confirm()
  if self.state == "review" then
    return false, "press APPLY to write it", "AT REVIEW"
  end
  if self.state ~= "running" then
    return false, "not calibrating", "IDLE"
  end
  local step = self:_step()
  local det = self.cur and self.cur.detected
  if not det then
    return false, "do the move first", "NO READING"
  end

  if step.kind == "gimbal" then
    self.result.gimbal[step.axis] = { index = det.index, sign = det.sign }
  elseif step.kind == "yaw" then
    if det.index then self.result.gimbal.yaw = { index = det.index, sign = det.sign } end
    if det.yawRateSign then self.result.yawRateSign = det.yawRateSign end
  elseif step.kind == "lateral" then
    if det.lateralFront then self.result.velocity.lateralFront = det.lateralFront end
    if det.lateralRear then self.result.velocity.lateralRear = det.lateralRear end
  elseif step.kind == "medial" then
    self.result.velocity.medial = det.medial
  end
  -- upright: nothing to store; the confirm IS the operator asserting the craft is the right way up.

  self.index = self.index + 1
  if self.index > #STEPS then
    self.state = "review"
    self.detail = "review, then APPLY"
    self.log:info("SENSOR CAL: walkthrough complete, awaiting apply")
  else
    self:_armStep()
  end
  return true
end

--- The learned mapping, once state == "review". The app turns this into config and saves it.
function SensorCal:takeResult()
  local r = self.result
  self.state = "idle"
  self.index = 0
  self.cur = nil
  self.detail = "applied"
  return r
end

--- Everything a panel needs to render the walkthrough. Reported state only -- no optimism.
function SensorCal:facts()
  local step = self:_step()
  local det = self.cur and self.cur.detected
  return {
    state = self.state,                                   -- idle | running | review
    stepId = step and step.id or nil,
    stepIndex = self.state == "running" and self.index or nil,
    stepCount = #STEPS,
    prompt = step and step.prompt or nil,
    hint = step and step.hint or nil,
    detected = det ~= nil,                                -- is there something to confirm right now
    detail = self.detail,
    ready = self.ready and { ok = self.ready.ok, checks = self.ready.checks } or nil,
    result = (self.state == "review") and self.result or nil,
  }
end

return SensorCal
