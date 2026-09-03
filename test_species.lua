-- HiveMind species registry tests
--
-- The apiary is mocked with the exact shapes calibration captured in game,
-- including the callable-table form OpenComputers really uses for component
-- methods, so a "type(m) == 'function'" mistake cannot slip back in.

package.path = package.path .. ";./?.lua"

local species = require("lib.species")

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

--- Component methods are tables carrying __call, never plain functions
local function callable(fn)
    return setmetatable({}, {__call = function(_, ...) return fn(...) end})
end

local calls = {listAllSpecies = 0, getBeeParents = 0}

-- Verbatim shapes from tools/calibrate.lua on the live world
local APIARY = {
    listAllSpecies = callable(function()
        calls.listAllSpecies = calls.listAllSpecies + 1
        return {
            {name = "Nickel", uid = "magicbees.speciesNickel"},
            {name = "Saffron", uid = "extrabees.species.yellow"},
            -- Untranslated lang key, exactly as the game returned it
            {name = "gendustry.bees.species.NerdySpider", uid = "gendustry.bee.NerdySpider"},
            {name = "Forest", uid = "forestry.speciesForest"},
        }
    end),

    getBeeParents = callable(function(uid)
        calls.getBeeParents = calls.getBeeParents + 1

        if uid == "magicbees.speciesNickel" then
            return {
                {
                    allele1 = {name = "Ferrous", uid = "magicbees.speciesIron"},
                    allele2 = {name = "Esoteric", uid = "magicbees.speciesEsoteric"},
                    chance = 14.0,
                    specialConditions = {"Requires blockNickel as a foundation."},
                },
            }
        end

        if uid == "extrabees.species.yellow" then
            -- Two paths to the same species: impossible to express in the old table
            return {
                {allele1 = {name = "A", uid = "u.a"}, allele2 = {name = "B", uid = "u.b"},
                 chance = 10.0, specialConditions = {}},
                {allele1 = {name = "C", uid = "u.c"}, allele2 = {name = "D", uid = "u.d"},
                 chance = 25.0, specialConditions = {}},
            }
        end

        return {}   -- base species
    end),
}

local TMP = (os.getenv("TEMP") or os.getenv("TMPDIR") or "/tmp"):gsub("\\", "/")
local CACHE = TMP .. "/hivemind-species-test.lua"
os.remove(CACHE)

print("=== Species registry tests ===")
print("")
print("-- interrogation du jeu --")

local registry = species.new({apiary = APIARY, cachePath = CACHE})

local count, err = registry:refresh()
check("4 especes apprises (" .. tostring(err) .. ")", count, 4)

local all, source = registry:list()
check("source vivante", source, "live")
check("indexation sur uid", all["magicbees.speciesNickel"].name, "Nickel")
checkTruthy("cle de langue non resolue conservee telle quelle",
            all["gendustry.bee.NerdySpider"])
check("nom non traduit garde pour affichage",
      all["gendustry.bee.NerdySpider"].name, "gendustry.bees.species.NerdySpider")

print("")
print("-- chemins de mutation --")

