--[[ The overhead panel -- above the driver's seat, facing down, 1 wide x 2 high.

     Engine start/stop, both fuel gauges (liquid tank and solid vault), and their configuration
     in a submenu. Mirrored to one monitor on either side of the cockpit: this module is
     instantiated once per assigned monitor and every instance is fed the same model, so the
     two screens cannot disagree.

     A 1x2 monitor at text scale 0.5 is about 15 x 20 characters. Everything is laid out from
     the frame's real size rather than from that assumption, and if a monitor turns out too
     small to be useful the panel says so instead of drawing nonsense.
]]

local Theme = require("ui.theme")
local Util = require("shared.util")
local Hardware = require("ui.hardware")

local Overhead = {}

local MIN_WIDTH, MIN_HEIGHT = 10, 14

--- opts = { cfg, actions, log }
--- actions = { engineMaster(bool), engineFeed(), configSet(path, value) }
function Overhead.build(frame, opts)
  local cfg, actions = opts.cfg, opts.actions
  local width = frame:getWidth()
  local height = frame:getHeight()

  frame:setBackground(Theme.bg)

  if width < MIN_WIDTH or height < MIN_HEIGHT then
    Theme.line(frame, 1, width, "TOO SMALL", Theme.warning)
    Theme.line(frame, 2, width, ("%dx%d"):format(width, height), Theme.dim)
    Theme.line(frame, 3, width, "need " .. MIN_WIDTH .. "x" .. MIN_HEIGHT, Theme.dim)
    return { update = function() end }
  end

  -- Two pages in one frame: only one is visible at a time.
  local main = frame:addFrame({ x = 1, y = 1, width = width, height = height,
    background = Theme.bg })
  local settings = frame:addFrame({ x = 1, y = 1, width = width, height = height,
    background = Theme.bg })
  settings:setVisible(false)

  -- ---------------------------------------------------------------- main page

  local y = 1
  local title = Theme.line(main, y, width, Theme.centre("EASYHOVER", width), Theme.accent)
  y = y + 1
  local stale = Theme.staleBanner(main, y, width)
  local modeLine = Theme.line(main, y, width, Theme.centre("--", width), Theme.dim)
  y = y + 1
  Theme.rule(main, y, width); y = y + 1

  Theme.heading(main, y, width, "ENGINE"); y = y + 1
  local engineState = Theme.line(main, y, width, "OFF", Theme.dim); y = y + 1
  local engineFeedLine = Theme.line(main, y, width, "", Theme.dim); y = y + 1
  -- Last reported state, kept in this closure. NOT on the element: Basalt's property system
  -- owns field access on an element, so an arbitrary key there is not a safe place for state.
  local reported = { master = false, invert = false, available = false }
  local engineButton = Theme.button(main, 1, y, math.min(width, 9), "START", function()
    -- With no relay assigned there is nothing to switch, so the button becomes the way IN to
    -- assigning one instead of a dead "--".
    if not reported.available then
      main:setVisible(false)
      settings:setVisible(true)
      return
    end
    -- Act on what the craft last told us, not on a local guess about what we asked for.
    actions.engineMaster(not reported.master)
  end)
  y = y + 1
  Theme.rule(main, y, width); y = y + 1

  Theme.heading(main, y, width, "TANK"); y = y + 1
  local tankGauge = Theme.gauge(main, y, width, cfg); y = y + 2
  Theme.rule(main, y, width); y = y + 1

  Theme.heading(main, y, width, "VAULT"); y = y + 1
  local vaultLine = Theme.line(main, y, width, "--", Theme.dim); y = y + 1

  -- Anything below here is optional: on a short monitor we simply run out of rows.
  local altLine, primeButton
  if y + 2 <= height then
    Theme.rule(main, y, width); y = y + 1
    altLine = Theme.line(main, y, width, "", Theme.dim); y = y + 1
  end
  if y <= height - 1 then
    -- "PRIME" meant nothing to anyone. This drops the funnel signal once, by hand, so exactly
    -- one item falls into the engine -- the same thing the keep-alive does on its timer.
    primeButton = Theme.button(main, 1, y, math.min(width, 7), "FEED 1", function()
      actions.engineFeed()
    end)
  end
  Theme.button(main, math.max(1, width - 4), math.min(height, y), 5, "CFG", function()
    main:setVisible(false)
    settings:setVisible(true)
  end)

  -- ---------------------------------------------------------------- settings page

  local sy = 1
  Theme.line(settings, sy, width, Theme.centre("ENGINE CFG", width), Theme.accent); sy = sy + 1
  Theme.rule(settings, sy, width); sy = sy + 1

  --- A "label / value / -+" row driven by a config path.
  local function tunable(label, path, step, minimum, maximum, unit)
    local nameLine = Theme.line(settings, sy, width, label, Theme.dim); sy = sy + 1
    local valueLine = Theme.line(settings, sy, width, "--", Theme.fg)
    local row = { path = path, value = nil, label = nameLine, display = valueLine }
    local function nudge(delta)
      if type(row.value) ~= "number" then return end
      local next = Util.clamp(row.value + delta, minimum, maximum)
      if next ~= row.value then actions.configSet(path, next) end
    end
    row.minus = Theme.button(settings, math.max(1, width - 6), sy, 3, "-", function() nudge(-step) end)
    row.plus = Theme.button(settings, math.max(1, width - 2), sy, 3, "+", function() nudge(step) end)
    sy = sy + 1
    row.set = function(value)
      row.value = value
      valueLine:setText(type(value) == "number"
        and (Util.num(value, 0) .. (unit or "")) or "--")
    end
    return row
  end

  local pulseRow = tunable("pulse", "engine.pulseMs", 50, 50, 5000, "ms")
  local intervalRow = tunable("interval", "engine.intervalMs", 500, 500, 120000, "ms")

  local invertLine = Theme.line(settings, sy, width, "invert", Theme.dim)
  local invertButton = Theme.button(settings, math.max(1, width - 5), sy, 6, "OFF", function()
    actions.configSet("engine.invert", not reported.invert)
  end)
  sy = sy + 1

  -- The gauge needs a maximum to draw a bar against. Create usually reports one; when it does
  -- not, this is the fallback, and 0 means "trust whatever the tank reports" -- which the row
  -- itself says by showing "auto", so no hint line is spent on it. Rows are scarce here: every
  -- one saved is a hardware candidate the pilot can see without paging.
  local capacityRow = tunable("tank max", "hardware.tanks.1.capacityMb", 1000, 0, 1000000, "")

  Theme.rule(settings, sy, width); sy = sy + 1

  -- The same hardware picker the config panel uses, so the overhead monitor can assign the
  -- relay, tank and vault without walking to another screen.
  local hardware = nil
  if sy + Hardware.rows() <= height then
    hardware = Hardware.build(settings, 1, sy, width, height - sy, opts)
  else
    Theme.line(settings, sy, width, "hardware: use", Theme.dim)
    Theme.line(settings, sy + 1, width, "CONFIG > HW", Theme.dim)
  end

  Theme.button(settings, 1, height, math.min(width, 6), "BACK", function()
    settings:setVisible(false)
    main:setVisible(true)
  end)

  -- ---------------------------------------------------------------- update

  local function update(model)
    local t = model.telemetry
    stale:setVisible(model.stale)
    modeLine:setVisible(not model.stale)

    if model.stale then
      stale:setText(Theme.centre(model.ageMs == math.huge and "NO LINK" or "NO DATA", width))
      engineState:setText("?")
      engineState:setForeground(Theme.dim)
      engineFeedLine:setText("")
      tankGauge.set(nil, "--")
      vaultLine:setText("--")
      if altLine then altLine:setText("") end
      return
    end

    modeLine:setText(Theme.centre(tostring(t.mode or "--"), width))
    modeLine:setForeground(t.mode == "GROUND" and Theme.dim or Theme.ok)

    -- engine
    local engine = t.engine or {}
    reported.master = engine.master and true or false
    reported.available = engine.available and true or false
    if not engine.available then
      engineState:setText("NO RELAY")
      engineState:setForeground(Theme.warning)
      engineButton:setText("SET UP")
      engineButton:setBackground(Theme.caution)
      engineButton:setForeground(colours.black)
    else
      engineState:setText(engine.master and "RUNNING" or "OFF")
      engineState:setForeground(engine.master and Theme.ok or Theme.dim)
      engineButton:setText(engine.master and "STOP" or "START")
      engineButton:setBackground(engine.master and Theme.warning or Theme.ok)
      engineButton:setForeground(colours.black)
    end
    if engine.master and type(engine.nextFeedInMs) == "number" then
      engineFeedLine:setText(("feed %.1fs"):format(engine.nextFeedInMs / 1000))
    elseif engine.feeding then
      engineFeedLine:setText("feeding")
    else
      engineFeedLine:setText(engine.pulses and ("fed " .. tostring(engine.pulses) .. " items") or "")
    end

    -- liquid fuel
    local fuel = t.fuel or {}
    local tank = (fuel.tanks or {})[1]
    if tank then
      local text
      if tank.capacity and tank.capacity > 0 then
        text = ("%d/%d"):format(tank.amount or 0, tank.capacity)
      else
        -- no capacity reported and none configured: show the raw amount, no fake scale
        text = ("%d mB"):format(tank.amount or 0)
      end
      tankGauge.set(tank.fraction, Theme.fit(text, width))
    else
      tankGauge.set(nil, "not set: CFG")
    end

    -- solid fuel
    local vault = (fuel.vaults or {})[1]
    if vault then
      vaultLine:setText(Theme.fit(("%d items"):format(vault.count or 0), width))
      vaultLine:setForeground(vault.empty and Theme.warning or Theme.fg)
    else
      vaultLine:setText("not set: CFG")
      vaultLine:setForeground(Theme.dim)
    end

    if altLine then
      local alt = (t.altitude or {}).baro
      local vs = (t.altitude or {}).vs
      altLine:setText(Theme.fit(("ALT %s %s"):format(Util.num(alt, 1),
        type(vs) == "number" and (vs >= 0 and "+" or "") .. Util.num(vs, 1) or ""), width))
    end

    -- settings page mirrors the live config values the flight computer reports back
    local liveCfg = t.config or {}
    pulseRow.set(liveCfg.enginePulseMs)
    intervalRow.set(liveCfg.engineIntervalMs)
    if liveCfg.tankCapacityMb == nil then
      -- There is no tank assigned, so there is no capacity to edit and -/+ cannot do anything.
      -- Say which, rather than showing "--" over two buttons that silently refuse.
      capacityRow.value = nil
      capacityRow.display:setText("set tank")
      capacityRow.display:setForeground(Theme.dim)
    elseif liveCfg.tankCapacityMb == 0 then
      capacityRow.value = 0
      capacityRow.display:setText("auto")
      capacityRow.display:setForeground(Theme.fg)
    else
      capacityRow.set(liveCfg.tankCapacityMb)
      capacityRow.display:setForeground(Theme.fg)
    end
    if hardware then hardware.update(model) end
    if liveCfg.engineInvert ~= nil then
      reported.invert = liveCfg.engineInvert and true or false
      invertButton:setText(reported.invert and "ON" or "OFF")
    end
  end

  return {
    update = update,
    main = main,
    settings = settings,
    -- A deliberate test seam: tests/test_ui.lua asserts on the rendered text rather than on
    -- the model, so a panel that silently stops updating is caught.
    elements = {
      modeLine = modeLine, stale = stale, engineState = engineState,
      engineButton = engineButton, engineFeed = engineFeedLine,
      tankValue = tankGauge.value, tankBar = tankGauge.bar, vault = vaultLine,
      pulse = pulseRow, interval = intervalRow, invert = invertButton,
      capacity = capacityRow, feed = primeButton,
    },
    hardware = hardware,
  }
end

return Overhead
