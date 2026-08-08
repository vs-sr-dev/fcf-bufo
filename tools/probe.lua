-- probe.lua - sample the 3850's PC0 and print a histogram.
--
-- It answers ONE question: when the game "hangs", where is the CPU
-- actually running? No inferring it from the pixels.
--
-- Usage:
--   mame channelf -cart rom.bin -autoboot_script tools/probe.lua \
--        -seconds_to_run 8 -window -sound none -nothrottle
--
-- Environment variables (optional):
--   PROBE_START  frame to start sampling from (default 180)
--   PROBE_REGS   if "1", also dump the scratchpad registers

local START = tonumber(os.getenv("PROBE_START") or "180")
local WANT_REGS = os.getenv("PROBE_REGS") == "1"

local cpu = manager.machine.devices[":maincpu"]
local st = cpu.state
local frames = 0
local hist = {}
local nsamp = 0
local first = true

-- list the available state names once, so nothing has to be guessed
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
    print(string.format("PROBE: %d samples over %d frames", nsamp, frames))
    local arr = {}
    for pc, n in pairs(hist) do arr[#arr + 1] = { pc = pc, n = n } end
    table.sort(arr, function(a, b) return a.n > b.n end)
    print("   PC0    samples   %")
    for i = 1, math.min(#arr, 24) do
        local e = arr[i]
        print(string.format("  $%04X  %8d  %5.1f%%", e.pc, e.n, 100 * e.n / nsamp))
    end
    print(string.format("PROBE: %d distinct PCs", #arr))
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
