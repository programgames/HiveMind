-- HiveMind gene library
--
-- Two collections that could not be more different in how they are tracked.
--
-- Gene samples live in the ME network and need no bookkeeping at all: Gendustry
-- writes the gene into the item's display name ("Bee Sample - Species:
-- Cultivated"), so the network itself is the inventory. Reading it is always
-- correct, even if someone adds or removes samples by hand.
--
-- Genetic templates are the opposite. They all share one item id and one label,
-- and no machine slot exposes their NBT, so nothing about them can be read.
-- They live in a dedicated chest, one per slot, and the program remembers what
-- it put where. That memory is verifiable rather than merely hopeful:
-- transposer.store() copies a stack into a Database upgrade and
-- database.computeHash() yields a stable SHA-256, so a template that was moved,
-- swapped or consumed is detected instead of silently trusted.
--
-- The rule that follows: the template chest is the program's, and a human
-- reorganizing it invalidates the index. Everything else tolerates meddling.

local genome = require("lib.genome")
local state = require("lib.state")

local library = {}

local SAMPLE_ITEM = "gendustry:gene_sample"
local TEMPLATE_ITEM = "gendustry:gene_template"

local Library = {}
Library.__index = Library

--- Create the library
--- @param options table {transport, config, path, templateLink, scratchDbSlot}
--- @return table library
function library.new(options)
    options = options or {}

    local settings = (options.config and options.config.library) or {}

    return setmetatable({
        transport = options.transport,
        templateLink = options.templateLink,
        path = options.path or state.pathFor("library"),
        scratchDbSlot = options.scratchDbSlot or 9,
        minimumCopies = settings.minimum_copies or 2,
        targetCopies = settings.target_copies or 3,
        index = {templates = {}, nextTemplateId = 1},
        genes = nil,          -- built by scan()
        loaded = false,
    }, Library)
end

--- Load the template index from disk
--- @return boolean ok
--- @return string|nil error
function Library:load()
    if self.loaded then return true end
    self.loaded = true

    local stored, err = state.load(self.path, nil)

    if err then
        -- The template index is the one thing that cannot be rebuilt by
        -- looking around, so losing it is worth shouting about.
        return false, "index des templates illisible: " .. err
    end

    if stored and type(stored.templates) == "table" then
        self.index = stored
        self.index.nextTemplateId = stored.nextTemplateId or 1
    end

    return true
end

--- Persist the template index
function Library:save()
    return state.save(self.path, self.index)
end

-- ---------------------------------------------------------------------------
-- Gene samples
-- ---------------------------------------------------------------------------

--- Read every gene sample the ME network holds
--- No cache: the network is the truth, and reading it is cheap compared to
--- being wrong about what we own.
--- @return table genes slot -> allele -> {count, label, chromosome}
--- @return number total Distinct alleles found
function Library:scan()
    local genes = {}
    local total = 0

    if not self.transport then
        self.genes = genes
        return genes, 0
    end

    local ok, items = pcall(function()
        return self.transport.me and self.transport.me.getItemsInNetwork({name = SAMPLE_ITEM})
    end)

    if not ok or type(items) ~= "table" then
        -- Retry unfiltered: some builds reject the filter argument
        local retry_ok, all = pcall(function()
            return self.transport.me and self.transport.me.getItemsInNetwork()
        end)
        items = (retry_ok and type(all) == "table") and all or {}
    end

    for _, item in pairs(items) do
        if type(item) == "table" and item.name == SAMPLE_ITEM and item.label then
            local sample = genome.parseSampleLabel(item.label)

            if sample and sample.slot then
                genes[sample.slot] = genes[sample.slot] or {}

                local entry = genes[sample.slot][sample.allele]
                if not entry then
                    entry = {count = 0, label = item.label,
                             chromosome = sample.chromosome, allele = sample.allele}
                    genes[sample.slot][sample.allele] = entry
                    total = total + 1
                end

                entry.count = entry.count + (tonumber(item.size) or 0)
            end
        end
    end

    self.genes = genes
    return genes, total
end

--- Genes currently known, scanning if needed
--- @return table genes
function Library:allGenes()
    if not self.genes then self:scan() end
    return self.genes
end

--- How many copies of one allele are held
--- @param slot number Chromosome slot
--- @param allele string Allele as printed on the sample
--- @return number count
function Library:count(slot, allele)
    local genes = self:allGenes()
    local chromosome = genes[slot]
    if not chromosome then return 0 end

    local entry = chromosome[allele]
    return entry and entry.count or 0
end

--- Do we hold this allele at all
--- @param slot number
--- @param allele string
--- @return boolean
function Library:has(slot, allele)
    return self:count(slot, allele) > 0
end

--- The sample specification the transport layer needs to fetch one
--- @param slot number
--- @param allele string
--- @return table|nil spec {name, label}
function Library:specFor(slot, allele)
    local genes = self:allGenes()
    local chromosome = genes[slot]
    local entry = chromosome and chromosome[allele]

    if not entry then return nil end

    return {name = SAMPLE_ITEM, label = entry.label}
end

--- Alleles held in too few copies to be spent safely
--- Consuming the last copy of a gene loses it, possibly for good, so the
--- program duplicates through the Genetic Transposer before spending one.
--- @return table[] shortages {slot, allele, count, needed}
function Library:shortages()
    local shortages = {}

    for slot, chromosome in pairs(self:allGenes()) do
        for allele, entry in pairs(chromosome) do
            if entry.count < self.minimumCopies then
                table.insert(shortages, {
                    slot = slot,
                    allele = allele,
                    label = entry.label,
                    count = entry.count,
                    needed = self.targetCopies - entry.count,
                })
            end
        end
    end

    table.sort(shortages, function(a, b)
        if a.slot ~= b.slot then return a.slot < b.slot end
        return a.allele < b.allele
    end)

    return shortages
