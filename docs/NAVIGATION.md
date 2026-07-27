# EasyHover — navigation and autopilot

Design for the nav system and the autopilot. Options are laid out with trade-offs where the
choice is yours; recommendations are marked.

---

## 1. The load-bearing question: where are we?

Nothing in Create: Simulated reports absolute position. There is no `getPosition()` on any of its
peripherals. So position has to come from somewhere else, and this is the decision the whole nav
system rests on.

| Source | Gives | Infrastructure needed | Cost | Verdict |
|---|---|---|---|---|
| **CC GPS** — `gps.locate()` | exact `x, y, z` | 4+ host computers with wireless modems at known coords, within range; one wireless/ender modem on the craft | a blocking network round trip (~2 ticks) | **Recommended primary.** Vanilla CC, exact, and Sable patches CC's wireless distance math so it works from inside a moving sub-level. Must run on the nav computer — never inside the flight loop. |
| **Create: Radar** — `radar.getPosition()` / `plane_radar.getPosition()` | exact `x, y, z` of the radar block | a radar mounted on the craft | `mainThread` — 1 tick per call | **Recommended backup, or primary if you'd rather not build a GPS constellation.** No external infrastructure, and `getTracks()` gives you traffic awareness for free. |
| **Dead reckoning** — heading + `velocity_sensor` | position *estimate* | none | free | Gap-filler between fixes only. Drifts without bound. **Never primary.** |
| **`navigation_table.getRelativeAngle()`** | bearing to its item-configured target | nav table + a target item (lodestone/compass/magnet) | free, not `mainThread` | Emergency homing. One target at a time, configured physically, no range. |
| **`directional_link.getClosestAngle()` + `modulating_link.getClosestDistance()`** | bearing **and** range to the nearest Redstone Link on a frequency | a Redstone Link beacon at the waypoint | free, not `mainThread` | **Beacon navigation — a VOR/DME analogue.** If the usable range is decent this is the best precision-approach aid we have. Probe measures it. |

**DECIDED: GPS as primary**, over an ender modem, served by four `gps_beacon` computers --
see [GPS.md](GPS.md) for what CC's GPS actually requires and how the beacons are built. Radar
remains available as a backup source; dead reckoning smooths and fills gaps and is always
marked as an estimate. Every fix carries `{x, y, z, age, quality, source}` so
guidance can refuse to act on a stale one.

### Heading is the open question

Attitude comes from `gimbal_sensor.getAngles()`, but we don't yet know whether that list includes
**yaw** or only pitch and roll — and a nav system needs absolute heading. The probe now has a
dedicated yaw test for exactly this. Fallbacks in preference order if yaw is not there:

1. **Course over ground** from successive position fixes — exact, but only valid while moving.
   Useless in a hover, so it cannot be the only source.
2. **Beacon bearing** (`directional_link`) to a known-position link — works stationary.
3. **`navigation_table.getRelativeAngle()`** against a fixed target — works stationary, one target.
4. A **swivel-bearing-mounted sensor** as a mechanical compass — last resort, adds moving parts.

Until the probe answers this, guidance is written against a `heading()` provider interface with
these as interchangeable implementations. One file changes when we learn the answer.

---

## 2. Waypoints

Stored on the nav computer, `textutils.serialise` format, schema:

```lua
{ name = "Home Pad", x = 128, y = 71, z = -344, kind = "pad", note = "" }
-- kind: "nav" | "home" | "pad"   (pad = autoland-capable, home = RTB target)
```

Your three creation paths, all in the nav UI:

1. **Predefined library** — a shipped/edited `waypoints.tbl`. Import/export **via floppy disk**
   (the DriveByWire `disk.lua` pattern: write + verify readback) so a waypoint set can be carried
   between vehicles or backed up off-craft.
2. **Mark current position** — one button. It stores **the last real fix, never the
   dead-reckoned estimate**, and *refuses* if the fix is older than the configured age limit or
   its quality is low. A marked pad you can't trust is worse than no pad.
3. **Manual coordinates** — numeric entry with validation, optional snap-to-integer, and a
   "preview distance/bearing from here" readout so a typo is obvious before you save.

## 3. Routes

```lua
{
  name = "Home -> Mine",
  legs = {
    { to = "Waypoint 2", speed = 8.0, altitude = 95, arrivalRadius = 4, yawMode = "track" },
    { to = "Mine Pad",   speed = 3.0, altitude = 80, arrivalRadius = 2, yawMode = "hold",
      action = "land" },
  },
}
```

- A route can be **two waypoints**, **current position → waypoint** (a synthetic first leg), or
  **many legs with per-leg speed and altitude** — all three are the same structure.
- `yawMode`: `track` (nose along course), `hold` (keep current heading — the luxury-craft
  sideways-drift look), or `poi` (nose at a chosen waypoint).
- `action` on arrival: `none`, `hold <seconds>`, `land`.

---

## 4. Where the autopilot runs

**Guidance runs on the flight computer. The nav computer owns the database, the map UI, and
position fixing.**

That may look like it contradicts "never split a control loop", so here is the reasoning:

- Guidance bandwidth is **~1 Hz** — it emits *setpoints* (target heading, ground speed,
  altitude), not actuator commands. That makes the nav→flight hop a proper **cascade boundary**,
  where latency is harmless. The fast attitude and altitude loops stay entirely local.
- **Position fixing must not block the flight loop.** `gps.locate()` waits for replies and
  `radar.getPosition()` is `mainThread`. Both belong off the flight computer.
- Guidance itself is pure math with no peripheral calls, so it is nearly free and belongs where
  it can **degrade safely**.

**If the nav computer dies:** the autopilot loses its fixes, disconnects, and drops to altitude +
attitude hold using on-board sensors only, with full annunciation. Manual flight is completely
unaffected — it never needed position at all.

