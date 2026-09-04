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
local screen = need("lib.screen")

local hivemind = {}

-- Printed at startup so "am I running the version we just fixed?" is answerable
-- without counting bytes. raw.githubusercontent.com serves through a CDN that
-- can hand out the previous file for a few minutes after a push, which has
-- already cost one round of confusion.
hivemind.VERSION = "0.77.0"

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

    -- Templates share one item id and one label and differ only by NBT, so AE2
    -- cannot tell two of them apart and a template that enters the network is
    -- lost among its kind. They can therefore only ever move between a chest
    -- and a machine on the SAME transposer -- anything else would have to route
    -- through the network. Saying so now beats discovering it mid-imprint.
    local imprinter = config.machines.imprinter
    if imprinter and imprinter.enabled ~= false
       and config.template_chest.transposer ~= imprinter.transposer then
        table.insert(problems,
            "le coffre a templates est sur le transposer "
            .. tostring(config.template_chest.transposer)
            .. " et l'imprinter sur " .. tostring(imprinter.transposer)
            .. " : un template ne peut pas passer de l'un a l'autre sans")
        table.insert(problems,
            "  traverser le reseau ME, ou il devient indiscernable. Deplace le")
        table.insert(problems,
            "  coffre contre le transposer des machines de genetique.")
    end

    -- A module older than this file has none of the newer factories, and
    -- calling one produced a stack trace naming machine.lua -- which tells the
    -- reader nothing about the actual fix, "run hminstall again". Missing work
    -- is a startup problem to report, not a crash.
    local handlers = {}

    local function register(kind, module, factoryName, moduleName)
        local factory = module and module[factoryName]

        if type(factory) ~= "function" then
            table.insert(problems, "tache '" .. kind .. "' indisponible: "
                .. moduleName .. " est plus ancien que le programme."
                .. " Relance hminstall.")
            return
        end

        local ok, handler = pcall(factory)
        if not ok or type(handler) ~= "table" then
            table.insert(problems, "tache '" .. kind .. "' illisible dans "
                .. moduleName .. ": " .. tostring(handler))
            return
        end

        handlers[kind] = handler
    end

    register("breed",     breeding, "handler",          "lib/breeding.lua")
    register("multiply",  multiply, "handler",          "lib/multiply.lua")
    register("sample",    genetics, "sampleHandler",    "lib/genetics.lua")
    register("duplicate", genetics, "duplicateHandler", "lib/genetics.lua")
    register("campaign",  genetics, "campaignHandler",  "lib/genetics.lua")
    register("imprint",   genetics, "imprintHandler",   "lib/genetics.lua")
