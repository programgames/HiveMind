-- HiveMind configuration
--
-- Describes YOUR installation. Nothing here is guessed by the program: it moves
-- items exactly where this file says, so a wrong side means items going into the
-- wrong slot, not a crash.
--
-- Topology, in one paragraph. Machines are reached by Transposers. A Transposer
-- moves items between the inventories it physically touches, so every link below
-- names three things: which transposer, the side where the machine sits, and the
-- side where the items come from (the ME Interface, or a buffer chest). Machines
-- driven through The Apiarist Terminal (Mutatron, Industrial Apiary) also have a
-- component name, which is how the program reads their state.
--
-- Sides are OpenComputers side numbers, seen FROM THE TRANSPOSER, not from you.

local config = {}

-- Machines name their transposer by ADDRESS, never by position: adding one
-- transposer to the network renumbers every other one and silently aims each
-- machine at the wrong neighbour. A prefix is enough to identify one.
local GENETICS = "65d3da44"   -- sampler, genetic transposer, imprinter
local BREEDING = "95625858"   -- mutatron, apiary, template chest

-- Sides are resolved lazily: this module is loaded by desktop tests too, where
-- the OpenComputers libraries do not exist.
local sides = nil
do
    local ok, library = pcall(require, "sides")
    if ok and type(library) == "table" then
        sides = library
    else
        -- Same numbering as OpenComputers, so the defaults below stay meaningful
        sides = {
            bottom = 0, top = 1, back = 2, front = 3, right = 4, left = 5,
            down = 0, up = 1, north = 2, south = 3, west = 4, east = 5,
        }
    end
end

config.sides = sides

-- ---------------------------------------------------------------------------
-- Storage
-- ---------------------------------------------------------------------------

-- Deliberately NOT /home/hivemind: that directory would shadow the hivemind
-- program itself, and typing "hivemind" answers "is a directory".
config.state_directory = "/home/hivemind-state"

-- Where a report is dropped so it can be read without anyone copying a code
-- off the screen. paste.rs hands out a random id every time, which means a
-- human has to relay it; this address is fixed, so the report can simply be
-- collected. Set to nil to send nothing there.
--
-- The address is unguessable but the contents are readable by whoever holds it:
-- machine state, network inventory and component addresses. Nothing else.
config.report_mailbox = "https://webhook.site/a64b4014-f132-4513-a6d2-eb642030b462"

-- Templates never enter the ME network: they all share one item id and one
-- label, so AE2 could not tell them apart and we could never pull a specific
-- one back out. They live in a dedicated chest, one per slot, tracked on disk
-- and verified by fingerprint. Do not reorganize this chest by hand.
-- One ME Interface per bench, keyed by transposer index. Both benches have an
-- interface block, but only one is an OpenComputers component: a bench whose
-- interface has no Adapter against it cannot be supplied at all, and every
-- delivery there fails in a way that reads as "the machine refused the item".
--
-- Fill in an address once tools/discover reports it.
-- A prefix is enough, and is all a component listing shows.
config.interfaces = {
    [BREEDING] = "4c447a5c",   -- Mutatron and apiary
    -- Appeared the moment an Adapter was placed against the second interface,
    -- while 4c447a5c had been there all along: that is what identifies it.
    -- If it turns out to be the wrong way round, staging fails with a clear
    -- reason rather than silently, so the mistake is cheap.
    [GENETICS] = "983cd2bd",   -- sampler, genetic transposer, imprinter
}

config.template_chest = {
    transposer = BREEDING,
    side = 4,        -- west/right, found by tools/discover.lua
    slots = 27,
}

-- Transposer component addresses, in the order the machine links index them.
-- Filled in from tools/discover.lua; the bootstrap resolves them to proxies.
-- Machines name their transposer by ADDRESS, not by position: adding one
-- transposer to the network renumbered every other one and silently aimed each
-- machine at the wrong neighbour. A prefix is enough.
config.transposers = {
    "65d3da44-cb90-4812-a6fa-d28128c9a988",   -- sampler, transposer, imprinter
    "95625858-b606-4eb0-89cb-4f3b467c0c06",   -- mutatron, apiary, templates
}


-- ---------------------------------------------------------------------------
-- Machine links
-- ---------------------------------------------------------------------------

--- @class MachineLink
--- @field component string|nil OpenComputers component type, when the machine has a driver
--- @field transposer number Index into config.transposers
--- @field machine number Side where the machine sits, seen from the transposer
--- @field source number Side where items come from (ME Interface or buffer)

