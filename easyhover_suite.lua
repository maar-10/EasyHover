-- ===================================================================
-- EasyHover Suite  --  the setup tool: installs any role, updates every role
--
--   wget run https://raw.githubusercontent.com/maar-10/EasyHover/main/easyhover_suite.lua
--
-- The official way to put EasyHover on a computer and the official way to keep it current.
-- It carries no payload: it asks GitHub what the current release contains and fetches only
-- what this computer actually needs.
--
-- Run it with no arguments and it works out what to do:
--   * nothing installed   -> asks which role this computer should be, and installs it
--   * a role installed    -> updates that role, fetching only the files that differ
--   * a BROKEN install    -> repairs it, clearing the role's own files first
--
--   easyhover_suite.lua              install (asking for a role) or update, as appropriate
--   easyhover_suite.lua --check      say what WOULD change; write nothing
--   easyhover_suite.lua --repair     clear and reinstall the role's files
--   easyhover_suite.lua --fast       trust the version stamp and skip the checksums
--   easyhover_suite.lua --list       list every role
--   easyhover_suite.lua <role>       go straight to a role, no questions -- also switches one
--
-- FIVE PROPERTIES, because they are why this is safer than re-running an installer:
--
--   * IT CHECKSUMS EVERY FILE, EVERY RUN. A version stamp only says the files were correct
--     when they were written; it cannot know one has since been truncated by a chunk unload or
--     hand-edited. Finding that is the job, so it is the default, and it costs no network.
--   * ALL OR NOTHING. Every file is downloaded and checksum-verified into a `.ehnew` staging
--     file first. Only once every single one has arrived intact are they moved into place. A
--     dropped connection or a chunk unload half way through leaves the install exactly as it
--     was.
--   * CONFIG IS SACRED. Nothing matching the protected list is ever deleted, and `guard()` is
--     asserted immediately before every write, so a wrong manifest still could not clobber a
--     config. The guarantee does not depend on the manifest being right.
--   * CONFIG IS EXTENDED, NEVER REPLACED. A saved config is backed up, then re-saved through
--     the role's own Config.withDefaults, which deep-merges it over fresh defaults. Fields
--     added by a new release appear; every value you set is kept. The only case that replaces
--     a config is one that will not parse at all, and even then the original is backed up
--     first and you are told.
--   * REPAIR NEVER COSTS YOU SETTINGS. Repairing a corrupt install deletes only inside the
--     directories the role owns. Configs live at the root and are backed up before anything
--     is touched.
--
-- Trust model: HTTPS to a pinned raw.githubusercontent.com URL is the trust root, exactly as
-- it is for `wget run`. The checksums answer "did this change" and "did this arrive intact" --
-- they are not a signature and do not defend against a hostile GitHub.
-- ===================================================================

local DEFAULT_BASE = "https://raw.githubusercontent.com/maar-10/EasyHover/main"

--- A computer may point itself at a fork, a local mirror, or a LAN server. One line, the base
--- URL, no trailing slash. This is also how the test harness serves the repo from localhost.
local SOURCE_FILE = "/easyhover_suite_src.txt"

--- Optional. One line: a GitHub token, sent as an Authorization header. Only needed while the
--- repository is private -- see the note printed by --help. A token sitting in plain text on a
--- Minecraft computer is a poor secret; making the repo public is the better answer.
local TOKEN_FILE = "/easyhover_suite_token.txt"

--- What is installed here.
local STATE_FILE = "/easyhover_install.txt"

--- Backups land here, one timestamped folder per run that needed them.
local BACKUP_ROOT = "/easyhover_backup"

--- Staging suffix. Everything lands here first and is verified before anything moves.
local STAGE = ".ehnew"

--- NEVER deleted, and never written except by the config-extension step, which backs the file
--- up first. Everything the operator owns rather than the release. Lua patterns.
local PROTECTED = {
  "^/eh_.*%.tbl$",                  -- every role's config, waypoints, routes
  "^/easyhover_backup",             -- our own backups (directory, so no $ anchor)
  "^/easyhover_install%.txt$",      -- the install record
  "^/easyhover_suite_src%.txt$",    -- the operator's source override
  "^/easyhover_suite_token%.txt$",  -- and their token
  "^/role%.txt$",
  "^/probe_report%.txt$",           -- probe output is the operator's data
  "^/eh_.*%.log$",
}

local Suite = {}

-- ---------------------------------------------------------------- output

local function colour(c)
  if term.isColour and term.isColour() then term.setTextColour(c) end
