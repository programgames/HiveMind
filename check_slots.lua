-- check_slots.lua: read-only verification of slot indices and driver availability.
--
-- Answers one question that blocks the Gendustry driver migration: the drivers from
-- The-Apiarist-Terminal report raw tile slot indices (0-based), while OpenComputers'
-- inventory_controller is 1-based. This script determines the offset empirically by
-- correlating what the driver reports against what the inventory controller sees.
--
-- It writes nothing, moves nothing and starts nothing. Safe on a running setup.
--
-- Usage:
--   check_slots                    -- uses the sides from main.lua's config
--   check_slots --apiary=back --mutatron=front
--   check_slots --brief            -- only what is needed to set the config
--   check_slots --upload           -- put the report online and print one short link
--   check_slots --out=/home/slots.txt
--
-- The console scrolls faster than it can be read, so the full report is meant to be sent
-- somewhere rather than watched. --upload posts it to paste.rs and prints the link.
--
-- OpenOS ships `pastebin put`, but it no longer works: the API key baked into OpenOS 1.8.7 is
-- dead upstream and pastebin.com answers 422 to every anonymous upload.

local component = require("component")
local sides = require("sides")
local shell = require("shell")

local _, options = shell.parse(...)

-- Sides default to main.lua's config table so the report describes the real setup.
local APIARY_SIDE = sides[options.apiary or "back"]
local MUTATRON_SIDE = sides[options.mutatron or "front"]
local OUT_PATH = options.out

-- What main.lua believes today, so the report can say whether it is right.
local CONFIG_UNDER_TEST = {
    mutatron_input_slots = {1, 2},
    mutatron_output_slot = 3,
    apiary_input_slot = 1,
    apiary_output_slots = {2, 3, 4, 5, 6},
}

local BRIEF = options.brief == true
local UPLOAD = options.upload == true
-- Uploading and watching the console at once is pointless: the link is the readable copy.
local QUIET = options.quiet == true or UPLOAD

local out = OUT_PATH and io.open(OUT_PATH, "w") or nil

-- Every line is kept, whatever the output goes to, so the upload can send the whole report.
local lines = {}

local function w(line)
    line = line or ""
    lines[#lines + 1] = line

    if not QUIET then print(line) end
    if out then out:write(line .. "\n") end
end

--- Put the report online and return a link to it
---
--- paste.rs takes a raw body and answers with the URL, which is the least a script needs. The
--- computer needs an Internet Card; without one this says so rather than failing silently.
--- @param text string The whole report
--- @return string|nil url The link, or nil
--- @return string|nil reason Why it could not be uploaded
local function upload(text)
    if not component.isAvailable("internet") then

        return nil, "no Internet Card in this computer"
    end

    local ok, internet = pcall(require, "internet")
    if not ok then

        return nil, "the internet library is not available"
    end

    local body = nil
    local sent, err = pcall(function()
        local handle = internet.request("https://paste.rs", text,
            {["Content-Type"] = "text/plain"})

        body = ""
        for chunk in handle do
            body = body .. chunk
        end
    end)

    if not sent then

        return nil, tostring(err)
    end
    if not body or body == "" then

        return nil, "the paste service answered nothing"
    end

    return (body:gsub("%s+$", ""))
end

-- Addresses rather than component.<name>: OpenOS caches a proxy per address in a Lua
-- state that survives a world reload, so a proxy built before a mod update keeps
-- answering with the old method list.
local function addressOf(kind)
    return component.list(kind, true)()
end

local function call(address, method, ...)
    if not address then return nil, "component not present" end

    local r = table.pack(pcall(component.invoke, address, method, ...))
    if r[1] then return table.unpack(r, 2, r.n) end

    return nil, tostring(r[2])
end

local function describe(stack)
    if not stack then return nil end

    return string.format("%s x%s", tostring(stack.label or stack.name or "?"),
        tostring(stack.size or stack.count or "?"))
end

local function sortedKeys(t)
    local keys = {}
    for k in pairs(t) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)

    return keys
end

-- 1. What is on the network -------------------------------------------------
-- Printed first, so a report can be told apart from one produced by an older copy. GitHub serves
-- raw files through a cache for a few minutes, so a download right after a push can silently
-- hand back the previous version.
local VERSION = "2026-09-08c  side auto-detect"

