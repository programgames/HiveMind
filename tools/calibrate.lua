-- HiveMind calibration tool
--
-- Standalone in-game diagnostic. Run it once on the OpenComputers machine and
-- send back the generated report; every parser of the genetics layer is written
-- against the strings it captures instead of against assumptions made outside
-- the game.
--
-- READ ONLY by default: nothing is moved, consumed, crafted or modified. Every
-- call is wrapped so a missing component or an unexpected API never aborts.
--
-- Usage:
--   calibrate                  write the report to /home/hivemind-calibration.txt
--   calibrate /path/file.txt   write it somewhere else
--   calibrate --test-db        additionally fingerprint a template into the
--                              Database upgrade (writes a ghost stack into a
--                              database slot, nothing in the world moves)

local component = require("component")
local computer = require("computer")
local sides = require("sides")

local DEFAULT_OUTPUT = "/home/hivemind-calibration.txt"
local MAX_ME_ENTRIES = 80      -- the ME network holds thousands of item types
local MAX_DEPTH = 6

local report = {}

-- Location of a Genetic Template found while scanning, subject of the optional
-- fingerprint test. Templates cannot be read, but they can be hashed.
local found_template = nil

--- Append one line to the report and echo it to the screen
--- @param text string|nil Line to record (nil means blank line)
local function say(text)
    text = text or ""
    table.insert(report, text)
    print(text)
end

--- Append to the report without echoing (for bulky dumps)
--- @param text string|nil Line to record
local function record(text)
    table.insert(report, text or "")
end

local function header(title)
    say("")
    say("=== " .. title .. " ===")
end

--- Render any value as readable Lua-ish text, cycle safe and depth limited
--- The whole point of calibration is to discover field names we do not know,
--- so nothing here may assume a shape.
--- @param value any Value to render
--- @param indent string|nil Current indentation
--- @param depth number|nil Current depth
--- @param seen table|nil Tables already visited on this branch
--- @return string rendered
local function dump(value, indent, depth, seen)
    indent = indent or ""
    depth = depth or 0
    seen = seen or {}

    local kind = type(value)

    if kind == "string" then
        return string.format("%q", value)
    elseif kind ~= "table" then
        return tostring(value)
    end

    if seen[value] then return "<cycle>" end
    if depth >= MAX_DEPTH then return "<...>" end

    seen[value] = true

    -- Sort keys so two reports can be diffed
    local keys = {}
    for key in pairs(value) do
        table.insert(keys, key)
    end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)

    if #keys == 0 then
        seen[value] = nil
        return "{}"
    end

    local inner = indent .. "  "
    local parts = {"{"}

    for _, key in ipairs(keys) do
        table.insert(parts, inner .. "[" .. tostring(key) .. "] = "
            .. dump(value[key], inner, depth + 1, seen) .. ",")
    end

    table.insert(parts, indent .. "}")
    seen[value] = nil

    return table.concat(parts, "\n")
end

--- Call a component method defensively
--- Component methods are NOT functions: machine.lua builds them as
---   proxy[method] = setmetatable({address=..., name=...}, componentCallback)
--- so they are tables carrying a __call metamethod. Testing for "function"
--- rejects every method of every component, so only nil is checked here and the
--- call itself is left to decide.
--- @param proxy table|nil Component proxy
--- @param method string Method name
--- @return boolean ok
--- @return any result First return value, or the error message
local function call(proxy, method, ...)
    if not proxy then return false, "no component" end

    local target = proxy[method]
    if target == nil then return false, "method absent" end

    local ok, result = pcall(target, ...)
    return ok, result
end

--- Call a method and record the outcome under a label
--- @param proxy table|nil Component proxy
--- @param method string Method name
local function probe(proxy, method, ...)
    local ok, result = call(proxy, method, ...)

    if ok then
        record("  " .. method .. "() = " .. dump(result, "  "))
    else
        record("  " .. method .. "() -> UNAVAILABLE: " .. tostring(result))
    end

    return ok, result
end

--- First available component of any of the given types
--- @param ... string Component type names, in priority order
--- @return table|nil proxy
--- @return string|nil kind Component type that matched
local function firstAvailable(...)
    for _, kind in ipairs({...}) do
        if component.isAvailable(kind) then
            return component.getPrimary(kind), kind
        end
    end
    return nil, nil
end

-- ---------------------------------------------------------------------------
-- Section 1: what is actually connected
-- ---------------------------------------------------------------------------

