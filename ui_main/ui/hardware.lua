--[[ Hardware assignment: pick the engine relay, the fuel tank and the engine vault from a
     LIST of what the craft can actually see.

     Used by BOTH the overhead panel's CFG page and the config panel's HARDWARE page, so there
     is one implementation of "which peripheral is the tank" rather than two that can disagree.

     The first version cycled: one PICK button stepped through the candidates. The first dry
     run showed why that was wrong -- you cannot see what you are choosing between, so PICK
     either did what you wanted or something you did not expect, and reaching candidate three
     took three taps. Every candidate is now a row of its own; one tap assigns it. The first
     row is always `(none)`, so a wrong choice is undoable without walking the list again.

     THE CANDIDATE LIST COMES FROM THE FLIGHT COMPUTER over telemetry, not from this computer's
     own peripheral scan. Both see the same wired network, but the flight computer is the one
     that will actually open these peripherals, so its names are the authoritative ones.
]]

local Theme = require("ui.theme")

local Hardware = {}

local SIDES = { "top", "bottom", "left", "right", "front", "back" }

--- The narrowest this widget can be drawn. Below it the caller should send the pilot to a
--- bigger screen rather than draw a list nobody can read.
local MIN_ROWS = 7

--- opts = { actions, log, lastAck }
--- actions needs: setEngineRelay(peripheral, side), setTank(peripheral), setVault(peripheral)
function Hardware.build(parent, x, y, width, height, opts)
  local actions = opts.actions

  -- What the craft currently has, and what it could have. Filled in by update().
  local live = {
    candidates = { relays = {}, tanks = {}, vaults = {} },
    relay = "", side = "top", tank = "", vault = "",
  }

  local items = {
    {
      key = "relay", tag = "RLY", title = "ENGINE RELAY", command = "setEngineRelay",
      list = function() return live.candidates.relays end,
      current = function() return live.relay end,
      set = function(name) live.relay = name; actions.setEngineRelay(name, live.side) end,
    },
    {
      key = "tank", tag = "TNK", title = "FUEL TANK", command = "setTank",
      list = function() return live.candidates.tanks end,
      current = function() return live.tank end,
      set = function(name) live.tank = name; actions.setTank(name) end,
    },
    {
      key = "vault", tag = "VLT", title = "ENGINE VAULT", command = "setVault",
      list = function() return live.candidates.vaults end,
      current = function() return live.vault end,
      set = function(name) live.vault = name; actions.setVault(name) end,
    },
  }

  local selected, page = 1, 1
  local refused = nil          -- item key the craft most recently rejected, or nil
  local refresh                -- forward declaration: the buttons below call it

  local function nextSide()
    local index = 1
    for i, side in ipairs(SIDES) do
      if side == live.side then index = i end
    end
    live.side = SIDES[index % #SIDES + 1]
    -- Only meaningful for the relay, and only sent when one is assigned.
    if live.relay ~= "" then actions.setEngineRelay(live.relay, live.side) end
    refresh()
  end

  -- ------------------------------------------------------------------ layout

  local row = y
  local title = Theme.line(parent, row, width, "", Theme.accent); row = row + 1

  -- One tab per item. Three taps to see all three items, instead of a `>` you have to press
  -- an unknown number of times to get back to where you were.
  local tabWidth = math.max(3, math.floor((width - 2) / 3))
  local tabs = {}
  for i, item in ipairs(items) do
    tabs[i] = Theme.button(parent, x + (i - 1) * (tabWidth + 1), row, tabWidth, item.tag,
      function()
        selected, page = i, 1
        refresh()               -- redraw on the tap, not on the next telemetry frame
      end)
  end
  row = row + 1

  local valueLine = Theme.line(parent, row, width, "", Theme.fg); row = row + 1

  -- The relay's side lives with the relay. A relay's "face" is its BACK, so this is not a
  -- detail you can guess (WIRING.md).
  local sideLabel, sideButton
  local sideWidth = math.min(8, math.max(5, width - 6))
  if height >= 6 then
    sideLabel = Theme.line(parent, row, width, "", Theme.dim)
    sideButton = Theme.button(parent, x + width - sideWidth, row, sideWidth, "top", nextSide)
    row = row + 1
  end

  if height >= MIN_ROWS then Theme.rule(parent, row, width); row = row + 1 end

  -- Whatever rows are left become the list, keeping the last row for the count/paging line.
  local footerRow = y + height - 1
  local listStart = row
  local perPage = footerRow - listStart
  if perPage < 1 then perPage = 1; footerRow = nil end

  --- One tappable candidate per row. The name lives in a CLOSURE, never on the Basalt element
  --- (the property system owns field access), and the handler is registered ONCE -- Basalt
  --- appends callbacks rather than replacing them, so re-registering on every refresh would
  --- make one tap assign several times.
  local listRows = {}
  for i = 1, perPage do
    local entry = { name = nil }
    entry.button = Theme.button(parent, x, listStart + i - 1, width, "", function()
      if entry.name == nil then return end
      items[selected].set(entry.name)   -- "" unassigns
      refused = nil
      -- `set` already wrote the optimistic value into `live`, so the row highlights under the
      -- pilot's finger. Telemetry corrects it within a frame if the craft refused.
      refresh()
    end)
    listRows[i] = entry
  end
  row = listStart + perPage

  local footerText, upButton, downButton
  if footerRow then
    -- Full width: the paging buttons are added AFTER it, so they draw over its tail when they
    -- are visible, and it gets the whole row when they are not. "none on network" needs it.
    footerText = Theme.line(parent, footerRow, width, "", Theme.dim)
    upButton = Theme.button(parent, x + width - 7, footerRow, 3, "^", function()
      page = page - 1; refresh()
    end)
    downButton = Theme.button(parent, x + width - 3, footerRow, 3, "v", function()
      page = page + 1; refresh()
    end)
    row = footerRow + 1
  end

  -- ----------------------------------------------------------------- drawing

  function refresh()
    local item = items[selected]
    title:setText(Theme.fit(item.title, width))

    for i, tab in ipairs(tabs) do
      tab:setBackground(i == selected and Theme.accent or Theme.buttonBg)
      tab:setForeground(i == selected and colours.black or Theme.buttonFg)
    end

    local current = item.current() or ""
    if current == "" then
      valueLine:setText(Theme.fit("(not set)", width))
      valueLine:setForeground(Theme.warning)
    else
      valueLine:setText(Theme.fitEnd(current, width))
      valueLine:setForeground(Theme.ok)
    end

    if sideButton then
      local isRelay = (item.key == "relay")
      -- Fit the label to the columns LEFT OF the button, which is drawn over this same row.
      sideLabel:setText(isRelay and Theme.fit("side", width - sideWidth - 1) or "")
      sideButton:setText(Theme.centre(live.side, sideWidth))
      sideButton:setVisible(isRelay)
    end

    -- `(none)` first, then every candidate the craft reported.
    local candidates = item.list() or {}
    local entries = { "" }
    for _, name in ipairs(candidates) do entries[#entries + 1] = name end

    local pages = math.max(1, math.ceil(#entries / perPage))
    page = math.max(1, math.min(page, pages))

    for i, entry in ipairs(listRows) do
      local name = entries[(page - 1) * perPage + i]
      if name == nil then
        entry.name = nil
        entry.button:setVisible(false)
      else
        entry.name = name
        local isCurrent = (name == current)
        -- fitEnd, because "redstone_relay_0" and "redstone_relay_1" differ in the last column
        entry.button:setText(Theme.fitEnd(name == "" and "(none)" or name, width))
        entry.button:setBackground(isCurrent and Theme.ok or Theme.buttonBg)
        entry.button:setForeground(isCurrent and colours.black or Theme.buttonFg)
        entry.button:setVisible(true)
      end
    end

    if footerText then
      local text, colour
      if refused == item.key then
        text, colour = "CRAFT REFUSED", Theme.warning
      elseif #candidates == 0 then
        text, colour = "none on network", Theme.warning
      elseif pages > 1 then
        text, colour = ("pg %d/%d"):format(page, pages), Theme.dim
      else
        text, colour = ("%d found"):format(#candidates), Theme.dim
      end
      -- Only the paging buttons steal columns, and only while they are on screen.
      footerText:setText(Theme.fit(text, pages > 1 and math.max(1, width - 8) or width))
      footerText:setForeground(colour)
      upButton:setVisible(pages > 1)
      downButton:setVisible(pages > 1)
    end
  end

  refresh()

  local function update(model)
    local t = model and model.telemetry
    if t then
      local candidates = t.candidates or {}
      live.candidates.relays = candidates.relays or {}
      live.candidates.tanks = candidates.tanks or {}
      live.candidates.vaults = candidates.vaults or {}
      local cfg = t.config or {}
      live.relay = cfg.engineRelay or ""
      live.side = cfg.engineSide or live.side
      live.tank = cfg.tankPeripheral or ""
      live.vault = cfg.vaultPeripheral or ""
    end

    -- A refused assignment has to be visible. Silently reverting to the old value on the next
    -- telemetry frame looks exactly like a dead button.
    local ack = opts.lastAck and opts.lastAck()
    refused = nil
    if ack and ack.ack == false then
      for _, item in ipairs(items) do
        if ack.cmd == item.command then refused = item.key end
      end
    end

    refresh()
  end

  return {
    update = update,
    refresh = refresh,
    rowsUsed = row - y,
    elements = {
      title = title, value = valueLine, side = sideButton, sideLabel = sideLabel,
      count = footerText, up = upButton, down = downButton,
      tabs = tabs, rows = listRows,
    },
    --- Test seam: which item is on screen, and what the list currently offers.
    select = function(index) selected = index; page = 1; refresh() end,
    selected = function() return selected end,
    page = function() return page end,
    live = live,
  }
end

--- How many rows the widget needs to draw its full form.
function Hardware.rows()
  return MIN_ROWS
end

return Hardware
