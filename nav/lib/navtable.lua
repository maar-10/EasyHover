--[[ The navigation table peripheral -- Create: Simulated's `navigation_table`.

     ONE method matters: `getRelativeAngle() -> float|nil`, the craft's angle to whatever the
     table is aimed at. Aim it at true north (a magnet in the table) and it is an absolute heading.
     It is a boxed Float, so nil is a normal answer -- no target in range, or the table is not yet
     configured -- and it is free to call (not mainThread), so polling costs nothing.

     This module only FINDS and READS. What the number means -- sign, north reference, how it is
     fused with the gimbal -- is the Heading module's job. Keeping the two apart means the finding
     can be tested with a plain function and the fusing without a peripheral.
]]

local NavTable = {}

local TYPE = "navigation_table"

--- Is this peripheral a navigation table? Uses hasType where available, falls back to getType.
local function isNavTable(name)
  local ok, result = pcall(function()
    if peripheral.hasType then return peripheral.hasType(name, TYPE) end
    return peripheral.getType(name) == TYPE
  end)
  return ok and result and true or false
end

--- Every navigation table on the network, by peripheral name. For the config picker.
function NavTable.list(names)
  names = names or (peripheral and peripheral.getNames and peripheral.getNames()) or {}
  local out = {}
  for _, name in ipairs(names) do
    if isNavTable(name) then out[#out + 1] = name end
  end
  table.sort(out)
  return out
end

--- Resolve the configured table to a wrapped peripheral, or nil with a reason.
---
--- A blank name AUTO-PICKS the first table found, and says which -- the same modularity the rest
--- of the config uses. A named table that is absent is an ERROR the operator can see, not a
--- silent fall-through to some other table they did not choose.
function NavTable.resolve(wanted, names)
  local tables = NavTable.list(names)
  if #tables == 0 then return nil, "no navigation table on the network" end

  if wanted == nil or wanted == "" then
    return peripheral.wrap(tables[1]), nil, tables[1]
  end

  for _, name in ipairs(tables) do
    if name == wanted then return peripheral.wrap(name), nil, name end
  end
  return nil, ("navigation table '%s' is not on the network"):format(tostring(wanted))
end

--- A reader function for the Heading module: () -> raw getRelativeAngle() or nil. Re-resolves
--- lazily, so a table plugged in after boot starts working without a restart, and one unplugged
--- stops rather than erroring. `dev` is injectable for tests.
function NavTable.reader(wanted, opts)
  opts = opts or {}
  local dev = opts.dev
  return function()
    if dev == nil then
      dev = select(1, NavTable.resolve(wanted, opts.names))
      if dev == nil then return nil end
    end
    if type(dev.getRelativeAngle) ~= "function" then return nil end
    local ok, angle = pcall(dev.getRelativeAngle)
    if not ok then
      dev = nil          -- likely unplugged; re-resolve next call
      return nil
    end
    if type(angle) ~= "number" then return nil end
    return angle
  end
end

return NavTable
