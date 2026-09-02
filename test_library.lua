-- HiveMind gene library tests
--
-- Sample labels are the real ones the game produced. The template side is
-- tested for the property that matters: a chest someone reorganized must be
-- detected, not trusted.

package.path = package.path .. ";./?.lua"

local library = require("lib.library")
local genome = require("lib.genome")

local passed, failed = 0, 0

local function check(description, actual, expected)
    if actual == expected then
        passed = passed + 1
        print("  OK   " .. description)
    else
        failed = failed + 1
        print("  FAIL " .. description
            .. "\n         obtenu  : " .. tostring(actual)
            .. "\n         attendu : " .. tostring(expected))
    end
end

local function checkTruthy(description, value)
    if value then
        passed = passed + 1
        print("  OK   " .. description)
    else
        failed = failed + 1
        print("  FAIL " .. description)
    end
end

local TMP = (os.getenv("TEMP") or os.getenv("TMPDIR") or "/tmp"):gsub("\\", "/")
local PATH = TMP .. "/hivemind-library-test.lua"

local network, chest

local function reset()
    network = {
        {name = "gendustry:gene_sample", label = "Bee Sample - Species: Cultivated", size = 3},
        {name = "gendustry:gene_sample", label = "Bee Sample - Species: Forest", size = 1},
        {name = "gendustry:gene_sample", label = "Bee Sample - Speed: Fastest", size = 4},
        {name = "gendustry:gene_sample", label = "Bee Sample - Fertility: 4", size = 1},
        {name = "gendustry:gene_sample", label = "Bee Sample - Humidity tolerance: Both 1", size = 2},
        -- A template in the network is exactly what must never happen, and it
        -- must not be mistaken for a gene either way
        {name = "gendustry:gene_template", label = "Genetic Template", size = 2},
        {name = "minecraft:cobblestone", label = "Cobblestone", size = 64},
    }

    chest = {}
end

local TEMPLATE_LINK = {transposer = 1, machine = 1, source = 3}

local fakeTransport = {
    me = {
        getItemsInNetwork = function(filter)
            if filter and filter.name then
                local matching = {}
                for _, item in ipairs(network) do
                    if item.name == filter.name then table.insert(matching, item) end
                end
                return matching
            end
            return network
        end,
    },

    inspect = function(_, link, slot) return chest[slot] end,

    fingerprint = function(_, link, slot, dbSlot, onMachineSide)
        local stack = chest[slot]
        if not stack then return nil, "slot vide" end
        return "hash:" .. tostring(stack.id)
    end,
}

local function newLibrary()
    return library.new({
        transport = fakeTransport,
        templateLink = TEMPLATE_LINK,
        path = PATH,
        config = {library = {minimum_copies = 2, target_copies = 3}},
    })
end

os.remove(PATH)
reset()

print("=== Gene library tests ===")
print("")
print("-- lecture des samples dans le reseau --")

local lib = newLibrary()
local genes, total = lib:scan()

check("5 alleles distincts", total, 5)
check("deux especes archivees", (function()
    local n = 0
    for _ in pairs(genes[genome.SPECIES_SLOT]) do n = n + 1 end
    return n
end)(), 2)

check("copies comptees", lib:count(genome.SPECIES_SLOT, "Cultivated"), 3)
check("allele de vitesse", lib:count(1, "Fastest"), 4)
check("chromosome a deux mots resolu", lib:count(6, "Both 1"), 2)
check("allele absent", lib:count(1, "Slowest"), 0)
checkTruthy("presence", lib:has(genome.SPECIES_SLOT, "Forest"))
check("absence", lib:has(genome.SPECIES_SLOT, "Ender"), false)

-- Templates and cobblestone must not leak into the gene counts
check("le template n'est pas compte comme un gene",
      lib:count(genome.SPECIES_SLOT, "Genetic Template"), 0)

local spec = lib:specFor(genome.SPECIES_SLOT, "Cultivated")
check("specification pour le transport", spec and spec.label,
      "Bee Sample - Species: Cultivated")
check("bon item", spec and spec.name, "gendustry:gene_sample")
check("specification d'un allele absent", lib:specFor(1, "Slowest"), nil)

print("")
print("-- especes archivees --")

local archived = lib:speciesGenes()
check("Cultivated archivee", archived["Cultivated"], 3)
check("Forest archivee", archived["Forest"], 1)
check("la vitesse n'est pas une espece", archived["Fastest"], nil)

print("")
print("-- alleles en trop peu d'exemplaires --")

