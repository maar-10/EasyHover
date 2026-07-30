--[[ The navigation computer.

     One job, two halves: work out where the craft is, and tell the rest of the craft.

     It does NOT fly anything. No mixer, no PID, no thruster ever touched from here -- which is
     what lets navigation exist before the autopilot does. Guidance will live on the flight
     computer when it arrives (docs/NAVIGATION.md s4); this computer only ever answers "where".

     TWO MODEMS: the ender modem for GPS and the beacon mesh, the wired modem for the craft. The
     radio never carries a command, which is how the control surface stays off the air even though
     navigation needs a radio.

     TWO COROUTINES: gps.locate() BLOCKS for up to two seconds, so the service loop owns it and
     the UI loop owns the keyboard. Only the UI draws, so a fix landing mid-prompt cannot scribble
     over what is being typed.

     HEADING COMES FROM THE FLIGHT COMPUTER, over telemetry -- this computer has no gimbal of its
     own. Without a heading, dead reckoning cannot rotate craft-frame velocity into world axes at
     all, so Fix:reckon refuses rather than integrating garbage, and the screen says so.
]]

local Config = require("lib.config")
local Fix = require("lib.fix")
local Sources = require("lib.sources")
local Relay = require("lib.relay")
local Waypoints = require("lib.waypoints")
local Geo = require("lib.geo")
local Heading = require("lib.heading")
local NavTable = require("lib.navtable")
local NavCommand = require("lib.navcommand")
local Disk = require("lib.disk")
local Console = require("ui.console")
local Log = require("shared.log")

local App = {}
App.__index = App

local CONFIG_PATH = "/eh_nav_config.tbl"
local TICK_SECONDS = 1

