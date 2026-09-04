-- HiveMind breeding chain planner
--
-- Turns "I want Imperial" into the ordered list of crosses that gets there.
--
-- Built on the live mutation data rather than the bundled table, which matters:
-- the game reports several paths to one species, and this picks between them.
-- The old planner could not, because its data model held a single parent pair
-- per species.
--
-- Availability is injected rather than looked up here. What counts as "we have
-- this bee" depends on the ME network, the chest, or a test fixture, and the
-- planner has no business knowing which.

local planner = {}

--- Plan the crosses needed to obtain a species
--- @param options table {registry, available, target, maxDepth}
---   registry   species registry, for parents()
---   available  function(uid) -> boolean, "do we already have this species"
---   target     species uid
--- @return table|nil plan {steps, missing, reachable}
--- @return string|nil error
function planner.plan(options)
    options = options or {}

    local registry = options.registry
    local available = options.available
    local target = options.target
    local maxDepth = options.maxDepth or 24

    if not registry then return nil, "aucun registre d'especes" end
    if type(target) ~= "string" then return nil, "espece cible manquante" end
    if type(available) ~= "function" then available = function() return false end end

    local resolved = {}     -- uid -> solution already computed
    local visiting = {}     -- cycle guard

    --- Solve one species
    --- @return table solution {steps, missing, reachable}
    local function solve(uid, depth)
        if resolved[uid] then return resolved[uid] end

        -- Already in stock: nothing to do, and no reason to look further
        if available(uid) then
            local held = {steps = {}, missing = {}, reachable = true, held = true}
            resolved[uid] = held
            return held
        end

        if depth > maxDepth then
            return {steps = {}, missing = {{uid = uid, reason = "arbre trop profond"}},
                    reachable = false}
        end

        -- A cycle means this path leads back to itself; treat as unreachable
        -- here rather than looping, the other paths may still work
        if visiting[uid] then
            return {steps = {}, missing = {{uid = uid, reason = "dependance circulaire"}},
                    reachable = false}
        end

        local mutations = registry:parents(uid)

        if #mutations == 0 then
            -- A base species we do not hold: only the player can supply it
            local base = {steps = {}, reachable = false,
                          missing = {{uid = uid, reason = "espece de base absente"}}}
            resolved[uid] = base
            return base
        end

        visiting[uid] = true

        local best = nil

        for _, mutation in ipairs(mutations) do
            local princess = solve(mutation.parent1.uid, depth + 1)
            local drone = solve(mutation.parent2.uid, depth + 1)

            -- Steps of both parents, then this cross. Duplicates are removed
            -- later; a species needed twice is bred once.
            local steps = {}
            for _, step in ipairs(princess.steps) do table.insert(steps, step) end
            for _, step in ipairs(drone.steps) do table.insert(steps, step) end

            table.insert(steps, {
                target = uid,
                princess = mutation.parent1,
                drone = mutation.parent2,
                chance = mutation.chance,
                conditions = mutation.conditions,
            })

            local missing = {}
            for _, entry in ipairs(princess.missing) do table.insert(missing, entry) end
            for _, entry in ipairs(drone.missing) do table.insert(missing, entry) end

            local candidate = {
                steps = steps,
                missing = missing,
                reachable = princess.reachable and drone.reachable,
                -- A path needing a foundation block or a specific biome is not
                -- impossible, but it is not automatable either, so it loses
                constrained = #(mutation.conditions or {}) > 0,
            }

            local function better(a, b)
                if not b then return true end
                if a.reachable ~= b.reachable then return a.reachable end
                if a.constrained ~= b.constrained then return b.constrained end
                if #a.missing ~= #b.missing then return #a.missing < #b.missing end
                return #a.steps < #b.steps
            end

            if better(candidate, best) then best = candidate end
        end

        visiting[uid] = nil
        resolved[uid] = best

        return best
    end

    local solution = solve(target, 0)

    -- Deduplicate: the same cross reached through two branches is one cross
    local seen, steps = {}, {}
    for _, step in ipairs(solution.steps) do
        if not seen[step.target] then
            seen[step.target] = true
            table.insert(steps, step)
        end
    end

    local missingSeen, missing = {}, {}
    for _, entry in ipairs(solution.missing) do
        if not missingSeen[entry.uid] then
            missingSeen[entry.uid] = true
            table.insert(missing, entry)
        end
    end

    return {
        target = target,
        steps = steps,
        missing = missing,
        reachable = solution.reachable and #missing == 0,
        held = solution.held == true,
    }
