-- HiveMind genome layer
--
-- Reads the genetics the game actually exposes, rather than guessing from item
-- names. Two very different sources feed this module:
--
--   1. The raw NBT of a bee parked in a machine slot, handed over by The
--      Apiarist Terminal drivers (DriverApiary/DriverAdvMutatron dump
--      stack.getTagCompound().toString() verbatim). This is the only way to see
--      a genome: OpenComputers keeps NBT out of ordinary item descriptors
--      (settings.conf: allowItemStackNBTTags = false).
--
--   2. The display label of a Gene Sample. Gendustry overrides
--      getItemStackDisplayName for that item, so the label spells out the gene:
--      "Bee Sample - Species: Cultivated". Templates get no such treatment,
--      which is why they stay opaque and have to be fingerprinted instead.
--
-- Every format here was captured from a live game (see tools/calibrate.lua),
-- not inferred from source reading.

local genome = {}

--- The thirteen bee chromosomes, in Forestry's karyotype order
--- Slot indices come from the NBT dumps; labels come from Gendustry's
--- en_US.lang (gendustry.chromosome.*), which is what a sample label carries.
--- Note FLOWER_PROVIDER displays as "Flowers", not "Flower provider".
--- @type table<number, {key: string, label: string}>
genome.CHROMOSOMES = {
    [0]  = {key = "SPECIES",               label = "Species"},
    [1]  = {key = "SPEED",                 label = "Speed"},
    [2]  = {key = "LIFESPAN",              label = "Lifespan"},
    [3]  = {key = "FERTILITY",             label = "Fertility"},
    [4]  = {key = "TEMPERATURE_TOLERANCE", label = "Temperature tolerance"},
    [5]  = {key = "NOCTURNAL",             label = "Nocturnal"},
    [6]  = {key = "HUMIDITY_TOLERANCE",    label = "Humidity tolerance"},
    [7]  = {key = "TOLERANT_FLYER",        label = "Tolerant flyer"},
    [8]  = {key = "CAVE_DWELLING",         label = "Cave dwelling"},
    [9]  = {key = "FLOWER_PROVIDER",       label = "Flowers"},
    [10] = {key = "FLOWERING",             label = "Flowering"},
    [11] = {key = "TERRITORY",             label = "Territory"},
    [12] = {key = "EFFECT",                label = "Effect"},
}

genome.CHROMOSOME_COUNT = 13
genome.SPECIES_SLOT = 0

-- Reverse lookups, built once
local slot_by_label = {}
local slot_by_key = {}

for slot, chromosome in pairs(genome.CHROMOSOMES) do
    slot_by_label[chromosome.label:lower()] = slot
    slot_by_key[chromosome.key] = slot
end

--- Slot index for a chromosome display label, as printed on a sample
--- @param label string e.g. "Humidity tolerance"
--- @return number|nil slot
function genome.slotForLabel(label)
    if type(label) ~= "string" then return nil end
    return slot_by_label[label:lower()]
end

--- Slot index for a chromosome key
--- @param key string e.g. "FERTILITY"
--- @return number|nil slot
function genome.slotForKey(key)
    if type(key) ~= "string" then return nil end
    return slot_by_key[key:upper()]
end

--- Human name of a chromosome slot
--- @param slot number
--- @return string label
function genome.labelForSlot(slot)
    local chromosome = genome.CHROMOSOMES[slot]
    return chromosome and chromosome.label or ("Chromosome " .. tostring(slot))
end

