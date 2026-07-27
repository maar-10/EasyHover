--[[ The UI computer's own terminal.

     One job: decide WHICH MONITOR SHOWS WHICH PANEL. That is a property of this computer, not
     of the craft, so it does not belong on the config monitor with the vehicle's settings --
     and this is the one screen that is guaranteed to exist before anything has been assigned,
     which makes it the only place the bootstrap case can live.

     Tapping a monitor cycles it through the panels; each change saves immediately, because a
     half-made assignment lost to a reboot is worse than one you have to undo.
]]

local Theme = require("ui.theme")
local UiConfig = require("lib.config")
local Install = require("shared.install")

--- Read ONCE, when this file is first loaded, so it reports the record as it stood when the
--- RUNNING code was loaded. Compare it against the release: equal means the new code is running
--- and any remaining fault is in the code; older means the files updated and this computer was
--- never restarted. Those two look identical from the pilot's seat and need opposite fixes.
local BUILD = Install.stamp()

local Terminal = {}

--- opts = { cfg, monitors, log, savePanels, panelNames }
function Terminal.build(frame, opts)
  local cfg, monitors = opts.cfg, opts.monitors
  -- Only panels that HAVE a builder, so cycling can never park a monitor on a panel nothing
  -- draws. It used to walk Config.PANEL_ORDER, which meant two of the six stops (pfd and
  -- autopilot) were guaranteed black screens.
  local order = opts.panelNames or UiConfig.PANEL_ORDER
  local width, height = frame:getWidth(), frame:getHeight()
  frame:setBackground(Theme.bg)

  Theme.line(frame, 1, width, Theme.centre("EasyHover UI", width), Theme.accent)
  local buildLine = Theme.line(frame, 2, width, Theme.fitEnd(BUILD, width), Theme.dim)
  Theme.rule(frame, 3, width)

  local listStart = 4
  local footerRow = height
  local perPage = math.max(1, footerRow - listStart)
  local pageIndex = 1
  local refresh

  -- Widths are held HERE, not read back off the elements. A Basalt label auto-sizes to its
  -- text, so an empty one reports width 0 -- and fitEnd() to width 0 quietly returns nothing,
  -- which is a blank row that looks exactly like a missing monitor.
  local labelWidth = math.max(6, width - 14)
  local buttonWidth = math.max(6, width - labelWidth - 2)

  local rows = {}
  for i = 1, perPage do
    local entry = { name = nil }
    entry.label = Theme.line(frame, listStart + i - 1, labelWidth, "", Theme.fg)
    entry.button = Theme.button(frame, labelWidth + 2, listStart + i - 1,
      buttonWidth, "", function()
        if entry.name == nil then return end
        -- none -> overhead -> config -> nav -> none, skipping any panel with no builder
        local current = UiConfig.panelFor(cfg, entry.name)
        local nextPanel = order[1]
        if current then
          local found = false
          for j, panel in ipairs(order) do
            if panel == current then nextPanel = order[j + 1]; found = true; break end
          end
          -- Assigned to a panel this release does not implement (an old config, or one written
          -- by a newer release). Cycle forward to the first real one rather than sticking.
          if not found then nextPanel = order[1] end
        end
        if nextPanel == nil then
          UiConfig.unassign(cfg, entry.name)
        else
          UiConfig.assign(cfg, nextPanel, entry.name)
        end
        opts.savePanels()
        refresh()          -- redraw on the tap, not on the next data frame
      end)
    rows[i] = entry
  end

  local footer = Theme.line(frame, footerRow, math.max(1, width - 8), "", Theme.dim)
  local prevButton = Theme.button(frame, math.max(1, width - 7), footerRow, 3, "^", function()
    pageIndex = pageIndex - 1; refresh()
  end)
  local nextButton = Theme.button(frame, math.max(1, width - 3), footerRow, 3, "v", function()
    pageIndex = pageIndex + 1; refresh()
  end)

  local found = {}

  function refresh()
    found = monitors:available()
    local pages = math.max(1, math.ceil(#found / perPage))
    pageIndex = math.max(1, math.min(pageIndex, pages))

    for i, entry in ipairs(rows) do
      local item = found[(pageIndex - 1) * perPage + i]
      if item == nil then
        entry.name = nil
        entry.label:setVisible(false)
        entry.button:setVisible(false)
      else
        entry.name = item.name
        entry.label:setText(Theme.fitEnd(("%s %dx%d"):format(item.name, item.width or 0,
          item.height or 0), labelWidth))
        local panel = UiConfig.panelFor(cfg, item.name) or "none"
        entry.button:setText(Theme.fit(panel, buttonWidth))
        entry.button:setBackground(panel == "none" and Theme.buttonBg or Theme.accent)
        entry.button:setForeground(panel == "none" and Theme.buttonFg or colours.black)
        entry.label:setVisible(true)
        entry.button:setVisible(true)
      end
    end

    if #found == 0 then
      footer:setText(Theme.fit("no monitors found", math.max(1, width - 8)))
      footer:setForeground(Theme.warning)
    elseif pages > 1 then
      footer:setText(("pg %d/%d  %d screens"):format(pageIndex, pages, #found))
      footer:setForeground(Theme.dim)
    else
      footer:setText(Theme.fit(("%d screens  tap to cycle"):format(#found),
        math.max(1, width - 8)))
      footer:setForeground(Theme.dim)
    end
    prevButton:setVisible(pages > 1)
    nextButton:setVisible(pages > 1)
  end

  refresh()

  --- The terminal shows no craft data, so an update is just a rescan -- a monitor plugged in
  --- while you are looking at this screen should appear on it. It also carries the redraw cost,
  --- which is the one number that says whether this computer is keeping up: if a redraw takes
  --- longer than the interval between redraws, there is no room left for touches.
  local function update(model)
    refresh()
    local ms = model and model.refreshMs
    if type(ms) == "number" then
      buildLine:setText(Theme.fitEnd(("%s %dms"):format(BUILD, ms), width))
      buildLine:setForeground(ms > 150 and Theme.warning or Theme.dim)
    end
  end

  return {
    update = update,
    refresh = refresh,
    rows = rows,
    elements = { footer = footer, prev = prevButton, next = nextButton },
  }
end

return Terminal
