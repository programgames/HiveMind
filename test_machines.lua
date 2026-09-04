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
    .. '{Slot:1b,UID0:"forestry.speedSlower",UID1:"forestry.speedSlower"},'
    -- Chromosome 9 is the flower the apiary will demand
    .. '{Slot:9b,UID0:"forestry.flowersVanilla",UID1:"forestry.flowersVanilla"}]}}'

local COMMON = '{IsAnalyzed:0b,Genome:{Chromosomes:['
    .. '{Slot:0b,UID0:"forestry.speciesCommon",UID1:"forestry.speciesCommon"},'
    .. '{Slot:9b,UID0:"forestry.flowersCacti",UID1:"forestry.flowersCacti"}]}}'

local state

local function reset()
    state = {
        mutagen = 8000,
        energy = 20000,
        maxEnergy = 20000,
        errors = {},
        empty = false,
        automated = false,
        canStart = false,
        progress = 0,
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
    -- Reads false until a mutation is selected, which is the idle state
    canStart = callable(function() return state.canStart == true end),
    getProgress = callable(function() return state.progress or 0 end),
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
        if state.empty then return {} end
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

-- Reported from the game: a full tank with canStart() false must read as ready.
-- canStart is documented to answer false before a mutation is selected, so
-- gating on it made an idle machine look broken and retried forever.
check("canStart faux n'empeche pas d'etre pret", (mutatron:isReady()), machines.READY)
check("canStart reste consultable", mutatron:canStart(), false)

-- A production actually under way is a real reason to wait
state.progress = 0.4
check("production en cours = occupe", (mutatron:isReady()), machines.BUSY)
state.progress = 1.0
check("progression a 1 = machine libre", (mutatron:isReady()), machines.READY)
state.progress = 0

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

-- The queen slot emptying is what ends a cycle. Polling it ourselves is the
-- only thing that works: OpenComputers aborts a component call that blocks, so
-- the driver's own waitForPrincess answered "timeout" within seconds however
-- long a delay it was given, and a campaign never got past its first cycle.
state.slots[0] = nil
checkTruthy("cycle fini quand le slot reine se vide", apiary:awaitPrincess(10))
check("le driver n'est plus sollicite", state.princessWaited, false)

state.slots[0] = {label = "Wintry Queen", size = 1}
local stillAlive, aliveReason = apiary:awaitPrincess(5)
check("reine vivante: attente refusee", stillAlive, false)
checkTruthy("la raison dit qu'elle vit encore",
            aliveReason and aliveReason:find("vit encore"))
state.slots[0] = nil

print("")
print("-- Apiary en erreur --")

reset()
state.errors = {"forestry:too_hot", "forestry:no_sky", "forestry:no_flower"}
apiary = build(apiary_component, config.machines.breeding_apiary)

local apiary_status, apiary_detail = apiary:isReady()
check("erreurs remontees quand une abeille est dedans", apiary_status, machines.ERROR)
checkTruthy("erreurs listees", apiary_detail and apiary_detail:find("no_flower"))

-- Environmental complaints depend on the bee inside: a Wintry queen reports
-- too_hot exactly where a Forest one works. Blocking on an empty apiary would
-- stall the queue over a bee we have not loaded yet.
reset()
state.empty = true
state.errors = {"forestry:too_hot", "forestry:no_flower"}
apiary = build(apiary_component, config.machines.breeding_apiary)
check("apiary vide considere utilisable", (apiary:isReady()), machines.READY)
check("les erreurs restent consultables", #apiary:environmentErrors(), 2)

-- An error that only says "nothing loaded" is never a blocker
reset()
state.errors = {"forestry:no_queen"}
apiary = build(apiary_component, config.machines.breeding_apiary)
check("absence d'abeille n'est pas une panne", (apiary:isReady()), machines.READY)
check("elle n'apparait pas comme erreur d'environnement",
      #apiary:environmentErrors(), 0)

-- A real problem alongside a benign one must still come through
reset()
state.errors = {"forestry:no_drone", "forestry:no_sky"}
apiary = build(apiary_component, config.machines.breeding_apiary)
local mixed_status, mixed_detail = apiary:isReady()
check("le vrai probleme est retenu", mixed_status, machines.ERROR)
check("seul le vrai probleme est cite", mixed_detail, "forestry:no_sky")

print("")
print("-- l'upgrade Automation --")

reset()
state.automated = true
apiary = build(apiary_component, config.machines.breeding_apiary)

check("automation detectee", apiary:isAutomated(), true)

-- The upgrade is what broke the driver's waitForPrincess, and the warning in
-- the status screen exists for it. Polling the slot no longer goes through that
-- call, so the wait itself works; the warning stays, because automation also
-- empties the outputs before the harvest step can read them.
state.slots[0] = nil
checkTruthy("l'attente ne depend plus du driver", apiary:awaitPrincess(5))

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

-- The configuration describes the real installation. The Mutatron and the
-- breeding apiary have drivers; the genetics bench has none and is driven
-- entirely through its slots, which is why it must still be built here.
checkTruthy("mutatron construit", built.mutatron)
checkTruthy("apiary construit", built.breeding_apiary)

for _, name in ipairs({"sampler", "genetic_transposer", "imprinter"}) do
    checkTruthy(name .. " construit sans driver", built[name])
end

-- No component means no energy buffer to read. Answering "not ready" to that
-- would deadlock every job that touches these machines.
check("une machine sans driver est prete", (built.sampler:isReady()), machines.READY)

check("machine desactivee ignoree", built.production_apiary, nil)
-- A missing component must not prevent item moves on that machine
check("composant manquant signale", missing[1], "breeding_apiary")
check("le mutatron a bien le bon driver", built.mutatron:tank(), 8000)

-- The real topology, as discovered in game
check("mutatron sur la face est/gauche", config.machines.mutatron.machine, 5)
check("apiary sur la face sud/avant", config.machines.breeding_apiary.machine, 3)
check("source commune = ME Interface", config.machines.mutatron.source, 2)
check("coffre a templates sur ouest/droite", config.template_chest.side, 4)
-- Machines name their transposer by address, never by position. A third
-- transposer joining the network renumbered every other one and would have
-- aimed each machine at the wrong neighbour, silently.
checkTruthy("aucune machine ne designe un transposer par position", (function()
    for _, name in ipairs(config.enabledMachines()) do
        if type(config.machines[name].transposer) ~= "string" then return false end
    end
    return type(config.template_chest.transposer) == "string"
end)())

check("les trois machines de genetique partagent un transposer",
      config.machines.sampler.transposer, config.machines.imprinter.transposer)
check("le mutatron est sur l'autre", config.machines.mutatron.transposer,
      config.machines.breeding_apiary.transposer)
checkTruthy("et ce ne sont pas les memes",
            config.machines.sampler.transposer ~= config.machines.mutatron.transposer)
check("le coffre a templates suit l'apiary", config.template_chest.transposer,
      config.machines.breeding_apiary.transposer)
check("la source des machines de genetique", config.machines.imprinter.source, 4)

-- Supplying a dock only works on the interface that dock belongs to. Getting
-- this wrong makes the item never arrive, and the failure reads as "the machine
-- refuses this item" -- so a machine that can receive things must have one.
checkTruthy("chaque machine approvisionnee a une interface declaree", (function()
    for _, name in ipairs(config.enabledMachines()) do
        local link = config.machines[name]

        -- A machine with no source is never delivered to; only its tank is
        -- read, and that needs no interface at all
        if link.source ~= nil and not config.interfaces[link.transposer] then
            return false
        end
    end
    return true
end)())

-- Two benches sharing one interface address would silently stage into the
-- wrong one, and only one of the two would ever work
checkTruthy("aucune interface n'est declaree deux fois", (function()
    local seen = {}
    for _, address in pairs(config.interfaces) do
        if seen[address] then return false end
        seen[address] = true
    end
    return true
end)())

-- Every declared address must actually appear in the transposer list, or the
-- lookup finds nothing and the machine is unreachable
checkTruthy("chaque adresse citee existe", (function()
    for _, name in ipairs(config.enabledMachines()) do
        local wanted = config.machines[name].transposer
        local found = false
        for _, address in ipairs(config.transposers) do
            if address:sub(1, #wanted) == wanted then found = true end
        end
        if not found then return false end
    end
    return true
end)())

-- The genetics machines hold four slots, driver 0 to 3. The documentation put
-- labware at 3 and an output at 4: a slot that does not exist, where every
-- delivery would have vanished without an error.
for _, name in ipairs({"sampler", "genetic_transposer", "imprinter"}) do
    local slots = config.machines[name].slots
    local worst = -1
    for _, index in pairs(slots) do
        if type(index) == "number" and index > worst then worst = index end
    end
    checkTruthy(name .. ": aucun slot hors de l'inventaire", worst <= 3)
    checkTruthy(name .. ": labware au driver 1", slots.labware == 1)
end

print("")
print("-- la fleur exigee par l'abeille chargee --")

-- An apiary that lacks the right flower complains "no flower" and never says
-- which one. The genome does, and reading it turns a hunt into a two-minute fix.
reset()
state.slots = {}
apiary = build(apiary_component, config.machines.breeding_apiary)

local allele, flowerName = apiary:flowerRequirement()
check("allele brut lu", allele, "forestry.flowersVanilla")
check("nom lisible", flowerName, "Vanilla")

check("role explicite respecte", (apiary:flowerRequirement("drone")),
      "forestry.flowersCacti")

state.empty = true
check("aucune abeille chargee: rien a dire", (apiary:flowerRequirement()), nil)
state.empty = false

print("")
print("-- aucun appel de driver ne bloque le serveur --")

-- A component call does not block this computer, it blocks the SERVER: the
-- world stops until it returns. Handing waitForPrincess a 900 s budget froze
-- the host until the watchdog killed it and Julien had to restart the machine.
-- Both waiting calls now take a short fixed budget and the result is polled.
local source = assert(io.open("lib/machines.lua", "r"))
local machineText = source:read("*all")
source:close()

local blocking = {}
for call, argument in machineText:gmatch('"(waitForPrincess)"%s*,%s*([%w_%.]+)') do
    table.insert(blocking, call .. " <- " .. argument)
end
for call, argument in machineText:gmatch('"(selectAndProduce)"[^)]-,%s*([%w_%.]+)%s*%)') do
    local budget = tonumber(argument)
    if budget == nil or budget > 5 then
        table.insert(blocking, call .. " <- " .. argument)
    end
end

check("aucun appel bloquant a delai long", #blocking, 0)
if #blocking > 0 then print("         " .. table.concat(blocking, ", ")) end

checkTruthy("l'attente de la reine sonde le slot",
            machineText:find("self:slot(slots.queen)", 1, true))
checkTruthy("la production sonde la sortie",
            machineText:find("local produced = self:output()", 1, true))

print("")
print("=== Resultats ===")
print("Reussis : " .. passed)
print("Echoues : " .. failed)
print(failed == 0 and "Tous les tests des machines passent." or "Des tests echouent.")

os.exit(failed == 0 and 0 or 1)
