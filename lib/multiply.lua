-- HiveMind drone accumulation
--
-- Every cross spends a drone. A network holding sixteen princess species and
-- two drone species can plan anything and execute almost nothing, which is
-- exactly the state the first full report showed.
--
-- The fix is the oldest trick in Forestry: a princess and a drone of the same
-- species become a queen, the queen dies leaving a princess and several drones,
-- and the princess goes straight back in. One drone in, several out, and the
-- line never runs dry.
--
-- Four steps, run in a loop until the network holds enough:
--
--   1. empty the apiary output      3. wait for the queen to die
--   2. load princess and drone      4. collect, count, and go round again
--
-- The loop is the last step rewinding job.step. The queue increments it after a
-- DONE, so setting it to zero restarts at step one with the counters kept on
-- disk: a reboot mid-campaign resumes where it stopped.

local jobs = require("lib.jobs")

local multiply = {}

--- How many of one item the ME network holds
--- @param context table
--- @param spec table {name, label}
--- @return number
local function stock(context, spec)
    if not (context and context.transport) then return 0 end

    local total = 0
    for _, item in ipairs(context.transport:findAll(spec) or {}) do
        total = total + (tonumber(item.size) or 0)
    end

    return total
end

local function report(context, text)
    if context and type(context.log) == "function" then
        pcall(context.log, text)
    end
end

local function machineOf(context, name)
    local machine = context and context.machines and context.machines[name]
    if not machine then
        return nil, "machine indisponible: " .. name
    end
    return machine
end

local function labelInSlot(machine, slot)
    local stack = machine:slot(slot)
    return stack and stack.label or nil
end

--- Build and check the parameters of an accumulation job
--- @param options table {species, target, princess, drone, maxCycles}
--- @return table|nil params
--- @return string|nil error
function multiply.params(options)
    options = options or {}

    local species = options.species
    if type(species) ~= "string" or species == "" then
        return nil, "espece manquante"
    end

    -- "Water" is what the operator says; "Water Princess" is what the network
    -- calls it. Deriving both spares them typing the two labels.
    local princess = options.princess
        or {name = "forestry:bee_princess_ge", label = species .. " Princess"}
    local drone = options.drone
        or {name = "forestry:bee_drone_ge", label = species .. " Drone"}

    -- 32 is not a magic number, it is two budgets stacked:
    --   * a cross spends exactly one drone, so a few cover the breeding plan;
    --   * the Genetic Sampler destroys a drone per sample and draws one
    --     chromosome at random out of 13, so pulling one specific gene costs
    --     ~13 drones on average, and the failed draws still enrich the library.
    -- A species you only pass through on the way to another needs 2 or 3.
    local target = tonumber(options.target) or 32
    if target < 1 then return nil, "objectif invalide: " .. tostring(options.target) end

    return {
        species = species,
        princess = princess,
        drone = drone,
        target = target,
        -- A broken apiary would otherwise loop until the world ends
        maxCycles = tonumber(options.maxCycles) or (target * 4 + 10),
        cycles = 0,
        cycleTimeout = options.cycleTimeout,
    }
end

--- Has the goal already been met
--- @return boolean
local function satisfied(job, context)
    return stock(context, job.params.drone) >= job.params.target
end

