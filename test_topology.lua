-- HiveMind topology tests
--
-- The program described exactly one installation: the one it was measured in.
-- These tests drive discovery against a simulated network, because the point of
-- the module is a world nobody here has ever seen.

package.path = package.path .. ";./?.lua"

local topology = require("lib.topology")

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

local function callable(fn)
    return setmetatable({}, {__call = function(_, ...) return fn(...) end})
end

-- ---------------------------------------------------------------------------
-- A simulated base: two benches, each with its own ME Interface
-- ---------------------------------------------------------------------------

local WORLD = {
    ["aaaa1111-0000-0000-0000-000000000000"] = {
        [2] = "gendustry:mutatron_advanced",
        [3] = "forestry:industrial_apiary",
        [4] = "appliedenergistics2:interface",
        [1] = "ironchest:iron_chest",
    },
    ["bbbb2222-0000-0000-0000-000000000000"] = {
        -- Les noms tels que le jeu les rend vraiment: aucun ne contient le
        -- prefixe "genetic_", et c est ce qui a fait manquer le Transposer
        [0] = "Genetic Sampler",
        [1] = "Genetic Imprinter",
        [2] = "Transposer",
        [3] = "appliedenergistics2:interface",
        [5] = "Genetic Imprinter",
    },

    -- Un banc dont on ne lit que la cuve: il ne recoit jamais rien, donc il n a
    -- pas besoin d interface ME et le dire est une fausse alerte permanente
    ["eeee5555-0000-0000-0000-000000000000"] = {
        [2] = "gendustry:mutagen_producer",
    },
}

local SIZES = {
    ["gendustry:mutatron_advanced"] = 10,
    ["Genetic Sampler"] = 4,
    ["Genetic Imprinter"] = 4,
    ["Transposer"] = 4,
    ["gendustry:mutagen_producer"] = 1,
    ["forestry:industrial_apiary"] = 15,
    ["appliedenergistics2:interface"] = 9,
    ["ironchest:iron_chest"] = 108,
}

local function fakeComponents(world)
    local addresses = {}
    for address in pairs(world) do table.insert(addresses, address) end
    table.sort(addresses)

    return {
        list = function(kind)
            if kind == "transposer" then return addresses end
            if kind == "me_interface" then
                return {"cccc3333-0000-0000-0000-000000000000",
                        "dddd4444-0000-0000-0000-000000000000"}
            end
            return {}
        end,
        proxy = function(address)
            local sides = world[address] or {}
            return {
                getInventoryName = callable(function(side) return sides[side] end),
                getInventorySize = callable(function(side)
                    local name = sides[side]
                    return name and (SIZES[name] or 4) or nil
                end),
            }
        end,
    }
end

print("-- ce que le programme voit du monde --")

local injected = fakeComponents(WORLD)
local seen = assert(topology.scan(injected))

