--[[ Shared look and small widgets.

     ASCII 32-126 ONLY. CraftOS-PC ships a full CP437 font and real CC:Tweaked does not, so a
     box-drawing character looks right in the headless render tests and wrong in the cockpit.
     Rules are drawn with '-', bars with '#' and ' '.
]]


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
