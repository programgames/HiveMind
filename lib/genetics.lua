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

--- A step that lets a machine consume whatever is already in its input
--- Gendustry will not let anything pull an input slot back out, so a job that
--- demanded an empty machine had to ask for a human. But there is a second way
--- to empty an input: let the machine eat it. Handed the missing consumables it
--- finishes the work, the slot clears itself, and the result is a gene we
--- wanted anyway -- one labware and one blank for a job that no longer blocks.
---
--- The Mutatron is deliberately excluded: running a mutation on the wrong
--- parents can produce nothing at all, so there the hands are still needed.
--- @param machineName string
--- @param inputKey string Slot key holding what the machine reads
--- @param wantedLabel function(job) -> string|nil
--- @return table step
local function finishLoadedStep(machineName, inputKey, wantedLabel)
    local function foreign(job, machine)
        local slots = machine.link.slots
        local occupant = machine:slot(slots[inputKey])

        if not occupant then return nil end
        if occupant.label == wantedLabel(job) then return nil end

        return occupant
    end

    return {
        name = "finir-le-travail-engage",
        verify = function(job, context)
            local machine = machineOf(context, machineName)
            if not machine then return false end
            return foreign(job, machine) == nil
        end,
        run = function(job, context)
            local machine, err = machineOf(context, machineName)
            if not machine then return jobs.FAILED, err end

            local occupant = foreign(job, machine)
            if not occupant then return jobs.DONE end

            local slots = machine.link.slots

            -- Try simply taking it back first. The Sampler refuses that on its
            -- inputs, but not every machine does, and asking costs one call.
            machine:unload(slots[inputKey])
            if not foreign(job, machine) then
                report(context, "entree liberee: " .. tostring(occupant.label))
                return jobs.DONE
            end

            -- Some machines consume what they read and some do not. The Genetic
            -- Transposer keeps its source -- that is what makes duplication
            -- safe -- so running it clears nothing, and running it again clears
            -- nothing again. Three tries is enough to know which kind this is.
            job.params.clearAttempts = (job.params.clearAttempts or 0) + 1

            if job.params.clearAttempts > 3 then
                return jobs.FAILED, "le slot " .. machine:resolveSlot(slots[inputKey])
                    .. " tient " .. tostring(occupant.label)
                    .. " et la machine ne le consomme pas."
                    .. " Retire-le a la main, puis relance la file."
            end

            report(context, "travail engage a finir: " .. tostring(occupant.label))

            -- Only the consumables: the machine already holds what it reads
            for _, entry in ipairs({
                {spec = job.params.blank,   slot = slots.blank or slots.destination},
                {spec = job.params.labware, slot = slots.labware},
            }) do
                if entry.slot and not machine:slot(entry.slot) then
                    local ok, reason = machine:load(entry.spec, entry.slot, 1)
                    if not ok then
                        return jobs.RETRY,
                            "impossible de finir le travail engage: " .. tostring(reason)
                    end
                end
            end

            local wait = job.params.timeout
                or (context.config and context.config.genetics
                    and context.config.genetics.sample_timeout_seconds)
                or 120

            local stack = machine:awaitOutput(slots.output, wait)
            if not stack then
                return jobs.RETRY, "la machine ne finit pas le travail engage"
            end

            if stack.label then
                report(context, "recupere au passage: " .. stack.label)
            end

            machine:unload(slots.output)

            if foreign(job, machine) then
                -- One pass was not enough; coming back costs nothing
                return jobs.RETRY, "entree toujours occupee, nouvelle passe"
            end

            return jobs.DONE
        end,
    }
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
    finishLoadedStep("sampler", "input", function(job) return job.params.bee.label end),

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
                    -- The previous step exists to make this impossible; if it
                    -- still happens, something is stuck in a way no machine
                    -- cycle clears
                    return jobs.RETRY, entry.role .. ": le sampler tient encore "
                        .. tostring(occupant.label) .. " dans le slot "
                        .. sampler:resolveSlot(entry.slot)
                        .. ", que la machine ne consomme pas. Retire-le a la main."
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

