-- HiveMind chain planner tests
--
-- The chain is what turns "I want Imperial" into eight ordered crosses. What
-- matters is that it never plans a step before its parents, never plans one
-- twice, prefers a path the machines can actually run, and says plainly what
-- the player has to supply by hand.

package.path = package.path .. ";./?.lua"

local planner = require("lib.planner")

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

--- A registry standing in for the live game
--- @param tree table uid -> array of {p1, p2, chance, conditions}
local function registryFor(tree)
    return {
        parents = function(_, uid)
            local paths = tree[uid] or {}
            local mutations = {}
            for _, path in ipairs(paths) do
                table.insert(mutations, {
                    parent1 = {uid = path[1], name = path[1]},
                    parent2 = {uid = path[2], name = path[2]},
                    chance = path.chance,
                    conditions = path.conditions or {},
                })
            end
            return mutations
        end,
    }
end

local function heldSet(list)
    local held = {}
    for _, uid in ipairs(list) do held[uid] = true end
    return function(uid) return held[uid] == true end
end

-- Forestry's opening chain, plus a species reached two different ways
local TREE = {
    Common = {{"Forest", "Meadows"}},
    Cultivated = {{"Common", "Meadows"}},
    Noble = {{"Common", "Cultivated"}},
    Majestic = {{"Noble", "Cultivated"}},
    Imperial = {{"Noble", "Majestic"}},
    -- Two paths: one cheap, one needing a foundation block
    Nickel = {
        {"Ferrous", "Esoteric", conditions = {"Requires blockNickel as a foundation."}},
        {"Common", "Cultivated"},
    },
    Ferrous = {{"Forest", "Meadows"}},
    Esoteric = {{"Forest", "Meadows"}},
}

print("=== Chain planner tests ===")
print("")
print("-- cas simples --")

local registry = registryFor(TREE)

local held = planner.plan({registry = registry, target = "Common",
                           available = heldSet({"Common"})})
check("espece deja possedee", held.held, true)
check("aucun croisement", #held.steps, 0)

local single = planner.plan({registry = registry, target = "Common",
                             available = heldSet({"Forest", "Meadows"})})
check("un seul croisement", #single.steps, 1)
check("cible atteignable", single.reachable, true)
check("parents corrects", single.steps[1].princess.uid, "Forest")
check("drone correct", single.steps[1].drone.uid, "Meadows")

print("")
print("-- chaine complete --")

local chain = planner.plan({registry = registry, target = "Imperial",
                            available = heldSet({"Forest", "Meadows"})})
checkTruthy("chaine trouvee", chain.reachable)

-- Common feeds Cultivated, Noble and Majestic; breeding it four times would be
-- four wasted cycles
local counts = {}
for _, step in ipairs(chain.steps) do
    counts[step.target] = (counts[step.target] or 0) + 1
end
check("Common croisee une seule fois", counts.Common, 1)
check("Cultivated croisee une seule fois", counts.Cultivated, 1)
check("Imperial croisee une seule fois", counts.Imperial, 1)
check("cinq croisements", #chain.steps, 5)

-- Order is the whole point: a step whose parents are not yet bred cannot run
local produced = {Forest = true, Meadows = true}
local ordered = true
for _, step in ipairs(chain.steps) do
    if not (produced[step.princess.uid] and produced[step.drone.uid]) then
        ordered = false
    end
    produced[step.target] = true
end
check("chaque etape apres ses parents", ordered, true)
check("la derniere etape est la cible", chain.steps[#chain.steps].target, "Imperial")

print("")
print("-- especes de base manquantes --")

local short = planner.plan({registry = registry, target = "Imperial",
                            available = heldSet({"Forest"})})
check("plan non realisable", short.reachable, false)
check("une espece manquante", #short.missing, 1)
check("l'espece manquante est nommee", short.missing[1].uid, "Meadows")
checkTruthy("la raison est donnee", short.missing[1].reason)

local unknown = planner.plan({registry = registry, target = "Inexistante",
                              available = heldSet({})})
check("espece inconnue non realisable", unknown.reachable, false)
check("signalee comme espece de base", unknown.missing[1].uid, "Inexistante")

print("")
print("-- choix entre plusieurs chemins --")

-- Nickel has two paths; the one needing a foundation block cannot be automated
local nickel = planner.plan({registry = registry, target = "Nickel",
                             available = heldSet({"Forest", "Meadows"})})
checkTruthy("Nickel atteignable", nickel.reachable)

local last = nickel.steps[#nickel.steps]
check("le chemin sans contrainte est retenu", last.princess.uid, "Common")
check("aucune condition speciale", #(last.conditions or {}), 0)

-- With the unconstrained path unavailable, the constrained one is still offered
local constrainedOnly = registryFor({
    Nickel = {{"Ferrous", "Esoteric", conditions = {"Requires blockNickel."}}},
    Ferrous = {{"Forest", "Meadows"}},
    Esoteric = {{"Forest", "Meadows"}},
    Common = {{"Forest", "Meadows"}},
})

local forced = planner.plan({registry = constrainedOnly, target = "Nickel",
                             available = heldSet({"Forest", "Meadows"})})
checkTruthy("chemin contraint propose faute de mieux", forced.reachable)
check("la condition est conservee",
      forced.steps[#forced.steps].conditions[1], "Requires blockNickel.")

print("")
print("-- cycles et profondeur --")

-- A mutation graph that loops back on itself must not hang
local looping = registryFor({A = {{"B", "C"}}, B = {{"A", "C"}}, C = {}})
local cycle = planner.plan({registry = looping, target = "A", available = heldSet({"C"})})
check("cycle non realisable plutot que bloquant", cycle.reachable, false)
checkTruthy("un plan est quand meme rendu", cycle.steps)

local deep = {}
for level = 1, 40 do
    deep["S" .. level] = {{"S" .. (level + 1), "Base"}}
end
local tooDeep = planner.plan({registry = registryFor(deep), target = "S1",
                              available = heldSet({"Base"}), maxDepth = 5})
check("profondeur limitee", tooDeep.reachable, false)

print("")
print("-- entrees invalides --")

check("registre manquant", (planner.plan({target = "X"})), nil)
check("cible manquante", (planner.plan({registry = registry})), nil)

print("")
print("-- rendu lisible --")

local lines = planner.describe(chain)
checkTruthy("le nombre de croisements est annonce",
            table.concat(lines, "\n"):find("5 croisement", 1, true))

local withConditions = planner.describe(forced)
checkTruthy("les conditions speciales sont affichees",
            table.concat(withConditions, "\n"):find("blockNickel", 1, true))

local missingLines = planner.describe(short)
checkTruthy("les especes manquantes sont listees",
            table.concat(missingLines, "\n"):find("Meadows", 1, true))

print("")
print("=== Resultats ===")
print("Reussis : " .. passed)
print("Echoues : " .. failed)
print(failed == 0 and "Le planificateur passe." or "Des tests echouent.")

os.exit(failed == 0 and 0 or 1)
