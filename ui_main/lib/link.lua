--[[ Telemetry client and command sender for the UI computer.

     Subscribes to the flight computer's broadcast and keeps the LATEST payload with its age.
     Nothing here retries or buffers: a UI showing a two-second-old number as if it were live
     is worse than a UI saying STALE, so age is a first-class part of the model.

     Commands go the other way on the command protocol. The flight computer whitelists and
     type-checks every one of them on arrival, so this side does not pretend to be trusted --
     it just sends and reports the acknowledgement.
]]

local Util = require("shared.util")

local Link = {}
Link.__index = Link

function Link.new(cfg, log)
  local self = setmetatable({}, Link)
  self.cfg = cfg
  self.log = log
  self.modem = nil
  self.latest = nil          -- the last telemetry payload
  self.receivedAt = nil      -- epoch ms when it arrived
  self.flightId = nil        -- which computer is flying
  self.messages = 0
  self.lastAck = nil
  return self
end

--- Open rednet on a wired modem. Wired only, same reasoning as the flight side.
function Link:open()
  local name = self.cfg.comms.modem
  if name == nil or name == "" then
    for _, candidate in ipairs(peripheral.getNames()) do
      local ok, wireless = pcall(function()
        if peripheral.hasType and not peripheral.hasType(candidate, "modem") then return nil end
        local dev = peripheral.wrap(candidate)
        if dev and dev.isWireless then return dev.isWireless() end
        return nil
      end)
      if ok and wireless == false then
        name = candidate
        break
      end
    end
  end
  if name == nil or name == "" then
    self.log:warn("no wired modem: this computer cannot see the flight computer")
    return false, "no wired modem"
  end
  local ok, err = pcall(rednet.open, name)
  if not ok then
    self.log:error("rednet.open(%s) failed: %s", tostring(name), tostring(err))
    return false, tostring(err)
  end
  self.modem = name
  self.log:info("link open on %s", name)
  return true
end

function Link:isOpen()
  return self.modem ~= nil
end

--- Feed a rednet_message event. Returns "telemetry" | "ack" | nil.
function Link:onMessage(sender, message, protocol)
  if protocol == self.cfg.comms.telemetryProtocol then
    if type(message) ~= "table" or message.proto ~= "eh1" then return nil end
    -- MERGED, NOT REPLACED. A frame that omits a field must not erase what we already knew: the
    -- craft sends the big, slow-changing parts of the payload only occasionally, so wholesale
    -- replacement would blank thrusterAxes, candidates and layout on every frame in between --
    -- which is how the AXIS MAP and THR AXES screens came to read "no thrusters" while the config
    -- pages, reading a different field, listed them correctly.
    --
    -- deepMerge takes the new value wherever the frame HAS one and keeps the old where it does
    -- not. Lists are replaced wholesale, so an emptied list still empties.
    self.latest = Util.deepMerge(self.latest or {}, message)
    self.receivedAt = os.epoch("utc")
    self.flightId = sender
    self.messages = self.messages + 1
    return "telemetry"
  elseif protocol == self.cfg.comms.commandProtocol then
    if type(message) == "table" and message.ack ~= nil then
      self.lastAck = message
      if not message.ack then
        self.log:warn("command rejected: %s", textutils.serialise(message.detail or message.error or {}))
      end
      return "ack"
    end
  end
  return nil
end

--- Age of the newest telemetry, in ms. math.huge when nothing has arrived.
function Link:age()
  if not self.receivedAt then return math.huge end
  return os.epoch("utc") - self.receivedAt
end

function Link:isStale()
  return self:age() > (self.cfg.comms.staleMs or 2000)
end

--- The model every panel renders from. Always a table, never nil, and it always says whether
--- the numbers in it can be trusted.
function Link:model()
  local payload = self.latest
  return {
    connected = payload ~= nil and not self:isStale(),
    stale = self:isStale(),
    ageMs = self:age(),
    flightId = self.flightId,
    telemetry = payload,
  }
end

--- Send a command to the flight computer. Broadcast when we have not seen it yet, so the very
--- first command does not have to wait for a telemetry frame.
function Link:send(cmd)
  if not self.modem then return false, "link not open" end
  local ok
  if self.flightId then
    ok = pcall(rednet.send, self.flightId, cmd, self.cfg.comms.commandProtocol)
  else
    ok = pcall(rednet.broadcast, cmd, self.cfg.comms.commandProtocol)
  end
  if not ok then self.log:warn("could not send %s", tostring(cmd.cmd)) end
  return ok
end

function Link:close()
  if self.modem then pcall(rednet.close, self.modem) end
  self.modem = nil
end

return Link
