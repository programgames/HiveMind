-- HiveMind persistence layer
--
-- Everything the program must not forget across a reboot goes through here:
-- the gene library, the template index, the species cache, the job queue.
--
-- Two constraints shape this module:
--
--   * A Minecraft chunk can unload mid-write. A half-written state file is
--     worse than no state file at all, because it would be loaded and trusted.
--     So writes go to a temporary file and are renamed into place, which is
--     atomic on both OpenOS and a desktop filesystem.
--
--   * State files are data, never code. They are loaded in an empty
--     environment, so a corrupted or tampered file can define tables and
--     nothing else.

local state = {}

state.DEFAULT_DIRECTORY = "/home/hivemind/state"

-- OpenOS exposes rename/remove through its filesystem library; plain Lua does
-- not have one, so the desktop test runs fall back to the os functions.
local fs = nil
do
    local ok, library = pcall(require, "filesystem")
    if ok and type(library) == "table" then fs = library end
end

--- Remove a file, whatever the platform
--- @param path string
local function removeFile(path)
    if fs and fs.remove then
        pcall(fs.remove, path)
    else
        os.remove(path)
    end
end

--- Rename a file, whatever the platform
--- @param from string
--- @param to string
--- @return boolean ok
--- @return string|nil error
local function renameFile(from, to)
    if fs and fs.rename then
        local ok, err = fs.rename(from, to)
        return ok == true or ok == nil and err == nil, err
    end

    -- os.rename refuses to overwrite on some platforms, Windows included
    os.remove(to)
    local ok, err = os.rename(from, to)
    return ok == true, err
end

--- Create a directory and every parent it needs
--- The state directory is two levels deep (/home/hivemind/state), and creating
--- only the last segment leaves the write failing on a path that does not
--- exist. Segments are built one at a time rather than trusting the platform to
--- create parents.
--- @param path string
--- @return boolean ok
--- @return string|nil error
local function ensureDirectory(path)
    if not path or path == "" or path == "/" then return true end

    -- Desktop test runs have no filesystem library and use existing directories
    if not (fs and fs.makeDirectory) then return true end

    local absolute = path:sub(1, 1) == "/"
    local built = absolute and "" or "."

    for segment in path:gmatch("[^/\\]+") do
        built = built .. "/" .. segment

        local exists = fs.exists and fs.exists(built)
        if not exists then
            local ok, err = pcall(fs.makeDirectory, built)
            if not ok then
                return false, "creation de " .. built .. " impossible: " .. tostring(err)
            end
        end
    end

    return true
end

--- Escape a table key for use in generated Lua source
--- @param key any
--- @return string|nil rendered nil when the key cannot be persisted
local function renderKey(key)
    local kind = type(key)

    if kind == "string" then
        -- Identifiers stay bare for readability, anything else is bracketed
        if key:match("^[%a_][%w_]*$") then return key end
        return "[" .. string.format("%q", key) .. "]"
    end

    if kind == "number" and key == key and key ~= math.huge and key ~= -math.huge then
        return "[" .. tostring(key) .. "]"
    end

    return nil
end

