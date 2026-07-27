# EasyHover — control laws and the anti-oscillation contract

The hard requirement: **no self-escalating oscillation, ever.** This document is the contract
the control code must satisfy. Every rule here exists because of a specific, named failure mode.

---

## 1. Authority split — the core idea

Two actuators with very different characters:

| Actuator | Resolution | Speed | Role |
|---|---|---|---|
| **Thrust** (`setThrust`) | **16 steps** (1/15 ≈ 6.7 %) | instant | coarse, slow-moving lift |
| **Nozzle vector** (`setVector`) | continuous | slews physically | fine, fast trim + attitude |

A PID that writes *thrust* to hold altitude has 16 output levels and will limit-cycle: it
overshoots on one step, undershoots on the next, forever. So:

> **Coarse and slow on thrust. Fine and fast on the vector.**

Total vertical force from a tilted nozzle is `T · cos(θ)`, so nozzle deflection is also a
**continuous vertical trim** worth a few percent of thrust — precisely the resolution the
quantised axis is missing. Altitude hold therefore commands:

- a **thrust step** from the slow outer loop (changed rarely, with hysteresis), plus
- a **symmetric vector trim** from the fast loop for everything between steps.

## 1a. How continuous attitude control is possible at all — the toe trick

§1 said "fine control comes from the nozzle vector", and that needs to be precise, because
the naive version is wrong.

A thruster's force acts at its own position, so the moment it produces is `r × F`. For a
down-facing thruster at a corner, the dominant term is the *vertical* force at a longitudinal
or lateral offset — **not** the deflection. Deflecting one nozzle mostly produces horizontal
force (translation), not a moment. So pitch and roll come from **differential vertical
thrust between pairs**, which is the 16-step quantised axis. That is the problem, not the
solution.

The way out: a deflected nozzle's vertical component is `T·cos(θ)`, which **is** continuous
in θ. Deflect the two thrusters of a pair *toward each other* — toe them in — and their
horizontal forces cancel while both lose the same continuous fraction of vertical thrust.

> **Toe-in is a continuous, horizontal-force-free lift trim on a pair of thrusters.**

That single mechanism gives us everything the quantised axis cannot:

| Demand | Mechanism |
|---|---|
| **Vertical fine trim** | Toe all four equally. A configured `toeBase` is held as a baseline so trim can move in *both* directions. |
| **Pitch** | Toe the front pair against the rear pair — one pair loses lift, continuously. |
| **Roll** | Toe the left pair against the right pair. |
| **Translation** | Deflect all four the *same* way — net horizontal force, deliberately. |

Toe authority is finite (it costs `1 − cos θ` of lift, a few percent). So attitude is a
**coarse+fine split of its own**, exactly like altitude: demand up to `mixer.toeShare` is
served continuously by toe, and only the excess spills into differential *thrust steps*.
Since the excess only appears during large transients, quantisation noise never reaches the
steady-state attitude loop — which is the whole point.

## 2. Cascade structure

```
pilot input ──► mode/limits ──► OUTER (slow)          ──► INNER (fast)         ──► mixer ──► thrusters
                               altitude / vert-speed      attitude (pitch/roll)
                               heading / ground speed     yaw rate
```

- **Inner (attitude) loop rate ≥ 3× outer (altitude) loop rate.** Without that separation the
  two loops fight and the pair oscillates even when each is individually stable.
- Outer loops output *setpoints*, never actuator commands. Only the mixer touches thrusters.
- The mixer is the single place that knows the physical layout; it converts
  `{lift, pitch, roll, yaw, latX, latY}` into per-thruster `{thrust, vecX, vecY}`.

## 3. The nine protections

Each is mandatory, and each has a test.

1. **Hysteresis / Schmitt trigger on the quantised thrust axis.** Step up or down only when the
   error exceeds ~1.5 steps for N consecutive samples. Kills step dither.
2. **Slew limiting.** Commanded thrust steps and vector deflections both rate-limited. Bounds
   how fast the plant can be excited.
3. **Derivative on measurement, low-pass filtered** (first-order, α configurable ≈ 0.2).
   Never differentiate the setpoint (no derivative kick), never differentiate a raw noisy
   signal — gimbal angles *will* be noisy.
4. **Conditional integration + clamp.** Freeze the integrator whenever the output is saturated
   or the thruster reports obstruction; hard-clamp `I` to a configured band. No windup.
5. **dt discipline.** Compute `dt` from `os.epoch("utc")`, clamp it to `[dt_min, dt_max]`, and
   if a cycle overruns (a mainThread stall, a chunk hiccup) **skip integration and derivative
   for that cycle** instead of integrating a huge `dt`. A dt spike through a naive PID is a
   guaranteed kick.
