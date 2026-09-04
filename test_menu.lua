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

local settings = assert(io.open("lib/config.lua", "r"))
local settingsText = settings:read("*all")
settings:close()

-- ---------------------------------------------------------------------------

print("-- entrees du menu --")

local actions, keys, labels = {}, {}, {}
for key, label, action in text:gmatch(
        'key%s*=%s*"(%w)"%s*,%s*label%s*=%s*"([^"]*)"[^}]-action%s*=%s*"([%w_]+)"') do
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

-- The dispatch lowercases the answer, so an uppercase key could never be typed
local unreachable = {}
for key in pairs(keys) do
    if key ~= key:lower() then table.insert(unreachable, key) end
end
check("aucune touche impossible a taper", #unreachable == 0,
      table.concat(unreachable, ", "))

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
check("l'extraction de gene est atteignable", wired.sampleGene == true)

-- Sampling is a lottery: thirteen bees on average per chosen gene, and a
-- species whose drones share one genome can never yield anything else however
-- many are spent. Reading the genome first is one look instead.
check("la lecture de genome est atteignable", wired.analyseBee == true)

-- A source species is needed exactly once: one individual, one sample, and the
-- allele is in the library forever. So the useful question is which shortest
-- list of species covers every gene still missing.
check("le plan de croisement est atteignable", wired.breedingPlan == true)

-- Collecting a Species gene one menu choice at a time is fine for two species
-- and hopeless for twenty
check("le balayage des especes est atteignable", wired.speciesSweep == true)
check("il ne relance pas une campagne deja en file",
      text:find("deja en file", 1, true) ~= nil)
check("il refuse de risquer le dernier drone d une espece",
      text:find("Trop peu de drones", 1, true) ~= nil)
-- Thirteen drones against one, and the program cannot do the one itself
check("il signale le raccourci qui coute un drone au lieu de treize",
      text:find("Perfected Imbuement Fabrial", 1, true) ~= nil)
check("il annonce le cout total avant de confirmer",
      text:find("au pire", 1, true) ~= nil)

-- The Replicator is the only machine that makes a bee out of nothing, which is
-- what turns the gene library from a museum into insurance
check("la replication est atteignable", wired.replicateBee == true)
check("elle exige un template complet, espece comprise",
      text:find("13 chromosomes sur 13", 1, true) ~= nil)
check("elle peut demander un template nomme au reseau",
      text:find("placeTemplate(context, \"replicator\")", 1, true) ~= nil)
check("mais jamais par son nom, seulement par empreinte",
      text:find("library:deliverTemplate", 1, true) ~= nil)

do
    local libraryText = io.open("lib/library.lua"):read("a")
    local transportText = io.open("lib/transport.lua"):read("a")

    -- Every template carries the same label, so checking the label proves
    -- nothing. What arrives is fingerprinted and compared.
    check("et la livraison est verifiee avant d entrer dans la machine",
          transportText:find("arrived ~= expected", 1, true) ~= nil
          and transportText:find("le reseau a livre un autre objet",
                                 1, true) ~= nil)
    check("la fiche du Database n est jamais celle du brouillon",
          libraryText:find("existing ~= self.scratchDbSlot", 1, true) ~= nil)
end

-- Naming happens while the template is still in the chest, because that is the
-- only moment the program can ever hold it
check("nommer les templates est atteignable", wired.nameTemplates == true)
check("et se fait tant qu ils sont dans le coffre",
      text:find("QUE tant que le template est dans le coffre", 1, true) ~= nil)
check("un template sans fiche est signale comme non demandable",
      text:find("PAS DE FICHE: pas demandable", 1, true) ~= nil)

-- The chest slot goes stale the moment the template is put into the network
check("et le slot du coffre est presente comme un souvenir",
      text:find("n est qu un souvenir", 1, true) ~= nil)

-- And the names have to be visible without going through the naming screen
check("l etat detaille montre les templates nommes",
      io.open("lib/library.lua"):read("a")
          :find("Templates nommes", 1, true) ~= nil)
