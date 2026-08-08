# Devlog — quirks, gotchas, and what they cost

Notes from writing BUFO for the Fairchild Channel F. Ordered roughly by how
much time each one burned. Nothing here is speculation: every number was
measured on the running machine.

---

## The assembler lies: dasm silently truncates out-of-range branches

**The single most expensive bug in this project, and it was not in the code.**

F8 conditional branches carry a displacement of one *signed byte* (−128..+127).
If the label is farther away, dasm emits two bytes anyway, prints
`Complete. (0)`, and exits 0. The program then jumps somewhere arbitrary.

What it actually produced:

```
09e5   94 7f   bnz lu_lane   ->  09e6 + 127 = 0a65   (inside edge_run)
```

−129 was needed. The lane loop therefore never iterated: **one lane out of
seven moved**, and a band of garbage pixels appeared at y17–20, painted by
`edge_run` entered halfway with the wrong registers in place. Two symptoms that
look unrelated, one cause, and a compiler reporting success.

The fix is not the branch. The fix is [`tools/brcheck.py`](tools/brcheck.py),
which re-reads the listing, recomputes every branch target as
`opcode_address + 1 + displacement`, compares it against the label, and fails
the build. It is wired into `build.ps1`.

It paid for itself the same day: adding the win condition pushed `main_loop`
past 128 bytes, and the build stopped instead of shipping a ROM that jumped to
`$09B3`.

When a loop outgrows the range, invert the branch and use an absolute `jmp`.
`jmp` destroys A but leaves DC0 alone — essential when the loop keeps reading a
table with `lm`.

**Lesson:** if something "doesn't iterate" or draws garbage, run the branch
checker *before* reading the source.

---

## One hardware return level

The 3850 has exactly one return register, `PC1`. `pi` pushes into it; `pop`
restores from it. A routine that wants to call another must first stash `PC1`
into `K` (`lr k,p`), and `K` is a single register pair.

Consequence: **a routine that does `lr k,p` cannot call another routine that
does `lr k,p`.** There is nowhere to put the second return address.

This is not a style rule, it is a hard constraint, and it dictates structure.
`dead_tick` is deliberately a leaf: it decides *that* the toad should come back
but does not do it, because respawning needs `erase_frog`, which uses K. The
actual respawn lives in `main_loop`, one level up, where each `pi` is
independent. Same reason the home-bay sequence finishes in `main_loop` rather
than inside `check_frog`.

---

## Video RAM cannot be read back

There is no way to ask the screen what is under the sprite. Collision detection
by reading pixels is simply unavailable.

This turns out to be a feature: the same formula that draws a lane also erases
it and answers "is there an object at x?". Three uses, one source of truth, so
they cannot disagree.

It also means erasing must *recompute* the background. `erase_frog` looks the
lane up in the table and reapplies `rel = (x - PF_X0 - offset) & mask` for each
of the five columns it needs to restore.

---

## The palette is per row, so colour choice *is* layout choice

Each VRAM row carries two palette bits, stored in columns 125 and 126 (outside
the visible area). Pixel values 1, 2 and 3 are always blue, red and green; only
value **0** changes colour with the palette — black, pale blue, light grey, or
light green.

So you do not get to pick four colours per row. You pick a background, and the
other three are fixed. Any vertical layout is therefore also a colour plan.

This produced the one genuine design decision of the project. Originally the
river was pale blue with blue logs and the road was grey with red cars, which
taught the player "grey = safe" for half the screen and then reversed it. The
fix was to **invert which value acts as background**: the river rows use
palette 2 (value 0 = light grey) and are *filled* with value 1 = blue, so the
water is the fill and the logs are drawn with value 0 and come out grey. Now
"grey means you can stand on it" holds everywhere.

The cost is that "background" is no longer a constant. Everything that erases —
the trailing column of a scrolling lane, `erase_frog` — has to use the
background *of that lane*, not `C_BG`.

---

## Sound shares a byte with the VRAM row

The two sound bits are bits 7–6 of port 5, the same byte that carries the row
address. **Every pixel write clears them.**

So the tone cannot be "set and left". It is programmed once per frame, at the
end, and survives only for the following delay before the next frame's first
pixel kills it. One state change per frame instead of two hundred. On real
hardware this sounds like a tone chopped at ~80 Hz; that is inherent to sharing
the port, not a defect.

### Audio: MAME 0.287 crashes on any tone

Any non-zero tone crashes MAME 0.287:

```
channelf_state::port_5_w -> channelf_sound_device::sound_w(int)
  -> sound_stream::update() -> channelf_sound_device::sound_stream_update() + 0x00fe
     ACCESS VIOLATION, reading 0xffffffffffffffff
```

MAME calls `sound_w` on every port 5 write but returns immediately when the
mode has not changed — which is why keeping the tone at 0 means its stream is
never updated and the bug never fires. A single tone change, even twice per
frame, is enough to take it down. The ROM's use of port 5 follows the hardware
spec, so the fault is in MAME's device.

Tones are therefore off by default (`SOUND_ON = 0`). The sequencer still runs
so it cannot rot; only the write to the port is suppressed.

**The crash makes a good test oracle.** Build with `SOUND_ON = 1` and launch
MAME: if it dies with that stack, the tones really are reaching port 5. If it
*doesn't* crash, the sequencer is emitting nothing. That is how the music was
verified without ever hearing it.

### There is no melody to be had

Two bits give silence plus three *fixed* tones (roughly 1 kHz, 500 Hz, 120 Hz).
No divider, no pitch control. A tune in a key is not possible on this hardware;
what you can write is a rhythmic ostinato over three pitches, which is what
`mus_tbl` is.

---

## Frame order is an invariant, and breaking it leaves ghosts

`V_OLD*` must hold the position of the **last draw**, and only `save_old` at end
of frame may set it. Two violations, two different kinds of debris, both found
by dumping the whole screen rather than sampling it:

- `frog_input` used to save `V_OLD` when a hop was detected. But `lane_update`
  runs *first*, and a log may already have moved `V_FROGX` this frame. The erase
  then covered where the toad *is* instead of where it was *drawn* — leaving a
  single ghost column in the river.
- Entering a bay called `respawn`, which overwrites `V_OLD*` with the start
  position, *before* `erase_frog` had removed the toad from the lane it jumped
  from — stranding a whole sprite in the water.

Both fixes are structural rather than patches: don't save `V_OLD` anywhere but
`save_old`, and finish the bay sequence one level up, after the erase.

---

## Measurement traps

The F8 code in this project usually worked on the first try. What went wrong was
almost always the measurement.

**Periodic patterns alias.** Lane scroll measured from two snapshots is only
determined modulo the lane's period. A lane moving left at 20 px/s over one
second reads as `+12` when the period is 32. Three lanes looked like they were
running backwards until each measurement was compared against its own period —
at which point all seven agreed on a loop rate of 80 Hz.

**Snapshots land mid-frame.** MAME captures at a video frame boundary, which is
not synchronised with the game loop. Catch it between "draw the head" and
"erase the tail" and every object in that lane looks 1 px wider; catch
`draw_lives` mid-repaint and the game looks like it has zero lives. Neither is a
bug. Sample the same thing at four to six different instants before believing
it.

**Don't sample, look.** Reading "the prevailing colour" of a row measured the
gaps instead of the objects. Probing a fixed row read the timer bar instead of a
lane. `vcheck.py --map` prints every visible pixel as ASCII with a column ruler;
it makes a whole class of mistakes impossible.

**The loop rate is not one number.** The alive branch runs at ~80 Hz; the dying
branch skips lanes and drawing and runs at ~128 Hz. Anything counted in loop
iterations has to be tuned against the branch it actually runs in — `DEAD_PAUSE`
was 40% short until that was measured.

**MAME Lua notifiers get garbage collected.** `emu.add_machine_frame_notifier()`
returns a subscription that must be kept alive in a global. Let it fall out of
scope and the callbacks silently never fire: the emulator just hangs, having
taken no snapshots.

**PowerShell pipelines kill the producer.** `.\build.ps1 -Shot | Select-Object
-First 2` terminates the script upstream before MAME ever launches, leaving the
*previous* snapshot on disk. Half an hour went into a non-existent drawing bug
because of it. Use `| Out-String -Width 200`, and check the PNG's timestamp when
a snapshot seems to ignore your changes.

---

## Toolchain notes

- `make` fails to build dasm here: the native gcc invoked by the Makefile gets
  `TMPDIR` in POSIX form and falls back to `C:\WINDOWS\` — "Cannot create
  temporary file: Permission denied". Compiling the `.c` files by invoking gcc
  directly works.
- MAME wants the Channel F BIOS files named with a `.rom` extension, in a plain
  `channelf/` directory inside the rompath. No zip required.
