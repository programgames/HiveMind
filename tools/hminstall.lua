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
--   hminstall --clean         delete each file before writing it

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
    "lib/multiply.lua",
    "lib/genetics.lua",
    "lib/planner.lua",
    "lib/data/mutations.lua",
    "tools/calibrate.lua",
    "tools/discover.lua",
    "tools/probe.lua",
    "tools/upload.lua",
    "tools/autoreport.lua",
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
--- A value that differs on every run, to defeat the CDN cache
--- GitHub serves raw files through a cache that keeps handing out the previous
--- version for minutes after a push, per file and with independent expiry. That
--- produced an install mixing a fresh tool with a three-versions-old program,
--- which then failed in ways that had nothing to do with the actual code. A
--- query string the cache has never seen forces a fresh fetch.
--- @return string
local counter = 0
local function cacheBuster()
    counter = counter + 1

    local seconds = 0
    local ok, computer = pcall(require, "computer")
    if ok and computer and computer.uptime then
        seconds = math.floor((tonumber(computer.uptime()) or 0) * 1000)
    end

    return tostring(os.time()) .. "-" .. tostring(seconds) .. "-" .. counter
end

local function fetch(url)
    local ok, internet = pcall(require, "internet")
    if not ok then return nil, "bibliotheque internet indisponible" end

    if not component.isAvailable("internet") then
        return nil, "aucune carte Internet dans l'ordinateur"
    end

    local requested, handle = pcall(internet.request,
        url .. "?nocache=" .. cacheBuster())
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
--- Remove a file, tolerating one that is not there
--- @param path string
local function remove(path)
    local ok, filesystem = pcall(require, "filesystem")
    if not (ok and filesystem and filesystem.remove) then return end
    pcall(filesystem.remove, absolute(path))