check("elle annonce que le produit est une reine Ignoble",
      text:find("Il en sort une REINE", 1, true) ~= nil)

-- Symmetry with the other three machines said four slots each. The probe found
-- two, and the replicator has no labware slot at all.
do
    local settings = dofile("lib/config.lua")
    check("les slots du replicator sont ceux mesures",
          settings.machines.replicator.slots.template == 0
          and settings.machines.replicator.slots.output == 1
          and settings.machines.replicator.slots.labware == nil)
    check("ceux de l extracteur aussi",
          settings.machines.dna_extractor.slots.input == 0
          and settings.machines.dna_extractor.slots.labware == 1)
end

-- The extractor is the one place a bee is destroyed on purpose
check("l alimentation de l extracteur est atteignable",
      wired.feedExtractor == true)
check("elle refuse les especes dont le gene Species manque",
      text:find("gene Species pas encore acquis", 1, true) ~= nil)
check("elle garde une reserve de drones",
      text:find("drone_reserve", 1, true) ~= nil
      and settingsText:find("drone_reserve", 1, true) ~= nil)
check("elle dit clairement que les abeilles sont detruites",
      text:find("seront DETRUITES", 1, true) ~= nil)

-- "machine indisponible" is true and useless; four machines are declared and
-- not built
check("une machine non branchee explique quoi faire",
      text:find("tools/discover", 1, true) ~= nil
      and text:find("tools/probe", 1, true) ~= nil)

-- The player fills the tanks, so the only useful moment to mention them is
-- before an option that needs them is chosen
check("les reservoirs sont surveilles", wired.fluidLevels ~= nil
      or text:find("function hivemind.fluidLevels", 1, true) ~= nil)
check("un reservoir vide se distingue d un reservoir bas",
      text:find("plus de \" .. reading.fluid", 1, true) ~= nil
      or text:find("reading.empty", 1, true) ~= nil)
check("une machine non construite n est pas un probleme",
      text:find("link.enabled ~= false and link.machine ~= nil", 1, true) ~= nil)

-- Filling a template by hand is eleven separate campaigns and the carrier
-- species of each one typed from memory
check("la recolte groupee est atteignable", wired.harvestProfile == true)
check("elle ne relance pas un gene deja en file",
      text:find("Deja en file : ", 1, true) ~= nil)
check("elle distingue ce qui manque de ce qui est introuvable",
      text:find("A ATTRAPER D ABORD", 1, true) ~= nil)
check("elle prefere le porteur dont on a le plus de drones",
      text:find("Prefer the carrier we hold most of", 1, true) ~= nil)
check("elle croise la table du pack et les genomes lus",
      text:find("context.library:carriersOf(entry.slot, entry.allele)",
                1, true) ~= nil)
check("elle previent quand le labware ne suffira pas",
      text:find("pas assez de labware", 1, true) ~= nil)

check("les porteurs sont declares en config",
      settingsText:find("config.gene_carriers", 1, true) ~= nil)

