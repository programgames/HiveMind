-- HiveMind transport layer
--
-- Gets items from the ME network into a machine slot, and back.
--
-- The awkward part is that AE2 cannot hand an item to a Transposer directly.
-- The chain is:
--
--   1. me.store(filter, database, slot)          copy the exact stack, NBT and
--                                                all, into a Database upgrade
--   2. me.setInterfaceConfiguration(dock, ...)   ask the interface to physically
--                                                stock that item
--   3. wait for it to appear in the interface
--   4. transposer.transferItem(...)              move it into the machine
--   5. release the dock
--
-- Step 1 is what makes gene samples addressable at all: they share one item id
-- and differ only by NBT, which no plain filter can express. Their display
-- label does distinguish them ("Bee Sample - Species: Cultivated"), so a label
-- filter finds them and the database pins the exact stack.
--
-- The interface has nine configuration slots; they are treated as a pool of
-- loading docks, reserved and released, so two concurrent requests cannot
-- overwrite each other's staging.

local transport = {}

--- Real seconds since the computer started
--- os.time() on OpenOS returns Minecraft world time, which runs about 72 times
--- faster than real time: a twenty second timeout expired in under half a real
--- second, long before AE2 could react. computer.uptime() is the real clock.
--- @return function clock
local function realClock()
    local ok, computer = pcall(require, "computer")
    if ok and type(computer) == "table" and computer.uptime then
        return computer.uptime
    end
    return os.clock
end

local Transport = {}
Transport.__index = Transport

--- Create a transport layer
--- @param options table {me, database, transposers, config, sleep, clock}
---   me          me_interface component
---   database    database component
---   transposers array of transposer components (index 1 is the default)
---   sleep       injectable wait, so tests do not actually sleep
--- @return table transport
function transport.new(options)
    options = options or {}

    local settings = options.config or {}

    return setmetatable({
        me = options.me,
        -- One ME Interface per bench, keyed by transposer index. Two benches
        -- means two interface blocks, and configuring one while watching the
        -- other's dock means the item never arrives -- which is exactly what a
        -- whole probe run reported, fifteen times over.
        interfaces = options.interfaces or {},
        -- Proxies keyed by their own address, so a machine can name the
        -- transposer it sits on instead of its position in a list
        byAddress = options.byAddress or {},
        database = options.database,
        transposers = options.transposers or {},
        docks = settings.docks or {1, 2, 3, 4, 5, 6},
        stockTimeout = settings.stock_timeout_seconds or 20,
        pollInterval = settings.poll_interval_seconds or 0.5,
        reserved = {},
        sleep = options.sleep or function(seconds)
            local ok, os_sleep = pcall(function() return os.sleep end)
            if ok and os_sleep then os_sleep(seconds) end
        end,
        clock = options.clock or realClock(),
    }, Transport)
end

--- Call a component method, never letting it abort the caller
--- @return boolean ok
--- @return any result
local function invoke(component, method, ...)
    if not component then return false, "composant absent" end

    local target = component[method]
    if target == nil then return false, "methode absente: " .. method end

    return pcall(target, ...)
end

--- Interpret what transferItem answered
--- The in-game documentation of this build says ":boolean", while other
--- versions return the amount actually moved. Both are accepted; nil, false and
--- zero all mean nothing was transferred.
--- @param value any Raw return value
--- @param expected number Count that was requested
--- @return number moved
local function movedCount(value, expected)
    if value == true then return expected end

    local amount = tonumber(value)
    if amount then return amount end

    return 0
end

