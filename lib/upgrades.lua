-- HiveMind apiary upgrades
--
-- What an Industrial Apiary complains about, and what answers the complaint.
--
-- The apiary refuses to run a bee whose climate it cannot provide, and it says
-- so in one word: too_hot, too_arid, no_sky. Before this module the queue read
-- that word out loud and then waited for ever, because nothing in the world was
-- going to change on its own.
--
-- The rule here is that THE ATTEMPT IS THE MEASUREMENT. Nobody knows in advance
-- whether the upgrade slots accept an automated insertion: Gendustry refuses
-- extraction from several input slots and the documentation says nothing about
-- these. So the program tries. It looks for the upgrade in the ME network, puts
-- it in a free slot, and reads the slot back. If that works the job carries on.
-- If it does not, the player is told which upgrade to slot in by hand, which is
-- the same sentence either way.
--
-- The keywords below are matched against item LABELS, and they are guesses at
-- how this pack spells them. A wrong guess costs nothing: no upgrade is found,
-- and the player gets the gesture instead of the automatic fix.

local jobs = require("lib.jobs")

local upgrades = {}

--- Codes that name a climate the apiary can be made to provide
--- Keyed by the error code with its namespace stripped ("forestry:too_hot").
--- @type table<string, {gesture: string, keywords: string[]|nil}>
upgrades.ANSWERS = {
    too_hot = {
        gesture = "il fait trop chaud pour cette abeille: ajoute a l apiary un"
            .. " upgrade qui refroidit",
        keywords = {"cooling", "cooler", "refroid"},
    },
    too_cold = {
        gesture = "il fait trop froid pour cette abeille: ajoute a l apiary un"
            .. " upgrade qui chauffe",
        keywords = {"heating", "heater", "chauff"},
    },
    too_humid = {
        gesture = "il fait trop humide pour cette abeille: ajoute a l apiary un"
            .. " upgrade qui asseche",
        keywords = {"drying", "dehumid", "assech"},
    },
    too_arid = {
        gesture = "il fait trop sec pour cette abeille: ajoute a l apiary un"
            .. " upgrade qui humidifie",
        keywords = {"humidif", "humidity"},
    },
    no_sky = {
        gesture = "cette abeille veut voir le ciel: pose l apiary a l air libre"
            .. " ou ajoute l upgrade qui simule le ciel",
        keywords = {"sky", "ciel"},
    },
    not_night = {
        gesture = "cette abeille ne travaille que la nuit: ajoute l upgrade de"
            .. " lumiere qui simule la nuit",
        keywords = {"night", "nocturnal", "nuit"},
    },
    not_day = {
        gesture = "cette abeille ne travaille que le jour: ajoute l upgrade de"
            .. " lumiere qui simule le jour",
        keywords = {"day", "light", "jour"},
    },

    -- Complaints no upgrade answers. Listed anyway, because "il faut ta main"
    -- is only useful when it says which hand, and where.
    no_flower = {
        gesture = "il manque la fleur que cette abeille butine: pose-la a cote"
            .. " de l apiary",
    },
    no_space = {
        gesture = "la sortie de l apiary est pleine: choisis 7 pour la vider",
    },
}

--- The answer for one error code, whatever namespace it arrived with
--- Codes come through as "forestry:too_hot", so only the suffix matters.
--- @param code string
--- @return table|nil answer
--- @return string suffix
function upgrades.answerFor(code)
    local suffix = tostring(code):match("([^:]+)$") or ""
    suffix = suffix:lower()
    return upgrades.ANSWERS[suffix], suffix
end

--- An upgrade item in the ME network matching one of these keywords
--- Restricted to items that call themselves an upgrade, so a keyword like
--- "cooling" cannot come back holding a Cooling Coil block.
--- @param transport table
--- @param keywords string[]
--- @return table|nil spec {name, label}
function upgrades.findInNetwork(transport, keywords)
    if not transport or type(keywords) ~= "table" then return nil end

    for _, keyword in ipairs(keywords) do
        local ok, items = pcall(function()
            return transport:findAll({labelContains = keyword})
        end)

        if ok and type(items) == "table" then
            for _, item in ipairs(items) do
                local label = tostring(item.label or "")
                local name = tostring(item.name or "")

                if label:lower():find("upgrade", 1, true)
                   or name:lower():find("upgrade", 1, true) then
                    return {name = item.name, label = item.label}
                end
            end
        end
    end

    return nil
end

