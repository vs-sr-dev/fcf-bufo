; ===================================================================
;  BUFO  -  a road-and-river crossing game for the Fairchild Channel F
;
;  Written from scratch: no code, graphics or data derived from any
;  other game. The mechanics of a crossing game (road, river, home
;  bays) are not copyrightable; the name and the artwork here are ours.
;
;  Core idea: with 64 bytes of RAM there is no object list. Each lane
;  is ONE variable (an offset), and the cars / logs are a periodic
;  pattern that is *computed*:
;
;      rel = (x - PF_X0 - offset) & mask
;      an object covers x  <=>  rel < width
;
;  With mask = period-1 (a power of two dividing PF_W = 96) the modulo
;  is a plain AND and the pattern wraps seamlessly. The same formula
;  drives drawing, erasing and collision detection - which matters,
;  because Channel F video RAM cannot be read back.
;
;  Budget: ~20 us per pixel, i.e. ~800 pixels per frame. Repainting a
;  whole lane costs 96*4 = 384 pixels, impossible for 7 lanes. So
;  scrolling is DIFFERENTIAL: on each 1-pixel step we erase the
;  trailing column and draw the leading one, 4 pixels each. With 3
;  objects per lane that is 24 pixels instead of 384, and all 7 lanes
;  fit in ~170 pixels per frame.
; ===================================================================

        processor f8
        include "ves.inc"

; ------------------------------------------------------------------
;  Playfield geometry
; ------------------------------------------------------------------
PF_X0       = 4                 ; first column of the playfield
PF_W        = 96                ; width (divisible by 16 and by 32)

LANE_Y0     = 12                ; top row of lane 0
LANE_H      = 5                 ; height of one lane
OBJ_H       = 4                 ; height of objects (and of the toad)
NUM_MOV     = 7                 ; moving lanes (4 river + 3 road)

HOME_PERIOD = 18                ; home row: 6-wide wall + 12-wide bay
HOME_WALL   = 6
WIN_BAYS    = $1F               ; all 5 bays filled = round complete.
                                ; Lowering it (e.g. $04 = third bay
                                ; only) lets you exercise the win path
                                ; with a single crossing.

DIR_LEFT    = $80               ; bit 7 of the speed byte
RIDEABLE    = $40               ; bit 6: this lane CARRIES you (river)
SPEED_MASK  = $0F               ; bits 0-3 = frames per pixel

DELAY_OUTER = 2                 ; frame delay tuning (measured)

; ------------------------------------------------------------------
;  Scratchpad map
;
;  Only r0-r11 are addressable directly by the instruction set, so
;  they are the scarce resource and go to the hot data. Everything
;  else goes through ISAR (and remember that (IS)+ wraps inside its
;  8-register bank).
;
;    r0   base / index           r6   lane mask
;    r1   colour                 r7   top y of the lane
;    r2   x                      r8   object width
;    r3   y                      r9   speed / counter
;    r4   lane background        r10  ISAR base of the lane
;    r5   inner counter          r11  lanes left
;    r12:r13 = K (saved return address)
;
;  Banks 2-3 (r16-r29): one (offset, counter) pair per moving lane, so
;  the two values sit next to each other.
; ------------------------------------------------------------------
LANE_OFS    = 16                ; r16+2j = offset, r17+2j = counter

; bank 4: game state (reached through ISAR)
V_FRAME     = 32                ; frame counter
V_BARX      = 33                ; calibration bar (temporary)
V_FROGX     = 34                ; toad column
V_FROGL     = 35                ; toad lane (0 = home bays, 9 = start)
V_PREVIN    = 36                ; previous frame's input (rising edge)
V_OLDX      = 37                ; previous position, for erasing
V_OLDL      = 38

; bank 5: game rules
V_LIVES     = 40                ; lives left
V_BAYS      = 41                ; bits 0-4: bays already filled
V_STATE     = 42                ; 0 = playing, 1 = dying, 2 = game over
V_DEAD      = 43                ; pause frames after a death
V_TIMER     = 44                ; time left, in bar units
V_TTICK     = 45                ; frames until the next time unit
V_LIVESHOWN = 46                ; lives last drawn (to avoid redrawing)
V_SND       = 47                ; bits 7-6 = tone, bits 0-5 = frames left

; bank 6: music sequencer
V_MUSIDX    = 48                ; current note of the riff
V_MUSTICK   = 49                ; frames left on this note

; Tones: bits 7-6 = tone, bits 0-5 = duration in frames. The tone is
; programmed ONCE per frame (sound_tick), never from the drawing code.
;
; WARNING - TONES ARE DISABLED. Any non-zero tone crashes MAME 0.287
; inside channelf_sound_device::sound_stream_update (ACCESS VIOLATION,
; reading 0xffffffffffffffff), with this stack:
;     port_5_w -> sound_w(mode) -> sound_stream::update() -> crash
; MAME calls sound_w on every port 5 write but returns immediately if
; the mode has not changed: keeping the tone at 0 means its stream is
; never updated and the bug never fires. Our use of port 5 follows the
; hardware spec, so the fault is in MAME's device, not in this ROM.
; To try tones again (or on real hardware) restore the commented values.
SOUND_ON    = 0                 ; 1 = actually emit tones (crashes MAME 0.287)

SND_HOP     = 0                 ; was SND_TONE1|6   hop click
SND_BAY     = 0                 ; was SND_TONE2|20  bay reached
SND_DEAD    = 0                 ; was SND_TONE3|40  death

; ------------------------------------------------------------------
;  Background music
;
;  The Channel F has no programmable pitch: two bits give silence plus
;  THREE fixed tones (roughly 1 kHz, 500 Hz, 120 Hz), with no divider.
;  So a melody in a key is impossible; what this hardware can play is a
;  rhythmic ostinato over three pitches, and that is what this is.
;
;  Note: the sound bits live in the same byte as the VRAM row, so every
;  pixel write clears them. The tone is only on during the end-of-frame
;  delay, which on real hardware sounds like a tone chopped at ~80 Hz.
;  That is inherent to sharing port 5, not a defect in this code.
; ------------------------------------------------------------------
SND_LOW     = SND_TONE3         ; low    (~120 Hz)
SND_MID     = SND_TONE2         ; middle (~500 Hz)
SND_HIGH    = SND_TONE1         ; high   (~1 kHz)