--- Does this label name a bee of the species this campaign is breeding
--- "Common Princess" and "Common Queen" both belong to the Common campaign;
--- "Cultivated Queen" does not, however occupied the slot looks.
--- @param job table
--- @param label string|nil
--- @return boolean
local function isOurs(job, label)
    if not label then return false end

    local species = job.params.species
    return label:sub(1, #species + 1) == species .. " "
end

multiply.STEPS = {
    -- -----------------------------------------------------------------------
    {
        name = "vider-la-sortie-de-l-apiary",
        verify = function(job, context)
            local apiary = machineOf(context, "breeding_apiary")
            if not apiary then return false end
            return satisfied(job, context) or #apiary:outputs() == 0
        end,
        run = function(job, context)
            local apiary, err = machineOf(context, "breeding_apiary")
            if not apiary then return jobs.FAILED, err end

            for _, output in ipairs(apiary:outputs()) do
                apiary:unload(output.slot)
            end

            if #apiary:outputs() > 0 then
                return jobs.RETRY, "la sortie de l'apiary ne se vide pas"
            end

            return jobs.DONE
        end,
    },

    -- -----------------------------------------------------------------------
    {
        name = "charger-le-couple",
        verify = function(job, context)
            local apiary = machineOf(context, "breeding_apiary")
            if not apiary then return false end
            if satisfied(job, context) then return true end

            -- Forestry merges the pair into a queen within a tick, so an
            -- occupied queen slot means the step succeeded even though neither
            -- label matches the princess any more. It must still be OUR bee:
            -- there is one apiary and a breeding job puts its own queen in the
            -- same slot. Accepting any occupant made this job wait on someone
            -- else's cycle and then count their drones as its own.
            return isOurs(job, labelInSlot(apiary, apiary:slots().queen))
        end,
        run = function(job, context)
            local apiary, err = machineOf(context, "breeding_apiary")
            if not apiary then return jobs.FAILED, err end

            local slots = apiary:slots()

            -- One apiary, several jobs. A queen that belongs to a breeding job
            -- is in the middle of its cycle; pulling it out would send it back
            -- to the network where AE2 shows no genome and it is lost among its
            -- kind. Wait instead.
            local occupied = labelInSlot(apiary, slots.queen)
            if occupied and not isOurs(job, occupied)
               and occupied:find(" Queen", 1, true) then
                return jobs.RETRY, "l'apiary travaille deja sur " .. occupied
            end

            -- A leftover from another species blocks the delivery silently:
            -- two different bees never share a slot.
            local function place(spec, slot, role)
                local occupant = labelInSlot(apiary, slot)
                if occupant == spec.label then return true end

                if occupant then
                    apiary:unload(slot)
                    if labelInSlot(apiary, slot) then
                        -- Nothing automated clears a slot the machine will not
                        -- give back. Same situation as breeding, same answer:
                        -- the gesture, at the imperative, with the slot as the
                        -- player sees it. This function asked for a hand and
                        -- was answered with RETRY, so the job parked in silence.
                        return false, "retire " .. tostring(occupant)
                            .. " du slot " .. apiary:resolveSlot(slot)
                            .. " de l apiary (il occupe la place " .. role .. ")",
                            true
                    end
                end

                local ok, reason = apiary:load(spec, slot, 1)
                if not ok then
                    return false, "mets " .. tostring(spec.label or role)
                        .. " dans le reseau ME (" .. tostring(reason) .. ")",
                        true
                end

                return true
            end

            -- place() says whether what stops it needs a hand or just time
            local ok, why, gesture = place(job.params.princess, slots.queen, "princesse")
            if not ok then
                return gesture and jobs.NEEDS_PLAYER or jobs.RETRY, why
            end

            ok, why, gesture = place(job.params.drone, slots.drone, "drone")
            if not ok then
                return gesture and jobs.NEEDS_PLAYER or jobs.RETRY, why
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
            if satisfied(job, context) then return true end
            return apiary:slot(apiary:slots().queen) == nil
        end,
        run = function(job, context)
            local apiary, err = machineOf(context, "breeding_apiary")
            if not apiary then return jobs.FAILED, err end

            local blocking = apiary:environmentErrors()
            if #blocking > 0 then
                local detail = {"l'apiary ne convient pas a cette abeille: "
                    .. table.concat(blocking, ", ")}

                local environment = apiary.getEnvironment and apiary:getEnvironment() or nil
                if type(environment) == "table" then
                    table.insert(detail, "biome " .. tostring(environment.temperature)
                        .. "/" .. tostring(environment.humidity))
                end

                local upgrades = apiary.upgradeNames and apiary:upgradeNames() or {}
                if #upgrades > 0 then
                    table.insert(detail, "upgrades: " .. table.concat(upgrades, ", "))
                end

                -- The apiary only ever says "no flower", never which one. The
                -- genome of the bee sitting in it does say.
                if apiary.flowerRequirement then
                    local _, flower = apiary:flowerRequirement()
                    if flower then
                        table.insert(detail, "fleur requise: " .. flower)
                    end
                end

                return jobs.RETRY, table.concat(detail, " | ")
            end

            local wait = job.params.cycleTimeout
                or (context.config and context.config.breeding
                    and context.config.breeding.cycle_timeout_seconds)
                or 900

            local done, reason = apiary:awaitPrincess(wait)
            if not done then
                reason = tostring(reason) .. " (attente de " .. wait .. " s)"
            end
            if not done then return jobs.RETRY, reason end

            return jobs.DONE
        end,
    },

    -- -----------------------------------------------------------------------
    {
        name = "recolter-et-compter",
        -- No verify: this step is the loop, and skipping it would end the
        -- campaign after a single cycle.
        run = function(job, context)
            local apiary, err = machineOf(context, "breeding_apiary")
            if not apiary then return jobs.FAILED, err end

            for _, output in ipairs(apiary:outputs()) do
                apiary:unload(output.slot)
            end

            if #apiary:outputs() > 0 then
                return jobs.RETRY, "la sortie de l'apiary ne se vide pas"
            end

            job.params.cycles = (job.params.cycles or 0) + 1

            local held = stock(context, job.params.drone)
            report(context, job.params.species .. ": " .. held .. "/"
                .. job.params.target .. " drones apres "
                .. job.params.cycles .. " cycle(s)")

            if held >= job.params.target then
                return jobs.DONE, held .. " drones en stock"
            end

            if job.params.cycles >= job.params.maxCycles then
                -- Looping forever on an apiary that produces nothing is worse
                -- than stopping and saying so
                return jobs.FAILED, job.params.cycles .. " cycles pour "
                    .. held .. "/" .. job.params.target
                    .. " drones: l'apiary ne produit pas assez"
            end

            -- The queue adds one after a DONE, so zero restarts at step one
            job.step = 0

            return jobs.DONE, held .. "/" .. job.params.target .. " drones"
        end,
    },
}

--- The handler to register with the job queue
--- @return table handler
function multiply.handler()
    return {steps = multiply.STEPS}
end

return multiply
