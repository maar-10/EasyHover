--[[ Hardware assignment widget: pick the engine relay, the fuel tank and the engine vault.

     Used by BOTH the overhead panel's CFG page and the config panel's HARDWARE page, so there
     is one implementation of "which peripheral is the tank" rather than two that can disagree.

     ONE ITEM AT A TIME, with a `>` to move to the next. That is not a stylistic choice: a
     1x1 monitor at text scale 0.5 is 15x10 characters, and three items with a candidate list
     each cannot fit. Showing one item completely beats showing three items truncated.

     The candidate list comes from the FLIGHT computer over telemetry, not from this computer's
     own peripheral scan. Both see the same wired network, but the flight computer is the one
     that will actually open these peripherals, so its names are the authoritative ones.
]]

local Theme = require("ui.theme")

local Hardware = {}

local SIDES = { "top", "bottom", "left", "right", "front", "back" }

--- opts = { actions, log }
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
      key = "relay",
      title = "ENGINE RELAY",
      hint = "gates the funnel",
      list = function() return live.candidates.relays end,
      current = function() return live.relay end,
      set = function(name) actions.setEngineRelay(name, live.side) end,
    },
    {
      key = "tank",
      title = "FUEL TANK",
      hint = "liquid fuel gauge",
      list = function() return live.candidates.tanks end,
      current = function() return live.tank end,
      set = function(name) actions.setTank(name) end,
    },
    {
      key = "vault",
      title = "ENGINE VAULT",
      hint = "solid fuel gauge",
      list = function() return live.candidates.vaults end,
      current = function() return live.vault end,
      set = function(name) actions.setVault(name) end,
    },
  }

  local selected = 1
  local rows = {}

  local row = y
  local title = Theme.line(parent, row, width, "", Theme.accent); row = row + 1
  local hint = Theme.line(parent, row, width, "", Theme.dim); row = row + 1
  local valueLine = Theme.line(parent, row, width, "", Theme.fg); row = row + 1
  local extraLine = Theme.line(parent, row, width, "", Theme.dim); row = row + 1
  local countLine = Theme.line(parent, row, width, "", Theme.dim); row = row + 1

  --- Advance to the next candidate for the selected item, wrapping, with "" (none) in the
  --- cycle so a wrong pick can always be undone.
  local function nextCandidate()
    local item = items[selected]
    local list = item.list() or {}
    local current = item.current() or ""
    local index = 0
    for i, name in ipairs(list) do
      if name == current then index = i end
    end
    local nextName
    if index >= #list then
      nextName = ""              -- past the end: unassign
    else
      nextName = list[index + 1]
    end
    if current == "" and #list == 0 then return end
    item.set(nextName)
  end

  local function nextSide()
    local index = 1
    for i, side in ipairs(SIDES) do
      if side == live.side then index = i end
    end
    live.side = SIDES[index % #SIDES + 1]
    -- Only meaningful for the relay, and only sent when one is assigned.
    if live.relay ~= "" then actions.setEngineRelay(live.relay, live.side) end
  end

  local refresh

  local buttonRow = row
  local third = math.max(4, math.floor((width - 2) / 3))
  local setButton = Theme.button(parent, x, buttonRow, third, "PICK", nextCandidate)
  local sideButton = Theme.button(parent, x + third + 1, buttonRow, third, "SIDE", nextSide)
  local nextButton = Theme.button(parent, x + third * 2 + 2, buttonRow,
    math.max(3, width - third * 2 - 2), ">", function()
      selected = selected % #items + 1
      -- Redraw NOW. Waiting for the next telemetry frame is the same bug the pilot reported
      -- on the monitor rows: the label under your finger has to change on the tap.
      refresh()
    end)
  row = row + 1

  function refresh()
    local item = items[selected]
    title:setText(Theme.fit(item.title, width))
    hint:setText(Theme.fit(item.hint, width))

    local current = item.current() or ""
    if current == "" then
      valueLine:setText(Theme.fit("(not set)", width))
      valueLine:setForeground(Theme.warning)
    else
      valueLine:setText(Theme.fitEnd(current, width))
      valueLine:setForeground(Theme.ok)
    end

    if item.key == "relay" then
      extraLine:setText(Theme.fit("side " .. tostring(live.side), width))
      sideButton:setVisible(true)
    else
      extraLine:setText("")
      sideButton:setVisible(false)
    end

    local list = item.list() or {}
    if #list == 0 then
      countLine:setText(Theme.fit("none on network", width))
      countLine:setForeground(Theme.warning)
    else
      countLine:setText(Theme.fit(("%d found  item %d/%d"):format(#list, selected, #items), width))
      countLine:setForeground(Theme.dim)
    end
    setButton:setText(#list == 0 and "--" or "PICK")
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
    refresh()
  end

  return {
    update = update,
    refresh = refresh,
    rowsUsed = row - y,
    elements = {
      title = title, hint = hint, value = valueLine, extra = extraLine,
      count = countLine, pick = setButton, side = sideButton, next = nextButton,
    },
    --- Test seam: which item is on screen, and how to move on.
    select = function(index) selected = index; refresh() end,
    selected = function() return selected end,
    live = live,
  }
end

--- How many rows the widget needs.
function Hardware.rows()
  return 6
end

return Hardware
