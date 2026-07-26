--[[ The beacon's own screen. Runs on the computer's terminal -- a beacon is a standalone box in
     the world, not part of the craft's monitor network.

     Four things, in the order they matter:

       1. THIS BEACON'S COORDINATES, editable. The one setting, and the one that can be wrong.
       2. THE SELF CHECK. Whether the constellation agrees about where we are. A typo here is
          the failure that never announces itself, so it gets the loudest line on the screen.
       3. LINK STATUS for the other beacons, with age. Below four, GPS returns nothing at all.
       4. THE QUALITY GRADE and what to move, in words rather than a number nobody can act on.
]]

local Theme = require("ui.theme")

local Panel = {}

--- opts = { cfg, save, host, mesh, log }
function Panel.build(frame, opts)
  local cfg = opts.cfg
  local width, height = frame:getWidth(), frame:getHeight()
  frame:setBackground(Theme.bg)

  local live = { assessment = nil, status = nil }
  local pages = {}
  local function page()
    local p = frame:addFrame({ x = 1, y = 1, width = width, height = height,
      background = Theme.bg })
    p:setVisible(false)
    pages[#pages + 1] = p
    return p
  end

  local home, editPage = page(), page()
  home:setVisible(true)
  local function show(target)
    for _, p in ipairs(pages) do p:setVisible(p == target) end
  end

  -- ---------------------------------------------------------------- home

  local title = Theme.line(home, 1, width, "", Theme.accent)
  local posLine = Theme.line(home, 2, width, "", Theme.fg)
  local checkLine = Theme.line(home, 3, width, "", Theme.dim)
  Theme.rule(home, 4, width)

  local peerRows = {}
  local peerStart = 5
  local peerCount = math.max(1, math.min(4, height - 9))
  for i = 1, peerCount do
    peerRows[i] = Theme.line(home, peerStart + i - 1, width, "", Theme.dim)
  end

  local qualityRow = peerStart + peerCount
  Theme.rule(home, qualityRow, width)
  local gradeLine = Theme.line(home, qualityRow + 1, width, "", Theme.fg)
  local problemLine = Theme.line(home, qualityRow + 2, width, "", Theme.warning)
  local servedLine = Theme.line(home, math.min(qualityRow + 3, height - 1), width, "", Theme.dim)

  Theme.button(home, 1, height, math.min(10, width), "SET POS", function() show(editPage) end)
  local enableButton = Theme.button(home, math.max(1, width - 10), height, 11, "",
    function()
      cfg.enabled = not cfg.enabled
      opts.save()
    end)

  -- ---------------------------------------------------------------- edit

  Theme.line(editPage, 1, width, Theme.centre("THIS BEACON", width), Theme.accent)
  Theme.line(editPage, 2, width, "where is this computer?", Theme.dim)

  local fields, fy = {}, 4
  for _, axis in ipairs({ "x", "y", "z" }) do
    Theme.line(editPage, fy, 3, axis:upper(), Theme.dim)
    local input = editPage:addInput({
      x = 5, y = fy, width = math.max(8, width - 8), height = 1,
      background = Theme.buttonBg, foreground = Theme.fg,
    })
    fields[axis] = input
    fy = fy + 1
  end

  local editError = Theme.line(editPage, fy + 1, width, "", Theme.warning)

  --- Load the current config into the fields, so opening the page shows what is set.
  local function fillFields()
    for _, axis in ipairs({ "x", "y", "z" }) do
      local v = cfg.position[axis]
      fields[axis]:setValue(v ~= nil and tostring(math.floor(v)) or "")
    end
    editError:setText("")
  end

  Theme.button(editPage, 1, height, math.min(8, width), "SAVE", function()
    local wanted = {}
    for _, axis in ipairs({ "x", "y", "z" }) do
      local text = tostring(fields[axis]:getValue() or ""):gsub("%s", "")
      local number = tonumber(text)
      if number == nil then
        -- All three or none: two axes typed is a typo mid-entry, not a position.
        editError:setText(Theme.fit(axis:upper() .. " is not a number", width))
        return
      end
      wanted[axis] = math.floor(number)
    end

    local previous = { x = cfg.position.x, y = cfg.position.y, z = cfg.position.z }
    cfg.position.x, cfg.position.y, cfg.position.z = wanted.x, wanted.y, wanted.z
    local Config = require("lib.config")
    local ok, errors = Config.validate(cfg)
    if not ok then
      cfg.position.x, cfg.position.y, cfg.position.z = previous.x, previous.y, previous.z
      editError:setText(Theme.fitEnd(tostring(errors[1]), width))
      return
    end
    opts.save()
    -- A coordinate change invalidates the previous verdict; do not leave a stale "ok" showing.
    if opts.host then opts.host.selfCheck = { state = "unchecked" } end
    show(home)
  end)

  Theme.button(editPage, math.max(1, width - 8), height, 9, "CANCEL", function()
    fillFields()
    show(home)
  end)

  fillFields()

  -- ---------------------------------------------------------------- update

  local function update(model)
    live.assessment = model.assessment
    live.status = model.status
    local status = model.status or {}
    local assessment = model.assessment or { problems = {} }

    title:setText(Theme.fit(("GPS %s"):format(tostring(cfg.label)), width))

    if status.position and type(status.position.x) == "number" then
      posLine:setText(Theme.fit(("at %d %d %d"):format(status.position.x, status.position.y,
        status.position.z), width))
      posLine:setForeground(Theme.fg)
    else
      posLine:setText(Theme.fit("NO POSITION SET -- not answering", width))
      posLine:setForeground(Theme.warning)
    end

    -- The self check gets the loudest treatment: a wrong coordinate here is the one failure
    -- that otherwise never announces itself.
    local check = status.selfCheck or { state = "unchecked" }
    if check.state == "ok" then
      checkLine:setText(Theme.fit(("self check ok (%.2f)"):format(check.error or 0), width))
      checkLine:setForeground(Theme.ok)
    elseif check.state == "MISMATCH" then
      checkLine:setText(Theme.fit(("MISMATCH %.1f BLOCKS OFF"):format(check.error or 0), width))
      checkLine:setForeground(Theme.warning)
    else
      checkLine:setText(Theme.fit("self check: " .. tostring(check.state), width))
      checkLine:setForeground(Theme.dim)
    end

    local hosts = assessment.hosts or {}
    for i, row in ipairs(peerRows) do
      local host = hosts[i]
      if host == nil then
        row:setText("")
      elseif host.self_ then
        row:setText(Theme.fit("* " .. tostring(host.label) .. " (this one)", width))
        row:setForeground(Theme.dim)
      else
        row:setText(Theme.fit(("+ %s %d %d %d"):format(tostring(host.label),
          host.x, host.y, host.z), width))
        row:setForeground(Theme.ok)
      end
    end

    local grade = assessment.grade or "UNUSABLE"
    gradeLine:setText(Theme.fit(("%d/4  %s"):format(assessment.hostCount or 0, grade), width))
    gradeLine:setForeground(assessment.usable and Theme.ok or Theme.warning)

    -- One problem at a time, and the FIRST one, because they are ordered by how much they
    -- matter and a wall of text on a 51-column terminal is read by nobody.
    problemLine:setText(Theme.fit(tostring((assessment.problems or {})[1] or ""), width))

    servedLine:setText(Theme.fit(("served %d  peers %d"):format(status.served or 0,
      math.max(0, (assessment.hostCount or 1) - 1)), width))

    enableButton:setText(cfg.enabled and "ON" or "OFF")
    enableButton:setBackground(cfg.enabled and Theme.ok or Theme.warning)
    enableButton:setForeground(colours.black)
  end

  return {
    update = update,
    show = show,
    pages = { home = home, edit = editPage },
    fields = fields,
    elements = {
      title = title, position = posLine, check = checkLine, peers = peerRows,
      grade = gradeLine, problem = problemLine, served = servedLine,
      enable = enableButton, editError = editError,
    },
  }
end

return Panel
