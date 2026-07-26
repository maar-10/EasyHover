# EasyHover — plan

A CC:Tweaked flight-control system for a two-to-four-seat VTOL hovercraft built on
Create: Simulated + Create: Propulsion. Luxury personal transport, not military.

Started 2026-07-26. Target: **MC 1.21.1 / NeoForge**, CC:Tweaked, **Basalt 2.0 full build only**.

Read first: [MOD_API_RESEARCH.md](MOD_API_RESEARCH.md) (what the mods actually expose),
[WIRING.md](WIRING.md) (topology + computer roles), [CONTROL_LAWS.md](CONTROL_LAWS.md)
(the anti-oscillation contract), [NAVIGATION.md](NAVIGATION.md) (nav + autopilot),
[MUSIC.md](MUSIC.md) (what the music module actually requires).

---

## 1. Principles

- **The flight loop is sacred.** Nothing shares its computer, nothing crosses a network hop
  inside it, nothing blocks it. Every other feature is a client of its telemetry.
- **Fully modular, config-driven.** Every peripheral, every keybind, every gain is config, not
  code. Adding a module must never require editing another module.
- **Decisions are pluggable; actuation is not.** Lua indirection costs microseconds, a
  mainThread mod call costs ~50 ms. Abstraction everywhere *except* the actuation path.
  (Same resolution as FireControl.)
- **Config is backward-additive.** `Config.withDefaults` deep-merges over fresh defaults, so an
  old config file loads and gains new fields. (DriveByWire v5 lesson.)
- **ASCII only in anything rendered** (32–126, plus `\7`). CraftOS-PC's font is not the in-game
  font, so headless render tests lie about extended glyphs.
- **Everything self-tested headless before it is handed over.**

## 2. Module map

### `flight/` — the flight computer (no UI, no speaker, no HTTP)

```
startup.lua              launcher -> flight/app.lua  (shell.run, never dofile)
app.lua                  wires modules, owns the single loop and the single clock
lib/
  config.lua             load / withDefaults deep-merge / save / validate
  peripherals.lua        role -> name mapping, rescan, presence tracking, identify
  state.lua              the one snapshot store; every reader reads from here
  log.lua                ring-buffer log + optional file sink
  io/
    sensors.lua          altitude, gimbal, velocity, optical, nav table -> normalised units
    thrusters.lua        write-on-change, quantiser-aware, obstruction + fuel readback
    fuel.lua             tanks() / inventory sensing per thruster group
    relays.lua           failsafe level at boot; aux passthrough
  control/
    filter.lua           first-order LPF, median, rate limiter, hysteresis/Schmitt
    pid.lua              dt-disciplined PID: D-on-measurement, conditional I, clamps
    attitude.lua         inner loop: pitch / roll / yaw rate
    altitude.lua         outer loop: altitude + vertical speed, thrust step + vector trim
    translation.lua      lateral + forward/back demand -> attitude/vector demand
    mixer.lua            {lift,pitch,roll,yaw,latX,latY} -> per-thruster {thrust,vecX,vecY}
    envelope.lua         hard caps: bank, pitch, vertical speed, yaw rate
    oscillation.lua      sign-change detector -> gain scheduling -> DAMPED HOVER
    assist.lua           Flight Assistant: drift damping using all lateral thrusters
    brake.lua            brake law: tilt the lift thrusters into the direction of motion
    modes.lua            feel modes (cruise/rate/stutter) + GROUND/HOVER/PRECISION/BRAKE/
                         DAMPED/FAILSAFE state machine
  guidance/
    position.lua         fix + dead-reckoning fusion; age and quality tracking
    heading.lua          pluggable heading provider (gimbal yaw | course | beacon | nav table)
    autopilot.lua        HOLD / GOTO / ROUTE / RTB / AUTOLAND state machine + interlocks
    l1.lua               pursuit guidance: carrot point, turn anticipation
    autoland.lua         the descend/flare/touchdown sequence and its abort gates
  input/
    bindings.lua         action <- (typewriter key | controller axis/button), fully remappable
    typewriter.lua       POLL getPressedKeyCodes with edge detection (never events)
    controller.lua       tweaked_controller axes/buttons + setFullPrecision(true)
  telemetry.lua          publishes the snapshot on wired rednet at a configurable rate
  link.lua               optional ender-modem link: framing, seq, MAC, replay reject
```

### Other roles — each its own computer, each its own folder

| Folder | Role | Contents |
|---|---|---|
| `ui_main/` | main display + config | gauges (fuel, angles w/ criticality, baro + radar altitude), menu into config screens |
| `ui_pfd/` | primary flight display | animated attitude/roll marker over a moving horizon + flight-path marker |
| `ui_prox/` | proximity | per-surface laser proximity with graded warnings |
| `ui_aux/` | aux control | lights, doors, landing gear via relays |
| `nav/` | navigation | waypoint + route database, map/route UI, **position fixing** (GPS round trips, radar polling), streams fixes to `flight` |
| `music/` | entertainment | search + playlist + DFPWM streaming — see [MUSIC.md](MUSIC.md) |
| `ground/` | ground station | optional ender-modem telemetry receiver, advisory only |
| `tools/` | | `probe.lua`, installer generator |
| `tests/` | | headless logic suite, UI render suite, **`sim.lua` plant model** |
| `vendor/` | | `basalt-full.lua`, pinned |

## 3. On-board comms

- **Wired rednet** for everything on board. Protocols: `eh_telemetry` (flight → all, ~10 Hz),
  `eh_command` (UI → flight, validated + rate-limited), `eh_config` (UI ↔ flight),
  `eh_aux` (UI → aux).
