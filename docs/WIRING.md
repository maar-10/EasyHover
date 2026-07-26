# EasyHover — wiring, topology and computer roles

Answers the question "how should the vectored thrusters be wired for the fastest, most
accurate control?" — with the reasoning, so the decision can be re-checked later.

---

## Decision

**One dedicated flight computer. Every thruster, every sensor and every pilot input on a
single wired-modem network with it. No UI, no music, no aux redstone on that computer.
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
   all. It has exactly one job here: the persistent failsafe level (below).

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
| **Redstone relays driving thrust** | Loses vectoring entirely and quantises to 16 steps. Failsafe only. |
| **All thrusters on one PC that also runs the UI** | No. CC computers are single-threaded coroutines; a Basalt redraw competes directly with the control loop. This is the DriveByWire pattern (`parallel.waitForAny(basalt.run, mainLoop)`) and it is fine for a car — not for a hover PID. |

---

## Computer roles

All on the ship's single wired network. Rednet over wired modems for coordination.

| Role | Owns | Notes |
|---|---|---|
| **`flight`** | 8 vector thrusters, all sensors, typewriter + tweaked controller, failsafe relay, telemetry broadcast | **No UI, no speaker, no HTTP.** One loop, one clock. |
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

## Failsafe wiring (build this from day one)

Attaching a computer puts a thruster in `ControlMode.PERIPHERAL` and **adjacent redstone stops
driving thrust**. On detach — computer broken, unloaded, or rebooting — the block reverts to
`ControlMode.NORMAL` and reads `getBestNeighborSignal()`.

So: put a **redstone relay next to each lift thruster** and have the flight computer set its
analog output to the configured hover level **once at boot**. Relay outputs persist when the
owning computer dies, so the level is already sitting there the moment authority reverts. The
craft settles instead of dropping.

### Two different "failsafe hover" settings — don't confuse them

The relay carries a **thrust level, not an altitude**. It is open loop: there is no sensor and no
computer in that path, so it physically cannot *hold* an altitude. Depending on mass and remaining
fuel the craft will still drift slowly up or down. What it buys is a gentle settle instead of a
fall. Both of these are configurable, and they are different things:

| Config key | What it is | Default |
|---|---|---|
| `failsafe.redstoneLevel` | The analog level (0–15) written to the relays at boot. **Hardware failsafe** — the only thing that works when the computer is gone. | Derived from the **learned hover trim** (see [CONTROL_LAWS.md](CONTROL_LAWS.md) §4), rounded to the nearest step, with a configurable `failsafe.bias` in steps so you can choose to err slightly upward. Before trim has ever been learned, a conservative configured constant. |
| `failsafe.holdAltitude` | The altitude the **software** degraded-hold reverts to when the loop is alive but inputs or nav are lost. | **The first altitude the system reads at boot**, then continuously updated to the last commanded hover altitude. Overridable in config and from the UI. |

Both are editable in the config UI, and `failsafe.redstoneLevel` gets a **Test** button that
writes the level and reports the resulting `getCurrentThrustKN` against the learned hover
requirement — so the number can be validated on the ground instead of discovered in the air.
Getting `redstoneLevel` right is the single most important number before the first crewed flight.

## Identify feature

Because peripheral names are attach-ordered, the config UI gets an **Identify** button per
thruster slot: it sweeps that thruster's *nozzle only* (`setVector`) at **zero thrust** so the
user can see which physical unit is which. Nozzle-only, zero-thrust, and hard-gated to the
`GROUND` flight state — an identify sweep must never be possible in the air.
