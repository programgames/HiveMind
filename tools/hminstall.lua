-- HiveMind installer
--
-- Downloads every file the program needs, creating directories as it goes.
-- Re-run it any time to update: existing files are overwritten.
--
-- The OpenOS shell has no loops, so a dozen wget lines by hand is the
-- alternative.
--
-- Named hminstall and not install: OpenOS already ships an "install" command,
-- the one that copies OpenOS onto a hard drive. Which of the two ran would
-- depend on the PATH order, and getting that wrong is not a small mistake.
--
-- Requires an Internet Card and internet.enableHttp (on by default).
--
-- Usage:
--   hminstall                 install from the default branch
--   hminstall <branch>        install from another branch

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
    "tools/hminstall.lua",
}

--- Turn a path into an absolute one
--- The filesystem library takes absolute paths only; it is the shell that
--- resolves the working directory. Handing it "tools" silently does nothing,
--- and the write then fails on a directory that was never created.
--- @param path string
--- @return string absolute
local function absolute(path)
    if path:sub(1, 1) == "/" then return path end

    local loaded, shell = pcall(require, "shell")
    if not (loaded and type(shell) == "table") then return "/" .. path end

    if shell.resolve then
        local ok, resolved = pcall(shell.resolve, path)
        if ok and type(resolved) == "string" then return resolved end
    end

    if shell.getWorkingDirectory then
        local ok, cwd = pcall(shell.getWorkingDirectory)
        if ok and type(cwd) == "string" then
            return (cwd:gsub("/$", "")) .. "/" .. path
        end
    end

    return "/" .. path
end

--- Create a directory and its parents, tolerating those that exist
--- @param path string Directory path
--- @return boolean ok
--- @return string|nil error
local function ensureDirectory(path)
    if not path or path == "" or path == "/" then return true end

    local ok, filesystem = pcall(require, "filesystem")
    if not (ok and filesystem and filesystem.makeDirectory) then
        return true   -- desktop test runs have no filesystem library
    end

    local target = absolute(path)

    if filesystem.exists and filesystem.exists(target) then return true end

    local made, err = pcall(filesystem.makeDirectory, target)
    if not made then
        return false, "creation de " .. target .. " impossible: " .. tostring(err)
    end

    return true
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
    local made, directory_err = ensureDirectory(path:match("^(.*)/[^/]*$"))
    if not made then return false, directory_err end

    local file, err = io.open(path, "w")
    if not file then
        return false, "ouverture impossible (" .. tostring(err)
            .. ") - le repertoire existe-t-il ?"
    end

    file:write(body)
    file:close()

    return true
end

local function main(args)
    local branch = args[1] or DEFAULT_BRANCH
    local base = REPOSITORY .. branch .. "/"

    print("HiveMind - installation depuis la branche " .. branch)
    print("")

    local installed = 0
    local downloadFailures, writeFailures = {}, {}

    for _, path in ipairs(FILES) do
        io.write("  " .. path .. " ... ")

        local body, err = fetch(base .. path)

        if not body then
            print("TELECHARGEMENT ECHOUE")
            table.insert(downloadFailures, path .. " : " .. tostring(err))
        else
            local written, write_err = write(path, body)
            if written then
                installed = installed + 1
                print(#body .. " octets")
            else
                print("ECRITURE IMPOSSIBLE")
                table.insert(writeFailures, path .. " : " .. tostring(write_err))
            end
        end
    end

    print("")
    print(installed .. "/" .. #FILES .. " fichier(s) installe(s).")

    -- Two very different problems: blaming the network for a directory that
    -- could not be created sends the reader hunting in the wrong place.
    if #downloadFailures > 0 then
        print("")
        print("Telechargements echoues :")
        for _, failure in ipairs(downloadFailures) do print("  " .. failure) end
        print("Verifie la carte Internet et le nom de la branche.")
    end

    if #writeFailures > 0 then
        print("")
        print("Ecritures echouees (le reseau n'est pas en cause) :")
        for _, failure in ipairs(writeFailures) do print("  " .. failure) end
        print("Cree le repertoire a la main puis relance, par exemple :")
        print("  mkdir /home/tools")
    end

    if #downloadFailures > 0 or #writeFailures > 0 then
        return
    end

    -- OpenOS caches required modules for the whole session, so the files just
    -- written would be ignored until something drops them. hivemind does that
    -- for its own modules at startup; clearing here covers anything already
    -- loaded by another program in this session.
    local dropped = 0
    for name in pairs(package.loaded) do
        if type(name) == "string" and name:match("^lib%.") then
            package.loaded[name] = nil
            dropped = dropped + 1
        end
    end

    if dropped > 0 then
        print(dropped .. " module(s) en cache vide(s).")
    end

    print("")
    print("Lance le programme avec :  hivemind")
    print("Outils disponibles      :  calibrate, discover, upload")
    print("Mise a jour             :  hminstall")
    print("")
    print("Les fichiers sont dans le repertoire courant; lance-les depuis ici.")
end

main({...})
