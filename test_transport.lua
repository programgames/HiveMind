-- HiveMind transport layer tests
--
-- The mocked AE2 network and transposer follow the shapes and the semantics
-- calibration measured in game, including the two that already cost a wasted
-- trip: component methods are callable tables, and store() reports the previous
-- occupancy of the database slot rather than success.

package.path = package.path .. ";./?.lua"

local transport = require("lib.transport")

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

local SIDE_SOURCE, SIDE_MACHINE = 3, 2
local LINK = {transposer = 1, machine = SIDE_MACHINE, source = SIDE_SOURCE}

local world, calls

local function reset(options)
    options = options or {}

    world = {
        network = {
            {name = "gendustry:gene_sample", label = "Bee Sample - Species: Cultivated",
             size = 4, hasTag = true},
            {name = "gendustry:gene_sample", label = "Bee Sample - Speed: Fastest",
             size = 1, hasTag = true},
            {name = "gendustry:labware", label = "Labware", size = 64},
            {name = "gendustry:gene_sample", label = "Bee Sample - Epuise", size = 0},
        },
        interface = {},        -- dock -> {stack, count}
        machine = {},          -- slot -> stack
        database = {},         -- slot -> stack
        neverStocks = options.neverStocks,
        moveShort = options.moveShort,
        numericTransfer = options.numericTransfer,
        stickyDock = options.stickyDock,
        storeRefuses = options.storeRefuses,
    }

    calls = {store = 0, configure = 0, transfer = 0, cleared = {}}
end

local me = {
    getItemsInNetwork = callable(function(filter)
        if filter and filter.name then
            local matching = {}
            for _, item in ipairs(world.network) do
                if item.name == filter.name then table.insert(matching, item) end
            end
            return matching
        end
        return world.network
    end),

    -- Returns false when the filter matches nothing, and leaves the database
    -- slot untouched. Reading only pcall's success would take that for a win.
    store = callable(function(filter, address, slot, count)
        calls.store = calls.store + 1

        if world.storeRefuses then return false end

        for _, item in ipairs(world.network) do
            if item.label == filter.label then
                world.database[slot] = item
                return true
            end
        end
        return false
    end),

    setInterfaceConfiguration = callable(function(dock, address, entry, count)
        calls.configure = calls.configure + 1

        if not address then
            -- AE2 does not hand the stocked item back instantly. world.stickyDock
            -- reproduces a dock that keeps its previous contents, which is what
            -- once sent a Labware to the Mutatron labelled as a princess.
            if not world.stickyDock then
                world.interface[dock] = nil
            end
            table.insert(calls.cleared, dock)
            return true
        end

        if world.neverStocks then return true end
        world.interface[dock] = {stack = world.database[entry], count = count or 1}
        return true
    end),

    isNetworkPowered = callable(function() return true end),
}

local transposer = {
    getSlotStackSize = callable(function(side, slot)
        if side == SIDE_SOURCE then
            local staged = world.interface[slot]
            return staged and staged.count or 0
        end
        local stack = world.machine[slot]
        return stack and (stack.size or 1) or 0
    end),

    -- The Replicator and the Liquifier expose no component; their tanks are
    -- only readable through the transposer that already serves their slots
    getFluidInTank = callable(function(side)
        if world.tanks == nil then return nil end
        return world.tanks[side]
    end),

    getStackInSlot = callable(function(side, slot)
        if side == SIDE_SOURCE then
            if world.interfaceOverride then return world.interfaceOverride end
            local staged = world.interface[slot]
            return staged and staged.stack or nil
        end
        return world.machine[slot]
    end),

    -- This build documents transferItem as returning :boolean; other versions
    -- return the amount moved. world.numericTransfer switches between the two
    -- so both are exercised.
    transferItem = callable(function(fromSide, toSide, count, fromSlot, toSlot)
        calls.transfer = calls.transfer + 1

        if world.moveShort then return world.numericTransfer and 0 or false end

        local function answer()
            return world.numericTransfer and count or true
        end

        if fromSide == SIDE_SOURCE then
            local staged = world.interface[fromSlot]
            if not staged then return world.numericTransfer and 0 or false end
            world.machine[toSlot] = staged.stack
            world.interface[fromSlot] = nil
            return answer()
        end

        local stack = world.machine[fromSlot]
        if not stack then return world.numericTransfer and 0 or false end
        world.machine[fromSlot] = nil
        return answer()
    end),

    -- Reports prior occupancy of the database slot, never success
    store = callable(function(side, slot, address, dbSlot)
        local occupied = world.database[dbSlot] ~= nil
        world.database[dbSlot] = (side == SIDE_SOURCE)
            and (world.interface[slot] and world.interface[slot].stack)
            or world.machine[slot]
        return occupied
    end),

    compareStackToDatabase = callable(function(side, slot, address, dbSlot, checkNBT)
        local stack = (side == SIDE_SOURCE)
            and (world.interface[slot] and world.interface[slot].stack)
            or world.machine[slot]
        local reference = world.database[dbSlot]
        return stack ~= nil and reference ~= nil and stack.label == reference.label
    end),
}

