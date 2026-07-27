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
| **nav** | **live** | The map and waypoints come later, so the centre is empty on purpose. Its border carries the two pre-flight screens. |
| pfd | reserved | Attitude / flight-path indicator. Mirrored pair. |
| autopilot | reserved | Autopilot settings. |

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
| **THR AXES** | Which way each thruster's nozzle points in the craft's frame |
| **KEYS** | The typewriter keybind for each of the 17 flight actions |
| **DISK** | Save and load every config to a floppy |

The menu pages itself when the screen is too short for all twelve.

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

## The pre-flight screens

They live on the **nav** panel's border, because navigation itself comes later and the centre of
that screen is reserved for the map. Both replace the nav view until backed out.

### FCS TEST

Every pilot axis as a **signed** bar, drawn from the craft's own reported state — throttle runs
reverse ← 0 → forward, and a 0..1 bar would make full reverse and neutral look identical, which
is the one confusion that matters on this screen. Plus whether the brake is held, the current
feel/lateral/assist modes, and **which input device the craft is actually hearing**: a dead
typewriter looks exactly like a pilot not touching anything until you can see that line.

When the link drops the bars **blank** rather than freezing on their last value.

### SELF TEST

Three steps of 15 s — lift, lateral, then accelerators — each split into two 7.5 s phases that
sweep one nozzle axis through a full sine cycle (`0 → + → 0 → − → 0`). A whole group moves at
once, so you can watch four nozzles together and spot the one that disagrees. The screen shows
the step list with progress, the axis sweeping, and a countdown.

It reports **which thrusters could actually be swept** (`lif 4/4  mai 0/4`). A main thruster
often has thrust only and no nozzle; saying "tested" would be a lie you would believe until the
first flight.

> **The interlock is POWER, not the flight state.** A craft whose thrusters produce nothing is
> not flying, whatever any sensor believes — and `GROUND` depends on a down-facing laser being
> assigned, so gating on that alone would deny the test to exactly the half-configured craft
> that needs it. Power is re-checked every second while the sweep runs, and active flight aborts
> it. Nothing here ever commands thrust.

While the sweep runs it **owns the thrusters** — the mixer's commands are not applied. Both
writing to the same nozzles would spoil the test and, worse, is the one thing this vehicle must
never do.

### AXIS MAP — naming directions by looking at them

The third button on the nav border. A grid of every thruster against its nozzle's own four
deflections (`X+ X- Y+ Y-`). Tap one and that nozzle goes to **full deflection and stays there**;
a panel lights up with the direction the system currently believes it points:

```
lift_fl +x = RIGHT
```

Walk out, look at the nozzle, and if it is wrong **hold `a` / `d` / `w` / `s` on the typewriter**
to rename it. The label changes as soon as the craft accepts it, and the mixer is rebuilt on the
spot. While a nozzle is latched the normal keybinds are **silenced** — a/d/w/s are naming a
direction, and leaving them live would roll and pitch the craft while you stand next to it.

**What the keys mean depends on the nozzle**, because a nozzle deflects in the plane
perpendicular to its own thrust — the rule comes from `thrustAxis`, not from the group:

| Thruster | `a` / `d` | `w` / `s` |
|---|---|---|
| lift (points down) | LEFT / RIGHT | FWD / BACK |
| accelerator (points back) | LEFT / RIGHT | UP / DOWN |
| lateral (points sideways) | **DOWN / UP** | FWD / BACK |

The lateral row is the one that catches people: a sideways-pointing thruster **cannot** deflect
its thrust sideways, so `a`/`d` are down and up there. `a` and `s` are always the negative
direction and `d`/`w` always positive, so the keys never reverse their sense.

The legend is computed **on the craft**, where the rule lives, and sent as text — a panel that
hardcoded "a/d = left/right" would be lying on all four laterals. It is shown while a nozzle is
held, so there is nothing to remember.

> **It is a latch, not a held switch, and that is a platform limit rather than a choice.** CC
> gives a monitor `monitor_touch` and *nothing at all* for the release — there is no touch-up
> event in the API. Press-and-hold on a monitor cannot be expressed, so a tap latches and a
> second tap lets go. A watchdog releases anything forgotten after 45 s, and the latch is
> refused while the self test owns the same nozzles.

**Naming one axis fixes half the answer.** Assigning a nozzle axis also forces the *other* one
onto the remaining axis of the plane — both on one craft axis is geometrically impossible and the
mixer could never satisfy it. So six of the eight orientations are reachable from a single
naming, and all eight once you have named both axes, which is the workflow anyway.

## Thruster orientation — the thing nothing can work out for itself

The mixer turns a wanted craft-frame force into a nozzle deflection through each thruster's
`vectorMap` and its two invert flags. **Those default to the identity, and nothing measures
them.** A thruster mounted rotated or mirrored therefore gets pushed the *wrong way*, the
attitude loop sees the error grow and pushes harder — which is precisely the escalating
oscillation this design exists to prevent.

**AXIS MAP is the direct way to fix it** (above): deflect, look, name. THR AXES on the config
screen is the same eight states as abstract toggles, kept for when you already know the answer.

The fix is these screens working together:

1. **SELF TEST** shows you the truth. It commands nozzles through `setVectorRaw`, which
   deliberately **bypasses the mapping** — pushing the sweep through `mapVector()` would let a
   wrong mapping cancel against itself and look correct.