w("HIVEMIND -- SLOT INDEX VERIFICATION (read-only)")
w("script version: " .. VERSION)
w(string.rep("=", 72))
w()

local WANTED = {
    advmutatron = "Advanced Mutatron (hand-written driver)",
    industrial_apiary = "Industrial Apiary (hand-written driver)",
    inventory_controller = "Inventory Controller upgrade",
    genetic_sampler = "Genetic Sampler",
    genetic_imprinter = "Genetic Imprinter",
    genetic_transposer = "Genetic Transposer",
    mutagen_producer = "Mutagen Producer",
}

w("Components present:")
local seen = {}
for address, kind in component.list() do
    seen[kind] = (seen[kind] or 0) + 1
end
for _, kind in ipairs(sortedKeys(WANTED)) do
    w(string.format("  %-22s %s  %s", kind, seen[kind] and ("x" .. seen[kind]) or "MISSING",
        WANTED[kind]))
end
w()

local adv = addressOf("advmutatron")
local apiary = addressOf("industrial_apiary")

local inv = nil
if component.isAvailable("inventory_controller") then
    inv = component.inventory_controller
else
    w("!! No inventory_controller: the offset cannot be determined. Add the upgrade.")
end

-- 2. What sits on each of the six sides -------------------------------------
--
-- An Adapter has no visible facing, so there is no way to tell by eye which side the program
-- calls "front". This reads all six and names what it finds, which is what the config needs.
w(string.rep("-", 72))
w("SIDES -- as seen from the block holding the inventory controller")
w(string.rep("-", 72))

local ALL_SIDES = {sides.bottom, sides.top, sides.back, sides.front, sides.right, sides.left}

local SIDE_NAMES = {
    [sides.bottom] = "bottom (down)",
    [sides.top]    = "top (up)",
    [sides.back]   = "back",
    [sides.front]  = "front",
    [sides.right]  = "right",
    [sides.left]   = "left",
}

-- A machine reached through an Adapter answers listSlots; a chest does not. Comparing the
-- inventory size on a side with the size the driver reports is what identifies the machine.
local machineSizes = {}
if adv then
    local sl = call(adv, "listSlots")
    if type(sl) == "table" then machineSizes.advmutatron = sl.size end
end
if apiary then
    local sl = call(apiary, "listSlots")
    if type(sl) == "table" then machineSizes.industrial_apiary = sl.size end
end

