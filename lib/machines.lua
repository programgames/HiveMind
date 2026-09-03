-- HiveMind machine layer
--
-- One uniform way to talk to every machine, whatever it exposes.
--
-- Two of them have a real driver through The Apiarist Terminal and can be
-- asked what they are doing. The other six are ordinary inventories: the
-- program watches their slots and moves items through the transport layer.
-- Both kinds answer isReady(), awaitReady() and energy(), so a caller never has
-- to know which is which.
--
-- Deliberately one file rather than one per machine: the drivers are thin, and
-- every extra require costs memory on a machine that has 1.5 MB in total.
--
-- Energy policy, as specified: the program never manages power, it waits. It
-- only speaks up when the wait becomes long enough to be worth a human's
-- attention.

local genome = require("lib.genome")

local machines = {}

machines.READY = "ready"
machines.BUSY = "busy"
machines.NO_ENERGY = "no_energy"
machines.NO_RESOURCE = "no_resource"
machines.ERROR = "error"
machines.OFFLINE = "offline"

--- Real seconds since the computer started
--- os.time() on OpenOS returns Minecraft world time, which runs about 72 times
--- faster than real time: waiting "sixty seconds" on it lasts under a second.
--- @return function clock
local function realClock()
    local ok, computer = pcall(require, "computer")
    if ok and type(computer) == "table" and computer.uptime then
        return computer.uptime
    end
    return os.clock
end

--- Call a component method without ever aborting the caller
--- @return boolean ok
--- @return any result
local function invoke(component, method, ...)
    if not component then return false, "composant absent" end

    local target = component[method]
    if target == nil then return false, "methode absente: " .. tostring(method) end

    return pcall(target, ...)
end

-- ---------------------------------------------------------------------------
-- Base machine
-- ---------------------------------------------------------------------------

local Machine = {}
Machine.__index = Machine

--- @param options table {name, component, link, transport, config, sleep, clock, onWait}
local function newMachine(options, metatable)
    local settings = (options.config and options.config.energy) or {}

    return setmetatable({
        name = options.name,
        component = options.component,
        link = options.link,
        transport = options.transport,
        complainAfter = settings.complain_after_seconds or 60,
        minimumRatio = settings.minimum_ratio or 0.05,
        slotOffset = (options.config and options.config.slot_offset) or 0,
        onWait = options.onWait,
        sleep = options.sleep or function(seconds)
            local ok, os_sleep = pcall(function() return os.sleep end)
            if ok and os_sleep then os_sleep(seconds) end
        end,
        clock = options.clock or realClock(),
    }, metatable or Machine)
end

--- Energy in the machine's own buffer
--- Both drivers expose getEnergyStored/getMaxEnergyStored; item-only machines
--- expose nothing, and are reported as unknown rather than empty.
--- @return number|nil stored
--- @return number|nil maximum
--- @return number|nil ratio
function Machine:energy()
    local ok, stored = invoke(self.component, "getEnergyStored")
    if not ok then return nil, nil, nil end

    local max_ok, maximum = invoke(self.component, "getMaxEnergyStored")
    if not max_ok or not tonumber(maximum) or tonumber(maximum) == 0 then
        return tonumber(stored), nil, nil
    end

    stored, maximum = tonumber(stored) or 0, tonumber(maximum)
    return stored, maximum, stored / maximum
end

--- Does the machine have enough power to do anything
--- @return boolean powered
function Machine:hasEnergy()
    local _, _, ratio = self:energy()
    -- Unknown means "no reason to think otherwise": an item-only machine has no
    -- buffer to read, and blocking on that would deadlock the whole queue.
    if ratio == nil then return true end
    return ratio > self.minimumRatio
end

--- Machine state, uniform across every kind
--- @return string status One of the machines.* constants
--- @return string|nil detail
function Machine:isReady()
    if not self:hasEnergy() then
        return machines.NO_ENERGY, "energie insuffisante"
    end
    return machines.READY
end

--- Wait until the machine can work
--- Long waits are reported through onWait rather than silently endured, which
--- is the whole of the agreed energy policy.
--- @param options table|nil {timeout, interval}
--- @return boolean ready
--- @return string|nil reason
function Machine:awaitReady(options)
    options = options or {}

    local timeout = options.timeout or 300
    local interval = options.interval or 1
    local started = self.clock()
    local complained = false

    while true do
        local status, detail = self:isReady()
        if status == machines.READY then
            if complained and self.onWait then
                pcall(self.onWait, self.name, machines.READY, self.clock() - started)
            end
            return true
        end

        local elapsed = self.clock() - started

        if elapsed >= timeout then
            return false, detail or status
        end

        if not complained and elapsed >= self.complainAfter then
            complained = true
            if self.onWait then
                pcall(self.onWait, self.name, status, elapsed, detail)
            end
        end

        self.sleep(interval)
    end
