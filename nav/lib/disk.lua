--[[ Floppy support for the nav computer: carry a waypoint set between craft, or keep a backup.

     A drive on the wired network is reachable by name, so this works whether the drive is bolted
     to the nav computer or sitting on the cable somewhere. It copies whole FILES rather than
     re-serialising, so whatever the waypoint format grows into, the disk keeps a faithful copy
     and nothing here has to know the shape.

     SAVE and LOAD are deliberately explicit, never automatic. A disk inserted by mistake must not
     silently overwrite a waypoint set, and a save must not fire on eject. The operator presses the
     key; this module does exactly that and reports what it did.
]]

local Disk = {}

--- The nav files this module moves. Routes are listed too, so once routes exist they ride along
--- with no change here; a file that does not exist is simply skipped.
---   { key = "waypoints", src = cfg.waypointsPath }
function Disk.fileset(cfg)
  local out = {}
  if cfg.waypointsPath and cfg.waypointsPath ~= "" then
    out[#out + 1] = { key = "waypoints", src = cfg.waypointsPath }
  end
  if cfg.routesPath and cfg.routesPath ~= "" then
    out[#out + 1] = { key = "routes", src = cfg.routesPath }
  end
  return out
end

--- The basename of a path: "/eh_waypoints.tbl" -> "eh_waypoints.tbl". So the disk copy keeps a
--- recognisable name rather than a mount-relative path.
local function basename(path)
  return tostring(path):gsub(".*/", "")
end

Disk.basename = basename

--- Every drive on the network, with whether a disk is in it and its mount path. `list`/`isDrive`/
--- `wrap` are injectable so the whole thing is testable without a drive.
function Disk.drives(opts)
  opts = opts or {}
  local names = opts.names or (peripheral and peripheral.getNames and peripheral.getNames()) or {}
  local isDrive = opts.isDrive or function(name)
    local ok, r = pcall(function()
      if peripheral.hasType then return peripheral.hasType(name, "drive") end
      return peripheral.getType(name) == "drive"
    end)
    return ok and r and true or false
  end
  local wrap = opts.wrap or peripheral.wrap

  local out = {}
  for _, name in ipairs(names) do
    if isDrive(name) then
      local dev = wrap(name)
      local present, mount, label = false, nil, nil
      if dev then
        local okP, p = pcall(dev.isDiskPresent); present = okP and p and true or false
        if present then
          local okM, m = pcall(dev.getMountPath); mount = okM and m or nil
          local okL, l = pcall(dev.getDiskLabel); label = okL and l or nil
        end
      end
      out[#out + 1] = { name = name, dev = dev, present = present, mount = mount, label = label }
    end
  end
  table.sort(out, function(a, b) return a.name < b.name end)
  return out
end

--- The first drive with a disk in it, or nil with a reason -- the common case where there is one.
function Disk.firstReady(opts)
  local drives = Disk.drives(opts)
  if #drives == 0 then return nil, "no drive on the network" end
  for _, d in ipairs(drives) do
    if d.present and d.mount then return d end
  end
  return nil, "a drive is present but has no disk"
end

--- Copy the fileset onto a mounted disk. Returns ok, {saved=names}, err.
--- Overwrites its own copies on the disk (fs.copy refuses an existing path, so the old copy is
--- removed first) -- the disk mirrors the computer, which is what "save" means.
function Disk.save(mount, cfg, fsapi)
  fsapi = fsapi or fs
  if type(mount) ~= "string" or mount == "" then return false, {}, "no disk mounted" end
  local saved = {}
  for _, f in ipairs(Disk.fileset(cfg)) do
    if fsapi.exists(f.src) then
      local dst = mount .. "/" .. basename(f.src)
      if fsapi.exists(dst) then fsapi.delete(dst) end
      local ok = pcall(fsapi.copy, f.src, dst)
      if ok then saved[#saved + 1] = f.key end
    end
  end
  if #saved == 0 then return false, saved, "nothing to save yet (no waypoints on this computer)" end
  return true, saved, nil
end

--- Copy the fileset FROM a mounted disk onto the computer, replacing the local files. Returns ok,
--- {loaded=keys}, err. The caller reloads the waypoint store afterwards -- this only moves files.
function Disk.load(mount, cfg, fsapi)
  fsapi = fsapi or fs
  if type(mount) ~= "string" or mount == "" then return false, {}, "no disk mounted" end
  local loaded = {}
  for _, f in ipairs(Disk.fileset(cfg)) do
    local src = mount .. "/" .. basename(f.src)
    if fsapi.exists(src) then
      if fsapi.exists(f.src) then fsapi.delete(f.src) end
      local ok = pcall(fsapi.copy, src, f.src)
      if ok then loaded[#loaded + 1] = f.key end
    end
  end
  if #loaded == 0 then return false, loaded, "this disk has no EasyHover waypoints on it" end
  return true, loaded, nil
end

return Disk
