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
| **overhead** | **live** | Engine start/stop with a countdown to the next feed, both fuel gauges (liquid tank, solid vault), and their configuration in a submenu. Built for a 1×2 portrait screen. |
| **config** | **live** | In-flight values on its main page; **MON**, **HW**, **DISK** and **FLT** submenus. |
| pfd | reserved | Attitude / flight-path indicator. Mirrored pair. |
| autopilot | reserved | Autopilot settings. |
| nav | reserved | Waypoints and the map. |

Reserved panels can already be *assigned* — the plumbing is there, the UI is not.

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

## Assigning hardware

Config panel → **HW**, or the overhead panel's **CFG** page — the same widget, so there is one
implementation of "which peripheral is the tank".

**Every candidate is a row you tap once.** Three tabs — `RLY` `TNK` `VLT` — choose which item you
are assigning; under them is the list of what the craft can actually see, with `(none)` first so a
wrong choice is undoable, and the assigned row highlighted. Longer lists page with `^`/`v`.
**SIDE** cycles the relay's side (a relay's "face" is its BACK — see [WIRING.md](WIRING.md)).

> The first version cycled instead: one **PICK** button stepped to the next candidate. The first
> dry run killed it. You could not see what you were choosing between, reaching candidate three
> took three taps, and it interacted with the double-click bug below to look completely dead.

The assignment appears **on the tap**, before the craft confirms it, and a refusal shows as
`CRAFT REFUSED` on the count line. Silently reverting on the next telemetry frame is
indistinguishable from a dead button.

**The candidate list comes from the flight computer over telemetry**, not from the UI's own
peripheral scan. Both computers see the same wired network, but the flight computer is the one
that will actually open these peripherals, so its names are the authoritative ones.

Assigning the engine relay also switches `engine.enabled` on — a relay with the subsystem still
off looks configured and does nothing. `setEngineRelay` / `setTank` / `setVault` are dedicated
commands rather than `configSet`, because they have to *create* a list entry (`hardware.tanks`
starts empty) and `configSet` deliberately refuses to invent keys.

## Fitting a 1x1 monitor

Both panels compute their layout from the frame's real size. The config panel has a **narrow
mode** below 26 columns: shorter labels, the menu stacked into a 2×2 grid, and the live-value
block taking whatever rows are left. Minimum 14×9; below that it says which size it needs rather
than drawing nonsense.

`Theme.fitEnd` keeps a peripheral name's **tail** when it will not fit, because truncating
`redstone_relay_1` to `redstone_relay_` renders `relay_0` and `relay_1` identically.

## Assigning monitors

Config panel → **MONITORS**. Every monitor on the network is listed with its size and current
panel; tapping cycles it: *none → overhead → config → pfd → autopilot → nav → none*. Each change
saves immediately, because a half-made assignment lost on reboot is worse than one you have to
undo.

**The bootstrap case is handled:** with no monitor assigned to the config panel, the config panel
is also built on the UI computer's own **terminal**. A cockpit with nothing assigned yet is never
a dead end.

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
`setAltitude`, `identify`, `configSet`, `configSave`, `diskSave`, `diskLoad`, `ping`.

`identify` is gated on the craft actually being in `GROUND` state — on the flight side, not on
the sender's say-so.

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