end

--- Translate a driver slot index into a transposer slot index
--- The Apiarist Terminal reports slots from zero while OpenComputers numbers
--- them from one. Its documentation says to pass its indices straight through,
--- so the offset defaults to zero, but it is configurable because getting this
--- wrong puts every item one slot off with no error to explain it.
--- @param slot number
--- @return number
function Machine:resolveSlot(slot)
    return (tonumber(slot) or 0) + self.slotOffset
end

--- Read one of the machine's own slots
--- @param slot number
--- @return table|nil stack
function Machine:slot(slot)
    if not self.transport or not self.link then return nil end
    return self.transport:inspect(self.link, self:resolveSlot(slot))
end

--- Put an item from the ME network into one of the machine's slots
--- @param spec table {name, label}
--- @param slot number
--- @param count number|nil
--- @return boolean ok
--- @return string|nil error
function Machine:load(spec, slot, count)
    if not self.transport or not self.link then
        return false, "machine sans liaison de transport"
    end
    return self.transport:deliver(spec, self.link, self:resolveSlot(slot), count)
end

--- Empty a slot back into the network
--- @param slot number
--- @param count number|nil
--- @return number moved
function Machine:unload(slot, count)
    if not self.transport or not self.link then return 0 end
    return self.transport:retrieve(self.link, self:resolveSlot(slot), count)
end

--- Empty every listed slot back into the network
--- @param slots number[]
--- @return number moved
--- @return table byslot
function Machine:drain(slots)
    local total, detail = 0, {}

    for _, slot in ipairs(slots or {}) do
        local moved = self:unload(slot)
        if moved > 0 then
            total = total + moved
            detail[slot] = moved
        end
    end

    return total, detail
end

-- ---------------------------------------------------------------------------
-- Advanced Mutatron
-- ---------------------------------------------------------------------------

local Mutatron = setmetatable({}, {__index = Machine})
Mutatron.__index = Mutatron

--- Slot layout, asked of the machine and cached
--- @return table slots {in1, in2, output, labware, selectors}
function Mutatron:slots()
    if self.cachedSlots then return self.cachedSlots end

    local ok, slots = invoke(self.component, "listSlots")
    if ok and type(slots) == "table" and slots.in1 then
        self.cachedSlots = slots
    else
        -- Configuration holds a fallback for exactly this case
        self.cachedSlots = (self.link and self.link.slots) or
            {in1 = 0, in2 = 1, output = 2, labware = 3}
    end

    return self.cachedSlots
end

--- Mutagen tank
--- @return number amount
--- @return number capacity
function Mutatron:tank()
    local ok, tank = invoke(self.component, "getTank")
    if not ok or type(tank) ~= "table" then return 0, 0 end
    return tonumber(tank.amount) or 0, tonumber(tank.capacity) or 0
end

--- Mutations reachable with whatever is currently loaded
--- This is the machine's own answer, so a plan can be checked against reality
--- before it is executed rather than after it silently fails.
--- @return table[] mutations
function Mutatron:mutations()
    local ok, list = invoke(self.component, "listMutations")
    if not ok or type(list) ~= "table" then return {} end

    local mutations = {}
    for _, entry in pairs(list) do
        if type(entry) == "table" then
            table.insert(mutations, {
                index = entry.index,
                key = entry.key,
                name = entry.name,
                label = entry.label,
                nbt = entry.nbt,
                -- The listing carries the full genome of the result
                genome = entry.nbt and genome.parse(entry.nbt) or nil,
            })
        end
    end

    return mutations
end

--- Find the mutation producing a species among those currently offered
--- @param speciesUid string
--- @return table|nil mutation
function Mutatron:mutationFor(speciesUid)
    for _, mutation in ipairs(self:mutations()) do
        if mutation.genome and genome.species(mutation.genome) == speciesUid then
            return mutation
        end
        if mutation.name == speciesUid or mutation.label == speciesUid then
            return mutation
        end
    end
    return nil
end

--- Progress of the current operation, when the machine reports one
--- @return number|nil progress 0..1
function Mutatron:progress()
    local ok, progress = invoke(self.component, "getProgress")
    if not ok then return nil end
    return tonumber(progress)
end

