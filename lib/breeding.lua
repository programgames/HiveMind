-- HiveMind breeding job
--
-- The full cycle, as seven steps the queue can stop in the middle of:
--
--   1. empty the Mutatron output      5. move the queen to the apiary
--   2. supply labware                 6. wait for the queen to die
--   3. load the two parents           7. collect princess and drones
--   4. force the mutation
--
-- Every step declares verify() before run(), so the recorded step number is
-- only a hint about where to look. Crash between "the Mutatron produced a
-- queen" and "I wrote that down" and step 4 sees the queen in the output slot
-- and skips, instead of spending a second dose of mutagen.
--
-- Waiting is never failing. No power, no mutagen, an apiary that cannot host
-- the bee: all answer RETRY, which leaves the job pending with its reason
-- instead of burning attempts.

local jobs = require("lib.jobs")
local upgrades = require("lib.upgrades")
local genome = require("lib.genome")

local breeding = {}

--- Species of the bee in a machine slot, read through the transposer
--- The label is all an ordinary slot exposes, so this compares labels; genomes
--- are only readable in the two machines that have a driver.
--- @param machine table
--- @param slot number
--- @return string|nil label
local function labelInSlot(machine, slot)
    local stack = machine:slot(slot)
    return stack and stack.label or nil
end

--- Report progress without ever letting the reporter break the job
local function report(context, text)
    if context and type(context.log) == "function" then
        pcall(context.log, text)
    end
end

--- Machine lookup that fails loudly rather than indexing nil later
--- @param context table
--- @param name string
--- @return table|nil machine
--- @return string|nil error
local function machineOf(context, name)
    local machine = context and context.machines and context.machines[name]
    if not machine then
        return nil, "machine indisponible: " .. name
    end
    return machine
end

--- Display name of a species uid, as an item label spells it
--- The plan works in uids ("forestry.speciesCultivated") and the network works
--- in labels ("Cultivated Drone"). Getting this wrong queues a hunt for a bee
--- that does not exist under that name.
--- @param context table
--- @param uid string|nil
--- @return string|nil name
local function displayName(context, uid)
    if type(uid) ~= "string" or uid == "" then return nil end

    local registry = context and context.species
    if registry and type(registry.list) == "function" then
        local ok, all = pcall(registry.list, registry)
        if ok and type(all) == "table" and all[uid] and all[uid].name then
            return all[uid].name
        end
    end

    -- A uid with no dot is already a display name, which is what the bundled
    -- fallback table uses
    if not uid:find("%.") then return uid end

    return nil
end

--- How many drones of a species the network holds
--- @param context table
--- @param name string
--- @return number count
local function droneStock(context, name)
    if not context or not context.transport then return 0 end

    local wanted = name .. " Drone"
    local count = 0

    local ok, items = pcall(function()
        return context.transport:findAll({name = "forestry:bee_drone_ge"})
    end)

    if not ok or type(items) ~= "table" then return 0 end

    for _, item in ipairs(items) do
        if item.label == wanted then count = count + (tonumber(item.size) or 0) end
    end

    return count
end

--- Is a hunt for this species' gene already queued
--- Queueing it twice spends a second batch of drones on a gene already coming.
--- @param context table
--- @param name string
--- @return boolean
local function alreadyHunting(context, name)
    if not context or not context.queue then return false end

    local ok, list = pcall(function() return context.queue:list() end)
    if not ok or type(list) ~= "table" then return false end

    for _, job in ipairs(list) do
        if job.kind == "campaign" and job.status ~= "complete"
           and job.status ~= "cancelled" and job.params
           and job.params.bee and job.params.bee.label == (name .. " Drone") then
            return true
        end
    end

    return false
end

--- Is the machine able to work right now
--- An empty tank is ambiguous, and the two readings need opposite answers. The
--- Mutagen Producer refills the Mutatron on its own when it is fed, so a tank
--- momentarily dry resolves itself and RETRY is right. A producer with nothing
--- to work from never refills anything, and the job would sit aside for ever
--- without ever saying what to go and do.
---
--- Rather than reach into another machine to tell them apart, this counts: a
--- tank still dry after three passes is not refilling.
--- @param machine table
--- @param job table Carries the count between passes, on disk
--- @return string|nil retry Reason to come back later, nil when ready
--- @return boolean gesture True when waiting has stopped being reasonable
local function notReady(machine, job)
    local status, detail = machine:isReady()

    if status == "ready" then
        job.params.dryPasses = nil
        return nil, false
    end

    local machines = require("lib.machines")

    if status ~= machines.NO_RESOURCE then
        job.params.dryPasses = nil
        return detail or status, false
    end

    job.params.dryPasses = (job.params.dryPasses or 0) + 1

    return detail or status, job.params.dryPasses >= 3