- **Flight never depends on a reply.** If a UI computer is gone, the loop does not notice.
- **Commands are advisory and envelope-checked** on the flight side. A malformed or
  out-of-envelope command is logged and dropped, never clamped silently into something surprising.
- **Ender modem link** (`link.lua`) is opt-in and off by default. Lightweight framing:
  `{proto, seq, ts, payload, mac}` with a pre-shared key, truncated-SHA256 MAC, monotonic
  sequence for replay rejection, and a receive rate limit. **It carries telemetry outward only —
  it can never command the flight loop.** That constraint is structural, not configurable.

## 4. Phases

**Sequencing rule: the autopilot comes after manual flight is proven in the air.** An autopilot
built on an untuned controller just automates a crash, and you can't tell a guidance bug from a
control bug when both are new. Phases 13–15 do not start until phase 3's gains are flown.

| # | Phase | Depends on | Notes |
|---|---|---|---|
| **0** | **Probe** | *user* | `tools/probe.lua` on the assembled craft. Unblocks tuning **and** answers the heading question nav depends on. Not a blocker for 1–5. |
| 1 | Core scaffolding | — | config, peripherals, state, log, test harness. |
| 2 | IO layer | 1 | sensors, thrusters (write-on-change), fuel, failsafe relay, identify. |
| 3 | **Control + `tests/sim.lua`** | 1, 2 | pid/filter/mixer/attitude/altitude/envelope/oscillation, verified against the plant sim. Real gains wait for phase 0. |
| 4 | Inputs | 1 | typewriter (poll) + controller, fully remappable bindings. |
| 5 | Telemetry + link | 1 | wired rednet first; ender link after. |
| 6 | `ui_main` + config screens | 5 | tabbed, no dropdowns (DriveByWire v3 lesson). |
| 7 | `ui_pfd` | 5 | the animated PFD. |
| 8 | `ui_prox` | 5 | proximity warnings. |
| 9 | Annunciator | 5 | alarm speaker: critical angle, sink rate, oscillation, fuel, proximity. Ducks the music. |
| 10 | `ui_aux` | 5 | lights / doors / gear. |
| — | **Manual flight verified in-game** | 0–4 | **Gate.** Tuned, stable, flown. |
| 11 | `nav/` — position + waypoints | 5, gate | fix sources, fusion, waypoint DB, three creation paths, disk import/export. |
| 12 | Nav UI + map | 11 | route builder, per-leg speed/altitude, live map. |
| 13 | Autopilot: HOLD + GOTO | 11, 12 | plus every interlock, exercised in `sim.lua` first. |
| 14 | Autopilot: ROUTE + RTB | 13 | multi-leg, turn anticipation. |
| 15 | AUTOLAND | 13 | laser-referenced descent, flare, abort gates. |
| 16 | Music | 5 | [MUSIC.md](MUSIC.md) — needs the external service decided first. |
| 17 | Installer + repo | all | role-prompt installer (DriveByWire pattern), then the `new-project-repo` skill. |

## 5. Risks and flags

**Flagged because they affect usability of the flight functions:**

1. **Thrust is 16 steps, not continuous.** Mitigated by the authority split in
   [CONTROL_LAWS.md](CONTROL_LAWS.md). If hover precision is still unsatisfying after tuning,
   the only continuous path is `creative_vector_thruster.setThrustOutput(pN)` — a creative
   block. That is a build decision, not a code one.
2. **Nozzle slew rate is unknown and it caps the attitude-loop bandwidth.** Until the probe
   measures it, any gain set is a guess. Phase 3 code is written parameterised on it.
3. **`mainThread` budget.** Write-on-change keeps steady hover cheap. If it still binds, the
   next move is *fewer thrusters with more authority*, or splitting non-flight work further —
   never splitting the loop.
4. **Assembly/disassembly reboots the computers** (cf. SecDoor). Peripheral loss must be a
   normal recoverable state: rescan, re-apply failsafe, resume in GROUND mode.
5. **Music needs an external service.** Transcoding is impossible inside CC, so a search +
   DFPWM service is a hard dependency. Full requirements and the three ways to get one are in
   [MUSIC.md](MUSIC.md). Audio only, own computer, phase 16.
6. **Absolute heading may not exist yet.** If `gimbal_sensor.getAngles()` has no yaw component,
   nav needs one of the fallbacks in [NAVIGATION.md](NAVIGATION.md) — course-over-ground doesn't
   work in a hover, so this genuinely gates the nav design. The probe's yaw test answers it.
7. **Gimbal/velocity/altitude units and axis order are unknown.** Every sensor read goes through
   `sensors.lua` normalisation so a probe surprise changes one file.
8. **There is no obstacle avoidance and there cannot be.** Lasers are single-ray; nothing sees
   terrain ahead. Route altitudes must clear terrain by design. This is stated in the UI, not
   just in the docs.

**Dropped:** Vista. It only ever offered camera aiming (no pixels), its projector is unreachable
on NeoForge, and rendering from a moving sub-level was unverified — nothing it provides is worth
the risk for this vehicle. Removed from scope 2026-07-26.

## 6. Open decisions for the pilot

- Thruster count and layout (4 lift + 4 lateral assumed; the mixer is layout-driven config).
- Primary input: controller, typewriter, or both live at once (both is supported).
- Whether `ui_prox` gets its own computer or shares with `ui_main`.
- Whether the ender-modem ground station is wanted at all.
- **Position source: GPS constellation, on-board Create Radar, or both** (see
  [NAVIGATION.md](NAVIGATION.md)). Both is best — they cover each other's failure modes.
- Which music backend (public instance / self-hosted / ours) — [MUSIC.md](MUSIC.md).
