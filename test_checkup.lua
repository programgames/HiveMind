-- HiveMind installation checkup tests
--
-- The property under test: a player who has just placed nine machines learns in
-- one screen whether they can start, and every complaint carries the gesture
-- that fixes it. A diagnostic that says "probleme" without saying what to do is
-- the thing this replaces.

package.path = package.path .. ";./?.lua"

local checkup = require("lib.checkup")

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

--- Find one finding by the name it reports under
local function findingFor(findings, name)
    for _, finding in ipairs(findings) do
        if finding.name == name then return finding end
    end
    return nil
end

--- Every finding of a whole report, sections flattened
local function allFindings(report)
    local flat = {}
    for _, section in ipairs(report.sections) do
        for _, finding in ipairs(section.findings) do
            table.insert(flat, finding)
        end
    end
    return flat
end

-- ---------------------------------------------------------------------------
-- A transport that answers whatever the test decides
-- ---------------------------------------------------------------------------

local function fakeTransport(world)
    return {
        interfaces = world.interfaces or {},

        isOnline = function(self)
            if world.online == false then return false, world.offlineReason end
            return true
        end,

        networkItemCount = function(self) return world.itemCount or 42 end,

        inventorySize = function(self, link)
            if world.sizes == nil then return nil end
            return world.sizes[link.machine]
        end,

        findAll = function(self, spec)
            return (world.stock or {})[spec.name] or {}
        end,

        -- Read-only look into one slot, keyed by face then by TRANSPOSER slot:
        -- the caller adds slot_offset, exactly as the real one does
        inspect = function(self, link, slot)
            local inventory = (world.contents or {})[link.machine]
            return inventory and inventory[slot] or nil
        end,
    }
end

local function healthyWorld()
    return {
        online = true,
        itemCount = 128,
        sizes = {[5] = 4, [3] = 4, [2] = 4},
        -- Keyed by BENCH, as lib/transport is: one interface per transposer
        interfaces = {["65d3da44-cb90-4812"] = {}},
        stock = {
            ["gendustry:labware"] = {{size = 64}},
            ["gendustry:gene_sample_blank"] = {{size = 200}},
        },
    }
end

local function healthyConfig()
    return {
        slot_offset = 1,
        interfaces = {["65d3da44"] = "983cd2bd"},
        machines = {
            sampler = {transposer = "65d3da44", machine = 5, source = 4,
                       slots = {blank = 0, labware = 1, input = 2, output = 3}},
        },
    }
end

print("-- une installation saine passe sans un mot --")

