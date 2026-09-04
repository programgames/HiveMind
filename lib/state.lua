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

--- Emit a value as Lua source, one fragment at a time
--- It does NOT build the result. Returning a string per node kept every
--- fragment of the tree alive at once, and the final table.concat then had to
--- allocate the whole file on top of them: the species cache reached 355
--- entries with their mutation paths and ran the computer out of memory,
--- losing a sweep that had already cost three hundred component calls.
--- Handing fragments to a sink lets the caller flush them to disk as they come,
--- so the cost stops depending on how big the state is.
---
--- The output is compact -- no indentation, no line breaks. Those read nicely
--- on a ten-key state file and cost half the bytes on this one, and these files
--- carry "do not edit by hand" on their first line.
---
--- Keys are sorted so two saves of the same state produce the same bytes, which
--- makes the files diffable and the tests deterministic.
--- @param value any
--- @param seen table Tables already being emitted, to break cycles
--- @param write function(text) Receives each fragment in order
--- @return boolean ok
--- @return string|nil error
local function emit(value, seen, write)
    local kind = type(value)

    if kind == "nil" or kind == "boolean" then
        write(tostring(value))
        return true
    end

    if kind == "number" then
        if value ~= value then return false, "NaN n'est pas persistable" end
        if value == math.huge or value == -math.huge then
            return false, "l'infini n'est pas persistable"
        end
        -- %.14g round-trips a double without dragging in float noise
        write(string.format("%.14g", value))
        return true
    end

    if kind == "string" then
        write(string.format("%q", value))
        return true
    end

    if kind ~= "table" then
        return false, "type non persistable: " .. kind
    end

    if seen[value] then return false, "reference circulaire" end
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

    write("{")

    for _, entry in ipairs(keys) do
        write(entry.rendered)
        write("=")

        local ok, err = emit(value[entry.key], seen, write)
        if not ok then
            seen[value] = nil
            return false, err
        end

        write(",")
    end

    write("}")
    seen[value] = nil

    return true
end

local HEADER = "-- HiveMind state file, generated - do not edit by hand\nreturn "

--- Serialize a table to Lua source, in memory
--- Convenient, and the wrong tool above a few kilobytes: it holds the whole
--- file at once. state.save streams instead, and nothing on the hot path
--- should call this.
--- @param value table
--- @return string|nil source
--- @return string|nil error
function state.serialize(value)
    if type(value) ~= "table" then
        return nil, "seules les tables sont persistables"
    end

    local parts = {}
    local ok, err = emit(value, {}, function(text)
        table.insert(parts, text)
    end)

    if not ok then return nil, err end

    return HEADER .. table.concat(parts) .. "\n"
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
    if type(value) ~= "table" then
        return false, "seules les tables sont persistables"
    end

    local made, directory_err = ensureDirectory(path:match("^(.*)[/\\][^/\\]*$"))
    if not made then return false, directory_err end

    local temporary = path .. ".tmp"
    local file, open_err = io.open(temporary, "w")
    if not file then
        return false, "ecriture impossible: " .. tostring(open_err)
            .. " (le repertoire existe-t-il ?)"
    end

    -- Written as it is produced, in blocks. Building the file first cost as
    -- much memory as the file plus every fragment that made it, which is what
    -- killed a 355-species sweep. Four kilobytes is the whole footprint now,
    -- whatever the state weighs.
    local buffer, pending, written, blocks = {}, 0, true, 0

    local function flush()
        if pending == 0 then return end
        if written then written = file:write(table.concat(buffer)) end
        buffer, pending = {}, 0
        blocks = blocks + 1

        -- The fragments just written are garbage, and so is every sorted key
        -- list built to produce them. On a computer with two megabytes it is
        -- not enough for them to be collectable: they have to be COLLECTED --
        -- measured, an incremental step does not keep up and the garbage still
        -- grows to the size of the file. A real sweep every eight blocks bounds
        -- it to about thirty kilobytes whatever the state weighs.
        --
        -- Guarded: the OpenComputers sandbox does not promise every option, and
        -- a save must never die because a hint was refused.
        if blocks % 8 == 0 then pcall(collectgarbage) end
    end

    local function put(text)
        table.insert(buffer, text)
        pending = pending + #text
        if pending >= 4096 then flush() end
    end

    put(HEADER)

    local ok, emit_err = emit(value, {}, put)

    if ok then
        put("\n")
        flush()
    end

    file:close()

    if not ok then
        -- The temporary file holds half a state; the previous one is intact
        removeFile(temporary)
        return false, emit_err
    end

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