local function sectionComponents()
    header("1. COMPOSANTS CONNECTES")

    local found = {}
    for address, kind in component.list() do
        table.insert(found, {address = address, kind = kind})
    end
    table.sort(found, function(a, b) return a.kind < b.kind end)

    for _, entry in ipairs(found) do
        say(string.format("  %-28s %s", entry.kind, entry.address:sub(1, 8)))
    end

    say("")
    local expected = {
        "advmutatron", "industrial_apiary", "me_interface", "me_controller",
        "transposer", "database", "inventory_controller", "redstone"
    }

    for _, kind in ipairs(expected) do
        say(string.format("  %-22s %s", kind,
            component.isAvailable(kind) and "PRESENT" or "absent"))
    end

    -- The real API, as this exact mod version exposes it. Beats any doc.
    header("1b. API REELLE DES COMPOSANTS CLES")

    for _, kind in ipairs({"advmutatron", "industrial_apiary", "me_interface",
                           "me_controller", "database", "transposer"}) do
        if component.isAvailable(kind) then
            local proxy = component.getPrimary(kind)
            local address = proxy.address
            record("")
            record("-- " .. kind .. " --")

            -- component.methods() is authoritative; walking the proxy is the
            -- fallback, skipping the plain data fields it also carries.
            local names = {}
            local listed, methods = pcall(component.methods, address)

            if listed and type(methods) == "table" then
                for name in pairs(methods) do
                    table.insert(names, name)
                end
            else
                local skip = {address = true, type = true, slot = true, fields = true}
                for name in pairs(proxy) do
                    if not skip[name] then table.insert(names, name) end
                end
            end

            table.sort(names)
            say("  " .. kind .. ": " .. #names .. " methode(s)")

            for _, name in ipairs(names) do
                local ok, doc = pcall(component.doc, address, name)
                record("  " .. name .. (ok and doc and ("  --  " .. doc) or ""))
            end
        end
    end

    say("  (API detaillee ecrite dans le rapport)")
end

-- ---------------------------------------------------------------------------
-- Section 2: Industrial Apiary — the genome reader
-- ---------------------------------------------------------------------------

local function sectionApiary()
    header("2. INDUSTRIAL APIARY")

    local apiary = firstAvailable("industrial_apiary")
    if not apiary then
        say("  Aucun composant industrial_apiary. Adapter branche sur l'apiary ?")
        return
    end

    say("  Composant present.")
    probe(apiary, "listSlots")
    probe(apiary, "getEnvironment")
    probe(apiary, "getModifiers")
    probe(apiary, "listUpgrades")
    probe(apiary, "listOutputs")
    probe(apiary, "getErrors")
    probe(apiary, "getProgress")

    -- The decisive test: does a parked bee expose its full genome?
    local ok, bees = call(apiary, "getBees")
    record("")
    record("  getBees() = " .. dump(bees, "  "))

    if ok and type(bees) == "table" then
        local subject = bees.queen or bees.drone
        if subject and subject.nbt then
            say("  GENOME LISIBLE: le NBT est expose (" .. #tostring(subject.nbt) .. " caracteres).")
            record("")
            record("  --- DUMP NBT BRUT DE L'ABEILLE GAREE ---")
            record(tostring(subject.nbt))
            record("  --- FIN DUMP ---")
        elseif subject then
            say("  Abeille presente mais AUCUN champ nbt -> a signaler, le design en depend.")
        else
            say("  Slots queen et drone vides: pose une abeille dedans et relance.")
        end
    end
end

-- ---------------------------------------------------------------------------
-- Section 2b: the live breeding database
-- ---------------------------------------------------------------------------

--- Capture the mutation data the game itself holds
--- The driver exposes listAllSpecies / getBeeParents / getBeeBreedingData, which
--- would make the hardcoded 304-entry table redundant: no drift with the pack,
--- no duplicate keys, and alternative mutation paths become visible. Their exact
--- shape decides whether the planner can be fed from the game.
local function sectionBreedingData()
    header("2b. BASE DE MUTATIONS VIVANTE")

    local apiary = firstAvailable("industrial_apiary")
    if not apiary then
        say("  Pas d'industrial_apiary, section ignoree.")
        return
    end

    -- These can be very large; report the size and a readable sample
    local function sample(method, limit, ...)
        local ok, result = call(apiary, method, ...)

        if not ok then
            say("  " .. method .. " -> indisponible: " .. tostring(result))
            record("  " .. method .. " -> indisponible: " .. tostring(result))
            return nil
        end

        if type(result) ~= "table" then
            say("  " .. method .. " = " .. tostring(result))
            record("  " .. method .. " = " .. dump(result, "  "))
            return result
        end

        local count = 0
        for _ in pairs(result) do count = count + 1 end
        say("  " .. method .. " : " .. count .. " entree(s)")

        record("")
        record("  --- " .. method .. " (" .. count .. " entrees, " .. limit .. " montrees) ---")

        local shown = 0
        for key, value in pairs(result) do
            if shown >= limit then break end
            shown = shown + 1
            record("  [" .. tostring(key) .. "] = " .. dump(value, "  "))
        end
        record("  --- fin ---")

        return result
    end

    local species = sample("listAllSpecies", 8)
    sample("getBeeBreedingData", 3)
    probe(apiary, "canBreed")

    -- getBeeParents needs a species name; take one from the live list
    local subject = nil
    if type(species) == "table" then
        for _, value in pairs(species) do
            if type(value) == "string" then
                subject = value
                break
            elseif type(value) == "table" then
                subject = value.name or value.uid or value.species or value.label
                if subject then break end
            end
        end
    end

    subject = subject or "forestry.speciesCultivated"
    say("  getBeeParents teste avec: " .. tostring(subject))
    sample("getBeeParents", 6, subject)
end

-- ---------------------------------------------------------------------------
-- Section 3: Advanced Mutatron
-- ---------------------------------------------------------------------------

local function sectionMutatron()
    header("3. ADVANCED MUTATRON")

    local mutatron = firstAvailable("advmutatron")
    if not mutatron then
        say("  Aucun composant advmutatron. Adapter branche sur le Mutatron ?")
        return
    end

    say("  Composant present.")
    probe(mutatron, "listSlots")
    probe(mutatron, "getTank")
    probe(mutatron, "canStart")
    probe(mutatron, "getProgress")
    probe(mutatron, "getOutput")

    -- listMutations only says something useful with two parents loaded
    local ok, mutations = call(mutatron, "listMutations")
    record("")
    record("  listMutations() = " .. dump(mutations, "  "))

    if ok and type(mutations) == "table" then
        local count = 0
        for _ in pairs(mutations) do count = count + 1 end
        say("  listMutations(): " .. count .. " entree(s).")
        if count == 0 then
            say("  (charge deux parents dans le Mutatron et relance pour voir le format)")
        end
    end
end

-- ---------------------------------------------------------------------------
-- Section 4: ME network — how gendustry items look from AE2
-- ---------------------------------------------------------------------------

local function sectionNetwork()
    header("4. RESEAU ME")

    local me, kind = firstAvailable("me_interface", "me_controller")
    if not me then
        say("  Aucun composant me_interface / me_controller.")
        say("  Il faut un Adapter colle a une ME Interface (ou un ME Controller).")
        return
    end

    say("  Composant " .. kind .. " present.")

    -- Only gendustry items matter here, and the network holds thousands of types
    local ok, items = call(me, "getItemsInNetwork", {name = "gendustry:gene_sample"})
    if not ok then
        -- Older signatures may reject the filter; fall back to the full listing
        ok, items = call(me, "getItemsInNetwork")
        record("  (filtre refuse, listing complet filtre localement)")
    end

    if not ok or type(items) ~= "table" then
        say("  getItemsInNetwork indisponible: " .. tostring(items))
        return
    end

    local shown = 0
    record("")
    record("  --- ITEMS GENDUSTRY DANS LE RESEAU ---")

    for _, item in pairs(items) do
        if type(item) == "table" then
            local name = tostring(item.name or "")
            if name:find("gendustry", 1, true) then
                shown = shown + 1
                if shown <= MAX_ME_ENTRIES then
                    record("  [" .. shown .. "] " .. dump(item, "  "))
                end
            end
        end
    end

    record("  --- FIN (" .. shown .. " entree(s)) ---")
    say("  " .. shown .. " item(s) gendustry vus dans le reseau.")

    if shown == 0 then
        say("  Mets au moins un Gene Sample dans le reseau et relance:")
        say("  c'est lui qui verrouille le parseur 'Chromosome: Allele'.")
    end

    -- The interface config slots are our loading docks: called bare it answers
    -- nil, so ask for a specific slot
    probe(me, "getInterfaceConfiguration", 1)
    probe(me, "isNetworkPowered")
end

-- ---------------------------------------------------------------------------
-- Section 5: adjacent inventories — what OC itself exposes per stack
-- ---------------------------------------------------------------------------

--- Component able to read adjacent inventories, best first
--- The Transposer is preferred over the Inventory Controller: it reads AND
--- moves, whereas the upgrade sitting in an Adapter only ever inspects.
--- @return table|nil reader
--- @return string|nil kind
local function inventoryReader()
    if component.isAvailable("transposer") then
        return component.getPrimary("transposer"), "transposer"
    end
    if component.isAvailable("inventory_controller") then
        return component.inventory_controller, "inventory_controller"
    end
    return nil, nil
end

local function sectionInventories()
    header("5. INVENTAIRES ADJACENTS")

    local inv, reader_kind = inventoryReader()
    if not inv then
        say("  Ni transposer ni inventory_controller.")
        say("  Le Transposer est le bon choix: lui seul sait deplacer des items.")
        return
    end

    say("  Lecture via " .. reader_kind
        .. (reader_kind == "transposer" and " (peut aussi deplacer)" or " (lecture seule)"))

    local all_sides = {sides.down, sides.up, sides.north, sides.south, sides.west, sides.east}
    local side_names = {[0] = "bottom", [1] = "top", [2] = "north/back",
                        [3] = "south/front", [4] = "west/right", [5] = "east/left"}

    local samples_seen, templates_seen = 0, 0

    for _, side in ipairs(all_sides) do
        local ok, size = call(inv, "getInventorySize", side)

        if ok and type(size) == "number" and size > 0 then
            say(string.format("  %-12s %d slots", side_names[side] or side, size))

            for slot = 1, size do
                local got, stack = call(inv, "getStackInSlot", side, slot)

                if got and type(stack) == "table" then
                    local name = tostring(stack.name or "")
                    local label = tostring(stack.label or "")

                    -- Dump the complete field set of anything genetics related:
                    -- we need to know exactly which fields OC hands us
                    if name:find("gendustry", 1, true) then
                        record("")
                        record("  " .. (side_names[side] or side) .. " slot " .. slot
                            .. " = " .. dump(stack, "  "))

                        if name:find("gene_sample", 1, true) and label ~= "" then
                            samples_seen = samples_seen + 1
                            say("    SAMPLE label = " .. label)
                        elseif name:find("gene_template", 1, true) then
                            templates_seen = templates_seen + 1
                            say("    TEMPLATE label = " .. label
                                .. "  (hasTag=" .. tostring(stack.hasTag) .. ")")

                            -- Remember one, so the fingerprint test has a subject
                            found_template = found_template
                                or {side = side, slot = slot, reader = reader_kind}
                        end
                    end
                end
            end
        end
    end

    say("")
    say("  " .. samples_seen .. " gene sample(s), " .. templates_seen .. " template(s) en coffre.")
end

-- ---------------------------------------------------------------------------
-- Section 6: Database upgrade — the NBT-exact reference we need for AE2
-- ---------------------------------------------------------------------------

local function sectionDatabase()
    header("6. DATABASE UPGRADE")

    local db = firstAvailable("database")
    if not db then
        say("  Aucun composant database. C'est lui qui permet de designer un item")
        say("  par son NBT exact dans AE2 -> indispensable pour les samples.")
        return
    end

    say("  Composant present, adresse " .. db.address:sub(1, 8))

    -- Read-only inspection: report what the database already holds
    for slot = 1, 3 do
        probe(db, "get", slot)
    end
end

-- ---------------------------------------------------------------------------
-- Section 6b: template fingerprinting (opt-in, --test-db)
-- ---------------------------------------------------------------------------

--- Prove that a Genetic Template can be identified without being readable
--- Templates share one item id and one label; only their NBT differs, and no
--- machine slot exposes it. But transposer.store() copies the whole stack, NBT
--- included, into a Database upgrade, and computeHash() then yields a stable
--- identifier. That is enough to detect a tampered template library.
local function sectionFingerprint(enabled)
    header("6b. EMPREINTE DE TEMPLATE (test optionnel)")

    if not enabled then
        say("  Non execute. Relance avec --test-db pour le tester.")
        say("  Ce test ecrit un stack fantome dans le Database upgrade;")
        say("  rien ne bouge dans le monde.")
        return
    end

    local db = firstAvailable("database")
    if not db then
        say("  Pas de Database upgrade: test impossible.")
        return
    end

    if not found_template then
        say("  Aucun Genetic Template vu en coffre adjacent.")
        say("  Pose un template dans un coffre lu par le Transposer et relance.")
        return
    end

    if found_template.reader ~= "transposer" then
        say("  Template trouve, mais lu via " .. found_template.reader .. ".")
        say("  store() vers une database demande un Transposer.")
        return
    end

    local transposer = component.getPrimary("transposer")
    local DB_SLOT = 9  -- high slot, unlikely to collide with anything in use

    say("  Template en " .. found_template.side .. "/" .. found_template.slot
        .. " -> database slot " .. DB_SLOT)

    local stored_ok, stored = call(transposer, "store",
        found_template.side, found_template.slot, db.address, DB_SLOT)

    if not stored_ok or not stored then
        say("  ECHEC store(): " .. tostring(stored))
        say("  -> l'empreinte de template n'est pas disponible, a signaler.")
        return
    end

    say("  store() OK.")
    probe(db, "get", DB_SLOT)

    local hash_ok, hash = call(db, "computeHash", DB_SLOT)
    if hash_ok and hash then
        say("  EMPREINTE = " .. tostring(hash))
        say("  -> l'index des templates sera verifiable, le risque principal tombe.")
        record("  computeHash(" .. DB_SLOT .. ") = " .. tostring(hash))
    else
        say("  computeHash indisponible: " .. tostring(hash))
    end

    -- NBT-aware comparison: the other half of the integrity check
    local cmp_ok, cmp = call(transposer, "compareStackToDatabase",
        found_template.side, found_template.slot, db.address, DB_SLOT, true)
    say("  compareStackToDatabase(checkNBT=true) = "
        .. (cmp_ok and tostring(cmp) or ("indisponible: " .. tostring(cmp))))

    say("  (le slot " .. DB_SLOT .. " de la database peut etre efface a la main)")
end

-- ---------------------------------------------------------------------------
-- Section 7: environment
-- ---------------------------------------------------------------------------

local function sectionEnvironment()
    header("7. ENVIRONNEMENT")

    say("  Memoire libre : " .. math.floor(computer.freeMemory() / 1024) .. " Ko")
    say("  Memoire totale: " .. math.floor(computer.totalMemory() / 1024) .. " Ko")
    say("  Energie       : " .. math.floor(computer.energy())
        .. " / " .. math.floor(computer.maxEnergy()))
    say("  Lua           : " .. _VERSION)
end

-- ---------------------------------------------------------------------------

local function main(args)
    local output_path = nil
    local test_db = false

    for _, arg in ipairs(args) do
        if arg == "--test-db" then
            test_db = true
        elseif not output_path then
            output_path = arg
        end
    end

    output_path = output_path or DEFAULT_OUTPUT

    say("=========================================")
    say("  HiveMind - calibration")
    say("=========================================")

    local sections = {
        sectionComponents, sectionApiary, sectionBreedingData, sectionMutatron,
        sectionNetwork, sectionInventories, sectionDatabase,
        function() sectionFingerprint(test_db) end,
        sectionEnvironment
    }

    for _, section in ipairs(sections) do
        local ok, err = pcall(section)
        if not ok then
            say("  ERREUR DANS LA SECTION: " .. tostring(err))
        end
    end

    header("A FAIRE AVANT DE RENVOYER LE RAPPORT")
    say("  Pour que la calibration serve a quelque chose, il faut que le")
    say("  programme ait vu au moins une fois:")
    say("   1. une abeille dans le slot queen ou drone de l'Industrial Apiary")
    say("      (c'est elle qui donne le format du genome)")
    say("   2. un Gene Sample, en coffre adjacent ou dans le reseau ME")
    say("      (c'est lui qui donne le format 'Chromosome: Allele')")
    say("   3. deux parents charges dans le Mutatron")
    say("      (pour voir le format de listMutations)")
    say("  Si une de ces trois lignes manque au rapport, remets l'item en place")
    say("  et relance. Test optionnel mais precieux: pose un Genetic Template a")
    say("  la main dans un slot de SORTIE de l'apiary et relance - si listOutputs")
    say("  le montre avec un champ nbt, on gagne la lecture des templates.")

    local file, err = io.open(output_path, "w")
    if not file then
        say("")
        say("ECHEC ECRITURE: " .. tostring(err))
        return
    end

    file:write(table.concat(report, "\n"))
    file:write("\n")
    file:close()

    print("")
    print("Rapport ecrit dans " .. output_path)
end

main({...})
