-- HiveMind genetics job tests
--
-- The Sampler has no driver component: the only signal it gives is its output
-- slot filling. The mock behaves the way the real machine did during the probe
-- -- handed a blank sample, a labware and a bee, it went ahead and produced a
-- gene sample, drawing a chromosome at random rather than the one anyone wanted.

package.path = package.path .. ";./?.lua"

local jobs = require("lib.jobs")
local genetics = require("lib.genetics")
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

local SIDE_INTERFACE = config.machines.sampler.source
local SIDE_SAMPLER = config.machines.sampler.machine
local SIDE_TRANSPOSER = config.machines.genetic_transposer.machine
local OFFSET = config.slot_offset

--- Transposer index of a slot the driver calls `driverSlot`
local function oc(driverSlot)
    return driverSlot + OFFSET
end

local world, log

local function reset(options)
    options = options or {}

    world = {
        network = {
            {name = "forestry:bee_drone_ge", label = "Meadows Drone", size = 12},
            {name = "gendustry:gene_sample_blank", label = "Blank Gene Sample", size = 70},
            {name = "gendustry:labware", label = "Genetics Labware", size = 8},
        },
        interface = {},
        sampler = {},
        gtransposer = {},
        collected = {},
        -- The chromosome the machine will draw. Nobody chooses it in game.
        draw = options.draw or "Territory: Average",
        runs = 0,
        starts = options.starts ~= false,
    }

    log = {}
end

-- ---------------------------------------------------------------------------
-- Mocked OpenComputers components
-- ---------------------------------------------------------------------------

local function inventoryFor(side)
    if side == SIDE_INTERFACE then return world.interface end
    if side == SIDE_SAMPLER then return world.sampler end
    if side == SIDE_TRANSPOSER then return world.gtransposer end
    return nil
end

