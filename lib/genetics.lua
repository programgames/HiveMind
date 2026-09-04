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

            -- Take it back first. Observed in game: the Genetic Transposer DOES
            -- release its source slot, which is what unblocked a queue that had
            -- spent three passes going round in circles. The Sampler refuses.
            -- Asking costs one call and answers the question per machine.
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
                -- Three passes answer the question: this machine keeps what it
                -- reads. Only a hand empties that slot, so the job waits for one
                -- instead of dying and taking its progress with it.
                job.params.clearAttempts = 0
                return jobs.NEEDS_PLAYER, "retire "
                    .. tostring(occupant.label) .. " du slot "
                    .. machine:resolveSlot(slots[inputKey])
                    .. " (la machine ne le consomme pas et ne le rend pas)"
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
                    -- A job already past the clearing step never goes back to
                    -- it, and another job's leftover can land here in between.
                    -- Trying the extraction costs one call and is what the
                    -- clearing step would have done.
                    sampler:unload(entry.slot)
                    occupant = sampler:slot(entry.slot)
                end

                if occupant and entry.spec.label
                   and occupant.label ~= entry.spec.label then
                    -- Nothing the program can do: Gendustry refuses
                    -- automated extraction from an input. Said as the gesture
                    -- it is, so the queue hands back a chore and not a fault.
                    return jobs.NEEDS_PLAYER, "retire "
                        .. tostring(occupant.label) .. " du slot "
                        .. sampler:resolveSlot(entry.slot)
                        .. " du Sampler (il occupe la place " .. entry.role .. ")"
                end
            end

            for _, entry in ipairs(order) do
                if not sampler:slot(entry.slot) then
                    local ok, reason = sampler:load(entry.spec, entry.slot, 1)
                    if not ok then
                        -- A missing consumable is a supply problem, not a bad
                        -- plan: waiting costs nothing, failing loses the job
                        -- Not a bad plan and not a transient wait: the
                        -- network simply has none. Only a hand fixes that.
                        return jobs.NEEDS_PLAYER, "mets " .. entry.role
                            .. " dans le reseau ME (" .. tostring(reason) .. ")"
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
                    -- A job already past the clearing step never goes back to
                    -- it, and another job's leftover can land here in between.
                    -- The transposer does release its source, so asking works.
                    machine:unload(entry.slot)
                    occupant = machine:slot(entry.slot)
                end

                if occupant and entry.spec.label
                   and occupant.label ~= entry.spec.label then
                    return jobs.NEEDS_PLAYER, "retire "
                        .. tostring(occupant.label) .. " du slot "
                        .. machine:resolveSlot(entry.slot)
                        .. " du Genetic Transposer (il occupe la place "
                        .. entry.role .. ")"
                end
            end

            for _, entry in ipairs(order) do
                if not machine:slot(entry.slot) then
                    local ok, reason = machine:load(entry.spec, entry.slot, 1)
                    if not ok then
                        -- Not a bad plan and not a transient wait: the
                        -- network simply has none. Only a hand fixes that.
                        return jobs.NEEDS_PLAYER, "mets " .. entry.role
                            .. " dans le reseau ME (" .. tostring(reason) .. ")"
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

-- Templates are NOT built in a machine. The mod says so itself:
--
--   gendustry.label.template.crafting=Genetic Samples can be added to a
--   Template. Combine them in any crafting table. Multiple samples can be
--   added at once.
--
-- That is why no slot of any machine accepts a Genetic Template, and why there
-- is no blank template item: a blank one is simply a template with zero
-- chromosomes. A job written against the opposite assumption could never work,
-- so it is gone rather than left to fail in the world.

--- Build and check the parameters of an imprinting job
--- The Imprinter overwrites a bee's genes with those of a template: this is
--- what turns the library into a tool rather than a museum.
---
--- The template is NOT supplied by the job. A filled template and an empty one
--- share an item id and a label, so AE2 cannot tell them apart and asking it
--- for one would hand back whichever it liked. The template is placed in the
--- machine by hand, once, and then serves every bee that follows.
--- @param options table {bee}
--- @return table|nil params
--- @return string|nil error
function genetics.imprintParams(options)
    options = options or {}

    local bee = options.bee
    if type(bee) ~= "table" or not bee.label then
        return nil, "abeille manquante ou sans etiquette"
    end

    return {
        bee = {name = bee.name or "forestry:bee_drone_ge", label = bee.label},
        labware = options.labware or {name = "gendustry:labware"},
        -- Which Imprinter. Two of them, one template each, is what removes
        -- template swapping; a job that did not say which one would always
        -- print the same profile.
        machine = options.machine or "imprinter",
        timeout = options.timeout,
    }
