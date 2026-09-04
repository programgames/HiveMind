-- HiveMind publishing tests
--
-- Two failures hid here for an evening, and both looked like success:
--   * internet.request() only creates the request; nothing is sent until the
--     handle is read, so "it did not throw" proved nothing.
--   * A completed request can still have failed. The mailbox answered 429 --
--     free quota exhausted -- while every tool printed "depose".

package.path = package.path .. ";./?.lua"

local publish = require("lib.publish")

local passed, failed = 0, 0

local function check(description, condition)
    if condition then
        passed = passed + 1
        print("  OK   " .. description)
    else
        failed = failed + 1
        print("  FAIL " .. description)
    end
end

-- A fake OpenOS internet library, installed into package.loaded
local world

local function fakeInternet()
    return {
        request = function(url, body)
            world.calls = world.calls + 1
            world.lastUrl = url
            world.lastBody = body

            if world.throwOnRequest then error("pas de carte") end

            local drained = false

            -- The handle is an iterator. Reading it is what sends the request,
            -- which is exactly the step the old code skipped.
            local handle = {
                response = function()
                    -- Per URL, because the interesting case is a mailbox that
                    -- refuses while the paste service accepts
                    return world.statusFor[url] or world.status, "", {}
                end,
            }

            return setmetatable(handle, {__call = function()
                if drained then return nil end
                drained = true
                world.read = true
                return world.answer
            end})
        end,
    }
end

local function reset(options)
    options = options or {}
    world = {
        calls = 0, read = false,
        status = options.status or 200,
        statusFor = options.statusFor or {},
        answer = options.answer or "https://paste.rs/abc",
        throwOnRequest = options.throwOnRequest or false,
    }
    package.loaded["internet"] = fakeInternet()
end

print("=== Publishing tests ===")
print("")

reset()
local ok, answer, status = publish.post("https://example.invalid/", "corps")
check("un 200 est un succes", ok == true)
check("la reponse est rendue", answer == "https://paste.rs/abc")
check("le statut est rendu", status == 200)
check("le handle a ete lu, donc la requete est partie", world.read == true)
check("le corps est bien celui qu on a passe", world.lastBody == "corps")

-- The whole point: a request that completes can still have failed
reset({status = 429})
ok, answer = publish.post("https://example.invalid/", "corps")
check("un 429 est un echec, pas un succes", ok == false)
check("et il explique que la boite est pleine",
      tostring(answer):find("quota epuise", 1, true) ~= nil)

reset({status = 500})
ok, answer = publish.post("https://example.invalid/", "corps")
check("un 500 est un echec", ok == false)
check("avec le code dans le message",
      tostring(answer):find("HTTP 500", 1, true) ~= nil)

reset({throwOnRequest = true})
ok = publish.post("https://example.invalid/", "corps")
check("une requete impossible est un echec", ok == false)

-- A dead mailbox must not cost the report: the paste is the fallback
reset({statusFor = {["https://example.invalid/mailbox"] = 429}})
local said = {}
local function say(text) table.insert(said, tostring(text)) end

local delivered = publish.report("corps", "https://example.invalid/mailbox", say)
local transcript = table.concat(said, "\n")

check("la boite refuse mais le rapport passe quand meme", delivered == true)
check("le repli est annonce",
      transcript:find("Repli sur un service de collage", 1, true) ~= nil)
check("l URL est affichee pour etre recopiee",
      transcript:find("https://paste.rs/abc", 1, true) ~= nil)
check("deux envois: la boite puis le collage", world.calls == 2)

-- Without a mailbox it goes straight to the paste, no failure message
reset()
said = {}
delivered = publish.report("corps", nil, say)
check("sans boite aux lettres il publie directement", delivered == true)
check("et ne se plaint de rien",
      table.concat(said, "\n"):find("injoignable", 1, true) == nil)
check("un seul envoi", world.calls == 1)

-- Everything failing must be reported as failure, not as a URL
reset({status = 500})
said = {}
delivered = publish.report("corps", nil, say)
check("tout en echec rend faux", delivered == false)

package.loaded["internet"] = nil

print("")
print("=== Resultats ===")
print("Reussis : " .. passed)
print("Echoues : " .. failed)
print(failed == 0 and "La publication tient." or "Des tests echouent.")
os.exit(failed == 0 and 0 or 1)