function Mutatron:isReady()
    if not self:hasEnergy() then return machines.NO_ENERGY, "energie insuffisante" end

    local amount = self:tank()
    if amount <= 0 then
        return machines.NO_RESOURCE, "reservoir de mutagene vide"
    end

    -- canStart() is deliberately NOT consulted here. Its own documentation says
    -- it reads false before a mutation is selected, which is the normal state of
    -- an idle machine; gating on it made a full tank look like a broken machine
    -- and would have retried forever.
    local progress = self:progress()
    if progress and progress > 0 and progress < 1 then
        return machines.BUSY, "production en cours"
    end

    return machines.READY
end

--- What the machine itself thinks about starting
--- Informational only: false is the normal answer before a selection.
--- @return boolean|nil
function Mutatron:canStart()
    local ok, can = invoke(self.component, "canStart")
    if not ok then return nil end
    return can == true
end

--- Run one mutation and wait for the result
--- @param index number 1-based index from mutations()
--- @param timeout number|nil
--- @return table|nil stack Produced stack
--- @return string|nil error
function Mutatron:produce(index, timeout)
    local ok, result, detail = invoke(self.component, "selectAndProduce", index, timeout or 60)

    if not ok then return nil, "appel impossible: " .. tostring(result) end
    if result == false then return nil, tostring(detail or "production refusee") end

    -- selectAndProduce answers true plus the stack, or just the stack
    local stack = (type(result) == "table") and result or detail
    if type(stack) ~= "table" then
        return nil, "aucune sortie rapportee par la machine"
    end

    return stack
end

--- Current output slot content
--- @return table|nil stack
function Mutatron:output()
    local ok, stack = invoke(self.component, "getOutput")
    if not ok or type(stack) ~= "table" then return nil end
    return stack
end

-- ---------------------------------------------------------------------------
-- Industrial Apiary
-- ---------------------------------------------------------------------------

local Apiary = setmetatable({}, {__index = Machine})
Apiary.__index = Apiary

--- Slot layout, asked of the machine and cached
--- @return table slots {queen, drone, upgrades, outputs}
function Apiary:slots()
    if self.cachedSlots then return self.cachedSlots end

    local ok, slots = invoke(self.component, "listSlots")
    if ok and type(slots) == "table" and slots.queen ~= nil then
        self.cachedSlots = slots
    else
        self.cachedSlots = (self.link and self.link.slots) or
            {queen = 0, drone = 1, outputs = {6, 7, 8, 9, 10, 11, 12, 13, 14}}
    end

    return self.cachedSlots
end

--- The bees currently inside, with their genomes already parsed
--- Parking a bee here is the only way to read a genome at all, since
--- OpenComputers keeps NBT out of ordinary item descriptors.
--- @return table bees {queen = {stack, genome}, drone = {stack, genome}}
function Apiary:bees()
    local ok, bees = invoke(self.component, "getBees")
    if not ok or type(bees) ~= "table" then return {} end

    local read = {}
    for role, stack in pairs(bees) do
        if type(stack) == "table" then
            read[role] = {
                stack = stack,
                label = stack.label,
                count = stack.count,
                genome = stack.nbt and genome.parse(stack.nbt) or nil,
            }
        end
    end

    return read
end

--- Species of the bee sitting in a slot
--- @param role string "queen" or "drone"
--- @return string|nil uid
function Apiary:speciesIn(role)
    local bee = self:bees()[role]
    return bee and bee.genome and genome.species(bee.genome) or nil
end

--- Non-empty output slots
--- @return table[] outputs
function Apiary:outputs()
    local ok, list = invoke(self.component, "listOutputs")
    if not ok or type(list) ~= "table" then return {} end

    local outputs = {}
    for _, item in pairs(list) do
        if type(item) == "table" and item.slot then table.insert(outputs, item) end
    end

    return outputs
end

--- Wait for the queen to die and free the slot
--- This single call replaces the Mechanical User, the beebee gun, the Assassin
--- Queen and the fixed thirty second sleep the old code relied on.
--- @param timeout number|nil
--- @return boolean ok
--- @return string|nil reason
function Apiary:awaitPrincess(timeout)
    local ok, done, reason = invoke(self.component, "waitForPrincess", timeout or 180)

    if not ok then return false, "appel impossible: " .. tostring(done) end
    if done == false then return false, tostring(reason or "delai depasse") end

    return true
end

--- Errors reported by Forestry and Gendustry
--- @return boolean hasErrors
--- @return string[] errors
function Apiary:errors()
    local ok, result = invoke(self.component, "getErrors")
    if not ok or type(result) ~= "table" then return false, {} end

    local list = {}
    for _, entry in ipairs(result.errors or {}) do table.insert(list, tostring(entry)) end

    return result.hasErrors == true, list
end