local sideReport = {}
if inv then
    for _, side in ipairs(ALL_SIDES) do
        local size = inv.getInventorySize(side)
        local guess = ""

        if size then
            local names = {}
            for slot = 1, math.min(size, 12) do
                local stack = inv.getStackInSlot(side, slot)
                if stack then
                    names[#names + 1] = describe(stack)
                end
                if #names >= 3 then break end
            end

            for kind, msize in pairs(machineSizes) do
                if msize == size then guess = guess .. "  <-- likely the " .. kind end
            end

            w(string.format("  %-14s %3d slots%s", SIDE_NAMES[side] or tostring(side), size, guess))
            if #names > 0 then
                w("                 holding: " .. table.concat(names, ", "))
            end

            sideReport[side] = {size = size, guess = guess}
        else
            w(string.format("  %-14s nothing readable (no inventory on that side)",
                SIDE_NAMES[side] or tostring(side)))
        end
    end
else
    w("  no inventory_controller, cannot read any side")
end

w()
w("  These six answers decide the config lines:")
w("    mutatron_side       -- the side whose slot count matches the Advanced Mutatron")
w("    apiary_side         -- the side whose slot count matches the Industrial Apiary")
w("    input_chest_side    -- the chest holding princesses, drones and labware")
w("    output_chest_side   -- the chest that receives the products")
w("    mech_user_side      -- the Mechanical User (redstone, and its own inventory)")
w()

-- 3. The offset test --------------------------------------------------------
--
-- The driver names a slot and says what is in it. The inventory controller reads the
-- same physical inventory under its own indexing. If driver slot s and controller
-- slot s+k hold the same item for every occupied slot, k is the offset.
local function detectOffset(address, side, label, silent)
    local say = silent and function() end or w

    say(string.rep("-", 72))
    say("OFFSET TEST -- " .. label)
    say(string.rep("-", 72))

    if not address then
        say("  driver absent, skipping")
        say()

        return nil
    end
    if not inv then
        say("  no inventory_controller, skipping")
        say()

        return nil
    end
    if not side then
        say("  no side identified for this machine, skipping")
        say()

        return nil
    end

    local size = inv.getInventorySize(side)
    if not size then
        say(string.format("  nothing readable on side %d -- wrong side?", side))
        say()

        return nil
    end

    local driverSlots = call(address, "listSlots")
    if type(driverSlots) ~= "table" then
        say("  listSlots() did not answer a table -- is the Adapter still touching it?")
        say()

        return nil
    end

    say(string.format("  inventory_controller reports %d slots", size))
    say(string.format("  driver listSlots().size = %s", tostring(driverSlots.size)))
    if driverSlots.size and driverSlots.size ~= size then
        say("  !! sizes disagree: the two are not looking at the same inventory")
    end
    say()

    -- Occupied slots as the controller sees them.
    local controllerItems = {}
    for slot = 1, size do
        local stack = inv.getStackInSlot(side, slot)
        if stack then controllerItems[slot] = stack end
    end

    -- Occupied slots as the driver sees them. listOutputs covers the product slots;
    -- getBees / getOutput cover the input side. Both report an index we can correlate.
    local driverItems = {}

    local outputs = call(address, "listOutputs")
    if type(outputs) == "table" then
        for _, item in pairs(outputs) do
            if type(item) == "table" and item.slot then driverItems[item.slot] = item end
        end
    end

    local upgrades = call(address, "listUpgrades")
    if type(upgrades) == "table" then
        for _, item in pairs(upgrades) do
            if type(item) == "table" and item.slot then driverItems[item.slot] = item end
        end
    end

    -- The mutatron has no listOutputs; getOutput plus listSlots.output gives one pair.
    local product = call(address, "getOutput")
    if type(product) == "table" and driverSlots.output then
        driverItems[driverSlots.output] = product
    end

    if next(driverItems) == nil then
        say("  the driver reports no occupied slot, so there is nothing to correlate.")
        say("  Load the machine (a bee in the apiary, or a product in the mutatron)")
        say("  and run this again -- the test needs at least one item to line up.")
        say()

        return nil
    end

    local function matches(a, b)
        if not a or not b then return false end

        local an = tostring(a.name or "")
        local bn = tostring(b.name or "")
        if an ~= "" and an == bn then return true end

        return tostring(a.label or "") == tostring(b.label or "")
    end

    local verdict = nil
    for _, k in ipairs({0, 1, -1}) do
        local agree, total = 0, 0
        for slot, item in pairs(driverItems) do
            total = total + 1
            if matches(item, controllerItems[slot + k]) then agree = agree + 1 end
        end

        say(string.format("  offset %+d: %d/%d driver slots line up", k, agree, total))
        if total > 0 and agree == total and not verdict then verdict = k end
    end
    say()

    if verdict then
        say(string.format("  ==> OFFSET = %+d", verdict))
        say(string.format("      controller_slot = driver_slot %+d", verdict))
    else
        say("  ==> INCONCLUSIVE. Load more slots and run again, or the two components")
        say("      are not addressing the same inventory.")
    end
    say()

    -- The named slots, translated both ways, so the config can be written by hand.
    say("  Named slots (driver index -> controller index):")
    for _, key in ipairs(sortedKeys(driverSlots)) do
        local value = driverSlots[key]
        if type(value) == "number" and key ~= "size" then
            local translated = verdict and tostring(value + verdict) or "?"
            say(string.format("    %-14s %3d -> %s   %s", key, value, translated,
                describe(verdict and controllerItems[value + verdict]) or ""))
        elseif type(value) == "table" then
            local parts = {}
            for _, v in pairs(value) do
                parts[#parts + 1] = verdict and tostring(v + verdict) or ("?" .. tostring(v))
            end
            table.sort(parts, function(a, b) return (tonumber(a) or 0) < (tonumber(b) or 0) end)
            say(string.format("    %-14s -> {%s}", key, table.concat(parts, ",")))
        end
    end
    say()

    return verdict, driverSlots
end


--- Pick the side a machine is really on
---
--- The size of an inventory is a weak clue: a computer case answers ten slots, exactly like the
--- Advanced Mutatron. So when several sides share the size, each is probed in silence and the one
--- that actually lines up wins. An explicit --apiary= or --mutatron= always overrides this.
--- @return number|nil side The chosen side
--- @return number count How many sides shared that size
local function chooseSide(address, label, override, driverSize)
    if override then

        return override, 1
    end
    if not inv or not address or not driverSize then

        return nil, 0
    end

    local candidates = {}
    for _, side in ipairs(ALL_SIDES) do
        if inv.getInventorySize(side) == driverSize then
            candidates[#candidates + 1] = side
        end
    end

    if #candidates == 0 then

        return nil, 0
    end
    if #candidates == 1 then

        return candidates[1], 1
    end

    for _, side in ipairs(candidates) do
        if detectOffset(address, side, label, true) then

            return side, #candidates
        end
    end

    return candidates[1], #candidates
end

local function driverSize(address)
    local sl = call(address, "listSlots")
    if type(sl) == "table" then return sl.size end

    return nil
end

local apiarySide, apiaryShared = chooseSide(apiary, "INDUSTRIAL APIARY",
    options.apiary and APIARY_SIDE or nil, driverSize(apiary))
local advSide, advShared = chooseSide(adv, "ADVANCED MUTATRON",
    options.mutatron and MUTATRON_SIDE or nil, driverSize(adv))

local function announce(label, side, shared)
    if not side then
        w(string.format("  %s: no side of this block has the right slot count", label))

        return
    end

    w(string.format("  %s is on the %s side%s", label, SIDE_NAMES[side] or tostring(side),
        shared > 1 and string.format("  (%d sides shared that slot count)", shared) or ""))
end

w(string.rep("-", 72))
w("SIDES CHOSEN FOR THE OFFSET TEST")
w(string.rep("-", 72))
announce("Industrial Apiary", apiarySide, apiaryShared or 0)
announce("Advanced Mutatron", advSide, advShared or 0)
w()

local apiaryOffset, apiarySlots = detectOffset(apiary, apiarySide, "INDUSTRIAL APIARY")
local advOffset, advSlots = detectOffset(adv, advSide, "ADVANCED MUTATRON")

-- 4. Verdict on the config currently in main.lua -----------------------------
w(string.rep("=", 72))
w("VERDICT ON main.lua CONFIG")
w(string.rep("=", 72))

local function verdictOn(name, current, expected)
    if expected == nil then
        w(string.format("  %-24s %-18s (undetermined)", name, tostring(current)))

        return
    end

    local ok = tostring(current) == tostring(expected)
    w(string.format("  %-24s current=%-14s expected=%-14s %s", name, tostring(current),
        tostring(expected), ok and "OK" or "<-- WRONG"))
end

local function joined(t)
    if type(t) ~= "table" then return tostring(t) end

    local parts = {}
    for _, v in pairs(t) do parts[#parts + 1] = tostring(v) end
    table.sort(parts, function(a, b) return (tonumber(a) or 0) < (tonumber(b) or 0) end)

    return "{" .. table.concat(parts, ",") .. "}"
end

if apiarySlots and apiaryOffset then
    verdictOn("apiary_input_slot", CONFIG_UNDER_TEST.apiary_input_slot,
        apiarySlots.queen + apiaryOffset)

    local expected = {}
    if type(apiarySlots.outputs) == "table" then
        for _, v in pairs(apiarySlots.outputs) do expected[#expected + 1] = v + apiaryOffset end
    end
    verdictOn("apiary_output_slots", joined(CONFIG_UNDER_TEST.apiary_output_slots),
        joined(expected))
else
    w("  apiary: undetermined")
end

if advSlots and advOffset then
    verdictOn("mutatron_input_slots", joined(CONFIG_UNDER_TEST.mutatron_input_slots),
        joined({advSlots.in1 + advOffset, advSlots.in2 + advOffset}))
    verdictOn("mutatron_output_slot", CONFIG_UNDER_TEST.mutatron_output_slot,
        advSlots.output + advOffset)
    w(string.format("  %-24s (absent from main.lua)  expected=%s", "labware slot",
        tostring(advSlots.labware + advOffset)))
else
    w("  mutatron: undetermined")
end
w()

-- 5. State the migration depends on -----------------------------------------
-- Skipped by --brief: setting the config needs the sides and the offset, not the hive state.
if not BRIEF then
w(string.rep("=", 72))
w("STATE READOUT")
w(string.rep("=", 72))

if apiary then
    w("Industrial Apiary:")

    local status = call(apiary, "getPrincessStatus")
    if type(status) == "table" then
        w(string.format("  princess status: occupied=%s type=%s freed=%s automated=%s%s",
            tostring(status.occupied), tostring(status.type), tostring(status.freed),
            tostring(status.automated), status.error and (" error=" .. tostring(status.error)) or ""))

        if status.automated then
            w("  !! Automation upgrade detected: the queen slot empties by itself, so")
            w("     'freed' no longer means a cycle ended. Remove it -- HiveMind needs")
            w("     to reclaim the princess between cycles.")
        end
    end

    local errors = call(apiary, "getErrors")
    if type(errors) == "table" then
        w(string.format("  errors: hasErrors=%s", tostring(errors.hasErrors)))
        if type(errors.errors) == "table" then
            for _, e in pairs(errors.errors) do w("    - " .. tostring(e)) end
        end
    end

    local env = call(apiary, "getEnvironment")
    if type(env) == "table" then
        w(string.format("  environment: temperature=%s humidity=%s",
            tostring(env.temperature), tostring(env.humidity)))
    end

    local mods = call(apiary, "getModifiers")
    if type(mods) == "table" then
        local parts = {}
        for _, key in ipairs(sortedKeys(mods)) do
            parts[#parts + 1] = string.format("%s=%s", key, tostring(mods[key]))
        end
        w("  modifiers: " .. table.concat(parts, " "))
    end

    local upgrades = call(apiary, "listUpgrades")
    if type(upgrades) == "table" then
        local n = 0
        for _, u in pairs(upgrades) do
            n = n + 1
            w(string.format("  upgrade slot %s: %s", tostring(u.slot),
                tostring(u.label or u.name)))
        end
        if n == 0 then w("  upgrades: none") end
    end

    w(string.format("  isWorking=%s progress=%s", tostring(call(apiary, "isWorking")),
        tostring(call(apiary, "getProgress"))))

    -- requireAnalyzedBees is off on this server, so this should answer.
    local genome = call(apiary, "getGenome", "queen")
    if type(genome) == "table" and type(genome.chromosomes) == "table" then
        local species = genome.chromosomes.species
        if species then
            w(string.format("  queen species: %s (active) / %s (inactive) pure=%s",
                tostring(species.active and species.active.name),
                tostring(species.inactive and species.inactive.name),
                tostring(species.pure)))
        end
    else
        w("  getGenome('queen'): no bee in the slot, or refused")
    end
    w()
end

if adv then
    w("Advanced Mutatron:")

    local tank = call(adv, "getTank")
    if type(tank) == "table" then
        w(string.format("  mutagen: %s/%s %s", tostring(tank.amount), tostring(tank.capacity),
            tostring(tank.fluid or "")))
    end

    local energy = call(adv, "getEnergy")
    if type(energy) == "table" then
        w(string.format("  energy: %s/%s", tostring(energy.stored), tostring(energy.capacity)))
    end

    w(string.format("  isWorking=%s progress=%s canStart=%s",
        tostring(call(adv, "isWorking")), tostring(call(adv, "getProgress")),
        tostring(call(adv, "canStart"))))

    -- Only meaningful with both parents loaded; empty is a valid answer.
    local mutations = call(adv, "listMutations")
    if type(mutations) == "table" then
        local n = 0
        for index, m in pairs(mutations) do
            n = n + 1
            w(string.format("  mutation %s: key=%s %s", tostring(index), tostring(m.key),
                tostring(m.label or m.name)))
        end
        if n == 0 then
            w("  listMutations: empty (load two parents to see the offered crosses)")
        end
    end
    w()
end

end  -- not BRIEF

w(string.rep("=", 72))
w("Report these lines back:")
w("  - the two OFFSET verdicts")
w("  - the VERDICT ON main.lua CONFIG block")
w("  - the 'automated' flag on the apiary")
w(string.rep("=", 72))

if out then
    out:close()
    print("written to " .. OUT_PATH)
end

if UPLOAD then
    print("Uploading the report...")

    local url, reason = upload(table.concat(lines, "\n"))
    if url then
        print()
        print("  " .. url)
        print()
        print("Send that link. Add .txt to it to read it in a browser.")
    else
        print("Upload failed: " .. tostring(reason))
        print("Fall back to:  check_slots --out=/home/rapport.txt")
        print("then read it with:  edit /home/rapport.txt")
    end
end
