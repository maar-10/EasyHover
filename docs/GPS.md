# EasyHover — the GPS constellation

Position comes from **CC's own GPS**, served by four `gps_beacon` computers standing in the
world. The craft's nav computer asks them where it is over an **ender modem**, then relays the
answer to the rest of the craft over the **wired** network.

Everything below was read out of CC:Tweaked's own `rom/apis/gps.lua` and
`ModemPeripheral.java`, not remembered, because every one of these failure modes is silent.

## What `gps.locate()` actually requires

| Requirement | Why | What happens if you get it wrong |
|---|---|---|
| **A wireless modem** on the asking computer | `locate()` walks the sides and takes the first modem whose `isWireless()` is true | a wired-only computer gets `nil` with no message |
| **Four hosts** | it trilaterates from **three**, which yields two mirror candidates, then uses the **fourth** to pick one. It returns only once it has one candidate and not two | with three it returns **nothing at all** |
| **Not coplanar** | the mirror image through the hosts' plane fits every measured distance equally well | four beacons in a flat ring — the most natural thing to build — return **nothing** |
| **More than 1 block apart** | a fix within 1 block of an existing one **replaces** it rather than adding | two adjacent beacons count as one host |
| **Same dimension as the craft** | `receiveSameDimension` queues `modem_message` *with* a distance; `receiveDifferentDimension` queues it *without*, and `locate()` skips any reply with no distance | a beacon in another world is invisible, not merely distant |

An **ender modem** satisfies "wireless" (`advanced = true`, range `Integer.MAX_VALUE`), so it
removes the range limit **within a dimension**. That is the whole reason to use one.

## The beacon role

Four standalone computers, each running `gps_beacon`. Install with the Suite and pick the role.

Each beacon:

- **answers pings on CC's own channel** (65534) with a **three-element array** `{x, y, z}`.
  `locate()` checks `#tMessage == 3` — a keyed `{x=,y=,z=}` table has length 0 and is silently
  ignored, so using CC's exact format is not optional.
- **announces itself** to the others on a separate rednet protocol (`eh_gps_mesh`). GPS is a wire
  format we do not own; a host that answered pings with anything else would break `locate()` for
  every computer in the world, so peer status rides alongside rather than inside it.
- **checks its own coordinates** against what the constellation says, every couple of minutes.

### The self check is the point

A beacon with a **typo'd coordinate does not fail**. It answers confidently, and every fix the
craft takes is wrong by however far the typo was — with nothing, anywhere, reporting a problem.
Once four beacons are up, each one can run `gps.locate()` itself and compare. That is the only
way to catch it, so it gets the loudest line on the beacon's screen:

```
MISMATCH 20.0 BLOCKS OFF
```

### Quality, in words you can act on

The beacon grades the live constellation from the coordinates the mesh reports, so nobody types
four positions into a calculator:

```
GPS beacon-3
at 60 150 60
self check ok (0.12)
-----------------
* beacon-3 (this one)
+ North 0 70 0
+ East 200 72 0
+ South 0 68 200
-----------------
4/4  EXCELLENT
served 1284  peers 3
```

The grade comes from the **tetrahedron volume** of the best four hosts, scaled by their mean edge
length so it is dimensionless — doubling the constellation's size does not change its grade,
because the geometry is the same shape. Below the coplanarity limit it reads **UNUSABLE** and
tells you to move one beacon up or down, because that is the case where `locate()` returns
nothing rather than something worse.

It also catches, in plain sentences: fewer than four hosts, two beacons on the **same**
coordinates (one copy-paste away, and it quietly costs a host), beacons closer than a block, and
a peer that has gone quiet.

Turning a beacon **OFF** makes it stop answering, so it drops out of the constellation honestly
while you move it — rather than answering from where it used to be.

## The craft's side

The nav computer has **two modems, and the split is the point**:

- the **ender modem** talks to the constellation and the beacon mesh. It is the only radio on the
  craft, and as far as control is concerned it is **receive-only**: it fetches position and never
  carries a command.
- the **wired modem** relays the fix to the flight computer and the cockpit screens, on
  `comms.navFixProtocol` — which has been in the flight config since phase 5, so nothing on the
  craft needs changing to start listening.

That is how the control surface stays off the air even though navigation needs a radio.

**`gps.locate()` blocks** — it transmits and waits up to `timeout` seconds for four answers. That
is wall-clock time on the nav computer, not a server tick, and it is exactly why navigation gets
a computer of its own: the same call inside the flight loop would wreck the `dt` discipline the
whole control design rests on, and inside a Basalt UI it would stall a redraw mid-frame.

Every published fix carries its **age, source, quality** and whether it is **dead-reckoned**. A
bare `x/y/z` would force every reader to trust it, and the one thing we know about a position is
that sometimes it is stale.

## Building it

1. Place four computers, **well apart**, and **not all at the same height** — one clearly above or
   below the others. This is a requirement, not a refinement.
2. Give each an ender modem, in the **same dimension** you intend to fly in.
3. Install `gps_beacon` on each, then **SET POS** on its screen and type where it stands.
4. Watch the count reach `4/4` and the grade settle. Fix anything the problem line names.
5. Wait for `self check ok` on all four. A **MISMATCH** on any one means a coordinate is wrong —
   and it may not be the beacon complaining.
