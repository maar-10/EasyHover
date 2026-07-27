# Nozzle vectoring from Lua — where it is defined, and the bug we hit

Written to be checked, not taken on trust. Every claim below cites a file and line.

**There is no wiki for Create: Propulsion. The source is the documentation.**

- Repository: <https://github.com/Propulsion-Team/create-propulsion-simulated>
- Pinned at commit `52283f3160ab50e9ade3b314b90389412d747add` (2026-07-26)
- Root below is `src/main/java/dev/propulsionteam/propulsionsimulated`

---

## 1. Yes, the nozzle is settable from Lua

`compat/computercraft/VectorThrusterPeripheral.java` — peripheral type `"vector_thruster"`:

```java
@LuaFunction(mainThread = true)                                              // L54-57
public final void setVector(double x, double y) {
    blockEntity.setVectorCoordinates((float) Mth.clamp(x, -1.0, 1.0), (float) Mth.clamp(y, -1.0, 1.0));
}

@LuaFunction(mainThread = true)  public final void setVectorX(double x)      // L44-47
@LuaFunction(mainThread = true)  public final void setVectorY(double y)      // L49-52

@LuaFunction  public final double getVectorX()                               // L24-26
@LuaFunction  public final double getTargetVectorX()                         // L34-37
```

`compat/computercraft/LiquidVectorThrusterPeripheral.java` — type `"liquid_vector_thruster"`,
**identical signatures** at L50 / L55 / L60, `getType()` at L25. This is the type on this craft.

So the API exists, on exactly the block in use. Note the asymmetry, which matters for cost: the
**setters are `mainThread = true`** (each waits a server tick), the **getters are plain
`@LuaFunction`** (free). `ThrusterPeripheralBase` declares no `@LuaFunction` at all — it is
attachment bookkeeping — so each peripheral's own list is authoritative.

## 2. And it is not gated on power, fuel or control mode

`content/thruster/vector_thruster/VectorThrusterBlockEntity.java`:

```java
public void tick() {                                          // L185-198
    updateMappedTargets();
    currentVectorX = tweenTowards(currentVectorX, targetVectorX);   // TWEEN_SPEED = 0.2, L32
    currentVectorY = tweenTowards(currentVectorY, targetVectorY);
    targetFlapProgress = (float) getThrottle();                     // flaps only
    ...
}
```

No condition. Not `isWorking()`, not fuel, not throttle, not `ControlMode`. The renderer tilts the
model by `interpolatedVector * MAX_VISUAL_TILT_DEGREES` where that constant is **30.0f** (L31),
again with no throttle term — throttle drives `flapProgress`, a separate visual.

`ControlMode` (`AbstractThrusterBlockEntity` L112-118, L173-181) is **throttle only**: `NORMAL`
reads `redstoneInput`, `PERIPHERAL` reads `digitalInput`. Vectoring never consults it.

**Therefore a vector thruster should tilt ~18° for a commanded 0.6 on a cold, unfuelled, unpowered
craft, arriving in about 1.5 s.**

## 3. What actually happens on this craft

Measured with `tools/nozzle.lua`, which commands `setVector(0.6, 0)`, reads `getTargetVectorX()`
back immediately, then again after 1.5 s. On 13 liquid vector thrusters:

```
name                 pwr    now   +1.5s  angle
l_vector_thruster_3  +0.000 +0.600 +0.000 +0.000
l_vector_thruster_4  +0.000 +0.600 +0.000 +0.000
l_vector_thruster_7  +0.000 +0.000 +0.000 +0.000
...
VERDICT
  7 took the value then LOST it within 1.5 s.
```

**The write lands.** `setVector` throws nothing and the target really does become `0.600`. Within
1.5 s it is back to `0.000`. The ones already reading `0.000` on the immediate read were simply
reverted before that read happened.

## 4. The second writer

`content/thruster/vector_thruster/VectorRedstoneLinkBehaviour.java`:

