--[[ The relay: get the fix off the nav computer and onto the craft's wired network.

     TWO MODEMS, TWO JOBS, and keeping them apart is the point of this file:

       * the ENDER modem talks to the GPS constellation and to the beacon mesh. It is the only
         thing on this craft with a radio, and it is RECEIVE-ONLY as far as control goes: it
         fetches position, it never carries a command.
       * the WIRED modem carries the fix to the flight computer and the cockpit screens, on the
         same cable as all the other craft traffic.

     That split is why the control surface stays off the air even though navigation needs a
     radio. Nothing that can move the craft ever crosses the ender link -- see docs/WIRING.md.

     The flight computer already anticipates this: `comms.navFixProtocol` has been in its config
     since phase 5, so nothing on the craft needs changing to start listening.
]]

local Relay = {}
Relay.__index = Relay

function Relay.new(cfg, log)
  local self = setmetatable({}, Relay)
  self.cfg = cfg
  self.log = log
  self.wired = nil
  self.wireless = nil
  self.published = 0
  self.seq = 0
  return self
end

--- Find a modem of a particular kind. Wired and wireless are told apart by isWireless(), which
--- is the same test gps.locate() uses -- so "the modem GPS will pick" and "the modem we open for
--- GPS" cannot disagree.
local function findModem(wantWireless)
  for _, name in ipairs(peripheral.getNames()) do
    local ok, wireless = pcall(function()
      if peripheral.hasType and not peripheral.hasType(name, "modem") then return nil end
      local dev = peripheral.wrap(name)
      if dev == nil or dev.isWireless == nil then return nil end
      return dev.isWireless()
    end)
    if ok and wireless == wantWireless then return name end
  end
  return nil
end

Relay.findModem = findModem

--- Open both links. Reports what it found either way: a nav computer with only one modem still
--- half works, and which half is missing decides what to tell the pilot.
function Relay:open()
  self.wired = (self.cfg.wiredModem ~= "" and self.cfg.wiredModem) or findModem(false)
  self.wireless = (self.cfg.enderModem ~= "" and self.cfg.enderModem) or findModem(true)

  if self.wired then
    local ok = pcall(rednet.open, self.wired)
    if not ok then
      self.log:error("could not open rednet on the wired modem %s", tostring(self.wired))
      self.wired = nil
    end
  else
    self.log:error("no WIRED modem: fixes cannot reach the craft's other computers")
  end

  if self.wireless == nil then
    self.log:error("no WIRELESS modem: gps.locate() has nothing to transmit on")
  else
    local interdimensional = false
    pcall(function()
      local dev = peripheral.wrap(self.wireless)
      interdimensional = dev.isInterdimensional and dev.isInterdimensional() or false
    end)
    self.log:info("GPS link on %s (%s)", self.wireless,
      interdimensional and "ender: unlimited range in this dimension"
        or "wireless: LIMITED range -- an ender modem removes the limit")
  end

  return self.wired ~= nil, self.wireless ~= nil
end

function Relay:close()
  if self.wired then pcall(rednet.close, self.wired) end
  self.wired = nil
end

--- Publish a fix on the wired network.
---
--- The payload carries the fix's AGE, SOURCE and QUALITY, and whether it is dead-reckoned --
--- everything a consumer needs to decide whether to act on it. A bare x/y/z would force every
--- reader to trust it, and the one thing we know about a position is that sometimes it is stale.
function Relay:publish(position, extra)
  if not self.wired then return false, "no wired modem" end
  if position == nil then return false, "no position" end

  self.seq = self.seq + 1
  local payload = {
    proto = "ehnav1",
    seq = self.seq,
    role = "nav",
    t = os.epoch("utc"),
    position = {
      x = position.x, y = position.y, z = position.z,
      source = position.source, quality = position.quality,
      ageMs = position.ageMs, dead = position.dead and true or false,
      stale = position.stale and true or false,
    },
  }
  if extra then
    for key, value in pairs(extra) do
      if payload[key] == nil then payload[key] = value end
    end
  end

  local ok = pcall(rednet.broadcast, payload, self.cfg.navFixProtocol)
  if ok then self.published = self.published + 1 end
  return ok
end

function Relay:status()
  return {
    wired = self.wired,
    wireless = self.wireless,
    published = self.published,
    seq = self.seq,
  }
end

return Relay
