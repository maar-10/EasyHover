# EasyHover

A CC:Tweaked flight-control system for a luxury two-to-four-seat **VTOL hovercraft** built on
Create: Simulated + Create: Propulsion, for **Minecraft 1.21.1 / NeoForge**.

Vectored thrusters for lift, hover, balance and translation — driven directly from Lua, with a
cascaded PID flight controller, a Basalt 2.0 glass cockpit, proximity warnings, an annunciator
and aux vehicle controls.

## Status

**Flight control and the cockpit UI are both in.**
`bash tests/run_headless.sh` (261) + `bash tests/run_ui.sh` (38) = **299 tests green.**

Everything needed to hover, climb and descend, set an altitude, translate in both lateral
modes, steer, accelerate forward on the main thrusters, brake, and reverse by pitching up.
Inputs from both a Linked Typewriter and a Tweaked Controller, fully remappable.

The plant simulator holds altitude to **~0.1 blocks** with no limit cycle, and it earned its
keep: it caught rate gains a full decade too hot, a free-fall hole at zero commanded thrust,
and a wrong toe-authority formula. See [docs/CONTROL_LAWS.md](docs/CONTROL_LAWS.md) §4a.

## Installing

```
wget run https://raw.githubusercontent.com/maar-10/EasyHover/main/easyhover_suite.lua
```

One file installs any role, updates it, repairs a corrupt install, and extends your saved
config with newly added defaults without ever replacing it. Full behaviour in
[docs/INSTALL.md](docs/INSTALL.md).

### Cockpit UI

A second computer (`ui_main` role) drives every screen — the flight computer stays math-only, and
since a monitor is a network peripheral the screens still sit wherever you mount them.

- **overhead panel** (mirrored to a pair of 1×2 screens): engine start/stop with a feed
  countdown, liquid + solid fuel gauges, and their config in a submenu
- **config panel**: live flight values, plus MONITORS / DISK / FLIGHT submenus
- monitor assignment is done by tapping, and works from the terminal too, so an unassigned
  cockpit is never a dead end

See [docs/UI.md](docs/UI.md).

### Still to come

PFD (7), proximity (8), annunciator (9), aux panel (10), nav + autopilot (11–15), music (16).
Their roles are already reserved in the Suite with directories and config paths ready.

### Vehicle systems

- **Engine master** — one switch (default **Z**) starts and keeps the portable engine running,
  by inverted redstone pulses through the funnel above it. The vehicle boots off, funnel
  blocked. [docs/WIRING.md](docs/WIRING.md).
- **Gauges** — fluid tank level and engine-vault item count.
- **Config disk** — run `diskmenu` to save or load every `/eh_*.tbl` to a floppy. Verified
  writes, backups on load, and a config that does not parse is refused.
- **Aux relays** — lights (**L**) and landing gear (**G**).

### Two things to know before flight

**There is no hardware thrust failsafe.** It was scrapped deliberately (a relay and cabling per
thruster cost too much space). If the flight computer is destroyed, unloaded or rebooted while
airborne, **the craft falls**. Land before stopping the program. Reasoning and habits in
[docs/WIRING.md](docs/WIRING.md).

**Drift damping and directional braking need a velocity vector.** Mount three velocity sensors
(one per axis) and map them in `hardware.sensors.velocityVector` — until then those two features
degrade and annunciate rather than guess. [docs/MODES.md](docs/MODES.md) §6.

### Before the first flight

`tools/probe.lua` is written and green (`bash tests/run_probe_headless.sh`, 20/20) but
**waiting on an in-game run**. It measures the nozzle slew rate that caps attitude-loop
bandwidth, whether the gimbal reports yaw, and whether `getVelocity()` is signed — the numbers
that turn sim-tuned gains into flight-tuned ones.

```bash
bash tests/run_headless.sh      # 261 flight-side tests
bash tests/run_ui.sh            # 38 ui_main tests (own interpreter)
bash tests/run_suite.sh         # Suite static checks
bash tests/run_suite_e2e.sh     # real install/update/repair against a localhost mirror
bash tests/run_probe_headless.sh
```

## Documentation

| Doc | What's in it |
|---|---|
| [docs/PLAN.md](docs/PLAN.md) | Module map, phases, comms protocols, risks. **Start here.** |
| [docs/CONTROL_LAWS.md](docs/CONTROL_LAWS.md) | The anti-oscillation contract, cascade design, tuning order. |
| [docs/MODES.md](docs/MODES.md) | Thruster layout, feel modes, Flight Assistant, braking — **and the velocity-sensor gap**. |
| [docs/WIRING.md](docs/WIRING.md) | Topology, computer roles, the engine master, gauges, and the scrapped failsafe. |
| [docs/NAVIGATION.md](docs/NAVIGATION.md) | Position sources, waypoints, routes, autopilot modes, autoland, interlocks. |
| [docs/MUSIC.md](docs/MUSIC.md) | Exactly what the music module requires, and why. |
| [docs/UI.md](docs/UI.md) | The UI computer: panels, mirroring, monitor assignment, telemetry, commands. |
| [docs/INSTALL.md](docs/INSTALL.md) | The EasyHover Suite: roles, updating, repair, and how configs are handled. |
| [docs/MOD_API_RESEARCH.md](docs/MOD_API_RESEARCH.md) | What every mod actually exposes to Lua, read from source/bytecode. |

## Layout

```
flight/     flight computer  (thrusters, sensors, inputs, PID) — no UI, ever
ui_main/    main display + configuration screens
ui_pfd/     primary flight display (attitude / flight-path indicator)
ui_prox/    proximity warning display
ui_aux/     lights, doors, landing gear
nav/        waypoints, routes, map UI, position fixing
music/      entertainment computer
launchers/  per-role /startup.lua launchers (shipped by the Suite)
ground/     optional ender-modem ground station
tools/      probe + installer generator
tests/      headless logic suite, UI render suite, plant simulator
vendor/     basalt-full.lua (pinned)
```

## Conventions

- **Basalt 2.0 `full` build only** — `vendor/basalt-full.lua`, never core/plain/dev.
- **ASCII 32–126 (plus `\7`) in anything rendered** — CraftOS-PC's font is not the in-game font.
- **Poll the typewriter** (`getPressedKeyCodes`); its `key`/`key_up` events do not arrive.
- Config is backward-additive: old config files load and gain new fields.
- Installers launch the real role file with `shell.run`; they never copy it.
