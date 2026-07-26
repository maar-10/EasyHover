--[[ EasyHover config disk menu.

     Run it from the shell on any EasyHover computer:  diskmenu

     Saves and loads EVERY /eh_*.tbl on this computer to and from a floppy in any networked
     drive. That means a disk written here can be read by the nav or UI computers later, and
     each one picks up the configs that belong to it.

     ASCII only (32-126). CraftOS-PC ships a full CP437 font and real CC:Tweaked does not, so
     anything prettier would look right in the test harness and wrong in game.

     This is the terminal version. The same lib/io/disk.lua backs the Disk tab in the Basalt
     configuration UI when that ships, so behaviour cannot drift between the two.
]]

package.path = "/flight/?.lua;/flight/?/init.lua;/?.lua;/?/init.lua;" .. package.path

local Config = require("lib.config")
local Log = require("lib.log")
local State = require("lib.state")
local Peripherals = require("lib.peripherals")
local Disk = require("lib.io.disk")

local CONFIG_PATH = "/eh_flight_config.tbl"

local cfg = Config.load(CONFIG_PATH)
local log = Log.new({ level = "info", capacity = 60 })
local state = State.new({})
local per = Peripherals.new(cfg, log):scan()
local disk = Disk.new(per, cfg, log, state)

local function colour(c)
  if term.isColour and term.isColour() then term.setTextColour(c) end
end

local message, messageColour = nil, colours.white

local function draw()
  term.clear()
  term.setCursorPos(1, 1)
  colour(colours.cyan)
  print("EasyHover -- Config Disk")
  colour(colours.lightGrey)
  print(("-"):rep(38))

  local drives = disk:drives()
  local ready = nil
  for _, row in ipairs(drives) do
    if row.present and row.mount then
      ready = ready or row
    end
  end

  colour(colours.white)
  if #drives == 0 then
    colour(colours.red)
    print("No disk drive found on the network.")
    colour(colours.lightGrey)
    print("Attach a drive with a wired modem, or place")
    print("one beside this computer.")
  else
    for _, row in ipairs(drives) do
      local status
      if not row.present then
        status = "empty"
      elseif not row.mount then
        status = "unreadable disk"
      else
        status = ("%d config(s)"):format(row.count)
        if row.label and row.label ~= "" then status = status .. "  \"" .. row.label .. "\"" end
      end
      colour(row.present and colours.white or colours.lightGrey)
      print(("%-14s %s"):format(row.name, status))
    end
  end

  local localConfigs = Disk.localConfigs()
  print("")
  colour(colours.white)
  print(("On this computer: %d config(s)"):format(#localConfigs))
  colour(colours.lightGrey)
  for _, name in ipairs(localConfigs) do print("  " .. name) end
  if #localConfigs == 0 then print("  (none yet -- they appear on first run)") end

  if ready and ready.count > 0 then
    print("")
    colour(colours.white)
    print("On the disk:")
    colour(colours.lightGrey)
    for _, name in ipairs(ready.configs) do print("  " .. name) end
  end

  print("")
  colour(colours.white)
  print("[S] Save all to disk    [L] Load all from disk")
  print("[E] Eject               [R] Refresh")
  print("[Q] Quit")

  if message then
    print("")
    colour(messageColour)
    print(message)
  end
  colour(colours.white)
end

local function setMessage(text, c)
  message, messageColour = text, c or colours.white
end

local function describe(report)
  local parts = {}
  if report.saved and #report.saved > 0 then
    parts[#parts + 1] = ("%d saved"):format(#report.saved)
  end
  if report.loaded and #report.loaded > 0 then
    parts[#parts + 1] = ("%d loaded"):format(#report.loaded)
  end
  if report.backedUp and #report.backedUp > 0 then
    parts[#parts + 1] = ("%d backed up"):format(#report.backedUp)
  end
  if report.failed and #report.failed > 0 then
    parts[#parts + 1] = ("%d FAILED"):format(#report.failed)
  end
  if report.refused and #report.refused > 0 then
    parts[#parts + 1] = ("%d REFUSED"):format(#report.refused)
  end
  if #parts == 0 then return report.reason or "nothing to do" end
  local text = table.concat(parts, ", ")
  if report.reason then text = text .. " (" .. report.reason .. ")" end
  for _, item in ipairs(report.failed or {}) do
    text = text .. "\n  " .. item.name .. ": " .. item.reason
  end
  for _, item in ipairs(report.refused or {}) do
    text = text .. "\n  " .. item.name .. ": " .. item.reason
  end
  if report.backupDir then text = text .. "\n  backups in " .. report.backupDir end
  return text
end

draw()
while true do
  local event, key = os.pullEvent()

  if event == "char" then
    local c = key:lower()
    if c == "q" then
      term.clear()
      term.setCursorPos(1, 1)
      colour(colours.white)
      return
    elseif c == "s" then
      local ok, report = disk:saveAll()
      setMessage(describe(report), ok and colours.lime or colours.red)
      draw()
    elseif c == "l" then
      local ok, report = disk:loadAll()
      local text = describe(report)
      if ok then text = text .. "\nReboot affected computers to apply." end
      setMessage(text, ok and colours.lime or colours.red)
      draw()
    elseif c == "e" then
      local ok, err = disk:eject()
      setMessage(ok and "Ejected." or ("Could not eject: " .. tostring(err)),
        ok and colours.lime or colours.red)
      draw()
    elseif c == "r" then
      per:scan()
      setMessage(nil)
      draw()
    end

  elseif event == "disk" or event == "disk_eject" then
    per:scan()
    setMessage(event == "disk" and "Disk inserted." or "Disk removed.", colours.yellow)
    draw()

  elseif event == "peripheral" or event == "peripheral_detach" then
    per:scan()
    draw()

  elseif event == "term_resize" then
    draw()
  end
end
