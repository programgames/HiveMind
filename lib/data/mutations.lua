-- HiveMind bee mutation database
--
-- Pure data, no dependencies. Loaded on demand by the planner so the ~28 KB of
-- table constructors are not resident when the program is only driving machines.
--
-- Each entry maps a species to the two parents that produce it and the mod that
-- adds it. A species that never appears as a key here is a base species: the
-- program can never produce it, only consume it.
--
--- @type table<string, {parents: string[], mod: string}>

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
