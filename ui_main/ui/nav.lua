--[[ The nav panel -- and, for now, the pre-flight test screens that live on its border.

     Navigation itself comes later. The centre of this screen is reserved for the map and the
     waypoint list, so it is deliberately left empty; the BORDER is free real estate, and the
     two things a pilot needs before a first flight sit on the bottom edge:

       FCS TEST   every flight input, drawn from the craft's OWN internal state. Move a
                  control and watch the bar move. If it does not, the problem is on the
                  ground rather than in the air.
       SELF TEST  sweeps each thruster group's nozzles, on the ground, so you can see that
                  the thruster you assigned to a slot is the one that moves -- and WHICH WAY
                  its nozzle goes when the software deflects it.

     Both replace the nav view until backed out, as asked.

     NO OPTIMISTIC FEEDBACK, as everywhere: every bar, mode and timer here is the craft's
     reported state. A test screen that showed what it had asked for would be worse than none.
]]

local Theme = require("ui.theme")
local Util = require("shared.util")

local Nav = {}

local MIN_WIDTH, MIN_HEIGHT = 14, 12

--- The pilot axes, in the order they sit under your hands.
local AXES = {
  { key = "accel",  label = "THR", signed = true,  hint = "reverse / forward" },
  { key = "climb",  label = "LFT", signed = true,  hint = "descend / climb" },
  { key = "pitch",  label = "PCH", signed = true },
  { key = "roll",   label = "RLL", signed = true },
  { key = "yaw",    label = "YAW", signed = true },
}

Nav.AXES = AXES

--- A signed bar for a -1..+1 axis, with the centre marked so zero is visible.
---
--- Signed, because throttle runs from reverse through zero to forward and a 0..1 bar would
--- make full reverse and neutral look the same -- which is the one confusion that matters here.
local function signedBar(frame, y, width, label)
  local labelWidth = math.min(4, width)
  local barWidth = math.max(4, width - labelWidth - 6)
  local name = Theme.line(frame, y, width, label, Theme.dim)
  local bar = frame:addLabel({ x = labelWidth + 1, y = y, width = barWidth,
    background = Theme.bg, foreground = Theme.fg })
  local value = frame:addLabel({ x = labelWidth + barWidth + 1, y = y,
    width = math.max(5, width - labelWidth - barWidth), background = Theme.bg,
    foreground = Theme.fg })

  local centre = math.floor(barWidth / 2) + 1
  return {
    name = name, bar = bar, value = value,
    --- v in -1..+1, or nil for "no data"
    set = function(v)
      if type(v) ~= "number" then
        bar:setText(("."):rep(barWidth))
        bar:setForeground(Theme.dim)
        value:setText("  --")
        return
      end
      v = Util.clamp(v, -1, 1)
      local cells = {}
      for i = 1, barWidth do cells[i] = (i == centre) and "|" or " " end
      local span = centre - 1
      local reach = math.floor(math.abs(v) * span + 0.5)
      for i = 1, reach do
        local at = (v >= 0) and (centre + i) or (centre - i)
        if at >= 1 and at <= barWidth then cells[at] = "#" end
      end
      bar:setText(table.concat(cells))
      bar:setForeground(math.abs(v) < 0.02 and Theme.dim or Theme.ok)
      value:setText(("%5.2f"):format(v))
    end,
  }
end

Nav.signedBar = signedBar

