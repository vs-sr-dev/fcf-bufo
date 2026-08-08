; ===================================================================
;  test_bands.asm - empirical check of palettes and plotting
;
;  Draws BUFO's vertical layout (one palette per band) and overlays
;  three vertical blue/red/green stripes, so you can see with your own
;  eyes how the three plot colours behave against every background.
;
;  Registers used:
;    r1 = colour (byte for P_COLOR)   r2 = X
;    r3 = Y                           r4 = sound bits (0)
;    r5 = inner counter               r6 = rows left in the band
;    r7 = palette lo                  r8 = bands left
;    r9 = palette hi        (J)
;  DC0 = pointer into the band table
; ===================================================================

        processor f8
        include "ves.inc"

        org     CART_BASE
        db      CART_MAGIC              ; $0800: "valid cartridge"
        nop                             ; $0801

; ------------------------------------------------------------------
;  $0802 - entry point
; ------------------------------------------------------------------
start:
        di
        clr
        lr      4,a                     ; sound off
        lr      3,a                     ; y = 0

        dci     band_tbl
        li      NUM_BANDS
        lr      8,a

; ------------------------------------------------------------------
;  One band per iteration
; ------------------------------------------------------------------
band_loop:
        lm                              ; height
        lr      6,a
        lm                              ; fill colour
        lr      1,a
        lm                              ; low palette bit
        lr      7,a
        lm                              ; high palette bit
        lr      9,a

row_loop:
        ; --- fill the current row across all 128 columns ---------
        lr      a,1
        outs    P_COLOR
        lr      a,3
        com                             ; the row must be complemented
        ni      ROW_MASK                ; clear the sound bits...
        xs      4                       ; ...and put ours back
        outs    P_ROW

        clr
        lr      5,a                     ; x = 0
fill_x:
        lr      a,5
        com
        outs    P_COL
        li      CTRL_WRITE              ; bit5 = 1: write the pixel
        outs    P_CTRL
        li      CTRL_IDLE               ; bit5 = 0
        outs    P_CTRL
        lr      a,5
        inc
        lr      5,a
        ci      128
        bnz     fill_x

        ; --- palette bits in columns 125 and 126 -----------------
        lr      a,7
        outs    P_COLOR
        li      VRAM_PAL_LO
        com
        outs    P_COL
        li      CTRL_WRITE
        outs    P_CTRL
        li      CTRL_IDLE
        outs    P_CTRL

        lr      a,9
        outs    P_COLOR
        li      VRAM_PAL_HI
        com
        outs    P_COL
        li      CTRL_WRITE
        outs    P_CTRL
        li      CTRL_IDLE
        outs    P_CTRL

        ; --- next row --------------------------------------------
        lr      a,3
        inc
        lr      3,a
        ds      6
        bnz     row_loop

        ds      8
        bnz     band_loop

; ------------------------------------------------------------------
;  Three vertical test stripes over the playfield
; ------------------------------------------------------------------
        li      12
        lr      3,a                     ; y = 12 (first playfield row)
stripe_y:
        li      C_BLUE
        lr      1,a
        li      20
        lr      2,a
        pi      plot4

        li      C_RED
        lr      1,a
        li      40
        lr      2,a
        pi      plot4

        li      C_GREEN
        lr      1,a
        li      60
        lr      2,a
        pi      plot4

        lr      a,3
        inc
        lr      3,a
        ci      62
        bnz     stripe_y

halt:
        br      halt

; ------------------------------------------------------------------
;  plot4 - four horizontal pixels of colour r1 starting at (r2,r3)
;          clobbers: A, r2 (advanced by 4), r5
; ------------------------------------------------------------------
plot4:
        lr      a,1
        outs    P_COLOR
        lr      a,3
        com
        ni      ROW_MASK
        xs      4
        outs    P_ROW
        li      4
        lr      5,a
p4_loop:
        lr      a,2
        com
        outs    P_COL
        li      CTRL_WRITE
        outs    P_CTRL
        li      CTRL_IDLE
        outs    P_CTRL
        lr      a,2
        inc
        lr      2,a
        ds      5
        bnz     p4_loop
        pop

; ------------------------------------------------------------------
;  Band table: height, fill colour, pal_lo, pal_hi
;  The heights add up to exactly 64.
; ------------------------------------------------------------------
band_tbl:
        db      4, C_BG, PAL0_LO, PAL0_HI       ; y 0-3   off screen
        db      8, C_BG, PAL0_LO, PAL0_HI       ; y 4-11  status (black)
        db      5, C_BG, PAL3_LO, PAL3_HI       ; y 12-16 home bays
        db      5, C_BG, PAL1_LO, PAL1_HI       ; y 17-21 river 1
        db      5, C_BG, PAL1_LO, PAL1_HI       ; y 22-26 river 2
        db      5, C_BG, PAL1_LO, PAL1_HI       ; y 27-31 river 3
        db      5, C_BG, PAL1_LO, PAL1_HI       ; y 32-36 river 4
        db      5, C_BG, PAL3_LO, PAL3_HI       ; y 37-41 median strip
        db      5, C_BG, PAL2_LO, PAL2_HI       ; y 42-46 road 1
        db      5, C_BG, PAL2_LO, PAL2_HI       ; y 47-51 road 2
        db      5, C_BG, PAL2_LO, PAL2_HI       ; y 52-56 road 3
        db      5, C_BG, PAL3_LO, PAL3_HI       ; y 57-61 start
        db      2, C_BG, PAL0_LO, PAL0_HI       ; y 62-63 off screen
NUM_BANDS = 13

        ; pad out to 2 KiB
        org     CART_BASE + $7FF
        db      $FF
