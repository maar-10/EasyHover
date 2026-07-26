# EasyHover

A CC:Tweaked flight-control system for a luxury two-to-four-seat **VTOL hovercraft** built on
Create: Simulated + Create: Propulsion, for **Minecraft 1.21.1 / NeoForge**.

Vectored thrusters for lift, hover, balance and translation — driven directly from Lua, with a
cascaded PID flight controller, a Basalt 2.0 glass cockpit, proximity warnings, an annunciator
and aux vehicle controls.

## Status

**The flight control system is complete and testable — `bash tests/run_headless.sh` (201/201).**

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

### Still to come

Nav + autopilot (phases 11–15), the UIs and annunciator (6–10), music (16). Their roles are
already reserved in the Suite, with directories and config paths ready.

### Known gap before flight

Drift damping and directional braking need a velocity **vector**. Mount three velocity
sensors (one per axis) and map them in `hardware.sensors.velocityVector` — until then those
two features degrade and annunciate rather than guess. [docs/MODES.md](docs/MODES.md) §6.

⚠️ **Open hardware item:** drift damping and the brake law need a velocity *vector*; the
confirmed sensors only give an unsigned scalar. See [docs/MODES.md](docs/MODES.md) §6 — it
needs two or three velocity sensors mounted on different axes.

`tools/probe.lua` is written and green too (`bash tests/run_probe_headless.sh`, 20/20) —
**waiting on an in-game run**; it measures the nozzle slew rate that caps attitude-loop
bandwidth and answers the heading question nav depends on.

Next: phase 3 — control laws plus `tests/sim.lua`, the plant simulator that has to prove no
limit cycle before anything flies.

```bash
bash tests/run_headless.sh
```

## Documentation

| Doc | What's in it |
|---|---|
| [docs/PLAN.md](docs/PLAN.md) | Module map, phases, comms protocols, risks. **Start here.** |
| [docs/CONTROL_LAWS.md](docs/CONTROL_LAWS.md) | The anti-oscillation contract, cascade design, tuning order. |
| [docs/MODES.md](docs/MODES.md) | Thruster layout, feel modes, Flight Assistant, braking — **and the velocity-sensor gap**. |
| [docs/WIRING.md](docs/WIRING.md) | Topology, computer roles, failsafe wiring, and why. |
| [docs/NAVIGATION.md](docs/NAVIGATION.md) | Position sources, waypoints, routes, autopilot modes, autoland, interlocks. |
| [docs/MUSIC.md](docs/MUSIC.md) | Exactly what the music module requires, and why. |
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
