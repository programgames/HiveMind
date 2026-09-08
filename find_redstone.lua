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
--   find_redstone --pause      -- wait for a key between sides, so nothing runs away
--
-- Safest of all: watch the redstone dust rather than the Mechanical User. The wire lights up on
-- the right side just the same, and nothing is triggered.
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
local PAUSE = options.pause == true

-- A side can do worse than nothing. If it feeds something that cuts the computer's own power --
-- a redstone-controlled energy conduit, a switch on the supply -- raising it shuts the computer
-- down, and the output stays raised, so it cannot come back. Name such sides here and they are
-- never touched:  find_redstone --skip=south
local SKIP = {}
for name in tostring(options.skip or ""):gmatch("[^,%s]+") do
    SKIP[name:lower()] = true
end

if not component.isAvailable("redstone") then
    print("No redstone component on the network.")
    print("The computer needs a Redstone Card, or a Redstone I/O block must be connected.")

    return
end

local rs = component.redstone
local computer = require("computer")

local ORDER = {"down", "up", "north", "south", "west", "east", "front", "back", "left", "right"}

-- The screen has gone black twice, which in OpenComputers means the computer stopped rather than
-- the program. Nothing survives that on screen, so each step is written to a file and flushed
-- immediately: after a reboot, the last line names the side that was live when it died, and the
-- energy readings say whether it starved.
local LOG = options.log or "/home/rs_log.txt"

local function note(text)
    local f = io.open(LOG, "a")
    if not f then return end

    f:write(text .. "\n")
    f:close()
end

local function energy()
    local ok, stored = pcall(computer.energy)
    local ok2, max = pcall(computer.maxEnergy)
    if not ok or not ok2 then return "energy unreadable" end

    return string.format("energy %.0f/%.0f", stored or 0, max or 0)
end

-- front/back/left/right are the same six faces under another name, resolved through the block's
-- facing. Both sets are listed because config.mech_user_side is written in the relative form.
local function pulse(name)
    local side = sides[name]
    if not side then
        print("'" .. tostring(name) .. "' is not a side")

        return
    end

    if SKIP[name:lower()] then
        note(string.format("skipped  %-6s  (--skip)", name))
        print(string.format("  %-6s skipped", name))

        return true
    end

    -- Named before the pulse, not after: you need to be watching when it happens.
    io.write(string.format("  %-6s ... ", name))
    io.flush()

    note(string.format("about to raise %-6s  %s", name, energy()))

    local ok = pcall(rs.setOutput, side, 15)
    if not ok then
        note("  refused: no such side on this block")
        print("refused (no such side on this block)")

        return
    end

    note(string.format("  raised   %-6s  %s", name, energy()))

    os.sleep(HOLD)
    pcall(rs.setOutput, side, 0)

    note(string.format("  lowered  %-6s  %s", name, energy()))
    print("done")

    if PAUSE then
        io.write("         press a key for the next side, or q to stop... ")
        io.flush()

        local event = require("event")
        local _, _, char = event.pull("key_down")
        print()

        if char == 113 or char == 81 then

            return false
        end

        return true
    end

    -- The pause is the point: it separates one side's reaction from the next one's pulse.
    os.sleep(GAP)

    return true
end

-- Clear everything first. A previous run that was interrupted can have left a side held high,
-- and a Mechanical User under a stuck signal keeps firing.
for _, name in ipairs(ORDER) do
    if sides[name] then pcall(rs.setOutput, sides[name], 0) end
end

-- A fresh log each run, so the last line is always from the run that just died.
local wipe = io.open(LOG, "w")
if wipe then
    wipe:write("find_redstone log\n")
    wipe:close()
end
note("start  " .. energy())

print("find_redstone  version 2026-09-08h")
print("Progress is written to " .. LOG .. " as it goes.")
print("If the screen goes black, reboot and read it: edit " .. LOG)
print()
if next(SKIP) then
    local names = {}
    for name in pairs(SKIP) do names[#names + 1] = name end
    table.sort(names)
    print("Skipping: " .. table.concat(names, ", "))
    print()
end

print("Watch the REDSTONE DUST, not the Mechanical User: the wire lights up just")
print("the same and nothing is triggered. If you would rather watch the machine,")
print("take the beebee gun out first -- under a signal it fires again and again.")
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
        if pulse(name) == false then return end
    end

    print()
    print("Relative sides (these are what config uses):")
    for _, name in ipairs({"front", "back", "left", "right"}) do
        if pulse(name) == false then return end
    end
end

-- Leave nothing energised behind: a side still held high would keep the Mechanical User firing.
for _, name in ipairs(ORDER) do
    if sides[name] then pcall(rs.setOutput, sides[name], 0) end
end

note("finished cleanly  " .. energy())

print()
print("All outputs back to zero.")
print("Log: " .. LOG)