--- The machine works the moment it has everything, as the probe found out the
--- hard way: a Sampler handed a blank, a labware and a bee produced a sample
--- nobody had asked for.
local function tickSampler()
    if world.sampler[oc(3)] then return end          -- output not collected yet
    if not world.starts then return end



    local blank = world.sampler[oc(0)]
    local labware = world.sampler[oc(1)]
    local bee = world.sampler[oc(2)]

    if not (blank and labware and bee) then return end

    -- A campaign hunting one chromosome depends on the draw changing, and it
    -- must change once per CYCLE. Advancing it on every slot read -- which is
    -- what the program does while it waits -- burned the whole list in one go.
    if world.draws then
        world.drawIndex = (world.drawIndex or 0) + 1
        world.draw = world.draws[math.min(world.drawIndex, #world.draws)]
    end

    world.runs = world.runs + 1
    world.sampler[oc(0)] = nil
    world.sampler[oc(1)] = nil
    world.sampler[oc(2)] = nil
    world.sampler[oc(3)] = {name = "gendustry:gene_sample",
                            label = "Bee Sample - " .. world.draw, size = 1}
end

--- The Genetic Transposer copies the source gene into the blank, and keeps the
--- source: that is the whole reason duplication is safe.
local function tickTransposer()
    if world.gtransposer[oc(3)] then return end
    if not world.starts then return end

    local blank = world.gtransposer[oc(0)]
    local labware = world.gtransposer[oc(1)]
    local source = world.gtransposer[oc(2)]

    if not (blank and labware and source) then return end

    world.copies = (world.copies or 0) + 1
    world.gtransposer[oc(0)] = nil
    world.gtransposer[oc(1)] = nil

    -- The source is NOT consumed. That is the whole reason duplication is safe,
    -- and the reason a job cannot clear this slot by running the machine.
    if not world.consumesSource then
        -- keep it in place
    else
        world.gtransposer[oc(2)] = nil
    end

    world.gtransposer[oc(3)] = {name = "gendustry:gene_sample",
                                label = source.label, size = 1}
end

local me = {
    getItemsInNetwork = callable(function(filter)
        local matching = {}
        for _, item in ipairs(world.network) do
            if not filter or not filter.name or item.name == filter.name then
                table.insert(matching, item)
            end
        end
        return matching
    end),
    store = callable(function() return false end),
    setInterfaceConfiguration = callable(function(dock, _, _, size)
        if not size then
            world.interface[dock] = nil
        end
        return true
    end),
    isNetworkPowered = callable(function() return true end),
}

local database = {
    address = "db",
    clear = callable(function() return true end),
    get = callable(function(slot) return world.staged and world.staged[slot] end),
}

local transposerComponent = {
    getInventorySize = callable(function(side)
        if side == SIDE_SAMPLER or side == SIDE_TRANSPOSER then return 4 end
        return inventoryFor(side) and 9 or nil
    end),
    getStackInSlot = callable(function(side, slot)
        if side == SIDE_SAMPLER then tickSampler() end
        if side == SIDE_TRANSPOSER then tickTransposer() end
        local inventory = inventoryFor(side)
        return inventory and inventory[slot] or nil
    end),
    transferItem = callable(function(fromSide, toSide, count, fromSlot, toSlot)
        local from = inventoryFor(fromSide)
        local to = inventoryFor(toSide)
        if not (from and to) then return false end

        local stack = from[fromSlot]
        if not stack then return false end

        if toSide == SIDE_INTERFACE then
            -- Gendustry refuses automated extraction from input slots, exactly
            -- as the Mutatron does. A mock that allowed it made a job asking
            -- for the impossible look correct.
            -- The Sampler refuses extraction from its inputs. Whether the
            -- Genetic Transposer does too is not known, so both are modelled.
            if fromSide == SIDE_SAMPLER and fromSlot ~= oc(3) then
                return false
            end

            if fromSide == SIDE_TRANSPOSER and fromSlot ~= oc(3)
               and not world.transposerReleasesInputs then
                return false
            end

            table.insert(world.collected, stack.label)
            from[fromSlot] = nil
            return true
        end

        -- A real machine takes only what a slot is for. Letting anything land
        -- anywhere would have hidden the whole reason tools/probe exists.
        local ACCEPTS = {
            [oc(0)] = "gendustry:gene_sample_blank",
            [oc(1)] = "gendustry:labware",
            [oc(2)] = "forestry:bee_drone_ge",
        }

        if toSide == SIDE_SAMPLER and ACCEPTS[toSlot] ~= stack.name then
            return false
        end

        local COPIES = {
            [oc(0)] = "gendustry:gene_sample_blank",
            [oc(1)] = "gendustry:labware",
            [oc(2)] = "gendustry:gene_sample",
        }

        if toSide == SIDE_TRANSPOSER and COPIES[toSlot] ~= stack.name then
            return false
        end

        if to[toSlot] then return false end

        to[toSlot] = stack
        from[fromSlot] = nil
        return true
    end),
    store = callable(function() return false end),
}

-- ---------------------------------------------------------------------------

local TMP = (os.getenv("TEMP") or os.getenv("TMPDIR") or "/tmp"):gsub("\\", "/")
local QUEUE = TMP .. "/hivemind-genetics-test.lua"

local ticks = 0

--- Staging is faked: the item appears on the dock, which is what AE2 does
local function stagingLayer()
    local layer = transport.new({
        me = me,
        database = database,
        transposers = {transposerComponent},
        byAddress = {["65d3da44-cb90-4812-a6fa-d28128c9a988"] = transposerComponent},
        interfaces = {[config.machines.sampler.transposer] = me},
        config = {docks = {1, 2}, stock_timeout_seconds = 3, poll_interval_seconds = 0},
        sleep = function() end,
        clock = function() ticks = ticks + 1 return ticks end,
    })

    -- The real stage() goes through the ME database; here the dock simply gets
    -- what was asked for, so the tests exercise the job and not AE2.
    layer.stage = function(self, spec, count, link)
        for _, item in ipairs(world.network) do
            if item.name == spec.name then
                world.interface[1] = {name = item.name, label = item.label, size = 1}
                return 1
            end
        end
        return nil, "introuvable dans le reseau: " .. tostring(spec.name)
    end

    layer.awaitStock = function() return true end

    return layer
end

local function buildStack()
    local layer = stagingLayer()

    local built = machines.all({
        config = config,
        components = {},
        transport = layer,
        sleep = function() end,
        clock = function() ticks = ticks + 1 return ticks end,
    })

    local queue = jobs.new({
        path = QUEUE,
        handlers = {sample = genetics.sampleHandler(),
                    duplicate = genetics.duplicateHandler(),
                    campaign = genetics.campaignHandler()},
        clock = function() ticks = ticks + 1 return ticks end,
        maxAttempts = 2,
    })

    local context = {
        machines = built,
        transport = layer,
        config = config,
        log = function(text) table.insert(log, text) end,
    }

    return queue, context
end

-- ---------------------------------------------------------------------------

print("=== Genetics job tests ===")
print("")
print("-- parametres --")

check("abeille manquante refusee", (genetics.sampleParams({})), nil)
check("abeille sans etiquette refusee",
      (genetics.sampleParams({bee = {name = "forestry:bee_drone_ge"}})), nil)

local defaults = genetics.sampleParams({bee = {label = "Meadows Drone"}})
check("sample vierge par defaut", defaults.blank.name, "gendustry:gene_sample_blank")
check("labware par defaut", defaults.labware.name, "gendustry:labware")
check("nom d'item deduit", defaults.bee.name, "forestry:bee_drone_ge")

print("")
print("-- un gene extrait d'une abeille --")

os.remove(QUEUE)
reset()

local queue, context = buildStack()
queue:submit("sample", genetics.sampleParams({bee = {label = "Meadows Drone"}}))

local outcome = queue:run(context, {maxSteps = 40})

check("tache terminee", queue:get(1).status, jobs.COMPLETE)
check("cinq etapes", outcome.steps, 5)
check("la machine a tourne une fois", world.runs, 1)
check("le sampler est vide a la fin", next(world.sampler), nil)

checkTruthy("le sample part au reseau",
            table.concat(world.collected, ","):find("Bee Sample", 1, true))

-- What the bee gave is the whole point: a campaign decides what to do next
local obtained = queue:get(1).params.obtained
check("chromosome lu", obtained and obtained.chromosome, "Territory")
check("allele lu", obtained and obtained.allele, "Average")
checkTruthy("le journal le dit aussi",
            table.concat(log, " | "):find("Territory = Average", 1, true))

print("")
print("-- le tirage est aleatoire, pas choisi --")

os.remove(QUEUE)
reset({draw = "Species: Cultivated"})

queue, context = buildStack()
queue:submit("sample", genetics.sampleParams({bee = {label = "Meadows Drone"}}))
queue:run(context, {maxSteps = 40})

check("tache terminee quel que soit le gene", queue:get(1).status, jobs.COMPLETE)
check("l'espece est un tirage comme un autre",
      queue:get(1).params.obtained.chromosome, "Species")

print("")
print("-- une machine encombree est videe avant de travailler --")

os.remove(QUEUE)
reset()
-- Left by a previous run: invisible to the ME network, and mistaken for this
-- job's own output if nobody clears it
world.sampler[oc(3)] = {name = "gendustry:gene_sample",
                        label = "Bee Sample - Species: Wintry", size = 1}

queue, context = buildStack()
queue:submit("sample", genetics.sampleParams({bee = {label = "Meadows Drone"}}))
queue:run(context, {maxSteps = 40})

check("tache terminee", queue:get(1).status, jobs.COMPLETE)
checkTruthy("l'ancien sample est rendu au reseau",
            table.concat(world.collected, ","):find("Species: Wintry", 1, true))
check("le gene rapporte est bien le nouveau",
      queue:get(1).params.obtained.chromosome, "Territory")

print("")
print("-- des consommables restes en entree servent au run suivant --")

-- Gendustry will not let anything pull these out, so a job that insisted on an
-- empty machine could never start. They are also exactly what is needed.
os.remove(QUEUE)
reset()
world.sampler[oc(0)] = {name = "gendustry:gene_sample_blank",
                        label = "Blank Gene Sample", size = 1}
world.sampler[oc(1)] = {name = "gendustry:labware",
                        label = "Genetics Labware", size = 1}

queue, context = buildStack()
queue:submit("sample", genetics.sampleParams({bee = {label = "Meadows Drone"}}))
queue:run(context, {maxSteps = 40})

check("tache terminee", queue:get(1).status, jobs.COMPLETE)
check("la machine a tourne", world.runs, 1)
-- Reused, not re-delivered: the network still holds all seventy blanks
check("les consommables en place sont reutilises",
      (function()
          for _, item in ipairs(world.network) do
              if item.name == "gendustry:gene_sample_blank" then return item.size end
          end
      end)(), 70)

print("")
print("-- une entree occupee est consommee, pas signalee a l'operateur --")

-- Nothing can pull an input slot back out, so a job that demanded an empty
-- machine had to ask for a human. Letting the machine eat what is there clears
-- the slot and yields a gene we wanted anyway.
os.remove(QUEUE)
reset()
world.sampler[oc(2)] = {name = "forestry:bee_drone_ge",
                        label = "Wintry Drone", size = 1}

queue, context = buildStack()
queue:submit("sample", genetics.sampleParams({bee = {label = "Meadows Drone"}}))
queue:run(context, {maxSteps = 60})

check("la tache aboutit sans intervention", queue:get(1).status, jobs.COMPLETE)
check("la machine a tourne deux fois", world.runs, 2)
checkTruthy("le travail engage est signale",
            table.concat(log, " | "):find("travail engage a finir", 1, true))
checkTruthy("et son resultat recupere",
            table.concat(log, " | "):find("recupere au passage", 1, true))

-- Two samples reached the network: the intruder's and this job's own
local reached = 0
for _, label in ipairs(world.collected) do
    if label:find("Bee Sample", 1, true) then reached = reached + 1 end
end
check("deux genes recoltes", reached, 2)

print("")
print("-- un consommable manquant fait attendre, pas echouer --")

os.remove(QUEUE)
reset()
world.network = {{name = "forestry:bee_drone_ge", label = "Meadows Drone", size = 1}}

queue, context = buildStack()
queue:submit("sample", genetics.sampleParams({bee = {label = "Meadows Drone"}}))
queue:run(context, {maxSteps = 40})

check("la tache attend", queue:get(1).status, jobs.PENDING)
checkTruthy("elle nomme ce qui manque",
            queue:get(1).error and queue:get(1).error:find("sample vierge"))
check("aucune abeille gaspillee", world.runs, 0)

print("")
print("-- une machine qui ne demarre pas ne bloque pas la file --")

os.remove(QUEUE)
reset({starts = false})

queue, context = buildStack()
queue:submit("sample", genetics.sampleParams({bee = {label = "Meadows Drone"}}))
queue:run(context, {maxSteps = 40})

check("la tache attend", queue:get(1).status, jobs.PENDING)
checkTruthy("le delai est cite",
            queue:get(1).error and queue:get(1).error:find("rien en sortie"))

os.remove(QUEUE)

print("")
print("-- dupliquer un gene, sans perdre la source --")

-- A gene held in one sample is one misplaced click from being gone. This is
-- the point of the whole library: the source must survive the copy.
os.remove(QUEUE)
reset()
table.insert(world.network, {name = "gendustry:gene_sample",
                             label = "Bee Sample - Fertility: 2", size = 1})

queue, context = buildStack()
queue:submit("duplicate", genetics.duplicateParams(
    {sample = {label = "Bee Sample - Fertility: 2"}}))

local report = queue:run(context, {maxSteps = 40})

check("tache terminee", queue:get(1).status, jobs.COMPLETE)
check("cinq etapes", report.steps, 5)
check("la machine a copie une fois", world.copies, 1)
check("la copie porte le meme gene",
      queue:get(1).params.copied, "Bee Sample - Fertility: 2")
checkTruthy("la copie part au reseau",
            table.concat(world.collected, ","):find("Fertility: 2", 1, true))

print("")
print("-- parametres de duplication --")

check("sample manquant refuse", (genetics.duplicateParams({})), nil)
check("sample sans etiquette refuse",
      (genetics.duplicateParams({sample = {name = "gendustry:gene_sample"}})), nil)

local copyDefaults = genetics.duplicateParams({sample = {label = "Bee Sample - Speed: Fast"}})
check("vierge par defaut", copyDefaults.blank.name, "gendustry:gene_sample_blank")
check("nom d'item deduit", copyDefaults.sample.name, "gendustry:gene_sample")

print("")
print("-- un gene absent du reseau fait attendre --")

os.remove(QUEUE)
reset()

queue, context = buildStack()
queue:submit("duplicate", genetics.duplicateParams(
    {sample = {label = "Bee Sample - Species: Ender"}}))
queue:run(context, {maxSteps = 40})

check("la tache attend", queue:get(1).status, jobs.PENDING)
checkTruthy("elle nomme la source manquante",
            queue:get(1).error and queue:get(1).error:find("sample source"))
check("rien n'a ete copie", world.copies, nil)

print("")
print("-- un sample etranger que la machine rend: on continue seul --")

os.remove(QUEUE)
reset()
world.transposerReleasesInputs = true
world.gtransposer[oc(2)] = {name = "gendustry:gene_sample",
                            label = "Bee Sample - Flowering: Slower", size = 1}
table.insert(world.network, {name = "gendustry:gene_sample",
                             label = "Bee Sample - Fertility: 2", size = 1})

queue, context = buildStack()
queue:submit("duplicate", genetics.duplicateParams(
    {sample = {label = "Bee Sample - Fertility: 2"}}))
queue:run(context, {maxSteps = 60})

check("la tache aboutit sans intervention", queue:get(1).status, jobs.COMPLETE)
check("la copie demandee est la bonne",
      queue:get(1).params.copied, "Bee Sample - Fertility: 2")
checkTruthy("l'intrus est rendu au reseau, pas jete",
            table.concat(world.collected, ","):find("Flowering: Slower", 1, true))

print("")
print("-- un sample etranger que rien ne peut sortir: on le dit vite --")

-- The Genetic Transposer keeps its source; that is what makes duplication safe.
-- Running it therefore clears nothing, and running it again clears nothing
-- again. Three passes of that is a loop, not a strategy.
os.remove(QUEUE)
reset()
world.gtransposer[oc(2)] = {name = "gendustry:gene_sample",
                            label = "Bee Sample - Flowering: Slower", size = 1}
table.insert(world.network, {name = "gendustry:gene_sample",
                             label = "Bee Sample - Fertility: 2", size = 1})

queue, context = buildStack()
queue:submit("duplicate", genetics.duplicateParams(
    {sample = {label = "Bee Sample - Fertility: 2"}}))
for _ = 1, 8 do queue:run(context, {maxSteps = 60}) end

check("la tache s'arrete en erreur", queue:get(1).status, jobs.ERROR)
checkTruthy("elle nomme l'intrus et le slot",
            queue:get(1).error and queue:get(1).error:find("Flowering: Slower"))
checkTruthy("et demande un retrait manuel",
            queue:get(1).error and queue:get(1).error:find("a la main"))
checkTruthy("sans tourner en rond indefiniment", (world.copies or 0) <= 4)

print("")
print("-- une campagne s'arrete des que le gene vise sort --")

os.remove(QUEUE)
reset()
world.draws = {"Speed: Slowest", "Fertility: 3", "Species: Meadows", "Speed: Fast"}

queue, context = buildStack()
queue:submit("campaign", genetics.campaignParams({
    bee = {label = "Meadows Drone"}, chromosome = "Species", bees = 10}))
queue:run(context, {maxSteps = 200})

check("tache terminee", queue:get(1).status, jobs.COMPLETE)
check("trois abeilles depensees", queue:get(1).params.spent, 3)
check("la machine a tourne trois fois", world.runs, 3)
check("les tirages rates sont gardes", #queue:get(1).params.obtainedList, 3)
checkTruthy("le gene vise est bien le dernier",
            queue:get(1).params.obtainedList[3]:find("Species", 1, true))

print("")
print("-- un budget epuise n'est pas un echec --")

os.remove(QUEUE)
reset()
world.draws = {"Speed: Slowest", "Speed: Slower", "Speed: Slow"}

queue, context = buildStack()
queue:submit("campaign", genetics.campaignParams({
    bee = {label = "Meadows Drone"}, chromosome = "Species", bees = 3}))
queue:run(context, {maxSteps = 200})

-- Three genes went into the library; calling that a failure would hide it
check("tache terminee, pas en erreur", queue:get(1).status, jobs.COMPLETE)
check("le budget est respecte", queue:get(1).params.spent, 3)
check("trois genes recoltes quand meme", #queue:get(1).params.obtainedList, 3)

print("")
print("-- sans cible, la campagne recolte jusqu'au budget --")

os.remove(QUEUE)
reset()
world.draws = {"Speed: Fast", "Fertility: 4", "Territory: Large"}

queue, context = buildStack()
queue:submit("campaign", genetics.campaignParams({
    bee = {label = "Meadows Drone"}, bees = 3}))
queue:run(context, {maxSteps = 200})

check("tache terminee", queue:get(1).status, jobs.COMPLETE)
check("trois abeilles depensees", queue:get(1).params.spent, 3)
check("trois genes differents", #queue:get(1).params.obtainedList, 3)

print("")
print("-- parametres de campagne --")

check("abeille manquante refusee", (genetics.campaignParams({})), nil)
check("budget nul refuse",
      (genetics.campaignParams({bee = {label = "X Drone"}, bees = 0})), nil)

local campaignDefaults = genetics.campaignParams({bee = {label = "X Drone"}})
check("budget par defaut", campaignDefaults.budget, 13)
check("aucune cible par defaut", campaignDefaults.chromosome, nil)

print("")
print("-- un intrus arrive APRES l'etape de deblocage --")

-- Seen in game: job #13 sat at the loading step while another job left its
-- sample in the source slot. It never goes back to the clearing step, so it
-- reported "retire-le a la main" while the job right behind it freed the very
-- same slot without trouble.
os.remove(QUEUE)
reset()
world.transposerReleasesInputs = true
table.insert(world.network, {name = "gendustry:gene_sample",
                             label = "Bee Sample - Fertility: 2", size = 1})

queue, context = buildStack()
local jobId = queue:submit("duplicate", genetics.duplicateParams(
    {sample = {label = "Bee Sample - Fertility: 2"}}))

-- Past the clearing step, with the source slot still empty
queue:step(queue:get(jobId), context)
queue:step(queue:get(jobId), context)
check("la tache est bien a l'etape de chargement", queue:get(jobId).step, 3)

-- Now someone else's sample lands in it
world.gtransposer[oc(2)] = {name = "gendustry:gene_sample",
                            label = "Bee Sample - Territory: Average", size = 1}

queue:run(context, {maxSteps = 60})

check("la tache aboutit quand meme", queue:get(jobId).status, jobs.COMPLETE)
check("et copie bien ce qu'on lui demandait",
      queue:get(jobId).params.copied, "Bee Sample - Fertility: 2")
checkTruthy("l'intrus est rendu au reseau",
            table.concat(world.collected, ","):find("Territory: Average", 1, true))

print("")
print("=== Resultats ===")
print("Reussis : " .. passed)
print("Echoues : " .. failed)
print(failed == 0 and "Les jobs de genetique passent." or "Des tests echouent.")

os.exit(failed == 0 and 0 or 1)
