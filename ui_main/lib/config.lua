--[[ ui_main configuration: which UI goes on which monitor, and how it is drawn.

     Same rules as the flight config: backward-additive (an old file loads and gains new
     fields), validated, and saved with a verified readback.

     The central idea is PANELS. A panel is a UI definition, and it can be assigned to SEVERAL
     monitors -- the overhead panel and the PFD are each mirrored to one screen on either side
     of the cockpit. Each assigned monitor gets its own Basalt frame built from the same data,
     which is how Basalt routes touch per monitor (it matches on `peripheral.getName`).
]]

local Util = require("shared.util")

local Config = {}

local PANEL_ORDER = { "overhead", "config", "pfd", "autopilot", "nav" }
Config.PANEL_ORDER = PANEL_ORDER

--- Every panel entry is merged over this, so a panel configured months ago gains new fields.
local function panelTemplate()
  return {
    monitors = {},      -- peripheral names; more than one mirrors the same UI
    textScale = 0.5,    -- 0.5 gives the most room on a small monitor
    enabled = true,
  }
end

function Config.defaults()
  return {
    --- 1 -> 2 re-enables panels that an old release saved as `enabled = false`. See migrate.
    version = 2,

    panelTemplate = panelTemplate(),

    --- EVERY PANEL DEFAULTS TO enabled = true, INCLUDING THE ONES NOT WRITTEN YET.
    ---
    --- `enabled` used to carry "is this panel implemented", and pfd/autopilot/nav were shipped
    --- false. That is a fact about the CODE, and storing it in the operator's config file made
    --- it impossible to change: config is extend-never-replace, so when nav went live the new
    --- `enabled = true` default lost to the `false` already saved on the computer. The panel was
    --- assignable, the monitor was blanked by the detach pass, and no frame was ever built --
    --- a permanently black screen with nothing in the log. See Config.migrate.
    ---
    --- Whether a panel EXISTS is now decided by App's builder table alone (app.lua
    --- PANEL_BUILDERS), which cannot go stale because it is the same table that builds them.
    panels = {
      -- Above the driver's seat, facing down, 1 wide x 2 high. Engine start/stop, both fuel
      -- gauges, and their configuration in a submenu. MIRRORED to one screen either side.
      overhead = { monitors = {}, textScale = 0.5, enabled = true },
      -- Upward-facing, bottom right. Configuration only: monitor assignment, the disk menu,
      -- and the flight-control settings -- all in submenus. Its main page is reserved for
      -- in-flight values that are worth having on screen the whole time.
      config = { monitors = {}, textScale = 0.5, enabled = true },
      -- The map and waypoints come later, but the panel is LIVE now: its border carries the
      -- three pre-flight screens (FCS TEST, SELF TEST, AXIS MAP), needed before a first hover.
      nav = { monitors = {}, textScale = 0.5, enabled = true },
      -- Declared so an assignment can be recorded early. Nothing builds them yet, so nothing
      -- can be assigned to them either -- the terminal only offers panels with a builder.
      pfd = { monitors = {}, textScale = 0.5, enabled = true },
      autopilot = { monitors = {}, textScale = 0.5, enabled = true },
    },

    comms = {
      modem = "",                             -- blank = auto-pick the first wired modem
      telemetryProtocol = "eh_telemetry",
      commandProtocol = "eh_command",
      -- The nav computer's position/heading broadcast (see nav/lib/relay.lua). Must match the nav
      -- computer's comms.navFixProtocol. The nav monitor's heading tape and map read from it.
      navFixProtocol = "eh_navfix",
      -- Commands TO the nav computer (heading source, which table, sign flips, SELF ALIGN). Must
      -- match the nav computer's comms.navCommandProtocol. Wired only.
      navCommandProtocol = "eh_navcmd",
      staleMs = 2000,                         -- no telemetry for this long = show STALE
      -- Nav fixes arrive slower than flight telemetry, so a longer grace before the tape blanks.
      navStaleMs = 4000,
    },

    ui = {
      refreshHz = 5,                          -- Basalt render throttle
      -- Gauge thresholds, so the colours mean the same thing on every panel.
      cautionFraction = 0.25,
      warningFraction = 0.10,
      -- "day" (bright, high-contrast for sunlight) or "night" (softer for a dark cockpit). The
      -- DAY/NGT button on the nav monitor toggles it; persisted so it survives a reboot.
      dayNight = "day",
    },
  }
end

--- Repair a config written by an older release.
---
--- Extend-never-replace is the right rule and stays: a value the operator set must survive an
--- update. `panels.*.enabled` was never such a value -- no screen has ever been able to set it,
--- so a stored `false` cannot represent a choice anybody made. It can only be a leftover of the
--- release that shipped it, which means overwriting it destroys nothing. That is exactly what
--- makes this migration safe, and it is the test to apply before adding another one.
---
--- Returns cfg, changed.
function Config.migrate(cfg)
  local changed = false
  local from = tonumber(cfg.version) or 1

  if from < 2 then
    for _, name in ipairs(PANEL_ORDER) do
      local panel = cfg.panels and cfg.panels[name]
      if type(panel) == "table" and panel.enabled == false then
        panel.enabled = true
        changed = true
      end
    end
  end

  if changed or from < 2 then
    cfg.version = 2
    changed = true
  end
  return cfg, changed
