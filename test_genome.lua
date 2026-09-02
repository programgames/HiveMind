-- HiveMind genome layer tests
--
-- Every fixture below is verbatim output from a live game, captured by
-- tools/calibrate.lua. Nothing here is invented: the whole point of the
-- calibration pass was to stop testing the parser against my assumptions.

package.path = package.path .. ";./?.lua"

local genome = require("lib.genome")

local passed, failed = 0, 0

local function check(description, actual, expected)
    if actual == expected then
        passed = passed + 1
        print("  OK   " .. description)
    else
        failed = failed + 1
        print("  FAIL " .. description
            .. "\n         obtenu   : " .. tostring(actual)
            .. "\n         attendu  : " .. tostring(expected))
    end
end

local function checkTruthy(description, value)
    if value then
        passed = passed + 1
        print("  OK   " .. description)
    else
        failed = failed + 1
        print("  FAIL " .. description .. " (valeur fausse ou nil)")
    end
end

-- ---------------------------------------------------------------------------
-- Fixtures captured in game
-- ---------------------------------------------------------------------------

-- Queen sitting in the Industrial Apiary: Wintry, mated with a Modest drone.
-- Note IsAnalyzed:0b - the genome is fully readable on an unanalyzed bee.
local WINTRY_QUEEN = '{IsAnalyzed:0b,Health:30,MaxH:30,Genome:{Chromosomes:['
    .. '{Slot:0b,UID0:"forestry.speciesWintry",UID1:"forestry.speciesWintry"},'
    .. '{Slot:1b,UID0:"forestry.speedSlower",UID1:"forestry.speedSlower"},'
    .. '{Slot:2b,UID0:"forestry.lifespanShort",UID1:"forestry.lifespanShort"},'
    .. '{Slot:3b,UID0:"forestry.fertilityMaximum",UID1:"forestry.fertilityMaximum"},'
    .. '{Slot:4b,UID0:"forestry.toleranceUp1",UID1:"forestry.toleranceUp1"},'
    .. '{Slot:5b,UID0:"forestry.boolFalse",UID1:"forestry.boolFalse"},'
    .. '{Slot:6b,UID0:"forestry.toleranceBoth1",UID1:"forestry.toleranceBoth1"},'
    .. '{Slot:7b,UID0:"forestry.boolFalse",UID1:"forestry.boolFalse"},'
    .. '{Slot:8b,UID0:"forestry.boolFalse",UID1:"forestry.boolFalse"},'
    .. '{Slot:9b,UID0:"forestry.flowersSnow",UID1:"forestry.flowersSnow"},'
    .. '{Slot:10b,UID0:"forestry.floweringSlowest",UID1:"forestry.floweringSlowest"},'
    .. '{Slot:11b,UID0:"forestry.territoryAverage",UID1:"forestry.territoryAverage"},'
    .. '{Slot:12b,UID0:"forestry.effectGlacial",UID1:"forestry.effectGlacial"}]},'
    .. 'Mate:{Chromosomes:['
    .. '{Slot:0b,UID0:"forestry.speciesModest",UID1:"forestry.speciesModest"},'
    .. '{Slot:1b,UID0:"forestry.speedSlower",UID1:"forestry.speedSlower"},'
    .. '{Slot:2b,UID0:"forestry.lifespanShort",UID1:"forestry.lifespanShort"},'
    .. '{Slot:3b,UID0:"forestry.fertilityNormal",UID1:"forestry.fertilityNormal"},'
    .. '{Slot:4b,UID0:"forestry.toleranceBoth1",UID1:"forestry.toleranceBoth1"},'
    .. '{Slot:5b,UID0:"forestry.boolTrue",UID1:"forestry.boolTrue"},'
    .. '{Slot:6b,UID0:"forestry.toleranceDown1",UID1:"forestry.toleranceDown1"},'
    .. '{Slot:7b,UID0:"forestry.boolFalse",UID1:"forestry.boolFalse"},'
    .. '{Slot:8b,UID0:"forestry.boolFalse",UID1:"forestry.boolFalse"},'
    .. '{Slot:9b,UID0:"forestry.flowersCacti",UID1:"forestry.flowersCacti"},'
    .. '{Slot:10b,UID0:"forestry.floweringSlowest",UID1:"forestry.floweringSlowest"},'
    .. '{Slot:11b,UID0:"forestry.territoryAverage",UID1:"forestry.territoryAverage"},'
    .. '{Slot:12b,UID0:"forestry.effectNone",UID1:"forestry.effectNone"}]}}'

-- Drone from the same apiary, no Mate block
local MODEST_DRONE = '{IsAnalyzed:0b,Health:30,MaxH:30,Genome:{Chromosomes:['
    .. '{Slot:0b,UID0:"forestry.speciesModest",UID1:"forestry.speciesModest"},'
    .. '{Slot:1b,UID0:"forestry.speedSlower",UID1:"forestry.speedSlower"},'
    .. '{Slot:2b,UID0:"forestry.lifespanShort",UID1:"forestry.lifespanShort"},'
    .. '{Slot:3b,UID0:"forestry.fertilityNormal",UID1:"forestry.fertilityNormal"},'
    .. '{Slot:4b,UID0:"forestry.toleranceBoth1",UID1:"forestry.toleranceBoth1"},'
    .. '{Slot:5b,UID0:"forestry.boolTrue",UID1:"forestry.boolTrue"},'
    .. '{Slot:6b,UID0:"forestry.toleranceDown1",UID1:"forestry.toleranceDown1"},'
    .. '{Slot:7b,UID0:"forestry.boolFalse",UID1:"forestry.boolFalse"},'
    .. '{Slot:8b,UID0:"forestry.boolFalse",UID1:"forestry.boolFalse"},'
    .. '{Slot:9b,UID0:"forestry.flowersCacti",UID1:"forestry.flowersCacti"},'
    .. '{Slot:10b,UID0:"forestry.floweringSlowest",UID1:"forestry.floweringSlowest"},'
    .. '{Slot:11b,UID0:"forestry.territoryAverage",UID1:"forestry.territoryAverage"},'
    .. '{Slot:12b,UID0:"forestry.effectNone",UID1:"forestry.effectNone"}]}}'