end
local function say(text, c) colour(c or colours.white); print(text) end
local function warn(text) say(text, colours.yellow) end
local function bad(text) say(text, colours.red) end
local function good(text) say(text, colours.lime) end
local function dim(text) say(text, colours.lightGrey) end

local function die(text)
  bad(text)
  colour(colours.white)
  error("", 0)
end

-- ---------------------------------------------------------------- checksum

-- FNV-1a, 32 bit, lower-case hex. MUST agree byte for byte with fnv1a() in
-- tools/gen_manifest.js; tests/run_suite.sh asserts that it does.
local FNV_PRIME, FNV_OFFSET = 16777619, 2166136261

function Suite.checksum(s)
  local h, n, i = FNV_OFFSET, #s, 1
  while i <= n do
    local j = i + 255
    if j > n then j = n end
    -- string.byte in 256-value batches: one call per byte is many times slower.
    local b = { string.byte(s, i, j) }
    for k = 1, #b do
      h = bit32.bxor(h, b[k])
      -- 32-bit multiply split into 16-bit halves. The naive product reaches ~7.2e16, past the
      -- 2^53 exact-integer limit of a double, and would silently lose precision.
      local lo = h % 65536
      local hi = (h - lo) / 65536
      h = ((hi * FNV_PRIME % 65536) * 65536 + lo * FNV_PRIME) % 4294967296
    end
    i = j + 1
  end
  return ("%08x"):format(h)
end

-- ---------------------------------------------------------------- files

local function readFile(path)
  if not fs.exists(path) or fs.isDir(path) then return nil end
  local f = fs.open(path, "r")
  if not f then return nil end
  local s = f.readAll()
  f.close()
  return s or ""
end

--- Unguarded write. Only for files the Suite itself owns: the state record and backups.
local function writeRaw(path, content)
  local dir = fs.getDir(path)
  if dir ~= "" and dir ~= "/" and not fs.exists(dir) then fs.makeDir(dir) end
  local f = fs.open(path, "w")
  if not f then return false end
  f.write(content)
  f.close()
  return true
end

--- Is this path the operator's rather than the release's?
function Suite.isProtected(path)
  if not path:match("^/") then path = "/" .. path end
  for _, pattern in ipairs(PROTECTED) do
    if path:match(pattern) then return true end
  end
  return false
end

--- The last line of defence. Every release write and every delete goes through here.
local function guard(path, what)
  if Suite.isProtected(path) then
    die(("REFUSED to %s a protected path: %s\nThis is a bug; nothing was changed.")
      :format(what or "write", path))
  end
end

local function writeRelease(path, content)
  guard(path, "write")
  return writeRaw(path, content)
end

-- ---------------------------------------------------------------- http

local token = nil

local function fetchOnce(url)
  -- CACHE-BUST. raw.githubusercontent.com is served through a CDN (Fastly) that can keep serving a
  -- file for minutes after a push. Left alone, a just-pushed manifest/file is invisible until the
  -- edge TTL expires -- exactly the "Already current" that hid a real update. A unique query string
  -- is a fresh cache key, and no-cache headers ask the edge to revalidate; together the update lands
  -- immediately. GitHub ignores the extra query param and returns the same file.
  local sep = url:find("?", 1, true) and "&" or "?"
  local bustUrl = url .. sep .. "cb=" .. tostring((os.epoch and os.epoch("utc")) or os.time())
  local headers = { ["Cache-Control"] = "no-cache", ["Pragma"] = "no-cache" }
  if token then headers.Authorization = "token " .. token end
  local ok, handle, err = pcall(http.get, bustUrl, headers)
  if not ok then return nil, tostring(handle) end
  if not handle then return nil, tostring(err or "no response") end
  local body = handle.readAll()
  handle.close()
  if body == nil or body == "" then return nil, "empty response" end
  return body
end

--- Two attempts: a single dropped packet should not fail a whole install.
local function fetch(url)
  local body, err = fetchOnce(url)
  if body then return body end
  sleep(1)
  local retry, err2 = fetchOnce(url)
  if retry then return retry end
  return nil, tostring(err2 or err)
end

-- ---------------------------------------------------------------- state

--- Parse the install record. Tolerant: a truncated or hand-mangled file yields nils rather
--- than an error, and the Suite then falls back to detecting the role from what is on disk.
function Suite.parseState(raw)
  raw = raw or ""
  return {
    version = raw:match("version=([%w]+)"),
    schema = tonumber(raw:match("schema=(%d+)")),
    role = raw:match("role=([%w_]+)"),
    at = raw:match("at=([^\n]+)"),
  }
end

