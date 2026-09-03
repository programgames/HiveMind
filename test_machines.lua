-- HiveMind machine layer tests
--
-- Mocks follow what the live game returned: callable-table methods, the exact
-- listSlots shapes, real NBT for getBees, and the error list an unconfigured
-- apiary actually produces ("forestry:too_hot", "forestry:no_sky", ...).

package.path = package.path .. ";./?.lua"

local machines = require("lib.machines")
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

local WINTRY = '{IsAnalyzed:0b,Health:30,MaxH:30,Genome:{Chromosomes:['
    .. '{Slot:0b,UID0:"forestry.speciesWintry",UID1:"forestry.speciesWintry"},'
    .. '{Slot:1b,UID0:"forestry.speedSlower",UID1:"forestry.speedSlower"}]}}'

local COMMON = '{IsAnalyzed:0b,Genome:{Chromosomes:['
    .. '{Slot:0b,UID0:"forestry.speciesCommon",UID1:"forestry.speciesCommon"}]}}'

local state

local function reset()
    state = {
        mutagen = 8000,
        energy = 20000,
        maxEnergy = 20000,
        errors = {},
        automated = false,
        produced = nil,
        princessWaited = false,
        slots = {},
    }
end

local mutatron_component = {
    listSlots = callable(function()
        return {in1 = 0, in2 = 1, output = 2, labware = 3, selectors = {4, 5, 6, 7, 8, 9}}
    end),
    getTank = callable(function()
        return {amount = state.mutagen, capacity = 10000}
    end),
    canStart = callable(function() return state.mutagen > 0 end),
    getEnergyStored = callable(function() return state.energy end),
    getMaxEnergyStored = callable(function() return state.maxEnergy end),
    listMutations = callable(function()
        return {{index = 1, key = 4, name = "forestry:bee_queen_ge",
                 label = "Common Queen", nbt = COMMON}}
    end),
    selectAndProduce = callable(function(index, timeout)
        if state.mutagen <= 0 then return false, "reservoir vide" end
        state.mutagen = state.mutagen - 1000
        state.produced = {name = "forestry:bee_queen_ge", label = "Common Queen", count = 1}
        return true, state.produced
    end),
    getOutput = callable(function() return state.produced end),
}