6. **Actuator-lag awareness.** The nozzle physically slews (`getVectorX` chases
   `getTargetVectorX`). Attitude-loop bandwidth must sit **at or below ~1/5 of the measured
   nozzle bandwidth**; exceed it and phase lag alone will sustain oscillation. The probe
   measures the slew rate, and that number sets the gain ceiling in config.
7. **Oscillation detector with automatic degrade.** Count error sign changes per second per
   axis. Above the configured threshold: halve the gains on that axis (gain scheduling), raise
   an alarm, and log it. If it persists, drop to **DAMPED HOVER** — vectors to neutral, hold
   last thrust step, full annunciation. This is the direct answer to "no escalating
   oscillation": the loop watches itself and gives up authority before it diverges.
8. **Envelope limiter.** Hard caps on commanded bank/pitch, vertical speed, and yaw rate.
   The pilot commands *within* the envelope; the envelope is not negotiable by any module.
9. **Ground state gating.** Detect on-ground via the laser sensors + near-zero vertical speed.
   While on the ground: integrators zeroed and frozen, attitude loop idle, identify sweeps
   permitted. Landed integrator windup is otherwise the classic "vehicle leaps on takeoff" bug.

## 3a. Braking, drift damping, and the sensor they depend on

The brake law and the Flight Assistant are specified in [MODES.md](MODES.md) — braking works
by tilting the lift thrusters into the direction of motion, proportionally, rate-limited and
hard-capped, and the assistant damps residual drift using all lateral thrusters.

Both are subject to every rule in §3, and both carry one extra constraint that the rules
above do not cover: **they need a velocity *vector*, and the confirmed sensor set only
provides an unsigned scalar** (MODES.md §6). `envelope.brakeTiltForSpeed()` and the assistant
therefore consult `sensors:velocityCapability()` and degrade — with annunciation — rather than
push in a guessed direction. Attitude and altitude control are unaffected; they never needed
a velocity vector.

The brake tilt cap is also validated against the pitch envelope at config load: a brake that
could command an attitude the attitude loop cannot hold calmly is a config error, not a
runtime surprise.

## 4. Hover trim learning

The craft's mass is unknown to us. Rather than hand-tune a feed-forward, the altitude loop
learns the hover thrust: a very slow integral of the thrust needed to hold a stable hover,
persisted to config. On the next boot it is the starting point, so the loop begins near
equilibrium instead of hunting for it.

(It used to also seed the hardware failsafe's redstone level. That failsafe was scrapped --
see [WIRING.md](WIRING.md) -- so the trim now serves only the loop itself.)

## 4a. Two things the simulator taught us the hard way

Both were found by running the loops against `tests/sim.lua`, not by reasoning, and both are
now encoded in config with comments pointing here.

**Rate-loop gains live in a narrow band, and the wrong decade is catastrophic.** The rate
loop's output is a *thrust fraction*, and the usable band around hover is only a few percent
wide — with a thrust-to-weight ratio `R`, hover sits near collective `1/R`. A gain sized as
if the full 0…1 range were available slams the demand to both rails: `p = 0.24` diverges with
±5 blocks/s of vertical speed, while `p = 0.05` holds altitude to about **0.1 blocks**. Same
structure, same plant, one decade apart.

**Zero commanded thrust is not "descend", it is free fall.** When the rate loop saturated
low, collective went to 0 and the craft fell at full gravity. `minAirborneCollective` now
floors it while airborne. Descent authority below that floor is ample, and the envelope caps
sink rate regardless.

**Design consequence for the airframe:** a *high* thrust-to-weight ratio makes smooth hover
**harder**, not easier — hover sits low in the throttle range, so each of the 16 thrust steps
is a bigger fraction of the hover thrust and the usable band is narrower. For a luxury
cruiser aim for roughly **1.3–1.6 thrust-to-weight**. Enough margin to climb and to brake,
without making every step a lurch.

## 5. Tuning procedure (in this order, no shortcuts)

1. Attitude loop, **P only**, gain low, on the ground with the craft restrained if possible.
   Raise P until response is crisp and *just short* of ringing; back off 30 %.
2. Add **D** (filtered, on measurement). Increase until ringing is damped. If D must be large,
   the loop is running too fast for the actuator — lower the loop rate instead (rule 6).
3. Add **I** last, small, with the clamp already in place. Its only job is steady-state bias.
4. Only then tune the outer altitude loop, at ≤ 1/3 the inner rate, thrust hysteresis first,
   vector trim second.
5. Every gain change gets re-run against `tests/sim.lua` before it goes in the air.

## 6. Offline verification — the plant simulator

`tests/sim.lua` is a lightweight vertical + pitch/roll plant model that deliberately reproduces
the two properties that cause trouble:

