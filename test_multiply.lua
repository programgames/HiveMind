-- HiveMind drone accumulation tests
--
-- A full campaign driven through the real job queue, the real machine drivers
-- and the real transport layer against a simulated world. Only the
-- OpenComputers components are mocked.
--
-- The loop is what these tests exist for: the last step rewinds job.step, and
-- nothing else in the program does that. An off-by-one there either stops the
-- campaign after one cycle or never stops it at all.

package.path = package.path .. ";./?.lua"

local jobs = require("lib.jobs")
local multiply = require("lib.multiply")
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
            {name = "forestry:bee_princess_ge", label = "Water Princess", size = 1},
            {name = "forestry:bee_drone_ge", label = "Water Drone", size = 1},
            {name = "gendustry:labware", label = "Labware", size = 64},
        },
        interface = {},
        staged = {},      -- the Database upgrade
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

        if toSide == SIDE_INTERFACE then
            -- Anything pushed into the interface leaves for the network, and
            -- shows up there: the campaign counts its own output to decide
            -- whether to go round again.
            table.insert(world.collected, stack.label)

            local merged = false
            for _, item in ipairs(world.network) do
                if item.label == stack.label then
                    item.size = item.size + (stack.size or 1)
                    merged = true
                    break
                end
            end

            if not merged then
                table.insert(world.network, {name = stack.name,
                                             label = stack.label,
                                             size = stack.size or 1})
            end
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
        local queen = world.apiary[oc(0)]
        if not queen then return false, "aucune reine" end

        world.cycleRuns = world.cycleRuns + 1

        -- The pair is spent: the queen dies and the drone went into her
        local species = (queen.label or ""):gsub("%s+%a+$", "")
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

        return true
    end),
}

-- ---------------------------------------------------------------------------

local TMP = (os.getenv("TEMP") or os.getenv("TMPDIR") or "/tmp"):gsub("\\", "/")
local QUEUE = TMP .. "/hivemind-multiply-test.lua"

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
        handlers = {multiply = multiply.handler()},
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


-- ---------------------------------------------------------------------------
-- Scenarios
-- ---------------------------------------------------------------------------

local function waterParams(options)
    options = options or {}
    return (multiply.params({
        species = "Water",
        target = options.target or 8,
        maxCycles = options.maxCycles,
    }))
end

local function droneStock()
    local total = 0
    for _, item in ipairs(world.network) do
        if item.label == "Water Drone" then total = total + item.size end
    end
    return total
end

print("")
print("-- une princesse et un drone deviennent un stock --")

os.remove(QUEUE)
reset()
local queue, context = buildStack()
queue:submit("multiply", waterParams({target = 8}))

local report = queue:run(context, {maxSteps = 200})

check("tache terminee", queue:get(1).status, jobs.COMPLETE)
checkTruthy("objectif atteint", droneStock() >= 8)
checkTruthy("plusieurs cycles d'apiary", world.cycleRuns > 1)
check("la princesse est rendue au reseau",
      (function()
          for _, item in ipairs(world.network) do
              if item.label == "Water Princess" then return true end
          end
          return false
      end)(), true)
