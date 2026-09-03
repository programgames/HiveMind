-- HiveMind installer
--
-- Downloads every file the program needs, creating directories as it goes.
-- Re-run it any time to update: existing files are overwritten.
--
-- The OpenOS shell has no loops, so nine wget lines by hand is the alternative.
--
-- Requires an Internet Card and internet.enableHttp (on by default).
--
-- Usage:
--   install                 install from the default branch
--   install <branch>        install from another branch

local component = require("component")

local REPOSITORY = "https://raw.githubusercontent.com/programgames/HiveMind/"
local DEFAULT_BRANCH = "industrial-genetics"

local FILES = {
    "hivemind.lua",
    "lib/config.lua",
    "lib/genome.lua",
    "lib/state.lua",
    "lib/species.lua",
    "lib/jobs.lua",
    "lib/transport.lua",
    "lib/machines.lua",
    "lib/library.lua",
    "lib/breeding.lua",
    "lib/data/mutations.lua",
    "tools/calibrate.lua",
    "tools/discover.lua",
    "tools/upload.lua",
}

--- Create a directory and its parents, tolerating those that exist
--- @param path string Directory path
local function ensureDirectory(path)
    if not path or path == "" or path == "/" then return end

    local ok, filesystem = pcall(require, "filesystem")
    if ok and filesystem and filesystem.makeDirectory then
        pcall(filesystem.makeDirectory, path)
    end
end

--- Fetch one file over HTTP
--- @param url string
--- @return string|nil body
--- @return string|nil error
local function fetch(url)
    local ok, internet = pcall(require, "internet")
    if not ok then return nil, "bibliotheque internet indisponible" end

    if not component.isAvailable("internet") then
        return nil, "aucune carte Internet dans l'ordinateur"
    end

    local requested, handle = pcall(internet.request, url)
    if not requested then return nil, tostring(handle) end

    local chunks = {}
    local read_ok, read_err = pcall(function()
        for chunk in handle do table.insert(chunks, chunk) end
    end)

    if not read_ok then return nil, "lecture interrompue: " .. tostring(read_err) end

    local body = table.concat(chunks)
    if body == "" then return nil, "reponse vide" end

    -- GitHub answers 404 with an HTML page, which would otherwise be written to
    -- disk as a Lua file and fail much later with a confusing message
    if body:sub(1, 1) == "<" then
        return nil, "le serveur a repondu une page HTML (fichier absent ?)"
    end

    return body
end

--- Write a file, creating its directory
--- @param path string
--- @param body string
--- @return boolean ok
--- @return string|nil error
local function write(path, body)
    ensureDirectory(path:match("^(.*)/[^/]*$"))

    local file, err = io.open(path, "w")
    if not file then return false, tostring(err) end

    file:write(body)
    file:close()

    return true
end

local function main(args)
    local branch = args[1] or DEFAULT_BRANCH
    local base = REPOSITORY .. branch .. "/"

    print("HiveMind - installation depuis la branche " .. branch)
    print("")

    local installed, failures = 0, {}

    for _, path in ipairs(FILES) do
        io.write("  " .. path .. " ... ")

        local body, err = fetch(base .. path)

        if not body then
            print("ECHEC")
            table.insert(failures, path .. " : " .. tostring(err))
        else
            local written, write_err = write(path, body)
            if written then
                installed = installed + 1
                print(#body .. " octets")
            else
                print("ECRITURE IMPOSSIBLE")
                table.insert(failures, path .. " : " .. tostring(write_err))
            end
        end
    end

    print("")
    print(installed .. "/" .. #FILES .. " fichier(s) installe(s).")

    if #failures > 0 then
        print("")
        print("Echecs :")
        for _, failure in ipairs(failures) do print("  " .. failure) end
        print("")
        print("Verifie la carte Internet et le nom de la branche.")
        return
    end

    print("")
    print("Lance le programme avec :  hivemind")
    print("Outils disponibles      :  calibrate, discover, upload")
end

main({...})
