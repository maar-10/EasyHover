--[[ CoM LEVELING: learn the trim that holds THIS loading level, by watching, not by flying.

     Unlike the self test or the axis map, this module is NOT a control owner. It never commands a
     thruster. It rides along beside the normal flight loop and just WATCHES: once the craft is
     hovering dead level and still for long enough, it proposes the steady torque the loop is
     already holding as a stored feedforward (see Attitude:steadyTorque / commitComTrim), so the
     PID integral no longer has to carry the centre-of-mass offset.

     That passivity is the whole robustness argument. There is no open-loop probing to destabilise,
     no attitude authority spent measuring the thing that provides attitude authority. If the nozzle
     maps are wrong the craft simply never settles, and the proposal never appears -- the failure
     mode is "nothing happens", not "loss of control".

     States: idle -> settling -> proposed. The app checks the hard prerequisites (airborne, engine
     on) before start(); this module owns only the "is it settled yet" judgement and the dwell.
]]

local ComLevel = {}
ComLevel.__index = ComLevel

function ComLevel.new(cfg, attitude, log)
  local self = setmetatable({}, ComLevel)
  self.cfg = cfg
  self.attitude = attitude
  self.log = log
  self.state = "idle"       -- idle | settling | proposed
  self.dwell = 0
  self.proposal = nil       -- { pitch, roll } once state == "proposed"
  self.detail = "idle"
  return self
end

function ComLevel:isRunning() return self.state == "settling" end
function ComLevel:hasProposal() return self.state == "proposed" end
function ComLevel:isActive() return self.state ~= "idle" end

--- Begin watching for a settled hover. Prerequisites are the caller's to enforce.
function ComLevel:start()
  self.state = "settling"
  self.dwell = 0
  self.proposal = nil
  self.detail = "hold a level hover"
  self.log:info("CoM leveling: watching for a settled level hover")
  return true
end

--- Stop, whatever state we are in. Used for the pilot's cancel and for control being taken over.
function ComLevel:cancel(reason)
  if self.state == "idle" then return false end
  self.state = "idle"
  self.dwell = 0
  self.proposal = nil
  self.detail = "idle"
  self.log:info("CoM leveling: stopped (%s)", tostring(reason or "cancelled"))
  return true
end

--[[ One cycle of watching. `sample` describes the craft right now:
       pitch, roll          measured attitude, degrees
       pitchRate, rollRate  body rates, deg/s
       verticalSpeed        m/s
       angleMode            true when the loop is holding an angle (not a rate)
       levelDemand          true when the pilot is NOT commanding a tilt
       airborne             true when off the ground
     Does nothing unless we are in the settling state.
]]
function ComLevel:observe(sample, dt)
  if self.state ~= "settling" then return end
  local cl = self.cfg.control.comLevel
  sample = sample or {}

  -- Each guard has its own hint, so the pilot on the monitor knows what is blocking the reading
  -- rather than watching an unexplained "not settled".
  local block
  if not sample.airborne then block = "get airborne first"
  elseif not sample.angleMode then block = "needs angle mode"
  elseif not sample.levelDemand then block = "release the sticks"
  elseif math.abs(sample.pitch or 99) > cl.angleTolDeg
      or math.abs(sample.roll or 99) > cl.angleTolDeg then block = "level it off"
  elseif math.abs(sample.pitchRate or 99) > cl.rateTolDps
      or math.abs(sample.rollRate or 99) > cl.rateTolDps then block = "let it stop turning"
  elseif math.abs(sample.verticalSpeed or 99) > cl.vsTolMps then block = "hold altitude"
  end

  if block then
    self.dwell = 0
    self.detail = block
    return
  end

  self.dwell = self.dwell + math.max(dt or 0, 0)
  if self.dwell >= cl.dwellSec then
    self.proposal = self.attitude:steadyTorque()
    self.state = "proposed"
    self.detail = "review and accept"
    self.log:info("CoM leveling: settled -- proposing pitch %.3f roll %.3f",
      self.proposal.pitch, self.proposal.roll)
  else
    self.detail = ("settling %.1f / %.1f s"):format(self.dwell, cl.dwellSec)
  end
end

--- Hand the proposal to the caller (which commits it to the attitude loop and config) and reset.
function ComLevel:takeProposal()
  local p = self.proposal
  self.state = "idle"
  self.dwell = 0
  self.proposal = nil
  self.detail = "idle"
  return p
end

--- Everything a UI needs to render the walkthrough.
function ComLevel:facts()
  local ct = self.attitude:getComTrim()
  return {
    state = self.state,                        -- idle | settling | proposed
    dwell = self.dwell,
    dwellTarget = self.cfg.control.comLevel.dwellSec,
    proposal = self.proposal and { pitch = self.proposal.pitch, roll = self.proposal.roll } or nil,
    detail = self.detail,
    comTrim = { pitch = ct.pitch, roll = ct.roll },
  }
end

return ComLevel