check("les trois transposers sont vus", #seen.transposers, 3)
check("le mutatron est trouve", seen.machines.mutatron ~= nil, true)
check("et il est devant son transposer", seen.machines.mutatron.machine, 2)
check("sa source est l interface ME du meme banc",
      seen.machines.mutatron.source, 4)
check("l apiary aussi", seen.machines.breeding_apiary.machine, 3)
check("le sampler est sur l autre banc",
      seen.machines.sampler.transposer,
      "bbbb2222-0000-0000-0000-000000000000")

-- Il s appelle "Transposer" tout court, sans prefixe. Sans repli sur ce nom
-- court il n etait reconnu par RIEN, et la configuration ecrite en jeu ne le
-- contenait pas -- alors que la machine repond et travaille.
checkTruthy("le Genetic Transposer est reconnu par son nom court",
            seen.machines.genetic_transposer ~= nil)
check("et sur la bonne face", seen.machines.genetic_transposer.machine, 2)
check("avec la source de SON banc", seen.machines.sampler.source, 3)

-- An ME Interface is where deliveries come from, not a machine to fill
check("l interface n est pas prise pour une machine",
      seen.machines._me_interface, nil)

check("le coffre est repere", #seen.chests, 1)
check("avec sa taille", seen.chests[1].slots, 108)

print("")
print("-- deux machines identiques, et un choix que rien ne peut deviner --")

do
    -- Deux Imprinters, un template chacun. La decouverte parcourt les faces
    -- dans l ordre, donc celle du dessus prend le nom de base -- ce qui, sur la
    -- vraie base, mettait le profil d elevage sur la machine qui tient le
    -- template de production. Chaque abeille serait sortie avec les mauvais
    -- genes, sans un mot.
    local doubled = topology.duplicates(seen)

    checkTruthy("les deux imprinters sont vus comme une paire",
                doubled.imprinter ~= nil and #doubled.imprinter == 2)
    check("et rien d autre n est double", doubled.sampler, nil)

    -- Les deux faces sont bien distinctes: c est la seule chose que le monde
    -- sache en dire, et c est pour ca que la question va au joueur
    local first = seen.machines[doubled.imprinter[1]]
    local second = seen.machines[doubled.imprinter[2]]
    checkTruthy("sur deux faces differentes", first.machine ~= second.machine)
end

print("")
print("-- un banc qu on ne fait que lire n a pas besoin d interface --")

do
    local reading = "eeee5555-0000-0000-0000-000000000000"

    check("le banc du Mutagen Producer ne reclame rien",
          topology.needsInterface(seen, reading), false)
    check("celui du Mutatron, si",
          topology.needsInterface(seen, "aaaa1111-0000-0000-0000-000000000000"),
          true)

    -- Un transposer qui ne touche aucune machine ne reclame rien non plus
    check("un transposer sans machine ne reclame rien",
          topology.needsInterface(seen, "zzzz0000"), false)
end

print("")
print("-- ce qui manque encore --")

local absent = topology.missing(seen)
local named = {}
for _, name in ipairs(absent) do named[name] = true end

checkTruthy("le replicator est annonce manquant", named.replicator)
checkTruthy("le Protein Liquifier aussi", named.protein_liquifier)
checkTruthy("mais pas le mutatron, qui est la", not named.mutatron)
checkTruthy("ni le producteur de mutagene, pose sur son propre banc",
            not named.mutagen_producer)
checkTruthy("ni le Genetic Transposer, desormais reconnu",
            not named.genetic_transposer)

print("")
print("-- une configuration qui n est pas celle de ce monde --")

-- The failure this exists for: a declared address nothing answers to makes
-- every delivery fail as "la machine refuse cet objet", and the installation
-- check would happily report on machines that are not there.
local elsewhere = {
    machines = {
        mutatron = {transposer = "99999999", machine = 3, source = 2},
        sampler = {transposer = "aaaa1111", machine = 0, source = 4},
        vieille = {transposer = "88888888", machine = 1, enabled = false},
    },
}

local stale = topology.stale(elsewhere, seen)
check("une seule adresse est etrangere a ce monde", #stale, 1)
check("et c est la bonne", stale[1], "99999999")

local here = {
    machines = {
        mutatron = {transposer = "aaaa1111", machine = 2, source = 4},
        sampler = {transposer = "bbbb2222", machine = 0, source = 3},
    },
}

check("une configuration juste ne signale rien", #topology.stale(here, seen), 0)

print("")
print("-- le fichier ecrit, relu, applique --")

local source = topology.render(seen, {
    interfaces = {["aaaa1111-0000-0000-0000-000000000000"] = "cccc3333"},
    chest = seen.chests[1],
})

local chunk = load(source, "topologie")
checkTruthy("le fichier ecrit est du Lua valide", chunk ~= nil)

local written = chunk()
check("il rend les trois transposers", #written.transposers, 3)
check("il nomme l interface du banc",
      written.interfaces["aaaa1111-0000-0000-0000-000000000000"], "cccc3333")
check("et le coffre a templates", written.template_chest.slots, 108)

-- Only the three things that belong to one base are overwritten: the slot map
-- is a property of the mod and was measured with a bee in the machine
local settings = {
    machines = {
        mutatron = {transposer = "vieux", machine = 9, source = 9,
                    slots = {in1 = 0, in2 = 1, output = 2, labware = 3}},
    },
}

local applied = topology.apply(settings, written)

checkTruthy("plusieurs machines sont reecrites", applied >= 4)
check("le transposer du mutatron est celui de ce monde",
      settings.machines.mutatron.transposer,
      "aaaa1111-0000-0000-0000-000000000000")
check("sa face aussi", settings.machines.mutatron.machine, 2)
check("mais son plan de slots est intact",
      settings.machines.mutatron.slots.labware, 3)
check("une machine absente de la config est ajoutee",
      settings.machines.sampler ~= nil, true)
check("le coffre a templates est repris", settings.template_chest.slots, 108)

print("")
print("-- un monde vide --")

local nothing = assert(topology.scan(fakeComponents({})))
check("aucun transposer", #nothing.transposers, 0)
check("aucune machine", next(nothing.machines), nil)

-- Rendering nothing must still produce a loadable file rather than an error:
-- the player is told what to build, and the program does not crash on the way
local emptySource = topology.render(nothing, {})
checkTruthy("le fichier d un monde vide reste valide",
            load(emptySource, "vide") ~= nil)

print("")
print("-- lecture d un fichier absent --")

local missing, err = topology.read("/aucun/fichier/ici.lua")
check("rien n est lu", missing, nil)
checkTruthy("et la raison est dite", err ~= nil)

print("")
print("=== Resultats ===")
print("Reussis : " .. passed)
print("Echoues : " .. failed)

if failed > 0 then
    print("Des tests echouent.")
    os.exit(1)
end

print("La topologie tient.")