print("=== Genome layer tests ===")
print("")
print("-- lecture du genome (NBT reel) --")

local queen, err = genome.parse(WINTRY_QUEEN)
checkTruthy("la reine Wintry se parse (" .. tostring(err) .. ")", queen)
check("13 chromosomes lus", queen and queen.chromosomeCount, 13)
check("genome complet", queen and queen.complete, true)
check("espece = Wintry", genome.species(queen), "forestry.speciesWintry")
check("IsAnalyzed:0b -> non analysee", queen and queen.isAnalyzed, false)
check("Health lu", queen and queen.health, 30)

-- The mapping between slots and chromosomes is the heart of the whole layer
check("slot 3 = fertilite maximale", (genome.alleles(queen, 3)), "forestry.fertilityMaximum")
check("slot 5 = nocturne (bool)", (genome.alleles(queen, 5)), "forestry.boolFalse")
check("slot 9 = fleurs de neige", (genome.alleles(queen, 9)), "forestry.flowersSnow")
check("slot 12 = effet glacial", (genome.alleles(queen, 12)), "forestry.effectGlacial")

-- A queen carries the drone she mated with: that is how we learn what was bred
checkTruthy("le bloc Mate est lu", queen and queen.mate)
check("partenaire = Modest", queen and queen.mate and queen.mate[0].active,
      "forestry.speciesModest")

local drone = genome.parse(MODEST_DRONE)
check("le drone se parse", drone and drone.chromosomeCount, 13)
check("drone sans partenaire", drone and drone.mate, nil)

print("")
print("-- purete --")

local pure, impure = genome.isPure(queen)
check("la reine Wintry est pure", pure, true)
check("aucun chromosome heterozygote", #impure, 0)

-- A hybrid: the recessive allele resurfaces in the offspring
local HYBRID = WINTRY_QUEEN:gsub('UID1:"forestry.speedSlower"',
                                 'UID1:"forestry.speedFastest"', 1)
local hybrid = genome.parse(HYBRID)
local hybrid_pure, hybrid_slots = genome.isPure(hybrid)
check("l'hybride est detecte", hybrid_pure, false)
check("chromosome fautif = slot 1 (Speed)", hybrid_slots[1], 1)

print("")
print("-- correspondance avec un profil cible --")

local PROFILE = {
    [3] = "forestry.fertilityMaximum",
    [1] = "forestry.speedFastest",
}

local matches, gaps = genome.matchesProfile(queen, PROFILE)
check("la reine ne correspond pas au profil", matches, false)
check("fertilite deja bonne", gaps[3], nil)
check("vitesse a corriger", gaps[1] and gaps[1].have, "forestry.speedSlower")

check("un profil vide correspond toujours", (genome.matchesProfile(queen, {})), true)

print("")
print("-- etiquettes de Gene Sample (labels reels) --")

local sample = genome.parseSampleLabel("Bee Sample - Species: Cultivated")
check("chromosome lu", sample and sample.chromosome, "Species")
check("allele lu", sample and sample.allele, "Cultivated")
check("slot resolu", sample and sample.slot, 0)
check("racine lue", sample and sample.root, "Bee")

local tolerance = genome.parseSampleLabel("Bee Sample - Humidity tolerance: Both 1")
check("chromosome a deux mots", tolerance and tolerance.chromosome, "Humidity tolerance")
check("allele a deux mots", tolerance and tolerance.allele, "Both 1")
check("slot de l'humidite", tolerance and tolerance.slot, 6)

-- FLOWER_PROVIDER displays as "Flowers", which a guess would have missed
check("slot des fleurs", genome.slotForLabel("Flowers"), 9)
check("recherche insensible a la casse", genome.slotForLabel("tolerant flyer"), 7)
check("chromosome inconnu -> nil", genome.slotForLabel("Girth"), nil)

print("")
print("-- entrees invalides --")

check("NBT nil", (genome.parse(nil)), nil)
check("NBT vide", (genome.parse("")), nil)
check("NBT sans genome", (genome.parse("{Health:30}")), nil)
check("etiquette d'un autre item", (genome.parseSampleLabel("Genetic Template")), nil)
check("etiquette nil", (genome.parseSampleLabel(nil)), nil)
check("espece d'un genome nil", genome.species(nil), nil)

-- A template label carries nothing: this is exactly why templates are
-- fingerprinted through the database instead of being read
check("le template ne dit rien de son contenu",
      (genome.parseSampleLabel("Genetic Template")), nil)

print("")
print("-- rendu lisible --")

local lines = genome.describe(queen)
check("13 lignes decrites", #lines, 13)
checkTruthy("la premiere ligne nomme l'espece", lines[1]:find("Species", 1, true))

print("")
print("=== Resultats ===")
print("Reussis : " .. passed)
print("Echoues : " .. failed)

if failed == 0 then
    print("Tous les tests du genome passent.")
else
    print("Des tests du genome echouent.")
end

os.exit(failed == 0 and 0 or 1)