end

breeding.STEPS = {
    -- -----------------------------------------------------------------------
    {
        name = "vider-la-sortie-du-mutatron",
        -- A queen left from a previous run would be mistaken for ours
        verify = function(job, context)
            local mutatron = machineOf(context, "mutatron")
            if not mutatron then return false end
            return mutatron:slot(mutatron:slots().output) == nil
        end,
        run = function(job, context)
            local mutatron, err = machineOf(context, "mutatron")
            if not mutatron then return jobs.FAILED, err end

            mutatron:unload(mutatron:slots().output)

            if mutatron:slot(mutatron:slots().output) then
                return jobs.RETRY, "la sortie du Mutatron ne se vide pas"
            end

            return jobs.DONE
        end,
    },

    -- -----------------------------------------------------------------------
    {
        name = "fournir-le-labware",
        verify = function(job, context)
            local mutatron = machineOf(context, "mutatron")
            if not mutatron then return false end
            return mutatron:slot(mutatron:slots().labware) ~= nil
        end,
        run = function(job, context)
            local mutatron, err = machineOf(context, "mutatron")
            if not mutatron then return jobs.FAILED, err end

            local spec = job.params.labware or {name = "gendustry:labware"}
            local ok, reason = mutatron:load(spec, mutatron:slots().labware, 1)

            if not ok then
                -- Missing labware is a supply problem, not a broken plan, and
                -- not something the program can solve on its own either
                return jobs.NEEDS_PLAYER,
                    "mets du labware dans le reseau ME (" .. tostring(reason) .. ")"
            end

            return jobs.DONE
        end,
    },

    -- -----------------------------------------------------------------------
    {
        name = "charger-les-parents",
        verify = function(job, context)
            local mutatron = machineOf(context, "mutatron")
            if not mutatron then return false end

            local slots = mutatron:slots()
            return labelInSlot(mutatron, slots.in1) == job.params.princess.label
               and labelInSlot(mutatron, slots.in2) == job.params.drone.label
        end,
        run = function(job, context)
            local mutatron, err = machineOf(context, "mutatron")
            if not mutatron then return jobs.FAILED, err end

            local slots = mutatron:slots()

            -- A previous job that stalled here leaves its own parent behind.
            -- Two different bees do not stack, so the delivery silently moves
            -- nothing and the failure is reported as "indisponible" for a bee
            -- that is sitting in the network all along. Clear the slot first.
            local function place(spec, slot, role)
                local occupant = labelInSlot(mutatron, slot)
                if occupant == spec.label then return true end

                if occupant then
                    mutatron:unload(slot)
                    if labelInSlot(mutatron, slot) then
                        -- Gendustry machines refuse extraction from their input
                        -- slots, so nothing automated can clear this. Naming the
                        -- slot the player actually sees is the whole point.
                        return false, "retire " .. tostring(occupant)
                            .. " du slot " .. mutatron:resolveSlot(slot)
                            .. " du Mutatron (il occupe la place " .. role .. ")",
                            true
                    end
                end

                local ok, reason = mutatron:load(spec, slot, 1)
                if not ok then
                    return false, "mets " .. tostring(spec.label or role)
                        .. " dans le reseau ME (" .. tostring(reason) .. ")",
                        true
                end

                return true
            end

            -- place() says whether what stops it is a chore or a wait: a slot
            -- the Mutatron refuses to give back and a bee the network does not
            -- hold both need a hand, and neither clears itself with time.
            local placed, why, gesture = place(job.params.princess, slots.in1, "princesse")
            if not placed then
                return gesture and jobs.NEEDS_PLAYER or jobs.RETRY, why
            end

            placed, why, gesture = place(job.params.drone, slots.in2, "drone")
            if not placed then
                return gesture and jobs.NEEDS_PLAYER or jobs.RETRY, why
            end

            return jobs.DONE
        end,
    },

    -- -----------------------------------------------------------------------
    {
        name = "forcer-la-mutation",
        verify = function(job, context)
            local mutatron = machineOf(context, "mutatron")
            if not mutatron then return false end

            -- The output carries a full genome, so this checks the species
            -- actually produced rather than merely that something appeared
            local stack = mutatron:output()
            if not stack or not stack.nbt then return false end

            local produced = genome.parse(stack.nbt)
            return produced ~= nil and genome.species(produced) == job.params.target
        end,
        run = function(job, context)
            local mutatron, err = machineOf(context, "mutatron")
            if not mutatron then return jobs.FAILED, err end

            local wait, gesture = notReady(mutatron, job)
            if wait then
                if gesture then
                    return jobs.NEEDS_PLAYER, wait .. " depuis trois passages:"
                        .. " alimente le Mutagen Producer, il ne se remplit plus"
                end
                return jobs.RETRY, wait
            end

            -- Ask the machine which mutations the loaded parents allow. This is
            -- the game's own answer, so an impossible plan is caught here
            -- instead of failing silently with no explanation.
            local mutation = mutatron:mutationFor(job.params.target)

            if not mutation then
                local offered = {}
                for _, candidate in ipairs(mutatron:mutations()) do
                    table.insert(offered, candidate.label or candidate.name or "?")
                end

                return jobs.FAILED, "le Mutatron ne propose pas " .. tostring(job.params.target)
                    .. " avec ces parents (propose: "
                    .. (#offered > 0 and table.concat(offered, ", ") or "rien") .. ")"
            end

            report(context, "mutation " .. tostring(mutation.label or job.params.target))

            -- Measured in game: sixty seconds was not enough and the step timed
            -- out on a machine that then finished on its own. Harmless, since
            -- verify() picks the queen up on the next pass, but noisy.
            local produced, produce_err = mutatron:produce(mutation.index or 1,
                                                          job.params.timeout or 180)
            if not produced then
                return jobs.RETRY, tostring(produce_err)
            end

            return jobs.DONE
        end,
    },

    -- -----------------------------------------------------------------------
    {
        name = "transferer-la-reine",
        verify = function(job, context)
            local apiary = machineOf(context, "breeding_apiary")
            if not apiary then return false end
            return apiary:speciesIn("queen") == job.params.target
        end,
        run = function(job, context)
            local mutatron, mutatron_err = machineOf(context, "mutatron")
            if not mutatron then return jobs.FAILED, mutatron_err end

            local apiary, apiary_err = machineOf(context, "breeding_apiary")
            if not apiary then return jobs.FAILED, apiary_err end

            local wait, gesture = notReady(apiary, job)
            if wait then
                if gesture then
                    return jobs.NEEDS_PLAYER, "l apiary est bloque depuis trois"
                        .. " passages: " .. wait
                end
                return jobs.RETRY, wait
            end

            local queen_slot = apiary:slots().queen
            if apiary:slot(queen_slot) then
                return jobs.RETRY, "le slot reine de l'apiary est deja occupe"
            end

            local transport = context.transport
            if not transport then return jobs.FAILED, "aucune couche de transport" end

            -- Straight from machine to machine: sending the queen back through
            -- the ME network would lose track of which queen is ours, since
            -- AE2 shows no genome.
            --
            -- Both indices go through resolveSlot: these are the driver's
            -- numbers, and the transposer counts differently.
            local moved, reason = transport:transferBetween(
                mutatron.link, mutatron:resolveSlot(mutatron:slots().output),
                apiary.link, apiary:resolveSlot(queen_slot), 1)

            if not moved then
                return jobs.RETRY, "transfert de la reine impossible: " .. tostring(reason)
            end

            return jobs.DONE
        end,
    },

    -- -----------------------------------------------------------------------
    {
        name = "attendre-la-fin-du-cycle",
        verify = function(job, context)
            local apiary = machineOf(context, "breeding_apiary")
            if not apiary then return false end
            -- The queen slot empties when she dies
            return apiary:slot(apiary:slots().queen) == nil
        end,
        run = function(job, context)
            local apiary, err = machineOf(context, "breeding_apiary")
            if not apiary then return jobs.FAILED, err end

            -- A climate the apiary cannot provide used to be read out loud
            -- and then waited on for ever. Now the missing upgrade is fetched
            -- from the ME network and slotted in; when that cannot be done the
            -- job asks for a hand instead of waiting on nothing.
            local blocking = apiary:environmentErrors()
            if #blocking > 0 then
                return upgrades.resolve(apiary, context, job, blocking)
            end

            -- One call replaces the Mechanical User, the beebee gun and the
            -- fixed sleep the old program relied on
            local wait = job.params.cycleTimeout
                or (context.config and context.config.breeding
                    and context.config.breeding.cycle_timeout_seconds)
                or 900

            local done, reason, elapsed = apiary:awaitPrincess(wait)

            if not done then
                -- Cumule sur disque: chaque passe repart de zero, donc sans
                -- ce total trois attentes de suite affichent "242 s" et rien
                -- ne distingue une reine qui vit longtemps d une file figee.
                job.params.waited = (job.params.waited or 0) + (elapsed or wait)

                return jobs.RETRY, tostring(reason)
                    .. string.format(" (%d s d attente au total)",
                                     job.params.waited)
            end

            job.params.waited = nil

            return jobs.DONE
        end,
    },

    -- -----------------------------------------------------------------------
    {
        name = "recolter",
        verify = function(job, context)
            local apiary = machineOf(context, "breeding_apiary")
            if not apiary then return false end
            return #apiary:outputs() == 0
        end,
        run = function(job, context)
            local apiary, err = machineOf(context, "breeding_apiary")
            if not apiary then return jobs.FAILED, err end

            local collected = 0
            for _, output in ipairs(apiary:outputs()) do
                collected = collected + apiary:unload(output.slot)
            end

            report(context, "recolte: " .. collected .. " item(s)")

            if #apiary:outputs() > 0 then
                -- Usually the network is full or the interface is saturated
                return jobs.RETRY, "la sortie de l'apiary ne se vide pas"
            end

            return jobs.DONE
        end,
    },

    -- -----------------------------------------------------------------------
    {
        name = "sauver-le-gene-d-espece",
        -- Never a reason to redo the cross: whatever happens here, the bees are
        -- already in the network and the job has succeeded.
        verify = function(job) return job.params.speciesSaved == true end,
        run = function(job, context)
            job.params.speciesSaved = true

            local settings = (context.config and context.config.genetics) or {}
            if settings.autosave_species == false then return jobs.DONE end

            local name = displayName(context, job.params.target)
            if not name then return jobs.DONE end

            -- Already in the library: a second sample costs thirteen drones for
            -- something the Genetic Transposer copies for one blank
            local ok, saved = pcall(function()
                return context.library:speciesGenes()
            end)
            if ok and type(saved) == "table" and saved[name] then
                return jobs.DONE
            end

            -- The pair is the criterion, not a stock. An apiary cycle nets one
            -- drone and the Sampler destroys one, so a species held as a
            -- princess and a drone can be drawn from for ever; the extraction
            -- runs its own cycles and needs nothing accumulated first. A cross
            -- that just succeeded leaves exactly that pair.
            local genetics = require("lib.genetics")
            local drones = genetics.droneCount(context, name .. " Drone")
            local princesses = genetics.princessCount(context, name)

            if drones == 0 or princesses == 0 then
                report(context, "gene d espece de " .. name .. " a sauver plus"
                    .. " tard: " .. (princesses == 0 and "aucune princesse"
                                                     or "aucun drone"))
                return jobs.DONE
            end

            if alreadyHunting(context, name) then return jobs.DONE end

            local params = genetics.campaignParams({
                bee = {label = name .. " Drone"},
                chromosome = "Species",
                allele = name,
                bees = 60,
            })

            if not params or not context.queue then return jobs.DONE end

            local id = context.queue:submit("campaign", params)
            if id then
                report(context, "espece nouvelle: chasse #" .. id
                    .. " en file pour sauver le gene " .. name)
            end

            return jobs.DONE
        end,
    },
}

--- The handler to register with the job queue
--- @return table handler
function breeding.handler()
    return {steps = breeding.STEPS}
end

--- Build the parameters of a breeding job
--- @param options table {target, princess, drone, labware, timeout, cycleTimeout}
--- @return table|nil params
--- @return string|nil error
function breeding.params(options)
    options = options or {}

    if type(options.target) ~= "string" then
        return nil, "espece cible manquante"
    end

    local function beeSpec(spec, role)
        if type(spec) ~= "table" or not spec.label then
            return nil, role .. " manquant ou sans etiquette"
        end
        return {name = spec.name or "forestry:bee_" .. role .. "_ge", label = spec.label}
    end

    local princess, princess_err = beeSpec(options.princess, "princess")
    if not princess then return nil, princess_err end

    local drone, drone_err = beeSpec(options.drone, "drone")
    if not drone then return nil, drone_err end

    return {
        target = options.target,
        princess = princess,
        drone = drone,
        labware = options.labware or {name = "gendustry:labware"},
        timeout = options.timeout,
        cycleTimeout = options.cycleTimeout,
    }
end

return breeding
