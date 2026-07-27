# Installing and updating — the EasyHover Suite

One file does everything: install, role selection, update, repair, and config handling.

```
wget run https://raw.githubusercontent.com/maar-10/EasyHover/main/easyhover_suite.lua
```

Run it with no arguments and it works out what to do.

| Situation | What it does |
|---|---|
| Bare computer | Asks which role this computer should be, then installs it |
| A role installed, release newer | Updates it, fetching only the files that differ |
| A role installed, already current | Says so and stops |
| **A broken install** | Detects it, clears the role's own files, reinstalls |
| No install record but role files present | Works the role out from what is on disk |

```
easyhover_suite.lua              install or update, as appropriate
easyhover_suite.lua --check      report what would change; write nothing
easyhover_suite.lua --repair     clear the role's files and reinstall
easyhover_suite.lua --fast       trust the version stamp, skip the checksums
easyhover_suite.lua --list       list every role
easyhover_suite.lua <role>       install or switch to a role
```

## Roles

| Role | Status | What it is |
|---|---|---|
| **flight** | **released** | Thrusters, sensors, pilot inputs, PID loops. One per craft, no UI. |
| **ui_main** | **released** | Cockpit screens: the overhead engine + fuel panel and the configuration screens. Drives every assigned monitor. |
| **nav** | **released** | Position fixing over GPS, waypoints, and the fix relay onto the craft's cable. Its own computer, with **an ender modem AND a wired one**. |
| **gps_beacon** | **released** | One of four world-anchored GPS hosts. Runs on a basic computer, keyboard-driven. See [GPS.md](GPS.md). |
| ui_pfd | reserved | Attitude / flight-path indicator. |
| ui_prox | reserved | Laser proximity warnings. |
| ui_aux | reserved | Lights, doors, landing gear. |
| music | reserved | Search, playlists, DFPWM streaming. |
| ground | reserved | Ender-modem telemetry receiver. |

A reserved role is in the design and has its directory, config paths and install machinery
ready, but ships no files yet. Choosing one tells you so plainly rather than pretending an
empty install succeeded.

**Note on the autopilot:** it does *not* get its own computer. Guidance runs **on the flight
computer** — it is about 1 Hz of pure maths, and putting it there keeps the fast loops local
and lets it degrade safely. The **nav** computer owns the waypoint database, the map UI and
position fixing (`gps.locate` blocks; `radar.getPosition` costs a server tick — neither belongs
in the flight loop). Reasoning in [NAVIGATION.md](NAVIGATION.md) §4.

## What it guarantees

**It checksums every file, every run.** A version stamp only says the files were correct when
they were written — it cannot know one has since been truncated by a chunk unload or
hand-edited. Finding that is the whole job, so it is the default and costs no network. `--fast`
opts out.

**All or nothing.** Every file is downloaded and checksum-verified into a `.ehnew` staging file
first. Only once every one has arrived intact are they moved into place. A dropped connection
half way through leaves the install exactly as it was.

**Config is sacred.** Nothing matching the protected list is ever deleted, and `guard()` is
asserted immediately before every write and every delete — so even a wrong manifest could not
clobber a config. The guarantee does not depend on the manifest being right.

**Config is extended, never replaced.** A saved config is backed up, then re-saved through the
role's own `Config.withDefaults`, which deep-merges it over fresh defaults. Fields added by a
new release appear; every value you set is kept. Whole sections can be added between releases
and your file simply grows.

> The one exception: a config that will not parse *at all*. There is nothing to preserve, so it
> is backed up first, then replaced with defaults, and you are told. That is the only case.

**Repair never costs you settings.** Repairing deletes only *inside* the directories the role
owns (`flight/` for the flight computer) plus the root-level launcher it ships. Configs live at
the root and are backed up before anything is touched.

## Protected paths

Never deleted, and only ever written by the config-extension step (which backs up first):

```
/eh_*.tbl                     every role's config, waypoints, routes
/easyhover_backup/**          our own backups
/easyhover_install.txt        the install record
/easyhover_suite_src.txt      your source override
/easyhover_suite_token.txt    your token
/role.txt
/probe_report.txt             probe output is your data
/eh_*.log
```

## Backups

Every run that could cost you something writes into
`/easyhover_backup/<timestamp>_<version>/`. Copies, never moves — the original stays where it
is, so a failed run costs nothing. A config-schema bump backs up every config before a single
file changes.

## Pointing at somewhere other than GitHub

Put a base URL in `/easyhover_suite_src.txt` (one line, no trailing slash) and the Suite
fetches from there: a fork, a LAN mirror, or a floppy-fed copy. This is also how
`tests/run_suite_e2e.sh` serves the repo from localhost.

The repository is **public**, so `wget run` works with no credentials on any computer — the same
choice EasyKey made. If it is ever made private again, `raw.githubusercontent.com` returns 404
without credentials; put a GitHub token in `/easyhover_suite_token.txt` for that case, bearing in
mind that a token in plain text on a Minecraft computer is a poor secret.

## Releasing a change

```bash
node tools/gen_manifest.js
```

Run it after **any** change to a role's files, then commit both the files and `manifest.lua`.
Forget it and the Suite will keep telling computers they are current when they are not —
`tests/run_suite.sh` asserts the manifest is in sync, so the test catches it.

## Update, or repair?

They look identical on disk — the installed files disagree with the manifest — and **the version
stamp is the only thing that tells them apart**:

