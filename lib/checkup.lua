-- HiveMind installation checkup
--
-- Answers one question, once: "est-ce que je peux commencer ?"
--
-- The pieces existed already -- tools/discover for the sides, tools/probe for
-- the slots, the tank banner, the slot diagnostic -- but they lived in three
-- programs outside the menu and nothing joined them into a verdict. A player
-- who had just placed nine machines had no way of knowing whether they had
-- finished, and found out by watching a job fail on the fourth step.
--
-- Two rules the whole module obeys:
--
--   * it MOVES NOTHING. A checkup that empties a slot to see whether it can is
--     a checkup that breaks a working bench. Everything here is a read.
--   * a machine declared enabled = false is not built yet, and an unbuilt
--     machine is not a fault. It is reported as absent and nothing else.
--
-- The result is a list of findings, each carrying the gesture that fixes it,
-- in the same words the queue uses when it stops for one.

local screen = require("lib.screen")

local checkup = {}

checkup.OK = "ok"
checkup.PROBLEM = "probleme"
checkup.ABSENT = "absent"

--- Never let a component call abort the checkup
--- A missing block answers by throwing, and a diagnostic that dies on the first
--- missing block diagnoses nothing.
--- @return boolean ok
--- @return any result
local function attempt(fn, ...)
    if type(fn) ~= "function" then return false, "appel indisponible" end
    return pcall(fn, ...)
end

--- Machines whose tanks the player fills, named as the menu names them
--- @type table<string, string>
checkup.MACHINE_NAMES = {
    mutatron          = "Mutatron",
    breeding_apiary   = "Apiary de croisement",
    production_apiary = "Apiary de production",
    sampler           = "Sampler",
    genetic_transposer = "Genetic Transposer",
    imprinter         = "Imprinter",
    imprinter_2       = "Imprinter 2",
    replicator        = "Replicator",
    dna_extractor     = "DNA Extractor",
    protein_liquifier = "Protein Liquifier",
    mutagen_producer  = "Mutagen Producer",
}

--- Display name of a machine key
--- @param key string
--- @return string
function checkup.nameOf(key)
    return checkup.MACHINE_NAMES[key] or tostring(key)
end

--- The largest slot index a machine's configuration expects to reach
--- A slot map that runs past the end of the inventory is the signature of a
--- machine declared on the wrong face: every delivery lands nowhere, and the
--- failure reads as "la machine refuse cet objet".
--- @param link table
--- @param offset number
--- @return number|nil highest
local function highestSlot(link, offset)
    local slots = link and link.slots
    if type(slots) ~= "table" then return nil end

    local highest = nil

    local function consider(value)
        local index = tonumber(value)
        if not index then return end
        local resolved = index + offset
        if not highest or resolved > highest then highest = resolved end
    end

    for _, value in pairs(slots) do
        if type(value) == "table" then
            for _, nested in pairs(value) do consider(nested) end
        else
            consider(value)
        end
    end

    return highest
end

--- Check every declared machine answers on the face it was declared on
--- @param options table {config, transport}
--- @return table[] findings
function checkup.machines(options)
    local settings = options.config or {}
    local transport = options.transport
    local offset = tonumber(settings.slot_offset) or 0

    local findings = {}
    local declared = settings.machines or {}

    -- pairs() over a config table has no order, and a diagnostic whose lines
    -- move between two runs cannot be compared with the previous one
    local keys = {}
    for key in pairs(declared) do table.insert(keys, key) end
    table.sort(keys)

    for _, key in ipairs(keys) do
        local link = declared[key]
        local name = checkup.nameOf(key)

        if link.enabled == false or link.machine == nil then
            table.insert(findings, {
                name = name, status = checkup.ABSENT,
                detail = "pas encore posee, rien a verifier",
            })
        else
            local ok, size = attempt(function()
                return transport:inventorySize(link)
            end)

            if not ok or size == nil then
                table.insert(findings, {
                    name = name, status = checkup.PROBLEM,
                    detail = "aucun inventaire sur la face "
                        .. tostring(link.machine) .. " du transposer "
                        .. tostring(link.transposer),
                    gesture = "trouve sa vraie face avec tools/discover,"
                        .. " puis corrige lib/config.lua",
                })
            elseif size == 0 then
                table.insert(findings, {
                    name = name, status = checkup.PROBLEM,
                    detail = "la face " .. tostring(link.machine)
                        .. " repond, mais avec zero slot",
                    gesture = "il n y a pas de machine sur cette face: relance"
                        .. " tools/discover",
                })
            else
                local highest = highestSlot(link, offset)

                if highest and highest > size then
                    table.insert(findings, {
                        name = name, status = checkup.PROBLEM,
                        detail = "la config attend un slot " .. highest
                            .. " et la machine n en a que " .. size,
                        gesture = "relance tools/probe: la carte des slots"
                            .. " ne correspond pas a la machine",
                    })
                else
                    table.insert(findings, {
                        name = name, status = checkup.OK,
                        detail = screen.count(size, "slot") .. ", carte coherente",
                    })
                end
            end
        end
    end

    return findings
