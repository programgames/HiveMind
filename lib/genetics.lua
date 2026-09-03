-- HiveMind genetics jobs
--
-- The three machines share one shape, measured by tools/probe rather than read
-- off a manual that had it wrong:
--
--   driver 0   what the work is written into   (blank sample, template)
--   driver 1   labware
--   driver 2   what it is read from            (bee, source sample)
--   driver 3   output
--
-- None of them has a driver component, so there is nothing to ask: the only
-- signal that the work is done is the output slot filling. Every wait polls and
-- yields, because a component call that blocks blocks the whole server.
--
-- Sampling is a lottery. The Sampler draws one chromosome out of thirteen, so
-- asking for a species gene costs about thirteen bees on average -- and the
-- twelve "failures" are genes worth keeping anyway. A job that demanded a
-- particular chromosome would spend most of its life reporting failure, so it
-- reports what it drew instead and lets the campaign decide.

local jobs = require("lib.jobs")
local genome = require("lib.genome")

local genetics = {}

local function report(context, text)
    if context and type(context.log) == "function" then
        pcall(context.log, text)
    end
end

local function machineOf(context, name)
    local machine = context and context.machines and context.machines[name]
    if not machine then
        return nil, "machine indisponible: " .. name
            .. " (declaree dans lib/config.lua ?)"
    end
    return machine
end

--- Empty a machine's OUTPUT back into the network
--- Gendustry refuses automated extraction from input slots -- the same rule the
--- Mutatron enforces -- so trying to empty everything asks for the impossible
--- and fails a step that had actually succeeded. Only the output can be taken.
---
--- What sits in an input is not rubbish anyway: a labware or a blank sample
--- left there is exactly what the next run needs.
--- @param machine table
--- @return number moved
--- @return boolean cleared
local function drainOutput(machine)
    local slot = machine.link.slots.output
    if not slot then return 0, true end

    if not machine:slot(slot) then return 0, true end

    local moved = machine:unload(slot) or 0
    return moved, machine:slot(slot) == nil
end

--- Build and check the parameters of a sampling job
--- @param options table {bee}
--- @return table|nil params
--- @return string|nil error
function genetics.sampleParams(options)
    options = options or {}

    local bee = options.bee
    if type(bee) ~= "table" or not bee.label then
        return nil, "abeille manquante ou sans etiquette"
    end

    return {
        bee = {name = bee.name or "forestry:bee_drone_ge", label = bee.label},
        blank = options.blank or {name = "gendustry:gene_sample_blank"},
        labware = options.labware or {name = "gendustry:labware"},
        timeout = options.timeout,
    }
end