local apiary_component = {
    listSlots = callable(function()
        return {queen = 0, drone = 1, upgrades = {2, 3, 4, 5},
                outputs = {6, 7, 8, 9, 10, 11, 12, 13, 14}}
    end),
    getBees = callable(function()
        return {
            queen = {name = "forestry:bee_queen_ge", label = "Wintry Queen",
                     nbt = WINTRY, count = 1},
            drone = {name = "forestry:bee_drone_ge", label = "Common Drone",
                     nbt = COMMON, count = 6},
        }
    end),
    listOutputs = callable(function()
        return {{name = "forestry:bee_drone_ge", label = "Wintry Drone",
                 count = 3, slot = 6}}
    end),
    getErrors = callable(function()
        return {hasErrors = #state.errors > 0, errors = state.errors}
    end),
    getModifiers = callable(function()
        return {production = 1.0, isAutomated = state.automated}
    end),
    getEnergyStored = callable(function() return state.energy end),
    getMaxEnergyStored = callable(function() return state.maxEnergy end),
    waitForPrincess = callable(function(timeout)
        if state.automated then return false, "upgrade Automation presente" end
        state.princessWaited = true
        return true
    end),
}

local MOVES = {}
local fakeTransport = {
    inspect = function(_, link, slot) return state.slots[slot] end,
    deliver = function(_, spec, link, slot, count)
        table.insert(MOVES, {spec = spec, slot = slot, count = count})
        state.slots[slot] = {label = spec.label}
        return true
    end,
    retrieve = function(_, link, slot, count)
        if not state.slots[slot] then return 0 end
        state.slots[slot] = nil
        return count or 1
    end,
}

local ticks = 0
local waits = {}

local function build(component, link)
    return machines.new({
        name = "test",
        component = component,
        link = link,
        transport = fakeTransport,
        config = {energy = {complain_after_seconds = 2, minimum_ratio = 0.05}},
        sleep = function() end,
        clock = function() ticks = ticks + 1 return ticks end,
        onWait = function(name, status, elapsed) table.insert(waits, status) end,
    })
end

reset()

print("=== Machine layer tests ===")
print("")
print("-- Advanced Mutatron --")

local mutatron = build(mutatron_component, config.machines.mutatron)

local slots = mutatron:slots()
check("slots demandes a la machine", slots.output, 2)
check("selecteurs lus", #slots.selectors, 6)

local amount, capacity = mutatron:tank()
check("mutagene lu", amount, 8000)
check("capacite lue", capacity, 10000)
check("machine prete", (mutatron:isReady()), machines.READY)

local mutations = mutatron:mutations()
check("une mutation proposee", #mutations, 1)
check("etiquette lue", mutations[1].label, "Common Queen")
-- listMutations carries the full genome of the result, so the plan can be
-- checked against the machine instead of against our own table
check("genome du resultat analyse", mutations[1].genome ~= nil, true)
checkTruthy("mutation retrouvee par espece",
            mutatron:mutationFor("forestry.speciesCommon"))
check("espece absente", mutatron:mutationFor("forestry.speciesEnder"), nil)

local produced, produce_err = mutatron:produce(1)
checkTruthy("production reussie (" .. tostring(produce_err) .. ")", produced)
check("sortie rapportee", produced and produced.label, "Common Queen")
check("mutagene consomme", select(1, mutatron:tank()), 7000)

print("")
print("-- Mutatron a sec --")

reset()
state.mutagen = 0
mutatron = build(mutatron_component, config.machines.mutatron)

local status, detail = mutatron:isReady()
check("manque de ressource detecte", status, machines.NO_RESOURCE)
checkTruthy("raison lisible", detail and detail:find("mutagene"))
check("production refusee", (mutatron:produce(1)), nil)

print("")
print("-- Industrial Apiary --")

reset()
local apiary = build(apiary_component, config.machines.breeding_apiary)

check("slot de la reine", apiary:slots().queen, 0)
check("neuf slots de sortie", #apiary:slots().outputs, 9)

local bees = apiary:bees()
checkTruthy("reine lue", bees.queen)
check("etiquette de la reine", bees.queen.label, "Wintry Queen")
-- Parking a bee in a machine slot is the only way to read a genome at all
check("genome de la reine analyse", bees.queen.genome ~= nil, true)
check("espece de la reine", apiary:speciesIn("queen"), "forestry.speciesWintry")
check("espece du drone", apiary:speciesIn("drone"), "forestry.speciesCommon")
check("role absent", apiary:speciesIn("princess"), nil)

check("une sortie non vide", #apiary:outputs(), 1)
check("slot de sortie", apiary:outputs()[1].slot, 6)

checkTruthy("attente de la princesse", apiary:awaitPrincess(10))
check("waitForPrincess appele", state.princessWaited, true)

print("")
print("-- Apiary en erreur --")

reset()
state.errors = {"forestry:too_hot", "forestry:no_sky", "forestry:no_flower"}
apiary = build(apiary_component, config.machines.breeding_apiary)

local apiary_status, apiary_detail = apiary:isReady()
check("erreurs remontees", apiary_status, machines.ERROR)
checkTruthy("erreurs listees", apiary_detail and apiary_detail:find("no_flower"))

print("")
print("-- l'upgrade Automation casse waitForPrincess --")

reset()
state.automated = true
apiary = build(apiary_component, config.machines.breeding_apiary)

check("automation detectee", apiary:isAutomated(), true)
local waited, wait_err = apiary:awaitPrincess(5)
check("attente refusee", waited, false)
checkTruthy("raison rapportee", wait_err and wait_err:find("Automation"))

print("")
print("-- energie --")

reset()
state.energy = 100          -- 0.5% of the buffer
local starved = build(mutatron_component, config.machines.mutatron)

local stored, maximum, ratio = starved:energy()
check("energie lue", stored, 100)
check("maximum lu", maximum, 20000)
check("ratio calcule", ratio and ratio < 0.01, true)
check("machine consideree hors service", (starved:isReady()), machines.NO_ENERGY)

waits = {}
local ready, ready_reason = starved:awaitReady({timeout = 5, interval = 0})
check("attente abandonnee au bout du delai", ready, false)
checkTruthy("raison rendue", ready_reason)
-- The agreed policy: wait silently, then speak up once it drags on
checkTruthy("attente longue signalee", #waits > 0)

print("")
print("-- machine sans composant --")

reset()
local dumb = build(nil, config.machines.sampler)

-- No buffer to read means no reason to block the queue
check("energie inconnue", (dumb:energy()), nil)
check("machine consideree utilisable", (dumb:isReady()), machines.READY)

MOVES = {}
checkTruthy("chargement via le transport",
            dumb:load({label = "Bee Sample - Species: Cultivated"}, 1))
check("un mouvement enregistre", #MOVES, 1)
check("slot vise", MOVES[1].slot, 1)
check("slot relu", dumb:slot(1).label, "Bee Sample - Species: Cultivated")
check("dechargement", dumb:unload(1, 1), 1)
check("slot vide apres dechargement", dumb:slot(1), nil)

state.slots[6] = {label = "Wintry Drone"}
state.slots[7] = {label = "Honey Comb"}
local drained = dumb:drain({6, 7, 8})
check("vidage groupe", drained, 2)

print("")
print("-- construction depuis la configuration --")

reset()
local built, missing = machines.all({
    config = config,
    components = {advmutatron = mutatron_component},
    transport = fakeTransport,
    sleep = function() end,
    clock = function() ticks = ticks + 1 return ticks end,
})

-- The configuration now describes the real installation: only the Mutatron and
-- the breeding apiary are built, the genetics machines are declared but
-- disabled until they exist in the world.
checkTruthy("mutatron construit", built.mutatron)
checkTruthy("apiary construit", built.breeding_apiary)
check("sampler pas encore installe", built.sampler, nil)
check("machine desactivee ignoree", built.production_apiary, nil)
-- A missing component must not prevent item moves on that machine
check("composant manquant signale", missing[1], "breeding_apiary")
check("le mutatron a bien le bon driver", built.mutatron:tank(), 8000)

-- The real topology, as discovered in game
check("mutatron sur la face est/gauche", config.machines.mutatron.machine, 5)
check("apiary sur la face sud/avant", config.machines.breeding_apiary.machine, 3)
check("source commune = ME Interface", config.machines.mutatron.source, 2)
check("coffre a templates sur ouest/droite", config.template_chest.side, 4)
check("un transposer declare", #config.transposers, 1)

print("")
print("=== Resultats ===")
print("Reussis : " .. passed)
print("Echoues : " .. failed)
print(failed == 0 and "Tous les tests des machines passent." or "Des tests echouent.")

os.exit(failed == 0 and 0 or 1)
