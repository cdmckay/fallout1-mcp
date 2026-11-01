-- The MCP command layer: the socket protocol, the tool registry, and the
-- scheduler that runs each request as a coroutine. See docs/mcp-design.md.
--
-- The engine drives this module through on_connect, on_disconnect, on_line
-- and tick (once per frame, from process_bk), and provides the global `fo`
-- table of bindings.
--
-- Requests are one JSON object per line, and each gets exactly one reply,
-- {"id": n, "result": ...} or {"id": n, "error": {"message": ...}}:
--   {"id": 1, "op": "list"}                                   the tools on offer
--   {"id": 2, "op": "call", "tool": "ping", "args": {}}       run a tool
--   {"id": 3, "op": "reload"}                                 rerun the Lua files

local json = require("lib.dkjson")

local core = {}

local tools = {}
local tool_names = {}

local frame = 0

-- The request being run: { id, tool, co, wake }. One at a time.
local current = nil

-- Engine calls queued by `defer` and `post`, run by `tick` outside any
-- coroutine.
local deferred = {}

-- True while `tick` is resuming the current request. A binding that opens a
-- screen re-enters `tick` from that screen's loop; while this is set, the
-- nested tick leaves the request alone.
local resuming = false

-- Errors raised with `core.fail` reach the agent as a plain message; anything
-- else is a bug, and reaches it with a traceback.
local ToolError = {}
ToolError.__tostring = function(e)
    return e.message
end

function core.fail(message)
    error(setmetatable({ message = message }, ToolError), 2)
end

-- dkjson encodes an empty table as an array unless told otherwise.
function core.object(t)
    return setmetatable(t or {}, { __jsontype = "object" })
end

function core.array(t)
    return setmetatable(t or {}, { __jsontype = "array" })
end

-- A JSON Schema for a tool's arguments.
function core.schema(properties, required)
    return core.object({
        type = "object",
        properties = core.object(properties),
        required = required and core.array(required) or nil,
        additionalProperties = false,
    })
end

