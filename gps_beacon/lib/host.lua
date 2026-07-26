--[[ The GPS host: answer gps.locate()'s pings, and check our own coordinates are right.

     THE PROTOCOL IS CC'S OWN, verified against rom/apis/gps.lua rather than remembered:

       * channel 65534 (`gps.CHANNEL_GPS`), reply channel the same
       * the request payload is the string "PING"
       * the reply is a THREE-ELEMENT ARRAY `{ x, y, z }` -- locate() checks `#tMessage == 3`
         and `tonumber()` on each, so a keyed table `{x=,y=,z=}` is silently ignored

     Using CC's protocol rather than a private one means `gps.locate()` on the craft works
     unmodified, and so does any other computer, turtle or pocket computer in range.

     SELF-VERIFICATION IS THE POINT OF THIS FILE. A beacon with a typo'd coordinate does not
     fail -- it answers confidently and every fix in the world is quietly wrong by however far
     the typo was. Once four beacons are up, each one can run gps.locate() itself and compare
     the answer to what it believes. That is the only way to catch it.
]]

local Host = {}
Host.__index = Host

--- CC's GPS channel. Hardcoded rather than read from the `gps` API so this module can be
--- tested without one, and because the value is part of a wire protocol we do not own.
Host.CHANNEL = 65534
Host.PING = "PING"

function Host.new(cfg, log)
  local self = setmetatable({}, Host)
  self.cfg = cfg
  self.log = log
  self.modem = nil
  self.served = 0
  self.lastServedAt = nil
  self.selfCheck = { state = "unchecked" }
  return self
end

--- The reply payload for a ping. A plain array, in x/y/z order.
function Host.reply(position)
  return { position.x, position.y, position.z }
end

--- Is this a ping we should answer? Kept separate so the decision is testable without a modem.
function Host.isPing(channel, replyChannel, message)
  return channel == Host.CHANNEL
    and replyChannel == Host.CHANNEL
    and message == Host.PING
end

--- Attach to a wireless modem and open the GPS channel.
---
--- Wireless specifically: a wired modem cannot carry GPS, and gps.locate() on the other end
--- only considers modems whose isWireless() is true. An ender modem qualifies and has unlimited
--- range WITHIN A DIMENSION -- a cross-dimension reply arrives with no distance and locate()
--- discards it, so a beacon in another world is worse than useless, it is invisible.
function Host:open()
  local name = self.cfg.modem
  if name == nil or name == "" then
    for _, candidate in ipairs(peripheral.getNames()) do
      local ok, wireless = pcall(function()
        if peripheral.hasType and not peripheral.hasType(candidate, "modem") then return nil end
        local dev = peripheral.wrap(candidate)
        return dev and dev.isWireless and dev.isWireless() or nil
      end)
      if ok and wireless == true then
        name = candidate
        break
      end
    end
  end

  if name == nil or name == "" then
    self.log:error("no WIRELESS modem found -- a GPS beacon cannot work without one")
    return false, "no wireless modem"
  end

  local dev = peripheral.wrap(name)
  if not dev then return false, "cannot wrap " .. tostring(name) end
  local ok, err = pcall(dev.open, Host.CHANNEL)
  if not ok then return false, tostring(err) end

  self.modem = dev
  self.modemName = name
  local interdimensional = false
  pcall(function() interdimensional = dev.isInterdimensional and dev.isInterdimensional() end)
  self.log:info("GPS host open on %s (channel %d, %s)", name, Host.CHANNEL,
    interdimensional and "ender: unlimited range in this dimension" or "wireless: limited range")
  return true
end

function Host:close()
  if self.modem then pcall(self.modem.close, Host.CHANNEL) end
  self.modem = nil
end

--- Handle one modem_message. Returns true when it was a ping we answered.
function Host:onModemMessage(side, channel, replyChannel, message)
  if not self.modem then return false end
  if not Host.isPing(channel, replyChannel, message) then return false end
  if not self.cfg.enabled then return false end

  local position = self.cfg.position
  if type(position.x) ~= "number" or type(position.y) ~= "number"
    or type(position.z) ~= "number" then
    self.log:throttled("nocoords", 10000, "error",
      "a ping arrived but this beacon has no coordinates set -- not answering")
    return false
  end

  self.modem.transmit(Host.CHANNEL, Host.CHANNEL, Host.reply(position))
  self.served = self.served + 1
  self.lastServedAt = os.epoch("utc")
  return true
end

-- ------------------------------------------------------------- self checking

--- Compare what gps.locate() says about us to what we believe.
---
--- `locate` is injected so this is testable; in production it is `gps.locate`. Needs the OTHER
--- beacons up: a constellation cannot fix its own first member.
function Host:verify(locate, timeout)
  local position = self.cfg.position
  if type(position.x) ~= "number" then
    self.selfCheck = { state = "no coordinates set" }
    return self.selfCheck
  end

  local ok, x, y, z = pcall(locate, timeout or 2)
  if not ok or type(x) ~= "number" then
    self.selfCheck = {
      state = "no fix",
      detail = "the other beacons are not answering, or there are fewer than four",
    }
    return self.selfCheck
  end

  local dx, dy, dz = x - position.x, y - position.y, z - position.z
  local error = math.sqrt(dx * dx + dy * dy + dz * dz)
  self.selfCheck = {
    state = (error <= (self.cfg.selfCheckTolerance or 1.0)) and "ok" or "MISMATCH",
    error = error,
    located = { x = x, y = y, z = z },
    configured = { x = position.x, y = position.y, z = position.z },
    at = os.epoch("utc"),
  }
  if self.selfCheck.state == "MISMATCH" then
    -- Loud, because this is the failure that otherwise never announces itself: every fix the
    -- craft takes is wrong by roughly this much and nothing else would ever say so.
    self.log:error("SELF CHECK FAILED: GPS puts this beacon %.1f blocks from its configured "
      .. "position (%d,%d,%d vs %d,%d,%d). One beacon's coordinates are wrong.",
      error, x, y, z, position.x, position.y, position.z)
  else
    self.log:info("self check ok (%.2f blocks)", error)
  end
  return self.selfCheck
end

function Host:status()
  return {
    open = self.modem ~= nil,
    modem = self.modemName,
    enabled = self.cfg.enabled and true or false,
    served = self.served,
    lastServedAt = self.lastServedAt,
    position = self.cfg.position,
    selfCheck = self.selfCheck,
  }
end

return Host
