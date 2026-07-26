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
| nav | reserved | Waypoints, routes, map UI, position fixing. Feeds the flight computer. |
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

## Testing it

```bash
bash tests/run_headless.sh      # flight side, includes the Suite's pure logic
bash tests/run_ui.sh            # ui_main, in its own interpreter
bash tests/run_suite_e2e.sh     # real install/update/repair against a localhost mirror
```

The e2e test really fetches, stages, commits, repairs and extends configs — it just serves the
repo from python instead of GitHub, which keeps it fast, offline, and independent of the
repository's visibility.
