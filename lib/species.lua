-- HiveMind species registry
--
-- Where the program learns which bees exist and how to breed them.
--
-- The source of truth is the game itself: the Industrial Apiary driver exposes
-- listAllSpecies() and getBeeParents(), which the hardcoded table never could
-- match. Calibration measured 329 live species against 304 hardcoded ones, and
-- the live data carries two things the table has no way to express:
--
--   * several mutation paths for one species (getBeeParents returns an array),
--   * mutation chance and special conditions, e.g. "Requires blockNickel as a
--     foundation." - plan a step that ignores those and the Mutatron simply
--     never produces anything, with no way to explain why.
--
-- Queries are cached on disk. Pulling the parents of 329 species one by one is
-- far too slow to redo at every boot, so parents are fetched lazily and kept.
-- With no apiary reachable the registry degrades to the bundled table, clearly
-- flagged as such, so planning still works offline and in tests.

local state = require("lib.state")

local species = {}

local CACHE_VERSION = 1

local Registry = {}
Registry.__index = Registry

--- Create a registry
--- @param options table|nil {apiary, cachePath, fallback}
---   apiary    component exposing listAllSpecies/getBeeParents (nil = offline)
---   cachePath where to persist what was learned
---   fallback  bundled mutations table, keyed by display name
--- @return table registry
function species.new(options)
    options = options or {}

    return setmetatable({
        apiary = options.apiary,
        cachePath = options.cachePath or state.pathFor("species"),
        fallback = options.fallback,
        cache = {
            version = CACHE_VERSION,
            species = {},   -- uid -> {uid, name}
            parents = {},   -- uid -> array of mutation entries
        },
        loaded = false,
    }, Registry)
end

--- Call a component method without ever letting it abort the caller
--- @param component table|nil
--- @param method string
--- @return boolean ok
--- @return any result
local function invoke(component, method, ...)
    if not component then return false, "aucun composant apiary" end

    local target = component[method]
    if target == nil then return false, "methode " .. method .. " absente" end

    return pcall(target, ...)
end

--- Load the disk cache, once
--- @return boolean ok
--- @return string|nil error
function Registry:load()
    if self.loaded then return true end

    local cached, err = state.load(self.cachePath, nil)

    if err then
        -- A corrupted cache is rebuildable; say so and carry on empty rather
        -- than refusing to start.
        self.loaded = true
        return false, "cache illisible, il sera reconstruit: " .. err
    end

    if cached and cached.version == CACHE_VERSION then
        self.cache = cached
        self.cache.species = self.cache.species or {}
        self.cache.parents = self.cache.parents or {}
    end

    self.loaded = true
    return true
end

--- Persist what has been learned
--- @return boolean ok
--- @return string|nil error
function Registry:save()
    return state.save(self.cachePath, self.cache)
end

--- Pull the full species list from the game
--- @return number|nil count Species learned
--- @return string|nil error
function Registry:refresh()
    self:load()

    local ok, result = invoke(self.apiary, "listAllSpecies")
    if not ok then return nil, tostring(result) end
    if type(result) ~= "table" then return nil, "listAllSpecies n'a pas rendu de table" end

    local learned = {}
    local count = 0

    for _, entry in pairs(result) do
        if type(entry) == "table" and entry.uid then
            -- Index on uid: some names are unresolved lang keys such as
            -- "gendustry.bees.species.NerdySpider", uid never is.
            learned[entry.uid] = {uid = entry.uid, name = entry.name or entry.uid}
            count = count + 1
        end
    end

    if count == 0 then return nil, "listAllSpecies n'a rendu aucune espece exploitable" end

    self.cache.species = learned
    self.cache.source = "live"
    return count
end

--- Every known species
--- Falls back to the bundled table when the game was never reached.
--- @return table<string, {uid: string, name: string}> byUid
--- @return string source "live", "cache" or "fallback"
function Registry:list()
    self:load()

    if next(self.cache.species) then
        return self.cache.species, self.cache.source or "cache"
    end

    if self.fallback then
        local built = {}
        for name, data in pairs(self.fallback) do
            built[name] = {uid = name, name = name}
            -- Parents are species too, and base species never appear as keys
            for _, parent in ipairs(data.parents or {}) do
                built[parent] = built[parent] or {uid = parent, name = parent}
            end
        end
        return built, "fallback"
    end

    return {}, "vide"
