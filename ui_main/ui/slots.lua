--[[ The slot picker: "which peripheral fills this named role".

     One widget behind every hardware page -- the four lift thrusters, the four accelerators,
     the four lateral thrusters, the velocity axes, the altimeter and gimbal, and the laser
     rays. They differ only in their slot list and which candidate list they draw from, so they
     share an implementation rather than having eight that can drift apart.

     TWO PAGES, because a 15-column monitor cannot show slots and candidates side by side:

       SLOTS       every slot with what currently fills it -- tap one to change it
       CANDIDATES  everything the craft can see for that slot -- tap one to assign it

     NO OPTIMISTIC FEEDBACK. A tap sends a command and nothing else; the assignment on screen
     is whatever the craft last reported. Until it confirms, the footer says "sent, waiting" --
     which is a fact about this computer, not a claim about the craft. See docs/UI.md.
]]

local Theme = require("ui.theme")

local Slots = {}

--- opts:
---   title      string shown at the top
---   slots      { { key = "fl", label = "FL", kind = "lift" }, ... }
---   candidates function(slot) -> { peripheral names }   -- per slot, so one page can mix
---                                                          families (relay AND vault)
---   assigned   function(slot) -> peripheral name or ""
---   set        function(slot, peripheral)   -- "" unassigns
---   refusedCmd string   the command name whose refusal belongs to this page
---   lastAck    function() -> ack table or nil
function Slots.build(parent, x, y, width, height, opts)
  local slots = opts.slots
  local page, chosen, pageIndex = "slots", nil, 1
  local pending = nil            -- { key, name } asked for but not yet confirmed
  local refused = false
  local refresh

  local row = y
  local title = Theme.line(parent, row, width, "", Theme.accent); row = row + 1
  local subtitle = Theme.line(parent, row, width, "", Theme.dim); row = row + 1
  Theme.rule(parent, row, width); row = row + 1

  local listStart = row
  local footerRow = y + height - 1
  local perPage = math.max(1, footerRow - listStart)

  --- Rows are reused by BOTH pages: same buttons, different meaning depending on `page`.
  --- Registered once -- Basalt appends callbacks rather than replacing them.
  local rows = {}
  for i = 1, perPage do
    local entry = { slot = nil, name = nil }
    entry.button = Theme.button(parent, x, listStart + i - 1, width, "", function()
      if page == "slots" then
        if entry.slot == nil then return end
        chosen, page, pageIndex = entry.slot, "candidates", 1
      else
        if entry.name == nil then return end
        opts.set(chosen, entry.name)
        pending = { slot = chosen, name = entry.name }
        refused = false
        page, pageIndex = "slots", 1
      end
      refresh()
    end)
    rows[i] = entry
  end

  local footer = Theme.line(parent, footerRow, width, "", Theme.dim)
  local prevButton = Theme.button(parent, x + width - 7, footerRow, 3, "^", function()
    pageIndex = pageIndex - 1; refresh()
  end)
  local nextButton = Theme.button(parent, x + width - 3, footerRow, 3, "v", function()
    pageIndex = pageIndex + 1; refresh()
  end)

  --- The label for a slot row: "front left  thruster_2", with the peripheral's TAIL kept
  --- because that is the part that distinguishes one from the next.
  --- PADDED TO THE FULL WIDTH, always. A Basalt button centres text that is shorter than it,
  --- so an unfilled row would sit centred while a filled one spans the width -- and a ragged
  --- column reads as a rendering fault rather than as "this one is empty".
  local function slotRowText(slot)
    local name = opts.assigned(slot) or ""
    local label = slot.label
    local text
    if name == "" then
      text = label .. " --"
    else
      local room = width - #label - 1
      text = room < 4 and Theme.fitEnd(name, width) or (label .. " " .. Theme.fitEnd(name, room))
    end
    return Theme.fit(text .. (" "):rep(math.max(0, width - #text)), width)
  end

  function refresh()
    local entries, pages

    if page == "slots" then
      title:setText(Theme.fit(opts.title, width))
      local filled = 0
      for _, slot in ipairs(slots) do
        if (opts.assigned(slot) or "") ~= "" then filled = filled + 1 end
      end
      subtitle:setText(Theme.fit(("%d of %d set"):format(filled, #slots), width))
      subtitle:setForeground(filled == #slots and Theme.ok or Theme.dim)
      entries = slots
    else
      title:setText(Theme.fit(chosen.title or chosen.label, width))
      subtitle:setText(Theme.fit(chosen.hint or "pick one", width))
      subtitle:setForeground(Theme.dim)
      -- "(none)" first, so an assignment is always undoable
      entries = { "" }
      for _, name in ipairs(opts.candidates(chosen) or {}) do entries[#entries + 1] = name end
    end

    pages = math.max(1, math.ceil(#entries / perPage))
    pageIndex = math.max(1, math.min(pageIndex, pages))

    for i, entry in ipairs(rows) do
      local item = entries[(pageIndex - 1) * perPage + i]
      if item == nil then
        entry.slot, entry.name = nil, nil
        entry.button:setVisible(false)
      else
        entry.button:setVisible(true)
        if page == "slots" then
          entry.slot, entry.name = item, nil
          entry.button:setText(slotRowText(item))
          local set = (opts.assigned(item) or "") ~= ""
          entry.button:setBackground(set and Theme.ok or Theme.buttonBg)
          entry.button:setForeground(set and colours.black or Theme.buttonFg)
        else
          entry.slot, entry.name = nil, item
          local isCurrent = (item == (opts.assigned(chosen) or ""))
          entry.button:setText(Theme.fitEnd(item == "" and "(none)" or item, width))
          entry.button:setBackground(isCurrent and Theme.ok or Theme.buttonBg)
          entry.button:setForeground(isCurrent and colours.black or Theme.buttonFg)
        end
      end
    end

    local text, colour
    if refused then
      text, colour = "CRAFT REFUSED", Theme.warning
    elseif pending then
      text, colour = "sent, waiting", Theme.caution
    elseif page == "candidates" and #entries <= 1 then
      text, colour = "none on network", Theme.warning
    elseif pages > 1 then
      text, colour = ("pg %d/%d"):format(pageIndex, pages), Theme.dim
    else
      text, colour = page == "slots" and "tap to change" or "tap to assign", Theme.dim
    end
    footer:setText(Theme.fit(text, pages > 1 and math.max(1, width - 8) or width))
    footer:setForeground(colour)
    prevButton:setVisible(pages > 1)
    nextButton:setVisible(pages > 1)
  end

  refresh()

  local function update()
    local ack = opts.lastAck and opts.lastAck()
    if ack and ack.cmd == opts.refusedCmd then
      if ack.ack == false then refused = true; pending = nil end
    end
    -- Waiting clears when the CRAFT reports the value, never on our own say-so.
    if pending and (opts.assigned(pending.slot) or "") == pending.name then
      pending = nil
      refused = false
    end
    refresh()
  end

  return {
    update = update,
    refresh = refresh,
    --- Test seams.
    page = function() return page end,
    showSlots = function() page, pageIndex, chosen = "slots", 1, nil; refresh() end,
    rows = rows,
    elements = { title = title, subtitle = subtitle, footer = footer,
                 prev = prevButton, next = nextButton },
  }
end

--- Minimum rows: title, subtitle, rule, one list row, footer.
function Slots.rows()
  return 5
end

return Slots
