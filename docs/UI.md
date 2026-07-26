# EasyHover — the UI computer

The `ui_main` role renders every cockpit screen. It runs on its **own computer**, never on the
flight computer: a CC computer is one single-threaded Lua VM, so a Basalt redraw and the control
loop would take turns on the same CPU, and the resulting `dt` jitter eats directly into the gain
margin the whole control design depends on ([CONTROL_LAWS.md](CONTROL_LAWS.md) §3 rule 6).

**A monitor is a network peripheral, so this costs you nothing in the cockpit.** Screens sit
wherever you mount them; which computer *draws* them is unrelated to where they are.

## Panels

A **panel** is a UI definition. It can be assigned to **several monitors**, which is how
mirroring is expressed — the overhead pair and the PFD each show the same thing on either side
of the cockpit.

| Panel | Status | What it shows |
|---|---|---|
| **overhead** | **live** | Engine start/stop with a countdown to the next feed, and both fuel gauges. **No configuration** — that moved out, which is what freed the rows. Built for a 1×2 portrait screen. |
| **config** | **live** | Every craft setting, reached from a menu. Nothing else. |
| pfd | reserved | Attitude / flight-path indicator. Mirrored pair. |
| autopilot | reserved | Autopilot settings. |
| nav | reserved | Waypoints and the map. |

The UI computer's **own terminal** is not a panel. It runs one screen — which monitor shows
which panel — and it always runs it.

## Where each setting lives

Three screens, three jobs, and the split is deliberate:

- **The UI computer's terminal** owns *which monitor shows what*. That is a property of this
  computer, not of the craft, and this is the one screen that exists before anything has been
  assigned — so it is both the right home for the setting and the only possible bootstrap.
- **The config monitor** owns *every craft setting*, and nothing else. Its home page is a menu
  and only a menu; there are no flight values on it.
- **The overhead panel** owns *what you read while flying*. It configures nothing.

Mixing configuration into the overhead panel cost it the rows it needed for gauges, and mixing
flight values into the config screen made a menu you had to hunt through. Separating them fixed
both at once.

## The config menu

| Entry | What it sets |
|---|---|
| **ENGINE** | The funnel relay and its side, the engine vault, and (under **TIMES**) the feed pulse and interval |
| **LIMITS** | Bank, pitch, climb, sink, yaw rate and brake tilt |
| **LIFT THR** | The four lift thrusters — FL, FR, RL, RR |
| **ACCEL THR** | The four main accelerators |
| **LAT THR** | The four lateral thrusters; the front pair steers, the rear pair is precision-only |
| **VELOCITY** | One velocity sensor per axis, named for what it measures: **MEDIAL** (forward/back), **LATERAL** (left/right), **VERTICAL** (up/down) |
| **ALT+GIMBAL** | The altimeter, the attitude gimbal, and the **down-facing laser** — that one is the radar altimeter, so it belongs with height rather than with the obstacle rays |
| **FUEL TANK** | The liquid tank and its gauge scale |
| **OPTICAL** | The proximity lasers — forward, back, left, right |
| **DISK** | Save and load every config to a floppy |

The menu pages itself when the screen is too short for all ten.

## Assigning hardware

Every hardware page is the **same widget** (`ui/slots.lua`), differing only in its slot list and
which candidate list it draws from. Two pages, because 15 columns cannot show both:

- **the slots** — every named role with what currently fills it, and `2 of 4 set` so you can see
  what is left. Tap one.
- **the candidates** — everything the craft can see for that role, `(none)` first so the choice
  is always undoable. Tap one and it returns to the slot list.

**The candidate lists come from the flight computer** over telemetry, not from the UI's own
peripheral scan. Both see the same wired network, but the flight computer is the one that will
actually open these peripherals, so its names are the authoritative ones.

### The geometry you are not asked for

The screens ask *which peripheral is the front-left lift thruster*, never *what are its
coordinates* — but the mixer needs a moment arm, and a thruster at the origin produces no pitch
or roll at all. `App.SLOT_GEOMETRY` fills that in from the slot name. **The signs are what
matter**: they decide which way the craft rotates when a corner pushes harder. The magnitudes
are a unit default that scales gains, and an unusual frame can tune them in the config file.

The same table is why the lateral front pair gets `yawAuthority` and the rear pair
`precisionOnly` without anyone being asked ([MODES.md](MODES.md)).

### Slot keys are per group; ids are not

`fl` is a corner of the **lift** set *and* of the **lateral** set, so a slot key only means
something alongside its group. But the **id** is what the mixer addresses a thruster by, and
those must be unique across the whole craft — so `setSlot` stores `lift_fl` and `lateral_fl`,
and `Config.slotKey` strips the prefix back off to recover the slot.

> Storing the bare key was a real bug: with the lift corners assigned, **every** lateral
> assignment came back `CRAFT REFUSED`, because the validator correctly refuses a duplicated id.
> It is also why the original naming scheme was group-prefixed, which is worth knowing before
> "simplifying" it again.

