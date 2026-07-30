--[[ The nav computer's screen -- plain `term`, keyboard-driven.

     Keyboard rather than buttons for the same reason as the beacon, plus one of its own: this
     screen has to TYPE THINGS. A waypoint needs a name and three coordinates, and a mouse is no
     help with either. (The nav computer is an advanced one, so a mouse would work here -- it
     just would not help.)

     `render()` is pure -- config and model in, rows out -- so the whole screen is testable
     without a terminal.
]]

local Geo = require("lib.geo")

local Console = {}

Console.ACTIONS = {
  m = "mark",           -- a waypoint here, from the last real FIX
  a = "add",            -- a waypoint by typed coordinates
  d = "delete",
  l = "list",
  f = "fixNow",
  s = "selfAlign",      -- re-true the heading to the navigation table
  k = "disk",           -- save/load waypoints and routes to a floppy
  q = "quit",
}

function Console.actionFor(key)
  if type(key) ~= "string" then return nil end
  return Console.ACTIONS[key:lower()]
end

local function pad(text, width)
  text = tostring(text or "")
  if #text > width then return text:sub(1, width) end
  return text
end

local function wrap(text, width, indent, out)
  local prefix = indent or ""
  local line = nil
  for word in tostring(text):gmatch("[^ ]+") do
    if line == nil then
      line = word
    elseif #prefix + #line + 1 + #word <= width then
      line = line .. " " .. word
    else
      out[#out + 1] = prefix .. line
      line = word
      prefix = (indent or "") .. "  "
    end
  end
  if line then out[#out + 1] = prefix .. line end
end

--- A number, or "--" when it is not one. Never 0 standing in for "unknown".
local function num(value, decimals)
  if type(value) ~= "number" then return "--" end
  return ("%." .. tostring(decimals or 0) .. "f"):format(value)
end

Console.num = num

--- The status screen, as { text, tone } rows. `tone` is a hint for a colour terminal; the text
--- stands alone.
function Console.render(cfg, model, width, height)
  width = width or 51
  local rows = {}
  local function row(text, tone) rows[#rows + 1] = { text = pad(text, width), tone = tone } end

  model = model or {}
  local position = model.position
  local link = model.link or {}
  local stats = model.stats or { sources = {} }

  row("EasyHover NAV", "normal")

  -- WHERE ARE WE. The one thing this computer exists to answer.
  if position == nil then
    row("position  NO FIX YET", "bad")
  else
    row(("position  %s %s %s"):format(num(position.x), num(position.y), num(position.z)),
      position.dead and "bad" or "good")
    -- THE ESTIMATE FLAG GOES FIRST, on its own line. It was appended to the end of the detail
    -- line, which on a 51-column screen truncated away the single most important word on the
    -- page: the flag saying these numbers are a guess. "Backup basic heading" is the pilot's
    -- name for this fallback -- an estimate carried on the gimbal heading between real fixes.
    if position.dead then
      row("  BACKUP BASIC HEADING -- estimated", "bad")
    elseif position.stale then
      row("  STALE -- no fresh fix and nothing to reckon from", "bad")
    end
    -- The source and age matter as much as the numbers: a consumer that cannot tell a fix from a
    -- five-second-old guess will act on the guess.
    row(("  from %s  %.1fs old  q %.2f"):format(
      tostring(position.source), (position.ageMs or 0) / 1000, position.quality or 0), "dim")
  end

  -- heading, its bearing, and WHAT IT RESTS ON -- the source is as important as the number:
  --   true N   a current navigation-table reading, referenced to true north
  --   backup   the Backup basic heading: gimbal carried forward from the last alignment
  --   rel      raw gimbal yaw, RELATIVE -- consistent but not referenced to north
  local h = model.heading
  if type(h) == "table" and type(h.degrees) == "number" then
    local tag = (h.source == "navtable" and "true N")
      or (h.source == "backup" and "backup")
      or "rel"
    local tone = (h.source == "navtable" and "good") or (h.source == "backup" and "normal") or "bad"
    row(("heading   %s  %s  %s"):format(num(h.degrees), Geo.compassPoint(h.degrees), tag), tone)
  else
    row("heading   NONE -- no table and no gimbal", "bad")
  end

  row(("-"):rep(width), "dim")

  -- the links, both of them, because half a nav computer is a specific failure
  row(("radio %s   cable %s"):format(
    link.wireless and tostring(link.wireless) or "MISSING",
    link.wired and tostring(link.wired) or "MISSING"),
    (link.wireless and link.wired) and "good" or "bad")
  row(("published %d fixes"):format(link.published or 0), "dim")

  -- per-source counters: which one is answering, and which has been backed off
  for _, source in ipairs(stats.sources or {}) do
    row(("  %s  ok %d  failed %d%s"):format(source.name, source.ok, source.bad,
      source.backedOff and "  BACKED OFF" or ""), source.backedOff and "bad" or "dim")
  end

  row(("-"):rep(width), "dim")
  row(("waypoints %d"):format(model.waypointCount or 0), "dim")

  -- the nearest few, with bearing and range, which is what a pilot actually wants
  for index, entry in ipairs(model.nearest or {}) do
    if index > 3 then break end
    row(("  %s  %s %s  %sm"):format(
      pad(entry.waypoint.name, 14),
      Geo.compassPoint(entry.bearing), num(entry.bearing),
      num(entry.distance)), "normal")
  end

  for _, problem in ipairs(model.problems or {}) do
    local lines = {}
    wrap(problem, width, "  ! ", lines)
    for _, line in ipairs(lines) do row(line, "bad") end
  end

  -- The legend is built to the WIDTH. Two keys per line only when both fit; a footer wider than
  -- the screen wraps in the terminal and pushes the top of the page out of view.
  local function legend(left, right, tone)
    if #left + 3 + #right <= width then
      return { text = pad(left .. (" "):rep(width - #left - #right) .. right, width), tone = tone }
    end
    return nil
  end
  rows.footer = {}
  local pairsWanted = {
    { "[M] mark here", "[A] add coords", "normal" },
    { "[D] delete", "[L] list all", "normal" },
    { "[F] fix now", "[S] self align", "normal" },
    { "[K] disk", "[Q] quit", "dim" },
  }
  for _, entry in ipairs(pairsWanted) do
    local combined = legend(entry[1], entry[2], entry[3])
    if combined then
      rows.footer[#rows.footer + 1] = combined
    else
      rows.footer[#rows.footer + 1] = { text = pad(entry[1], width), tone = entry[3] }
      rows.footer[#rows.footer + 1] = { text = pad(entry[2], width), tone = entry[3] }
    end
  end
  return rows
end

local TONES = {
  normal = colours.white,
  good = colours.lime,
  bad = colours.red,
  dim = colours.lightGrey,
}

function Console.draw(rows, width, height)
  local colour = term.isColour and term.isColour()
  term.setBackgroundColour(colours.black)
  term.clear()

  local room = height - #rows.footer
  for index, entry in ipairs(rows) do
    if index > room then break end
    term.setCursorPos(1, index)
    if colour then term.setTextColour(TONES[entry.tone] or colours.white) end
    term.write(entry.text)
  end

  for index, entry in ipairs(rows.footer) do
    term.setCursorPos(1, room + index)
    if colour then term.setTextColour(TONES[entry.tone] or colours.white) end
    term.write(entry.text)
  end
  if colour then term.setTextColour(colours.white) end
end

-- ------------------------------------------------------------- entry helpers

--- Read a waypoint name. Returns nil when the operator just pressed Enter, which is how you
--- back out of a prompt you opened by mistake.
function Console.readName(reader)
  term.write("name: ")
  local text = tostring(reader() or ""):gsub("^%s+", ""):gsub("%s+$", "")
  print()
  if text == "" then return nil, "cancelled" end
  return text
end

--- Read three coordinates. ALL THREE OR NONE, for the same reason as the beacon: two axes typed
--- is a typo mid-entry, and storing it would create a waypoint nobody can fly to.
function Console.readCoords(reader)
  local wanted = {}
  for _, axis in ipairs({ "x", "y", "z" }) do
    term.write(("%s: "):format(axis:upper()))
    local text = tostring(reader() or ""):gsub("%s", "")
    print()
    local number = tonumber(text)
    if number == nil then
      return nil, ("%s is not a number -- nothing was added"):format(axis:upper())
    end
    wanted[axis] = math.floor(number)
  end
  return wanted
end

--- A preview line for a typed waypoint, so a mis-typed coordinate is obvious BEFORE it is saved.
function Console.preview(from, to)
  if from == nil then return "no fix, so no distance from here" end
  local distance = Geo.distance(from, to)
  local bearing = Geo.bearing(from, to)
  if bearing == nil then return "that is where you are now" end
  return ("%s %s, %s blocks from here"):format(
    Geo.compassPoint(bearing), num(bearing), num(distance))
end

return Console
