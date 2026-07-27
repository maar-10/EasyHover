# VTOL vehicle — Mod API research (MC 1.21.1, NeoForge)

Everything below was read from **source or decompiled bytecode**, not from wikis or memory.
Researched 2026-07-26. Sources:

- `Propulsion-Team/create-propulsion-simulated` @ `main` (Java source + its own `wiki/`)
- `simulated-neoforge-1.21.1-1.1.3.jar` (Simulated itself — **closed source**, javap'd from
  Propulsion's `libs/`)
- `sable-neoforge-1.21.1-1.1.3.jar` (Sable — the physics engine under Simulated)
- `Creators-of-Aeronautics/Simulated-Project` @ `main` (Create: Aeronautics)
- `MehVahdJukaar/cameramod` @ `1.21.1-arch` (Vista)
- `getItemFromBlock/Create-Tweaked-Controllers` @ `dev-1.21`
- Prior work: `FireControl/docs/MOD_API_RESEARCH.md` (Radar / IE / Create / CBC)

---

## Headline findings

1. **Simulated ships a 12-peripheral CC suite of its own** — a full flight-instrument set
   (altitude, attitude, velocity, laser rangefinder, heading). Undocumented anywhere public.
2. **Propulsion thrusters are directly Lua-controllable** — thrust *and* 2-axis nozzle
   vectoring, no redstone in the loop. Attaching a computer takes authority away from redstone.
3. **Thruster throttle is quantised to 16 steps, despite the wiki advertising `0.0…1.0`.**
   Nozzle vectors *are* continuous. This shapes the whole control design.
4. **Vista exposes only camera *aiming*.** No pixels, no frame data, no "what am I looking at".
   Total CC surface: 8 `@LuaFunction`s, and 2 of those are unreachable on NeoForge.
5. **Wireless CC works across ships** — Sable explicitly patches CC's wireless distance math.
6. **Aeronautics propellers have zero CC integration** — rotation-driven only.

---

## 1. Create: Simulated — the instrument suite (undocumented)

`dev.simulated_team.simulated.compat.computercraft.peripherals.*`, registered per
block-entity type via `SimPeripheralService`. These are **real `IPeripheral`s**
(`SimPeripheral<T>`), so `getType()` is honoured — the type strings below are the literal
constants from the bytecode.

| Peripheral type | Methods (all `@LuaFunction`) | Notes |
|---|---|---|
| `altitude_sensor` | `getHeight() → float`, `getAirPressure() → double` | Altimeter. UI-configurable min/max altitude affects only its redstone output, not these. |
| `gimbal_sensor` | `getAngles() → table (list of numbers)` | **Attitude.** Per-axis, "each axis operates independently". Order/units/sign NOT determinable from bytecode — probe. |
| `velocity_sensor` | `getVelocity() → float` | **Scalar** speed, not a vector. Axis is set by the block's scroll value box. |
| `optical_sensor` | `getDistance() → float`, `getBlock() → string` | **Laser rangefinder** — distance to the obstructing block *and its block id*. Range configurable; filterable. |
| `navigation_table` | `getRelativeAngle() → float\|nil` | Heading relative to the table's nav target. Boxed `Float` → **can return nil**. |
| `linked_typewriter` | `getPressedKeyCodes() → table` | The ONLY method. Confirms structurally why `key`/`key_up` events are useless (see DriveByWire v9). |
| `docking_connector` | `getConnectedName() → string` | |
| `swivel_bearing` | `getTargetAngle() → double` | **Read-only** — you cannot command a swivel bearing from Lua. |
| `torsion_spring` | `setLimit(int)`, `getAngle() → float`, `getLimit() → int`, `isRunning() → bool` | **Writable** — the only Simulated actuator exposed to Lua. |
| `directional_link` | `getClosestAngle() → double` | Angle to nearest Redstone Link. |
| `modulating_link` | `getClosestDistance() → double` | Distance to nearest link. |
| `name_plate` | `setName(string)`, `getName() → string` | |

**None of these carry `mainThread = true`** → they run on the computer thread and do *not*
cost a server tick. Polling the whole instrument panel every tick is cheap. (Contrast Radar,
where every call is `mainThread`.)

Blocks that exist but expose **nothing** to Lua: Throttle Lever, Steering Wheel, Handle,
Analog Transmission, Redstone Accumulator, Redstone Inductor, Directional Gearshift,
Physics Assembler, Portable Engine, Laser Pointer / Laser Sensor, Absorber, Rope/Winch,
Magnet. There are matching **Display Sources** for most sensors, but Create's Display Link is
write-only from CC, so that is not a back door.

---

## 2. Create: Propulsion — the actuators

`dev.propulsionteam.propulsionsimulated.compat.computercraft.*`. Built on Create's
`SyncedPeripheral` pattern, so again real `IPeripheral`s with honoured type strings.
The repo ships its own `wiki/ComputerCraft-Peripherals.md` — accurate on method *names*,
**wrong on throttle resolution** (see below).

### Types

`thruster` (fluid), `solid_fuel_thruster`, `ion_thruster`, `creative_thruster`,
`vector_thruster`, `liquid_vector_thruster`, `creative_vector_thruster`, `tilt_adapter`,
`redstone_transmission`, `stirling_engine`, `coral_generator`.

### Vector thruster — the important one

```lua
t.setVector(x, y)          -- nozzle direction, each clamped -1..1, CONTINUOUS
t.setVectorX(x) / setVectorY(y)
t.getVectorX() / getVectorY()          -- actual (slews toward target)
t.getTargetVectorX() / getTargetVectorY()
t.setThrust(0..15) / setPower(0..15)   -- aliases
t.setThrustNormalized(0..1) / setPowerNormalized(0..1)
t.getThrust() -> 0..15 ; t.getPower() -> 0..1
```

Readouts shared by all thrusters: `getCurrentThrustPN/KN`, `getDisplayedThrustPN/KN`,
`getAirflowMs`, `getObstruction`, plus fuel (`getFuelAmountMb`/`getFuelCapacityMb` + `tanks()`
/`pushFluid`/`pullFluid` for fluid; `getFuelAmount`/`getBurnTimeRemaining`/`isBurning`/`list()`
for solid; `getEnergyAmountFe`/`getEnergyCapacityFe` for ion).

### ⚠️ Throttle is 16 discrete steps, not continuous

`ThrusterComputerHelpers.setThrottleNormalized` (used by **every** thruster peripheral,
vector and plain, creative included):

```java
int redstonePower = Mth.floor(Mth.clamp(normalized, 0, 1) * 15.0d + 1.0e-6d);
setThrottleFromRedstone(be, redstonePower);   // -> setDigitalInput(clamped / 15.0f)
```

So `setPowerNormalized(0.37)` lands on `5/15 = 0.3333`. Resolution is **1/15 ≈ 6.7 %**.
The block's own `setDigitalInput(float)` is fully continuous — the quantisation is purely in
the Lua-facing helper. Consequences:

- A lift PID has 16 levels. Expect visible step response / hunting if you feed it thrust alone.
- **Fine control must come from the nozzle vector**, which is genuinely continuous.
- The only continuous thrust path is `creative_vector_thruster.setThrustOutput(pN)` (absolute
  base thrust in pN, capped by config; `-1` or `clearThrustOutput()` releases the override).
  If smooth hover matters more than survival-mode legitimacy, that is the escape hatch.

### Attach semantics — and the failsafe this buys you

`ThrusterPeripheralBase.attach/detach` + `AbstractThrusterBlockEntity.ControlMode`:

- First computer attaches → `ControlMode.PERIPHERAL`. **World redstone next to the thruster
  stops driving thrust entirely.**
- Last computer detaches → `setDigitalInput(0)`, `setRedstoneInput(getBestNeighborSignal(pos))`,
  `ControlMode.NORMAL` — thrust reverts to whatever redstone the block sees.

**Design consequence:** wire a constant analog redstone "limp-home hover" level into the lift
thrusters. It is inert while the flight computer is attached, and the instant the computer is
broken, unloaded, or rebooting, the craft falls back to that level instead of dropping. This is
free failsafe hardware and it should be in the build from day one.

### Other actuators

- `tilt_adapter` — `setTargetAngle(angle)`, `getLeftSignal()`, `getRightSignal()`. Physical
  tilt (nacelle rotation) as opposed to nozzle deflection. Also takes computer authority while
  attached.
- `redstone_transmission` — `get/setTransmissionMode("direct"|"incremental")` (throws on
  invalid), `get/setShiftLevel`.
- `stirling_engine` — `getRpm()`, `setSpeed(target)` (snapped to scroll levels), `setActive(bool)`.

Every setter above is `mainThread = true`; every getter is not.

---

## 3. Vista — cameras (Q1 / Q2)

Vista's **entire** CC surface is 8 `@LuaFunction`s across two classes:

| Peripheral | Methods |
|---|---|
| View Finder | `setYaw(n)`, `getYaw()`, `setPitch(n)`, `getPitch()`, `setZoom(int 1..MAX_ZOOM)`, `getZoom()` |
| Signal Projector ("cassette_burner") | `getUrl()`, `setUrl(string)` |

### What works, what doesn't

- **You can aim and zoom a camera from Lua.** That is the whole feature.
- **You cannot read the image.** There is no frame, pixel, snapshot, or histogram method.
  Nothing renders server-side: `client/video_source/` (`LiveFeedVideoSource`,
  `WebUrlVideoSource`, `CassetteTapeVideoSource`, `BroadcastVideoSource`) and
  `client/textures/LiveFeedTexturesManager` are all client-only. The feed exists solely as a
  GPU texture on each player's machine.
- **No raycast/target readout.** The view finder does no server-side hit detection reachable
  from Lua (the only `BlockHitResult` uses are player right-click handlers).
- **A CC monitor cannot show a camera feed, and a Vista TV cannot show a CC screen.** They are
  unrelated render paths. In a cockpit these are two separate physical panels.

### ⚠️ NeoForge bug — the projector is unreachable

`neoforge/…/CCCompatImpl.setup()` registers **only** the view finder:

```java
ForgeComputerCraftAPI.registerGenericCapability(VIEW_FINDER_CAP);   // CASSETTE_BURNER_CAP: never registered
```

The Fabric impl registers **both** via `PeripheralLookup`. So on NeoForge, `setUrl`/`getUrl`
are dead — you cannot switch a projector's stream from Lua. Treat "CC can change what the
screen shows" as unavailable.

### Peripheral naming caveat

The view finder is a **generic capability**, not a plain peripheral — like Create: Radar's
generic sources, which appear as block ids (`create_radar:radar`). So expect the type to be
`vista:view_finder` (block id), **not** the `"view_finder"` string in `getType()`. Simulated's
and Propulsion's peripherals are real `IPeripheral`s and *do* use their `getType()` strings.
Confirm all of it with a probe before hardcoding.

### Also unverified: cameras on a moving ship

`ViewFinderAccess.Block.getGlobalPosition()` returns `blockPos.getCenter()` — a static world
position. Vista has **no** Create/Simulated/Sable integration whatsoever. Whether a view finder
inside a flying sub-level renders from the right place, or from a ghost of where the ship was
assembled, is an in-game test. Don't design the cockpit around it until it's confirmed.

---

## 4. What optical/sensory information Lua CAN get

Ranked by usefulness for this vehicle:

1. **`optical_sensor`** — `getDistance()` + `getBlock()`. A scriptable laser rangefinder that
   also identifies what it hit. This is the closest thing to machine vision available:
   ground-proximity / radar-altimeter, obstacle detection, landing-pad recognition by block id.
   Mount several on fixed bearings for a cheap depth fan.
2. **Create: Radar** (`radar`, `plane_radar`) — `getTracks()` gives other entities'
   position + velocity + type + id, and `getPosition()` gives the radar's own world position.
   The only *entity* sensing available. All `mainThread`; poll once per tick into a snapshot.
   Details already in `FireControl/docs/MOD_API_RESEARCH.md`.
3. **Simulated's own instruments** — altitude, air pressure, attitude angles, scalar speed,
   relative heading (§1).
4. **Laser Pointer + Laser Sensor** (Simulated) — beam-break tripwires, **redstone only**, no
   peripheral. Reachable from CC only by reading the sensor's redstone with a relay.
5. **IE Floodlight** — aimable from Lua (`turnAroundXZ`, `turnAroundY`), useful as a slaved
   searchlight; still no feedback about what it lights.

**Not available at any price:** pixels, images, screenshots, video, colour sampling, entity
recognition from a camera, or reading a Vista feed. Any "camera view" in this build is for the
human eye only.

---

## 5. Aeronautics propellers — no CC

Zero `@LuaFunction`/`IPeripheral`/`computercraft` references in the whole Aeronautics repo.

`BasePropellerBlockEntity.getThrust() = getConfigThrust() * getDirectionIndependentSpeed()` —
thrust is **linear in shaft RPM**, direction is block facing. The Smart Propeller adds a hinge
(`hingeAngle` → rotated thrust vector), i.e. mechanical vectoring rather than a Lua one.

So propellers are reachable only *indirectly*:

- **Create Rotation Speed Controller** — `setTargetSpeed(rpm)` from CC, integer, clamped
  ±256. Controls a whole kinetic network, not one propeller.
- **Simulated Analog Transmission** — analog redstone changes the gear ratio (higher signal =
  larger ratio; full signal disconnects). Per-propeller speed control, but the redstone has to
  come from CC via a `redstone_relay` (`setAnalogOutput(side, 0-15)`) or an IE Redstone
  Interface Connector.

That means each propeller you want independently controlled costs a redstone channel and lands
you back at 16 steps — with none of the vector thruster's continuous deflection. For
computer-controlled lateral/yaw authority, **small vector thrusters beat propellers**.

**Create's Encased Fan is not a propulsion device here** — its air current has no force-provider
hookup into Sable (the only `AirCurrentMixin` in Simulated is under `mixin/diving_boots/`).
Don't plan on fans for thrust.

---

## 6. Physics / platform facts that matter

- Simulated runs on **Sable** (`dev.ryanhcode.sable`). A vehicle is a **SubLevel** — real
  blocks in a sub-level world, which is why computers, modems and peripherals keep working
  while flying. Thrust is applied as point impulses into named force groups
  (`PROPULSION`, `DRAG`) — see `SimulatedThrustAdapter`.
- **Wireless CC works across sub-levels.** Sable ships
  `mixin/compatibility/computercraft/WirelessNetworkMixin`, replacing CC's receiver-distance
  check with `distanceSquaredWithSubLevels(...)`. So a wireless/ender modem link from the
  craft to a ground station is supported *by design*, unlike DriveByWire's wired-only setup.
  On-board comms should still be wired (faster, no range questions).
- **`mainThread` budget is the real performance ceiling.** Every thruster setter costs a
  server-tick slot; the instrument getters cost nothing. 8 thrusters × (`setVector` +
  `setThrust`) = 16 mainThread calls per control cycle. Mitigations: only write values that
  actually changed, run the loop at 10–20 Hz, and never call a setter from UI code.
- Expect **reboots across assembly/disassembly** (cf. SecDoor). Re-scan `peripheral.getNames()`
  after every assembly and treat peripheral loss as a normal, recoverable state.

---

## 7. Control inputs available

| Path | Surface | Verdict |
|---|---|---|
| **Create: Tweaked Controllers** — `tweaked_controller` | `getAxis(1..6) → float`, `getButton(1..15) → bool`, `hasUser()`, `getUserUUID()`, `setFullPrecision(bool)`, `isFullPrecision()`; **push events** `controller_start_using` / `controller_stop_using` | **Best fit.** A real gamepad: 6 proportional axes for collective/cyclic/pedals + 15 buttons. Note `setFullPrecision(true)` — default sends coarse values. |
| **Simulated Linked Typewriter** — `linked_typewriter` | `getPressedKeyCodes()` only | Keyboard fallback, digital only. **Poll it** — the peripheral has no events, which retroactively explains DriveByWire v9. Every key must be bound to a frequency. |
| **CC monitor touch** | `monitor_touch` | Buttons/toggles for modes, trim, lights. Not a flight axis. |
| Throttle Lever / Steering Wheel / Handle (Simulated) | none | Physical props only — invisible to Lua. |

---

## 8. Open questions — probe in-game before coding

A ~30-line probe on the assembled craft settles all of these:

1. `gimbal_sensor.getAngles()` — how many values, which axis is which, degrees or radians,
   sign convention, and whether it's ship-relative or world-relative.
2. `velocity_sensor.getVelocity()` — units (blocks/tick vs blocks/s), and whether the scroll
   value box selects the measured axis.
3. `altitude_sensor.getHeight()` — world Y, or height above the configured minimum?
4. Actual peripheral **type strings** as seen by `peripheral.getType()` — especially the Vista
   view finder (`vista:view_finder` vs `view_finder`).
5. Whether the Vista view finder renders correctly from inside a moving sub-level.
6. Nozzle slew rate: how many ticks `getVectorX()` takes to reach `getTargetVectorX()` —
   this sets the achievable attitude-loop bandwidth.
7. `optical_sensor` max range and whether `getBlock()` returns a full id (`minecraft:stone`).
8. Whether thruster peripherals survive assembly, or need re-wrapping afterwards.

---

## ⚠️ `getPower()` is the throttle read-back, NOT thrust

This one reached the craft. `getPower()` / `getThrust()` return **what `setPower`/`setThrust` last
asked for** — the commanded throttle. They say nothing about whether the thruster is doing
anything: a thruster with no fuel reaching it holds its throttle and produces **zero** thrust.

`getCurrentThrustKN` / `getDisplayedThrustKN` are the physical output. Use those for any question
of the form *"is anything actually firing?"*

The self-test interlock read `getPower() > 0.001`. Because `Thrusters:apply` runs every control
cycle **regardless of the engine master**, the altitude loop keeps asking the lift thrusters for
about 20% lift while the craft sits parked. The interlock read its own command back and told the
pilot to `CUT THE ENGINE` — with **no way to comply**, because the reading did not come from the
engine at all. The engine was already off.

**Only kN readouts are used.** `PN` is listed for every thruster too, but mixing units to gain a
fallback is how an epsilon silently becomes a thousand times too large. There is **no `getPower`
fallback at all** — falling back to it hands the interlock the flight computer's own command as
though it were evidence, which is the whole bug.

Verified in the source, not inferred:

- `getCurrentThrustPN()` → `blockEntity.getCurrentThrust()` → `thrusterData.getThrust()`, which
  `updateThrust` only sets nonzero when `isWorking() && currentPower > 0` **and fuel is actually
  being consumed**. This is real output.
- `getCurrentThrustKN()` is that divided by `PropulsionConfig.getThrustUnitsPerKnOrDefault()`.
- `getDisplayedThrustPN()` → `getDisplayedThrustPnForTooltip()`. **A display figure. Never use it
  to decide whether a nozzle is firing.**

### ⚠️ Every thruster `@LuaFunction` is `mainThread = true` — getters included

`getPower`, `getCurrentThrustPN/KN`, `getDisplayedThrust*`, `getObstruction`, `getFuelAmountMb`,
`getFuelCapacityMb` — all of them. `flight/lib/io/thrusters.lua` used to claim "getters are NOT
mainThread, so this is cheap"; that was wrong, and `readback()` runs over every thruster every
control cycle. Each call waits on a server tick.

### The engine master does not make the thrusters cold

`ENGINE OFF` on the overhead panel means the **item funnel** is blocked by its relay. The **liquid
fuel tank feeds the vector thrusters directly**, so with a full tank they are fuelled regardless.
Combined with `Thrusters:apply` running every cycle whatever the engine state, a parked craft can
sit there with the altitude loop holding ~20% throttle and the lift nozzles genuinely producing
tens of kN. Any interlock phrased as "cut the engine" is therefore telling the pilot to operate a
switch that does not control the thing being measured.

### The mock had the same confusion

`tests/mocks/peripherals.lua` derived `getCurrentThrustKN` from commanded power, so the two were
indistinguishable and **no test could tell a false interlock trip from a true one**. Every thruster
mock now has a `__setFuelled(false)` switch (test scaffolding, not a mod method) that makes the
thrust readouts return 0 while the throttle keeps its value — which is what an unfuelled thruster
really does.

A fix for a physical-semantics bug is not verified until the mock can express the physics.
