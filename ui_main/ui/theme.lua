--[[ Shared look and small widgets.

     ASCII 32-126 ONLY. CraftOS-PC ships a full CP437 font and real CC:Tweaked does not, so a
     box-drawing character looks right in the headless render tests and wrong in the cockpit.
     Rules are drawn with '-', bars with '#' and ' '.
]]

local Util = require("shared.util")

local Theme = {}

--- DAY / NIGHT. Two colour sets, chosen from CC's fixed 16, swapped by Theme.setMode. Day is the
--- high-contrast set for reading in sunlight (pure white on black, bright accents); night is the
--- softer set for a dark cockpit (greys instead of white, calmer accents). Because panels capture
--- these values when they BUILD, the app rebuilds every panel after a mode change -- see
--- ui_main/app.lua toggleDayNight. Colours only, never characters, so the ASCII rule still holds.
local PALETTES = {
  day = {
    bg = colours.black, fg = colours.white, dim = colours.lightGrey,
    accent = colours.cyan, ok = colours.lime, caution = colours.yellow,
    warning = colours.red, buttonBg = colours.grey, buttonFg = colours.white,
  },
  night = {
    bg = colours.black, fg = colours.lightGrey, dim = colours.grey,
    accent = colours.lightBlue, ok = colours.green, caution = colours.orange,
    warning = colours.red, buttonBg = colours.grey, buttonFg = colours.lightGrey,
  },
}

--- Switch the active colour set. Returns the mode actually set. Anything but "night" is "day".
function Theme.setMode(mode)
  Theme.mode = (mode == "night") and "night" or "day"
  for key, value in pairs(PALETTES[Theme.mode]) do Theme[key] = value end
  return Theme.mode
end

Theme.mode = "day"
Theme.setMode("day")     -- seed the colour fields below from the day palette

--- Colour for a 0..1 fraction, using the configured thresholds so every gauge agrees.
function Theme.levelColour(fraction, cfg)
  if type(fraction) ~= "number" then return Theme.dim end
  local warn = (cfg and cfg.ui.warningFraction) or 0.10
  local caution = (cfg and cfg.ui.cautionFraction) or 0.25
  if fraction <= warn then return Theme.warning end
  if fraction <= caution then return Theme.caution end
  return Theme.ok
end

--- A horizontal rule of '-' across the given width.
function Theme.rule(frame, y, width)
  return frame:addLabel({ x = 1, y = y, width = width, background = Theme.bg,
    foreground = Theme.dim }):setText(("-"):rep(math.max(width, 1)))
end

--- A section heading.
function Theme.heading(frame, y, width, text)
  return frame:addLabel({ x = 1, y = y, width = width, background = Theme.bg,
    foreground = Theme.accent }):setText(text)
end

--- A plain value line, returned so the caller can setText() it every update.
function Theme.line(frame, y, width, text, colour)
  return frame:addLabel({ x = 1, y = y, width = width, background = Theme.bg,
    foreground = colour or Theme.fg }):setText(text or "")
end

--- A gauge: a progress bar plus a value line under it. Returns { bar, value }.
function Theme.gauge(frame, y, width, cfg)
  local bar = frame:addProgressBar({
    x = 1, y = y, width = width, height = 1,
    background = Theme.bg, progressColor = Theme.ok, foreground = Theme.fg,
  })
  local value = Theme.line(frame, y + 1, width, "--", Theme.dim)
  return {
    bar = bar,
    value = value,
    --- fraction 0..1 (or nil), plus the text to show underneath
    set = function(fraction, text)
      local pct = Util.pct(fraction)
      bar:setProgress(pct or 0)
      bar:setProgressColor(Theme.levelColour(fraction, cfg))
      value:setText(text or "--")
      value:setForeground(fraction == nil and Theme.dim or Theme.fg)
    end,
  }
end

