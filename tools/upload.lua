-- HiveMind upload tool
--
-- Sends a local file to a public paste service over HTTP POST and prints the
-- resulting URL. Written for shipping diagnostic reports off the machine
-- without digging through the world save folder.
--
-- WARNING: this PUBLISHES the file. Anyone holding the URL can read it, and
-- paste services routinely cache or index content even after deletion. Use it
-- for diagnostics you are comfortable making public, never for anything else.
-- The tool always asks for confirmation before sending.
--
-- Requires an Internet Card, and HTTP enabled in the OpenComputers config
-- (internet.enableHttp, on by default).
--
-- Usage:
--   upload                       send /home/hivemind-calibration.txt
--   upload /path/to/file.txt     send another file
--   upload file.txt --yes        skip the confirmation prompt

local component = require("component")

local DEFAULT_FILE = "/home/hivemind-calibration.txt"
local ENDPOINT = "https://paste.rs/"
local MAX_BYTES = 512 * 1024      -- paste services reject large bodies
local PREVIEW_LINES = 3

--- Read a whole file into memory
--- @param path string File to read
--- @return string|nil content
--- @return string|nil error
local function readFile(path)
    local file, err = io.open(path, "r")
    if not file then return nil, tostring(err) end

    local content = file:read("*all")
    file:close()

    if not content or content == "" then
        return nil, "le fichier est vide"
    end

    return content
end

--- Ask the user to confirm the upload
--- @param path string File about to be sent
--- @param size number Size in bytes
--- @return boolean confirmed
local function confirm(path, size)
    print("")
    print("A ENVOYER : " .. path .. "  (" .. size .. " octets)")
    print("VERS      : " .. ENDPOINT)
    print("")
    print("Ce contenu deviendra PUBLIC: quiconque a l'URL pourra le lire,")
    print("et le service peut le conserver meme apres suppression.")
    print("")
    io.write("Confirmer l'envoi ? (o/N) ")

    local answer = io.read()
    if not answer then return false end

    answer = answer:lower()
    return answer == "o" or answer == "oui" or answer == "y" or answer == "yes"
end

--- POST a body and collect the whole response
--- @param body string Raw request body
--- @return string|nil response
--- @return string|nil error
local function post(body)
    -- Required lazily: on a machine without an Internet Card the library errors
    local ok, internet = pcall(require, "internet")
    if not ok then
        return nil, "bibliotheque internet indisponible"
    end

    if not component.isAvailable("internet") then
        return nil, "aucune carte Internet dans l'ordinateur"
    end

    local requested, result = pcall(internet.request, ENDPOINT, body,
        {["Content-Type"] = "text/plain"}, "POST")

    if not requested then
        return nil, "requete refusee: " .. tostring(result)
    end

    -- The handle is an iterator; reading it can fail mid-stream
    local chunks = {}
    local read_ok, read_err = pcall(function()
        for chunk in result do
            table.insert(chunks, chunk)
        end
    end)

    if not read_ok then
        return nil, "lecture de la reponse interrompue: " .. tostring(read_err)
    end

    local response = table.concat(chunks)
    if response == "" then
        return nil, "reponse vide du serveur"
    end

    return response
end

local function main(args)
    local path = nil
    local skip_confirm = false

    for _, arg in ipairs(args) do
        if arg == "--yes" or arg == "-y" then
            skip_confirm = true
        elseif not path then
            path = arg
        end
    end

    path = path or DEFAULT_FILE

    local content, err = readFile(path)
    if not content then
        print("Lecture impossible: " .. err)
        return
    end

    if #content > MAX_BYTES then
        print("Fichier trop gros: " .. #content .. " octets (maximum "
            .. MAX_BYTES .. ").")
        return
    end

    -- Show what is about to leave the machine
    print("Debut du fichier:")
    local shown = 0
    for line in (content .. "\n"):gmatch("(.-)\n") do
        if shown >= PREVIEW_LINES then break end
        print("  | " .. line)
        shown = shown + 1
    end

    if not skip_confirm and not confirm(path, #content) then
        print("Envoi annule. Rien n'a quitte la machine.")
        return
    end

    print("Envoi en cours...")

    local response, post_err = post(content)
    if not response then
        print("ECHEC: " .. post_err)
        print("")
        print("Si c'est un probleme de carte ou de config, le fichier reste")
        print("recuperable dans saves/<monde>/opencomputers/<uuid>" .. path)
        return
    end

    -- paste.rs answers with the bare URL
    local url = response:match("(https?://%S+)") or response

    print("")
    print("=====================================")
    print("  " .. url)
    print("=====================================")
end

main({...})
