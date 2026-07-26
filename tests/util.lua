--[[ Minimal test framework.

     Deliberately tiny: no dependencies, no output formatting beyond what the harness
     greps for, and every failure carries its own message so a red line in the report is
     actionable without opening the test.
]]

local T = {}

T.results = { passed = 0, failed = 0, lines = {}, suite = "?" }

local function record(ok, name, detail)
  if ok then
    T.results.passed = T.results.passed + 1
    T.results.lines[#T.results.lines + 1] = ("  ok   %s"):format(name)
  else
    T.results.failed = T.results.failed + 1
    T.results.lines[#T.results.lines + 1] = ("  FAIL %s -- %s"):format(name, detail or "?")
  end
end

function T.suite(name)
  T.results.suite = name
  T.results.lines[#T.results.lines + 1] = ("== %s =="):format(name)
end

--- Run one case. Assertion failures inside are caught and reported, not fatal.
function T.it(name, fn)
  local ok, err = pcall(fn)
  record(ok, name, ok and nil or tostring(err))
end

local function fail(msg)
  error(msg, 3)
end

function T.eq(actual, expected, what)
  if actual ~= expected then
    fail(("%s: expected %s, got %s"):format(what or "value", tostring(expected), tostring(actual)))
  end
end

function T.near(actual, expected, tol, what)
  tol = tol or 1e-6
  if type(actual) ~= "number" then
    fail(("%s: expected a number near %s, got %s"):format(what or "value", tostring(expected), tostring(actual)))
  end
  if math.abs(actual - expected) > tol then
    fail(("%s: expected %s +/- %s, got %s"):format(what or "value", tostring(expected), tostring(tol), tostring(actual)))
  end
end

function T.isTrue(v, what)
  if not v then fail(("%s: expected truthy, got %s"):format(what or "value", tostring(v))) end
end

function T.isFalse(v, what)
  if v then fail(("%s: expected falsy, got %s"):format(what or "value", tostring(v))) end
end

function T.isNil(v, what)
  if v ~= nil then fail(("%s: expected nil, got %s"):format(what or "value", tostring(v))) end
end

function T.notNil(v, what)
  if v == nil then fail(("%s: expected non-nil"):format(what or "value")) end
end

--- Assert a list of strings contains one matching `pattern`.
function T.containsMatch(list, pattern, what)
  for _, s in ipairs(list or {}) do
    if type(s) == "string" and s:find(pattern) then return s end
  end
  fail(("%s: no entry matching /%s/ in {%s}"):format(
    what or "list", pattern, table.concat(list or {}, " | ")))
end

function T.noMatch(list, pattern, what)
  for _, s in ipairs(list or {}) do
    if type(s) == "string" and s:find(pattern) then
      fail(("%s: unexpected entry matching /%s/: %s"):format(what or "list", pattern, s))
    end
  end
end

function T.report()
  local header = ("%s: %d passed, %d failed"):format(
    T.results.suite, T.results.passed, T.results.failed)
  return header, T.results.lines, T.results.failed == 0
end

return T
