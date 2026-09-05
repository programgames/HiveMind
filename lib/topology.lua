-- HiveMind topology
--
-- What the program can see of the world, and the configuration file it writes
-- from it.
--
-- Until now lib/config.lua held one installation: Julien's. Every address and
-- every block face in it was measured once, by hand, in one world. A second
-- player starting from nothing had a program that moved items into faces that
-- do not exist, which reads as "la machine refuse cet objet" and takes an
-- evening to understand.
--
-- So the addresses and faces are discovered rather than declared. A Transposer
-- is asked what sits on each of its six sides through getInventoryName(), which
-- returns the inventory's registry name -- enough to tell a Genetic Sampler
-- from a Replicator from an ME Interface. What comes out is written to a file
-- that lib/config.lua reads on top of its own defaults.
--
-- What stays in lib/config.lua is what does NOT change between worlds: the slot
-- maps, the two profiles, the thresholds. Those are properties of the mod, not
-- of anyone's base.
--
-- READ ONLY. Nothing here moves a single item.

local topology = {}

--- Registry name fragments, and the machine key they mean
--- Ordered from most specific to least: "industrial_apiary" must be tested
--- before "apiary", and "genetic_transposer" before "transposer".
--- @type table[]
topology.SIGNATURES = {
    {pattern = "mutatron_advanced",   machine = "mutatron"},
    {pattern = "advanced_mutatron",   machine = "mutatron"},
    {pattern = "mutatron",            machine = "mutatron"},
    {pattern = "industrial_apiary",   machine = "breeding_apiary"},
    {pattern = "apiary",              machine = "breeding_apiary"},
    {pattern = "genetic_sampler",     machine = "sampler"},
    {pattern = "sampler",             machine = "sampler"},
    {pattern = "genetic_transposer",  machine = "genetic_transposer"},
    {pattern = "genetic_imprinter",   machine = "imprinter"},
    {pattern = "imprinter",           machine = "imprinter"},
    {pattern = "genetic_replicator",  machine = "replicator"},
    {pattern = "replicator",          machine = "replicator"},
    {pattern = "dna_extractor",       machine = "dna_extractor"},
    {pattern = "extractor",           machine = "dna_extractor"},
    {pattern = "protein",             machine = "protein_liquifier"},
    {pattern = "liquifier",           machine = "protein_liquifier"},
    {pattern = "mutagen",             machine = "mutagen_producer"},
    {pattern = "interface",           machine = "_me_interface"},
    {pattern = "chest",               machine = "_chest"},
}

--- The machines the program needs before it can do anything useful
--- @type string[]
topology.EXPECTED = {
    "mutatron", "breeding_apiary", "sampler", "genetic_transposer",
    "imprinter", "replicator", "dna_extractor", "protein_liquifier",
    "mutagen_producer",
}

--- Faces, named the way the player sees them standing at the transposer
--- @type table<number, string>
topology.SIDE_NAMES = {
    [0] = "dessous", [1] = "dessus", [2] = "derriere",
    [3] = "devant", [4] = "a droite", [5] = "a gauche",
}

--- Which machine an inventory name refers to
--- @param name string Registry or display name
--- @return string|nil machine
function topology.identify(name)
    if type(name) ~= "string" or name == "" then return nil end

    local lowered = name:lower()
    for _, signature in ipairs(topology.SIGNATURES) do
        if lowered:find(signature.pattern, 1, true) then
            return signature.machine
        end
    end

    return nil
end

--- Call a component method without ever letting it break discovery
--- Component methods are callable tables, not functions, so only nil is ruled
--- out here and the call itself decides.
local function call(proxy, method, ...)
    if not proxy then return nil end

    local target = proxy[method]
    if target == nil then return nil end

    local ok, result = pcall(target, ...)
    if not ok then return nil end

    return result
end

