--[[ Floppy-disk config transfer: save and load EVERY EasyHover config.

     Same purpose as DriveByWire's disk support, and the same reason: a config you can carry is
     a config you can restore after a rebuild, copy to a second craft, or hand to the nav
     computer without retyping it.

     "All configs" means every `/eh_*.tbl` on this computer -- not just this role's. A disk
     written on the flight computer can therefore be read by the nav computer later, and each
     machine picks up the files that belong to it.

     Three rules:
       * WRITE THEN VERIFY. Every file written to the disk is read back and compared before it
         is called saved. A floppy that silently holds half a config is worse than none.
       * NEVER INSTALL A BROKEN CONFIG. A file that will not parse is refused on load, with its
         name reported. The live config is left alone.
       * BACK UP BEFORE OVERWRITING. Loading backs up whatever is already there, into the same
         /easyhover_backup tree the Suite uses.
]]

local Disk = {}
Disk.__index = Disk

local CONFIG_PATTERN = "^eh_.*%.tbl$"
local DISK_DIR = "easyhover"
local INDEX_FILE = "index.txt"
local BACKUP_ROOT = "/easyhover_backup"

function Disk.new(peripherals, cfg, log, state)
  local self = setmetatable({}, Disk)
  self.per = peripherals
  self.cfg = cfg
  self.log = log
  self.state = state
  return self
end

-- ---------------------------------------------------------------- helpers

local function readFile(path)
  if not fs.exists(path) or fs.isDir(path) then return nil end
  local f = fs.open(path, "r")
  if not f then return nil end
  local s = f.readAll()
  f.close()
  return s or ""
end

local function writeFile(path, content)
  local dir = fs.getDir(path)
  if dir ~= "" and dir ~= "/" and not fs.exists(dir) then fs.makeDir(dir) end
  local f = fs.open(path, "w")
  if not f then return false end
  f.write(content)
  f.close()
  return true
end

local function call(dev, method, ...)
  local fn = dev[method]
  if type(fn) ~= "function" then return nil end
  local ok, v = pcall(fn, ...)
  if ok then return v end
  return nil
end

local function timestamp()
  local ok, stamp = pcall(os.date, "%Y-%m-%d_%H-%M-%S")
  if ok and type(stamp) == "string" then return stamp end
  return tostring(os.epoch("utc"))
end