end

--- Normalize whatever getBeeParents returned into our own shape
--- @param raw table
--- @return table[] mutations
local function normalizeParents(raw)
    local mutations = {}

    for _, entry in pairs(raw) do
        if type(entry) == "table" and entry.allele1 and entry.allele2 then
            local conditions = {}
            for _, condition in ipairs(entry.specialConditions or {}) do
                table.insert(conditions, tostring(condition))
            end

            table.insert(mutations, {
                parent1 = {
                    uid = entry.allele1.uid or entry.allele1.name,
                    name = entry.allele1.name or entry.allele1.uid,
                },
                parent2 = {
                    uid = entry.allele2.uid or entry.allele2.name,
                    name = entry.allele2.name or entry.allele2.uid,
                },
                chance = tonumber(entry.chance),
                conditions = conditions,
            })
        end
    end

    return mutations
end

--- Mutation paths producing a species
--- Fetched from the game on first ask, then cached. An empty array is cached
--- too: "this species has no parents" is an answer worth remembering, and it is
--- how base species are recognized.
--- @param uid string Species uid, or display name in fallback mode
--- @return table[] mutations Possibly empty
--- @return string source "cache", "live" or "fallback"
function Registry:parents(uid)
    self:load()

    if type(uid) ~= "string" then return {}, "invalide" end

    local cached = self.cache.parents[uid]
    if cached then return cached, "cache" end

    local ok, result = invoke(self.apiary, "getBeeParents", uid)

    -- Calibration queried it with a display name and got an answer; whether the
    -- uid works is unknown, so an empty result is retried with the name before
    -- concluding the species has no parents.
    if ok and type(result) == "table" and next(result) == nil then
        local entry = self.cache.species[uid]
        if entry and entry.name and entry.name ~= uid then
            local retry_ok, retried = invoke(self.apiary, "getBeeParents", entry.name)
            if retry_ok and type(retried) == "table" and next(retried) ~= nil then
                ok, result = retry_ok, retried
            end
        end
    end

    if ok and type(result) == "table" then
        local mutations = normalizeParents(result)
        self.cache.parents[uid] = mutations
        return mutations, "live"
    end

    -- Offline: read the bundled table, which only knows one path per species
    if self.fallback then
        local data = self.fallback[uid]
        if data and data.parents then
            local mutations = {{
                parent1 = {uid = data.parents[1], name = data.parents[1]},
                parent2 = {uid = data.parents[2], name = data.parents[2]},
                chance = nil,
                conditions = {},
            }}
            return mutations, "fallback"
        end
        return {}, "fallback"
    end

    return {}, "inconnu"
end

--- Key for an unordered pair of parents
--- @param a string
--- @param b string
--- @return string
local function pairKey(a, b)
    if a <= b then return a .. "|" .. b end
    return b .. "|" .. a
end