- the **16-step thrust quantiser**, and
- **first-order nozzle slew lag** with the measured time constant,

plus sensor noise and a configurable dt jitter. The controller runs against it headless, and the
suite asserts:

- settles to the altitude setpoint within a tolerance and a time limit,
- **no limit cycle** — oscillation amplitude strictly decreasing over the last N seconds,
- no integrator windup after a saturation episode,
- a dt spike (simulated stall) produces no output kick,
- the oscillation detector *does* fire on a deliberately over-gained run (the detector must be
  tested too, not just trusted).

Nothing flies until this suite is green. It is cheap, it runs in CraftOS-PC headless, and it is
the only place we can safely provoke divergence.

## Which nozzles the mixer actually deflects

Worth stating plainly, because the pre-flight screens let you map all of them:

| Group | Thrust | Nozzle |
|---|---|---|
| **lift** | collective + differential | **deflected** — the toe trick for pitch/roll, plus uniform translation |
| **lateral** | translation + yaw | **centred**. `defX = 0, defZ = 0` |
| **main** | forward thrust | **centred**. `defX = 0, defZ = 0` |

So today **only the lift thrusters' nozzle mapping affects flight.** Mapping the lateral and
accelerator nozzles in AXIS MAP records the truth for when the mixer starts using them; it
changes nothing yet, and a wrong mapping on those is currently harmless because a zero
deflection maps to zero whatever the signs say.

### The roll coupling, for when it does

A lateral thruster's nozzle steers **up/down and fore/aft** — it cannot deflect sideways,
because sideways is where it already points. Deflecting it downward tilts its thrust down, so
the reaction pushes that side of the craft **up**:

- **left-side** thruster, nozzle down → left side lifts → **rolls right** (clockwise from behind)
- **right-side** thruster, nozzle down → right side lifts → **rolls left**

That is real roll authority sitting unused, and it is the reason to wire lateral vectoring into
the attitude mixer later: it adds roll that costs no lift, where the lift-thruster toe trick
trades a little. It also means the pilot's mapping of those nozzles has to be right *before*
that change lands, which is what AXIS MAP is for.

> Until then the lateral nozzles are held at centre, so none of this coupling occurs — and the
> attitude loop is not silently fighting an unmodelled moment.

## The two sign conventions, and the bug that lived between them

**Frame:** x = right, y = up, z = forward. Positive pitch = nose up, positive roll = right wing
down, positive yaw = nose right.

Two conventions in this codebase point **opposite ways**, and confusing them is the most
dangerous mistake available:

| Quantity | Means | Example |
|---|---|---|
| `thrustAxis` | **where the thruster FACES** — where its exhaust goes | lift = `down`, accelerator = `back`, lateral = `left`/`right` |
| `defX`/`defY`/`defZ` | **where the nozzle is AIMED**, in the craft frame | positive `defX` aims the exhaust right |
| `translateX`/`translateZ` | a wanted **FORCE** | `+1` = push the craft right |

**The force is opposite the exhaust.** Exhaust down pushes the craft up — that is the only reason
a down-facing lift thruster lifts. So:

- `Mixer:build()` computes `force = −AXIS_VECTORS[thrustAxis]` once, and yaw and lateral
  translation use that force, never the facing.
- Translation into lift-nozzle deflection is **negated**: `defX = toeX − translateX × authority`.
- Toe terms need no negation: they are deflections already, and a pair's horizontal forces
  cancel whichever way it toes.

### Why this was worth hunting

The mixer treated a nozzle aim as a force, **and `tests/sim.lua` made the same mistake** — its
`up` term was negated (a down-facing thruster lifted, correctly) while its `fx`/`fz` followed the
aim. The two errors cancelled, so every translation and drift-damping test passed.

On a real craft they do not cancel: only the software is wrong. **Translation and the flight
assistant would have run backwards** — and an assistant that damps drift by pushing *with* it is
positive feedback: the drift grows, it pushes harder. That is exactly the runaway this whole
design exists to prevent, and it would have appeared on the first hover.

The simulator now models real physics, so it can no longer agree with the same mistake. Ten
tests in `tests/test_loops.lua` pin one direction each **against physics rather than against the
other half of the code**, and each was verified to fail when its fix is reverted.

> One of those tests initially passed *with* the bug reintroduced: the lateral thrusters serve
> the same translation demand and are strong enough to mask a lift-vectoring sign error in a
> whole-craft figure. The assertions now isolate the lift group. A net number is not evidence
> about a part.

---

## The pre-flight sweeps run cold

