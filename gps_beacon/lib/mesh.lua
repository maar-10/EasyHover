--[[ The beacon mesh: every beacon knows about the others.

     Separate from the GPS protocol on purpose. GPS is CC's, it is a wire format we do not own,
     and a host that answered pings with anything other than `{x,y,z}` would break locate() for
     every computer in the world. So peer status rides its own rednet protocol alongside it.

     What the mesh buys, and why it is worth a second protocol:

       * LINK STATUS -- which of the other three are alive, and how long since each was heard.
         A beacon that has crashed or been broken takes the whole constellation below four hosts
         and gps.locate() then returns nothing at all, with no error anywhere.
       * THE WHOLE CONSTELLATION'S COORDINATES, without anyone typing them four times. That is
         what makes an accuracy estimate possible on every beacon rather than on paper.
       * A DUPLICATE-COORDINATE CHECK. Two beacons configured with the same position is a
         copy-paste away, and it silently reduces the constellation to three usable hosts.

     No encryption, as specified. It is position data for a navigation aid on a private server;
     the cost of a shared key is real and the thing being protected is a set of coordinates the
     pilot could read off a signpost.
]]

local Geometry = require("lib.geometry")

local Mesh = {}
Mesh.__index = Mesh

function Mesh.new(cfg, log)
  local self = setmetatable(({}), Mesh)
  self.cfg = cfg
  self.log = log
  self.peers = {}        -- id -> { id, label, position, lastAt, uptime }
  self.modem = nil
  self.sent = 0
  self.received = 0
  return self
end

function Mesh:open(modemName)
  if modemName == nil or modemName == "" then return false, "no modem" end
  local ok, err = pcall(rednet.open, modemName)
  if not ok then
    self.log:error("could not open rednet on %s: %s", tostring(modemName), tostring(err))
    return false, tostring(err)
  end
  self.modem = modemName
  return true
end

function Mesh:close()
  if self.modem then pcall(rednet.close, self.modem) end
  self.modem = nil
end

--- Announce ourselves. Called on a timer; cheap and idempotent.
function Mesh:announce(now)
  if not self.modem then return false end
  local payload = {
    proto = "ehgps1",
    id = os.getComputerID(),
    label = self.cfg.label,
    position = {
      x = self.cfg.position.x, y = self.cfg.position.y, z = self.cfg.position.z,
    },
    enabled = self.cfg.enabled and true or false,
    served = self.served or 0,
    at = now or os.epoch("utc"),
  }
  local ok = pcall(rednet.broadcast, payload, self.cfg.meshProtocol)
  if ok then self.sent = self.sent + 1 end
  return ok
end

--- Take in a peer's announcement. Returns true when it was one of ours.
function Mesh:onMessage(sender, message, protocol, now)
  if protocol ~= self.cfg.meshProtocol then return false end
  if type(message) ~= "table" or message.proto ~= "ehgps1" then return false end
  if message.id == os.getComputerID() then return false end   -- our own broadcast coming back

  now = now or os.epoch("utc")
  local position = message.position
  if type(position) ~= "table" or type(position.x) ~= "number" then return false end

  local known = self.peers[message.id]
  if known == nil then
    self.log:info("beacon %s (id %d) joined the mesh", tostring(message.label), message.id)
  end
  self.peers[message.id] = {
    id = message.id,
    label = message.label or ("id " .. tostring(message.id)),
    position = { x = position.x, y = position.y, z = position.z },
    enabled = message.enabled and true or false,
    served = message.served or 0,
    lastAt = now,
  }
  self.received = self.received + 1
  return true
end

--- Peers heard from recently enough to count, plus the stale ones, listed separately.
function Mesh:linkStatus(now)
  now = now or os.epoch("utc")
  local timeout = self.cfg.peerTimeoutMs or 15000
  local alive, lost = {}, {}
  for _, peer in pairs(self.peers) do
    local age = now - peer.lastAt
    local row = {
      id = peer.id, label = peer.label, position = peer.position,
      enabled = peer.enabled, ageMs = age,
    }
    if age <= timeout then alive[#alive + 1] = row else lost[#lost + 1] = row end
  end
  local function byLabel(a, b) return tostring(a.label) < tostring(b.label) end
  table.sort(alive, byLabel)
  table.sort(lost, byLabel)
  return alive, lost
end

--- The whole constellation as gps.locate() would see it: us, plus every live peer that is
--- enabled. A disabled beacon does not answer pings, so it must not count toward the four.
function Mesh:constellation(now)
  local hosts = {}
  if self.cfg.enabled and type(self.cfg.position.x) == "number" then
    hosts[#hosts + 1] = {
      x = self.cfg.position.x, y = self.cfg.position.y, z = self.cfg.position.z,
      label = self.cfg.label, self_ = true,
    }
  end
  local alive = self:linkStatus(now)
  for _, peer in ipairs(alive) do
    if peer.enabled then
      hosts[#hosts + 1] = {
        x = peer.position.x, y = peer.position.y, z = peer.position.z,
        label = peer.label, id = peer.id,
      }
    end
  end
  return hosts
end

--- Assess the live constellation, and add the mesh's own findings to the problem list.
function Mesh:assess(now)
  local hosts = self:constellation(now)
  local assessment = Geometry.assess(hosts)
  assessment.hosts = hosts

  -- Two beacons on the same coordinates is a copy-paste away and quietly costs a host.
  for i = 1, #hosts do
    for j = i + 1, #hosts do
      if Geometry.distance(hosts[i], hosts[j]) < 1e-6 then
        assessment.usable = false
        assessment.grade = "UNUSABLE"
        assessment.problems[#assessment.problems + 1] =
          ("%s and %s are configured at the SAME position -- one of them is a copy"):format(
            tostring(hosts[i].label), tostring(hosts[j].label))
      end
    end
  end

  local _, lost = self:linkStatus(now)
  for _, peer in ipairs(lost) do
    assessment.problems[#assessment.problems + 1] =
      ("%s has not been heard from for %.0fs"):format(tostring(peer.label), peer.ageMs / 1000)
  end
  return assessment
end

function Mesh:stats()
  return { sent = self.sent, received = self.received, peers = self.peers }
end

return Mesh