register("replicate", genetics, "replicateHandler", "lib/genetics.lua")
register("extract",   genetics, "extractHandler",   "lib/genetics.lua")

    local queue = jobs.new({
        path = stateDirectory .. "/jobs.lua",
        handlers = handlers,
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
--- Which roles of a species the network actually holds
--- A cross needs a princess of one species and a DRONE of the other. Treating
--- "we have some Water bees" as "we can cross with Water" is what left a plan
--- stuck on "Water Drone introuvable" with three Water princesses in store.
--- @param context table
--- @param registry table
--- @return function(uid) -> table {princess, drone}
local function rolesFrom(context, registry)
    local byRole = {princess = {}, drone = {}}

    for role, itemName in pairs({princess = "forestry:bee_princess_ge",
                                 drone = "forestry:bee_drone_ge"}) do
        for _, item in ipairs(context.transport:findAll({name = itemName}) or {}) do
            table.insert(byRole[role], tostring(item.label or ""):lower())
        end
    end

    local all = registry:list()

    return function(uid)
        local entry = all[uid]
        local needle = tostring(entry and entry.name or uid):lower()
        if needle == "" then return {princess = false, drone = false} end

        local held = {}
        for role, labels in pairs(byRole) do
            held[role] = false
            for _, label in ipairs(labels) do
                if label:find(needle, 1, true) then held[role] = true break end
            end
        end

        return held
    end
end

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

    local queued, accumulations = 0, 0
    local roles = rolesFrom(context, registry)
    local scheduled = {}

    for _, step in ipairs(plan.steps) do
        -- The drone parent is the one that runs out. A species we hold only as
        -- princesses cannot be crossed at all, and the plan called it available
        -- because it looked only at "do we have this species".
        --
        -- Later steps are fine: a cross ends by returning its princess and its
        -- drones to the network, so a species this plan breeds will have both.
        local droneUid = step.drone.uid
        local held = roles(droneUid)

        if held.princess and not held.drone and not scheduled[droneUid] then
            scheduled[droneUid] = true

            local species = naming(droneUid)
            local params = multiply.params({
                species = species,
                target = (config.breeding.spare_drones or 1) + 1,
            })

            if params then
                local id = context.queue:submit("multiply", params)
                if id then
                    accumulations = accumulations + 1
                    print("  accumulation programmee pour " .. species
                        .. " (princesse en stock, aucun drone)")
                end
            end
        end

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

    if accumulations > 0 then
        print(accumulations .. " accumulation(s) de drones ajoutee(s) avant les croisements.")
    end

    print(queued .. " croisement(s) en file. Choisis 6 pour les executer.")
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

--- Queue the imprinting of a bee with the template already in the machine
--- This is what turns the library into a tool: the bee comes out carrying the
--- template's genes instead of its own.
--- @param context table
function hivemind.imprintBee(context)
    print("")
    print("=== IMPRIMER UNE ABEILLE ===")
    print("L imprinter ecrase les genes de l abeille par ceux du template.")
    print("")

    local imprinter = context.machines and context.machines.imprinter
    if not imprinter then
        print("Imprinter absent de la configuration.")
        return
    end

    -- The template is placed by hand and stays: a filled one and an empty one
    -- are indistinguishable in AE2, so the program must never pick one itself
    local template = imprinter:slot(imprinter.link.slots.template)

    if not template then
        print("Aucun template dans l imprinter.")
        print("")
        print("Fabrique-le a la table de craft (option e), puis pose-le a la")
        print("main dans le slot " .. imprinter:resolveSlot(imprinter.link.slots.template)
            .. " de l imprinter. Le programme ne peut pas le choisir")
        print("lui-meme: un template rempli et un vide portent le meme nom.")
        return
    end

    print("Template en place : " .. tostring(template.label))
    print("")

    local beeSpec = chooseBee(context, "forestry:bee_drone_ge", "drone")
    if not beeSpec then print("Annule.") return end

    print("")
    print("  " .. beeSpec.label .. " recevra les genes du template")
    io.write("Confirmer ? (o/N): ")

    local answer = io.read()
    if not answer or not (answer:lower():sub(1, 1) == "o"
                       or answer:lower():sub(1, 1) == "y") then
        print("Annule.")
        return
    end

    local params, err = genetics.imprintParams({bee = beeSpec})
    if not params then
        print("Parametres invalides: " .. tostring(err))
        return
    end

    local id, submit_err = context.queue:submit("imprint", params)
    if not id then
        print("Impossible de creer la tache: " .. tostring(submit_err))
        return
    end

    print("Tache #" .. id .. " creee. Choisis 6 pour la faire tourner.")
end

--- Read every chromosome of one bee, instead of guessing at thirteen of them
--- Sampling is a lottery: thirteen bees on average to see one chosen gene, and
--- a species whose drones all share a genome can never yield anything but the
--- same thirteen alleles however many are spent. Reading the genome first turns
--- "is Fertility 4 in there?" from thirteen destroyed bees into one look.
---
--- The apiary is the only machine that hands back a genome. A drone alone in
--- the drone slot starts nothing: Forestry needs a princess for that.
--- @param context table
function hivemind.analyseBee(context)
    print("")
    print("=== LIRE LE GENOME D UNE ABEILLE ===")
    print("Aucune abeille n est detruite. En revanche l apiary ne rend pas")
    print("toujours son slot drone: si elle y reste, retire-la a la main ou")
    print("laisse le prochain cycle la consommer.")
    print("")

    local apiary = context.machines and context.machines.breeding_apiary
    if not apiary then
        print("Apiary absent de la configuration.")
        return
    end

    local slots = apiary:slots()

    -- A princess in the queen slot plus this drone would start a cycle, and the
    -- bee would be consumed instead of read
    if apiary:slot(slots.queen) then
        print("Une abeille occupe le slot reine de l apiary.")
        print("Vide-le d abord (option 7, ou a la main) sinon un cycle demarre.")
        return
    end

    local occupant = apiary:slot(slots.drone)
    local beeSpec

    if occupant then
        -- The apiary keeps its drone, so a previous read leaves one behind.
        -- Reading it costs nothing; replacing it costs a bee and usually fails.
        print("Le slot drone contient " .. tostring(occupant.label) .. ".")
        io.write("La lire elle ? (O/n, n = en poser une autre): ")

        local answer = io.read()
        local reuse = not answer or answer == ""
            or answer:lower():sub(1, 1) == "o" or answer:lower():sub(1, 1) == "y"

        if reuse then
            beeSpec = {name = occupant.name, label = occupant.label}
        else
            apiary:unload(slots.drone)

            if apiary:slot(slots.drone) then
                print("L apiary ne la rend pas. Sors-la a la main puis reessaie.")
                return
            end
        end
    end

    if not beeSpec then
        beeSpec = chooseBee(context, "forestry:bee_drone_ge", "drone")
        if not beeSpec then print("Annule.") return end

        local ok, reason = apiary:load(beeSpec, slots.drone, 1)
        if not ok then
            print("Impossible de poser l abeille: " .. tostring(reason))
            return
        end
    end

    local bee = apiary:bees().drone
    local parsed = bee and bee.genome

    if not parsed then
        print("Genome illisible. L abeille reste dans l apiary.")
        apiary:unload(slots.drone)
        return
    end

    -- Written down at once. AE2 hides NBT, so this genome can only be learned
    -- by parking the bee here; read once, known forever.
    local species = beeSpec.label:gsub("%s+Drone$", "")
    local recorded = context.library:recordGenome(species, parsed)

    print("")
    print(beeSpec.label .. " :")
    print("")

    -- Both alleles matter: a recessive one is invisible in the bee but passes
    -- to its offspring, and the Sampler can draw either
    for slot = 0, 12 do
        local active, inactive = genome.alleles(parsed, slot)

        if active then
            local name = genome.labelForSlot(slot) or tostring(slot)
            local pretty = tostring(active):match("([^.]+)$") or active

            if inactive and inactive ~= active then
                local other = tostring(inactive):match("([^.]+)$") or inactive
                print(string.format("  %-22s %-18s (recessif: %s)",
                    name, pretty, other))
            else
                print(string.format("  %-22s %s", name, pretty))
            end
        end
    end

    -- The whole point: which of these are worth spending bees on
    --- Does a raw allele uid correspond to a profile's display name
    --- The genome gives uids like "forestry.floweringSlowest" while a profile
    --- names alleles as their sample labels do, "Slow". A substring test made
    --- Slowest answer for Slow, which is the opposite value.
    --- @param uid string|nil
    --- @param allele string
    --- @return boolean
    local function corresponds(uid, allele)
        if not uid then return false end

        local function flatten(text)
            return tostring(text):lower():gsub("[^%w]", "")
        end

        local flat, target = flatten(uid), flatten(allele)
        if target == "" then return false end

        return flat:sub(-#target) == target
    end

    local wanted, uncertain = {}, false

    for name, profile in pairs(config.profiles or {}) do
        for slot, allele in pairs(profile) do
            local active, inactive = genome.alleles(parsed, slot)

            if corresponds(active, allele) or corresponds(inactive, allele) then
                if not context.library:has(slot, allele) then
                    table.insert(wanted, string.format("  %-22s %-12s (profil %s)",
                        tostring(genome.labelForSlot(slot) or slot), allele, name))
                end
            elseif active and not context.library:has(slot, allele) then
                -- Not every chromosome names its uid after its label: Fertility
                -- shows "2" on a sample and something else entirely in the
                -- genome. Saying so beats a confident wrong answer.
                uncertain = true
            end
        end
    end

    print("")
    if #wanted > 0 then
        print("Cette abeille porte des genes que tes profils veulent et que la")
        print("bibliotheque n a pas :")
        for _, line in ipairs(wanted) do print(line) end
        print("")
        print("Une campagne sur cette espece vaut donc le coup.")
    else
        print("Rien de sur ici que tes profils veuillent et que tu n aies pas.")
    end

    if uncertain then
        print("")
        print("Certains chromosomes ne nomment pas leur allele comme l etiquette")
        print("d un sample: compare la liste ci-dessus avec ce que veut le profil")
        print("(option e) avant de conclure.")
    end

    if recorded > 0 then
        print("")
        print(recorded .. " chromosome(s) memorises pour " .. species .. ".")
        print("L option h s en servira sans avoir a relire cette abeille.")
    end

    apiary:unload(slots.drone)

    if apiary:slot(slots.drone) then
        print("")
        print("L abeille reste dans l apiary: il ne rend pas ce slot.")
        print("La prochaine lecture pourra la relire sans en depenser une autre.")
    end
end

--- Queue a Species hunt for every species the network holds and the library lacks
--- A Species gene is what lets the Replicator make a bee from nothing and what
--- a per-species template is built on. Collecting them one menu choice at a
--- time is fine for two species and hopeless for twenty.
---
--- One species costs about thirteen drones on average -- the Sampler draws one
--- chromosome in thirteen -- so the total is stated before anything is queued.
--- @param context table
function hivemind.speciesSweep(context)
    print("")
    print("=== RECOLTER LE GENE SPECIES DE CHAQUE ESPECE ===")
    print("Le Sampler tire un chromosome sur 13: compte une treizaine de")
    print("drones par espece. Les tirages rates enrichissent la bibliotheque.")
    print("")

    -- The pack ships a shortcut this program cannot use: a shapeless craft that
    -- returns the Species sample of any drone, every time. Thirteen drones
    -- against one is worth saying out loud before spending the thirteen.
    print("RACCOURCI: le Perfected Imbuement Fabrial (table de craft) rend")
    print("le gene Species d un drone a coup sur, en un seul drone.")
    print("Cette file reste utile pour les 12 autres chromosomes.")
    print("")

    context.library:scan()
    local held = context.library:speciesGenes()

    -- Only species we actually hold drones of: a campaign needs bees to spend
    local stock = {}
    for _, item in ipairs(context.transport:findAll(
            {name = "forestry:bee_drone_ge"}) or {}) do
        local label = tostring(item.label or "")
        local species = label:gsub("%s+Drone$", "")

        if species ~= "" and species ~= label then
            stock[species] = (stock[species] or 0) + (tonumber(item.size) or 0)
        end
    end

    -- Anything already queued must not be queued twice: running this command
    -- again would spend a second batch of drones for genes already coming
    local queued = {}
    for _, job in ipairs(context.queue:list()) do
        if job.kind == "campaign" and job.status ~= "complete"
           and job.status ~= "cancelled" and job.params and job.params.bee then
            queued[job.params.bee.label] = true
        end
    end

    local plan, covered, short = {}, {}, {}
    local names = {}
    for species in pairs(stock) do table.insert(names, species) end
    table.sort(names)

    for _, species in ipairs(names) do
        local count = stock[species]

        if held[species] then
            table.insert(covered, species)
        elseif queued[species .. " Drone"] then
            table.insert(covered, species .. " (deja en file)")
        elseif count < 2 then
            -- One drone is a coin flip at best, and losing the last of a
            -- species to a failed draw is worse than not trying
            table.insert(short, string.format("%s (%d drone)", species, count))
        else
            table.insert(plan, {species = species, stock = count})
        end
    end

    if #covered > 0 then
        print("Deja acquis ou en file : " .. table.concat(covered, ", "))
        print("")
    end

    if #short > 0 then
        print("Trop peu de drones pour tenter : " .. table.concat(short, ", "))
        print("Accumule-les d abord (option 3).")
        print("")
    end

    if #plan == 0 then
        print("Rien a lancer.")
        return
    end

    local budget = 13
    print("A lancer :")
    for _, entry in ipairs(plan) do
        local spend = math.min(budget, entry.stock)
        print(string.format("  %-16s %d drone(s) en stock, budget %d",
            entry.species, entry.stock, spend))
    end

    local labware = 0
    for _, item in ipairs(context.transport:findAll(
            {name = "gendustry:labware"}) or {}) do
        labware = labware + (tonumber(item.size) or 0)
    end

    local worst = 0
    for _, entry in ipairs(plan) do worst = worst + math.min(budget, entry.stock) end

    print("")
    print("  " .. #plan .. " campagne(s), au pire " .. worst .. " abeille(s)")
    print("  labware en stock : " .. labware)

    if labware < worst then
        print("  ATTENTION: pas assez de labware, la file s arretera en route.")
    end

    io.write("Confirmer ? (o/N): ")
    local answer = io.read()
    if not answer or not (answer:lower():sub(1, 1) == "o"
                       or answer:lower():sub(1, 1) == "y") then
        print("Annule.")
        return
    end

    local created = 0
    for _, entry in ipairs(plan) do
        local params = genetics.campaignParams({
            bee = {label = entry.species .. " Drone"},
            chromosome = "Species",
            allele = entry.species,
            bees = math.min(budget, entry.stock),
        })

        if params then
            local id = context.queue:submit("campaign", params)
            if id then created = created + 1 end
        end
    end

    print(created .. " campagne(s) en file. Choisis 6 pour les faire tourner.")
end

--- Explain what to do about a machine that is not wired up yet
--- Four machines are declared but disabled, because nothing was built when they
--- were written. "machine indisponible" is a true answer and a useless one.
--- @param name string Key in config.machines
--- @param humanName string
--- @return boolean available
local function machineReady(context, name, humanName)
    if context.machines and context.machines[name] then return true end

    print("")
    print(humanName .. " pas encore branche.")
    print("")
    print("Dans l ordre, une seule fois :")
    print("  1. Pose la machine contre un transposer")
    print("  2. Lance  tools/discover   pour relever sa face")
    print("  3. Lance  tools/probe      pour relever ses slots")
    print("  4. Dans lib/config.lua, renseigne machine/source et")
    print("     passe enabled a true")
    print("")
    print("Les slots supposes sont deja ecrits, mais le programme refusera")
    print("de bouger quoi que ce soit tant qu ils ne collent pas.")
    return false
end

--- Print a bee from a complete template
--- The Replicator is the only machine that makes a bee out of nothing, and it
--- is what turns the gene library into insurance: losing the last Robotic drone
--- stops mattering once its template exists.
--- @param context table
function hivemind.replicateBee(context)
    print("")
    print("=== REPLIQUER UNE ABEILLE ===")
    print("Le replicator fabrique une abeille a partir d un template COMPLET")
    print("(13 chromosomes sur 13, gene Species compris) et de DNA liquide.")
    print("")

    if not machineReady(context, "replicator", "Le Genetic Replicator") then
        return
    end

    local machine = context.machines.replicator
    local template = machine:slot(machine.link.slots.template)

    if not template then
        print("Aucun template dans le replicator.")
        print("")
        print("Pose-le a la main dans le slot "
            .. machine:resolveSlot(machine.link.slots.template) .. ".")
        print("Le programme ne peut pas le choisir: dans le reseau ME, un")
        print("template complet et un template vide portent le meme nom.")
        return
    end

    print("Template en place : " .. tostring(template.label))

    local tank = context.transport:tank(machine.link)
    if tank then
        print(string.format("DNA liquide : %d / %d",
            tank.amount or 0, tank.capacity or 0))
        if (tank.amount or 0) == 0 then
            print("Vide. C est toi qui le fournis.")
        end
    end

    print("")
    print("  L abeille produite sera Ignoble: reserve cela aux drones.")
    io.write("Confirmer ? (o/N): ")

    local answer = io.read()
    if not answer or not (answer:lower():sub(1, 1) == "o"
                       or answer:lower():sub(1, 1) == "y") then
        print("Annule.")
        return
    end

    local params, err = genetics.replicateParams({})
    if not params then
        print("Parametres invalides: " .. tostring(err))
        return
    end

    local id, submit_err = context.queue:submit("replicate", params)
    if not id then
        print("Impossible de creer la tache: " .. tostring(submit_err))
        return
    end

    print("Tache #" .. id .. " creee. Choisis 6 pour la faire tourner.")
end

--- Feed surplus bees to the DNA Extractor
--- This is the one place in the system where a bee is destroyed on purpose, so
--- what goes in is chosen narrowly: only species whose Species gene is already
--- in the library, and only the surplus above a reserve. A bee is cheap to keep
--- and expensive to re-obtain.
--- @param context table
function hivemind.feedExtractor(context)
    print("")
    print("=== TRANSFORMER LES DRONES INUTILES EN DNA ===")
    print("Le DNA liquide alimente le replicator. Chaque abeille envoyee est")
    print("detruite: seules partent celles dont le gene Species est deja")
    print("en bibliotheque, et seulement au-dela d une reserve.")
    print("")

    if not machineReady(context, "dna_extractor", "Le DNA Extractor") then
        return
    end

    local RESERVE = (config.genetics and config.genetics.drone_reserve) or 16

    context.library:scan()
    local held = context.library:speciesGenes()

    local stock = {}
    for _, item in ipairs(context.transport:findAll(
            {name = "forestry:bee_drone_ge"}) or {}) do
        local label = tostring(item.label or "")
        local species = label:gsub("%s+Drone$", "")
        if species ~= "" and species ~= label then
            stock[species] = (stock[species] or 0) + (tonumber(item.size) or 0)
        end
    end

    local spendable, kept = {}, {}
    local names = {}
    for species in pairs(stock) do table.insert(names, species) end
    table.sort(names)

    for _, species in ipairs(names) do
        local count = stock[species]
        local surplus = count - RESERVE

        if not held[species] then
            -- Its Species gene exists nowhere else: destroying these is how a
            -- species is lost for good
            table.insert(kept, species .. " (gene Species pas encore acquis)")
        elseif surplus < 1 then
            table.insert(kept, string.format("%s (%d, reserve %d)",
                species, count, RESERVE))
        else
            table.insert(spendable,
                {species = species, count = count, surplus = surplus})
        end
    end

    if #kept > 0 then
        print("Gardees :")
        for _, line in ipairs(kept) do print("  " .. line) end
        print("")
    end

    if #spendable == 0 then
        print("Rien a envoyer. Accumule des drones (option 3) ou recolte")
        print("d abord les genes Species manquants (option i).")
        return
    end

    print("Envoyables :")
    for index, entry in ipairs(spendable) do
        print(string.format("  %d. %-18s %d en stock, %d au-dela de la reserve",
            index, entry.species, entry.count, entry.surplus))
    end

    print("")
    io.write("Numero (vide = annuler): ")
    local answer = io.read()
    local pick = tonumber(answer and answer:gsub("%s+", ""))

    local chosen = pick and spendable[pick]
    if not chosen then
        print("Annule.")
        return
    end

    io.write("Combien ? [" .. chosen.surplus .. "]: ")
    answer = io.read()
    local count = tonumber(answer and answer:gsub("%s+", "")) or chosen.surplus

    if count < 1 or count > chosen.surplus then
        print("Hors bornes: entre 1 et " .. chosen.surplus .. ".")
        return
    end

    print("")
    print("  " .. count .. " x " .. chosen.species
        .. " Drone seront DETRUITES pour faire du DNA.")
    io.write("Confirmer ? (o/N): ")

    answer = io.read()
    if not answer or not (answer:lower():sub(1, 1) == "o"
                       or answer:lower():sub(1, 1) == "y") then
        print("Annule.")
        return
    end

    local params, err = genetics.extractParams({
        bee = {label = chosen.species .. " Drone"},
        count = count,
    })

    if not params then
        print("Parametres invalides: " .. tostring(err))
        return
    end

    local id, submit_err = context.queue:submit("extract", params)
    if not id then
        print("Impossible de creer la tache: " .. tostring(submit_err))
        return
    end

    print("Tache #" .. id .. " creee. Choisis 6 pour la faire tourner.")
end

--- Fluids the player supplies, and whether any of them has run out
---
--- Four machines are the player's business, not the program's: the Protein
--- Liquifier and the Mutagen Producer make what the others drink, and the
--- Replicator drinks DNA. The program never fills them. But failing on an empty
--- tank and saying "la machine refuse l objet" is the worst of both worlds, so
--- it reads them and says which one is empty.
---
--- Machines that are not built report nothing at all rather than zero: an
--- absent Replicator is not a Replicator that is out of DNA.
--- @param context table
--- @return table[] readings {machine, label, amount, capacity, ratio, low}
function hivemind.fluidLevels(context)
    -- Below a tenth, a run that has already started can still finish; at zero
    -- nothing will start at all. Both are worth saying, differently.
    local LOW = 0.10

    local watched = {
        {key = "mutatron", name = "Mutatron", fluid = "mutagene"},
        {key = "replicator", name = "Replicator", fluid = "DNA liquide"},
        {key = "protein_liquifier", name = "Protein Liquifier", fluid = "proteines"},
        {key = "mutagen_producer", name = "Mutagen Producer", fluid = "mutagene"},
    }

    local readings = {}

    for _, entry in ipairs(watched) do
        local link = (config.machines or {})[entry.key]

        -- enabled = false means "not built yet", and a machine nobody has
        -- placed must not appear as a problem
        if link and link.enabled ~= false and link.machine ~= nil then
            local ok, tank = pcall(function()
                return context.transport:tank(link)
            end)

            -- The Mutatron has a driver and answers directly; everything else
            -- is read through the transposer
            if entry.key == "mutatron" and context.machines
               and context.machines.mutatron then
                local fine, amount, capacity = pcall(function()
                    return context.machines.mutatron:tank()
                end)
                if fine and capacity and capacity > 0 then
                    tank = {amount = amount, capacity = capacity,
                            ratio = amount / capacity, label = entry.fluid}
                    ok = true
                end
            end

            if ok and type(tank) == "table" then
                table.insert(readings, {
                    machine = entry.name,
                    fluid = entry.fluid,
                    label = tank.label,
                    amount = tank.amount or 0,
                    capacity = tank.capacity or 0,
                    ratio = tank.ratio,
                    low = (tank.ratio ~= nil and tank.ratio < LOW)
                          or (tank.amount or 0) == 0,
                    empty = (tank.amount or 0) == 0,
                })
            end
        end
    end

    return readings
end

--- One line per fluid that needs the player's attention, or none
--- @param context table
--- @return string[] warnings
function hivemind.fluidWarnings(context)
    local warnings = {}

    for _, reading in ipairs(hivemind.fluidLevels(context)) do
        if reading.empty then
            table.insert(warnings, reading.machine .. " : plus de "
                .. reading.fluid .. " -- a toi de le remplir")
        elseif reading.low then
            table.insert(warnings, string.format("%s : %s bas (%d/%d)",
                reading.machine, reading.fluid,
                reading.amount, reading.capacity))
        end
    end

    return warnings
end

--- Queue everything a profile still needs, in one choice
--- Filling a template by hand means running eleven separate campaigns and
--- typing the carrier species of each missing allele from memory. The program
--- already knows what is missing and who carries it; this joins the two.
--- @param context table
function hivemind.harvestProfile(context)
    print("")
    print("=== RECOLTER TOUT CE QUI MANQUE POUR UN PROFIL ===")

    local profiles = config.profiles or {}
    local names = {}
    for name in pairs(profiles) do table.insert(names, name) end
    table.sort(names)

    if #names == 0 then
        print("Aucun profil declare dans lib/config.lua.")
        return
    end

    for index, name in ipairs(names) do
        print("  " .. index .. " = " .. name)
    end
    print("  " .. (#names + 1) .. " = les deux")

    io.write("Profil: ")
    local answer = io.read()
    local pick = tonumber(answer and answer:gsub("%s+", ""))

    local wanted = {}
    if pick == #names + 1 then
        wanted = names
    elseif pick and names[pick] then
        wanted = {names[pick]}
    else
        print("Annule.")
        return
    end

    context.library:scan()

    -- One allele can be wanted by both profiles; queueing it twice would spend
    -- a second batch of bees on a gene already coming
    local targets, order = {}, {}
    for _, name in ipairs(wanted) do
        for _, entry in ipairs(context.library:missingForProfile(profiles[name])) do
            local key = entry.slot .. "/" .. entry.allele
            if not targets[key] then
                targets[key] = entry
                table.insert(order, key)
            end
        end
    end

    if #order == 0 then
        print("")
        print("Rien ne manque: les profils choisis sont complets.")
        print("Choisis e pour la liste des samples a assembler.")
        return
    end

    -- Drones in stock, by species. A carrier nobody owns is a hunting note,
    -- not a job: queueing it would fail on the first step.
    local stock = {}
    for _, item in ipairs(context.transport:findAll(
            {name = "forestry:bee_drone_ge"}) or {}) do
        local label = tostring(item.label or "")
        local species = label:gsub("%s+Drone$", "")
        if species ~= "" and species ~= label then
            stock[species] = (stock[species] or 0) + (tonumber(item.size) or 0)
        end
    end

    local queued = {}
    for _, job in ipairs(context.queue:list()) do
        if job.kind == "campaign" and job.status ~= "complete"
           and job.status ~= "cancelled" and job.params then
            queued[tostring(job.params.chromosome) .. "/"
                .. tostring(job.params.allele)] = true
        end
    end

    local plan, toHunt, alreadyGoing = {}, {}, {}

    for _, key in ipairs(order) do
        local entry = targets[key]

        -- Two sources, and both are needed: the table transcribed from the
        -- pack's quests, and whatever reading real genomes has taught us
        local found, carriers = {}, {}
        local byAllele = (config.gene_carriers or {})[entry.slot]
        for _, one in ipairs((byAllele and byAllele[entry.allele]) or {}) do
            if not found[one] then found[one] = true table.insert(carriers, one) end
        end
        for _, one in ipairs(context.library:carriersOf(entry.slot, entry.allele)) do
            if not found[one] then found[one] = true table.insert(carriers, one) end
        end

        local chromosome = entry.chromosome or entry.slot

        if queued[tostring(chromosome) .. "/" .. tostring(entry.allele)] then
            table.insert(alreadyGoing, chromosome .. " = " .. entry.allele)
        else
            -- Prefer the carrier we hold most of: a campaign spends bees, and
            -- running out mid-way parks the job for nothing
            local best, bestStock
            for _, one in ipairs(carriers) do
                if (stock[one] or 0) > (bestStock or 0) then
                    best, bestStock = one, stock[one]
                end
            end

            if best then
                table.insert(plan, {
                    species = best, stock = bestStock,
                    chromosome = chromosome, allele = entry.allele,
                    slot = entry.slot,
                })
            else
                table.insert(toHunt, string.format("%s = %s  <- %s",
                    chromosome, entry.allele,
                    #carriers > 0 and table.concat(carriers, " ou ")
                                  or "porteur inconnu"))
            end
        end
    end

    if #alreadyGoing > 0 then
        print("")
        print("Deja en file : " .. table.concat(alreadyGoing, ", "))
    end

    if #toHunt > 0 then
        print("")
        print("A ATTRAPER D ABORD (aucun drone en stock) :")
        for _, line in ipairs(toHunt) do print("  " .. line) end
    end

    if #plan == 0 then
        print("")
        print("Rien a lancer maintenant.")
        return
    end

    print("")
    print("A LANCER :")

    local budget, worst = 13, 0
    for _, item in ipairs(plan) do
        local spend = math.min(budget, item.stock)
        worst = worst + spend
        print(string.format("  %-22s %-10s <- %s (%d en stock, budget %d)",
            tostring(item.chromosome), item.allele, item.species,
            item.stock, spend))
    end

    local labware = 0
    for _, item in ipairs(context.transport:findAll(
            {name = "gendustry:labware"}) or {}) do
        labware = labware + (tonumber(item.size) or 0)
    end

    print("")
    print("  " .. #plan .. " campagne(s), au pire " .. worst .. " abeille(s)")
    print("  labware en stock : " .. labware)

    if labware < worst then
        print("  ATTENTION: pas assez de labware, la file s arretera en route.")
    end

    io.write("Confirmer ? (o/N): ")
    answer = io.read()
    if not answer or not (answer:lower():sub(1, 1) == "o"
                       or answer:lower():sub(1, 1) == "y") then
        print("Annule.")
        return
    end

    local created = 0
    for _, item in ipairs(plan) do
        local params = genetics.campaignParams({
            bee = {label = item.species .. " Drone"},
            chromosome = tostring(item.chromosome),
            allele = item.allele,
            bees = math.min(budget, item.stock),
        })

        if params then
            local id = context.queue:submit("campaign", params)
            if id then created = created + 1 end
        end
    end

    print(created .. " campagne(s) en file. Choisis 6 pour les faire tourner.")
end

--- Rank the species worth breeding, by how many missing genes each one brings
--- A source species is needed exactly once: one individual, one successful
--- sample, and the allele is in the library forever. So the useful question is
--- not "how do I get all these bees" but "what is the shortest list of species
--- that covers every gene still missing".
--- @param context table
function hivemind.breedingPlan(context)
    print("")
    print("=== QUOI CROISER ENSUITE ===")
    print("Chaque espece n est necessaire qu une fois: un individu, un")
    print("echantillonnage reussi, et le gene est acquis pour toujours.")
    print("")

    local carriers = config.gene_carriers or {}
    local learned = context.library:knownGenomes()

    local readCount = 0
    for _ in pairs(learned) do readCount = readCount + 1 end

    print(readCount .. " espece(s) dont le genome a ete lu (option g).")
    print("")

    if next(carriers) == nil and readCount == 0 then
        print("Aucun porteur connu: ni table declaree, ni genome lu.")
        print("Lis quelques especes avec l option g, elles se rangeront ici.")
        return
    end

    context.library:scan()

    -- What each species would bring, counted once per allele even when two
    -- profiles want the same one
    local brings, seen = {}, {}

    for name, profile in pairs(config.profiles or {}) do
        for slot, allele in pairs(profile) do
            local key = slot .. "/" .. allele

            if not seen[key] and not context.library:has(slot, allele) then
                seen[key] = true

                -- Two sources: the hand-written table, and every genome
                -- actually read. The second needs no list from anyone.
                local found = {}

                local byAllele = carriers[slot]
                for _, one in ipairs((byAllele and byAllele[allele]) or {}) do
                    found[one] = true
                end

                for _, one in ipairs(context.library:carriersOf(slot, allele)) do
                    found[one] = true
                end

                for one in pairs(found) do
                    brings[one] = brings[one] or {}
                    table.insert(brings[one], string.format("%s = %s",
                        tostring(genome.labelForSlot(slot) or slot), allele))
                end
            end
        end
    end

    -- Species already in the network need no breeding at all, only a sample
    local held = {}
    for _, item in ipairs(context.transport:findAll(
            {name = "forestry:bee_drone_ge"}) or {}) do
        held[tostring(item.label or ""):gsub("%s+Drone$", "")] = true
    end

    local ranked = {}
    for species, genes in pairs(brings) do
        table.insert(ranked, {species = species, genes = genes, held = held[species]})
    end

    if #ranked == 0 then
        print("Aucune espece connue n apporte un gene qui te manque.")
        print("Soit tu as tout, soit la table des porteurs est incomplete.")
        return
    end

    -- Most genes first, and among equals the ones already in stock: those cost
    -- a sample instead of a breeding chain
    table.sort(ranked, function(a, b)
        if #a.genes ~= #b.genes then return #a.genes > #b.genes end
        if a.held ~= b.held then return a.held == true end
        return a.species < b.species
    end)

    print("Par ordre de rendement :")
    print("")

    for index, entry in ipairs(ranked) do
        print(string.format("%2d. %-16s %d gene(s)   %s", index, entry.species,
            #entry.genes,
            entry.held and "DEJA EN STOCK: echantillonne-la" or "a croiser"))

        for _, gene in ipairs(entry.genes) do
            print("      " .. gene)
        end
    end

    local immediate = 0
    for _, entry in ipairs(ranked) do
        if entry.held then immediate = immediate + 1 end
    end

    print("")
    if immediate > 0 then
        print(immediate .. " espece(s) sont deja dans ton reseau: commence par")
        print("celles-la, elles ne coutent qu une campagne (option d).")
    end

    print("Pour les autres, l option 5 calcule la chaine de croisements.")
end

--- Show what each genetic profile still needs, and how a template is built
--- Templates are not made in a machine. The mod's own text says so: "Genetic
--- Samples can be added to a Template. Combine them in any crafting table."
--- So this says what to gather rather than pretending to build one.
--- @param context table
function hivemind.templateHelp(context)
    print("")
    print("=== CONSTRUIRE UN TEMPLATE ===")
    print("Table de craft: un Genetic Template + tes Gene Samples, ensemble.")
    print("Plusieurs samples d un coup. En AE2, un motif de craft fait pareil.")
    print("")

    local templates = 0
    for _, item in ipairs(context.transport:findAll(
            {name = "gendustry:gene_template"}) or {}) do
        templates = templates + (tonumber(item.size) or 0)
    end

    print("Genetic Template en stock : " .. templates)

    context.library:scan()

    local profiles = config.profiles or {}
    local names = {}
    for name in pairs(profiles) do table.insert(names, name) end
    table.sort(names)

    if #names == 0 then
        print("Aucun profil declare dans lib/config.lua.")
        return
    end

    for _, name in ipairs(names) do
        local profile = profiles[name]
        local missing, complete = context.library:missingForProfile(profile)

        local total = 0
        for _ in pairs(profile) do total = total + 1 end

        print("")
        print("-- profil " .. name .. " : " .. (total - #missing) .. "/" .. total
            .. " gene(s) en bibliotheque --")

        if complete then
            print("  Complet. Assemble ces samples avec un template:")

            local slots = {}
            for slot in pairs(profile) do table.insert(slots, slot) end
            table.sort(slots)

            for _, slot in ipairs(slots) do
                print(string.format("    %-22s %s",
                    tostring(genome.labelForSlot(slot) or slot), profile[slot]))
            end
        else
            -- What to hunt next, and where. A missing allele with no idea
            -- which bee carries it is a list, not a plan.
            local sources = config.gene_sources or {}

            for _, entry in ipairs(missing) do
                local hint = sources[entry.slot]
                print(string.format("  manque  %-22s %-10s %s",
                    tostring(entry.chromosome or entry.slot), entry.allele,
                    hint and ("<- " .. hint) or ""))
            end
        end
    end

    print("")
    print("Species est volontairement absent des deux profils: c est ce qui")
    print("permet d appliquer un template a n importe quelle espece sans la")
    print("changer. Cave dwelling l est aussi, l abeille garde le sien.")
    print("")
    print("Un allele qui n existe pas sous ce nom apparaitra toujours comme")
    print("manquant: compare avec l etiquette d un vrai sample si un gene")
    print("resiste alors que tu es sur de l avoir.")
end

--- Queue a run of extractions until a gene comes up
--- One draw is a lottery ticket; getting a particular chromosome means buying
--- tickets until it comes up. Nobody should restart that thirteen times by hand.
--- @param context table
function hivemind.geneCampaign(context)
    print("")
    print("=== CAMPAGNE DE GENES ===")
    print("Extrait des genes d'une meme espece jusqu'a obtenir celui vise,")
    print("ou jusqu'a epuisement du budget d'abeilles. Chaque tirage rate")
    print("enrichit quand meme la bibliotheque.")
    print("")

    local beeSpec = chooseBee(context, "forestry:bee_drone_ge", "drone")
    if not beeSpec then print("Annule.") return end

    print("")
    print("Chromosome vise (vide = tout prendre, sans cible) :")
    for slot = 0, 12 do
        local chromosome = genome.CHROMOSOMES[slot]
        if chromosome then
            io.write(string.format("  %-16s", chromosome.label))
            if slot % 3 == 2 then print("") end
        end
    end
    print("")

    io.write("Chromosome (nom exact, ou vide): ")
    local wanted = io.read()
    wanted = wanted and wanted:gsub("^%s+", ""):gsub("%s+$", "")
    if wanted == "" then wanted = nil end

    if wanted and not genome.slotForLabel(wanted) then
        print("Chromosome inconnu: " .. wanted)
        print("Reprends un nom de la liste ci-dessus, tel quel.")
        return
    end

    -- A profile wants Fertility 4, not any Fertility: stopping on the first
    -- draw of the right chromosome hands back whatever that bee carried
    local wantedAllele = nil
    if wanted then
        io.write("Allele precis ? (vide = n importe lequel): ")
        wantedAllele = io.read()
        wantedAllele = wantedAllele
            and wantedAllele:gsub("^%s+", ""):gsub("%s+$", "")
        if wantedAllele == "" then wantedAllele = nil end
    end

    io.write("Combien d'abeilles au maximum ? [13]: ")
    local answer = io.read()
    local budget = tonumber(answer and answer:gsub("%s+", "")) or 13

    local params, err = genetics.campaignParams({
        bee = beeSpec, chromosome = wanted, allele = wantedAllele, bees = budget,
    })

    if not params then
        print("Parametres invalides: " .. tostring(err))
        return
    end

    print("")
    print("  " .. beeSpec.label .. " x" .. budget
        .. (wanted and (" -> vise " .. wanted) or " -> tout prendre")
        .. (wantedAllele and (" = " .. wantedAllele) or ""))
    print("  Le Sampler detruit chaque abeille.")
    io.write("Confirmer ? (o/N): ")

    answer = io.read()
    if not answer or not (answer:lower():sub(1, 1) == "o"
                       or answer:lower():sub(1, 1) == "y") then
        print("Annule.")
        return
    end

    local id, submit_err = context.queue:submit("campaign", params)
    if not id then
        print("Impossible de creer la tache: " .. tostring(submit_err))
        return
    end

    print("Tache #" .. id .. " creee. Choisis 6 pour la faire tourner.")
end

--- Queue a copy of every gene held below the safe number
--- Picking genes off a list one at a time is fine for two of them and hopeless
--- for sixty. The library already knows which are short; this turns that into
--- work. The source survives every copy, so this can only ever add.
--- @param context table
function hivemind.secureLibrary(context)
    print("")
    print("=== METTRE LA BIBLIOTHEQUE A L'ABRI ===")

    context.library:scan()
    local shortages = context.library:shortages()

    if #shortages == 0 then
        print("Chaque gene connu est deja en assez d'exemplaires.")
        return
    end

    print(#shortages .. " gene(s) sous le seuil de securite :")
    print("")

    -- Already queued work must not be queued again: running the same command
    -- twice would spend a labware and a blank sample for nothing
    local queued = {}
    for _, job in ipairs(context.queue:list()) do
        if job.kind == "duplicate" and job.status ~= "complete"
           and job.status ~= "cancelled" and job.params and job.params.sample then
            queued[job.params.sample.label] = true
        end
    end

    local plan = {}
    for _, shortage in ipairs(shortages) do
        if queued[shortage.label] then
            print(string.format("  %-44s deja en file", shortage.label))
        else
            print(string.format("  %-44s %d copie(s), il en faut %d",
                shortage.label, shortage.count, shortage.needed))
            table.insert(plan, shortage)
        end
    end

    if #plan == 0 then
        print("")
        print("Tout est deja en file. Choisis 6 pour les faire tourner.")
        return
    end

    local blanks, labware = 0, 0
    for _, item in ipairs(context.transport:findAll(
            {name = "gendustry:gene_sample_blank"}) or {}) do
        blanks = blanks + (tonumber(item.size) or 0)
    end
    for _, item in ipairs(context.transport:findAll(
            {name = "gendustry:labware"}) or {}) do
        labware = labware + (tonumber(item.size) or 0)
    end

    -- Each copy eats one of each. Saying so before the confirmation beats
    -- discovering it halfway through a queue that then stalls.
    print("")
    print("  " .. #plan .. " copie(s) a faire")
    print("  samples vierges : " .. blanks .. "   labware : " .. labware)

    if blanks < #plan or labware < #plan then
        print("  ATTENTION: pas de quoi tout faire, la file s'arretera en route.")
    end

    io.write("Confirmer ? (o/N): ")
    local answer = io.read()
    if not answer or not (answer:lower():sub(1, 1) == "o"
                       or answer:lower():sub(1, 1) == "y") then
        print("Annule.")
        return
    end

    local created = 0
    for _, shortage in ipairs(plan) do
        local params = genetics.duplicateParams({sample = {label = shortage.label}})
        if params then
            local id = context.queue:submit("duplicate", params)
            if id then created = created + 1 end
        end
    end

    print(created .. " tache(s) creee(s). Choisis 6 pour les faire tourner.")
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

    -- The player fills these, so the only useful moment to mention them is
    -- before an option is chosen that will need them
    local ok, warnings = pcall(hivemind.fluidWarnings, context)
    if ok then
        for _, warning in ipairs(warnings or {}) do
            print("  ! " .. warning)
        end
    end
end

local ENTRIES = {
    {group = "Regarder"},
    {key = "1", label = "Etat detaille",
     hint = "stocks, machines, genes, file", action = "status"},
    {key = "2", label = "Diagnostic des slots",
     hint = "ce que chaque machine tient vraiment", action = "slotDiagnostic"},
    {key = "g", label = "Lire le genome d une abeille",
     hint = "13 alleles d un coup, sans la detruire", action = "analyseBee"},

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
    {key = "c", label = "Mettre la bibliotheque a l abri",
     hint = "copie tout ce qui est en un seul exemplaire", action = "secureLibrary"},
    {key = "d", label = "Campagne de genes",
     hint = "extrait en boucle jusqu au gene vise", action = "geneCampaign"},
    {key = "i", label = "Recolter tous les genes Species",
     hint = "une campagne par espece en stock", action = "speciesSweep"},
    {key = "t", label = "Recolter ce qui manque",
     hint = "toutes les campagnes d un profil, d un coup", action = "harvestProfile"},
    {key = "e", label = "Construire un template",
     hint = "ce qui manque pour chaque profil", action = "templateHelp"},
    {key = "h", label = "Quoi croiser ensuite",
     hint = "les especes classees par gene apporte", action = "breedingPlan"},
    {key = "f", label = "Imprimer une abeille",
     hint = "applique le template pose dans la machine", action = "imprintBee"},

    {key = "r", label = "Repliquer une abeille",
     hint = "template complet + DNA -> une abeille", action = "replicateBee"},
    {key = "x", label = "Drones inutiles -> DNA",
     hint = "detruit le surplus pour alimenter le replicator",
     action = "feedExtractor"},

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

--- How many lines the full menu needs, groups, blanks and prompt included
--- @return number
local function fullMenuHeight()
    local lines = 8   -- title, headline, advice, "0 Quitter", prompt
    for _, entry in ipairs(ENTRIES) do
        lines = lines + (entry.group and 2 or 1)
    end
    return lines
end

--- Draw the options, folding them when the screen is too short
--- The full listing is forty lines and a tier 2 screen holds twenty-five, so on
--- small hardware the groups and the hints go and the keys pair up two per
--- line. The keys themselves never change: the compact menu is the same menu.
--- @param width number
--- @param height number
local function drawOptions(width, height)
    if height >= fullMenuHeight() then
        for _, entry in ipairs(ENTRIES) do
            if entry.group then
                print("")
                print("  " .. entry.group)
            else
                print(string.format("    %s  %-28s %s",
                    entry.key, entry.label, entry.hint))
            end
        end
        return
    end

    local options = {}
    for _, entry in ipairs(ENTRIES) do
        if not entry.group then table.insert(options, entry) end
    end

    print("")

    -- Two columns need room for two labels; below that one column, truncated,
    -- which is still readable where a wrapped line is not
    local columns = (width >= 76) and 2 or 1
    local cell = math.floor((width - 4) / columns) - 4

    local rows = math.ceil(#options / columns)
    for row = 1, rows do
        local parts = {}
        for column = 0, columns - 1 do
            local entry = options[row + column * rows]
            if entry then
                local label = entry.label
                if #label > cell then label = label:sub(1, cell) end
                table.insert(parts, string.format("%s  %-" .. cell .. "s",
                    entry.key, label))
            end
        end
        print("  " .. table.concat(parts, "  "))
    end
end

local function menu(context)
    -- A tier 3 pair reaches 160x50, and the whole menu fits there. Asking once
    -- costs nothing and is the difference between folding and not.
    screen.maximise()

    while true do
        -- Erasing is the actual fix. Without it every option's output is still
        -- on screen when the menu redraws over it, which is what made a genome
        -- read unreadable however slowly it was printed.
        screen.clear()

        local width, height = screen.size()

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

        drawOptions(width, height)

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

            -- The menu redraws straight after and pushes everything off the
            -- top of the screen. A genome read is thirteen lines nobody gets
            -- to see if the next thing printed is a menu.
            print("")
            screen.pause()
        else
            -- The invalid branch needs the pause too, or the complaint is the
            -- one line that scrolls away before it is read
            print("")
            print("Choix inconnu: " .. choice)
            screen.pause()
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
