-- find_redstone.lua: find which side the computer must emit redstone on.
--
-- config.mech_user_side is a side of the COMPUTER, not of the Adapter, and a computer case has a
-- facing, so "right" is not a direction you can read off the world. This pulses each side in turn
-- and names it, so you can watch which one reaches the Mechanical User.
--
-- TAKE THE BEEBEE GUN OUT OF THE MECHANICAL USER FIRST.
--
-- A Mechanical User held under power does not act once, it acts over and over. With the gun in
-- it that fires a swarm, and the game stops responding. Empty, it just swings, which is all this
-- test needs to see.
--
-- Usage:
--   find_redstone              -- a short pulse on each side, with a pause to watch
--   find_redstone --hold=0.6   -- longer pulse, if the Mechanical User misses it
--   find_redstone --gap=3      -- longer pause between sides
--   find_redstone --side=right -- one named side only
--
-- Stand where you can see the Mechanical User. The side that makes it swing is the one to put in
-- config.mech_user_side.

local component = require("component")
local sides = require("sides")
local shell = require("shell")

local _, options = shell.parse(...)

-- Short by design. Three seconds of held signal is dozens of activations, not one.
local HOLD = tonumber(options.hold) or 0.3
local GAP = tonumber(options.gap) or 2

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

    -- Named before the pulse, not after: you need to be watching when it happens.
    io.write(string.format("  %-6s ... ", name))
    io.flush()

    local ok = pcall(rs.setOutput, side, 15)
    if not ok then
        print("refused (no such side on this block)")

        return
    end

    os.sleep(HOLD)
    pcall(rs.setOutput, side, 0)
    print("done")

    -- The pause is the point: it separates one side's reaction from the next one's pulse.
    os.sleep(GAP)
end

-- Clear everything first. A previous run that was interrupted can have left a side held high,
-- and a Mechanical User under a stuck signal keeps firing.
for _, name in ipairs(ORDER) do
    if sides[name] then pcall(rs.setOutput, sides[name], 0) end
end

print("find_redstone  version 2026-09-08e")
print()
print("Take the beebee gun OUT of the Mechanical User before running this.")
print("Under a held signal it fires again and again, which will lag the game.")
print()
print(string.format("Pulse %ss, then %ss to watch. Note the side that makes it swing.",
    tostring(HOLD), tostring(GAP)))
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
