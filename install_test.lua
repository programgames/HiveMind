-- Harness for tools/hminstall.lua: no network, no writes outside memory.

local requested, written = {}, {}
local mode = "ok"

package.loaded["component"] = {
    isAvailable = function(kind) return mode ~= "no_card" and kind == "internet" end,
}

package.loaded["internet"] = {
    request = function(url)
        table.insert(requested, url)

        if mode == "html" then
            local done = false
            return function()
                if done then return nil end
                done = true
                return "<!DOCTYPE html><html>404</html>"
            end
        end

        if mode == "empty" then
            return function() return nil end
        end

        -- The installer re-executes the copy it just downloaded, so that copy
        -- has to be the real thing or the second pass runs a comment and the
        -- recursion guard is never exercised.
        local body = "-- contenu de " .. url
        if url:find("tools/hminstall.lua", 1, true) then
            local real = io.open("tools/hminstall.lua", "r")
            if real then
                body = real:read("*all")
                real:close()
            end
        end

        local done = false
        return function()
            if done then return nil end
            done = true
            return body
        end
    end,
}

-- The filesystem library only accepts absolute paths; the shell is what
-- resolves the working directory. Refusing a relative one here reproduces the
-- failure seen in game, where lib/ worked only because it existed already.
local existing = {}

local removed = {}

package.loaded["filesystem"] = {
    remove = function(path) table.insert(removed, path) return true end,
    exists = function(path) return existing[path] == true end,
    makeDirectory = function(path)
        if path:sub(1, 1) ~= "/" then
            error("chemin relatif refuse: " .. path)
        end
        existing[path] = true
        table.insert(written, "dir:" .. path)
        return true
    end,
}

package.loaded["shell"] = {
    resolve = function(path)
        if path:sub(1, 1) == "/" then return path end
        return "/home/" .. path
    end,
    getWorkingDirectory = function() return "/home" end,
}

local real_open, real_print = io.open, print
local out = {}

-- What a write actually put on disk, so a read-back can be answered. The
-- installer verifies its own writes now: hivemind.lua kept updating while
-- lib/genetics.lua stayed behind, and a write that silently does nothing looks
-- exactly like one that worked.
local contents = {}

