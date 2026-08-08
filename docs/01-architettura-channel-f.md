# Fairchild Channel F — architecture and toolchain

> Field notes taken while writing *BUFO*. Every number in here was checked
> against a primary source: the MAME driver `fairchild/channelf.cpp` +
> `channelf_v.cpp`, the F8 backend of `dasm` (`src/mnef8.c`), and the technical
> pages at [veswiki](https://channelf.se/veswiki/).

---

## 1. Why this machine is strange

The Channel F (1976) is the **first cartridge console with a real CPU**. It
predates the Atari 2600 by a year, and that shows in a counter-intuitive way:

- The Atari 2600 has an ordinary CPU (6502) and a hellish video chip (TIA) that
  forces you to chase the electron beam line by line (*racing the beam*).
- The Channel F does the **opposite**: it has *easy* video (a real framebuffer,
  refreshed by the hardware on its own — no timing to respect, no vblank to
  chase) but an **alien** CPU and an amount of RAM that is a joke.

The upshot is that on the Channel F the hard part is not the video: it is
**fitting the game into 64 bytes of RAM**.

---

## 2. The F8 chipset

"F8" is not a chip, it is a **family of chips that split the work** between
them — a multi-chip architecture, typical of 1975:

| Chip | Role |
|---|---|
| **3850 CPU** | 8-bit ALU, **64 bytes of internal RAM** (scratchpad), 2 I/O ports |
| **3851 PSU** | *Program Storage Unit*: 1 KiB of ROM + programmable timer + interrupt logic + 2 I/O ports |
| 3852 / 3853 | memory interfaces (DRAM / SRAM) — used only by some cartridges |

The console contains **two 3851s**, which together form the 2 KiB BIOS:

| Range | Contents | ROM file |
|---|---|---|
| `$0000-$03FF` | BIOS part 1 | `sl31253.rom` |
| `$0400-$07FF` | BIOS part 2 | `sl31254.rom` |
| `$0800-...`   | **cartridge** | our `.bin` |

The third file, `sl90025.rom`, is the revision used by later models (System II);
MAME wants it in the romset regardless.

Crucial fact: **there is no system RAM.** The 64 bytes inside the 3850 are all
the writable memory you get. There is no stack in RAM, no heap, no variable
area. There are 64 registers, and that is it.

### 2.1 The 3850 programming model

```
A                 accumulator, 8 bit
W                 status/flags: sign, carry, zero, overflow, interrupt-enable
ISAR              6-bit pointer into the scratchpad (see below)
r0 .. r63         scratchpad: 64 bytes. THIS IS THE RAM.
PC0               program counter
PC1               *one single* level of return address
DC0, DC1          data counters: the "pointers" used to read/write memory
```

Some scratchpad registers have a second name because the CPU uses them as
16-bit pairs:

| Registers | Pair name | Use |
|---|---|---|
| r9 | `J` | scratch for saving `W` |
| r10:r11 | `H` (`HU`:`HL`) | save slot for `DC0` |
| r12:r13 | `K` (`KU`:`KL`) | save slot for `PC1` → **nested subroutines** |
| r14:r15 | `Q` (`QU`:`QL`) | another 16-bit save slot |

⚠️ The register field in the instruction encoding is only 4 bits wide, and the
values 12/13/14 are reserved for the ISAR modes. So **r12–r15 are not directly
addressable**: you reach them only through the names `K`/`Q`, or via ISAR.

### 2.2 ISAR: indirect addressing (and its trap)

`ISAR` is a 6-bit pointer into the scratchpad, but it is **split into two 3-bit
halves**:

```
ISAR = [ ISARU (3 bit) | ISARL (3 bit) ]
         bank 0..7        index 0..7
```

- `lisu n` writes the high three bits (the bank), `lisl n` the low three.
- In instructions, the register `(IS)` reads/writes wherever ISAR points;
  `(IS)+` and `(IS)-` post-increment/decrement.

**The trap**: `(IS)+` increments **only the low three bits**, which *wrap*
inside the 8-register bank. Stepping past r23 does not get you to r24: it takes
you back to r16.

So the scratchpad has to be thought of as **8 banks of 8 bytes**, and every
array in the game has to be bank-aligned. This is not a detail: it is the
constraint that dictates *BUFO*'s entire memory layout.

### 2.3 The instructions that matter

| Instruction | Meaning |
|---|---|
| `lr d,s` | move between registers (`lr a,3`, `lr 3,a`, `lr a,(is)+`, `lr k,p`, …) |
| `li n` / `lis n` | load immediate (`lis` = 1 byte, only 0–15) |
| `clr` / `com` / `inc` | A=0 / A=~A / A=A+1 |
| `as r` / `ns r` / `xs r` | A += r / A &= r / A ^= r |
| `ai n` / `ni` / `oi` / `xi` / `ci` | immediate arithmetic/logic (`ci` = compare) |
| `ds r` | **decrement a scratchpad register** and set the flags → loop counters |
| `sl 1` `sl 4` `sr 1` `sr 4` | shifts, by 1 or 4 places only |
| `dci addr` | DC0 = addr |
| `lm` / `st` | A = M(DC0), DC0++ / M(DC0) = A, DC0++ |
| `adc` | **DC0 += A** (signed) → table indexing |
| `xdc` | swap DC0 and DC1 |
| `pi addr` | call: PC1 = return address, PC0 = addr |
| `pop` | return: PC0 = PC1 |
| `jmp addr` | absolute jump — ⚠️ **destroys A** |
| `br addr` | relative jump (−128…+127), leaves A alone |
| `bt m,a` / `bf m,a` | branch on a flag mask; aliases: `bp bc bz bnz bnc bm bno` |
| `ins n` / `outs n` | A = port n / port n = A |

Two things to memorise straight away:

1. **`jmp` destroys the accumulator.** Use `br` where you can.
2. **There is one single return level** (`PC1`). To nest calls you must save the
   return address by hand:

```asm
    ; we are inside a subroutine and want to call another one
    lr   k,p        ; K (r12:r13) = PC1, i.e. our own return address
    pi   other_sub
    lr   p,k        ; restore PC1
    pop             ; return
```

`K` gets you to depth 2, `Q` to depth 3. Beyond that you need a software stack.

---

## 3. Video: 128×64, 2 bits per pixel, **write-only**

Video RAM is **2 KiB of separate DRAM**, scanned out by the video hardware on
its own. Consequences:

- ✅ **No need to synchronise with the raster.** Write whenever you like; it
  stays on screen.
- ❌ The CPU **cannot read VRAM back**. It is write-only. If you need to know
  what is on screen, you have to track it yourself… in your 64 bytes.

Layout: 128 columns × 64 rows, **2 bits per pixel**.

### 3.1 Visible area

| | |
|---|---|
| Buffer | 128 × 64 |
| Visible | ~102 × 58, starting at column 4, row 4 |
| *Safe area* | ~95 × 58 |

Columns 125 and 126 are **not graphics**: they hold the row's palette bits.

### 3.2 The four ports

| Port | Write | Read |
|---|---|---|
| **0** | bit 5 = **VRAM write strobe**; bit 6 = 1 disables the controllers | front-panel buttons (bits 0–3: TIME, HOLD, MODE, START) |
| **1** | bits 7–6 = **pixel value, complemented** | **right** controller |
| **4** | **column** (7 bits), complemented | **left** controller |
| **5** | **row** (6 bits), complemented; bits 7–6 = **sound** | — |

Every input and every address is **active low**: hence the `com` you will find
scattered throughout the code. The exact logic in the MAME driver is:

```cpp
// port 4 write
m_col_reg = (data | 0x80) ^ 0xff;      // column = complement of bits 0-6
// port 5 write
m_row_reg = (data | 0xc0) ^ 0xff;      // row    = complement of bits 0-5
m_custom->sound_w((data >> 6) & 3);    // and the high bits are the sound
// port 1 write
m_val_reg = ((data ^ 0xff) >> 6) & 0x03;   // pixel = complement of bits 7-6
// port 0 write
if (data & 0x20) m_p_videoram[m_row_reg*128 + m_col_reg] = m_val_reg;
```

So **plotting one pixel = four OUTs**: colour to port 1, X to port 4, Y to
port 5, and finally the strobe on port 0.

Byte written to port 1 → resulting pixel value:

| Port 1 | Pixel value |
|---|---|
| `$C0` | 0 (background) |
| `$80` | 1 |
| `$40` | 2 |
| `$00` | 3 |

### 3.3 Colour: 4 palettes, **one per row**

The final colour is `colormap[row_palette * 4 + pixel_value]`, where the table
(from `channelf_v.cpp`) is:

```c
static const uint16_t colormap[] = {
    BLACK,   WHITE, WHITE, WHITE,     // palette 0
    LTBLUE,  BLUE,  RED,   GREEN,     // palette 1
    LTGRAY,  BLUE,  RED,   GREEN,     // palette 2
    LTGREEN, BLUE,  RED,   GREEN,     // palette 3
};
```

The 8 physical colours:

| Name | RGB |
|---|---|
| BLACK | `#101010` |
| WHITE | `#FDFDFD` |
| RED | `#FF3153` |
| GREEN | `#02CC5D` |
| BLUE | `#4B3FF3` |
| LTGRAY | `#E0E0E0` |
| LTGREEN | `#91FFA6` |
| LTBLUE | `#CED0FF` |

Read it like this: **value 0 is "the background" and changes with the palette;
values 1/2/3 are always blue/red/green** (except under palette 0, which is
white on black).

In other words: you get **a single graphics plane with 3 colours plus a
background, and you pick the background row by row**. Nothing else. No sprites,
no collision hardware, no scrolling.

### 3.4 How a row's palette is selected

MAME:

```cpp
palette_offset = ((reg2 & 0x2) | (reg1 >> 1)) << 2;
// reg1 = videoram[y*128 + 125], reg2 = videoram[y*128 + 126]
```

Translated: the palette of row `y` is formed from **bit 1 of the pixel in
column 125** (low bit) and **bit 1 of the pixel in column 126** (high bit).

Bit 1 is set in values 2 and 3. So:

| To make the bit… | Write into col. 125/126 |
|---|---|
| 1 (set) | value 2 or 3 → port 1 = `$40` or `$00` |
| 0 (clear) | value 0 or 1 → port 1 = `$C0` or `$80` |

Since those columns fall outside the visible area, whatever colour lands there
is irrelevant: only the bits matter.

---

## 4. Sound

Three fixed tones, on bits 7–6 of port 5: `00` = silence, `01`/`10`/`11` = three
frequencies. The tone **decays on its own** (it is an RC network), so it has to
be retriggered. That is all of it. No channel, no volume, no envelope.

Practical note: port 5 *also* carries the VRAM row. Every time you plot a pixel
you write to port 5, and would therefore **clobber the sound**. The sound bits
have to be maintained inside the row byte on every single write.

---

## 5. Controllers

The Channel F "grip stick" is a plectrum that does 8 things: 4 directions,
twist in two senses, and pull/push. Everything is **active low** → read it and
`com` it.

| Bit | Function |
|---|---|
| 0 | right |
| 1 | left |
| 2 | backward (down) |
| 3 | forward (up) |
| 4 | twist counter-clockwise |
| 5 | twist clockwise |
| 6 | pull up |
| 7 | push down |

The reading idiom (the `clr`+`outs` clears the latch; without it the bits stay
forced to 1):

```asm
    clr
    outs 0          ; enable the controllers (bit 6 = 0) and clear the latch
    outs 1
    ins  1          ; read the right controller
    com             ; now 1 = pressed
```

The front-panel buttons (TIME/HOLD/MODE/START) sit on port 0, bits 0–3, also
active low.

---

## 6. Cartridge format

The ROM starts at `$0800`. On reset the BIOS **compares the first byte against
`$55`**; if it does not match it launches the built-in games (Hockey/Tennis).
Then it jumps to `$0802`.

```asm
    org  $0800
    db   $55        ; "valid cartridge"
    nop
    ; execution begins here, at $0802
```

Original cartridges were 2 KiB (`$0800-$0FFF`) or 4 KiB.

The BIOS stays mapped and **readable**: you can call its routines (`clrscrn` at
`$00D0`, `drawchar` at `$0679`, …) or ignore them and just read its data — for
instance the 5×8 font that lives around `$0674`. Beware though: the BIOS
routines reserve registers for themselves (`r59` as a stack pointer, `r40-r58`
as a stack for `K`), and those bytes are precious.

---

## 7. Toolchain used in this project

| Piece | Choice | Notes |
|---|---|---|
| Assembler | **dasm** 2.20.16 | officially supports the F8 (`processor f8`); built from source with MinGW64 |
| Emulator | **MAME** 0.287, `channelf` driver | needs the BIOS romset (`sl31253/31254/90025.rom`) |
| Alternatives | asmx, f8tool | Emma 02 as an alternative emulator |

Quirks of dasm's F8 backend:

- `DS` is an F8 instruction, so the "define space" directive is called **`RES`**.
- It does not optimise: `li 0` assembles to 2 bytes, `lis 0` to 1. Your choice.
- Registers: `0`–`11` directly, `(is)`/`(is)+`/`(is)-` (or the aliases
  `s`/`i`/`d`), plus the special names `a dc0 h is k ku kl pc0 pc1 q qu ql w`
  and `j hu hl`.
- Round and square brackets are interchangeable in expressions.
- ⚠️ **It truncates out-of-range relative branches without any diagnostic.** See
  `tools/brcheck.py` and the devlog; this cost a full debugging session.

---

## 8. Design consequences for BUFO

Putting the constraints together:

1. **64 bytes of RAM** → no object list. Each lane is *one variable*: a scroll
   offset. The cars and the logs are a **generated periodic pattern**, not
   entities. Collision is computed arithmetically from the lane's offset, not
   by reading the screen (impossible — VRAM cannot be read back).
2. **Write-only VRAM** → a disciplined redraw rule is required. The toad's
   previous position is erased and redrawn each frame; the lanes are **not**
   repainted in full when they scroll, that would cost 384 pixel writes per
   lane against a budget of ~800 per frame. Scrolling is **differential**: on
   each 1-pixel step only the trailing column is erased and the leading one
   drawn.
3. **Per-row palette** → the game's vertical layout *is* the colour plan:

| Band | Palette | Fill | Objects |
|---|---|---|---|
| status | 0 | black | white bar and blocks |
| home bays | 3 | light green | blue walls |
| river | 2 | **blue (value 1) = water** | logs drawn with value 0 → **grey** |
| median strip | 3 | light green | — |
| road | 2 | light grey (asphalt) | **red** cars |
| start | 3 | light green | — |

   Note the river row: it is the one place where the fill is *not* value 0. The
   rows use palette 2 (whose value 0 is light grey) and are filled with value 1
   = blue, so the water is the fill and the logs come out grey. This keeps
   "grey means you can stand on it" true across the whole screen; with pale
   water and blue logs the convention flipped halfway up. The cost is that
   anything which erases has to use the background *of that lane*, not a global
   constant.

   The toad is **green** on every band: dark green against light green, grey and
   blue always reads. It is the only colour that works everywhere, since no band
   uses green as its fill.
4. **One single return level** → a flat call hierarchy, with `K` used explicitly
   where depth 2 is needed. A routine that saves `K` cannot call another one
   that saves `K`; this is what shapes the main loop.