MUS_LEN     = 8                 ; notes in the riff
MUS_FRAMES  = 16                ; ~0.2 s per note -> the riff lasts ~1.6 s

; The loop runs at ~80 iterations per second: MEASURED by comparing two
; snapshots 1 s apart and reading the scroll of all seven lanes against
; their respective periods (see tools/measure.lua). Do not infer it from
; the code: it depends on DELAY_OUTER and on the cost of the frame.
LOOP_HZ     = 80

LIVES0      = 3                 ; lives at the start of a game
LIVES_MAX   = 3                 ; cap: above this the end-of-round bonus
                                ; is not granted, because draw_lives
                                ; paints into a fixed-width slot
; The pause is counted in LOOP ITERATIONS, and the "dying" branch runs
; many more of them per second (~128) because it skips lanes and
; drawing: 64 gave 0.5 s instead of 0.8. This value is tuned against the
; measured rate of THAT branch, not against LOOP_HZ.
DEAD_PAUSE  = 100               ; ~0.8 s pause after a death
TIMER0      = 56                ; time units (= width of the bar)
TIMER_FRAMES= 40                ; 0.5 s per unit -> ~28 s per life

; status area: black band, y 4-11
ST_TIMER_Y  = 9                 ; time bar, y 9-10
ST_TIMER_X  = 4
ST_LIVES_Y  = 5                 ; lives, y 5-7
ST_LIVES_X  = 78                ; three 4 px blocks plus spacing

; home bays: phase range that counts as being inside a bay (the bay
; spans 6..17, and the toad is 5 wide, hence 6..13)
HOME_PH_MIN = 6                 ; = HOME_WALL
HOME_PH_MAX = 13                ; = HOME_PERIOD - toad width (18-5)

; ------------------------------------------------------------------
;  The toad
; ------------------------------------------------------------------
FROG_W      = 5                 ; sprite width
FROG_HOP    = 6                 ; horizontal step of one hop
FROG_XMIN   = PF_X0             ; = 4
FROG_XMAX   = PF_X0+15*FROG_HOP ; = 94: the 16 slots 4,10,...,94
FROG_X0     = PF_X0+7*FROG_HOP  ; = 46, start (and edge of bay 3)
LANE_MAX    = 9                 ; the starting lane

        org     CART_BASE
        db      CART_MAGIC              ; $0800 - "valid cartridge"
        nop                             ; $0801

; ===================================================================
;  Macro: write one pixel at row r3, then advance r3.
;  Colour and column must be programmed beforehand. Clobbers: A, r3.
; ===================================================================
        MAC pixrow
        lr      a,3
        com                             ; the row select is active low
        ni      ROW_MASK                ; bits 7-6 to zero: NEVER touch
        outs    P_ROW                   ; the sound from here (see sound_tick)
        li      CTRL_WRITE              ; bit 5 = VRAM write strobe
        outs    P_CTRL
        li      CTRL_IDLE
        outs    P_CTRL
        lr      a,3
        inc
        lr      3,a
        ENDM

; ===================================================================
;  Macro: access game state (registers above r11, so reachable only
;  through ISAR). lisu/lisl do not touch A.
; ===================================================================
        MAC ldv                         ; ldv reg -> A = r{reg}
        lisu    ({1})>>3
        lisl    ({1})&7
        lr      a,s
        ENDM

        MAC stv                         ; stv reg -> r{reg} = A
        lisu    ({1})>>3
        lisl    ({1})&7
        lr      s,a
        ENDM

; ===================================================================
;  $0802 - entry point
;
;  Initialisation runs at call level 0, so it may use "pi" into leaf
;  routines without saving PC1 into K.
; ===================================================================
start:
        di
        clr
        lr      4,a                     ; no tone active

; -------------------------------------------------------------------
;  1) Horizontal bands: background and palette bits of every row
; -------------------------------------------------------------------
        clr
        lr      3,a                     ; y = 0
        dci     band_tbl
        li      NUM_BANDS
        lr      8,a

band_loop:
        lm
        lr      6,a                     ; band height
        lm
        lr      1,a                     ; fill colour
        lm
        lr      7,a                     ; low palette bit
        lm
        lr      9,a                     ; high palette bit

band_row:
        lr      a,1
        outs    P_COLOR
        pi      set_row
        clr
        lr      5,a
band_x:
        lr      a,5
        com
        outs    P_COL
        pi      pulse
        lr      a,5
        inc
        lr      5,a
        ci      VRAM_W
        bnz     band_x

        ; the two palette bits live outside the visible area
        lr      a,7
        outs    P_COLOR
        li      VRAM_PAL_LO
        com
        outs    P_COL
        pi      pulse
        lr      a,9
        outs    P_COLOR
        li      VRAM_PAL_HI
        com
        outs    P_COL
        pi      pulse

        lr      a,3
        inc
        lr      3,a
        ds      6
        bnz     band_row
        ds      8
        bnz     band_loop

; -------------------------------------------------------------------
;  2) Home bays: 6-wide blue walls every 18 pixels -> five 12-wide bays
; -------------------------------------------------------------------
        pi      draw_homes

; -------------------------------------------------------------------
;  3) Moving lanes: seed the state and paint the full pattern.
;
;  The initial paint reuses edge_run: calling it with base = offset+d
;  for d = 0..width-1 covers every column of every object, so there is
;  no need for a second drawing routine.
; -------------------------------------------------------------------
        dci     lane_tbl
        li      NUM_MOV
        lr      11,a
        li      LANE_OFS
        lr      10,a

init_lane:
        lm
        lr      7,a                     ; top y
        lm
        lr      6,a                     ; mask
        lm
        lr      8,a                     ; width
        lm
        lr      1,a                     ; colour
        lm
        lr      9,a                     ; speed
        lm
        lr      2,a                     ; initial offset

        ; offset = initial value
        lr      a,10
        lr      is,a
        lr      a,2
        lr      s,a
        ; counter = frames per pixel
        lr      a,10
        inc
        lr      is,a
        lr      a,9
        ni      SPEED_MASK
        lr      s,a

        clr
        lr      9,a                     ; d = 0 (r9 is free from here)