function Suite.formatState(state)
  return ("version=%s\nschema=%d\nrole=%s\nat=%s\n"):format(
    tostring(state.version), tonumber(state.schema) or 1,
    tostring(state.role), tostring(state.at or ""))
end

--- Which role do the files on disk look like? Used when the install record is missing or
--- unreadable, which is exactly the corrupt-install case the operator most needs handled.
--- Returns role, matchedCount, totalCount.
function Suite.detectRole(manifest, exists)
  exists = exists or function(p) return fs.exists(p) and not fs.isDir(p) end
  local bestRole, bestScore, bestTotal = nil, 0, 0
  for roleName, spec in pairs(manifest.roles) do
    if spec.status == "released" and #spec.files > 0 then
      local matched = 0
      for _, entry in ipairs(spec.files) do
        if exists("/" .. entry.dst) then matched = matched + 1 end
      end
      -- Prefer the role with the most of its files present; ties go to the larger role, so a
      -- role that is a strict subset of another cannot win by accident.
      if matched > bestScore or (matched == bestScore and matched > 0 and #spec.files > bestTotal) then
        bestRole, bestScore, bestTotal = roleName, matched, #spec.files
      end
    end
  end
  if bestScore == 0 then return nil, 0, 0 end
  return bestRole, bestScore, bestTotal
end

-- ---------------------------------------------------------------- integrity

--- Compare every file of a role against the manifest. Pure enough to test: `read` and `size`
--- are injectable.
--- Returns { ok, missing = {}, corrupt = {}, present = n, total = n }
function Suite.integrity(spec, read)
  read = read or readFile
  local report = { missing = {}, corrupt = {}, present = 0, total = #spec.files }
  for _, entry in ipairs(spec.files) do
    local path = "/" .. entry.dst
    local body = read(path)
    if body == nil then
      report.missing[#report.missing + 1] = entry.dst
    else
      report.present = report.present + 1
      if #body ~= entry.size or Suite.checksum(body) ~= entry.sum then
        report.corrupt[#report.corrupt + 1] = entry.dst
      end
    end
  end
  report.ok = (#report.missing == 0 and #report.corrupt == 0)
  return report
end

-- ---------------------------------------------------------------- backups

local backupDir = nil
local backedUp = {}

local function timestamp()
  local ok, stamp = pcall(os.date, "%Y-%m-%d_%H-%M-%S")
  if ok and type(stamp) == "string" then return stamp end
  return tostring(os.epoch("utc"))
end

local function ensureBackupDir(version)
  if backupDir then return backupDir end
  backupDir = ("%s/%s_%s"):format(BACKUP_ROOT, timestamp(), tostring(version or "manual"))
  fs.makeDir(backupDir)
  return backupDir
end

--- Copy a file into this run's backup folder. Copy, never move: the original stays exactly
--- where it is so a failed run costs nothing.
local function backup(path, version)
  if not fs.exists(path) or fs.isDir(path) then return nil end
  local dir = ensureBackupDir(version)
  local name = path:gsub("^/", ""):gsub("/", "_")
  local target = ("%s/%s"):format(dir, name)
  local body = readFile(path)
  if body == nil then return nil end
  writeRaw(target, body)
  backedUp[#backedUp + 1] = target
  return target
end

-- ---------------------------------------------------------------- config

--- Extend a saved config with any defaults a new release added, in place.
---
--- The role's own Config.withDefaults does the deep merge (lists replaced, maps merged, each
--- thruster/relay entry merged over its template), so this cannot invent semantics of its own:
--- it is the same code path the program itself uses at load time. Which is also why this step
--- is a convenience rather than a guarantee -- the program merges on load regardless.
---
--- Returns one of: "extended" | "fresh" | "absent" | "quarantined" | "skipped: <why>"
function Suite.extendConfig(spec, path, version)
  if not spec.luaPath or spec.luaPath == "" then return "skipped: no lua path" end
  if not fs.exists(path) then return "absent" end

  backup(path, version)

  local ok, result = pcall(function()
    package.path = spec.luaPath .. "/?.lua;" .. spec.luaPath .. "/?/init.lua;" .. package.path
    -- drop any cached copies so the freshly installed modules are the ones used
    package.loaded["lib.config"] = nil
    package.loaded["lib.util"] = nil
    local Config = require("lib.config")

    local cfg, existed, err = Config.load(path)
    if err then return "corrupt" end
    if not existed then return "absent" end

    local saved, saveErr = Config.save(path, cfg)
    if not saved then error(tostring(saveErr), 0) end
    return "extended"
  end)

  if not ok then return "skipped: " .. tostring(result) end

  if result == "corrupt" then
    -- The one case where a config is replaced: it does not parse, so there is nothing to
    -- preserve. It is already backed up above, and the operator is told.
    local ok2 = pcall(function()
      local Config = require("lib.config")
      local fresh = Config.withDefaults({})
      local saved, saveErr = Config.save(path, fresh)
      if not saved then error(tostring(saveErr), 0) end
    end)
    return ok2 and "quarantined" or "skipped: unparseable and could not rewrite"
  end

  return result
end

-- ---------------------------------------------------------------- repair

--- Delete the role's own files so a corrupt install is cleared before reinstalling.
---
--- Scoped to the directories the manifest says the role owns, plus root-level files it ships.
--- Configs live at the root and are not in the file list, so they are structurally out of
--- reach -- and guard() is asserted on every delete anyway.
function Suite.clearRole(spec, dryRun)
  local removed = {}
  for _, dir in ipairs(spec.dirs or {}) do
    local path = "/" .. dir
    if fs.exists(path) and fs.isDir(path) then
      guard(path, "delete")
      if not dryRun then fs.delete(path) end
      removed[#removed + 1] = path .. "/"
    end
  end
  for _, entry in ipairs(spec.files) do
    if not entry.dst:find("/") then          -- a root-level file such as startup.lua
      local path = "/" .. entry.dst
      if fs.exists(path) then
        guard(path, "delete")
        if not dryRun then fs.delete(path) end
        removed[#removed + 1] = path
      end
    end
  end
  return removed
end

--- Decide what this run is: "install" | "repair" | "current" | "update".
---
--- UPDATE AND CORRUPTION LOOK IDENTICAL ON DISK, and the version stamp is what tells them
--- apart. Files differing from a manifest they were never built from is exactly what an update
--- IS -- so treating that as corruption, as this once did, meant the Suite could only ever
--- "fix" a computer and never update one. The files ended up right either way, but it told the
--- operator their install was broken every single time a release shipped.
---
--- It is corruption only when the stamp claims THESE EXACT FILES are already correct and the
--- bytes disagree, or when files are present and nothing on the computer records what they are.
--- MISSING FILES ALONE PROVE NOTHING: a release that adds a module leaves an older install
--- legitimately missing it.
---
--- Pure, so the decision is testable without a network or a filesystem.
function Suite.choosePlan(s)
  if not s.anyInstall then return "install" end
  if s.forceRepair then return "repair" end
  if s.noRecord then return "repair" end
  if s.sameVersion then
    return s.mismatched and "repair" or "current"
  end
  return "update"
end

--- Delete files under the role's own directories that the release no longer ships.
---
--- An update rewrites every file it knows about, but a module the new release DROPPED would
--- otherwise sit there for ever -- invisible to the integrity check, which only looks for the
--- files the manifest lists. Run AFTER the new files are committed, never before: clearing up
--- front would turn a failed download into a destroyed install.
function Suite.pruneRole(spec, dryRun)
  local keep = {}
  for _, entry in ipairs(spec.files) do keep["/" .. entry.dst] = true end

  local removed = {}
  local function walk(dir)
    if not fs.exists(dir) or not fs.isDir(dir) then return end
    for _, name in ipairs(fs.list(dir)) do
      local path = fs.combine(dir, name)
      if not path:match("^/") then path = "/" .. path end
      if fs.isDir(path) then
        walk(path)
      elseif not keep[path] and not Suite.isProtected(path) and not path:find("%" .. STAGE .. "$") then
        guard(path, "delete")
        if not dryRun then fs.delete(path) end
        removed[#removed + 1] = path
      end
    end
  end
  for _, dir in ipairs(spec.dirs or {}) do walk("/" .. dir) end
  return removed
end

-- ---------------------------------------------------------------- role picker

--- How should the role list be laid out on THIS terminal?
---
--- Pure, so tests/test_suite.lua can check it against every terminal size instead of us
--- discovering on a basic computer that the first four roles scrolled off with no way back.
---
--- released/reserved are counts; `height` is the terminal's rows. Returns:
---   mode    "blurbs"  one line per role plus a blurb for the INSTALLABLE ones
---           "compact" one line per role
---           "paged"   one line per role, split across pages
---   perPage how many roles fit on a page (only meaningful for "paged")
function Suite.rolePickerLayout(released, reserved, height)
  local total = released + reserved
  -- Reserved rows: title, blank, blank, prompt, input line.
  local available = math.max(1, (height or 19) - 5)

  -- Blurbs only for the roles you can actually install -- that is where the detail helps, and
  -- it is what makes the list fit on an advanced terminal.
  if (released * 2) + reserved <= available then
    return { mode = "blurbs", perPage = total }
  end
  if total <= available then
    return { mode = "compact", perPage = total }
  end
  -- Paged: one row goes to the "page x/y" footer.
  return { mode = "paged", perPage = math.max(1, available - 1) }
end

--- Exposed so tests can drive the real draw-and-input loop with a stubbed read().
function Suite.askForRole(manifest, order)
  local width, height = term.getSize()

  local choices = {}
  local released, reserved = 0, 0
  for _, name in ipairs(order) do
    if manifest.roles[name] then
      choices[#choices + 1] = name
      if manifest.roles[name].status == "released" then
        released = released + 1
      else
        reserved = reserved + 1
      end
    end
  end
  if #choices == 0 then return nil end

  local layout = Suite.rolePickerLayout(released, reserved, height)
  local pages = math.max(1, math.ceil(#choices / layout.perPage))
  local page = 1

  local function fit(text)
    text = tostring(text)
    if #text > width then return text:sub(1, width) end
    return text
  end

  local function draw()
    -- Start from a clean screen every time. Whatever the Suite printed before this point has
    -- already scrolled, and the operator cannot scroll back in a CC terminal.
    term.clear()
    term.setCursorPos(1, 1)
    colour(colours.cyan)
    print(fit("EasyHover -- which role is this computer?"))

    local first = (page - 1) * layout.perPage + 1
    local last = math.min(#choices, first + layout.perPage - 1)
    for index = first, last do
      local name = choices[index]
      local spec = manifest.roles[name]
      local isReleased = spec.status == "released"
      local line
      if layout.mode == "blurbs" then
        line = ("%d) %s"):format(index, spec.title or name)
      else
        -- name AND title, so a typed answer is obvious too
        line = ("%d) %-9s %s"):format(index, name, spec.title or "")
      end
      if not isReleased then line = line .. " (soon)" end
      say(fit(line), isReleased and colours.white or colours.lightGrey)
      if layout.mode == "blurbs" and isReleased then
        dim(fit("   " .. (spec.blurb or "")))
      end
    end

    if pages > 1 then
      colour(colours.lightGrey)
      print(fit(("page %d/%d -- 'n' next, 'p' previous"):format(page, pages)))
    end
    print("")
    colour(colours.lightGrey)
    print(fit("number or name, blank to cancel"))
    colour(colours.white)
    write("> ")
  end

  while true do
    draw()
    local answer = read()
    if answer == nil or answer == "" then return nil end
    answer = answer:lower():gsub("%s", "")

    if pages > 1 and (answer == "n" or answer == "next") then
      page = page % pages + 1
    elseif pages > 1 and (answer == "p" or answer == "prev" or answer == "previous") then
      page = (page - 2) % pages + 1
    else
      local index = tonumber(answer)
      if index and choices[index] then return choices[index] end
      if manifest.roles[answer] then return answer end
      bad(fit("Not a role: " .. tostring(answer)))
      sleep(1.2)
    end
  end
end

-- ---------------------------------------------------------------- main

function Suite.main(args)
  args = args or {}
  local wantRole, checkOnly, forceRepair, listOnly, fastPath =
    nil, false, false, false, false

  for _, arg in ipairs(args) do
    local a = tostring(arg):lower()
    if a == "--check" or a == "-n" then checkOnly = true
    elseif a == "--verify" then fastPath = false          -- the default; kept for habit
    elseif a == "--fast" then fastPath = true
    elseif a == "--repair" then forceRepair = true
    elseif a == "--list" then listOnly = true
    elseif a == "--help" or a == "-h" then
      say("EasyHover Suite", colours.cyan)
      dim("  easyhover_suite.lua              install or update, as appropriate")
      dim("  easyhover_suite.lua --check      report what would change, write nothing")
      dim("  easyhover_suite.lua --repair     clear the role's files and reinstall")
      dim("  easyhover_suite.lua --fast       trust the version stamp, skip checksums")
      dim("  easyhover_suite.lua --list       list every role")
      dim("  easyhover_suite.lua <role>       install or switch to a role")
      print("")
      dim("Source override: put a base URL in " .. SOURCE_FILE)
      dim("Private repo:    put a GitHub token in " .. TOKEN_FILE)
      return true
    elseif a:sub(1, 2) == "--" then
      die("unknown option: " .. tostring(arg))
    else
      wantRole = a
    end
  end

  -- ---- where to fetch from
  local base = readFile(SOURCE_FILE)
  base = base and base:gsub("%s+$", ""):gsub("/+$", "") or nil
  if base == "" then base = nil end
  base = base or DEFAULT_BASE

  token = readFile(TOKEN_FILE)
  token = token and token:gsub("%s+$", "") or nil
  if token == "" then token = nil end

  say("EasyHover Suite", colours.cyan)
  dim("source: " .. base .. (token and "  (token)" or ""))
  print("")

  if not http then
    die("The http API is disabled on this server, so nothing can be fetched.\n"
      .. "Ask the server owner to enable http, or install from a floppy disk.")
  end

  -- ---- the release manifest
  local body, err = fetch(base .. "/manifest.lua")
  if not body then
    bad("could not reach the release manifest: " .. tostring(err))
    print("")
    dim("If the repository is private, raw.githubusercontent.com returns 404 without a")
    dim("token. Put one in " .. TOKEN_FILE .. ", or make the repository public.")
    die("nothing was changed.")
  end

  -- Parsed as DATA, not run as code: unserialise evaluates a table constructor in an empty
  -- environment, so the manifest cannot do anything but describe files.
  local manifest = textutils.unserialise(body)
  if type(manifest) ~= "table" or type(manifest.roles) ~= "table" or not manifest.version then
    die("the release manifest is not readable (is the source URL right?)")
  end

  local order = {}
  for name in pairs(manifest.roles) do order[#order + 1] = name end
  table.sort(order, function(a, b)
    local ra, rb = manifest.roles[a], manifest.roles[b]
    local sa = (ra.status == "released") and 0 or 1
    local sb = (rb.status == "released") and 0 or 1
    if sa ~= sb then return sa < sb end
    return a < b
  end)

  if listOnly then
    say(("release %s, schema %d"):format(manifest.version, manifest.schema or 1))
    print("")
    for _, name in ipairs(order) do
      local spec = manifest.roles[name]
      local tag = (spec.status == "released")
        and ("%d file(s)"):format(#spec.files) or "not released yet"
      say(("  %-9s %-26s %s"):format(name, spec.title or "", tag),
        spec.status == "released" and colours.white or colours.lightGrey)
    end
    colour(colours.white)
    return true
  end

  -- ---- what is installed here
  local state = Suite.parseState(readFile(STATE_FILE))
  local detected, detectedMatched, detectedTotal = Suite.detectRole(manifest)

  local role = wantRole or state.role or detected
  if role and not manifest.roles[role] then
    die("no such role: " .. tostring(role) .. "  (try --list)")
  end

  if not role then
    role = Suite.askForRole(manifest, order)
    if not role then
      warn("Cancelled. Nothing was changed.")
      return false
    end
  end

  local spec = manifest.roles[role]

  if spec.status ~= "released" then
    warn(("The '%s' role (%s) is reserved in the design but ships no files yet.")
      :format(role, spec.title or role))
    dim("Nothing was installed. Re-run the Suite once it is released.")
    dim("Its config will be at: " .. table.concat(spec.configs or {}, ", "))
    return false
  end

  say(("role %s  (%s)"):format(role, spec.title or role))
  if state.role and state.role ~= role then
    warn(("switching role: %s -> %s"):format(state.role, role))
  end
  if not state.role and detected then
    dim(("no install record; detected %s from %d/%d files on disk")
      :format(detected, detectedMatched, detectedTotal))
  end
  dim(("installed %s -> release %s"):format(state.version or "unknown", manifest.version))

  -- ---- integrity
  local switching = (state.role ~= nil and state.role ~= role)
  local sameVersion = (state.version == manifest.version) and not switching

  -- ALWAYS checksum, unless explicitly asked not to.
  --
  -- A version stamp says "these files were correct when they were written". It cannot know
  -- that one has since been truncated by a chunk unload, hand-edited, or half-overwritten.
  -- Detecting exactly that is a core job of this tool, so trusting the stamp by default would
  -- defeat the point -- and the cost is reading a few hundred KB locally, with no network.
  -- `--fast` exists for anyone who wants the old behaviour.
  local report
  if fastPath and sameVersion then
    report = { ok = true, missing = {}, corrupt = {}, present = #spec.files, total = #spec.files }
    dim("--fast: version matches, checksums skipped")
  else
    report = Suite.integrity(spec)
    if report.ok and sameVersion then dim("all " .. report.total .. " file(s) verified") end
  end

  local anyInstall = (report.present > 0)
  local fresh = not anyInstall
  local mismatched = not report.ok
  local noRecord = (state.version == nil)
  local corrupt = anyInstall and ((sameVersion and mismatched) or noRecord)
  local plan = Suite.choosePlan({
    anyInstall = anyInstall, mismatched = mismatched,
    sameVersion = sameVersion, noRecord = noRecord, forceRepair = forceRepair,
  })

  print("")
  if plan == "install" then
    good("Fresh install.")
  elseif plan == "repair" then
    if noRecord then
      bad("Broken install: files are here but nothing records what they are.")
    else
      bad(("Broken install: version %s says these files are correct, but %d missing "
        .. "and %d differ of %d."):format(tostring(state.version), #report.missing,
        #report.corrupt, report.total))
    end
    for _, name in ipairs(report.missing) do dim("  missing  " .. name) end
    for _, name in ipairs(report.corrupt) do dim("  corrupt  " .. name) end
    say("Repairing: the role's own files will be cleared and reinstalled.")
    say("Configs are backed up first and never deleted.", colours.lime)
  elseif plan == "current" then
    good("Already current: " .. manifest.version)
  else
    say(("Update available: %s -> %s"):format(state.version or "unknown", manifest.version))
    dim(("%d new, %d changed, %d unchanged"):format(#report.missing, #report.corrupt,
      report.total - #report.missing - #report.corrupt))
  end

  local schemaBump = (state.schema ~= nil and (manifest.schema or 1) > state.schema)
  if schemaBump then
    warn(("Config schema %d -> %d: saved configs will be backed up before anything changes.")
      :format(state.schema, manifest.schema or 1))
  end

  -- ---- dry run stops here
  if checkOnly then
    print("")
    if plan == "current" then
      dim("Nothing to do.")
    else
      say(("Would %s role '%s': %d file(s)."):format(plan, role, #spec.files))
      local cleared = (plan == "repair") and Suite.clearRole(spec, true) or {}
      for _, path in ipairs(cleared) do dim("  would clear  " .. path) end
      for _, cfgPath in ipairs(spec.configs or {}) do
        if fs.exists(cfgPath) then dim("  would back up and extend  " .. cfgPath) end
      end
    end
    dim("--check: nothing was written.")
    colour(colours.white)
    return true
  end

  if plan == "current" then
    -- Still worth checking whether the Suite itself is stale.
    Suite.selfUpdateNotice(base, manifest)
    colour(colours.white)
    return true
  end

  -- ---- back up configs BEFORE touching anything
  for _, cfgPath in ipairs(spec.configs or {}) do
    if fs.exists(cfgPath) then
      local target = backup(cfgPath, manifest.version)
      if target then dim("backed up " .. cfgPath) end
    end
  end

  -- ---- clear a broken install (never configs)
  if plan == "repair" then
    local cleared = Suite.clearRole(spec, false)
    for _, path in ipairs(cleared) do dim("cleared " .. path) end
  end

  -- ---- stage: download and verify EVERYTHING before moving anything into place
  print("")
  say(("Fetching %d file(s)..."):format(#spec.files))
  local staged = {}

  local function discardStaged()
    for _, item in ipairs(staged) do
      if fs.exists(item.stage) then fs.delete(item.stage) end
    end
  end

  for index, entry in ipairs(spec.files) do
    local url = ("%s/%s"):format(base, entry.src)
    local content, fetchErr = fetch(url)
    if not content then
      discardStaged()
      die(("failed on %s (%s)\nNothing was changed; the install is as it was.")
        :format(entry.src, tostring(fetchErr)))
    end
    -- GitHub raw serves what is committed; a proxy that rewrites line endings would show up
    -- here as a size mismatch rather than as a mysterious runtime error later.
    if #content ~= entry.size or Suite.checksum(content) ~= entry.sum then
      discardStaged()
      die(("%s arrived corrupt (expected %d bytes / %s, got %d / %s)\nNothing was changed.")
        :format(entry.src, entry.size, entry.sum, #content, Suite.checksum(content)))
    end
    local stagePath = "/" .. entry.dst .. STAGE
    guard("/" .. entry.dst, "write")
    if not writeRaw(stagePath, content) then
      discardStaged()
      die("could not write " .. stagePath .. " (disk full?)\nNothing was changed.")
    end
    staged[#staged + 1] = { stage = stagePath, final = "/" .. entry.dst, dst = entry.dst }
    if index % 5 == 0 or index == #spec.files then
      dim(("  %d/%d"):format(index, #spec.files))
    end
  end

  -- ---- commit: every file arrived intact, so move them all into place
  for _, item in ipairs(staged) do
    guard(item.final, "replace")
    if fs.exists(item.final) then fs.delete(item.final) end
    fs.move(item.stage, item.final)
  end
  good(("Installed %d file(s)."):format(#staged))

  -- ---- configs: extend with any newly added defaults, in place
  print("")
  for _, cfgPath in ipairs(spec.configs or {}) do
    local result = Suite.extendConfig(spec, cfgPath, manifest.version)
    if result == "extended" then
      good(("config extended with new defaults: %s"):format(cfgPath))
    elseif result == "quarantined" then
      warn(("config %s would not parse: backed up and replaced with defaults"):format(cfgPath))
    elseif result == "absent" then
      dim(("no config yet at %s (it is created on first run)"):format(cfgPath))
    else
      dim(("config %s: %s"):format(cfgPath, result))
    end
  end

  -- ---- drop anything this release no longer ships (after the new files are safely in place)
  local pruned = Suite.pruneRole(spec, false)
  for _, path in ipairs(pruned) do dim("removed " .. path .. " (no longer shipped)") end

  -- ---- record what is now installed
  writeRaw(STATE_FILE, Suite.formatState({
    version = manifest.version,
    schema = manifest.schema or 1,
    role = role,
    at = timestamp(),
  }))

  print("")
  if #backedUp > 0 then
    warn(("%d file(s) backed up in %s"):format(#backedUp, backupDir))
  end
  good(("Now at %s as role '%s'."):format(manifest.version, role))
  if spec.entry ~= "" then
    if #staged > 0 and not fresh then
      -- THIS COMPUTER IS STILL RUNNING THE OLD CODE. CC loads a program once; new files on
      -- disk do nothing until something starts them. Updating a running cockpit and then
      -- wondering why the new buttons do not work is exactly what happens without this line,
      -- so it is a warning rather than a dim hint.
      warn("REBOOT THIS COMPUTER -- it is still running the old version.")
      dim("  reboot     (or run: " .. spec.entry .. ")")
    else
      dim("Reboot to run it, or: " .. spec.entry)
    end
  end

  Suite.selfUpdateNotice(base, manifest)
  colour(colours.white)
  return true
end

--- Is the Suite itself current? If not, fetch the new one now -- we are done with our own file
--- by this point, so replacing it is safe, and the next run uses it.
function Suite.selfUpdateNotice(base, manifest)
  if type(manifest.updater) ~= "table" then return end
  local ok, selfPath = pcall(shell.getRunningProgram)
  if not ok or type(selfPath) ~= "string" or selfPath == "" then
    selfPath = "easyhover_suite.lua"
  end
  if not selfPath:match("^/") then selfPath = "/" .. selfPath end

  local mine = readFile(selfPath)
  if mine == nil then return end
  if #mine == manifest.updater.size and Suite.checksum(mine) == manifest.updater.sum then
    return
  end

  -- Dim, not yellow. This is a routine step that then SUCCEEDS, and a warning colour at the
  -- very end of a clean install reads as "something is wrong" -- which is how it was reported.
  -- The warning colours below are for the cases that actually leave the Suite stale.
  print("")
  dim("The Suite itself is out of date; fetching the new one.")
  local body = fetch(base .. "/easyhover_suite.lua")
  if not body then
    warn("could not fetch the new Suite. Update by hand with:")
    dim("  wget " .. base .. "/easyhover_suite.lua easyhover_suite.lua")
    return
  end
  if #body ~= manifest.updater.size or Suite.checksum(body) ~= manifest.updater.sum then
    -- The PUBLISHED Suite does not match the stamp in the PUBLISHED manifest, so the release
    -- is inconsistent -- nothing is wrong with this computer. Saying "arrived corrupt" pointed
    -- the blame the wrong way, and because the local copy can never match either, every single
    -- run repeated the whole dance. Name the real fault so it is fixable at the source.
    warn("release inconsistency: the published Suite does not match the manifest.")
    dim(("  manifest expects %d bytes / %s, the server sent %d / %s")
      :format(manifest.updater.size, tostring(manifest.updater.sum), #body,
        tostring(Suite.checksum(body))))
    dim("  the role's files are fine; regenerate the manifest at the source.")
    return
  end
  local stagePath = selfPath .. STAGE
  if writeRaw(stagePath, body) then
    if fs.exists(selfPath) then fs.delete(selfPath) end
    fs.move(stagePath, selfPath)
    good("Suite updated. The next run uses the new one.")
  end
end

-- Exposed so tests can exercise the pure logic without running an install.
if not _G.EASYHOVER_SUITE_NO_RUN then
  Suite.main({ ... })
end

return Suite