end

genetics.IMPRINT_STEPS = {
    -- -----------------------------------------------------------------------
    {
        name = "vider-la-sortie-de-l-imprinter",
        verify = function(job, context)
            local machine = machineOf(context, job.params.machine or "imprinter")
            if not machine then return false end
            return machine:slot(machine.link.slots.output) == nil
        end,
        run = function(job, context)
            local machine, err = machineOf(context, job.params.machine or "imprinter")
            if not machine then return jobs.FAILED, err end

            local moved, cleared = drainOutput(machine)
            if moved > 0 then
                report(context, "sortie de l imprinter recoltee: " .. moved .. " item(s)")
            end

            if not cleared then
                return jobs.RETRY, "la sortie de l imprinter ne se vide pas"
            end

            return jobs.DONE
        end,
    },

    -- -----------------------------------------------------------------------
    {
        name = "verifier-le-template",
        verify = function(job, context)
            local machine = machineOf(context, job.params.machine or "imprinter")
            if not machine then return false end
            return machine:slot(machine.link.slots.template) ~= nil
        end,
        run = function(job, context)
            local machine, err = machineOf(context, job.params.machine or "imprinter")
            if not machine then return jobs.FAILED, err end

            -- Never fetched from the network: a filled template and an empty
            -- one share an id and a label there, so AE2 would hand back
            -- whichever it liked and the bee would come out wrong.
            return jobs.NEEDS_PLAYER,
                "pose le template dans le slot "
                .. machine:resolveSlot(machine.link.slots.template)
                .. " de l Imprinter: rempli ou vide, ils sont indiscernables"
                .. " dans le reseau ME, le programme ne peut pas choisir"
        end,
    },

    -- -----------------------------------------------------------------------
    {
        name = "charger-l-abeille",
        verify = function(job, context)
            local machine = machineOf(context, job.params.machine or "imprinter")
            if not machine then return false end

            local slots = machine.link.slots
            local bee = machine:slot(slots.bee)

            return bee ~= nil and bee.label == job.params.bee.label
                and machine:slot(slots.labware) ~= nil
        end,
        run = function(job, context)
            local machine, err = machineOf(context, job.params.machine or "imprinter")
            if not machine then return jobs.FAILED, err end

            local slots = machine.link.slots

            for _, entry in ipairs({
                {spec = job.params.labware, slot = slots.labware, role = "labware"},
                {spec = job.params.bee,     slot = slots.bee,     role = "abeille"},
            }) do
                local occupant = machine:slot(entry.slot)

                if occupant and entry.spec.label
                   and occupant.label ~= entry.spec.label then
                    machine:unload(entry.slot)
                    occupant = machine:slot(entry.slot)
                end

                if occupant and entry.spec.label
                   and occupant.label ~= entry.spec.label then
                    return jobs.NEEDS_PLAYER, "retire "
                        .. tostring(occupant.label) .. " du slot "
                        .. machine:resolveSlot(entry.slot)
                        .. " de l Imprinter (il occupe la place "
                        .. entry.role .. ")"
                end

                if not occupant then
                    local ok, reason = machine:load(entry.spec, entry.slot, 1)
                    if not ok then
                        -- Not a bad plan and not a transient wait: the
                        -- network simply has none. Only a hand fixes that.
                        return jobs.NEEDS_PLAYER, "mets " .. entry.role
                            .. " dans le reseau ME (" .. tostring(reason) .. ")"
                    end
                end
            end

            return jobs.DONE
        end,
    },

    -- -----------------------------------------------------------------------
    {
        name = "attendre-l-abeille-imprimee",
        verify = function(job, context)
            local machine = machineOf(context, job.params.machine or "imprinter")
            if not machine then return false end
            return machine:slot(machine.link.slots.output) ~= nil
        end,
        run = function(job, context)
            local machine, err = machineOf(context, job.params.machine or "imprinter")
            if not machine then return jobs.FAILED, err end

            -- Same trap as the replicator: the template was approved several
            -- steps ago and can have been taken out since. Waiting two minutes
            -- on a machine that cannot work says nothing useful.
            local slots = machine.link.slots

            if not machine:slot(slots.template) then
                return jobs.FAILED,
                    "le template a quitte l imprinter: il n a plus rien a"
                    .. " appliquer. Repose-le et relance."
            end

            if not machine:slot(slots.bee) then
                return jobs.FAILED,
                    "l abeille n est plus dans l imprinter: elle a ete retiree"
                    .. " ou consommee sans rien produire."
            end

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
        name = "recolter-l-abeille",
        verify = function(job, context)
            local machine = machineOf(context, job.params.machine or "imprinter")
            if not machine then return false end
            return machine:slot(machine.link.slots.output) == nil
        end,
        run = function(job, context)
            local machine, err = machineOf(context, job.params.machine or "imprinter")
            if not machine then return jobs.FAILED, err end

            local slots = machine.link.slots
            local produced = machine:slot(slots.output)

            if produced then
                job.params.imprinted = tostring(produced.label)
                report(context, "abeille imprimee: " .. job.params.imprinted)
            end

            machine:unload(slots.output)

            if machine:slot(slots.output) then
                return jobs.RETRY, "la sortie de l imprinter ne se vide pas"
            end

            -- Worth knowing whether the machine keeps its template: it decides
            -- whether one placement serves every bee or only the next one
            if not machine:slot(slots.template) then
                report(context, "le template a ete consomme; il faut en reposer un")
            end

            return jobs.DONE
        end,
    },
}

