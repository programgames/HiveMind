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

--- Empty every slot of a machine back into the network
--- Anything left in a machine is invisible to the ME network, so a job looking
--- for it reports it missing while it sits two blocks away. Draining first also
--- means a previous run's output is never mistaken for this one's.
--- @param machine table
--- @return number moved
--- @return number remaining
local function drain(machine)
    local moved, remaining = 0, 0

    for _, slot in pairs(machine.link.slots or {}) do
        if type(slot) == "number" then
            if machine:slot(slot) then
                moved = moved + (machine:unload(slot) or 0)
            end
            if machine:slot(slot) then remaining = remaining + 1 end
        end
    end

    return moved, remaining
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
        name = "vider-le-sampler",
        verify = function(job, context)
            local sampler = machineOf(context, "sampler")
            if not sampler then return false end
            return sampler:slot(sampler.link.slots.output) == nil
        end,
        run = function(job, context)
            local sampler, err = machineOf(context, "sampler")
            if not sampler then return jobs.FAILED, err end

            local moved, remaining = drain(sampler)
            if moved > 0 then
                report(context, "sampler vide: " .. moved .. " item(s) rendus")
            end

            if remaining > 0 then
                return jobs.RETRY, remaining .. " slot(s) du sampler ne se vident pas"
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
genetics.drain = drain

return genetics
