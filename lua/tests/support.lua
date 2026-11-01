-- A stand-in for the engine: a fake `fo` table, a fresh core per test, and
-- helpers to send requests, run frames and read replies.

local json = require("lib.dkjson")

local support = {}

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

    package.loaded["mcp.core"] = nil
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
