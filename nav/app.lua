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

  -- What the flight computer last told us. Dead reckoning needs the heading; without it the
  -- estimate cannot exist, which is a state to report rather than paper over.
  self.craft = { heading = nil, forward = 0, right = 0, altitude = nil, at = nil }

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
  self.craft.heading = type(attitude.yaw) == "number" and attitude.yaw or nil
  -- The velocity sensors read along the craft's own axes; z is forward, x is right.
  self.craft.forward = type(velocity.z) == "number" and velocity.z or 0
  self.craft.right = type(velocity.x) == "number" and velocity.x or 0
  self.craft.altitude = (message.altitude or {}).baro
  self.craft.at = os.epoch("utc")
  return true
end

--- The best position we can offer, altimeter altitude preferred over the fix's coarse block y.
function App:position(now)
  return self.fix:position(now, self.craft.altitude)
end

--- One service tick: take a fix if it is due, advance the estimate, publish.
function App:tick(now)
  now = now or os.epoch("utc")

  if now - self.lastFixAt >= self.cfg.fixEverySeconds * 1000 then
    self.lastFixAt = now
    -- This BLOCKS. It is why the service loop exists and why nav is its own computer.
    self.fix:acquire(now)
    self.dirty = true
  end

  -- Dead reckoning between fixes, when there is a heading to rotate by.
  if self.lastReckonAt ~= nil and self.craft.heading ~= nil then
    local dt = (now - self.lastReckonAt) / 1000
    if dt > 0 then
      self.fix:reckon(dt, self.craft.forward, self.craft.right, self.craft.heading, now)
    end
  end
  self.lastReckonAt = now

  local position = self:position(now)
  if position then
    self.relay:publish(position, {
      heading = self.craft.heading,
      waypointCount = self.waypoints:count(),
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
    heading = self.craft.heading,
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
      if self:onTelemetry(event[2], event[3], event[4]) then self.dirty = true end
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
  if position.dead then print("This is a DEAD-RECKONED estimate, not a fix.") end
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