--- The handler to register with the job queue
--- @return table handler
function genetics.imprintHandler()
    return {steps = genetics.IMPRINT_STEPS}
end

--- The handler to register with the job queue
--- @return table handler
function genetics.duplicateHandler()
    return {steps = genetics.DUPLICATE_STEPS}
end

-- ---------------------------------------------------------------------------
-- Genetic Replicator
--
-- The one machine that makes a bee out of nothing: a template holding all
-- thirteen chromosomes, Liquid DNA, and it prints the bee that template
-- describes. That is the difference between a library and an insurance policy.
--
-- It always produces Ignoble stock, so this is for drones. The player supplies
-- the DNA; the program only says when there is none.

--- Check the shape of a machine before anything is moved into it
--- The Gendustry documentation was wrong about the other three -- it put
--- labware at slot 3 and an output at slot 4, in an inventory that holds four
--- slots total, so every delivery would have gone nowhere with no error at all.
--- These two have never been inspected in a real world, so they are checked
--- rather than trusted.
--- @param machine table
--- @return boolean ok
--- @return string|nil error
local function shapeAgrees(machine)
    local size = machine.transport
        and machine.transport:inventorySize(machine.link)

    if not size then
        return false, "machine injoignable: le transposer ne voit pas cet"
            .. " inventaire. Verifie qu elle est bien collee a lui."
    end

    for role, slot in pairs(machine.link.slots or {}) do
        if type(slot) == "number" then
            local resolved = machine:resolveSlot(slot)
            if resolved > size then
                return false, string.format(
                    "slot %s annonce en %d, or la machine n en a que %d."
                    .. " Lance tools/probe avant de t en servir.",
                    role, resolved, size)
            end
        end
    end

    return true
end

--- Build and check the parameters of a replication job
--- @param options table {labware, timeout}
--- @return table|nil params
--- @return string|nil error
function genetics.replicateParams(options)
    options = options or {}

    return {
        labware = options.labware or {name = "gendustry:labware"},
        timeout = options.timeout,
    }
end