--- Effective upgrade modifiers
--- @return table modifiers
function Apiary:modifiers()
    local ok, result = invoke(self.component, "getModifiers")
    if not ok or type(result) ~= "table" then return {} end
    return result
end

--- Environment the apiary actually reports
--- @return table {temperature, humidity}
function Apiary:getEnvironment()
    local ok, environment = invoke(self.component, "getEnvironment")
    if not ok or type(environment) ~= "table" then return {} end
    return environment
end

--- Names of the installed upgrades
--- An upgrade fitted for a previous bee is the usual reason a new one refuses
--- to work, so it belongs in any environment complaint.
--- @return string[] names
function Apiary:upgradeNames()
    local ok, upgrades = invoke(self.component, "listUpgrades")
    if not ok or type(upgrades) ~= "table" then return {} end

    local names = {}
    for _, upgrade in pairs(upgrades) do
        if type(upgrade) == "table" then
            table.insert(names, tostring(upgrade.label or upgrade.name or "?"))
        end
    end

    table.sort(names)
    return names
end

--- Is an Automation upgrade installed
--- It must not be, on the apiary the program drives: waitForPrincess is
--- documented to fail when one is present.
--- @return boolean automated
function Apiary:isAutomated()
    return self:modifiers().isAutomated == true
end

--- Forestry error codes that mean "nothing loaded yet", not "broken"
local WAITING_FOR_BEE = {
    no_queen = true, no_princess = true, no_drone = true,
    no_bee = true, not_gendered = true, no_sapling = true,
}

--- Is this error simply about an empty machine
--- Codes arrive namespaced ("forestry:no_queen"), so only the suffix matters.
--- @param code string
--- @return boolean
local function isWaitingForBee(code)
    local suffix = tostring(code):match("([^:]+)$") or ""
    return WAITING_FOR_BEE[suffix:lower()] == true
end

function Apiary:isReady()
    if not self:hasEnergy() then return machines.NO_ENERGY, "energie insuffisante" end

    local has_errors, list = self:errors()
    if not has_errors then return machines.READY end

    -- Environmental complaints are bee-dependent: a Wintry queen reports
    -- too_hot exactly where a Forest one works fine. Judging them on an empty
    -- apiary would block the queue over a bee we have not loaded yet, so they
    -- only count once something is actually inside and still cannot work.
    local bees = self:bees()
    if not (bees.queen or bees.drone) then
        return machines.READY
    end

    local blocking = {}
    for _, code in ipairs(list) do
        if not isWaitingForBee(code) then table.insert(blocking, code) end
    end

    if #blocking == 0 then return machines.READY end

    return machines.ERROR, table.concat(blocking, ", ")
end

--- Errors that would stop the bee currently loaded
--- Reported separately from isReady so the interface can show a warning about
--- an empty apiary that will not suit the bee we are about to put in it.
--- @return string[] blocking
function Apiary:environmentErrors()
    local _, list = self:errors()

    local blocking = {}
    for _, code in ipairs(list) do
        if not isWaitingForBee(code) then table.insert(blocking, code) end
    end

    return blocking
end

-- ---------------------------------------------------------------------------
-- Factory
-- ---------------------------------------------------------------------------

local BY_COMPONENT = {
    advmutatron = Mutatron,
    industrial_apiary = Apiary,
}

--- Build a machine driver
--- The right driver is chosen from the component type in the configuration; a
--- machine without one gets the plain inventory driver, which is enough for the
--- six item-only machines.
--- @param options table {name, component, link, transport, config, sleep, clock, onWait}
--- @return table machine
function machines.new(options)
    options = options or {}

    local link = options.link or {}
    local metatable = BY_COMPONENT[link.component or ""] or Machine

    return newMachine(options, metatable)
end

--- Build every machine declared in the configuration
--- A machine whose component is missing is still built: it keeps its transport
--- link, so item moves work even when its driver is unavailable.
--- @param options table {config, components, transport, sleep, clock, onWait}
--- @return table<string, table> machines
--- @return string[] missing Names whose component was expected but absent
function machines.all(options)
    options = options or {}

    local settings = options.config
    local built, missing = {}, {}

    for _, name in ipairs(settings.enabledMachines()) do
        local link = settings.machines[name]
        local component = nil

        if link.component then
            component = options.components and options.components[link.component]
            if not component then table.insert(missing, name) end
        end

        built[name] = machines.new({
            name = name,
            component = component,
            link = link,
            transport = options.transport,
            config = settings,
            sleep = options.sleep,
            clock = options.clock,
            onWait = options.onWait,
        })
    end

    table.sort(missing)
    return built, missing
end

machines.Machine = Machine
machines.Mutatron = Mutatron
machines.Apiary = Apiary

return machines