--- The transposer serving a link
--- @param index number|nil
--- @return table|nil transposer
--- @return string|nil error
function Transport:transposerFor(index)
    -- An address prefix, not a position. Adding one transposer to the network
    -- renumbered every other one and quietly aimed each machine at the wrong
    -- neighbour; an address survives any rearrangement.
    if type(index) == "string" then
        for address, proxy in pairs(self.byAddress or {}) do
            if address:sub(1, #index) == index then return proxy end
        end
        return nil, "transposer introuvable: " .. index
    end

    local transposer = self.transposers[index or 1] or self.transposers[1]
    if not transposer then return nil, "aucun transposer configure" end
    return transposer
end

--- Find one item in the ME network
--- Samples are matched on their label, which is the only thing distinguishing
--- two stacks of the same item id.
--- @param spec table {name = ..., label = ...}
--- @return table|nil entry
--- @return string|nil error
function Transport:find(spec)
    if type(spec) ~= "table" then return nil, "specification invalide" end

    local filter = {}
    if spec.name then filter.name = spec.name end
    if spec.damage then filter.damage = spec.damage end

    local ok, items = invoke(self.me, "getItemsInNetwork", filter)
    if not ok then
        -- Older signatures reject a filter; fall back to the full listing
        ok, items = invoke(self.me, "getItemsInNetwork")
    end

    if not ok or type(items) ~= "table" then
        return nil, "reseau ME injoignable: " .. tostring(items)
    end

    for _, item in pairs(items) do
        if type(item) == "table" then
            local name_ok = not spec.name or item.name == spec.name
            local label_ok = not spec.label or item.label == spec.label
            local size = tonumber(item.size) or 0

            if name_ok and label_ok and size > 0 then
                return item
            end
        end
    end

    return nil, "introuvable dans le reseau: " .. (spec.label or spec.name or "?")
end

--- Every network item matching a specification
--- Used to offer the player a list instead of a blank field: nobody should have
--- to remember the exact label of a bee to breed it.
--- @param spec table {name = ..., labelContains = ...}
--- @return table[] entries Sorted by label
function Transport:findAll(spec)
    spec = spec or {}

    local filter = {}
    if spec.name then filter.name = spec.name end

    local ok, items = invoke(self.me, "getItemsInNetwork", filter)
    if not ok then
        ok, items = invoke(self.me, "getItemsInNetwork")
    end

    if not ok or type(items) ~= "table" then return {} end

    local matching = {}

    for _, item in pairs(items) do
        if type(item) == "table" and (tonumber(item.size) or 0) > 0 then
            local name_ok = not spec.name or item.name == spec.name
            local label_ok = true

            -- find() has always honoured an exact label; findAll ignored it,
            -- so a caller counting one species counted the whole item type.
            if spec.label then label_ok = item.label == spec.label end

            if spec.labelContains and item.label then
                label_ok = item.label:lower():find(spec.labelContains:lower(), 1, true) ~= nil
            elseif spec.labelContains then
                label_ok = false
            end

            if name_ok and label_ok then table.insert(matching, item) end
        end
    end

    table.sort(matching, function(a, b)
        return tostring(a.label or a.name) < tostring(b.label or b.name)
    end)

    return matching
end

--- Reserve a loading dock
--- @return number|nil dock
--- @return string|nil error
--- The ME Interface that serves a machine
--- Item lookups and power readings work from any interface on the network, but
--- stocking a dock only works on the interface that dock belongs to.
--- @param link table|nil
--- @return table|nil proxy
function Transport:interfaceFor(link)
    local key = link and link.transposer
    if not key then return self.me end

    if self.interfaces[key] then return self.interfaces[key] end

    -- Declared by address prefix, same as the transposers
    if type(key) == "string" then
        for address, proxy in pairs(self.interfaces) do
            if type(address) == "string"
               and address:sub(1, #key) == key then return proxy end
        end
    end

    return self.me
end

--- Docks are per interface: two benches both have a dock 1
--- @param link table|nil
--- @param dock number
--- @return string
local function dockKey(link, dock)
    return tostring(link and link.transposer or 0) .. "/" .. tostring(dock)
end

function Transport:reserveDock(link)
    for _, dock in ipairs(self.docks) do
        local key = dockKey(link, dock)
        if not self.reserved[key] then
            self.reserved[key] = true
            return dock
        end
    end

    return nil, "tous les quais de chargement sont occupes"
end

--- Give a dock back, clearing the interface configuration
--- @param dock number
function Transport:releaseDock(dock, link)
    if not dock then return end

    -- Clearing matters: a dock left configured keeps pulling that item out of
    -- the network and holding it in the interface forever.
    invoke(self:interfaceFor(link), "setInterfaceConfiguration", dock)
    self.reserved[dockKey(link, dock)] = nil
end

--- Wait until a dock holds nothing
--- Clearing an interface configuration does not instantly hand the stocked item
--- back to the network; AE2 takes a few ticks. Reusing the dock before then
--- leaves the previous item sitting there, and a size check cannot tell the
--- difference between a leftover and what was asked for.
--- @param link table Machine link, for the source side
--- @param dock number
--- @return boolean emptied
--- @return string|nil occupant
function Transport:awaitDockEmpty(link, dock)
    local transposer = self:transposerFor(link.transposer)
    if not transposer then return false end

    local deadline = self.clock() + self.stockTimeout
    local occupant = nil

    repeat
        local ok, stack = invoke(transposer, "getStackInSlot", link.source, dock)
        if not ok or type(stack) ~= "table" then return true end

        occupant = stack.label or stack.name
        self.sleep(self.pollInterval)
    until self.clock() > deadline

    return false, occupant
end

--- Stage an item in the interface so a transposer can pick it up
--- @param spec table {name, label}
--- @param count number|nil
--- @param link table Machine link, needed to watch the dock
--- @return number|nil dock
--- @return string|nil error
function Transport:stage(spec, count, link)
    count = count or 1

    local entry, find_err = self:find(spec)
    if not entry then return nil, find_err end

    local dock, dock_err = self:reserveDock(link)
    if not dock then return nil, dock_err end

    local interface = self:interfaceFor(link)

    -- Hand back whatever the previous operation left, and wait for it to go
    if link then
        invoke(interface, "setInterfaceConfiguration", dock)

        local emptied, occupant = self:awaitDockEmpty(link, dock)
        if not emptied then
            self:releaseDock(dock, link)
            return nil, "le quai " .. dock .. " ne se vide pas (contient encore '"
                .. tostring(occupant) .. "')"
        end
    end

    -- Drop any previous entry: a stale one would be stocked instead, and the
    -- interface would faithfully deliver the wrong item.
    invoke(self.database, "clear", dock)

    -- Pin the exact stack, NBT included, into the database.
    -- invoke() answers (pcall succeeded, method result); reading only the first
    -- treats a store() that returned false as a success, which is how a stale
    -- database entry once had AE2 deliver a Labware labelled as a princess.
    local called, stored = invoke(interface, "store",
        {name = entry.name, label = entry.label}, self.database.address, dock, 1)

    if not called then
        self:releaseDock(dock, link)
        return nil, "store() injoignable: " .. tostring(stored)
    end

    -- Trust nothing: read the entry back and check it is what was asked for
    local read_ok, written = invoke(self.database, "get", dock)
    local writtenLabel = (read_ok and type(written) == "table")
        and (written.label or written.name) or nil

    if not writtenLabel then
        self:releaseDock(dock, link)
        return nil, "store() n'a rien ecrit dans la database pour '"
            .. tostring(spec.label or spec.name) .. "'"
    end

    if spec.label and writtenLabel ~= spec.label then
        self:releaseDock(dock, link)
        return nil, "la database contient '" .. writtenLabel
            .. "' au lieu de '" .. spec.label .. "' (filtre AE2 inadapte ?)"
    end

    local config_called, configured = invoke(interface, "setInterfaceConfiguration",
        dock, self.database.address, dock, count)

    if not config_called or configured == false then
        self:releaseDock(dock, link)
        return nil, "configuration du quai impossible: " .. tostring(configured)
    end

    return dock
end

--- How many pages the Database upgrade holds
--- It decides how many templates can be addressed at once, because a template
--- can only be requested from a page that already holds its photograph -- and
--- photographing needs the item in hand, which is exactly what we no longer
--- have once it is in the network. Tier 1 holds nine, tier 3 eighty-one.
--- @return number pages
function Transport:databaseCapacity()
    if self.databasePages then return self.databasePages end

    -- No method reports it, so it is measured: a valid empty page answers nil,
    -- an invalid one raises.
    local pages = 0
    for page = 1, 81 do
        local ok = invoke(self.database, "get", page)
        if not ok then break end
        pages = page
    end

    self.databasePages = pages
    return pages
end

--- A page nothing is using
--- Docks write to the page matching their own number, and the library keeps a
--- scratch page, so those are stepped over rather than fought with.
--- @param reserved table<number, boolean>|nil Extra pages to leave alone
--- @return number|nil page
function Transport:freePage(reserved)
    reserved = reserved or {}

    local capacity = self:databaseCapacity()

    -- Docks use the page matching their own number: see stage()
    for _, dock in ipairs(self.docks or {}) do reserved[dock] = true end

    for page = 1, capacity do
        if not reserved[page] then
            local ok, entry = invoke(self.database, "get", page)
            if ok and type(entry) ~= "table" then return page end
        end
    end

    return nil
end

--- Find the database page holding a fingerprint
--- The page number is a hint that can go stale -- pages get overwritten -- but
--- the fingerprint identifies the item itself. Asking the database which page
--- holds a hash survives any reshuffling; only losing the photograph does not.
--- @param hash string
--- @return number|nil page
function Transport:pageFor(hash)
    if type(hash) ~= "string" or hash == "" then return nil end

    local ok, page = invoke(self.database, "indexOf", hash)
    if ok and tonumber(page) then return tonumber(page) end

    return nil
end

--- Ask the network for one EXACT item, named by a database page
---
--- This is what stage() cannot do. stage() starts from a filter, which can only
--- name an item id, so AE2 hands over an arbitrary match -- and for templates,
--- every template matches. Starting from a page that already holds the item's
--- full nbt asks for that one item and no other.
---
--- Proven in game on 2026-09-04, with a control: two templates of different
--- contents, two requests, two exact deliveries.
--- @param page number Database page holding the photograph
--- @param link table Machine link, for the interface and the dock side
--- @param count number|nil
--- @return number|nil dock
--- @return string|nil error
function Transport:stageFromDatabase(page, link, count)
    count = count or 1

    if not tonumber(page) then return nil, "page de database invalide" end

    local entry_ok, entry = invoke(self.database, "get", page)
    if not entry_ok or type(entry) ~= "table" then
        return nil, "la page " .. tostring(page) .. " de la database est vide"
    end

    local dock, dock_err = self:reserveDock(link)
    if not dock then return nil, dock_err end

    local interface = self:interfaceFor(link)

    -- Hand back whatever the previous operation left, and wait for it to go
    invoke(interface, "setInterfaceConfiguration", dock)

    local emptied, occupant = self:awaitDockEmpty(link, dock)
    if not emptied then
        self:releaseDock(dock, link)
        return nil, "le quai " .. dock .. " ne se vide pas (contient encore '"
            .. tostring(occupant) .. "')"
    end

    local called, configured = invoke(interface, "setInterfaceConfiguration",
        dock, self.database.address, page, count)

    if not called or configured == false then
        self:releaseDock(dock, link)
        return nil, "configuration du quai impossible: " .. tostring(configured)
    end

    return dock
end

--- Wait until the interface physically holds the staged item
--- Identity is checked, not just quantity: a leftover from a previous operation
--- satisfies a size check while being an entirely different item, which is how
--- a Labware once got fed to the Mutatron as a princess.
--- @param link table Machine link, giving the transposer and the source side
--- @param dock number
--- @param count number
--- @param expectedLabel string|nil Label the dock must end up holding
--- @return boolean ok
--- @return string|nil error
function Transport:awaitStock(link, dock, count, expectedLabel)
    local transposer, err = self:transposerFor(link.transposer)
    if not transposer then return false, err end

    local deadline = self.clock() + self.stockTimeout
    local seen = nil

    repeat
        local ok, stack = invoke(transposer, "getStackInSlot", link.source, dock)

        if ok and type(stack) == "table" then
            seen = stack.label or stack.name
            local enough = (tonumber(stack.size) or 0) >= count
            local right = not expectedLabel or seen == expectedLabel

            if enough and right then return true end
        end

        self.sleep(self.pollInterval)
    until self.clock() > deadline

    if seen and expectedLabel and seen ~= expectedLabel then
        return false, "le quai contient '" .. seen .. "' au lieu de '"
            .. expectedLabel .. "'"
    end

    return false, "AE2 n'a pas fourni l'item dans le delai imparti"
end

--- Put an item from the network into a machine slot
--- @param spec table {name, label}
--- @param link table Machine link from the configuration
--- @param slot number Destination slot in the machine
--- @param count number|nil
--- @return boolean ok
--- @return string|nil error
function Transport:deliver(spec, link, slot, count)
    count = count or 1

    local transposer, transposer_err = self:transposerFor(link.transposer)
    if not transposer then return false, transposer_err end

    local dock, stage_err = self:stage(spec, count, link)
    if not dock then return false, stage_err end

    local stocked, stock_err = self:awaitStock(link, dock, count, spec.label)
    if not stocked then
        self:releaseDock(dock, link)
        return false, stock_err
    end

    -- Check what actually landed on the dock. AE2 stocks whatever its filter
    -- matched, which is not always what was asked for, and a machine silently
    -- refusing the wrong item looks exactly like a machine refusing the right
    -- one.
    local staged_ok, staged = invoke(transposer, "getStackInSlot", link.source, dock)
    local stagedLabel = (staged_ok and type(staged) == "table")
        and (staged.label or staged.name) or nil

    if spec.label and stagedLabel and stagedLabel ~= spec.label then
        self:releaseDock(dock, link)
        return false, "le quai contient '" .. stagedLabel
            .. "' au lieu de '" .. spec.label .. "'"
    end

    local ok, answer = invoke(transposer, "transferItem",
        link.source, link.machine, count, dock, slot)

    if not ok then
        self:releaseDock(dock, link)
        return false, "transfert impossible: " .. tostring(answer)
    end

    local moved = movedCount(answer, count)

    if moved < count then
        -- Say what was refused and what the destination already held: a machine
        -- rejecting an insertion gives no reason of its own.
        local occupant_ok, occupant = invoke(transposer, "getStackInSlot", link.machine, slot)
        local occupied = (occupant_ok and type(occupant) == "table")
            and (occupant.label or occupant.name) or "vide"

        self:releaseDock(dock, link)

        return false, string.format(
            "la machine refuse '%s' dans le slot %d (ce slot contient: %s)",
            stagedLabel or spec.label or "?", slot, occupied)
    end

    self:releaseDock(dock, link)
    return true
end

--- Take an item out of a machine and hand it back to the network
--- The interface accepts anything pushed into it, so no dock is needed here.
--- @param link table Machine link
--- @param slot number Source slot in the machine
--- @param count number|nil
--- @return number moved
--- @return string|nil error
--- Deliver one EXACT item into a machine slot, checked by fingerprint
---
--- deliver() checks the label, which is the only thing it can check and is
--- worthless here: every Genetic Template carries the same one. So what lands
--- in the interface is fingerprinted and compared to what was asked for, and a
--- mismatch refuses rather than writing unknown genes onto a bee.
--- @param page number Database slot holding the item's description
--- @param expected string Fingerprint the delivery must match
--- @param link table Machine link
--- @param slot number Machine slot to fill
--- @param scratch number Database slot to fingerprint the arrival through
--- @return boolean ok
--- @return string|nil error
function Transport:deliverExact(page, expected, link, slot, scratch)
    local transposer, transposer_err = self:transposerFor(link.transposer)
    if not transposer then return false, transposer_err end

    local dock, stage_err = self:stageFromDatabase(page, link, 1)
    if not dock then return false, stage_err end

    local stocked, stock_err = self:awaitStock(link, dock, 1)
    if not stocked then
        self:releaseDock(dock, link)
        return false, stock_err
    end

    if expected then
        local arrived = self:fingerprint(link, dock, scratch or page, false)

        if arrived ~= expected then
            self:releaseDock(dock, link)
            return false, "le reseau a livre un autre objet ("
                .. tostring(arrived and arrived:sub(1, 12) or "illisible")
                .. "... au lieu de " .. expected:sub(1, 12) .. "...)"
        end
    end

    local ok, answer = invoke(transposer, "transferItem",
        link.source, link.machine, 1, dock, slot)

    if not ok then
        self:releaseDock(dock, link)
        return false, "transfert impossible: " .. tostring(answer)
    end

    if movedCount(answer, 1) < 1 then
        local occupant_ok, occupant =
            invoke(transposer, "getStackInSlot", link.machine, slot)
        local occupied = (occupant_ok and type(occupant) == "table")
            and (occupant.label or occupant.name) or "vide"

        self:releaseDock(dock, link)
        return false, string.format(
            "la machine refuse l objet dans le slot %d (ce slot contient: %s)",
            slot, occupied)
    end

    self:releaseDock(dock, link)
    return true
end

function Transport:retrieve(link, slot, count)
    local transposer, err = self:transposerFor(link.transposer)
    if not transposer then return 0, err end

    local requested = count or 64
    local ok, answer = invoke(transposer, "transferItem",
        link.machine, link.source, requested, slot)

    if not ok then return 0, "retrait impossible: " .. tostring(answer) end

    return movedCount(answer, requested)
end

--- Get an item OUT of a slot, by any door that opens
---
--- retrieve() knows one destination: the ME Interface. That is right for
--- everything the program normally does -- a harvested bee belongs in the
--- network, not in a chest. But it makes one failure unreadable: when the
--- interface refuses (its nine slots are loading docks, and a dock still
--- carrying a configuration turns an ordinary item away), the caller concludes
--- that the MACHINE is holding on, which is a completely different problem with
--- a completely different fix.
---
--- So this one tries the network first, then every other inventory the same
--- transposer touches. The attempt is the measurement: if any door opens, the
--- slot was never stuck.
---
--- Machine faces are excluded by the caller. Emptying a drone into the
--- Mutatron's input would be worse than leaving it where it was.
--- @param link table Machine link
--- @param slot number Slot in the machine
--- @param count number|nil
--- @param avoid table|nil Set of sides never to use, keyed by side number
--- @return number moved
--- @return string|nil where "reseau", or the face it went to
function Transport:evict(link, slot, count, avoid)
    avoid = avoid or {}

    local moved = self:retrieve(link, slot, count)
    if moved > 0 then return moved, "reseau" end

    local transposer = self:transposerFor(link.transposer)
    if not transposer then return 0 end

    local requested = count or 64

    for side = 0, 5 do
        if side ~= link.machine and side ~= link.source and not avoid[side] then
            local named, name = invoke(transposer, "getInventoryName", side)

            if named and name then
                local ok, answer = invoke(transposer, "transferItem",
                    link.machine, side, requested, slot)

                if ok then
                    local count_moved = movedCount(answer, requested)
                    if count_moved > 0 then
                        return count_moved, "face " .. side
                    end
                end
            end
        end
    end

    return 0
end

--- Move an item straight from one machine to another
--- Used for the queen leaving the Mutatron for the apiary: sending her through
--- the ME network would lose track of which queen is ours, because AE2 exposes
--- no genome and every queen carries the same label shape. Both machines must
--- hang off the same transposer, since a transposer only reaches what it
--- physically touches.
--- @param fromLink table Source machine link
--- @param fromSlot number
--- @param toLink table Destination machine link
--- @param toSlot number
--- @param count number|nil
--- @return boolean ok
--- @return string|nil error
function Transport:transferBetween(fromLink, fromSlot, toLink, toSlot, count)
    count = count or 1

    if not fromLink or not toLink then
        return false, "liaison de machine manquante"
    end

    local fromIndex = fromLink.transposer or 1
    local toIndex = toLink.transposer or 1

    if fromIndex ~= toIndex then
        return false, "les deux machines ne partagent pas le meme transposer"
    end

    local transposer, err = self:transposerFor(fromIndex)
    if not transposer then return false, err end

    local ok, answer = invoke(transposer, "transferItem",
        fromLink.machine, toLink.machine, count, fromSlot, toSlot)

    if not ok then
        return false, "transfert impossible: " .. tostring(answer)
    end

    local moved = movedCount(answer, count)
    if moved < count then
        return false, "transfert incomplet (" .. moved .. "/" .. count .. ")"
    end

    return true
end

--- Read a machine slot
--- @param link table Machine link
--- @param slot number
--- @return table|nil stack
--- How many slots a machine's inventory has
--- The diagnostic could only show slots that held something, so an empty slot
--- and a slot that does not exist looked identical, and the real shape of a
--- machine stayed invisible.
--- @param link table
--- @return number|nil size
function Transport:inventorySize(link)
    local transposer = self:transposerFor(link.transposer)
    if not transposer then return nil end

    local ok, size = invoke(transposer, "getInventorySize", link.machine)
    if not ok then return nil end

    return tonumber(size)
end

--- Read the fluid tanks of whatever sits on a transposer side
--- The Replicator, the Protein Liquifier and the Mutagen Producer expose no
--- OpenComputers component at all, so nothing can ask them anything -- but the
--- transposer that already moves their items can read their tanks. That is the
--- whole difference between warning "il manque du DNA" and failing on it.
--- @param link table Machine link
--- @param onMachineSide boolean|nil false to read the source side instead
--- @return table[] tanks {amount, capacity, label, ratio}
function Transport:tanks(link, onMachineSide)
    if type(link) ~= "table" then return {} end

    local transposer = self:transposerFor(link.transposer)
    if not transposer then return {} end

    local side = (onMachineSide == false) and link.source or link.machine
    if side == nil then return {} end

    local ok, list = invoke(transposer, "getFluidInTank", side)
    if not ok or type(list) ~= "table" then return {} end

    local tanks = {}
    for _, tank in pairs(list) do
        if type(tank) == "table" then
            local amount = tonumber(tank.amount) or 0
            local capacity = tonumber(tank.capacity) or 0

            table.insert(tanks, {
                amount = amount,
                capacity = capacity,
                -- An empty tank has no fluid and therefore no name; reporting
                -- it as unknown rather than skipping it is the point, since
                -- "empty" is exactly the state worth warning about
                label = tank.label or tank.name,
                ratio = capacity > 0 and (amount / capacity) or nil,
            })
        end
    end

    return tanks
end

--- The fullest tank on a side, which is the one that matters
--- A machine with several tanks reports them in an order nothing documents.
--- @param link table
--- @param onMachineSide boolean|nil
--- @return table|nil tank
function Transport:tank(link, onMachineSide)
    local best
    for _, tank in ipairs(self:tanks(link, onMachineSide)) do
        if not best or tank.amount > best.amount then best = tank end
    end
    return best
end

function Transport:inspect(link, slot)
    local transposer = self:transposerFor(link.transposer)
    if not transposer then return nil end

    local ok, stack = invoke(transposer, "getStackInSlot", link.machine, slot)
    if not ok then return nil end

    return stack
end

--- Fingerprint the item in a slot
--- Templates cannot be read: they share one id and one label and no machine slot
--- exposes their NBT. But store() copies the whole stack into a database and
--- computeHash() then yields a stable SHA-256, which is enough to tell one
--- template from another and to detect a tampered library.
--- @param link table Machine link, or any inventory reachable by the transposer
--- @param slot number
--- @param dbSlot number Scratch slot in the database
--- @param onMachineSide boolean|nil true to read the machine, false the source
--- @return string|nil hash
--- @return string|nil error
function Transport:fingerprint(link, slot, dbSlot, onMachineSide)
    local transposer, err = self:transposerFor(link.transposer)
    if not transposer then return nil, err end

    local side = (onMachineSide == false) and link.source or link.machine

    -- store() reports whether the database slot was ALREADY occupied, never
    -- whether the write worked: the write always happens. So the return value
    -- is ignored and success is established by reading the entry back.
    local stored = invoke(transposer, "store", side, slot, self.database.address, dbSlot)
    if not stored then return nil, "store() injoignable" end

    local read_ok, entry = invoke(self.database, "get", dbSlot)
    if not read_ok or type(entry) ~= "table" then
        return nil, "rien n'a ete ecrit dans la database (slot " .. dbSlot .. " valide ?)"
    end

    local hash_ok, hash = invoke(self.database, "computeHash", dbSlot)
    if not hash_ok or type(hash) ~= "string" then
        return nil, "computeHash indisponible"
    end

    return hash
end

--- Check that a slot still holds the exact item recorded in the database
--- @param link table Machine link
--- @param slot number
--- @param dbSlot number Database slot holding the reference
--- @param onMachineSide boolean|nil
--- @return boolean matches
function Transport:matchesReference(link, slot, dbSlot, onMachineSide)
    local transposer = self:transposerFor(link.transposer)
    if not transposer then return false end

    local side = (onMachineSide == false) and link.source or link.machine

    local ok, same = invoke(transposer, "compareStackToDatabase",
        side, slot, self.database.address, dbSlot, true)

    return ok and same == true
end

--- Is the ME network answering and powered
--- The reason carries the actual figures: "unpowered" alone sends you looking
--- at the wrong thing when the interface is simply on a subnetwork of its own.
--- @return boolean online
--- @return string|nil reason
function Transport:isOnline()
    local ok, powered = invoke(self.me, "isNetworkPowered")
    if not ok then return false, "interface ME injoignable: " .. tostring(powered) end

    if powered == false then
        local details = {}

        local stored_ok, stored = invoke(self.me, "getStoredPower")
        local max_ok, maximum = invoke(self.me, "getMaxStoredPower")
        if stored_ok and tonumber(stored) then
            table.insert(details, string.format("stockage %.0f/%.0f",
                tonumber(stored), (max_ok and tonumber(maximum)) or 0))
        end

        local demand_ok, demand = invoke(self.me, "getEnergyDemand")
        if demand_ok and tonumber(demand) then
            table.insert(details, string.format("demande %.1f", tonumber(demand)))
        end

        local usage_ok, usage = invoke(self.me, "getAvgPowerUsage")
        local injection_ok, injection = invoke(self.me, "getAvgPowerInjection")
        if usage_ok and injection_ok and tonumber(usage) and tonumber(injection) then
            table.insert(details, string.format("conso %.1f, injection %.1f",
                tonumber(usage), tonumber(injection)))
        end

        local reason = "reseau AE2 hors tension"
        if #details > 0 then
            reason = reason .. " (" .. table.concat(details, ", ") .. ")"
        end

        return false, reason
    end

    return true
end

--- How many items the network can see
--- Zero on a network that reports itself powered usually means the interface
--- sits on a subnetwork with no storage attached.
--- @return number count
function Transport:networkItemCount()
    local ok, items = invoke(self.me, "getItemsInNetwork")
    if not ok or type(items) ~= "table" then return 0 end

    local count = 0
    for _ in pairs(items) do count = count + 1 end
    return count
end

return transport
