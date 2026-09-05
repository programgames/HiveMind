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

-- The Apiarist Terminal numbers slots from zero, OpenComputers from one, and
-- the first real run proved they are off by one: inserting labware at driver
-- slot 3 landed on the output and was refused. The simulated inventories are
-- therefore keyed by transposer index, and the mocked drivers convert, so the
-- two views describe the same physical slot the way the game does.
local SLOT_OFFSET = 1

--- Transposer index of a slot the driver calls `driverSlot`
--- @param driverSlot number
--- @return number
local function oc(driverSlot)
    return driverSlot + SLOT_OFFSET
end

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
        staged = {},      -- the Database upgrade
        mutatron = {},
        apiary = {},
        mutagen = options.mutagen or 8000,
        energy = options.energy or 20000,
        errors = options.errors or {},
        immortalQueen = options.immortalQueen or false,
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

-- The queen dies after a few reads of her slot, which is how a cycle really
-- ends. OpenComputers aborts a component call that blocks, so nothing can wait
-- inside waitForPrincess: the program polls, and the world has to move between
-- polls or the poll loop tests nothing.
local READS_BEFORE_DEATH = 3

local function tickQueen()
    -- A princess alone is not a queen and does not die: Forestry merges her
    -- with a drone first. Killing anything parked in the slot made the mock
    -- swallow bees the program was about to hand back to the network.
    local occupant = world.apiary[oc(0)]
    if not occupant then return end

    local label = occupant.label or ""

    if not label:find(" Queen", 1, true) then
        if not world.apiary[oc(1)] then return end

        -- The pair becomes a queen, which is what the game does within a tick
        local species = label:gsub("%s+%a+$", "")
        world.apiary[oc(0)] = {name = "forestry:bee_queen_ge",
                               label = species .. " Queen", size = 1}
        world.apiary[oc(1)] = nil
        world.queenReads = 0
        return
    end

    world.queenReads = (world.queenReads or 0) + 1

    -- Une reine qui ne meurt jamais: c est le seul moyen de reproduire ici
    -- une attente qui expire, et l attente qui expire est le cas ou le cumul
    -- se lit
    if world.immortalQueen then return end

    if world.queenReads < READS_BEFORE_DEATH then return end

    world.queenReads = 0
    world.cycleRuns = world.cycleRuns + 1

    local species = label:gsub("%s+%a+$", "")
    world.apiary[oc(0)] = nil
    world.apiary[oc(1)] = nil

    world.apiary[oc(6)] = {name = "forestry:bee_princess_ge",
                           label = species .. " Princess", size = 1}

    local produced = world.dronesPerCycle
    if produced == nil then produced = 3 end

    if produced > 0 then
        world.apiary[oc(7)] = {name = "forestry:bee_drone_ge",
                               label = species .. " Drone", size = produced}
    end
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
    -- Writes into the database only on a match, and answers false otherwise.
    -- Taking that for success is what once had AE2 stock a stale entry.
    store = callable(function(filter, address, slot)
        for _, item in ipairs(world.network) do
            if item.label == filter.label then
                world.staged[slot] = item
                return true
            end
        end
        return false
    end),
    setInterfaceConfiguration = callable(function(dock, address, entry, count)
        if not address then world.interface[dock] = nil return true end
        local item = world.staged[entry]
        if item then
            world.interface[dock] = {label = item.label, name = item.name, size = count or 1}
        end
        return true
    end),
    isNetworkPowered = callable(function() return true end),
}

