-- HiveMind breeding cycle tests
--
-- The one integration test of the project: a full Forest + Meadows -> Common
-- run driven through the real job queue, the real machine drivers and the real
-- transport layer, against a simulated world. Only the OpenComputers components
-- are mocked, with the shapes and semantics calibration measured in game.

package.path = package.path .. ";./?.lua"

local jobs = require("lib.jobs")
local breeding = require("lib.breeding")
local machines = require("lib.machines")
local transport = require("lib.transport")
local config = require("lib.config")

local passed, failed = 0, 0

local function check(description, actual, expected)
    if actual == expected then
        passed = passed + 1
        print("  OK   " .. description)
    else
        failed = failed + 1
        print("  FAIL " .. description
            .. "\n         obtenu  : " .. tostring(actual)
            .. "\n         attendu : " .. tostring(expected))
    end
end

local function checkTruthy(description, value)
    if value then
        passed = passed + 1
        print("  OK   " .. description)
    else
        failed = failed + 1
        print("  FAIL " .. description)
    end
end

local function callable(fn)
    return setmetatable({}, {__call = function(_, ...) return fn(...) end})
end

local function genomeFor(species)
    return '{IsAnalyzed:0b,Genome:{Chromosomes:['
        .. '{Slot:0b,UID0:"' .. species .. '",UID1:"' .. species .. '"},'
        .. '{Slot:1b,UID0:"forestry.speedSlower",UID1:"forestry.speedSlower"}]}}'
end

-- Sides come from the real installation discovered in game
local SIDE_INTERFACE, SIDE_APIARY, SIDE_MUTATRON = 2, 3, 5

local world, log

local function reset(options)
    options = options or {}

    world = {
        network = {
            {name = "forestry:bee_princess_ge", label = "Forest Princess", size = 1},
            {name = "forestry:bee_drone_ge", label = "Meadows Drone", size = 12},
            {name = "gendustry:labware", label = "Labware", size = 64},
        },
        interface = {},
        mutatron = {},
        apiary = {},
        mutagen = options.mutagen or 8000,
        energy = options.energy or 20000,
        errors = options.errors or {},
        cycleRuns = 0,
        produceCalls = 0,
        collected = {},
    }

    log = {}
end

-- ---------------------------------------------------------------------------
-- Mocked OpenComputers components
-- ---------------------------------------------------------------------------

local function inventoryFor(side)
    if side == SIDE_INTERFACE then return world.interface end
    if side == SIDE_MUTATRON then return world.mutatron end
    if side == SIDE_APIARY then return world.apiary end
    return nil
end

local me = {
    getItemsInNetwork = callable(function(filter)
        if filter and filter.name then
            local matching = {}
            for _, item in ipairs(world.network) do
                if item.name == filter.name then table.insert(matching, item) end
            end
            return matching
        end
        return world.network
    end),
    store = callable(function(filter, address, slot)
        for _, item in ipairs(world.network) do
            if item.label == filter.label then
                world.staged = world.staged or {}
                world.staged[slot] = item
                return true
            end
        end
        return false
    end),
    setInterfaceConfiguration = callable(function(dock, address, entry, count)
        if not address then world.interface[dock] = nil return true end
        local item = world.staged and world.staged[entry]
        if item then world.interface[dock] = {label = item.label, name = item.name, size = count or 1} end
        return true
    end),
    isNetworkPowered = callable(function() return true end),
}

local database = {
    address = "db",
    get = callable(function() return nil end),
    computeHash = callable(function() return "hash" end),
}

local transposerComponent = {
    getInventorySize = callable(function(side)
        return inventoryFor(side) and 32 or nil
    end),
    getSlotStackSize = callable(function(side, slot)
        local inventory = inventoryFor(side)
        local stack = inventory and inventory[slot]
        return stack and (stack.size or 1) or 0
    end),
    getStackInSlot = callable(function(side, slot)
        local inventory = inventoryFor(side)
        return inventory and inventory[slot] or nil
    end),
    transferItem = callable(function(fromSide, toSide, count, fromSlot, toSlot)
        local from = inventoryFor(fromSide)
        local to = inventoryFor(toSide)
        if not from or not to then return false end

        local stack = from[fromSlot]
        if not stack then return false end

        if toSide == SIDE_INTERFACE then
            -- Anything pushed into the interface leaves for the network
            table.insert(world.collected, stack.label)
        else
            to[toSlot] = stack
        end

        from[fromSlot] = nil
        return true
    end),
    store = callable(function() return false end),
    compareStackToDatabase = callable(function() return false end),
}

