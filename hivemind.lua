-- HiveMind
--
-- Entry point: wires the modules to the real machines, reports what it found,
-- resumes whatever was interrupted, and offers a small menu.
--
-- Nothing here contains logic worth testing; everything it does is delegated.
-- Its job is to fail clearly when the world is not what the configuration
-- claims, rather than to index a nil three modules deeper.

local MODULE_NAME = ...

do
    local source = debug.getinfo(1, "S").source
    local here = source:match("^@(.*)[/\\][^/\\]*$")
    if here and not package.path:find(here, 1, true) then
        package.path = here .. "/?.lua;" .. here .. "/?/init.lua;" .. package.path
    end

    -- OpenOS keeps required modules in package.loaded for the whole session.
    -- This file is re-read on every launch, but lib/* would stay at whatever
    -- version was loaded first, so an update silently has no effect until a
    -- reboot: a new program driving stale modules. Dropping ours makes
    -- "hminstall then hivemind" enough.
    for name in pairs(package.loaded) do
        if type(name) == "string" and name:match("^lib%.") then
            package.loaded[name] = nil
        end
    end
end

local component = require("component")

--- Load a module, saying which one is missing rather than dying on a bare colon
--- A module added to the program but forgotten in the installer's file list
--- produced an empty error and a stack trace pointing at package.lua, which
--- names neither the module nor the fix.
--- @param name string
--- @return table module
local function need(name)
    local ok, module = pcall(require, name)

    if not ok or type(module) ~= "table" then
        print("Module manquant ou illisible : " .. name)
        print("Detail : " .. tostring(module))
        print("")
        print("Lance 'hminstall' pour (re)telecharger les fichiers du programme.")
        error("module " .. name .. " indisponible", 0)
    end

    return module
end

local config = need("lib.config")
local transport = need("lib.transport")
local machines = need("lib.machines")
local library = need("lib.library")
local species = need("lib.species")
local jobs = need("lib.jobs")
local breeding = need("lib.breeding")
local multiply = need("lib.multiply")
local genetics = need("lib.genetics")
local planner = need("lib.planner")
local genome = need("lib.genome")

local hivemind = {}

-- Printed at startup so "am I running the version we just fixed?" is answerable
-- without counting bytes. raw.githubusercontent.com serves through a CDN that
-- can hand out the previous file for a few minutes after a push, which has
-- already cost one round of confusion.
hivemind.VERSION = "0.42.0"

--- Resolve a component, without throwing when it is absent
--- @param kind string
--- @return table|nil proxy
local function optional(kind)
    if not component.isAvailable(kind) then return nil end

    local ok, proxy = pcall(component.getPrimary, kind)
    return ok and proxy or nil
end

--- Resolve the transposers named in the configuration
--- Falls back to the primary transposer when no address is listed, which is the
--- single-transposer case.
--- @return table[] transposers
--- @return string[] problems
local function resolveTransposers()
    local resolved, problems = {}, {}

    if #config.transposers == 0 then
        local primary = optional("transposer")
        if primary then
            table.insert(resolved, primary)
        else
            table.insert(problems, "aucun transposer sur le reseau")
        end
        return resolved, problems
    end

    for index, address in ipairs(config.transposers) do
        local ok, proxy = pcall(component.proxy, address)
        if ok and proxy then
            resolved[index] = proxy
        else
            table.insert(problems,
                "transposer " .. index .. " introuvable (" .. address:sub(1, 8) .. ")")
        end
    end

    return resolved, problems
end

--- Build everything and report what is missing
--- @param options table|nil {stateDirectory} Overrides, used by the tests
--- @return table context
--- @return string[] problems
function hivemind.bootstrap(options)
    options = options or {}
    local stateDirectory = options.stateDirectory or config.state_directory
    local problems = {}

    local transposers, transposerProblems = resolveTransposers()
    for _, problem in ipairs(transposerProblems) do table.insert(problems, problem) end

    -- Keyed by their own address so a machine can name the transposer it sits
    -- on. Positions shift the moment another transposer joins the network.
    local transposersByAddress = {}
    for address in component.list("transposer") do
        local ok, proxy = pcall(component.proxy, address)
        if ok and proxy then transposersByAddress[address] = proxy end
    end

    local me = optional("me_interface") or optional("me_controller")
    if not me then table.insert(problems, "aucune interface ME (adapter sur la ME Interface ?)") end

    -- One interface per bench. Configuring one while watching another bench's
    -- dock means the item never arrives, and every failure reads as "the
    -- machine refused it" -- which cost a whole probe run.
    local interfaces = {}
    for address in component.list("me_interface") do
        local resolved, proxy = pcall(component.proxy, address)
        if resolved and proxy then interfaces[address] = proxy end
    end

    local byBench = {}
    for bench, address in pairs(config.interfaces or {}) do
        -- A prefix, because that is all a component listing shows and writing
        -- a full uuid from memory means writing one that does not exist
        local proxy = nil
        for full, candidate in pairs(interfaces) do
            if full:sub(1, #address) == address then proxy = candidate break end
        end

        if proxy then
            byBench[bench] = proxy
        else
            table.insert(problems, "interface ME du transposer " .. tostring(bench)
                .. " introuvable (" .. tostring(address):sub(1, 8)
                .. ") - un Adapter la touche-t-il ?")
        end
    end

    -- A bench with no interface of its own cannot be supplied at all, and the
    -- failure looks like a machine refusing every item
    for _, name in ipairs(config.enabledMachines()) do
        local bench = config.machines[name].transposer
        if bench and not byBench[bench] and next(config.interfaces or {}) then
            table.insert(problems, name
                .. " : aucune interface ME adressable sur son transposer "
                .. tostring(bench) .. " (Adapter manquant ?)")
        end
    end

    local database = optional("database")
    if not database then
        table.insert(problems, "aucune Database upgrade (dans le slot d'un Adapter)")
    end

    local layer = transport.new({
        me = me,
        interfaces = byBench,
        byAddress = transposersByAddress,
        database = database or {address = nil},
        transposers = transposers,
        config = config.transport,
    })

    local components = {}
    for _, kind in ipairs({"advmutatron", "industrial_apiary"}) do
        components[kind] = optional(kind)
    end

    local built, missing = machines.all({
        config = config,
        components = components,
        transport = layer,
        onWait = function(name, status, elapsed)
            print(string.format("[attente] %s: %s depuis %ds", name, status, elapsed))
        end,
    })

    for _, name in ipairs(missing) do
        table.insert(problems, "composant absent pour " .. name .. " (adapter branche ?)")
    end

    local registry = species.new({
        apiary = components.industrial_apiary,
        cachePath = stateDirectory .. "/species.lua",
    })

    local genes = library.new({
        transport = layer,
        templateLink = {
            transposer = config.template_chest.transposer,
            machine = config.template_chest.side,
            source = config.machines.mutatron.source,
        },
        path = stateDirectory .. "/library.lua",
        config = config,
    })

    local queue = jobs.new({
        path = stateDirectory .. "/jobs.lua",
        handlers = {breed = breeding.handler(),
                    multiply = multiply.handler(),
                    sample = genetics.sampleHandler(),
                    duplicate = genetics.duplicateHandler()},
    })

    return {
        transport = layer,
        machines = built,
        species = registry,
        library = genes,
        queue = queue,
        -- Job steps read tuning from here rather than carrying a copy in every
        -- set of parameters, where an old value would outlive the config
        config = config,
        log = function(text) print("  " .. text) end,
    }, problems
end

--- Print what the world looks like right now
--- @param context table
function hivemind.status(context)
    print("=== ETAT ===")

    local online, reason = context.transport:isOnline()

    if online then
        local items = context.transport:networkItemCount()
        print("Reseau ME    : en ligne, " .. items .. " type(s) d'item visible(s)")

        if items == 0 then
            -- A powered network showing nothing usually means the interface is
            -- on a subnetwork with no storage on it
            print("  ATTENTION: aucun item visible. L'interface est-elle sur le")
            print("  bon reseau, avec des cellules de stockage ?")
        end
    else
        print("Reseau ME    : HORS LIGNE - " .. tostring(reason))
    end

    local mutatron = context.machines.mutatron
    if mutatron then
        local amount, capacity = mutatron:tank()
        local status, detail = mutatron:isReady()
        print(string.format("Mutatron     : %s, mutagene %d/%d",
            detail or status, amount, capacity))
    else
        print("Mutatron     : absent")
    end

    local apiary = context.machines.breeding_apiary
    if apiary then
        local status, detail = apiary:isReady()
        print("Apiary       : " .. (detail or status))

        if apiary:isAutomated() then
            -- waitForPrincess is documented to fail with this upgrade present
            print("  ATTENTION: upgrade Automation detectee, retire-la de cet apiary")
        end

        local bees = apiary:bees()
        for role, bee in pairs(bees) do
            local uid = bee.genome and genome.species(bee.genome) or "?"
            print(string.format("  %s: %s (%s)", role, bee.label or "?", uid))
        end

        local _, flower = apiary:flowerRequirement()
        if flower then
            print("  fleur requise par l'abeille chargee : " .. flower)
        end

        local blocking = apiary:environmentErrors()
        if #blocking > 0 then
            print("  environnement: " .. table.concat(blocking, ", "))
        end
    else
        print("Apiary       : absent")
    end

    local known, source = context.species:list()
    local count = 0
    for _ in pairs(known) do count = count + 1 end
    print(string.format("Especes      : %d connues (%s)", count, source))

    for _, line in ipairs(context.library:describe()) do
        print("  " .. line)
    end

    local pending = context.queue:pending()
    print("Taches       : " .. #pending .. " en attente")
    for _, line in ipairs(context.queue:describe()) do print("  " .. line) end
end

--- Ask the game for the full species list and cache it
--- @param context table
function hivemind.refreshSpecies(context)
    print("Interrogation du jeu...")

    local count, err = context.species:refresh()
    if not count then
        print("Echec: " .. tostring(err))
        print("(l'apiary doit avoir un Adapter et le mod Apiarist Terminal)")
        return
    end

    context.species:save()
    print(count .. " especes apprises et mises en cache.")
end

--- Show a numbered list and read a choice
--- Long lists are paged rather than truncated: a species hidden past the cutoff
--- is a species the player cannot ask for.
--- @param entries table[] Items to choose from
--- @param render function Turns an entry into a line
--- @param prompt string
--- @return table|nil chosen
local function pick(entries, render, prompt)
    local PAGE = 12
    local page = 1
    local pages = math.max(1, math.ceil(#entries / PAGE))

    while true do
        local first = (page - 1) * PAGE + 1
        local last = math.min(page * PAGE, #entries)

        print("")
        for index = first, last do
            print(string.format("%3d. %s", index, render(entries[index])))
        end

        if pages > 1 then
            print(string.format("     page %d/%d  (s = suivante, p = precedente)", page, pages))
        end

        io.write(prompt .. " (numero, ou vide pour annuler): ")
        local answer = io.read()

        if not answer or answer == "" then return nil end
        answer = answer:gsub("%s+", "")

        if answer == "s" and page < pages then
            page = page + 1
        elseif answer == "p" and page > 1 then
            page = page - 1
        else
            local index = tonumber(answer)
            if index and entries[index] then return entries[index] end
            print("Choix invalide.")
        end
    end
end

--- Let the player choose a bee actually present in the ME network
--- @param context table
--- @param itemName string Registry name to filter on
--- @param role string Shown in the prompt
--- @return table|nil spec {name, label}
local function chooseBee(context, itemName, role)
    local found = context.transport:findAll({name = itemName})

    -- AE2 lists genetically different bees as separate stacks under the same
    -- label, so "Attuned Princess" appeared three times with different counts.
    -- They are merged here: the label is all the transport layer can address.
    local entries, byLabel = {}, {}

    for _, item in ipairs(found) do
        local label = item.label or item.name or "?"
        local existing = byLabel[label]

        if existing then
            existing.size = (existing.size or 0) + (tonumber(item.size) or 0)
            existing.variants = existing.variants + 1
        else
            local merged = {
                name = item.name,
                label = label,
                size = tonumber(item.size) or 0,
                variants = 1,
            }
            byLabel[label] = merged
            table.insert(entries, merged)
        end
    end

    if #entries == 0 then
        print("Aucun item '" .. itemName .. "' visible dans le reseau ME.")
        io.write("Etiquette exacte a la main (vide pour annuler): ")
        local typed = io.read()
        if not typed or typed == "" then return nil end
        return {name = itemName, label = typed}
    end

    local chosen = pick(entries,
        function(entry)
            -- Several variants under one label means bees of the same species
            -- with different genomes; worth knowing, since which one AE2 hands
            -- over is not ours to choose
            local variants = entry.variants > 1
                and ("  (" .. entry.variants .. " genomes)") or ""
            return string.format("%-30s x%-5d%s", entry.label or "?", entry.size or 0, variants)
        end,
        "Choisis la " .. role)

    if not chosen then return nil end

    return {name = chosen.name, label = chosen.label}
end

--- Ask the Mutatron itself what these two parents can produce
--- Authoritative, and free of every guess about names: the parents are loaded
--- and listMutations() answers with the full genome of each result, so the
--- species uid is read rather than inferred. Loading them costs nothing - no
--- mutagen is spent - and the breeding job will find them already in place.
--- @param context table
--- @param princessSpec table
--- @param droneSpec table
--- @return string|nil uid
--- @return boolean handled
local function chooseFromMutatron(context, princessSpec, droneSpec)
    local mutatron = context.machines and context.machines.mutatron
    if not mutatron or not mutatron.mutations then return nil, false end

    local slots = mutatron:slots()

    print("")
    print("Chargement des parents dans le Mutatron pour l'interroger...")

    -- A queen left in the output hides the mutation list
    if mutatron:slot(slots.output) then mutatron:unload(slots.output) end

    local function ensure(spec, slot, role)
        local present = mutatron:slot(slot)
        if present and present.label == spec.label then return true end

        if present then mutatron:unload(slot) end

        local ok, err = mutatron:load(spec, slot, 1)
        if not ok then
            print("  " .. role .. " : " .. tostring(err))
            return false
        end
        return true
    end

    if not ensure(princessSpec, slots.in1, "princesse") then return nil, false end
    if not ensure(droneSpec, slots.in2, "drone") then return nil, false end

    local mutations = mutatron:mutations()

    if #mutations == 0 then
        print("Le Mutatron ne propose aucune mutation avec ces deux parents.")
        print("Choisis un autre couple, ou vise une espece par recherche.")
        return nil, false
    end

    local entries = {}
    for _, mutation in ipairs(mutations) do
        table.insert(entries, {
            uid = mutation.genome and genome.species(mutation.genome) or nil,
            name = mutation.label or mutation.name or "?",
        })
    end

    print("")
    print("Le Mutatron propose :")

    local chosen = pick(entries,
        function(entry) return string.format("%-28s %s", entry.name, entry.uid or "?") end,
        "Espece visee")

    if chosen and chosen.uid then return chosen.uid, true end
    if chosen then
        print("Cette mutation ne rapporte pas d'identifiant d'espece exploitable.")
    end

    return nil, true
end

--- Offer the species those two parents can actually produce
--- Far better than searching 329 entries for one that may not even be reachable
--- from the chosen pair. Needs the reverse index, which is built once and kept.
--- @param context table
--- @param princessLabel string
--- @param droneLabel string
--- @return string|nil uid
--- @return boolean handled True when the question was answered here
local function chooseFromParents(context, princessLabel, droneLabel)
    local registry = context.species

    if not registry.fromBeeLabel then
        print("")
        print("(version ancienne: la proposition par parents est indisponible)")
        return nil, false
    end

    local princess = registry:fromBeeLabel(princessLabel)
    local drone = registry:fromBeeLabel(droneLabel)

    -- Falling back without a word is how a whole feature goes unnoticed
    if not (princess and drone) then
        local missing = not princess and princessLabel or droneLabel

        print("")
        print("Espece introuvable pour '" .. tostring(missing) .. "'.")

        -- The shape of the real names cannot be guessed from outside the game,
        -- so show what the registry actually holds
        if registry.sampleNames then
            print("Le registre contient par exemple :")
            for _, sample in ipairs(registry:sampleNames(5)) do
                print("  " .. sample)
            end
        end

        print("Lance l'option 2 si la liste des especes est vide.")
        return nil, false
    end

    if not registry:hasOffspringIndex() then
        print("")
        print("Le programme peut lister ce que ces deux parents produisent,")
        print("mais doit d'abord interroger le jeu sur les 329 especes.")
        print("C'est long une fois, puis conserve sur disque.")
        io.write("Construire cet index maintenant ? (o/N): ")

        local answer = io.read()
        if not answer or answer:lower():sub(1, 1) ~= "o" then return nil, false end

        print("Construction...")
        local built, err = registry:buildOffspringIndex(function(done, total)
            print("  " .. done .. "/" .. total)
        end)

        if not built then
            print("Echec: " .. tostring(err))
            return nil, false
        end

        registry:save()
        print(built .. " couples de parents indexes.")
    end

    local offspring = registry:offspringOf(princess.uid, drone.uid)

    if #offspring == 0 then
        print("")
        print("Aucune mutation connue entre " .. (princess.name or princess.uid)
            .. " et " .. (drone.name or drone.uid) .. ".")
        print("Tu peux quand meme viser une espece par recherche.")
        return nil, false
    end

    local entries = {}
    local all = registry:list()
    for _, uid in ipairs(offspring) do
        table.insert(entries, all[uid] or {uid = uid, name = uid})
    end
    table.sort(entries, function(a, b) return tostring(a.name) < tostring(b.name) end)

    print("")
    print("Mutations possibles entre " .. (princess.name or "?")
        .. " et " .. (drone.name or "?") .. " :")

    local chosen = pick(entries,
        function(entry) return string.format("%-28s %s", entry.name or "?", entry.uid or "?") end,
        "Espece visee")

    if chosen then return chosen.uid, true end

    return nil, true
end

--- Let the player choose a target species by searching the registry
--- @param context table
--- @return string|nil uid
local function chooseSpecies(context)
    local known = context.species:list()

    local all = {}
    for _, entry in pairs(known) do table.insert(all, entry) end
    table.sort(all, function(a, b) return tostring(a.name) < tostring(b.name) end)

    if #all == 0 then
        print("Aucune espece connue. Lance d'abord l'option 2 pour les charger.")
        io.write("Identifiant a la main (vide pour annuler): ")
        local typed = io.read()
        if typed == "" then return nil end
        return typed
    end

    while true do
        -- Not "empty = all": pressing enter then dumped 329 species across
        -- 28 pages, which is not a list anyone reads.
        io.write("Recherche d'espece (ex: common) - vide pour annuler: ")
        local term = io.read()
        if not term or term == "" then return nil end

        local matching = {}
        do
            local needle = term:lower()
            for _, entry in ipairs(all) do
                if tostring(entry.name):lower():find(needle, 1, true)
                    or tostring(entry.uid):lower():find(needle, 1, true) then
                    table.insert(matching, entry)
                end
            end
        end

        if #matching == 0 then
            print("Aucune espece ne correspond a '" .. term .. "'.")
        else
            local chosen = pick(matching,
                function(entry)
                    return string.format("%-28s %s", entry.name or "?", entry.uid or "?")
                end,
                "Espece visee")

            if chosen then return chosen.uid end
            return nil
        end
    end
end

--- Queue one breeding cycle
--- @param context table
function hivemind.submitBreeding(context)
    local princessSpec = chooseBee(context, "forestry:bee_princess_ge", "princesse")
    if not princessSpec then print("Annule.") return end

    local droneSpec = chooseBee(context, "forestry:bee_drone_ge", "drone")
    if not droneSpec then print("Annule.") return end

    -- The machine is asked first: it answers with genomes, so nothing has to be
    -- guessed from names. The index and the search are fallbacks for when the
    -- Mutatron is unreachable.
    local target, handled = chooseFromMutatron(context, princessSpec, droneSpec)

    if not target and not handled then
        target, handled = chooseFromParents(context, princessSpec.label, droneSpec.label)
    end

    if not target and not handled then
        target = chooseSpecies(context)
    end

    if not target then print("Annule.") return end

    local params, err = breeding.params({
        target = target,
        princess = princessSpec,
        drone = droneSpec,
    })

    if not params then
        print("Parametres invalides: " .. tostring(err))
        return
    end

    print("")
    print("  " .. princessSpec.label .. "  +  " .. droneSpec.label .. "  ->  " .. target)
    io.write("Confirmer ? (o/N): ")

    local answer = io.read()
    if not answer or not (answer:lower():sub(1, 1) == "o" or answer:lower():sub(1, 1) == "y") then
        print("Annule.")
        return
    end

    local id, submit_err = context.queue:submit("breed", params)
    if not id then
        print("Impossible de creer la tache: " .. tostring(submit_err))
        return
    end

    print("Tache #" .. id .. " creee.")
end

--- Dump what the transposer really sees, slot by slot
--- The driver reports slot indices from zero, OpenComputers numbers them from
--- one, and nothing says which side has already adjusted. Rather than guess,
--- this prints the raw inventory next to the driver's map so the offset can be
--- read off the screen.
--- @param context table
function hivemind.slotDiagnostic(context)
    print("=== SLOTS REELS (lecture brute par le transposer) ===")
    print("Decalage actuellement applique : " .. tostring(config.slot_offset))
    print("")

    -- Every enabled machine, not a hardcoded pair: the genetics bench arrived
    -- and its slot map is taken from the Gendustry docs, which is exactly the
    -- kind of assumption this screen exists to check.
    for _, name in ipairs(config.enabledMachines()) do
        local machine = context.machines[name]
        if not machine then
            print(name .. " : absent")
        else
            local link = machine.link
            print(name .. " (face " .. tostring(link.machine) .. ")")

            local slots = machine.slots and machine:slots() or {}
            local labels = {}
            for key, value in pairs(slots) do
                if type(value) == "number" then
                    labels[value] = key
                elseif type(value) == "table" then
                    for _, index in ipairs(value) do labels[index] = key end
                end
            end

            -- Every slot the machine really has, empty ones included. Hiding
            -- them made an empty slot and a slot that does not exist look the
            -- same, which is no use at all when the point is to learn the shape
            -- of a machine nobody has documented for us.
            local size = context.transport:inventorySize(link) or 16
            print("  " .. size .. " slot(s)")

            for raw = 1, size do
                local stack = context.transport:inspect(link, raw)
                -- raw is the transposer index; the driver would call it raw-offset
                local driverIndex = raw - config.slot_offset
                local role = labels[driverIndex]

                print(string.format("  slot %-3d (driver %-3d %-11s) %s",
                    raw, driverIndex, role or "?",
                    stack and (stack.label or stack.name or "?") or "vide"))
            end
            print("")
        end
    end

    print("Lis la ligne d'un item que tu as pose toi-meme : si son role ne")
    print("correspond pas, ajuste config.slot_offset dans lib/config.lua.")

    -- The ME Interface is the one inventory the program cannot see through the
    -- machine links, and it is where staging goes wrong: a dock that keeps the
    -- previous item looks exactly like a delivery that never happened.
    print("")
    print("=== ME INTERFACE (les quais de chargement) ===")

    local link = config.machines.mutatron
    local anything = false

    for slot = 1, 9 do
        local stack = context.transport:inspect(
            {transposer = link.transposer, machine = link.source}, slot)

        local configured = "?"
        local ok, entry = pcall(function()
            return context.transport.me
                and context.transport.me.getInterfaceConfiguration(slot)
        end)

        if ok and type(entry) == "table" then
            configured = entry.label or entry.name or "(configure)"
        elseif ok then
            configured = "(vide)"
        end

        if stack or configured ~= "(vide)" then
            anything = true
            print(string.format("  quai %d : contenu=%-28s configuration=%s",
                slot,
                stack and (stack.label or stack.name or "?") or "vide",
                configured))
        end
    end

    if not anything then
        print("  aucun quai occupe ni configure")
    end

    print("")
    print("Un quai dont le contenu ne correspond pas a sa configuration bloque")
    print("les livraisons. Vide-le a la main dans la ME Interface si besoin.")
end

--- Which species the ME network already holds
--- Built once from the bee labels rather than queried per species: a chain can
--- ask about dozens, and each query is a round trip to the network.
--- @param context table
--- @param registry table
--- @return function available
local function availabilityFrom(context, registry)
    local labels = {}

    for _, itemName in ipairs({"forestry:bee_princess_ge", "forestry:bee_drone_ge"}) do
        for _, item in ipairs(context.transport:findAll({name = itemName})) do
            table.insert(labels, tostring(item.label or ""):lower())
        end
    end

    local all = registry:list()

    return function(uid)
        local entry = all[uid]
        local needle = tostring(entry and entry.name or uid):lower()
        if needle == "" then return false end

        for _, label in ipairs(labels) do
            if label:find(needle, 1, true) then return true end
        end

        return false
    end
end

--- Move everything sitting in the breeding apiary's output slots to the network
--- Full output slots stall a cycle and, worse, hide bees the queue is looking
--- for: a Common Drone parked in slot 8 is invisible to a job that searches the
--- ME network, which then reports it as missing.
--- @param context table
--- @return number collected
function hivemind.harvestApiary(context)
    local apiary = context.machines and context.machines.breeding_apiary

    if not apiary then
        print("Aucun apiary de croisement configure.")
        return 0
    end

    local waiting = apiary:outputs()
    if #waiting == 0 then
        print("La sortie de l'apiary est deja vide.")
        return 0
    end

    print("Recolte de " .. #waiting .. " pile(s) dans la sortie de l'apiary...")

    local collected = 0
    for _, output in ipairs(waiting) do
        -- The driver sometimes reports a stack with no label, and "?" tells the
        -- operator nothing. The transposer sees the same slot and does name it.
        local label = output.label
        if not label then
            local stack = apiary:slot(output.slot)
            label = stack and stack.label or nil
        end

        local moved = apiary:unload(output.slot)
        collected = collected + (tonumber(moved) or 0)
        print(string.format("  %-28s %s",
            tostring(label or "(sans etiquette)"),
            (tonumber(moved) or 0) > 0 and "recolte" or "NON DEPLACE"))
    end

    local left = #apiary:outputs()
    print(collected .. " item(s) envoye(s) au reseau, " .. left .. " pile(s) restante(s).")

    if left > 0 then
        print("Le reseau refuse le reste: verifie la ME Interface et l'espace disque.")
    end

    return collected
end

--- Plan a whole breeding chain and queue it
--- @param context table
function hivemind.planChain(context)
    local registry = context.species

    -- list() answers (species, source). Without the parentheses both are passed
    -- to next(), which then treats "cache" as a table key and refuses.
    local known = registry.list and registry:list() or nil

    if not known or next(known) == nil then
        print("Aucune espece connue. Lance d'abord l'option 2.")
        return
    end

    local target = chooseSpecies(context)
    if not target then print("Annule.") return end

    print("")
    print("Analyse du reseau et de l'arbre de croisement...")

    local available = availabilityFrom(context, registry)

    local plan, err = planner.plan({
        registry = registry,
        available = available,
        target = target,
    })

    if not plan then
        print("Planification impossible: " .. tostring(err))
        return
    end

    local all = registry:list()
    local function naming(uid)
        local entry = all[uid]
        return entry and entry.name or uid
    end

    print("")
    for _, line in ipairs(planner.describe(plan, naming)) do print(line) end

    if plan.held then return end

    if not plan.reachable then
        -- "Absent" can mean three very different things: unknown to the
        -- registry, known but named differently from the item label, or simply
        -- not in the network. Each needs a different fix, so say which.
        print("")
        print("Detail des especes manquantes :")

        local labels = {}
        for _, itemName in ipairs({"forestry:bee_princess_ge", "forestry:bee_drone_ge"}) do
            for _, item in ipairs(context.transport:findAll({name = itemName})) do
                table.insert(labels, tostring(item.label or ""))
            end
        end

        for _, entry in ipairs(plan.missing) do
            local known = all[entry.uid]
            local name = known and known.name or nil

            local matches = {}
            if name then
                local needle = name:lower()
                for _, label in ipairs(labels) do
                    if label:lower():find(needle, 1, true) then
                        table.insert(matches, label)
                    end
                end
            end

            print("  " .. entry.uid)
            print("     nom au registre : " .. (name or "INCONNU DU REGISTRE"))
            print("     dans le reseau  : "
                .. (#matches > 0 and table.concat(matches, ", ") or "rien de correspondant"))
        end

        print("")
        print("Fournis les especes manquantes puis relance cette option.")
        return
    end

    -- Labels of species not bred yet cannot be read from the network, so they
    -- are predicted from the species name. A wrong guess surfaces as a clear
    -- "introuvable dans le reseau" on that step rather than a silent failure.
    print("")
    io.write("Mettre ces " .. #plan.steps .. " croisement(s) en file ? (o/N): ")

    local answer = io.read()
    if not answer or answer:lower():sub(1, 1) ~= "o" then
        print("Annule.")
        return
    end

    local queued = 0

    for _, step in ipairs(plan.steps) do
        local params, params_err = breeding.params({
            target = step.target,
            princess = {name = "forestry:bee_princess_ge",
                        label = naming(step.princess.uid) .. " Princess"},
            drone = {name = "forestry:bee_drone_ge",
                     label = naming(step.drone.uid) .. " Drone"},
        })

        if not params then
            print("Etape ignoree (" .. naming(step.target) .. "): " .. tostring(params_err))
        else
            local id, submit_err = context.queue:submit("breed", params)
            if id then
                queued = queued + 1
            else
                print("Etape ignoree (" .. naming(step.target) .. "): " .. tostring(submit_err))
            end
        end
    end

    print(queued .. " tache(s) creee(s). Lance l'option 4 pour les executer.")
end

--- Cancel a job or clear out the finished ones
--- A job whose target turned out to be impossible sits in the queue blocking
--- everything behind it, and there was no way to get rid of it.
--- @param context table
function hivemind.manageQueue(context)
    local all = context.queue:list()

    if #all == 0 then
        print("La file est vide.")
        return
    end

    print("")
    for _, line in ipairs(context.queue:describe()) do print("  " .. line) end

    print("")
    print("  a = annuler une tache")
    print("  p = purger les taches terminees et annulees")
    print("  vide = retour")
    io.write("Choix: ")

    local answer = io.read()
    if not answer then return end
    answer = answer:gsub("%s+", ""):lower()

    if answer == "p" then
        print(context.queue:prune() .. " tache(s) purgee(s).")
        return
    end

    if answer ~= "a" then return end

    io.write("Numero de la tache a annuler: ")
    local id = tonumber(io.read())

    if not id then
        print("Annule.")
        return
    end

    local ok, err = context.queue:cancel(id)
    if ok then
        print("Tache #" .. id .. " annulee.")
    else
        print("Impossible: " .. tostring(err))
    end
end

--- Run the queue until it stops making progress
--- @param context table
function hivemind.runQueue(context, options)
    options = options or {}
    local pending = #context.queue:pending()
    if pending == 0 then
        print("Aucune tache en attente.")
        return
    end

    print("Execution de " .. pending .. " tache(s)...")

    local report = context.queue:run(context, {
        budget = options.budget,
        onProgress = function(job, outcome, detail)
            print(string.format("  #%d %s etape %d : %s%s",
                job.id, job.kind, job.step, outcome,
                detail and ("  " .. detail) or ""))
        end,
    })

    print(string.format("%d etape(s), %d terminee(s), %d attente(s), %d echec(s)",
        report.steps, report.completed, report.retried, report.failed))

    if report.exhausted then
        print("Temps imparti ecoule: la file reprend ou elle s'est arretee.")
    elseif report.blocked then
        print("La file est bloquee: corrige la cause puis relance.")
    end
end

--- Queue a drone accumulation campaign
--- A cross spends a drone, and the network was holding sixteen princess species
--- against two drone species: everything could be planned and almost nothing
--- executed. This puts a princess and a drone of one species in the apiary and
--- keeps recycling the princess until the stock is deep enough.
--- @param context table
function hivemind.accumulateDrones(context)
    print("")
    print("=== ACCUMULER DES DRONES ===")
    print("Une princesse et un drone de la meme espece deviennent une reine.")
    print("La reine meurt en laissant une princesse et plusieurs drones, et la")
    print("princesse repart aussitot. Un drone entre, plusieurs sortent.")
    print("")

    local princessSpec = chooseBee(context, "forestry:bee_princess_ge", "princesse")
    if not princessSpec then print("Annule.") return end

    -- "Water Princess" is what the network calls it; the job wants "Water"
    local species = princessSpec.label:gsub("%s+Princess$", "")
    local droneSpec = {name = "forestry:bee_drone_ge", label = species .. " Drone"}

    -- One drone has to exist to start the line. Saying so now beats a job that
    -- retries forever with "introuvable dans le reseau".
    local held = 0
    for _, item in ipairs(context.transport:findAll(droneSpec) or {}) do
        held = held + (tonumber(item.size) or 0)
    end

    print("")
    print("Espece : " .. species)
    print("En stock : " .. held .. " " .. droneSpec.label)

    if held == 0 then
        print("")
        print("Il faut au moins UN " .. droneSpec.label .. " pour amorcer.")
        print("Sans lui, aucune reine ne peut se former. Recupere-le par un")
        print("croisement, une ruche sauvage, ou vide la sortie de l'apiary")
        print("(option 7) s'il s'y trouve deja.")
        return
    end

    print("")
    print("2 ou 3 suffisent pour une espece de passage: un croisement depense")
    print("un seul drone. Vise ~16 pour une espece dont tu voudras le gene:")
    print("le Sampler detruit un drone par echantillon et tire au hasard.")
    io.write("Objectif (nombre de drones a atteindre) [32]: ")
    local answer = io.read()
    local target = tonumber(answer and answer:gsub("%s+", "")) or 32

    local params, err = multiply.params({
        species = species,
        princess = princessSpec,
        drone = droneSpec,
        target = target,
    })

    if not params then
        print("Parametres invalides: " .. tostring(err))
        return
    end

    print("")
    print("  " .. species .. " : " .. held .. " -> " .. target .. " drones")
    print("  au plus " .. params.maxCycles .. " cycles d'apiary")
    io.write("Confirmer ? (o/N): ")

    answer = io.read()
    if not answer or not (answer:lower():sub(1, 1) == "o"
                       or answer:lower():sub(1, 1) == "y") then
        print("Annule.")
        return
    end

    local id, submit_err = context.queue:submit("multiply", params)
    if not id then
        print("Impossible de creer la tache: " .. tostring(submit_err))
        return
    end

    print("Tache #" .. id .. " creee. Lance l'option 6 pour la faire tourner.")
end

--- Queue one gene extraction
--- The Sampler destroys the bee and draws one chromosome out of thirteen, so
--- this is a lottery ticket, not an order. Saying so before the confirmation
--- is the difference between a tool and a trap.
--- @param context table
function hivemind.sampleGene(context)
    print("")
    print("=== EXTRAIRE UN GENE ===")
    print("Le Sampler detruit l'abeille et tire UN chromosome au hasard sur 13.")
    print("Viser un gene precis coute donc une treizaine d'abeilles en moyenne,")
    print("mais les tirages 'rates' remplissent quand meme la bibliotheque.")
    print("")

    local beeSpec = chooseBee(context, "forestry:bee_drone_ge", "drone")
    if not beeSpec then print("Annule.") return end

    local blanks = 0
    for _, item in ipairs(context.transport:findAll(
            {name = "gendustry:gene_sample_blank"}) or {}) do
        blanks = blanks + (tonumber(item.size) or 0)
    end

    print("")
    print("  " .. beeSpec.label .. " -> un gene au hasard")
    print("  samples vierges en stock : " .. blanks)

    if blanks == 0 then
        print("")
        print("Sans Blank Gene Sample, le Sampler ne peut rien produire.")
        print("Mets-en en autocraft AE2: il en faut des centaines.")
        return
    end

    io.write("Confirmer ? (o/N): ")
    local answer = io.read()
    if not answer or not (answer:lower():sub(1, 1) == "o"
                       or answer:lower():sub(1, 1) == "y") then
        print("Annule.")
        return
    end

    local params, err = genetics.sampleParams({bee = beeSpec})
    if not params then
        print("Parametres invalides: " .. tostring(err))
        return
    end

    local id, submit_err = context.queue:submit("sample", params)
    if not id then
        print("Impossible de creer la tache: " .. tostring(submit_err))
        return
    end

    print("Tache #" .. id .. " creee. Lance l'option 6 pour la faire tourner.")
end

--- Queue a copy of a gene sample
--- A gene held in one sample is one misplaced click from being gone. The source
--- survives the copy, so this only ever adds.
--- @param context table
function hivemind.duplicateGene(context)
    print("")
    print("=== DUPLIQUER UN GENE ===")
    print("Le Genetic Transposer lit un sample et ecrit une copie dans un")
    print("sample vierge. La source n'est pas consommee.")
    print("")

    local samples = context.transport:findAll({name = "gendustry:gene_sample"})

    if #samples == 0 then
        print("Aucun gene en stock. Utilise d'abord l'option 'a'.")
        return
    end

    -- Merged by label: AE2 splits a stack across cells and showing the same
    -- gene four times would only make the list harder to read
    local merged, order = {}, {}
    for _, item in ipairs(samples) do
        local label = tostring(item.label or "?")
        if not merged[label] then
            merged[label] = 0
            table.insert(order, label)
        end
        merged[label] = merged[label] + (tonumber(item.size) or 0)
    end
    table.sort(order)

    print("")
    for index, label in ipairs(order) do
        print(string.format("%3d. %-44s x%d", index, label, merged[label]))
    end

    print("")
    io.write("Choisis le gene (numero, ou vide pour annuler): ")
    local answer = io.read()
    local choice = tonumber(answer and answer:gsub("%s+", ""))

    if not choice or not order[choice] then print("Annule.") return end

    local params, err = genetics.duplicateParams({sample = {label = order[choice]}})
    if not params then
        print("Parametres invalides: " .. tostring(err))
        return
    end

    local id, submit_err = context.queue:submit("duplicate", params)
    if not id then
        print("Impossible de creer la tache: " .. tostring(submit_err))
        return
    end

    print("Tache #" .. id .. " creee. Lance l'option 6 pour la faire tourner.")
end

--- What the operator should probably do next
--- The menu used to be nine equal choices with no hint which one mattered. Most
--- of the time the world has already decided: a full apiary output blocks
--- everything, a job stalled on a missing drone will never resolve on its own.
--- @param context table
--- @return string[] lines
function hivemind.advice(context)
    local lines = {}

    -- Cheap reads only: a transposer glance and the queue already in memory.
    -- The menu redraws after every action and must not cost a network sweep.
    local apiary = context.machines and context.machines.breeding_apiary
    if apiary then
        local waiting = apiary:outputs()
        if #waiting > 0 then
            table.insert(lines, "La sortie de l'apiary contient " .. #waiting
                .. " pile(s). Choisis 7 : tant qu'elles y sont, les taches ne")
            table.insert(lines, "les voient pas et les reclament comme manquantes.")
        end
    end

    local pending = context.queue:pending()
    local suggested = {}

    for _, job in ipairs(pending) do
        -- "drone indisponible: introuvable dans le reseau: Water Drone"
        local missing = job.error and job.error:match("introuvable dans le reseau:%s*(.+)$")
        if missing then
            local shortSpecies = missing:gsub("%s+Drone$", ""):gsub("%s+Princess$", "")
            if not suggested[shortSpecies] then
                suggested[shortSpecies] = true
                if missing:find("Drone") then
                    table.insert(lines, "La tache #" .. job.id .. " attend un "
                        .. missing .. " que personne ne produit.")
                    table.insert(lines, "Choisis 3 pour en accumuler, ou 8 pour"
                        .. " annuler la tache.")
                else
                    table.insert(lines, "La tache #" .. job.id .. " attend un "
                        .. missing .. ", absent du reseau.")
                end
            end
        end
    end

    if #lines == 0 then
        if #pending == 0 then
            table.insert(lines, "Rien en file. Choisis 5 pour viser une espece,"
                .. " ou 3 pour constituer un stock de drones.")
        else
            table.insert(lines, #pending .. " tache(s) prete(s). Choisis 6 pour"
                .. " les faire tourner.")
        end
    end

    return lines
end

--- One-line summary of the things that stop work
--- @param context table
local function headline(context)
    local online = context.transport:isOnline()
    local parts = {online and "Reseau ME en ligne" or "Reseau ME HORS LIGNE"}

    local mutatron = context.machines and context.machines.mutatron
    if mutatron then
        local status = mutatron:isReady()
        table.insert(parts, "Mutatron " .. tostring(status))
    end

    local apiary = context.machines and context.machines.breeding_apiary
    if apiary then
        local status = apiary:isReady()
        local waiting = #apiary:outputs()
        table.insert(parts, "Apiary " .. tostring(status)
            .. (waiting > 0 and (" (" .. waiting .. " en sortie)") or ""))
    end

    local pending = context.queue:pending()
    local blocked = 0
    for _, job in ipairs(pending) do
        if job.error then blocked = blocked + 1 end
    end

    table.insert(parts, #pending .. " tache(s)"
        .. (blocked > 0 and (", " .. blocked .. " bloquee(s)") or ""))

    print(table.concat(parts, "  |  "))
end

local ENTRIES = {
    {group = "Regarder"},
    {key = "1", label = "Etat detaille",
     hint = "stocks, machines, genes, file", action = "status"},
    {key = "2", label = "Diagnostic des slots",
     hint = "ce que chaque machine tient vraiment", action = "slotDiagnostic"},

    {group = "Produire"},
    {key = "3", label = "Accumuler des drones",
     hint = "une espece, en boucle, jusqu a un objectif", action = "accumulateDrones"},
    {key = "4", label = "Programmer un croisement",
     hint = "un seul croisement A + B -> C", action = "submitBreeding"},
    {key = "5", label = "Viser une espece",
     hint = "chaine complete calculee toute seule", action = "planChain"},
    {key = "a", label = "Extraire un gene",
     hint = "une abeille -> un chromosome au hasard", action = "sampleGene"},
    {key = "b", label = "Dupliquer un gene",
     hint = "une copie de plus, la source survit", action = "duplicateGene"},

    {group = "Faire tourner"},
    {key = "6", label = "Executer la file",
     hint = "avance toutes les taches en attente", action = "runQueue"},
    {key = "7", label = "Vider la sortie de l apiary",
     hint = "renvoie les abeilles vers le reseau", action = "harvestApiary"},

    {group = "Entretenir"},
    {key = "8", label = "Gerer la file",
     hint = "annuler une tache, purger les finies", action = "manageQueue"},
    {key = "9", label = "Rafraichir les especes",
     hint = "relit la liste complete depuis le jeu", action = "refreshSpecies"},
}

local function menu(context)
    while true do
        print("")
        print("=== HiveMind " .. hivemind.VERSION .. " ===")

        -- Reading the world before drawing the menu costs one transposer call
        -- and answers the question the menu cannot: which option matters now.
        local ok = pcall(headline, context)
        if not ok then print("(etat illisible)") end

        local advised = {}
        pcall(function() advised = hivemind.advice(context) end)

        if #advised > 0 then
            print("")
            for index, line in ipairs(advised) do
                print((index == 1 and "  -> " or "     ") .. line)
            end
        end

        for _, entry in ipairs(ENTRIES) do
            if entry.group then
                print("")
                print("  " .. entry.group)
            else
                print(string.format("    %s  %-28s %s",
                    entry.key, entry.label, entry.hint))
            end
        end

        print("")
        print("    0  Quitter")
        io.write("Choix: ")

        local choice = io.read()
        if not choice then return end

        choice = choice:gsub("%s+", ""):lower()

        if choice == "0" or choice == "q" then
            print("Au revoir.")
            return
        end

        local matched = nil
        for _, entry in ipairs(ENTRIES) do
            if entry.key == choice then matched = entry break end
        end

        if matched then
            hivemind[matched.action](context)
        else
            print("Choix invalide: tape un chiffre de 0 a 9.")
        end
    end
end

function hivemind.main()
    print("HiveMind v" .. hivemind.VERSION .. " - demarrage")
    print("")

    local context, problems = hivemind.bootstrap()

    if #problems > 0 then
        print("PROBLEMES DETECTES:")
        for _, problem in ipairs(problems) do print("  - " .. problem) end
        print("")
        print("Le programme demarre quand meme, mais les taches concernees echoueront.")
        print("")
    end

    -- Anything left running by a crash is picked up here; its steps re-verify
    -- against the world before acting, so nothing is repeated.
    local interrupted = context.queue:pending()
    if #interrupted > 0 then
        print(#interrupted .. " tache(s) interrompue(s) reprise(s) au demarrage.")
    end

    hivemind.status(context)
    menu(context)
end

if not MODULE_NAME then
    hivemind.main()
end

return hivemind