--- Build and check the parameters of a duplication job
--- A gene held in a single sample is one misplaced click from being gone. The
--- Genetic Transposer reads one sample and writes a copy into a blank, so the
--- source survives and the library gains a spare.
--- @param options table {sample}
--- @return table|nil params
--- @return string|nil error
function genetics.duplicateParams(options)
    options = options or {}

    local sample = options.sample
    if type(sample) ~= "table" or not sample.label then
        return nil, "sample source manquant ou sans etiquette"
    end

    return {
        sample = {name = sample.name or "gendustry:gene_sample", label = sample.label},
        blank = options.blank or {name = "gendustry:gene_sample_blank"},
        labware = options.labware or {name = "gendustry:labware"},
        timeout = options.timeout,
    }
end

genetics.DUPLICATE_STEPS = {
    -- -----------------------------------------------------------------------
    {
        name = "vider-la-sortie-du-transposer",
        verify = function(job, context)
            local machine = machineOf(context, "genetic_transposer")
            if not machine then return false end
            return machine:slot(machine.link.slots.output) == nil
        end,
        run = function(job, context)
            local machine, err = machineOf(context, "genetic_transposer")
            if not machine then return jobs.FAILED, err end

            local moved, cleared = drainOutput(machine)
            if moved > 0 then
                report(context, "sortie du transposer recoltee: " .. moved .. " item(s)")
            end

            if not cleared then
                return jobs.RETRY, "la sortie du transposer ne se vide pas"
            end

            return jobs.DONE
        end,
    },

    -- -----------------------------------------------------------------------
    finishLoadedStep("genetic_transposer", "source",
                     function(job) return job.params.sample.label end),

    -- -----------------------------------------------------------------------
    {
        name = "charger-le-transposer",
        verify = function(job, context)
            local machine = machineOf(context, "genetic_transposer")
            if not machine then return false end

            local source = machine:slot(machine.link.slots.source)
            return source ~= nil and source.label == job.params.sample.label
        end,
        run = function(job, context)
            local machine, err = machineOf(context, "genetic_transposer")
            if not machine then return jobs.FAILED, err end

            local slots = machine.link.slots

            -- The source goes in last, for the same reason the bee does in the
            -- sampler: the machine starts as soon as it has everything
            local order = {
                {spec = job.params.blank,   slot = slots.destination, role = "sample vierge"},
                {spec = job.params.labware, slot = slots.labware,     role = "labware"},
                {spec = job.params.sample,  slot = slots.source,      role = "sample source"},
            }

            -- Inspect before loading anything, or the consumables complete the
            -- machine's requirements around whatever sample is already there
            for _, entry in ipairs(order) do
                local occupant = machine:slot(entry.slot)

                if occupant and entry.spec.label
                   and occupant.label ~= entry.spec.label then
                    -- The previous step exists to make this impossible; if it
                    -- still happens, something is stuck in a way no machine
                    -- cycle clears
                    return jobs.RETRY, entry.role
                        .. ": le transposer tient encore "
                        .. tostring(occupant.label) .. " dans le slot "
                        .. machine:resolveSlot(entry.slot)
                        .. ", que la machine ne consomme pas. Retire-le a la main."
                end
            end

            for _, entry in ipairs(order) do
                if not machine:slot(entry.slot) then
                    local ok, reason = machine:load(entry.spec, entry.slot, 1)
                    if not ok then
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
        name = "attendre-la-copie",
        verify = function(job, context)
            local machine = machineOf(context, "genetic_transposer")
            if not machine then return false end
            return machine:slot(machine.link.slots.output) ~= nil
        end,
        run = function(job, context)
            local machine, err = machineOf(context, "genetic_transposer")
            if not machine then return jobs.FAILED, err end

            local wait = job.params.timeout
                or (context.config and context.config.genetics
                    and context.config.genetics.sample_timeout_seconds)
                or 120

            local stack, reason = machine:awaitOutput(machine.link.slots.output, wait)
            if not stack then return jobs.RETRY, tostring(reason) end

            return jobs.DONE
        end,
    },

    -- -----------------------------------------------------------------------
    {
        name = "recolter-la-copie",
        verify = function(job, context)
            local machine = machineOf(context, "genetic_transposer")
            if not machine then return false end
            return machine:slot(machine.link.slots.output) == nil
        end,
        run = function(job, context)
            local machine, err = machineOf(context, "genetic_transposer")
            if not machine then return jobs.FAILED, err end

            local slots = machine.link.slots
            local produced = machine:slot(slots.output)

            if produced and produced.label then
                -- A copy that is not the same gene means the machine did
                -- something other than what was asked, and a library built on
                -- that assumption would be quietly wrong
                if produced.label ~= job.params.sample.label then
                    report(context, "ATTENTION: copie '" .. produced.label
                        .. "' pour une source '" .. job.params.sample.label .. "'")
                else
                    report(context, "copie obtenue: " .. produced.label)
                end

                job.params.copied = produced.label
            end

            machine:unload(slots.output)

            if machine:slot(slots.output) then
                return jobs.RETRY, "la sortie du transposer ne se vide pas"
            end

            return jobs.DONE
        end,
    },
}