local mutatronComponent = {
    listSlots = callable(function()
        return {in1 = 0, in2 = 1, output = 2, labware = 3, selectors = {4, 5, 6, 7, 8, 9}}
    end),
    getTank = callable(function() return {amount = world.mutagen, capacity = 10000} end),
    canStart = callable(function() return world.mutagen > 0 end),
    getEnergyStored = callable(function() return world.energy end),
    getMaxEnergyStored = callable(function() return 20000 end),
    getOutput = callable(function() return world.mutatron[2] end),
    listMutations = callable(function()
        -- The machine only offers mutations the loaded parents allow
        if not (world.mutatron[0] and world.mutatron[1]) then return {} end
        return {{index = 1, key = 4, name = "forestry:bee_queen_ge",
                 label = "Common Queen", nbt = genomeFor("forestry.speciesCommon")}}
    end),
    selectAndProduce = callable(function(index, timeout)
        world.produceCalls = world.produceCalls + 1

        if world.mutagen <= 0 then return false, "reservoir vide" end
        if not world.mutatron[3] then return false, "labware manquant" end

        world.mutagen = world.mutagen - 1000
        world.mutatron[0], world.mutatron[1] = nil, nil
        world.mutatron[2] = {name = "forestry:bee_queen_ge", label = "Common Queen",
                             nbt = genomeFor("forestry.speciesCommon"), size = 1}
        return true, world.mutatron[2]
    end),
}

