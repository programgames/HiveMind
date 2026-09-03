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
        clock = options.clock or os.time,
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

--- Reserve a loading dock
--- @return number|nil dock
--- @return string|nil error
function Transport:reserveDock()
    for _, dock in ipairs(self.docks) do
        if not self.reserved[dock] then
            self.reserved[dock] = true
            return dock
        end
    end

    return nil, "tous les quais de chargement sont occupes"
end

--- Give a dock back, clearing the interface configuration
--- @param dock number
function Transport:releaseDock(dock)
    if not dock then return end

    -- Clearing matters: a dock left configured keeps pulling that item out of
    -- the network and holding it in the interface forever.
    invoke(self.me, "setInterfaceConfiguration", dock)
    self.reserved[dock] = nil
end

--- Stage an item in the interface so a transposer can pick it up
--- @param spec table {name, label}
--- @param count number|nil
--- @return number|nil dock
--- @return string|nil error
function Transport:stage(spec, count)
    count = count or 1

    local entry, find_err = self:find(spec)
    if not entry then return nil, find_err end

    local dock, dock_err = self:reserveDock()
    if not dock then return nil, dock_err end

    -- Pin the exact stack, NBT included, into the database
    local stored, store_err = invoke(self.me, "store",
        {name = entry.name, label = entry.label}, self.database.address, dock, 1)

    if not stored then
        self:releaseDock(dock)
        return nil, "store() a echoue: " .. tostring(store_err)
    end

    local configured, config_err = invoke(self.me, "setInterfaceConfiguration",
        dock, self.database.address, dock, count)

    if not configured then
        self:releaseDock(dock)
        return nil, "configuration du quai impossible: " .. tostring(config_err)
    end

    return dock
end

--- Wait until the interface physically holds the staged item
--- @param link table Machine link, giving the transposer and the source side
--- @param dock number
--- @param count number
--- @return boolean ok
--- @return string|nil error
function Transport:awaitStock(link, dock, count)
    local transposer, err = self:transposerFor(link.transposer)
    if not transposer then return false, err end

    local deadline = self.clock() + self.stockTimeout

    repeat
        local ok, size = invoke(transposer, "getSlotStackSize", link.source, dock)
        if ok and (tonumber(size) or 0) >= count then
            return true
        end

        self.sleep(self.pollInterval)
    until self.clock() > deadline

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

    local dock, stage_err = self:stage(spec, count)
    if not dock then return false, stage_err end

    local stocked, stock_err = self:awaitStock(link, dock, count)
    if not stocked then
        self:releaseDock(dock)
        return false, stock_err
    end

    local ok, answer = invoke(transposer, "transferItem",
        link.source, link.machine, count, dock, slot)

    self:releaseDock(dock)

    if not ok then
        return false, "transfert impossible: " .. tostring(answer)
    end

    local moved = movedCount(answer, count)
    if moved < count then
        return false, "transfert incomplet (" .. moved .. "/" .. count .. ")"
    end

    return true
end

--- Take an item out of a machine and hand it back to the network
--- The interface accepts anything pushed into it, so no dock is needed here.
--- @param link table Machine link
--- @param slot number Source slot in the machine
--- @param count number|nil
--- @return number moved
--- @return string|nil error
function Transport:retrieve(link, slot, count)
    local transposer, err = self:transposerFor(link.transposer)
    if not transposer then return 0, err end

    local requested = count or 64
    local ok, answer = invoke(transposer, "transferItem",
        link.machine, link.source, requested, slot)

    if not ok then return 0, "retrait impossible: " .. tostring(answer) end

    return movedCount(answer, requested)
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
