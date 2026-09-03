-- HiveMind slot prober
--
-- The genetics machines have no driver to ask, and the slot maps in the
-- Gendustry documentation turned out to be wrong: labware sits at index 1 on
-- the imprinter and the genetic transposer, not 3, and the documented output at
-- 4 is outside a four-slot inventory. Guessing again would put every delivery
-- in the wrong place, silently.
--
-- So the machines are asked the only way they answer: offer a known item to a
-- slot and see whether it stays. A machine refuses what a slot is not for,
-- which turns "which slot takes a bee?" into an experiment.
--
-- One staging per marker, not one per attempt. Going through the ME network for
-- every slot cost up to twenty seconds each and turned a short experiment into
-- twenty minutes of apparent hang. The marker is parked on a dock once, then
-- offered to each slot straight from there.
--
-- Usage:
--   probe            list what would be tried, move nothing
--   probe --yes      run the experiment
--   probe --upload   publish the result

local component = require("component")

-- Items whose slot a machine will accept or refuse, and that exist in quantity
local MARKERS = {
    {name = "gendustry:labware",           role = "labware"},
    {name = "forestry:bee_drone_ge",       role = "abeille"},
    {name = "gendustry:gene_sample_blank", role = "sample vierge"},
    {name = "gendustry:gene_sample",       role = "sample"},
    {name = "gendustry:gene_template",       role = "template"},
    {name = "gendustry:gene_template_blank", role = "template vierge"},
}

local report = {}

local function say(text)
    table.insert(report, text or "")
    print(text or "")
end

--- Call a component method without letting a failure stop the run
local function invoke(proxy, method, ...)
    if not proxy then return false, "composant absent" end
    local target = proxy[method]
    if target == nil then return false, "methode absente" end
    return pcall(target, ...)
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
    local transport = context.transport

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

    -- A marker nobody owns teaches nothing, and its failure would read as
    -- "this slot refuses bees" when it means "there are no bees"
    local available = {}
    for _, marker in ipairs(MARKERS) do
        local total = 0
        for _, item in ipairs(transport:findAll({name = marker.name}) or {}) do
            total = total + (tonumber(item.size) or 0)
        end

        if total > 0 then
            table.insert(available, marker)
            say(string.format("  marqueur %-30s %-14s x%d",
                marker.name, marker.role, total))
        else
            say(string.format("  marqueur %-30s %-14s ABSENT, ignore",
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
        local transposer = transport:transposerFor(link.transposer)

        say("")
        say("=== " .. name .. " (face " .. tostring(link.machine) .. ") ===")

        local size = transport:inventorySize(link)

        if not transposer then
            say("  transposer introuvable")
        elseif not size then
            say("  inventaire illisible")
        else
            -- accepted[slot] = {roles...}
            local accepted, occupied = {}, {}

            for raw = 1, size do
                local stack = transport:inspect(link, raw)
                if stack then
                    occupied[raw] = stack.label or stack.name or "?"
                end
                accepted[raw] = {}
            end

            for _, marker in ipairs(available) do
                -- Staged once for the whole machine instead of once per slot:
                -- the ME round trip is what made this look like a hang
                local dock, stage_err = transport:stage({name = marker.name}, 1, link)

                if not dock then
                    say("  " .. marker.role .. " : mise a quai impossible ("
                        .. tostring(stage_err) .. ")")
                else
                    local stocked = transport:awaitStock(link, dock, 1)

                    if not stocked then
                        -- Saying so distinguishes "the machine refused it" from
                        -- "it never arrived", which look identical otherwise
                        say("  " .. marker.role .. " : jamais arrive au quai")
                    else
                        for raw = 1, size do
                            if not occupied[raw] then
                                local moved_ok, answer = invoke(transposer,
                                    "transferItem", link.source, link.machine,
                                    1, dock, raw)

                                local moved = moved_ok
                                    and ((answer == true) or (tonumber(answer) or 0) > 0)

                                if moved then
                                    table.insert(accepted[raw], marker.role)
                                    -- Straight back to the dock, so the next
                                    -- slot is offered the same single item
                                    invoke(transposer, "transferItem",
                                        link.machine, link.source, 64, raw, dock)
                                end
                            end
                        end
                    end

                    -- Clearing the dock's configuration is what sends the
                    -- marker home: while it stands, AE2 keeps that item pinned
                    -- in the interface.
                    -- The link matters: docks are reserved per bench, and
                    -- releasing without one frees a key nobody holds. Every
                    -- dock stayed marked busy and the next two machines could
                    -- not stage a single marker.
                    transport:releaseDock(dock, link)
                end
            end

            say("  " .. size .. " slot(s)")
            for raw = 1, size do
                local driverIndex = raw - config.slot_offset

                if occupied[raw] then
                    say(string.format("  slot %-3d (driver %-3d) occupe par %s",
                        raw, driverIndex, occupied[raw]))
                elseif #accepted[raw] > 0 then
                    say(string.format("  slot %-3d (driver %-3d) accepte : %s",
                        raw, driverIndex, table.concat(accepted[raw], ", ")))
                else
                    say(string.format("  slot %-3d (driver %-3d) refuse tout"
                        .. " (sortie ?)", raw, driverIndex))
                end
            end
        end
    end

    -- The machines kept what was handed to them: a Genetic Transposer given a
    -- blank and a source went ahead and did the job, leaving its output behind.
    -- Anything left in a machine is invisible to the ME network, which is how a
    -- bee reported as missing ends up sitting two blocks away.
    say("")
    say("=== RANGEMENT ===")

    for _, name in ipairs(targets) do
        local machine = context.machines[name]
        local link = machine.link
        local size = transport:inventorySize(link) or 0
        local returned = 0

        for raw = 1, size do
            if transport:inspect(link, raw) then
                returned = returned + (transport:retrieve(link, raw, 64) or 0)
            end
        end

        local left = 0
        for raw = 1, size do
            if transport:inspect(link, raw) then left = left + 1 end
        end

        say(string.format("  %-20s %d item(s) rendu(s), %d slot(s) encore occupe(s)",
            name, returned, left))
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