local database = {
    address = "db-0000",
    clear = callable(function(slot) world.database[slot] = nil return true end),
    get = callable(function(slot) return world.database[slot] end),
    computeHash = callable(function(slot)
        local stack = world.database[slot]
        if not stack then return nil end
        return "hash:" .. stack.label
    end),
}

local ticks = 0
local function newTransport()
    return transport.new({
        me = me,
        database = database,
        transposers = {transposer},
        config = {docks = {1, 2}, stock_timeout_seconds = 3, poll_interval_seconds = 1},
        sleep = function() end,
        clock = function() ticks = ticks + 1 return ticks end,
    })
end

print("=== Transport layer tests ===")
print("")
print("-- recherche dans le reseau --")

reset()
local layer = newTransport()

local found = layer:find({label = "Bee Sample - Species: Cultivated"})
checkTruthy("sample trouve par etiquette", found)
check("bon item", found and found.name, "gendustry:gene_sample")

-- Two samples share one item id: only the label separates them
local other = layer:find({name = "gendustry:gene_sample", label = "Bee Sample - Speed: Fastest"})
check("l'etiquette departage deux stacks du meme item",
      other and other.label, "Bee Sample - Speed: Fastest")

check("item absent", (layer:find({label = "Inexistant"})), nil)
check("stack a zero ignore", (layer:find({label = "Bee Sample - Epuise"})), nil)
check("specification invalide", (layer:find("texte")), nil)

print("")
print("-- livraison vers une machine --")

reset()
layer = newTransport()

local ok, err = layer:deliver({label = "Bee Sample - Species: Cultivated"}, LINK, 7)
checkTruthy("livraison reussie (" .. tostring(err) .. ")", ok)
check("item arrive dans le bon slot", world.machine[7] and world.machine[7].label,
      "Bee Sample - Species: Cultivated")
check("un seul store", calls.store, 1)
check("un seul transfert", calls.transfer, 1)