local function capture()
    io.open = function(path, m)
        if m == "w" then
            return {
                write = function(_, body)
                    table.insert(written, path .. "=" .. #body)
                    contents[path] = body
                end,
                close = function() end,
            }
        end

        if contents[path] then
            local body = contents[path]
            return {read = function() return body end, close = function() end}
        end

        return real_open(path, m)
    end
    io.write = function() end
    print = function(...)
        local parts = {}
        for i = 1, select("#", ...) do parts[i] = tostring((select(i, ...))) end
        table.insert(out, table.concat(parts, "\t"))
    end
end

local function release()
    io.open, print = real_open, real_print
end

local failed = false
local function check(label, condition)
    real_print((condition and "  OK     " or "  ECHEC  ") .. label)
    if not condition then failed = true end
end

-- OpenOS keeps required modules for the whole shell session, so files just
-- written are ignored until something drops them. Leaving "hivemind" cached is
-- how a tool once reported version 0.14.1 with 0.17.0 on disk.
package.loaded["hivemind"] = {stale = true}
package.loaded["lib.multiply"] = {stale = true}

-- Nominal install
capture()
local ok = pcall(assert(loadfile("tools/hminstall.lua")))
release()

check("hivemind est vide du cache", package.loaded["hivemind"] == nil)
check("les modules lib sont vides du cache",
      package.loaded["lib.multiply"] == nil)

check("installation sans exception", ok)

local text = table.concat(out, "\n")
-- Counting the entries rather than hardcoding a total: the number changes
-- every time a module is added, and a test that fails for that reason teaches
-- nothing.
local installerSource = real_open("tools/hminstall.lua"):read("*all")
-- Four spaces then a quoted path: that is a FILES entry, and nothing else in
-- the installer is written that way.
local declared = select(2, installerSource:gsub('    "[^"]+%.lua",', ""))

check("la liste de fichiers n'est pas vide", declared > 0)
check("tous les fichiers declares sont installes",
      text:find(declared .. "/" .. declared, 1, true) ~= nil)

-- Every module hivemind requires must be in the installer's list, or the
-- program dies on a require with an empty message
local sources = io.open("hivemind.lua"):read("*all")
local requiredModules = {}
for name in sources:gmatch('need%("(lib%.[%w_]+)"%)') do
    table.insert(requiredModules, (name:gsub("%.", "/")) .. ".lua")
end

local listed = table.concat(requested, " ")
local allListed = #requiredModules > 0
for _, module in ipairs(requiredModules) do
    if not listed:find(module, 1, true) then
        real_print("    absent de l'installeur : " .. module)
        allListed = false
    end
end
check("tous les modules requis sont telecharges", allListed)

check("branche par defaut utilisee", requested[1]:find("industrial-genetics", 1, true) ~= nil)


-- GitHub's raw CDN kept serving a stale copy for minutes after a push, which
-- once produced an install mixing a fresh tool with a three-versions-old
-- program. A query the cache has never seen forces a real fetch.
local busted, distinct, seen = true, true, {}
for _, url in ipairs(requested) do
    local token = url:match("nocache=([^&]+)$")
    if not token then busted = false end
    if token then
        if seen[token] then distinct = false end
        seen[token] = true
    end
end

check("chaque telechargement contourne le cache", busted)
check("aucun jeton de cache reutilise", distinct)
check("hivemind telecharge", requested[1]:find("hivemind.lua", 1, true) ~= nil)

local writes = table.concat(written, " ")
-- Directories must be created with absolute paths, which is what failed in game
check("repertoire lib cree en absolu", writes:find("dir:/home/lib ", 1, true) ~= nil)
check("repertoire lib/data cree en absolu", writes:find("dir:/home/lib/data", 1, true) ~= nil)
check("repertoire tools cree en absolu", writes:find("dir:/home/tools", 1, true) ~= nil)
check("mutations ecrite", writes:find("lib/data/mutations.lua=", 1, true) ~= nil)
check("calibrate ecrit", writes:find("tools/calibrate.lua=", 1, true) ~= nil)
-- The running copy lives where it was first fetched, not in tools/. Without a
-- self-update it reports an old file count forever and omits new modules.
check("l'installeur se met a jour lui-meme",
      writes:find("tools/hminstall.lua=", 1, true) ~= nil)

-- Three runs in a row behaved like an older version, with no way to tell a
-- stale file from a stale module cache. A file that cannot survive the install
-- cannot be stale.
requested, written, out, removed = {}, {}, {}, {}
capture()
pcall(assert(loadfile("tools/hminstall.lua")), "--clean")
release()

check("--clean efface avant d'ecrire", #removed > 0)
check("il efface autant de fichiers qu'il en installe", #removed == declared)
check("et il installe quand meme tout",
      table.concat(out, " "):find(declared .. "/" .. declared, 1, true) ~= nil)

-- Without it nothing is deleted: a normal run must stay a plain overwrite
requested, written, out, removed = {}, {}, {}, {}
capture()
pcall(assert(loadfile("tools/hminstall.lua")))
release()
check("sans --clean rien n'est efface", #removed == 0)

-- Run from where the user actually launches it, not from tools/. That copy is
-- the one that never updated itself, so it kept reporting an old file count and
-- silently omitting newly added modules.
--
-- Both chunk-name prefixes are exercised on purpose. OpenOS loads programs with
-- load(..., "=" .. path) while desktop loadfile uses "@", and testing only "@"
-- is exactly how the broken self-update passed for weeks.
local body = real_open("tools/hminstall.lua"):read("*all")

for _, prefix in ipairs({"=", "@"}) do
    requested, written, out = {}, {}, {}
    for path in pairs(contents) do contents[path] = nil end
    local elsewhere = assert(load(body, prefix .. "/home/hminstall.lua"))

    capture()
    pcall(elsewhere)
    release()
    text = table.concat(out, "\n")

    check("la copie lancee est reecrite (prefixe " .. prefix .. ")",
          table.concat(written, " "):find("/home/hminstall.lua=", 1, true) ~= nil)

    -- The old list has just been applied and the new one may name modules this
    -- pass never fetched: that is how a fresh hivemind met a lib/ module that
    -- did not exist. It runs the second pass itself instead of asking.
    check("une seconde passe est enchainee (prefixe " .. prefix .. ")",
          text:find("nouvelle passe avec sa liste", 1, true) ~= nil)
    check("et l'operateur n'a rien a relancer (prefixe " .. prefix .. ")",
          text:find("Relance 'hminstall' une fois", 1, true) == nil)

    -- Twice, not forever: the second pass must not chain a third
    local passes = select(2, text:gsub("HiveMind %- installation depuis", ""))
    check("exactement deux passes (prefixe " .. prefix .. ")", passes == 2, passes)
end

-- Launched from tools/ itself, the download already wrote the file: rewriting it
-- and demanding a re-run would loop forever.
requested, written, out = {}, {}, {}

-- An out-of-date launcher copy sitting next to hivemind: exactly the drift that
-- had "hminstall" and "tools/hminstall" installing different file lists
for path in pairs(contents) do contents[path] = nil end
contents["/home/hminstall.lua"] = "-- une vieille copie"

capture()
pcall(assert(load(body, "=/home/tools/hminstall.lua")))
release()
check("pas de relance quand il tourne depuis tools/",
      table.concat(out, "\n"):find("Relance 'hminstall'", 1, true) == nil)

-- They drifted: /home/hminstall.lua sat at a seventeen-file list while tools/
-- had twenty, so the two commands installed different things and
-- lib/genetics.lua was in only one of them
check("la copie de lancement est remise a niveau",
      table.concat(written, " "):find("/home/hminstall.lua=", 1, true) ~= nil)

-- An option an older copy does not know is not a branch name. Passing
-- "--clean" to one made it fetch a branch of that name: seventeen failed
-- downloads that looked like a network problem.
requested, written, out = {}, {}, {}
for path in pairs(contents) do contents[path] = nil end
capture()
pcall(assert(loadfile("tools/hminstall.lua")), "--inconnue")
release()

check("une option inconnue n'est pas prise pour une branche",
      table.concat(out, " "):find("Option inconnue", 1, true) ~= nil)
check("et rien n'est telecharge", #requested == 0)
check("elle renvoie vers la copie fraiche",
      table.concat(out, " "):find("tools/hminstall", 1, true) ~= nil)


-- The command has to carry the tools/ prefix: that directory is not on the
-- OpenOS PATH, so a bare name answers "file not found".
requested, written, out = {}, {}, {}
capture()
pcall(assert(loadfile("tools/hminstall.lua")))
release()
check("la commande du rapport est lancable telle quelle",
      table.concat(out, "\n"):find("tools/autoreport --run --upload", 1, true) ~= nil)

-- Another branch
requested, written, out = {}, {}, {}
capture()
pcall(assert(loadfile("tools/hminstall.lua")), "main")
release()
check("branche personnalisee respectee",
      requested[1]:find("/HiveMind/main/", 1, true) ~= nil)

-- GitHub answers 404 with HTML; writing that as a .lua file would fail much later
requested, written, out = {}, {}, {}
mode = "html"
capture()
pcall(assert(loadfile("tools/hminstall.lua")))
release()
text = table.concat(out, "\n")
check("page HTML refusee", text:find("HTML", 1, true) ~= nil)
check("rien n'est ecrit", #written == 0 or table.concat(written, " "):find("=") == nil)
check("zero fichier installe", text:find("0/" .. declared, 1, true) ~= nil)

-- No internet card
requested, written, out = {}, {}, {}
mode = "no_card"
capture()
local degraded = pcall(assert(loadfile("tools/hminstall.lua")))
release()
text = table.concat(out, "\n")
check("absence de carte geree sans exception", degraded)
check("carte Internet signalee", text:find("carte Internet", 1, true) ~= nil)

-- A write failure must not be reported as a network problem
requested, written, out = {}, {}, {}
mode = "ok"
existing = {}
package.loaded["filesystem"] = {
    exists = function() return false end,
    makeDirectory = function() error("disque plein") end,
}
capture()
local write_fail = pcall(assert(loadfile("tools/hminstall.lua")))
release()
text = table.concat(out, "\n")

check("echec d'ecriture gere sans exception", write_fail)
check("les ecritures echouees sont distinguees",
      text:find("Ecritures echouees", 1, true) ~= nil)
check("le reseau est explicitement disculpe",
      text:find("le reseau n'est pas en cause", 1, true) ~= nil)
check("aucune accusation de carte Internet",
      text:find("Verifie la carte Internet", 1, true) == nil)
check("une solution concrete est donnee", text:find("mkdir /home/", 1, true) ~= nil)

-- A write that silently does nothing looks exactly like one that worked, and
-- that is how lib/genetics.lua stayed at an older revision while every other
-- file updated around it.
requested, written, out = {}, {}, {}
for path in pairs(contents) do contents[path] = nil end

-- The disk-full case above left a filesystem that refuses every directory, and
-- with it every write fails long before the read-back is reached
package.loaded["filesystem"] = {
    remove = function() return true end,
    exists = function() return true end,
    makeDirectory = function() return true end,
}

local real_capture = capture
capture = function()
    real_capture()
    local honest = io.open
    io.open = function(path, m)
        -- One file that accepts the write and keeps nothing
        if m == "w" and path:find("genetics", 1, true) then
            return {write = function() end, close = function() end}
        end
        return honest(path, m)
    end
end

capture()
pcall(assert(loadfile("tools/hminstall.lua")))
release()
capture = real_capture

text = table.concat(out, " ")
check("une ecriture sans effet est detectee",
      text:find("octets, relu", 1, true) ~= nil)
check("et comptee comme un echec d'ecriture",
      text:find("Ecritures echouees", 1, true) ~= nil)

os.exit(failed and 1 or 0)