--- An upgrade slot the apiary is not already using
--- @param apiary table
--- @return number|nil slot
function upgrades.freeSlot(apiary)
    local slots = apiary:slots() or {}

    for _, slot in ipairs(slots.upgrades or {}) do
        if apiary:slot(slot) == nil then return slot end
    end

    return nil
end

--- Try to install the upgrade that answers one complaint
--- @param apiary table
--- @param transport table
--- @param answer table Entry from ANSWERS
--- @return string status "installed", "absent", "no_slot", "refused", "manual"
--- @return string|nil detail
function upgrades.install(apiary, transport, answer)
    if not answer or not answer.keywords then return "manual" end

    local spec = upgrades.findInNetwork(transport, answer.keywords)
    if not spec then return "absent" end

    local slot = upgrades.freeSlot(apiary)
    if not slot then
        return "no_slot", "les slots d upgrade de l apiary sont pleins"
    end

    local ok, reason = apiary:load(spec, slot, 1)
    if not ok then return "refused", tostring(reason) end

    -- Read the slot back rather than trusting the delivery: an upgrade slot
    -- that silently rejects the item is exactly the case this exists for
    if apiary:slot(slot) == nil then
        return "refused", "le slot d upgrade n a rien garde"
    end

    return "installed", tostring(spec.label or spec.name)
end

--- What the apiary currently is, in one line, for a message
--- @param apiary table
--- @return string
local function describe(apiary)
    local parts = {}

    local environment = apiary.getEnvironment and apiary:getEnvironment() or nil
    if type(environment) == "table" and environment.temperature then
        parts[#parts + 1] = "biome " .. tostring(environment.temperature)
            .. "/" .. tostring(environment.humidity)
    end

    local installed = apiary.upgradeNames and apiary:upgradeNames() or {}
    if #installed > 0 then
        parts[#parts + 1] = "upgrades: " .. table.concat(installed, ", ")
    end

    -- The apiary only ever says "no flower", never which one. The genome of the
    -- bee sitting in it does say.
    if apiary.flowerRequirement then
        local _, flower = apiary:flowerRequirement()
        if flower then parts[#parts + 1] = "fleur requise: " .. flower end
    end

    return table.concat(parts, " | ")
end

--- Deal with everything the apiary is complaining about
---
--- Called from the step that waits on a cycle, in both breeding and multiply:
--- the two carried the same twenty lines and the same dead end, and a bee that
--- cannot live in the apiary blocks either of them identically.
--- @param apiary table
--- @param context table
--- @param job table Records what has already been tried, on disk
--- @param blocking string[] Error codes
--- @return string outcome jobs.RETRY or jobs.NEEDS_PLAYER
--- @return string detail
function upgrades.resolve(apiary, context, job, blocking)
    job.params.upgradeTried = job.params.upgradeTried or {}

    local installed, gestures, unknown = {}, {}, {}

    for _, code in ipairs(blocking) do
        local answer, suffix = upgrades.answerFor(code)

        if not answer then
            table.insert(unknown, code)
        elseif not answer.keywords then
            -- Nothing to install: only a hand fixes this one
            table.insert(gestures, answer.gesture)
        elseif job.params.upgradeTried[suffix] then
            -- Tried once and the complaint is still here, so the attempt is
            -- settled: it is a gesture now, not a wait
            table.insert(gestures, answer.gesture)
        else
            job.params.upgradeTried[suffix] = true

            local status, detail = upgrades.install(apiary, context.transport, answer)

            if status == "installed" then
                table.insert(installed, detail)
            elseif status == "absent" then
                table.insert(gestures, answer.gesture
                    .. " (aucun dans le reseau ME)")
            else
                table.insert(gestures, answer.gesture
                    .. (detail and (" -- " .. detail) or ""))
            end
        end
    end

    if #installed > 0 then
        -- Something changed in the world: the next pass reads the apiary again
        -- instead of deciding now on a state that no longer holds
        return jobs.RETRY, "upgrade pose: " .. table.concat(installed, ", ")
    end

    if #gestures > 0 then
        return jobs.NEEDS_PLAYER, table.concat(gestures, " | ")
    end

    -- A complaint nothing here recognizes stays a wait, which is what it was
    -- before this module existed: guessing wrong is worse than waiting
    local detail = "l apiary ne convient pas a cette abeille: "
        .. table.concat(unknown, ", ")
    local state = describe(apiary)

    return jobs.RETRY, state ~= "" and (detail .. " | " .. state) or detail
end

return upgrades
