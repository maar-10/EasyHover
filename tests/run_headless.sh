#!/usr/bin/env bash
# EasyHover headless unit suite (CraftOS-PC console build).
#   bash tests/run_headless.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
CRAFTOS="/c/Program Files/CraftOS-PC/CraftOS-PC_console.exe"
DATA="$HERE/.craftos/unit"
C0="$DATA/computer/0"

rm -rf "$DATA"
mkdir -p "$C0"
cp -r "$ROOT/flight" "$C0/flight"
mkdir -p "$C0/tests/mocks"
cp "$ROOT/tests/util.lua" "$C0/tests/util.lua"
cp "$ROOT/tests/sim.lua" "$C0/tests/sim.lua"
cp "$ROOT/tests/mocks/peripherals.lua" "$C0/tests/mocks/peripherals.lua"
for f in "$ROOT"/tests/test_*.lua; do cp "$f" "$C0/tests/"; done

cat > "$C0/startup.lua" <<'LUA'
package.path = "/flight/?.lua;/flight/?/init.lua;/?.lua;/?/init.lua;" .. package.path

local SUITES = { "/tests/test_core.lua", "/tests/test_io.lua", "/tests/test_control.lua", "/tests/test_loops.lua", "/tests/test_modes.lua", "/tests/test_input.lua" }

local out = {}
local function w(line) out[#out + 1] = line end

local T = require("tests.util")

-- CC only injects require/package into SHELL-RUN programs, so dofile() would run each
-- suite in a bare env with require == nil. shell.run would work but swallows the error.
-- So: load the source with an env that inherits _G and carries require/package through.
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

timeout 120 "$CRAFTOS" --headless -d "$DATA" >/dev/null 2>&1

RESULTS="$C0/results.txt"
if [[ ! -f "$RESULTS" ]]; then
  echo "FAIL: no results.txt -- CraftOS-PC did not complete"
  exit 1
fi

cat "$RESULTS"

if grep -q "SUITE_PASS" "$RESULTS"; then
  exit 0
fi
echo
echo "FAILED -- see the FAIL / LOAD_ERROR lines above"
exit 1
