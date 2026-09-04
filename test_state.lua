-- HiveMind persistence layer tests
--
-- The properties that matter here are not "it round-trips": they are that a
-- crash mid-write cannot destroy the previous state, and that a corrupted file
-- is reported rather than silently replaced by defaults.

package.path = package.path .. ";./?.lua"

local state = require("lib.state")

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
local PATH = TMP .. "/hivemind-state-test.lua"

os.remove(PATH)
os.remove(PATH .. ".tmp")

print("=== Persistence layer tests ===")
print("")
print("-- aller-retour --")

local SAMPLE = {
    version = 3,
    enabled = true,
    ratio = 0.5,
    library = {
        ["forestry.speciesWintry"] = {copies = 2, slot = 7},
        ["magicbees.speciesNickel"] = {copies = 1, slot = 12},
    },
    queue = {"sample", "imprint", "replicate"},
    ["cle avec espaces"] = "valeur",
}

local ok, err = state.save(PATH, SAMPLE)
checkTruthy("sauvegarde reussie (" .. tostring(err) .. ")", ok)

local loaded = state.load(PATH)
checkTruthy("rechargement reussi", loaded)
check("nombre entier conserve", loaded and loaded.version, 3)
check("booleen conserve", loaded and loaded.enabled, true)
check("nombre flottant conserve", loaded and loaded.ratio, 0.5)
check("table imbriquee conservee",
      loaded and loaded.library["forestry.speciesWintry"].copies, 2)
check("cle pointee conservee",
      loaded and loaded.library["magicbees.speciesNickel"].slot, 12)
check("tableau conserve", loaded and loaded.queue[2], "imprint")
check("cle non identifiante conservee", loaded and loaded["cle avec espaces"], "valeur")

print("")
print("-- determinisme --")

local first = state.serialize(SAMPLE)
local second = state.serialize(SAMPLE)
check("deux serialisations identiques", first, second)

print("")
print("-- fichier absent et fichier corrompu --")

local missing, missing_err = state.load(TMP .. "/hivemind-nexiste-pas.lua", {fresh = true})
check("valeur par defaut rendue", missing and missing.fresh, true)
check("aucune erreur pour un fichier absent", missing_err, nil)

local corrupt = io.open(PATH .. ".corrupt", "w")
corrupt:write("return {oups = ")
corrupt:close()

local broken, broken_err = state.load(PATH .. ".corrupt", {fresh = true})
check("fichier corrompu -> pas de valeur", broken, nil)
checkTruthy("fichier corrompu -> erreur remontee", broken_err)
os.remove(PATH .. ".corrupt")

print("")
print("-- un fichier d'etat est une donnee, jamais du code --")

-- Loaded in an empty environment: even a hostile file cannot reach anything
local hostile = state.deserialize('return {x = 1, y = os.time()}')
check("appel a os.* neutralise", hostile, nil)

local plain = state.deserialize('return {x = 1}')
check("une table simple passe", plain and plain.x, 1)

print("")
print("-- valeurs non persistables --")

check("fonction refusee", (state.serialize({f = function() end})), nil)
check("NaN refuse", (state.serialize({n = 0 / 0})), nil)
check("infini refuse", (state.serialize({n = math.huge})), nil)

local cycle = {}
cycle.self = cycle
check("reference circulaire refusee", (state.serialize(cycle)), nil)

check("non-table refusee", (state.serialize("texte")), nil)

print("")
print("-- ecriture atomique --")

-- The previous version must survive a failed write
state.save(PATH, {generation = 1})
local before = state.load(PATH)
check("generation 1 en place", before and before.generation, 1)

local refused, refuse_err = state.save(PATH, {bad = function() end})
check("sauvegarde invalide refusee", refused, false)
checkTruthy("raison donnee", refuse_err)

local after = state.load(PATH)
check("l'ancienne version a survecu", after and after.generation, 1)

-- No temporary file left behind
local leftover = io.open(PATH .. ".tmp", "r")
check("aucun fichier temporaire orphelin", leftover, nil)
if leftover then leftover:close() end

