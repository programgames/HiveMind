-- HiveMind automatic report
--
-- Collects in one pass everything that would otherwise take a dozen screenshots
-- and menu navigations: machine state, network inventory, species registry,
-- queue with its errors, raw slots, and optionally the output of running the
-- queue. Writes it to a file and can upload it.
--
-- Answers nothing interactively: every choice is a flag. That is the point.
--
-- Usage:
--   autoreport                 collect and write /home/hivemind-report.txt
--   autoreport --run           also empty the apiary and advance the queue
--   autoreport --upload        also publish the report and print the URL
--   autoreport --cancel 3     drop job 3 (repeatable) before anything runs
--   autoreport --multiply Common:32
--                             queue a drone campaign (repeatable)
--   autoreport --run --upload  both
--
-- --run moves items, consumes mutagen and can kill a queen, exactly as menu
-- option 4 does. It is opt-in for that reason.

local component = require("component")

local OUTPUT = "/home/hivemind-report.txt"
local MAX_ITEMS = 200

local report = {}

local function say(text)
    table.insert(report, text or "")
end

local function section(title)
    say("")
    say("=== " .. title .. " ===")
end

--- Run a function while capturing everything it prints
--- @param fn function
--- @return boolean ok
--- @return string|nil error
local function capture(fn, ...)
    local real = print

    print = function(...)
        local parts = {}
        for i = 1, select("#", ...) do parts[i] = tostring((select(i, ...))) end
        say(table.concat(parts, "\t"))
    end

    local ok, err
    if type(fn) ~= "function" then
        ok, err = false, "fonction absente de cette version du programme"
    else
        ok, err = pcall(fn, ...)
    end

    print = real

    -- An empty section is the worst answer: it reads as "nothing to report"
    -- when it actually means the call never happened.
    if not ok then
        say("  ECHEC: " .. tostring(err))
        say("  (relance hminstall si la fonction est absente)")
    end

    return ok, err
end

--- Render a value, cycle safe and depth limited
local function dump(value, indent, depth, seen)
    indent, depth, seen = indent or "", depth or 0, seen or {}

    if type(value) == "string" then return string.format("%q", value) end
    if type(value) ~= "table" then return tostring(value) end
    if seen[value] then return "<cycle>" end
    if depth >= 4 then return "<...>" end

    seen[value] = true

    local keys = {}
    for key in pairs(value) do table.insert(keys, key) end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)

    if #keys == 0 then seen[value] = nil return "{}" end

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