init_draw:
        lr      a,10
        lr      is,a
        lr      a,s                     ; offset
        as      9                       ; + d
        lr      0,a
        pi      edge_run
        lr      a,9
        inc
        lr      9,a
        lr      a,8
        com
        inc                             ; A = -width
        as      9                       ; A = d - width
        bnz     init_draw

        lr      a,10
        ai      2
        lr      10,a                    ; next (offset,counter) pair
        ds      11
        bnz     init_lane

; -------------------------------------------------------------------
;  4) Initial state
; -------------------------------------------------------------------
        clr
        stv     V_FRAME
        stv     V_PREVIN
        stv     V_BAYS
        stv     V_STATE
        stv     V_DEAD
        li      LIVES0
        stv     V_LIVES
        li      $FF
        stv     V_LIVESHOWN             ; differs from V_LIVES: forces a draw
        clr
        stv     V_SND
        stv     V_MUSIDX                ; the riff starts on its first note
        li      MUS_FRAMES
        stv     V_MUSTICK
        pi      respawn
        pi      draw_timer_full
        pi      draw_frog
        pi      draw_lives

; ===================================================================
;  Main loop
;
;  The toad is redrawn every frame (~16 pixels): it is cheap, and it
;  saves having to know when a scrolling lane has painted over it. It
;  is only erased when it hops, rebuilding the background with the same
;  formula that draws the lane.
; ===================================================================
;  The loop has two branches, selected by V_STATE: alive (0), or dying
;  (1) / game over (2). Keeping them apart avoids sprinkling state
;  checks through the individual routines.
;
;  No routine called from here may call another one that uses K: the
;  3850 has exactly ONE hardware return level (PC1) and K is the only
;  place to save it. That is why respawning happens here and not inside
;  dead_tick, which would otherwise have to call erase_frog (which
;  uses K).
main_loop:
        ldv     V_STATE
        ci      0
        bnz     ml_dead

        pi      lane_update
        pi      frog_input
        pi      check_frog
        pi      tick_timer
        pi      erase_frog
        pi      draw_frog
        pi      save_old

        ; --- did we reach a home bay this frame? ----------------
        ; We get here with the toad already erased from the lane it
        ; jumped from (erase_frog did it using V_OLD*), so the bay can
        ; now be marked and the toad respawned without leaving debris.
        ldv     V_STATE
        ci      3
        bnz     ml_tail
        pi      draw_bay

        ; --- five bays out of five: round complete --------------
        ldv     V_BAYS
        ci      WIN_BAYS
        bnz     ml_nowin
        pi      new_round               ; free the bays, +1 life
        pi      draw_homes              ; wipe the green markers
ml_nowin:
        pi      respawn
        pi      draw_timer_full
        pi      draw_frog
        pi      save_old
        clr
        stv     V_STATE
        br      ml_tail

; --- dying: run out the pause, then respawn ------------------------
ml_dead:
        pi      dead_tick
        ldv     V_STATE
        ci      2
        bz      ml_over                 ; game over
        ci      0
        bnz     ml_tail                 ; pause still running
        ; Pause over. The toad must be erased from WHERE IT DIED before
        ; respawning, because respawn overwrites V_OLD* with the start
        ; position and after that there is no record of where it was.
        pi      erase_frog
        pi      respawn
        pi      draw_timer_full
        pi      draw_frog
        pi      save_old
        br      ml_tail

; --- game over: blinking bar, START restarts -----------------------
;     There is neither room nor a font to spell it out: blinking is the
;     most readable signal this hardware affords cheaply. V_DEAD is
;     free here (dead_tick leaves it alone once the game is over) and
;     serves as the counter: bits 0-4 the period, bit 5 the phase.
ml_over:
        ldv     V_DEAD
        inc
        stv     V_DEAD
        ni      $1F
        bnz     ml_start                ; repaint once every 32 loops
        ldv     V_DEAD
        ni      $20
        bz      ml_off
        li      C_WHITE
        br      ml_bar
ml_off:
        li      C_BG
ml_bar:
        lr      1,a
        pi      draw_timer_bar

ml_start:
        clr
        outs    P_CTRL                  ; enable the console buttons and
        ins     P_PANEL                 ; clear the port 0 latch
        com                             ; active low -> 1 = pressed
        ni      BTN_START
        bz      ml_tail
        jmp     start                   ; new game, everything from scratch

ml_tail:
        pi      draw_lives
        pi      sound_tick
        pi      delay
        ; The loop body is longer than 128 bytes, so a "br" cannot reach
        ; the top: dasm would silently truncate it. A is dead here and
        ; DC0 gets reloaded by lane_update, so jmp is safe.
        jmp     main_loop

; ===================================================================
;  frog_input - read the controller and make the toad hop.
;
;  Hops fire on the RISING EDGE of the command: holding a direction
;  does not make the toad slide.
; ===================================================================
frog_input:
        clr
        outs    P_CTRL                  ; bit6 = 0: enable the controllers
        outs    P_COLOR                 ; clear the port 1 latch
        ins     P_JOY_R
        com                             ; active low -> 1 = pressed
        lr      6,a
        ldv     V_PREVIN
        com                             ; ~previous
        ns      6                       ; & current = newly pressed keys
        lr      7,a
        lr      a,6
        stv     V_PREVIN
        lr      a,7
        ci      0
        bz      fi_done

        ; Do NOT save V_OLD* here. It looks like the right place, but it
        ; is not: lane_update runs BEFORE frog_input, and a log may have
        ; already moved V_FROGX this frame. We would erase where the toad
        ; *is* rather than where it was *drawn*, leaving a ghost column
        ; in the river. V_OLD* is maintained by save_old at end of frame,
        ; which is exactly the position of the last draw.

        ; --- one direction per hop ------------------------------
        lr      a,7
        ni      JOY_UP
        bnz     fi_up
        lr      a,7
        ni      JOY_DOWN
        bnz     fi_down
        lr      a,7
        ni      JOY_LEFT
        bnz     fi_left
        lr      a,7
        ni      JOY_RIGHT
        bnz     fi_right
        br      fi_done

fi_up:                                  ; towards the bays: lane--
        ldv     V_FROGL
        ci      0
        bz      fi_done                 ; already at the top
        ai      $FF
        stv     V_FROGL
        br      fi_move

fi_down:                                ; lane++
        ldv     V_FROGL
        ci      LANE_MAX
        bz      fi_done
        inc
        stv     V_FROGL
        br      fi_move