genetics.REPLICATE_STEPS = {
    -- -----------------------------------------------------------------------
    {
        name = "verifier-la-forme-du-replicator",
        verify = function(job, context)
            return job.params.shapeChecked == true
        end,
        run = function(job, context)
            local machine, err = machineOf(context, "replicator")
            if not machine then return jobs.FAILED, err end

            local ok, reason = shapeAgrees(machine)
            if not ok then return jobs.FAILED, reason end

            job.params.shapeChecked = true
            return jobs.DONE
        end,
    },

    -- -----------------------------------------------------------------------
    {
        name = "vider-la-sortie-du-replicator",
        verify = function(job, context)
            local machine = machineOf(context, "replicator")
            if not machine then return false end
            return machine:slot(machine.link.slots.output) == nil
        end,
        run = function(job, context)
            local machine, err = machineOf(context, "replicator")
            if not machine then return jobs.FAILED, err end

            local moved, cleared = drainOutput(machine)
            if moved > 0 then
                report(context, "sortie du replicator recoltee: "
                    .. moved .. " item(s)")
            end

            if not cleared then
                return jobs.RETRY, "la sortie du replicator ne se vide pas"
            end

            return jobs.DONE
        end,
    },

    -- -----------------------------------------------------------------------
    {
        name = "verifier-le-template-complet",
        verify = function(job, context)
            local machine = machineOf(context, "replicator")
            if not machine then return false end
            return machine:slot(machine.link.slots.template) ~= nil
        end,
        run = function(job, context)
            local machine, err = machineOf(context, "replicator")
            if not machine then return jobs.FAILED, err end

            -- Same reason as the imprinter, and it matters more here: this
            -- template needs all thirteen chromosomes including the species,
            -- and AE2 cannot tell a full one from an empty one.
            return jobs.NEEDS_PLAYER,
                "pose un template COMPLET (13 chromosomes sur 13, gene Species"
                .. " compris) dans le slot "
                .. machine:resolveSlot(machine.link.slots.template)
                .. " du Replicator: c est lui qui decide quelle abeille sort"
        end,
    },

    -- -----------------------------------------------------------------------
    {
        name = "verifier-le-dna",
        verify = function(job, context)
            -- A live reading, never remembered: the tank drains while the job
            -- runs, so a remembered "it was full" is worth nothing
            return false
        end,
        run = function(job, context)
            local machine, err = machineOf(context, "replicator")
            if not machine then return jobs.FAILED, err end

            local tank = context.transport:tank(machine.link)

            -- No readable tank is not the same as an empty one: a transposer
            -- that cannot see fluids should not stop a job that would work
            if tank and (tank.amount or 0) == 0 then
                return jobs.RETRY,
                    "plus de DNA liquide dans le replicator. C est toi qui le"
                    .. " fournis: remplis-le et relance la file."
            end

            return jobs.DONE
        end,
    },

    -- -----------------------------------------------------------------------
    {
        name = "charger-le-labware",
        verify = function(job, context)
            local machine = machineOf(context, "replicator")
            if not machine then return false end

            local labware = machine.link.slots.labware
            if labware == nil then return true end
            return machine:slot(labware) ~= nil
        end,
        run = function(job, context)
            local machine, err = machineOf(context, "replicator")
            if not machine then return jobs.FAILED, err end

            local labware = machine.link.slots.labware
            if labware == nil then return jobs.DONE end

            local ok, reason = machine:load(job.params.labware, labware, 1)
            if not ok then
                return jobs.RETRY, "labware indisponible: " .. tostring(reason)
            end

            return jobs.DONE
        end,
    },

    -- -----------------------------------------------------------------------
    {
        name = "attendre-l-abeille-repliquee",
        verify = function(job, context)
            local machine = machineOf(context, "replicator")
            if not machine then return false end
            return machine:slot(machine.link.slots.output) ~= nil
        end,
        run = function(job, context)
            local machine, err = machineOf(context, "replicator")
            if not machine then return jobs.FAILED, err end

            -- Check the machine can still work before waiting on it. The
            -- template was present when step 3 approved it and can have left
            -- since -- taken by hand, most likely -- and waiting two minutes
            -- for a machine with nothing in it teaches nobody anything.
            if not machine:slot(machine.link.slots.template) then
                return jobs.FAILED,
                    "le template a quitte le replicator: il n a plus rien a"
                    .. " copier. Repose un template COMPLET (13 genes sur 13,"
                    .. " gene d espece compris) et relance."
            end

            local tank = context.transport:tank(machine.link)
            if tank and (tank.amount or 0) == 0 then
                return jobs.RETRY,
                    "plus de liquide dans le replicator: remplis-le et relance."
            end

            local wait = job.params.timeout
                or (context.config and context.config.genetics
                    and context.config.genetics.sample_timeout_seconds)
                or 120

            local stack, reason =
                machine:awaitOutput(machine.link.slots.output, wait)
            if not stack then return jobs.RETRY, tostring(reason) end

            return jobs.DONE
        end,
    },

    -- -----------------------------------------------------------------------
    {
        name = "recolter-l-abeille-repliquee",
        verify = function(job, context)
            local machine = machineOf(context, "replicator")
            if not machine then return false end
            return machine:slot(machine.link.slots.output) == nil
        end,
        run = function(job, context)
            local machine, err = machineOf(context, "replicator")
            if not machine then return jobs.FAILED, err end

            local produced = machine:slot(machine.link.slots.output)
            if produced then
                job.params.produced = tostring(produced.label)
                report(context, "reine repliquee: " .. job.params.produced
                    .. " (Ignoble Stock)")
            end

            machine:unload(machine.link.slots.output)

            if machine:slot(machine.link.slots.output) then
                return jobs.RETRY, "la sortie du replicator ne se vide pas"
            end

            return jobs.DONE
        end,
    },
}