local database = {
    address = "db",
    clear = callable(function(slot) world.staged[slot] = nil return true end),
    get = callable(function(slot) return world.staged[slot] end),
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
        -- Reading the queen slot is what the program does while it waits, so
        -- that read is where the simulated cycle advances
        if side == SIDE_APIARY and slot == oc(0) then tickQueen() end

        local inventory = inventoryFor(side)
        return inventory and inventory[slot] or nil
    end),
    transferItem = callable(function(fromSide, toSide, count, fromSlot, toSlot)
        local from = inventoryFor(fromSide)
        local to = inventoryFor(toSide)
        if not from or not to then return false end

        local stack = from[fromSlot]
        if not stack then return false end

        -- Gendustry input slots refuse automated extraction. The mock let
        -- everything out, so a blocked slot -- the single most common thing to
        -- go wrong in game -- could not be reproduced here at all.
        if world.mutatronLocked and fromSide == SIDE_MUTATRON then return false end

        if toSide == SIDE_INTERFACE then
            -- Anything pushed into the interface leaves for the network
            table.insert(world.collected, stack.label)
        else
            -- A real transposer cannot merge two different items into one
            -- slot. Overwriting here made the mock more forgiving than the
            -- game and hid a leftover parent blocking every later delivery.
            local occupant = to[toSlot]
            if occupant and occupant.label ~= stack.label then return false end

            if occupant then
                occupant.size = (occupant.size or 1) + (stack.size or 1)
            else
                to[toSlot] = stack
            end
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
    getOutput = callable(function() return world.mutatron[oc(2)] end),
    listMutations = callable(function()
        -- The machine only offers mutations the loaded parents allow
        if not (world.mutatron[oc(0)] and world.mutatron[oc(1)]) then return {} end
        return {{index = 1, key = 4, name = "forestry:bee_queen_ge",
                 label = "Common Queen", nbt = genomeFor("forestry.speciesCommon")}}
    end),
    selectAndProduce = callable(function(index, timeout)
        world.produceCalls = world.produceCalls + 1

        if world.mutagen <= 0 then return false, "reservoir vide" end
        if not world.mutatron[oc(3)] then return false, "labware manquant" end

        world.mutagen = world.mutagen - 1000
        world.mutatron[oc(0)], world.mutatron[oc(1)] = nil, nil
        world.mutatron[oc(2)] = {name = "forestry:bee_queen_ge", label = "Common Queen",
                                 nbt = genomeFor("forestry.speciesCommon"), size = 1}
        return true, world.mutatron[oc(2)]
    end),
}