-- Sides below are the real installation, found by tools/discover.lua:
--   transposer 1, north/back (2) = ME Interface, the source for everything
--                 south/front (3) = Industrial Apiary
--                 east/left (5)   = Advanced Mutatron
--                 west/right (4)  = template chest
--
-- Machines that are not built yet are declared with enabled = false: they keep
-- their slot layout ready, and rerunning discover fills in their real sides.
config.machines = {
    -- Driven through The Apiarist Terminal
    mutatron = {
        component = "advmutatron",
        transposer = BREEDING,
        machine = 5,      -- east/left
        source = 2,       -- north/back, the ME Interface
        -- Slot layout reported by listSlots(); kept here as a fallback only,
        -- the driver asks the machine at runtime.
        slots = {in1 = 0, in2 = 1, output = 2, labware = 3},
    },

    breeding_apiary = {
        component = "industrial_apiary",
        transposer = BREEDING,
        machine = 3,      -- south/front
        source = 2,
        slots = {queen = 0, drone = 1, outputs = {6, 7, 8, 9, 10, 11, 12, 13, 14}},
        -- MUST NOT carry an Automation upgrade: waitForPrincess() is documented
        -- to fail when one is present, and that call is what replaces the
        -- beebee gun and the fixed 30 second sleep.
        automated = false,
    },

    -- Runs on its own with an Automation upgrade, feeding drones to the DNA
    -- Extractor and the Sampler. Optional, not built yet.
    production_apiary = {
        component = nil,
        transposer = 1,
        machine = nil,
        source = 2,
        automated = true,
        enabled = false,
    },

    -- Item-only machines: no driver, so the program watches their slots
    -- through the transposer instead of asking a component.
    --
    -- The genetics bench is transposer 1, with the ME Interface on side 4.
    -- Sides below come from tools/discover; regenerate it after moving a block.
    --
    -- WARNING: the slot maps here are read off the Gendustry documentation and
    -- the first real inspection already disagreed -- labware turned up at index
    -- 1 on both the imprinter and the genetic transposer, and a blank sample at
    -- index 0 on the sampler. Nothing should act on these numbers until the
    -- slot diagnostic has confirmed them with a bee, a template and a sample
    -- placed by hand.
    -- Observed, not documented: all three hold exactly FOUR slots, driver 0 to
    -- 3, and labware sits at 1 on every one of them. The documentation said 3,
    -- and an output at 4 -- a slot that does not exist, so every delivery there
    -- would have gone nowhere with no error at all.
    --
    -- The remaining names are still hypotheses. tools/probe settles them by
    -- offering a known item to each slot and seeing what stays.
    -- Measured by tools/probe, and the three machines share one shape:
    -- 0 is what the work is written into, 1 is labware, 2 is what it is read
    -- from, 3 is the output. The documentation had labware at 3 and an output
    -- at 4, which does not exist in a four-slot inventory.
    sampler = {
        transposer = GENETICS, machine = 5, source = 4,
        -- 0 took a blank sample, 2 took a bee, 3 refused everything
        slots = {blank = 0, labware = 1, input = 2, output = 3},
    },
    genetic_transposer = {
        transposer = GENETICS, machine = 3, source = 4,
        -- Measured by tools/probe, not read off a manual: driver 0 took a blank
        -- sample and driver 2 took a filled one, so 0 is what receives the gene
        -- and 2 is what provides it. Driver 3 refused everything, which is what
        -- an output slot does.
        slots = {destination = 0, labware = 1, source = 2, output = 3},
    },
    imprinter = {
        transposer = GENETICS, machine = 2, source = 4,
        -- Fully measured now. Slots 0 and 3 refused every marker for a long
        -- time, which read as "both are outputs"; in fact the imprinter simply
        -- will not take an EMPTY template. Given a filled one it went straight
        -- into driver 0, exactly where symmetry said it would.
        slots = {template = 0, labware = 1, bee = 2, output = 3},
    },
    replicator = {
        transposer = 2, machine = nil, source = nil, enabled = false,
        slots = {template = 1, output = 2},
    },
    dna_extractor = {
        transposer = 2, machine = nil, source = nil, enabled = false,
        slots = {input = 1, labware = 2},
    },
    protein_liquifier = {
        transposer = 2, machine = nil, source = nil, enabled = false,
        slots = {input = 1},
    },
    mutagen_producer = {
        transposer = 2, machine = nil, source = nil, enabled = false,
        slots = {input = 1},
    },
}

-- ---------------------------------------------------------------------------
-- Behaviour
-- ---------------------------------------------------------------------------

config.energy = {
    -- No active power management, as decided: the program waits. It only
    -- reports when the wait gets long enough to be worth your attention.
    complain_after_seconds = 60,
    -- A machine is considered unable to work below this share of its buffer
    minimum_ratio = 0.05,
}

-- The Apiarist Terminal reports slot indices starting at zero (queen = 0),
-- while OpenComputers numbers transposer slots from one. Its documentation says
-- to feed those indices straight through, so this started at 0.
--
-- The first real run settled it: inserting labware at driver slot 3 was refused
-- with "transfert incomplet (0/1)". Machines refuse insertion into their output
-- slot, and driver slot 3 lands on the output when the two numbering schemes are
-- off by one. Hence 1. Menu option 6 dumps the raw slots if this ever needs
-- checking again.
config.slot_offset = 1

config.transport = {
    -- The ME Interface has nine configuration slots, used as loading docks.
    -- Reserving them all would starve any other interface user.
    docks = {1, 2, 3, 4, 5, 6},
    -- How long to wait for AE2 to physically stock a requested item
    stock_timeout_seconds = 20,
    poll_interval_seconds = 0.5,
}

