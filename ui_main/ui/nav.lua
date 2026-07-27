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

--- THE SMALLEST MONITOR ANYONE ACTUALLY USES: one block at text scale 0.5, which is 15x10.
--- The floor was 14x12, chosen from what the pages happened to need rather than from the
--- hardware, so the standard single monitor got "TOO SMALL" and nothing else. Every page below
--- is laid out to fit in 10 rows, and 15 columns is what the axis map's label + four buttons
--- need (3 + 4*3). 0.5 is CC's finest text scale, so nothing can be gained below this.
local MIN_WIDTH, MIN_HEIGHT = 15, 10

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
    Theme.line(frame, 4, width, ("need %dx%d"):format(MIN_WIDTH, MIN_HEIGHT), Theme.dim)
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

  --- A line that is only placed if a row was spared for it. It is created either way, so
  --- update() never needs to know which rows a given monitor could afford -- an unplaced one is
  --- simply invisible. Passing `nil` for the row is how a caller says "no room".
  local function optionalLine(parent, row, text, colour)
    local element = Theme.line(parent, row or 1, width, text, colour)
    if row == nil then element:setVisible(false) end
    return element
  end

  -- ---------------------------------------------------------------- nav view

  Theme.line(navPage, 1, width, Theme.centre("NAV", width), Theme.accent)
  Theme.rule(navPage, 2, width)

  -- The middle is left empty ON PURPOSE: the map and waypoint list land here, and filling it
  -- with placeholder decoration now would only have to be torn out.
  local reservedTop = 3
  -- The border carries the pre-flight tests. THREE ACROSS ONLY IF THE LABELS FIT: the widest is
  -- "FCS TEST" at 8, so a single row needs 3*8 + 2 gaps = 26 columns. Below that they stack, one
  -- per row up the bottom edge. Squeezed onto one row on a 15-wide screen they read
  -- "FCS T SELFT AXI" and the third one hangs off the right edge -- unreadable, and these three
  -- buttons are the whole point of the screen before a first flight.
  local BUTTONS = {
    { "FCS TEST", function() show(fcsPage) end },
    { "SELFTEST", function() show(selfPage) end },
    { "AXISMAP",  function() show(axisPage) end },
  }
  local stacked = width < 26
  local reservedBottom = stacked and (height - #BUTTONS - 1) or (height - 2)

  local navPlaceholder = Theme.line(navPage, math.floor((reservedTop + reservedBottom) / 2),
    width, Theme.centre("no nav yet", width), Theme.dim)

  local testButtons = {}
  if stacked then
    for i, entry in ipairs(BUTTONS) do
      testButtons[i] = Theme.button(navPage, 1, height - #BUTTONS + i, width, entry[1], entry[2])
    end
  else
    local third = math.floor((width - 2) / 3)
    testButtons[1] = Theme.button(navPage, 1, height, third, BUTTONS[1][1], BUTTONS[1][2])
    testButtons[2] = Theme.button(navPage, third + 2, height, third, BUTTONS[2][1], BUTTONS[2][2])
    -- the last one takes the remainder so it ends exactly on the right edge, never past it
    testButtons[3] = Theme.button(navPage, third * 2 + 3, height, width - third * 2 - 2,
      BUTTONS[3][1], BUTTONS[3][2])
  end

  -- ---------------------------------------------------------------- FCS test

  Theme.line(fcsPage, 1, width, Theme.centre("FCS TEST", width), Theme.accent)

  --- ALL FIVE AXES, OR NONE. The bar loop used to stop at `height - 5`, which on a 10-row
  --- monitor drew three bars and silently dropped roll and yaw -- so a dead roll input would
  --- have passed the one test whose entire purpose is to catch it. The five bars and the BACK
  --- button are now mandatory; everything else is spent out of what is left, in the order it is
  --- worth having. A screen too short for all five is refused by MIN_HEIGHT instead.
  local spare = height - (1 + #AXES + 1)      -- title, bars, BACK
  local wantStale = spare >= 4
  local wantRule = spare >= 5

  local by = 2
  local function take()
    local row = by
    by = by + 1
    return row
  end

  local fcsStale = optionalLine(fcsPage, wantStale and take() or nil, "", Theme.dim)

  local bars = {}
  for _, axis in ipairs(AXES) do
    bars[axis.key] = signedBar(fcsPage, take(), width, axis.label)
  end

  if wantRule then Theme.rule(fcsPage, take(), width) end

  local brakeLine = optionalLine(fcsPage, spare >= 1 and take() or nil, "", Theme.dim)
  local modeLine = optionalLine(fcsPage, spare >= 2 and take() or nil, "", Theme.fg)
  local sourceLine = optionalLine(fcsPage, spare >= 3 and take() or nil, "", Theme.dim)

  Theme.button(fcsPage, 1, height, math.min(6, width), "BACK", function() show(navPage) end)

  -- --------------------------------------------------------------- self test

  Theme.line(selfPage, 1, width, Theme.centre("SELF TEST", width), Theme.accent)

  --- Same budgeting as the FCS page, and for a sharper reason: these rows used to be placed by
  --- `math.min(sy, height - 2)`, which on a 10-row monitor stacked the result on top of the
  --- timer and START/ABORT on top of the watchdog line. Overlapping Basalt elements do not
  --- error -- they just draw over each other, so the screen lies rather than breaks.
  --- Mandatory: title, three step lines, status, the START/ABORT row, BACK.
  local selfSpare = height - (1 + 3 + 1 + 1 + 1)
  local sy = 2
  local function takeSelf()
    local row = sy
    sy = sy + 1
    return row
  end

  -- GROUND ONLY first: the craft enforces the interlock, but the pilot should be told before
  -- the button is within reach rather than after.
  local selfWarn = optionalLine(selfPage, selfSpare >= 1 and takeSelf() or nil,
    "GROUND ONLY", Theme.caution)

  local stepLines = {}
  for i = 1, 3 do stepLines[i] = Theme.line(selfPage, takeSelf(), width, "", Theme.dim) end

  if selfSpare >= 5 then Theme.rule(selfPage, takeSelf(), width) end
  local selfStatus = Theme.line(selfPage, takeSelf(), width, "", Theme.fg)
  -- selfWatch OUTRANKS THE TIMER. It carries commanded-against-achieved for the witness nozzle,
  -- which is the answer to "it says running and nothing is moving" -- and on a 10-row monitor it
  -- was the first row dropped, so the one screen that could have answered the question showed a
  -- countdown instead. How long is left only matters once something is known to be happening.
  local selfWatch = optionalLine(selfPage, selfSpare >= 2 and takeSelf() or nil, "", Theme.dim)
  local selfTimer = optionalLine(selfPage, selfSpare >= 3 and takeSelf() or nil, "", Theme.accent)
  local selfResult = optionalLine(selfPage, selfSpare >= 4 and takeSelf() or nil, "", Theme.dim)

  -- START stops one column short of ABORT. They used to be `min(9, width)` and `width - 6`,
  -- which on a 15-wide screen both claimed column 9: the labels happened not to collide, but a
  -- tap on that column hit whichever button drew last.
  local abortX = math.max(1, width - 6)
  local startButton = Theme.button(selfPage, 1, height - 1,
    math.max(4, math.min(9, abortX - 2)), "START", function() actions.selfTest("start") end)
  Theme.button(selfPage, abortX, height - 1, 7, "ABORT",
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

  --- PAGE NAVIGATION. There was none: axisPageIndex was clamped and read, but nothing ever
  --- changed it, so with twelve thrusters and four rows to a page only the first four were
  --- reachable -- the footer said "pg 1/3" and there was no way to get to 2 or 3. It stayed
  --- hidden because a tall monitor fits all twelve on one page.
  local axisFooterWidth = width
  local axisPrev, axisNext
  local axisFooter = Theme.line(axisPage, axisFooterRow, width, "", Theme.dim)
  local axisHolding = Theme.line(axisPage, height - 1, width, "", Theme.fg)
  Theme.button(axisPage, 1, height, math.min(6, width), "BACK", function()
    actions.vectorHold("release", "", "x", 1)
    show(navPage)
  end)
  local axisRelease = Theme.button(axisPage, math.max(1, width - 8), height, 9, "RELEASE",
    function() actions.vectorHold("release", "", "x", 1) end)

  -- On the footer row, right-aligned, exactly as the terminal's monitor list does it. The footer
  -- text is built to what is left over rather than fitted afterwards.
  if width >= 12 then
    axisFooterWidth = width - 8
    axisPrev = Theme.button(axisPage, width - 7, axisFooterRow, 3, "^", function()
      axisPageIndex = axisPageIndex - 1
      refreshAxisRows()
    end)
    axisNext = Theme.button(axisPage, width - 3, axisFooterRow, 3, "v", function()
      axisPageIndex = axisPageIndex + 1
      refreshAxisRows()
    end)
  end

  --- Pages are built PER GROUP, not by slicing the flat list. Two reasons: the row labels are
  --- bare keys, which are only unique WITHIN a group -- the craft really does have a lift `fl`
  --- and a lateral `fl` -- and one group to a page matches the SELF TEST's three steps, so you
  --- inspect the same nozzles the sweep just moved. A group with more thrusters than there are
  --- rows spills onto a second page of its own.
  local function buildAxisPages(list)
    local order, byGroup = {}, {}
    for _, entry in ipairs(list) do
      if byGroup[entry.group] == nil then
        byGroup[entry.group] = {}
        order[#order + 1] = entry.group
      end
      local bucket = byGroup[entry.group]
      bucket[#bucket + 1] = entry
    end
    local out = {}
    for _, group in ipairs(order) do
      local entries = byGroup[group]
      for start = 1, #entries, axisRowCount do
        local page = { group = group, entries = {} }
        for i = start, math.min(start + axisRowCount - 1, #entries) do
          page.entries[#page.entries + 1] = entries[i]
        end
        out[#out + 1] = page
      end
    end
    return out
  end

  function refreshAxisRows()
    local list = live.thrusterAxes or {}
    local held = live.axisMap or {}
    local allPages = buildAxisPages(list)
    local pagesTotal = math.max(1, #allPages)
    axisPageIndex = math.max(1, math.min(axisPageIndex, pagesTotal))
    local current = allPages[axisPageIndex] or { group = nil, entries = {} }

    for i, row in ipairs(axisRows) do
      local entry = current.entries[i]
      row.entry = entry
      row.label:setVisible(entry ~= nil)
      if entry then
        -- THE KEY, NOT THE GROUP. "lift:fl" and "lift:fr" both truncated to "LIF" in the three
        -- columns a 15-wide monitor can spare, so the two rows were identical -- on the one
        -- screen whose whole job is telling you which nozzle you just moved. Keys are unique
        -- within a group, and the group is named in the footer.
        local label = tostring(entry.key):upper()
        if axisLabelWidth >= #label + 4 then
          label = (entry.group:sub(1, 3) .. ":" .. tostring(entry.key)):upper()
        end
        row.label:setText(Theme.fit(label, axisLabelWidth))
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

    -- The GROUP is named here, because the row labels are bare keys. Built to the room actually
    -- left beside the paging buttons: "5 thrusters  pg 1/2" fitted to 15 columns came out as
    -- "5 thrusters  pg", losing the page number -- half of what a paging footer is for.
    if #list == 0 then
      axisFooter:setText(Theme.fit("no thrusters assigned", axisFooterWidth))
      axisFooter:setForeground(Theme.warning)
    else
      local group = tostring(current.group or "?"):upper()
      local page = ("%d/%d"):format(axisPageIndex, pagesTotal)
      local long = ("%s  %d nozzles  pg %s"):format(group, #current.entries, page)
      local medium = ("%s  pg %s"):format(group, page)
      local text = long
      if #text > axisFooterWidth then text = medium end
      if #text > axisFooterWidth then text = ("%s %s"):format(group:sub(1, 3), page) end
      axisFooter:setText(Theme.fit(text, axisFooterWidth))
      axisFooter:setForeground(Theme.dim)
    end
    if axisPrev then axisPrev:setVisible(pagesTotal > 1) end
    if axisNext then axisNext:setVisible(pagesTotal > 1) end

    -- THE LIT PANEL: what is deflected, and what the system thinks that direction is.
    if held.holding then
      -- THE DIRECTION SURVIVES THE TRUNCATION. "lift:fl +x = left" is 17 characters, so on a
      -- 15-wide monitor it arrived as "lift:fl +x = le" -- the believed direction is the single
      -- thing this screen is for, and it was the part that got cut. The id is already obvious
      -- from the highlighted row, so it is what gets dropped when there is no room.
      local deflection = ("%s%s"):format(held.sign > 0 and "+" or "-",
        tostring(held.axis):upper())
      local direction = tostring(held.direction or "?"):upper()
      local long = ("%s %s = %s"):format(tostring(held.id), deflection, direction)
      axisHolding:setText(#long <= width and long
        or Theme.fit(("%s = %s"):format(deflection, direction), width))
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
      -- Head-fit with the craft's short form, never a tail cut: "nozzle mapping only runs on
      -- the ground, with the engine off" tail-fitted read "with the engine".
      local long = tostring(held.error)
      axisHolding:setText(Theme.fit(
        #long <= width and long or tostring(held.errorShort or long), width))
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
      -- NOTHING TO SWEEP is the most useful thing this screen can say, and it was buried in a
      -- "lif 0/4" findings line that only parsed if you already knew what it meant. A group whose
      -- thrusters are all thrust-only has no nozzle to move, so the countdown means nothing.
      if st.moving == 0 then
        selfStatus:setText(Theme.fit(("NO NOZZLE: %d THR"):format(st.groupCount or 0), width))
        selfStatus:setForeground(Theme.warning)
      else
        -- SAYS IT IS TESTING, and which of the three. The label alone ("LIFT THRUSTERS") names
        -- the group but never states that a test is under way, so a stopped screen and a running
        -- one read almost the same.
        local testing = ("TESTING %d/%d"):format(st.step or 1, st.steps or 3)
        local label = tostring(st.label or "")
        if #testing + 1 + #label <= width then testing = testing .. " " .. label end
        selfStatus:setText(Theme.fit(testing, width))
        selfStatus:setForeground(Theme.accent)
      end
      -- THE COUNTDOWN, for this step and for the whole run. Built to the width: the long form
      -- names the axis being swept, the short one keeps both numbers, because a countdown that
      -- has been truncated to one number cannot tell you whether the run is nearly over.
      local stepLeft = math.max(0, (st.stepRemainingMs or 0) / 1000)
      local allLeft = math.max(0, (st.remainingMs or 0) / 1000)
      local long = ("%s  %.0fs left  %.0fs total"):format(tostring(st.phase or ""), stepLeft,
        allLeft)
      local short = ("%s %.0fs all %.0fs"):format(tostring(st.phase or ""):sub(1, 1), stepLeft,
        allLeft)
      selfTimer:setText(Theme.fit(#long <= width and long or short, width))
      selfTimer:setForeground(Theme.accent)
      -- COMMANDED -> ACHIEVED, from the craft. If a nozzle is not moving, this is the line that
      -- says whose fault it is: no arrow at all means the write was refused, a commanded value
      -- with a flat readback means the block took it and did not move.
      if (st.writeFails or 0) > 0 then
        selfWatch:setText(Theme.fit(("WRITE FAILED x%d"):format(st.writeFails), width))
        selfWatch:setForeground(Theme.warning)
      elseif type(st.aimCommanded) == "number" then
        local shown = tostring(st.witness or "?"):gsub("^%a+[_:]", "")
        local actual = type(st.aimActual) == "number" and ("%+.2f"):format(st.aimActual) or "--"
        selfWatch:setText(Theme.fit(("%s %+.2f>%s"):format(shown, st.aimCommanded, actual), width))
        selfWatch:setForeground(type(st.aimActual) == "number"
          and math.abs((st.aimActual or 0) - st.aimCommanded) < 0.25 and Theme.ok or Theme.caution)
      else
        selfWatch:setText(Theme.fit("watch: " .. tostring(st.watch or ""), width))
        selfWatch:setForeground(Theme.dim)
      end
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
        -- Same rule as a refusal: the craft supplies the short wording. "aborted: lift_fl
        -- started producing thrust" head-fitted to 15 columns reads "aborted: lift_", which
        -- says a thing happened but not the one thing worth knowing -- that thrust appeared.
        local long = tostring(st.aborted)
        local text = long
        if #text > width then text = tostring(st.abortedShort or long) end
        selfStatus:setText(Theme.fit(text, width))
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
    --
    -- THE SHORT FORM COMES FROM THE CRAFT, and this used to be Theme.fitEnd. Tail-fitting
    -- "<id> is producing thrust (0.40) -- cut the engine first" to 15 columns produced
    -- "he engine first", which reads as "start the engine" -- the exact opposite of what the
    -- interlock wants, and it would talk a pilot into powering up for a test that must run cold.
    -- Truncation is never allowed to decide what a refusal means.
    local ack = opts.lastAck and opts.lastAck()
    if ack and ack.cmd == "selfTest" and ack.ack == false then
      local detail = ack.detail or {}
      local long = tostring(detail.error or "REFUSED")
      local text = long
      if #text > width then text = tostring(detail.errorShort or long) end
      selfStatus:setText(Theme.fit(text, width))
      selfStatus:setForeground(Theme.warning)
    end
  end

  return {
    update = update,
    show = show,
    buttons = testButtons,
    stacked = stacked,
    pages = { nav = navPage, fcs = fcsPage, selfTest = selfPage, axisMap = axisPage },
    axisRows = axisRows,
    bars = bars,
    elements = {
      placeholder = navPlaceholder, fcsStale = fcsStale, brake = brakeLine,
      mode = modeLine, source = sourceLine, warn = selfWarn,
      steps = stepLines, status = selfStatus, timer = selfTimer,
      watch = selfWatch, result = selfResult, start = startButton,
      axisHint = axisHint, axisFooter = axisFooter, axisHolding = axisHolding,
      axisRelease = axisRelease, axisPrev = axisPrev, axisNext = axisNext,
    },
  }
end

return Nav