function App.new(opts)
  opts = opts or {}
  local self = setmetatable({}, App)
  self.configPath = opts.configPath or CONFIG_PATH

  local cfg, existed = Config.load(self.configPath)
  self.cfg = cfg
  self.configExisted = existed
  -- echo = false: the log must not print over the screen; problems reach the operator through
  -- the screen, which is where they can act on them.
  self.log = Log.new({ level = "info", capacity = 120, echo = false })

  local ok, errors, warnings = Config.validate(cfg)
  self.configValid = ok
  self.problems = {}
  for _, e in ipairs(errors or {}) do
    self.log:error("config: %s", e)
    self.problems[#self.problems + 1] = e
  end
  for _, w in ipairs(warnings or {}) do self.log:warn("config: %s", w) end

  self.fix = Fix.new(cfg, self.log)
  self.relay = Relay.new(cfg, self.log)
  self.waypoints = Waypoints.new(cfg.waypointsPath, self.log)

  -- Heading model. In "gimbal" mode the raw telemetry yaw stands in as a relative heading; in
  -- "navtable"/"auto" the navigation table gives an absolute true-north reference and the gimbal
  -- is the Backup basic heading between reads. See lib/heading.lua.
  self.heading = Heading.new({
    navSign = cfg.navSign,
    gimbalSign = cfg.gimbalSign,
    staleMs = cfg.navHeadingStaleMs,
    rawGimbalOk = (cfg.headingSource ~= "navtable"),
  })

  -- Craft-frame velocity from telemetry, for dead reckoning. Heading now lives in self.heading.
  self.craft = { forward = 0, right = 0, altitude = nil, at = nil }

  self.lastFixAt = 0
  self.lastReckonAt = nil
  self.running = false
  self.dirty = true
  return self
end

function App:boot()
  self.log:info("EasyHover nav booting (config %s)", self.configExisted and "loaded" or "defaults")

  local wired, wireless = self.relay:open()
  if not wired then
    self.problems[#self.problems + 1] = "no WIRED modem: the craft cannot hear our fixes"
  end
  if not wireless then
    self.problems[#self.problems + 1] = "no WIRELESS modem: gps.locate() has nothing to send on"
  end

  local built, problems = Sources.build(self.cfg, self.log)
  for _, source in ipairs(built) do self.fix:addSource(source) end
  for _, problem in ipairs(problems) do self.problems[#self.problems + 1] = problem end

  local ok, msg = self:wireHeadingSource()
  if ok then
    self.log:info("heading: %s", msg)
  else
    self.problems[#self.problems + 1] = msg
  end

  local loaded, count, dropped = self.waypoints:load()
  if loaded then
    self.log:info("%d waypoint(s) loaded%s", count,
      (dropped or 0) > 0 and (", %d invalid and skipped"):format(dropped) or "")
  else
    self.problems[#self.problems + 1] = "the waypoint file will not parse -- it was left alone"
  end

  return self.configValid
end

--- Flight telemetry, for the heading and craft-frame velocity dead reckoning needs.
function App:onTelemetry(sender, message, protocol)
  if protocol ~= self.cfg.telemetryProtocol then return false end
  if type(message) ~= "table" or message.proto ~= "eh1" then return false end

  local attitude = message.attitude or {}
  local velocity = message.velocity or {}
  -- The gimbal yaw feeds the heading model, which owns sign and true-north calibration.
  self.heading:updateGimbal(type(attitude.yaw) == "number" and attitude.yaw or nil)
  -- The velocity sensors read along the craft's own axes; z is forward, x is right.
  self.craft.forward = type(velocity.z) == "number" and velocity.z or 0
  self.craft.right = type(velocity.x) == "number" and velocity.x or 0
  self.craft.altitude = (message.altitude or {}).baro
  self.craft.at = os.epoch("utc")
  return true
end

--- Point the heading model at the configured source. Returns ok, message. Shared by boot and by
--- the setHeadingSource / setNavTable commands, so a change takes effect without a reboot. The
--- reader re-resolves lazily, so a table plugged in later begins working on its own.
function App:wireHeadingSource()
  -- In gimbal-only mode the raw yaw stands in as a relative heading; otherwise an un-aligned craft
  -- honestly has no heading rather than a plausible-looking wrong one. See lib/heading.lua.
  self.heading.rawGimbalOk = (self.cfg.headingSource ~= "navtable")

  if self.cfg.headingSource == "gimbal" then
    self.heading:setSource(nil)
    return true, "gimbal only (relative heading)"
  end

  local dev, err, picked = NavTable.resolve(self.cfg.navTable)
  if dev then
    self.heading:setSource(NavTable.reader(self.cfg.navTable))
    return true, ("navigation table: %s"):format(tostring(picked))
  end

  -- No table. In "navtable" mode that is a real problem; in "auto" it just means gimbal for now.
  self.heading:setSource(nil)
  if self.cfg.headingSource == "navtable" then
    return false, "heading source is 'navtable' but " .. tostring(err)
  end
  return true, ("no navigation table (%s); using the gimbal"):format(tostring(err))
end

--- SELF ALIGN: force a fresh navigation-table read and re-true the heading to it. Returns ok, msg.
function App:selfAlign(now)
  return self.heading:align(now or os.epoch("utc"))
end

--- A validated command from the UI computer. Returns ok, detail. Config-changing commands SAVE
--- immediately, exactly as the flight side does, so a choice survives a reboot.
function App:handleCommand(cmd)
  local now = os.epoch("utc")
  if cmd.cmd == "navPing" then
    return true, { role = "nav" }

  elseif cmd.cmd == "setHeadingSource" then
    self.cfg.headingSource = cmd.source
    local ok, msg = self:wireHeadingSource()
    self:saveConfig()
    self.dirty = true
    return ok, { headingSource = cmd.source, detail = msg,
      errorShort = ok and nil or "NO TABLE" }

  elseif cmd.cmd == "setNavTable" then
    self.cfg.navTable = cmd.peripheral
    local ok, msg = self:wireHeadingSource()
    self:saveConfig()
    self.dirty = true
    return ok, { navTable = cmd.peripheral, detail = msg,
      errorShort = ok and nil or "NO TABLE" }

  elseif cmd.cmd == "setNavSign" then
    local sign = (cmd.sign < 0) and -1 or 1
    self.cfg.navSign = sign
    self.heading:setNavSign(sign)          -- clears the calibration; a SELF ALIGN re-trues it
    self:saveConfig()
    self.dirty = true
    return true, { navSign = sign, detail = "sign set -- SELF ALIGN to re-true" }

  elseif cmd.cmd == "setGimbalSign" then
    local sign = (cmd.sign < 0) and -1 or 1
    self.cfg.gimbalSign = sign
    self.heading:setGimbalSign(sign)
    self:saveConfig()
    self.dirty = true
    return true, { gimbalSign = sign, detail = "sign set -- SELF ALIGN to re-true" }

  elseif cmd.cmd == "selfAlign" then
    local ok, msg = self:selfAlign(now)
    self.dirty = true
    return ok, { detail = msg, errorShort = ok and nil or "NO TABLE" }
  end

  return false, { error = "unhandled command: " .. tostring(cmd.cmd) }
end

--- A message on the wired command protocol. Validate, apply, and ALWAYS reply -- a UI waiting on an
--- ack must never hang because a command was malformed or a handler threw. Returns whether it acted.
function App:onCommand(sender, message)
  local proto = self.cfg.navCommandProtocol
  local cmd, reason = NavCommand.parse(message, sender)
  if not cmd then
    self.log:warn("nav command rejected: %s", tostring(reason))
    self.relay:reply(sender, { ack = false,
      cmd = type(message) == "table" and message.cmd or nil,
      detail = { error = reason, errorShort = "BAD CMD" } }, proto)
    return false
  end

  local caught, ok, detail = pcall(self.handleCommand, self, cmd)
  if not caught then
    self.log:error("nav command %s FAILED: %s", tostring(cmd.cmd), tostring(ok))
    self.relay:reply(sender, { ack = false, cmd = cmd.cmd,
      detail = { error = tostring(ok), errorShort = "CMD ERROR" } }, proto)
    return false
  end

  self.log:info("nav command %s -> %s", cmd.cmd, ok and "ok" or "refused")
  self.relay:reply(sender, { ack = ok, cmd = cmd.cmd, detail = detail }, proto)
  return ok
end

--- The best position we can offer, altimeter altitude preferred over the fix's coarse block y.
function App:position(now)
  return self.fix:position(now, self.craft.altitude)
end

--- One service tick: take a fix if it is due, advance the estimate, publish.
function App:tick(now)
  now = now or os.epoch("utc")

  -- Keep the heading trued: poll the navigation table (free) and re-calibrate the gimbal offset.
  self.heading:tick(now)
  local headingInfo = self.heading:current(now)   -- { degrees, source, aligned } or nil
  local heading = headingInfo and headingInfo.degrees or nil

  if now - self.lastFixAt >= self.cfg.fixEverySeconds * 1000 then
    self.lastFixAt = now
    -- This BLOCKS. It is why the service loop exists and why nav is its own computer.
    self.fix:acquire(now)
    self.dirty = true
  end

  -- Dead reckoning between fixes, when there is a heading to rotate by.
  if self.lastReckonAt ~= nil and heading ~= nil then
    local dt = (now - self.lastReckonAt) / 1000
    if dt > 0 then
      self.fix:reckon(dt, self.craft.forward, self.craft.right, heading, now)
    end
  end
  self.lastReckonAt = now

  local position = self:position(now)
  if position then
    self.relay:publish(position, {
      heading = heading,                             -- degrees, kept a bare number for consumers
      headingSource = headingInfo and headingInfo.source or nil,  -- navtable|backup|gimbal
      headingAligned = headingInfo and headingInfo.aligned or nil,
      waypointCount = self.waypoints:count(),
      -- The nav CONFIG and the tables available, so the UI's NAV submenu can show what is selected
      -- and offer the alternatives without a request/response -- the same read-from-broadcast the
      -- rest of the cockpit uses. `config.headingSource` is what the pilot CHOSE; `headingSource`
      -- above is what the heading currently RESTS on, which differ when auto falls back to gimbal.
      config = {
        headingSource = self.cfg.headingSource,
        navTable = self.cfg.navTable,
        navSign = self.cfg.navSign,
        gimbalSign = self.cfg.gimbalSign,
      },
      navTables = NavTable.list(),                   -- candidate tables, for the picker
    })
  end
  return position
end

--- Everything the screen shows.
function App:model(now)
  now = now or os.epoch("utc")
  local position = self:position(now)
  return {
    position = position,
    heading = self.heading:current(now),   -- { degrees, source, ageMs, aligned } or nil
    link = self.relay:status(),
    stats = self.fix:stats(),
    waypointCount = self.waypoints:count(),
    nearest = position and self.waypoints:nearest(Geo, position) or {},
    problems = self.problems,
  }
end

function App:redraw()
  local width, height = term.getSize()
  Console.draw(Console.render(self.cfg, self:model(), width, height), width, height)
  self.dirty = false
end

-- ---------------------------------------------------------------- the loops

--- Radio, clock and the blocking fix. Never draws.
function App:service()
  self.timer = os.startTimer(TICK_SECONDS)
  while self.running do
    local event = { os.pullEvent() }
    local name = event[1]

    if name == "rednet_message" then
      local sender, message, protocol = event[2], event[3], event[4]
      if protocol == self.cfg.navCommandProtocol then
        -- A command from the UI. onCommand replies on its own; we only note a redraw is due.
        if self:onCommand(sender, message) then self.dirty = true end
      elseif self:onTelemetry(sender, message, protocol) then
        self.dirty = true
      end
    elseif name == "timer" and event[2] == self.timer then
      self:tick()
      self.timer = os.startTimer(TICK_SECONDS)
      if self.dirty and not self.prompting then self:redraw() end
    end
  end
end

--- Keyboard. Owns the screen.
function App:ui()
  self:redraw()
  while self.running do
    local _, key = os.pullEvent("char")
    local action = Console.actionFor(key)

    if action == "quit" then
      self.running = false
    elseif action == "fixNow" then
      self.lastFixAt = 0
      self:tick()
      self:redraw()
    elseif action == "mark" then
      self:promptMark()
      self:redraw()
    elseif action == "add" then
      self:promptAdd()
      self:redraw()
    elseif action == "delete" then
      self:promptDelete()
      self:redraw()
    elseif action == "list" then
      self:showList()
      self:redraw()
    elseif action == "selfAlign" then
      self:promptSelfAlign()
      self:redraw()
    elseif action == "disk" then
      self:promptDisk()
      self:redraw()
    end
  end
end

local function pause()
  print("")
  print("Press any key.")
  os.pullEvent("char")
end

function App:beginPrompt(title)
  self.prompting = true
  term.setBackgroundColour(colours.black)
  term.clear()
  term.setCursorPos(1, 1)
  print(title)
  print("")
end

--- MARK: a waypoint where we are standing.
---
--- Refuses a dead-reckoned or stale fix. A landing pad you cannot trust is worse than no pad,
--- because you would fly to it and find open air -- the refusal lives in Waypoints:mark, and this
--- only reports it.
function App:promptMark()
  self:beginPrompt("Mark a waypoint HERE")
  local position = self:position()
  if position == nil then
    print("No position fix. Nothing to mark.")
    pause(); self.prompting = false; return false
  end
  print(("at %s %s %s  from %s, %.1fs old"):format(
    Console.num(position.x), Console.num(position.y), Console.num(position.z),
    tostring(position.source), (position.ageMs or 0) / 1000))
  if position.dead then print("This is a BACKUP (estimated) position, not a fix.") end
  print("")

  local name, cancelled = Console.readName(read)
  if name == nil then
    print(tostring(cancelled)); pause(); self.prompting = false; return false
  end

  local ok, err = self.waypoints:mark(name, position, {
    maxAgeMs = self.cfg.markMaxAgeMs,
    minQuality = self.cfg.markMinQuality,
  })
  if not ok then
    print("REFUSED: " .. tostring(err))
    pause(); self.prompting = false; return false
  end

  local saved, saveErr = self.waypoints:save()
  if not saved then print("saved in memory but NOT to disk: " .. tostring(saveErr)) end
  print(("marked '%s'"):format(name))
  pause()
  self.prompting = false
  return true
end

--- ADD: a waypoint by typed coordinates, with a preview so a typo is obvious before it is saved.
function App:promptAdd()
  self:beginPrompt("Add a waypoint by coordinates")
  local name, cancelled = Console.readName(read)
  if name == nil then
    print(tostring(cancelled)); pause(); self.prompting = false; return false
  end

  local coords, err = Console.readCoords(read)
  if coords == nil then
    print(tostring(err)); pause(); self.prompting = false; return false
  end

  -- The preview is the point of typing them here rather than editing a file: a mis-keyed digit
  -- shows up as a distance that makes no sense, BEFORE it is stored.
  print("")
  print(Console.preview(self:position(), coords))
  print("")
  term.write("save? (y/N): ")
  local answer = tostring(read() or ""):lower()
  print()
  if answer ~= "y" and answer ~= "yes" then
    print("not saved")
    pause(); self.prompting = false; return false
  end

  local ok, addErr = self.waypoints:add({
    name = name, x = coords.x, y = coords.y, z = coords.z, source = "manual",
  })
  if not ok then
    print("REFUSED: " .. tostring(addErr))
    pause(); self.prompting = false; return false
  end
  local saved, saveErr = self.waypoints:save()
  if not saved then print("saved in memory but NOT to disk: " .. tostring(saveErr)) end
  print(("added '%s'"):format(name))
  pause()
  self.prompting = false
  return true
end

function App:promptDelete()
  self:beginPrompt("Delete a waypoint")
  for _, entry in ipairs(self.waypoints:all()) do
    print(("  %s  %d %d %d  %s"):format(entry.name, entry.x, entry.y, entry.z,
      tostring(entry.kind)))
  end
  print("")
  local name, cancelled = Console.readName(read)
  if name == nil then
    print(tostring(cancelled)); pause(); self.prompting = false; return false
  end
  local ok, err = self.waypoints:remove(name)
  if not ok then
    print("REFUSED: " .. tostring(err))
  else
    self.waypoints:save()
    print(("deleted '%s'"):format(name))
  end
  pause()
  self.prompting = false
  return ok
end

function App:showList()
  self:beginPrompt(("Waypoints (%d)"):format(self.waypoints:count()))
  local position = self:position()
  local list = position and self.waypoints:nearest(Geo, position) or nil
  if list then
    for _, entry in ipairs(list) do
      print(("  %-14s %s %s  %sm"):format(entry.waypoint.name,
        Geo.compassPoint(entry.bearing), Console.num(entry.bearing),
        Console.num(entry.distance)))
    end
    if #list == 0 then print("  none yet -- press M to mark where you are") end
  else
    for _, entry in ipairs(self.waypoints:all()) do
      print(("  %-14s %d %d %d"):format(entry.name, entry.x, entry.y, entry.z))
    end
    print("")
    print("(no fix, so no bearings)")
  end
  pause()
  self.prompting = false
end

--- SELF ALIGN: show the current heading and let the operator force a fresh sync with the
--- navigation table. "Realigning" here means re-truing the heading reference to north, not turning
--- the craft -- the nav computer cannot move anything.
function App:promptSelfAlign()
  self:beginPrompt("SELF ALIGN -- re-true the heading to the navigation table")
  local h = self.heading:current()
  if type(h) == "table" and type(h.degrees) == "number" then
    local tag = (h.source == "navtable" and "true north")
      or (h.source == "backup" and "Backup basic heading (gimbal)")
      or "relative gimbal -- NOT referenced to north"
    print(("current heading  %s deg  (%s)"):format(Console.num(h.degrees), tag))
  else
    print("current heading  NONE -- no navigation table and no gimbal yet")
  end
  print(("signs: nav %+d  gimbal %+d"):format(self.cfg.navSign, self.cfg.gimbalSign))
  print("")
  print("[A] align to the table now")
  print("[N] flip nav sign     (if the heading runs BACKWARDS)")
  print("[G] flip gimbal sign  (if the backup heading runs backwards)")
  print("[Enter] back")
  term.write("> ")
  local answer = tostring(read() or ""):lower()
  print()

  if answer == "a" then
    local ok, msg = self:selfAlign()
    print(ok and ("ALIGNED: " .. tostring(msg)) or ("could not align: " .. tostring(msg)))
  elseif answer == "n" then
    self.cfg.navSign = -self.cfg.navSign
    self.heading:setNavSign(self.cfg.navSign)
    self:saveConfig()
    print(("nav sign is now %+d -- re-align (A) to re-true the offset"):format(self.cfg.navSign))
  elseif answer == "g" then
    self.cfg.gimbalSign = -self.cfg.gimbalSign
    self.heading:setGimbalSign(self.cfg.gimbalSign)
    self:saveConfig()
    print(("gimbal sign is now %+d -- re-align (A)"):format(self.cfg.gimbalSign))
  else
    print("no change")
  end
  pause()
  self.prompting = false
  return true
end

--- Persist the config after an in-menu change (a sign flip). Best-effort: a failed save is
--- reported but the running change still stands for this session.
function App:saveConfig()
  local ok, err = Config.save(self.configPath, self.cfg)
  if not ok then self.log:warn("could not save config: %s", tostring(err)) end
  return ok
end

--- DISK: check for a floppy, and save or load the waypoint (and route) set. Explicit both ways --
--- nothing is written or read without a keypress, so an inserted disk never clobbers anything.
function App:promptDisk()
  self:beginPrompt("DISK -- save or load waypoints")
  local drives = Disk.drives()
  if #drives == 0 then
    print("No drive on the network.")
    pause(); self.prompting = false; return false
  end
  for _, d in ipairs(drives) do
    if d.present then
      print(("  %s  disk present%s"):format(d.name, d.label and (" (" .. d.label .. ")") or ""))
    else
      print(("  %s  NO DISK"):format(d.name))
    end
  end
  print("")
  print("Press S to SAVE to disk, L to LOAD from disk, or Enter to go back.")
  term.write("> ")
  local answer = tostring(read() or ""):lower()
  print()

  local ready, reason = Disk.firstReady()
  if answer == "s" then
    if not ready then print("cannot save: " .. tostring(reason)); pause()
      self.prompting = false; return false end
    local ok, saved, err = Disk.save(ready.mount, self.cfg)
    print(ok and ("saved to disk: " .. table.concat(saved, ", ")) or ("save failed: " .. tostring(err)))
  elseif answer == "l" then
    if not ready then print("cannot load: " .. tostring(reason)); pause()
      self.prompting = false; return false end
    local ok, loaded, err = Disk.load(ready.mount, self.cfg)
    if ok then
      -- The files on disk are now the local files; reload the store so the change takes effect.
      self.waypoints:load()
      print("loaded from disk: " .. table.concat(loaded, ", "))
    else
      print("load failed: " .. tostring(err))
    end
  else
    print("no change")
  end
  pause()
  self.prompting = false
  return true
end

function App:run()
  self:boot()
  self.running = true
  parallel.waitForAny(function() self:service() end, function() self:ui() end)

  self.relay:close()
  term.setBackgroundColour(colours.black)
  term.clear()
  term.setCursorPos(1, 1)
  print("Navigation stopped. The craft will report NO NAV DATA until it runs again.")
end

return App