end

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

    -- Read it back. hivemind.lua and autoreport.lua were updating while
    -- lib/genetics.lua stayed at an older revision, and a write that silently
    -- does nothing is indistinguishable from one that worked.
    local check = io.open(path, "r")
    if not check then
        return false, "ecrit puis introuvable"
    end

    local written = check:read("*all") or ""
    check:close()

    if #written ~= #body then
        return false, string.format("ecrit %d octets, relu %d", #body, #written)
    end

    return true
end

local function main(args)
    -- Set when this pass is the automatic second one, so it cannot recurse
    local again = false
    local positional = {}

    -- Deletes each target before writing it. Three runs in a row behaved like
    -- an older version with no way to tell a stale file from a stale cache, and
    -- a file that cannot survive cannot be stale.
    local clean = false

    for _, arg in ipairs(args) do
        if arg == "--again" then again = true
        elseif arg == "--clean" then clean = true
        else table.insert(positional, arg) end
    end

    -- An option this version does not know is not a branch name. Passing
    -- "--clean" to an older copy made it fetch a branch of that name: seventeen
    -- failed downloads and a listing that looked like a network problem.
    local branch = positional[1]

    if branch and branch:sub(1, 2) == "--" then
        print("Option inconnue de cette version : " .. branch)
        print("Ta copie de hminstall est plus ancienne que le depot.")
        print("Lance 'tools/hminstall' : c'est celle qui vient d'etre telechargee.")
        return
    end

    branch = branch or DEFAULT_BRANCH
    local base = REPOSITORY .. branch .. "/"

    print("HiveMind - installation depuis la branche " .. branch)
    print("")

    local installed = 0
    local downloadFailures, writeFailures = {}, {}
    local ownBody = nil

    for _, path in ipairs(FILES) do
        io.write("  " .. path .. " ... ")

        if clean then remove(path) end

        local body, err = fetch(base .. path)

        if not body then
            print("TELECHARGEMENT ECHOUE")
            table.insert(downloadFailures, path .. " : " .. tostring(err))
        else
            if path == "tools/hminstall.lua" then ownBody = body end

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

    -- The copy being run sits where it was first fetched, usually next to
    -- hivemind, while the download goes to tools/. Without this the running
    -- installer never updates itself: it reports an old file count forever and
    -- silently omits newly added modules.
    if ownBody then
        -- OpenOS loads programs with load(..., "=" .. path), so the source
        -- carries a "=" prefix and not the "@" that loadfile uses on a desktop
        -- Lua. Matching only "@" left `running` nil and silently skipped every
        -- self-update: the installer kept announcing an old file count and
        -- omitting newly added modules, run after run.
        local source = debug.getinfo(1, "S").source or ""
        local running = source:match("^[@=](.*)$")

        local updatedItself, updateError = false, nil

        -- Keep the launcher copy in step with the downloaded one. They drifted:
        -- /home/hminstall.lua sat at a seventeen-file list while tools/ had
        -- twenty, so "hminstall" and "tools/hminstall" installed different
        -- things and lib/genetics.lua was in only one of them.
        local launcher = absolute("hminstall.lua")
        if running and absolute(running) == absolute("tools/hminstall.lua") then
            local existing_copy = io.open(launcher, "r")
            local existing_body = existing_copy and existing_copy:read("*all") or nil
            if existing_copy then existing_copy:close() end

            if existing_body and existing_body ~= ownBody then
                local synced = write(launcher, ownBody)
                if synced then
                    print("")
                    print("Copie de lancement remise a niveau : " .. launcher)
                end
            end
        end

        if running and absolute(running) ~= absolute("tools/hminstall.lua") then
            local current = io.open(running, "r")
            local body = current and current:read("*all") or nil
            if current then current:close() end

            if body ~= ownBody then
                local ok, err = write(running, ownBody)
                updatedItself = ok
                if not ok then updateError = err end
            end
        end

        if updatedItself and not again then
            -- The old list has just been applied, and the new one may name
            -- modules this pass never fetched: that is how a fresh hivemind met
            -- a lib/ module that did not exist yet. Asking the operator to run
            -- the same command twice was a ritual, not an explanation.
            print("")
            print("L'installeur s'est mis a jour; nouvelle passe avec sa liste...")
            print("")

            local chunk = load(ownBody, "=" .. tostring(running))
            if chunk then
                local ok, err = pcall(chunk, branch, "--again")
                if ok then return end
                print("Seconde passe impossible: " .. tostring(err))
                print("Relance 'hminstall' a la main.")
                return
            end

            print("Relance 'hminstall' une fois: la liste de fichiers a change.")
        elseif updatedItself then
            print("")
            print("L'installeur s'est mis a jour lui-meme.")
        elseif updateError then
            -- Staying silent here is how the previous failure hid for so long
            print("")
            print("L'installeur n'a PAS pu se mettre a jour : " .. tostring(updateError))
            print("Copie-le a la main :  cp tools/hminstall.lua " .. tostring(running))
        end
    end

    -- A directory named like the program shadows it: typing "hivemind" then
    -- answers "is a directory". An old state directory left over from before
    -- the rename does exactly that.
    local ok, filesystem = pcall(require, "filesystem")
    if ok and filesystem and filesystem.isDirectory then
        for _, stray in ipairs({"/home/hivemind", "hivemind"}) do
            local resolved = absolute(stray)
            if filesystem.isDirectory(resolved) then
                print("")
                print("ATTENTION: " .. resolved .. " est un repertoire et masque le")
                print("programme du meme nom. Supprime-le :  rm -r " .. resolved)
            end
        end
    end

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
        if type(name) == "string"
           and (name == "hivemind" or name:match("^lib%.")) then
            package.loaded[name] = nil
            dropped = dropped + 1
        end
    end

    if dropped > 0 then
        print(dropped .. " module(s) en cache vide(s).")
    end

    -- GitHub serves raw files through a CDN that can hand out the previous
    -- version for a few minutes after a push. Showing what was actually
    -- downloaded turns "did my update land?" into a glance.
    local downloaded = io.open("hivemind.lua", "r")
    if downloaded then
        local body = downloaded:read("*all")
        downloaded:close()

        local version = body:match('VERSION%s*=%s*"([^"]+)"')
        print("")
        print("Version installee : " .. (version or "inconnue"))
        print("Si elle n'a pas change alors qu'elle devrait, le CDN de GitHub")
        print("sert encore l'ancienne: attends une minute et relance hminstall.")
    end

    -- The tools land in tools/, which is not on the OpenOS PATH. Naming them
    -- bare invited "autoreport: file not found"; the path is part of the
    -- command, so it belongs in the command shown.
    print("")
    print("Lance le programme avec :  hivemind")
    print("Rapport automatique     :  tools/autoreport --run --upload")
    print("Tout en une commande    :  tools/autoreport --secure --run --upload")
    print("Sondage des slots       :  tools/probe --yes --upload")
    print("Autres outils           :  tools/calibrate, tools/discover, tools/upload")
    print("Mise a jour             :  hminstall")
    print("Reinstallation propre   :  hminstall --clean")
    print("")
    print("Les fichiers sont dans le repertoire courant; lance-les depuis ici.")
end

main({...})
