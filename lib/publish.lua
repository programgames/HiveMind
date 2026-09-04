--- Getting a report off the machine
---
--- Three tools needed this and each had its own copy, each subtly broken in a
--- different way. What they all missed:
---
---   * internet.request() only CREATES the request. Nothing is sent until the
---     handle is read, so "it did not throw" means nothing at all.
---   * A request that completes can still have failed. The fixed mailbox
---     answered 429 -- quota exhausted -- for a whole evening while every tool
---     printed "depose dans la boite aux lettres".
---
--- So: read the handle, read the STATUS, and when the mailbox refuses, fall
--- back to a paste service and print the URL. A report that needs relaying by
--- hand is worse than one that arrives on its own, and far better than one that
--- silently evaporates.

local publish = {}

publish.PASTE = "https://paste.rs/"

--- POST a body and wait for the real answer
--- @param url string
--- @param body string
--- @return boolean ok True only on a 2xx answer
--- @return string detail Response body, or the reason it failed
--- @return number|nil status HTTP status when one came back
function publish.post(url, body)
    local net_ok, internet = pcall(require, "internet")
    if not net_ok then return false, "bibliotheque internet absente" end

    local requested, handle = pcall(internet.request, url, body,
        {["Content-Type"] = "text/plain"}, "POST")

    if not requested then return false, tostring(handle) end

    -- Reading is what actually sends it
    local chunks = {}
    local read_ok, reason = pcall(function()
        for chunk in handle do table.insert(chunks, chunk) end
    end)

    if not read_ok then return false, "reponse illisible: " .. tostring(reason) end

    local answer = table.concat(chunks)

    -- response() exists on the OpenOS handle and is the only way to tell a
    -- delivery from a refusal. Older builds may not have it, in which case a
    -- completed read is the best evidence available.
    local status
    local has_status, code = pcall(function()
        if handle.response then return (handle.response()) end
        return nil
    end)

    if has_status then status = tonumber(code) end

    if status and (status < 200 or status >= 300) then
        local why = "HTTP " .. status
        if status == 429 then
            why = why .. " (quota epuise: cette boite aux lettres est pleine,"
                .. " genere une nouvelle adresse sur webhook.site et remplace"
                .. " config.report_mailbox)"
        end
        return false, why, status
    end

    return true, answer, status
end

--- Send a report to the mailbox, and to a paste service if that fails
--- @param body string
--- @param mailbox string|nil Fixed address, nil to skip straight to the paste
--- @param say function|nil Where to print progress, defaults to print
--- @return boolean delivered
function publish.report(body, mailbox, say)
    say = say or print

    if mailbox then
        local ok, detail = publish.post(mailbox, body)
        if ok then
            say("Rapport depose dans la boite aux lettres.")
            return true
        end

        say("Boite aux lettres injoignable: " .. tostring(detail))
        say("Repli sur un service de collage.")
    end

    local ok, answer = publish.post(publish.PASTE, body)

    if not ok or answer == "" then
        say("Publication impossible: " .. tostring(answer))
        return false
    end

    say("")
    say("=====================================")
    say("  " .. (answer:match("(https?://%S+)") or answer))
    say("=====================================")
    say("Colle cette adresse dans la conversation.")

    return true
end

return publish
