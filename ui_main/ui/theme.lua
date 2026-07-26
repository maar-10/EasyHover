--[[ Shared look and small widgets.

     ASCII 32-126 ONLY. CraftOS-PC ships a full CP437 font and real CC:Tweaked does not, so a
     box-drawing character looks right in the headless render tests and wrong in the cockpit.
     Rules are drawn with '-', bars with '#' and ' '.
]]

local Util = require("shared.util")

local Theme = {}

Theme.bg = colours.black
Theme.fg = colours.white
Theme.dim = colours.lightGrey
Theme.accent = colours.cyan
Theme.ok = colours.lime
Theme.caution = colours.yellow
Theme.warning = colours.red
Theme.buttonBg = colours.grey
Theme.buttonFg = colours.white

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
function Theme.button(frame, x, y, width, text, onPress)
  local button = frame:addButton({
    x = x, y = y, width = width, height = 1,
    background = Theme.buttonBg, foreground = Theme.buttonFg,
  }):setText(text)
  if onPress then
    button:onClick(function()
      -- pcall so a panel bug cannot take down the whole UI computer
      local ok, err = pcall(onPress)
      if not ok then
        button:setText("ERR")
        button:setBackground(Theme.warning)
        return true
      end
      return true
    end)
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
