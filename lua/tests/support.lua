-- A stand-in for the engine: a fake `fo` table, a fresh core per test, and
-- helpers to send requests, run frames and read replies.

local json = require("lib.dkjson")

local support = {}

-- Fills in the state view's bindings with an empty world: no critters, no
-- exits, no messages, no fight, nothing on screen. Tests override what they
-- need on top.
function support.quiet_world()
    fo.critters = function()
        return {}
    end
    fo.exits = function()
        return {}
    end
    fo.messages = function()
        return {}, 0
    end
    fo.combat = function()
        return nil
    end
    fo.equipped = function()
        return nil
    end
    fo.awareness = function()
        return false
    end
    fo.tile_center = function()
        return nil
    end
    fo.tile_distance = function(a, b)
        return math.abs(a - b)
    end
    fo.tile_direction = function()
        return 0
    end
    fo.map_name = function(index)
        return index <= 0 and "the world map" or ("map " .. index)
    end
end

-- Returns a fresh core and a fake engine. `options.omniscient` sets the mode.
function support.new(options)
    options = options or {}

    local sent = {}
    local engine = {
        now = 0,
        omniscient = options.omniscient or false,
        reload_id = nil,
        logs = {},
    }

    _G.fo = {
        send = function(line)
            sent[#sent + 1] = line
            return true
        end,
        log = function(message)
            engine.logs[#engine.logs + 1] = message
        end,
        ticks = function()
            return engine.now
        end,
        omniscient = function()
            return engine.omniscient
        end,
        reload = function(id)
            engine.reload_id = id
        end,
    }
    support.quiet_world()

    -- Fresh modules, so no state (a message cursor, a running request)
    -- carries over from another test.
    for name in pairs(package.loaded) do
        if name:match("^mcp%.") or name:match("^tools%.") then
            package.loaded[name] = nil
        end
    end
    local core = require("mcp.core")

    function engine.request(request)
        core.on_line(json.encode(request))
    end

    -- Runs `n` frames (default 1), 16 ms apart.
    function engine.frames(n)
        for _ = 1, n or 1 do
            engine.now = engine.now + 16
            core.tick()
        end
    end

    -- Returns the replies sent since the last call, decoded.
    function engine.replies()
        local replies = {}
        for i, line in ipairs(sent) do
            replies[i] = json.decode(line)
        end
        for i = #sent, 1, -1 do
            sent[i] = nil
        end
        return replies
    end

    -- Returns the only reply sent since the last call.
    function engine.reply()
        local replies = engine.replies()
        assert(#replies == 1, ("expected one reply, got %d"):format(#replies))
        return replies[1]
    end

    return core, engine
end

function support.equal(actual, expected, what)
    if actual ~= expected then
        error(("%s: expected %s, got %s"):format(what or "value", tostring(expected), tostring(actual)), 2)
    end
end

function support.contains(haystack, needle, what)
    if type(haystack) ~= "string" or not haystack:find(needle, 1, true) then
        error(("%s: expected %q in %s"):format(what or "string", needle, tostring(haystack)), 2)
    end
end

return support