--- The handler to register with the job queue
--- @return table handler
function genetics.replicateHandler()
    return {steps = genetics.REPLICATE_STEPS}
end

-- ---------------------------------------------------------------------------
-- DNA Extractor
--
-- Turns bees into Liquid DNA, which is what the Replicator drinks. Its input is
-- the one place in the system where a bee is meant to be destroyed, so what
-- goes in is chosen narrowly: surplus drones of a species whose Species gene is
-- already safe in the library. Everything else is worth more alive.

--- Build and check the parameters of an extraction job
--- @param options table {bee, count}
--- @return table|nil params
--- @return string|nil error
function genetics.extractParams(options)
    options = options or {}

    local bee = options.bee
    if type(bee) ~= "table" or not bee.label then
        return nil, "abeille manquante ou sans etiquette"
    end

    local count = tonumber(options.count) or 1
    if count < 1 then
        return nil, "quantite invalide: " .. tostring(options.count)
    end

    return {
        bee = {name = bee.name or "forestry:bee_drone_ge", label = bee.label},
        labware = options.labware or {name = "gendustry:labware"},
        count = count,
        fed = 0,
        timeout = options.timeout,
    }
end

genetics.EXTRACT_STEPS = {
    -- -----------------------------------------------------------------------
    {
        name = "verifier-la-forme-de-l-extracteur",
        verify = function(job, context)
            return job.params.shapeChecked == true
        end,
        run = function(job, context)
            local machine, err = machineOf(context, "dna_extractor")
            if not machine then return jobs.FAILED, err end

            local ok, reason = shapeAgrees(machine)
            if not ok then return jobs.FAILED, reason end

            job.params.shapeChecked = true
            return jobs.DONE
        end,
    },

    -- -----------------------------------------------------------------------
    {
        name = "alimenter-l-extracteur",
        verify = function(job, context)
            return (job.params.fed or 0) >= job.params.count
        end,
        run = function(job, context)
            local machine, err = machineOf(context, "dna_extractor")
            if not machine then return jobs.FAILED, err end

            local slots = machine.link.slots

            -- The input slots of Gendustry machines refuse automated
            -- extraction, so a bee already sitting there is not a blockage to
            -- clear: it is the previous one, still being consumed.
            if machine:slot(slots.input) then
                return jobs.RETRY,
                    "l extracteur digere encore l abeille precedente"
            end

            if slots.labware ~= nil and not machine:slot(slots.labware) then
                local fine = machine:load(job.params.labware, slots.labware, 1)
                if not fine then
                    return jobs.NEEDS_PLAYER,
                        "mets du labware dans le reseau ME, le DNA Extractor"
                        .. " n en a plus"
                end
            end

            local ok, reason = machine:load(job.params.bee, slots.input, 1)
            if not ok then
                return jobs.NEEDS_PLAYER, "mets "
                    .. tostring(job.params.bee.label or "l abeille")
                    .. " dans le reseau ME (" .. tostring(reason) .. ")"
            end

            job.params.fed = (job.params.fed or 0) + 1
            report(context, string.format("%s -> extracteur ADN (%d/%d)",
                job.params.bee.label, job.params.fed, job.params.count))

            if job.params.fed < job.params.count then
                return jobs.RETRY, "abeille suivante au prochain passage"
            end

            return jobs.DONE
        end,
    },
}

