# EasyHover — flight modes, flight assistant, and braking

The pilot's specification, written down as a contract. Where a requirement runs into a
hardware limit, that is called out here rather than quietly reinterpreted in code.

---

## 1. Thruster layout

| Group | Count | Job |
|---|---|---|
| **lift** | 4 | Lift, hover, pitch, roll — **and braking** (§5). Down-facing, vectored. |
| **main** | 1+ | Main forward thrust for high speed. |
| **lateral** — yaw pair | 2 | Yaw in every mode; also translate in Precision mode and for the assistant. |
| **lateral** — rear pair | 2 | **Idle in normal flight.** Used only in Precision mode and by the Flight Assistant. |

Config marks each lateral thruster with `yawAuthority` (contributes to yaw) and
`precisionOnly` (idle unless Precision mode or the assistant is damping). The mixer is
driven entirely by that, so a layout change is a config change.

## 2. Lateral movement modes

**Flight mode** — steer like an aircraft. Turning left or right *rolls* into the turn, and
pitch (pulling up) tightens it. Rudder (yaw) is available as an additional input, not the
primary one. The rear lateral pair stays idle.

**Precision mode** — direct translation using **all four** lateral thrusters, no banking
required. Automatically selected in landing mode and by the autopilot's autoland.

## 3. Control feel modes

| Mode | Attitude | Forward thrust |
|---|---|---|
| **Cruise** (default) | Stick commands an **angle**; release returns to neutral and holds level. Fly-by-wire, luxury feel. | **Holds its level.** Accelerate/decelerate inputs adjust it; releasing them keeps the current setting. |
| **Rate** | Stick commands a **rotation rate**; release stops rotating and holds the attitude reached. Steering-wheel feel. | Same as Cruise — holds its level. |
| **Stutter** | Same as Cruise — angles revert to neutral on release. | **Decays to zero** on release, and ramps up **faster** than the other modes while accelerating. |

Note the deliberate asymmetry in Cruise and Rate: *angles* return to neutral, *thrust* does
not. Releasing the stick should level the craft, not stop it.

## 4. Flight Assistant

Separate from the autopilot. **Enabled by default, switchable off.**

- Uses **all** directional thrusters — including the rear pair that normal flight leaves
  idle — to **damp drift**: after a turn, it cancels residual lateral movement until the
  craft is tracking straight ahead.
- **Never fights deliberate input.** Suppressed while a steering or thrust input is active,
  and for a short hold-off afterwards.
- **Force-disabled in Rate mode**, where holding an attitude is the point.

## 5. Braking

Manual brake, Brake mode, and the autopilot all use the same law:

> Pitch and/or roll the craft so the **lift thrusters face into the direction of motion**,
> using their thrust to oppose it.

Constraints, all of them mandatory:

- **Proportional, not binary.** Tilt scales with speed, so the slightest drift does not
  produce a lurch. Below `brake.minSpeed` there is no braking at all.
- **Hard tilt cap** (`brake.maxTiltDeg`) — the brake is not allowed to command an attitude
  the attitude loop cannot hold calmly.
- **Rate-limited tilt-in** (`brake.tiltRateDps`), so braking cannot step-excite the
  airframe.
- **Subject to the oscillation detector like everything else.** If braking starts a
  cross-coupled oscillation, gains are cut and the brake authority goes with them.

### Brake mode

An **internal** mode, entered automatically whenever **the Flight Assistant is engaged AND
forward thrust is zero**. It brakes and then holds position.

---

## 6. ⚠️ The hardware gap this specification runs into

**Damping drift and braking into the direction of motion both need a velocity *vector*.
The sensor set we have confirmed only provides a scalar.**

`velocity_sensor.getVelocity()` returns a single unsigned number. It cannot tell forward
from sideways, or forward from backward. Nothing else on board supplies a horizontal
velocity direction: the gimbal gives attitude, the lasers give distance, and vertical speed
we already have to obtain by differentiating baro altitude.

So, in preference order:

1. **Mount two or three velocity sensors on different axes** — forward, right, and
   optionally up. Config maps each one to a craft axis with a sign
   (`hardware.sensors.velocityVector`), and `sensors.lua` assembles them into a proper
   vector. This is the clean fix and it is a wiring job, not a code one.
   *To verify, two things:* Simulated's velocity sensor has a scroll value box whose
   meaning (measured axis? range?) is undocumented — mount a second sensor facing sideways
   and the probe will show whether the two read differently. **And whether `getVelocity()`
   is signed along its axis, or only a magnitude.** Its redstone output cannot be negative,
   so the Lua getter may well be unsigned too. If it is, an axis-mounted sensor still
   cannot tell left drift from right drift, and `sensors.velocity.signed = false` makes the
   assistant degrade rather than push the wrong way. Check by reversing the craft and
   watching for a negative value.
2. **Derive drift from position fixes** (GPS or Radar, phase 11) — works, but at 5–10 Hz
   with latency. Adequate for slow drift damping, too coarse for crisp braking.
3. **Neither available** → the Flight Assistant and the brake law **degrade and annunciate**
   rather than guess. Attitude and altitude control are unaffected; they never needed a
   velocity vector.

The code is written for case 1 with graceful fallback to 2 and 3, so mounting the extra
sensors later is a config edit. But **the assistant and braking will not be fully functional
until those sensors exist**, and I would rather say so now than ship something that appears
to damp drift while actually guessing at its direction.