fi_left:
        ldv     V_FROGX
        ci      FROG_XMIN
        bz      fi_done
        ai      (256-FROG_HOP)
        stv     V_FROGX
        br      fi_move

fi_right:
        ldv     V_FROGX
        ci      FROG_XMAX
        bz      fi_done
        ai      FROG_HOP
        stv     V_FROGX

fi_move:
        li      SND_HOP
        stv     V_SND
fi_done:
        pop

; ===================================================================
;  lane_update - scroll by 1 pixel every lane whose turn it is.
;
;  Called from level 0, so it saves the return address in K in order to
;  be able to call edge_run.
; ===================================================================
lane_update:
        lr      k,p                     ; save PC1: the "pi" calls need it
        ldv     V_FRAME                 ; a single, global counter
        inc
        stv     V_FRAME
        dci     lane_tbl
        li      NUM_MOV
        lr      11,a
        li      LANE_OFS
        lr      10,a

lu_lane:
        lm
        lr      7,a                     ; top y
        lm
        lr      6,a                     ; mask
        lm
        lr      8,a                     ; width
        lm
        lr      1,a                     ; colour
        lm
        lr      9,a                     ; speed
        lm                              ; initial offset: not needed here

        ; --- is it this lane's turn? ----------------------------
        ; A lane moves when (frame & mask) == 0. There is no per-lane
        ; counter to maintain: the global counter decides, and the mask
        ; (a power of two minus one) sets the rhythm.
        lr      a,9
        ni      SPEED_MASK
        lr      5,a                     ; rhythm mask
        ldv     V_FRAME
        ns      5
        bnz     lu_next                 ; not this lane's turn

        ; --- background of THIS lane ----------------------------
        ; In the river the fill is water (value 1); on the road it is
        ; asphalt (value 0). The trailing column must be erased with the
        ; right one or it leaves a trail. r4 is free (it used to hold
        ; the sound bits, which sound_tick now owns).
        li      C_BG
        lr      4,a
        lr      a,9
        ni      RIDEABLE
        bz      lu_bgok
        li      C_BLUE
        lr      4,a
lu_bgok:

        ; --- current offset -------------------------------------
        lr      a,10
        lr      is,a                    ; ISAR -> offset
        lr      a,s
        lr      2,a                     ; offset_old
        lr      a,9
        ni      DIR_LEFT
        bnz     lu_left

; ---- rightwards: offset++ --------------------------------------
;      head = offset_new + width-1   tail = offset_old
        lr      a,2
        inc
        ns      6                       ; & mask
        lr      s,a                     ; offset_new
        lr      a,8
        ai      $FF                     ; width - 1
        as      s                       ; + offset_new
        lr      0,a
        pi      edge_run                ; draw the head
        ; the tail follows from the new offset: no need to keep it
        lr      a,10
        lr      is,a
        lr      a,s
        ai      $FF                     ; offset_new - 1 = offset_old
        ns      6
        lr      0,a
        lr      a,4                     ; lane background (water or asphalt)
        lr      1,a
        pi      edge_run                ; erase the tail
        br      lu_carry

; ---- leftwards: offset-- ---------------------------------------
;      head = offset_new   tail = offset_old + width-1
lu_left:
        lr      a,2
        ai      $FF                     ; offset - 1
        ns      6
        lr      s,a                     ; offset_new
        lr      0,a
        pi      edge_run                ; draw the head
        lr      a,10
        lr      is,a
        lr      a,s
        inc                             ; offset_new + 1 = offset_old
        ns      6
        lr      2,a
        lr      a,8
        ai      $FF                     ; width - 1
        as      2
        lr      0,a
        lr      a,4                     ; lane background (water or asphalt)
        lr      1,a
        pi      edge_run                ; erase the tail

; ---- carrying: if the toad is on this lane and the lane is
;      "rideable" (a river lane), it drifts along with the log.
;      r7 = lane y, r9 = speed byte
lu_carry:
        lr      a,9
        ni      RIDEABLE
        bz      lu_next                 ; the road does not carry
        ldv     V_FROGL
        lr      0,a
        sl      1
        sl      1
        as      0
        ai      LANE_Y0
        lr      5,a                     ; toad y
        lr      a,7
        com
        inc
        as      5                       ; toad_y - lane_y
        bnz     lu_next                 ; not on this lane
        ldv     V_FROGX
        lr      2,a
        lr      a,9
        ni      DIR_LEFT
        bnz     lu_cleft
        lr      a,2
        inc                             ; the log drifts right
        br      lu_cstore
lu_cleft:
        lr      a,2
        ai      $FF                     ; the log drifts left
lu_cstore:
        stv     V_FROGX

lu_next:
        lr      a,10
        ai      2
        lr      10,a
        ds      11
        bz      lu_end
        ; The loop body exceeds 128 bytes, so a "bnz lu_lane" does NOT
        ; reach it: the branch displacement is a single signed byte and
        ; dasm would truncate it silently (this cost us a debugging
        ; session: it landed inside edge_run). Absolute jump instead.
        ; jmp destroys A, which is already dead here, and leaves DC0
        ; alone - essential, because lu_lane keeps reading with "lm".
        jmp     lu_lane
lu_end:
        lr      p,k                     ; restore the return address
        pop

; ===================================================================
;  Leaf routines (they call nothing, so they use PC1 directly)
; ===================================================================

; -------------------------------------------------------------------
;  edge_run - draw one OBJ_H-tall column for EVERY object in the lane,
;             all at the same phase.
;
;  in:   r0 = starting phase (offset + delta)
;        r1 = colour    r6 = mask    r7 = top y
;  out:  clobbers A, r2, r3, r5   (r0 and r1 stay valid)
;
;  The number of objects need not be known: the phases are base + t
;  with t = 0, P, 2P, ..., and we stop once t reaches PF_W, because the
;  period divides the playfield width.
; -------------------------------------------------------------------
edge_run:
        clr
        lr      5,a                     ; t = 0
er_loop:
        lr      a,0
        as      5                       ; x' = base + t
        lr      2,a
        li      PF_W
        com
        inc                             ; A = -96
        as      2                       ; A = x' - 96
        bnc     er_nowrap               ; x' < 96: nothing to do
        lr      2,a                     ; otherwise wrap it around