end

--- Which alleles of a profile are still missing
--- @param profile table<number, string> slot -> wanted allele
--- @return table[] missing {slot, chromosome, allele}
--- @return boolean complete
function Library:missingForProfile(profile)
    local missing = {}

    for slot, allele in pairs(profile or {}) do
        if not self:has(slot, allele) then
            table.insert(missing, {
                slot = slot,
                chromosome = genome.labelForSlot(slot),
                allele = allele,
            })
        end
    end

    table.sort(missing, function(a, b) return a.slot < b.slot end)

    return missing, #missing == 0
end

--- Species whose Species gene we hold
--- This is the collection the whole project is aimed at: with one of these plus
--- a set of good alleles, any species can be printed on demand.
--- @return table<string, number> species allele name -> copies
function Library:speciesGenes()
    local held = {}

    for allele, entry in pairs(self:allGenes()[genome.SPECIES_SLOT] or {}) do
        held[allele] = entry.count
    end

    return held
end

-- ---------------------------------------------------------------------------
-- Templates
-- ---------------------------------------------------------------------------

--- Record a template that was just built
--- The fingerprint is what makes the record verifiable later.
--- @param slot number Slot in the template chest
--- @param description table {species, contents, complete}
--- @return table|nil entry
--- @return string|nil error
function Library:registerTemplate(slot, description)
    self:load()

    if not self.transport or not self.templateLink then
        return nil, "aucun acces au coffre a templates"
    end

    local hash, err = self:fingerprint(slot)
    if not hash then return nil, err end

    local entry = {
        id = self.index.nextTemplateId,
        slot = slot,
        hash = hash,
        species = description and description.species,
        contents = description and description.contents or {},
        complete = description and description.complete or false,
    }

    self.index.nextTemplateId = entry.id + 1
    self.index.templates[tostring(slot)] = entry

    local saved, save_err = self:save()
    if not saved then return nil, save_err end

    return entry
end

--- Fingerprint whatever sits in a template chest slot
--- @param slot number
--- @return string|nil hash
--- @return string|nil error
function Library:fingerprint(slot)
    if not self.transport or not self.templateLink then
        return nil, "aucun acces au coffre a templates"
    end

    return self.transport:fingerprint(self.templateLink, slot, self.scratchDbSlot, true)
end

--- What the index says about a slot
--- @param slot number
--- @return table|nil entry
function Library:template(slot)
    self:load()
    return self.index.templates[tostring(slot)]
end

--- Every recorded template
--- @return table[] entries
function Library:templates()
    self:load()

    local list = {}
    for _, entry in pairs(self.index.templates) do table.insert(list, entry) end
    table.sort(list, function(a, b) return a.slot < b.slot end)

    return list
end

--- The template holding a species, if we built one
--- @param speciesUid string
--- @return table|nil entry
function Library:templateFor(speciesUid)
    for _, entry in ipairs(self:templates()) do
        if entry.species == speciesUid then return entry end
    end
    return nil
end

--- Check the index against the chest
--- Every recorded slot is re-fingerprinted and compared. This is the only
--- defence against a human having reorganized the chest, and it must run before
--- any template is used for anything irreversible.
--- @return boolean intact
--- @return table[] discrepancies {slot, expected, found, reason}
function Library:verify()
    self:load()

    local discrepancies = {}

    for _, entry in ipairs(self:templates()) do
        local hash, err = self:fingerprint(entry.slot)

        if not hash then
            table.insert(discrepancies, {
                slot = entry.slot, expected = entry.hash, found = nil,
                reason = err or "slot vide",
            })
        elseif hash ~= entry.hash then
            table.insert(discrepancies, {
                slot = entry.slot, expected = entry.hash, found = hash,
                reason = "le contenu du slot a change",
            })
        end
    end

    return #discrepancies == 0, discrepancies
end

--- Forget a template, after it was deliberately consumed or replaced
--- @param slot number
--- @return boolean ok
function Library:forgetTemplate(slot)
    self:load()

    if not self.index.templates[tostring(slot)] then return false end

    self.index.templates[tostring(slot)] = nil
    return (self:save())
end

--- First slot of the template chest holding nothing we know about
--- @param capacity number Slots in the chest
--- @return number|nil slot
function Library:freeTemplateSlot(capacity)
    self:load()

    for slot = 1, capacity or 27 do
        if not self.index.templates[tostring(slot)] then
            -- Trust but check: an unrecorded slot may still hold something
            local stack = self.transport and self.templateLink
                and self.transport:inspect(self.templateLink, slot) or nil
            if not stack then return slot end
        end
    end

    return nil
end

--- Human summary, for the report shown at startup
--- @return string[] lines
function Library:describe()
    local lines = {}

    local genes = self:allGenes()
    local chromosomes, alleles = 0, 0

    for _, chromosome in pairs(genes) do
        chromosomes = chromosomes + 1
        for _ in pairs(chromosome) do alleles = alleles + 1 end
    end

    table.insert(lines, string.format("Genes : %d alleles sur %d chromosomes",
        alleles, chromosomes))

    local species_count = 0
    for _ in pairs(self:speciesGenes()) do species_count = species_count + 1 end
    table.insert(lines, string.format("Especes archivees : %d", species_count))

    local shortages = self:shortages()
    if #shortages > 0 then
        table.insert(lines, string.format("A dupliquer : %d allele(s) en dessous de %d copies",
            #shortages, self.minimumCopies))
    end

    table.insert(lines, string.format("Templates indexes : %d", #self:templates()))

    return lines
end

library.SAMPLE_ITEM = SAMPLE_ITEM
library.TEMPLATE_ITEM = TEMPLATE_ITEM

return library
