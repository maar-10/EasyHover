--[[ Commands the UI computer may send the navigation computer, whitelisted and type-checked.

     The nav computer answers "where am I" and "which way am I facing". Almost nothing should be
     able to change it from off-computer -- but the pilot does need to pick the heading SOURCE (the
     nav table vs the raw gimbal), pick WHICH table when there are several, flip a sign that reads
     backwards in-game, and force a SELF ALIGN. Those, and only those, live here.

     Same contract as the flight computer's command channel (flight/lib/telemetry.lua): a UI is not
     a trusted peer, so every command is checked HERE, on this computer, before it reaches anything
     that writes config. WIRED ONLY -- the caller passes the protocol and the app only listens for
     it on the wired modem, so the control surface stays off the air (docs/WIRING.md).
]]

local NavCommand = {}

--- The whitelist. Each entry maps field -> expected type. "enum:a,b" restricts a string to a set.
--- A command with no fields (selfAlign, navPing) is just its name.
local COMMANDS = {
  navPing          = {},
  -- Where heading comes from: the nav table (true north, gimbal as backup), the raw gimbal
  -- (relative, no north reference), or auto (table if present, else gimbal).
  setHeadingSource = { source = "enum:auto,navtable,gimbal" },
  -- Which navigation table. "" auto-picks the first on the network (the config's modularity rule).
  setNavTable      = { peripheral = "string" },
  -- Sign flips, for a table or gimbal that counts the wrong way. The value is a number; the app
  -- reduces it to +1/-1. Flipping either clears the calibration, so a SELF ALIGN should follow.
  setNavSign       = { sign = "number" },
  setGimbalSign    = { sign = "number" },
  -- Force a fresh table read and re-true the heading to it, now.
  selfAlign        = {},
}
NavCommand.COMMANDS = COMMANDS

--- Does `value` satisfy `spec`? Identical rules to the flight side, on purpose: one wire-format
--- convention across the craft. "enum:..." checks membership; "any" is any non-nil; otherwise it
--- is a Lua type name.
local function typeMatches(spec, value)
  if spec == "any" then return value ~= nil end
  if spec:sub(1, 5) == "enum:" then
    if type(value) ~= "string" then return false end
    for option in spec:sub(6):gmatch("[^,]+") do
      if value == option then return true end
    end
    return false
  end
  return type(value) == spec
end
NavCommand.typeMatches = typeMatches

--- Validate a received message. Returns a cleaned command table (only the whitelisted fields, plus
--- `sender`) on success, or nil + reason. No side effects: this only decides whether the app should
--- act on the message.
function NavCommand.parse(message, sender)
  if type(message) ~= "table" then return nil, "not a table" end
  local name = message.cmd
  if type(name) ~= "string" then return nil, "no cmd field" end
  local spec = COMMANDS[name]
  if spec == nil then return nil, "unknown command: " .. name end

  for field, expected in pairs(spec) do
    if not typeMatches(expected, message[field]) then
      return nil, ("field '%s' expects %s"):format(field, expected)
    end
  end

  local cmd = { cmd = name, sender = sender }
  for field in pairs(spec) do cmd[field] = message[field] end
  return cmd
end

return NavCommand