**A nozzle can only be in one slot.** Assigning one that is already used elsewhere *moves* it,
and a config with the same peripheral in two entries is refused — the mixer would otherwise
command that nozzle twice, with two different values, and fight itself.

### Axis names, not axis letters

The velocity page says MEDIAL, LATERAL and VERTICAL. `x`/`y`/`z` depend on whose convention you
mean and which way the sensor is bolted on, and a sensor on the wrong axis makes the flight
assistant push the craft the wrong way. The config keys stay `x`/`y`/`z`, because that is what
the control code reads.

## The engine feed interval

Shown and set in **minutes and seconds**, from 15 s to 1 hour, default 1 minute, with **two step
sizes**: ±1 s to land on a number and ±15 s to cross an hour without wearing out a button.

It is not a cosmetic unit choice. The interval has to roughly match **one fuel unit's burn
time** — minutes, for blaze cake. Feed faster and the engine hoards a whole stack, which means
it keeps running for over an hour after the master switch goes off and burns the lot whether the
craft needs it or not. Matched to the burn time, it takes only what it needs and a shutdown
costs at most one unit.

A config written before this range existed is **clamped, not rejected** — `Config.migrate`
raises an out-of-range interval to the floor and reports that it did. Refusing to boot over a
setting the pilot never chose would be the wrong answer.

## How mirroring actually works

Verified from Basalt 2.0's source, because the obvious approach is the wrong one:

- `basalt.createFrame()` then `frame:setTerm(monitor)` is the whole binding. The `term` property
  setter registers the frame in Basalt's `activeFrames`, records `peripheral.getName(monitor)`,
  builds the render target, and sizes the frame from `monitor.getSize()`.
- `renderFrames()` iterates **every** active frame, so several monitors render natively.
- `monitor_touch` is dispatched to every frame, and each one filters on its own
  `_peripheralName` — per-monitor touch routing is built in.

> So mirroring is **one frame per monitor**, each built from the same data model — not one frame
> fanned out to a proxy terminal. A proxy has no peripheral name, so Basalt could not route
> touches to it: the buttons would render on both screens and respond on neither.

`Monitors:update(model)` pushes one model into every instance, so two mirrored screens cannot
disagree.

## Fitting a 1x1 monitor

Both panels compute their layout from the frame's real size. The config panel has a **narrow
mode** below 26 columns: shorter labels, the menu stacked into a 2×2 grid, and the live-value
block taking whatever rows are left. Minimum 14×9; below that it says which size it needs rather
than drawing nonsense.

`Theme.fitEnd` keeps a peripheral name's **tail** when it will not fit, because truncating
`redstone_relay_1` to `redstone_relay_` renders `relay_0` and `relay_1` identically.

## Assigning monitors

On the UI computer's **own terminal**, always — see *Where each setting lives*. Every monitor on
the network is listed with its size and current panel; tapping cycles it: *none → overhead →
config → pfd → autopilot → nav → none*. Each change saves immediately, because a half-made
assignment lost on reboot is worse than one you have to undo.

A cockpit with nothing assigned yet is therefore never a dead end: the screen that does the
assigning is the computer's own terminal, which cannot be unassigned.

## Telemetry

The flight computer broadcasts a compact snapshot on `eh_telemetry` at `tuning.telemetryHz`
(default 10 Hz) over **wired** rednet. The UI subscribes and keeps the latest payload *with its
age*.

**Age is part of the model.** A panel showing a two-second-old number as though it were live is
worse than one saying `NO DATA`, so every panel blanks its gauges and shows the banner when the
link goes quiet. `basalt.onEvent("rednet_message", ...)` hooks this into Basalt's own loop — no
second coroutine competing for events.

## Commands

Buttons send whitelisted commands on `eh_command`. **The flight computer validates every one on
arrival** — name whitelist, per-field type check, enum check, and a rate limit — because a UI is
not a trusted peer, just another computer on the wire. Config edits go through `Config.set`,
which re-validates the whole config and **puts the old value back** if the result would be
invalid.

Available: `engineMaster`, `engineFeed`, `setAux`, `setFeel`, `setLateral`, `setAssist`,
`setAltitude`, `identify`, `configSet`, `configSave`, `diskSave`, `diskLoad`, `ping`,
`setEngineRelay`, `setTank`, `setVault`, and **`setSlot`**.

`setSlot { kind, key, peripheral }` is the one command behind every hardware page — `kind` names
the family (`lift`, `main`, `lateral`, `velocity`, `altitude`, `gimbal`, `optical`) and `key` the
slot inside it. An empty peripheral unassigns. It exists rather than eight commands because they
would differ only in which list they edit, and because the flight side has to *create* entries
that `configSet` deliberately refuses to invent. The craft re-validates the whole config after
every one and **puts the previous state back** if the result would be illegal.

`identify` is gated on the craft actually being in `GROUND` state — on the flight side, not on
the sender's say-so.

## No optimistic feedback

**A panel never draws a state it only asked for.** Every gauge, label and highlight reads what
the flight computer *reported*; a button press sends a command and changes nothing on screen by
itself. This is a standing rule across EasyKey and DriveByWire too, and it is not stylistic.

