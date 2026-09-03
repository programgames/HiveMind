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

local config = require("lib.config")
local transport = require("lib.transport")
local machines = require("lib.machines")
local library = require("lib.library")
local species = require("lib.species")
local jobs = require("lib.jobs")
local breeding = require("lib.breeding")
local genome = require("lib.genome")

local hivemind = {}

-- Printed at startup so "am I running the version we just fixed?" is answerable
-- without counting bytes. raw.githubusercontent.com serves through a CDN that
-- can hand out the previous file for a few minutes after a push, which has
-- already cost one round of confusion.
hivemind.VERSION = "0.6.0"

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

    local me = optional("me_interface") or optional("me_controller")
    if not me then table.insert(problems, "aucune interface ME (adapter sur la ME Interface ?)") end

    local database = optional("database")
    if not database then
        table.insert(problems, "aucune Database upgrade (dans le slot d'un Adapter)")
    end

    local layer = transport.new({
        me = me,
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
        handlers = {breed = breeding.handler()},
    })

    return {
        transport = layer,
        machines = built,
        species = registry,
        library = genes,
        queue = queue,
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
    local entries = context.transport:findAll({name = itemName})

    if #entries == 0 then
        print("Aucun item '" .. itemName .. "' visible dans le reseau ME.")
        io.write("Etiquette exacte a la main (vide pour annuler): ")
        local typed = io.read()
        if not typed or typed == "" then return nil end
        return {name = itemName, label = typed}
    end

    local chosen = pick(entries,
        function(entry) return string.format("%-32s x%d", entry.label or "?", entry.size or 0) end,
        "Choisis la " .. role)

    if not chosen then return nil end

    return {name = chosen.name, label = chosen.label}
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
        io.write("Recherche d'espece (nom ou fragment, vide = tout): ")
        local term = io.read()
        if not term then return nil end

        local matching = {}
        if term == "" then
            matching = all
        else
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

    local target = chooseSpecies(context)
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

--- Run the queue until it stops making progress
--- @param context table
function hivemind.runQueue(context)
    local pending = #context.queue:pending()
    if pending == 0 then
        print("Aucune tache en attente.")
        return
    end

    print("Execution de " .. pending .. " tache(s)...")

    local report = context.queue:run(context, {
        onProgress = function(job, outcome, detail)
            print(string.format("  #%d %s etape %d : %s%s",
                job.id, job.kind, job.step, outcome,
                detail and ("  " .. detail) or ""))
        end,
    })

    print(string.format("%d etape(s), %d terminee(s), %d attente(s), %d echec(s)",
        report.steps, report.completed, report.retried, report.failed))

    if report.blocked then
        print("La file est bloquee: corrige la cause puis relance.")
    end
end

local function menu(context)
    while true do
        print("")
        print("=== HiveMind ===")
        print("1. Etat")
        print("2. Rafraichir la liste des especes depuis le jeu")
        print("3. Programmer un croisement")
        print("4. Executer la file")
        print("5. Quitter")
        io.write("Choix: ")

        local choice = io.read()
        if not choice then return end

        choice = choice:gsub("%s+", "")

        if choice == "1" then hivemind.status(context)
        elseif choice == "2" then hivemind.refreshSpecies(context)
        elseif choice == "3" then hivemind.submitBreeding(context)
        elseif choice == "4" then hivemind.runQueue(context)
        elseif choice == "5" then print("Au revoir.") return
        else print("Choix invalide.") end
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
