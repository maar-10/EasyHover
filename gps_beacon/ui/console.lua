--[[ The beacon's screen -- plain `term`, keyboard-driven, no Basalt.

     WHY NOT BASALT, when every other screen in this project uses it: a beacon runs on a BASIC
     computer, and a basic computer has no mouse. `mouse_click` is only generated on advanced
     ones, so a panel of buttons is not merely ugly there, it is entirely inert. The first beacon
     in the world proved it -- the handlers were correct and the events never arrived.

     Two consequences shape this file:

       * EVERY ACTION IS A SINGLE KEYPRESS. Nothing needs pointing at.
       * SEVERITY IS IN THE TEXT, NOT THE COLOUR. A basic terminal is monochrome, so a red
         MISMATCH and a green OK render identically. Colour is added when the terminal has it
         and never carries meaning on its own.

     `render()` is pure -- config and model in, lines out -- so the whole screen is testable
     without a terminal, which the button panel never was.
]]

local Geometry = require("lib.geometry")

local Console = {}

--- The actions a keypress can ask for. Returned rather than performed, so the caller owns the
--- side effects and this stays testable.
Console.ACTIONS = {
  p = "setPosition",
  e = "toggleEnabled",
  v = "verify",
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

--- Wrap a sentence to the width, indented, so a problem never runs off the screen unread.
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

--- The whole screen, as a list of { text, tone } rows.
---
--- `tone` is "normal" | "good" | "bad" | "dim" -- a HINT for a colour terminal. The text must
--- stand alone, because on a basic computer the tone is invisible.
function Console.render(cfg, model, width, height)
  width = width or 51
  local rows = {}
  local function row(text, tone) rows[#rows + 1] = { text = pad(text, width), tone = tone } end

  local status = (model and model.status) or {}
  local assessment = (model and model.assessment) or { problems = {}, hostCount = 0 }

  row(("EasyHover GPS   %s"):format(tostring(cfg.label)), "normal")

  -- position
  local position = status.position or cfg.position or {}
  if type(position.x) == "number" then
    row(("position  %d %d %d"):format(position.x, position.y, position.z), "good")
  else
    row("position  NOT SET -- not answering pings", "bad")
  end

  -- the self check gets the loudest line, in WORDS
  local check = status.selfCheck or { state = "unchecked" }
  if check.state == "ok" then
    row(("self check  OK (%.2f blocks out)"):format(check.error or 0), "good")
  elseif check.state == "MISMATCH" then
    row(("self check  !! MISMATCH: %.1f BLOCKS OFF !!"):format(check.error or 0), "bad")
    if check.located and check.configured then
      row(("  GPS says %d %d %d, config says %d %d %d"):format(
        check.located.x, check.located.y, check.located.z,
        check.configured.x, check.configured.y, check.configured.z), "bad")
    end
  else
    row("self check  " .. tostring(check.state), "dim")
  end

  row(("-"):rep(width), "dim")

  -- the constellation
  row(("constellation  %d of 4   %s"):format(assessment.hostCount or 0,
    tostring(assessment.grade or "UNUSABLE")), assessment.usable and "good" or "bad")

  for _, host in ipairs(assessment.hosts or {}) do
    if host.self_ then
      row(("  * %s (this one)"):format(tostring(host.label)), "dim")
    else
      row(("  + %s  %d %d %d"):format(tostring(host.label), host.x, host.y, host.z), "good")
    end
  end

  -- problems, wrapped, most important first
  local problemLines = {}
  for index, problem in ipairs(assessment.problems or {}) do
    if index > 2 then break end          -- two at a time; the rest follow once these are fixed
    wrap(problem, width, "  ! ", problemLines)
  end
  for _, line in ipairs(problemLines) do row(line, "bad") end

  row(("-"):rep(width), "dim")
  row(("served %d pings   peers %d"):format(status.served or 0,
    math.max(0, (assessment.hostCount or 1) - 1)), "dim")

  -- the key legend, always last so it sits at a predictable place on the screen
  rows.footer = {
    { text = "[P] set position", tone = "normal" },
    { text = ("[E] enabled: %s"):format(cfg.enabled and "YES" or "NO"),
      tone = cfg.enabled and "good" or "bad" },
    { text = "[V] verify now", tone = "normal" },
    { text = "[Q] quit to shell", tone = "dim" },
  }
  return rows
end

-- ---------------------------------------------------------------- drawing

local TONES = {
  normal = colours.white,
  good = colours.lime,
  bad = colours.red,
  dim = colours.lightGrey,
}

--- Paint the rendered rows. Colour only when the terminal has it; the text already carries the
--- meaning, so a monochrome beacon loses nothing but the decoration.
function Console.draw(rows, width, height)
  local colour = term.isColour and term.isColour()
  term.setBackgroundColour(colours.black)
  term.clear()

  for index, entry in ipairs(rows) do
    if index > height - #rows.footer - 1 then break end
    term.setCursorPos(1, index)
    if colour then term.setTextColour(TONES[entry.tone] or colours.white) end
    term.write(entry.text)
  end

  local footerTop = height - #rows.footer + 1
  for index, entry in ipairs(rows.footer) do
    term.setCursorPos(1, footerTop + index - 1)
    if colour then term.setTextColour(TONES[entry.tone] or colours.white) end
    term.write(entry.text)
  end
  if colour then term.setTextColour(colours.white) end
end

-- ------------------------------------------------------------ position entry

--- Read three coordinates from the keyboard.
---
--- `reader` is injected so this is testable; in production it is `read`. Returns a position, or
--- nil and a reason. ALL THREE OR NONE: two axes typed is a typo mid-entry, not a position, and
--- storing it would leave the beacon in a state its own validator rejects.
function Console.readPosition(reader, current)
  local wanted = {}
  for _, axis in ipairs({ "x", "y", "z" }) do
    local existing = current and current[axis]
    local prompt = existing ~= nil
      and ("%s [%d]: "):format(axis:upper(), math.floor(existing))
      or ("%s: "):format(axis:upper())
    term.write(prompt)
    local text = tostring(reader() or ""):gsub("%s", "")
    print()

    if text == "" and existing ~= nil then
      wanted[axis] = math.floor(existing)      -- blank keeps what is already set
    else
      local number = tonumber(text)
      if number == nil then
        return nil, ("%s is not a number -- nothing was changed"):format(axis:upper())
      end
      wanted[axis] = math.floor(number)
    end
  end
  return wanted
end

--- The header shown above the coordinate prompts.
function Console.positionHeader(width)
  return {
    "Where does THIS computer stand?",
    "",
    "Read the coordinates off F3 and type them in.",
    "A wrong number here poisons every fix the craft",
    "takes, and only the self check will notice.",
    "",
    "Blank keeps the current value.",
    "",
  }
end

Console.Geometry = Geometry

return Console