--- Render a value as Lua source
--- Keys are sorted so two saves of the same state produce the same bytes, which
--- makes the files diffable and the tests deterministic.
--- @param value any
--- @param indent string
--- @param seen table Tables already being rendered, to break cycles
--- @return string|nil rendered
--- @return string|nil error
local function render(value, indent, seen)
    local kind = type(value)

    if kind == "nil" or kind == "boolean" then
        return tostring(value)
    end

    if kind == "number" then
        if value ~= value then return nil, "NaN n'est pas persistable" end
        if value == math.huge or value == -math.huge then
            return nil, "l'infini n'est pas persistable"
        end
        -- %.14g round-trips a double without dragging in float noise
        return string.format("%.14g", value)
    end

    if kind == "string" then
        return string.format("%q", value)
    end

    if kind ~= "table" then
        return nil, "type non persistable: " .. kind
    end

    if seen[value] then return nil, "reference circulaire" end
    seen[value] = true

    local keys = {}
    for key in pairs(value) do
        local rendered = renderKey(key)
        if rendered then
            table.insert(keys, {key = key, rendered = rendered})
        end
    end

    table.sort(keys, function(a, b)
        local ta, tb = type(a.key), type(b.key)
        if ta ~= tb then return ta < tb end
        if ta == "number" then return a.key < b.key end
        return tostring(a.key) < tostring(b.key)
    end)

    if #keys == 0 then
        seen[value] = nil
        return "{}"
    end

    -- Compact, deliberately. One line and two spaces of indentation per key
    -- read nicely on a ten-key state file and are fatal on a big one: the
    -- species cache reached 355 entries with their mutation paths, and the
    -- pretty-printed form ran the computer out of memory INSIDE table.concat --
    -- losing a sweep that had already cost three hundred component calls.
    -- These files carry "do not edit by hand" on their first line.
    local parts = {"{"}

    for _, entry in ipairs(keys) do
        local rendered, err = render(value[entry.key], indent, seen)
        if not rendered then
            seen[value] = nil
            return nil, err
        end
        table.insert(parts, entry.rendered .. "=" .. rendered .. ",")
    end

    table.insert(parts, "}")
    seen[value] = nil

    return table.concat(parts)
end

--- Serialize a table to Lua source
--- @param value table
--- @return string|nil source
--- @return string|nil error
function state.serialize(value)
    if type(value) ~= "table" then
        return nil, "seules les tables sont persistables"
    end

    local body, err = render(value, "", {})
    if not body then return nil, err end

    return "-- HiveMind state file, generated - do not edit by hand\nreturn " .. body .. "\n"
end

--- Read a table back from Lua source
--- The chunk runs in an empty environment: a corrupted file can build tables
--- and nothing else, no matter what it contains.
--- @param source string
--- @return table|nil value
--- @return string|nil error
function state.deserialize(source)
    if type(source) ~= "string" or source == "" then
        return nil, "source vide"
    end

    local chunk, err = load(source, "=state", "t", {})
    if not chunk then return nil, "source illisible: " .. tostring(err) end

    local ok, value = pcall(chunk)
    if not ok then return nil, "evaluation impossible: " .. tostring(value) end
    if type(value) ~= "table" then return nil, "le fichier ne rend pas une table" end

    return value
end

--- Write a state file atomically
--- The temporary file is renamed into place, so a crash mid-write leaves the
--- previous version intact rather than a truncated one.
--- @param path string Destination file
--- @param value table State to persist
--- @return boolean ok
--- @return string|nil error
function state.save(path, value)
    local source, err = state.serialize(value)
    if not source then return false, err end

    local made, directory_err = ensureDirectory(path:match("^(.*)[/\\][^/\\]*$"))
    if not made then return false, directory_err end

    local temporary = path .. ".tmp"
    local file, open_err = io.open(temporary, "w")
    if not file then
        return false, "ecriture impossible: " .. tostring(open_err)
            .. " (le repertoire existe-t-il ?)"
    end

    local written = file:write(source)
    file:close()

    if not written then
        removeFile(temporary)
        return false, "ecriture interrompue"
    end

    local renamed, rename_err = renameFile(temporary, path)
    if not renamed then
        removeFile(temporary)
        return false, "renommage impossible: " .. tostring(rename_err)
    end

    return true
end

--- Read a state file
--- @param path string
--- @param default table|nil Returned when the file does not exist yet
--- @return table|nil value
--- @return string|nil error nil when the default was used
function state.load(path, default)
    local file = io.open(path, "r")
    if not file then
        return default, nil
    end

    local source = file:read("*all")
    file:close()

    local value, err = state.deserialize(source)
    if not value then
        -- Never silently fall back to the default: a corrupted file is a fact
        -- the caller has to know about, not something to paper over.
        return nil, err
    end

    return value
end

--- Path of a named state file inside the state directory
--- @param name string e.g. "jobs"
--- @param directory string|nil Defaults to state.DEFAULT_DIRECTORY
--- @return string path
function state.pathFor(name, directory)
    return (directory or state.DEFAULT_DIRECTORY) .. "/" .. name .. ".lua"
end

return state
