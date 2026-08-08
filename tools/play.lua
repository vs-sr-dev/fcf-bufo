-- play.lua - pilota il controller da script, per provare le regole di
-- gioco (investimento, annegamento, tronchi, tane) senza mani.
--
-- Senza questo si possono verificare solo le cose che accadono da sole:
-- il tempo che scade. Tutto il resto richiede input.
--
-- Variabili d'ambiente:
--   PLAY_LIST   "frame:tasto,frame:tasto,..."  es. "120:UP,180:UP"
--               tasti: UP DOWN LEFT RIGHT
--   PLAY_SHOTS  frame in cui scattare uno snapshot, separati da virgola
--   PLAY_DUMP   se "1", elenca le porte di input e termina
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
        print("PORTA " .. pname)
        for fname, _ in pairs(port.fields) do
            print("   campo: " .. fname)
        end
    end
    manager.machine:exit()
    return
end

-- Il gioco legge il controller DESTRO (porta 1 = P_JOY_R), che in MAME
-- e' ":RIGHT_C". Nomi esatti: cercare per sottostringa pescherebbe i
-- campi del P2, o "P1 Pull Up" al posto di "P1 Up".
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
    -- il gioco reagisce al FRONTE di salita: tieni premuto qualche frame
    -- e poi rilascia, altrimenti il tasto non viene mai visto rilasciato
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
            print("PLAY: campo non trovato per " .. key)
        end
    end
    if shots[n] then
        manager.machine.video:snapshot()
        print(string.format("PLAY: scatto al frame %d", n))
    end
    if n > last + 30 then manager.machine:exit() end
end

FIELDS.UP = findfield("P1 Up")
FIELDS.DOWN = findfield("P1 Down")
FIELDS.LEFT = findfield("P1 Left")
FIELDS.RIGHT = findfield("P1 Right")

-- START sta sui pulsanti frontali della console, non sul controller
local PANEL = ioport.ports[":PANEL"]
FIELDS.START = PANEL and PANEL.fields["START (Button 4)"] or nil
for k, v in pairs(FIELDS) do
    print(string.format("PLAY: %s -> %s", k, v and "ok" or "MANCANTE"))
end

_G.keepalive = emu.add_machine_frame_notifier(tick)
