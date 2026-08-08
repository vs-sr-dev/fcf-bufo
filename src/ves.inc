; ===================================================================
;  ves.inc - Fairchild Channel F (VES) hardware definitions
;  Written from scratch for BUFO. dasm syntax, processor f8.
;
;  References checked against: MAME fairchild/channelf.cpp + channelf_v.cpp
; ===================================================================

; ------------------------------------------------------------------
;  I/O ports
; ------------------------------------------------------------------
;  P_CTRL  (0) write: bit5 = VRAM write strobe
;                     bit6 = 1 -> controllers disabled
;              read:  console front-panel buttons, active low
;  P_COLOR (1) write: bits 7-6 = complemented pixel value
;              read:  right controller, active low
;  P_COL   (4) write: column (7 bits), complemented
;              read:  left controller, active low
;  P_ROW   (5) write: row (6 bits), complemented, + bits 7-6 = sound
; ------------------------------------------------------------------
P_CTRL          = 0
P_COLOR         = 1
P_COL           = 4
P_ROW           = 5

P_JOY_R         = 1             ; read aliases
P_JOY_L         = 4
P_PANEL         = 0

; values written to P_CTRL
CTRL_IDLE       = $40           ; controllers off, no strobe
CTRL_WRITE      = $60           ; controllers off + VRAM write strobe
CTRL_READ       = $00           ; controllers enabled

; ------------------------------------------------------------------
;  Colours: byte written to P_COLOR (bits 7-6 = ~pixel_value)
;  The colour you actually get depends on the row's palette:
;      pal 0:  BLACK   WHITE WHITE WHITE
;      pal 1:  LTBLUE  BLUE  RED   GREEN
;      pal 2:  LTGRAY  BLUE  RED   GREEN
;      pal 3:  LTGREEN BLUE  RED   GREEN
;                ^val0  ^1    ^2    ^3
; ------------------------------------------------------------------
C_BG            = $C0           ; pixel value 0 -> the background colour
C_BLUE          = $80           ; pixel value 1
C_RED           = $40           ; pixel value 2
C_GREEN         = $00           ; pixel value 3

C_WHITE         = $80           ; under palette 0 every non-zero value is white
C_BLACK         = $C0

; ------------------------------------------------------------------
;  Per-row palette: stored in columns 125 and 126.
;  The palette is formed from bit 1 of the pixel value:
;      low bit   <- bit1 of the pixel in column 125
;      high bit  <- bit1 of the pixel in column 126
;  Bit 1 is set for values 2 (RED) and 3 (GREEN).
;  So we use C_RED for "bit set" and C_BG for "bit clear".
; ------------------------------------------------------------------
VRAM_PAL_LO     = 125           ; column holding the low palette bit
VRAM_PAL_HI     = 126           ; column holding the high palette bit

PBIT_1          = $40           ; = C_RED  -> palette bit set
PBIT_0          = $C0           ; = C_BG   -> palette bit clear

; the four combinations, as (column 125, column 126) pairs
PAL0_LO = PBIT_0
PAL0_HI = PBIT_0                ; palette 0: black / white
PAL1_LO = PBIT_1
PAL1_HI = PBIT_0                ; palette 1: pale blue background
PAL2_LO = PBIT_0
PAL2_HI = PBIT_1                ; palette 2: light grey background
PAL3_LO = PBIT_1
PAL3_HI = PBIT_1                ; palette 3: light green background

; ------------------------------------------------------------------
;  Geometry
; ------------------------------------------------------------------
VRAM_W          = 128           ; addressable columns
VRAM_H          = 64            ; rows
VIS_X0          = 4             ; first visible column
VIS_Y0          = 4             ; first visible row
VIS_W           = 102
VIS_H           = 58

; ------------------------------------------------------------------
;  Sound: bits 7-6 of the byte written to P_ROW.
;  The tone decays on its own and has to be retriggered by writing it
;  again. Careful: P_ROW is written on every pixel, so the sound bits
;  must be held in a register and reapplied every time.
; ------------------------------------------------------------------
SND_OFF         = $00
SND_TONE1       = $40
SND_TONE2       = $80
SND_TONE3       = $C0
SND_MASK        = $C0
ROW_MASK        = $3F           ; mask that clears the sound bits

; ------------------------------------------------------------------
;  Controllers (after ins + com: 1 = pressed)
; ------------------------------------------------------------------
JOY_RIGHT       = $01
JOY_LEFT        = $02
JOY_DOWN        = $04
JOY_UP          = $08
JOY_CCW         = $10
JOY_CW          = $20
JOY_PULL        = $40
JOY_PUSH        = $80

; front-panel buttons (port 0, after com)
BTN_TIME        = $01
BTN_HOLD        = $02
BTN_MODE        = $04
BTN_START       = $08

; ------------------------------------------------------------------
;  Cartridge
; ------------------------------------------------------------------
CART_BASE       = $0800
CART_MAGIC      = $55           ; the BIOS compares $0800 against this
                                ; value and then jumps to $0802

; ------------------------------------------------------------------
;  BIOS routines (unused by the game, but handy while debugging).
;  Careful: they reserve r59 as a stack pointer and r40-r58 as a stack
;  for K.
; ------------------------------------------------------------------
BIOS_CLRSCRN    = $00D0
BIOS_DELAY      = $008F
BIOS_DRAWCHAR   = $0679
BIOS_FONT       = $0674         ; 5x8 font data

; ------------------------------------------------------------------
;  Masks for bt / bf
; ------------------------------------------------------------------
F_SIGN          = 1
F_CARRY         = 2
F_ZERO          = 4
F_OVF           = 8