--- Look at the whole network and work out where everything is
--- @param options table|nil {list, proxy} injected for the desktop tests
--- @return table|nil discovered {transposers, machines, chests, interfaces, unknown}
--- @return string|nil error
function topology.scan(options)
    options = options or {}

    local list, proxy = options.list, options.proxy

    if not list or not proxy then
        local ok, component = pcall(require, "component")
        if not ok or type(component) ~= "table" then
            return nil, "OpenComputers indisponible: rien a decouvrir"
        end

        list = function(kind)
            local found = {}
            for address in component.list(kind) do table.insert(found, address) end
            table.sort(found)
            return found
        end

        proxy = function(address) return component.proxy(address) end
    end

    local addresses = list("transposer") or {}

    local discovered = {
        transposers = {},
        machines = {},
        chests = {},
        interfaces = list("me_interface") or {},
        unknown = {},
        -- Which transposer sees an ME Interface, and on which face
        interfaceSides = {},
    }

    for _, address in ipairs(addresses) do
        table.insert(discovered.transposers, address)

        local device = proxy(address)
        local neighbours = {}

        for side = 0, 5 do
            local name = call(device, "getInventoryName", side)
            local size = call(device, "getInventorySize", side)

            if name or size then
                table.insert(neighbours, {side = side, name = name or "?",
                                          size = tonumber(size) or 0,
                                          machine = topology.identify(name)})
            end
        end

        -- The ME Interface is where items come from for every machine on this
        -- transposer, so it has to be found before the machines are recorded
        local interfaceSide = nil
        for _, neighbour in ipairs(neighbours) do
            if neighbour.machine == "_me_interface" then
                interfaceSide = neighbour.side
            end
        end

        discovered.interfaceSides[address] = interfaceSide

        for _, neighbour in ipairs(neighbours) do
            if neighbour.machine == "_chest" then
                table.insert(discovered.chests, {
                    transposer = address, side = neighbour.side,
                    slots = neighbour.size, inventory = neighbour.name,
                })
            elseif neighbour.machine == "_me_interface" then
                -- Recorded above; it is a source, not a machine
            elseif neighbour.machine then
                -- Two Imprinters is the point of having two profiles, and one
                -- key per machine kind silently kept the last one seen
                local key = neighbour.machine
                local suffix = 2

                while discovered.machines[key] do
                    key = neighbour.machine .. "_" .. suffix
                    suffix = suffix + 1
                end

                discovered.machines[key] = {
                    transposer = address,
                    machine = neighbour.side,
                    source = interfaceSide,
                    inventory = neighbour.name,
                    slots = neighbour.size,
                }
            else
                table.insert(discovered.unknown,
                    {transposer = address, side = neighbour.side,
                     name = neighbour.name})
            end
        end
    end

    return discovered
end

--- Machines the program needs and discovery did not find
--- @param discovered table
--- @return string[] names
function topology.missing(discovered)
    local absent = {}

    for _, name in ipairs(topology.EXPECTED) do
        if not (discovered.machines or {})[name] then
            table.insert(absent, name)
        end
    end

    return absent
end

