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
--   autoreport --run           also advance the queue, capturing what happens
--   autoreport --upload        also publish the report and print the URL
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

    local ok, err = pcall(fn, ...)
    print = real

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
    local doRun, doUpload = false, false
    for _, arg in ipairs(args) do
        if arg == "--run" then doRun = true end
        if arg == "--upload" then doUpload = true end
    end

    -- Required as a module so it does not start its own menu
    local ok, hivemind = pcall(require, "hivemind")
    if not ok or type(hivemind) ~= "table" then
        print("hivemind.lua introuvable ou illisible: " .. tostring(hivemind))
        print("Lance 'hminstall' puis reessaie.")
        return
    end

    say("HiveMind - rapport automatique")
    say("version " .. tostring(hivemind.VERSION))

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

    if doRun then
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
