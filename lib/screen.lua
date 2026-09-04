--- Screen handling
---
--- The menu is forty lines and an OpenComputers tier 2 screen holds
--- twenty-five. Every option therefore pushed its own result off the top before
--- anyone could read it, and clearing the screen alone does not fix that: the
--- menu itself does not fit.
---
--- So this module does three things -- take the biggest size the hardware
--- allows, erase between screens, and report the room actually available so the
--- menu can fold itself when there is not enough.
---
--- Everything here degrades to a no-op off OpenComputers, because the test
--- suite runs on a desktop Lua where neither component nor term exists.

local screen = {}

--- Require a module that only exists in game
--- @param name string
--- @return table|nil
local function optional(name)
    local ok, module = pcall(require, name)
    if ok and type(module) == "table" then return module end
    return nil
end

--- The GPU, if there is one
--- @return table|nil
local function gpu()
    local component = optional("component")
    if not component then return nil end

    -- component.gpu raises rather than returning nil when nothing is bound
    local ok, proxy = pcall(function() return component.gpu end)
    if ok and proxy then return proxy end
    return nil
end

--- Push the screen to the largest size the GPU and the monitor agree on
--- A tier 3 pair reaches 160x50, which is the difference between a menu that
--- fits and a menu that scrolls away as it is drawn.
--- @return number width
--- @return number height
function screen.maximise()
    local card = gpu()
    if not card then return 80, 25 end

    local ok, width, height = pcall(function()
        return card.maxResolution()
    end)

    if not ok or not tonumber(width) then return screen.size() end

    -- Refusing is normal: the monitor may be smaller than the card can drive
    pcall(function() card.setResolution(width, height) end)

    return screen.size()
end

--- Current size
--- @return number width
--- @return number height
function screen.size()
    local card = gpu()
    if not card then return 80, 25 end

    local ok, width, height = pcall(function() return card.getResolution() end)
    if ok and tonumber(width) and tonumber(height) then
        return tonumber(width), tonumber(height)
    end

    return 80, 25
end

--- Rows available
--- @return number
function screen.height()
    local _, height = screen.size()
    return height
end

--- Columns available
--- @return number
function screen.width()
    local width = screen.size()
    return width
end

--- Erase everything and put the cursor back at the top
--- Off OpenComputers this does nothing at all, on purpose: wiping a developer's
--- terminal mid test run helps nobody.
function screen.clear()
    local term = optional("term")
    if term and term.clear then
        pcall(term.clear)
        return true
    end
    return false
end

--- Wait for the reader before moving on
--- The whole point of the pause: a genome read is thirteen lines, and the menu
--- redrawing on top of them makes them unreadable however fast anyone is.
--- @param message string|nil
function screen.pause(message)
    io.write(message or "-- Entree pour revenir au menu --")

    -- io.read returns nil on a closed stream; treating that as a keypress is
    -- what turns a lost terminal into an infinite loop
    local answer = io.read()
    return answer ~= nil
end

return screen
