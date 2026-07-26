# EasyHover — wiring, topology and computer roles

Answers the question "how should the vectored thrusters be wired for the fastest, most
accurate control?" — with the reasoning, so the decision can be re-checked later.

---

## Decision

**One dedicated flight computer. Every thruster, every sensor and every pilot input on a
single wired-modem network with it. No UI, no music, no HTTP on that computer.
Everything else lives on its own computer and talks to the flight computer over wired rednet.**

---

## Why — the four facts that decide it

1. **Distance is free; calls are not.** A peripheral call over a wired modem costs exactly the
   same as a call to an adjacent block. Splitting thrusters across several computers buys
   **zero** actuation speed.
2. **Every computer boundary you add to the control path adds latency *and jitter*.** A rednet
   hop is an event round-trip plus each computer's own scheduling. Variable dead time in the
   actuation path eats phase margin — it is the single most reliable way to turn a tuned PID
   into an oscillator. **Never split a control loop across computers.**
3. **`mainThread` is the real budget.** Every thruster setter (`setVector`, `setThrust`,
   `tilt_adapter.setTargetAngle`) is `mainThread = true` and costs a server-tick slot;
   CC's defaults are ~5 ms per computer and ~10 ms global per tick. Every Simulated sensor
   getter is **not** mainThread and costs nothing. So sensing is free and actuation is the
   scarce resource — and the global budget is *shared*, so spreading thrusters over more
   computers does not enlarge it.
4. **Redstone can't vector.** The redstone path gives 16 thrust steps and no nozzle control at
   all. Its jobs here are the engine master and the aux outputs (below).

### Budget math

8 thrusters × (`setVector` + `setThrust`) = 16 mainThread calls per cycle; at 20 Hz that is
320 calls/s. That is why the thruster module **writes only what changed**:

- `setThrust` is quantised to 16 steps anyway → in steady hover the step almost never changes,
  so those 8 calls collapse to ~0.
- `setVector` is written only when the commanded deflection moves more than the write deadband.

Steady hover should therefore cost a handful of calls per cycle, not 16.

---

## Options considered and rejected