--- A button. `onPress` gets no arguments -- panels should not care about click coordinates.
---
--- BOTH click events are wired, and that is not belt-and-braces. Basalt turns two clicks on
--- the same element within 0.4 s into `mouse_double_click` INSTEAD OF a second `mouse_click`
--- (VisualElement:mouse_click), so an `onClick`-only button silently eats every rapid second
--- tap. In the cockpit that reads as a dead button: you tap, nothing seems to happen, you tap
--- again -- and the second tap is the one that gets thrown away.
function Theme.button(frame, x, y, width, text, onPress)
  local button = frame:addButton({
    x = x, y = y, width = width, height = 1,
    background = Theme.buttonBg, foreground = Theme.buttonFg,
  }):setText(text)
  if onPress then
    local function fire()
      -- pcall so a panel bug cannot take down the whole UI computer
      local ok = pcall(onPress)
      if not ok then
        button:setText("ERR")
        button:setBackground(Theme.warning)
      end
      return true
    end
    button:onClick(fire)
    button:onDoubleClick(fire)
  end
  return button
end

--- Centre a string inside a width, padded with spaces. Truncates rather than wrapping.
function Theme.centre(text, width)
  text = tostring(text or "")
  if #text >= width then return text:sub(1, width) end
  local left = math.floor((width - #text) / 2)
  return (" "):rep(left) .. text .. (" "):rep(width - #text - left)
end

--- Fit a label to a width: truncate with no ellipsis (an ellipsis costs three of very few
--- columns on a 15-wide monitor).
function Theme.fit(text, width)
  text = tostring(text or "")
  if #text <= width then return text end
  return text:sub(1, width)
end

--- Fit text by keeping its END rather than its start. For a peripheral name the tail is the
--- part that distinguishes it, so truncating "redstone_relay_1" to "redstone_relay_" loses
--- exactly the character that mattered.
function Theme.fitEnd(text, width)
  text = tostring(text or "")
  if #text <= width then return text end
  return text:sub(#text - width + 1)
end

--- Word-wrap `text` into a list of lines no wider than `width`, breaking on spaces. A single word
--- longer than the width is hard-split across lines rather than lost. With `maxLines` set, any
--- overflow past the last line is truncated onto it (Theme.fit) so nothing vanishes without a
--- trace. Used where cropping the tail would drop the word that matters -- e.g. the SENSOR CAL move
--- prompt, whose DIRECTION word lives at the end ("... NOSE UP", "... wing DOWN").
function Theme.wrap(text, width, maxLines)
  text = tostring(text or "")
  if width < 1 then return { text } end
  local lines, cur = {}, ""
  local function flush() if cur ~= "" then lines[#lines + 1] = cur; cur = "" end end
  for word in text:gmatch("%S+") do
    while #word > width do            -- a word too long to ever fit: hard-split it
      flush()
      lines[#lines + 1] = word:sub(1, width)
      word = word:sub(width + 1)
    end
    if cur == "" then
      cur = word
    elseif #cur + 1 + #word <= width then
      cur = cur .. " " .. word
    else
      flush(); cur = word
    end
  end
  flush()
  if #lines == 0 then lines[1] = "" end
  if maxLines and #lines > maxLines then
    -- Keep the first maxLines lines; fold the remaining words onto the last kept line, truncated,
    -- so the operator at least sees the start of what did not fit rather than silence.
    local tail = table.concat(lines, " ", maxLines)
    local kept = {}
    for i = 1, maxLines - 1 do kept[i] = lines[i] end
    kept[maxLines] = Theme.fit(tail, width)
    lines = kept
  end
  return lines
end

--- The stale banner every panel shows when telemetry has stopped. Returning it lets the panel
--- update the text with the age.
function Theme.staleBanner(frame, y, width)
  local label = frame:addLabel({ x = 1, y = y, width = width,
    background = Theme.warning, foreground = colours.white })
  label:setText(Theme.centre("NO DATA", width))
  label:setVisible(false)
  return label
end

return Theme