--- The handler to register with the job queue
--- @return table handler
function genetics.extractHandler()
    return {steps = genetics.EXTRACT_STEPS}
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

    -- A profile wants Fertility 4, not any Fertility. Stopping on the first
    -- draw of the right chromosome hands back whatever value that bee happened
    -- to carry, and the campaign has to be run again for the one that counts.
    local allele = options.allele
    if allele ~= nil and type(allele) ~= "string" then
        return nil, "allele vise invalide"
    end

    if allele and not chromosome then
        return nil, "un allele vise sans chromosome"
    end

    local budget = tonumber(options.bees) or 13
    if budget < 1 then return nil, "budget invalide: " .. tostring(options.bees) end

    return {
        bee = {name = bee.name or "forestry:bee_drone_ge", label = bee.label},
        blank = options.blank or {name = "gendustry:gene_sample_blank"},
        labware = options.labware or {name = "gendustry:labware"},
        chromosome = chromosome,
        allele = allele,
        budget = budget,
        -- When set, an exhausted budget breeds back up to this many drones and
        -- starts over instead of giving up. nil keeps the single-attempt
        -- behaviour, which is what a one-off draw from the menu wants.
        refill = tonumber(options.refill),
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
        local wantedAllele = job.params.allele

        local hit = drawn and wanted and drawn.chromosome == wanted
            and (not wantedAllele or drawn.allele == wantedAllele)

        -- The right chromosome with the WRONG value proves something: this bee
        -- carries another allele there. A bee holds two, so one wrong draw
        -- means nothing; three in a row means the species almost certainly does
        -- not carry what we are after, and looping for ever would burn drones
        -- on a bee that can never give it.
        if drawn and wanted and wantedAllele
           and drawn.chromosome == wanted and drawn.allele ~= wantedAllele then
            job.params.wrongAllele = (job.params.wrongAllele or 0) + 1

            if job.params.wrongAllele >= 3 then
                return jobs.FAILED, job.params.bee.label .. " a donne "
                    .. wanted .. " trois fois sans jamais " .. wantedAllele
                    .. ": cette espece ne le porte probablement pas."
                    .. " Lis son genome (option g) avant d y depenser plus."
            end
        end

        report(context, job.params.bee.label .. ": " .. job.params.spent .. "/"
            .. job.params.budget .. " abeille(s), dernier tirage "
            .. ((drawn and drawn.chromosome) or "?"))

        if hit then
            return jobs.DONE, wanted
                .. (wantedAllele and (" = " .. wantedAllele) or "")
                .. " obtenu apres " .. job.params.spent .. " abeille(s)"
        end

        if job.params.spent >= job.params.budget then
            if wanted then
                -- "Obtiens-moi ce gene" is a standing goal, not one attempt.
                -- The budget is what can be spent WITHOUT taking the last
                -- drone; when it runs out the answer is to breed more and come
                -- back, not to give up on a gene the template needs.
                if job.params.refill and context and context.queue then
                    local multiply = require("lib.multiply")
                    local species = job.params.bee.label:gsub("%s+Drone$", "")

                    local grow = multiply.params({
                        species = species,
                        target = job.params.refill,
                    })

                    if grow and context.queue:submit("multiply", grow) then
                        -- Rewound to zero, the queue restarts it at step one
                        -- once the accumulation ahead of it has run.
                        job.params.spent = 0
                        job.params.obtained = nil
                        job.step = 0

                        return jobs.DONE, "budget epuise sans " .. wanted
                            .. ": accumulation jusqu a " .. job.params.refill
                            .. " drones, puis on recommence"
                    end
                end

                -- Not a failure: thirteen genes went into the library and the
                -- draw simply did not come up. Saying "failed" would hide that.
                return jobs.DONE, "budget epuise sans " .. wanted
                    .. (wantedAllele and (" = " .. wantedAllele) or "")
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
