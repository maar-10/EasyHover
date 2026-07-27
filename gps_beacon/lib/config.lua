--[[ The beacon's config. Same extend-never-replace rule as every other role.

     Deliberately tiny: a GPS beacon has one job and the fewer settings it has, the fewer ways
     it can be wrong. The one setting that matters is `position`, and getting it wrong is the
     failure this whole role is built to catch -- see host.lua's self check.
]]

local Config = {}

--- LISTS ARE REPLACED WHOLESALE, not merged element by element. shared/util.lua already gets
--- this right, so it is used rather than hand-rolled a third time -- my own version merged them
--- and therefore could not empty a list at all: `positionSources = {}` in a config silently kept
--- the default, and a shorter list inherited the tail of the longer default.
local Util = require("shared.util")

local deepMerge = Util.deepMerge

Config.deepMerge = deepMerge

function Config.defaults()
  return {
    version = 1,

    --- What this beacon is called on the mesh and in the other beacons' link lists.
    label = "",

    --- WHERE THIS COMPUTER IS. nil until set, and the beacon refuses to answer pings without
    --- it -- answering with a wrong or absent position is worse than staying quiet, because a
    --- silent beacon shows up as "3 of 4" while a lying one shows up as nothing at all.
    position = { x = nil, y = nil, z = nil },

    --- Blank = auto-pick the first WIRELESS modem. Must not be a wired one: gps.locate() only
    --- considers modems whose isWireless() is true.
    modem = "",

    --- Off means "do not answer pings". Useful while moving a beacon, so it drops out of the
    --- constellation honestly instead of answering from where it used to be.
    enabled = true,

    --- Peer status rides its own protocol; GPS itself is CC's format and we must not alter it.
    meshProtocol = "eh_gps_mesh",
    announceEverySeconds = 5,
    peerTimeoutMs = 15000,

    --- How often to check our own coordinates against what the constellation says, and how far
    --- off is too far. Needs the other beacons up, so it retries rather than failing once.
    selfCheckEverySeconds = 120,
    selfCheckTolerance = 1.0,
    gpsTimeout = 2,

    ui = { refreshHz = 4 },
  }
end

function Config.withDefaults(loaded)
  local cfg = deepMerge(Config.defaults(), loaded or {})
  -- A label nobody set is confusing on three other screens, so derive one.
  if cfg.label == nil or cfg.label == "" then
    cfg.label = "beacon-" .. tostring(os.getComputerID())
  end
  return cfg
end

--- Returns ok, errors. Position may be unset -- that is a state to report, not an error.
function Config.validate(cfg)
  local errors = {}
  local function err(fmt, ...) errors[#errors + 1] = fmt:format(...) end

  if type(cfg.label) ~= "string" or cfg.label == "" then err("label must be a name") end
  if type(cfg.meshProtocol) ~= "string" or cfg.meshProtocol == "" then
    err("meshProtocol must be a protocol name")
  end
  if type(cfg.peerTimeoutMs) ~= "number" or cfg.peerTimeoutMs < 1000 then
    err("peerTimeoutMs must be at least 1000")
  end
  if type(cfg.selfCheckTolerance) ~= "number" or cfg.selfCheckTolerance <= 0 then
    err("selfCheckTolerance must be positive")
  end

  local p = cfg.position or {}
  local set = 0
  for _, axis in ipairs({ "x", "y", "z" }) do
    local v = p[axis]
    if v ~= nil then
      if type(v) ~= "number" or v ~= v then
        err("position.%s must be a number", axis)
      elseif math.abs(v) > 3e7 then
        err("position.%s is outside the world", axis)
      else
        set = set + 1
      end
    end
  end
  -- Two axes out of three is not a position; it is a typo mid-entry.
  if set > 0 and set < 3 then err("position needs all three of x, y and z (have %d)", set) end

  return #errors == 0, errors
end

function Config.hasPosition(cfg)
  local p = cfg.position or {}
  return type(p.x) == "number" and type(p.y) == "number" and type(p.z) == "number"
end

function Config.load(path)
  if not fs.exists(path) then return Config.withDefaults({}), false end
  local handle = fs.open(path, "r")
  if not handle then return Config.withDefaults({}), false end
  local body = handle.readAll()
  handle.close()
  local ok, parsed = pcall(textutils.unserialise, body)
  if not ok or type(parsed) ~= "table" then
    return Config.withDefaults({}), false, "config will not parse"
  end
  return Config.withDefaults(parsed), true
end

function Config.save(path, cfg)
  local stage = path .. ".new"
  local handle = fs.open(stage, "w")
  if not handle then return false, "cannot write " .. stage end
  handle.write(textutils.serialise(cfg))
  handle.close()
  if fs.exists(path) then fs.delete(path) end
  fs.move(stage, path)
  return true
end

return Config