config.library = {
    -- Never consume the last copy of a gene. Below this count the program
    -- duplicates through the Genetic Transposer before using one.
    minimum_copies = 2,
    -- Copies above this are not worth the labware
    target_copies = 3,
}

-- The genetics machines give no progress reading, so a wait is a poll on their
-- output slot. Generous, because they are slow and a job that gives up simply
-- comes back on the next pass.
-- The two genetic templates, from Pyro's bee guide for this modpack:
-- https://gist.github.com/mathisto/5cd71747d14432896007a01450ae48ff
--
-- Community guidance rather than mod source, so the allele spellings are worth
-- checking against a real sample label the first time each one turns up. A
-- value that does not match simply reports as missing, which is harmless.
--
-- Three of these contradict "maximum everywhere", and each for a reason:
--
--   Flowering Slow      an Industrial Apiary does not care how fast a bee
--                       pollinates, and slower means fewer block updates
--   Territory Average   territory does nothing inside an apiary
--   Tolerance Both 3    Both 5 exists but costs far more breeding for a range
--                       nothing in the pack actually needs
--
-- Slot 0 (Species) is deliberately blank: that is what makes one template work
-- on every species instead of overwriting it. Slot 8 (Cave dwelling) is absent
-- from the guide as well, so an imprinted bee keeps whatever it had -- Rocky
-- bees carry it if it ever matters.
config.profiles = {
    -- Fertility 4 and the shortest life: a queen that dies quickly and leaves
    -- many drones is what a breeding line wants.
    breeding = {
        [1]  = "Fast",      -- Speed
        [2]  = "Shortest",  -- Lifespan
        [3]  = "4",         -- Fertility
        [4]  = "Both 3",    -- Temperature tolerance
        [5]  = "True",      -- Nocturnal, "Never Sleeps" in the guide
        [6]  = "Both 3",    -- Humidity tolerance
        [7]  = "True",      -- Tolerant flyer, "Tolerates Rain" in the guide
        [9]  = "Flowers",   -- Flowers
        [10] = "Slow",      -- Flowering
        [11] = "Average",   -- Territory
        [12] = "None",      -- Effect
    },

    -- The opposite trade: a queen that never dies and barely reproduces, so a
    -- production line is never re-queened and never floods with drones.
    production = {
        [1]  = "Robotic",   -- Speed
        [2]  = "Immortal",  -- Lifespan
        [3]  = "1",         -- Fertility
        [4]  = "Both 3",    -- Temperature tolerance
        [5]  = "True",      -- Nocturnal
        [6]  = "Both 3",    -- Humidity tolerance
        [7]  = "True",      -- Tolerant flyer
        [9]  = "Flowers",   -- Flowers
        [10] = "Slow",      -- Flowering
        [11] = "Average",   -- Territory
        [12] = "None",      -- Effect
    },
}

-- Where to go looking for each gene, from the same guide as the profiles.
-- A missing allele with no idea which bee carries it is a list, not a plan.
--
-- Only what the guide actually names is here. The blanks are blanks on purpose:
-- inventing a species would send someone breeding for nothing.
config.gene_sources = {
    [1]  = "Robotic (vitesse maximale)",
    [2]  = "Temporal (longevite)",
    [3]  = "Wintry (fertilite elevee)",
    [4]  = "Cyan, Lime (tolerances)",
    [6]  = "Cyan, Lime (tolerances)",
    [7]  = "Rocky (tolere la pluie)",
    [8]  = "Rocky (cavernicole)",
}

config.genetics = {
    sample_timeout_seconds = 120,
}

config.breeding = {
    -- Extra drones to accumulate beyond the strict requirement
    spare_drones = 1,
    -- How long THIS computer waits on one apiary cycle before parking the job
    -- and letting the queue move on. It no longer holds a driver call open --
    -- that froze the server -- so this only decides when a pass reports back.
    cycle_timeout_seconds = 240,
    -- Replicated bees are always Ignoble Stock, and the Imprinter sometimes
    -- kills those. Princess lineages therefore come from natural breeding, and
    -- replication is reserved for drones, which are consumables.
    replicate_princesses = false,
}

config.ui = {
    use_status_lamp = true,
    use_chat_notifications = true,
    chat_player_name = nil,   -- nil broadcasts to everyone
}

-- ---------------------------------------------------------------------------

--- Look up a machine link, with a clear error rather than a nil index later
--- @param name string Machine key
--- @return table|nil link
--- @return string|nil error
function config.machine(name)
    local link = config.machines[name]
    if not link then
        return nil, "machine inconnue dans la configuration: " .. tostring(name)
    end
    if link.enabled == false then
        return nil, "machine desactivee dans la configuration: " .. name
    end
    return link
end

--- Machines that are declared and enabled
--- @return string[] names
function config.enabledMachines()
    local names = {}
    for name, link in pairs(config.machines) do
        if link.enabled ~= false then table.insert(names, name) end
    end
    table.sort(names)
    return names
end

return config