-- A dock left configured would keep draining that item out of the network
checkTruthy("le quai a ete libere", #calls.cleared > 0)
check("aucun quai encore reserve", next(layer.reserved), nil)

-- Same delivery against the other documented return convention
reset({numericTransfer = true})
layer = newTransport()

local numeric_ok, numeric_err = layer:deliver({label = "Bee Sample - Speed: Fastest"}, LINK, 4)
checkTruthy("livraison avec transferItem numerique (" .. tostring(numeric_err) .. ")", numeric_ok)
check("item arrive aussi dans ce mode", world.machine[4] and world.machine[4].label,
      "Bee Sample - Speed: Fastest")

print("")
print("-- quais de chargement --")

reset()
layer = newTransport()

local first = layer:reserveDock()
local second = layer:reserveDock()
check("premier quai", first, 1)
check("second quai", second, 2)
check("pool epuise", (layer:reserveDock()), nil)

layer:releaseDock(first)
check("quai reutilisable apres liberation", layer:reserveDock(), 1)

print("")
print("-- pannes --")

reset({neverStocks = true})
layer = newTransport()
local stocked, stock_err = layer:deliver({label = "Bee Sample - Speed: Fastest"}, LINK, 1)
check("AE2 ne fournit pas -> echec", stocked, false)
checkTruthy("raison explicite", stock_err and stock_err:find("delai"))
check("quai libere malgre l'echec", next(layer.reserved), nil)

reset({moveShort = true})
layer = newTransport()
local moved, move_err = layer:deliver({label = "Bee Sample - Speed: Fastest"}, LINK, 1)
check("refus de la machine -> echec", moved, false)
-- A machine rejecting an insertion gives no reason of its own, so the message
-- has to say what was refused, where, and what was already in the way
checkTruthy("l'item refuse est nomme", move_err and move_err:find("Speed: Fastest", 1, true))
checkTruthy("le slot vise est nomme", move_err and move_err:find("slot 1", 1, true))
checkTruthy("le contenu du slot est rapporte", move_err and move_err:find("contient", 1, true))
check("quai libere malgre l'echec", next(layer.reserved), nil)

-- store() answering false must not pass for success. A stale database entry is
-- then stocked instead, and AE2 delivers the wrong item with total confidence.
reset({storeRefuses = true})
layer = newTransport()
world.database[1] = {label = "Genetics Labware", name = "gendustry:labware"}

local stale, stale_err = layer:deliver({label = "Bee Sample - Speed: Fastest"}, LINK, 1)
check("store() refuse -> echec", stale, false)
checkTruthy("la cause est nommee", stale_err and stale_err:find("database", 1, true))
check("aucune livraison du mauvais item", world.machine[1], nil)
check("quai libere", next(layer.reserved), nil)

-- The entry left over from a previous staging must not be reused either
reset()
layer = newTransport()
world.database[1] = {label = "Genetics Labware", name = "gendustry:labware"}
local fresh = layer:deliver({label = "Bee Sample - Speed: Fastest"}, LINK, 3)
checkTruthy("l'entree perimee est remplacee", fresh)
check("bon item livre", world.machine[3] and world.machine[3].label,
      "Bee Sample - Speed: Fastest")

-- A dock that never releases its contents is caught before anything is moved,
-- rather than after the wrong item has been fed to a machine
reset()
layer = newTransport()
world.interfaceOverride = {label = "Cobblestone", name = "minecraft:cobblestone", size = 1}
local wrong, wrong_err = layer:deliver({label = "Bee Sample - Speed: Fastest"}, LINK, 1)
check("quai bloque detecte", wrong, false)
checkTruthy("l'occupant est nomme", wrong_err and wrong_err:find("Cobblestone", 1, true))
check("rien n'a ete livre", world.machine[1], nil)
check("quai libere", next(layer.reserved), nil)

-- The real failure: a dock still holding the previous operation's item. Its
-- size satisfies a naive check, and a Labware gets delivered as a princess.
reset({stickyDock = true})
layer = newTransport()
world.interface[1] = {stack = {label = "Genetics Labware", name = "gendustry:labware"}, count = 1}

local sticky, sticky_err = layer:deliver({label = "Bee Sample - Speed: Fastest"}, LINK, 1)
check("quai encombre detecte", sticky, false)
checkTruthy("le reliquat est nomme",
            sticky_err and sticky_err:find("Genetics Labware", 1, true))
check("rien n'a ete livre", world.machine[1], nil)
check("quai libere", next(layer.reserved), nil)

-- And once the dock does empty, the delivery goes through
reset()
layer = newTransport()
world.interface[1] = {stack = {label = "Genetics Labware"}, count = 1}
local recovered = layer:deliver({label = "Bee Sample - Speed: Fastest"}, LINK, 2)
checkTruthy("livraison apres liberation du quai", recovered)
check("bon item arrive", world.machine[2] and world.machine[2].label,
      "Bee Sample - Speed: Fastest")

reset()
layer = newTransport()
local missing, missing_err = layer:deliver({label = "Inexistant"}, LINK, 1)
check("item absent -> echec", missing, false)
checkTruthy("raison explicite", missing_err and missing_err:find("introuvable"))
check("aucun quai gaspille", next(layer.reserved), nil)

print("")
print("-- retrait depuis une machine --")

reset()
layer = newTransport()
world.machine[3] = {name = "forestry:bee_drone_ge", label = "Forest Drone", size = 5}

check("items rendus au reseau", layer:retrieve(LINK, 3, 5), 5)
check("slot machine vide", world.machine[3], nil)

print("")
print("-- transfert machine a machine --")

reset()
layer = newTransport()

local MUTATRON = {transposer = 1, machine = 5, source = SIDE_SOURCE}
local APIARY = {transposer = 1, machine = 2, source = SIDE_SOURCE}

world.machine[2] = {name = "forestry:bee_queen_ge", label = "Common Queen"}

-- The queen must not travel through AE2: it exposes no genome, so we would lose
-- track of which queen is ours
local direct, direct_err = layer:transferBetween(MUTATRON, 2, APIARY, 0, 1)
checkTruthy("transfert direct reussi (" .. tostring(direct_err) .. ")", direct)
check("aucun quai consomme", next(layer.reserved), nil)
check("aucun passage par le reseau", calls.store, 0)

local OTHER = {transposer = 2, machine = 1, source = SIDE_SOURCE}
local crossed, crossed_err = layer:transferBetween(MUTATRON, 2, OTHER, 0, 1)
check("transposers differents refuse", crossed, false)
checkTruthy("raison explicite", crossed_err and crossed_err:find("transposer"))

check("liaison manquante refusee", (layer:transferBetween(nil, 1, APIARY, 0)), false)

reset({moveShort = true})
layer = newTransport()
world.machine[2] = {name = "forestry:bee_queen_ge", label = "Common Queen"}
check("transfert incomplet detecte", (layer:transferBetween(MUTATRON, 2, APIARY, 0, 1)), false)

print("")
print("-- inspection --")

reset()
layer = newTransport()
world.machine[2] = {name = "forestry:bee_queen_ge", label = "Wintry Queen"}
check("lecture d'un slot machine", layer:inspect(LINK, 2).label, "Wintry Queen")
check("slot vide", layer:inspect(LINK, 9), nil)

print("")
print("-- empreinte de template --")

reset()
layer = newTransport()
world.machine[1] = {name = "gendustry:gene_template", label = "Genetic Template"}

local hash, hash_err = layer:fingerprint(LINK, 1, 9)
check("empreinte calculee (" .. tostring(hash_err) .. ")", hash, "hash:Genetic Template")

-- Two templates look identical; only the fingerprint tells them apart
world.machine[2] = {name = "gendustry:gene_template", label = "Genetic Template"}
checkTruthy("un template correspond a sa reference", layer:matchesReference(LINK, 2, 9))

world.machine[2] = {name = "gendustry:gene_sample", label = "Bee Sample - Speed: Fastest"}
check("un item different est detecte", layer:matchesReference(LINK, 2, 9), false)

-- The empty-database case is what a wrong tier would look like
reset()
layer = newTransport()
local no_hash, no_hash_err = layer:fingerprint(LINK, 5, 9)
check("slot vide -> pas d'empreinte", no_hash, nil)
checkTruthy("piste donnee sur la database", no_hash_err and no_hash_err:find("database"))

print("")
print("-- etat du reseau --")

reset()
layer = newTransport()
checkTruthy("reseau en ligne", layer:isOnline())
check("items du reseau comptes", layer:networkItemCount(), 4)

local offline = transport.new({me = {}, database = database, transposers = {transposer}})
check("interface injoignable", (offline:isOnline()), false)
check("comptage sans interface", offline:networkItemCount(), 0)

-- "Unpowered" alone sends you looking in the wrong place; the figures say where
local unpowered = transport.new({
    me = {
        isNetworkPowered = callable(function() return false end),
        getStoredPower = callable(function() return 0 end),
        getMaxStoredPower = callable(function() return 20000 end),
        getEnergyDemand = callable(function() return 12.5 end),
    },
    database = database, transposers = {transposer},
})

local up, why = unpowered:isOnline()
check("hors tension detecte", up, false)
checkTruthy("stockage rapporte", why and why:find("stockage 0/20000", 1, true))
checkTruthy("demande rapportee", why and why:find("demande 12.5", 1, true))

local unwired = transport.new({me = me, database = database, transposers = {}})
check("aucun transposer configure", (unwired:transposerFor(1)), nil)

print("")
print("-- findAll filtre sur l'etiquette exacte --")

-- Ignoring spec.label made a caller counting one species count the whole item
-- type: a campaign holding four Common drones saw 37 and declared victory.
world.network = {
    {name = "forestry:bee_drone_ge", label = "Common Drone", size = 4},
    {name = "forestry:bee_drone_ge", label = "Wintry Drone", size = 32},
    {name = "forestry:bee_drone_ge", label = "Monastic Drone", size = 1},
    {name = "forestry:bee_princess_ge", label = "Common Princess", size = 1},
}

local layer = newTransport()

local commons = layer:findAll({name = "forestry:bee_drone_ge", label = "Common Drone"})
check("une seule pile correspond", #commons, 1)
check("la bonne quantite", commons[1] and commons[1].size, 4)

local allDrones = layer:findAll({name = "forestry:bee_drone_ge"})
check("sans etiquette, tout le type remonte", #allDrones, 3)

local absent = layer:findAll({name = "forestry:bee_drone_ge", label = "Water Drone"})
check("une etiquette absente ne remonte rien", #absent, 0)

print("")
print("-- une interface ME par banc --")

-- Two benches, two interface blocks. Stocking a dock only works on the
-- interface that dock belongs to; configuring one while watching the other
-- means the item never arrives, and every failure reads as "the machine
-- refused it". A whole probe run reported that, fifteen times over.
local configured = {}

local function fakeInterface(tag)
    return {
        setInterfaceConfiguration = callable(function(dock)
            table.insert(configured, tag .. ":" .. tostring(dock))
            return true
        end),
        store = callable(function() return false end),
        getItemsInNetwork = callable(function() return {} end),
    }
end

local twoBenches = transport.new({
    me = fakeInterface("defaut"),
    interfaces = {[1] = fakeInterface("genetique"), [2] = fakeInterface("elevage")},
    database = {address = "db"},
    transposers = {},
    config = {docks = {1, 2}},
})

checkTruthy("le banc 1 a son interface",
            twoBenches:interfaceFor({transposer = 1}) ~= twoBenches.me)
checkTruthy("le banc 2 aussi",
            twoBenches:interfaceFor({transposer = 2}) ~= twoBenches.me)
check("un banc inconnu retombe sur l'interface par defaut",
      twoBenches:interfaceFor({transposer = 9}), twoBenches.me)
check("sans lien, l'interface par defaut", twoBenches:interfaceFor(nil), twoBenches.me)

-- Docks are numbered per interface: both benches have a dock 1, and treating
-- them as one pool would hand the same dock to two benches at once
local first = twoBenches:reserveDock({transposer = 1})
local second = twoBenches:reserveDock({transposer = 2})
check("chaque banc obtient son quai 1", first, 1)
check("sans se le disputer", second, 1)

twoBenches:releaseDock(first, {transposer = 1})
check("la liberation vise la bonne interface",
      configured[#configured], "genetique:1")

-- ---------------------------------------------------------------------------
-- Fluid tanks
--
-- Four of the seven machines have no component at all. Warning that the DNA is
-- low instead of failing on it is the only thing separating a run that stops
-- politely from one that reports a machine refusing items.

do
    local reader = newTransport()
    local link = {transposer = 1, machine = SIDE_MACHINE, source = SIDE_SOURCE}

    world.tanks = {}
    check("aucun reservoir lisible rend une liste vide", #reader:tanks(link), 0)
    checkTruthy("et aucun reservoir du tout, pas une erreur",
                reader:tank(link) == nil)

    world.tanks = {
        [SIDE_MACHINE] = {
            {amount = 200, capacity = 2000, label = "Liquid DNA"},
            {amount = 1500, capacity = 2000, label = "Mutagen"},
        },
    }

    local tanks = reader:tanks(link)
    check("les reservoirs sont lus par le transposer", #tanks, 2)
    check("et leur remplissage calcule", tanks[1].ratio, 0.1)
    check("le plus rempli est celui qu on remonte",
          (reader:tank(link) or {}).label, "Mutagen")

    -- An empty tank carries no fluid and therefore no name. Skipping it would
    -- hide exactly the state worth warning about.
    world.tanks = {[SIDE_MACHINE] = {{amount = 0, capacity = 8000}}}
    local empty = reader:tanks(link)[1]
    check("un reservoir vide est rapporte quand meme", empty and empty.ratio, 0)

    -- A machine with no side declared must not be read from side nil
    check("un lien sans face ne lit rien", #reader:tanks({transposer = 1}), 0)

    world.tanks = nil
end

print("")
print("=== Resultats ===")
print("Reussis : " .. passed)
print("Echoues : " .. failed)
print(failed == 0 and "Tous les tests du transport passent." or "Des tests echouent.")

os.exit(failed == 0 and 0 or 1)
