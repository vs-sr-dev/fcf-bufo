-- measure.lua - take snapshots at exact frames, so you can measure what
-- changes over time instead of inferring it from a still.
--
-- Environment variables:
--   MEAS_FRAMES  comma-separated list of video frames
--                (default "240,300": two shots 1 s apart)
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
        print(string.format("MEAS: snapshot at frame %d", n))
    end
    if n > last then
        manager.machine:exit()
    end
end

-- CAREFUL: the subscription has to be kept alive in a global, otherwise
-- Lua's garbage collector frees it, the callbacks never fire, and the
-- emulator just hangs without ever taking a snapshot.
if emu.add_machine_frame_notifier then
    _G.keepalive = emu.add_machine_frame_notifier(tick)
else
    emu.register_frame_done(tick)
end