-- A profile allele nobody carries is a dead end that only shows up months
-- later, in game, when the plan says "aucune espece n apporte ce gene".
-- These come from the bee itself and need no source species: they are what an
-- ordinary bee already is. Keyed by slot, because "None" needs a carrier on a
-- tolerance chromosome and needs none on Effect.
do
    local settings = dofile("lib/config.lua")
    local fromTheBeeItself = {
        [1]  = {["Fast"] = true},
        [9]  = {["Flowers"] = true},
        [10] = {["Slow"] = true},
        [11] = {["Average"] = true},
        [12] = {["None"] = true},
    }

    local orphans = {}
    for _, profile in pairs(settings.profiles or {}) do
        for slot, allele in pairs(profile) do
            local byAllele = settings.gene_carriers[slot]
            local ordinary = fromTheBeeItself[slot]
            if not (ordinary and ordinary[allele])
               and not (byAllele and byAllele[allele]) then
                table.insert(orphans, slot .. "=" .. allele)
            end
        end
    end

    check("chaque allele voulu sait d ou il vient: "
          .. (#orphans > 0 and table.concat(orphans, " ") or "-"),
          #orphans == 0)

    -- Four traits on one bee: Rocky is the single most valuable catch, and a
    -- table that lost that would send someone chasing four species instead
    local rocky = 0
    for _, byAllele in pairs(settings.gene_carriers) do
        for _, species in pairs(byAllele) do
            for _, one in ipairs(species) do
                if one == "Rocky" then rocky = rocky + 1 end
            end
        end
    end
    check("Rocky porte bien quatre genes voulus", rocky >= 4)
end
check("le plan les classe par nombre de genes apportes",
      text:find("#a.genes ~= #b.genes", 1, true) ~= nil)
check("et distingue ce qui est deja en stock",
      text:find("DEJA EN STOCK", 1, true) ~= nil)

check("elle ne detruit pas l abeille",
      text:find("Aucune abeille n est detruite", 1, true) ~= nil)
check("elle refuse de lire si une princesse peut declencher un cycle",
      text:find("slot reine de l apiary", 1, true) ~= nil)
check("elle compare le genome aux profils",
      text:find("context.library:has(slot, allele)", 1, true) ~= nil)

-- AE2 hides NBT, so a genome can only be learned by parking the bee in the
-- apiary. Read once, written down, never read again.
check("la lecture memorise ce qu elle apprend",
      text:find("context.library:recordGenome", 1, true) ~= nil)
check("le plan de croisement s en sert",
      text:find("context.library:carriersOf", 1, true) ~= nil)
check("il fonctionne sans table declaree a la main",
      text:find("ni table declaree, ni genome lu", 1, true) ~= nil)


-- floweringSlowest answered for Slow, which is the opposite value. A suffix
-- test refuses that; a substring one cannot.
check("la comparaison d allele est un suffixe, pas un substring",
      text:find("flat:sub(-#target) == target", 1, true) ~= nil)
check("un chromosome dont l uid ne suit pas l etiquette est signale",
      text:find("ne nomment pas leur allele", 1, true) ~= nil)

-- The menu redraws straight after an action and pushes its output off the top
local screenText = io.open("lib/screen.lua"):read("a")

-- The topology report is hundreds of lines. Reading it off a screen or
-- retyping it is not a workflow, and it was the only diagnostic with no way
-- out of the machine.
do
    local discoverText = io.open("tools/discover.lua"):read("a")
    local probeText = io.open("tools/probe.lua"):read("a")

    -- Two failures hid here and both looked like success: the request was
    -- never sent, and later it was sent and refused with 429. One module now
    -- does it for all three tools, and test_publish holds it.
    check("discover publie par lib.publish",
          discoverText:find("publish.report(body, mailbox)", 1, true) ~= nil)
    check("probe aussi",
          probeText:find("publish.report(table.concat(report", 1, true) ~= nil)
    check("et autoreport aussi",
          io.open("tools/autoreport.lua"):read("a")
              :find("publish.report(body, mailbox)", 1, true) ~= nil)
    -- config.interfaces cannot be guessed, and finding the new address used to
    -- mean a second round trip through another tool
    -- Two Imprinters is the whole point of having two profiles, and the old
    -- code keyed machines by name: the second overwrote the first in silence
    check("un deuxieme exemplaire d une machine ne remplace pas le premier",
          discoverText:find("deuxieme ", 1, true) ~= nil
          and discoverText:find("neighbour.machine .. \"_\" .. suffix",
                                1, true) ~= nil)

    -- Which chest is the template chest is a decision, not a discovery
    check("discover liste tous les coffres",
          discoverText:find("discovered.chests", 1, true) ~= nil)

-- The experiment pulls a template out of AE2. Leaving it in a dock would keep
-- it out of the network forever, and a dock left configured keeps pulling.
do
    local nbtText = io.open("tools/nbtprobe.lua"):read("a")

    check("l experience NBT rend toujours le quai",
          nbtText:find("Always give the template back", 1, true) ~= nil
          and nbtText:find("local verdict", 1, true) ~= nil
          and nbtText:find("return verdict", 1, true) ~= nil)
    check("elle ne demande rien sans --yes",
          nbtText:find("Rien n a ete deplace", 1, true) ~= nil)
    check("elle verifie que le reseau a quelque chose a rendre",
          nbtText:find("Aucun template dans le reseau", 1, true) ~= nil)
    check("elle compare deux empreintes, pas deux etiquettes",
          nbtText:find("delivered == wanted", 1, true) ~= nil)

    -- One template proves nothing: with a hundred in the network, a bridge that
    -- ignored the nbt could hand back the right one by luck
    check("elle teste chaque template, pas seulement le premier",
          nbtText:find("for _, entry in ipairs(templates) do", 1, true) ~= nil
          and nbtText:find("askFor(entry)", 1, true) ~= nil)
    check("et refuse de conclure sur un seul contenu",
          nbtText:find("NON CONCLUANT", 1, true) ~= nil)
    check("elle tranche par un verdict lisible",
          nbtText:find("VERDICT : OUI", 1, true) ~= nil
          and nbtText:find("VERDICT : NON", 1, true) ~= nil)
    check("et empreinte tout le coffre au passage",
          nbtText:find("empreinte(s) distincte(s)", 1, true) ~= nil)

    check("l installeur la connait",
          io.open("tools/hminstall.lua"):read("a")
              :find("tools/nbtprobe.lua", 1, true) ~= nil)
end

    check("discover liste les interfaces adressables",
          discoverText:find("component.list(\"me_interface\")", 1, true) ~= nil)
    check("et dit ou les reporter",
          discoverText:find("config.interfaces", 1, true) ~= nil)

    -- A dry run that stops before sending is a report nobody outside the
    -- machine ever sees -- and the dry run is the one worth reading first
    check("probe publie meme sans rien deplacer",
          probeText:find("local function send()", 1, true) ~= nil)
    check("le repli sec appelle l envoi",
          probeText:find("Rien n'a ete deplace", 1, true) ~= nil)

    -- Probing a bench whose slots are already measured disturbs something that
    -- works, and probing a machine with no source concludes the exact opposite
    -- of the truth about it
    check("probe accepte des noms de machines",
          probeText:find("non demandee", 1, true) ~= nil)
    check("et refuse de sonder ce qu on ne livre jamais",
          probeText:find("aucune source d items", 1, true) ~= nil)

    check("aucun outil ne poste plus dans son coin",
          discoverText:find("internet.request", 1, true) == nil
          and probeText:find("internet.request", 1, true) == nil)
    check("discover sait envoyer son rapport",
          discoverText:find("--upload", 1, true) ~= nil
          and discoverText:find("report_mailbox", 1, true) ~= nil)
    check("et le dit quand on ne le lui demande pas",
          discoverText:find("relance avec --upload", 1, true) ~= nil)
    check("sans carte Internet il ne perd pas le rapport",
          discoverText:find("le rapport reste sur le disque", 1, true) ~= nil)
end

check("chaque action laisse le temps de lire",
      screenText:find("Entree pour revenir au menu", 1, true) ~= nil)
check("le menu marque la pause apres chaque action",
      text:find("screen.pause()", 1, true) ~= nil)

-- Pausing was never the whole fix: the previous output is still on screen when
-- the menu draws over it
check("et efface avant de redessiner",
      text:find("screen.clear()", 1, true) ~= nil)
check("l ecran est mis a sa taille maximale au demarrage",
      text:find("screen.maximise()", 1, true) ~= nil)

-- Forty lines of menu on a twenty-five line screen scroll away as they are
-- drawn, cleared or not
check("le menu se replie quand l ecran est trop court",
      text:find("fullMenuHeight", 1, true) ~= nil
      and text:find("local columns = (width >= 76) and 2 or 1", 1, true) ~= nil)
check("un choix inconnu se lit avant de disparaitre",
      text:find("Choix inconnu", 1, true) ~= nil)

do
    local screenLib = dofile("lib/screen.lua")

    -- Off OpenComputers there is no gpu and no term, and every one of these is
    -- called before the menu can draw anything
    check("l ecran repond hors du jeu sans lever d erreur",
          screenLib.height() == 25 and screenLib.width() == 80
          and screenLib.clear() == false)

    local width, height = screenLib.maximise()
    check("maximiser sans carte graphique rend une taille utilisable",
          tonumber(width) ~= nil and tonumber(height) ~= nil)
end

-- The apiary keeps its drone, so every read leaves one behind. Reading that one
-- costs nothing; replacing it costs a bee and usually fails anyway.
check("une abeille deja en place peut etre relue",
      text:find("La lire elle ?", 1, true) ~= nil)



check("la duplication est atteignable", wired.duplicateGene == true)
check("la mise a l'abri est atteignable", wired.secureLibrary == true)

-- A cross needs a princess of one species and a DRONE of the other. Treating
-- "we have some Water bees" as "we can cross with Water" left a plan stuck on
-- "Water Drone introuvable" with three Water princesses in store.
check("la disponibilite distingue les roles",
      text:find("local function rolesFrom", 1, true) ~= nil)
check("le planificateur programme l'accumulation manquante",
      text:find("accumulation programmee pour", 1, true) ~= nil)
check("et il la met en file avant le croisement",
      (function()
          local from = text:find("function hivemind.planChain", 1, true)
          if not from then return false end

          -- Up to the next top-level "end", so the two submits compared are
          -- both this function's and not another's
          local stop = text:find("\nend\n", from, true) or #text
          local body = text:sub(from, stop)
          local accumulate = body:find('queue:submit("multiply"', 1, true)
          local breed = body:find('queue:submit("breed"', 1, true)

          return accumulate ~= nil and breed ~= nil and accumulate < breed
      end)())

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
check("genetics est charge", loaded.genetics == true)
for _, kind in ipairs({"breed", "multiply", "sample", "duplicate", "campaign"}) do
    check("la tache '" .. kind .. "' est enregistree",
          text:find('register("' .. kind .. '"', 1, true) ~= nil)
end

-- A module older than this file has none of the newer factories, and calling
-- one produced a stack trace naming machine.lua, which says nothing about the
-- actual fix
check("un module trop ancien est signale, pas fatal",
      text:find("est plus ancien que le programme", 1, true) ~= nil)

-- Templates share one id and one label, so AE2 cannot tell two apart and one
-- that enters the network is lost. They can only move between a chest and a
-- machine on the same transposer.
check("les deux profils sont declares",
      settingsText:find("config.profiles", 1, true) ~= nil
      and settingsText:find("breeding = {", 1, true) ~= nil
      and settingsText:find("production = {", 1, true) ~= nil)

-- Species blank is what lets one template serve every species
check("Species reste hors des profils",
      settingsText:find("%[0%]%s*=%s*\"") == nil)

check("l aide compare la bibliotheque aux profils",
      text:find("missingForProfile", 1, true) ~= nil)

-- A missing allele with no idea which bee carries it is a list, not a plan
check("chaque gene manquant peut nommer une espece",
      settingsText:find("config.gene_sources", 1, true) ~= nil
      and text:find("config.gene_sources", 1, true) ~= nil)

-- The free-text list and the structured table are read by different code and
-- drift silently. Anything named in one has to exist in the other, or the plan
-- ranks species the hint never mentions -- and the reverse.
do
    local settings = dofile("lib/config.lua")

    local mismatched = {}
    for slot in pairs(settings.gene_sources or {}) do
        if not settings.gene_carriers[slot] then
            table.insert(mismatched, "texte sans porteur: " .. slot)
        end
    end
    for slot in pairs(settings.gene_carriers or {}) do
        if not (settings.gene_sources or {})[slot] then
            table.insert(mismatched, "porteur sans texte: " .. slot)
        end
    end

    check("les deux listes de sources disent la meme chose: "
          .. (#mismatched > 0 and table.concat(mismatched, ", ") or "-"),
          #mismatched == 0)

    -- Effect stays unattributed on purpose: no bee is bred for None, it is
    -- what a bee has until something gives it an effect
    check("l effet reste sans source, volontairement",
          settings.gene_sources[12] == nil
          and settings.gene_carriers[12] == nil)
end

-- The two profiles are not ours to improve: they are the pack community's
-- answer, posted on the MeatballCraft Discord and transcribed here trait by
-- trait. Every "obvious" upgrade to them has a reason not to be made -- Speed
-- stays Fast on a breeding line that dies on purpose, Flowering stays Slow
-- because an Industrial Apiary ignores pollination, Cave dwelling is absent
-- because the apiary provides it. So they get pinned, and any edit has to
-- argue with this test first.
do
    local settings = dofile("lib/config.lua")
    local slotFor = {
        ["Speed"] = 1, ["Lifespan"] = 2, ["Fertility"] = 3,
        ["Temperature Tolerance"] = 4, ["Never Sleeps"] = 5,
        ["Humidity Tolerance"] = 6, ["Tolerates Rain"] = 7,
        ["Flowers"] = 9, ["Flowering"] = 10, ["Territory"] = 11,
        ["Effect"] = 12,
    }

    local discord = {
        breeding = {
            ["Never Sleeps"] = "True",   ["Flowering"] = "Slow",
            ["Speed"] = "Fast",          ["Humidity Tolerance"] = "Both 3",
            ["Flowers"] = "Flowers",     ["Lifespan"] = "Shortest",
            ["Effect"] = "None",         ["Tolerates Rain"] = "True",
            ["Fertility"] = "4",         ["Territory"] = "Average",
            ["Temperature Tolerance"] = "Both 3",
        },
        production = {
            ["Never Sleeps"] = "True",   ["Flowering"] = "Slow",
            ["Speed"] = "Robotic",       ["Humidity Tolerance"] = "Both 3",
            ["Flowers"] = "Flowers",     ["Lifespan"] = "Immortal",
            ["Effect"] = "None",         ["Tolerates Rain"] = "True",
            ["Fertility"] = "1",         ["Territory"] = "Average",
            ["Temperature Tolerance"] = "Both 3",
        },
    }

    local drift = {}
    for name, wanted in pairs(discord) do
        local profile = settings.profiles[name] or {}

        local extra = {}
        for slot, allele in pairs(profile) do extra[slot] = allele end

        for trait, allele in pairs(wanted) do
            local slot = slotFor[trait]
            if profile[slot] ~= allele then
                table.insert(drift, string.format("%s/%s attendu %s, trouve %s",
                    name, trait, allele, tostring(profile[slot])))
            end
            extra[slot] = nil
        end

        for slot, allele in pairs(extra) do
            table.insert(drift, name .. "/slot " .. slot .. " en trop = " .. allele)
        end
    end

    check("les profils sont ceux du Discord du pack, trait pour trait: "
          .. (#drift > 0 and table.concat(drift, " | ") or "-"),
          #drift == 0)

    -- Species absent is the whole point: a template that carried one would
    -- overwrite the species of every bee it is applied to
    check("Species reste hors des deux profils",
          settings.profiles.breeding[0] == nil
          and settings.profiles.production[0] == nil)

    -- Cave dwelling is the thirteenth chromosome, the one the list does not
    -- name. Adding it is a change to the pack's answer, not a fix to ours.
    check("Cave dwelling reste hors des deux profils, comme la liste",
          settings.profiles.breeding[8] == nil
          and settings.profiles.production[8] == nil)
end

check("le coffre a templates est verifie au demarrage",
      text:find("le coffre a templates est sur le transposer", 1, true) ~= nil)

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

-- "6 alleles sur 6 chromosomes" says nothing about which six or how exposed
-- they are, and the library is the whole point of phase 2
check("le rapport detaille la bibliotheque",
      toolText:find("BIBLIOTHEQUE DE GENES", 1, true) ~= nil)
check("il nomme les chromosomes plutot que leur numero",
      toolText:find("genome.labelForSlot(slot)", 1, true) ~= nil)
check("et il charge bien le module qui les nomme",
      toolText:find('pcall(require, "lib.genome")', 1, true) ~= nil)

-- Any module the tool uses must be required, or it is a nil global that fails
-- silently rather than loudly
for _, module in ipairs({"lib.genetics", "lib.multiply", "lib.genome", "lib.config"}) do
    local short = module:match("%.(%w+)$")
    if toolText:find(short .. "%.%w") then
        check("le module " .. module .. " est charge",
              toolText:find('require, "' .. module .. '"', 1, true) ~= nil
              or toolText:find('require("' .. module .. '")', 1, true) ~= nil)
    end
end
check("il signale ce qui est sous le seuil",
      toolText:find("sous le seuil de securite", 1, true) ~= nil)

-- Guessing item ids cost two rounds: gendustry:gene_template is refused by every
-- machine and gendustry:gene_template_blank does not exist. The network knows
-- the real names.
check("le rapport enumere les items gendustry",
      toolText:find("ITEMS GENDUSTRY DANS LE RESEAU", 1, true) ~= nil)

-- The whole point of this tool is that a session fits in one command with no
-- menu: a feature reachable only from the menu is a feature we cannot test
-- together without a screenshot round trip.
check("la mise a l'abri est pilotable sans menu",
      toolText:find('arg == "--secure"', 1, true) ~= nil)
check("les campagnes de genes aussi",
      toolText:find('arg == "--genes"', 1, true) ~= nil)
check("une campagne deja en file n'est pas recreee",
      toolText:find("deja en file", 1, true) ~= nil)

-- A crash nine sections in lost everything that had been collected, after the
-- work had already been done in the world
check("le rapport est publie meme apres une interruption",
      toolText:find("pcall(main, {...})", 1, true) ~= nil
      and toolText:find("publish(wantsUpload)", 1, true) ~= nil)
check("l'interruption apparait dans le rapport",
      toolText:find("=== INTERROMPU ===", 1, true) ~= nil)
check("la memoire est rapportee",
      toolText:find("computer.freeMemory()", 1, true) ~= nil)

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
-- Returned to the dock rather than to the network: the same single item is
-- offered to the next slot, instead of paying another ME round trip
check("il reprend chaque marqueur",
      probeText:find("link.machine, link.source, 64, raw, dock", 1, true) ~= nil)
-- Docks are reserved per bench: releasing without the link frees a key nobody
-- holds, and every dock stays marked busy for the rest of the run
check("et libere le quai en nommant son banc",
      probeText:find("transport:releaseDock(dock, link)", 1, true) ~= nil)
check("aucune liberation anonyme",
      probeText:find("releaseDock(dock)", 1, true) == nil)
check("il ignore les marqueurs absents du reseau",
      probeText:find("ABSENT, ignore", 1, true) ~= nil)
check("il ne sonde que les machines sans driver",
      probeText:find("if link.component then", 1, true) ~= nil)

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

-- A Genetic Transposer handed a blank and a source simply did the job and kept
-- the result. Anything left in a machine is invisible to the ME network, which
-- is how a bee reported as missing ends up sitting two blocks away.
check("le sondage range les machines a la fin",
      probeText:find("RANGEMENT", 1, true) ~= nil
      and probeText:find("transport:retrieve(link, raw, 64)", 1, true) ~= nil)
check("et dit ce qui resiste",
      probeText:find("slot(s) encore occupe(s)", 1, true) ~= nil)

print("")
print("=== Resultats ===")
print("Reussis : " .. passed)
print("Echoues : " .. failed)
print(failed == 0 and "Le menu est coherent." or "Des tests echouent.")

os.exit(failed == 0 and 0 or 1)