er_nowrap:
        lr      a,2
        ai      PF_X0
        lr      2,a                     ; absolute column

        lr      a,1
        outs    P_COLOR
        lr      a,2
        com
        outs    P_COL
        lr      a,7
        lr      3,a                     ; start from the top y
        pixrow
        pixrow
        pixrow
        pixrow                          ; OBJ_H = 4 rows

        lr      a,6
        inc                             ; period = mask + 1
        as      5
        lr      5,a                     ; t += period
        ci      PF_W
        bnz     er_loop
        pop

; -------------------------------------------------------------------
;  draw_frog - draw the toad's 5x4 sprite, in green.
;
;  The bitmap is stored by COLUMN (one byte per column, bit 0 = top
;  row), so colour and column are programmed once per column and the
;  byte is walked with "sr 1".
;  clobbers: A, r0, r2, r3, r5, r6, r7, r8, DC0
; -------------------------------------------------------------------
draw_frog:
        ldv     V_FROGL
        lr      0,a
        sl      1
        sl      1                       ; lane * 4
        as      0                       ; lane * 5
        ai      LANE_Y0
        lr      7,a                     ; top y
        ldv     V_FROGX
        lr      2,a
        dci     frog_bmp
        li      FROG_W
        lr      5,a
df_col:
        lm
        lr      6,a                     ; column mask
        li      C_GREEN
        outs    P_COLOR
        lr      a,2
        com
        outs    P_COL
        lr      a,7
        lr      3,a
        li      OBJ_H
        lr      8,a
df_row:
        lr      a,6
        ni      1
        bz      df_skip                 ; bit clear: transparent pixel
        lr      a,3
        com
        ni      ROW_MASK
        outs    P_ROW
        li      CTRL_WRITE
        outs    P_CTRL
        li      CTRL_IDLE
        outs    P_CTRL
df_skip:
        lr      a,3
        inc
        lr      3,a
        lr      a,6
        sr      1
        lr      6,a
        ds      8
        bnz     df_row
        lr      a,2
        inc
        lr      2,a
        ds      5
        bnz     df_col
        pop

; -------------------------------------------------------------------
;  erase_frog - restore the background where the toad used to be.
;
;  Since VRAM cannot be read back, the background has to be
;  RECOMPUTED: look the lane up in the table and, for each column,
;  reapply rel = (x - PF_X0 - offset) & mask ; object if rel < width.
;  Static lanes (bays, median, start) have width = 0 and are erased
;  with the plain background colour.
;  clobbers: A, r0..r3, r5..r11, DC0
; -------------------------------------------------------------------
erase_frog:
        lr      k,p
        ldv     V_OLDL
        lr      0,a
        sl      1
        sl      1
        as      0
        ai      LANE_Y0
        lr      7,a                     ; top y
        ldv     V_OLDX
        lr      2,a
        pi      lane_lookup             ; r8=width r6=mask r9=offset r1=colour

        ; Background of this lane: water on the river, the plain
        ; background elsewhere. It has to be decided BEFORE reusing r0,
        ; where lane_lookup left the speed byte with the RIDEABLE bit.
        ; On static lanes r8 = 0 and r0 is not meaningful.
        li      C_BG
        lr      4,a
        lr      a,8
        ci      0
        bz      ef_bgok                 ; static lane
        lr      a,0
        ni      RIDEABLE
        bz      ef_bgok                 ; road
        li      C_BLUE                  ; river: the background is water
        lr      4,a
ef_bgok:
        li      FROG_W
        lr      11,a
ef_col:
        lr      a,4
        lr      0,a                     ; default colour
        lr      a,8
        ci      0
        bz      ef_put                  ; static lane
        lr      a,2
        ai      (256-PF_X0)             ; x - PF_X0
        lr      3,a
        lr      a,9
        com
        inc                             ; -offset
        as      3
        ns      6                       ; rel
        lr      3,a
        lr      a,8
        com
        inc                             ; -width
        as      3                       ; rel - width, C if rel >= width
        bc      ef_put                  ; outside the object
        lr      a,1
        lr      0,a                     ; inside: the object's colour
ef_put:
        lr      a,0
        outs    P_COLOR
        lr      a,2
        com
        outs    P_COL
        lr      a,7
        lr      3,a
        pixrow
        pixrow
        pixrow
        pixrow
        lr      a,2
        inc
        lr      2,a
        ds      11
        bnz     ef_col
        lr      p,k
        pop

; -------------------------------------------------------------------
;  lane_lookup - find the moving lane that sits at row r7.
;
;  out: r8 = object width (0 = static lane: no objects)
;       r6 = mask   r9 = current offset   r1 = object colour
;       r0 = speed byte (RIDEABLE / DIR_LEFT bits)
;  r1/r0/r6/r9 are only meaningful when r8 != 0.
;  clobbers: A, r0, r1, r5, r6, r8, r9, r10, r11, DC0. Preserves r2, r7.
; -------------------------------------------------------------------
lane_lookup:
        clr
        lr      8,a                     ; width = 0 -> static
        dci     lane_tbl
        li      NUM_MOV
        lr      11,a
        li      LANE_OFS
        lr      10,a
ll_scan:
        lm
        lr      9,a                     ; y of this entry
        lm
        lr      6,a                     ; mask
        lm
        lr      5,a                     ; width
        lm
        lr      1,a                     ; colour
        lm
        lr      0,a                     ; speed
        lm                              ; initial offset: discarded
        lr      a,7
        com
        inc
        as      9                       ; entry_y - wanted_y
        bnz     ll_next
        lr      a,5
        lr      8,a                     ; found: publish the width
        lr      a,10
        lr      is,a
        lr      a,s
        lr      9,a                     ; current offset
        pop
ll_next:
        lr      a,10
        ai      2
        lr      10,a
        ds      11
        bnz     ll_scan
        pop