local function main(args)
    local doRun, doUpload, toCancel, campaigns = false, false, {}, {}
    for index, arg in ipairs(args) do
        if arg == "--run" then doRun = true end
        if arg == "--upload" then doUpload = true end

        -- --multiply Common:32 queues a drone campaign without the menu, so a
        -- whole session still fits in one non-interactive command.
        if arg == "--multiply" then
            local value = args[index + 1]
            if value then
                local species, target = value:match("^([^:]+):?(%d*)$")
                if species then
                    table.insert(campaigns,
                        {species = species, target = tonumber(target)})
                end
            end
        end
        -- Cancelling through the menu costs a screenshot round trip for what is
        -- one number; a blocked job that will never resolve has to go before
        -- the queue can move at all.
        if arg == "--cancel" then
            local id = tonumber(args[index + 1])
            if id then table.insert(toCancel, id) end
        end
    end

    -- OpenOS keeps required modules in package.loaded for the whole shell
    -- session, so a second run gets the copy loaded before the update rather
    -- than the file just written. That is how this tool once reported version
    -- 0.14.1 with 0.17.0 sitting on disk.
    for name in pairs(package.loaded) do
        if type(name) == "string"
           and (name == "hivemind" or name:match("^lib%.")) then
            package.loaded[name] = nil
        end
    end

    -- Loaded as a module, never as a program: hivemind starts its menu unless it
    -- receives a module name, and a menu is the one thing this tool must avoid.
    --
    -- require() searches "./?.lua", which resolves against the working directory
    -- and not against this script. Launched as tools/autoreport from anywhere
    -- but /home it would fail, so the sibling path is tried too.
    local ok, hivemind = pcall(require, "hivemind")

    if not ok or type(hivemind) ~= "table" then
        local source = debug.getinfo(1, "S").source or ""
        local directory = source:match("^[@=](.*)/[^/]*$")

        for _, candidate in ipairs({directory and (directory .. "/../hivemind.lua"),
                                    directory and (directory .. "/hivemind.lua"),
                                    "/home/hivemind.lua"}) do
            local chunk = candidate and loadfile(candidate)
            if chunk then
                local loaded, value = pcall(chunk, "hivemind")
                if loaded and type(value) == "table" then
                    ok, hivemind = true, value
                    break
                end
            end
        end
    end

    if not ok or type(hivemind) ~= "table" then
        print("hivemind.lua introuvable ou illisible: " .. tostring(hivemind))
        print("Lance 'hminstall' puis reessaie depuis le repertoire de hivemind.")
        return
    end

    -- Loaded the same way hivemind loads it, from the install directory
    local has_multiply, multiply = pcall(require, "lib.multiply")
    if not has_multiply then multiply = nil end

    say("HiveMind - rapport automatique")
    say("version " .. tostring(hivemind.VERSION))

    -- The CDN can serve a fresh tool next to a stale program. Saying so here
    -- beats a report full of empty sections that look like good news.
    local absent = {}
    for _, name in ipairs({"bootstrap", "status", "slotDiagnostic", "runQueue",
                           "harvestApiary"}) do
        if type(hivemind[name]) ~= "function" then table.insert(absent, name) end
    end

    if #absent > 0 then
        say("")
        say("ATTENTION: hivemind.lua est plus ancien que cet outil.")
        say("  manquant: " .. table.concat(absent, ", "))
        say("  Relance hminstall, puis redemarre l'ordinateur si cela persiste:")
        say("  OpenOS garde les modules en cache pour toute la session.")
        print("hivemind.lua est trop ancien (" .. table.concat(absent, ", ") .. ").")
        print("Relance hminstall; si le message revient, redemarre l'ordinateur.")
    end

    section("COMPOSANTS")
    for address, kind in component.list() do
        say(string.format("  %-24s %s", kind, address:sub(1, 8)))
    end

    local context, problems = hivemind.bootstrap()

    if #problems > 0 then
        section("PROBLEMES AU DEMARRAGE")
        for _, problem in ipairs(problems) do say("  " .. problem) end
    end

    section("ETAT")
    capture(hivemind.status, context)

    -- The bee inventory is what every "introuvable dans le reseau" comes down
    -- to, and it is tedious to read off a menu one page at a time
    section("ABEILLES DANS LE RESEAU")

    for _, itemName in ipairs({"forestry:bee_princess_ge", "forestry:bee_drone_ge",
                               "forestry:bee_queen_ge"}) do
        say("")
        say("  " .. itemName)

        local found = context.transport:findAll({name = itemName})
        local merged, order = {}, {}

        for _, item in ipairs(found) do
            local label = tostring(item.label or "?")
            if not merged[label] then
                merged[label] = {count = 0, variants = 0}
                table.insert(order, label)
            end
            merged[label].count = merged[label].count + (tonumber(item.size) or 0)
            merged[label].variants = merged[label].variants + 1
        end

        table.sort(order)

        if #order == 0 then say("    (aucun)") end
        for index, label in ipairs(order) do
            if index > MAX_ITEMS then say("    ...") break end
            say(string.format("    %-34s x%-6d %d genome(s)",
                label, merged[label].count, merged[label].variants))
        end
    end

    section("CONSOMMABLES")
    for _, itemName in ipairs({"gendustry:labware", "gendustry:gene_sample",
                               "gendustry:gene_template", "gendustry:gene_sample_blank"}) do
        local found = context.transport:findAll({name = itemName})
        local total = 0
        for _, item in ipairs(found) do total = total + (tonumber(item.size) or 0) end
        say(string.format("  %-32s %d", itemName, total))
    end

    section("REGISTRE DES ESPECES")
    local known, source = context.species:list()
    local count, derived = 0, 0
    for _, entry in pairs(known) do
        count = count + 1
        if entry.derived then derived = derived + 1 end
    end
    say("  " .. count .. " especes (" .. tostring(source) .. "), dont "
        .. derived .. " au nom deduit")
    say("  index inverse construit : " .. tostring(context.species:hasOffspringIndex()))

    section("FILE DE TACHES")
    local all = context.queue:list()
    if #all == 0 then say("  (vide)") end
    for _, job in ipairs(all) do
        say("  #" .. job.id .. " " .. job.kind .. "  " .. job.status
            .. "  etape " .. tostring(job.step))
        say("     params: " .. dump(job.params, "     "))
        if job.error then say("     erreur: " .. tostring(job.error)) end
    end

    section("SLOTS")
    capture(hivemind.slotDiagnostic, context)

    if #toCancel > 0 then
        section("ANNULATIONS")
        for _, id in ipairs(toCancel) do
            local cancelled = context.queue:cancel(id)
            say("  #" .. id .. " : " .. (cancelled and "annulee" or "introuvable"))
        end
    end

    if #campaigns > 0 then
        section("CAMPAGNES DE DRONES")
        for _, campaign in ipairs(campaigns) do
            local params, err
            if multiply then
                params, err = multiply.params(campaign)
            else
                err = "lib/multiply.lua absent: relance hminstall"
            end
            if not params then
                say("  " .. campaign.species .. " : refuse (" .. tostring(err) .. ")")
            else
                local id, submit_err = context.queue:submit("multiply", params)
                say("  " .. campaign.species .. " -> " .. params.target
                    .. " drones : " .. (id and ("tache #" .. id)
                                           or tostring(submit_err)))
            end
        end
    end

    if doRun then
        -- Harvest first. Bees left in the apiary output are invisible to jobs,
        -- which search the ME network: a Common Drone parked in an output slot
        -- is reported as "introuvable dans le reseau" while sitting two blocks
        -- away. Emptying the slots also lets the next cycle start.
        section("RECOLTE DE L'APIARY")
        capture(hivemind.harvestApiary, context)

        -- Moves items, spends mutagen, can kill a queen: the same thing menu
        -- option 4 does, which is why it is not the default
        section("EXECUTION DE LA FILE")
        capture(hivemind.runQueue, context)

        section("FILE APRES EXECUTION")
        for _, line in ipairs(context.queue:describe()) do say("  " .. line) end
    end

    local body = table.concat(report, "\n") .. "\n"

    local file, err = io.open(OUTPUT, "w")
    if file then
        file:write(body)
        file:close()
        print("Rapport ecrit dans " .. OUTPUT .. " (" .. #body .. " octets)")
    else
        print("Ecriture impossible: " .. tostring(err))
    end

    if not doUpload then
        print("Relance avec --upload pour le publier.")
        return
    end

    -- Publishing makes the content readable by anyone holding the URL
    local net_ok, internet = pcall(require, "internet")
    if not net_ok or not component.isAvailable("internet") then
        print("Pas de carte Internet: envoie le fichier a la main.")
        return
    end

    local requested, handle = pcall(internet.request, "https://paste.rs/", body,
        {["Content-Type"] = "text/plain"}, "POST")

    if not requested then
        print("Envoi impossible: " .. tostring(handle))
        return
    end

    local chunks = {}
    local read_ok = pcall(function()
        for chunk in handle do table.insert(chunks, chunk) end
    end)

    local response = table.concat(chunks)

    if not read_ok or response == "" then
        print("Reponse vide du serveur; le fichier reste dans " .. OUTPUT)
        return
    end

    print("")
    print("=====================================")
    print("  " .. (response:match("(https?://%S+)") or response))
    print("=====================================")
end

main({...})