check("l'apiary est vide a la fin", #apiaryComponent.listOutputs(), 0)
check("aucun blocage", report.blocked, false)

print("")
print("-- objectif deja atteint: aucun cycle gaspille --")

os.remove(QUEUE)
reset()
world.network[#world.network + 1] =
    {name = "forestry:bee_drone_ge", label = "Water Drone", size = 40}

queue, context = buildStack()
queue:submit("multiply", waterParams({target = 8}))
queue:run(context, {maxSteps = 200})

check("tache terminee", queue:get(1).status, jobs.COMPLETE)
check("aucun cycle lance", world.cycleRuns, 0)

print("")
print("-- un apiary sterile s'arrete au lieu de tourner sans fin --")

os.remove(QUEUE)
reset()
world.dronesPerCycle = 0

queue, context = buildStack()
queue:submit("multiply", waterParams({target = 8, maxCycles = 3}))
for _ = 1, 4 do queue:run(context, {maxSteps = 200}) end

check("tache en erreur", queue:get(1).status, jobs.ERROR)
checkTruthy("la raison compte les cycles",
            queue:get(1).error and queue:get(1).error:find("cycles"))
checkTruthy("le nombre de cycles est borne", world.cycleRuns <= 4)

print("")
print("-- une abeille d'une autre espece occupe le slot reine --")

os.remove(QUEUE)
reset()
world.apiary[oc(0)] = {name = "forestry:bee_princess_ge",
                       label = "Wintry Princess", size = 1}

queue, context = buildStack()
queue:submit("multiply", waterParams({target = 4}))
queue:run(context, {maxSteps = 200})

check("tache terminee malgre l'intruse", queue:get(1).status, jobs.COMPLETE)
checkTruthy("l'intruse est rendue au reseau",
            table.concat(world.collected, ","):find("Wintry Princess", 1, true))

print("")
print("-- reprise apres coupure en pleine campagne --")

os.remove(QUEUE)
reset()
queue, context = buildStack()
queue:submit("multiply", waterParams({target = 12}))

-- Stop the computer partway: enough steps to have cycled at least once
for _ = 1, 9 do
    local job = queue:pending()[1]
    if job then queue:step(job, context) end
end

local interrupted = queue:get(1)
checkTruthy("des cycles ont ete comptes", (interrupted.params.cycles or 0) >= 1)
check("la tache n'est pas finie", interrupted.status, jobs.PENDING)

-- New process: nothing in memory, the queue is reread from disk
local resumed, resumedContext = buildStack()
local before = resumed:get(1).params.cycles

resumed:run(resumedContext, {maxSteps = 200})

check("la tache se termine apres reprise", resumed:get(1).status, jobs.COMPLETE)
checkTruthy("le compteur de cycles a survecu au disque",
            resumed:get(1).params.cycles > before)
checkTruthy("objectif atteint", droneStock() >= 12)

print("")
print("-- une reine d'une autre tache occupe l'apiary --")

-- There is one apiary and a breeding job puts its own queen in the same slot.
-- Accepting any occupant made this campaign wait on someone else's cycle and
-- then count their drones; pulling it out would have sent a queen back to the
-- network, where AE2 shows no genome and it is lost among its kind.
os.remove(QUEUE)
reset()
world.apiary[oc(0)] = {name = "forestry:bee_queen_ge",
                       label = "Cultivated Queen", size = 1}

queue, context = buildStack()
queue:submit("multiply", waterParams({target = 4}))
queue:run(context, {maxSteps = 30})

check("la campagne attend", queue:get(1).status, jobs.PENDING)
checkTruthy("elle dit qui occupe la machine",
            queue:get(1).error and queue:get(1).error:find("Cultivated Queen"))
check("la reine etrangere est intacte",
      world.apiary[oc(0)] and world.apiary[oc(0)].label, "Cultivated Queen")
checkTruthy("aucun cycle vole", world.cycleRuns == 0)

-- Once the machine is free the campaign proceeds on its own
world.apiary[oc(0)] = nil
queue:run(context, {maxSteps = 200})
check("elle repart seule", queue:get(1).status, jobs.COMPLETE)

print("")
print("-- parametres --")

check("espece manquante refusee", (multiply.params({})), nil)
check("objectif nul refuse", (multiply.params({species = "Water", target = 0})), nil)

local derived = multiply.params({species = "Water"})
check("etiquette de princesse deduite", derived.princess.label, "Water Princess")
check("etiquette de drone deduite", derived.drone.label, "Water Drone")
check("objectif par defaut", derived.target, 32)
checkTruthy("plafond de cycles pose", derived.maxCycles > derived.target)

os.remove(QUEUE)

print("")
print("=== Resultats ===")
print("Reussis : " .. passed)
print("Echoues : " .. failed)
print(failed == 0 and "L'accumulation de drones passe." or "Des tests echouent.")

os.exit(failed == 0 and 0 or 1)