; -------------------------------------------------------------------
;  check_frog - the rules: run over, drowning, home bays.
;
;  It looks at the toad's CENTRE column: on the road, being centred on
;  a car means being run over; on the river, NOT being on a log means
;  drowning. Same formula as the drawing code, third application.
; -------------------------------------------------------------------
check_frog:
        lr      k,p

        ; --- carried off the playfield? -------------------------
        ldv     V_FROGX
        lr      2,a
        li      PF_X0
        com
        inc
        as      2                       ; x - PF_X0
        bnc     cf_kill                 ; x < PF_X0
        lr      a,2
        lr      5,a
        li      FROG_XMAX+1
        com
        inc
        as      5                       ; x - (XMAX+1)
        bc      cf_kill                 ; x > XMAX

        ; --- lane 0 = the home bays -----------------------------
        ldv     V_FROGL
        ci      0
        bz      cf_home

        ; --- find the lane under the toad -----------------------
        lr      0,a
        sl      1
        sl      1
        as      0
        ai      LANE_Y0
        lr      7,a
        ldv     V_FROGX
        ai      2                       ; centre column
        lr      2,a
        pi      lane_lookup
        lr      a,8
        ci      0
        bz      cf_safe                 ; static lane: always safe

        ; --- is there an object under the centre? ---------------
        lr      a,2
        ai      (256-PF_X0)
        lr      3,a
        lr      a,9
        com
        inc
        as      3
        ns      6                       ; rel
        lr      3,a
        lr      a,8
        com
        inc
        as      3                       ; rel - width
        bc      cf_noobj                ; outside the object

        lr      a,0                     ; on top of an object
        ni      RIDEABLE
        bnz     cf_safe                 ; a log: it floats
        br      cf_kill                 ; a car: run over

cf_noobj:
        lr      a,0
        ni      RIDEABLE
        bnz     cf_kill                 ; river with no log: it drowns
cf_safe:
        lr      p,k
        pop

cf_kill:
        pi      kill_frog
        lr      p,k
        pop

; --- lane 0: did it land inside a bay? ---------------------------
;     phase = (x - PF_X0) mod 18, index = (x - PF_X0) / 18
cf_home:
        ldv     V_FROGX
        ai      (256-PF_X0)
        lr      2,a                     ; p
        clr
        lr      5,a                     ; bay index
ch_mod:
        lr      a,2
        lr      3,a
        li      HOME_PERIOD
        com
        inc
        as      3                       ; p - 18
        bnc     ch_phase                ; p < 18: phase found
        lr      2,a                     ; p -= 18
        lr      a,5
        inc
        lr      5,a
        br      ch_mod

ch_phase:
        lr      a,2                     ; phase
        lr      3,a
        li      HOME_PH_MIN
        com
        inc
        as      3                       ; phase - 6
        bnc     cf_kill                 ; on the wall
        lr      a,2
        lr      3,a
        li      HOME_PH_MAX+1
        com
        inc
        as      3
        bc      cf_kill                 ; sticking out of the bay

        ; --- bit mask for this bay: 1 << index ------------------
        li      1
        lr      3,a
        lr      a,5
        ci      0
        bz      ch_mask
ch_shl:
        lr      a,3
        sl      1
        lr      3,a
        ds      5
        bnz     ch_shl
ch_mask:
        ldv     V_BAYS
        ns      3
        bnz     cf_kill                 ; bay already taken

        ldv     V_BAYS
        xs      3                       ; the bit was 0: xor = set
        stv     V_BAYS

        li      SND_BAY
        stv     V_SND
        ; Bay taken. The rest (marking the bay, respawning) is done by
        ; main_loop: respawn cannot be called here, because it would
        ; clear V_OLD* BEFORE erase_frog has removed the toad from the
        ; lane it jumped from, stranding a whole sprite in the river.
        li      3
        stv     V_STATE
        lr      p,k
        pop

; -------------------------------------------------------------------
;  kill_frog - the toad dies: pause, one life less, low tone
; -------------------------------------------------------------------
kill_frog:
        li      1
        stv     V_STATE
        li      DEAD_PAUSE
        stv     V_DEAD
        ldv     V_LIVES
        ci      0
        bz      kf_none
        ai      $FF
        stv     V_LIVES
kf_none:
        li      SND_DEAD
        stv     V_SND
        pop

; -------------------------------------------------------------------
;  dead_tick - run out the post-death pause and decide how it ends.
;
;  It is deliberately a LEAF: it calls nothing, so it never touches K.
;  It clears V_STATE once the pause is over; actually bringing the toad
;  back (erasing it, respawn, redrawing) is main_loop's job, which sits
;  at the right level to do it without nesting two saves of K.
; -------------------------------------------------------------------
dead_tick:
        ldv     V_STATE
        ci      2
        bz      dt_done                 ; game over: stay put
        ldv     V_DEAD
        ai      $FF
        stv     V_DEAD
        ci      0
        bnz     dt_done                 ; pause still running
        clr
        stv     V_SND                   ; silence
        ldv     V_LIVES
        ci      0
        bz      dt_over
        clr
        stv     V_STATE                 ; back into play
        pop
dt_over:
        li      2
        stv     V_STATE                 ; game over
dt_done:
        pop

; -------------------------------------------------------------------
;  respawn - put the toad back at the start and reload the timer
; -------------------------------------------------------------------
respawn:
        li      FROG_X0
        stv     V_FROGX
        stv     V_OLDX
        li      LANE_MAX
        stv     V_FROGL
        stv     V_OLDL
        li      TIMER0
        stv     V_TIMER
        li      TIMER_FRAMES
        stv     V_TTICK
        pop

; -------------------------------------------------------------------
;  sound_tick - program the tone ONCE per frame.
;
;  On the Channel F the sound bits sit in bits 7-6 of the same byte
;  that carries the VRAM row: every pixel write clears them. So the
;  tone is switched on here, at the end of the frame, and lasts for the
;  delay that follows - then the first pixel of the next frame kills
;  it. One state change per frame instead of two hundred.
;  clobbers: A
; -------------------------------------------------------------------
sound_tick:
        ldv     V_SND
        ni      $3F                     ; frames left on the effect
        bz      st_music                ; no effect: play the riff
        ldv     V_SND
        ai      $FF                     ; one frame less
        stv     V_SND
        ni      SND_MASK                ; tone bits only
        br      st_out

; --- background ostinato: one note every MUS_FRAMES frames ---------
st_music:
        ldv     V_MUSTICK
        ai      $FF
        stv     V_MUSTICK
        ci      0
        bnz     st_note                 ; the current note still runs
        li      MUS_FRAMES
        stv     V_MUSTICK
        ldv     V_MUSIDX
        inc
        ci      MUS_LEN
        bnz     st_idx
        clr                             ; end of the riff: start over
st_idx:
        stv     V_MUSIDX
st_note:
        dci     mus_tbl
        ldv     V_MUSIDX
        adc                             ; DC0 += note index
        lm                              ; A = tone bits of the note

