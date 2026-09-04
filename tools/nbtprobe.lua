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
-- The experiment needs two identical templates: one in the chest, one in the
-- network. It fingerprints the chest one, asks the network for it, and
-- fingerprints what turns up. Same hash means the nbt was honoured.
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
    -- -----------------------------------------------------------------------

    local subject = templates[1]
    if not subject.hash then
        say("Impossible d empreinter le premier template: rien a tester.")
        send()
        return
    end

    -- Any bench with an ME Interface will do; the database is shared by the
    -- whole computer, so the chest and the interface need not be neighbours.
    local link = config.machines.sampler
    local interface = transport:interfaceFor(link)

    say("=== EXPERIENCE ===")
    say("  template teste : slot " .. subject.slot
        .. ", empreinte " .. subject.hash:sub(1, 16) .. "...")
    say("  interface      : " .. tostring(config.interfaces[link.transposer]))
    say("")
    say("  Le meme template doit se trouver dans le reseau AE2, sinon le")
    say("  reseau n a rien a rendre et l experience ne prouve rien.")

    local inNetwork = 0
    for _, item in ipairs(transport:findAll({name = TEMPLATE}) or {}) do
        inNetwork = inNetwork + (tonumber(item.size) or 0)
    end
    say("  templates dans le reseau : " .. inNetwork)

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

    -- Re-photograph into DB_WANTED: the loop above may have overwritten it
    local wanted, wanted_err =
        transport:fingerprint(chestLink, subject.slot, DB_WANTED, true)

    if not wanted then
        say("Empreinte perdue: " .. tostring(wanted_err))
        send()
        return
    end

    local dock, dock_err = transport:reserveDock(link)
    if not dock then
        say("Aucun quai libre: " .. tostring(dock_err))
        send()
        return
    end

    say("")
    say("  quai reserve : " .. dock)

    -- Hand back whatever the dock held, and wait for AE2 to take it
    invoke(interface, "setInterfaceConfiguration", dock)
    local emptied, occupant = transport:awaitDockEmpty(link, dock)

    if not emptied then
        say("  le quai ne se vide pas (contient '" .. tostring(occupant) .. "')")
        transport:releaseDock(dock, link)
        send()
        return
    end

    -- The whole experiment is this call: a dock configured from a database
    -- entry that carries the nbt of a template we hold.
    local called, configured = invoke(interface, "setInterfaceConfiguration",
        dock, transport.database.address, DB_WANTED, 1)

    if not called or configured == false then
        say("  configuration du quai refusee: " .. tostring(configured))
        transport:releaseDock(dock, link)
        send()
        return
    end

    say("  quai configure depuis l empreinte, attente de la livraison...")

    local arrived = transport:awaitStock(link, dock, 1)

    if not arrived then
        say("")
        say("VERDICT : le reseau n a rien livre.")
        say("  Le filtre construit depuis le NBT ne correspond a aucun item.")
        say("  Autrement dit AE2 le prend au pied de la lettre et ne trouve")
        say("  pas ce template -- verifie qu il est bien dans le reseau.")
        transport:releaseDock(dock, link)
        send()
        return
    end

    local delivered = transport:fingerprint(link, dock, DB_ARRIVED, false)
    local stack = transport:inspect({transposer = link.transposer,
                                     machine = link.source}, dock)

    say("")
    say("  livre : " .. tostring(type(stack) == "table" and stack.label or "?"))
    say("  empreinte voulue : " .. wanted)
    say("  empreinte livree : " .. tostring(delivered))
    say("")

    if delivered == wanted then
        say("VERDICT : OUI. Le NBT est honore.")
        say("  Les templates peuvent vivre dans AE2, en nombre illimite, et le")
        say("  programme peut demander celui qu il veut. Le coffre devient une")
        say("  commodite au lieu d une obligation.")
    else
        say("VERDICT : NON. Le NBT est ignore.")
        say("  Le reseau a rendu un autre template. Les templates restent dans")
        say("  le coffre, designes par leur position, et l index sur disque est")
        say("  la seule facon de savoir lequel est lequel.")
    end

    -- Always give the template back, whatever the verdict
    transport:releaseDock(dock, link)
    transport:awaitDockEmpty(link, dock)

    say("")
    say("Quai libere, le template est rendu au reseau.")

    send()
end

main({...})
