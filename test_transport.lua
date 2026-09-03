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

    store = callable(function(filter, address, slot, count)
        calls.store = calls.store + 1
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
            world.interface[dock] = nil
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

    getStackInSlot = callable(function(side, slot)
        if side == SIDE_SOURCE then
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
check("transfert incomplet -> echec", moved, false)
checkTruthy("raison explicite", move_err and move_err:find("incomplet"))
check("quai libere malgre l'echec", next(layer.reserved), nil)

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

local offline = transport.new({me = {}, database = database, transposers = {transposer}})
check("interface injoignable", (offline:isOnline()), false)

local unwired = transport.new({me = me, database = database, transposers = {}})
check("aucun transposer configure", (unwired:transposerFor(1)), nil)

print("")
print("=== Resultats ===")
print("Reussis : " .. passed)
print("Echoues : " .. failed)
print(failed == 0 and "Tous les tests du transport passent." or "Des tests echouent.")

os.exit(failed == 0 and 0 or 1)
