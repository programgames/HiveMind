-- HiveMind NBT experiment
--
-- One question, one answer: can the program ask AE2 for a SPECIFIC template?
--
-- Every Genetic Template shares an item id and a label. Asking the network for
-- "gendustry:gene_template" gets an arbitrary one, which on a Replicator would
-- print an arbitrary species. AE2 itself distinguishes them -- it stores items
-- by id, damage AND nbt -- but the OpenComputers bridge only shows the name.
--
-- The idea: do not start from the network. Photograph a template we physically
-- hold, in a chest, with transposer.store() -- which captures the whole stack,
-- nbt included, into a Database upgrade. Then configure an interface dock from
-- THAT database entry. If AE2 honours the nbt, the template that arrives is the
-- one we asked for.
--
-- One template does not settle it. With a hundred templates in the network and
-- one of them filled, a bridge that ignored the nbt would hand back an
-- arbitrary one -- and if that happened to be the filled one, the test would
-- say "honoured" while nothing was. So EVERY template in the chest is asked for
-- in turn and each delivery checked against its own request. Two different
-- contents each coming back correctly cannot be luck.
--
-- It also lists every template in the chest with its fingerprint, which is
-- useful on its own: that is how "slot 3 = complete Robotic template" becomes
-- something the program can state rather than assume.
--
-- Usage:
--   nbtprobe            list the chest, move nothing
--   nbtprobe --yes      run the experiment
--   nbtprobe --upload   publish the result

local component = require("component")

local TEMPLATE = "gendustry:gene_template"

-- Database slots for the experiment. Docks use slots 1 and 2 (see stage()), so
-- these start above that and stay inside a tier 1 database's nine.
local DB_WANTED, DB_ARRIVED = 4, 5

local report = {}

local function say(text)
    text = text or ""
    table.insert(report, text)
    print(text)
