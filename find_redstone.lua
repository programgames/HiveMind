-- find_redstone.lua: find which side the computer must emit redstone on.
--
-- config.mech_user_side is a side of the COMPUTER, not of the Adapter, and a computer case has a
-- facing, so "right" is not a direction you can read off the world. This pulses each side in turn
-- and names it, so you can watch which one reaches the Mechanical User.
--
-- Usage:
--   find_redstone              -- 3 seconds on each of the six sides
--   find_redstone --hold=5     -- longer, if the Mechanical User is slow to react
--   find_redstone --side=right -- pulse one named side only
--
-- Stand where you can see the Mechanical User. The side that makes it swing is the one to put in
-- config.mech_user_side.

local component = require("component")
local sides = require("sides")
local shell = require("shell")

local _, options = shell.parse(...)

local HOLD = tonumber(options.hold) or 3

if not component.isAvailable("redstone") then
    print("No redstone component on the network.")
    print("The computer needs a Redstone Card, or a Redstone I/O block must be connected.")

    return
end

local rs = component.redstone

local ORDER = {"down", "up", "north", "south", "west", "east", "front", "back", "left", "right"}

-- front/back/left/right are the same six faces under another name, resolved through the block's
-- facing. Both sets are listed because config.mech_user_side is written in the relative form.
local function pulse(name)
    local side = sides[name]
    if not side then
        print("'" .. tostring(name) .. "' is not a side")

        return
    end

    io.write(string.format("  %-6s -> ON  ", name))
    io.flush()

    local ok = pcall(rs.setOutput, side, 15)
    if not ok then
        print("refused (no such side on this block)")

        return
    end

    os.sleep(HOLD)
    pcall(rs.setOutput, side, 0)
    print("off")
end

print("find_redstone  version 2026-09-08c")
print("Pulsing each side for " .. HOLD .. "s. Watch the Mechanical User.")
print("Note the name that makes it swing, then put it in config.mech_user_side.")
print()

if options.side then
    pulse(options.side)
else
    -- The absolute names first: they are unambiguous, and tell you the geometry. The relative
    -- ones repeat some of the same faces, which is the point -- config uses relative names.
    print("Absolute sides:")
    for _, name in ipairs({"down", "up", "north", "south", "west", "east"}) do
        pulse(name)
    end

    print()
    print("Relative sides (these are what config uses):")
    for _, name in ipairs({"front", "back", "left", "right"}) do
        pulse(name)
    end
end

-- Leave nothing energised behind: a side still held high would keep the Mechanical User firing.
for _, name in ipairs(ORDER) do
    if sides[name] then pcall(rs.setOutput, sides[name], 0) end
end

print()
print("All outputs back to zero.")