Both the **SELF TEST** (sweep each group's nozzles) and the **AXIS MAP** (latch one nozzle at full
deflection) exist to answer one question: *is the thruster you assigned to a slot the thruster that
actually moves?* Nothing about that needs thrust, and thrust would move the craft while you are
stood next to it looking at a nozzle.

**The gate is `not engine.master`.** It used to be `GROUND or engine off`, which allowed the test
on a craft parked with the engine **running**, so long as no thruster happened to read thrust at
the instant the button was pressed. A running engine means fuel is reaching the thrusters, so
thrust can appear a tick later — the 1 Hz power re-check would catch that only after up to a second
of sweeping under power. Refusing outright removes the race instead of policing it.

Gating on the engine rather than on `GROUND` also keeps the test available to the half-configured
craft that most needs it: `GROUND` depends on a down-facing laser being assigned, which is one of
the things you are still setting up when you run these.

Three layers, and the sweep itself commands no thrust at all — asserted by a test that stubs
`setThrust`/`setThrustNormalized`/`setPower` on every thruster and drives all 45 seconds:

| Layer | What it stops |
|---|---|
| `engine.master` must be off | fuel reaching the thrusters at all |
| refuse if **known airborne** and making thrust | silencing a craft holding itself up |
| `allStop()` once the checks pass | the mixer's last throttle standing for 45 s |
| thrust surviving a 2.5 s settle aborts the run | fuel reaching a nozzle from elsewhere |

**Actual thrust, not the commanded throttle.** This interlock read `getPower()`, which is the
read-back of `setPower` — so on a craft parked with the engine off it read the altitude loop's own
~20% lift command and told the pilot to cut an engine that was already off. `getPower` is a
throttle; `getCurrentThrustKN` is physics. See [MOD_API_RESEARCH.md](MOD_API_RESEARCH.md).

### A commanded throttle is ours to retract

Refusing to run because a thruster reads thrust was **unsatisfiable in the only situation that
matters.** `Thrusters:apply` runs every control cycle whatever the engine master says, so the
altitude loop holds the lift thrusters at ~20% on a parked craft — and the fuel **tank** feeds those
nozzles directly, so the engine master being off does not make them cold. Measured in the harness on
the pilot's own configuration: engine OFF, throttle 0.2, **24 kN of real thrust**. The reading was
true; the instruction was useless. There was no action that would clear it.

So the sweep **zeroes the throttles itself** and only then judges:

1. refuse if the craft is **known airborne** *and* making thrust (see below)
2. refuse if the engine master is on
3. `allStop()` — retract our own commands
4. let them fade for `SETTLE_MS` (2.5 s), judging nothing
5. after that, check each second; thrust that **outlived** the settle is not ours, so abort with
   `STILL FUELLED` — naming fuel, not an engine switch that does not control the tank

### Never gate on the flight mode

The airborne guard must rest on **evidence**. `groundContact == false` is a laser saying so; `nil`
is the absence of a sensor, which is not evidence.

The mode is not a usable proxy, and got this wrong in both directions at once:

- **Too lax:** a first attempt listed `FLIGHT/HOVER/REVERSE` and silently omitted `BRAKE`,
  `DAMPED` and `FAILSAFE` — all airborne.
- **Too strict:** with no ground sensor *and* no altitude sensor, the mode machine settles on
  **`BRAKE`**. Every "is it airborne" list counts that as flying, so the sweep became unavailable on
  precisely the half-configured craft being wired up for the first time — and unsatisfiably so: no
  laser means the mode never reads `GROUND`, and the thrust is this computer's own command.

The pilot standing next to the craft, reading `GROUND ONLY` on the screen, is a better authority
than a guess. `App:knownAirborne()` refuses only on positive evidence.

The same defect was in the **identify sweep**, gated on `mode == "GROUND"`; it uses the same
predicate now.

## A refusal must not invert when it is truncated

`<id> is producing thrust (0.40) -- cut the engine first` tail-fitted to a 15-column monitor
arrived as **`he engine first`** — which reads as an instruction to *start* the engine, the exact
opposite of the interlock, on a test that must run cold. The pilot read it that way, which is the
only evidence that matters.

So **every refusal returns three values: `ok, long, short`**, and the short form fits 15 columns.
The wording is the craft's responsibility at both lengths; the panel picks a whole string and never
composes one with a substring. `tests/test_vehicle.lua` asserts this for every refusal
`SelfTest:start` and `AxisMap:latch` can produce, so a new one without a short form fails there
rather than shipping and inverting itself in the field.

The UI test for this was **initially a false green**: it asserted the displayed text contained
"cut", and the tail of the shortened long form happens to contain "cut", so restoring the old
`fitEnd` still passed. It now asserts the text *equals* the craft's short form — pin the mechanism,
not a keyword that a broken implementation can satisfy by accident.
