-- HiveMind: OpenComputers Bee Breeding Automation
-- Requires: Advanced Mutatron, Mechanical User, Assassin Queen in Beebee gun

--[[
Type Definitions:
@alias BeeSpecies string
@alias SideName number

@class MutationData
@field parent1 string First parent species name
@field parent2 string Second parent species name
@field mod string Mod name that adds this species

@class GUIState
@field target string Target species name
@field current_species string Current species being processed
@field step_type string Current step type (Loading, Breeding, etc.)
@field current_step number Current step number
@field total_steps number Total number of steps
@field inventory_status string Inventory status text
@field errors string Error message text
@field status string Overall status (Running, Paused, Error, etc.)
@field progress string Progress description text

@class ControlState
@field paused boolean Whether operation is manually paused
@field error_state boolean Whether system is in error state
@field last_error string Last error message
@field abort_requested boolean Whether user requested abort
@field validation_required boolean Whether error requires validation before resume
--]]

local component = require("component")
local computer = require("computer")
local term = require("term")
local sides = require("sides")
local event = require("event")
local gpu = component.gpu

-- Unguarded, this threw a bare "attempt to index a nil value" when no Redstone Card was fitted,
-- which says nothing about what is missing.
if not component.isAvailable("redstone") then
    error("A Redstone Card is required: the Mechanical User is fired by a redstone signal.")
end

local redstone = component.redstone

-- Optional components for status indicators
local notification_interface = component.isAvailable("notification_interface") and component.notification_interface or nil
local coloredlamp = component.isAvailable("coloredlamp") and component.coloredlamp or nil

-- Check for required components
if not component.isAvailable("inventory_controller") then
    error("Inventory Controller upgrade required!")
end

local inv_controller = component.inventory_controller

-- Forward declarations for the shared state tables.
--
-- Lua resolves a name in a function body against the locals visible where the body is written,
-- so a `local` declared further down the file is invisible to every function above it: the body
-- reads a global instead, and gets nil. waitForBeebeeGun and loadMutatron did exactly that with
-- control_state and raised on their first call. Declaring the three here, and assigning them at
-- their original sites, keeps them in scope for the whole file.
local gui_state
local control_state
local status_colors

-- The size the screen actually ended up at. The GUI frame is drawn against these rather than
-- against 80 by 25, so a tier 3 screen is used at its full size instead of being shrunk to the
-- size of a tier 2 one.
local screen_width, screen_height = 80, 25

-- config is declared here for the same reason: refreshGendustrySlots, just below, reads
-- config.slot_offset. Written above `local config`, it would resolve a nil global and silently
-- fall back to an offset of 1, ignoring whatever check_slots.lua found.
local config

-- Gendustry drivers, as exposed by The-Apiarist-Terminal.
--
-- Two machines have a hand-written driver and are the only ones this program talks to:
-- "advmutatron" and "industrial_apiary". The old heuristic sweep over component.list() guessed
-- names that no mod ever registers, so it never found anything.
--
-- Shared contract for the rest of the file:
--   gendustry.available      boolean, true when at least one driver answered
--   gendustry.adv            address of the "advmutatron" component, or nil
--   gendustry.apiary         address of the "industrial_apiary" component, or nil
--   gendustry.slots.mutatron listSlots() of the mutatron, already shifted to controller indices
--   gendustry.slots.apiary   listSlots() of the apiary, already shifted to controller indices
--   advCall(method, ...)     call the mutatron; returns its values, or nil plus a reason
--   apiaryCall(method, ...)  call the apiary; returns its values, or nil plus a reason
--   config.slot_offset       driver index -> inventory_controller index (see check_slots.lua)
--
-- Every new capability tests gendustry.available (or gendustry.adv / gendustry.apiary for a
-- single machine) and falls back on the existing redstone + inventory_controller path when it
-- is false. Without the mod the program behaves exactly as it does today.
local GENDUSTRY_MUTATRON_KIND = "advmutatron"
local GENDUSTRY_APIARY_KIND = "industrial_apiary"

local gendustry = {
    available = false,
    adv = nil,
    apiary = nil,
    slots = {mutatron = nil, apiary = nil}
}

--- Address of the first component of a kind, or nil when none is on the network.
--- Addresses rather than component.<name>: OpenOS caches a proxy per address in a Lua state
--- that survives a world reload, so a proxy built before a mod update keeps answering with the
--- old method list and a new callback looks like it does not exist.
--- @param kind string Exact component type name
--- @return string|nil address
local function gendustryAddress(kind)
    local ok, listing = pcall(component.list, kind, true)
    if not ok or listing == nil then return nil end

    -- component.list answers a TABLE, not a function: one that can be walked with pairs and also
    -- called like an iterator, through a __call metamethod. Insisting on a function rejected every
    -- real answer, so no driver was ever found in game.
    if type(listing) == "function" then

        return listing()
    end

    if type(listing) == "table" then
        local called, address = pcall(listing)
        if called and address then

            return address
        end

        for address in pairs(listing) do

            return address
        end
    end

    return nil
end

--- Invoke a callback on a component address without ever raising.
--- @param address string|nil Component address
--- @param method string Callback name
--- @return any ... The callback's return values, or nil plus a textual reason
local function driverCall(address, method, ...)
    if not address then return nil, "component not present" end

    local result = table.pack(pcall(component.invoke, address, method, ...))
    if result[1] then return table.unpack(result, 2, result.n) end

    return nil, tostring(result[2] or "call failed with no message")
end

--- Call the Advanced Mutatron driver.
--- @return any ... The callback's return values, or nil plus a reason
function advCall(method, ...)
    return driverCall(gendustry.adv, method, ...)
end

--- Call the Industrial Apiary driver.
--- @return any ... The callback's return values, or nil plus a reason
function apiaryCall(method, ...)
    return driverCall(gendustry.apiary, method, ...)
end

--- Translate a driver slot map into inventory_controller indices.
--- The drivers report raw tile indices; inventory_controller numbers the same slots from one.
--- "size" is a count, not an index, so it is copied through untouched.
--- @param slots table|nil Result of listSlots()
--- @param offset number config.slot_offset
--- @return table|nil shifted
local function shiftDriverSlots(slots, offset)
    if type(slots) ~= "table" then return nil end

    local shifted = {}
    for key, value in pairs(slots) do
        if key == "size" or type(value) ~= "number" and type(value) ~= "table" then
            shifted[key] = value
        elseif type(value) == "number" then
            shifted[key] = value + offset
        else
            local list = {}
            for index, entry in pairs(value) do
                list[index] = type(entry) == "number" and (entry + offset) or entry
            end
            shifted[key] = list
        end
    end

    return shifted
end

--- Resolve the drivers and read their slot maps. Called once after config exists, and again by
--- checkGendustryAPI so an Adapter placed while the program runs is still picked up.
--- @return boolean available True when at least one driver answered
function refreshGendustrySlots()
    gendustry.adv = gendustryAddress(GENDUSTRY_MUTATRON_KIND)
    gendustry.apiary = gendustryAddress(GENDUSTRY_APIARY_KIND)

    local offset = config and config.slot_offset or 1

    gendustry.slots.mutatron = shiftDriverSlots(advCall("listSlots"), offset)
    gendustry.slots.apiary = shiftDriverSlots(apiaryCall("listSlots"), offset)

    -- A component that does not answer listSlots is a ghost: the Adapter has been removed, or
    -- the driver failed to attach. Treat it as absent rather than half usable.
    if not gendustry.slots.mutatron then gendustry.adv = nil end
    if not gendustry.slots.apiary then gendustry.apiary = nil end

    gendustry.available = (gendustry.adv ~= nil) or (gendustry.apiary ~= nil)

    return gendustry.available
end

-- Get component methods for debugging
local function getComponentMethods(comp)
    local methods = {}
    if comp then
        for k, v in pairs(comp) do
            if type(v) == "function" then
                table.insert(methods, k)
            end
        end
    end
    return methods
end