--- Build the reverse index: which species a given pair of parents produces
--- getBeeParents only answers the forward question, so the reverse has to be
--- assembled once by asking about every species. That is slow - several hundred
--- component calls - which is exactly why it is cached on disk and never
--- rebuilt unless asked.
--- @param onProgress function|nil Called with (done, total, name)
--- @return number pairs Number of parent pairs indexed
--- @return string|nil error
function Registry:buildOffspringIndex(onProgress)
    self:load()

    local all, source = self:list()
    if source == "vide" then return 0, "aucune espece connue" end

    local names = {}
    for uid in pairs(all) do table.insert(names, uid) end
    table.sort(names)

    local index = {}
    local pairs_found = 0

    for position, uid in ipairs(names) do
        for _, mutation in ipairs(self:parents(uid)) do
            local key = pairKey(mutation.parent1.uid, mutation.parent2.uid)

            if not index[key] then
                index[key] = {}
                pairs_found = pairs_found + 1
            end

            table.insert(index[key], uid)
        end

        if onProgress and position % 10 == 0 then
            pcall(onProgress, position, #names, all[uid] and all[uid].name)
        end
    end

    self.cache.offspring = index
    return pairs_found
end

--- Species that two parents can produce
--- @param a string Parent species uid
--- @param b string Parent species uid
--- @return string[] uids
--- @return boolean built True when the index exists at all
function Registry:offspringOf(a, b)
    self:load()

    local index = self.cache.offspring
    if not index then return {}, false end

    if type(a) ~= "string" or type(b) ~= "string" then return {}, true end

    return index[pairKey(a, b)] or {}, true
end

--- Is the reverse index available
--- @return boolean
function Registry:hasOffspringIndex()
    self:load()
    return self.cache.offspring ~= nil
end

--- A species the program can never produce, only be given
--- @param uid string
--- @return boolean isBase
function Registry:isBase(uid)
    return #(self:parents(uid)) == 0
end

--- Mutation paths that need something beyond two parents
--- These are the ones a planner must not treat as ordinary steps.
--- @param uid string
--- @return table[] constrained
function Registry:constrainedPaths(uid)
    local constrained = {}

    for _, mutation in ipairs(self:parents(uid)) do
        if #mutation.conditions > 0 then
            table.insert(constrained, mutation)
        end
    end

    return constrained
end

--- Species behind a bee item label
--- "Meadows Princess" names the species Meadows. An exact match after stripping
--- the role is not enough: display names do not always equal the word used in
--- the item label, so the label is also matched against every known species
--- name, longest first so "Light Gray" wins over "Gray".
--- @param label string
--- @return table|nil entry
function Registry:fromBeeLabel(label)
    if type(label) ~= "string" then return nil end

    local base = label
    for _, suffix in ipairs({" Princess", " Drone", " Queen", " princess", " drone", " queen"}) do
        base = base:gsub(suffix .. "$", "")
    end

    local exact = self:resolve(base)
    if exact then return exact end

    -- Fall back to matching species names inside the label
    local lowered = label:lower()
    local best = nil

    for _, entry in pairs(self:list()) do
        local name = entry.name
        if type(name) == "string" and name ~= "" then
            local needle = name:lower()
            local start_pos, end_pos = lowered:find(needle, 1, true)

            if start_pos then
                local before = start_pos > 1 and lowered:sub(start_pos - 1, start_pos - 1) or " "
                local after = end_pos < #lowered and lowered:sub(end_pos + 1, end_pos + 1) or " "

                if not before:match("%a") and not after:match("%a") then
                    if not best or #name > #best.name then best = entry end
                end
            end
        end
    end

    return best
end

--- A few species names, to show what the registry actually holds
--- Printed when a lookup fails: the shape of the real names is the one thing
--- that cannot be guessed from outside the game.
--- @param count number|nil
--- @return string[] samples
function Registry:sampleNames(count)
    local samples = {}

    for uid, entry in pairs(self:list()) do
        table.insert(samples, tostring(entry.name) .. "  (" .. tostring(uid) .. ")")
        if #samples >= (count or 5) then break end
    end

    table.sort(samples)
    return samples
end

--- Find a species by uid or by display name
--- @param needle string
--- @return table|nil entry
function Registry:resolve(needle)
    if type(needle) ~= "string" then return nil end

    local all = self:list()
    if all[needle] then return all[needle] end

    local lowered = needle:lower()
    for _, entry in pairs(all) do
        if entry.name and entry.name:lower() == lowered then
            return entry
        end
    end

    return nil
end

--- How many species and paths are known
--- @return table stats {species, withParents, base, constrained, source}
function Registry:stats()
    local all, source = self:list()

    local total, with_parents, constrained = 0, 0, 0
    for _ in pairs(all) do total = total + 1 end

    for uid, mutations in pairs(self.cache.parents) do
        if #mutations > 0 then with_parents = with_parents + 1 end
        for _, mutation in ipairs(mutations) do
            if #mutation.conditions > 0 then
                constrained = constrained + 1
                break
            end
        end
    end

    return {
        species = total,
        withParents = with_parents,
        pathsKnown = 0,
        constrained = constrained,
        source = source,
    }
end

return species