The panels run on a different computer from the thing they control, over rednet. A screen that
draws its own request is lying whenever the command is refused, rate-limited, dropped, or the
link is down — and the pilot cannot tell that apart from a screen that worked. It also *hides
transport bugs*: while the UI computer was flooding its own event queue (see below) and dropping
telemetry, the single control that still looked healthy was the one that had been made optimistic.

Two things are legitimately local and do render immediately, because this computer genuinely is
the authority on them:

- **Which panel is on which monitor** — that lives in the UI computer's own config.
- **A choice staged before anything is assigned** — the relay *side* with no relay assigned yet.

Saying that a request went out is also fine, because it is a fact about this computer rather
than a claim about the craft: `sent, waiting` on the hardware picker, `saving...` on the disk
page. These clear when the real state confirms, and a refusal is shown rather than swallowed.

## Hardware changes apply live

Assigning a thruster from the config screen used to change the config file **and nothing else**.
A `per:scan()` alone is not enough: the mixer builds its control matrix once, the thruster layer
caches what it last wrote, and the layout and velocity capability are published from `boot()`.
The craft therefore kept flying on its old mixer until someone rebooted the flight computer —
which is how it was reported from the cockpit ("I have to restart the flight controller").

`App:rebuildHardware()` re-derives all of it, and every `setSlot` calls it. It performs the same
list `boot()` does, deliberately: **if a hardware change needs it at startup, it needs it now.**

> Separately, and not the same thing: after the Suite *updates* a computer, that computer is
> still running the code it loaded at boot. CC loads a program once; new files on disk do
> nothing until something starts them. The Suite now says `REBOOT THIS COMPUTER` rather than
> leaving it as a dim hint, because updating a running cockpit and then finding the new buttons
> dead is the obvious trap.

## The event-queue trap

`basalt.onEvent("timer", ...)` fires for **every** timer on the computer, including Basalt's own
— a lazy-element pass every 0.2 s, and a `sleep(0.1)` after every single `monitor_touch`. A
heartbeat handler that re-arms itself without checking the id therefore spawns a **new,
permanent** refresh chain out of every stray timer, several times a second. They accumulate;
within a minute hundreds of chains are each pushing a full model into every monitor, CC's
256-event queue overflows, and it starts **dropping `monitor_touch` and `rednet_message`**.

The cockpit symptom is not a crash. It is sluggish buttons, controls that do nothing, and gauges
that stop tracking — exactly what a "the UI is broken" report looks like. `App:onTimer` checks
the id and returns early, and `tests/test_ui.lua` fires 50 foreign timers to prove none of them
refresh or re-arm anything.

## Two Basalt details worth remembering

Both cost a debugging round and are noted where they bite:

- **`isInBounds()` compares against an element's x/y in its *parent's* coordinate space.** A
  simulated click at (1,1) silently misses.
- **Basalt coalesces two clicks on one element within 0.4 s into `mouse_double_click` *instead
  of* a second `mouse_click`.** A plain `onClick` handler never sees it, so the button eats every
  rapid second tap — which in the cockpit reads as a dead control: you tap, nothing appears to
  happen, you tap again, and the second tap is the one thrown away. `Theme.button` therefore
  wires **both** events to the same handler, which is why every button in the cockpit is safe
  rather than just the one that was reported. The tests used to `sleep(0.45)` between taps, which
  hid this for weeks; they now tap with no delay and one test taps the same row three times in a
  row on purpose.
- **Never stash state on a Basalt element.** The property system owns field access, so an
  arbitrary key like `_master` is not a safe place to keep anything — panels keep their last
  reported state in a closure instead.
- **Register click handlers once.** Basalt *appends* callbacks rather than replacing them, so
  re-registering on every refresh made one tap cycle an assignment several times.
- **A label auto-sizes to its text, so an empty one reports width 0.** Reading a width back off
  an element and passing it to `Theme.fitEnd` then truncates to nothing — a blank row that looks
  exactly like missing data. Hold the width you laid the element out with, in a local.
- **Redraw on the tap, not on the next data frame.** A handler that only mutates state leaves
  the label under the pilot's finger stale until something else triggers a refresh. Both the
  monitor rows and the hardware widget's `>` had this bug in the first dry run.

## Testing

```bash
bash tests/run_ui.sh
```

Its own CraftOS instance, on purpose: both roles have a `lib/config.lua`, so a shared Lua state
would make `require("lib.config")` ambiguous — and it would resolve to the flight one. Different
computers in game, different interpreters in test.

The panels are built against **real Basalt**, rendering into real `window` objects, and the
tests assert on the text that ended up on screen rather than on the model — so a panel that
silently stops updating is caught.

Two click paths are exercised, deliberately. `click()` dispatches `mouse_click` on an element,
which is fast and enough for most assertions. `tap()` dispatches **`monitor_touch` on the frame**
— the event CC actually delivers — so `BaseFrame`'s peripheral-name routing and its
`mouse_click(1, x, y)` translation are under test too. The double-click bug above was only
reachable through `tap()`.
