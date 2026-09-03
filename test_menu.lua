-- HiveMind menu wiring tests
--
-- The menu dispatches with hivemind[entry.action](context). A typo there is
-- invisible until someone picks that option in game and gets "attempt to call a
-- nil value", which is the worst possible place to find out.
--
-- Static checks against the source: hivemind.lua cannot be loaded on a desktop
-- Lua because it requires the OpenComputers component library on its first
-- line.

package.path = package.path .. ";./?.lua"

local passed, failed = 0, 0

local function check(description, condition, detail)
    if condition then
        passed = passed + 1
        print("  OK   " .. description)
    else
        failed = failed + 1
        print("  FAIL " .. description)
        if detail then print("         " .. tostring(detail)) end
    end
end

local source = assert(io.open("hivemind.lua", "r"))
local text = source:read("*all")
source:close()

-- ---------------------------------------------------------------------------

print("-- entrees du menu --")

local actions, keys, labels = {}, {}, {}
for key, label, action in text:gmatch(
        'key%s*=%s*"(%d)"%s*,%s*label%s*=%s*"([^"]*)"[^}]-action%s*=%s*"([%w_]+)"') do
    table.insert(actions, action)
    table.insert(labels, label)
    keys[key] = (keys[key] or 0) + 1
end

check("le menu a des entrees", #actions > 0, #actions .. " trouvee(s)")

local duplicated = nil
for key, count in pairs(keys) do
    if count > 1 then duplicated = key end
end
check("aucune touche en double", duplicated == nil, duplicated)

check("la touche 0 n'est pas reutilisee", keys["0"] == nil)

-- ---------------------------------------------------------------------------

print("")
print("-- chaque entree pointe vers une fonction reelle --")

local defined = {}
for name in text:gmatch("function hivemind%.([%w_]+)") do
    defined[name] = true
end

local missing = {}
for _, action in ipairs(actions) do
    if not defined[action] then table.insert(missing, action) end
end

check("toutes les actions existent", #missing == 0, table.concat(missing, ", "))

-- The two capabilities the last report showed were needed
check("la recolte de l'apiary est branchee", defined.harvestApiary == true)
check("l'accumulation de drones est branchee", defined.accumulateDrones == true)

local wired = {}
for _, action in ipairs(actions) do wired[action] = true end
check("la recolte est atteignable depuis le menu", wired.harvestApiary == true)
check("l'accumulation est atteignable depuis le menu",
      wired.accumulateDrones == true)

-- ---------------------------------------------------------------------------

print("")
print("-- lisibilite --")

local unexplained = {}
for label, hint in text:gmatch('label%s*=%s*"([^"]*)"%s*,%s*hint%s*=%s*"([^"]*)"') do
    if hint == "" then table.insert(unexplained, label) end
end
check("chaque entree porte une explication", #unexplained == 0,
      table.concat(unexplained, ", "))

check("le menu est groupe", (select(2, text:gsub("group%s*=%s*\"", ""))) >= 3)

-- ---------------------------------------------------------------------------

print("")
print("-- modules requis --")

-- A module used but never loaded dies at startup with an empty require error
local loaded = {}
for name in text:gmatch('need%("lib%.([%w_]+)"%)') do loaded[name] = true end

check("multiply est charge", loaded.multiply == true)
check("son gestionnaire est enregistre",
      text:find("multiply = multiply.handler()", 1, true) ~= nil)

-- ---------------------------------------------------------------------------

print("")
print("-- autoreport --")

local tool = assert(io.open("tools/autoreport.lua", "r"))
local toolText = tool:read("*all")
tool:close()

-- The cache purge has to happen before the require, or it purges nothing
local purge = toolText:find("package.loaded[name] = nil", 1, true)
local require_at = toolText:find('pcall(require, "hivemind")', 1, true)

check("autoreport vide le cache des modules", purge ~= nil)
check("il le fait avant de charger hivemind",
      purge ~= nil and require_at ~= nil and purge < require_at)
check("il verifie que le programme est assez recent",
      toolText:find("plus ancien que cet outil", 1, true) ~= nil)
check("un appel impossible est signale",
      toolText:find("fonction absente de cette version", 1, true) ~= nil)

-- Ten minutes of black screen looked exactly like a hang, because capture()
-- redirected every print into the report and nothing reached the operator.
check("la progression est aussi affichee a l'ecran",
      toolText:find("real(line)", 1, true) ~= nil)
check("chaque section s'annonce",
      toolText:find('print("[" .. title .. "]")', 1, true) ~= nil)

-- Every hivemind function autoreport calls must exist, same trap as the menu
local called = {}
for name in toolText:gmatch("hivemind%.([%w_]+)%s*[(,)]") do called[name] = true end

local absent = {}
for name in pairs(called) do
    if name ~= "VERSION" and not defined[name] then table.insert(absent, name) end
end
check("autoreport n'appelle que des fonctions reelles", #absent == 0,
      table.concat(absent, ", "))

-- ---------------------------------------------------------------------------

print("")
print("-- probe --")

local prober = assert(io.open("tools/probe.lua", "r"))
local probeText = prober:read("*all")
prober:close()

-- It moves items into machines, so it must not do that just for being run
check("le sondage ne bouge rien sans --yes",
      probeText:find("Rien n", 1, true) ~= nil
      and probeText:find("ete deplace", 1, true) ~= nil)
check("il rend chaque marqueur",
      probeText:find("context.transport:retrieve", 1, true) ~= nil)
check("il ignore les marqueurs absents du reseau",
      probeText:find("ABSENT, ignore", 1, true) ~= nil)
check("il ne sonde que les machines sans driver",
      probeText:find("not config.machines[name].component", 1, true) ~= nil)

-- One ME round trip per attempt cost up to twenty seconds each: sixty attempts
-- turned a short experiment into an apparent hang. The marker is staged once
-- per machine and offered to every slot from the dock.
check("un seul approvisionnement par marqueur",
      probeText:find("transport:stage", 1, true) ~= nil
      and probeText:find("transport:deliver", 1, true) == nil)
check("le marqueur revient au quai entre deux slots",
      probeText:find("link.machine, link.source, 64, raw, dock", 1, true) ~= nil)
check("un marqueur jamais arrive est distingue d'un refus",
      probeText:find("jamais arrive au quai", 1, true) ~= nil)

print("")
print("=== Resultats ===")
print("Reussis : " .. passed)
print("Echoues : " .. failed)
print(failed == 0 and "Le menu est coherent." or "Des tests echouent.")

os.exit(failed == 0 and 0 or 1)