-- Spending the last copy of a gene loses it, so anything below the minimum has
-- to be duplicated before it is used
local shortages = lib:shortages()
check("deux alleles sous le seuil", #shortages, 2)

local by_allele = {}
for _, entry in ipairs(shortages) do by_allele[entry.allele] = entry end

checkTruthy("Forest en penurie", by_allele["Forest"])
check("manque calcule", by_allele["Forest"] and by_allele["Forest"].needed, 2)
checkTruthy("Fertilite 4 en penurie", by_allele["4"])
check("Cultivated n'est pas en penurie", by_allele["Cultivated"], nil)

print("")
print("-- ecart a un profil --")

local PROFILE = {
    [genome.SPECIES_SLOT] = "Cultivated",
    [1] = "Fastest",
    [3] = "4",
    [5] = "Yes",          -- nocturnal, never collected
    [9] = "Flowers",      -- never collected
}

local missing, complete = lib:missingForProfile(PROFILE)
check("profil incomplet", complete, false)
check("deux alleles manquants", #missing, 2)
check("trie par chromosome", missing[1].slot, 5)
check("chromosome nomme", missing[1].chromosome, "Nocturnal")

local held, held_complete = lib:missingForProfile({[1] = "Fastest"})
check("profil deja satisfait", held_complete, true)
check("rien a chercher", #held, 0)

print("")
print("-- index des templates --")

os.remove(PATH)
lib = newLibrary()

chest[1] = {id = "alpha", name = "gendustry:gene_template", label = "Genetic Template"}
chest[2] = {id = "beta", name = "gendustry:gene_template", label = "Genetic Template"}

local entry, register_err = lib:registerTemplate(1, {
    species = "forestry.speciesImperial",
    contents = {[0] = "Imperial", [1] = "Fastest"},
    complete = true,
})

checkTruthy("template enregistre (" .. tostring(register_err) .. ")", entry)
check("empreinte relevee", entry and entry.hash, "hash:alpha")
check("espece notee", entry and entry.species, "forestry.speciesImperial")

lib:registerTemplate(2, {species = "forestry.speciesWintry", complete = false})
check("deux templates indexes", #lib:templates(), 2)
check("recherche par espece", lib:templateFor("forestry.speciesWintry").slot, 2)
check("espece non indexee", lib:templateFor("forestry.speciesEnder"), nil)

print("")
print("-- verification de l'index --")

local intact, discrepancies = lib:verify()
checkTruthy("index conforme au coffre", intact)
check("aucun ecart", #discrepancies, 0)

-- Someone swaps two templates by hand: nothing in their label betrays it
chest[1], chest[2] = chest[2], chest[1]

local swapped, swapped_discrepancies = lib:verify()
check("permutation manuelle detectee", swapped, false)
check("les deux slots signales", #swapped_discrepancies, 2)
checkTruthy("raison donnee", swapped_discrepancies[1].reason:find("change"))

-- And a template simply taken out
chest[1], chest[2] = nil, nil
local emptied, emptied_discrepancies = lib:verify()
check("disparition detectee", emptied, false)
check("slot vide signale", emptied_discrepancies[1].found, nil)

print("")
print("-- persistance de l'index --")

os.remove(PATH)
lib = newLibrary()
chest[3] = {id = "gamma"}
lib:registerTemplate(3, {species = "forestry.speciesNoble"})

local reloaded = newLibrary()
check("index relu depuis le disque", reloaded:template(3).species, "forestry.speciesNoble")
check("empreinte conservee", reloaded:template(3).hash, "hash:gamma")
check("identifiants poursuivis", reloaded.index.nextTemplateId, 2)

checkTruthy("oubli d'un template", reloaded:forgetTemplate(3))
check("template oublie", reloaded:template(3), nil)
check("oubli d'un slot inconnu", reloaded:forgetTemplate(99), false)

print("")
print("-- slot libre --")

os.remove(PATH)
lib = newLibrary()
chest = {}
chest[1] = {id = "occupe"}
lib:registerTemplate(1, {species = "x"})

-- Slot 2 is unrecorded and empty
check("premier slot libre", lib:freeTemplateSlot(27), 2)

-- An unrecorded slot holding something is not free either
chest[2] = {id = "intrus"}
check("slot occupe hors index ignore", lib:freeTemplateSlot(27), 3)

print("")
print("-- resume --")

reset()
lib = newLibrary()
local lines = lib:describe()
checkTruthy("resume produit", #lines >= 3)
checkTruthy("les genes sont comptes", lines[1]:find("alleles"))

os.remove(PATH)

print("")
print("=== Resultats ===")
print("Reussis : " .. passed)
print("Echoues : " .. failed)
print(failed == 0 and "Tous les tests de la bibliotheque passent." or "Des tests echouent.")

os.exit(failed == 0 and 0 or 1)
