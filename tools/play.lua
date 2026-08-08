-- play.lua - drive the controller from a script, to exercise the game
-- rules (getting run over, drowning, riding logs, home bays) hands-free.
--
-- Without this you can only verify what happens on its own: the timer
-- running out. Everything else needs input.
--
-- Environment variables:
--   PLAY_LIST   "frame:key,frame:key,..."  e.g. "120:UP,180:UP"
--               keys: UP DOWN LEFT RIGHT START
--   PLAY_SHOTS  comma-separated frames at which to take a snapshot
--   PLAY_DUMP   if "1", list the input ports and quit
local script = {}
for f, k in (os.getenv("PLAY_LIST") or ""):gmatch("(%d+):(%u+)") do
    script[tonumber(f)] = k
end
local shots, last = {}, 0
for f in (os.getenv("PLAY_SHOTS") or ""):gmatch("%d+") do
    shots[tonumber(f)] = true
    if tonumber(f) > last then last = tonumber(f) end
end
for f, _ in pairs(script) do if f > last then last = f end end

local ioport = manager.machine.ioport

if os.getenv("PLAY_DUMP") == "1" then
    for pname, port in pairs(ioport.ports) do
        print("PORT " .. pname)
        for fname, _ in pairs(port.fields) do
            print("   field: " .. fname)
        end
    end
    manager.machine:exit()
    return
end

-- The game reads the RIGHT controller (port 1 = P_JOY_R), which MAME
-- calls ":RIGHT_C". Exact names only: a substring search would pick up
-- the P2 fields, or "P1 Pull Up" instead of "P1 Up".
local RIGHT = ioport.ports[":RIGHT_C"]
local FIELDS = {}
local function findfield(name)
    return RIGHT and RIGHT.fields[name] or nil
end

local n = 0
local held = nil
local heldfor = 0

local function tick()
    n = n + 1
    -- the game reacts to the RISING EDGE: hold for a few frames and then
    -- release, otherwise the key is never seen going back up
    if held then
        heldfor = heldfor - 1
        if heldfor <= 0 then
            held.field:set_value(0)
            held = nil
        end
    end
    local key = script[n]
    if key and not held then
        local f = FIELDS[key]
        if f then
            f:set_value(1)
            held = { field = f }
            heldfor = 8
            print(string.format("PLAY: frame %d -> %s", n, key))
        else
            print("PLAY: no field found for " .. key)
        end
    end
    if shots[n] then
        manager.machine.video:snapshot()
        print(string.format("PLAY: snapshot at frame %d", n))
    end
    if n > last + 30 then manager.machine:exit() end
end

FIELDS.UP = findfield("P1 Up")
FIELDS.DOWN = findfield("P1 Down")
FIELDS.LEFT = findfield("P1 Left")
FIELDS.RIGHT = findfield("P1 Right")

-- START is on the console front panel, not on the controller
local PANEL = ioport.ports[":PANEL"]
FIELDS.START = PANEL and PANEL.fields["START (Button 4)"] or nil
for k, v in pairs(FIELDS) do
    print(string.format("PLAY: %s -> %s", k, v and "ok" or "MISSING"))
end

-- kept in a global on purpose: see the note in measure.lua
_G.keepalive = emu.add_machine_frame_notifier(tick)
