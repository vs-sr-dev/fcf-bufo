-- probe.lua - campiona PC0 della 3850 e stampa un istogramma.
--
-- Serve a rispondere a UNA domanda: quando il gioco "si blocca",
-- dove sta girando la CPU? Nessuna deduzione dai pixel.
--
-- Uso:
--   mame channelf -cart rom.bin -autoboot_script tools/probe.lua \
--        -seconds_to_run 8 -window -sound none -nothrottle
--
-- Variabili d'ambiente (opzionali):
--   PROBE_START  frame da cui iniziare a campionare (default 180)
--   PROBE_REGS   se "1", stampa anche i registri dello scratchpad

local START = tonumber(os.getenv("PROBE_START") or "180")
local WANT_REGS = os.getenv("PROBE_REGS") == "1"

local cpu = manager.machine.devices[":maincpu"]
local st = cpu.state
local frames = 0
local hist = {}
local nsamp = 0
local first = true

-- elenca una volta i nomi di stato disponibili, cosi' non tiro a indovinare
local function dump_state_names()
    local names = {}
    for k, _ in pairs(st) do names[#names + 1] = k end
    table.sort(names)
    print("STATE: " .. table.concat(names, " "))
end

local function sample()
    local pc = st["PC0"].value
    hist[pc] = (hist[pc] or 0) + 1
    nsamp = nsamp + 1
end

local function report()
    print(string.format("PROBE: %d campioni su %d frame", nsamp, frames))
    local arr = {}
    for pc, n in pairs(hist) do arr[#arr + 1] = { pc = pc, n = n } end
    table.sort(arr, function(a, b) return a.n > b.n end)
    print("   PC0   campioni   %")
    for i = 1, math.min(#arr, 24) do
        local e = arr[i]
        print(string.format("  $%04X  %8d  %5.1f%%", e.pc, e.n, 100 * e.n / nsamp))
    end
    print(string.format("PROBE: %d PC distinti", #arr))
end

local function tick()
    frames = frames + 1
    if first then
        first = false
        dump_state_names()
    end
    if frames >= START then
        sample()
        if WANT_REGS and frames % 60 == 0 then
            local r = {}
            for i = 0, 13 do
                local ok, v = pcall(function() return st["R" .. i].value end)
                r[#r + 1] = string.format("r%d=%02X", i, ok and v or 0)
            end
            print(string.format("F%d ISAR=%02X %s", frames,
                st["ISAR"] and st["ISAR"].value or 0, table.concat(r, " ")))
        end
    end
end

emu.register_frame_done(tick)
emu.register_stop(report)
