-- HiveMind slot prober
--
-- The genetics machines have no driver to ask, and the slot maps in the
-- Gendustry documentation turned out to be wrong: labware sits at index 1 on
-- the imprinter and the genetic transposer, not 3. Guessing again would put
-- every delivery in the wrong place, silently.
--
-- So the machines are asked the only way they answer: try to put a known item
-- in a slot and see whether it stays. A machine refuses what a slot is not for,
-- which turns "which slot takes a bee?" into an experiment instead of a guess.
--
-- Every marker is taken back out afterwards. Nothing is consumed unless a
-- machine starts working on what it was handed, which is why this only runs
-- with --yes.
--
-- Usage:
--   probe            list what would be tried, move nothing
--   probe --yes      run the experiment
--   probe --upload   publish the result

local component = require("component")

-- Items whose slot a machine will accept or refuse, and that exist in quantity
local MARKERS = {
    {name = "gendustry:labware",          role = "labware"},
    {name = "forestry:bee_drone_ge",      role = "abeille"},
    {name = "gendustry:gene_sample_blank", role = "sample vierge"},
    {name = "gendustry:gene_sample",      role = "sample"},
    {name = "gendustry:gene_template",    role = "template"},
}

local report = {}

local function say(text)
    table.insert(report, text or "")
    print(text or "")
end

local function main(args)
    local commit, doUpload = false, false
    for _, arg in ipairs(args) do
        if arg == "--yes" then commit = true end
        if arg == "--upload" then doUpload = true end
    end

    -- OpenOS caches modules for the whole shell session
    for name in pairs(package.loaded) do
        if type(name) == "string"
           and (name == "hivemind" or name:match("^lib%.")) then
            package.loaded[name] = nil
        end
    end

    local ok, hivemind = pcall(require, "hivemind")
    if not ok or type(hivemind) ~= "table" then
        print("hivemind.lua introuvable: " .. tostring(hivemind))
        return
    end

    local config = require("lib.config")
    local context = hivemind.bootstrap()

    say("HiveMind - sondage des slots")
    say("version " .. tostring(hivemind.VERSION))
    say("")

    -- Only machines without a driver need this: the others answer listSlots()
    local targets = {}
    for _, name in ipairs(config.enabledMachines()) do
        if not config.machines[name].component then
            table.insert(targets, name)
        end
    end

    if #targets == 0 then
        say("Aucune machine sans driver: rien a sonder.")
        return
    end

    say("Machines a sonder : " .. table.concat(targets, ", "))

    -- A marker nobody owns teaches nothing, and the failure would read as
    -- "this slot refuses bees" when it means "there are no bees"
    local available = {}
    for _, marker in ipairs(MARKERS) do
        local total = 0
        for _, item in ipairs(context.transport:findAll({name = marker.name}) or {}) do
            total = total + (tonumber(item.size) or 0)
        end

        if total > 0 then
            table.insert(available, marker)
            say(string.format("  marqueur %-24s %-14s x%d",
                marker.name, marker.role, total))
        else
            say(string.format("  marqueur %-24s %-14s ABSENT, ignore",
                marker.name, marker.role))
        end
    end

    if #available == 0 then
        say("")
        say("Aucun marqueur en stock: impossible de sonder.")
        return
    end

    if not commit then
        say("")
        say("Rien n'a ete deplace. Relance avec --yes pour sonder reellement.")
        say("Chaque marqueur est repris apres l'essai; une machine qui se met")
        say("a travailler sur ce qu'on lui tend peut toutefois le consommer.")
        return
    end

    for _, name in ipairs(targets) do
        local machine = context.machines[name]
        local link = machine.link

        say("")
        say("=== " .. name .. " (face " .. tostring(link.machine) .. ") ===")

        local size = context.transport:inventorySize(link)
        if not size then
            say("  inventaire illisible")
        else
            say("  " .. size .. " slot(s)")

            for raw = 1, size do
                local occupied = context.transport:inspect(link, raw)

                if occupied then
                    say(string.format("  slot %-3d deja occupe par %s",
                        raw, tostring(occupied.label or occupied.name)))
                else
                    local accepted = {}

                    for _, marker in ipairs(available) do
                        -- deliver() takes driver indices, and resolveSlot adds
                        -- the offset; raw is already a transposer index
                        local moved = context.transport:deliver(
                            {name = marker.name}, link, raw, 1)

                        if moved then
                            table.insert(accepted, marker.role)
                            context.transport:retrieve(link, raw, 64)
                        end
                    end

                    if #accepted > 0 then
                        say(string.format("  slot %-3d (driver %-3d) accepte : %s",
                            raw, raw - config.slot_offset,
                            table.concat(accepted, ", ")))
                    else
                        say(string.format("  slot %-3d (driver %-3d) refuse tout",
                            raw, raw - config.slot_offset))
                    end
                end
            end
        end
    end

    say("")
    say("Reporte ces indices dans config.machines.<machine>.slots.")

    if not doUpload then return end

    local body = table.concat(report, "\n") .. "\n"
    local net_ok, internet = pcall(require, "internet")

    if not net_ok or not component.isAvailable("internet") then
        print("Pas de carte Internet.")
        return
    end

    local mailbox = config.report_mailbox
    if mailbox then
        pcall(internet.request, mailbox, body,
            {["Content-Type"] = "text/plain"}, "POST")
        print("Resultat depose dans la boite aux lettres.")
    end
end

main({...})
