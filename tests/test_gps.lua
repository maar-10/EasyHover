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



-- ------------------------------------------------------------------ console

T.suite("beacon console")

--- The screen is plain `term`, keyboard-driven, because A BEACON RUNS ON A BASIC COMPUTER and a
--- basic computer HAS NO MOUSE. `mouse_click` is only generated on advanced ones, so the first
--- version -- a panel of Basalt buttons -- was entirely inert in the world: the handlers were
--- correct and the events never arrived.
---
--- `render` is pure, so all of this is testable without a terminal, which the button panel
--- never was.
local Console = require("ui.console")

local function rendered(cfg, model, width)
  local rows = Console.render(cfg, model or {}, width or 51, 19)
  local text = {}
  for _, row in ipairs(rows) do text[#text + 1] = row.text end
  for _, row in ipairs(rows.footer) do text[#text + 1] = row.text end
  return table.concat(text, "\n"), rows
end

local function model(status, assessment)
  return { status = status or {}, assessment = assessment or { problems = {}, hostCount = 0 } }
end

T.it("EVERY ACTION IS A SINGLE KEYPRESS -- nothing needs pointing at", function()
  T.eq(Console.actionFor("p"), "setPosition")
  T.eq(Console.actionFor("e"), "toggleEnabled")
  T.eq(Console.actionFor("v"), "verify")
  T.eq(Console.actionFor("q"), "quit")
  T.eq(Console.actionFor("P"), "setPosition", "upper case works too")
  T.isNil(Console.actionFor("x"), "and an unbound key does nothing")
  T.isNil(Console.actionFor(nil), "nor does a nil")
end)

T.it("the key legend is on the screen, so nothing has to be remembered", function()
  local text = rendered(Config.withDefaults({}), model())
  for _, key in ipairs({ "%[P%]", "%[E%]", "%[V%]", "%[Q%]" }) do
    T.isTrue(text:find(key) ~= nil, "legend has " .. key)
  end
  T.isTrue(text:find("set position") ~= nil, "and says what P does")
end)

T.it("SEVERITY IS IN THE TEXT, not just the colour", function()
  -- A basic terminal is MONOCHROME. A red MISMATCH and a green OK would render identically, so
  -- the words have to carry it on their own.
  local cfg = Config.withDefaults({ position = { x = 1, y = 2, z = 3 } })
  local text = rendered(cfg, model({ position = { x = 1, y = 2, z = 3 },
    selfCheck = { state = "MISMATCH", error = 20.4,
                  located = { x = 1, y = 2, z = 23 }, configured = { x = 1, y = 2, z = 3 } } }))
  T.isTrue(text:find("!! MISMATCH") ~= nil, "shouted in text: " .. text:match("[^\\n]*MISMATCH[^\\n]*"))
  T.isTrue(text:find("20%.4") ~= nil, "with how far off")
  T.isTrue(text:find("GPS says") ~= nil, "and both numbers, so the typo is obvious")
end)

T.it("a passing check reads calmly and still says so in words", function()
  local cfg = Config.withDefaults({ position = { x = 1, y = 2, z = 3 } })
  local text, rows = rendered(cfg, model({ position = { x = 1, y = 2, z = 3 },
    selfCheck = { state = "ok", error = 0.12 } }))
  T.isTrue(text:find("OK") ~= nil, "says OK")
  T.isFalse(text:find("MISMATCH") ~= nil, "and nothing alarming")
  -- the tone is a hint for a colour terminal, never the only signal
  local toned = false
  for _, row in ipairs(rows) do if row.tone == "good" then toned = true end end
  T.isTrue(toned, "a colour terminal still gets the hint")
end)

T.it("says NOT SET rather than drawing zeros", function()
  local text = rendered(Config.withDefaults({}), model({ position = {} }))
  T.isTrue(text:find("NOT SET") ~= nil, "named")
  T.isTrue(text:find("not answering") ~= nil, "and says what that means: " ..
    text:match("[^\\n]*NOT SET[^\\n]*"))
end)

T.it("shows the count, the grade, and this beacon marked among its peers", function()
  local text = rendered(Config.withDefaults({ label = "North" }), model({}, {
    hostCount = 3, usable = false, grade = "UNUSABLE", problems = {}, hosts = {
      { x = 0, y = 70, z = 0, label = "North", self_ = true },
      { x = 200, y = 72, z = 0, label = "East" },
      { x = 0, y = 68, z = 200, label = "South" },
    } }))
  T.isTrue(text:find("3 of 4") ~= nil, "the count")
  T.isTrue(text:find("UNUSABLE") ~= nil, "the grade")
  T.isTrue(text:find("%* North %(this one%)") ~= nil, "ours is marked")
  T.isTrue(text:find("%+ East  200 72 0") ~= nil, "and peers show their coordinates")
end)

T.it("WRAPS a problem rather than letting it run off the screen unread", function()
  local long = "the beacons are effectively COPLANAR -- gps.locate() cannot resolve the mirror "
    .. "position and will return nothing. Move one well above or below the others."
  local _, rows = rendered(Config.withDefaults({}),
    model({}, { hostCount = 4, usable = false, grade = "UNUSABLE", problems = { long }, hosts = {} }))
  local wrapped = 0
  for _, row in ipairs(rows) do
    T.isTrue(#row.text <= 51, "no row exceeds the width: " .. row.text)
    if row.text:find("COPLANAR") or row.text:find("above or below") then wrapped = wrapped + 1 end
  end
  T.isTrue(wrapped >= 2, "the sentence was wrapped over several rows, got " .. wrapped)
end)

T.it("shows at most two problems, because the rest follow once these are fixed", function()
  local _, rows = rendered(Config.withDefaults({}), model({}, {
    hostCount = 4, usable = false, problems = { "first one", "second one", "third one" },
    hosts = {} }))
  local text = {}
  for _, row in ipairs(rows) do text[#text + 1] = row.text end
  local joined = table.concat(text, "\n")
  T.isTrue(joined:find("first one") ~= nil, "first shown")
  T.isTrue(joined:find("second one") ~= nil, "second shown")
  T.isFalse(joined:find("third one") ~= nil, "third withheld")
end)

T.it("the ENABLED legend reflects the config", function()
  local on = rendered(Config.withDefaults({ enabled = true }), model())
  T.isTrue(on:find("enabled: YES") ~= nil, "on")
  local off = rendered(Config.withDefaults({ enabled = false }), model())
  T.isTrue(off:find("enabled: NO") ~= nil, "off")
end)

T.it("every row fits the terminal width, at 51 and at 26", function()
  -- Deliberately awkward content: a long label and six-figure coordinates, which is what a
  -- beacon far from spawn actually has.
  local cfg = Config.withDefaults({ label = "a-very-long-beacon-label-indeed",
                                    position = { x = -123456, y = 200, z = 987654 } })
  local worst = model({
    position = cfg.position,
    selfCheck = { state = "MISMATCH", error = 1234.5,
                  located = { x = 1, y = 2, z = 3 }, configured = cfg.position },
    served = 999999,
  }, {
    hostCount = 4, usable = false, grade = "UNUSABLE",
    problems = { "two beacons are configured at the SAME position -- one of them is a copy" },
    hosts = { { x = -123456, y = 200, z = 987654, label = cfg.label, self_ = true } },
  })

  for _, width in ipairs({ 51, 26 }) do
    local rows = Console.render(cfg, worst, width, 19)
    for _, row in ipairs(rows) do
      T.isTrue(#row.text <= width, ("width %d: %q is %d"):format(width, row.text, #row.text))
    end
    for _, row in ipairs(rows.footer) do
      T.isTrue(#row.text <= width, ("footer at %d: %q"):format(width, row.text))
    end
  end
end)

-- --------------------------------------------------------- coordinate entry

T.suite("beacon position entry")

--- A reader that hands back canned answers, so the prompt is testable without a keyboard.
local function reader(answers)
  local index = 0
  return function()
    index = index + 1
    return answers[index]
  end
end

T.it("reads three coordinates and floors them", function()
  local wanted = Console.readPosition(reader({ "100", "72.6", "-300" }))
  T.eq(wanted.x, 100)
  T.eq(wanted.y, 72, "floored")
  T.eq(wanted.z, -300, "negatives work")
end)

T.it("ALL THREE OR NONE -- a bad axis changes nothing", function()
  -- Two axes stored is a typo mid-entry, not a position, and would leave the beacon in a state
  -- its own validator rejects.
  local wanted, err = Console.readPosition(reader({ "100", "seventy", "-300" }))
  T.isNil(wanted, "refused")
  T.isTrue(tostring(err):find("Y is not a number") ~= nil, "names the axis: " .. tostring(err))
  T.isTrue(tostring(err):find("nothing was changed") ~= nil, "and reassures")
end)

T.it("a BLANK answer keeps the value already set", function()
  local wanted = Console.readPosition(reader({ "", "", "" }), { x = 5, y = 6, z = 7 })
  T.eq(wanted.x, 5, "kept")
  T.eq(wanted.z, 7)
end)

T.it("but a blank with nothing set is refused rather than stored as zero", function()
  local wanted, err = Console.readPosition(reader({ "", "1", "2" }), nil)
  T.isNil(wanted, "refused")
  T.isTrue(tostring(err):find("X") ~= nil, "names it: " .. tostring(err))
end)

T.it("tolerates spaces around a number", function()
  local wanted = Console.readPosition(reader({ "  100 ", " 72", "-300  " }))
  T.eq(wanted.x, 100)
  T.eq(wanted.y, 72)
end)

T.it("the header WARNS what a wrong number costs", function()
  local header = table.concat(Console.positionHeader(), " ")
  T.isTrue(header:find("F3") ~= nil, "tells you where to read them")
  T.isTrue(header:find("poisons every fix") ~= nil, "and what a typo does: " .. header)
  T.isTrue(header:find("self check") ~= nil, "and that only the self check notices")
end)

return true