end

--- Plan the crosses needed to obtain SEVERAL species at once
--- The template wants eleven alleles carried by seven bees, and planning them
--- one at a time is both tedious and wasteful: two carriers usually share most
--- of their tree, and a species bred for one is available for the next. Merging
--- the plans is what turns "seven chains" into one ordered list.
---
--- The order is the order of the merged steps, and it already respects
--- dependencies: solve() emits a species' parents before the species itself,
--- and the deduplication keeps the FIRST occurrence, which is the earliest a
--- step could run.
--- @param options table {registry, available, targets, maxDepth}
--- @return table|nil plan {steps, missing, targets, reachable}
--- @return string|nil error
function planner.planMany(options)
    options = options or {}

    local targets = options.targets
    if type(targets) ~= "table" or #targets == 0 then
        return nil, "aucune espece visee"
    end

    -- A species bred for one target is in stock for the next, so availability
    -- grows as the merged plan progresses. Without this the same cross is
    -- planned twice and the second one fails on a princess already spent.
    local produced = {}
    local base = options.available or function() return false end
    local function available(uid)
        return produced[uid] == true or base(uid)
    end

    local steps, seenStep = {}, {}
    local missing, seenMissing = {}, {}
    local outcomes = {}

    for _, target in ipairs(targets) do
        local plan, err = planner.plan({
            registry = options.registry,
            available = available,
            target = target,
            maxDepth = options.maxDepth,
        })

        if not plan then return nil, err end

        for _, step in ipairs(plan.steps) do
            if not seenStep[step.target] then
                seenStep[step.target] = true
                table.insert(steps, step)
                produced[step.target] = true
            end
        end

        for _, entry in ipairs(plan.missing) do
            if not seenMissing[entry.uid] then
                seenMissing[entry.uid] = true
                table.insert(missing, entry)
            end
        end

        table.insert(outcomes, {
            uid = target,
            held = plan.held == true,
            reachable = plan.reachable,
            steps = #plan.steps,
        })
    end

    return {
        targets = outcomes,
        steps = steps,
        missing = missing,
        reachable = #missing == 0,
    }
end

--- Readable rendering of a plan
--- @param plan table
--- @param naming function|nil uid -> display name
--- @return string[] lines
function planner.describe(plan, naming)
    local function name(uid)
        if naming then
            local display = naming(uid)
            if display then return display end
        end
        return uid
    end

    local lines = {}

    if plan.held then
        table.insert(lines, name(plan.target) .. " est deja disponible.")
        return lines
    end

    if #plan.missing > 0 then
        table.insert(lines, "Especes manquantes, a fournir a la main :")
        for _, entry in ipairs(plan.missing) do
            table.insert(lines, "  " .. name(entry.uid) .. "  (" .. entry.reason .. ")")
        end
        table.insert(lines, "")
    end

    table.insert(lines, #plan.steps .. " croisement(s) pour obtenir " .. name(plan.target) .. " :")

    for index, step in ipairs(plan.steps) do
        local line = string.format("  %2d. %s + %s -> %s",
            index, name(step.princess.uid), name(step.drone.uid), name(step.target))

        if step.chance then
            line = line .. string.format("  (%.0f%%)", step.chance)
        end

        table.insert(lines, line)

        -- A cross needing a foundation block will simply never produce, and
        -- nothing in the machine says why
        for _, condition in ipairs(step.conditions or {}) do
            table.insert(lines, "        ! " .. condition)
        end
    end

    return lines
end

return planner