Nav computer streams `eh_navfix` at 5–10 Hz plus the active route on change. Flight fuses fix +
dead reckoning into one position estimate with an age and quality it can reason about.

## 5. Autopilot modes

| Mode | Behaviour |
|---|---|
| **HOLD** | Hold current position + altitude. With a fix: true position hold. Without: velocity-nulling drift hold, clearly annunciated as degraded. |
| **GOTO** | Direct leg to one waypoint at a configured speed and altitude. |
| **ROUTE** | Multi-leg, per-leg speed/altitude/yaw/action. |
| **RTB** | GOTO the `home` waypoint, then optionally `land`. |
| **AUTOLAND** | The sequence below. |

### Guidance law

**L1 / pursuit guidance**, deliberately, because it does not oscillate: pick a "carrot" point a
configurable distance ahead on the leg and steer at it. Cross-track error is corrected implicitly
by the geometry rather than by a high-gain feedback term, which is precisely how cross-track
oscillation gets designed out instead of tuned out. On top of that:

- **Turn anticipation** — start the turn to the next leg early, based on ground speed and the
  envelope's max bank, so the craft flies a rounded corner instead of overshooting and
  S-turning back.
- Speed demand → forward tilt demand, **rate-limited and envelope-capped**.
- Altitude demand goes to the existing altitude loop untouched.
- All guidance output passes through `envelope.lua`. **The envelope always wins.** The autopilot
  is just another setpoint source with no special privileges.

### Autoland sequence

1. **Arm** over a `pad` waypoint. Refuses without a fresh fix and a `pad`-kind waypoint.
2. **Align** — hold position over the pad until lateral speed is below threshold.
3. **Descend** at the configured rate on baro altitude.
4. **Switch to laser** below the configured height — the down-facing `optical_sensor` becomes the
   altitude reference, because baro is relative to sea level and the pad is not.
5. **Flare** — reduce to touchdown descent rate.
6. **Touchdown detect** — laser distance minimal *and* vertical speed ≈ 0 *and* the thrust
   needed drops. Then thrust to the failsafe idle level, AP disarms, gear/brakes per config.

**Abort to a climb-and-hold** on any of: lateral drift over limit, `getBlock()` reporting a
block id that isn't in the configured pad whitelist, thruster obstruction, oscillation detector
firing, or the fix going stale. Aborting is the default; landing is the exception that has to earn
its way through every gate.

## 6. Interlocks — read this part twice

- **Any pilot input disconnects the autopilot instantly**, exactly like a real one. No modes, no
  fighting the pilot.
- **A stale position fix disconnects it** and degrades to HOLD.
- **Geofence + hard altitude floor**, independent of any route.
- **Terrain floor** — the down laser can trigger a climb if the ground closes on you.
- **This is not obstacle avoidance, and it must never be sold as such.** The lasers are
  single-ray; nothing can see terrain *ahead*. **Route altitudes must clear the terrain by
  design.** A forward-facing laser can add a crude "something ahead → stop and hold", and that is
  the honest limit of it.

## 7. Verification

`tests/sim.lua` gains a horizontal plane plus fix latency and noise. The suite must show:

- route tracking converges, and **cross-track error never oscillates** — strictly decreasing
  envelope on the last N seconds of a leg;
- turn anticipation produces no overshoot at the configured max bank;
- autoland touches down within the configured vertical speed limit;
- **every abort path fires when provoked** — stale fix, wrong pad block, drift, obstruction;
- a nav-computer dropout degrades to hold and annunciates, and never produces a control
  transient.

---

## The nav computer, as built

Installed with the Suite as the **nav** role. It needs **two modems**: an ender modem for GPS and
the beacon mesh, and a wired one for the craft's cable. Half of that is a specific failure the
screen names, because a nav computer with no radio cannot fix and one with no cable cannot tell
anyone.

```
EasyHover NAV
position  128 82 -344
  from gps  0.2s old  q 1.00
heading   47  NE
---------------------------------------------------
radio modem_0   cable modem_1
published 1842 fixes
  gps  ok 1840  failed 2
---------------------------------------------------
waypoints 3
  Home Pad  SW 214  86m
  North Ridge  N 4  1240m

[M] mark here                        [A] add coords
[D] delete                             [L] list all
[F] fix now                                [Q] quit
```

**Keyboard-driven, plain `term`, no Basalt.** This screen has to *type* things — a waypoint name
and three coordinates — and a mouse helps with neither. (The nav computer is advanced, so a mouse
would work here; it just would not help.)

When GPS drops, the estimate takes over and **says so on its own line**:

```
position  131 82 -350
  DEAD RECKONED -- this is an estimate
  from estimate  3.1s old  q 0.62
```

That flag was originally appended to the end of the source line, where a 51-column screen
truncated away the single most important word on the page.

### Heading comes from the flight computer

Over telemetry — this computer has no gimbal. If `attitude.yaw` is absent the screen says
**`heading NONE -- dead reckoning cannot run`**, because craft-frame velocity cannot be rotated
into world axes without it and `Fix:reckon` refuses rather than integrating garbage.

### The three waypoint paths, all live

- **[M] mark here** — from the last real *fix*. Refuses a dead-reckoned or stale one: a pad you
  cannot trust is worse than no pad, because you would fly to it and find open air.
- **[A] add coords** — typed, with a **preview** before saving. A stray zero shows up as
  `100000 blocks from here`, which is the whole reason to type them here rather than edit a file.
- **[L] list all** — nearest first, with bearing and range.

Both `/eh_waypoints.tbl` and `/eh_routes.tbl` are **protected paths**: the Suite never deletes
them, and the e2e suite asserts a `--repair` leaves them intact with their contents.