| Option | Verdict |
|---|---|
| **One PC per thruster, networked to a main PC** | **Worst.** A network hop inside the fast path, N clocks, split integrator state, and *more* global mainThread contention, not less. |
| **Group PCs (e.g. 4 thrusters each) → main PC** | Same defect, smaller. Only justified if one PC's mainThread budget is *measured* to be insufficient — and then the hop must be placed on a cascade boundary (the group PC would have to run its own inner loop), which is a much larger redesign. Not now. |
| **Ender modems in the control path** | **No.** Unbounded latency, no ordering guarantee, cross-dimension delivery. Telemetry only. |
| **Wireless modems in the control path** | No. They *do* work across sub-levels (Sable patches CC's distance check), but the jitter argument is unchanged. |
| **Redstone relays driving thrust** | Loses vectoring entirely and quantises to 16 steps. Never for thrust; the relays here drive the engine master and aux outputs only. |
| **All thrusters on one PC that also runs the UI** | No. CC computers are single-threaded coroutines; a Basalt redraw competes directly with the control loop. This is the DriveByWire pattern (`parallel.waitForAny(basalt.run, mainLoop)`) and it is fine for a car — not for a hover PID. |

---

## Computer roles

All on the ship's single wired network. Rednet over wired modems for coordination.

| Role | Owns | Notes |
|---|---|---|
| **`flight`** | 8 vector thrusters, all sensors, typewriter + tweaked controller, engine + aux relays, telemetry broadcast | **No UI, no speaker, no HTTP.** One loop, one clock. |
| **`ui_main`** | Main display monitor + config screens + annunciator speaker | Config edits are sent to `flight`, which validates and live-applies. |
| **`ui_pfd`** | PFD / flight-path-indicator monitor only | Its own computer so a high refresh rate can't starve anything else. |
| **`ui_prox`** | Proximity monitor | Separate role; may share hardware with `ui_main` if perf allows — a config choice, not a code change. |
| **`nav`** | Waypoint/route database, map UI, **position fixing** (wireless modem for GPS, and/or the on-board radar) | Guidance itself runs on `flight`; this computer supplies fixes and owns the database. If it dies, autopilot degrades to hold — manual flight is unaffected. |
| **`music`** | Music speaker, browse monitor, HTTP | Audio streaming is CPU- and bandwidth-heavy. Must never share a computer with flight. |
| **`aux`** | Redstone relays for lights / doors / landing gear + its monitor | Non-critical actuation. |
| **`ground`** (optional) | Ender-modem telemetry receiver | Advisory only. Never commands flight. |

---

## Physical wiring

- **Wired modem on every thruster** (or a full-block modem adjacent), all on one networking-cable
  trunk to the flight computer. Same trunk for the sensors, the typewriter and the controller
  lectern.
- **Peripheral names are attach-ordered** (`vector_thruster_0`, `_1`, …) and are *not* stable
  across rebuilds. So config maps **role → peripheral name**, and nothing in the code may depend
  on discovery order. See the Identify feature below.
- **Fuel:** each thruster needs its own supply; the fuel/inventory sensing reads the supply
  containers via the generic `inventory` / `tanks()` methods.

## The hardware failsafe: SCRAPPED, deliberately

Attaching a computer puts a thruster in `ControlMode.PERIPHERAL` and **adjacent redstone stops
driving thrust**. On detach — computer broken, unloaded, or rebooting — the block reverts to
`ControlMode.NORMAL` and reads `getBestNeighborSignal()`.

The original design put a **redstone relay beside each lift thruster**, holding a hover-thrust
level written once at boot. Relay outputs persist when their computer dies, so the level would
already be standing by the moment authority reverted, and the craft would settle rather than drop.

**Scrapped 2026-07-26 at the pilot's decision.** A relay, cabling and a modem per thruster cost
too much space and weight on a small craft for something that, with wired-only controls, should
never fire.

### The accepted consequence — stated plainly, because it is real

> **If the flight computer is destroyed, unloaded, or rebooted while airborne, the thrusters
> revert to redstone control, see no signal, and the craft falls.**

The reasoning for accepting it: control is wired end to end, so there is no link to drop; and the
loop's own failure modes are already handled in software — a Lua error in a cycle is caught and
leaves thrust commanded while neutralising the nozzles, and the DAMPED and FAILSAFE states hold
thrust rather than cutting it. What is *not* covered is the computer itself ceasing to exist.

Habits that follow from that:

- **Land before stopping the program.** Ctrl+T, `os.shutdown`, or breaking the computer while
  airborne all end the same way.
- **Keep the flight computer inside the hull**, where nothing can shoot or clip it.
- Do not reintroduce a half-version of this. Either the relays are wired or they are not — a
  partially wired failsafe is worse than none, because it looks like protection.

### What remains

| Config key | What it is | Default |
|---|---|---|
| `failsafe.holdAltitude` | The **software** degraded-hold reference: where the loop holds when it is alive but has lost inputs or nav. | **The first altitude the system reads at boot**, then the last commanded hover altitude. |

## Engine master wiring (the vehicle's on/off switch)

The portable engine drives the fuel pumps, and a funnel above it feeds it items. **The funnel
passes items only while UNPOWERED**, so the control signal is inverted by nature:

| Master | Signal | Effect |
|---|---|---|
| **OFF** | held **HIGH** continuously | funnel blocked, engine starves, vehicle off |
| **ON** | HIGH, dropped for `pulseMs` every `intervalMs` | one item per interrupt keeps the engine running |

Turning the master on drops the signal once immediately — the **kickstart** — then settles into
the periodic interrupt.

Wire **one relay** to the funnel and name it in `hardware.engine = { relay, side }`; the timings
live in `engine = { pulseMs, intervalMs, kickstart, invert }`.

- `pulseMs` must be long enough for exactly one item to pass and short enough that a second
  cannot follow.
- `intervalMs` must be shorter than the engine's burn time.
- Config validation **rejects a pulse longer than the interval**, since that would leave the
  funnel never blocked.
- `engine.invert = true` flips the polarity for a build wired the other way round.

The output is asserted **blocked at boot** and re-asserted every cycle, so a relay that reboots
cannot quietly drain the vault into a cold engine. Default keybind: **Z** (or controller button 7).

## Aux relays

`hardware.relays` entries with `purpose = "aux"` and a `label` drive lights, doors and landing
gear. **G** toggles `gear` and **L** toggles `lights` by default.

## Gauges

| Config | Reads | Shows |
|---|---|---|
| `hardware.tanks` | generic `fluid_storage.tanks()` | the craft's fuel supply |
| `hardware.vaults` | generic `inventory.list()` | engine fuel left in the vault |

Create's fluid tanks usually report a capacity; when yours does not, set `capacityMb` so the
gauge has a scale. Without either we show the raw amount and **no** fraction rather than
inventing a maximum. A vault `item` filter counts one id only; blank counts everything.

## Config disk

Any networked **disk drive** lets you save and load every `/eh_*.tbl` on the computer. Run
`diskmenu` on the flight computer. Writes are verified by readback, loads back up whatever they
overwrite, and a config that does not parse is **refused** rather than installed.

## Identify feature

Because peripheral names are attach-ordered, the config UI gets an **Identify** button per
thruster slot: it sweeps that thruster's *nozzle only* (`setVector`) at **zero thrust** so you
can see which physical unit is which. Nozzle-only, zero-thrust, and hard-gated to the `GROUND`
flight state — an identify sweep must never be possible in the air.

## Where the fuel reading comes from

**A piped thruster has no fuel of its own to report, and that is normal.** Create Propulsion's
vector thrusters are fed from a tank through pipes, so they expose no fuel API at all — the
**tank gauge** is the fuel reading, read separately from the configured tank and driving its own
low-fuel alarm.

The flight computer used to warn, *per thruster*, that "fuel display will be blank". It was
false whenever a tank was configured — which is the normal case — and it re-fired every time the
kind cache was cleared, i.e. on every tank or vault assignment. It now says the situation once,
as information, and only warns when there is **no tank either**, because then there genuinely is
no fuel reading anywhere.

The same rule now applies to the "auto-picked one of N peripherals" warning: `scan()` runs on
every hardware assignment, so it reports once per changed situation rather than once per scan.

> The general principle, learned twice: **a message that repeats on every scan is a message
> that will be emitted hundreds of times while someone configures a craft.** Report on change,
> not on pass.