--- The handler to register with the job queue
--- @return table handler
function genetics.duplicateHandler()
    return {steps = genetics.DUPLICATE_STEPS}
end

--- Build and check the parameters of a gene campaign
--- One extraction is a lottery ticket. Getting a particular gene means buying
--- tickets until it comes up, and that is a loop, not a job an operator should
--- have to restart thirteen times.
--- @param options table {bee, chromosome, bees}
--- @return table|nil params
--- @return string|nil error
function genetics.campaignParams(options)
    options = options or {}

    local bee = options.bee
    if type(bee) ~= "table" or not bee.label then
        return nil, "abeille manquante ou sans etiquette"
    end

    -- Without a target chromosome the campaign simply harvests: every draw is
    -- a gene the library did not have, which is worth doing on its own
    local chromosome = options.chromosome
    if chromosome ~= nil and type(chromosome) ~= "string" then
        return nil, "chromosome vise invalide"
    end

    local budget = tonumber(options.bees) or 13
    if budget < 1 then return nil, "budget invalide: " .. tostring(options.bees) end

    return {
        bee = {name = bee.name or "forestry:bee_drone_ge", label = bee.label},
        blank = options.blank or {name = "gendustry:gene_sample_blank"},
        labware = options.labware or {name = "gendustry:labware"},
        chromosome = chromosome,
        budget = budget,
        spent = 0,
        obtainedList = {},
        timeout = options.timeout,
    }
end

--- The campaign is the sample cycle plus a decision at the end
--- Rewinding job.step is how the accumulation campaign loops, and the queue
--- increments after a DONE, so zero restarts at step one with the counters kept
--- on disk: a reboot mid-campaign resumes where it stopped.
genetics.CAMPAIGN_STEPS = {}

for _, step in ipairs(genetics.SAMPLE_STEPS) do
    table.insert(genetics.CAMPAIGN_STEPS, step)
end

table.insert(genetics.CAMPAIGN_STEPS, {
    name = "compter-et-recommencer",
    -- No verify: this step is the loop, and skipping it ends the campaign after
    -- a single draw
    run = function(job, context)
        job.params.spent = (job.params.spent or 0) + 1

        local drawn = job.params.obtained
        if drawn and drawn.chromosome then
            table.insert(job.params.obtainedList, drawn.chromosome .. " = "
                .. tostring(drawn.allele))
        end

        local wanted = job.params.chromosome
        local hit = drawn and wanted and drawn.chromosome == wanted

        report(context, job.params.bee.label .. ": " .. job.params.spent .. "/"
            .. job.params.budget .. " abeille(s), dernier tirage "
            .. ((drawn and drawn.chromosome) or "?"))

        if hit then
            return jobs.DONE, wanted .. " obtenu apres "
                .. job.params.spent .. " abeille(s)"
        end

        if job.params.spent >= job.params.budget then
            if wanted then
                -- Not a failure: thirteen genes went into the library and the
                -- draw simply did not come up. Saying "failed" would hide that.
                return jobs.DONE, "budget epuise sans " .. wanted
                    .. "; " .. #job.params.obtainedList .. " gene(s) recoltes"
            end

            return jobs.DONE, #job.params.obtainedList .. " gene(s) recoltes"
        end

        -- The queue adds one after a DONE, so zero restarts at step one
        job.params.obtained = nil
        job.step = 0

        return jobs.DONE, job.params.spent .. "/" .. job.params.budget
    end,
})

--- The handler to register with the job queue
--- @return table handler
function genetics.campaignHandler()
    return {steps = genetics.CAMPAIGN_STEPS}
end

--- The handler to register with the job queue
--- @return table handler
function genetics.sampleHandler()
    return {steps = genetics.SAMPLE_STEPS}
end

-- Exposed for the tests and for tools that need to tidy a machine
genetics.drainOutput = drainOutput

return genetics