st_out:
        IF SOUND_ON == 0
        ; Tones disabled (see the note above): MAME 0.287 crashes as
        ; soon as the tone changes. The sequencer still runs, so it
        ; cannot rot; flipping SOUND_ON = 1 is all it takes.
        clr
        ENDIF
        outs    P_ROW
        pop

; -------------------------------------------------------------------
;  save_old - this frame's position becomes the "previous" one
; -------------------------------------------------------------------
save_old:
        ldv     V_FROGX
        stv     V_OLDX
        ldv     V_FROGL
        stv     V_OLDL
        pop

; -------------------------------------------------------------------
;  tick_timer - burn time and shorten the bar by one column
; -------------------------------------------------------------------
tick_timer:
        lr      k,p
        ldv     V_TTICK
        ai      $FF
        stv     V_TTICK
        ci      0
        bnz     tt_done
        li      TIMER_FRAMES
        stv     V_TTICK
        ldv     V_TIMER
        ci      0
        bz      tt_out
        ai      $FF
        stv     V_TIMER
        lr      2,a                     ; the column that just expired
        li      C_BG
        outs    P_COLOR
        lr      a,2
        ai      ST_TIMER_X
        com
        outs    P_COL
        li      ST_TIMER_Y
        lr      3,a
        pixrow
        pixrow
        ldv     V_TIMER
        ci      0
        bnz     tt_done
tt_out:
        pi      kill_frog               ; time is up
tt_done:
        lr      p,k
        pop

; -------------------------------------------------------------------
;  draw_homes - repaint the home band from scratch: 6-wide blue walls
;               every 18 pixels, hence five 12-wide bays.
;
;  Needed twice: at startup, and on a completed round to wipe the green
;  markers. It repaints EVERY column (background or wall), so there is
;  no need to remember where the markers were. That is 96*5 = 480
;  pixels, beyond a single frame's budget: it is a rare event and costs
;  one visible hitch.
;  It only touches x = PF_X0..PF_X0+PF_W-1, so it never goes near the
;  palette columns (125-126).
; -------------------------------------------------------------------
draw_homes:
        lr      k,p
        clr
        lr      0,a                     ; i = playfield column
        lr      6,a                     ; c = phase within the period
dh_loop:
        li      C_BG
        lr      1,a
        lr      a,6
        lr      5,a
        li      HOME_WALL
        com
        inc                             ; A = -6
        as      5                       ; A = c - 6, C if c >= 6
        bc      dh_col                  ; inside a bay: background
        li      C_BLUE
        lr      1,a                     ; first 6 of the phase: wall
dh_col:
        lr      a,0
        ai      PF_X0
        lr      2,a
        li      LANE_Y0
        lr      3,a
        pi      col5                    ; a 5-tall column = the whole lane
        lr      a,6
        inc
        lr      6,a
        ci      HOME_PERIOD
        bnz     dh_nowrap
        clr
        lr      6,a
dh_nowrap:
        lr      a,0
        inc
        lr      0,a
        ci      PF_W
        bnz     dh_loop
        lr      p,k
        pop

; -------------------------------------------------------------------
;  new_round - all five bays filled: the round is complete.
;              Frees the bays and grants a life, up to the maximum
;              draw_lives can paint. A leaf: the caller is responsible
;              for draw_homes, because that one uses K.
; -------------------------------------------------------------------
new_round:
        clr
        stv     V_BAYS                  ; bays are free again
        ldv     V_LIVES
        ci      LIVES_MAX
        bz      nr_done                 ; already at the cap
        inc
        stv     V_LIVES                 ; one bonus life
nr_done:
        pop

; -------------------------------------------------------------------
;  draw_bay - fill the captured bay with green, at the column where the
;             toad entered. A solid 5x4 block: it also covers the
;             sprite draw_frog has just painted there.
; -------------------------------------------------------------------
draw_bay:
        li      C_GREEN
        outs    P_COLOR
        ldv     V_FROGX
        lr      2,a
        li      FROG_W
        lr      5,a
db_mark:
        lr      a,2
        com
        outs    P_COL
        li      LANE_Y0
        lr      3,a
        pixrow
        pixrow
        pixrow
        pixrow
        lr      a,2
        inc
        lr      2,a
        ds      5
        bnz     db_mark
        pop

; -------------------------------------------------------------------
;  draw_timer_full - repaint the time bar at full length.
;  draw_timer_bar  - the same bar with the colour already in r1: used
;                    to switch it off, and hence to blink it once the
;                    game is over.
; -------------------------------------------------------------------
draw_timer_full:
        li      C_WHITE
        lr      1,a
draw_timer_bar:
        lr      a,1
        outs    P_COLOR
        li      TIMER0
        lr      5,a
        li      ST_TIMER_X
        lr      2,a
tf_loop:
        lr      a,2
        com
        outs    P_COL
        li      ST_TIMER_Y
        lr      3,a
        pixrow
        pixrow
        lr      a,2
        inc
        lr      2,a
        ds      5
        bnz     tf_loop
        pop

; -------------------------------------------------------------------
;  draw_lives - one 3x3 block per life, top right.
;
;  Palette 0 rules the status band (black / white / white / white), so
;  the C_GREEN below comes out WHITE on screen: that is intended.
;
;  It is called every frame but only repaints when the number of lives
;  has changed: that is what V_LIVESHOWN is for. Without it, this would
;  waste ~45 pixels per frame out of a budget of 800.
; -------------------------------------------------------------------
draw_lives:
        ldv     V_LIVESHOWN
        com
        inc                             ; A = -shown
        lr      6,a
        ldv     V_LIVES
        as      6                       ; lives - shown
        bnz     dl_redraw
        pop                             ; unchanged: nothing to do

dl_redraw:
        li      C_BG                    ; clear the area
        outs    P_COLOR
        li      ST_LIVES_X
        lr      2,a
        li      4*LIVES_MAX
        lr      5,a
dl_clear:
        lr      a,2
        com
        outs    P_COL
        li      ST_LIVES_Y
        lr      3,a
        pixrow
        pixrow
        pixrow
        lr      a,2
        inc
        lr      2,a
        ds      5
        bnz     dl_clear

        ldv     V_LIVES
        lr      6,a
        stv     V_LIVESHOWN
        ci      0
        bz      dl_done
        li      C_GREEN
        outs    P_COLOR
        li      ST_LIVES_X
        lr      2,a
