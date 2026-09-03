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
--- @return table context
--- @return string[] problems
function hivemind.bootstrap()
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
        cachePath = config.state_directory .. "/species.lua",
    })

    local genes = library.new({
        transport = layer,
        templateLink = {
            transposer = config.template_chest.transposer,
            machine = config.template_chest.side,
            source = config.machines.mutatron.source,
        },
        path = config.state_directory .. "/library.lua",
        config = config,
    })

    local queue = jobs.new({
        path = config.state_directory .. "/jobs.lua",
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
    print("Reseau ME    : " .. (online and "en ligne" or ("HORS LIGNE - " .. tostring(reason))))

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

--- Queue one breeding cycle
--- @param context table
function hivemind.submitBreeding(context)
    io.write("Etiquette de la princesse (ex: Forest Princess): ")
    local princess = io.read()
    io.write("Etiquette du drone (ex: Meadows Drone): ")
    local drone = io.read()
    io.write("Espece visee (uid, ex: forestry.speciesCommon): ")
    local target = io.read()

    if not (princess and drone and target) then
        print("Annule.")
        return
    end

    local params, err = breeding.params({
        target = target,
        princess = {name = "forestry:bee_princess_ge", label = princess},
        drone = {name = "forestry:bee_drone_ge", label = drone},
    })

    if not params then
        print("Parametres invalides: " .. tostring(err))
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
    print("HiveMind - demarrage")
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
