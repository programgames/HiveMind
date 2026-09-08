-- test_ingame.lua: run the execution path against a simulated Minecraft.
--
-- test_planning.lua covers how a breeding path is calculated. Nothing covered what happens when
-- the program actually drives the machines, which is why every fault on that path -- main() never
-- called, control_state out of scope, a harvest reading the upgrade slots -- survived to be found
-- in game, one reboot at a time.
--
-- This stands in a whole world: two chests, an Advanced Mutatron and an Industrial Apiary behind
-- the Gendustry drivers, a redstone card wired to a Mechanical User, and the signals the machines
-- raise when they finish. The machines answer like the real ones: the mutatron only produces once
-- both parents, the labware and the mutagen are there, the apiary only frees its queen slot once
-- the beebee gun has fired.
--
-- Usage: lua test_ingame.lua

-- Unbuffered, so a run that hangs still shows how far it got.
io.stdout:setvbuf("no")

local world = {}

----------------------------------------------------------------------------------------------
-- The world
----------------------------------------------------------------------------------------------

local SIDES = {
    bottom = 0, down = 0, top = 1, up = 1,
    back = 2, north = 2, front = 3, south = 3,
    right = 4, west = 4, left = 5, east = 5,
}

-- Inventories are 1-based, the way OpenComputers' inventory controller numbers them.
local function chest(size, contents)
    local inv = {size = size, slots = {}}
    for slot, stack in pairs(contents or {}) do
        inv.slots[slot] = stack
    end

    return inv
end

local function stack(name, label, count)
    return {name = name, label = label, size = count or 1, count = count or 1}
end