local nickel = registry:parents("magicbees.speciesNickel")
check("un chemin pour Nickel", #nickel, 1)
check("parent 1", nickel[1].parent1.name, "Ferrous")
check("parent 2 sur uid", nickel[1].parent2.uid, "magicbees.speciesEsoteric")
check("chance conservee", nickel[1].chance, 14.0)
check("condition speciale conservee", nickel[1].conditions[1],
      "Requires blockNickel as a foundation.")

local saffron = registry:parents("extrabees.species.yellow")
check("deux chemins pour Saffron", #saffron, 2)
check("second chemin lu", saffron[2].chance, 25.0)

check("une espece de base n'a aucun parent", #registry:parents("forestry.speciesForest"), 0)
check("espece de base reconnue", registry:isBase("forestry.speciesForest"), true)
check("espece croisable non basique", registry:isBase("magicbees.speciesNickel"), false)

print("")
print("-- especes apprises par les parents --")

-- Measured in game: listAllSpecies returned 329 entries while getBeeParents
-- referenced uids absent from them, so the planner declared bees missing that
-- were sitting in the network.
local unlisted = species.new({
    apiary = {
        listAllSpecies = callable(function()
            return {{name = "Nickel", uid = "magicbees.speciesNickel"}}
        end),
        getBeeParents = callable(function(uid)
            if uid ~= "magicbees.speciesNickel" then return {} end
            return {{
                allele1 = {name = nil, uid = "extrabees.species.water"},
                allele2 = {name = nil, uid = "magicbees.speciesMystical"},
                chance = 10.0,
                specialConditions = {},
            }}
        end),
    },
    cachePath = TMP .. "/hivemind-unlisted.lua",
})

unlisted:refresh()
check("une seule espece listee au depart", (function()
    local n = 0
    for _ in pairs(unlisted:list()) do n = n + 1 end
    return n
end)(), 1)

unlisted:parents("magicbees.speciesNickel")

local learned = unlisted:list()
checkTruthy("le parent absent de la liste est appris", learned["extrabees.species.water"])
checkTruthy("le second aussi", learned["magicbees.speciesMystical"])

-- The derived name has to match the word used in item labels, or the lookup
-- fails exactly as before
check("nom derive d'un uid a segments",
      learned["extrabees.species.water"].name, "Water")
check("prefixe species retire",
      learned["magicbees.speciesMystical"].name, "Mystical")
check("le nom est marque comme deduit",
      learned["extrabees.species.water"].derived, true)

check("l'espece apprise se retrouve par etiquette",
      unlisted:fromBeeLabel("Water Princess").uid, "extrabees.species.water")

print("")
print("-- conditions speciales isolees --")

check("Nickel a un chemin contraint", #registry:constrainedPaths("magicbees.speciesNickel"), 1)
check("Saffron n'en a aucun", #registry:constrainedPaths("extrabees.species.yellow"), 0)

print("")
print("-- cache --")

local before = calls.getBeeParents
registry:parents("magicbees.speciesNickel")
check("second appel servi par le cache", calls.getBeeParents, before)

-- Even "no parents" is cached: base species must not be re-queried 329 times
local base_before = calls.getBeeParents
registry:parents("forestry.speciesForest")
check("l'absence de parents est mise en cache", calls.getBeeParents, base_before)

checkTruthy("sauvegarde du cache", registry:save())

local reloaded = species.new({apiary = nil, cachePath = CACHE})
local reloaded_all, reloaded_source = reloaded:list()
check("cache relu sans apiary", reloaded_all["magicbees.speciesNickel"].name, "Nickel")
check("source = cache", reloaded_source, "live")
check("chemins relus depuis le cache",
      reloaded:parents("magicbees.speciesNickel")[1].parent1.name, "Ferrous")
check("conditions relues depuis le cache",
      reloaded:parents("magicbees.speciesNickel")[1].conditions[1],
      "Requires blockNickel as a foundation.")

print("")
print("-- mode degrade sans apiary ni cache --")

local offline = species.new({
    apiary = nil,
    cachePath = TMP .. "/hivemind-species-absent.lua",
    fallback = {
        Imperial = {parents = {"Noble", "Majestic"}, mod = "Forestry"},
        Majestic = {parents = {"Noble", "Cultivated"}, mod = "Forestry"},
    },
})

local offline_all, offline_source = offline:list()
check("repli sur la table embarquee", offline_source, "fallback")
checkTruthy("especes croisables presentes", offline_all["Imperial"])
-- Base species only ever appear as parents in the bundled table
checkTruthy("especes de base deduites des parents", offline_all["Noble"])

local imperial = offline:parents("Imperial")
check("un seul chemin en mode degrade", #imperial, 1)
check("parents lus", imperial[1].parent2.name, "Majestic")
check("aucune condition connue hors ligne", #imperial[1].conditions, 0)
check("Noble vu comme base hors ligne", offline:isBase("Noble"), true)

print("")
print("-- index inverse : que produisent ces deux parents --")

-- getBeeParents only answers the forward question. Searching 329 species for
-- one reachable from a given pair is not something a person should do by hand.
check("index absent au depart", registry:hasOffspringIndex(), false)
check("aucune reponse sans index", #(registry:offspringOf("u.a", "u.b")), 0)

local progress = 0
local pairsFound = registry:buildOffspringIndex(function() progress = progress + 1 end)
checkTruthy("index construit", pairsFound and pairsFound > 0)
check("index disponible", registry:hasOffspringIndex(), true)

-- Saffron has two paths; both parent pairs must lead to it
local fromAB = registry:offspringOf("u.a", "u.b")
check("premier chemin indexe", fromAB[1], "extrabees.species.yellow")
local fromCD = registry:offspringOf("u.c", "u.d")
check("second chemin indexe", fromCD[1], "extrabees.species.yellow")

-- The pair is unordered: a princess and a drone can be given either way round
check("ordre des parents indifferent",
      (registry:offspringOf("u.b", "u.a"))[1], "extrabees.species.yellow")

local nickel = registry:offspringOf("magicbees.speciesIron", "magicbees.speciesEsoteric")
check("Nickel retrouve par ses parents", nickel[1], "magicbees.speciesNickel")
check("couple sans mutation", #(registry:offspringOf("u.a", "u.d")), 0)

-- Survives a reload, since rebuilding costs hundreds of component calls
registry:save()
local withIndex = species.new({apiary = nil, cachePath = CACHE})
check("index relu depuis le cache", withIndex:hasOffspringIndex(), true)
check("contenu preserve",
      (withIndex:offspringOf("magicbees.speciesIron", "magicbees.speciesEsoteric"))[1],
      "magicbees.speciesNickel")

print("")
print("-- espece derriere une etiquette d'abeille --")

check("princesse", registry:fromBeeLabel("Nickel Princess").uid, "magicbees.speciesNickel")
check("drone", registry:fromBeeLabel("Saffron Drone").uid, "extrabees.species.yellow")
check("reine", registry:fromBeeLabel("Nickel Queen").uid, "magicbees.speciesNickel")
check("etiquette inconnue", registry:fromBeeLabel("Cobblestone"), nil)
check("etiquette nil", registry:fromBeeLabel(nil), nil)

-- Display names do not always equal the word used in the item label, so the
-- species name is also looked for inside the label
local extra = species.new({apiary = nil, cachePath = TMP .. "/hivemind-labels.lua"})
extra.cache.species = {
    ["forestry.speciesMeadows"] = {uid = "forestry.speciesMeadows", name = "Meadows Bee"},
    ["x.gray"] = {uid = "x.gray", name = "Gray"},
    ["x.lightgray"] = {uid = "x.lightgray", name = "Light Gray"},
}
extra.loaded = true

check("nom present dans l'etiquette",
      extra:fromBeeLabel("Meadows Bee Princess").uid, "forestry.speciesMeadows")
-- Longest wins, or every Light Gray bee reads as Gray
check("le nom le plus long l'emporte",
      extra:fromBeeLabel("Light Gray Drone").uid, "x.lightgray")
check("aucune correspondance partielle abusive", extra:fromBeeLabel("Grayscale Drone"), nil)

checkTruthy("echantillon de noms disponible", #extra:sampleNames(2) > 0)

print("")
print("-- resolution par nom --")

check("resolution par uid", registry:resolve("magicbees.speciesNickel").name, "Nickel")
check("resolution par nom affiche", registry:resolve("Nickel").uid, "magicbees.speciesNickel")
check("resolution insensible a la casse", registry:resolve("saffron").uid,
      "extrabees.species.yellow")
check("nom inconnu", registry:resolve("Inexistante"), nil)

print("")
print("-- apiary injoignable --")

local broken = species.new({
    apiary = {listAllSpecies = callable(function() error("composant deconnecte") end)},
    cachePath = TMP .. "/hivemind-species-broken.lua",
})

local broken_count, broken_err = broken:refresh()
check("refresh echoue proprement", broken_count, nil)
checkTruthy("raison remontee", broken_err)

local absent = species.new({apiary = {}, cachePath = TMP .. "/hivemind-species-absent2.lua"})
local absent_count, absent_err = absent:refresh()
check("methode absente detectee", absent_count, nil)
checkTruthy("methode absente expliquee", absent_err and absent_err:find("absente"))

os.remove(CACHE)

print("")
print("=== Resultats ===")
print("Reussis : " .. passed)
print("Echoues : " .. failed)
print(failed == 0 and "Tous les tests du registre passent." or "Des tests echouent.")

os.exit(failed == 0 and 0 or 1)