--- Comprehensive bee mutation database
--- @return table<string, {parent1: string, parent2: string, mod: string}> mutations Map of species to their parent combinations
local function loadBeeDatabase()
    local mutations = {}

    -- Forestry Base Bees (https://github.com/ForestryMC/ForestryMC/blob/mc-1.12/src/main/java/forestry/apiculture/genetics/BeeBranchDefinition.java)
    mutations["Imperial"] = {parents = {"Noble", "Majestic"}, mod = "Forestry"}
    mutations["Edenic"] = {parents = {"Tropical", "Exotic"}, mod = "Forestry"}
    mutations["Black"] = {parents = {"White", "Diligent"}, mod = "Forestry"}
    mutations["Vengeful"] = {parents = {"Demonic", "Vindictive"}, mod = "Forestry"}
    mutations["Spectral"] = {parents = {"Ender", "Hermitic"}, mod = "Forestry"}
    mutations["Pink"] = {parents = {"White", "Red"}, mod = "Forestry"}
    mutations["Rural"] = {parents = {"Meadows", "Diligent"}, mod = "Forestry"}
    mutations["Gray"] = {parents = {"Black", "White"}, mod = "Forestry"}
    mutations["Green"] = {parents = {"Blue", "Yellow"}, mod = "Forestry"}
    mutations["Farmerly"] = {parents = {"Rural", "Unweary"}, mod = "Forestry"}
    mutations["Light Gray"] = {parents = {"Gray", "White"}, mod = "Forestry"}
    mutations["Cultivated"] = {parents = {"Meadows", "Common"}, mod = "Forestry"}
    mutations["White"] = {parents = {"Wintry", "Diligent"}, mod = "Forestry"}
    mutations["Majestic"] = {parents = {"Noble", "Cultivated"}, mod = "Forestry"}
    mutations["Avenging"] = {parents = {"Vengeful", "Vindictive"}, mod = "Forestry"}
    mutations["Secluded"] = {parents = {"Austere", "Monastic"}, mod = "Forestry"}
    mutations["Diligent"] = {parents = {"Common", "Cultivated"}, mod = "Forestry"}
    mutations["Fiendish"] = {parents = {"Sinister", "Cultivated"}, mod = "Forestry"}
    mutations["Derpious"] = {parents = {"Marshy", "Cultivated"}, mod = "Forestry"}
    mutations["Hermitic"] = {parents = {"Secluded", "Monastic"}, mod = "Forestry"}
    mutations["Exotic"] = {parents = {"Austere", "Tropical"}, mod = "Forestry"}
    mutations["Yellow"] = {parents = {"Modest", "Diligent"}, mod = "Forestry"}
    mutations["Purple"] = {parents = {"Red", "Blue"}, mod = "Forestry"}
    mutations["Industrious"] = {parents = {"Diligent", "Unweary"}, mod = "Forestry"}
    mutations["Cyan"] = {parents = {"Green", "Blue"}, mod = "Forestry"}
    mutations["Miry"] = {parents = {"Marshy", "Noble"}, mod = "Forestry"}
    mutations["Unweary"] = {parents = {"Diligent", "Cultivated"}, mod = "Forestry"}
    mutations["Sinister"] = {parents = {"Modest", "Cultivated"}, mod = "Forestry"}
    mutations["Noble"] = {parents = {"Cultivated", "Common"}, mod = "Forestry"}
    mutations["Icy"] = {parents = {"Wintry", "Industrious"}, mod = "Forestry"}
    mutations["Lime"] = {parents = {"White", "Green"}, mod = "Forestry"}
    mutations["Vindictive"] = {parents = {"Demonic", "Monastic"}, mod = "Forestry"}
    mutations["Frugal"] = {parents = {"Modest", "Sinister"}, mod = "Forestry"}
    mutations["Demonic"] = {parents = {"Sinister", "Fiendish"}, mod = "Forestry"}
    mutations["Heroic"] = {parents = {"Valiant", "Steadfast"}, mod = "Forestry"}
    mutations["Blue"] = {parents = {"Forest", "Diligent"}, mod = "Forestry"}
    mutations["Phantasmal"] = {parents = {"Ender", "Spectral"}, mod = "Forestry"}
    mutations["Glacial"] = {parents = {"Wintry", "Icy"}, mod = "Forestry"}
    mutations["Orange"] = {parents = {"Yellow", "Red"}, mod = "Forestry"}
    mutations["Agrarian"] = {parents = {"Farmerly", "Industrious"}, mod = "Forestry"}
    mutations["Common"] = {parents = {"Meadows", "Forest"}, mod = "Forestry"}
    mutations["Red"] = {parents = {"Common", "Diligent"}, mod = "Forestry"}
    mutations["Austere"] = {parents = {"Modest", "Frugal"}, mod = "Forestry"}
    mutations["Brown"] = {parents = {"Tropical", "Diligent"}, mod = "Forestry"}

    -- MagicBees (https://github.com/ForestryMC/MagicBees/blob/1.12/src/main/java/magicbees/bees/EnumBeeSpecies.java)
    mutations["Manyullyn"] = {parents = {"Ardite", "Cobalt"}, mod = "MagicBees"}
    mutations["Electrum"] = {parents = {"Argentum", "Auric"}, mod = "MagicBees"}
    mutations["Windy"] = {parents = {"Supernatural", "Ethereal"}, mod = "MagicBees"}
    mutations["Lordly"] = {parents = {"Imperial", "Timely"}, mod = "MagicBees"}
    mutations["Withering"] = {parents = {"Demonic", "Spiteful"}, mod = "MagicBees"}
    mutations["Grounded"] = {parents = {"Smouldering", "Earthen"}, mod = "MagicBees"}
    mutations["Soul"] = {parents = {"Spirit", "Aware"}, mod = "MagicBees"}
    mutations["Porcine"] = {parents = {"Common", "Shulking"}, mod = "MagicBees"}
    mutations["Winsome"] = {parents = {"Oblivion", "Platinum"}, mod = "MagicBees"}
    mutations["Batty"] = {parents = {"Shulking", "Windy"}, mod = "MagicBees"}
    mutations["Charmed"] = {parents = {"Cultivated", "Eldritch"}, mod = "MagicBees"}
    mutations["Scholarly"] = {parents = {"Pupil", "Arcane"}, mod = "MagicBees"}
    mutations["Enchanted"] = {parents = {"Eldritch", "Charmed"}, mod = "MagicBees"}
    mutations["Invisible"] = {parents = {"Mystical", "Mutable"}, mod = "MagicBees"}
    mutations["Crumbling"] = {parents = {"Unusual", "Mutable"}, mod = "MagicBees"}
    mutations["Dreaming"] = {parents = {"Windy", "Somnolent"}, mod = "MagicBees"}
    mutations["Fluxed"] = {parents = {"Electrum", "Destabilized"}, mod = "MagicBees"}
    mutations["Auric"] = {parents = {"Plumbum", "Imperial"}, mod = "MagicBees"}
    mutations["Argentum"] = {parents = {"Modest", "Imperial"}, mod = "MagicBees"}
    mutations["Osmium"] = {parents = {"Argentum", "Cobalt"}, mod = "MagicBees"}
    mutations["Earthen"] = {parents = {"Supernatural", "Ethereal"}, mod = "MagicBees"}
    mutations["Maroon"] = {parents = {"Forest", "Valiant"}, mod = "MagicBees"}
    mutations["Plumbum"] = {parents = {"Common", "Stannum"}, mod = "MagicBees"}
    mutations["Timely"] = {parents = {"Imperial", "Ethereal"}, mod = "MagicBees"}
    mutations["Spiteful"] = {parents = {"Infernal", "Hateful"}, mod = "MagicBees"}
    mutations["Big Bad"] = {parents = {"Shulking", "Mysterious"}, mod = "MagicBees"}
    mutations["Cobalt"] = {parents = {"Infernal", "Imperial"}, mod = "MagicBees"}
    mutations["Cobalt"] = {parents = {"Infernal", "Industrious"}, mod = "MagicBees"}
    mutations["Beefy"] = {parents = {"Common", "Shulking"}, mod = "MagicBees"}
    mutations["Esoteric"] = {parents = {"Cultivated", "Eldritch"}, mod = "MagicBees"}
    mutations["Catty"] = {parents = {"Poultry", "Spidery"}, mod = "MagicBees"}
    mutations["Poultry"] = {parents = {"Common", "Shulking"}, mod = "MagicBees"}
    mutations["Firey"] = {parents = {"Supernatural", "Ethereal"}, mod = "MagicBees"}
    mutations["Floral"] = {parents = {"Botanic", "Blossom"}, mod = "MagicBees"}
    mutations["Invar"] = {parents = {"Ferrous", "Nickel"}, mod = "MagicBees"}
    mutations["Endearing"] = {parents = {"Winsome", "Carbon"}, mod = "MagicBees"}
    mutations["Shocking"] = {parents = {"Smouldering", "Windy"}, mod = "MagicBees"}
    mutations["Aluminum"] = {parents = {"Cultivated", "Industrious"}, mod = "MagicBees"}
    mutations["Supernatural"] = {parents = {"Enchanted", "Charmed"}, mod = "MagicBees"}
    mutations["Dante"] = {parents = {"Austere", "Smouldering"}, mod = "MagicBees"}
    mutations["Platinum"] = {parents = {"Nickel", "Invar"}, mod = "MagicBees"}
    mutations["Destabilized"] = {parents = {"Industrious", "Spiteful"}, mod = "MagicBees"}
    mutations["Aware"] = {parents = {"Attuned", "Ethereal"}, mod = "MagicBees"}
    mutations["Transmuting"] = {parents = {"Unusual", "Mutable"}, mod = "MagicBees"}
    mutations["Hateful"] = {parents = {"Infernal", "Eldritch"}, mod = "MagicBees"}
    mutations["Spirit"] = {parents = {"Aware", "Ethereal"}, mod = "MagicBees"}
    mutations["Rockin'"] = {parents = {"Grounded", "Earthen"}, mod = "MagicBees"}
    mutations["Pupil"] = {parents = {"Arcane", "Monastic"}, mod = "MagicBees"}
    mutations["Stannum"] = {parents = {"Forest", "Industrious"}, mod = "MagicBees"}
    mutations["Draconic"] = {parents = {"Abandoned", "Imperial"}, mod = "MagicBees"}
    mutations["Carbon"] = {parents = {"Spiteful", "Stannum"}, mod = "MagicBees"}
    mutations["Arcane"] = {parents = {"Esoteric", "Mysterious"}, mod = "MagicBees"}
    mutations["Blossom"] = {parents = {"Botanic", "Earthen"}, mod = "MagicBees"}
    mutations["Ferrous"] = {parents = {"Common", "Industrious"}, mod = "MagicBees"}
    mutations["Watery"] = {parents = {"Supernatural", "Ethereal"}, mod = "MagicBees"}
    mutations["Somnolent"] = {parents = {"Rooted", "Watery"}, mod = "MagicBees"}
    mutations["Savant"] = {parents = {"Scholarly", "Pupil"}, mod = "MagicBees"}
    mutations["Lux"] = {parents = {"Infernal", "Smouldering"}, mod = "MagicBees"}
    mutations["Neighsayer"] = {parents = {"Beefy", "Sheepish"}, mod = "MagicBees"}
    mutations["Diamandi"] = {parents = {"Austere", "Auric"}, mod = "MagicBees"}
    mutations["Rooted"] = {parents = {"Forest", "Eldritch"}, mod = "MagicBees"}
    mutations["Cuprum"] = {parents = {"Meadows", "Industrious"}, mod = "MagicBees"}
    mutations["Eldritch"] = {parents = {"Mystical", "Cultivated"}, mod = "MagicBees"}
    mutations["Pyro"] = {parents = {"Dante", "Carbon"}, mod = "MagicBees"}
    mutations["Nickel"] = {parents = {"Ferrous", "Esoteric"}, mod = "MagicBees"}
    mutations["Bronzed"] = {parents = {"Stannum", "Cuprum"}, mod = "MagicBees"}
    mutations["Nameless"] = {parents = {"Oblivion", "Ethereal"}, mod = "MagicBees"}
    mutations["Apatine"] = {parents = {"Rural", "Cuprum"}, mod = "MagicBees"}
    mutations["Tarnished"] = {parents = {"Marshy", "Resilient"}, mod = "MagicBees"}
    mutations["Ethereal"] = {parents = {"Supernatural", "Arcane"}, mod = "MagicBees"}
    mutations["Abandoned"] = {parents = {"Oblivion", "Nameless"}, mod = "MagicBees"}
    mutations["Forlorn"] = {parents = {"Abandoned", "Nameless"}, mod = "MagicBees"}
    mutations["Amped"] = {parents = {"Shocking", "Windy"}, mod = "MagicBees"}
    mutations["Skystone"] = {parents = {"Earthen", "Windy"}, mod = "MagicBees"}
    mutations["Doctoral"] = {parents = {"Timely", "Lordly"}, mod = "MagicBees"}
    mutations["Mutable"] = {parents = {"Unusual", "Eldritch"}, mod = "MagicBees"}
    mutations["Mysterious"] = {parents = {"Forest", "Common"}, mod = "MagicBees"}
    mutations["Sheepish"] = {parents = {"Porcine", "Shulking"}, mod = "MagicBees"}

    -- ExtraBees (https://github.com/ForestryMC/Binnie/blob/master-MC1.12/extrabees/src/main/java/binnie/extrabees/genetics/ExtraBeeDefinition.java)
    mutations["Lustered"] = {parents = {"Forest", "Resilient"}, mod = "ExtraBees"}
    mutations["Tarry"] = {parents = {"Distilled", "Fossilised"}, mod = "ExtraBees"}
    mutations["Malicious"] = {parents = {"Tropical", "Sinister"}, mod = "ExtraBees"}
    mutations["Sugary"] = {parents = {"Rural", "Sweetened"}, mod = "ExtraBees"}
    mutations["Bovine"] = {parents = {"Water", "Farmerly"}, mod = "ExtraBees"}
    mutations["Furious"] = {parents = {"Embittered", "Fiendish"}, mod = "ExtraBees"}
    mutations["Yellorium"] = {parents = {"Frugal", "Nuclear"}, mod = "ExtraBees"}
    mutations["Sepia"] = {parents = {"Marshy", "Valiant"}, mod = "ExtraBees"}
    mutations["Bauxite"] = {parents = {"Resilient", "Diligent"}, mod = "ExtraBees"}
    mutations["Shining"] = {parents = {"Majestic", "Galvanized"}, mod = "ExtraBees"}
    mutations["Viscous"] = {parents = {"Water", "Exotic"}, mod = "ExtraBees"}
    mutations["Turquoise"] = {parents = {"Natural", "Prussian"}, mod = "ExtraBees"}
    mutations["Glutinous"] = {parents = {"Exotic", "Viscous"}, mod = "ExtraBees"}
    mutations["Glittering"] = {parents = {"Majestic", "Rusty"}, mod = "ExtraBees"}
    mutations["Energetic"] = {parents = {"Diligent", "Excited"}, mod = "ExtraBees"}
    mutations["Abyssal"] = {parents = {"Shadowed", "Darkened"}, mod = "ExtraBees"}
    mutations["Bleached"] = {parents = {"Wintry", "Valiant"}, mod = "ExtraBees"}
    mutations["Pyrite"] = {parents = {"Rusty", "Sinister"}, mod = "ExtraBees"}
    mutations["Farmed"] = {parents = {"Meadows", "Farmerly"}, mod = "ExtraBees"}
    mutations["Jaded"] = {parents = {"Ender", "Relic"}, mod = "ExtraBees"}
    mutations["Fruity"] = {parents = {"Sweetened", "Thriving"}, mod = "ExtraBees"}
    mutations["Radioactive"] = {parents = {"Nuclear", "Glittering"}, mod = "ExtraBees"}
    mutations["Lavender"] = {parents = {"Maroon", "Bleached"}, mod = "ExtraBees"}
    mutations["Magenta"] = {parents = {"Blue", "Pink"}, mod = "ExtraBees"}
    mutations["Boggy"] = {parents = {"Miry", "Swamp"}, mod = "ExtraBees"}
    mutations["Light Blue"] = {parents = {"Blue", "White"}, mod = "ExtraBees"}
    mutations["Stained"] = {parents = {"Ebony", "Ocean"}, mod = "ExtraBees"}
    mutations["Glowering"] = {parents = {"Furious", "Excited"}, mod = "ExtraBees"}
    mutations["Nuclear"] = {parents = {"Unstable", "Rusty"}, mod = "ExtraBees"}
    mutations["Frigid"] = {parents = {"Wintry", "Diligent"}, mod = "ExtraBees"}
    mutations["Sweetened"] = {parents = {"Valiant", "Diligent"}, mod = "ExtraBees"}
    mutations["Fuchsia"] = {parents = {"Indigo", "Lavender"}, mod = "ExtraBees"}
    mutations["Gelid"] = {parents = {"Blizzy", "Icy"}, mod = "ExtraBees"}
    mutations["Ripening"] = {parents = {"Sweetened", "Growing"}, mod = "ExtraBees"}
    mutations["Prussian"] = {parents = {"Water", "Valiant"}, mod = "ExtraBees"}
    mutations["Impregnable"] = {parents = {"Cultivated", "Resilient"}, mod = "ExtraBees"}
    mutations["Prehistoric"] = {parents = {"Primeval", "Ancient"}, mod = "ExtraBees"}
    mutations["Decomposing"] = {parents = {"Marshy", "Barren"}, mod = "ExtraBees"}
    mutations["Sphalerite"] = {parents = {"Tarnished", "Sinister"}, mod = "ExtraBees"}
    mutations["Thriving"] = {parents = {"Unweary", "Growing"}, mod = "ExtraBees"}
    mutations["Blutonium"] = {parents = {"Cyanite", "Yellorium"}, mod = "ExtraBees"}
    mutations["Hazardous"] = {parents = {"Austere", "Desolate"}, mod = "ExtraBees"}
    mutations["Corrosive"] = {parents = {"Malicious", "Viscous"}, mod = "ExtraBees"}
    mutations["Oily"] = {parents = {"Ocean", "Primeval"}, mod = "ExtraBees"}
    mutations["Excited"] = {parents = {"Valiant", "Cultivated"}, mod = "ExtraBees"}
    mutations["Galvanized"] = {parents = {"Wintry", "Resilient"}, mod = "ExtraBees"}
    mutations["Ashen"] = {parents = {"Bleached", "Slate"}, mod = "ExtraBees"}
    mutations["Primeval"] = {parents = {"Secluded", "Ancient"}, mod = "ExtraBees"}
    mutations["Robust"] = {parents = {"Tolerant", "Unweary"}, mod = "ExtraBees"}
    mutations["Caustic"] = {parents = {"Fiendish", "Corrosive"}, mod = "ExtraBees"}
    mutations["Lime"] = {parents = {"Natural", "Bleached"}, mod = "ExtraBees"}
    mutations["Ebony"] = {parents = {"Rocky", "Valiant"}, mod = "ExtraBees"}
    mutations["Saffron"] = {parents = {"Meadows", "Valiant"}, mod = "ExtraBees"}
    mutations["Slate"] = {parents = {"Ebony", "Bleached"}, mod = "ExtraBees"}
    mutations["Virulent"] = {parents = {"Malicious", "Infectious"}, mod = "ExtraBees"}
    mutations["Diamond"] = {parents = {"Cultivated", "Lapis"}, mod = "ExtraBees"}
    mutations["River"] = {parents = {"Water", "Diligent"}, mod = "ExtraBees"}
    mutations["Spatial"] = {parents = {"Abnormal", "Hermitic"}, mod = "ExtraBees"}
    mutations["Ocean"] = {parents = {"Water", "Diligent"}, mod = "ExtraBees"}
    mutations["Sticky"] = {parents = {"Viscous", "Glutinous"}, mod = "ExtraBees"}
    mutations["Decaying"] = {parents = {"Meadows", "Desolate"}, mod = "ExtraBees"}
    mutations["Sodalite"] = {parents = {"Lapis", "Diligent"}, mod = "ExtraBees"}
    mutations["Valuable"] = {parents = {"Glittering", "Shining"}, mod = "ExtraBees"}
    mutations["Abnormal"] = {parents = {"Ender", "Secluded"}, mod = "ExtraBees"}
    mutations["Sapphire"] = {parents = {"Water", "Lapis"}, mod = "ExtraBees"}
    mutations["Skeletal"] = {parents = {"Forest", "Desolate"}, mod = "ExtraBees"}
    mutations["Unstable"] = {parents = {"Prehistoric", "Resilient"}, mod = "ExtraBees"}
    mutations["Growing"] = {parents = {"Forest", "Diligent"}, mod = "ExtraBees"}
    mutations["Amber"] = {parents = {"Maroon", "Saffron"}, mod = "ExtraBees"}
    mutations["Distilled"] = {parents = {"Industrious", "Oily"}, mod = "ExtraBees"}
    mutations["Indigo"] = {parents = {"Maroon", "Prussian"}, mod = "ExtraBees"}
    mutations["Desolate"] = {parents = {"Arid", "Barren"}, mod = "ExtraBees"}
    mutations["Corroded"] = {parents = {"Wintry", "Resilient"}, mod = "ExtraBees"}
    mutations["Resilient"] = {parents = {"Industrious", "Robust"}, mod = "ExtraBees"}
    mutations["Fungal"] = {parents = {"Boggy", "Miry"}, mod = "ExtraBees"}
    mutations["Mystical"] = {parents = {"Noble", "Monastic"}, mod = "MagicBees"}
    mutations["Cinnabar"] = {parents = {"Sinister", "Resilient"}, mod = "ExtraBees"}
    mutations["Ruby"] = {parents = {"Modest", "Lapis"}, mod = "ExtraBees"}
    mutations["Darkened"] = {parents = {"Shadowed", "Rocky"}, mod = "ExtraBees"}
    mutations["Blizzy"] = {parents = {"Wintry", "Shulking"}, mod = "ExtraBees"}
    mutations["Absolute"] = {parents = {"Ocean", "Frigid"}, mod = "ExtraBees"}
    mutations["Invincible"] = {parents = {"Common", "Resilient"}, mod = "ExtraBees"}
    mutations["Natural"] = {parents = {"Tropical", "Valiant"}, mod = "ExtraBees"}
    mutations["Tolerant"] = {parents = {"Rocky", "Diligent"}, mod = "ExtraBees"}
    mutations["Ancient"] = {parents = {"Noble", "Diligent"}, mod = "ExtraBees"}
    mutations["Shadowed"] = {parents = {"Rocky", "Sinister"}, mod = "ExtraBees"}
    mutations["Cyanite"] = {parents = {"Nuclear", "Yellorium"}, mod = "ExtraBees"}
    mutations["Fossilised"] = {parents = {"Growing", "Primeval"}, mod = "ExtraBees"}
    mutations["Emerald"] = {parents = {"Forest", "Lapis"}, mod = "ExtraBees"}
    mutations["Infectious"] = {parents = {"Tropical", "Malicious"}, mod = "ExtraBees"}
    mutations["Sodden"] = {parents = {"Boggy", "Damp"}, mod = "ExtraBees"}
    mutations["Arid"] = {parents = {"Meadows", "Frugal"}, mod = "ExtraBees"}
    mutations["Rusty"] = {parents = {"Meadows", "Resilient"}, mod = "ExtraBees"}
    mutations["Classical"] = {parents = {"Greek", "Roman"}, mod = "ExtraBees"}
    mutations["Acidic"] = {parents = {"Corrosive", "Caustic"}, mod = "ExtraBees"}
    mutations["Damp"] = {parents = {"Water", "Miry"}, mod = "ExtraBees"}
    mutations["Creepy"] = {parents = {"Modest", "Desolate"}, mod = "ExtraBees"}
    mutations["Relic"] = {parents = {"Imperial", "Prehistoric"}, mod = "ExtraBees"}
    mutations["Lapis"] = {parents = {"Water", "Resilient"}, mod = "ExtraBees"}
    mutations["Ecstatic"] = {parents = {"Excited", "Energetic"}, mod = "ExtraBees"}
    mutations["Barren"] = {parents = {"Common", "Arid"}, mod = "ExtraBees"}
    mutations["Blooming"] = {parents = {"Industrious", "Thriving"}, mod = "ExtraBees"}
    mutations["Azure"] = {parents = {"Prussian", "Bleached"}, mod = "ExtraBees"}
    mutations["Greek"] = {parents = {"Roman", "Marble"}, mod = "ExtraBees"}
    mutations["Roman"] = {parents = {"Marble", "Heroic"}, mod = "ExtraBees"}
    mutations["Leaden"] = {parents = {"Meadows", "Resilient"}, mod = "ExtraBees"}
    mutations["Fermented"] = {parents = {"Farmerly", "Meadows"}, mod = "ExtraBees"}
    mutations["Esmeraldi"] = {parents = {"Austere", "Argentum"}, mod = "ExtraBees"}
    mutations["Quantum"] = {parents = {"Spectral", "Spatial"}, mod = "ExtraBees"}
    mutations["Celebratory"] = {parents = {"Austere", "Excited"}, mod = "ExtraBees"}
    mutations["Volcanic"] = {parents = {"Demonic", "Furious"}, mod = "ExtraBees"}

    -- Career Bees mod (https://github.com/rwtema/Careerbees/blob/master/src/main/java/com/rwtema/careerbees/bees/CareerBeeSpecies.java)
    mutations["PHD"] = {parents = {"Graduate", "Student"}, mod = "Career Bees"}
    mutations["Clockwork"] = {parents = {"Smelter", "Engineer"}, mod = "Career Bees"}
    mutations["Junk Seller"] = {parents = {"Common", "Buisness"}, mod = "Career Bees"}
    mutations["Engineer"] = {parents = {"Noble", "PHD"}, mod = "Career Bees"}
    mutations["Honey-Smelter"] = {parents = {"Graduate", "Smelter"}, mod = "Career Bees"}
    mutations["Thief"] = {parents = {"Sinister", "Police"}, mod = "Career Bees"}
    mutations["Priest"] = {parents = {"Graduate", "Yente"}, mod = "Career Bees"}
    mutations["Quantum Charming"] = {parents = {"Phantasmal", "Mad Scientist"}, mod = "Career Bees"}
    mutations["Mason"] = {parents = {"Smelter", "Graduate"}, mod = "Career Bees"}
    mutations["Yente"] = {parents = {"Student", "Husbandry"}, mod = "Career Bees"}
    mutations["Graduate"] = {parents = {"Common", "Student"}, mod = "Career Bees"}
    mutations["Rainbow"] = {parents = {"Artistic", "PHD"}, mod = "Career Bees"}
    mutations["Buisness"] = {parents = {"Imperial", "PHD"}, mod = "Career Bees"}
    mutations["Butcher"] = {parents = {"Lumber", "Graduate"}, mod = "Career Bees"}
    mutations["Police"] = {parents = {"Valiant", "Graduate"}, mod = "Career Bees"}
    -- mutations["Mad Scientist"] = {parents = {"Science", "Engineer"}, mod = "Career Bees"}
    mutations["Artistic"] = {parents = {"Cultivated", "Graduate"}, mod = "Career Bees"}
    mutations["Science"] = {parents = {"PHD", "Industrious"}, mod = "Career Bees"}
    mutations["Husbandry"] = {parents = {"Meadows", "Graduate"}, mod = "Career Bees"}
    mutations["Lumber"] = {parents = {"Forest", "Graduate"}, mod = "Career Bees"}
    mutations["Plague"] = {parents = {"Sinister", "Doctor"}, mod = "Career Bees"}
    mutations["Student"] = {parents = {"Common", "Cultivated"}, mod = "Career Bees"}
    mutations["Politician"] = {parents = {"Devil", "Thief"}, mod = "Career Bees"}
    mutations["Assassin"] = {parents = {"Police", "Devil"}, mod = "Career Bees"}
    mutations["Robot"] = {parents = {"Clockwork", "Electrician"}, mod = "Career Bees"}
    mutations["Devil"] = {parents = {"Smelter", "Demonic"}, mod = "Career Bees"}
    mutations["Quantum Strange"] = {parents = {"Mad Scientist", "Phantasmal"}, mod = "Career Bees"}
    mutations["N.C.A."] = {parents = {"Devil", "Politician"}, mod = "Career Bees"}
    mutations["Electrician"] = {parents = {"Clockwork", "Engineer"}, mod = "Career Bees"}
    mutations["Smelter"] = {parents = {"Graduate", "Industrious"}, mod = "Career Bees"}
    mutations["Collecting"] = {parents = {"Student", "Common"}, mod = "Career Bees"}
    mutations["Doctor"] = {parents = {"PHD", "Majestic"}, mod = "Career Bees"}
    mutations["Temporal"] = {parents = {"Quantum Charming", "Quantum Strange"}, mod = "Career Bees"}

    -- MeatballCraft Custom Bees (https://github.com/sainagh/meatballcraft/blob/main/config/gendustry/meatball_bees.cfg)
    mutations["Baguette"] = {parents = {"Thief", "Pupil"}, mod = "MeatballCraft"}
    mutations["RestlessClam"] = {parents = {"White", "Shocking"}, mod = "MeatballCraft"}
    mutations["Formic"] = {parents = {"Meadows", "Acidic"}, mod = "MeatballCraft"}
    mutations["Shadow46x2"] = {parents = {"Fermented", "Transmuting"}, mod = "MeatballCraft"}
    mutations["LordRaine"] = {parents = {"Sorcerous", "Temporal"}, mod = "MeatballCraft"}
    mutations["NerdySpider"] = {parents = {"Phantasmal", "Esmeraldi"}, mod = "MeatballCraft"}
    mutations["Fios"] = {parents = {"Light Blue", "Classical"}, mod = "MeatballCraft"}
    mutations["Luctor"] = {parents = {"Rainbow", "Abyssal"}, mod = "MeatballCraft"}
    mutations["Balanced"] = {parents = {"Temporal", "Forlorn"}, mod = "MeatballCraft"}
    mutations["Sandman366"] = {parents = {"Black", "Firey"}, mod = "MeatballCraft"}
    mutations["KurryCat"] = {parents = {"Scholarly", "PHD"}, mod = "MeatballCraft"}
    mutations["Thermally Expanded"] = {parents = {"Pyro", "PHD"}, mod = "MeatballCraft"}
    mutations["Hyperventilating"] = {parents = {"Imperial", "Student"}, mod = "MeatballCraft"}
    mutations["EMBee"] = {parents = {"Ethereal", "Arcane"}, mod = "MeatballCraft"}
    mutations["Experienced"] = {parents = {"Radiant", "Armored"}, mod = "MeatballCraft"}
    mutations["Freeky"] = {parents = {"Sweetened", "EMBee"}, mod = "MeatballCraft"}
    mutations["Pyromaniacal"] = {parents = {"Devil", "Rainbow"}, mod = "MeatballCraft"}
    mutations["SpoonyPanda"] = {parents = {"Supernatural", "Resilient"}, mod = "MeatballCraft"}
    mutations["High-Pitched"] = {parents = {"Oxygen", "Deep Learner"}, mod = "MeatballCraft"}
    mutations["Nuclear Technician"] = {parents = {"Bomber", "PHD"}, mod = "MeatballCraft"}
    mutations["Dentist"] = {parents = {"High-Pitched", "Hyperventilating"}, mod = "MeatballCraft"}
    mutations["Chevron"] = {parents = {"Light Blue", "Robot"}, mod = "MeatballCraft"}
    mutations["Pyramid"] = {parents = {"Lordly", "Temporal"}, mod = "MeatballCraft"}
    mutations["Mathias"] = {parents = {"Ringbearer", "Robust"}, mod = "MeatballCraft"}
    mutations["Ringbearer"] = {parents = {"Glittering", "Endearing"}, mod = "MeatballCraft"}
    mutations["Stargazer"] = {parents = {"Quantum", "Classical"}, mod = "MeatballCraft"}
    mutations["Aedial"] = {parents = {"Skeletal", "Scholarly"}, mod = "MeatballCraft"}
    mutations["Buried"] = {parents = {"Skystone", "Valuable"}, mod = "MeatballCraft"}
    mutations["Isekai"] = {parents = {"Crepuscular", "Deep Learner"}, mod = "MeatballCraft"}
    mutations["Meatball"] = {parents = {"Industrious", "Common"}, mod = "MeatballCraft"}
    mutations["Tinkerest"] = {parents = {"Blutonium", "PHD"}, mod = "MeatballCraft"}
    mutations["Connor"] = {parents = {"Radioactive", "Draconic"}, mod = "MeatballCraft"}
    mutations["Controller"] = {parents = {"Ringbearer", "Chevron"}, mod = "MeatballCraft"}
    mutations["Agricultural"] = {parents = {"Virulent", "Doctoral"}, mod = "MeatballCraft"}
    mutations["Heraldry"] = {parents = {"Spectral", "Endearing"}, mod = "MeatballCraft"}
    mutations["StaffiX"] = {parents = {"Water", "Prehistoric"}, mod = "MeatballCraft"}
    mutations["Herblore"] = {parents = {"Esoteric", "Quantum"}, mod = "MeatballCraft"}
    mutations["Necronomibee"] = {parents = {"Savant", "Abyssal"}, mod = "MeatballCraft"}
    mutations["Serenading"] = {parents = {"Arcane", "Radiant"}, mod = "MeatballCraft"}
    mutations["ChaosStrikez"] = {parents = {"Energetic", "Savant"}, mod = "MeatballCraft"}
    mutations["UselessForce"] = {parents = {"Red", "Fiendish"}, mod = "MeatballCraft"}

    return mutations
end

local mutations = loadBeeDatabase()

-- System configuration
config = {
    -- General settings
    -- The face of the COMPUTER the redstone leaves from, on its way to the Mechanical User.
    --
    -- Up, because it needs no compass at all and the wire is two dust long: one on top of the
    -- computer, one on top of the Adapter, which puts it against the Mechanical User sitting on
    -- the apiary. front/back/left/right are resolved through the case's own facing, which cannot
    -- be read off the world, so they can only be found by trial -- and a wrong guess raises a
    -- signal into whatever happens to sit there.
    mech_user_side = sides.up,
    pulse_duration = 1,               -- Duration of redstone pulse in seconds
    apiary_wait_time = 30,            -- Time to wait for apiary to process queen (seconds)
    collection_wait_time = 5,         -- Time between collection attempts
    add_drone_count = 0,              -- Number of additional drones to produce during accumulation

    -- Adjacent inventories other than the two configured chests are only scanned when they hold
    -- at least this many slots, so a furnace or a small machine is not mistaken for storage. The
    -- configured input and output chests are always scanned, whatever their size. Lower this if
    -- you keep bees in a small modded container.
    min_scan_inventory_size = 10,

    -- The mutatron eats both parents. A species with no recipe -- one you found, traded or were
    -- given -- cannot be made again, so spending the last one is irreversible. The plan screen
    -- says which ones a run will use up before you start it; set false to hide that warning.
    warn_last_base_species = true,
    enabled_mods = {"Forestry", "MagicBees", "ExtraBees", "Career Bees", "MeatballCraft"},  -- Mods to include in bee list (nil for all)

    -- Status indicators
    use_status_lamp = true,           -- Enable colored lamp status indicator
    use_chat_notifications = true,    -- Enable Notification Interface notifications
    chat_player_name = nil,           -- Player name for notifications (not used with Notification Interface)

    -- Machine positions, as seen from the block holding the inventory controller (the Adapter).
    -- These are NOT sides of the computer: only mech_user_side below is. Run check_slots to read
    -- the real ones off your build -- its SIDES block names what sits on each of the six.
    mutatron_side = sides.right,      -- Advanced Mutatron location
    apiary_side = sides.left,         -- Industrial Apiary location
    input_chest_side = sides.back,    -- Princess/drone/labware input chest
    output_chest_side = sides.down,   -- Product output chest

    -- Where to read the beebee gun, or nil when the Mechanical User is not against the adapter.
    -- It cannot be: it has to touch the apiary to click it, and two blocks already touching each
    -- other share no neighbour. Left nil, the program says once that it cannot verify the gun and
    -- carries on rather than blocking on a slot it will never see.
    mech_user_inventory_side = nil,

    -- Slot configurations
    -- These literals are fallbacks for the degraded mode only (no drivers on the network).
    -- When the drivers answer, applyDriverSlots() overwrites them with listSlots() corrected by
    -- config.slot_offset. BLOCKED BY Q3: the offset itself is decided in game by check_slots.lua,
    -- so no index below may be trusted as an absolute value.
    mutatron_input_slots = {1, 2},    -- Princess, drone slots in mutatron (driver in1 = 0, in2 = 1)
    mutatron_output_slot = 3,         -- Queen output slot (driver output = 2)
    mutatron_labware_slot = 4,        -- Labware slot in mutatron (driver labware = 3)
    apiary_input_slot = 1,            -- Queen input slot in apiary (driver queen = 0)
    apiary_output_slots = {7, 8, 9, 10, 11, 12, 13, 14, 15},  -- driver outputs 6..14, plus offset
    beebee_gun_slot = 1,              -- Slot where beebee gun should be in Mechanical User

    -- Gendustry drivers (The-Apiarist-Terminal)
    -- The drivers report raw tile slot indices, inventory_controller numbers them from one:
    -- controller_slot = driver_slot + slot_offset. Confirmed in game against a loaded Industrial
    -- Apiary: 2 of 2 occupied slots line up at +1, none at 0 or -1. The convention is OpenComputers'
    -- own, so it holds for every machine, not just that one.
    slot_offset = 1,                  -- Measured in game: controller_slot = driver_slot + 1
    report_path = "/home/hivemind_report.txt",  -- Diagnostic report written by checkGendustryAPI

    -- Mutagen management (task 10)
    mutagen_reserve_mb = 1000,        -- Millibuckets the tank must hold before a cycle is started
    mutagen_wait_timeout = 120,       -- Seconds to wait for the tank to refill before giving up

    -- Species registry, genetics and hive display (tasks 26, 27, 29)
    species_audit_max_lines = 12,     -- Lines printed per direction by the startup audit
    dominance_weighting = false,      -- Weight a cross by the dominance of its species allele
    recessive_step_weight = 2,        -- Cost of a cross whose species allele is recessive
    hive_conditions_refresh = 5,      -- Seconds between two readings of the hive modifiers

    -- Driver driven timings (used only when the Gendustry drivers are reachable)
    mutatron_timeout = 180,           -- Max wait for "advmutatron_finished" (seconds)
    apiary_cycle_timeout = 600,       -- Max wait for "apiary_finished" (seconds)
    apiary_mating_timeout = 60,       -- Max wait for a princess to be mated (seconds)
    beebee_gun_retries = 3,           -- Shots allowed before declaring the gun empty
    signal_interval_ticks = 20        -- Output scan rate; _started/_finished are never throttled
}

-- Resolve the Gendustry drivers now that config.slot_offset is known. The socle above is
-- declared before config, so slot translation cannot happen there.
refreshGendustrySlots()

-- Generate dynamic bee list from mutations database
local function generateBeeList(modlist)
    local bees = {}
    local seen = {}

    local function add(species)
        if species and not seen[species] then
            seen[species] = true
            table.insert(bees, species)
        end
    end

    -- Add all bees from mutations
    for species, data in pairs(mutations) do
        if not modlist or (modlist and modlist[data.mod]) then
            add(species)

            -- And their parents. The database is keyed by what a cross PRODUCES, so a base
            -- species -- Forest, Meadows, the ones actually in the starting chest -- is never a
            -- key. Left out, extractSpecies could not name them, and scanInventory reported an
            -- empty chest while looking straight at them.
            for _, parent in ipairs(data.parents or {}) do
                add(parent)
            end
        end
    end

    -- Sort alphabetically for easier browsing
    table.sort(bees)

    return bees
end

local available_bees = generateBeeList()

-- Filter bees by mod
local function getBeesByMod(mod_name)
    local filtered = {}

    for species, data in pairs(mutations) do
        if data.mod == mod_name then
            table.insert(filtered, species)
        end
    end

    table.sort(filtered)

    return filtered
end

-- Current inventory
local inventory = {
    princesses = {},
    drones = {}
}

--- Use the largest resolution this GPU and screen can manage
---
--- setResolution(80, 25) was hardcoded, so a tier 3 screen -- 160 by 50 -- was cut down to the
--- size of a tier 2 one. The pair is only as good as its weaker half, which is what
--- maxResolution already answers.
--- @return number width, number height The resolution in use
function applyBestResolution()
    local ok, width, height = pcall(gpu.maxResolution)

    if not ok or type(width) ~= "number" or type(height) ~= "number" then
        width, height = 80, 25
    end

    -- The frame below assumes at least the tier 2 size; anything smaller would draw outside it.
    width = math.max(80, math.floor(width))
    height = math.max(25, math.floor(height))

    pcall(gpu.setResolution, width, height)

    screen_width, screen_height = width, height

    return width, height
end

-- Clear screen and set up display
function setupDisplay()
    -- Resolution first, then clear. Changing it afterwards redraws the old buffer at the new
    -- size, which is what left the previous screen showing through the frame.
    applyBestResolution()
    term.clear()
    gpu.setBackground(0x000000)  -- TODO: better color (slate gray instead of black?)
    gpu.setForeground(0xFFFFFF)  -- TODO: better color (light gray instead of white?)

    print("=== HiveMind: Bee Breeding Automation ===")
    print()

    -- Set initial status
    updateStatusIndicators("idle", "System started - Ready for commands")
end

--- Note where a bee was found, so the plan can be questioned
---
--- "It says I have a Cultivated -- where does that come from?" had no answer: the scan counted
--- bees and threw away everything else. It now keeps the side, the slot and the label it read.
--- @param species string Species the item was identified as
--- @param kind string "princess" or "drone"
--- @param side number Inventory side it was found on
--- @param slot number Slot within that inventory
--- @param label string The item name that was read
function recordBeeSource(species, kind, side, slot, label)
    inventory.sources = inventory.sources or {}

    local key = species .. " " .. kind
    inventory.sources[key] = inventory.sources[key] or {}

    table.insert(inventory.sources[key], {
        species = species, kind = kind, side = side, slot = slot, label = label,
    })
end

--- Print what the scan actually found, species by species, and where
function printInventoryDetail()
    local keys = {}
    for key in pairs(inventory.sources or {}) do
        table.insert(keys, key)
    end
    table.sort(keys)

    if #keys == 0 then
        print("No bees identified in any connected inventory.")

        return
    end

    print()
    print("Bees found, and where:")

    for _, key in ipairs(keys) do
        local entries = inventory.sources[key]
        local first = entries[1]
        local places = {}

        for _, entry in ipairs(entries) do
            table.insert(places, getSideName(entry.side) .. " slot " .. entry.slot)
        end

        print(string.format("  %-24s x%-3d read as \"%s\"  (%s)", key, #entries,
            tostring(first.label), table.concat(places, ", ")))
    end
end

-- Scan inventories for princesses and drones (including input/output chests)
function scanInventory()
    print("Scanning inventories for bees...")
    inventory.princesses = {}
    inventory.drones = {}
    inventory.sources = {}

    local total_inventories = 0

    -- Priority scan: Input and output chests first
    local priority_sides = {
        {side = config.input_chest_side, name = "input chest"},
        {side = config.output_chest_side, name = "output chest"}
    }

    for _, priority in ipairs(priority_sides) do
        local side = priority.side
        local name = priority.name
        local inv_size = inv_controller.getInventorySize(side)

        -- TODO: refactor to avoid code duplication
        if inv_size then
            total_inventories = total_inventories + 1
            print("Scanning " .. name .. " (" .. inv_size .. " slots)")

            for slot = 1, inv_size do
                local stack = inv_controller.getStackInSlot(side, slot)
                if stack then
                    local item_name = stack.label or stack.name or ""

                    -- TODO: if we find any queen, we should kill them to get princess + drone back and rescan
                    if item_name:lower():find("princess") or item_name:lower():find("queen") then
                        local species = extractSpecies(item_name)
                        if species then
                            table.insert(inventory.princesses, species)
                            recordBeeSource(species, "princess", side, slot, item_name)
                        end
                    elseif item_name:lower():find("drone") then
                        local species = extractSpecies(item_name)
                        if species then
                            table.insert(inventory.drones, species)
                            recordBeeSource(species, "drone", side, slot, item_name)
                        end
                    end
                end
            end
        end
    end

    -- Check all other adjacent inventories (10+ slots)
    local all_sides = {sides.up, sides.down, sides.north, sides.south, sides.east, sides.west}

    for _, side in ipairs(all_sides) do
        -- Skip if this is already scanned as input/output chest
        local skip = false
        for _, priority in ipairs(priority_sides) do
            if side == priority.side then
                skip = true
                break
            end
        end

        if not skip then
            local inv_size = inv_controller.getInventorySize(side)

            if inv_size and inv_size >= (config.min_scan_inventory_size or 10) then
                total_inventories = total_inventories + 1
                print("Found inventory on " .. getSideName(side) .. " side with " .. inv_size .. " slots")

                -- Scan this inventory
                for slot = 1, inv_size do
                    local stack = inv_controller.getStackInSlot(side, slot)
                    if stack then
                        local item_name = stack.label or stack.name or ""
                        if item_name:lower():find("princess") or item_name:lower():find("queen") then
                            local species = extractSpecies(item_name)
                            if species then
                                table.insert(inventory.princesses, species)
                                recordBeeSource(species, "princess", side, slot, item_name)
                            end
                        elseif item_name:lower():find("drone") then
                            local species = extractSpecies(item_name)
                            if species then
                                table.insert(inventory.drones, species)
                                recordBeeSource(species, "drone", side, slot, item_name)
                            end
                        end
                    end
                end
            end
        end
    end

    if total_inventories == 0 then
        print("No inventories found!")
        print("Make sure input/output chests and storage are properly connected.")
    else
        print("Scanned " .. total_inventories .. " inventories")
        print("Found " .. #inventory.princesses .. " princesses/queens, " .. #inventory.drones .. " drones")
        printInventoryDetail()
    end
end

--- Helper function to get side name for display
--- @param side number Side constant from sides enum
--- @return string sideName Human-readable side name
function getSideName(side)
    local side_names = {
        [sides.up] = "top",
        [sides.down] = "bottom",
        [sides.north] = "north",
        [sides.south] = "south",
        [sides.east] = "east",
        [sides.west] = "west"
    }
    return side_names[side] or "unknown"
end

-- Extract species name from item name
--
-- Keeps the longest match rather than the first. available_bees is sorted alphabetically, so
-- returning the first hit made "Uncommon Queen" resolve to "Common": every species whose name is
-- a substring of a longer one was shadowing it. Plain find, because a species name is data and
-- must not be read as a pattern.
function extractSpecies(itemName)
    local best = nil

    -- Whole word, through the same test the mutatron output validation uses: a substring match
    -- reads "Common" out of "Uncommon Princess". The longest match still wins, so a two-word
    -- species is preferred over the one-word species contained in it.
    for _, species in ipairs(available_bees) do
        if speciesMatchesItem(itemName, species) then
            if not best or #species > #best then
                best = species
            end
        end
    end

    return best
end

-- New tree-based breeding path calculation
function calculateBreedingPath(target)
    print("Calculating breeding strategy for " .. target .. "...")

    -- Check if we already have the target
    if hasSpecies(target) then
        return {
            tree = nil,
            starting_princesses = {},
            drone_requirements = {},
            total_steps = 0,
            target = target
        }
    end

    -- Build the breeding tree
    local tree = buildBreedingTree(target)
    if not tree then
        print("ERROR: Cannot find path to " .. target)
        return nil
    end

    -- Clean the tree (remove duplicate drone requirements)
    cleanBreedingTree(tree)

    -- Extract drone requirements and calculate steps
    local drone_requirements = calculateDroneRequirements(tree)
    local total_steps = countTreeSteps(tree)

    -- Calculate base species requirements (this gives us the actual starting princesses needed)
    local missing_princesses, missing_drones = calculateMissingBaseSpecies(tree, drone_requirements)

    -- The starting princesses are just the base species that we need as princesses
    local starting_princesses = {}
    local base_princesses_needed = {}
    local base_drones_needed = {}

    findBaseSpeciesNeeded(tree, base_princesses_needed, base_drones_needed)

    for species, count in pairs(base_princesses_needed) do
        table.insert(starting_princesses, species)
    end

    -- pairs() has no defined order and Lua randomises string hashing per process, so the same
    -- plan listed its starting species differently on every run. Sort, so the plan reads the
    -- same twice and a diff between two runs means something.
    table.sort(starting_princesses)

    -- Check if plan can be executed (no missing base species)
    local can_execute = true
    for _, _ in pairs(missing_princesses) do
        can_execute = false
        break
    end
    if can_execute then
        for _, _ in pairs(missing_drones) do
            can_execute = false
            break
        end
    end

    -- Perform sanity checks on the optimized tree
    local sanity_results = performTreeSanityChecks(tree, target)

    -- Handle critical errors (plan is invalid)
    if sanity_results.has_errors then
        print("❌ CRITICAL ERRORS detected in breeding plan:")
        for _, error in ipairs(sanity_results.errors) do
            print("  " .. error.message)
            if error.path then
                print("    Location: " .. error.path)
            end
        end
        -- Return error details for debugging instead of nil
        return {
            tree = tree,
            starting_princesses = starting_princesses,
            drone_requirements = drone_requirements,
            total_steps = total_steps,
            target = target,
            missing_princesses = missing_princesses,
            missing_drones = missing_drones,
            can_execute = false,
            critical_errors = sanity_results.errors,
            plan_failed = true,
            sanity_issues = sanity_results.warnings
        }
    end

    -- Handle warnings (plan is valid but suboptimal)
    if sanity_results.has_warnings then
        print("⚠️  Optimization warnings:")
        for _, warning in ipairs(sanity_results.warnings) do
            print("  " .. warning.message)
            if warning.type == "missed_reuse" then
                for species, details in pairs(warning.details) do
                    if details.potential_additional_reuse then
                        local reused_count = details.reused or 0
                        print("    " .. species .. ": " .. details.occurrences .. " occurrences, " .. reused_count .. " reused, could reuse " .. details.potential_additional_reuse .. " more")
                    else
                        print("    " .. species .. ": " .. details.occurrences .. " occurrences, no reuse")
                    end
                end
            end
        end
    end

    return {
        tree = tree,
        starting_princesses = starting_princesses,
        drone_requirements = drone_requirements,
        total_steps = total_steps,
        target = target,
        missing_princesses = missing_princesses,
        missing_drones = missing_drones,
        can_execute = can_execute,
        sanity_issues = sanity_results.warnings -- Only pass warnings to artifacts (errors already failed the plan)
    }
end

-- Build breeding tree with left (princess) and right (drone) branches
function buildBreedingTree(species)
    -- Base case: if no mutation exists, this is a base species
    if not mutations[species] then
        return {
            species = species,
            left_parent = nil,
            right_parent = nil,
            need_princess = not hasSpeciesPrincess(species),
            need_drone = not hasSpeciesDrone(species),
            drone_count = 0
        }
    end

    local parents = mutations[species].parents
    local left_parent = parents[1]  -- Princess parent (golden path)
    local right_parent = parents[2] -- Drone parent

    local tree = {
        species = species,
        left_parent = nil,
        right_parent = nil,
        need_princess = not hasSpeciesPrincess(species),
        need_drone = not hasSpeciesDrone(species),
        drone_count = 0
    }

    -- ALWAYS build complete tree - build both parent branches
    tree.left_parent = buildBreedingTree(left_parent)
    tree.right_parent = buildBreedingTree(right_parent)

    return tree
end

-- Clean breeding tree using breadth-first stock optimization + climbing optimization
function cleanBreedingTree(tree)
    if not tree then return end

    -- Step 1: Complete tree is already built by buildBreedingTree

    -- Step 2: Breadth-first stock optimization - remove sub-trees for species we have in stock
    optimizeTreeByStock(tree)

    -- Step 3: Pre-exploration to analyze species occurrences and complexities
    local species_info = {}
    preExploreTree(tree, species_info)

    -- Step 4: Climbing optimization for drone accumulation with smart branch selection
    local accumulated_drones = {}
    climbingOptimizeForAccumulation(tree, accumulated_drones, species_info, nil)

    -- Step 5: Smart starting-node-based reuse optimization (prevents circular dependencies)
    strategicReuseOptimization(tree, species_info)

    -- Step 6: Ensure that for every required dependency species, at least one breeding-capable node exists
    -- Only perform repair if the current plan cannot execute according to our dry-run simulator.
    if not simulateExecutionFeasibleForPlan or not simulateExecutionFeasibleForPlan(tree) then
        ensureBreedingSourcesForDependencies(tree)
    end

    -- Note: We intentionally skip a final global reuse pass here. A late global pass can
    -- re-trigger dependency restorations and inflate steps. Local sibling reuse (e.g.,
    -- Platinum/Invar/Nickel) is already handled inside strategicReuseOptimization safely.
    -- However, to stabilize immediate sibling cases post-restore, enforce a single local pass.
    local function _findInSubtree(subtree, species)
        local found = nil
        local function dfs(n)
            if not n or found then return end
            if n.species == species and not n.reusing_drone then
                found = n
                return
            end
            dfs(n.left_parent)
            dfs(n.right_parent)
        end
        dfs(subtree)
        return found
    end
    local function _convertToReuse(n)
        n.reusing_drone = true
        n.left_parent = nil
        n.right_parent = nil
    end
    local function _enforceLocalSiblingReuse(n, root)
        if not n then return end
        local L, R = n.left_parent, n.right_parent
        if L and R and not (L.reusing_drone or R.reusing_drone) then
            local prefer_L = dependsOnSpecies(R, L.species)
            local prefer_R = dependsOnSpecies(L, R.species)
            -- Base-species rule override: keep base as breeder (except Monastic), reuse non-base
            local function is_base(spec)
                return mutations[spec] == nil
            end
            local function is_monastic(spec)
                return spec == "Monastic"
            end
            local L_base, R_base = is_base(L.species), is_base(R.species)
            if L_base ~= R_base then
                if L_base and not is_monastic(L.species) then
                    prefer_L, prefer_R = false, true
                elseif R_base and not is_monastic(R.species) then
                    prefer_L, prefer_R = true, false
                end
            end
            if prefer_L then
                local alt = _findInSubtree(R, L.species)
                if alt and alt ~= L and canSafelyConvertToReuse(L, alt, root, L.species, true) then
                    _convertToReuse(L)
                end
            elseif prefer_R then
                local alt = _findInSubtree(L, R.species)
                if alt and alt ~= R and canSafelyConvertToReuse(R, alt, root, R.species, true) then
                    _convertToReuse(R)
                end
            end
        end
        _enforceLocalSiblingReuse(L, root)
        _enforceLocalSiblingReuse(R, root)
    end
    _enforceLocalSiblingReuse(tree, tree)
end

-- Strategic reuse optimization using starting-node approach to prevent circular dependencies
-- Strategic reuse optimization using depth-based selective un-reusing
function strategicReuseOptimization(tree, species_info)
    if not tree then return end

    -- Convert a node to reuse (clear parents)
    local function convertToReuse(node)
        node.reusing_drone = true
        node.left_parent = nil
        node.right_parent = nil
    end

    -- Traverse top-down and, per parent, convert at most one child to reuse (prefer higher cost)
    local function optimizeAtNode(node, primary_nodes, species_counts)
        if not node then return false end

        local changed = false

        local L = node.left_parent
        local R = node.right_parent
        if L and R then
            -- Per-decision memoized cost function to reflect current tree state accurately
            local memo = {}
            local function cost(n)
                if not n then return 0 end
                local v = memo[n]
                if v ~= nil then return v end
                -- Dominance-weighted cost; identical to countTreeSteps while
                -- config.dominance_weighting is off (task 27)
                local c = countTreeCost(n)
                memo[n] = c
                return c
            end
            -- Helper: find species node in a subtree
            local function findInSubtree(subtree, species)
                local found = nil
                local function dfs(n)
                    if not n or found then return end
                    if n.species == species and not n.reusing_drone then
                        found = n
                        return
                    end
                    dfs(n.left_parent)
                    dfs(n.right_parent)
                end
                dfs(subtree)
                return found
            end

            -- Simple dependency-aware preference: if a child species appears in the sibling subtree,
            -- prefer reusing that child and keep the sibling as the breeder.
            local prefer_reuse_L = dependsOnSpecies(R, L.species)
            local prefer_reuse_R = dependsOnSpecies(L, R.species)

            -- Base-species rule: if one side is a base species (no mutation) and the other is not,
            -- prefer reusing the non-base side (keep base species as breeder), except for Monastic
            -- which we treat as non-preferred for princess. This overrides the sibling-subtree hint.
            local function is_base(spec)
                return mutations[spec] == nil
            end
            local function is_monastic(spec)
                return spec == "Monastic"
            end
            if L and R then
                local L_base = is_base(L.species)
                local R_base = is_base(R.species)
                if L_base ~= R_base then
                    if L_base and not is_monastic(L.species) then
                        -- Left is base, prefer reusing right (non-base)
                        prefer_reuse_L = false
                        prefer_reuse_R = true
                    elseif R_base and not is_monastic(R.species) then
                        -- Right is base, prefer reusing left (non-base)
                        prefer_reuse_L = true
                        prefer_reuse_R = false
                    end
                end
            end

            local L_primary = primary_nodes[L.species]
            local R_primary = primary_nodes[R.species]
            local L_local_override = false
            local R_local_override = false

            if prefer_reuse_L and R then
                local alt = findInSubtree(R, L.species)
                if alt and alt ~= L then
                    L_primary = alt
                    L_local_override = true -- allow local sibling-based reuse even if primary is deeper
                end
            end
            if prefer_reuse_R and L then
                local alt = findInSubtree(L, R.species)
                if alt and alt ~= R then
                    R_primary = alt
                    R_local_override = true -- allow local sibling-based reuse even if primary is deeper
                end
            end

            local L_ok = L_primary and L_primary ~= L and canSafelyConvertToReuse(L, L_primary, tree, L.species, L_local_override)
            local R_ok = R_primary and R_primary ~= R and canSafelyConvertToReuse(R, R_primary, tree, R.species, R_local_override)

            if L_ok and R_ok then
                -- Choose to reuse the costlier branch and keep the cheaper one
                local lc = cost(L)
                local rc = cost(R)
                -- Tiebreakers:
                -- 1) Honor dependency preference when set
                -- 2) Prefer reusing higher-cost subtree
                -- 3) If perfectly tied, prefer reusing the side whose species occurs more in the tree (more consolidation)
                -- 4) If still tied, prefer the side that has a local sibling-subtree overlap
                if prefer_reuse_L and not prefer_reuse_R then
                    convertToReuse(L)
                    changed = true
                elseif prefer_reuse_R and not prefer_reuse_L then
                    convertToReuse(R)
                    changed = true
                elseif lc > rc then
                    convertToReuse(L)
                    changed = true
                elseif rc > lc then
                    convertToReuse(R)
                    changed = true
                else
                    -- Perfect tie: apply generic consolidation heuristic
                    local occL = (species_counts and species_counts[L.species]) or 0
                    local occR = (species_counts and species_counts[R.species]) or 0
                    if occL > occR then
                        convertToReuse(L)
                        changed = true
                    elseif occR > occL then
                        convertToReuse(R)
                        changed = true
                    else
                        -- Still tied: prefer the one with sibling-subtree overlap
                        local overlapL = dependsOnSpecies(R, L.species)
                        local overlapR = dependsOnSpecies(L, R.species)
                        if overlapL and not overlapR then
                            convertToReuse(L)
                            changed = true
                        elseif overlapR and not overlapL then
                            convertToReuse(R)
                            changed = true
                        else
                            -- Fall back to left by convention
                            convertToReuse(L)
                            changed = true
                        end
                    end
                end
            elseif L_ok and not R_ok then
                convertToReuse(L)
                changed = true
            elseif R_ok and not L_ok then
                convertToReuse(R)
                changed = true
            end
        end

        -- Recurse to children that remain
        local cl = optimizeAtNode(node.left_parent, primary_nodes, species_counts)
        local cr = optimizeAtNode(node.right_parent, primary_nodes, species_counts)
        return changed or cl or cr
    end

    -- Run multiple passes: recompute species_info and primary nodes each pass to unlock more safe reuses
    local max_passes = 4
    local final_primary_nodes = nil
    for _ = 1, max_passes do
        -- Recompute species_info based on current tree
        local pass_info = {}
        preExploreTree(tree, pass_info, 0)

        -- Choose one primary (breeding) node per species with duplicates (using refreshed metrics)
        local primary_nodes = {}
        for sp, info in pairs(pass_info) do
            local nodes = info.nodes or {}
            if #nodes > 1 then
                -- Pick the SHALLOWEST instance by distance from root so deeper ones can safely reuse it.
                -- Tie-breakers: lower subtree cost, then lower original depth
                local best, best_depth, best_cost, best_orig_depth = nil, math.huge, math.huge, math.huge
                for _, n in ipairs(nodes) do
                    if not n.reusing_drone then
                        local d = n._distance_from_root or 0
                        -- Weighted subtree cost as tie-breaker (task 27)
                        local c = countTreeCost(n)
                        local od = n._original_depth or 0
                        if (d < best_depth) or (d == best_depth and c < best_cost) or (d == best_depth and c == best_cost and od < best_orig_depth) then
                            best = n
                            best_depth = d
                            best_cost = c
                            best_orig_depth = od
                        end
                    end
                end
                if best then
                    best.is_primary_breeding_node = true
                    primary_nodes[sp] = best
                end
            end
        end

        -- Build species occurrence counts for this pass
        local species_counts = {}
        for sp, info in pairs(pass_info) do
            species_counts[sp] = info.occurrences or 0
        end

        final_primary_nodes = primary_nodes
        local any_changed = optimizeAtNode(tree, primary_nodes, species_counts)
        if not any_changed then break end
    end

    -- Greedy candidate-based reuse: consider remaining duplicates and apply safe reuses by savings
    local function hasAnotherBreedingSourceForSpecies(root, species, exclude)
        local found = false
        local function dfs(n)
            if not n or found then return end
            if n ~= exclude and n.species == species and (n.left_parent or n.right_parent) and not n.reusing_drone then
                found = true
                return
            end
            dfs(n.left_parent)
            dfs(n.right_parent)
        end
        dfs(root)
        return found
    end

    local function findLocalSource(node, root)
        if not node or not node._parent_ref then return nil, false end
        local parent = node._parent_ref
        local sibling = (parent.left_parent == node) and parent.right_parent or parent.left_parent
        if sibling then
            -- If sibling subtree contains this species, prefer that as local source
            if dependsOnSpecies(sibling, node.species) then
                -- Find a concrete node in sibling subtree
                local function findInSubtree(subtree, species)
                    local found = nil
                    local function dfs(n)
                        if not n or found then return end
                        if n.species == species and not n.reusing_drone then
                            found = n
                            return
                        end
                        dfs(n.left_parent)
                        dfs(n.right_parent)
                    end
                    dfs(subtree)
                    return found
                end
                local alt = findInSubtree(sibling, node.species)
                if alt and alt ~= node then
                    return alt, true
                end
            end
        end
        return nil, false
    end

    -- Augment tree with parent refs for local lookups
    local function attachParents(n, parent)
        if not n then return end
        n._parent_ref = parent
        attachParents(n.left_parent, n)
        attachParents(n.right_parent, n)
    end
    attachParents(tree, nil)

    -- Build candidate list (non-primary duplicates)
    local info = {}
    preExploreTree(tree, info, 0)
    local candidates = {}
    -- Build occurrence counts for tie-breakers (consolidation heuristic)
    local species_counts_global = {}
    for sp, data in pairs(info) do
        species_counts_global[sp] = data.occurrences or 0
    end
    local primaries = final_primary_nodes or {}
    for sp, data in pairs(info) do
        if #data.nodes > 1 then
            local primary = primaries[sp]
            for _, n in ipairs(data.nodes) do
                if n ~= primary and not n.reusing_drone then
                    -- Savings in weighted cost: dropping a recessive subtree
                    -- saves more than dropping a dominant one (task 27)
                    local savings = countTreeCost(n)
                    local local_src, allow_rev = findLocalSource(n, tree)
                    table.insert(candidates, {node=n, species=sp, savings=savings, source=(local_src or primary), allow_reverse=allow_rev})
                end
            end
        end
    end
    table.sort(candidates, function(a,b)
        if a.savings ~= b.savings then return a.savings > b.savings end
        local occa = species_counts_global[a.species] or 0
        local occb = species_counts_global[b.species] or 0
        if occa ~= occb then return occa > occb end
        if a.allow_reverse ~= b.allow_reverse then return a.allow_reverse and not b.allow_reverse end
        local da = (a.node._distance_from_root or 0)
        local db = (b.node._distance_from_root or 0)
        return da < db
    end)

    -- Dry-run execution simulator to validate candidate safety beyond local checks
    function simulateExecutionFeasible(root)
        if not root then return true end
        local simulated_bred = {}
        local visiting = {}
        local function findBreedableNode(r, species)
            local found = nil
            local function dfs(node)
                if not node or found then return end
                if node.species == species and (node.left_parent or node.right_parent) and not node.reusing_drone then
                    found = node
                    return
                end
                dfs(node.left_parent)
                dfs(node.right_parent)
            end
            dfs(r)
            return found
        end

        local function simulateEnsure(spec)
            if simulated_bred[spec] then return true end
            -- Treat base species as available in simulation
            if not mutations[spec] then return true end
            if visiting[spec] then return false end
            visiting[spec] = true
            local dep = findBreedableNode(root, spec)
            local ok = false
            if dep then
                ok = simulateSingle(dep)
            end
            visiting[spec] = nil
            return ok or simulated_bred[spec] or (not mutations[spec])
        end

        function simulateSingle(node)
            if not node or simulated_bred[node.species] then return true end
            if node.reusing_drone and not node.is_primary_breeding_node then
                return true
            end
            local m = mutations[node.species]
            if not m then
                simulated_bred[node.species] = true
                return true
            end
            local parents = m.parents
            local princess_parent = parents[1]
            local drone_parent = parents[2]
            if not simulateEnsure(princess_parent) then return false end
            if not simulateEnsure(drone_parent) then return false end
            simulated_bred[node.species] = true
            return true
        end

        -- Collect breeding nodes as in executeBreedingTree (read-only)
        local all_breeding_nodes = {}
        local function collect(node)
            if not node then return end
            local should_collect = (node.left_parent or node.right_parent) and
                                  (not node.reusing_drone or node.is_primary_breeding_node)
            if should_collect then
                table.insert(all_breeding_nodes, node)
            end
            collect(node.left_parent)
            collect(node.right_parent)
        end
        collect(root)

        -- Locally select one primary per species without mutating nodes
        local species_found = {}
        for _, node in ipairs(all_breeding_nodes) do
            local list = species_found[node.species]
            if not list then list = {}; species_found[node.species] = list end
            table.insert(list, node)
        end
        local primary_breeding_nodes = {}
        local species_to_primary = {}
        for sp, instances in pairs(species_found) do
            -- Pick shallowest; tie-break by lower subtree cost, then original depth
            local best, best_depth, best_cost, best_orig = nil, math.huge, math.huge, math.huge
            for _, inst in ipairs(instances) do
                local d = inst._distance_from_root or 0
                local c = countTreeCost(inst)
                local od = inst._original_depth or 0
                if (d < best_depth) or (d == best_depth and c < best_cost) or (d == best_depth and c == best_cost and od < best_orig) then
                    best, best_depth, best_cost, best_orig = inst, d, c, od
                end
            end
            table.insert(primary_breeding_nodes, best)
            species_to_primary[sp] = best
        end

        -- Local topological sort that uses our locally selected primaries (no flags)
        local function localTopoSort(primaries)
            local sorted, visited, visiting = {}, {}, {}
            local function visit(node)
                if visiting[node] or visited[node] then return end
                visiting[node] = true
                if node.left_parent then
                    local dep = species_to_primary[node.left_parent.species]
                    if dep then visit(dep) end
                end
                if node.right_parent then
                    local dep = species_to_primary[node.right_parent.species]
                    if dep then visit(dep) end
                end
                visiting[node] = nil
                visited[node] = true
                table.insert(sorted, node)
            end
            for _, n in ipairs(primaries) do visit(n) end
            return sorted
        end

        local sorted_primary_nodes = localTopoSort(primary_breeding_nodes)
        for _, node in ipairs(sorted_primary_nodes) do
            if not simulateSingle(node) then return false end
        end

        -- Post-order for remaining nodes
        local function post(node)
            if not node then return true end
            if node.left_parent and not post(node.left_parent) then return false end
            if node.right_parent and not post(node.right_parent) then return false end
            if (node.left_parent or node.right_parent) and not node.reusing_drone and
               not node.is_primary_breeding_node and not simulated_bred[node.species] then
                if not simulateSingle(node) then return false end
            end
            return true
        end
        return post(root)
    end

    -- Helper to deep-copy a tree minimally for reuse search
    local function cloneNode(n, parent_map)
        if not n then return nil end
        if parent_map[n] then return parent_map[n] end
        local c = {
            species = n.species,
            reusing_drone = n.reusing_drone,
            is_primary_breeding_node = n.is_primary_breeding_node,
            need_princess = n.need_princess,
            need_drone = n.need_drone,
            drone_count = n.drone_count,
            _distance_from_root = n._distance_from_root,
            _original_depth = n._original_depth,
        }
        parent_map[n] = c
        c.left_parent = cloneNode(n.left_parent, parent_map)
        c.right_parent = cloneNode(n.right_parent, parent_map)
        return c
    end

    local function cloneTree(root)
        return cloneNode(root, {})
    end

    -- Optional beam search over reuse combinations (disabled by default)
    local enable_beam_search = config and config.enable_beam_search
    if enable_beam_search then
        local beam_width = config.beam_width or 6
        local max_expansions = math.min(config.max_beam_expansions or 24, #candidates)
        local frontier = { tree }
        local best_tree = tree
        local best_steps = countTreeSteps(tree)

        local expansions = 0
        while expansions < max_expansions and #frontier > 0 do
            -- Expand each tree in the frontier by trying next viable candidates specific to that snapshot
            local next_frontier = {}
            for _, snapshot in ipairs(frontier) do
            -- Rebuild parent refs for this snapshot
            local function attachParentsSnap(n, parent)
                if not n then return end
                n._parent_ref = parent
                attachParentsSnap(n.left_parent, n)
                attachParentsSnap(n.right_parent, n)
            end
            attachParentsSnap(snapshot, nil)

            -- Recompute candidates on this snapshot (using same logic)
            local snapshot_info = {}
            preExploreTree(snapshot, snapshot_info, 0)
            local snapshot_primaries = {}
            for sp, info2 in pairs(snapshot_info) do
                local nodes2 = info2.nodes or {}
                if #nodes2 > 1 then
                    local best, bd, bc, bod = nil, math.huge, math.huge, math.huge
                    for _, n2 in ipairs(nodes2) do
                        if not n2.reusing_drone then
                            local d2 = n2._distance_from_root or 0
                            local c2 = countTreeSteps(n2)
                            local od2 = n2._original_depth or 0
                            if (d2 < bd) or (d2 == bd and c2 < bc) or (d2 == bd and c2 == bc and od2 < bod) then
                                best, bd, bc, bod = n2, d2, c2, od2
                            end
                        end
                    end
                    if best then
                        best.is_primary_breeding_node = true
                        snapshot_primaries[sp] = best
                    end
                end
            end

            local snap_candidates = {}
            for sp, data2 in pairs(snapshot_info) do
                if #data2.nodes > 1 then
                    local primary = snapshot_primaries[sp]
                    for _, n2 in ipairs(data2.nodes) do
                        if n2 ~= primary and not n2.reusing_drone then
                            local save2 = countTreeSteps(n2)
                            local local_src2, allow_rev2 = findLocalSource(n2, snapshot)
                            table.insert(snap_candidates, {node=n2, species=sp, savings=save2, source=(local_src2 or primary), allow_reverse=allow_rev2})
                        end
                    end
                end
            end
            -- Occurrence-aware sort in beam snapshots as well
            local counts_snap = {}
            for sp, data2 in pairs(snapshot_info) do
                counts_snap[sp] = data2.occurrences or 0
            end
            table.sort(snap_candidates, function(a,b)
                if a.savings ~= b.savings then return a.savings > b.savings end
                local occa = counts_snap[a.species] or 0
                local occb = counts_snap[b.species] or 0
                if occa ~= occb then return occa > occb end
                if a.allow_reverse ~= b.allow_reverse then return a.allow_reverse and not b.allow_reverse end
                local da = (a.node._distance_from_root or 0)
                local db = (b.node._distance_from_root or 0)
                return da < db
            end)

            -- Try up to beam_width best candidates for this snapshot
            local trials = 0
            for _, cand in ipairs(snap_candidates) do
                if trials >= beam_width then break end
                local n2 = cand.node
                local src2 = cand.source
                if n2 and src2 and src2 ~= n2 and not n2.reusing_drone then
                    if hasAnotherBreedingSourceForSpecies(snapshot, cand.species, n2) and not wouldCreateBothChildrenReused(n2, snapshot) then
                        if canSafelyConvertToReuse(n2, src2, snapshot, cand.species, cand.allow_reverse) then
                            -- Clone, apply candidate, simulate
                            local cloned = cloneTree(snapshot)
                            -- Map back from original node to cloned node by path: re-find by species/depth heuristics
                            local function findCloneByPath(rootA, rootB, target)
                                if rootA == target then return rootB end
                                local res = nil
                                if rootA.left_parent and rootB.left_parent then
                                    res = findCloneByPath(rootA.left_parent, rootB.left_parent, target)
                                    if res then return res end
                                end
                                if rootA.right_parent and rootB.right_parent then
                                    res = findCloneByPath(rootA.right_parent, rootB.right_parent, target)
                                    if res then return res end
                                end
                                return nil
                            end
                            local cloned_n = findCloneByPath(snapshot, cloned, n2)
                            if cloned_n then
                                cloned_n.reusing_drone = true
                                cloned_n.left_parent = nil
                                cloned_n.right_parent = nil
                                if simulateExecutionFeasible(cloned) then
                                    table.insert(next_frontier, cloned)
                                    trials = trials + 1
                                    local steps_now = countTreeSteps(cloned)
                                    if steps_now < best_steps then
                                        best_steps = steps_now
                                        best_tree = cloned
                                    end
                                end
                            end
                        end
                    end
                end
            end -- end for cand in snap_candidates
            end -- end for snapshot in frontier
            -- Prepare next layer of the beam
            table.sort(next_frontier, function(a,b)
                return countTreeSteps(a) < countTreeSteps(b)
            end)
            if #next_frontier > beam_width then
                local trimmed = {}
                for i=1, beam_width do trimmed[i] = next_frontier[i] end
                next_frontier = trimmed
            end
            frontier = next_frontier
            expansions = expansions + 1
        end

        -- If we found a better tree, copy it back into the original tree (in place)
        if best_tree ~= tree then
            -- Replace fields of tree with best_tree
            local function overwrite(dst, src)
                dst.species = src.species
                dst.reusing_drone = src.reusing_drone
                dst.is_primary_breeding_node = src.is_primary_breeding_node
                dst.need_princess = src.need_princess
                dst.need_drone = src.need_drone
                dst.drone_count = src.drone_count
                dst._distance_from_root = src._distance_from_root
                dst._original_depth = src._original_depth
                if src.left_parent then
                    if not dst.left_parent then dst.left_parent = {} end
                    overwrite(dst.left_parent, src.left_parent)
                else
                    dst.left_parent = nil
                end
                if src.right_parent then
                    if not dst.right_parent then dst.right_parent = {} end
                    overwrite(dst.right_parent, src.right_parent)
                else
                    dst.right_parent = nil
                end
            end
            overwrite(tree, best_tree)
        end
    end
end

-- Global wrapper for plan executability simulation used by cleanBreedingTree gating
function simulateExecutionFeasibleForPlan(tree)
    if simulateExecutionFeasible then
        return simulateExecutionFeasible(tree)
    end
    -- If simulator is unavailable, be conservative and report infeasible so repairs run
    return false
end

-- (Removed duplicate getNodeDepth; use getNodeDepth below which returns distance from root)

-- Check if converting an instance to reuse is safe
function canSafelyConvertToReuse(instance, starting_node, root_tree, species, allow_reverse_order)
    if instance.reusing_drone then return false end

    -- Safety check: ensure this instance isn't required by the starting node's breeding path
    if isInBreedingPath(instance, starting_node) then
        return false
    end

    -- CRITICAL SAFETY: Check if converting this instance would create a parent with both children reused
    if wouldCreateBothChildrenReused(instance, root_tree) then
        return false
    end

    -- Additional safety: check execution order
    local instance_depth = getNodeDepth(instance, root_tree)
    local starting_depth = getNodeDepth(starting_node, root_tree)

    -- Default rule: only convert instances that come after the starting node in execution order
    -- Local sibling-based reuse override: if the reuse source is within the sibling subtree (deeper),
    -- we allow reverse depth ordering because that subtree will execute first in post-order.
    if allow_reverse_order then
        -- Only allow when the source (starting_node) is strictly deeper than the instance,
        -- which happens in sibling-subtree reuse (e.g., reuse Nickel at Platinum from Invar subtree).
        return (instance_depth >= 0 and starting_depth > instance_depth)
    end
    return instance_depth >= starting_depth
end

-- Check if a node depends on a specific species in its breeding path
function dependsOnSpecies(node, species)
    if not node then return false end
    if node.species == species then return true end

    return dependsOnSpecies(node.left_parent, species) or dependsOnSpecies(node.right_parent, species)
end

-- Check if one node is in the breeding path of another
function isInBreedingPath(potential_dependency, target_node)
    if not target_node then return false end
    if potential_dependency == target_node then return true end

    return isInBreedingPath(potential_dependency, target_node.left_parent) or
           isInBreedingPath(potential_dependency, target_node.right_parent)
end

-- Check if converting an instance to reuse would create a parent with both children reused
function wouldCreateBothChildrenReused(instance, root_tree)
    -- Find all parent nodes that have this instance as a child
    local parent_nodes = findParentNodes(instance, root_tree)

    for _, parent in ipairs(parent_nodes) do
        if parent.left_parent and parent.right_parent then
            local left_would_be_reused = (parent.left_parent == instance) or parent.left_parent.reusing_drone
            local right_would_be_reused = (parent.right_parent == instance) or parent.right_parent.reusing_drone

            -- If converting this instance would make both children reused, it's unsafe
            if left_would_be_reused and right_would_be_reused then
                return true
            end
        end
    end

    return false
end

-- Find all parent nodes that have the target as a direct child
function findParentNodes(target_node, root_tree)
    local parents = {}

    local function searchForParents(node)
        if not node then return end

        if node.left_parent == target_node or node.right_parent == target_node then
            table.insert(parents, node)
        end

        searchForParents(node.left_parent)
        searchForParents(node.right_parent)
    end

    searchForParents(root_tree)
    return parents
end

-- Get the depth of a node in the tree (distance from root)
function getNodeDepth(target_node, root_tree)
    local function findDepth(current_node, target, depth)
        if not current_node then return -1 end
        if current_node == target then return depth end

        local left_depth = findDepth(current_node.left_parent, target, depth + 1)
        if left_depth >= 0 then return left_depth end

        return findDepth(current_node.right_parent, target, depth + 1)
    end

    return findDepth(root_tree, target_node, 0)
end

-- Count how many times each species is needed as a drone in the tree
function countDroneOccurrences(tree, counts)
    if not tree then return end

    -- Count this species if it's needed as a drone
    if tree.need_drone then
        counts[tree.species] = (counts[tree.species] or 0) + 1
    end

    -- Recursively count in subtrees
    countDroneOccurrences(tree.left_parent, counts)
    countDroneOccurrences(tree.right_parent, counts)
end

-- Breadth-first stock optimization - remove sub-trees for species we have in stock
function optimizeTreeByStock(tree)
    if not tree then return end

    -- Process tree level by level (breadth-first)
    local current_level = {tree}

    while #current_level > 0 do
        local next_level = {}

        for _, node in ipairs(current_level) do
            -- Check if we have stock of this species (accounting for breeding needs)
            local available_princesses = countAvailablePrincesses(node.species)
            local available_drones = countAvailableDrones(node.species)

            -- If we have stock, we can simplify this node
            if available_princesses > 0 or available_drones > 0 then
                -- Remove breeding sub-tree but keep as leaf node for breeding
                node.left_parent = nil
                node.right_parent = nil
                node.reusing_stock = true
                -- Don't process children of this node (they're removed)
            else
                -- Add children to next level for processing
                if node.left_parent then
                    table.insert(next_level, node.left_parent)
                end
                if node.right_parent then
                    table.insert(next_level, node.right_parent)
                end
            end
        end

        current_level = next_level
    end
end

-- Count available princesses for a species
function countAvailablePrincesses(species)
    local count = 0
    for _, princess in ipairs(inventory.princesses) do
        if princess == species then
            count = count + 1
        end
    end
    return count
end

-- Find the deepest node in the tree (furthest from root)
function findDeepestNode(tree)
    local deepest = tree
    local max_depth = 0

    local function findDepth(node, depth)
        if not node then return end

        if depth > max_depth then
            max_depth = depth
            deepest = node
        end

        if node.left_parent then
            findDepth(node.left_parent, depth + 1)
        end
        if node.right_parent then
            findDepth(node.right_parent, depth + 1)
        end
    end

    findDepth(tree, 0)
    return deepest
end


-- Calculate depth of a tree (for optimization decisions)
function calculateTreeDepth(tree)
    if not tree then return 0 end
    if not tree.left_parent and not tree.right_parent then return 1 end

    local left_depth = calculateTreeDepth(tree.left_parent)
    local right_depth = calculateTreeDepth(tree.right_parent)

    return 1 + math.max(left_depth, right_depth)
end

-- Pre-exploration to find all species and their breeding complexities
function preExploreTree(tree, species_info, distance_from_root)
    if not tree then return end

    distance_from_root = distance_from_root or 0

    -- Calculate depth of this subtree and distance from root
    local subtree_depth = calculateTreeDepth(tree)
    tree._original_depth = subtree_depth  -- Store original subtree depth
    tree._distance_from_root = distance_from_root  -- Store distance from root

    -- Store or update species info
    if not species_info[tree.species] then
        species_info[tree.species] = {
            min_subtree_depth = subtree_depth,
            min_distance_from_root = distance_from_root,
            occurrences = 0,
            nodes = {}
        }
    else
        -- Keep track of minimum values
        species_info[tree.species].min_subtree_depth = math.min(species_info[tree.species].min_subtree_depth, subtree_depth)
        species_info[tree.species].min_distance_from_root = math.min(species_info[tree.species].min_distance_from_root, distance_from_root)
    end

    species_info[tree.species].occurrences = species_info[tree.species].occurrences + 1
    table.insert(species_info[tree.species].nodes, tree)

    -- Recursively explore children
    preExploreTree(tree.left_parent, species_info, distance_from_root + 1)
    preExploreTree(tree.right_parent, species_info, distance_from_root + 1)
end

-- Climbing optimization for drone accumulation (with smart branch selection)
function climbingOptimizeForAccumulation(tree, accumulated_drones, species_info, parent)
    if not tree then return end

    if tree.left_parent then
        climbingOptimizeForAccumulation(tree.left_parent, accumulated_drones, species_info, tree)
    end
    if tree.right_parent then
        climbingOptimizeForAccumulation(tree.right_parent, accumulated_drones, species_info, tree)
    end

    -- Skip if this node is already marked for reuse
    if tree.reusing_drone then
        return
    end

    -- Check if we've already encountered this species and can reuse
    local species_data = species_info[tree.species]
    if species_data and species_data.occurrences > 1 and accumulated_drones[tree.species] and accumulated_drones[tree.species] > 0 then
        local current_distance = tree._distance_from_root or 0
        local min_distance = species_data.min_distance_from_root

        if current_distance >= min_distance then
            if parent and parent.left_parent and parent.right_parent then
                local sibling = parent.left_parent == tree and parent.right_parent or parent.left_parent
                if sibling and sibling.reusing_drone then
                    return
                end
            end
            tree.reusing_drone = true
            accumulated_drones[tree.species] = accumulated_drones[tree.species] - 1
            tree.left_parent = nil
            tree.right_parent = nil
            return
        end
    end

    -- If we're breeding this species (has parents), add it to accumulation
    if tree.left_parent or tree.right_parent then
        accumulated_drones[tree.species] = (accumulated_drones[tree.species] or 0) + 1
    end
end

-- Second optimization pass: breadth-first analysis + climbing optimization
function smarterReuseOptimization(tree, species_info)
    if not tree then return end

    -- Step 1: Breadth-first pass to identify nodes with both parents unreused (potential for optimization)
    local optimization_candidates = {}
    identifyOptimizationCandidates(tree, optimization_candidates, 0)

    -- Sort candidates by distance from root (process closer to root first)
    table.sort(optimization_candidates, function(a, b) return a.distance < b.distance end)

    -- Step 2: Climbing pass - for each candidate, try to reuse one parent without killing ancestors
    for _, candidate in ipairs(optimization_candidates) do
        optimizeNodeParents(candidate.node, tree, species_info)
    end
end

-- Breadth-first identification of nodes that have both parents unreused (optimization candidates)
function identifyOptimizationCandidates(tree, candidates, distance)
    if not tree then return end

    -- Check if this node has both parents unreused (potential for optimization)
    if tree.left_parent and tree.right_parent then
        local left_reused = tree.left_parent.reusing_drone or false
        local right_reused = tree.right_parent.reusing_drone or false

        if not left_reused and not right_reused then
            -- This node has both parents unreused - it's a candidate for optimization
            table.insert(candidates, {node = tree, distance = distance})
        end
    end

    -- Continue breadth-first traversal
    identifyOptimizationCandidates(tree.left_parent, candidates, distance + 1)
    identifyOptimizationCandidates(tree.right_parent, candidates, distance + 1)
end

-- Try to optimize a node's parents by reusing one of them (climbing approach)
function optimizeNodeParents(node, root_tree, species_info)
    if not node or not node.left_parent or not node.right_parent then
        return
    end

    local left_parent = node.left_parent
    local right_parent = node.right_parent
    local left_reused = left_parent.reusing_drone
    local right_reused = right_parent.reusing_drone

    -- Ensure at least one parent remains available for breeding
    if left_reused or right_reused then
        return
    end

    if canReuseParentSafely(left_parent, root_tree, species_info) then
        left_parent.reusing_drone = true
        left_parent.left_parent = nil
        left_parent.right_parent = nil
        return
    end

    if canReuseParentSafely(right_parent, root_tree, species_info) then
        right_parent.reusing_drone = true
        right_parent.left_parent = nil
        right_parent.right_parent = nil
        return
    end
end

-- Check if a parent can be safely reused without "killing ancestors"
function canReuseParentSafely(parent, root_tree, species_info)
    if not parent or parent.reusing_drone then
        return false -- Already reused or invalid
    end

    -- Check if this parent species is available elsewhere in the tree
    local parent_species = parent.species
    local available_sources = countAvailableSourcesForSpecies(parent_species, root_tree, parent)

    -- We need at least one other source for this species (excluding this one)
    if available_sources < 1 then
        return false -- Would kill our only source for this species
    end

    -- Check if we have this species in stock
    if hasSpeciesDrone(parent_species) then
        return true -- We have it in stock, safe to reuse
    end

    return available_sources > 0 -- Safe if there are other sources
end

-- Count how many other sources exist for a species (excluding the given node)
function countAvailableSourcesForSpecies(species, tree, exclude_node)
    if not tree or tree == exclude_node then
        return 0
    end

    local count = 0

    -- If this node produces the species and is not reused, count it
    if tree.species == species and not tree.reusing_drone and (tree.left_parent or tree.right_parent) then
        count = count + 1
    end

    -- Recursively count in subtrees
    count = count + countAvailableSourcesForSpecies(species, tree.left_parent, exclude_node)
    count = count + countAvailableSourcesForSpecies(species, tree.right_parent, exclude_node)

    return count
end

-- Find the best node to keep as the producer (closest to root, most efficient)
function findBestProducer(nodes)
    local best = nodes[1]
    local best_distance = best._distance_from_root or 0

    for i = 2, #nodes do
        local node = nodes[i]
        local distance = node._distance_from_root or 0

        -- Prefer nodes closer to root (lower distance)
        if distance < best_distance then
            best = node
            best_distance = distance
        end
    end

    return best
end

-- Check if a node can be safely reused without creating dependency issues
function canSafelyReuseNode(node, species, species_info)
    if not node.left_parent or not node.right_parent then
        return true -- Leaf nodes can always be reused safely
    end

    -- Check if reusing this node would create a dependency on base species that we can't fulfill
    local required_princesses = {}
    findPrincessRequirementsForNode(node, required_princesses)

    -- For each required princess species, check if we have other ways to obtain it
    for req_species, count in pairs(required_princesses) do
        if not canFulfillPrincessRequirement(req_species, count, species_info) then
            return false
        end
    end

    return true
end

-- Find princess requirements that would be lost if we reuse this node
function findPrincessRequirementsForNode(node, requirements)
    if not node then return end

    -- If this is a leaf node that needs a princess, count it
    if not node.left_parent and not node.right_parent then
        if node.need_princess then
            requirements[node.species] = (requirements[node.species] or 0) + 1
        end
        return
    end

    -- Recursively check children
    findPrincessRequirementsForNode(node.left_parent, requirements)
    findPrincessRequirementsForNode(node.right_parent, requirements)
end

-- Check if a princess requirement can be fulfilled by other nodes in the tree
function canFulfillPrincessRequirement(species, count, species_info)
    -- If we have the species in stock, we can fulfill it
    if hasSpeciesPrincess(species) then
        return true
    end

    -- If there are other non-reused occurrences of this species that can produce it, we're good
    local species_data = species_info[species]
    if species_data then
        local available_producers = 0
        for _, node in ipairs(species_data.nodes) do
            if not node.reusing_drone and (node.left_parent or node.right_parent) then
                available_producers = available_producers + 1
            end
        end

        if available_producers >= count then
            return true
        end
    end

    return false
end

-- Check if the current tree has any impossible parents (both children reused)
function treeHasImpossibleParents(species_info)
    -- Check all species nodes to see if any parent has both children reused
    for species, data in pairs(species_info) do
        for _, node in ipairs(data.nodes) do
            if node.left_parent and node.right_parent then
                local left_reused = node.left_parent.reusing_drone or false
                local right_reused = node.right_parent.reusing_drone or false

                if left_reused and right_reused then
                    return true -- Found an impossible parent
                end
            end
        end
    end

    return false -- No impossible parents found
end

-- Validate tree after optimization to ensure no impossible parent-child relationships
function validateTreeAfterOptimization(tree)
    if not tree then return end

    -- Check this node
    if tree.left_parent and tree.right_parent then
        -- If both children exist, at least one must not be reused
        local left_reused = tree.left_parent.reusing_drone or false
        local right_reused = tree.right_parent.reusing_drone or false

        if left_reused and right_reused then
            -- CRITICAL ERROR: Both children are reused, this parent cannot be bred
            -- Fix by un-reusing one of the children (prefer the deeper/more complex one)
            fixImpossibleParent(tree)
        end
    end

    -- Recursively validate children
    validateTreeAfterOptimization(tree.left_parent)
    validateTreeAfterOptimization(tree.right_parent)
end

-- Ensure that for every species used as a parent in the tree, there exists at least one
-- breeding-capable (non-reused) node for that species. If missing, un-reuse a suitable instance.
function ensureBreedingSourcesForDependencies(root)
    if not root then return end

    -- Collect all required parent species in the plan
    local required = {}
    local function collectRequired(node)
        if not node then return end
        if node.left_parent then required[node.left_parent.species] = true end
        if node.right_parent then required[node.right_parent.species] = true end
        collectRequired(node.left_parent)
        collectRequired(node.right_parent)
    end
    collectRequired(root)

    -- Map species to nodes and detect breeding-capable availability
    local species_nodes = {}
    local has_breeding_capable = {}
    local function indexNodes(node)
        if not node then return end
        species_nodes[node.species] = species_nodes[node.species] or {}
        table.insert(species_nodes[node.species], node)
        if (node.left_parent or node.right_parent) and not node.reusing_drone then
            has_breeding_capable[node.species] = true
        end
        indexNodes(node.left_parent)
        indexNodes(node.right_parent)
    end
    indexNodes(root)

    -- For each required species, ensure there is at least one breeding-capable node
    for species, _ in pairs(required) do
        if not has_breeding_capable[species] then
            local candidates = species_nodes[species] or {}
            local to_restore = nil
            local best_cost = math.huge
            -- Prefer the cheapest reused instance to restore, using original depth as cost proxy
            for _, n in ipairs(candidates) do
                if n.reusing_drone then
                    local cost = n._original_depth or math.huge
                    if cost < best_cost then
                        best_cost = cost
                        to_restore = n
                    end
                end
            end
            -- If none reused (edge case), fall back to primary or first
            if not to_restore then
                for _, n in ipairs(candidates) do
                    if n.is_primary_breeding_node then
                        to_restore = n
                        break
                    end
                end
                if not to_restore and #candidates > 0 then
                    to_restore = candidates[1]
                end
            end
            if to_restore and to_restore.reusing_drone then
                unreuseNode(to_restore)
            end
        end
    end
end

-- Fix a parent node that has both children reused (impossible situation)
function fixImpossibleParent(parent)
    if not parent.left_parent or not parent.right_parent then
        return -- Nothing to fix
    end

    local left_child = parent.left_parent
    local right_child = parent.right_parent

    -- Choose which child to un-reuse (prefer keeping the simpler one reused)
    local left_depth = left_child._original_depth or 0
    local right_depth = right_child._original_depth or 0

    if left_depth >= right_depth then
        -- Left is deeper/more complex, un-reuse it and restore its breeding tree
        unreuseNode(left_child)
    else
        -- Right is deeper/more complex, un-reuse it and restore its breeding tree
        unreuseNode(right_child)
    end
end

-- Un-reuse a node by restoring its breeding capability (preserving optimizations where possible)
function unreuseNode(node)
    if not node or not node.reusing_drone then
        return -- Nothing to do
    end

    -- Clear the reuse flag
    node.reusing_drone = false

    -- Restore the breeding tree (we need to rebuild it)
    if mutations[node.species] then
        local parents = mutations[node.species].parents
        node.left_parent = buildBreedingTree(parents[1])
        node.right_parent = buildBreedingTree(parents[2])

        -- Apply optimizations to the restored subtree
        optimizeTreeByStock(node)

        -- Re-apply reuse optimizations to the subtree (but avoid the validation loop)
        local species_info = {}
        preExploreTree(node, species_info)
        local accumulated_drones = {}
        climbingOptimizeForAccumulation(node, accumulated_drones, species_info)
    end
end

-- Apply the climbing optimization results to the tree
function applyClimbingOptimization(tree, available_drones)
    if not tree then return end

    -- Apply reusing_drone markers that were set during climbing
    applyClimbingOptimization(tree.left_parent, available_drones)
    applyClimbingOptimization(tree.right_parent, available_drones)
end

-- Find all starting princesses needed for the tree
function findStartingPrincesses(tree)
    if not tree then return {} end

    local princesses = {}

    -- If this is a leaf node and we need a princess, it's a starting princess
    if not tree.left_parent and not tree.right_parent and tree.need_princess then
        table.insert(princesses, tree.species)
    end

    -- Recursively find starting princesses in subtrees
    local left_princesses = findStartingPrincesses(tree.left_parent)
    local right_princesses = findStartingPrincesses(tree.right_parent)

    for _, princess in ipairs(left_princesses) do
        table.insert(princesses, princess)
    end
    for _, princess in ipairs(right_princesses) do
        table.insert(princesses, princess)
    end

    return princesses
end

-- Recursively find all base species needed for a tree node
function findBaseSpeciesNeeded(tree, base_princesses, base_drones)
    if not tree then return end

    -- If this is a base species (no mutation), count it
    if not mutations[tree.species] then
        if tree.need_princess then
            base_princesses[tree.species] = (base_princesses[tree.species] or 0) + 1
        end
        if tree.need_drone and not tree.reusing_drone then
            base_drones[tree.species] = (base_drones[tree.species] or 0) + 1
        end
        return
    end

    -- If this is an intermediate species, recurse to its components
    findBaseSpeciesNeeded(tree.left_parent, base_princesses, base_drones)
    findBaseSpeciesNeeded(tree.right_parent, base_princesses, base_drones)
end

-- Calculate missing base species needed for the breeding plan
function calculateMissingBaseSpecies(tree, drone_requirements)
    local base_princesses_needed = {}
    local base_drones_needed = {}

    -- Find all base species needed by traversing the complete tree
    findBaseSpeciesNeeded(tree, base_princesses_needed, base_drones_needed)

    -- Calculate missing princesses (base species only)
    local missing_princesses = {}
    for species, needed in pairs(base_princesses_needed) do
        local available = 0
        if hasSpeciesPrincess(species) then
            available = 1 -- Simple count - could be enhanced to track actual quantities
        end
        if needed > available then
            missing_princesses[species] = needed - available
        end
    end

    -- Calculate missing drones (base species only)
    local missing_drones = {}
    for species, needed in pairs(base_drones_needed) do
        local available = 0
        if hasSpeciesDrone(species) then
            available = 1 -- Simple count - could be enhanced to track actual quantities
        end
        if needed > available then
            missing_drones[species] = needed - available
        end
    end

    return missing_princesses, missing_drones
end

-- Sanity check: detect species that appear multiple times but weren't reused
function detectMissedReuseOpportunities(tree)
    local species_occurrences = {}
    local missed_opportunities = {}

    -- Check if a node can be reused based on sibling constraints
    local function canNodeBeReused(node, parent_context)
        if not parent_context or not parent_context.parent then
            return true -- Root or orphaned nodes can be reused
        end

        local parent = parent_context.parent
        local sibling = parent_context.side == "left" and parent.right_parent or parent.left_parent

        -- If sibling is reused, this node cannot be reused (would create impossible parent)
        if sibling and sibling.reusing_drone then
            return false
        end

        return true
    end

    -- Count all occurrences of each species in the tree, tracking sibling relationships
    local function countSpeciesOccurrences(node, parent_context)
        if not node then return end

        if not species_occurrences[node.species] then
            species_occurrences[node.species] = {
                total = 0,
                reused = 0,
                nodes = {},
                reusable_nodes = {}
            }
        end

        species_occurrences[node.species].total = species_occurrences[node.species].total + 1
        table.insert(species_occurrences[node.species].nodes, node)

        if node.reusing_drone then
            species_occurrences[node.species].reused = species_occurrences[node.species].reused + 1
        else
            -- Check if this node can actually be reused (no reusing siblings)
            if canNodeBeReused(node, parent_context) then
                table.insert(species_occurrences[node.species].reusable_nodes, node)
            end
        end

        countSpeciesOccurrences(node.left_parent, {parent = node, side = "left"})
        countSpeciesOccurrences(node.right_parent, {parent = node, side = "right"})
    end

    countSpeciesOccurrences(tree, nil)

    -- Identify missed opportunities (only for intermediate species, considering sibling constraints)
    for species, data in pairs(species_occurrences) do
        -- Skip base species (species without mutations) - their multiple occurrences are expected
        if mutations[species] then
            local total_reusable = #data.reusable_nodes

            if data.total > 1 and data.reused == 0 and total_reusable > 0 then
                -- Multiple occurrences but no reuse, and some could be reused
                missed_opportunities[species] = {
                    occurrences = data.total,
                    nodes = data.nodes,
                    potential_additional_reuse = total_reusable - 1 -- Keep at least one
                }
            elseif total_reusable > 1 and data.reused < total_reusable - 1 then
                -- More reusable nodes than we're currently reusing
                missed_opportunities[species] = {
                    occurrences = data.total,
                    reused = data.reused,
                    potential_additional_reuse = (total_reusable - 1) - data.reused,
                    nodes = data.nodes
                }
            end
        end
    end

    return missed_opportunities
end

-- Sanity check: verify tree consistency
function performTreeSanityChecks(tree, target)
    local warnings = {}
    local errors = {}

    -- Check for missed reuse opportunities (WARNING - not fatal)
    local missed_reuse = detectMissedReuseOpportunities(tree)
    if next(missed_reuse) then
        table.insert(warnings, {
            type = "missed_reuse",
            severity = "warning",
            details = missed_reuse,
            message = "Potential missed reuse opportunities detected"
        })
    end

    -- Check for reused nodes that still have children (ERROR - fatal)
    local function checkReuseConsistency(node, path)
        if not node then return end

        if node.reusing_drone and (node.left_parent or node.right_parent) then
            table.insert(errors, {
                type = "reuse_inconsistency",
                severity = "error",
                species = node.species,
                path = path,
                message = "CRITICAL: Reused node " .. node.species .. " still has breeding children"
            })
        end

        if node.left_parent then
            checkReuseConsistency(node.left_parent, path .. "->" .. node.left_parent.species)
        end
        if node.right_parent then
            checkReuseConsistency(node.right_parent, path .. "->" .. node.right_parent.species)
        end
    end

    checkReuseConsistency(tree, target)

    -- Check for impossible parents (ERROR - fatal)
    local function checkImpossibleParents(node, path)
        if not node then return end

        if node.left_parent and node.right_parent then
            local left_reused = node.left_parent.reusing_drone or false
            local right_reused = node.right_parent.reusing_drone or false

            if left_reused and right_reused then
                table.insert(errors, {
                    type = "impossible_parent",
                    severity = "error",
                    species = node.species,
                    path = path,
                    message = "CRITICAL: " .. node.species .. " has both children reused (impossible to breed)"
                })
            end
        end

        if node.left_parent then
            checkImpossibleParents(node.left_parent, path .. "->" .. node.left_parent.species)
        end
        if node.right_parent then
            checkImpossibleParents(node.right_parent, path .. "->" .. node.right_parent.species)
        end
    end

    checkImpossibleParents(tree, target)

    return {
        warnings = warnings,
        errors = errors,
        has_errors = #errors > 0,
        has_warnings = #warnings > 0
    }
end

-- Calculate drone requirements with accumulation counts (base species only)
function calculateDroneRequirements(tree)
    if not tree then return {} end

    local requirements = {}

    -- Calculate base species drone requirements by accumulating all intermediate needs
    local base_drones_needed = {}
    calculateBaseDroneRequirements(tree, base_drones_needed)

    -- Convert to the expected format
    for species, count in pairs(base_drones_needed) do
        requirements[species] = {
            available = countAvailableDrones(species),
            needed = count
        }
    end

    return requirements
end

-- Calculate base species drone requirements by traversing and accumulating
function calculateBaseDroneRequirements(tree, base_drones_needed)
    if not tree then return end

    -- If this is a base species (no mutation) that needs a drone and is not reusing, count it
    if not mutations[tree.species] then
        if tree.need_drone and not tree.reusing_drone then
            base_drones_needed[tree.species] = (base_drones_needed[tree.species] or 0) + 1
        end
        return
    end

    -- For intermediate species, recurse to their components
    calculateBaseDroneRequirements(tree.left_parent, base_drones_needed)
    calculateBaseDroneRequirements(tree.right_parent, base_drones_needed)
end

-- Count available drones for a species
function countAvailableDrones(species)
    local count = 0
    for _, drone in ipairs(inventory.drones) do
        if drone == species then
            count = count + 1
        end
    end
    return count
end

-- Count total breeding steps in the tree
function countTreeSteps(tree)
    if not tree then return 0 end

    local steps = 0

    -- If this node requires breeding (has parents), count it
    if tree.left_parent or tree.right_parent then
        steps = steps + 1
    end

    -- Add steps from subtrees
    steps = steps + countTreeSteps(tree.left_parent)
    steps = steps + countTreeSteps(tree.right_parent)

    return steps
end

--- Check if we have a specific species as princess
--- @param species string The bee species to check for
--- @return boolean hasPrincess True if we have this species as princess/queen
--- Count how many of a species are in stock
--- @param species string Species name
--- @param kind string "princess" or "drone"
--- @return number count
function countSpecies(species, kind)
    local list = (kind == "drone") and inventory.drones or inventory.princesses
    local count = 0

    for _, held in ipairs(list or {}) do
        if held == species then
            count = count + 1
        end
    end

    return count
end

--- Is this a species the program cannot breed?
---
--- The database is keyed by what a cross produces, so anything absent from it is a starting
--- species: found in a hive, traded for, given. Spending the last one cannot be undone.
--- @param species string Species name
--- @return boolean unbreedable
function isBaseSpecies(species)
    return mutations[species] == nil
end

function hasSpeciesPrincess(species)
    for _, princess in ipairs(inventory.princesses) do
        if princess == species then
            return true
        end
    end
    return false
end

-- Check if we have a specific species as drone
function hasSpeciesDrone(species)
    for _, drone in ipairs(inventory.drones) do
        if drone == species then
            return true
        end
    end
    return false
end

-- Check if we have a specific species
function hasSpecies(species)
    for _, p in ipairs(inventory.princesses) do
        if p == species then
            for _, d in ipairs(inventory.drones) do
                if d == species then
                    return true
                end
            end
        end
    end

    return false
end

--- Check if Mechanical User has beebee gun equipped
--- @return boolean hasGun True if beebee gun is found
--- @return string|nil gunName Name of the gun item if found
--- Check whether the Mechanical User holds a beebee gun
---
--- Three answers, not two. The redstone that fires the Mechanical User travels as far as a wire
--- goes, but reading its inventory needs the block to touch the one holding the inventory
--- controller. When it does not, the slot is unreadable -- which is not the same thing as an
--- empty one, and must not stop the run.
--- @return boolean hasGun True if a beebee gun was found
--- @return string|nil gunName Name of the gun item if found
--- @return boolean readable False when that side holds no readable inventory at all
function checkBeebeeGun()
    if not config.mech_user_inventory_side then

        return false, nil, false
    end

    if not inv_controller.getInventorySize(config.mech_user_inventory_side) then

        return false, nil, false
    end

    local stack = inv_controller.getStackInSlot(config.mech_user_inventory_side, config.beebee_gun_slot)

    if stack and stack.name then
        local name = stack.name:lower()
        if name:find("beebee") or name:find("bee.*gun") then

            return true, stack.name, true
        end
    end

    return false, nil, true
end

-- Wait for beebee gun to be available in Mechanical User
function waitForBeebeeGun()
    local hasGun, gunName, readable = checkBeebeeGun()

    -- The Mechanical User is not next to the inventory controller, so its slots cannot be read.
    -- Say so once and carry on: blocking here would stop a setup that is merely wired with
    -- redstone rather than placed against the adapter.
    if not readable then
        if not control_state.beebee_unreadable_warned then
            control_state.beebee_unreadable_warned = true
            drawGUI({progress = "BeeBee Gun not verifiable",
                     errors = "No readable inventory on the Mechanical User side - firing blind",
                     status = "Warning"})
        end

        return true
    end

    if not hasGun then
        updateStatusIndicators("waiting", "Waiting for beebee gun", gui_state.current_species)
        handleError("Beebee gun not found in Mechanical User slot " .. config.beebee_gun_slot, validateBeebeeGun)

        if control_state.abort_requested then

            return false
        end

        -- Read again: the name from before the pause is still nil, and concatenating it threw
        hasGun, gunName = checkBeebeeGun()
        if not hasGun then

            return false
        end
    end

    if control_state.abort_requested then

        return false
    end

    drawGUI({progress = "Beebee gun ready: " .. tostring(gunName or "unknown"), status = "Ready"})

    return true
end

-- Activate Mechanical User via redstone pulse (with beebee gun check)
function activateMechanicalUser()
    waitForBeebeeGun()

    redstone.setOutput(config.mech_user_side, 15)
    os.sleep(config.pulse_duration)
    redstone.setOutput(config.mech_user_side, 0)
end

--- Move items between inventories
--- @param from_side number Source inventory side
--- @param from_slot number Source slot number
--- @param to_side number Destination inventory side
--- @param to_slot number|nil Destination slot number (nil for any slot)
--- @param count number|nil Number of items to move (default 64)
--- @return boolean success True if items were moved
function moveItem(from_side, from_slot, to_side, to_slot, count)
    count = count or 64

    -- A nil source slot used to reach transferItem and raise from inside OpenComputers, which
    -- produced a stack trace and no clue about which item was missing. Say it plainly instead.
    --
    -- A nil DESTINATION slot is not an error: OpenComputers reads it as "the first free slot",
    -- which is what putting something back in a chest wants.
    if from_side == nil or from_slot == nil or to_side == nil then
        print(string.format("Cannot move: side/slot missing (from %s/%s to %s)",
            tostring(from_side), tostring(from_slot), tostring(to_side)))

        return false
    end

    local ok, moved = pcall(inv_controller.transferItem, from_side, to_side, count, from_slot, to_slot)
    if not ok then
        print("Transfer refused: " .. tostring(moved))

        return false
    end

    moved = moved or 0

    local destination = to_slot and ("slot " .. to_slot) or "the first free slot"

    if moved > 0 then
        print("Moved " .. moved .. " items from slot " .. from_slot .. " to " .. destination)

        return true
    end

    print("Failed to move items from slot " .. from_slot .. " to " .. destination)

    return false
end

-- Find item in inventory by name pattern (searches multiple inventories)
--- Find an item in one inventory by pattern
---
--- Matches the display label as well as the item id. The species of a bee lives only in the
--- label -- every Forestry princess is `forestry:bee_princess_ge` -- so searching the id alone
--- never found "Meadows Princess", and the program stopped on the first cross asking for a bee
--- that was sitting in the chest in front of it.
--- @param side number Inventory side
--- @param pattern string Lua pattern, matched case-insensitively
--- @return number|nil slot, table|nil stack
function findItem(side, pattern)
    local inv_size = inv_controller.getInventorySize(side)
    if not inv_size then return nil end

    local needle = pattern:lower()

    for slot = 1, inv_size do
        local stack = inv_controller.getStackInSlot(side, slot)

        if stack then
            local label = (stack.label or ""):lower()
            local name = (stack.name or ""):lower()

            if label:find(needle) or name:find(needle) then
                return slot, stack
            end
        end
    end

    return nil
end

-- Find item across all available inventories (input, output, and storage)
function findItemAnyInventory(pattern)
    -- Priority search: output chest first (for produced bees), then input chest
    local search_order = {
        {side = config.output_chest_side, name = "output chest"},
        {side = config.input_chest_side, name = "input chest"}
    }

    for _, location in ipairs(search_order) do
        local slot, stack = findItem(location.side, pattern)
        if slot then
            return location.side, slot, stack
        end
    end

    -- Search other inventories
    local all_sides = {sides.up, sides.down, sides.north, sides.south, sides.east, sides.west}

    for _, side in ipairs(all_sides) do
        -- Skip already searched sides
        local already_searched = false
        for _, location in ipairs(search_order) do
            if side == location.side then
                already_searched = true
                break
            end
        end

        if not already_searched then
            local inv_size = inv_controller.getInventorySize(side)
            if inv_size and inv_size >= (config.min_scan_inventory_size or 10) then
                local slot, stack = findItem(side, pattern)
                if slot then
                    return side, slot, stack
                end
            end
        end
    end

    return nil
end

--- List the leaves of a plan that cannot be bred and are not in stock
---
--- A leaf with no star has no recipe in the database; if neither a princess nor a drone of it is
--- held, the plan cannot start. Reading that off a forty-line tree by eye is exactly the kind of
--- thing a program should do for you.
--- @param tree table|nil The breeding tree
--- @return string[] species Sorted, without repeats
function collectBlockingLeaves(tree)
    local found = {}

    local function walk(node)
        if not node then return end

        local breedable = node.left_parent or node.right_parent

        if not breedable
           and not hasSpeciesPrincess(node.species)
           and not hasSpeciesDrone(node.species) then
            found[node.species] = true
        end

        walk(node.left_parent)
        walk(node.right_parent)
    end

    walk(tree)

    local list = {}
    for species in pairs(found) do
        table.insert(list, species)
    end
    table.sort(list)

    return list
end

--- List the unbreedable species a plan will consume, and what is held of each
---
--- The mutatron eats both parents, and a species absent from the database cannot be remade. This
--- is the one thing worth knowing BEFORE a run rather than after it.
--- @param tree table|nil The breeding tree
--- @return table[] entries { species, princesses, drones, tight }
function collectConsumedBaseSpecies(tree)
    local seen = {}

    local function walk(node)
        if not node then return end

        if isBaseSpecies(node.species)
           and (hasSpeciesPrincess(node.species) or hasSpeciesDrone(node.species)) then
            seen[node.species] = true
        end

        walk(node.left_parent)
        walk(node.right_parent)
    end

    walk(tree)

    local entries = {}
    for species in pairs(seen) do
        local princesses = countSpecies(species, "princess")
        local drones = countSpecies(species, "drone")

        table.insert(entries, {
            species = species,
            princesses = princesses,
            drones = drones,
            tight = (princesses + drones) <= 1,
        })
    end

    table.sort(entries, function(a, b) return a.species < b.species end)

    return entries
end

--- Describe what occupies a slot, for a message a player can act on
--- @param side number Inventory side
--- @param slot number|nil Slot index
--- @return string|nil label Item name, or nil when the slot is free
local function occupantOf(side, slot)
    if not slot then return nil end

    local held = inv_controller.getStackInSlot(side, slot)
    if not held then return nil end

    return tostring(held.label or held.name or "something")
end

--- Empty the mutatron's slots before loading it again
---
--- A run that stopped part way -- a crash, an abort, a cross that was refused -- leaves the
--- parents it had already inserted sitting in the machine. The next attempt then finds those
--- slots taken and fails on "check mutatron inventory space", which says nothing about the two
--- bees standing in the way. Put them back where they came from instead.
--- @return boolean cleared True when every input slot is free afterwards
--- @return string|nil report What was moved, or what could not be
function clearMutatron()
    applyDriverSlots()

    local side = config.mutatron_side
    local moved = {}

    -- A finished queen belongs in the apiary, but this is not the moment: park it in the output
    -- chest so the cycle can be restarted from a clean machine.
    local output = occupantOf(side, config.mutatron_output_slot)
    if output then
        if moveItem(side, config.mutatron_output_slot, config.output_chest_side, nil, 64) then
            table.insert(moved, output .. " (leftover product) -> output chest")
        else

            return false, "The mutatron still holds " .. output ..
                          " in its output slot and it could not be moved out"
        end
    end

    for _, slot in ipairs(config.mutatron_input_slots or {}) do
        local held = occupantOf(side, slot)

        if held then
            if moveItem(side, slot, config.input_chest_side, nil, 64) then
                table.insert(moved, held .. " -> input chest")
            else

                return false, "The mutatron still holds " .. held ..
                              " and the input chest has no room for it"
            end
        end
    end

    if #moved == 0 then

        return true, nil
    end

    return true, "Cleared the mutatron: " .. table.concat(moved, ", ")
end

--- Explain, in one sentence, why a bee could not be put into the mutatron
---
--- "Check mutatron inventory space" was true of only one of the reasons. A machine can refuse an
--- insertion because the slot is taken, because the face the adapter touches does not accept it,
--- or because the bee is no longer where it was found. Each needs a different fix, so each is
--- named.
--- @param species string Species being loaded
--- @param kind string "princess" or "drone"
--- @param from_side number Where the bee was found
--- @param from_slot number Slot it was found in
--- @param to_slot number|nil Slot it was aimed at
--- @return string reason
function describeLoadFailure(species, kind, from_side, from_slot, to_slot)
    local blocker = occupantOf(config.mutatron_side, to_slot)
    if blocker then

        return string.format("Could not load the %s %s: mutatron slot %s already holds %s",
            species, kind, tostring(to_slot), blocker)
    end

    local source = occupantOf(from_side, from_slot)
    if not source then

        return string.format("Could not load the %s %s: it is no longer in %s slot %d",
            species, kind, getSideName(from_side), from_slot)
    end

    local size = inv_controller.getInventorySize(config.mutatron_side)
    if not size then

        return string.format("Could not load the %s %s: nothing readable on the %s side -- is "
            .. "config.mutatron_side right?", species, kind, getSideName(config.mutatron_side))
    end

    if to_slot and to_slot > size then

        return string.format("Could not load the %s %s: slot %d is beyond the mutatron's %d "
            .. "slots -- check config.slot_offset", species, kind, to_slot, size)
    end

    return string.format(
        "The mutatron refused the %s %s into slot %s and into every free slot. It has %d slots "
        .. "and the target is empty, so the face the adapter touches is not accepting bees -- "
        .. "try an adapter on another face of the machine.",
        species, kind, tostring(to_slot), size)
end

--- Insert princess and drone into mutatron
--- @param parent1 string Species name for princess/queen
--- @param parent2 string Species name for drone
--- @return boolean success True if mutatron was loaded successfully
--- @return string message Status message
function loadMutatron(parent1, parent2)
    -- Check continue state
    local should_continue, abort_msg = checkContinue()
    if not should_continue then
        return false, abort_msg
    end

    -- Find princess and drone across all inventories.
    --
    -- Two searches rather than "princess|queen": Lua patterns have no alternation, so that group
    -- was matched literally and never found anything.
    local princess_side, princess_slot, princess_stack = findItemAnyInventory(parent1 .. ".*princess")
    if not princess_slot then
        princess_side, princess_slot, princess_stack = findItemAnyInventory(parent1 .. ".*queen")
    end

    local drone_side, drone_slot, drone_stack = findItemAnyInventory(parent2 .. ".*drone")

    -- Look again after the pause. handleError returns once the bee has been put in a chest, but
    -- the slot found before the pause is still nil -- and it went straight into transferItem,
    -- which raised from inside OpenComputers instead of saying which bee was missing.
    if not princess_slot then
        handleError("Could not find " .. parent1 .. " princess/queen in any inventory!",
                   function() return validateBeeAvailability(parent1, "princess") end)
        if control_state.abort_requested then return false, "Aborted" end

        princess_side, princess_slot, princess_stack = findItemAnyInventory(parent1 .. ".*princess")
        if not princess_slot then
            princess_side, princess_slot, princess_stack = findItemAnyInventory(parent1 .. ".*queen")
        end

        if not princess_slot then

            return false, "No " .. parent1 .. " princess or queen available"
        end
    end

    if not drone_slot then
        handleError("Could not find " .. parent2 .. " drone in any inventory!",
                   function() return validateBeeAvailability(parent2, "drone") end)
        if control_state.abort_requested then return false, "Aborted" end

        drone_side, drone_slot, drone_stack = findItemAnyInventory(parent2 .. ".*drone")

        if not drone_slot then

            return false, "No " .. parent2 .. " drone available"
        end
    end

    -- Move items to mutatron. Ask the drivers for the real slot indices first: without them the
    -- literals from config are used, which is the degraded mode.
    applyDriverSlots()

    -- Anything a previous attempt left in the machine goes back to a chest first.
    local cleared, clear_report = clearMutatron()
    if not cleared then
        handleError(clear_report, nil)
        if control_state.abort_requested then return false, "Aborted" end

        cleared, clear_report = clearMutatron()
        if not cleared then

            return false, clear_report
        end
    end

    if clear_report then
        drawGUI({progress = clear_report, status = "Working"})
    end

    -- Named individually. "Check mutatron inventory space" did not say which bee could not go in,
    -- nor what was in its way, which is the whole of what you need to fix it.
    local moves = {
        {parent1, "princess", princess_side, princess_slot, config.mutatron_input_slots[1]},
        {parent2, "drone", drone_side, drone_slot, config.mutatron_input_slots[2]},
    }

    for _, move in ipairs(moves) do
        local species, kind, from_side, from_slot, to_slot = table.unpack(move)

        if not moveItem(from_side, from_slot, config.mutatron_side, to_slot, 1) then
            -- The named slot was refused. A Gendustry machine is sided: the face the adapter
            -- touches decides which slots accept an insertion, and it need not be the one the
            -- driver numbers. Let the machine choose a slot itself before giving up.
            if moveItem(from_side, from_slot, config.mutatron_side, nil, 1) then
                drawGUI({progress = string.format(
                    "Mutatron refused slot %s for the %s %s; it placed it itself",
                    tostring(to_slot), species, kind), status = "Warning"})
            else

                return false, describeLoadFailure(species, kind, from_side, from_slot, to_slot)
            end
        end
    end

    -- The mutatron consumes one labware per cycle and refuses to start without it. Nothing fed
    -- that slot before, so a chained sequence of crosses stalled on the second one.
    local labware_ok, labware_msg = ensureLabware()
    if not labware_ok then
        handleError(labware_msg, validateLabware)
        local should_continue, abort_msg = checkContinue()
        if not should_continue then

            return false, abort_msg
        end
    end

    return true, "Successfully loaded mutatron"
end

-- Extract queen from mutatron and move to apiary
--- Wait until the mutatron has something in its output slot
---
--- Split out of moveQueenToApiary so the product can be identified before it is moved: once the
--- queen is in the apiary, rejecting her costs a full apiary cycle. Returns immediately when the
--- output is already there, so calling it twice is free.
--- @return boolean ready True if the mutatron output slot holds a bee
function waitForMutatronOutput()
    if gendustry and gendustry.available and gendustry.adv then
        local output = advCall("getOutput")

        if not output then
            local received, reason = waitForMachineSignal("advmutatron_finished", config.mutatron_timeout)

            if not received then
                if reason == "aborted" then

                    return false
                end

                -- Timeout: tell a long cycle apart from a machine that stopped
                local working = advCall("isWorking")
                if working then
                    drawGUI({progress = "Mutatron still working",
                             errors = "Cycle longer than config.mutatron_timeout - still waiting",
                             status = "Warning"})
                else
                    drawGUI({progress = "Mutatron stalled",
                             errors = "Mutatron is not working and produced nothing - check mutagen, labware and power",
                             status = "Error"})

                    return false
                end
            end

            output = advCall("getOutput")
        end

        if not output then
            print("ERROR: No queen produced by mutatron!")

            return false
        end
    else
        -- Degraded mode: poll the output slot as before
        os.sleep(2)

        local queen_stack = inv_controller.getStackInSlot(config.mutatron_side, config.mutatron_output_slot)
        if not queen_stack then
            print("Waiting for mutatron to produce queen...")
            for i = 1, 10 do
                os.sleep(1)
                queen_stack = inv_controller.getStackInSlot(config.mutatron_side, config.mutatron_output_slot)
                if queen_stack then break end
            end

            if not queen_stack then
                print("ERROR: No queen produced by mutatron!")

                return false
            end
        end
    end

    return true
end

--- Move the queen from the mutatron to the apiary
--- @return boolean success True if the queen reached the apiary
function moveQueenToApiary()
    print("Moving queen from mutatron to apiary...")

    if not waitForMutatronOutput() then

        return false
    end

    print("Queen ready! Moving to apiary...")

    -- Move queen to apiary with the apiary held still, so the insertion cannot race
    -- a cycle that is already running (task 20)
    local previous_mode = freezeApiary()
    local success = moveItem(config.mutatron_side, config.mutatron_output_slot, config.apiary_side, config.apiary_input_slot, 1)
    unfreezeApiary(previous_mode)

    if success then
        print("Queen successfully placed in apiary!")
        return true
    else
        drawGUI({progress = "Move failed", errors = "Failed to move queen to apiary", status = "Error"})
        return false
    end
end

-- Collect all products from apiary
function collectApiaryProducts()
    print("Collecting products from apiary...")

    local collected_items = {}
    local total_collected = 0

    -- Build the list of occupied output slots. listOutputs() reports the driver's own
    -- slot numbering and a "count" field, where the inventory controller uses 1-based
    -- slots and "size"; both are normalised here.
    -- BLOCKED BY Q3: config.slot_offset must be verified by check_slots.lua before the
    -- driver path can be trusted (apiary_output_slots = {2..6} vs driver outputs = 6..14).
    local outputs = nil

    if gendustry.available and gendustry.apiary then
        local list, reason = apiaryCall("listOutputs")
        if list then
            outputs = {}
            for _, item in ipairs(list) do
                table.insert(outputs, {
                    slot = item.slot + (config.slot_offset or 0),
                    count = item.count or 0,
                    name = item.label or item.name
                })
            end
        else
            print("listOutputs failed (" .. tostring(reason) .. ") - falling back to configured slots")
        end
    end

    if not outputs then
        outputs = {}
        for _, slot in ipairs(config.apiary_output_slots) do
            local stack = inv_controller.getStackInSlot(config.apiary_side, slot)
            if stack then
                table.insert(outputs, {
                    slot = slot,
                    count = stack.size or 0,
                    name = stack.label or stack.name
                })
            end
        end
    end

    for _, item in ipairs(outputs) do
        if item.count and item.count > 0 then
            -- Try to move to output chest
            local moved = inv_controller.transferItem(config.apiary_side, config.output_chest_side, item.count, item.slot)
            if moved and moved > 0 then
                total_collected = total_collected + moved
                local item_name = item.name or "unknown"
                collected_items[item_name] = (collected_items[item_name] or 0) + moved

                print("  Collected " .. moved .. "x " .. item_name)
            end
        end
    end

    if total_collected > 0 then
        print("Total items collected: " .. total_collected)

        -- Update inventory tracking. A finished cycle yields a PRINCESS, so the same
        -- three types scanInventory recognises are recognised here, case-insensitively.
        for item_name, count in pairs(collected_items) do
            local lowered = item_name:lower()
            if lowered:find("princess") or lowered:find("queen") then
                local species = extractSpecies(item_name)
                if species then
                    for i = 1, count do
                        table.insert(inventory.princesses, species)
                    end
                end
            elseif lowered:find("drone") then
                local species = extractSpecies(item_name)
                if species then
                    for i = 1, count do
                        table.insert(inventory.drones, species)
                    end
                end
            end
        end

        return true
    else
        print("No items collected from apiary!")

        return false
    end
end

-- Check if the Gendustry drivers are available and write a diagnostic report to a file.
--
-- Modelled on the mod's survey.lua: a report is far longer than a screen, and an installation
-- is usually diagnosed by someone who is not standing in front of it. Read it in game with
-- `edit /home/hivemind_report.txt`.
--- @return boolean available True if at least one Gendustry driver answered
function checkGendustryAPI()
    refreshGendustrySlots()

    local path = config.report_path or "/home/hivemind_report.txt"
    local out = io.open(path, "w")

    local function w(line)
        if out then out:write((line or "") .. "\n") end
    end

    local function rule()
        w(string.rep("=", 72))
    end

    -- Which callbacks a component actually offers. A short list here means a driver problem.
    local function callbacksOf(address)
        if not address then return "component absent" end

        local ok, methods = pcall(component.methods, address)
        if not ok or type(methods) ~= "table" then
            return "NONE -- ghost component or driver failure"
        end

        local names = {}
        for name in pairs(methods) do names[#names + 1] = name end
        table.sort(names)

        return string.format("(%d) %s", #names, table.concat(names, " "))
    end

    local function writeSlots(slots)
        if type(slots) ~= "table" then
            w("  not answered")

            return
        end

        local keys = {}
        for key in pairs(slots) do keys[#keys + 1] = tostring(key) end
        table.sort(keys)

        for _, key in ipairs(keys) do
            local value = slots[key]
            if type(value) == "table" then
                local parts = {}
                for _, index in pairs(value) do parts[#parts + 1] = index end
                table.sort(parts, function(a, b)
                    if type(a) == "number" and type(b) == "number" then return a < b end

                    return tostring(a) < tostring(b)
                end)
                for i, index in ipairs(parts) do parts[i] = tostring(index) end
                w(string.format("  %-12s [%s]", key, table.concat(parts, ",")))
            else
                w(string.format("  %-12s %s", key, tostring(value)))
            end
        end
    end

    local function writeEnergy(caller)
        local energy = caller("getEnergy")
        if type(energy) == "table" then
            w(string.format("energy: %s / %s", tostring(energy.stored), tostring(energy.capacity)))
        else
            w("energy: not answered")
        end
    end

    local function describeStack(stack)
        if type(stack) ~= "table" then return "empty" end

        return string.format("%s x%s", tostring(stack.label or stack.name),
            tostring(stack.count or stack.size))
    end

    local offset = config.slot_offset or 1

    -- 1. Header ------------------------------------------------------------
    rule()
    w("HIVEMIND -- GENDUSTRY DRIVER REPORT")
    rule()
    w(string.format("uptime %.0fs, memory %d/%d bytes free",
        computer.uptime(), computer.freeMemory(), computer.totalMemory()))
    w(string.format("config.slot_offset = %+d  (controller_slot = driver_slot %+d)", offset, offset))
    w(string.format("mutatron side %s, apiary side %s, output chest side %s",
        tostring(config.mutatron_side), tostring(config.apiary_side),
        tostring(config.output_chest_side)))
    w("")
    w(string.format("advmutatron:       %s", tostring(gendustry.adv or "absent")))
    w(string.format("industrial_apiary: %s", tostring(gendustry.apiary or "absent")))

    -- 2. Advanced Mutatron -------------------------------------------------
    w("")
    rule()
    w("ADVANCED MUTATRON (advmutatron)")
    rule()
    if gendustry.adv then
        w("callbacks: " .. callbacksOf(gendustry.adv))
        w(string.format("working: %s   progress: %s",
            tostring(advCall("isWorking")), tostring(advCall("getProgress"))))
        writeEnergy(advCall)

        local can, canWhy = advCall("canStart")
        w("canStart: " .. tostring(can) .. (canWhy and ("  -- " .. tostring(canWhy)) or ""))

        local tank = advCall("getTank")
        if type(tank) == "table" then
            w(string.format("mutagen: %s / %s  %s", tostring(tank.amount),
                tostring(tank.capacity), tostring(tank.fluid or "(empty)")))
        else
            w("mutagen: not answered")
        end

        w("slots as the driver reports them:")
        writeSlots(advCall("listSlots"))
        w("slots after config.slot_offset:")
        writeSlots(gendustry.slots.mutatron)

        w("output slot: " .. describeStack(advCall("getOutput")))

        local offered = advCall("listMutations")
        if type(offered) == "table" then
            local count = 0
            for _, entry in pairs(offered) do
                if type(entry) == "table" then
                    count = count + 1
                    w(string.format("  mutation %s: %s", tostring(entry.index),
                        tostring(entry.label or entry.name)))
                end
            end
            if count == 0 then
                w("  no mutation offered -- load two parents and a labware, then run again")
            end
        else
            w("listMutations: not answered")
        end
    else
        w("absent -- no Adapter against the Advanced Mutatron, or no cable back to this computer")
    end

    -- 3. Industrial Apiary -------------------------------------------------
    w("")
    rule()
    w("INDUSTRIAL APIARY (industrial_apiary)")
    rule()
    if gendustry.apiary then
        w("callbacks: " .. callbacksOf(gendustry.apiary))
        w(string.format("working: %s   progress: %s",
            tostring(apiaryCall("isWorking")), tostring(apiaryCall("getProgress"))))
        writeEnergy(apiaryCall)

        w("slots as the driver reports them:")
        writeSlots(apiaryCall("listSlots"))
        w("slots after config.slot_offset:")
        writeSlots(gendustry.slots.apiary)

        local environment = apiaryCall("getEnvironment")
        if type(environment) == "table" then
            w(string.format("environment: temperature %s, humidity %s",
                tostring(environment.temperature), tostring(environment.humidity)))
        end

        local modifiers = apiaryCall("getModifiers")
        if type(modifiers) == "table" then
            local keys = {}
            for key in pairs(modifiers) do keys[#keys + 1] = tostring(key) end
            table.sort(keys)
            w("modifiers:")
            for _, key in ipairs(keys) do
                w(string.format("  %-20s %s", key, tostring(modifiers[key])))
            end
        end

        local redstone_mode = apiaryCall("getRedstoneMode")
        if type(redstone_mode) == "table" then
            w(string.format("redstone mode: %s (canWork %s)",
                tostring(redstone_mode.mode), tostring(redstone_mode.canWork)))
        end

        local status = apiaryCall("getPrincessStatus")
        if type(status) == "table" then
            w(string.format("queen slot: occupied %s, type %s, freed %s, automated %s%s",
                tostring(status.occupied), tostring(status.type), tostring(status.freed),
                tostring(status.automated),
                status.error and (", error " .. tostring(status.error)) or ""))
            if status.automated then
                w("  !! the Automation upgrade reinserts the princess and starts a new cycle,")
                w("     which takes away the parent this program needs. Remove it.")
            end
        end

        local errors = apiaryCall("getErrors")
        if type(errors) == "table" then
            if errors.hasErrors and type(errors.errors) == "table" then
                w("Forestry errors:")
                for _, message in pairs(errors.errors) do
                    w("  " .. tostring(message))
                end
            else
                w("Forestry errors: none")
            end
        end

        local upgrades = apiaryCall("listUpgrades")
        if type(upgrades) == "table" then
            local count = 0
            for _, item in pairs(upgrades) do
                if type(item) == "table" then
                    count = count + 1
                    w(string.format("  upgrade slot %s: %s", tostring(item.slot), describeStack(item)))
                end
            end
            if count == 0 then w("upgrades: none installed") end
        end

        local outputs = apiaryCall("listOutputs")
        if type(outputs) == "table" then
            local count = 0
            for _, item in pairs(outputs) do
                if type(item) == "table" then
                    count = count + 1
                    w(string.format("  output driver slot %s (controller %s): %s",
                        tostring(item.slot),
                        type(item.slot) == "number" and tostring(item.slot + offset) or "?",
                        describeStack(item)))
                end
            end
            if count == 0 then w("outputs: all empty") end
        end
    else
        w("absent -- no Adapter against the Industrial Apiary, or no cable back to this computer")
    end

    -- 4. The same inventories through inventory_controller -----------------
    -- Printed side by side with the driver indices above so a wrong config.slot_offset shows up
    -- as two lists that do not line up.
    w("")
    rule()
    w("INVENTORY CONTROLLER VIEW (1-based)")
    rule()

    local function safeInv(method, ...)
        local result = table.pack(pcall(inv_controller[method], ...))
        if result[1] then return table.unpack(result, 2, result.n) end

        return nil
    end

    local views = {
        {name = "mutatron", side = config.mutatron_side},
        {name = "apiary", side = config.apiary_side},
        {name = "input chest", side = config.input_chest_side},
        {name = "output chest", side = config.output_chest_side}
    }

    for _, view in ipairs(views) do
        local size = safeInv("getInventorySize", view.side)
        w(string.format("%s on side %s: %s slots",
            view.name, tostring(view.side), tostring(size or "nothing readable")))
        if type(size) == "number" then
            for slot = 1, size do
                local stack = safeInv("getStackInSlot", view.side, slot)
                if type(stack) == "table" then
                    w(string.format("  controller[%d] (driver %d) %s",
                        slot, slot - offset, describeStack(stack)))
                end
            end
        end
    end

    -- 5. Verdict -----------------------------------------------------------
    w("")
    rule()
    w(string.format("drivers available: %s  (mutatron %s, apiary %s)",
        tostring(gendustry.available),
        gendustry.adv and "yes" or "no",
        gendustry.apiary and "yes" or "no"))
    if not gendustry.available then
        w("Falling back to redstone control and inventory_controller, as before the migration.")
    end

    if out then out:close() end

    if gendustry.available then
        print("Gendustry drivers available (mutatron: " .. (gendustry.adv and "yes" or "no") ..
              ", apiary: " .. (gendustry.apiary and "yes" or "no") .. ")")
    else
        print("No Gendustry driver found -- put an Adapter against the Advanced Mutatron")
        print("and the Industrial Apiary, and cable them to this computer.")
        print("Using manual redstone control for Mechanical User")
    end

    if out then
        print("Diagnostic report written to " .. path)
        print("Read it with:  edit " .. path)
    else
        print("Could not write the diagnostic report to " .. path)
    end

    return gendustry.available
end

-- Driver-reported slot indices -------------------------------------------------------------
-- listSlots() answers in the driver's own numbering (mutatron in1 = 0, apiary queen = 0), while
-- inventory_controller counts from 1. config.slot_offset bridges the two. Q3 IS NOT SETTLED: the
-- value is decided in game by check_slots.lua, so nothing below writes a literal index.
local driver_slots_applied = false

--- Convert one driver slot index to an inventory_controller slot index
--- @param index number|nil Slot index as reported by listSlots()
--- @return number|nil converted Index usable with inventory_controller, or nil
--- Accept a slot index that has already been translated
---
--- gendustry.slots.* are shifted to controller numbering once, when the drivers are resolved.
--- Shifting them a second time here put the parents in the mutatron's slots 2 and 3 instead of
--- 1 and 2, so the machine saw an empty pair and offered no mutation at all -- a failure that
--- reads as "these parents cannot breed that", not as an off-by-one.
--- @param index any A slot index from gendustry.slots
--- @return number|nil index The index unchanged, or nil when it is not one
local function toControllerSlot(index)
    if type(index) ~= "number" then

        return nil
    end

    return index
end

--- Overwrite the literal slot configuration with what the drivers report
--- Idempotent: the first successful call wins, later calls are free.
--- @return boolean applied True if at least one machine answered with usable slots
function applyDriverSlots()
    if driver_slots_applied then

        return true
    end

    if not (gendustry and gendustry.available) then

        return false
    end

    local applied = false
    local mutatron_slots = gendustry.slots and gendustry.slots.mutatron

    if type(mutatron_slots) == "table" then
        local in1 = toControllerSlot(mutatron_slots.in1)
        local in2 = toControllerSlot(mutatron_slots.in2)

        if in1 and in2 then
            config.mutatron_input_slots = {in1, in2}
            applied = true
        end

        local output = toControllerSlot(mutatron_slots.output)
        if output then
            config.mutatron_output_slot = output
            applied = true
        end

        local labware = toControllerSlot(mutatron_slots.labware)
        if labware then
            config.mutatron_labware_slot = labware
            applied = true
        end
    end

    local apiary_slots = gendustry.slots and gendustry.slots.apiary

    if type(apiary_slots) == "table" then
        local queen = toControllerSlot(apiary_slots.queen)
        if queen then
            config.apiary_input_slot = queen
            applied = true
        end

        if type(apiary_slots.outputs) == "table" then
            local outputs = {}

            for _, slot in ipairs(apiary_slots.outputs) do
                local index = toControllerSlot(slot)
                if index then
                    table.insert(outputs, index)
                end
            end

            if #outputs > 0 then
                config.apiary_output_slots = outputs
                applied = true
            end
        end
    end

    driver_slots_applied = applied

    return applied
end

-- Labware --------------------------------------------------------------------------------------

--- Make sure the mutatron holds labware; it consumes one per cycle and will not start without
--- @return boolean success True if labware sits in the mutatron labware slot
--- @return string message Explanation of what was done or what is missing
function ensureLabware()
    applyDriverSlots()

    local slot = config.mutatron_labware_slot
    if not slot then

        return false, "Labware slot unknown - the mutatron did not answer listSlots()"
    end

    local present = inv_controller.getStackInSlot(config.mutatron_side, slot)
    if present and (present.size or 0) > 0 then

        return true, "Labware already loaded"
    end

    local labware_side, labware_slot = findItemAnyInventory("labware")
    if not labware_slot then

        return false, "Could not find labware in any inventory - the mutatron cannot start without it"
    end

    if not moveItem(labware_side, labware_slot, config.mutatron_side, slot, 1) then

        return false, "Failed to move labware into mutatron slot " .. tostring(slot)
    end

    return true, "Labware loaded"
end

--- Validation callback for handleError: has the operator supplied labware?
--- @return boolean success
--- @return string|nil errorMessage
function validateLabware()
    local ok, message = ensureLabware()
    if ok then

        return true, nil
    end

    return false, message
end

-- Mutagen --------------------------------------------------------------------------------------

--- Read the mutatron mutagen tank
--- @return table|nil tank { amount, capacity, fluid }, or nil plus a reason
--- @return string|nil reason
function readMutagenTank()
    if not (gendustry and gendustry.available) then

        return nil, "Gendustry drivers unavailable"
    end

    local tank, reason = advCall("getTank")
    if type(tank) ~= "table" then

        return nil, reason or "The mutatron did not answer getTank()"
    end

    return tank
end

--- Validation callback for handleError: has the tank been refilled?
--- @return boolean success
--- @return string|nil errorMessage
function validateMutagen()
    local tank = readMutagenTank()
    if not tank then
        -- An unreadable tank must not hold the operator hostage.

        return true, nil
    end

    local needed = config.mutagen_reserve_mb or 0
    if (tank.amount or 0) >= needed then

        return true, nil
    end

    return false, string.format("Mutagen still at %d mB, %d mB needed", tank.amount or 0, needed)
end

--- Validation callback for handleError: has the output slot been cleared?
--- @return boolean success
--- @return string|nil errorMessage
function validateMutatronOutputCleared()
    local stack = inv_controller.getStackInSlot(config.mutatron_side, config.mutatron_output_slot)
    if stack then

        return false, "Mutatron output slot " .. tostring(config.mutatron_output_slot) .. " is still occupied"
    end

    return true, nil
end

--- Wait until the tank can pay for a cycle, showing the level instead of starting a doomed run
--- @return boolean ready True if a cycle may be started
--- @return string message Level reached, or why the wait was given up
function waitForMutagen()
    if not (gendustry and gendustry.available) then

        return true, "Mutagen unchecked - no drivers"
    end

    local needed = config.mutagen_reserve_mb or 0
    local deadline = computer.uptime() + (config.mutagen_wait_timeout or 120)

    while true do
        local tank, reason = readMutagenTank()
        if not tank then
            -- Cannot read it, so do not block on it: the driver refusal will name it anyway.

            return true, reason or "Mutagen unchecked"
        end

        local amount = tank.amount or 0
        local capacity = tank.capacity or 0

        if amount >= needed then

            return true, string.format("Mutagen %d/%d mB", amount, capacity)
        end

        local level = string.format("Mutagen %d/%d mB - %d mB needed", amount, capacity, needed)
        drawGUI({step_type = "Waiting", progress = "Waiting for mutagen", errors = level, status = "Warning"})

        if computer.uptime() >= deadline then

            return false, "Not enough mutagen: " .. level
        end

        local should_continue, abort_msg = checkContinue()
        if not should_continue then

            return false, abort_msg or "Operation aborted by user"
        end

        os.sleep(1)
    end
end

-- Mutation selection ---------------------------------------------------------------------------

--- Human-readable list of what the loaded pair really offers
--- @param list table Entries from listMutations()
--- @return string names Comma separated names, sorted
function describeMutations(list)
    local names = {}

    if type(list) == "table" then
        for _, entry in pairs(list) do
            if type(entry) == "table" then
                table.insert(names, tostring(entry.label or entry.name or "?"))
            end
        end
    end

    if #names == 0 then

        return "no mutation at all"
    end

    table.sort(names)

    return table.concat(names, ", ")
end

--- Find the mutation the driver offers for a target species
--- Exact name wins over a partial one, so "Gray" never steals "Light Gray".
--- @param list table Entries from listMutations()
--- @param target string Species name we are aiming for
--- @return number|nil index Index to hand to selectAndProduce
--- @return string|nil name Name the driver gave it
function findMutationIndex(list, target)
    if type(list) ~= "table" or type(target) ~= "string" then

        return nil
    end

    local wanted = target:lower()
    local partial_index, partial_name

    for index, entry in pairs(list) do
        if type(entry) == "table" then
            local name = tostring(entry.label or entry.name or "")
            local lowered = name:lower()

            if lowered == wanted then

                return index, name
            end

            if not partial_index and lowered:find(wanted, 1, true) then
                partial_index, partial_name = index, name
            end
        end
    end

    return partial_index, partial_name
end

--- Compare the a priori plan from the hard-coded database with what the machine really offers
--- The pack is the truth; the database only planned the route. A divergence is named, not swallowed.
--- @param parent1 string Species loaded as princess/queen
--- @param parent2 string Species loaded as drone
--- @param target string Species we want out of the mutatron
--- @param offered table Entries from listMutations()
--- @return boolean agrees True if plan and machine say the same thing
function verifyPlannedMutation(parent1, parent2, target, offered)
    local planned = mutations[target]
    local planned_text = "nothing"

    if planned and planned.parents then
        planned_text = tostring(planned.parents[1]) .. " + " .. tostring(planned.parents[2])
    end

    local pair_matches = false
    if planned and planned.parents then
        pair_matches = (planned.parents[1] == parent1 and planned.parents[2] == parent2)
            or (planned.parents[1] == parent2 and planned.parents[2] == parent1)
    end

    local machine_offers = findMutationIndex(offered, target) ~= nil

    if pair_matches and machine_offers then

        return true
    end

    local message = string.format(
        "Plan differs from machine: database breeds %s from %s, mutatron loaded with %s + %s offers %s",
        target, planned_text, parent1, parent2, describeMutations(offered))

    print("WARNING: " .. message)
    drawGUI({errors = message, status = "Warning"})

    return false
end

--- Turn a driver refusal into something the operator can act on
--- @param reason string|nil Raw reason returned by selectAndProduce
--- @return string message
function explainDriverRefusal(reason)
    local raw = tostring(reason or "unknown reason")
    local lowered = raw:lower()

    if lowered:find("missing parent 1", 1, true) then

        return "Mutatron refused: missing parent 1 - no princess/queen in slot " .. tostring(config.mutatron_input_slots[1])
    end

    if lowered:find("missing parent 2", 1, true) then

        return "Mutatron refused: missing parent 2 - no drone in slot " .. tostring(config.mutatron_input_slots[2])
    end

    if lowered:find("missing labware", 1, true) then

        return "Mutatron refused: missing labware - put labware in slot " .. tostring(config.mutatron_labware_slot)
    end

    if lowered:find("output full", 1, true) then

        return "Mutatron refused: output full - clear slot " .. tostring(config.mutatron_output_slot)
    end

    local have, want = raw:match("not enough mutagen:%s*(%d+)%s*of%s*(%d+)")
    if have then

        return string.format("Mutatron refused: mutagen at %s mB of %s mB needed - refill the tank", have, want)
    end

    return "Mutatron refused: " .. raw
end

--- Pick the validation callback that matches a refusal, so [R]esume can actually check the fix
--- @param reason string|nil Raw reason returned by selectAndProduce
--- @return function|nil validator
function refusalValidator(reason)
    local lowered = tostring(reason or ""):lower()

    if lowered:find("labware", 1, true) then

        return validateLabware
    end

    if lowered:find("mutagen", 1, true) then

        return validateMutagen
    end

    if lowered:find("output full", 1, true) then

        return validateMutatronOutputCleared
    end

    return nil
end

--- Select and start the mutation that leads to the target species
--- Replaces the old stub, which read none of its three parameters and always returned true.
--- @param parent1 string Species loaded as princess/queen
--- @param parent2 string Species loaded as drone
--- @param target string Species we want out of the mutatron
--- @return boolean success True if the mutatron accepted and started the mutation
--- @return string message Chosen mutation on success, reason on failure
function useGendustryAPI(parent1, parent2, target)
    if not (gendustry and gendustry.available and gendustry.adv) then

        return false, "Gendustry drivers unavailable"
    end

    applyDriverSlots()

    -- Never start a cycle the tank cannot pay for: the signal would never come.
    local mutagen_ok, mutagen_msg = waitForMutagen()
    if not mutagen_ok then
        handleError(mutagen_msg, validateMutagen)

        local should_continue, abort_msg = checkContinue()
        if not should_continue then

            return false, abort_msg or "Aborted"
        end
    end

    local list, reason = advCall("listMutations")
    if type(list) ~= "table" then
        local message = "The mutatron did not answer listMutations(): " .. tostring(reason or "no table returned")
        drawGUI({errors = message, status = "Error"})

        return false, message
    end

    -- The hard-coded database is only a plan; listMutations() is the ground truth.
    verifyPlannedMutation(parent1, parent2, target, list)

    local index, name = findMutationIndex(list, target)
    if not index then
        local message = string.format("%s + %s cannot produce %s. This pair offers: %s",
            parent1, parent2, target, describeMutations(list))
        print(message)
        handleError(message, nil)

        return false, message
    end

    drawGUI({step_type = "Breeding", progress = "Selecting mutation: " .. (name or target), status = "Working"})

    local started, refused = advCall("selectAndProduce", index)
    if not started then
        local message = explainDriverRefusal(refused)
        handleError(message, refusalValidator(refused))

        return false, message
    end

    return true, "Mutation started: " .. (name or target)
end

-- Display comprehensive breeding plan with tree structure
function displayBreedingPlan(target, breeding_plan)
    print()
    print("=== BREEDING STRATEGY FOR " .. target:upper() .. " ===")
    print()

    if not breeding_plan then
        print("ERROR: Cannot find breeding strategy for " .. target)
        return false
    end

    if breeding_plan.total_steps == 0 then
        print("Target bee already available!")
        return true
    end

    print("Total estimated steps: " .. breeding_plan.total_steps)
    print()

    -- Display starting princesses required
    if #breeding_plan.starting_princesses > 0 then
        print("=== STARTING PRINCESSES REQUIRED ===")
        for i, princess in ipairs(breeding_plan.starting_princesses) do
            local status = hasSpeciesPrincess(princess) and " ✓" or " ✗"
            print(string.format("%d. %s%s", i, princess, status))
        end
        print()
    end

    -- Display drone requirements
    if next(breeding_plan.drone_requirements) then
        print("=== DRONE REQUIREMENTS ===")
        for species, req in pairs(breeding_plan.drone_requirements) do
            local shortage = math.max(0, req.needed - req.available)
            local accumulation = shortage + config.add_drone_count
            print(string.format("%s: %d available / %d needed (+%d accumulation = %d total)",
                  species, req.available, req.needed, config.add_drone_count, accumulation))
        end
        print()
    end

    -- Display breeding tree structure
    if breeding_plan.tree then
        print("=== BREEDING TREE ===")
        print("Golden path (left branch) and drone branches (right):")
        displayTree(breeding_plan.tree, "", true)
        print()
    end

    -- What the plan cannot make and you do not have.
    --
    -- The same information is in the sections above, but a deep tree pushes them off the top of
    -- the screen -- and this is the one thing you have to act on before pressing 1.
    local blocking = collectBlockingLeaves(breeding_plan.tree)

    if config.warn_last_base_species then
        local at_risk = collectConsumedBaseSpecies(breeding_plan.tree)

        if #at_risk > 0 then
            print("=== THESE WILL BE USED UP ===")

            for _, entry in ipairs(at_risk) do
                print(string.format("  %-18s %d princess(es), %d drone(s) in stock%s",
                    entry.species, entry.princesses, entry.drones,
                    entry.tight and "   <-- your last one" or ""))
            end

            print()
            print("The mutatron consumes BOTH parents. These species have no recipe, so once")
            print("spent they cannot be made again. Breed spares first if you want to keep them.")
            print()
        end
    end

    if #blocking > 0 then
        print("=== YOU MUST SUPPLY THESE FIRST ===")

        for _, species in ipairs(blocking) do
            print(string.format("  %-18s a princess OR a drone -- put it in the input chest",
                species))
        end

        print()
        print("These have no recipe in the database and none is in stock, so the plan stops")
        print("at them. Everything else is bred from what you already have.")
        print()
    end

    -- Display execution summary
    print("=== EXECUTION SUMMARY ===")
    print("1. Build the tree from bottom to top (depth-first)")
    print("2. Follow golden path (left branches)")
    print("3. When missing drones, execute accumulation cycles")
    print("4. Resume golden path when drones are available")
    print("5. Each step: Princess + Drone -> Queen -> Apiary -> New Queen + Drones")

    if #blocking > 0 then
        print()
        print("NOT READY: " .. #blocking .. " species missing, listed above.")
    end

    return true
end

-- Display breeding tree structure
function displayTree(tree, prefix, isLast)
    if not tree then return end

    local connector = isLast and "└── " or "├── "
    local status_princess = hasSpeciesPrincess(tree.species) and "P" or " "
    local status_drone = hasSpeciesDrone(tree.species) and "D" or " "
    local breeding_marker = (tree.left_parent or tree.right_parent) and " *" or ""

    -- Add optimization marker for nodes that reuse drones from elsewhere
    local optimization_marker = ""
    if tree.reusing_stock then
        optimization_marker = " (from stock)"
    elseif tree.reusing_drone then
        optimization_marker = " (reusing)"
    end

    print(prefix .. connector .. tree.species .. " [" .. status_princess .. status_drone .. "]" .. breeding_marker .. optimization_marker)

    local newPrefix = prefix .. (isLast and "    " or "│   ")

    -- Display all children to show complete breeding structure
    if tree.left_parent and tree.right_parent then
        -- Both parents exist
        displayTree(tree.left_parent, newPrefix, false)
        displayTree(tree.right_parent, newPrefix, true)
    elseif tree.left_parent then
        -- Only princess parent (left)
        displayTree(tree.left_parent, newPrefix, true)
    elseif tree.right_parent then
        -- Only drone parent (right)
        displayTree(tree.right_parent, newPrefix, true)
    end
end

-- Helper function to determine if a node should be displayed
function shouldDisplayNode(tree)
    if not tree then return false end

    -- Always show nodes that need breeding (have parents)
    if tree.left_parent or tree.right_parent then
        return true
    end

    -- Always show leaf nodes - they represent essential breeding components
    -- Even if they don't need drones, they might be needed as princesses
    return true
end

-- Get user confirmation
function getConfirmation()
    print()
    print("Options:")
    print("1. Start breeding process")
    print("2. Refresh inventory")
    print("3. Choose different target")
    print("4. Exit")
    print()
    io.write("Choice (1-4): ")

    local choice = io.read()
    return tonumber(choice) or 0
end

-- Enhanced target selection with mod filtering
function selectTarget()
    -- config.mod_list has never existed: the key is enabled_mods. Reading the wrong one left
    -- `mods` empty, so the menu listed no filter at all and "f" could only offer 0 to 0.
    local mods = config.enabled_mods or {}
    local current_filter = nil
    local search_results = nil
    local filtered_bees = available_bees

    -- Declared out here on purpose. Inside the loop these were reset on every redraw, so "n"
    -- moved to page two and the next redraw put you straight back on page one.
    -- One line per bee, minus the room the header, the mod list and the prompt need.
    local page_size = math.max(5, (screen_height or 25) - 10 - #mods)
    local current_page = 1

    mod_counts = {}
    for _, mod in ipairs(mods) do
        mod_counts[mod] = 0
    end

    for _, species in ipairs(available_bees) do
        local mod = mutations[species] and mutations[species].mod
        if mod and mod_counts[mod] then
            mod_counts[mod] = mod_counts[mod] + 1
        end
    end

    while true do
        setupDisplay()

        print("=== BEE SELECTION MENU ===")
        print("Database contains " .. #available_bees .. " bee species")
        print()

        -- Show mod filter options
        print("Mod Filters:")
        print("0. All Mods (" .. #available_bees .. " bees)")
        for i, mod in ipairs(mods) do
            local count = mod_counts[mod] or 0
            local active = (current_filter == mod) and " [ACTIVE]" or ""
            print(string.format("%d. %s (%d bees)%s", i, mod, count, active))
        end
        print()

        -- A search wins over a mod filter, and both over the full list. Before, a search stored
        -- its results in filtered_bees and the next redraw overwrote them from current_filter,
        -- which held "Search: ..." -- a mod name that matches nothing. The results vanished on
        -- the very next frame.
        if search_results then
            filtered_bees = search_results
            print("Showing matches for '" .. tostring(current_filter) .. "':")
        elseif current_filter then
            filtered_bees = getBeesByMod(current_filter)
            print("Showing " .. current_filter .. " bees:")
        else
            filtered_bees = available_bees
            print("Showing all bees:")
        end

        -- Show bees with pagination
        local total_pages = math.max(1, math.ceil(#filtered_bees / page_size))
        if current_page > total_pages then current_page = total_pages end

        local function showPage(page)
            local start_idx = (page - 1) * page_size + 1
            local end_idx = math.min(page * page_size, #filtered_bees)

            for i = start_idx, end_idx do
                local species = filtered_bees[i]
                local status = hasSpecies(species) and " [HAVE]" or ""
                local mod_info = mutations[species] and (" [" .. mutations[species].mod .. "]") or ""

                print(string.format("%2d. %s%s%s", i, species, status, mod_info))
            end

            if total_pages > 1 then
                print()
                print("Page " .. page .. " of " .. total_pages)
                print("Commands: n=next page, p=prev page, f=filter, s=search, c=clear, 0=quit")
            end
        end

        showPage(current_page)

        print()
        io.write("Choice (number/command): ")
        local input = io.read()

        if input == "n" and current_page < total_pages then
            current_page = current_page + 1
        elseif input == "p" and current_page > 1 then
            current_page = current_page - 1
        elseif input == "c" then
            current_filter = nil
            search_results = nil
            current_page = 1
        elseif input == "f" then
            print("Select mod filter (0-" .. #mods .. "): ")

            local filter_choice = tonumber(io.read())

            search_results = nil

            if filter_choice == 0 then
                current_filter = nil
            elseif filter_choice and filter_choice >= 1 and filter_choice <= #mods then
                current_filter = mods[filter_choice]
            end

            current_page = 1
        elseif input == "s" then
            print("Enter search term: ")

            local search = io.read():lower()
            local matches = {}

            -- Plain find: a species name is data, and "Nuclear Technician" or a name with a dash
            -- would otherwise be read as a pattern.
            for _, species in ipairs(available_bees) do
                if species:lower():find(search, 1, true) then
                    table.insert(matches, species)
                end
            end

            if #matches > 0 then
                search_results = matches
                current_filter = search
                current_page = 1
            else
                print("No matches found. Press anything...")
                io.read()
            end
        else
            local choice = tonumber(input)

            if choice == 0 then
                return nil
            elseif choice and choice >= 1 and choice <= #filtered_bees then
                return filtered_bees[choice]
            else
                print("Invalid choice. Press anything to continue...")
                io.read()
            end
        end
    end
end

-- GUI state variables (declared at the top of the file)
gui_state = {
    target = "",
    current_species = "",
    step_type = "", -- "breeding", "accumulation", "complete"
    current_step = 0,
    total_steps = 0,
    inventory_status = "",
    errors = "",
    status = "Running", -- "Running", "Paused", "Error", "Complete"
    progress = ""
}

-- Error handling and control state (declared at the top of the file)
control_state = {
    paused = false,
    error_state = false,
    last_error = "",
    abort_requested = false,
    validation_required = false,
    beebee_unreadable_warned = false,  -- The unreadable-gun warning is only worth saying once
    signal_queue = {},              -- Machine signals pulled while waiting for another one
    automation_warned = false       -- The Automation upgrade warning is only worth saying once
}

--- Helper function for concise GUI updates
--- @param progress string|nil Progress description text
--- @param step_type string|nil Current step type
--- @param status string|nil Overall status
--- @param errors string|nil Error message text
--- @param current_species string|nil Current species being processed
local function updateGUI(progress, step_type, status, errors, current_species)
    local args = {}
    if progress then args.progress = progress end
    if step_type then args.step_type = step_type end
    if status then args.status = status end
    if errors then args.errors = errors end
    if current_species then args.current_species = current_species end
    drawGUI(args)
end

--- Handle error with user intervention
--- @param error_message string The error message to display
--- @param validation_func function|nil Function to validate fix (returns boolean, string)
function handleError(error_message, validation_func)
    control_state.error_state = true
    control_state.last_error = error_message
    control_state.validation_required = validation_func ~= nil

    gui_state.errors = error_message
    gui_state.status = "Error"
    drawGUI({errors = error_message, status = "Error"})

    -- Update status indicators
    updateStatusIndicators("error", "ERROR: " .. error_message, gui_state.current_species)

    computer.beep(1000, 0.5) -- Error beep
    computer.beep(800, 0.3)

    -- Wait for user intervention
    waitForUserAction(validation_func)
end

--- Wait for user to resume or abort after error/pause
--- @param validation_func function|nil Function to validate fix before resuming
function waitForUserAction(validation_func)
    drawGUI({progress = "PAUSED - Press [R]esume, [A]bort, or [Q]uit", status = "Paused"})

    while control_state.error_state or control_state.paused do
        -- Check for keyboard input without swallowing machine signals (task 14).
        -- A pause can outlast a whole apiary cycle; a filtered pull here would eat
        -- the apiary_finished the caller is waiting for.
        local eventType, address, char, code = event.pull(0.1)

        if eventType and eventType ~= "key_down" then
            queueMachineSignal(eventType)
            eventType = nil
        end

        if eventType then
            local key = string.char(char):lower()

            if key == 'r' then
                -- Resume request
                if control_state.error_state and validation_func then
                    -- Validate that the issue is fixed
                    drawGUI({progress = "Validating fix...", status = "Validating"})
                    local success, error_msg = validation_func()

                    if success then
                        -- Issue fixed, can resume
                        control_state.error_state = false
                        control_state.paused = false
                        gui_state.errors = ""
                        gui_state.status = "Running"
                        drawGUI({progress = "Resuming...", errors = "", status = "Running"})
                        updateStatusIndicators("working", "Resumed: Issue fixed", gui_state.current_species)
                        computer.beep(600, 0.2) -- Success beep
                        os.sleep(1)
                        break
                    else
                        -- Issue not fixed, stay paused
                        handleError(error_msg or control_state.last_error, validation_func)
                    end
                else
                    -- Simple resume (no validation required)
                    control_state.error_state = false
                    control_state.paused = false
                    gui_state.errors = ""
                    gui_state.status = "Running"
                    drawGUI({progress = "Resuming...", errors = "", status = "Running"})
                    computer.beep(600, 0.2)
                    os.sleep(1)
                    break
                end

            elseif key == 'a' or key == 'q' then
                -- Abort request
                control_state.abort_requested = true
                control_state.error_state = false
                control_state.paused = false
                gui_state.status = "Aborted"
                drawGUI({progress = "Operation aborted by user", status = "Aborted"})
                updateStatusIndicators("aborted", "Operation aborted by user", gui_state.current_species)
                computer.beep(400, 0.8) -- Abort beep
                break

            elseif key == 'p' and not control_state.error_state then
                -- Manual pause toggle
                control_state.paused = not control_state.paused
                if control_state.paused then
                    gui_state.status = "Paused"
                    drawGUI({progress = "Manually paused", status = "Paused"})
                else
                    gui_state.status = "Running"
                    drawGUI({progress = "Resuming...", status = "Running"})
                    break
                end
            end
        end

        os.sleep(0.1) -- Small delay to prevent CPU spinning
    end
end

--- Check if operation should continue (handles pause/abort)
--- @return boolean shouldContinue True if operation should continue
--- @return string|nil errorMessage Error message if operation should stop
function checkContinue()
    if control_state.abort_requested then
        return false, "Operation aborted by user"
    end

    -- Drain the event queue without dropping anything (task 14). A pull filtered on
    -- "key_down" throws away every machine signal queued in front of it, and a pull
    -- filtered on a machine signal throws away the key presses that pause and abort
    -- rely on. So pull unfiltered and dispatch by hand.
    for _ = 1, 16 do
        local event_name, address, char = event.pull(0)
        if not event_name then break end

        if event_name == "key_down" then
            if processKeyEvent(char) then

                return false, "Operation aborted by user"
            end
        else
            queueMachineSignal(event_name)
        end
    end

    if control_state.paused and not control_state.error_state then
        waitForUserAction()
    end

    return not control_state.abort_requested, nil
end

-- Machine signals worth remembering when they arrive out of turn. The _output
-- signals are deliberately absent: they are frequent and carry no state we need.
local buffered_signals = {
    advmutatron_started = true,
    advmutatron_finished = true,
    apiary_started = true,
    apiary_finished = true
}

--- Act on a single key press taken from the event queue
--- @param char number|nil Character code from a key_down signal
--- @return boolean abort True if the user asked to abort
function processKeyEvent(char)
    if type(char) ~= "number" or char < 32 or char > 255 then

        return false
    end

    local key = string.char(char):lower()

    if key == 'p' then
        control_state.paused = true
        waitForUserAction()
    elseif key == 'a' or key == 'q' then
        control_state.abort_requested = true

        return true
    end

    return false
end

--- Remember a machine signal pulled while waiting for something else (task 14)
--- @param event_name string Name of the signal
function queueMachineSignal(event_name)
    if buffered_signals[event_name] then
        control_state.signal_queue[event_name] = true
    end
end

--- Consume a machine signal that had already arrived
--- @param event_name string Name of the signal
--- @return boolean seen True if the signal was buffered
function takeQueuedSignal(event_name)
    if control_state.signal_queue[event_name] then
        control_state.signal_queue[event_name] = nil

        return true
    end

    return false
end

--- Wait for a machine signal while keeping pause and abort responsive (task 14)
--- @param signal_name string Signal to wait for, e.g. "apiary_finished"
--- @param timeout number Maximum wait in seconds
--- @param on_tick function|nil Called about once a second with the elapsed seconds
--- @return boolean received True if the signal arrived
--- @return string|nil reason "timeout" or "aborted" when it did not
function waitForMachineSignal(signal_name, timeout, on_tick)
    if takeQueuedSignal(signal_name) then

        return true
    end

    local started = computer.uptime()
    local last_tick = started

    while computer.uptime() - started < timeout do
        -- Short and UNFILTERED, for the reason spelled out in checkContinue
        local event_name, address, char = event.pull(0.25)

        if event_name == "key_down" then
            if processKeyEvent(char) then

                return false, "aborted"
            end
        elseif event_name == signal_name then

            return true
        elseif event_name then
            queueMachineSignal(event_name)
        end

        if control_state.abort_requested then

            return false, "aborted"
        end

        if on_tick and computer.uptime() - last_tick >= 1 then
            last_tick = computer.uptime()
            on_tick(computer.uptime() - started)
        end
    end

    return false, "timeout"
end

--- Read the apiary queen slot
--- @return table|nil status { occupied, type, freed, automated, error }, nil without drivers
--- @return string|nil reason Why the read failed
function getApiaryPrincessStatus()
    if not (gendustry and gendustry.available and gendustry.apiary) then

        return nil, "no drivers"
    end

    local status, reason = apiaryCall("getPrincessStatus")
    if type(status) ~= "table" then

        return nil, reason or "getPrincessStatus returned nothing"
    end

    return status
end

--- Read the Forestry error states of the apiary (task 19)
--- @return string description Human readable cause, or a fallback text
function describeApiaryErrors()
    if not (gendustry and gendustry.available and gendustry.apiary) then

        return "No products collected"
    end

    local errors, reason = apiaryCall("getErrors")
    if type(errors) ~= "table" then

        return "No products collected - could not read apiary errors: " .. tostring(reason)
    end

    if not errors.hasErrors or not errors.errors or #errors.errors == 0 then

        return "No products collected - the apiary reports no error"
    end

    return "Apiary errors: " .. table.concat(errors.errors, ", ")
end

--- Stop the apiary so an inventory transfer cannot race a running cycle (task 20)
--- @return string|nil previous_mode Mode to hand back to unfreezeApiary, nil if nothing changed
function freezeApiary()
    if not (gendustry and gendustry.available and gendustry.apiary) then

        return nil
    end

    local current = apiaryCall("getRedstoneMode")
    local previous = type(current) == "table" and current.mode or nil

    -- ALWAYS/NEVER rather than RS_ON/RS_OFF: the apiary must not follow the wire
    -- the Mechanical User sits on
    local ok = apiaryCall("setRedstoneMode", "NEVER")
    if not ok then

        return nil
    end

    return previous or "ALWAYS"
end

--- Give the apiary back the mode saved by freezeApiary (task 20)
--- @param previous_mode string|nil Mode returned by freezeApiary
function unfreezeApiary(previous_mode)
    if not previous_mode then

        return
    end

    if not (gendustry and gendustry.available and gendustry.apiary) then

        return
    end

    local mode = previous_mode
    if mode == "RS_ON" or mode == "RS_OFF" then
        -- Never hand the apiary back to the Mechanical User's signal
        mode = "ALWAYS"
    end

    apiaryCall("setRedstoneMode", mode)
end

--- Tune signal rates and warn about a misconfigured apiary (tasks 15, 18)
function prepareApiaryForRun()
    if not (gendustry and gendustry.available) then

        return
    end

    -- Task 15: only the output scan is throttled. _started and _finished are never
    -- coalesced by the driver, so slowing this down cannot lose a cycle boundary.
    if gendustry.apiary then
        apiaryCall("setEventsEnabled", true)
        apiaryCall("setSignalInterval", config.signal_interval_ticks)
    end

    if gendustry.adv then
        advCall("setEventsEnabled", true)
        advCall("setSignalInterval", config.signal_interval_ticks)
    end

    -- Task 18: with an Automation upgrade the queen slot empties itself, so "freed"
    -- no longer means "cycle finished". Decision D3: the upgrade must not be there.
    local status = getApiaryPrincessStatus()
    if status and status.automated and not control_state.automation_warned then
        control_state.automation_warned = true
        print("WARNING: Automation upgrade installed on the apiary - remove it (MIGRATION.md D3)")
        drawGUI({progress = "WARNING: Automation upgrade on the apiary",
                 errors = "Remove the Automation upgrade: it empties the queen slot and breaks cycle detection",
                 status = "Warning"})
        computer.beep(500, 0.4)
    end
end

--- Wait until the queen slot holds a mated queen (task 16a)
--- @param timeout number Seconds to allow for mating
--- @return boolean ready True if a queen is in the slot, or if we cannot tell
--- @return string|nil errorMessage Why the wait failed
function waitForMatedQueen(timeout)
    local status = getApiaryPrincessStatus()
    if not status then
        -- Degraded mode: nothing to read, keep the previous behaviour

        return true, nil
    end

    local started = computer.uptime()

    while status and status.type == "princess" and computer.uptime() - started < timeout do
        drawGUI({step_type = "Processing", progress = "Waiting for the princess to be mated", status = "Working"})

        local should_continue, abort_msg = checkContinue()
        if not should_continue then

            return false, abort_msg
        end

        os.sleep(1)
        status = getApiaryPrincessStatus()
    end

    if status and status.type == "princess" then

        return false, "Princess still unmated after " .. timeout .. "s - is a drone loaded?"
    end

    return true, nil
end

--- Fire the BeeBee Gun, but only at a confirmed queen (tasks 16a, 17)
--- @return boolean fired True if the queen slot was freed by the shot
--- @return string|nil reason Why nothing was fired, or why the shot did not carry
function killQueenWithBeebeeGun()
    local status = getApiaryPrincessStatus()

    if not status then
        -- Degraded mode: we cannot tell a princess from a queen, so behave as before
        activateMechanicalUser()

        return true, nil
    end

    if status.automated then

        return false, "Automation upgrade installed - the queen slot empties itself (D3)"
    end

    if status.freed or status.type == "none" then

        return false, "Queen slot already empty - the cycle is over"
    end

    if status.type == "princess" then
        -- Shooting here would cost the whole line, silently

        return false, "Unmated princess in the apiary - refusing to shoot"
    end

    if status.type ~= "queen" then

        return false, "Unexpected queen slot content: " .. tostring(status.type)
    end

    for attempt = 1, config.beebee_gun_retries do
        activateMechanicalUser()

        if control_state.abort_requested then

            return false, "Operation aborted by user"
        end

        -- Let the Mechanical User swing before reading the slot back
        os.sleep(1)

        local after = getApiaryPrincessStatus()
        if not after or after.freed or after.type ~= "queen" then

            return true, nil
        end

        drawGUI({step_type = "Processing",
                 progress = "Shot " .. attempt .. " did not free the queen slot",
                 status = "Working"})
    end

    return false, "BeeBee Gun fired " .. config.beebee_gun_retries ..
                  " times without freeing the queen slot - check the ammunition"
end

--- Wait for the apiary cycle to end and time it (tasks 13, 21)
--- @return boolean success True if the cycle ended
--- @return number|string elapsed Measured duration in seconds, or an error message
function waitForApiaryCycle()
    local started = computer.uptime()

    if not (gendustry and gendustry.available and gendustry.apiary) then
        -- Degraded mode: the fixed timer is all we have
        for t = 1, config.apiary_wait_time do
            if t % 10 == 0 then
                drawGUI({step_type = "Processing",
                         progress = (config.apiary_wait_time - t) .. " seconds remaining",
                         status = "Working"})

                local should_continue, abort_msg = checkContinue()
                if not should_continue then

                    return false, abort_msg
                end
            end
            os.sleep(1)
        end

        return true, computer.uptime() - started
    end

    local status = getApiaryPrincessStatus()
    if status and (status.freed or status.type == "none") then
        -- The BeeBee Gun already ended it; no signal is coming

        return true, computer.uptime() - started
    end

    local function tick(elapsed)
        drawGUI({step_type = "Processing",
                 progress = string.format("Apiary cycle: %ds elapsed", math.floor(elapsed)),
                 status = "Working"})
    end

    local received, reason = waitForMachineSignal("apiary_finished", config.apiary_cycle_timeout, tick)
    local elapsed = computer.uptime() - started

    if not received then
        if reason == "aborted" then

            return false, "Operation aborted by user"
        end

        -- Timeout: a long cycle is not a stalled machine
        local working = apiaryCall("isWorking")
        if working then

            return false, string.format("Apiary still working after %ds - raise config.apiary_cycle_timeout",
                                        math.floor(elapsed))
        end

        return false, "Apiary stopped without finishing - " .. describeApiaryErrors()
    end

    -- Task 21: a measured duration is what should replace apiary_wait_time
    local modifiers = apiaryCall("getModifiers")
    local lifespan = type(modifiers) == "table" and modifiers.lifespan or "?"
    print(string.format("Apiary cycle took %.1fs (lifespan modifier %s)", elapsed, tostring(lifespan)))

    return true, elapsed
end

--- Validate that beebee gun is available
--- @return boolean success True if beebee gun is found
--- @return string|nil errorMessage Error message if validation failed
function validateBeebeeGun()
    local hasGun, gunName = checkBeebeeGun()
    if hasGun then
        return true, nil
    else
        return false, "Beebee gun still not found in Mechanical User slot " .. config.beebee_gun_slot
    end
end

--- Validate that a specific bee type is available
--- @param species string The bee species name
--- @param bee_type string Type of bee ("princess" or "drone")
--- @return boolean success True if bee is found
--- @return string|nil errorMessage Error message if validation failed
function validateBeeAvailability(species, bee_type)
    local location = findBeeInInventory(species, bee_type)
    if location then
        return true, nil
    else
        return false, "Could not find " .. species .. " " .. bee_type .. " in any inventory"
    end
end

--- Test whether an item name designates a given species, as a whole word
--- Guards against "Common" matching "Uncommon", which a plain find() does not
--- @param item_name string|nil Item label or item id
--- @param species string|nil Species name to look for
--- @return boolean matched True if the species appears as a whole word
function speciesMatchesItem(item_name, species)
    if not item_name or not species then

        return false
    end

    local haystack = item_name:lower()
    local needle = (species:lower():gsub("(%W)", "%%%1"))

    return haystack:find("%f[%a]" .. needle .. "%f[%A]") ~= nil
end

--- Read the mutatron output stack, preferring the driver over the inventory controller
--- @return table|nil stack Normalised stack { name, label, count } or nil when empty
--- @return string|nil reason Reason the output could not be read
function readMutatronOutput()
    if gendustry.available and gendustry.adv then
        local out, reason = advCall("getOutput")
        if out == nil then

            return nil, reason
        end

        return {name = out.name, label = out.label, count = out.count or 1}, nil
    end

    -- Degraded mode: read the configured output slot through the inventory controller
    local stack = inv_controller.getStackInSlot(config.mutatron_side, config.mutatron_output_slot)
    if not stack then

        return nil, nil
    end

    return {name = stack.name, label = stack.label, count = stack.size or 1}, nil
end

--- Validate the mutatron output, and the species it holds when a target is given
--- @param target_species string|nil Expected species, or nil to only check presence
--- @return boolean success True if the output holds the expected bee
--- @return string|nil errorMessage Error message if validation failed
function validateMutatronOutput(target_species)
    local stack, reason = readMutatronOutput()
    if not stack then

        return false, reason or "No queen produced by mutatron - check power and materials"
    end

    if not target_species then

        return true, nil
    end

    -- The species reads from the display label; the item id carries only the bee type
    local item_name = stack.label or stack.name or ""
    if speciesMatchesItem(item_name, target_species) then

        return true, nil
    end

    -- Reject only when another species is positively identified. An unreadable name
    -- must not cost a cycle, so it is reported and accepted.
    local produced = extractSpecies(item_name)
    if produced then

        return false, "Mutatron produced " .. produced .. " instead of " .. target_species
    end

    drawGUI({errors = "Unidentified mutatron output '" .. item_name .. "' - assuming " .. target_species,
             status = "Warning"})

    return true, nil
end

function validateApiarySpace()
    local stack = inv_controller.getStackInSlot(config.apiary_side, config.apiary_input_slot)
    if not stack then
        return true, nil
    else
        return false, "Apiary input slot is blocked - clear slot " .. config.apiary_input_slot
    end
end

--- Set colored lamp status
--- @param color number RGB color value (0x000000 to 0xFFFFFF)
function setStatusLamp(color)
    if config.use_status_lamp and coloredlamp then
        coloredlamp.setLampColor(color)
    end
end

--- Send notification interface message
--- @param message string The message to send
--- @param player string|nil Specific player to send to (nil for broadcast)
function sendChatNotification(message, player)
    if config.use_chat_notifications and notification_interface then
        player = player or config.chat_player_name
        -- Use notify function: notify(title, description, iconName, iconMeta)
        local title = "HiveMind"
        local description = message
        local icon = "forestry:bee_drone_ge" -- Use a bee-related icon if available
        local iconMeta = 0

        notification_interface.notify(title, description, icon, iconMeta)
    end
end

-- Status indicator color scheme (declared at the top of the file)
status_colors = {
    idle = 0xFFFFFF,      -- White - idle/ready
    working = 0x00FF00,   -- Green - working normally
    waiting = 0xFFFF00,   -- Yellow - waiting for resources
    error = 0xFF0000,     -- Red - error state
    paused = 0xFF8800,    -- Orange - paused
    complete = 0x0000FF,  -- Blue - task complete
    aborted = 0x800080    -- Purple - aborted
}

--- Update status indicators based on current state
--- @param state string Status state key (idle, working, waiting, error, paused, complete, aborted)
--- @param message string|nil Chat message to send (nil for lamp-only update)
--- @param species string|nil Current species being processed
function updateStatusIndicators(state, message, species)
    local color = status_colors[state] or status_colors.idle
    setStatusLamp(color)

    if message then
        local chat_message = message
        if species then
            chat_message = chat_message .. " (" .. species .. ")"
        end
        sendChatNotification(chat_message)
    end
end

--- Initialize the GUI display
function initGUI()
    -- Set up GUI layout, resolution before clearing (see setupDisplay)
    applyBestResolution()
    term.clear()
    gpu.setBackground(0x000000)
    gpu.setForeground(0xFFFFFF)

    -- Draw static GUI frame
    drawGUIFrame()
end

function drawGUIFrame()
    local width = screen_width or 80
    local height = screen_height or 25
    local rule = string.rep("═", width - 2)

    -- Draw top border
    gpu.set(1, 1, "╔" .. rule .. "╗")

    -- Draw section separators. The rows are fixed: the sections hold a known number of lines,
    -- and extra height goes to the last one, which is where the error messages land.
    for _, row in ipairs({3, 6, 9, 12, 15, 18}) do
        gpu.set(1, row, "╠" .. rule .. "╣")
    end

    -- Draw bottom border
    gpu.set(1, height, "╚" .. rule .. "╝")

    -- Draw side borders
    for i = 2, height - 1 do
        gpu.set(1, i, "║")
        gpu.set(width, i, "║")
    end

    -- Draw section labels
    gpu.set(3, 2, "Target:")
    gpu.set(3, 4, "Current Step:")
    gpu.set(3, 7, "Progress:")
    gpu.set(3, 10, "Inventory:")
    gpu.set(3, 13, "Status:")
    gpu.set(3, 16, "Errors/Warnings:")
    gpu.set(3, 19, "Controls: [P]ause [R]esume [A]bort [Q]uit")
end

--- Draw GUI elements with current status
--- @param args table<string, any> GUI arguments table
--- @param args.current_species string|nil Current bee species being processed
--- @param args.step_type string|nil Current step type (Loading, Breeding, Processing, etc.)
--- @param args.progress string|nil Progress description text
--- @param args.current_step number|nil Current step number
--- @param args.total_steps number|nil Total number of steps
--- @param args.inventory_status string|nil Inventory status text
--- @param args.errors string|nil Error message text
--- @param args.status string|nil Overall status (Working, Error, Paused, etc.)
function drawGUI(args)
    -- Update GUI state
    if args.current_species then gui_state.current_species = args.current_species end
    if args.step_type then gui_state.step_type = args.step_type end
    if args.progress then gui_state.progress = args.progress end
    if args.current_step then gui_state.current_step = args.current_step end
    if args.total_steps then gui_state.total_steps = args.total_steps end
    if args.inventory_status then gui_state.inventory_status = args.inventory_status end
    if args.errors then gui_state.errors = args.errors end
    if args.status then gui_state.status = args.status end

    -- Clear content areas (keep borders)
    for i = 2, 24 do
        if i ~= 3 and i ~= 6 and i ~= 9 and i ~= 12 and i ~= 15 and i ~= 18 then
            gpu.set(2, i, string.rep(" ", 78))
        end
    end

    -- Draw target
    gpu.set(12, 2, gui_state.current_species or "")

    -- Draw current step info
    local step_info = ""
    if gui_state.step_type then
        if gui_state.step_type:lower() == "breeding" then
            step_info = "Breeding " .. (gui_state.current_species or "")
        elseif gui_state.step_type:lower() == "accumulation" then
            step_info = "Accumulating " .. (gui_state.current_species or "") .. " drones"
        elseif gui_state.step_type:lower() == "complete" then
            step_info = "Breeding Complete!"
        else
            step_info = gui_state.step_type .. ": " .. (gui_state.current_species or "")
        end
    else
        step_info = gui_state.current_species or ""
    end
    gpu.set(16, 4, step_info)

    -- Draw sub-step progress
    gpu.set(3, 5, gui_state.progress)

    -- Draw progress bar
    local progress_width = 70
    local filled = 0
    if gui_state.total_steps > 0 then
        filled = math.floor((gui_state.current_step / gui_state.total_steps) * progress_width)
    end

    local progress_bar = "[" .. string.rep("█", filled) .. string.rep("░", progress_width - filled) .. "]"
    gpu.set(3, 8, progress_bar)

    -- Draw step counter
    local step_text = string.format("Step %d/%d", gui_state.current_step, gui_state.total_steps)
    gpu.set(76 - string.len(step_text), 8, step_text)

    -- Draw inventory status
    gpu.set(3, 11, gui_state.inventory_status)

    -- Draw status with color
    local status_color = 0xFFFFFF -- White
    if gui_state.status == "Running" then
        status_color = 0x00FF00 -- Green
    elseif gui_state.status == "Paused" then
        status_color = 0xFFFF00 -- Yellow
    elseif gui_state.status == "Error" then
        status_color = 0xFF0000 -- Red
    elseif gui_state.status == "Complete" then
        status_color = 0x00FFFF -- Cyan
    end

    gpu.setForeground(status_color)
    gpu.set(11, 13, gui_state.status)
    gpu.setForeground(0xFFFFFF)

    -- Draw errors/warnings
    if gui_state.errors and gui_state.errors ~= "" then
        gpu.setForeground(0xFF0000) -- Red for errors
        -- Word wrap errors to fit in the area
        local error_lines = wrapText(gui_state.errors, 76)
        for i, line in ipairs(error_lines) do
            if i <= 2 then -- Only show first 2 lines
                gpu.set(3, 16 + i, line)
            end
        end
        gpu.setForeground(0xFFFFFF)
    end

    -- Redraw the controls line: the content clear above wipes row 19, which is
    -- only painted once by drawGUIFrame
    gpu.set(3, 19, "Controls: [P]ause [R]esume [A]bort [Q]uit")

    -- Draw hive conditions, mutation first: it multiplies the cross chance (task 29)
    local conditions = getApiaryConditions()
    if conditions then
        local mutation_color = 0xFFFFFF
        if type(conditions.mutation) == "number" then
            if conditions.mutation > 1 then
                mutation_color = 0x00FF00 -- Green: the cross is helped
            elseif conditions.mutation < 1 then
                mutation_color = 0xFF0000 -- Red: the cross is penalized
            end
        end

        gpu.set(3, 20, "Hive:")
        gpu.setForeground(mutation_color)
        gpu.set(9, 20, string.sub(conditions.mutation_text, 1, 16))
        gpu.setForeground(0xFFFFFF)
        gpu.set(26, 20, string.sub(conditions.detail, 1, 52))
        gpu.set(9, 21, string.sub(conditions.climate, 1, 70))

        if conditions.automated then
            gpu.setForeground(0xFFFF00)
            gpu.set(3, 22, "Automation upgrade installed: it reinserts the princess by itself")
            gpu.setForeground(0xFFFFFF)
        end
    end
end

-- Helper function to wrap text to specified width
function wrapText(text, width)
    local lines = {}
    local current_line = ""

    for word in text:gmatch("%S+") do
        if string.len(current_line .. " " .. word) <= width then
            if current_line == "" then
                current_line = word
            else
                current_line = current_line .. " " .. word
            end
        else
            if current_line ~= "" then
                table.insert(lines, current_line)
            end
            current_line = word
        end
    end

    if current_line ~= "" then
        table.insert(lines, current_line)
    end

    return lines
end

-- Set target for GUI display
function setGUITarget(target)
    gui_state.target = target
end

-- Execute breeding process with new tree-based approach
function executeBreeding(target, breeding_plan)
    if not breeding_plan or breeding_plan.total_steps == 0 then
        print("No breeding required - target already available!")
        return true
    end

    -- Everything that prints happens BEFORE the frame is drawn. checkGendustryAPI writes its
    -- report path and prepareApiaryForRun its warnings with print(), which scrolls the terminal
    -- underneath the frame and leaves the two overlaid on top of each other.
    local hasAPI = checkGendustryAPI()

    -- Tune the signal rates and warn about an Automation upgrade before the first
    -- cycle rather than after it (tasks 15, 18)
    prepareApiaryForRun()

    -- Initialize GUI and status indicators
    initGUI()
    setGUITarget(target)
    updateStatusIndicators("working", "Starting breeding sequence", target)

    -- Initial GUI state
    drawGUI({
        step_type = "breeding",
        current_species = "Initializing...",
        progress = "Starting breeding process",
        current_step = 0,
        total_steps = breeding_plan.total_steps,
        inventory_status = "Checking inventory...",
        status = "Running"
    })

    -- Execute the breeding tree
    gui_state.current_step = 0
    local success = executeBreedingTree(breeding_plan.tree, breeding_plan.drone_requirements, hasAPI, breeding_plan.total_steps)

    if success then
        drawGUI({
            step_type = "complete",
            current_species = target,
            progress = "Breeding completed successfully!",
            current_step = breeding_plan.total_steps,
            status = "Complete"
        })
        computer.beep(1000, 0.5)

        -- Final inventory scan
        scanInventory()
    else
        -- Keep the reason the step itself gave. Overwriting it with a generic line threw away
        -- the only sentence that said what actually went wrong.
        local reason = gui_state.errors
        if not reason or reason == "" then
            reason = "Could not complete breeding strategy"
        end

        drawGUI({
            step_type = "complete",
            current_species = target,
            progress = "Breeding failed!",
            errors = reason,
            status = "Error"
        })
    end

    return success
end

-- Execute breeding tree with smart dependency ordering to handle reuse correctly
-- Find a breeding-capable node for a given species in the tree (has parents and not reusing)
local function findBreedingNodeForSpecies(root, species)
    local found = nil
    local function dfs(node)
        if not node or found then return end
        if node.species == species and (node.left_parent or node.right_parent) and not node.reusing_drone then
            found = node
            return
        end
        dfs(node.left_parent)
        dfs(node.right_parent)
    end
    dfs(root)
    return found
end
-- Helper function to check if there's a primary breeding node for a species in the tree
function hasPrimaryBreedingNodeForSpecies(tree, species)
    if not tree then return false end

    -- Check if this node is a primary breeding node for the target species
    if tree.species == species and tree.is_primary_breeding_node then
        return true
    end

    -- Recursively check children
    return hasPrimaryBreedingNodeForSpecies(tree.left_parent, species) or
           hasPrimaryBreedingNodeForSpecies(tree.right_parent, species)
end

-- Topologically sort primary breeding nodes by their dependencies
function topologicalSortByDependencies(primary_nodes)
    local sorted = {}
    local visited = {}
    local visiting = {}

    -- Start topological sort (debug prints removed)
    for _, _ in ipairs(primary_nodes) do end

    local function visit(node)
        if visiting[node] then
            -- Circular dependency detected; handled gracefully
            return
        end

        if visited[node] then
            return
        end

        visiting[node] = true
        -- Visiting node (debug removed)

        -- Visit dependencies first (nodes that this node depends on)
        -- For dependency analysis, we care about the species, not the specific instance
        if node.left_parent then
            -- Find the primary breeding node for this dependency
            for _, dep_node in ipairs(primary_nodes) do
                if dep_node.species == node.left_parent.species and dep_node.is_primary_breeding_node then
                    visit(dep_node)
                    break
                end
            end
        end

        if node.right_parent then
            -- Find the primary breeding node for this dependency
            local found_dep = false
            for _, dep_node in ipairs(primary_nodes) do
                if dep_node.species == node.right_parent.species and dep_node.is_primary_breeding_node then
                    visit(dep_node)
                    found_dep = true
                    break
                end
            end
            -- If no dep found, we still proceed; debug removed
        end

        visiting[node] = false
        visited[node] = true
        table.insert(sorted, node)
    end

    -- Visit all primary nodes
    for _, node in ipairs(primary_nodes) do
        visit(node)
    end

    -- Topological sort complete (debug prints removed)

    return sorted
end

-- Execute a single breeding node with all validation and accumulation
function executeSingleBreedingNode(node, drone_requirements, hasAPI, total_steps)
    if not node or _G.execution_bred_species[node.species] then
        return true
    end
    -- Skip reused nodes unless explicitly designated as primary breeder for their species
    if node.reusing_drone and not node.is_primary_breeding_node then
        return true
    end

    local parents = mutations[node.species].parents
    local princess_parent = parents[1]
    local drone_parent = parents[2]

    -- Enhanced validation: check if parents are available (bred earlier or base species)
    local princess_available = hasSpeciesPrincess(princess_parent) or _G.execution_bred_species[princess_parent]
    local drone_available = hasSpeciesDrone(drone_parent) or _G.execution_bred_species[drone_parent]

    -- Attempt on-demand breeding of missing parents (handles non-primary dependencies like Esoteric)
    _G._breeding_stack = _G._breeding_stack or {}
    local function ensureSpeciesBred(spec)
        if _G.execution_bred_species[spec] then return true end
        -- Base species cannot be bred here; rely on inventory
        if not mutations[spec] then
            return hasSpeciesPrincess(spec) and hasSpeciesDrone(spec)
        end
        -- Prevent recursion cycles
        if _G._breeding_stack[spec] then return false end
        _G._breeding_stack[spec] = true
        -- Find a node in the current tree capable of breeding this species
        local root = _G._current_execution_root
        local dep_node = root and findBreedingNodeForSpecies(root, spec) or nil
        local ok = false
        if dep_node then
            ok = executeSingleBreedingNode(dep_node, drone_requirements, hasAPI, total_steps)
        end
        _G._breeding_stack[spec] = nil
        return ok or _G.execution_bred_species[spec] or (hasSpeciesPrincess(spec) and hasSpeciesDrone(spec))
    end

    if not princess_available then
        if not ensureSpeciesBred(princess_parent) then
            drawGUI({
                current_species = node.species,
                step_type = "breeding",
                progress = "ERROR: Princess " .. princess_parent .. " not available for " .. node.species,
                errors = "Missing required princess: " .. princess_parent,
                status = "Error"
            })
            return false
        end
        princess_available = true
    end

    if not drone_available then
        if not ensureSpeciesBred(drone_parent) then
            drawGUI({
                current_species = node.species,
                step_type = "breeding",
                progress = "ERROR: Drone " .. drone_parent .. " not available for " .. node.species,
                errors = "Missing required drone: " .. drone_parent,
                status = "Error"
            })
            return false
        end
        drone_available = true
    end

    drawGUI({
        current_species = node.species,
        step_type = "breeding",
        progress = "Breeding: " .. princess_parent .. " + " .. drone_parent .. " -> " .. node.species
    })

    -- Check if we need accumulation for the drone
    local drone_req = drone_requirements[drone_parent]
    if drone_req and drone_req.needed and drone_req.available and drone_req.needed > drone_req.available then
        local shortage = drone_req.needed - drone_req.available
        -- The counter is now only a floor: it says how many drones are missing.
        -- The species purity says when the trait is fixed and further cycles add nothing.
        local base_cycles = shortage + (config.add_drone_count or 1)
        local max_cycles = base_cycles + 5
        local cycle = 0
        local pure = nil

        while true do
            cycle = cycle + 1
            drawGUI({
                current_species = drone_parent,
                step_type = "accumulation",
                progress = "Accumulation cycle " .. cycle .. " (min " .. base_cycles ..
                           ", max " .. max_cycles .. ") for " .. drone_parent
            })

            local success, cycle_error
            success, cycle_error, pure = executeAccumulationCycle(drone_parent)
            if not success then
                drawGUI({
                    errors = "Accumulation cycle failed for " .. drone_parent ..
                             (cycle_error and (": " .. cycle_error) or "")
                })

                return false
            end

            -- Update available count
            if drone_req.available then
                drone_req.available = drone_req.available + 1
            end

            -- pure == nil means the genome could not be read: the counter decides alone
            if cycle >= base_cycles and pure ~= false then
                break
            end

            if cycle >= max_cycles then
                drawGUI({
                    errors = "Accumulation stopped after " .. cycle .. " cycles: " ..
                             drone_parent .. " species chromosome still not pure"
                })
                break
            end
        end
    end

    -- Execute the actual breeding step
    local success = executeSingleBreedingStep(princess_parent, drone_parent, node.species, hasAPI)
    if not success then
        drawGUI({
            current_species = node.species,
            step_type = "breeding",
            progress = "FAILED: " .. node.species,
            errors = "Could not complete breeding step for " .. node.species,
            status = "Error"
        })
        return false
    end

    -- Mark this species as successfully bred in this execution session
    _G.execution_bred_species[node.species] = true

    -- Update step counter and GUI status
    gui_state.current_step = gui_state.current_step + 1
    drawGUI({
        current_species = node.species,
        step_type = "breeding",
        progress = "Completed " .. node.species,
        current_step = gui_state.current_step,
        total_steps = total_steps
    })

    return true
end

function executeBreedingTree(tree, drone_requirements, hasAPI, total_steps)
    if not tree then return true end

    -- Initialize global tracking for species bred in this execution session
    if not _G.execution_bred_species then
        _G.execution_bred_species = {}
    end

    -- First pass: collect all breeding nodes that need to be executed
    local all_breeding_nodes = {}
    local primary_breeding_nodes = {}

    local function collectBreedingNodes(node)
        if not node then return end

    -- Debug output removed

        -- Collect this node if it requires breeding and either:
        -- 1. It's not marked as reusing, OR
        -- 2. It's a primary breeding node (even if marked as reusing)
        local should_collect = (node.left_parent or node.right_parent) and
                              (not node.reusing_drone or node.is_primary_breeding_node)

        if should_collect then
            table.insert(all_breeding_nodes, node)

            -- Separate primary breeding nodes
            if node.is_primary_breeding_node then
                table.insert(primary_breeding_nodes, node)
                -- Track as primary breeding node
            end
        end

        -- Recursively collect from children
        collectBreedingNodes(node.left_parent)
        collectBreedingNodes(node.right_parent)
    end

    collectBreedingNodes(tree)
    -- Expose root for on-demand dependency breeding
    _G._current_execution_root = tree

    -- Fallback: ensure every breeding species has at least one primary node
    -- Only consider instances that were actually collected from the tree
    local species_found = {}
    for _, node in ipairs(all_breeding_nodes) do
        species_found[node.species] = species_found[node.species] or {}
        table.insert(species_found[node.species], node)
    end

    -- For species with no primary breeding nodes, designate the first collected instance as primary
    --
    -- Walked in sorted order: the fallback primaries are appended to primary_breeding_nodes here,
    -- and topologicalSortByDependencies preserves input order between nodes it cannot order by
    -- dependency. Iterating pairs() therefore made the execution order of independent subtrees
    -- change from one run to the next, for the same plan.
    local species_in_order = {}
    for species in pairs(species_found) do
        table.insert(species_in_order, species)
    end
    table.sort(species_in_order)

    for _, species in ipairs(species_in_order) do
        local instances = species_found[species]
        local has_primary = false
        for _, instance in ipairs(instances) do
            if instance.is_primary_breeding_node then
                has_primary = true
                break
            end
        end

        if not has_primary and #instances > 0 then
            instances[1].is_primary_breeding_node = true
            table.insert(primary_breeding_nodes, instances[1])
            -- Fallback: designated instance as primary breeding node

            -- Debug: Check the parent connections of this fallback primary node
            -- Debug inspection removed
        end
    end

    -- Second pass: topologically sort primary breeding nodes by dependencies
    local sorted_primary_nodes = topologicalSortByDependencies(primary_breeding_nodes)

    -- Third pass: execute nodes in dependency-aware order
    -- 1. Execute sorted primary breeding nodes first
    for _, node in ipairs(sorted_primary_nodes) do
        local success = executeSingleBreedingNode(node, drone_requirements, hasAPI, total_steps)
        if not success then return false end
    end

    -- 2. Execute remaining non-primary nodes using post-order traversal
    local function executeRemainingNodes(node)
        if not node then return true end

        -- Execute children first (post-order)
        if node.left_parent then
            local success = executeRemainingNodes(node.left_parent)
            if not success then return false end
        end

        if node.right_parent then
            local success = executeRemainingNodes(node.right_parent)
            if not success then return false end
        end

        -- Execute current node if it needs breeding, isn't primary, and hasn't been bred yet
        if (node.left_parent or node.right_parent) and not node.reusing_drone and
           not node.is_primary_breeding_node and not _G.execution_bred_species[node.species] then
            local success = executeSingleBreedingNode(node, drone_requirements, hasAPI, total_steps)
            if not success then return false end
        end

        return true
    end

    -- Execute remaining non-primary nodes
    local success = executeRemainingNodes(tree)
    if not success then return false end

    -- Final completion status if this is the top-level call
    if tree and tree.species == gui_state.target then
        updateStatusIndicators("complete", "All breeding completed successfully!", tree.species)
        -- Clean up execution tracking
        _G.execution_bred_species = nil
        _G._current_execution_root = nil
        _G._breeding_stack = nil
    end

    return true
end

--- Execute a single breeding step (mutatron + apiary cycle)
--- @param princess_species string Species name for princess/queen
--- @param drone_species string Species name for drone
--- @param target_species string Expected output species name
--- @param hasAPI boolean Whether Gendustry API is available
--- @return boolean success True if breeding step completed successfully
--- @return string|nil errorMessage Error message if step failed
function executeSingleBreedingStep(princess_species, drone_species, target_species, hasAPI)
    -- Check if we should continue
    local should_continue, abort_msg = checkContinue()
    if not should_continue then
        return false, abort_msg
    end

    -- Phase 1: Load Mutatron
    drawGUI({current_species = target_species, step_type = "Loading", progress = "Loading: " .. princess_species .. " + " .. drone_species, status = "Working"})
    -- Only update lamp status, no chat spam
    setStatusLamp(status_colors.working)
    local load_success, load_msg = loadMutatron(princess_species, drone_species)
    if not load_success then
        return false, load_msg
    end

    -- Phase 2: Start the Mutatron
    -- With the drivers present the machine is driven, not clicked: a refusal is a real failure and
    -- is reported, never papered over by a redstone pulse aimed at the apiary.
    if hasAPI and gendustry.available then
        local api_success, api_reason = useGendustryAPI(princess_species, drone_species, target_species)
        if not api_success then
            local message = api_reason or "Mutation selection failed"
            drawGUI({step_type = "Breeding", progress = "Mutatron refused", errors = message, status = "Error"})

            return false, message
        end

        drawGUI({step_type = "Breeding", progress = api_reason or "Mutation started", status = "Working"})
    else
        -- Degraded mode: nothing to start. There is a single Mechanical User and it is aimed at
        -- the Industrial Apiary (README, Wiring 2), so the pulse that used to sit here fired the
        -- BeeBee Gun at whatever was in the queen slot instead of starting the Mutatron, killing
        -- an unmated princess and losing the line without a word. The Mutatron starts on its own
        -- through the bdlib server tick (decision D2), with or without the drivers.
        drawGUI({step_type = "Breeding", progress = "Waiting for the mutatron (no driver)",
                 status = "Working"})
    end

    -- Phase 2b: check what the mutatron actually produced, BEFORE the queen leaves it.
    -- Once she is in the apiary, rejecting her costs a full apiary cycle.
    if not waitForMutatronOutput() then

        return false, "Mutatron produced nothing"
    end

    local output_ok, output_msg = validateMutatronOutput(target_species)
    if not output_ok then
        drawGUI({step_type = "Validating", progress = "Unexpected mutatron output",
                 errors = output_msg, status = "Error"})
        handleError(output_msg, function() return validateMutatronOutput(target_species) end)
        if control_state.abort_requested then

            return false, "Aborted"
        end

        -- Re-read after the user's intervention; give up if the output is still wrong
        output_ok, output_msg = validateMutatronOutput(target_species)
        if not output_ok then

            return false, output_msg
        end
    end

    -- Phase 3: Move Queen to Apiary
    local queen_success = moveQueenToApiary()
    if not queen_success then
        drawGUI({step_type = "Breeding", progress = "Moving queen failed", errors = "Could not move queen to apiary", status = "Error"})
        return false
    end

    -- Phase 4: Process in Apiary
    prepareApiaryForRun()

    local mated_ok, mated_msg = waitForMatedQueen(config.apiary_mating_timeout)
    if not mated_ok then
        drawGUI({step_type = "Processing", progress = "Apiary cycle failed", errors = mated_msg, status = "Error"})

        return false, mated_msg
    end

    -- Only a confirmed queen is shot: an unmated princess would cost the line (task 16a),
    -- and an empty slot would waste a round and read as an error (tasks 16a, 17)
    local fired, fire_reason = killQueenWithBeebeeGun()
    if control_state.abort_requested then

        return false, "Operation aborted by user"
    end

    if not fired and fire_reason then
        drawGUI({step_type = "Processing", progress = "BeeBee Gun: " .. fire_reason, status = "Working"})
    end

    local cycle_ok, cycle_info = waitForApiaryCycle()
    if not cycle_ok then
        drawGUI({step_type = "Processing", progress = "Apiary cycle failed", errors = tostring(cycle_info), status = "Error"})

        return false, tostring(cycle_info)
    end

    -- Phase 5: Collect Products, with the apiary frozen so the inventory does not
    -- move under the transfer (task 20)
    local previous_mode = freezeApiary()
    local collect_success = collectApiaryProducts()
    unfreezeApiary(previous_mode)

    if not collect_success then
        -- Say why nothing came out instead of "No products collected" (task 19)
        drawGUI({step_type = "Collecting", progress = "Collection warning", errors = describeApiaryErrors(), status = "Warning"})
    end

    drawGUI({step_type = "Complete", progress = "Breeding step complete", status = "Completed"})
    -- Only update lamp status, no chat spam
    setStatusLamp(status_colors.working)
    computer.beep(800, 0.2)

    return true
end

--- Execute accumulation cycle (apiary-only to get more drones)
--- @param species string The species to accumulate drones for
--- @return boolean success True if accumulation cycle completed successfully
--- @return string|nil errorMessage Error message if cycle failed
--- Read whether the species chromosome of a bee in the apiary is pure
--- @param slot string "queen" or "drone"
--- @return boolean|nil pure True/false when the genome could be read, nil when it could not
--- @return string|nil reason Driver reason when the genome is unavailable
function getSpeciesPurity(slot)
    if not (gendustry.available and gendustry.apiary) then

        return nil, "no industrial_apiary driver"
    end

    -- getGenome answers false plus a reason when requireAnalyzedBees is on
    local genome, reason = apiaryCall("getGenome", slot or "queen")
    if genome == nil or genome == false then

        return nil, reason or "genome unavailable"
    end

    local chromosomes = genome.chromosomes
    if not (chromosomes and chromosomes.species) then

        return nil, "genome carries no species chromosome"
    end

    return chromosomes.species.pure == true, nil
end

function executeAccumulationCycle(species)
    drawGUI({current_species = species, step_type = "Accumulation", progress = "Running accumulation cycle", status = "Working"})

    -- Find existing queen of this species across all inventories
    local queen_side, queen_slot, queen_stack = findItemAnyInventory(species .. ".*queen")
    if not queen_slot then
        drawGUI({progress = "Accumulation failed", errors = "No " .. species .. " queen found", status = "Error"})
        return false
    end

    -- Move queen to apiary, apiary held still during the transfer (task 20)
    local insert_mode = freezeApiary()
    local success = moveItem(queen_side, queen_slot, config.apiary_side, config.apiary_input_slot, 1)
    unfreezeApiary(insert_mode)

    if not success then
        drawGUI({progress = "Move failed", errors = "Failed to move queen to apiary", status = "Error"})

        return false
    end

    -- Run the apiary cycle on signals rather than on a fixed timer (task 13)
    prepareApiaryForRun()

    local mated_ok, mated_msg = waitForMatedQueen(config.apiary_mating_timeout)
    if not mated_ok then
        drawGUI({progress = "Accumulation failed", errors = mated_msg, status = "Error"})

        return false
    end

    -- Read the queen's genome before the cycle runs: the drones she leaves behind inherit from
    -- her, so a pure species chromosome means the trait is already fixed (tasks 23, 24)
    local pure, purity_reason = getSpeciesPurity("queen")
    if pure == nil and purity_reason then
        -- Clean degradation: show the driver's own words and fall back to item names
        drawGUI({current_species = species, step_type = "Accumulation",
                 progress = "Genome unavailable - falling back to item names",
                 errors = purity_reason, status = "Warning"})
    end

    -- Only a confirmed queen is shot (tasks 16a, 17)
    local fired, fire_reason = killQueenWithBeebeeGun()
    if control_state.abort_requested then

        return false
    end

    if not fired and fire_reason then
        drawGUI({progress = "BeeBee Gun: " .. fire_reason, status = "Working"})
    end

    local cycle_ok, cycle_info = waitForApiaryCycle()
    if not cycle_ok then
        drawGUI({progress = "Accumulation failed", errors = tostring(cycle_info), status = "Error"})

        return false
    end

    -- Collect products with the apiary frozen (task 20)
    local previous_mode = freezeApiary()
    local collected = collectApiaryProducts()
    unfreezeApiary(previous_mode)

    if not collected then
        -- Task 19: name the Forestry cause instead of staying silent
        drawGUI({progress = "Collection warning", errors = describeApiaryErrors(), status = "Warning"})
    end

    drawGUI({progress = "Accumulation cycle complete", status = "Completed"})

    return true, nil, pure
end

-- ---------------------------------------------------------------------------
-- Species registry, genetics and hive conditions (tasks 26, 27, 29)
-- ---------------------------------------------------------------------------

-- The Forestry allele registry as reported by listSpeciesTemplates(). Species
-- from other mods carry their own prefix, so a uid can never be rebuilt by
-- gluing "forestry.species" in front of a name: every entry comes from the
-- driver, and the hard-coded database is matched against it, never the reverse.
local species_registry = {
    loaded = false,
    entries = {},        -- array of { uid, name, dominant, hasTemplate }
    by_key = {},         -- normalized name / uid / uid tail -> entry
    report = nil         -- last audit report
}

-- Default genomes, keyed by database species name. getSpeciesTemplate is a
-- server round trip, so each species is asked for once and remembered.
local species_template_cache = {}

--- Normalize a species name so "Light Gray", "lightgray" and "LIGHT_GRAY" match
--- @param name string|nil Raw name, uid or uid tail
--- @return string|nil key Normalized key, or nil when nothing usable is left
local function normalizeSpeciesKey(name)
    if type(name) ~= "string" then

        return nil
    end

    local key = name:lower():gsub("[^%a%d]", "")
    if key == "" then

        return nil
    end

    return key
end

--- Index one registry entry under every key it can be recognized by
--- @param entry table Registry entry { uid, name, dominant, hasTemplate }
local function indexRegistryEntry(entry)
    local keys = {}

    local function addKey(value)
        local key = normalizeSpeciesKey(value)
        if key then
            table.insert(keys, key)
        end
    end

    addKey(entry.name)
    addKey(entry.uid)

    -- "forestry.speciesForest" is "Forest" in the hard-coded database
    if type(entry.uid) == "string" then
        local tail = entry.uid:match("[^%.]+$")
        if tail then
            addKey(tail)
            addKey((tail:gsub("^[Ss]pecies", "")))
        end
    end

    for _, key in ipairs(keys) do
        if not species_registry.by_key[key] then
            species_registry.by_key[key] = entry
        end
    end
end

--- Load the Forestry allele registry once (task 26)
--- @param force boolean|nil Reload even when already loaded
--- @return boolean loaded True when the registry is usable
function loadSpeciesRegistry(force)
    if species_registry.loaded and not force then

        return true
    end

    if not (gendustry.available and gendustry.apiary) then

        return false
    end

    local list, reason = apiaryCall("listSpeciesTemplates")
    if type(list) ~= "table" then
        print("Species registry unavailable: " .. tostring(reason or "no answer from the apiary"))

        return false
    end

    species_registry.entries = {}
    species_registry.by_key = {}

    for _, entry in ipairs(list) do
        if type(entry) == "table" and entry.uid then
            table.insert(species_registry.entries, entry)
            indexRegistryEntry(entry)
        end
    end

    species_registry.loaded = true

    return true
end

--- Find the registry entry matching a database species name
--- @param species string Database species name, uid or display name
--- @return table|nil entry Registry entry, or nil when the pack does not have it
function findRegistrySpecies(species)
    if not species_registry.loaded then

        return nil
    end

    local key = normalizeSpeciesKey(species)
    if not key then

        return nil
    end

    return species_registry.by_key[key]
end

--- Every species the hard-coded database mentions: results and their parents
--- @return table<string, string> species Species name -> mod that declares it
local function collectDatabaseSpecies()
    local names = {}

    for species, data in pairs(mutations) do
        names[species] = data.mod or "unknown"
        for _, parent in ipairs(data.parents or {}) do
            if not names[parent] then
                names[parent] = (mutations[parent] and mutations[parent].mod) or "base species"
            end
        end
    end

    return names
end

--- Print the audit, capped so a large pack does not scroll the screen away
--- @param report table Report produced by auditSpeciesDatabase
local function printSpeciesAudit(report)
    local max_lines = config.species_audit_max_lines or 12

    print(string.format("Species audit: %d in the database, %d registered by the pack, %d matched",
        report.database_total, report.registry_total, #report.matched))

    if #report.missing > 0 then
        print("  In the database but not registered here (planning will fail on them):")
        for i, item in ipairs(report.missing) do
            if i > max_lines then
                print(string.format("    ... and %d more", #report.missing - i + 1))
                break
            end
            print(string.format("    %-22s (%s)", item.species, item.mod))
        end
    end

    if #report.unmatched > 0 then
        print(string.format("  Registered here but unknown to the database: %d species", #report.unmatched))
        for i, entry in ipairs(report.unmatched) do
            if i > max_lines then
                print("    ... see the diagnostic report for the full list")
                break
            end
            print(string.format("    %-30s %s", tostring(entry.uid), tostring(entry.name)))
        end
    end

    if #report.missing == 0 and #report.unmatched == 0 then
        print("  Database and pack agree")
    end
end

--- Confront the hard-coded database with the species the pack registers (task 26)
--- Reports both directions: a species we plan with that the pack does not have,
--- and a species the pack offers that the database ignores.
--- @return table|nil report { matched, missing, unmatched, totals }
function auditSpeciesDatabase()
    if not loadSpeciesRegistry() then
        species_registry.report = nil

        return nil
    end

    local db_species = collectDatabaseSpecies()
    local report = {
        matched = {},
        missing = {},         -- known to the database, absent from the registry
        unmatched = {},       -- registered by the pack, absent from the database
        registry_total = #species_registry.entries,
        database_total = 0
    }

    local seen_uid = {}

    for species, mod in pairs(db_species) do
        report.database_total = report.database_total + 1
        local entry = findRegistrySpecies(species)
        if entry then
            seen_uid[entry.uid] = true
            table.insert(report.matched, species)
        else
            table.insert(report.missing, {species = species, mod = mod})
        end
    end

    for _, entry in ipairs(species_registry.entries) do
        if not seen_uid[entry.uid] then
            table.insert(report.unmatched, entry)
        end
    end

    table.sort(report.matched)
    table.sort(report.missing, function(a, b) return a.species < b.species end)
    table.sort(report.unmatched, function(a, b) return tostring(a.uid) < tostring(b.uid) end)

    species_registry.report = report
    printSpeciesAudit(report)

    return report
end

--- Last audit report, for the diagnostic report and the tests
--- @return table|nil report
function getSpeciesAuditReport()

    return species_registry.report
end

--- Default genome of a species, cached (task 27)
--- @param species string Database species name
--- @return table|nil chromosomes, string|nil reason
function getSpeciesTemplateFor(species)
    local cached = species_template_cache[species]
    if cached then

        return cached.template, cached.reason
    end

    local template, reason = nil, nil

    if gendustry.available and gendustry.apiary then
        local entry = findRegistrySpecies(species)
        local answer, why = apiaryCall("getSpeciesTemplate", entry and entry.uid or species)
        if type(answer) == "table" then
            template = answer
        else
            reason = why or "species unknown to the registry"
        end
    else
        reason = "drivers unavailable"
    end

    species_template_cache[species] = {template = template, reason = reason}

    return template, reason
end

--- Inject a species template, for tests and for offline experiments (task 27)
--- @param species string Database species name
--- @param template table|nil Chromosome map, or nil to drop the cached answer
function setSpeciesTemplateOverride(species, template)
    if template == nil then
        species_template_cache[species] = nil

        return
    end

    species_template_cache[species] = {template = template, reason = nil}
end

--- Cost, in breeding steps, of obtaining one bee of this species (task 27)
--- A dominant species allele carries over in a single cross. A recessive one is
--- expressed only when both parents hold it, which costs at least one extra
--- generation of accumulation. Anything the driver cannot answer weighs 1, so a
--- weighted plan is never worse informed than an unweighted one.
--- @param species string Database species name
--- @return number weight
function getSpeciesStepWeight(species)
    if not config.dominance_weighting then

        return 1
    end

    local template = getSpeciesTemplateFor(species)
    local allele = template and template.species
    if type(allele) ~= "table" or allele.dominant == nil then

        return 1
    end

    if allele.dominant then

        return 1
    end

    return config.recessive_step_weight or 2
end

--- Weighted equivalent of countTreeSteps, used by the optimizer to compare
--- alternative trees. With config.dominance_weighting off it returns exactly
--- countTreeSteps, so the planner keeps its current behaviour and the existing
--- test baselines hold. countTreeSteps stays the reported step count.
--- @param tree table|nil Breeding tree node
--- @return number cost
function countTreeCost(tree)
    if not tree then return 0 end

    local cost = 0

    -- A node with parents is a cross to perform
    if tree.left_parent or tree.right_parent then
        cost = cost + getSpeciesStepWeight(tree.species)
    end

    cost = cost + countTreeCost(tree.left_parent)
    cost = cost + countTreeCost(tree.right_parent)

    return cost
end

-- Cached view of what the hive offers. drawGUI runs on every step, while
-- getModifiers is a server round trip, so the reading is held for a few seconds.
local hive_conditions = {time = -1, data = nil}

--- Read environment and modifiers from the apiary for display (task 29)
--- @param force boolean|nil Ignore the cache
--- @return table|nil conditions { mutation, automated, mutation_text, detail, climate }
function getApiaryConditions(force)
    if not (gendustry.available and gendustry.apiary) then

        return nil
    end

    local now = computer.uptime()
    if not force and hive_conditions.data and (now - hive_conditions.time) < (config.hive_conditions_refresh or 5) then

        return hive_conditions.data
    end

    local mods = apiaryCall("getModifiers")
    local env = apiaryCall("getEnvironment")

    hive_conditions.time = now

    if type(mods) ~= "table" and type(env) ~= "table" then
        hive_conditions.data = nil

        return nil
    end

    mods = type(mods) == "table" and mods or {}
    env = type(env) == "table" and env or {}

    local function factor(value)
        if type(value) ~= "number" then

            return "n/a"
        end

        return string.format("x%.2f", value)
    end

    local flags = {}
    if mods.isSealed then table.insert(flags, "sealed") end
    if mods.isSelfLighted then table.insert(flags, "lit") end
    if mods.isSunlightSimulated then table.insert(flags, "sun") end
    if mods.isCollectingPollen then table.insert(flags, "pollen") end
    if mods.isAutomated then table.insert(flags, "AUTOMATED") end

    hive_conditions.data = {
        mutation = mods.mutation,
        automated = mods.isAutomated and true or false,
        -- Mutation comes first: it multiplies the cross chance directly
        mutation_text = "Mutation " .. factor(mods.mutation),
        detail = string.format("Prod %s  Life %s  Flower %s  Terr %s",
            factor(mods.production), factor(mods.lifespan), factor(mods.flowering), factor(mods.territory)),
        climate = string.format("Climate %s / %s%s",
            tostring(env.temperature or mods.temperature or "?"),
            tostring(env.humidity or mods.humidity or "?"),
            #flags > 0 and ("  [" .. table.concat(flags, " ") .. "]") or "")
    }

    return hive_conditions.data
end

-- Main program loop
function main()
    setupDisplay()

    -- Confront the hard-coded database with what the pack registers (task 26)
    auditSpeciesDatabase()

    while true do
        scanInventory()

        local target = selectTarget()
        if not target then
            print("Goodbye!")
            break
        end

        local breeding_plan = calculateBreedingPath(target)

        -- Check if plan failed due to critical errors
        if breeding_plan and breeding_plan.plan_failed then
            print("Press anything to continue...")
            io.read()
        else
            while true do
                setupDisplay()
                local success = displayBreedingPlan(target, breeding_plan)

                if not success then
                    print("Press anything to continue...")
                    io.read()
                    break
                end

                local choice = getConfirmation()

                if choice == 1 then
                    executeBreeding(target, breeding_plan)
                    print("Press anything to continue...")
                    io.read()
                    break
                elseif choice == 2 then
                    scanInventory()
                    breeding_plan = calculateBreedingPath(target)
                elseif choice == 3 then
                    break
                elseif choice == 4 then
                    print("Goodbye!")
                    return
                else
                    print("Invalid choice. Press anything to continue...")
                    io.read()
                end
            end
        end
    end
end

-- Run the program when this file is executed, not when it is required.
--
-- Without this the file defined main() and never called it: running it on the computer loaded
-- every function, returned the table below and exited, with nothing on screen.
--
-- The importer says so explicitly rather than the file guessing from `...`: what a shell passes a
-- program varies, and a guard that reads the arguments fails silently and looks exactly like the
-- bug it replaced -- an empty screen and no error.
if not _G.HIVEMIND_AS_MODULE then
    main()
end

-- Always export module functions (tests import this module)
return {
    -- Planning functions
    calculateBreedingPath = calculateBreedingPath,
    buildBreedingTree = buildBreedingTree,
    findStartingPrincesses = findStartingPrincesses,
    calculateDroneRequirements = calculateDroneRequirements,
    displayTree = displayTree,

    -- Execution functions
    executeBreedingTree = executeBreedingTree,
    executeSingleBreedingStep = executeSingleBreedingStep,
    executeAccumulationCycle = executeAccumulationCycle,

    -- Utility functions
    getSideName = getSideName,
    hasSpeciesPrincess = hasSpeciesPrincess,
    hasSpeciesDrone = hasSpeciesDrone,

    -- Status functions (for integration tests)
    updateStatusIndicators = updateStatusIndicators,
    checkBeebeeGun = checkBeebeeGun,

    -- The execution path, so test_ingame.lua can drive it against a simulated world
    scanInventory = scanInventory,
    printInventoryDetail = printInventoryDetail,
    countSpecies = countSpecies,
    isBaseSpecies = isBaseSpecies,
    collectBlockingLeaves = collectBlockingLeaves,
    collectConsumedBaseSpecies = collectConsumedBaseSpecies,
    clearMutatron = clearMutatron,
    describeLoadFailure = describeLoadFailure,
    checkGendustryAPI = checkGendustryAPI,
    loadMutatron = loadMutatron,
    waitForMutatronOutput = waitForMutatronOutput,
    moveQueenToApiary = moveQueenToApiary,
    collectApiaryProducts = collectApiaryProducts,
    validateMutatronOutput = validateMutatronOutput,
    useGendustryAPI = useGendustryAPI,
    killQueenWithBeebeeGun = killQueenWithBeebeeGun,
    inventory = inventory,

    -- Genetics and species registry (tasks 26, 27)
    auditSpeciesDatabase = auditSpeciesDatabase,
    getSpeciesAuditReport = getSpeciesAuditReport,
    loadSpeciesRegistry = loadSpeciesRegistry,
    findRegistrySpecies = findRegistrySpecies,
    getSpeciesTemplateFor = getSpeciesTemplateFor,
    setSpeciesTemplateOverride = setSpeciesTemplateOverride,
    getSpeciesStepWeight = getSpeciesStepWeight,
    countTreeCost = countTreeCost,
    countTreeSteps = countTreeSteps,

    -- Interface
    getApiaryConditions = getApiaryConditions,

    -- Data
    mutations = mutations,
    config = config
}