world.log = {}
local function record(fmt, ...)
    local line = string.format(fmt, ...)
    world.log[#world.log + 1] = line
end

-- side -> inventory. The Adapter sits at the centre; these are its faces.
world.inventories = {
    [SIDES.back]  = chest(27, {                                   -- input chest
        [1] = stack("forestry:bee_princess_ge", "Meadows Princess"),
        [2] = stack("forestry:bee_drone_ge", "Forest Drone"),
        [3] = stack("gendustry:labware", "Genetics Labware", 64),
    }),
    [SIDES.down]  = chest(27, {}),                                -- output chest
    [SIDES.right] = chest(10, {}),                                -- Advanced Mutatron
    [SIDES.left]  = chest(15, {                                   -- Industrial Apiary
        [3] = stack("gendustry:apiary_upgrade", "Light Upgrade"),
        [4] = stack("gendustry:apiary_upgrade", "Open Sky Upgrade"),
    }),
}

world.mutatron = {
    side = SIDES.right,
    mutagen = 10000,
    selected = nil,
    working = false,
    -- Driver slot indices are 0-based; the controller numbers the same slots from 1.
    slots = {in1 = 0, in2 = 1, output = 2, labware = 3, selectors = {4, 5, 6, 7, 8, 9}, size = 10},
}

world.apiary = {
    side = SIDES.left,
    slots = {queen = 0, drone = 1, bees = {0, 1}, upgrades = {2, 3, 4, 5},
             outputs = {6, 7, 8, 9, 10, 11, 12, 13, 14}, size = 15},
    redstone_mode = "ALWAYS",
    mated = false,
    shot = false,
}

world.signals = {}
local function raise(name, ...)
    world.signals[#world.signals + 1] = {name, ...}
    record("signal raised: %s", name)
end

----------------------------------------------------------------------------------------------
-- Machine behaviour
----------------------------------------------------------------------------------------------

local OFFSET = 1  -- controller slot = driver slot + 1, as measured in game

local function invOf(side) return world.inventories[side] end

local function driverSlot(side, index)
    return invOf(side).slots[index + OFFSET]
end

local function setDriverSlot(side, index, value)
    invOf(side).slots[index + OFFSET] = value
end

-- The mutation the loaded parents can make. Only one pair is set up, which is all a smoke test
-- needs: Meadows x Forest -> Common, the first cross of every Forestry playthrough.
local function offeredMutations()
    local p1 = driverSlot(world.mutatron.side, world.mutatron.slots.in1)
    local p2 = driverSlot(world.mutatron.side, world.mutatron.slots.in2)
    if not p1 or not p2 then return {} end

    return {[1] = {index = 1, key = 4, name = "forestry:bee_queen_ge", label = "Common Queen"}}
end

local function mutatronCanStart()
    local m = world.mutatron
    if not driverSlot(m.side, m.slots.in1) then return false, "missing parent 1" end
    if not driverSlot(m.side, m.slots.in2) then return false, "missing parent 2" end
    if not driverSlot(m.side, m.slots.labware) then return false, "missing labware" end
    if driverSlot(m.side, m.slots.output) then return false, "output full" end
    if m.mutagen < 500 then
        return false, string.format("not enough mutagen: %d of 500 mB", m.mutagen)
    end

    return true
end

local function mutatronProduce()
    local m = world.mutatron
    setDriverSlot(m.side, m.slots.in1, nil)
    setDriverSlot(m.side, m.slots.in2, nil)

    local labware = driverSlot(m.side, m.slots.labware)
    if labware then
        labware.size = labware.size - 1
        labware.count = labware.size
        if labware.size <= 0 then setDriverSlot(m.side, m.slots.labware, nil) end
    end

    m.mutagen = m.mutagen - 500
    setDriverSlot(m.side, m.slots.output, stack("forestry:bee_queen_ge", "Common Queen"))
    m.working = false

    record("mutatron produced a Common Queen")
    raise("advmutatron_finished")
    raise("advmutatron_output")
end

local function apiaryQueenType()
    local a = world.apiary
    local held = driverSlot(a.side, a.slots.queen)
    if not held then return "none" end

    local label = (held.label or ""):lower()
    if label:find("queen") then return "queen" end
    if label:find("princess") then return "princess" end

    return "other"
end

-- The beebee gun kills the queen: the slot frees, and the cycle's products appear.
local function apiaryFire()
    local a = world.apiary
    if apiaryQueenType() ~= "queen" then
        record("beebee gun fired at a slot holding: %s", apiaryQueenType())

        return
    end

    local held = driverSlot(a.side, a.slots.queen)

    -- A dying queen leaves a princess and drones of HER species. Producing a fixed species made
    -- the queen-to-princess conversion look like it had failed, whatever it converted.
    local species = tostring(held.label or ""):gsub("%s*[Qq]ueen$", "")
    if species == "" then species = "Common" end

    setDriverSlot(a.side, a.slots.queen, nil)

    local products = {
        stack("forestry:bee_princess_ge", species .. " Princess"),
        stack("forestry:bee_drone_ge", species .. " Drone", 2),
        stack("forestry:honey_drop", "Honey Drop", 4),
    }
    for i, item in ipairs(products) do
        setDriverSlot(a.side, a.slots.outputs[i], item)
    end

    a.shot = true
    record("queen killed, %d output stacks produced", #products)
    raise("apiary_finished")
    raise("apiary_output")
end

----------------------------------------------------------------------------------------------
-- The components
----------------------------------------------------------------------------------------------

local function stackInfo(item)
    if not item then return nil end

    return {name = item.name, label = item.label, count = item.size, size = item.size}
end

local advmutatron = {
    listSlots = function()
        local s = world.mutatron.slots

        return {in1 = s.in1, in2 = s.in2, output = s.output, labware = s.labware,
                selectors = s.selectors, size = s.size}
    end,
    listMutations = function() return offeredMutations() end,
    getTank = function() return {amount = world.mutatron.mutagen, capacity = 10000, fluid = "mutagen"} end,
    getEnergy = function() return {stored = 160000, capacity = 160000} end,
    getProgress = function() return world.mutatron.working and 0.5 or 0 end,
    isWorking = function() return world.mutatron.working end,
    canStart = function() return (mutatronCanStart()) end,
    getOutput = function()
        return stackInfo(driverSlot(world.mutatron.side, world.mutatron.slots.output))
    end,
    setEventsEnabled = function() return true end,
    setSignalInterval = function() return true end,
    selectAndProduce = function(n)
        local mutations = offeredMutations()
        if not mutations[n] then return false, "invalid index/key" end

        local ok, why = mutatronCanStart()
        if not ok then return false, why end

        world.mutatron.selected = n
        world.mutatron.working = true
        record("selectAndProduce(%s) accepted", tostring(n))

        -- The real machine returns at once and finishes on its own tick.
        mutatronProduce()

        return true
    end,
}
advmutatron.selectAndProduceAsync = advmutatron.selectAndProduce

local industrial_apiary = {
    listSlots = function()
        local s = world.apiary.slots

        return {queen = s.queen, drone = s.drone, bees = s.bees, upgrades = s.upgrades,
                outputs = s.outputs, size = s.size}
    end,
    getPrincessStatus = function()
        local t = apiaryQueenType()

        return {occupied = t ~= "none", type = t, freed = t == "none", automated = false}
    end,
    getErrors = function() return {hasErrors = false, errors = {}} end,
    getEnvironment = function() return {temperature = "Normal", humidity = "Normal"} end,
    getModifiers = function()
        return {production = 1, lifespan = 1, territory = 1, mutation = 1, flowering = 1,
                geneticDecay = 1, isSealed = false, isSelfLighted = true, isSunlightSimulated = false,
                isAutomated = false, isCollectingPollen = false, energy = 1,
                temperature = "Normal", humidity = "Normal"}
    end,
    getProgress = function() return 0 end,
    isWorking = function() return apiaryQueenType() == "queen" end,
    getEnergy = function() return {stored = 40000, capacity = 40000} end,
    getRedstoneMode = function() return {mode = world.apiary.redstone_mode, canWork = true} end,
    setRedstoneMode = function(mode)
        world.apiary.redstone_mode = mode
        record("apiary redstone mode -> %s", tostring(mode))

        return true
    end,
    listUpgrades = function()
        local out = {}
        for _, index in ipairs(world.apiary.slots.upgrades) do
            local item = driverSlot(world.apiary.side, index)
            if item then
                out[#out + 1] = {name = item.name, label = item.label, count = item.size, slot = index}
            end
        end

        return out
    end,
    listOutputs = function()
        local out = {}
        for _, index in ipairs(world.apiary.slots.outputs) do
            local item = driverSlot(world.apiary.side, index)
            if item then
                out[#out + 1] = {name = item.name, label = item.label, count = item.size, slot = index}
            end
        end

        return out
    end,
    getBees = function()
        return {queen = stackInfo(driverSlot(world.apiary.side, world.apiary.slots.queen)),
                drone = stackInfo(driverSlot(world.apiary.side, world.apiary.slots.drone))}
    end,
    getGenome = function(slot)
        local item = driverSlot(world.apiary.side,
            slot == "drone" and world.apiary.slots.drone or world.apiary.slots.queen)
        if not item then return false, "slot is empty" end

        local species = (item.label or ""):gsub("%s*%a+$", "")

        return {
            bee = {type = slot, analyzed = true, natural = true, generation = 1, mated = true},
            chromosomes = {
                species = {active = {uid = "forestry.species" .. species, name = species},
                           inactive = {uid = "forestry.species" .. species, name = species},
                           pure = true},
            },
        }
    end,
    getSpeciesTemplate = function(name)
        return {species = {uid = "forestry.species" .. tostring(name), name = tostring(name),
                           dominant = true}}
    end,
    listSpeciesTemplates = function()
        local out = {}
        for _, name in ipairs({"Forest", "Meadows", "Common", "Cultivated", "Noble", "Majestic",
                               "Imperial", "Diligent", "Unweary", "Industrious"}) do
            out[#out + 1] = {uid = "forestry.species" .. name, name = name, dominant = true,
                             hasTemplate = true}
        end

        return out
    end,
    setEventsEnabled = function() return true end,
    setSignalInterval = function() return true end,
}

local ADDRESSES = {
    ["advmutatron-0000"] = {kind = "advmutatron", api = advmutatron},
    ["industrial-0000"] = {kind = "industrial_apiary", api = industrial_apiary},
}

----------------------------------------------------------------------------------------------
-- The OpenComputers API
----------------------------------------------------------------------------------------------

local redstone_output = {}

local mock_component = {
    isAvailable = function(name)
        if name == "inventory_controller" or name == "gpu" or name == "redstone" then return true end
        if name == "advmutatron" or name == "industrial_apiary" then return true end

        return false
    end,

    list = function(filter)
        local matches = {}
        for address, entry in pairs(ADDRESSES) do
            if not filter or entry.kind == filter then matches[address] = entry.kind end
        end
        matches["inventory-0000"] = matches["inventory-0000"]
        if not filter then
            matches["inventory-0000"] = "inventory_controller"
            matches["gpu-0000"] = "gpu"
            matches["redstone-0000"] = "redstone"
        end

        local keys = {}
        for address in pairs(matches) do keys[#keys + 1] = address end

        local i = 0
        local iterator = function()
            i = i + 1
            if keys[i] then return keys[i], matches[keys[i]] end

            return nil
        end

        return setmetatable({}, {__call = iterator, __pairs = function()
            return function(_, key)
                local seen = false
                for _, address in ipairs(keys) do
                    if seen or key == nil then return address, matches[address] end
                    if address == key then seen = true end
                end

                return nil
            end, matches, nil
        end})
    end,

    invoke = function(address, method, ...)
        local entry = ADDRESSES[address]
        if not entry then error("no component " .. tostring(address)) end

        local fn = entry.api[method]
        if not fn then error("no such method: " .. tostring(method)) end

        return fn(...)
    end,

    inventory_controller = {
        getInventorySize = function(side)
            local inv = invOf(side)

            return inv and inv.size or nil
        end,
        getStackInSlot = function(side, slot)
            local inv = invOf(side)
            if not inv then return nil end

            return stackInfo(inv.slots[slot])
        end,
        transferItem = function(from, to, count, fromSlot, toSlot)
            local source, target = invOf(from), invOf(to)
            if not source or not target then return 0 end

            local item = source.slots[fromSlot]
            if not item then return 0 end

            local moved = math.min(count or 64, item.size)

            if not toSlot then
                for slot = 1, target.size do
                    if not target.slots[slot] then toSlot = slot break end
                end
            end
            if not toSlot or target.slots[toSlot] then return 0 end

            target.slots[toSlot] = stack(item.name, item.label, moved)
            item.size = item.size - moved
            item.count = item.size
            if item.size <= 0 then source.slots[fromSlot] = nil end

            record("moved %dx %s  side %d slot %d -> side %d slot %d",
                moved, item.label or item.name, from, fromSlot, to, toSlot)

            return moved
        end,
    },

    gpu = {
        setResolution = function() return true end,
        getResolution = function() return 160, 50 end,
        maxResolution = function() return 160, 50 end,
        setBackground = function() return 0 end,
        setForeground = function() return 0xFFFFFF end,
        fill = function() return true end,
        set = function() return true end,
        get = function() return " " end,
    },

    redstone = {
        setOutput = function(side, value)
            redstone_output[side] = value
            if value and value > 0 then
                record("redstone %d -> %d", side, value)
                -- The Mechanical User acts on the rising edge.
                apiaryFire()
            end

            return true
        end,
        getOutput = function(side) return redstone_output[side] or 0 end,
    },
}
mock_component.getPrimary = function(name) return mock_component[name] end
mock_component.proxy = function(address)
    return ADDRESSES[address] and ADDRESSES[address].api or {}
end

local uptime = 0
local mock_computer = {
    energy = function() return 1000 end,
    maxEnergy = function() return 1000 end,
    beep = function() return true end,
    freeMemory = function() return 400000 end,
    totalMemory = function() return 800000 end,
    address = function() return "computer-0000" end,
    shutdown = function() error("the program tried to shut the computer down") end,
    uptime = function()
        uptime = uptime + 0.1

        return uptime
    end,
    pullSignal = function() return nil end,
}

-- A real computer waiting on a signal that never comes just sits there. Here that would be an
-- endless loop with nothing on screen, which is the one failure a simulator must never reproduce:
-- after enough empty polls, say what the program is waiting for and stop.
local empty_pulls = 0
local PULL_LIMIT = 400

local mock_event = {
    -- Signals raised by the machines are handed out in order; anything else times out at once,
    -- which is what an idle world does.
    pull = function(timeout, filter)
        if type(timeout) == "string" then filter, timeout = timeout, nil end

        for i, signal in ipairs(world.signals) do
            if not filter or signal[1] == filter then
                table.remove(world.signals, i)
                empty_pulls = 0

                return table.unpack(signal)
            end
        end

        empty_pulls = empty_pulls + 1
        if empty_pulls > PULL_LIMIT then
            error(string.format(
                "deadlock: %d event.pull(%s) in a row with nothing to answer -- the program is "
                .. "waiting for something this world never raises\n%s", empty_pulls,
                tostring(filter or "any"), debug.traceback("", 2)), 0)
        end

        return nil
    end,
    listen = function() return true end,
    ignore = function() return true end,
    timer = function() return 1 end,
}

local mock_term = {
    clear = function() return true end,
    setCursor = function() return true end,
    getCursor = function() return 1, 1 end,
    write = function() return true end,
    read = function() return "" end,
}

package.loaded["component"] = mock_component
package.loaded["computer"] = mock_computer
package.loaded["term"] = mock_term
package.loaded["event"] = mock_event
package.loaded["keyboard"] = {}
package.loaded["sides"] = SIDES

_G.component = mock_component
_G.computer = mock_computer
_G.term = mock_term
_G.event = mock_event
_G.sides = SIDES

-- OpenOS adds os.sleep; standard Lua has no such thing.
os.sleep = function() end

_G.HIVEMIND_AS_MODULE = true

----------------------------------------------------------------------------------------------
-- The run
----------------------------------------------------------------------------------------------

local hive = require("main")

local passed, failed = 0, 0
local function check(label, ok, detail)
    if ok then
        passed = passed + 1
        print(string.format("  OK    %s", label))
    else
        failed = failed + 1
        print(string.format("  FAIL  %s%s", label, detail and ("  -- " .. detail) or ""))
    end
end

print("=== HiveMind against a simulated world ===")
print()

print("Drivers")
check("the two drivers are found", hive.config ~= nil)
local api = hive.checkGendustryAPI and hive.checkGendustryAPI() or nil
check("checkGendustryAPI reports the drivers", api == true, "answered " .. tostring(api))
print()

print("Inventory")
hive.scanInventory()
local inventory = hive.inventory or {}
check("a princess was found", #(inventory.princesses or {}) > 0,
    "found " .. #(inventory.princesses or {}))
check("a drone was found", #(inventory.drones or {}) > 0,
    "found " .. #(inventory.drones or {}))
print()

print("One breeding step: Meadows + Forest -> Common")
local ok, err = pcall(function()
    return hive.executeSingleBreedingStep("Meadows", "Forest", "Common", true)
end)
check("the step ran without raising", ok, tostring(err))
print()

print("What the world looks like afterwards")
check("the mutatron output slot is empty again",
    driverSlot(world.mutatron.side, world.mutatron.slots.output) == nil)
check("the apiary queen slot is free", apiaryQueenType() == "none", apiaryQueenType())
check("the beebee gun was fired", world.apiary.shot == true)
-- One labware is carried into the machine per cycle and burnt there, so the stack that shrinks
-- is the one in the chest, not one sitting in the mutatron.
local labware_left = (world.inventories[SIDES.back].slots[3] or {size = 0}).size
check("one labware was taken from the chest", labware_left == 63, tostring(labware_left))
check("the labware slot is empty again, ready for the next cycle",
    driverSlot(world.mutatron.side, world.mutatron.slots.labware) == nil)
check("mutagen was consumed", world.mutatron.mutagen == 9500, tostring(world.mutatron.mutagen))

local harvested, princess_back = 0, false
for _, item in pairs(world.inventories[SIDES.down].slots) do
    harvested = harvested + (item and 1 or 0)
    if item and (item.label or ""):find("Princess") then princess_back = true end
end
check("products reached the output chest", harvested > 0, tostring(harvested) .. " stacks")
check("the princess came back, so the line can continue", princess_back)
check("the apiary was released after the transfer", world.apiary.redstone_mode == "ALWAYS",
    world.apiary.redstone_mode)
print()

print("Only a queen left of a species the cross needs")
-- Exactly the state a run leaves when a cross consumed the princess and an earlier attempt
-- dropped a queen in a chest: the mutatron takes a princess and refuses the queen outright.
world.inventories[SIDES.back].slots[1] = stack("forestry:bee_queen_ge", "Meadows Queen")
world.inventories[SIDES.back].slots[2] = stack("forestry:bee_drone_ge", "Forest Drone")
world.apiary.shot = false
hive.scanInventory()

local converted, why = pcall(function() return hive.loadMutatron("Meadows", "Forest") end)
check("loading with only a queen does not raise", converted, tostring(why))
check("the queen went through the apiary", world.apiary.shot == true)
print()

print("A machine left loaded by a previous attempt")
-- Exactly the state a crashed or aborted run leaves behind.
setDriverSlot(world.mutatron.side, world.mutatron.slots.in1,
    stack("forestry:bee_princess_ge", "Common Princess"))
setDriverSlot(world.mutatron.side, world.mutatron.slots.output,
    stack("forestry:bee_queen_ge", "Common Queen"))

local cleared, report = hive.clearMutatron()
check("the leftovers are cleared", cleared == true, tostring(report))
check("the parent slot is free again",
    driverSlot(world.mutatron.side, world.mutatron.slots.in1) == nil)
check("the output slot is free again",
    driverSlot(world.mutatron.side, world.mutatron.slots.output) == nil)
print()

print("A cross whose parents are not in stock")
-- The bee is absent and no one is there to put one in a chest, so handleError waits forever --
-- which is what a headless run of the real thing does too. What matters is that it stops on a
-- sentence naming the missing bee rather than raising out of transferItem with a stack trace.
local ok2, err2 = pcall(function()
    return hive.loadMutatron("Imperial", "Nonexistent", true)
end)
local message = tostring(err2 or "")
check("it does not raise from inside transferItem",
    not message:find("transferItem", 1, true), message:sub(1, 90))
print()

print("World log")
for _, line in ipairs(world.log) do print("  " .. line) end
print()

print(string.format("=== %d passed, %d failed ===", passed, failed))
os.exit(failed == 0 and 0 or 1)