| On the computer | Verdict |
|---|---|
| Nothing installed | **install** |
| Stamp differs from the release | **update** — drift from an older release is expected |
| Stamp matches the release, bytes do not | **repair** — the stamp claims *these exact files*, so something damaged them |
| Files present, no install record | **repair** — nothing says what they are, so verify everything |
| `--repair` given | **repair**, always |

The Suite originally treated any difference as corruption, which meant it could only ever *fix*
a computer and never *update* one — and told the operator their install was broken every time a
release shipped. `Suite.choosePlan` is pure and unit-tested, because this is the kind of logic
that quietly regresses.

**Missing files alone prove nothing.** A release that adds a module leaves an older install
legitimately missing it, which is exactly the case this distinction exists for.

An update also **prunes** files the new release no longer ships — after the new ones are safely
committed, never before, since clearing up front would turn a failed download into a destroyed
install.

## The updater stamp

`manifest.updater` records the size and checksum of `easyhover_suite.lua` itself. If it ever
drifts from the published file, every run tells the operator their Suite is out of date, fetches
a replacement, fails to verify it, and repeats **for ever** — a silent infinite nag rather than
an error. `tests/run_suite.sh` asserts the stamp matches the file, and the Suite now names the
release as the fault rather than blaming the operator's computer.

Regenerate the manifest **after** any edit to `easyhover_suite.lua`.

## Testing it

```bash
bash tests/run_headless.sh      # flight side, includes the Suite's pure logic
bash tests/run_ui.sh            # ui_main, in its own interpreter
bash tests/run_suite_e2e.sh     # real install/update/repair against a localhost mirror
```

The e2e test really fetches, stages, commits, repairs and extends configs — it just serves the
repo from a local mirror instead of GitHub, which keeps it fast, offline, and independent of the
repository's visibility. Twelve phases, in order:

| Phase | What it proves |
|---|---|
| `install` | a bare computer ends up with the launcher, the role files and an install record |
| `current` | an up-to-date run backs nothing up and changes nothing |
| `configkeep` | a hand-written config keeps **my** values and gains the fields it never had |
| `repair` | corrupt and stale files are replaced — and **the config survives** |
| `badconfig` | an unparseable config is replaced, and the broken one is backed up, not discarded |
| `detect` | the role is re-derived from the files on disk when the record is gone |
| `protect` | `--repair` leaves configs, waypoints, probe output and hand-made backups alone |
| `check` | `--check` is a true dry run: it writes nothing, even over a corrupt file |
| `prepared` | an unreleased role installs nothing and does not clobber the current record |
| `uimain` | a fresh install of a **second** released role, on a wiped computer |
| `beacon` | the **gps_beacon** role installs on a bare computer and its config loads |
| `navrole` | the **nav** role installs, and a repair leaves the waypoint file intact |

Each phase inherits the computer the last one left behind — that is how a real install ages.
The last three are the exception and each start from bare, because installing a second role over
the first is a role *change*, not the fresh install a pilot performs. `prepared` therefore has to
name a role that is *still* reserved — it used `nav` until nav shipped, at which point the phase
was quietly testing a released role and proving nothing. Iterate on one phase with
`EASYHOVER_E2E_PHASES="install badconfig" bash tests/run_suite_e2e.sh` (keep `install` first).

> **The probe must call `os.shutdown()`.** Without it CraftOS-PC finishes the script, drops to
> its shell and idles until the runner's `timeout 180` kills it — and because the results file
> was already written, the phase still reports PASS. That cost 27 minutes a run, invisibly,
> until someone timed it.

---

## "Did it actually install?"

Two things are easy to confuse, and both look like a broken update:

**1. The files did not arrive.** Ask the Suite, on that computer:

```
easyhover_suite.lua --check
```

It is a true dry run — it writes nothing, even over a corrupt file — and reports exactly what
differs from the release. `Nothing to do.` means the bytes on disk match the manifest. Anything else
lists what would change.

The installed release is recorded in `/easyhover_install.txt`, and `version` there is a digest of
every shipped file's checksum and size, so it moves whenever shipped bytes move.

**2. The files arrived and the old code is still running.** Lua loads at boot. Until the computer
restarts, it keeps executing what it loaded, however new the files on disk are. **Each computer
updates and reboots independently** — the flight computer and the UI computer are separate installs,
and a change may live in either or both.

### Which build is ACTUALLY running

The UI computer's own terminal now shows it on line 2, and the flight computer logs it as its
first line at boot:

```
        EasyHover UI
ui_main 2bf66320
```

**It is read once, when the program loads.** That is the entire point — it reports the record as it
stood when the running code started, not as it stands now. Compare it against the release
(`node tools/gen_manifest.js` prints the version; `easyhover_suite.lua --check` reports it too):

| | |
|---|---|
| stamp **==** release | the new code is running — any remaining fault is in the code |
| stamp **<** release | the files updated and this program never restarted |

Without it, those two are indistinguishable from the pilot's seat, and debugging can go several
rounds into the wrong one. It costs one line on a screen that had a decorative subtitle there.

### And a third thing that is neither

A screen can look unchanged because the state it would show has not been reached. The SELF TEST
page only prints `TESTING 2/3` and its countdown **while a test is running**; when a run has been
refused, an old build and a new one render identically — dim steps, `START` on the button, the
refusal in the status line. Before concluding a release did not ship, check whether the new text is
reachable in the state the screen is actually in.
