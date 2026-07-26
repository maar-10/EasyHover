#!/usr/bin/env bash
# Headless smoke test for tools/probe.lua against mocked peripherals.
# Verifies the probe parses, runs end to end, and reports the values we expect.
#
# Requires the CraftOS-PC *console* build (the GUI exe returns no stdout).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
CRAFTOS="/c/Program Files/CraftOS-PC/CraftOS-PC_console.exe"
DATA="$HERE/.craftos/probe"
C0="$DATA/computer/0"

rm -rf "$DATA"
mkdir -p "$C0/tools" "$C0/tests/mocks"
cp "$ROOT/tools/probe.lua" "$C0/tools/probe.lua"
cp "$ROOT/tests/mocks/peripherals.lua" "$C0/tests/mocks/peripherals.lua"

cat > "$C0/startup.lua" <<'LUA'
package.path = "/?.lua;/?/init.lua;" .. package.path

local ok, err = pcall(function()
  local mock = dofile("/tests/mocks/peripherals.lua")
  -- must patch _G: CC sandboxes program envs, so a local would be invisible to the probe
  _G.peripheral = mock.install()
  _G.EASYHOVER_PROBE = {
    REPORT = "/probe_report.txt",
    SAMPLES = 6,
    SLEW_TIMEOUT = 2.0,
    CALL_COUNT = 5,
    SETTLE = 0.2,
    CONTROLLER_MS = 600,
    TYPEWRITER_MS = 400,
    YAW_MS = 800,
    GPS_TIMEOUT = 1,
  }
  -- dofile, not shell.run: shell.run swallows the error, and the probe needs no
  -- require/package injection.
  dofile("/tools/probe.lua")
end)

local f = fs.open("/results.txt", "w")
if ok then
  f.write("PROBE_RAN_OK\n")
else
  f.write("PROBE_ERROR: " .. tostring(err) .. "\n")
end
f.close()
os.shutdown()
LUA

timeout 90 "$CRAFTOS" --headless -d "$DATA" >/dev/null 2>&1

RESULTS="$C0/results.txt"
REPORT="$C0/probe_report.txt"

if [[ ! -f "$RESULTS" ]]; then
  echo "FAIL: no results.txt -- CraftOS-PC did not complete"
  exit 1
fi

echo "---- harness ----"
cat "$RESULTS"

if grep -q "PROBE_ERROR" "$RESULTS"; then
  echo "FAIL: probe raised an error"
  exit 1
fi

if [[ ! -f "$REPORT" ]]; then
  echo "FAIL: probe_report.txt was not written"
  exit 1
fi

echo "---- probe report ----"
cat "$REPORT"

fails=0
check() { # description, pattern
  if grep -qE "$2" "$REPORT"; then
    echo "  ok   : $1"
  else
    echo "  FAIL : $1  (expected /$2/)"
    fails=$((fails + 1))
  fi
}

echo "---- assertions ----"
check "peripherals enumerated"            "vector_thruster_0 +vector_thruster"
check "method list dumped"                "setVector"
check "gimbal shape reported"             "element count=2"
check "altitude sampled"                  "getHeight .*first=74\.5"
check "optical block id reported"         "minecraft:grass_block"
check "thruster state listed"             "vector_thruster_0 .*power=0"
check "slew measured, not skipped"        "RESULT: +0 -> 1 in [0-9]+ ms"
check "mainThread cost measured"          "ms/call"
check "controller axis 1 span found"      "axis 1 +min=-?[0-9]"
check "typewriter poll produced keys"     "key codes seen: .*\(w\)"
check "gimbal element count identified"   "getAngles\(\) -- 2 element\(s\)"
check "two-element warning fired"         "PITCH and ROLL only"
check "nav table angle tracked"           "relative angle +min=132"
check "gps probed"                        "gps.locate +: (FIX|no fix)"
check "radar position read"               "getPosition +: \{.*x=128\.5"
check "radar tracks read"                 "getTracks +: 1 track"
check "beacon nav detected"               "getClosestDistance = 17\.5"
check "laser altimeter counted"           "laser alt +: 1 optical_sensor"
check "unknown peripheral surfaced"       "vista:view_finder"
check "report reached the end"            "=== done ==="

if [[ $fails -gt 0 ]]; then
  echo "FAILED: $fails assertion(s)"
  exit 1
fi
echo "PASS: probe smoke test green"