do
    local report = checkup.run({
        config = healthyConfig(),
        transport = fakeTransport(healthyWorld()),
        fluids = {{machine = "Mutatron", fluid = "mutagene", amount = 8000,
                   capacity = 10000}},
    })

    check("verdict: installation validee", report.ok, true)
    check("aucun geste demande", #report.gestures, 0)
    check("aucun probleme", report.counts.problem, 0)

    -- The order matters: everything reads as broken on a dead network, and
    -- sending someone to check nine faces when a cable is missing is the worst
    -- thing a diagnostic can do
    check("le reseau est verifie en premier",
          report.sections[1].title, "RESEAU")
end

print("")
print("-- une machine sur la mauvaise face --")

do
    local world = healthyWorld()
    world.sizes = {}   -- the declared face answers nothing at all

    local report = checkup.run({
        config = healthyConfig(),
        transport = fakeTransport(world),
        fluids = {},
    })

    check("verdict: pas pret", report.ok, false)

    local finding = findingFor(allFindings(report), "Sampler")
    check("le Sampler est en probleme", finding.status, checkup.PROBLEM)
    checkTruthy("le detail nomme la face declaree",
                finding.detail and finding.detail:find("face 5"))
    checkTruthy("et le geste envoie vers discover",
                finding.gesture and finding.gesture:find("discover"))
    checkTruthy("le geste remonte dans la liste finale", #report.gestures > 0)
end

print("")
print("-- une carte de slots qui depasse l inventaire --")

do
    -- The signature of a machine declared on the wrong face: every delivery
    -- lands nowhere and the failure reads as "la machine refuse cet objet",
    -- which sends the player inspecting a machine that is perfectly fine.
    local world = healthyWorld()
    world.sizes = {[5] = 2}   -- two slots, but the config reaches slot 4

    local report = checkup.run({
        config = healthyConfig(),
        transport = fakeTransport(world),
        fluids = {},
    })

    local finding = findingFor(allFindings(report), "Sampler")
    check("la carte incoherente est vue", finding.status, checkup.PROBLEM)
    checkTruthy("le detail donne les deux chiffres",
                finding.detail and finding.detail:find("4")
                and finding.detail:find("2"))
    checkTruthy("et le geste envoie vers probe",
                finding.gesture and finding.gesture:find("probe"))
end

print("")
print("-- une machine pas encore posee n est pas une panne --")

do
    local settings = healthyConfig()
    settings.machines.production_apiary = {transposer = "65d3da44",
                                           machine = nil, enabled = false}

    local report = checkup.run({
        config = settings,
        transport = fakeTransport(healthyWorld()),
        fluids = {},
    })

    check("le verdict reste bon", report.ok, true)

    local finding = findingFor(allFindings(report), "Apiary de production")
    check("elle est signalee absente", finding.status, checkup.ABSENT)
    check("et ne demande aucun geste", finding.gesture, nil)
    check("elle est comptee comme absente", report.counts.absent, 1)
end

print("")
print("-- une interface ME declaree mais invisible --")

do
    -- Une ME Interface sans Adapter est invisible, et chaque livraison echoue
    -- en donnant l impression que la machine refuse l objet.
    local world = healthyWorld()
    world.interfaces = {}

    local report = checkup.run({
        config = healthyConfig(),
        transport = fakeTransport(world),
        fluids = {},
    })

    check("verdict: pas pret", report.ok, false)

    local finding = findingFor(allFindings(report), "Banc 65d3da44")
    check("l interface manquante est vue", finding.status, checkup.PROBLEM)
    checkTruthy("le geste parle de l Adapter",
                finding.gesture and finding.gesture:find("Adapter"))
    checkTruthy("et nomme la machine qui en depend",
                finding.gesture and finding.gesture:find("Sampler"))
end

print("")
print("-- un banc qu on ne fait que lire n a besoin d aucune interface --")

do
    -- Le Liquifier et le Mutagen Producer n ont que leurs cuves lues, et un
    -- transposer lit une cuve sans interface. Exiger une interface la produisait
    -- une fausse alerte permanente.
    local settings = healthyConfig()
    settings.machines.protein_liquifier = {transposer = "a142f36b", machine = 4,
                                           source = nil, slots = {input = 2}}

    local world = healthyWorld()
    world.sizes[4] = 9

    local report = checkup.run({
        config = settings,
        transport = fakeTransport(world),
        fluids = {},
    })

    check("aucune interface reclamee pour ce banc", report.ok, true)
    check("et rien n est dit du banc a142f36b",
          findingFor(allFindings(report), "Banc a142f36b"), nil)
end

print("")
print("-- les consommables sans lesquels rien ne tourne --")

do
    local world = healthyWorld()
    world.stock = {["gendustry:labware"] = {{size = 3}}}

    local report = checkup.run({
        config = healthyConfig(),
        transport = fakeTransport(world),
        fluids = {},
    })

    local low = findingFor(allFindings(report), "labware")
    check("un stock trop bas est signale", low.status, checkup.PROBLEM)
    checkTruthy("avec le chiffre reel",
                low.detail and low.detail:find("3 en stock"))

    local none = findingFor(allFindings(report), "samples vierges")
    check("un stock nul aussi", none.status, checkup.PROBLEM)
    checkTruthy("et le geste dit l autocraft",
                none.gesture and none.gesture:find("autocraft"))
end

print("")
print("-- les cuves, dans le bon sens --")

do
    -- La cuve du DNA Extractor se REMPLIT au lieu de se vider. La signaler
    -- comme "plus d ADN" serait exactement l inverse de la verite.
    local findings = checkup.fluids({
        {machine = "Mutagen Producer", fluid = "mutagene", amount = 0,
         capacity = 8000, empty = true, low = true},
        {machine = "DNA Extractor", fluid = "ADN", amount = 7800,
         capacity = 8000, fills = true, full = true},
    })

    local empty = findingFor(findings, "Mutagen Producer")
    check("une cuve vide est un probleme", empty.status, checkup.PROBLEM)
    checkTruthy("et le geste dit que c est au joueur de la remplir",
                empty.gesture and empty.gesture:find("remplis"))

    local full = findingFor(findings, "DNA Extractor")
    check("une cuve pleine aussi", full.status, checkup.PROBLEM)
    checkTruthy("mais le geste dit de la VIDER, pas de la remplir",
                full.gesture and full.gesture:find("vide")
                and not full.gesture:find("remplis"))
end

print("")
print("-- un reseau hors tension arrete tout de suite --")

do
    local world = healthyWorld()
    world.online = false
    world.offlineReason = "reseau AE2 hors tension (stockage 0/1000)"

    local report = checkup.run({
        config = healthyConfig(),
        transport = fakeTransport(world),
        fluids = {},
    })

    check("verdict: pas pret", report.ok, false)

    local finding = findingFor(allFindings(report), "Reseau AE2")
    check("le reseau est le probleme", finding.status, checkup.PROBLEM)
    checkTruthy("et la raison porte les chiffres",
                finding.detail and finding.detail:find("stockage"))
end

print("")
print("-- l ordre des lignes ne bouge pas d une passe a l autre --")

do
    -- pairs() sur une table de config n a aucun ordre, et un diagnostic dont
    -- les lignes bougent entre deux passes ne se compare pas au precedent.
    local settings = healthyConfig()
    settings.machines.imprinter = {transposer = "65d3da44", machine = 2,
                                   slots = {template = 0, output = 3}}
    settings.machines.genetic_transposer = {transposer = "65d3da44", machine = 3,
                                            slots = {destination = 0, output = 3}}

    local function names()
        local report = checkup.run({
            config = settings,
            transport = fakeTransport(healthyWorld()),
            fluids = {},
        })
        local out = {}
        for _, section in ipairs(report.sections) do
            if section.title == "MACHINES" then
                for _, finding in ipairs(section.findings) do
                    table.insert(out, finding.name)
                end
            end
        end
        return table.concat(out, "|")
    end

    check("deux passes donnent le meme ordre", names(), names())
    check("et cet ordre est alphabetique", names(),
          "Genetic Transposer|Imprinter|Sampler")
end

print("")
print("-- ce qui reste dans les deux machines que le joueur remplit --")

-- Le Liquifier et le Mutagen Producer ne sont alimentes par personne: leurs
-- transposers ne touchent aucune interface ME. Le programme ne peut donc rien
-- y mettre -- mais il peut regarder dedans, et un ventre vide se voit bien
-- avant que la cuve qu il remplit ne soit seche.
-- Une machine apparait deux fois dans le rapport: la section MACHINES dit que
-- sa face repond, celle-ci dit ce qu il reste dedans. Chercher par nom dans
-- tout le rapport ramenait la premiere, et le test lisait la mauvaise ligne.
local function fedFinding(report, name)
    for _, section in ipairs(report.sections) do
        if section.title == "LES DEUX MACHINES QUE TU REMPLIS" then
            for _, finding in ipairs(section.findings) do
                if finding.name == name then return finding end
            end
        end
    end
    return nil
end

local function fedConfig()
    local settings = healthyConfig()

    settings.machines.protein_liquifier = {transposer = "a142f36b", machine = 4,
                                           source = nil, slots = {input = 0}}
    settings.machines.mutagen_producer = {transposer = "d28c3d3d", machine = 2,
                                          source = nil, slots = {input = 0}}
    return settings
end

local function fedWorld(contents)
    local world = healthyWorld()
    world.sizes[4] = 1
    world.sizes[2] = 1
    world.contents = contents
    return world
end

do
    -- Slot 0 de la machine, donc slot 1 du transposer: slot_offset vaut 1, et
    -- se tromper d un cran est la faute que ce projet a deja payee une fois
    local report = checkup.run({
        config = fedConfig(),
        transport = fakeTransport(fedWorld({
            [4] = {[1] = {label = "Raw Porkchop", size = 12}},
            [2] = {[1] = {label = "Glowstone Dust", size = 64}},
        })),
        fluids = {},
    })

    check("le verdict reste bon", report.ok, true)

    local liquifier = fedFinding(report, "Protein Liquifier")
    check("le Liquifier est repu", liquifier.status, checkup.OK)
    checkTruthy("et on lit ce qu il mange",
                liquifier.detail and liquifier.detail:find("Raw Porkchop"))
    checkTruthy("avec la quantite",
                liquifier.detail and liquifier.detail:find("12"))

    local producer = fedFinding(report, "Mutagen Producer")
    checkTruthy("le Producer aussi",
                producer.detail and producer.detail:find("Glowstone"))
end

do
    -- Un producteur vide n est PAS une panne: il a mange ce qu on lui a donne
    -- et rempli sa cuve. Le dire a chaque fois etait le bruit qui noyait les
    -- vrais avertissements.
    local report = checkup.run({
        config = fedConfig(),
        transport = fakeTransport(fedWorld({})),
        fluids = {{key = "mutagen_producer", machine = "Mutagen Producer",
                   fluid = "mutagene", amount = 9000, capacity = 10000}},
    })

    check("un ventre vide sur une cuve pleine ne bloque rien", report.ok, true)

    local producer = fedFinding(report, "Mutagen Producer")
    check("et ne compte pas comme un probleme", producer.status, checkup.OK)
    checkTruthy("mais le dit quand meme",
                producer.detail and producer.detail:find("cuve tient"))
end

do
    -- Vide ET la cuve qui suit: la chaine va s arreter, et c est la seule
    -- situation qui merite un geste
    local report = checkup.run({
        config = fedConfig(),
        transport = fakeTransport(fedWorld({})),
        fluids = {{key = "mutagen_producer", machine = "Mutagen Producer",
                   fluid = "mutagene", amount = 0, capacity = 10000,
                   empty = true, low = true}},
    })

    check("la, il faut le remplir", report.ok, false)

    local producer = fedFinding(report, "Mutagen Producer")
    check("et c est un probleme", producer.status, checkup.PROBLEM)
    checkTruthy("le geste dit quoi y mettre",
                producer.gesture and producer.gesture:find("mutagene"))
    checkTruthy("et pourquoi maintenant",
                producer.gesture and producer.gesture:find("s arreter"))

    -- Le Liquifier, lui, n a aucune cuve en peine dans ce relevé
    local liquifier = fedFinding(report, "Protein Liquifier")
    check("l autre machine n est pas entrainee avec", liquifier.status,
          checkup.OK)
end

do
    -- Une machine que la configuration ne nomme pas n a rien a signaler ici:
    -- la section MACHINES est la seule a parler de ce qui est declare
    local report = checkup.run({
        config = healthyConfig(),
        transport = fakeTransport(healthyWorld()),
        fluids = {},
    })

    check("une machine non declaree ne dit rien",
          fedFinding(report, "Protein Liquifier"), nil)
    check("et ne compte pas comme absente", report.counts.absent, 0)
end

print("")
print("=== Resultats ===")
print("Reussis : " .. passed)
print("Echoues : " .. failed)
print(failed == 0 and "Le controle d installation passe."
                   or "Des tests echouent.")

os.exit(failed == 0 and 0 or 1)
