#!/usr/bin/env bash
# Static checks on the EasyHover Suite and its manifest. Fast -- no CraftOS, no network.
#
#   bash tests/run_suite.sh
#
# The Suite's runtime logic is unit-tested in tests/test_suite.lua (run by
# tests/run_headless.sh) and exercised for real by tests/run_suite_e2e.sh.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
cd "$ROOT"

fails=0
pass() { echo "  ok   $1"; }
fail() { echo "  FAIL $1${2:+  -- $2}"; fails=$((fails + 1)); }

echo "== manifest =="

# 1. Is the committed manifest in sync with the files on disk?
if out=$(node tools/gen_manifest.js --check 2>&1); then
  pass "manifest.lua is in sync with the working tree"
else
  fail "manifest.lua is out of sync" "$out"
fi

# 2. Every file the manifest ships must actually exist.
missing=0
while read -r src; do
  [[ -z "$src" ]] && continue
  [[ -f "$ROOT/$src" ]] || { fail "manifest references a missing file" "$src"; missing=1; }
done < <(grep -oE '\["src"\] = "[^"]+"' manifest.lua | sed 's/.*= "//; s/"$//' | sort -u)
[[ $missing -eq 0 ]] && pass "every file the manifest ships exists on disk"

# 3. The manifest must be DATA: no executable constructs.
if grep -qE '^\s*(return|function|require|os\.|fs\.|http\.)' manifest.lua; then
  fail "manifest.lua contains executable-looking constructs"
else
  pass "manifest.lua is a plain data table"
fi

# 4. It must start with a comment block and then a table constructor.
if head -20 manifest.lua | grep -q '^{'; then
  pass "manifest.lua opens a table constructor"
else
  fail "manifest.lua does not look like a table constructor"
fi

echo ""
echo "== checksum agreement (Lua vs JS) =="

# The two implementations must agree byte for byte, or every computer would think every file
# had changed. The Lua side asserts these same values in tests/test_suite.lua.
selftest=$(node tools/gen_manifest.js --selftest 2>&1)
check_hash() {
  local key="$1" expected="$2"
  local actual
  actual=$(echo "$selftest" | grep "^$key=" | cut -d= -f2)
  if [[ "$actual" == "$expected" ]]; then
    pass "JS fnv1a($key) = $expected"
  else
    fail "JS fnv1a($key)" "expected $expected, got ${actual:-nothing}"
  fi
  if grep -q "\"$expected\"" "$ROOT/tests/test_suite.lua"; then
    pass "and tests/test_suite.lua asserts the same value on the Lua side"
  else
    fail "tests/test_suite.lua does not assert $expected" "the cross-check is not wired up"
  fi
}
check_hash empty 811c9dc5
check_hash a e40c292c
check_hash hello 4f9f2cab

echo ""
echo "== suite source =="

# 5. The Suite must be loadable as a module without running an install.
if grep -q "EASYHOVER_SUITE_NO_RUN" easyhover_suite.lua; then
  pass "the Suite has a no-run guard so it can be unit-tested"
else
  fail "the Suite always runs on load" "tests could not require it safely"
fi

# 6. Every write path must go through the guard.
if grep -q "local function guard" easyhover_suite.lua \
  && grep -q "guard(path, \"write\")" easyhover_suite.lua; then
  pass "writes are guarded against protected paths"
else
  fail "the write guard is missing"
fi

# 7. Deletes must be guarded too -- that is what protects configs during a repair.
if grep -q 'guard(path, "delete")' easyhover_suite.lua; then
  pass "deletes are guarded against protected paths"
else
  fail "deletes are not guarded" "a repair could cost the operator their config"
fi

# 8. Staging must exist, or an interrupted update would half-overwrite the install.
if grep -q 'local STAGE = "%.ehnew"' easyhover_suite.lua \
  || grep -q 'local STAGE = ".ehnew"' easyhover_suite.lua; then
  pass "downloads are staged before being committed"
else
  fail "no staging suffix found"
fi

echo ""
if [[ $fails -gt 0 ]]; then
  echo "FAILED: $fails check(s)"
  exit 1
fi
echo "PASS: suite static checks green"
