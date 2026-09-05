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
        -- genomes: species -> {[slot] = "allele uid"}, learned by reading a bee
        index = {templates = {}, nextTemplateId = 1, genomes = {}},
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
        -- Added after the first files were written, so an older one has none
        self.index.genomes = stored.genomes or {}
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

--- Remember every allele a species was seen carrying
--- Which species carries which allele is the one thing that decides what is
--- worth breeding, and it cannot be read from the network: AE2 hides NBT. It
--- can only be learned by parking a bee in the apiary and reading it -- so what
--- is read once is written down, and never has to be read again.
--- @param species string As the drone label spells it, without " Drone"
--- @param chromosomes table Parsed genome
--- @return number recorded How many chromosomes were stored
function Library:recordGenome(species, chromosomes)
    if type(species) ~= "string" or species == "" then return 0 end
    if type(chromosomes) ~= "table" then return 0 end

    self:load()
    self.index.genomes = self.index.genomes or {}

    local seen = {}
    local recorded = 0

    for slot = 0, 12 do
        local active, inactive = genome.alleles(chromosomes, slot)

        -- The recessive counts: it is invisible on the bee but passes to its
        -- offspring, and the Sampler can draw it
        if active then
            seen[tostring(slot)] = {active = active, inactive = inactive}
            recorded = recorded + 1
        end
    end

    if recorded == 0 then return 0 end

    self.index.genomes[species] = seen
    self:save()

    return recorded
end

--- Every species known to carry an allele, from what has been read
--- @param slot number
--- @param uidSuffix string Allele as a sample label spells it, e.g. "Both 3"
--- @return string[] species
function Library:carriersOf(slot, uidSuffix)
    self:load()

    local function flatten(text)
        return tostring(text):lower():gsub("[^%w]", "")
    end

    local target = flatten(uidSuffix)
    if target == "" then return {} end

    local found = {}

    for species, chromosomes in pairs(self.index.genomes or {}) do
        local entry = chromosomes[tostring(slot)]

        if entry then
            -- Suffix, never substring: floweringSlowest would answer for Slow,
            -- which is the opposite value
            for _, uid in ipairs({entry.active, entry.inactive}) do
                local flat = uid and flatten(uid) or ""
                if #flat >= #target and flat:sub(-#target) == target then
                    table.insert(found, species)
                    break
                end
            end
        end
    end

    table.sort(found)
    return found
end

--- Which species have been read at all
--- @return table species -> number of chromosomes recorded
function Library:knownGenomes()
    self:load()

    local known = {}
    for species, chromosomes in pairs(self.index.genomes or {}) do
        local count = 0
        for _ in pairs(chromosomes) do count = count + 1 end
        known[species] = count
    end

    return known
end

--- How many copies of one allele are held
--- @param slot number Chromosome slot
--- @param allele string Allele as printed on the sample
--- @return number count
function Library:count(slot, allele)
    local genes = self:allGenes()
    local chromosome = genes[slot]
    if not chromosome then return 0 end

    -- Folded lookup: the game writes "immortal" where the guide writes
    -- "Immortal", and an exact table lookup makes those two unrelated keys
    local entry = genome.lookupAllele(chromosome, allele)
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
    local entry = genome.lookupAllele(chromosome, allele)

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

--- Keep a template's photograph on a durable database page
---
--- A template can only be requested from the network by a page that already
--- holds its nbt, and photographing needs the item in hand -- which is exactly
--- what we no longer have once it is in the network. So the photograph is taken
--- while the template is still in the chest, and kept.
---
--- The page number is only a hint: pages get overwritten, and the fingerprint
--- is what identifies the template. Losing the page means re-photographing from
--- the chest, not losing the template.
--- @param entry table Record from registerTemplate
--- @return number|nil page
--- @return string|nil error
function Library:keepPhotograph(entry)
    if not self.transport or not self.templateLink then
        return nil, "aucun acces au coffre a templates"
    end

    if not entry or not entry.slot then return nil, "template inconnu" end

    -- Already there? The hash finds it whatever page it drifted to.
    --
    -- Except the scratch page: registerTemplate fingerprints through it, so it
    -- always holds the last template looked at. Adopting it as a durable page
    -- means the next fingerprint silently overwrites the photograph, and the
    -- template becomes unrequestable without anything saying so.
    local existing = self.transport:pageFor(entry.hash)
    if existing and existing ~= self.scratchDbSlot then
        entry.page = existing
        self:save()
        return existing
    end

    -- Never take a page another template is using
    local reserved = {[self.scratchDbSlot] = true}
    for _, other in pairs(self.index.templates) do
        if other.page and other ~= entry then reserved[other.page] = true end
    end

    local page = self.transport:freePage(reserved)
    if not page then
        return nil, "plus une seule page libre dans la database ("
            .. tostring(self.transport:databaseCapacity())
            .. " au total): un upgrade de tier superieur en donnerait plus"
    end

    local hash, err =
        self.transport:fingerprint(self.templateLink, entry.slot, page, true)

    if not hash then return nil, err end

    entry.page = page
    entry.hash = hash
    self:save()

    return page