end

function Config.withDefaults(loaded)
  local cfg = Util.deepMerge(Config.defaults(), loaded or {})
  local template = cfg.panelTemplate or panelTemplate()
  for _, name in ipairs(PANEL_ORDER) do
    cfg.panels[name] = Util.deepMerge(template, cfg.panels[name] or {})
  end
  -- The version in the FILE decides, so this has to run on the merged table using the loaded
  -- version -- deepMerge has already replaced it with the default otherwise.
  if loaded and loaded.version ~= nil then cfg.version = loaded.version end
  return (Config.migrate(cfg))
end

--- Structural validation. Returns ok, errors, warnings.
function Config.validate(cfg)
  local errors, warnings = {}, {}
  local function err(fmt, ...) errors[#errors + 1] = string.format(fmt, ...) end
  local function warn(fmt, ...) warnings[#warnings + 1] = string.format(fmt, ...) end

  local claimed = {}
  for _, name in ipairs(PANEL_ORDER) do
    local panel = cfg.panels[name]
    if type(panel) ~= "table" then
      err("panels.%s is missing", name)
    else
      if type(panel.monitors) ~= "table" then
        err("panels.%s.monitors must be a list", name)
      else
        for _, monitor in ipairs(panel.monitors) do
          if type(monitor) ~= "string" or monitor == "" then
            err("panels.%s has an empty monitor name", name)
          elseif claimed[monitor] then
            -- One monitor cannot show two panels: they would fight over the same frame.
            err("monitor '%s' is assigned to both %s and %s", monitor, claimed[monitor], name)
          else
            claimed[monitor] = name
          end
        end
      end
      if type(panel.textScale) ~= "number" or panel.textScale <= 0 then
        err("panels.%s.textScale must be a positive number", name)
      end
    end
  end

  if #(cfg.panels.overhead.monitors or {}) == 0 then
    warn("no monitor assigned to the overhead panel (engine + fuel) -- assign one in Config > Monitors")
  end
  if #(cfg.panels.config.monitors or {}) == 0 then
    warn("no monitor assigned to the config panel -- it will only be reachable from the terminal")
  end

  if type(cfg.ui.refreshHz) ~= "number" or cfg.ui.refreshHz <= 0 or cfg.ui.refreshHz > 20 then
    err("ui.refreshHz must be between 0 and 20")
  end

  return #errors == 0, errors, warnings
end

function Config.load(path)
  if not fs.exists(path) then return Config.withDefaults({}), false end
  local f = fs.open(path, "r")
  if not f then return Config.withDefaults({}), false end
  local text = f.readAll()
  f.close()
  local ok, parsed = pcall(textutils.unserialise, text)
  if not ok or type(parsed) ~= "table" then
    return Config.withDefaults({}), false, "config file is not a valid table"
  end
  return Config.withDefaults(parsed), true
end

function Config.save(path, cfg)
  local ok, text = pcall(textutils.serialise, cfg)
  if not ok then return false, "could not serialise config" end
  local f = fs.open(path, "w")
  if not f then return false, "could not open " .. tostring(path) end
  f.write(text)
  f.close()
  local reread = fs.open(path, "r")
  if not reread then return false, "could not reopen for verify" end
  local back = reread.readAll()
  reread.close()
  if back ~= text then return false, "verify readback mismatch" end
  return true
end

--- Assign a monitor to a panel, removing it from whatever panel had it. Returns ok, err.
function Config.assign(cfg, panelName, monitorName)
  local panel = cfg.panels[panelName]
  if not panel then return false, "no such panel: " .. tostring(panelName) end
  Config.unassign(cfg, monitorName)
  for _, existing in ipairs(panel.monitors) do
    if existing == monitorName then return true end
  end
  panel.monitors[#panel.monitors + 1] = monitorName
  table.sort(panel.monitors)
  return true
end

--- Remove a monitor from every panel.
function Config.unassign(cfg, monitorName)
  local removed = nil
  for _, name in ipairs(PANEL_ORDER) do
    local list = cfg.panels[name].monitors
    for i = #list, 1, -1 do
      if list[i] == monitorName then
        table.remove(list, i)
        removed = name
      end
    end
  end
  return removed
end

--- Which panel owns this monitor, if any?
function Config.panelFor(cfg, monitorName)
  for _, name in ipairs(PANEL_ORDER) do
    for _, monitor in ipairs(cfg.panels[name].monitors) do
      if monitor == monitorName then return name end
    end
  end
  return nil
end

return Config
