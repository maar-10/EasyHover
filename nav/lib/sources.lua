--[[ Position sources, wired into the Fix provider.

     Each one is a small adaptor: it knows how to ask one thing where we are and returns x, y, z
     or nil. Fix owns priority, staleness, backoff and quality; none of that belongs here.

     THE GPS ONE IS THE INTERESTING CASE. `gps.locate()` BLOCKS -- it transmits a ping and waits
     up to `timeout` seconds for four hosts to answer. That is wall-clock time on this computer,
     not a server tick, which is exactly why the nav role gets a computer of its own: the same
     call inside the flight loop would wreck the dt discipline the whole control design rests on,
     and inside a Basalt UI it would stall a redraw mid-frame.

     It also needs a WIRELESS modem. An ender modem qualifies and has unlimited range within a
     dimension; a reply from another dimension arrives with no distance and locate() discards it,
     so the beacons must be in the same world as the craft.
]]

local Sources = {}

--- CC's GPS. `locate` is injected so this is testable without a modem or a constellation.
---
--- `y` from GPS is a block coordinate and coarser than the craft's own altimeter, so the caller
--- is expected to prefer the altimeter for altitude -- Fix:position takes it as an argument.
function Sources.gps(opts)
  opts = opts or {}
  local locate = opts.locate or (gps and gps.locate)
  return {
    name = "gps",
    priority = opts.priority or 10,
    quality = opts.quality or 1.0,
    costMs = opts.costMs or 2000,
    backoffMs = opts.backoffMs or 5000,
    locate = function()
      if type(locate) ~= "function" then return nil end
      local ok, x, y, z = pcall(locate, opts.timeout or 2)
      if not ok then return nil end
      return x, y, z
    end,
  }
end

--- Create: Radar, if one is mounted. getPosition() is mainThread -- one server tick per call --
--- so it is a backup rather than something to poll hard.
function Sources.radar(opts)
  opts = opts or {}
  local find = opts.find or function()
    for _, name in ipairs(peripheral.getNames()) do
      local ok, isRadar = pcall(function()
        if peripheral.hasType then
          return peripheral.hasType(name, "radar") or peripheral.hasType(name, "plane_radar")
        end
        local t = peripheral.getType(name)
        return t == "radar" or t == "plane_radar"
      end)
      if ok and isRadar then return peripheral.wrap(name) end
    end
    return nil
  end

  return {
    name = "radar",
    priority = opts.priority or 20,
    quality = opts.quality or 1.0,
    costMs = opts.costMs or 50,
    backoffMs = opts.backoffMs or 5000,
    locate = function()
      local dev = find()
      if dev == nil or type(dev.getPosition) ~= "function" then return nil end
      local ok, position = pcall(dev.getPosition)
      if not ok or type(position) ~= "table" then return nil end
      -- Radar may answer as a list or as a keyed table; accept either rather than guessing.
      local x = position.x or position[1]
      local y = position.y or position[2]
      local z = position.z or position[3]
      if type(x) ~= "number" then return nil end
      return x, y, z
    end,
  }
end

--- Build the sources this craft is configured for, in the order the config lists them.
---
--- Unknown names are reported rather than skipped silently: a typo in `positionSources` would
--- otherwise leave navigation with no sources and no explanation.
function Sources.build(cfg, log, injected)
  injected = injected or {}
  local built, problems = {}, {}
  for index, name in ipairs(cfg.positionSources or {}) do
    local factory = Sources[name]
    if type(factory) ~= "function" then
      problems[#problems + 1] = ("unknown position source '%s'"):format(tostring(name))
    else
      local spec = factory({
        priority = index * 10,
        locate = injected[name],
        timeout = cfg.gpsTimeout,
      })
      built[#built + 1] = spec
    end
  end
  if #built == 0 then
    problems[#problems + 1] = "no position source is configured -- navigation cannot fix"
  end
  for _, problem in ipairs(problems) do
    if log then log:error("%s", problem) end
  end
  return built, problems
end

return Sources