state.save(PATH, {generation = 2})
check("remplacement effectif", state.load(PATH).generation, 2)

print("")
print("-- chemins --")

check("chemin nomme", state.pathFor("jobs", "/home/hivemind/state"),
      "/home/hivemind/state/jobs.lua")

os.remove(PATH)

print("")
print("")
print("-- un gros etat doit tenir dans la memoire d un ordinateur --")

do
    -- Plante en jeu: 355 especes avec leurs chemins de mutation, et le
    -- programme est mort dans table.concat au milieu de la sauvegarde. Rendre
    -- une chaine par noeud gardait tous les fragments vivants a la fois, et le
    -- concat final devait allouer le fichier entier par-dessus.
    local cache = {version = 1, species = {}, parents = {}}
    for i = 1, 400 do
        local uid = "forestry.speciesEspece" .. i
        cache.species[uid] = {uid = uid, name = "Espece " .. i, derived = false}
        local mutations = {}
        for m = 1, 2 do
            table.insert(mutations, {
                parent1 = {uid = "forestry.speciesParent" .. m .. i,
                           name = "Parent " .. m .. i},
                parent2 = {uid = "magicbees.speciesAutre" .. m .. i,
                           name = "Autre " .. m .. i},
                chance = 12.5,
                conditions = {"Requires blockNickel as a foundation."},
            })
        end
        cache.parents[uid] = mutations
    end

    local big = TMP .. "/hivemind-gros-etat.lua"
    os.remove(big)

    -- Mesurer APRES la sauvegarde ne prouve rien: tout ce qu elle a alloue est
    -- devenu du dechet entre-temps. Ce qui tue la machine, c est le PIC, et il
    -- se mesure au moment ou les octets partent sur le disque.
    -- Mesurer les kilo-octets vus par collectgarbage sur un poste de bureau ne
    -- modelise pas l allocateur d OpenComputers, et le chiffre bouge d une
    -- passe a l autre. Ce qui se mesure vraiment, et qui est exactement la
    -- panne: la taille de la plus grosse ecriture. L ancienne version en
    -- faisait UNE, de la taille du fichier, apres l avoir construit en entier.
    local writes, biggest, total = 0, 0, 0
    local realOpen = io.open

    io.open = function(path, mode)
        local file = realOpen(path, mode)
        if not file or mode ~= "w" then return file end

        return setmetatable({}, {__index = function(_, key)
            if key == "write" then
                return function(_, text)
                    writes = writes + 1
                    total = total + #text
                    if #text > biggest then biggest = #text end
                    return file:write(text)
                end
            end
            if key == "close" then return function() return file:close() end end
            return function(_, ...) return file[key](file, ...) end
        end})
    end

    local ok, err = state.save(big, cache)

    io.open = realOpen

    check("un etat de 400 especes s ecrit (" .. tostring(err) .. ")", ok, true)
    checkTruthy("le fichier fait plus de 100 Ko (" .. total .. " octets)",
                total > 100000)
    checkTruthy("il part par blocs (" .. writes .. " ecritures)", writes > 10)
    checkTruthy(string.format(
                    "et aucun bloc ne porte le fichier entier (%d octets au plus)",
                    biggest),
                biggest < 8192)

    local back, load_err = state.load(big, nil)
    checkTruthy("il se relit (" .. tostring(load_err) .. ")", back ~= nil)
    check("jusque dans les feuilles",
          back.parents["forestry.speciesEspece399"][2].parent2.name, "Autre 2399")
    check("les conditions de mutation survivent",
          back.parents["forestry.speciesEspece1"][1].conditions[1],
          "Requires blockNickel as a foundation.")

    os.remove(big)
end

print("=== Resultats ===")
print("Reussis : " .. passed)
print("Echoues : " .. failed)
print(failed == 0 and "Tous les tests de persistance passent." or "Des tests echouent.")

os.exit(failed == 0 and 0 or 1)