```java
frequencyFirst = Frequency.EMPTY;                     // L49-50, constructor default
frequencyLast  = Frequency.EMPTY;

public void initialize() {                            // L101-106
    super.initialize();
    if (getWorld().isClientSide) return;
    Create.REDSTONE_LINK_NETWORK_HANDLER.addToNetwork(getWorld(), this);   // UNCONDITIONAL
    newPosition = true;
}

public void setReceivedStrength(int networkPower) {   // L88-93
    if (!newPosition) return;
    signalCallback.accept(networkPower);              // -> setSignal(power, side)
}

public void read(...) {                               // L136-138
    newPosition = positionInTag != positionKey;
}
```

Each vector thruster registers **four** of these (west/east/down/up —
`VectorThrusterBlockEntity` L75-93), and `setSignal` writes the very fields `setVectorCoordinates`
writes (L101-118 vs L161-167). `tick()` then re-derives the target from them every tick
(`updateMappedTargets`, L291-296).

There is **no check for whether a frequency was ever assigned.** Every vector thruster therefore
joins the shared *blank* network as a receiver, and re-applies that network's value — **0**, with
no transmitter — whenever `newPosition` is true. `read()` sets `newPosition` true whenever the
block entity is read at a position other than the one in its NBT, which on a **Create: Simulated
contraption is continuous, because the blocks move**.

This predicts exactly what we see:

| Observation | Explained by |
|---|---|
| `setVector` throws nothing, target briefly `0.600` | the write really does land |
| back to `0.000` within 1.5 s | receiver re-applies the blank network's 0 |
| all thrusters affected together | they share one blank network |
| manual redstone works perfectly | that is a real transmitter pushing a real value |
| discovery, `getType`, all getters normal | nothing is wrong with the peripheral |

## 5. THE ANSWER: all four sides must have channels

**Found on the craft, not in the source: every one of the four vector redstone links must have a
frequency assigned.** With any side left blank, `setVector` is accepted and the nozzle does not
hold it. Assign channels to west, east, down and up on each thruster and Lua vectoring works.

This is the operational fix, and it corrects what section 4 originally reasoned toward. The
mechanism there is right — the four `VectorRedstoneLinkBehaviour` receivers share the nozzle's
signal fields with `setVectorCoordinates`, and `initialize()` puts them on a network whether or not
a frequency was ever set. What was wrong was the conclusion drawn from it: this document previously
suggested that stopping the receivers joining a network would be the cure. The opposite is true in
practice. A configured link is what makes the side behave; a blank one is what breaks it.

Worth being plain about how that went: the mechanism was derived from source and the fix was
guessed from the mechanism. Only the second half was wrong, and only testing on the craft caught
it.

## 6. What we did about it, and what we cannot

**Mitigation (ours).** Never treat *"I sent it"* as *"it holds it"*. Both the mixer
(`flight/lib/io/thrusters.lua`) and the pre-flight sweep deduplicated writes against their own
record of the last command — which is only safe when nothing else writes the nozzle. With a
competing writer it is the worst available choice: the nozzle is zeroed, our record still says
"commanded", and we never write again. Both now compare against `getTargetVectorX/Y` and re-assert
on disagreement. The getters are free, so this costs nothing but the re-writes themselves.

**This is a mitigation, not a cure.** We re-assert once per control cycle; the receiver can undo it
in between. Expect a nozzle that twitches or lags rather than one that holds.

**Still worth raising upstream.** A blank link silently overwriting a peripheral-set nozzle, with
no error and no indication, is very hard to diagnose from in-game — every getter reads normally and
discovery is unaffected. Either a blank behaviour should not join a network, or the failure should
be visible. But it is a usability report now, not a blocker: configuring the channels works.

### Build requirement, for anyone wiring one of these

**Assign a channel to all four vector link slots on every vector thruster** — west, east, down and
up. They do not need a transmitter driving them; they need to be configured. A thruster with even
one blank side will accept `setVector` and not hold it, silently, with every getter and every bit
of peripheral discovery behaving perfectly normally.