dl_life:
        li      3
        lr      5,a
dl_col:
        lr      a,2
        com
        outs    P_COL
        li      ST_LIVES_Y
        lr      3,a
        pixrow
        pixrow
        pixrow
        lr      a,2
        inc
        lr      2,a
        ds      5
        bnz     dl_col
        lr      a,2
        inc
        lr      2,a                     ; gap between two blocks
        ds      6
        bnz     dl_life
dl_done:
        pop

; -------------------------------------------------------------------
;  col5 - a LANE_H-tall column (used for the bay walls)
;         in: r1 colour, r2 x, r3 y   clobbers: A, r3
; -------------------------------------------------------------------
col5:
        lr      a,1
        outs    P_COLOR
        lr      a,2
        com
        outs    P_COL
        pixrow
        pixrow
        pixrow
        pixrow
        pixrow
        pop

; -------------------------------------------------------------------
;  set_row - program P_ROW from row r3 while preserving the sound bits
; -------------------------------------------------------------------
set_row:
        lr      a,3
        com
        ni      ROW_MASK
        outs    P_ROW
        pop

; -------------------------------------------------------------------
;  pulse - VRAM write strobe
; -------------------------------------------------------------------
pulse:
        li      CTRL_WRITE
        outs    P_CTRL
        li      CTRL_IDLE
        outs    P_CTRL
        pop

; -------------------------------------------------------------------
;  delay - frame delay (there is no vblank to sync against)
;          clobbers: A, r0, r5
; -------------------------------------------------------------------
delay:
        li      DELAY_OUTER
        lr      5,a
dly_outer:
        clr
        lr      0,a
dly_inner:
        ds      0
        bnz     dly_inner
        ds      5
        bnz     dly_outer
        pop

; ===================================================================
;  Tables
; ===================================================================

; -------------------------------------------------------------------
;  Bands: height, colour, low palette bit, high palette bit.
;  The heights add up to exactly 64.
; -------------------------------------------------------------------
band_tbl:
        db      4, C_BG, PAL0_LO, PAL0_HI       ; y 0-3   off screen
        db      8, C_BG, PAL0_LO, PAL0_HI       ; y 4-11  status
        db      5, C_BG, PAL3_LO, PAL3_HI       ; y 12-16 home bays
        ; River: here the background is NOT value 0. These rows use
        ; palette 2 (value 0 = light grey, same as asphalt) and are
        ; filled with value 1 = BLUE, which acts as the water. The logs
        ; are then drawn with value 0 and come out GREY.
        ; Reason: this way "grey = you can stand on it" holds across the
        ; whole screen. With pale water and blue logs the convention
        ; flipped halfway up.
        db      5, C_BLUE, PAL2_LO, PAL2_HI     ; y 17-21 river 1
        db      5, C_BLUE, PAL2_LO, PAL2_HI     ; y 22-26 river 2
        db      5, C_BLUE, PAL2_LO, PAL2_HI     ; y 27-31 river 3
        db      5, C_BLUE, PAL2_LO, PAL2_HI     ; y 32-36 river 4
        db      5, C_BG, PAL3_LO, PAL3_HI       ; y 37-41 median strip
        db      5, C_BG, PAL2_LO, PAL2_HI       ; y 42-46 road 1
        db      5, C_BG, PAL2_LO, PAL2_HI       ; y 47-51 road 2
        db      5, C_BG, PAL2_LO, PAL2_HI       ; y 52-56 road 3
        db      5, C_BG, PAL3_LO, PAL3_HI       ; y 57-61 start
        db      2, C_BG, PAL0_LO, PAL0_HI       ; y 62-63 off screen
NUM_BANDS = 13

; -------------------------------------------------------------------
;  Moving lanes: y, mask, width, colour, speed, offset
;
;  mask = period-1, period 16 or 32 (it must divide PF_W = 96).
;  speed: bits 0-3 = RHYTHM MASK (must be 2^n-1: 1,3,7,15),
;  bit 6 = RIDEABLE, bit 7 = moves left.
;  A lane advances 1 px when (frame & mask) == 0, i.e. one frame out of
;  (mask+1). At the measured ~80 loops/s: 3 -> ~20 px/s, 7 -> ~10 px/s,
;  15 -> ~5 px/s.
lane_tbl:
        ; The logs are drawn with value 0 (= grey under palette 2),
        ; because in the river it is the WATER that fills (value 1).
        db      17, 31, 20, C_BG,    7|RIDEABLE,          0  ; river 1 ->
        db      22, 31, 16, C_BG,    3|RIDEABLE|DIR_LEFT, 8  ; river 2 <-
        db      27, 31, 20, C_BG,   15|RIDEABLE,          16 ; river 3 ->
        db      32, 15, 10, C_BG,    7|RIDEABLE|DIR_LEFT, 4  ; river 4 <-
        db      42, 31, 10, C_RED,   7|DIR_LEFT,          12 ; road 1  <-
        db      47, 31,  8, C_RED,  15,                   20 ; road 2  ->
        db      52, 31,  8, C_RED,   3|DIR_LEFT,          0  ; road 3  <-

; -------------------------------------------------------------------
;  The riff: low low high low low mid high low, looping.
;  Only bits 7-6 matter; they go to P_ROW exactly as they are.
; -------------------------------------------------------------------
mus_tbl:
        db      SND_LOW
        db      SND_LOW
        db      SND_HIGH
        db      SND_LOW
        db      SND_LOW
        db      SND_MID
        db      SND_HIGH
        db      SND_LOW

; -------------------------------------------------------------------
;  Toad sprite: 5 columns, bit 0 = top row.
;
;      . # # # .      head
;      # # # # #      squat body
;      # # # # #
;      # . # . #      legs
;
;  16 pixels instead of the 12 of the splayed-legs version: it reads
;  much better in motion and the frame budget takes it easily.
;  The centre column is filled on all four rows, which matters:
;  check_frog decides "run over" and "drowned" by looking at exactly
;  that column.
; -------------------------------------------------------------------
frog_bmp:
        db      %00001110               ; column 0
        db      %00000111               ; column 1
        db      %00001111               ; column 2
        db      %00000111               ; column 3
        db      %00001110               ; column 4

        ; padding out to 2 KiB
        org     CART_BASE + $7FF
        db      $FF