end

--- Check every bench that receives items has its own ME Interface declared
--- Approvisionner un quai ne marche que sur l'interface a laquelle ce quai
--- appartient. Configuring one while watching the other's dock makes the item
--- never arrive, and the failure reads as "la machine refuse cet objet" --
--- which sends the player to inspect a machine that is perfectly fine.
---
--- Read-only on purpose: a test delivery would move an item through a bench
--- that may be mid-job, and it answers the same question as comparing the
--- declared address with the ones the network actually exposes.
--- @param options table {config, transport}
--- @return table[] findings
function checkup.interfaces(options)
    local settings = options.config or {}
    local transport = options.transport
    local findings = {}

    -- Which transposers actually receive something. A bench the program only
    -- ever READS -- the Liquifier, the Mutagen Producer -- needs no interface,
    -- and demanding one there produced a permanent false alarm.
    local needs = {}
    for key, link in pairs(settings.machines or {}) do
        if link.enabled ~= false and link.machine ~= nil
           and link.source ~= nil and link.transposer ~= nil then
            needs[link.transposer] = needs[link.transposer] or {}
            table.insert(needs[link.transposer], checkup.nameOf(key))
        end
    end

    local benches = {}
    for bench in pairs(needs) do table.insert(benches, bench) end
    table.sort(benches, function(a, b) return tostring(a) < tostring(b) end)

    for _, bench in ipairs(benches) do
        table.sort(needs[bench])
        local served = table.concat(needs[bench], ", ")
        local wanted = (settings.interfaces or {})[bench]

        if not wanted then
            table.insert(findings, {
                name = "Banc " .. tostring(bench),
                status = checkup.PROBLEM,
                detail = "aucune interface declaree pour " .. served,
                gesture = "lance tools/discover et ajoute l adresse dans"
                    .. " config.interfaces",
            })
        else
            local found = nil
            for address in pairs((transport and transport.interfaces) or {}) do
                if type(address) == "string"
                   and address:sub(1, #tostring(bench)) == tostring(bench) then
                    found = address
                end
            end

            if found then
                table.insert(findings, {
                    name = "Banc " .. tostring(bench),
                    status = checkup.OK,
                    detail = "sert " .. served,
                })
            else
                table.insert(findings, {
                    name = "Banc " .. tostring(bench),
                    status = checkup.PROBLEM,
                    detail = "l interface " .. tostring(wanted)
                        .. " est declaree mais le programme ne la voit pas",
                    gesture = "verifie qu un Adapter touche cette ME Interface:"
                        .. " sans lui elle est invisible et chaque livraison a"
                        .. " " .. served .. " echoue",
                })
            end
        end
    end

    return findings
end

--- Check the consumables every genetics job spends
--- @param options table {transport, thresholds}
--- @return table[] findings
function checkup.supplies(options)
    local transport = options.transport
    local thresholds = options.thresholds or {}

    local watched = {
        {name = "gendustry:labware", label = "labware",
         floor = thresholds.labware or 16},
        {name = "gendustry:gene_sample_blank", label = "samples vierges",
         floor = thresholds.blank or 16},
    }

    local findings = {}

    for _, entry in ipairs(watched) do
        local ok, items = attempt(function()
            return transport:findAll({name = entry.name})
        end)

        if not ok or type(items) ~= "table" then
            table.insert(findings, {
                name = entry.label, status = checkup.PROBLEM,
                detail = "le reseau ME ne repond pas",
                gesture = "verifie que l ordinateur voit bien le reseau AE2",
            })
        else
            local count = 0
            for _, item in ipairs(items) do
                count = count + (tonumber(item.size) or 0)
            end

            if count == 0 then
                table.insert(findings, {
                    name = entry.label, status = checkup.PROBLEM,
                    detail = "aucun en stock",
                    gesture = "mets " .. entry.label .. " en autocraft AE2:"
                        .. " sans eux aucune machine de genetique ne produit",
                })
            elseif count < entry.floor then
                table.insert(findings, {
                    name = entry.label, status = checkup.PROBLEM,
                    detail = count .. " en stock, il en faut " .. entry.floor,
                    gesture = "relance l autocraft de " .. entry.label,
                })
            else
                table.insert(findings, {
                    name = entry.label, status = checkup.OK,
                    detail = count .. " en stock",
                })
            end
        end
    end

    return findings
end

--- Turn the fluid readings into findings
--- The readings themselves come from the caller: reading a tank needs the live
--- machines, and this module is meant to be testable without them.
--- @param readings table[] From hivemind.fluidLevels
--- @return table[] findings
function checkup.fluids(readings)
    local findings = {}

    for _, reading in ipairs(readings or {}) do
        if reading.empty then
            table.insert(findings, {
                name = reading.machine, status = checkup.PROBLEM,
                detail = "plus de " .. tostring(reading.fluid),
                gesture = "remplis le " .. reading.machine .. ": c est a toi,"
                    .. " le programme ne fait que lire cette cuve",
            })
        elseif reading.full then
            -- The one tank that fills instead of emptying. Reporting it as
            -- "out of ADN" would be exactly backwards.
            table.insert(findings, {
                name = reading.machine, status = checkup.PROBLEM,
                detail = string.format("cuve pleine (%d/%d)",
                    reading.amount or 0, reading.capacity or 0),
                gesture = "vide le " .. reading.machine
                    .. ": plein, il ne produit plus rien",
            })
        elseif reading.dry then
            -- A buffered tank is full most of the time and that is normal.
            -- Empty is the only state worth a word: whatever drinks from it
            -- is about to stop.
            table.insert(findings, {
                name = reading.machine, status = checkup.PROBLEM,
                detail = "plus de " .. tostring(reading.fluid),
                gesture = "alimente le " .. reading.machine
                    .. ": la chaine qui en boit va s arreter",
            })
        elseif reading.low then
            table.insert(findings, {
                name = reading.machine, status = checkup.PROBLEM,
                detail = string.format("%s bas (%d/%d)",
                    tostring(reading.fluid), reading.amount or 0,
                    reading.capacity or 0),
                gesture = "recharge le " .. reading.machine
                    .. " avant de lancer une longue file",
            })
        else
            local amount = reading.amount or 0
            local capacity = tonumber(reading.capacity) or 0

            -- "mutagene : 10000" leaves the reader asking "out of what".
            local level = capacity > 0
                and string.format("%d/%d", amount, capacity)
                or tostring(amount)

            local detail = tostring(reading.fluid) .. " : " .. level

            -- A tank that FILLS is empty when the machine has nothing waiting,
            -- which is the normal state. A bare zero on a checkup screen reads
            -- as a fault, so it says which zero this is.
            if reading.fills and amount == 0 then
                detail = detail .. "  (rien a transferer, c est normal)"
            end

            table.insert(findings, {
                name = reading.machine, status = checkup.OK, detail = detail,
            })
        end
    end

    return findings
end

--- The whole checkup, in the order a player fixes things
--- Power first: everything else reads as broken on a network that is off, and
--- sending someone to check nine faces when the answer is a missing cable is
--- the worst thing a diagnostic can do.
--- @param options table {config, transport, fluids}
--- @return table report {sections, ok, gestures, counts}
function checkup.run(options)
    options = options or {}

    local sections = {}
    local transport = options.transport

    -- ---------------------------------------------------------------
    local network = {}

    local ok, online, reason = attempt(function()
        return transport:isOnline()
    end)

    if not ok then
        table.insert(network, {
            name = "Reseau AE2", status = checkup.PROBLEM,
            detail = "interface ME injoignable",
            gesture = "verifie qu un Adapter touche la ME Interface",
        })
    elseif online == false then
        table.insert(network, {
            name = "Reseau AE2", status = checkup.PROBLEM,
            detail = tostring(reason or "hors tension"),
            gesture = "remets le reseau AE2 sous tension",
        })
    else
        local counted, items = attempt(function()
            return transport:networkItemCount()
        end)
        local total = counted and tonumber(items) or 0

        if total == 0 then
            table.insert(network, {
                name = "Reseau AE2", status = checkup.PROBLEM,
                detail = "sous tension mais vide",
                gesture = "l interface est sans doute sur un sous-reseau sans"
                    .. " stockage: verifie le cablage",
            })
        else
            table.insert(network, {
                name = "Reseau AE2", status = checkup.OK,
                detail = screen.count(total, "objet") .. " "
                    .. screen.plural(total, "visible"),
            })
        end
    end

    table.insert(sections, {title = "RESEAU", findings = network})

    -- ---------------------------------------------------------------
    table.insert(sections, {title = "MACHINES",
                            findings = checkup.machines(options)})
    table.insert(sections, {title = "INTERFACES ME",
                            findings = checkup.interfaces(options)})
    table.insert(sections, {title = "CUVES",
                            findings = checkup.fluids(options.fluids)})
    table.insert(sections, {title = "CONSOMMABLES",
                            findings = checkup.supplies(options)})

    -- ---------------------------------------------------------------
    local counts = {ok = 0, problem = 0, absent = 0}
    local gestures = {}

    for _, section in ipairs(sections) do
        for _, finding in ipairs(section.findings) do
            if finding.status == checkup.OK then
                counts.ok = counts.ok + 1
            elseif finding.status == checkup.ABSENT then
                counts.absent = counts.absent + 1
            else
                counts.problem = counts.problem + 1
                if finding.gesture then
                    table.insert(gestures, finding.name .. " : " .. finding.gesture)
                end
            end
        end
    end

    return {
        sections = sections,
        counts = counts,
        gestures = gestures,
        -- An unbuilt machine is not a fault, so it does not hold the verdict
        ok = counts.problem == 0,
    }
end

return checkup
