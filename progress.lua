-- Recompute the project progress from AVANCEMENT.md
--
-- A percentage nobody can check is a percentage nobody should believe. This
-- reads the checklist and does the arithmetic, so the number in a report and
-- the boxes in the file can never drift apart.
--
--   lua progress.lua            summary
--   lua progress.lua --detail   with every unfinished item

local DETAIL = false
for _, arg in ipairs({...}) do
    if arg == "--detail" then DETAIL = true end
end

local file = assert(io.open("AVANCEMENT.md", "r"),
                    "AVANCEMENT.md introuvable: lance depuis la racine du depot")
local text = file:read("*all")
file:close()

local phases, current = {}, nil

for line in text:gmatch("[^\n]*") do
    local title, weight = line:match("^##%s+(.-)%s*%(poids%s+(%d+)%)")
    if title then
        current = {title = title, weight = tonumber(weight),
                   done = 0, total = 0, pending = {}}
        table.insert(phases, current)
    elseif current then
        local mark, label = line:match("^%-%s+%[([ xX])%]%s+(.+)$")
        if mark then
            current.total = current.total + 1
            if mark ~= " " then
                current.done = current.done + 1
            else
                table.insert(current.pending, label)
            end
        end
    end
end

assert(#phases > 0, "aucune phase avec un poids trouvee dans AVANCEMENT.md")

--- Width in characters, not bytes
--- The titles are UTF-8 and %-34s pads by byte count, so every accent shifted
--- the column by one. Continuation bytes are 0x80..0xBF and start no character.
--- @param s string
--- @return number
local function width(s)
    local count = 0
    for index = 1, #s do
        local byte = s:byte(index)
        if byte < 128 or byte > 191 then count = count + 1 end
    end
    return count
end

local earned, available = 0, 0

print("")
for _, phase in ipairs(phases) do
    local ratio = phase.total > 0 and (phase.done / phase.total) or 0
    earned = earned + ratio * phase.weight
    available = available + phase.weight

    local padded = phase.title .. string.rep(" ", math.max(0, 34 - width(phase.title)))

    print(string.format("  %s %2d/%-2d  %3d%%   (poids %d)",
        padded, phase.done, phase.total, math.floor(ratio * 100 + 0.5),
        phase.weight))

    if DETAIL then
        for _, label in ipairs(phase.pending) do
            print("        reste : " .. label)
        end
    end
end

-- A weight total that is not 100 silently rescales every number above
if available ~= 100 then
    print("")
    print(string.format("  ATTENTION: les poids totalisent %d et non 100.", available))
end

print("")
print(string.format("  GLOBAL : %d%%", math.floor(earned / available * 100 + 0.5)))
print("")
