-- measure.lua - snapshot a istanti precisi, per misurare cosa cambia nel
-- tempo invece di dedurlo da un fermo immagine.
--
-- Variabili d'ambiente:
--   MEAS_FRAMES  elenco di frame video separati da virgola
--                (default "240,300": due scatti a 1 s di distanza)
local list = os.getenv("MEAS_FRAMES") or "240,300"
local want, last = {}, 0
for f in list:gmatch("%d+") do
    local n = tonumber(f)
    want[n] = true
    if n > last then last = n end
end

local n = 0

local function tick()
    n = n + 1
    if want[n] then
        manager.machine.video:snapshot()
        print(string.format("MEAS: scatto al frame %d", n))
    end
    if n > last then
        manager.machine:exit()
    end
end

-- ATTENZIONE: la sottoscrizione va tenuta viva in una variabile globale,
-- altrimenti il garbage collector di Lua la libera, i callback non
-- arrivano mai e l'emulatore resta appeso senza scattare niente.
if emu.add_machine_frame_notifier then
    _G.keepalive = emu.add_machine_frame_notifier(tick)
else
    emu.register_frame_done(tick)
end