--- opts = { cfg, actions, log, lastAck }
function Nav.build(frame, opts)
  local actions = opts.actions
  local width, height = frame:getWidth(), frame:getHeight()
  frame:setBackground(Theme.bg)

  if width < MIN_WIDTH or height < MIN_HEIGHT then
    Theme.line(frame, 1, width, "NAV: TOO", Theme.warning)
    Theme.line(frame, 2, width, "SMALL", Theme.warning)
    Theme.line(frame, 3, width, ("%dx%d"):format(width, height), Theme.dim)
    return { update = function() end, elements = {}, pages = {} }
  end

  local live = { pilot = {}, modes = {}, selfTest = {}, stale = true }

  local pages = {}
  local function page()
    local p = frame:addFrame({ x = 1, y = 1, width = width, height = height,
      background = Theme.bg })
    p:setVisible(false)
    pages[#pages + 1] = p
    return p
  end

  local navPage, fcsPage, selfPage, axisPage = page(), page(), page(), page()
  navPage:setVisible(true)

  local function show(target)
    for _, p in ipairs(pages) do p:setVisible(p == target) end
  end

  -- ---------------------------------------------------------------- nav view

  Theme.line(navPage, 1, width, Theme.centre("NAV", width), Theme.accent)
  Theme.rule(navPage, 2, width)

  -- The middle is left empty ON PURPOSE: the map and waypoint list land here, and filling it
  -- with placeholder decoration now would only have to be torn out.
  local reservedTop = 3
  local reservedBottom = height - 2
  local navPlaceholder = Theme.line(navPage, math.floor((reservedTop + reservedBottom) / 2),
    width, Theme.centre("no nav yet", width), Theme.dim)

  -- the border carries the pre-flight tests: three buttons across the bottom edge
  local third = math.max(5, math.floor((width - 2) / 3))
  Theme.button(navPage, 1, height, third, "FCS TEST", function() show(fcsPage) end)
  Theme.button(navPage, third + 2, height, third, "SELFTEST", function() show(selfPage) end)
  Theme.button(navPage, third * 2 + 3, height, math.max(5, width - third * 2 - 2), "AXISMAP",
    function() show(axisPage) end)

  -- ---------------------------------------------------------------- FCS test

  Theme.line(fcsPage, 1, width, Theme.centre("FCS TEST", width), Theme.accent)
  local fcsStale = Theme.line(fcsPage, 2, width, "", Theme.dim)

  local bars, by = {}, 3
  for _, axis in ipairs(AXES) do
    if by <= height - 5 then
      bars[axis.key] = signedBar(fcsPage, by, width, axis.label)
      by = by + 1
    end
  end
  Theme.rule(fcsPage, by, width); by = by + 1

  local brakeLine = Theme.line(fcsPage, by, width, "", Theme.dim); by = by + 1
  local modeLine = Theme.line(fcsPage, by, width, "", Theme.fg); by = by + 1
  local sourceLine = Theme.line(fcsPage, math.min(by, height - 1), width, "", Theme.dim)

  Theme.button(fcsPage, 1, height, math.min(6, width), "BACK", function() show(navPage) end)

  -- --------------------------------------------------------------- self test

  Theme.line(selfPage, 1, width, Theme.centre("SELF TEST", width), Theme.accent)
  local selfWarn = Theme.line(selfPage, 2, width, "GROUND ONLY", Theme.caution)

  local stepLines = {}
  local sy = 3
  for i = 1, 3 do
    stepLines[i] = Theme.line(selfPage, sy, width, "", Theme.dim)
    sy = sy + 1
  end
  Theme.rule(selfPage, sy, width); sy = sy + 1
  local selfStatus = Theme.line(selfPage, sy, width, "", Theme.fg); sy = sy + 1
  local selfTimer = Theme.line(selfPage, sy, width, "", Theme.accent); sy = sy + 1
  local selfWatch = Theme.line(selfPage, sy, width, "", Theme.dim); sy = sy + 1
  local selfResult = Theme.line(selfPage, math.min(sy, height - 2), width, "", Theme.dim)

  local startButton = Theme.button(selfPage, 1, height - 1, math.min(9, width), "START",
    function() actions.selfTest("start") end)
  Theme.button(selfPage, math.max(1, width - 6), height - 1, 7, "ABORT",
    function() actions.selfTest("abort") end)
  Theme.button(selfPage, 1, height, math.min(6, width), "BACK", function() show(navPage) end)

  -- --------------------------------------------------------------- axis map

  Theme.line(axisPage, 1, width, Theme.centre("AXIS MAP", width), Theme.accent)
  local axisHint = Theme.line(axisPage, 2, width, "tap a nozzle direction", Theme.dim)
  Theme.rule(axisPage, 3, width)

  --- One row per thruster, four buttons per row: the nozzle's OWN four deflections. Tapping one
  --- latches that nozzle at full deflection so you can walk out and look at it; the panel below
  --- lights up with the direction the system currently believes it points, and holding a/d/w/s
  --- on the typewriter renames it.
  ---
  --- A LATCH, not a held switch: CC delivers `monitor_touch` and nothing whatsoever for the
  --- release, so press-and-hold on a monitor is not expressible. Tap again to let go.
  local axisLabelWidth = math.max(3, math.min(6, width - 12))
  local axisButtonWidth = math.max(3, math.floor((width - axisLabelWidth) / 4))
  local axisFooterRow = height - 2
  local axisRowCount = math.max(1, axisFooterRow - 4)
  local axisRows, axisPageIndex = {}, 1
  local refreshAxisRows

  local DEFLECTIONS = {
    { axis = "x", sign = 1, label = "X+" },
    { axis = "x", sign = -1, label = "X-" },
    { axis = "y", sign = 1, label = "Y+" },
    { axis = "y", sign = -1, label = "Y-" },
  }

  for i = 1, axisRowCount do
    local row = { entry = nil, buttons = {} }
    row.label = Theme.line(axisPage, 3 + i, axisLabelWidth, "", Theme.fg)
    for j, deflection in ipairs(DEFLECTIONS) do
      row.buttons[j] = Theme.button(axisPage,
        axisLabelWidth + (j - 1) * axisButtonWidth + 1, 3 + i, axisButtonWidth,
        deflection.label, function()
          local e = row.entry
          if not e then return end
          local held = live.axisMap or {}
          -- tapping the one already latched releases it
          if held.holding and held.id == e.id and held.axis == deflection.axis
            and held.sign == deflection.sign then
            actions.vectorHold("release", e.id, deflection.axis, deflection.sign)
          else
            actions.vectorHold("latch", e.id, deflection.axis, deflection.sign)
          end
        end)
    end
    axisRows[i] = row
  end

  local axisFooter = Theme.line(axisPage, axisFooterRow, width, "", Theme.dim)
  local axisHolding = Theme.line(axisPage, height - 1, width, "", Theme.fg)
  Theme.button(axisPage, 1, height, math.min(6, width), "BACK", function()
    actions.vectorHold("release", "", "x", 1)
    show(navPage)
  end)
  local axisRelease = Theme.button(axisPage, math.max(1, width - 8), height, 9, "RELEASE",
    function() actions.vectorHold("release", "", "x", 1) end)

  function refreshAxisRows()
    local list = live.thrusterAxes or {}
    local held = live.axisMap or {}
    local pagesTotal = math.max(1, math.ceil(#list / axisRowCount))
    axisPageIndex = math.max(1, math.min(axisPageIndex, pagesTotal))

    for i, row in ipairs(axisRows) do
      local entry = list[(axisPageIndex - 1) * axisRowCount + i]
      row.entry = entry
      row.label:setVisible(entry ~= nil)
      if entry then
        row.label:setText(Theme.fit((entry.group:sub(1, 3) .. tostring(entry.key)):upper(),
          axisLabelWidth))
      end
      for j, button in ipairs(row.buttons) do
        button:setVisible(entry ~= nil)
        if entry then
          local d = DEFLECTIONS[j]
          local isHeld = held.holding and held.id == entry.id and held.axis == d.axis
            and held.sign == d.sign
          button:setBackground(isHeld and Theme.warning or Theme.buttonBg)
          button:setForeground(isHeld and colours.white or Theme.buttonFg)
        end
      end
    end

    if #list == 0 then
      axisFooter:setText(Theme.fit("no thrusters assigned", width))
      axisFooter:setForeground(Theme.warning)
    elseif pagesTotal > 1 then
      axisFooter:setText(Theme.fit(("%d thrusters  pg %d/%d"):format(#list, axisPageIndex,
        pagesTotal), width))
      axisFooter:setForeground(Theme.dim)
    else
      axisFooter:setText(Theme.fit(("%d thrusters"):format(#list), width))
      axisFooter:setForeground(Theme.dim)
    end

    -- THE LIT PANEL: what is deflected, and what the system thinks that direction is.
    if held.holding then
      axisHolding:setText(Theme.fit(("%s %s%s = %s"):format(tostring(held.id),
        held.sign > 0 and "+" or "-", tostring(held.axis),
        tostring(held.direction or "?")), width))
      axisHolding:setForeground(Theme.ok)
      -- The legend comes from the CRAFT, which owns the plane rule. A lateral nozzle cannot
      -- point sideways, so a hardcoded "a/d = left/right" here would be a lie on four of them.
      axisHint:setText(Theme.fit(tostring(held.legend or "hold a/d w/s"), width))
      axisHint:setForeground(Theme.accent)
      axisRelease:setBackground(Theme.warning)
      axisRelease:setForeground(colours.white)
    else
      axisHolding:setText("")
      axisHint:setText(Theme.fit("tap a nozzle, then hold a/d/w/s", width))
      axisHint:setForeground(Theme.dim)
      axisRelease:setBackground(Theme.buttonBg)
      axisRelease:setForeground(Theme.buttonFg)
    end
    if held.error then
      axisHolding:setText(Theme.fitEnd(tostring(held.error), width))
      axisHolding:setForeground(Theme.warning)
    end
  end
  refreshAxisRows()

  -- ---------------------------------------------------------------- update

  local function update(model)
    local t = model.telemetry or {}
    live.stale = model.stale
    live.pilot = t.pilot or {}
    live.modes = t.modes or {}
    live.selfTest = t.selfTest or {}
    live.thrusterAxes = t.thrusterAxes or {}
    live.axisMap = t.axisMap or {}
    refreshAxisRows()

    navPlaceholder:setText(Theme.centre(model.stale and "NO DATA" or "no nav yet", width))
    navPlaceholder:setForeground(model.stale and Theme.warning or Theme.dim)

    -- ---- FCS
    fcsStale:setText(model.stale and "NO DATA -- craft not reporting" or "live from the craft")
    fcsStale:setForeground(model.stale and Theme.warning or Theme.dim)

    local axes = live.pilot.axes or {}
    for _, axis in ipairs(AXES) do
      local bar = bars[axis.key]
      if bar then bar.set(model.stale and nil or axes[axis.key]) end
    end

    if model.stale then
      brakeLine:setText("")
      modeLine:setText("")
      sourceLine:setText("")
    else
      local braking = live.pilot.brake and true or false
      brakeLine:setText(Theme.fit("BRAKE " .. (braking and "HELD" or "off"), width))
      brakeLine:setForeground(braking and Theme.warning or Theme.dim)

      modeLine:setText(Theme.fit(("%s %s%s"):format(
        tostring(live.modes.feel or "-"),
        tostring(live.modes.lateral or "-"),
        live.modes.assist and " AST" or ""), width))

      -- Which input device the craft is actually hearing. A dead typewriter looks exactly
      -- like a pilot who is not touching anything, until you can see this.
      local parts = {}
      if live.pilot.controller then parts[#parts + 1] = "ctrl" end
      if live.pilot.typewriter then parts[#parts + 1] = "typwr" end
      sourceLine:setText(Theme.fit(#parts > 0 and ("in: " .. table.concat(parts, "+"))
        or "no input device", width))
      sourceLine:setForeground(#parts > 0 and Theme.dim or Theme.warning)
    end

    -- ---- self test
    local st = live.selfTest
    local STEP_LABELS = { "1 LIFT THR", "2 LATERAL THR", "3 ACCEL THR" }
    for i, line in ipairs(stepLines) do
      local label = STEP_LABELS[i]
      if st.running and st.step == i then
        line:setText(Theme.fit("> " .. label, width))
        line:setForeground(Theme.accent)
      elseif st.running and st.step > i then
        line:setText(Theme.fit("+ " .. label, width))
        line:setForeground(Theme.ok)
      else
        line:setText(Theme.fit("  " .. label, width))
        line:setForeground(Theme.dim)
      end
    end

    if st.running then
      selfStatus:setText(Theme.fit(tostring(st.label or ""), width))
      selfStatus:setForeground(Theme.fg)
      selfTimer:setText(Theme.fit(("%s  %.0fs left"):format(tostring(st.phase or ""),
        (st.stepRemainingMs or 0) / 1000), width))
      selfWatch:setText(Theme.fit("watch: " .. tostring(st.watch or ""), width))
      startButton:setText("RUNNING")
      startButton:setBackground(Theme.caution)
      startButton:setForeground(colours.black)
    else
      selfTimer:setText("")
      selfWatch:setText("")
      startButton:setText("START")
      startButton:setBackground(Theme.buttonBg)
      startButton:setForeground(Theme.buttonFg)
      if st.aborted then
        selfStatus:setText(Theme.fit(tostring(st.aborted), width))
        selfStatus:setForeground(Theme.warning)
      elseif st.complete then
        selfStatus:setText("complete")
        selfStatus:setForeground(Theme.ok)
      else
        selfStatus:setText(model.stale and "" or "ready")
        selfStatus:setForeground(Theme.dim)
      end
    end

    -- What the run found: how many of each group could actually be swept. A group with no
    -- nozzles is the interesting answer, so it is the one reported.
    local findings = st.findings
    if findings then
      local parts = {}
      for _, group in ipairs({ "lift", "lateral", "main" }) do
        local f = findings[group]
        if f then
          parts[#parts + 1] = ("%s %d/%d"):format(group:sub(1, 3), #(f.vectoring or {}), f.count)
        end
      end
      selfResult:setText(Theme.fit(table.concat(parts, " "), width))
    else
      selfResult:setText("")
    end

    -- A refusal has to be visible; the craft is the only thing that knows it is airborne.
    local ack = opts.lastAck and opts.lastAck()
    if ack and ack.cmd == "selfTest" and ack.ack == false then
      local detail = ack.detail or {}
      selfStatus:setText(Theme.fitEnd(tostring(detail.error or "REFUSED"), width))
      selfStatus:setForeground(Theme.warning)
    end
  end

  return {
    update = update,
    show = show,
    pages = { nav = navPage, fcs = fcsPage, selfTest = selfPage, axisMap = axisPage },
    axisRows = axisRows,
    bars = bars,
    elements = {
      placeholder = navPlaceholder, fcsStale = fcsStale, brake = brakeLine,
      mode = modeLine, source = sourceLine, warn = selfWarn,
      steps = stepLines, status = selfStatus, timer = selfTimer,
      watch = selfWatch, result = selfResult, start = startButton,
      axisHint = axisHint, axisFooter = axisFooter, axisHolding = axisHolding,
      axisRelease = axisRelease,
    },
  }
end

return Nav
