--[[ The overhead panel -- above the driver's seat, facing down, 1 wide x 2 high.

     Engine start/stop and both fuel gauges (liquid tank and solid vault). NOTHING IS
     CONFIGURED HERE -- every craft setting lives on the config monitor, which freed the rows
     this panel needed for the things a pilot reads at a glance. Mirrored to one monitor on
     either side of the cockpit: this module is instantiated once per assigned monitor and
     every instance is fed the same model, so the two screens cannot disagree.

     A 1x2 monitor at text scale 0.5 is about 15 x 20 characters. Everything is laid out from
     the frame's real size rather than from that assumption, and if a monitor turns out too
     small to be useful the panel says so instead of drawing nonsense.
]]

local Theme = require("ui.theme")
local Util = require("shared.util")

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

  local main = frame:addFrame({ x = 1, y = 1, width = width, height = height,
    background = Theme.bg })

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
    -- With no relay assigned there is nothing to switch. The label says CONFIG and the button
    -- does nothing, rather than sending a command the craft would only refuse.
    if not reported.available then return end
    -- Act on what the craft last told us, not on a local guess about what we asked for.
    actions.engineMaster(not reported.master)
  end)
  y = y + 1
  Theme.rule(main, y, width); y = y + 1

  -- FLIGHT CONTROL arm/disarm. The mixer (the PID) runs only when this is ENGAGED, so preflight is
  -- provably safe: SELF TEST, SELF CONFIG, AXIS MAP and just warming the engine on the pad all
  -- happen with flight control OFF. Reflects the CRAFT's reported arm state, never the tap.
  Theme.heading(main, y, width, "FLIGHT CTRL"); y = y + 1
  local flightArmed = false
  local flightButton = Theme.button(main, 1, y, math.min(width, 11), "SAFE", function()
    actions.flightArm(not flightArmed)
  end)
  y = y + 1
  -- Why an ENGAGED craft is (or is not) firing. "ENGAGED" alone hid the pad-safety gate: the mixer
  -- holds until the engine is on AND the craft is airborne or climbing, and a silent throttle then
  -- looked broken. This line names the reason so the pilot knows what to do next.
  local flightHoldLine = Theme.line(main, y, width, "", Theme.dim); y = y + 1
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
  -- The rows the settings page used to need are now free, so the vault gauge and the
  -- altitude line both fit on a 1x2 screen. Configuration lives on the config monitor.

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
      flightButton:setText("?")
      flightButton:setBackground(Theme.buttonBg)
      flightButton:setForeground(Theme.dim)
      flightHoldLine:setText("")
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
      engineButton:setText("CONFIG")
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

    -- flight control arm state, from the CRAFT. ENGAGED gets a caution colour because the mixer is
    -- then live and may command thrusters; SAFE is dim because nothing can fire.
    flightArmed = (t.modes or {}).armed and true or false
    flightButton:setText(flightArmed and "ENGAGED" or "SAFE")
    flightButton:setBackground(flightArmed and Theme.caution or Theme.buttonBg)
    flightButton:setForeground(flightArmed and colours.black or Theme.buttonFg)

    -- Why the mixer is or is not actuating. Only meaningful once ENGAGED -- SAFE explains itself.
    -- `hold` is the craft's reported reason; absent while ENGAGED means the mixer IS flying it.
    local hold = (t.flight or {}).hold
    if not flightArmed then
      flightHoldLine:setText("")
    elseif hold == "ENGINE OFF" then
      -- No "hold:" prefix -- it overflows a 15-wide monitor and the word is clear on its own.
      flightHoldLine:setText(Theme.fit("ENGINE OFF", width))
      flightHoldLine:setForeground(Theme.warning)
    elseif hold == "ON GROUND" then
      flightHoldLine:setText(Theme.fit("ready: CLIMB up", width))
      flightHoldLine:setForeground(Theme.caution)
    elseif hold then
      -- DISENGAGED here would contradict flightArmed; any other hold is shown verbatim.
      flightHoldLine:setText(Theme.fit(tostring(hold), width))
      flightHoldLine:setForeground(Theme.warning)
    else
      flightHoldLine:setText(Theme.fit("LIVE", width))
      flightHoldLine:setForeground(Theme.ok)
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

    reported.invert = (t.config or {}).engineInvert and true or false
  end

  return {
    update = update,
    main = main,
    -- A deliberate test seam: tests/test_ui.lua asserts on the rendered text rather than on
    -- the model, so a panel that silently stops updating is caught.
    elements = {
      modeLine = modeLine, stale = stale, engineState = engineState,
      engineButton = engineButton, engineFeed = engineFeedLine,
      flightButton = flightButton, flightHold = flightHoldLine,
      tankValue = tankGauge.value, tankBar = tankGauge.bar, vault = vaultLine,
      feed = primeButton,
    },
  }
end

return Overhead
