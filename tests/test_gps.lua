--[[ The gps_beacon role: the host protocol, the peer mesh, and constellation geometry.

     Every rule asserted here was read out of CC's own rom/apis/gps.lua, not remembered. The
     failure modes are silent -- a constellation that cannot give a fix returns NOTHING rather
     than a worse fix -- so the tests are written against the protocol's actual requirements.
]]

local T = require("tests.util")
local Geometry = require("lib.geometry")
local Host = require("lib.host")
local Mesh = require("lib.mesh")
local Config = require("lib.config")
local Theme = require("ui.theme")
local Log = require("shared.log")

local function quietLog() return Log.new({ level = "error", capacity = 80 }) end

-- ------------------------------------------------------------ the protocol

T.suite("gps host protocol")

T.it("answers on CC's OWN channel, so gps.locate() works unmodified", function()
  T.eq(Host.CHANNEL, 65534, "gps.CHANNEL_GPS")
  T.eq(Host.PING, "PING", "the request payload locate() sends")
end)

T.it("THE REPLY IS A THREE-ELEMENT ARRAY, not a keyed table", function()
  -- locate() checks `#tMessage == 3` and tonumber() on each element. A { x =, y =, z = } table
  -- has length 0 and is silently ignored -- the beacon would look alive and never count.
  local reply = Host.reply({ x = 10, y = 64, z = -20 })
  T.eq(#reply, 3, "three elements")
  T.eq(reply[1], 10, "x first")
  T.eq(reply[2], 64, "then y")
  T.eq(reply[3], -20, "then z")
  T.isNil(reply.x, "and NOT keyed")
end)

T.it("only answers a ping on the right channel with the right payload", function()
  T.isTrue(Host.isPing(65534, 65534, "PING"), "the real thing")
  T.isFalse(Host.isPing(1, 65534, "PING"), "wrong channel")
  T.isFalse(Host.isPing(65534, 1, "PING"), "wrong reply channel")
  T.isFalse(Host.isPing(65534, 65534, "HELLO"), "wrong payload")
  T.isFalse(Host.isPing(65534, 65534, { "PING" }), "a table is not the string")
end)

T.it("REFUSES TO ANSWER without coordinates", function()
  -- Silence shows up on the other beacons as "3 of 4". Answering from a wrong or absent
  -- position shows up as nothing at all, which is much harder to diagnose.
  local cfg = Config.withDefaults({ position = { x = nil, y = nil, z = nil } })
  local host = Host.new(cfg, quietLog())
  local sent = {}
  host.modem = { transmit = function(...) sent[#sent + 1] = { ... } end }
  T.isFalse(host:onModemMessage("back", 65534, 65534, "PING"), "not answered")
  T.eq(#sent, 0, "nothing transmitted")
end)

T.it("answers with its configured position, and counts what it served", function()
  local cfg = Config.withDefaults({ position = { x = 100, y = 72, z = -300 } })
  local host = Host.new(cfg, quietLog())
  local sent = {}
  host.modem = { transmit = function(channel, reply, payload)
    sent[#sent + 1] = { channel = channel, reply = reply, payload = payload }
  end }

  T.isTrue(host:onModemMessage("back", 65534, 65534, "PING"), "answered")
  T.eq(#sent, 1)
  T.eq(sent[1].channel, 65534, "on the GPS channel")
  T.eq(sent[1].reply, 65534, "replying on it too")
  T.eq(sent[1].payload[1], 100)
  T.eq(sent[1].payload[3], -300)
  T.eq(host.served, 1, "counted")
end)

T.it("a disabled beacon goes quiet instead of answering from where it used to be", function()
  local cfg = Config.withDefaults({ position = { x = 1, y = 2, z = 3 }, enabled = false })
  local host = Host.new(cfg, quietLog())
  local sent = 0
  host.modem = { transmit = function() sent = sent + 1 end }
  T.isFalse(host:onModemMessage("back", 65534, 65534, "PING"))
  T.eq(sent, 0, "silent, so it drops out of the constellation honestly")
end)

-- ------------------------------------------------------------- self checking

T.suite("beacon self check")

T.it("CATCHES A TYPO'D COORDINATE, which nothing else would", function()
  -- This is the failure that never announces itself: the beacon answers confidently and every
  -- fix in the world is wrong by however far the typo was.
  local cfg = Config.withDefaults({ position = { x = 100, y = 64, z = 200 } })
  local host = Host.new(cfg, quietLog())
  -- the constellation says we are somewhere else entirely
  local check = host:verify(function() return 100, 64, 220 end)
  T.eq(check.state, "MISMATCH", "caught")
  T.near(check.error, 20, 1e-6, "and reports how far off: " .. tostring(check.error))
  T.eq(check.configured.z, 200, "showing both numbers so the typo is obvious")
  T.eq(check.located.z, 220)
end)

T.it("passes when the constellation agrees", function()
  local cfg = Config.withDefaults({ position = { x = 100, y = 64, z = 200 } })
  local host = Host.new(cfg, quietLog())
  local check = host:verify(function() return 100.2, 64, 199.9 end)
  T.eq(check.state, "ok", "within tolerance")
end)

T.it("says NO FIX rather than ok when the others are not up yet", function()
  -- A constellation cannot fix its own first member, so this is the normal state while building.
  local cfg = Config.withDefaults({ position = { x = 1, y = 2, z = 3 } })
  local host = Host.new(cfg, quietLog())
  local check = host:verify(function() return nil end)
  T.eq(check.state, "no fix", "not mistaken for a pass")
  T.isTrue(check.detail:find("four") ~= nil, "and explains: " .. check.detail)
end)

T.it("survives gps.locate() throwing", function()
  local cfg = Config.withDefaults({ position = { x = 1, y = 2, z = 3 } })
  local host = Host.new(cfg, quietLog())
  local check = host:verify(function() error("no modem") end)
  T.eq(check.state, "no fix", "an exploding locate is just a missing fix")
end)

T.it("reports 'no coordinates set' distinctly from a failed check", function()
  local host = Host.new(Config.withDefaults({}), quietLog())
  T.eq(host:verify(function() return 1, 2, 3 end).state, "no coordinates set")
end)

-- --------------------------------------------------------------- geometry

T.suite("constellation geometry")

--- A good constellation: well spread, and one beacon well above the others.
local function goodHosts()
  return {
    { x = 0, y = 70, z = 0, label = "N" },
    { x = 200, y = 72, z = 0, label = "E" },
    { x = 0, y = 68, z = 200, label = "S" },
    { x = 60, y = 150, z = 60, label = "HIGH" },
  }
end

T.it("FOUR COPLANAR BEACONS ARE UNUSABLE, not merely worse", function()
  -- The natural thing to build is a flat ring at one height. gps.locate() then cannot resolve
  -- the mirror position and returns NOTHING -- so this must be caught loudly.
  local flat = {
    { x = 0, y = 70, z = 0 }, { x = 200, y = 70, z = 0 },
    { x = 200, y = 70, z = 200 }, { x = 0, y = 70, z = 200 },
  }
  local a = Geometry.assess(flat)
  T.isTrue(a.coplanar, "detected")
  T.isFalse(a.usable, "and refused")
  T.eq(a.grade, "UNUSABLE")
  local joined = table.concat(a.problems, " ")
  T.isTrue(joined:find("COPLANAR") ~= nil, "named: " .. joined)
  T.isTrue(joined:find("above or below") ~= nil, "with the fix to make")
end)

T.it("says how many are missing when there are fewer than four", function()
  local a = Geometry.assess({ { x = 0, y = 70, z = 0 }, { x = 100, y = 80, z = 0 } })
  T.isFalse(a.usable)
  T.eq(a.hostCount, 2)
  T.isTrue(table.concat(a.problems, " "):find("needs four") ~= nil,
    "explains the requirement: " .. table.concat(a.problems, " "))
end)

T.it("a well-spread constellation with height variation grades well", function()
  local a = Geometry.assess(goodHosts())
  T.isTrue(a.usable, "usable: " .. table.concat(a.problems, "; "))
  T.isFalse(a.coplanar)
  T.isTrue(a.grade == "GOOD" or a.grade == "EXCELLENT", "grade: " .. a.grade)
  T.isTrue(a.volume > 0, "with a real tetrahedron volume")
end)

T.it("BEACONS CLOSER THAN A BLOCK COUNT AS ONE", function()
  -- gps.locate() replaces a fix within 1 block of an existing one rather than adding it.
  local hosts = goodHosts()
  hosts[2] = { x = 0.5, y = 70, z = 0, label = "TOO CLOSE" }
  local a = Geometry.assess(hosts)
  T.isFalse(a.usable, "refused")
  T.isTrue(table.concat(a.problems, " "):find("counts as ONE") ~= nil,
    "and says why: " .. table.concat(a.problems, " "))
end)

T.it("the spread measure is scale-free", function()
  -- Doubling the constellation's size must not change its grade: the geometry is the same shape.
  local small = Geometry.assess(goodHosts())
  local big = {}
  for i, host in ipairs(goodHosts()) do
    big[i] = { x = host.x * 4, y = (host.y - 70) * 4 + 70, z = host.z * 4, label = host.label }
  end
  local scaled = Geometry.assess(big)
  T.near(scaled.spread, small.spread, 1e-6, "same shape, same spread figure")
  T.eq(scaled.grade, small.grade, "and the same grade")
end)

T.it("summary fits a narrow screen", function()
  T.eq(Geometry.summary(Geometry.assess({ { x = 0, y = 0, z = 0 } })), "1/4 beacons")
  local good = Geometry.summary(Geometry.assess(goodHosts()))
  T.isTrue(#good <= 26, "short enough to show: '" .. good .. "'")
end)

-- ------------------------------------------------------------------- mesh

T.suite("beacon mesh")

local function meshRig(label, position)
  local cfg = Config.withDefaults({ label = label, position = position })
  return Mesh.new(cfg, quietLog()), cfg
end

local function announcement(id, label, position, enabled)
  return { proto = "ehgps1", id = id, label = label, position = position,
           enabled = enabled ~= false, served = 0, at = 1000 }
end

T.it("takes in a peer and lists it as alive", function()
  local mesh = meshRig("A", { x = 0, y = 70, z = 0 })
  T.isTrue(mesh:onMessage(2, announcement(2, "B", { x = 100, y = 72, z = 0 }),
    "eh_gps_mesh", 1000), "accepted")
  local alive = mesh:linkStatus(1000)
  T.eq(#alive, 1)
  T.eq(alive[1].label, "B")
  T.eq(alive[1].ageMs, 0)
end)

T.it("ignores a foreign protocol and a malformed announcement", function()
  local mesh = meshRig("A", { x = 0, y = 70, z = 0 })
  T.isFalse(mesh:onMessage(2, announcement(2, "B", { x = 1, y = 1, z = 1 }), "something_else", 1))
  T.isFalse(mesh:onMessage(2, { proto = "nope" }, "eh_gps_mesh", 1), "wrong proto tag")
  T.isFalse(mesh:onMessage(2, "hello", "eh_gps_mesh", 1), "not a table")
  T.isFalse(mesh:onMessage(2, announcement(2, "B", nil), "eh_gps_mesh", 1), "no position")
end)

T.it("a peer stops counting once it goes quiet", function()
  local mesh, cfg = meshRig("A", { x = 0, y = 70, z = 0 })
  mesh:onMessage(2, announcement(2, "B", { x = 100, y = 72, z = 0 }), cfg.meshProtocol, 1000)
  local alive, lost = mesh:linkStatus(1000 + cfg.peerTimeoutMs + 1)
  T.eq(#alive, 0, "no longer alive")
  T.eq(#lost, 1, "and listed as lost")
  T.eq(lost[1].label, "B")
end)

T.it("THE CONSTELLATION IS US PLUS THE LIVE, ENABLED PEERS", function()
  local mesh, cfg = meshRig("SELF", { x = 0, y = 70, z = 0 })
  mesh:onMessage(2, announcement(2, "B", { x = 200, y = 72, z = 0 }), cfg.meshProtocol, 1000)
  mesh:onMessage(3, announcement(3, "C", { x = 0, y = 68, z = 200 }), cfg.meshProtocol, 1000)
  -- a disabled beacon does not answer pings, so it must not count toward the four
  mesh:onMessage(4, announcement(4, "D", { x = 60, y = 150, z = 60 }, false),
    cfg.meshProtocol, 1000)

  local hosts = mesh:constellation(1000)
  T.eq(#hosts, 3, "three, because D is disabled: " .. #hosts)
  local a = mesh:assess(1000)
  T.isFalse(a.usable, "and therefore not usable")
end)

T.it("assesses the live constellation and grades it", function()
  local mesh, cfg = meshRig("SELF", { x = 0, y = 70, z = 0 })
  mesh:onMessage(2, announcement(2, "B", { x = 200, y = 72, z = 0 }), cfg.meshProtocol, 1000)
  mesh:onMessage(3, announcement(3, "C", { x = 0, y = 68, z = 200 }), cfg.meshProtocol, 1000)
  mesh:onMessage(4, announcement(4, "D", { x = 60, y = 150, z = 60 }), cfg.meshProtocol, 1000)
  local a = mesh:assess(1000)
  T.eq(a.hostCount, 4, "all four")
  T.isTrue(a.usable, "usable: " .. table.concat(a.problems, "; "))
end)

T.it("CATCHES TWO BEACONS ON THE SAME COORDINATES", function()
  -- One copy-paste away, and it quietly reduces the constellation to three usable hosts.
  local mesh, cfg = meshRig("SELF", { x = 0, y = 70, z = 0 })
  mesh:onMessage(2, announcement(2, "B", { x = 0, y = 70, z = 0 }), cfg.meshProtocol, 1000)
  mesh:onMessage(3, announcement(3, "C", { x = 0, y = 68, z = 200 }), cfg.meshProtocol, 1000)
  mesh:onMessage(4, announcement(4, "D", { x = 60, y = 150, z = 60 }), cfg.meshProtocol, 1000)
  local a = mesh:assess(1000)
  T.isFalse(a.usable, "refused")
  T.isTrue(table.concat(a.problems, " "):find("SAME position") ~= nil,
    "named: " .. table.concat(a.problems, " "))
end)

T.it("reports a lost peer as a problem on the quality readout", function()
  local mesh, cfg = meshRig("SELF", { x = 0, y = 70, z = 0 })
  mesh:onMessage(2, announcement(2, "GONE", { x = 200, y = 72, z = 0 }), cfg.meshProtocol, 1000)
  local a = mesh:assess(1000 + cfg.peerTimeoutMs + 5000)
  local joined = table.concat(a.problems, " ")
  T.isTrue(joined:find("GONE") ~= nil, "names it: " .. joined)
  T.isTrue(joined:find("not been heard") ~= nil, "and says what happened")
end)

-- ------------------------------------------------------------------ config

T.suite("beacon config")

T.it("derives a label so three other screens are not full of blanks", function()
  local cfg = Config.withDefaults({})
  T.isTrue(cfg.label:find("beacon%-") ~= nil, "label: " .. cfg.label)
end)

T.it("an unset position is a STATE, not an error", function()
  local cfg = Config.withDefaults({})
  T.isTrue((Config.validate(cfg)), "valid config")
  T.isFalse(Config.hasPosition(cfg), "but no position yet")
end)

T.it("TWO AXES OUT OF THREE IS A TYPO, and is refused", function()
  local cfg = Config.withDefaults({ position = { x = 10, y = 70 } })
  local ok, errors = Config.validate(cfg)
  T.isFalse(ok, "refused")
  T.isTrue(table.concat(errors, " "):find("all three") ~= nil,
    "and says so: " .. table.concat(errors, " "))
end)

T.it("rejects NaN and out-of-world coordinates", function()
  T.isFalse((Config.validate(Config.withDefaults({ position = { x = 0/0, y = 1, z = 2 } }))), "NaN")
  T.isFalse((Config.validate(Config.withDefaults({ position = { x = 5e7, y = 1, z = 2 } }))),
    "outside the world")
end)

T.it("an old config gains fields added later", function()
  local cfg = Config.withDefaults({ label = "North", position = { x = 1, y = 2, z = 3 } })
  T.eq(cfg.label, "North", "mine survived")
  T.eq(cfg.meshProtocol, "eh_gps_mesh", "and new fields appeared")
  T.eq(cfg.selfCheckTolerance, 1.0)
end)


-- ------------------------------------------------------------------- panel

T.suite("beacon panel")

--- Built against REAL Basalt, in a real window.
---
--- These exist because the first beacon installed in game crashed on boot: the panel called
--- `setValue` on an Input, which does not exist -- Basalt holds an Input's contents in its `text`
--- property, so the generated accessors are setText/getText. Every other module in this role had
--- tests and the screen had none, so a guessed API reached the pilot untested.
local basalt = require("basalt")
local Panel = require("ui.panel")

local function panelRig(width, height, cfgOver)
  local monitor = window.create(term.current(), 1, 1, width or 51, height or 19, false)
  monitor.setTextScale = function() end
  monitor.getTextScale = function() return 1 end
  local frame = basalt.createFrame()
  frame:setTerm(monitor)
  local cfg = Config.withDefaults(cfgOver or {})
  local saves = { count = 0 }
  local host = Host.new(cfg, quietLog())
  local mesh = Mesh.new(cfg, quietLog())
  local panel = Panel.build(frame, {
    cfg = cfg, host = host, mesh = mesh, log = quietLog(),
    save = function() saves.count = saves.count + 1 end,
  })
  return panel, cfg, saves, frame, monitor
end

local function model(status, assessment)
  return { status = status or {}, assessment = assessment or { problems = {}, hostCount = 0 } }
end

--- A tap through Basalt's own hit test, as the terminal delivers it.
local function click(element)
  return element:dispatchEvent("mouse_click", 1, element:getX(), element:getY())
end

T.it("BUILDS AND UPDATES WITHOUT THROWING -- the crash that shipped", function()
  local panel = panelRig()
  panel.update(model())                       -- must not error
  T.notNil(panel.elements.title, "the panel exists")
end)

T.it("the coordinate fields use Basalt's REAL Input API", function()
  -- setText/getText, from the `text` property. setValue does not exist and fails only at runtime.
  local panel = panelRig(51, 19, { position = { x = 12, y = 70, z = -34 } })
  for _, axis in ipairs({ "x", "y", "z" }) do
    local field = panel.fields[axis]
    T.eq(type(field.setText), "function", axis .. " has setText")
    T.eq(type(field.getText), "function", axis .. " has getText")
    T.isNil(field.setValue, axis .. ": setValue does NOT exist, which is what broke")
  end
  T.eq(panel.fields.x:getText(), "12", "and the fields were filled from the config")
  T.eq(panel.fields.z:getText(), "-34", "including negatives")
end)

T.it("shows blank fields when no position is set yet", function()
  local panel = panelRig()
  T.eq(panel.fields.x:getText(), "", "nothing to show")
end)

T.it("SAVES a typed position, and tells the config", function()
  local panel, cfg, saves = panelRig()
  panel.show(panel.pages.edit)
  panel.fields.x:setText("100")
  panel.fields.y:setText("72")
  panel.fields.z:setText("-300")
  click(panel.elements.title and panel.pages.edit or panel.pages.edit)   -- no-op, keeps shape
  -- the SAVE button is the first bottom-row button on the edit page
  local saved = false
  for _, child in ipairs(panel.pages.edit.getChildren and panel.pages.edit:getChildren() or {}) do
    if child.getText and child:getText() == "SAVE" then click(child); saved = true end
  end
  T.isTrue(saved, "found the SAVE button")
  T.eq(cfg.position.x, 100, "x stored")
  T.eq(cfg.position.z, -300, "z stored")
  T.eq(saves.count, 1, "and written to disk")
  T.isTrue(panel.pages.home:getVisible(), "returning to the home page")
end)

T.it("REFUSES a non-numeric coordinate and says which axis", function()
  local panel, cfg = panelRig()
  panel.show(panel.pages.edit)
  panel.fields.x:setText("100")
  panel.fields.y:setText("seventy")
  panel.fields.z:setText("-300")
  for _, child in ipairs(panel.pages.edit:getChildren()) do
    if child.getText and child:getText() == "SAVE" then click(child) end
  end
  T.isTrue(panel.elements.editError:getText():find("Y") ~= nil,
    "names the axis: " .. panel.elements.editError:getText())
  T.isNil(cfg.position.x, "and NOTHING was stored -- not two axes out of three")
end)

T.it("says NO POSITION SET rather than drawing zeros", function()
  local panel = panelRig()
  panel.update(model({ position = {} }))
  T.isTrue(panel.elements.position:getText():find("NO POSITION") ~= nil,
    "position line: " .. panel.elements.position:getText())
  T.eq(panel.elements.position:getForeground(), Theme.warning, "and flags it")
end)

T.it("A SELF-CHECK MISMATCH IS THE LOUDEST LINE ON THE SCREEN", function()
  local panel = panelRig(51, 19, { position = { x = 1, y = 2, z = 3 } })
  panel.update(model({ position = { x = 1, y = 2, z = 3 },
                       selfCheck = { state = "MISMATCH", error = 20.4 } }))
  local text = panel.elements.check:getText()
  T.isTrue(text:find("MISMATCH") ~= nil, "named: " .. text)
  T.isTrue(text:find("20") ~= nil, "with how far off")
  T.eq(panel.elements.check:getForeground(), Theme.warning, "in the warning colour")
end)

T.it("a passing self check reads calmly", function()
  local panel = panelRig(51, 19, { position = { x = 1, y = 2, z = 3 } })
  panel.update(model({ position = { x = 1, y = 2, z = 3 },
                       selfCheck = { state = "ok", error = 0.12 } }))
  T.isTrue(panel.elements.check:getText():find("ok") ~= nil)
  T.eq(panel.elements.check:getForeground(), Theme.ok)
end)

T.it("lists this beacon and its peers, marking which one is us", function()
  local panel = panelRig()
  panel.update(model({}, { hostCount = 3, usable = false, problems = {}, hosts = {
    { x = 0, y = 70, z = 0, label = "me", self_ = true },
    { x = 200, y = 72, z = 0, label = "East" },
    { x = 0, y = 68, z = 200, label = "South" },
  } }))
  T.isTrue(panel.elements.peers[1]:getText():find("this one") ~= nil,
    "ours is marked: " .. panel.elements.peers[1]:getText())
  T.isTrue(panel.elements.peers[2]:getText():find("East") ~= nil, "peers named with coordinates")
  T.isTrue(panel.elements.peers[2]:getText():find("200") ~= nil)
end)

T.it("shows the count and grade, and the FIRST problem to fix", function()
  local panel = panelRig()
  panel.update(model({}, { hostCount = 4, usable = false, grade = "UNUSABLE",
    problems = { "the beacons are effectively COPLANAR", "something else" }, hosts = {} }))
  T.isTrue(panel.elements.grade:getText():find("4/4") ~= nil,
    "count: " .. panel.elements.grade:getText())
  T.isTrue(panel.elements.grade:getText():find("UNUSABLE") ~= nil, "and the grade")
  T.eq(panel.elements.grade:getForeground(), Theme.warning, "flagged")
  T.isTrue(panel.elements.problem:getText():find("COPLANAR") ~= nil,
    "the first problem, not a wall of them: " .. panel.elements.problem:getText())
end)

T.it("the ENABLE toggle reflects and flips the config", function()
  local panel, cfg, saves = panelRig()
  panel.update(model())
  T.eq(panel.elements.enable:getText(), "ON", "starts enabled")
  click(panel.elements.enable)
  T.isFalse(cfg.enabled, "flipped")
  T.eq(saves.count, 1, "and saved, so moving a beacon survives a reboot")
  panel.update(model())
  T.eq(panel.elements.enable:getText(), "OFF", "and the label follows")
end)

T.it("CANCEL puts the fields back rather than keeping a half-typed value", function()
  local panel, cfg = panelRig(51, 19, { position = { x = 5, y = 6, z = 7 } })
  panel.show(panel.pages.edit)
  panel.fields.x:setText("999")
  for _, child in ipairs(panel.pages.edit:getChildren()) do
    if child.getText and child:getText() == "CANCEL" then click(child) end
  end
  T.eq(cfg.position.x, 5, "config untouched")
  T.eq(panel.fields.x:getText(), "5", "and the field reverted")
  T.isTrue(panel.pages.home:getVisible(), "back on the home page")
end)

T.it("changing coordinates INVALIDATES the previous self-check verdict", function()
  -- Leaving a stale "ok" showing after moving a beacon would be the most misleading thing on
  -- the screen: the check that passed was for a different position.
  local panel, cfg, _, _, _ = panelRig(51, 19, { position = { x = 1, y = 2, z = 3 } })
  local host = Host.new(cfg, quietLog())
  host.selfCheck = { state = "ok", error = 0.1 }
  -- rebuild with that host so the panel holds it
  local monitor = window.create(term.current(), 1, 1, 51, 19, false)
  monitor.setTextScale = function() end
  local frame = basalt.createFrame()
  frame:setTerm(monitor)
  local p2 = Panel.build(frame, { cfg = cfg, host = host, mesh = Mesh.new(cfg, quietLog()),
    log = quietLog(), save = function() end })
  p2.show(p2.pages.edit)
  p2.fields.x:setText("50")
  p2.fields.y:setText("60")
  p2.fields.z:setText("70")
  for _, child in ipairs(p2.pages.edit:getChildren()) do
    if child.getText and child:getText() == "SAVE" then click(child) end
  end
  T.eq(host.selfCheck.state, "unchecked", "the stale verdict was cleared")
end)

T.it("fits a standard 51x19 terminal, and a pocket-sized one", function()
  local wide = panelRig(51, 19)
  wide.update(model())
  local small = panelRig(26, 20)
  small.update(model())          -- must not throw
  T.notNil(small.elements.grade, "still builds")
end)

return true
