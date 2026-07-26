#!/usr/bin/env bash
# End-to-end test of easyhover_suite.lua against a LOCALHOST MIRROR of the repo.
#
#   bash tests/run_suite_e2e.sh
#
# This is the test that actually proves the Suite: it really fetches, really stages, really
# commits, really repairs, and really extends configs. Serving the repo from python instead of
# GitHub keeps it fast, offline and independent of the repository's visibility.
#
# Needs: CraftOS-PC (console build), python, curl.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
CRAFTOS="/c/Program Files/CraftOS-PC/CraftOS-PC_console.exe"
WORK="$HERE/.craftos/suite_e2e"
DATA="$WORK/data"
C0="$DATA/computer/0"

command -v python >/dev/null || { echo "python is required to serve the mirror"; exit 1; }

# ---------- serve the repo ----------
PORT="${EASYHOVER_E2E_PORT:-8753}"
port_free() { ! (curl -fsS --max-time 1 "http://127.0.0.1:$1/" -o /dev/null 2>/dev/null); }
for _ in $(seq 1 20); do port_free "$PORT" && break; PORT=$((PORT + 1)); done

python -m http.server "$PORT" --directory "$ROOT" --bind 127.0.0.1 >/dev/null 2>&1 &
SERVER_PID=$!
cleanup() { kill "$SERVER_PID" >/dev/null 2>&1 || true; }
trap cleanup EXIT

for _ in $(seq 1 40); do
  curl -fsS --max-time 2 "http://127.0.0.1:$PORT/manifest.lua" -o /dev/null 2>/dev/null && break
  sleep 0.25
done
curl -fsS --max-time 2 "http://127.0.0.1:$PORT/manifest.lua" -o /dev/null 2>/dev/null \
  || { echo "could not serve the mirror on port $PORT"; exit 1; }
MIRROR="http://127.0.0.1:$PORT"
echo "mirror: $MIRROR"
echo ""

# ---------- lay out a bare computer ----------
lay_out_computer() {
  rm -rf "$WORK"
  mkdir -p "$C0" "$DATA/config"
  # CraftOS-PC blocks private ranges by default; allow localhost.
  printf '{ "http_enable": true, "http_whitelist": ["*"], "http_blacklist": [] }' \
    > "$DATA/config/global.json"
  cp "$ROOT/easyhover_suite.lua" "$C0/easyhover_suite.lua"
  printf '%s' "$MIRROR" > "$C0/easyhover_suite_src.txt"
  # the probe compares the install record against the release it was served
  cp "$ROOT/manifest.lua" "$C0/mirror_manifest.lua"
}
lay_out_computer

# Phases that need a BARE computer rather than the aged one the chain has been building. A
# second role cannot be tested on top of the first: installing ui_main over flight is a role
# CHANGE, which is a different operation from the fresh install a pilot actually performs.
FRESH_PHASES=" uimain beacon "

FAILED=0
run_phase() {
  local phase="$1"
  [[ "$FRESH_PHASES" == *" $phase "* ]] && lay_out_computer
  printf '%s' "$phase" > "$C0/pc_phase.txt"
  cp "$ROOT/tests/suite_probe.lua" "$C0/e2e_probe.lua"
  rm -f "$C0/pc_result.txt"
  # --script, NOT /startup.lua: the Suite installs its own startup.lua, and overwriting it
  # would make the probe itself a modified release file -- which the Suite would then
  # correctly report as a corrupt install. That test artefact looks exactly like a real bug.
  timeout 180 "$CRAFTOS" --headless -d "$DATA" --script "$C0/e2e_probe.lua" >/dev/null 2>&1 || true
  if [[ -f "$C0/pc_result.txt" ]]; then
    cat "$C0/pc_result.txt"
    grep -q "FAIL" "$C0/pc_result.txt" && FAILED=$((FAILED + 1))
  else
    echo "=== $phase === NO RESULT (hung or crashed)"
    FAILED=$((FAILED + 1))
  fi
  echo ""
}

# Order matters: each phase builds on the computer the previous one left behind, which is
# exactly how a real install ages. Iterating on one phase is much faster than the whole chain:
#   EASYHOVER_E2E_PHASES="install badconfig" bash tests/run_suite_e2e.sh
# `install` is a prerequisite for every later phase, so keep it first in any subset.
# `uimain` is last because it wipes the computer: it is a fresh install of the OTHER released
# role, which nothing else here covers.
ALL_PHASES="install current configkeep repair badconfig detect protect check prepared uimain beacon"
PHASES="${EASYHOVER_E2E_PHASES:-$ALL_PHASES}"
[[ "$PHASES" != "$ALL_PHASES" ]] && echo "(limited to: $PHASES)" && echo ""

for phase in $PHASES; do
  run_phase "$phase"
done

if [[ $FAILED -gt 0 ]]; then
  echo "FAILED: $FAILED phase(s)"
  exit 1
fi
echo "PASS: suite e2e green ($MIRROR)"
