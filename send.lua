-- send.lua: put a file online and print one link.
--
-- The trace and the diagnostic report are both longer than a screen and scroll faster than they
-- can be read. This uploads any of them and gives back a short link to paste.
--
-- OpenOS ships `pastebin put`, but it no longer works: the API key baked into OpenOS 1.8.7 is
-- dead upstream and pastebin.com answers 422 to every anonymous upload.
--
-- Usage:
--   send /home/hivemind_trace.txt
--   send                            -- the trace, which is the usual one

local component = require("component")
local shell = require("shell")

local args = shell.parse(...)
local path = args[1] or "/home/hivemind_trace.txt"

local file = io.open(path, "r")
if not file then
    print("Cannot read " .. path)
    print("Run the program with --trace first:  main.lua --trace")

    return
end

local text = file:read("*a")
file:close()

if not text or text == "" then
    print(path .. " is empty.")

    return
end

print(string.format("%s: %d bytes", path, #text))

if not component.isAvailable("internet") then
    print("No Internet Card in this computer, so it cannot be uploaded.")
    print("Read it here instead:  edit " .. path)

    return
end

local ok, internet = pcall(require, "internet")
if not ok then
    print("The internet library is not available.")

    return
end

print("Uploading...")

local body = nil
local sent, err = pcall(function()
    local handle = internet.request("https://paste.rs", text, {["Content-Type"] = "text/plain"})

    body = ""
    for chunk in handle do
        body = body .. chunk
    end
end)

if not sent then
    print("Upload failed: " .. tostring(err))
    print("Read it here instead:  edit " .. path)

    return
end

if not body or body == "" then
    print("The paste service answered nothing.")

    return
end

print()
print("  " .. (body:gsub("%s+$", "")))
print()
print("Send that link. Add .txt to it to read it in a browser.")