end

--- Ask the network for a recorded template, staged so a transposer can take it
--- @param entry table Record from registerTemplate
--- @param link table Machine link of the bench that will receive it
--- @return number|nil dock
--- @return string|nil error
function Library:requestTemplate(entry, link)
    if not self.transport then return nil, "aucun transport" end
    if not entry then return nil, "template inconnu" end

    local page = self.transport:pageFor(entry.hash)

    -- The photograph is gone: retake it, which needs the template in the chest
    if not page then
        local kept, err = self:keepPhotograph(entry)
        if not kept then
            return nil, "photo perdue et le coffre ne la rend pas: "
                .. tostring(err)
        end
        page = kept
    end

    return self.transport:stageFromDatabase(page, link, 1)
end

--- Put a recorded template into a machine slot
--- Refuses unless what the network hands over fingerprints identically. The
--- alternative is writing whatever genes turned up onto a live bee.
--- @param entry table Record from registerTemplate
--- @param link table Machine link
--- @param slot number Machine slot
--- @return boolean ok
--- @return string|nil error
function Library:deliverTemplate(entry, link, slot)
    if not self.transport then return false, "aucun transport" end
    if not entry or not entry.hash then return false, "template inconnu" end

    local page = self.transport:pageFor(entry.hash)

    if not page or page == self.scratchDbSlot then
        local kept, err = self:keepPhotograph(entry)
        if not kept then
            return false, "fiche perdue et le coffre ne la rend pas: "
                .. tostring(err)
        end
        page = kept
    end

    return self.transport:deliverExact(page, entry.hash, link, slot,
                                       self.scratchDbSlot)
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

    -- "Especes archivees" ne disait pas ce qui etait archive, ni ou. Ce sont
    -- les genes d espece sauves: la collection vers laquelle tout le programme
    -- travaille, puisqu un seul de ces genes suffit a reimprimer l espece.
    local species_count = 0
    for _ in pairs(self:speciesGenes()) do species_count = species_count + 1 end
    table.insert(lines, string.format("Genes d espece sauves : %d", species_count))

    local shortages = self:shortages()
    if #shortages > 0 then
        table.insert(lines, string.format("A securiser : %d %s en moins de %d %s",
            #shortages, #shortages > 1 and "genes" or "gene",
            self.minimumCopies,
            self.minimumCopies > 1 and "exemplaires" or "exemplaire"))
        table.insert(lines,
            "  un gene en un seul exemplaire disparait avec lui, et le")
        table.insert(lines,
            "  retrouver coute une treizaine d abeilles.")
        -- "Option c" ne dit pas ou la trouver: elle est sous 9, comme les
        -- vingt autres, et le reste du programme ecrit toujours les deux
        table.insert(lines,
            "  Choisis 9 puis c pour les copier.")
    end

    -- A count answers "how many" and never "which one", and which one is the
    -- only question anybody has: every template shares a label, so this list is
    -- the only place their names exist.
    local templates = self:templates()
    table.insert(lines, string.format("Templates nommes : %d", #templates))

    local shown = 0
    for _, entry in ipairs(templates) do
        if shown < 15 then
            shown = shown + 1

            table.insert(lines, string.format("  %-22s %-24s %s",
                tostring(entry.name or entry.species or "sans nom"),
                -- Sans entree dans la Database il ne peut pas etre redemande
                -- au reseau: un template qu on voit et qu on ne peut pas
                -- utiliser. Le numero de page etait un detail de mecanique --
                -- ce qui compte est de pouvoir le ravoir ou non.
                entry.page and "demandable au reseau ME"
                    or "PAS DEMANDABLE",
                -- Where it was when it was named. It goes stale as soon as the
                -- template is put into the network, and that is fine: identity
                -- is the fingerprint, not the position.
                "nomme au slot " .. tostring(entry.slot) .. " du coffre"))
        end
    end

    if #templates > shown then
        table.insert(lines, "  ... et " .. (#templates - shown) .. " autre(s)")
    end

    -- "PAS DEMANDABLE" nomme un etat sans dire quoi en faire. Tous les
    -- templates partagent une etiquette, donc AE2 ne sait pas les distinguer:
    -- sans sa photographie dans la Database, celui-la ne ressortira jamais du
    -- reseau et doit rester dans le coffre.
    local unreachable = 0
    for _, entry in ipairs(templates) do
        if not entry.page then unreachable = unreachable + 1 end
    end

    if unreachable > 0 then
        table.insert(lines, "  " .. unreachable .. " ne peuvent pas etre"
            .. " ressortis du reseau ME: laisse-les au coffre, ou")
        table.insert(lines, "  choisis 9 puis n pour les photographier.")
    end

    return lines
end

library.SAMPLE_ITEM = SAMPLE_ITEM
library.TEMPLATE_ITEM = TEMPLATE_ITEM

return library