local apiaryComponent = {
    listSlots = callable(function()
        return {queen = 0, drone = 1, upgrades = {2, 3, 4, 5},
                outputs = {6, 7, 8, 9, 10, 11, 12, 13, 14}}
    end),
    getBees = callable(function()
        local bees = {}
        if world.apiary[oc(0)] then bees.queen = world.apiary[oc(0)] end
        if world.apiary[oc(1)] then bees.drone = world.apiary[oc(1)] end
        return bees
    end),
    listOutputs = callable(function()
        local outputs = {}
        -- The driver reports its own indices, which the machine layer converts
        for _, slot in ipairs({6, 7, 8, 9, 10, 11, 12, 13, 14}) do
            local stack = world.apiary[oc(slot)]
            if stack then
                table.insert(outputs, {slot = slot, label = stack.label, count = 1})
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
        if not world.apiary[oc(0)] then return false, "aucune reine" end
        world.cycleRuns = world.cycleRuns + 1
        world.apiary[oc(0)] = nil
        world.apiary[oc(6)] = {label = "Common Princess", size = 1}
        world.apiary[oc(7)] = {label = "Common Drone", size = 3}
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
        -- Machines name their transposer by address now, so the stack has to
        -- offer one to find. A position would break the moment the real world
        -- gained another transposer, which is exactly what happened.
        byAddress = {
            ["65d3da44-cb90-4812-a6fa-d28128c9a988"] = transposerComponent,
            ["95625858-b606-4eb0-89cb-4f3b467c0c06"] = transposerComponent,
        },
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

--- Fresh breeding parameters
--- A submitted job keeps its params table BY REFERENCE, and the steps write
--- their own bookkeeping into it (how many dry passes, which upgrade was
--- already tried). Sharing one table between two cases carried the first
--- case's history into the second, which is exactly what it was there to test.
--- @return table
local function freshParams()
    return breeding.params({
        target = "forestry.speciesCommon",
        princess = {name = "forestry:bee_princess_ge", label = "Forest Princess"},
        drone = {name = "forestry:bee_drone_ge", label = "Meadows Drone"},
    })
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
-- Eight since the cross saves the new species' gene on its way out: an
-- species obtained once must never have to be obtained again.
check("huit etapes", report.steps, 8)
check("le Mutatron a tourne une fois", world.produceCalls, 1)
check("mutagene consomme une fois", world.mutagen, 7000)
check("un cycle d'apiary", world.cycleRuns, 1)
check("slot reine vide a la fin", world.apiary[oc(0)], nil)
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
check("la reine est produite", world.mutatron[oc(2)] ~= nil, true)
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
world.mutatron[oc(3)] = {label = "Labware", size = 1}
queue:step(queue:pending()[1], context)          -- output already empty
local skipped = queue:step(queue:pending()[1], context)
check("l'etape labware est sautee", skipped, jobs.DONE)
check("aucun labware supplementaire tire", world.mutatron[oc(3)].size, 1)

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
print("-- une reine qui vit longtemps cumule son attente --")

do
    -- Chaque passe repart de zero, donc sans total trois attentes de suite
    -- affichent le meme nombre: rien ne distingue une reine qui prend son
    -- temps d une file figee, et c est exactement ce qu on a lu en jeu.
    os.remove(QUEUE)
    reset()
    queue, context = buildStack()
    queue:submit("breed", freshParams())

    -- La reine ne meurt jamais: le mock ne fait avancer le cycle que quand on
    -- lit son slot, et on fige le compteur pour qu elle survive a l attente
    world.immortalQueen = true

    queue:run(context, {maxSteps = 40})

    local job = queue:get(1)
    checkTruthy("l attente est cumulee sur disque",
                (job.params.waited or 0) > 0)

    local first = job.params.waited

    queue:run(context, {maxSteps = 40})
    checkTruthy("et elle grandit d une passe a l autre",
                (queue:get(1).params.waited or 0) > first)

    checkTruthy("la raison porte le total",
                queue:get(1).error
                and queue:get(1).error:find("au total", 1, true) ~= nil)
end

print("")
print("-- apiary inadapte a l'abeille, sans upgrade dans le reseau --")

-- The apiary complains in one word and nothing in the world was going to
-- change on its own: the job waited for ever on "too_hot". It now tries to
-- fetch the upgrade that answers the complaint, and when the network holds
-- none it says which upgrade to add by hand.
os.remove(QUEUE)
reset({errors = {"forestry:too_hot"}})
queue, context = buildStack()
queue:submit("breed", freshParams())

queue:run(context, {maxSteps = 40})
check("la tache demande la main", queue:get(1).status, jobs.WAITING)

local hostileWhy = queue:get(1).action or queue:get(1).error or ""
checkTruthy("elle dit qu il fait trop chaud", hostileWhy:find("trop chaud"))
checkTruthy("et que le reseau ME n a pas l upgrade",
            hostileWhy:find("aucun dans le reseau ME"))
checkTruthy("le code brut ne suffit pas a un joueur",
            not hostileWhy:find("too_hot"))

world.errors = {}
queue:resumeAll()
queue:run(context, {maxSteps = 40})
check("cycle acheve une fois l'apiary corrige", queue:get(1).status, jobs.COMPLETE)

print("")
print("-- apiary inadapte, mais l upgrade est en stock --")

-- The attempt IS the measurement: nothing says in advance whether an upgrade
-- slot accepts an automated insertion, so the program tries and reads the slot
-- back rather than asking the player first.
os.remove(QUEUE)
reset({errors = {"forestry:too_hot"}})
table.insert(world.network, {name = "gendustry:apiary_upgrade",
                             label = "Cooling Upgrade", size = 4})
queue, context = buildStack()
queue:submit("breed", freshParams())

queue:run(context, {maxSteps = 40})

local fitted = world.apiary[oc(2)]
checkTruthy("l upgrade est pose dans l apiary", fitted ~= nil)
check("et c est le bon", fitted and fitted.label, "Cooling Upgrade")
check("la tache attend le prochain passage, pas la main",
      queue:get(1).status, jobs.PENDING)

world.errors = {}
queue:run(context, {maxSteps = 40})
check("le cycle s acheve ensuite", queue:get(1).status, jobs.COMPLETE)

print("")
print("-- un upgrade pose qui ne suffit pas devient un geste --")

-- Posing the upgrade and finding the same complaint still there settles it:
-- the automatic answer has been spent, and waiting longer buys nothing.
os.remove(QUEUE)
reset({errors = {"forestry:too_hot"}})
table.insert(world.network, {name = "gendustry:apiary_upgrade",
                             label = "Cooling Upgrade", size = 4})
queue, context = buildStack()
queue:submit("breed", PARAMS)

queue:run(context, {maxSteps = 40})
queue:run(context, {maxSteps = 40})
check("la deuxieme fois, il faut une main", queue:get(1).status, jobs.WAITING)

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

-- ---------------------------------------------------------------------------
-- A parent left behind by an earlier job
-- ---------------------------------------------------------------------------
-- Seen in game: job #3 stalled after loading its princess, and job #4 then
-- reported "princesse indisponible" for a bee the network held in stock. Two
-- different bees do not stack, so the delivery moved nothing at all.

print("")
print("-- slot in1 occupe par la princesse d'une tache precedente --")

os.remove(QUEUE)
reset()
world.mutatron[oc(0)] = {name = "forestry:bee_princess_ge",
                         label = "Embittered Princess", size = 1}

local queue, context = buildStack()
queue:submit("breed", PARAMS)

local report = queue:run(context, {maxSteps = 40})

check("tache terminee malgre l'intrus", queue:get(1).status, jobs.COMPLETE)
check("le Mutatron a tourne une fois", world.produceCalls, 1)

checkTruthy("l'intruse est rendue au reseau",
            table.concat(world.collected, ","):find("Embittered Princess", 1, true))

os.remove(QUEUE)

print("")
print("-- un slot que le Mutatron ne rend pas: on demande la main --")

do
    -- The one failure the player cannot delegate. It used to park the job with
    -- a message nobody read, or kill it outright after three passes; either way
    -- the cross was lost over a five second gesture.
    os.remove(QUEUE)
    reset()
    world.mutatronLocked = true
    world.mutatron[oc(0)] = {name = "forestry:bee_princess_ge",
                             label = "Embittered Princess", size = 1}

    local queue, context = buildStack()
    queue:submit("breed", PARAMS)

    local report = queue:run(context, {maxSteps = 40})

    check("la tache attend le joueur", queue:get(1).status, jobs.WAITING)
    checkTruthy("le geste nomme l'intruse",
                queue:get(1).action
                and queue:get(1).action:find("Embittered Princess", 1, true))
    checkTruthy("et le slot, tel que le joueur le voit",
                queue:get(1).action and queue:get(1).action:find("Mutatron"))
    checkTruthy("dit a l'imperatif",
                queue:get(1).action and queue:get(1).action:find("retire"))
    check("la passe le compte comme une attente", report.waiting, 1)
    check("le Mutatron n'a rien produit", world.produceCalls, 0)

    -- And the job survives: this is the whole point
    queue:run(context, {maxSteps = 40})
    queue:run(context, {maxSteps = 40})
    check("la tache est toujours la apres deux passes",
          queue:get(1).status, jobs.WAITING)

    -- The player clears the slot and says so
    world.mutatron[oc(0)] = nil
    world.mutatronLocked = false
    queue:resume(1)

    for _ = 1, 4 do queue:run(context, {maxSteps = 60}) end
    check("et le croisement va jusqu au bout",
          queue:get(1).status, jobs.COMPLETE)

    os.remove(QUEUE)
end

print("")
print("-- une espece obtenue est une espece sauvee --")

do
    -- Les genes d une abeille sont fixes a la naissance, et une espece perdue
    -- se rattrape en refaisant toute la chaine. Le gene Species doit partir en
    -- file au moment ou l espece existe, pas quand on y repense.
    local function stackWithLibrary(saved, droneCount)
        local queue, context = buildStack()

        queue.handlers.campaign = {steps = {
            {name = "faux", verify = function() return true end,
             run = function() return jobs.DONE end},
        }}

        context.queue = queue
        context.config = {genetics = {autosave_species = true,
                                      autosave_min_drones = 4}}
        context.species = {
            list = function()
                return {["forestry.speciesCommon"] = {uid = "forestry.speciesCommon",
                                                      name = "Common"}}
            end,
        }
        context.library = {
            speciesGenes = function() return saved end,
        }

        table.insert(world.network, {name = "forestry:bee_drone_ge",
                                     label = "Common Drone", size = droneCount})

        -- La paire est le critere: un cycle d apiary exige une princesse ET un
        -- drone, et c est exactement ce qu un croisement reussi laisse.
        if droneCount > 0 then
            table.insert(world.network, {name = "forestry:bee_princess_ge",
                                         label = "Common Princess", size = 1})
        end

        return queue, context
    end

    -- The species is new: the hunt goes out on its own
    os.remove(QUEUE)
    reset()
    local queue, context = stackWithLibrary({}, 9)
    queue:submit("breed", freshParams())
    queue:run(context, {maxSteps = 40})

    local hunt = nil
    for _, job in ipairs(queue:list()) do
        if job.kind == "campaign" then hunt = job end
    end

    checkTruthy("une chasse au gene d espece est en file", hunt)
    check("elle vise le bon chromosome", hunt.params.chromosome, "Species")
    check("et le bon allele", hunt.params.allele, "Common")
    check("sur les drones de cette espece", hunt.params.bee.label, "Common Drone")
    -- Le budget n est plus un stock a constituer: l extraction fait tourner
    -- l apiary entre deux tirages et s arrete au premier bon.
    checkTruthy("le budget laisse la boucle travailler", hunt.params.budget > 13)
    check("le croisement reste termine", queue:get(1).status, jobs.COMPLETE)

    -- Already in the library: thirteen drones for a sample the Genetic
    -- Transposer copies for one blank would be pure waste
    os.remove(QUEUE)
    reset()
    local queue2, context2 = stackWithLibrary({Common = true}, 9)
    queue2:submit("breed", freshParams())
    queue2:run(context2, {maxSteps = 40})

    local second = nil
    for _, job in ipairs(queue2:list()) do
        if job.kind == "campaign" then second = job end
    end

    check("un gene deja en bibliotheque ne relance rien", second, nil)

    -- Not enough drones: a campaign with nothing to spend parks itself at once
    -- and clutters the queue with a chore nobody can do
    os.remove(QUEUE)
    reset()
    local queue3, context3 = stackWithLibrary({}, 1)
    queue3:submit("breed", freshParams())
    queue3:run(context3, {maxSteps = 40})

    local third = nil
    for _, job in ipairs(queue3:list()) do
        if job.kind == "campaign" then third = job end
    end

    -- Un seul drone suffit desormais, tant que la princesse est la: c est la
    -- paire qui rend l espece tirable indefiniment.
    checkTruthy("un drone et une princesse suffisent", third)

    -- Sans princesse, en revanche, aucun cycle n est possible
    os.remove(QUEUE)
    reset()
    local queue4, context4 = stackWithLibrary({}, 0)
    table.insert(world.network, {name = "forestry:bee_drone_ge",
                                 label = "Common Drone", size = 3})
    queue4:submit("breed", freshParams())
    queue4:run(context4, {maxSteps = 40})

    local fourth = nil
    for _, job in ipairs(queue4:list()) do
        if job.kind == "campaign" then fourth = job end
    end

    check("sans princesse, aucune chasse n est lancee", fourth, nil)
    checkTruthy("et le programme le dit",
                table.concat(log, " "):find("a sauver plus tard"))

    os.remove(QUEUE)
end

print("")
print("-- un reservoir vide qui ne se remplit plus finit par demander --")

do
    -- Deux lectures opposees derriere le meme symptome. Le Mutagen Producer
    -- remplit le Mutatron tout seul quand il est alimente, donc une cuve
    -- momentanement seche se repare seule et RETRY est juste. Un producteur
    -- sans rien a travailler ne remplira jamais rien, et la tache attendrait
    -- pour toujours sans dire quoi faire.
    local function params()
        return breeding.params({
            target = "forestry.speciesCommon",
            princess = {name = "forestry:bee_princess_ge", label = "Forest Princess"},
            drone = {name = "forestry:bee_drone_ge", label = "Meadows Drone"},
        })
    end

    os.remove(QUEUE)
    reset()
    world.mutagen = 0

    local queue, context = buildStack()
    queue:submit("breed", params())

    -- Les deux premieres passes attendent: la cuve peut encore se remplir
    queue:run(context, {maxSteps = 40})
    check("d abord on attend", queue:get(1).status, jobs.PENDING)
    queue:run(context, {maxSteps = 40})
    check("on attend encore", queue:get(1).status, jobs.PENDING)

    -- A la troisieme, elle n a pas bouge: ce n est plus une attente
    queue:run(context, {maxSteps = 40})
    check("puis le programme demande la main", queue:get(1).status, jobs.WAITING)
    checkTruthy("en nommant la machine a alimenter",
                queue:get(1).action
                and queue:get(1).action:find("Mutagen Producer", 1, true))

    -- Et une cuve qui se remplit entre-temps ne declenche rien
    os.remove(QUEUE)
    reset()
    local queue2, context2 = buildStack()
    queue2:submit("breed", params())
    queue2:run(context2, {maxSteps = 40})
    world.mutagen = 10000
    for _ = 1, 4 do queue2:run(context2, {maxSteps = 60}) end

    check("un remplissage entre deux passes suffit",
          queue2:get(1).status, jobs.COMPLETE)

    os.remove(QUEUE)
end

print("")
print("=== Resultats ===")
print("Reussis : " .. passed)
print("Echoues : " .. failed)
print(failed == 0 and "Le cycle de croisement passe." or "Des tests echouent.")

os.exit(failed == 0 and 0 or 1)