--- Config files on this computer, sorted.
function Disk.localConfigs()
  local out = {}
  for _, name in ipairs(fs.list("/")) do
    if not fs.isDir("/" .. name) and name:match(CONFIG_PATTERN) then out[#out + 1] = name end
  end
  table.sort(out)
  return out
end

-- ---------------------------------------------------------------- drives

--- Every drive on the network, with what is in it. Never throws: a drive that vanished
--- mid-scan simply reports as absent.
function Disk:drives()
  local out = {}
  for _, item in ipairs(self.per.drives or {}) do
    local present = call(item.dev, "isDiskPresent")
    local row = {
      name = item.name,
      dev = item.dev,
      present = present and true or false,
      hasData = call(item.dev, "hasData") and true or false,
      label = call(item.dev, "getDiskLabel"),
      mount = call(item.dev, "getMountPath"),
    }
    if row.mount then
      row.configs = Disk.diskConfigs(row.mount)
      row.count = #row.configs
    else
      row.configs, row.count = {}, 0
    end
    out[#out + 1] = row
  end
  return out
end

--- The first drive with a usable, writable disk in it.
function Disk:firstReady()
  for _, row in ipairs(self:drives()) do
    if row.present and row.mount then return row end
  end
  return nil
end

--- Config files stored on a mounted disk.
function Disk.diskConfigs(mount)
  local dir = fs.combine(mount, DISK_DIR)
  local out = {}
  if not fs.exists(dir) or not fs.isDir(dir) then return out end
  for _, name in ipairs(fs.list(dir)) do
    local path = fs.combine(dir, name)
    if not fs.isDir(path) and name:match(CONFIG_PATTERN) then out[#out + 1] = name end
  end
  table.sort(out)
  return out
end

-- ---------------------------------------------------------------- save

--- Copy every local config onto the disk, verifying each readback.
-- Returns ok, report.
function Disk:saveAll(drive)
  drive = drive or self:firstReady()
  if not drive then return false, { ok = false, reason = "no disk in any drive" } end
  if not drive.mount then return false, { ok = false, reason = "disk is not mounted" } end

  local configs = Disk.localConfigs()
  local report = { ok = true, saved = {}, failed = {}, mount = drive.mount, drive = drive.name }
  if #configs == 0 then
    report.ok = false
    report.reason = "this computer has no config files yet"
    return false, report
  end

  local dir = fs.combine(drive.mount, DISK_DIR)
  if not fs.exists(dir) then fs.makeDir(dir) end

  for _, name in ipairs(configs) do
    local body = readFile("/" .. name)
    if body == nil then
      report.failed[#report.failed + 1] = { name = name, reason = "could not read" }
      report.ok = false
    else
      local target = fs.combine(dir, name)
      if not writeFile(target, body) then
        report.failed[#report.failed + 1] = { name = name, reason = "could not write (disk full?)" }
        report.ok = false
      else
        -- verify readback: a floppy holding half a config is worse than none
        local back = readFile(target)
        if back ~= body then
          report.failed[#report.failed + 1] = { name = name, reason = "verify readback mismatch" }
          report.ok = false
        else
          report.saved[#report.saved + 1] = name
        end
      end
    end
  end

  local index = {
    ("written=%s"):format(timestamp()),
    ("computer=%s"):format(tostring(os.getComputerID())),
    ("label=%s"):format(tostring(os.getComputerLabel() or "(none)")),
    ("files=%d"):format(#report.saved),
  }
  for _, name in ipairs(report.saved) do index[#index + 1] = "  " .. name end
  writeFile(fs.combine(dir, INDEX_FILE), table.concat(index, "\n") .. "\n")

  self.log:info("disk save: %d saved, %d failed (%s)", #report.saved, #report.failed, drive.name)
  return report.ok, report
end

-- ---------------------------------------------------------------- load

--- Copy configs from the disk onto this computer.
---
--- Every candidate is PARSED FIRST. A file that will not parse is refused and named, and the
--- live config it would have replaced is left exactly as it is. Whatever is overwritten is
--- backed up first.
--- `opts.only` restricts to a single filename.
function Disk:loadAll(drive, opts)
  opts = opts or {}
  drive = drive or self:firstReady()
  if not drive then return false, { ok = false, reason = "no disk in any drive" } end
  if not drive.mount then return false, { ok = false, reason = "disk is not mounted" } end

  local dir = fs.combine(drive.mount, DISK_DIR)
  local available = Disk.diskConfigs(drive.mount)
  local report = {
    ok = true, loaded = {}, refused = {}, backedUp = {},
    mount = drive.mount, drive = drive.name,
  }
  if #available == 0 then
    report.ok = false
    report.reason = "no EasyHover configs on this disk"
    return false, report
  end

  local backupDir = ("%s/%s_disk"):format(BACKUP_ROOT, timestamp())

  for _, name in ipairs(available) do
    if not opts.only or opts.only == name then
      local body = readFile(fs.combine(dir, name))
      if body == nil then
        report.refused[#report.refused + 1] = { name = name, reason = "could not read from disk" }
        report.ok = false
      else
        local parsed = textutils.unserialise(body)
        if type(parsed) ~= "table" then
          -- refuse rather than install: an unparseable config would leave the program running
          -- on defaults with no clue why
          report.refused[#report.refused + 1] = { name = name, reason = "does not parse" }
          report.ok = false
        else
          local live = "/" .. name
          if fs.exists(live) then
            local existing = readFile(live)
            if existing then
              if not fs.exists(backupDir) then fs.makeDir(backupDir) end
              writeFile(("%s/%s"):format(backupDir, name), existing)
              report.backedUp[#report.backedUp + 1] = name
            end
          end
          if writeFile(live, body) then
            report.loaded[#report.loaded + 1] = name
          else
            report.refused[#report.refused + 1] = { name = name, reason = "could not write locally" }
            report.ok = false
          end
        end
      end
    end
  end

  if #report.backedUp > 0 then report.backupDir = backupDir end
  self.log:info("disk load: %d loaded, %d refused, %d backed up (%s)",
    #report.loaded, #report.refused, #report.backedUp, drive.name)
  return report.ok, report
end

function Disk:eject(drive)
  drive = drive or self:firstReady()
  if not drive then return false, "no disk in any drive" end
  local fn = drive.dev.ejectDisk
  if type(fn) ~= "function" then return false, "drive cannot eject" end
  local ok = pcall(fn)
  return ok
end

--- Summary for the UI and for telemetry.
function Disk:status()
  local drives = self:drives()
  local ready = nil
  for _, row in ipairs(drives) do
    if row.present and row.mount then ready = row break end
  end
  local status = {
    driveCount = #drives,
    diskPresent = ready ~= nil,
    label = ready and ready.label or nil,
    onDisk = ready and ready.count or 0,
    localConfigs = #Disk.localConfigs(),
    drive = ready and ready.name or nil,
  }
  if self.state then self.state:setGroup("disk", status) end
  return status
end

return Disk