--- Transposers the configuration names that the world does not have
--- This is the whole test for "does this configuration describe THIS world":
--- a declared address nothing answers to means every delivery through it fails,
--- and it fails as though the machine had refused the item.
--- @param settings table lib/config
--- @param discovered table
--- @return string[] stale Addresses declared and absent
function topology.stale(settings, discovered)
    local present = {}
    for _, address in ipairs(discovered.transposers or {}) do
        present[address] = true
    end

    local declared, seen = {}, {}

    for name, link in pairs(settings.machines or {}) do
        local key = link.transposer
        if link.enabled ~= false and type(key) == "string" and not seen[key] then
            seen[key] = true
            table.insert(declared, {key = key, machine = name})
        end
    end

    local stale = {}

    for _, entry in ipairs(declared) do
        local found = false
        for address in pairs(present) do
            if address:sub(1, #entry.key) == entry.key then found = true break end
        end
        if not found then table.insert(stale, entry.key) end
    end

    table.sort(stale)
    return stale
end

--- Escape a string for a Lua source file
local function quote(text)
    return string.format("%q", tostring(text))
end

--- The configuration file, as Lua source
--- Written next to the program rather than into lib/config.lua: what is in that
--- file is the mod's behaviour -- slot maps, the two profiles, the thresholds --
--- and it is the same in every world. Only the addresses and the block faces
--- belong to one base, and only those are written here.
--- @param discovered table
--- @param options table|nil {interfaces = {[transposer] = address}, chest = table}
--- @return string source
function topology.render(discovered, options)
    options = options or {}

    local lines = {
        "-- Topologie de CETTE installation, ecrite par HiveMind (option 1).",
        "-- Elle est relue par lib/config.lua par-dessus ses valeurs par defaut.",
        "--",
        "-- Efface ce fichier et relance l option 1 apres avoir deplace un bloc.",
        "-- Rien ici ne se devine: chaque face a ete demandee au transposer.",
        "",
        "return {",
        "    transposers = {",
    }

    for _, address in ipairs(discovered.transposers or {}) do
        table.insert(lines, "        " .. quote(address) .. ",")
    end

    table.insert(lines, "    },")

    local interfaces = options.interfaces or {}
    local anyInterface = false
    for _ in pairs(interfaces) do anyInterface = true break end

    if anyInterface then
        table.insert(lines, "")
        table.insert(lines, "    -- Une interface ME par banc, par adresse de transposer.")
        table.insert(lines, "    -- Sans Adapter colle a l interface, elle n a pas d adresse")
        table.insert(lines, "    -- et rien ne peut lui etre livre.")
        table.insert(lines, "    interfaces = {")

        local order = {}
        for key in pairs(interfaces) do table.insert(order, key) end
        table.sort(order)

        for _, key in ipairs(order) do
            table.insert(lines, "        [" .. quote(key) .. "] = "
                .. quote(interfaces[key]) .. ",")
        end

        table.insert(lines, "    },")
    end

    table.insert(lines, "")
    table.insert(lines, "    machines = {")

    local names = {}
    for name in pairs(discovered.machines or {}) do table.insert(names, name) end
    table.sort(names)

    for _, name in ipairs(names) do
        local link = discovered.machines[name]
        table.insert(lines, string.format(
            "        %s = {transposer = %s, machine = %d, source = %s},  -- %s",
            name, quote(link.transposer), link.machine,
            link.source and tostring(link.source) or "nil",
            tostring(link.inventory)))
    end

    table.insert(lines, "    },")

    local chest = options.chest
    if chest then
        table.insert(lines, "")
        table.insert(lines, "    -- Les templates ne rentrent jamais dans le reseau ME:")
        table.insert(lines, "    -- ils partagent tous une etiquette, AE2 ne peut pas les")
        table.insert(lines, "    -- distinguer. Ils vivent dans ce coffre, un par slot.")
        table.insert(lines, string.format(
            "    template_chest = {transposer = %s, side = %d, slots = %d},",
            quote(chest.transposer), chest.side, chest.slots or 0))
    end

    table.insert(lines, "}")

    return table.concat(lines, "\n") .. "\n"
end

--- Apply a written topology on top of a configuration table
--- Kept here rather than in lib/config.lua so it can be tested without a file.
--- @param settings table lib/config
--- @param written table What the file returned
--- @return number applied How many machine links were rewritten
function topology.apply(settings, written)
    if type(written) ~= "table" then return 0 end

    if type(written.transposers) == "table" and #written.transposers > 0 then
        settings.transposers = written.transposers
    end

    if type(written.interfaces) == "table" then
        settings.interfaces = written.interfaces
    end

    if type(written.template_chest) == "table" then
        settings.template_chest = written.template_chest
    end

    local applied = 0

    for name, link in pairs(written.machines or {}) do
        local existing = settings.machines[name]

        if existing then
            -- Only the three things that belong to one base. The slot map is a
            -- property of the mod and stays where it was measured.
            existing.transposer = link.transposer
            existing.machine = link.machine
            existing.source = link.source
            existing.enabled = true
        else
            settings.machines[name] = {
                transposer = link.transposer,
                machine = link.machine,
                source = link.source,
            }
        end

        applied = applied + 1
    end

    return applied
end

--- Read a written topology, if there is one
--- @param path string
--- @return table|nil written
--- @return string|nil error
function topology.read(path)
    local file = io.open(path, "r")
    if not file then return nil, "aucun fichier de topologie" end

    local source = file:read("*a")
    file:close()

    local chunk, err = load(source, "topologie")
    if not chunk then return nil, tostring(err) end

    local ok, written = pcall(chunk)
    if not ok or type(written) ~= "table" then
        return nil, "fichier de topologie illisible"
    end

    return written
end

--- Write a topology file
--- @param path string
--- @param source string
--- @return boolean ok
--- @return string|nil error
function topology.write(path, source)
    local file, err = io.open(path, "w")
    if not file then return false, tostring(err) end

    file:write(source)
    file:close()

    return true
end

return topology