end

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
        say("hivemind.lua introuvable: " .. tostring(hivemind))
        return
    end

    local config = require("lib.config")
    local context = hivemind.bootstrap()
    local transport = context.transport

    say("HiveMind - experience NBT")
    say("version " .. tostring(hivemind.VERSION))
    say("")

    local function send()
        if not doUpload then return end
        if not component.isAvailable("internet") then
            say("Pas de carte Internet: le resultat reste a l ecran.")
            return
        end

        local ok_publish, publish = pcall(require, "lib.publish")
        if not ok_publish then
            print("lib/publish.lua absent: relance tools/hminstall.")
            return
        end

        publish.report(table.concat(report, "\n") .. "\n", config.report_mailbox)
    end

    -- -----------------------------------------------------------------------
    -- What the chest holds
    -- -----------------------------------------------------------------------

    local chest = config.template_chest
    if not chest or not chest.transposer then
        say("Aucun coffre a templates declare dans lib/config.lua.")
        send()
        return
    end

    local chestLink = {transposer = chest.transposer, machine = chest.side}

    local size = transport:inventorySize(chestLink)
    if not size then
        say("Le coffre est injoignable: le transposer " .. tostring(chest.transposer))
        say("ne voit rien sur la face " .. tostring(chest.side) .. ".")
        send()
        return
    end

    say("=== COFFRE A TEMPLATES ===")
    say("  transposer " .. tostring(chest.transposer)
        .. ", face " .. tostring(chest.side) .. ", " .. size .. " slots")
    say("")

    local templates = {}
    for slot = 1, size do
        local stack = transport:inspect(chestLink, slot)
        if type(stack) == "table" and stack.name == TEMPLATE then
            table.insert(templates, {slot = slot, label = stack.label})
        end
    end

    if #templates == 0 then
        say("Aucun template dans le coffre.")
        say("Pose-y celui de l experience avant de relancer.")
        send()
        return
    end

    -- Fingerprinting every one of them is the point of the chest: two templates
    -- that look identical get two different hashes, and that is what lets an
    -- index say which slot holds what.
    for _, entry in ipairs(templates) do
        local hash, err = transport:fingerprint(chestLink, entry.slot, DB_WANTED, true)
        entry.hash = hash

        say(string.format("  slot %-3d %-20s %s", entry.slot,
            tostring(entry.label), hash and hash:sub(1, 16) .. "..."
                or ("EMPREINTE IMPOSSIBLE: " .. tostring(err))))
    end

    say("")

    if #templates > 1 then
        local distinct = {}
        for _, entry in ipairs(templates) do
            if entry.hash then distinct[entry.hash] = true end
        end

        local count = 0
        for _ in pairs(distinct) do count = count + 1 end

        say("  " .. count .. " empreinte(s) distincte(s) pour "
            .. #templates .. " template(s).")
        say("  (deux templates au meme contenu partagent une empreinte)")
        say("")
    end

    -- -----------------------------------------------------------------------
    -- The experiment
    --
    -- One template proves almost nothing. With 128 templates in the network and
    -- one of them filled, a bridge that ignored the nbt entirely would hand
    -- back an arbitrary one -- and if it happens to hand back the filled one,
    -- the test says "honoured" while nothing was honoured at all.
    --
    -- So every template in the chest is asked for in turn, and each delivery is
    -- checked against ITS OWN request. Two templates with different contents
    -- that each come back correctly cannot be a coincidence: a blind bridge
    -- would answer both with the same item.
    -- -----------------------------------------------------------------------

    -- Any bench with an ME Interface will do; the database is shared by the
    -- whole computer, so the chest and the interface need not be neighbours.
    local link = config.machines.sampler
    local interface = transport:interfaceFor(link)

    local distinct = {}
    for _, entry in ipairs(templates) do
        if entry.hash then distinct[entry.hash] = true end
    end

    local variety = 0
    for _ in pairs(distinct) do variety = variety + 1 end

    say("=== EXPERIENCE ===")
    say("  interface : " .. tostring(config.interfaces[link.transposer]))
    say("  a tester  : " .. #templates .. " template(s), "
        .. variety .. " contenu(s) different(s)")

    if variety < 2 then
        say("")
        say("  ATTENTION: un seul contenu distinct dans le coffre.")
        say("  Le test ne pourra pas etre concluant: si le reseau rendait un")
        say("  template au hasard, il pourrait tomber juste par chance.")
        say("  Mets-en un DEUXIEME, de contenu different (un vierge suffit).")
    end

    local inNetwork = 0
    for _, item in ipairs(transport:findAll({name = TEMPLATE}) or {}) do
        inNetwork = inNetwork + (tonumber(item.size) or 0)
    end
    say("  reseau    : " .. inNetwork .. " template(s)")

    if inNetwork == 0 then
        say("")
        say("Aucun template dans le reseau: rien a demander.")
        send()
        return
    end

    if not commit then
        say("")
        say("Rien n a ete deplace. Relance avec --yes pour tenter la demande.")
        say("Un template sortira du reseau et y sera rendu ensuite.")
        send()
        return
    end

    --- Ask the network for one precise template and see what turns up
    --- @param entry table {slot, hash}
    --- @return string verdict
    local function askFor(entry)
        -- Re-photograph: the previous round overwrote this database slot
        local wanted, wanted_err =
            transport:fingerprint(chestLink, entry.slot, DB_WANTED, true)

        if not wanted then return "empreinte perdue: " .. tostring(wanted_err) end

        local dock, dock_err = transport:reserveDock(link)
        if not dock then return "aucun quai libre: " .. tostring(dock_err) end

        local verdict

        -- Hand back whatever the dock held, and wait for AE2 to take it
        invoke(interface, "setInterfaceConfiguration", dock)
        local emptied, occupant = transport:awaitDockEmpty(link, dock)

        if not emptied then
            verdict = "le quai ne se vide pas ('" .. tostring(occupant) .. "')"
        else
            -- The whole experiment is this call: a dock configured from a
            -- database entry that carries the nbt of a template we hold.
            local called, configured = invoke(interface,
                "setInterfaceConfiguration",
                dock, transport.database.address, DB_WANTED, 1)

            if not called or configured == false then
                verdict = "quai refuse: " .. tostring(configured)
            elseif not transport:awaitStock(link, dock, 1) then
                verdict = "RIEN LIVRE"
            else
                local delivered =
                    transport:fingerprint(link, dock, DB_ARRIVED, false)

                if delivered == wanted then
                    verdict = "EXACT"
                else
                    verdict = "AUTRE (" .. tostring(delivered
                        and delivered:sub(1, 16) or "?") .. "...)"
                end
            end
        end

        -- Always give the template back, whatever happened
        transport:releaseDock(dock, link)
        transport:awaitDockEmpty(link, dock)

        return verdict
    end

    say("")

    local exact, total = 0, 0
    for _, entry in ipairs(templates) do
        if entry.hash then
            total = total + 1
            local verdict = askFor(entry)

            say(string.format("  slot %-3d %s...  ->  %s",
                entry.slot, entry.hash:sub(1, 16), verdict))

            if verdict == "EXACT" then exact = exact + 1 end
        end
    end

    say("")

    if exact == total and total > 0 and variety >= 2 then
        say("VERDICT : OUI, le NBT est honore.")
        say("  " .. total .. " demandes, " .. total .. " livraisons exactes, sur "
            .. variety .. " contenus differents.")
        say("  Un reseau qui ignorerait le NBT aurait rendu le meme objet aux")
        say("  deux demandes: ce n est pas un hasard.")
        say("  Les templates peuvent vivre dans AE2, en nombre illimite.")
    elseif exact == total and total > 0 then
        say("RESULTAT : livraison exacte, mais NON CONCLUANT.")
        say("  Un seul contenu teste. Avec " .. inNetwork .. " templates dans le")
        say("  reseau, un tirage au hasard pouvait tomber juste.")
        say("  Ajoute un template de contenu different dans le coffre et")
        say("  relance: c est ce deuxieme essai qui tranche.")
    else
        say("VERDICT : NON, le NBT n est pas honore.")
        say("  " .. exact .. " livraison(s) exacte(s) sur " .. total .. ".")
        say("  Les templates restent dans le coffre, designes par leur")
        say("  position, et l index sur disque dit lequel est lequel.")
    end

    say("")
    say("Quais liberes, les templates sont rendus au reseau.")

    send()
end

main({...})