genetics.SAMPLE_STEPS = {
    -- -----------------------------------------------------------------------
    {
        name = "vider-la-sortie-du-sampler",
        verify = function(job, context)
            local sampler = machineOf(context, "sampler")
            if not sampler then return false end
            return sampler:slot(sampler.link.slots.output) == nil
        end,
        run = function(job, context)
            local sampler, err = machineOf(context, "sampler")
            if not sampler then return jobs.FAILED, err end

            local moved, cleared = drainOutput(sampler)
            if moved > 0 then
                report(context, "sortie du sampler recoltee: " .. moved .. " item(s)")
            end

            if not cleared then
                return jobs.RETRY, "la sortie du sampler ne se vide pas"
            end

            return jobs.DONE
        end,
    },

    -- -----------------------------------------------------------------------
    {
        name = "charger-le-sampler",
        verify = function(job, context)
            local sampler = machineOf(context, "sampler")
            if not sampler then return false end

            local slots = sampler.link.slots
            local bee = sampler:slot(slots.input)
            return bee ~= nil and bee.label == job.params.bee.label
        end,
        run = function(job, context)
            local sampler, err = machineOf(context, "sampler")
            if not sampler then return jobs.FAILED, err end

            local slots = sampler.link.slots

            -- The bee goes in last: the machine starts as soon as it has
            -- everything, and starting before the labware is in place wastes
            -- the bee for nothing.
            local order = {
                {spec = job.params.blank,   slot = slots.blank,   role = "sample vierge"},
                {spec = job.params.labware, slot = slots.labware, role = "labware"},
                {spec = job.params.bee,     slot = slots.input,   role = "abeille"},
            }

            -- Inspect everything BEFORE loading anything. Feeding the
            -- consumables in first completes the machine's requirements around
            -- whatever bee is already sitting there, and it runs on the wrong
            -- one before the mismatch is ever noticed.
            for _, entry in ipairs(order) do
                local occupant = sampler:slot(entry.slot)

                if occupant and entry.spec.label
                   and occupant.label ~= entry.spec.label then
                    -- Gendustry will not let anything pull this back out, so
                    -- naming the slot the player sees is all we can offer
                    return jobs.RETRY, entry.role .. ": le sampler contient deja "
                        .. tostring(occupant.label) .. " dans le slot "
                        .. sampler:resolveSlot(entry.slot)
                        .. ". Retire-le a la main puis relance."
                end
            end

            for _, entry in ipairs(order) do
                if not sampler:slot(entry.slot) then
                    local ok, reason = sampler:load(entry.spec, entry.slot, 1)
                    if not ok then
                        -- A missing consumable is a supply problem, not a bad
                        -- plan: waiting costs nothing, failing loses the job
                        return jobs.RETRY, entry.role .. " indisponible: "
                            .. tostring(reason)
                    end
                end
            end

            return jobs.DONE
        end,
    },

    -- -----------------------------------------------------------------------
    {
        name = "attendre-le-sample",
        verify = function(job, context)
            local sampler = machineOf(context, "sampler")
            if not sampler then return false end
            return sampler:slot(sampler.link.slots.output) ~= nil
        end,
        run = function(job, context)
            local sampler, err = machineOf(context, "sampler")
            if not sampler then return jobs.FAILED, err end

            local wait = job.params.timeout
                or (context.config and context.config.genetics
                    and context.config.genetics.sample_timeout_seconds)
                or 120

            local stack, reason = sampler:awaitOutput(
                sampler.link.slots.output, wait)

            if not stack then return jobs.RETRY, tostring(reason) end

            return jobs.DONE
        end,
    },

    -- -----------------------------------------------------------------------
    {
        name = "recolter-le-sample",
        verify = function(job, context)
            local sampler = machineOf(context, "sampler")
            if not sampler then return false end
            return sampler:slot(sampler.link.slots.output) == nil
        end,
        run = function(job, context)
            local sampler, err = machineOf(context, "sampler")
            if not sampler then return jobs.FAILED, err end

            local slots = sampler.link.slots
            local produced = sampler:slot(slots.output)

            -- Read before moving: once it is in the network the label is still
            -- there, but saying what this bee gave is the point of the job
            if produced and produced.label then
                local parsed = genome.parseSampleLabel(produced.label)

                if parsed then
                    report(context, "gene obtenu: " .. parsed.chromosome
                        .. " = " .. parsed.allele)
                    job.params.obtained = {
                        chromosome = parsed.chromosome,
                        allele = parsed.allele,
                        slot = parsed.slot,
                        label = produced.label,
                    }
                else
                    -- Not a gene sample: worth recording rather than discarding,
                    -- because it means the machine did something unexpected
                    report(context, "sortie inattendue: " .. produced.label)
                    job.params.obtained = {label = produced.label}
                end
            end

            sampler:unload(slots.output)

            if sampler:slot(slots.output) then
                return jobs.RETRY, "la sortie du sampler ne se vide pas"
            end

            return jobs.DONE
        end,
    },
}

--- The handler to register with the job queue
--- @return table handler
function genetics.sampleHandler()
    return {steps = genetics.SAMPLE_STEPS}
end

-- Exposed for the tests and for tools that need to tidy a machine
genetics.drainOutput = drainOutput

return genetics
