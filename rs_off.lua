-- rs_off.lua: drop every redstone output to zero.
--
-- A Mechanical User under a held signal keeps acting, and a program interrupted mid-pulse leaves
-- the signal where it was. This is the fastest way to stop it without breaking the wire.
--
-- Usage: rs_off

local component = require("component")
local sides = require("sides")

if not component.isAvailable("redstone") then
    print("No redstone component on the network - nothing to switch off here.")

    return
end

local rs = component.redstone
local cleared = {}

for _, name in ipairs({"down", "up", "north", "south", "west", "east",
                       "front", "back", "left", "right"}) do
    local side = sides[name]
    if side then
        local was = 0
        pcall(function() was = rs.getOutput(side) or 0 end)
        pcall(rs.setOutput, side, 0)
        if was and was > 0 then cleared[#cleared + 1] = name .. " (was " .. was .. ")" end
    end
end

if #cleared > 0 then
    print("Switched off: " .. table.concat(cleared, ", "))
else
    print("Every side was already at zero.")
end