2. **THR AXES** is where you correct it: one row per thruster with `SWP` (nozzle X drives
   fore/aft instead of left/right), `-X` and `-Y`. Eight orientations per thruster, all
   reachable. `setAxes` is addressed **by thruster id, not list index** — `setSlot` reorders the
   list, so an index would silently retarget the wrong thruster — and it rebuilds the mixer
   immediately.

## Typewriter keybinds

**KEYS** is the same slot widget again: the seventeen actions on one page with the key each is
bound to, and a curated key list behind whichever you tap. Long names keep their **head**, not
their tail — `leftShift` and `rightShift` differ at the front, the opposite of a peripheral name,
which is why the widget takes a `fitValue` option.

The key list is curated rather than all of CC's `keys` table: a monitor can only be tapped, so
every extra entry is another page to wade through, and most of `keys` is unreachable on a
typewriter anyway. Modifiers and letters come first.

> **A key does nothing at all unless it is bound to a frequency on the typewriter itself.** This
> page sets what the *software* listens for; the typewriter decides what it *sends*.

A rebind takes effect immediately — `configSet` runs `App:applyConfig`, which re-resolves the
bindings — and an invalid key name is refused by the validator rather than becoming a control
that silently does nothing.

**Conflicts are shown where you cause them.** Two actions on one key means the second resolved
gets *no* binding, so the page's subtitle turns red and names both (`space: CLIMB+BRAKE`). That
resolution order used to come from `pairs()`, which made a duplicate binding disable an
arbitrary one of the two — and a different one on each boot. It is now a fixed order: axes as
declared, then held, then edges. Same config, same behaviour, every time.

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
- **An `Input`'s contents live in its `text` property**, so the accessors are `setText`/`getText`
  — there is no `setValue`. A guessed accessor is `nil` and fails only when that screen is first
  drawn, which on a fresh install is on the pilot's monitor. Every element's real property list
  is in `src/elements/<Name>.lua` under `defineProperty`; read it rather than guessing.
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

> **Every screen needs at least a build-and-update test.** The first GPS beacon installed in game
> crashed on boot because its panel called a Basalt method that does not exist. Every other module
> in that role had tests; the screen had none, so a guessed API reached the pilot untested. A
> single test that constructs the panel and calls `update` once would have caught it, and now does.

Two click paths are exercised, deliberately. `click()` dispatches `mouse_click` on an element,
which is fast and enough for most assertions. `tap()` dispatches **`monitor_touch` on the frame**
— the event CC actually delivers — so `BaseFrame`'s peripheral-name routing and its
`mouse_click(1, x, y)` translation are under test too. The double-click bug above was only
reachable through `tap()`.

---

## Never store a fact about the code in the operator's config

`panels.*.enabled` carried "is this panel implemented yet", and the first ui_main release shipped
`nav = { enabled = false }`. Every computer that ran it **saved that into its config file**.

When the nav panel went live, the new `enabled = true` default lost to the `false` already on
disk — because config here is extend-never-replace, which is correct and is not the bug. The
result was the worst kind of failure:

- the panel could still be assigned to a monitor, so the assignment screen said `nav`
- the detach pass **blanked** that monitor
- `Monitors:sync` skipped the panel, so no frame was ever built
- nothing was logged, because nothing had gone wrong from the code's point of view

A permanently black screen, indistinguishable from a broken monitor, while every other panel
worked. It cannot be fixed by editing a default — that is the whole point.

**The rule:** a config file holds what the *operator* chose. Whether a panel exists is a fact
about the release, so it lives in the release. `app.lua`'s `PANEL_BUILDERS` is now the single
source of truth: it builds the frames *and* supplies the terminal's cycle list, so the two cannot
drift.

That fixed a second black-screen path in passing. The terminal cycled through all of
`Config.PANEL_ORDER`, so two of its six stops — `pfd` and `autopilot` — were panels nothing
builds. Tapping onto one gave a blank monitor with no explanation. It now offers only panels with
a builder, and a monitor found parked on one without one cycles forward rather than sticking.

### When a migration is safe

`Config.migrate` overwrites `enabled`, which sounds like it violates extend-never-replace. It
does not, and the reason is the test to apply before writing another one:

> **No screen has ever been able to set `enabled`.** A stored `false` therefore cannot represent
> a choice anybody made — it can only be a leftover from the release that shipped it. There is no
> operator intent to preserve, so there is none to destroy.

The monitor assignments of a re-enabled panel are kept: assigning a screen to a panel before it
went live *is* a real choice. `withDefaults` reads the version from the **loaded file**, not the
merged table — `deepMerge` has already replaced it with the current default by then, which would
make the migration a no-op on exactly the configs that need it.

No `manifest.schema` bump: the layout is unchanged and `Config.load` migrates at every boot, so
an affected computer heals itself the moment it runs the new code.

## Fit the labels, or stack them

The nav panel's three pre-flight buttons were laid out as three equal thirds of the width. On a
15-column cockpit monitor that reads `FCS T SELFT AXI`, with the third button hanging past the
right edge. The widest label is `FCS TEST` at 8, so one row needs `3*8 + 2 = 26` columns; below
that they stack one per row up the bottom border, and the reserved centre shrinks to match. The
test asserts full labels and `x + width - 1 <= width` at six widths, because "it fits on my
screen" is not a property of the screen the pilot has.