-- Registers a tool. `def` has:
--   name, description   shown to the agent;
--   schema              the arguments, from core.schema (default: none);
--   run(args)           runs as a coroutine and returns the result: a string,
--                       or a table with any of `data` (sent as JSON), `text`
--                       and `image` (a base64 PNG);
--   omniscient          true for tools offered only in omniscient mode.
function core.tool(def)
    assert(type(def.name) == "string", "a tool needs a name")
    assert(type(def.run) == "function", def.name .. " needs a run function")
    if tools[def.name] == nil then
        tool_names[#tool_names + 1] = def.name
    end
    tools[def.name] = def
end

-- "fair" or "omniscient", fixed when the bridge starts the game.
function core.access()
    return fo.omniscient() and "omniscient" or "fair"
end

function core.frame()
    return frame
end

local function available(def)
    return not def.omniscient or fo.omniscient()
end

local function send(message)
    fo.send(json.encode(message))
end

local function reply(id, result)
    send({ id = id, result = result })
end

local function reply_error(id, message)
    send({ id = id, error = { message = message } })
end

local function list_tools()
    local list = core.array()
    for _, name in ipairs(tool_names) do
        local def = tools[name]
        if available(def) then
            list[#list + 1] = {
                name = name,
                description = def.description or "",
                inputSchema = def.schema or core.schema({}),
            }
        end
    end
    return list
end

local function to_content(value)
    local content = core.array()
    if type(value) == "string" then
        content[#content + 1] = { type = "text", text = value }
    elseif type(value) == "table" then
        if value.data ~= nil then
            content[#content + 1] = { type = "text", text = json.encode(value.data) }
        end
        if value.text ~= nil then
            content[#content + 1] = { type = "text", text = value.text }
        end
        if value.image ~= nil then
            content[#content + 1] = { type = "image", data = value.image, mimeType = "image/png" }
        end
    end
    return { content = content, access = core.access() }
end

local function handle_error(e)
    if getmetatable(e) == ToolError then
        return e
    end
    return debug.traceback(tostring(e), 2)
end

local function start(id, def, args)
    if type(args) ~= "table" then
        args = {}
    end

    local co = coroutine.create(function()
        return xpcall(def.run, handle_error, args)
    end)

    -- Started by the next tick, not here, so on_line stays quick.
    current = { id = id, tool = def.name, co = co, wake = frame }
end

local function resume()
    local job = current

    resuming = true
    local ok, a, b = coroutine.resume(job.co)
    resuming = false

    if current ~= job then
        -- Cancelled while it ran, by a disconnect seen in a nested tick.
        return
    end

    if not ok then
        current = nil
        reply_error(job.id, tostring(a))
        return
    end

    if coroutine.status(job.co) == "dead" then
        current = nil
        -- `a` and `b` are what xpcall returned.
        if a then
            reply(job.id, to_content(b))
        else
            reply_error(job.id, tostring(b))
        end
        return
    end

    -- Yielded by a wait: `a` says how many frames to sleep.
    local frames = type(a) == "table" and a.frames or 1
    job.wake = frame + frames
end

local function run_deferred()
    while #deferred > 0 do
        local item = table.remove(deferred, 1)
        item.results = table.pack(pcall(item.fn, table.unpack(item.args, 1, item.args.n)))
        item.done = true
        if not item.results[1] and item.posted then
            fo.log("posted call failed: " .. tostring(item.results[2]))
        end
    end
end

-- Sleeps the current request for `n` frames (default 1).
function core.wait_frames(n)
    coroutine.yield({ frames = n or 1 })
end

-- Checks `predicate` once a frame until it returns true or `timeout_ms`
-- (default 5000) passes. Returns whether it came true.
function core.wait_until(predicate, timeout_ms)
    local deadline = fo.ticks() + (timeout_ms or 5000)
    while true do
        if predicate() then
            return true
        end
        if fo.ticks() >= deadline then
            return false
        end
        coroutine.yield({ frames = 1 })
    end
end

-- Runs `fn(...)` on the next tick outside the coroutine, waits for it, and
-- returns its results. For engine calls that must not run inside a coroutine
-- but return promptly.
function core.defer(fn, ...)
    local item = { fn = fn, args = table.pack(...), done = false }
    deferred[#deferred + 1] = item
    while not item.done do
        coroutine.yield({ frames = 1 })
    end
    if not item.results[1] then
        error(item.results[2], 0)
    end
    return table.unpack(item.results, 2, item.results.n)
end

-- Runs `fn(...)` on the next tick outside the coroutine without waiting. For
-- engine calls that open a screen and only return when it closes: the
-- request goes on, resumed from inside that screen's loop, and typically
-- waits for the screen to appear.
function core.post(fn, ...)
    deferred[#deferred + 1] = { fn = fn, args = table.pack(...), done = false, posted = true }
end

function core.on_connect()
end

function core.on_disconnect()
    -- Nobody is left to answer; drop the request and anything it queued.
    current = nil
    deferred = {}
end

function core.on_line(line)
    if line == "" then
        return
    end

    local request, _, err = json.decode(line)
    if type(request) ~= "table" then
        send({ error = { message = "can't parse request: " .. tostring(err) } })
        return
    end

    local id = request.id
    if math.type(id) ~= "integer" then
        send({ error = { message = "request needs an integer id" } })
        return
    end

    -- Every request gets an answer, even when handling it goes wrong;
    -- otherwise the bridge waits until it times out.
    local ok, err = xpcall(function()
        local op = request.op
        if op == "list" then
            reply(id, { access = core.access(), tools = list_tools() })
        elseif op == "call" then
            local def = tools[request.tool]
            if def == nil or not available(def) then
                reply_error(id, "unknown tool: " .. tostring(request.tool))
            elseif current ~= nil then
                reply_error(id, "busy: still running " .. current.tool)
            else
                start(id, def, request.args)
            end
        elseif op == "reload" then
            if current ~= nil then
                reply_error(id, "busy: still running " .. current.tool)
            else
                fo.reload(id)
            end
        else
            reply_error(id, "unknown op: " .. tostring(op))
        end
    end, debug.traceback)

    if not ok then
        reply_error(id, "the game's Lua failed handling this request: " .. tostring(err))
    end
end

function core.tick()
    frame = frame + 1

    if resuming then
        return
    end

    run_deferred()

    if current ~= nil and frame >= current.wake then
        resume()
    end
end

return core