local apiaryComponent = {
    listSlots = callable(function()
        return {queen = 0, drone = 1, upgrades = {2, 3, 4, 5},
                outputs = {6, 7, 8, 9, 10, 11, 12, 13, 14}}
    end),
    getBees = callable(function()
        local bees = {}
        if world.apiary[0] then bees.queen = world.apiary[0] end
        if world.apiary[1] then bees.drone = world.apiary[1] end
        return bees
    end),
    listOutputs = callable(function()
        local outputs = {}
        for _, slot in ipairs({6, 7, 8, 9, 10, 11, 12, 13, 14}) do
            if world.apiary[slot] then
                table.insert(outputs, {slot = slot, label = world.apiary[slot].label, count = 1})
            end
        end
        return outputs
    end),
    getErrors = callable(function()
        return {hasErrors = #world.errors > 0, errors = world.errors}
    end),
    getModifiers = callable(function() return {isAutomated = false} end),
    getEnergyStored = callable(function() return world.energy end),
    getMaxEnergyStored = callable(function() return 20000 end),
    waitForPrincess = callable(function(timeout)
        if not world.apiary[0] then return false, "aucune reine" end
        world.cycleRuns = world.cycleRuns + 1
        world.apiary[0] = nil
        world.apiary[6] = {label = "Common Princess", size = 1}
        world.apiary[7] = {label = "Common Drone", size = 3}
        return true
    end),
}

-- ---------------------------------------------------------------------------

local TMP = (os.getenv("TEMP") or os.getenv("TMPDIR") or "/tmp"):gsub("\\", "/")
local QUEUE = TMP .. "/hivemind-breeding-test.lua"

local ticks = 0

local function buildStack()
    local layer = transport.new({
        me = me,
        database = database,
        transposers = {transposerComponent},
        config = {docks = {1, 2}, stock_timeout_seconds = 3, poll_interval_seconds = 0},
        sleep = function() end,
        clock = function() ticks = ticks + 1 return ticks end,
    })

    local built = machines.all({
        config = config,
        components = {advmutatron = mutatronComponent, industrial_apiary = apiaryComponent},
        transport = layer,
        sleep = function() end,
        clock = function() ticks = ticks + 1 return ticks end,
    })

    local queue = jobs.new({
        path = QUEUE,
        handlers = {breed = breeding.handler()},
        clock = function() ticks = ticks + 1 return ticks end,
        maxAttempts = 2,
    })

    local context = {
        machines = built,
        transport = layer,
        log = function(text) table.insert(log, text) end,
    }

    return queue, context
end

local PARAMS = breeding.params({
    target = "forestry.speciesCommon",
    princess = {name = "forestry:bee_princess_ge", label = "Forest Princess"},
    drone = {name = "forestry:bee_drone_ge", label = "Meadows Drone"},
})

os.remove(QUEUE)
reset()

print("=== Breeding cycle tests ===")
print("")
print("-- parametres --")

checkTruthy("parametres construits", PARAMS)
check("cible conservee", PARAMS.target, "forestry.speciesCommon")
check("labware par defaut", PARAMS.labware.name, "gendustry:labware")
check("cible manquante refusee", (breeding.params({})), nil)
check("princesse sans etiquette refusee",
      (breeding.params({target = "x", princess = {}, drone = {label = "d"}})), nil)

print("")
print("-- cycle complet Forest + Meadows -> Common --")

os.remove(QUEUE)
reset()
local queue, context = buildStack()
queue:submit("breed", PARAMS)

local report = queue:run(context, {maxSteps = 40})

check("tache terminee", queue:get(1).status, jobs.COMPLETE)
check("sept etapes", report.steps, 7)
check("le Mutatron a tourne une fois", world.produceCalls, 1)
check("mutagene consomme une fois", world.mutagen, 7000)
check("un cycle d'apiary", world.cycleRuns, 1)
check("slot reine vide a la fin", world.apiary[0], nil)
check("sorties de l'apiary videes", #apiaryComponent.listOutputs(), 0)

-- Everything harvested went back to the ME network
local harvested = table.concat(world.collected, ",")
checkTruthy("princesse recoltee", harvested:find("Common Princess", 1, true))
checkTruthy("drones recoltes", harvested:find("Common Drone", 1, true))

print("")
print("-- reprise apres coupure --")

-- Kill the computer after the queen is produced but before it is recorded
os.remove(QUEUE)
reset()
queue, context = buildStack()
queue:submit("breed", PARAMS)

for _ = 1, 4 do queue:step(queue:pending()[1], context) end
check("la reine est produite", world.mutatron[2] ~= nil, true)
check("un seul passage au Mutatron", world.produceCalls, 1)

-- New process: nothing in memory, the queue is reread from disk
local resumed, resumedContext = buildStack()
resumed:run(resumedContext, {maxSteps = 40})

check("la tache s'acheve apres reprise", resumed:get(1).status, jobs.COMPLETE)
-- The decisive property: no second dose of mutagen
check("le Mutatron n'a pas retourne", world.produceCalls, 1)
check("mutagene consomme une seule fois", world.mutagen, 7000)

print("")
print("-- etape deja accomplie hors du programme --")

os.remove(QUEUE)
reset()
queue, context = buildStack()
queue:submit("breed", PARAMS)

-- Someone put the labware in by hand
world.mutatron[3] = {label = "Labware", size = 1}
queue:step(queue:pending()[1], context)          -- output already empty
local skipped = queue:step(queue:pending()[1], context)
check("l'etape labware est sautee", skipped, jobs.DONE)
check("aucun labware supplementaire tire", world.mutatron[3].size, 1)

print("")
print("-- panne de mutagene : attendre, pas echouer --")

os.remove(QUEUE)
reset({mutagen = 0})
queue, context = buildStack()
queue:submit("breed", PARAMS)

local dry = queue:run(context, {maxSteps = 40})
check("la file signale un blocage", dry.blocked, true)
check("tache en attente, pas en erreur", queue:get(1).status, jobs.PENDING)
checkTruthy("raison mentionnant le mutagene",
            queue:get(1).error and queue:get(1).error:find("mutagene"))

-- Refill and come back: it picks up where it stopped
world.mutagen = 5000
queue:run(context, {maxSteps = 40})
check("cycle acheve apres remplissage", queue:get(1).status, jobs.COMPLETE)
check("une seule production", world.produceCalls, 1)

print("")
print("-- apiary inadapte a l'abeille --")

os.remove(QUEUE)
reset({errors = {"forestry:too_hot"}})
queue, context = buildStack()
queue:submit("breed", PARAMS)

local hostile = queue:run(context, {maxSteps = 40})
check("la file attend", hostile.blocked, true)
check("pas d'erreur definitive", queue:get(1).status, jobs.PENDING)
checkTruthy("l'environnement est cite",
            queue:get(1).error and queue:get(1).error:find("too_hot"))

world.errors = {}
queue:run(context, {maxSteps = 40})
check("cycle acheve une fois l'apiary corrige", queue:get(1).status, jobs.COMPLETE)

print("")
print("-- mutation impossible avec ces parents --")

os.remove(QUEUE)
reset()
queue, context = buildStack()

local impossible = breeding.params({
    target = "forestry.speciesImperial",
    princess = {name = "forestry:bee_princess_ge", label = "Forest Princess"},
    drone = {name = "forestry:bee_drone_ge", label = "Meadows Drone"},
})
queue:submit("breed", impossible)

for _ = 1, 6 do queue:run(context, {maxSteps = 10}) end

-- The machine's own answer, so the plan is refused before wasting anything
check("tache en erreur", queue:get(1).status, jobs.ERROR)
checkTruthy("la raison nomme la cible",
            queue:get(1).error and queue:get(1).error:find("Imperial"))
checkTruthy("les mutations proposees sont listees",
            queue:get(1).error and queue:get(1).error:find("Common Queen"))
check("aucun mutagene gaspille", world.mutagen, 8000)

os.remove(QUEUE)

print("")
print("=== Resultats ===")
print("Reussis : " .. passed)
print("Echoues : " .. failed)
print(failed == 0 and "Le cycle de croisement passe." or "Des tests echouent.")

os.exit(failed == 0 and 0 or 1)
