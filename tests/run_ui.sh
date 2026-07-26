#!/usr/bin/env bash
# ui_main suite, in its OWN CraftOS instance.
#
#   bash tests/run_ui.sh
#
# Separate from run_headless.sh on purpose: both roles have a lib/config.lua, so a shared Lua
# state would make require("lib.config") ambiguous -- and it would resolve to the flight one.
# Different computers in game, different interpreters here.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
CRAFTOS="/c/Program Files/CraftOS-PC/CraftOS-PC_console.exe"
DATA="$HERE/.craftos/ui"
C0="$DATA/computer/0"

rm -rf "$DATA"
mkdir -p "$C0/tests/mocks"
cp -r "$ROOT/ui_main" "$C0/ui_main"
cp -r "$ROOT/shared" "$C0/shared"
# Basalt installs at /basalt.lua on a real ui_main computer, so require("basalt") resolves.
cp "$ROOT/vendor/basalt-full.lua" "$C0/basalt.lua"
cp "$ROOT/tests/util.lua" "$C0/tests/util.lua"
cp "$ROOT/tests/mocks/peripherals.lua" "$C0/tests/mocks/peripherals.lua"
cp "$ROOT/tests/test_ui.lua" "$C0/tests/test_ui.lua"

cat > "$C0/startup.lua" <<'LUA'
package.path = "/ui_main/?.lua;/ui_main/?/init.lua;/?.lua;/?/init.lua;" .. package.path

local SUITES = { "/tests/test_ui.lua" }

local out = {}
local function w(line) out[#out + 1] = line end

local T = require("tests.util")

local function runSuite(path)
  local handle = fs.open(path, "r")
  if not handle then return false, "cannot open " .. path end
  local src = handle.readAll()
  handle.close()
  local env = setmetatable({ require = require, package = package }, { __index = _G })
  local fn, loadErr = load(src, path, "t", env)
  if not fn then return false, loadErr end
  return pcall(fn)
end

for _, path in ipairs(SUITES) do
  local ok, err = runSuite(path)
  if not ok then
    w(("LOAD_ERROR %s: %s"):format(path, tostring(err)))
    T.results.failed = T.results.failed + 1
  end
end

for _, line in ipairs(T.results.lines) do w(line) end
w(("TOTAL: %d passed, %d failed"):format(T.results.passed, T.results.failed))
w(T.results.failed == 0 and "SUITE_PASS" or "SUITE_FAIL")

local f = fs.open("/results.txt", "w")
f.write(table.concat(out, "\n") .. "\n")
f.close()
os.shutdown()
LUA

timeout 180 "$CRAFTOS" --headless -d "$DATA" >/dev/null 2>&1

RESULTS="$C0/results.txt"
if [[ ! -f "$RESULTS" ]]; then
  echo "FAIL: no results.txt -- CraftOS-PC did not complete"
  exit 1
fi

cat "$RESULTS"
grep -q "SUITE_PASS" "$RESULTS" && exit 0
echo
echo "FAILED -- see the FAIL / LOAD_ERROR lines above"
exit 1
