--[[ Monitor assignment and mirroring.

     WHY IT WORKS THIS WAY, from Basalt 2.0's source:

       * `basalt.createFrame()` then `frame:setTerm(monitor)` is all that is needed. The term
         property setter registers the frame in Basalt's activeFrames, records
         `peripheral.getName(monitor)`, builds the render target, and sizes the frame from
         `monitor.getSize()`.
       * `renderFrames()` iterates EVERY active frame, so several monitors render natively.
       * `monitor_touch` is dispatched to every frame and each one filters on its own
         `_peripheralName`, so touch routing per monitor is built in.

     Which is why MIRRORING is one frame per monitor rather than one frame fanned out to a
     proxy terminal. A proxy would have no peripheral name, so Basalt could not route touches
     to it -- the buttons would render on both screens and respond on neither. Two frames built
     from the same model cost a little more render time and keep every framework guarantee.

     Text scale is set BEFORE setTerm, because the frame takes its size from the monitor at
     that moment.
]]

local Monitors = {}
Monitors.__index = Monitors

function Monitors.new(cfg, log, basalt)
  local self = setmetatable({}, Monitors)
  self.cfg = cfg
  self.log = log
  self.basalt = basalt
  self.frames = {}     -- panelName -> { { name, monitor, frame, instance } }
  self.missing = {}
  return self
end

--- Every monitor on the network, sorted, with its size and current assignment.
function Monitors:available()
  local out = {}
  local ok, names = pcall(peripheral.getNames)
  if not ok then return out end
  table.sort(names)
  for _, name in ipairs(names) do
    local isMonitor = false
    if peripheral.hasType then
      local okType, result = pcall(peripheral.hasType, name, "monitor")
      isMonitor = okType and result and true or false
    else
      local okType, ptype = pcall(peripheral.getType, name)
      isMonitor = okType and ptype == "monitor"
    end
    if isMonitor then
      local row = { name = name }
      local dev = peripheral.wrap(name)
      if dev then
        local okSize, w, h = pcall(dev.getSize)
        if okSize then row.width, row.height = w, h end
      end
      out[#out + 1] = row
    end
  end
  return out
end

--- Unregister one frame and blank its monitor, so nothing is left frozen on screen.
function Monitors:_teardown(item)
  if not item or not item.frame then return end
  pcall(function() self.basalt.setActiveFrame(item.frame, false) end)
  pcall(function()
    item.monitor.setBackgroundColour(colours.black)
    item.monitor.clear()
  end)
end

--- Tear down every frame.
function Monitors:clear()
  for _, instances in pairs(self.frames) do
    for _, item in ipairs(instances) do self:_teardown(item) end
  end
  self.frames = {}
  self.missing = {}
end

--- Build one frame on one monitor. Returns the instance, or nil with a reason.
function Monitors:_build(panelName, name, index, builder)
  local panel = self.cfg.panels[panelName]
  local monitor = nil
  local ok = pcall(function() monitor = peripheral.wrap(name) end)
  if not ok or monitor == nil or monitor.setCursorPos == nil then
    self.missing[#self.missing + 1] = ("%s -> %s"):format(panelName, name)
    self.log:warn("panel %s: monitor '%s' is not present", panelName, name)
    return nil
  end
  pcall(function() monitor.setTextScale(panel.textScale or 0.5) end)
  local frame = self.basalt.createFrame()
  frame:setTerm(monitor)
  local okBuild, instance = pcall(builder, frame, panelName, index)
  if not okBuild then
    self.log:error("panel %s on %s failed to build: %s", panelName, name, tostring(instance))
    return nil
  end
  return { name = name, monitor = monitor, frame = frame, instance = instance }
end

--- Reconcile the live frames against the configured assignment, touching only what changed.
---
--- This is why reassigning a monitor no longer rebuilds the whole cockpit: the panel you are
--- configuring FROM survives, unless you reassigned its own monitor -- in which case it should
--- change. `builders` maps panel name -> builder function.
--- Returns the number of frames added or removed.
function Monitors:sync(builders)
  local changed = 0

  -- Detach anything that is no longer assigned where it is built.
  for panelName, instances in pairs(self.frames) do
    local panel = self.cfg.panels[panelName]
    local wanted = {}
    if panel and panel.enabled ~= false then
      for _, name in ipairs(panel.monitors or {}) do wanted[name] = true end
    end
    for i = #instances, 1, -1 do
      if not wanted[instances[i].name] then
        self:_teardown(instances[i])
        table.remove(instances, i)
        changed = changed + 1
      end
    end
  end

  -- Attach anything assigned but not yet built.
  self.missing = {}
  for panelName, builder in pairs(builders) do
    local panel = self.cfg.panels[panelName]
    if panel and panel.enabled ~= false then
      self.frames[panelName] = self.frames[panelName] or {}
      local live = self.frames[panelName]
      for index, name in ipairs(panel.monitors or {}) do
        local exists = false
        for _, item in ipairs(live) do
          if item.name == name then exists = true end
        end
        if not exists then
          local instance = self:_build(panelName, name, index, builder)
          if instance then
            live[#live + 1] = instance
            changed = changed + 1
          end
        end
      end
    end
  end

  return changed
end

--- Build frames for one panel. `builder(frame, panelName, index)` returns the panel instance,
--- which must expose `update(model)`.
function Monitors:buildPanel(panelName, builder)
  local panel = self.cfg.panels[panelName]
  if not panel or panel.enabled == false then return {} end

  local instances = {}
  for index, name in ipairs(panel.monitors or {}) do
    local instance = self:_build(panelName, name, index, builder)
    if instance then instances[#instances + 1] = instance end
  end
  self.frames[panelName] = instances
  if #instances > 1 then
    self.log:info("panel %s mirrored to %d monitors", panelName, #instances)
  elseif #instances == 1 then
    self.log:info("panel %s on %s", panelName, instances[1].name)
  end
  return instances
end

--- Push a fresh model into every instance of every panel. One data source, N screens.
function Monitors:update(model)
  for panelName, instances in pairs(self.frames) do
    for _, item in ipairs(instances) do
      if item.instance and item.instance.update then
        local ok, err = pcall(item.instance.update, model)
        if not ok then
          self.log:throttled("panelupd:" .. panelName, 5000, "error",
            "panel %s update failed: %s", panelName, tostring(err))
        end
      end
    end
  end
end

function Monitors:count(panelName)
  return #(self.frames[panelName] or {})
end

function Monitors:summary()
  local out = {}
  for _, panelName in ipairs(require("lib.config").PANEL_ORDER) do
    out[panelName] = {
      assigned = #((self.cfg.panels[panelName] or {}).monitors or {}),
      live = self:count(panelName),
    }
  end
  out.missing = self.missing
  return out
end

return Monitors