--- Pull the alleles out of one Chromosomes:[...] array
--- Fields are matched by name inside each balanced group rather than by
--- position, so a different key order in a future version still parses.
--- @param array string The text between Chromosomes:[ and its closing bracket
--- @return table<number, {active: string, inactive: string}> chromosomes
--- @return number count Number of chromosomes recognized
local function parseChromosomeArray(array)
    local chromosomes = {}
    local count = 0

    for group in array:gmatch("%b{}") do
        local slot = group:match("Slot%s*:%s*(%-?%d+)")
        local active = group:match('UID0%s*:%s*"([^"]*)"')
        local inactive = group:match('UID1%s*:%s*"([^"]*)"')

        if slot and active then
            chromosomes[tonumber(slot)] = {
                active = active,
                -- A half-written chromosome falls back to its dominant allele
                inactive = inactive or active
            }
            count = count + 1
        end
    end

    return chromosomes, count
end

--- Extract one genome block ("Genome" or "Mate") from a bee's NBT
--- @param nbt string Raw NBT text
--- @param block string Block name
--- @return table<number, table>|nil chromosomes
--- @return number count
local function parseBlock(nbt, block)
    local section = nbt:match(block .. "%s*:%s*(%b{})")
    if not section then return nil, 0 end

    local array = section:match("Chromosomes%s*:%s*(%b[])")
    if not array then return nil, 0 end

    return parseChromosomeArray(array)
end

--- Parse the raw NBT of a bee
--- @param nbt string|nil NBT text as handed over by the Apiarist Terminal driver
--- @return table|nil bee {chromosomes, mate, isAnalyzed, health, maxHealth, complete}
--- @return string|nil error
function genome.parse(nbt)
    if type(nbt) ~= "string" or nbt == "" then
        return nil, "aucune donnee NBT"
    end

    local chromosomes, count = parseBlock(nbt, "Genome")
    if not chromosomes then
        return nil, "pas de bloc Genome dans le NBT"
    end
    if count == 0 then
        return nil, "bloc Genome vide"
    end

    local mate = parseBlock(nbt, "Mate")

    -- Forestry writes these as NBT bytes/shorts: 0b, 30s, ...
    local analyzed = nbt:match("IsAnalyzed%s*:%s*(%d+)")
    local health = nbt:match("Health%s*:%s*(%d+)")
    local max_health = nbt:match("MaxH%s*:%s*(%d+)")

    return {
        chromosomes = chromosomes,
        mate = mate,
        -- The genome is readable whether or not the bee was analyzed, so this
        -- is informational only: no Beealyzer is needed anywhere.
        isAnalyzed = analyzed == "1",
        health = tonumber(health),
        maxHealth = tonumber(max_health),
        complete = count == genome.CHROMOSOME_COUNT,
        chromosomeCount = count,
    }
end

--- Allele UIDs of one chromosome
--- @param bee table Parsed genome
--- @param slot number Chromosome slot
--- @return string|nil active
--- @return string|nil inactive
function genome.alleles(bee, slot)
    if not bee or not bee.chromosomes then return nil, nil end

    local chromosome = bee.chromosomes[slot]
    if not chromosome then return nil, nil end

    return chromosome.active, chromosome.inactive
end

--- Species UID of a parsed genome
--- @param bee table Parsed genome
--- @return string|nil uid e.g. "forestry.speciesWintry"
function genome.species(bee)
    return (genome.alleles(bee, genome.SPECIES_SLOT))
end

--- True when both alleles match on every chromosome present
--- A hybrid bee carries a recessive allele that resurfaces in its offspring, so
--- purity decides whether a bee is safe to use as a breeding source.
--- @param bee table Parsed genome
--- @return boolean pure
--- @return number[] impure Slots carrying two different alleles
function genome.isPure(bee)
    local impure = {}

    if not bee or not bee.chromosomes then return false, impure end

    for slot = 0, genome.CHROMOSOME_COUNT - 1 do
        local chromosome = bee.chromosomes[slot]
        if chromosome and chromosome.active ~= chromosome.inactive then
            table.insert(impure, slot)
        end
    end

    return #impure == 0, impure
end

--- Compare a genome against a target set of alleles
--- @param bee table Parsed genome
--- @param profile table<number, string> Wanted active allele UID per slot
--- @return boolean matches True when every requested slot already holds its target
--- @return table<number, {want: string, have: string|nil}> gaps Slots still off target
function genome.matchesProfile(bee, profile)
    local gaps = {}

    for slot, wanted in pairs(profile or {}) do
        local active = genome.alleles(bee, slot)
        if active ~= wanted then
            gaps[slot] = {want = wanted, have = active}
        end
    end

    return next(gaps) == nil, gaps
end

--- Read a Gene Sample from its display label
--- Gendustry formats it as "<Root> Sample - <Chromosome>: <Allele>"
--- (item.gendustry.gene_sample.name=%s Sample - %s), for example
--- "Bee Sample - Humidity tolerance: Both 1".
--- @param label string|nil Item label
--- @return table|nil sample {root, chromosome, slot, allele}
--- @return string|nil error
function genome.parseSampleLabel(label)
    if type(label) ~= "string" or label == "" then
        return nil, "etiquette vide"
    end

    local root, body = label:match("^(.-)%s+Sample%s*%-%s*(.+)$")
    if not body then
        return nil, "ce n'est pas une etiquette de Gene Sample"
    end

    -- The allele itself may contain ": " (none seen so far), so split on the
    -- first separator only
    local chromosome, allele = body:match("^(.-):%s*(.+)$")
    if not chromosome then
        return nil, "separateur chromosome/allele introuvable"
    end

    -- Trailing spaces appear in some localizations
    chromosome = chromosome:gsub("%s+$", "")
    allele = allele:gsub("%s+$", "")

    return {
        root = root,
        chromosome = chromosome,
        slot = genome.slotForLabel(chromosome),
        allele = allele,
    }
end

--- Readable one-line-per-chromosome rendering, for the GUI and reports
--- @param bee table Parsed genome
--- @return string[] lines
function genome.describe(bee)
    local lines = {}

    if not bee or not bee.chromosomes then
        return {"genome illisible"}
    end

    for slot = 0, genome.CHROMOSOME_COUNT - 1 do
        local active, inactive = genome.alleles(bee, slot)

        if active then
            local value = active
            if inactive and inactive ~= active then
                value = active .. " / " .. inactive
            end
            table.insert(lines, string.format("%-22s %s", genome.labelForSlot(slot), value))
        end
    end

    return lines
end

return genome
