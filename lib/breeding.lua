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

--- Is the machine able to work right now
--- @return string|nil retry Reason to come back later, nil when ready
local function notReady(machine)
    local status, detail = machine:isReady()
    if status == "ready" then return nil end
    return detail or status
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
                -- Missing labware is a supply problem, not a broken plan
                return jobs.RETRY, "labware indisponible: " .. tostring(reason)
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

            if labelInSlot(mutatron, slots.in1) ~= job.params.princess.label then
                local ok, reason = mutatron:load(job.params.princess, slots.in1, 1)
                if not ok then
                    return jobs.RETRY, "princesse indisponible: " .. tostring(reason)
                end
            end

            if labelInSlot(mutatron, slots.in2) ~= job.params.drone.label then
                local ok, reason = mutatron:load(job.params.drone, slots.in2, 1)
                if not ok then
                    return jobs.RETRY, "drone indisponible: " .. tostring(reason)
                end
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

            local wait = notReady(mutatron)
            if wait then return jobs.RETRY, wait end

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

            local produced, produce_err = mutatron:produce(mutation.index or 1,
                                                          job.params.timeout or 60)
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

            local wait = notReady(apiary)
            if wait then return jobs.RETRY, wait end

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

            local blocking = apiary:environmentErrors()
            if #blocking > 0 then
                return jobs.RETRY, "l'apiary ne convient pas a cette abeille: "
                    .. table.concat(blocking, ", ")
            end

            -- One call replaces the Mechanical User, the beebee gun and the
            -- fixed sleep the old program relied on
            local done, reason = apiary:awaitPrincess(job.params.cycleTimeout or 300)
            if not done then return jobs.RETRY, tostring(reason) end

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
