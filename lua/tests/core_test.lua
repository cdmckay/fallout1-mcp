local json = require("lib.dkjson")
local support = require("tests.support")

local equal, contains = support.equal, support.contains

local tests = {}

local function add_echo(core)
    core.tool({
        name = "echo",
        description = "Echoes its argument.",
        schema = core.schema({ value = { type = "string" } }, { "value" }),
        run = function(args)
            return { data = { value = args.value } }
        end,
    })
end

function tests.list_offers_fair_tools_only_in_fair_mode()
    local core, engine = support.new()
    add_echo(core)
    core.tool({ name = "secret", omniscient = true, run = function() end })

    engine.request({ id = 1, op = "list" })
    local reply = engine.reply()

    equal(reply.id, 1, "id")
    equal(reply.result.access, "fair", "access")
    equal(#reply.result.tools, 1, "tool count")
    equal(reply.result.tools[1].name, "echo", "tool")
    equal(reply.result.tools[1].inputSchema.required[1], "value", "schema")
end

function tests.list_offers_everything_in_omniscient_mode()
    local core, engine = support.new({ omniscient = true })
    add_echo(core)
    core.tool({ name = "secret", omniscient = true, run = function() end })

    engine.request({ id = 1, op = "list" })
    local reply = engine.reply()

    equal(reply.result.access, "omniscient", "access")
    equal(#reply.result.tools, 2, "tool count")
end

function tests.empty_schema_properties_encode_as_an_object()
    local core, engine = support.new()
    core.tool({ name = "noargs", run = function() end })

    engine.request({ id = 1, op = "list" })
    engine.frames()
    local _ = engine.replies()

    -- Re-encode to check the wire form: "properties" must be {}, not [].
    local listed = json.encode(core.schema({}))
    contains(listed, '"properties":{}', "schema JSON")
end

function tests.a_call_runs_on_the_next_frame_not_immediately()
    local core, engine = support.new()
    add_echo(core)

    engine.request({ id = 7, op = "call", tool = "echo", args = { value = "hi" } })
    equal(#engine.replies(), 0, "replies before a frame")

    engine.frames()
    local reply = engine.reply()
    equal(reply.id, 7, "id")
    equal(reply.result.access, "fair", "access")
    equal(json.decode(reply.result.content[1].text).value, "hi", "echoed value")
end

function tests.wait_frames_sleeps_that_many_frames()
    local core, engine = support.new()
    core.tool({
        name = "slow",
        run = function()
            core.wait_frames(3)
            return "done"
        end,
    })

    engine.request({ id = 1, op = "call", tool = "slow" })
    engine.frames(3)
    equal(#engine.replies(), 0, "replies after 3 frames")

    engine.frames()
    equal(engine.reply().result.content[1].text, "done", "result")
end

function tests.a_second_call_while_one_runs_is_busy()
    local core, engine = support.new()
    core.tool({ name = "slow", run = function() core.wait_frames(10) end })

    engine.request({ id = 1, op = "call", tool = "slow" })
    engine.frames()
    engine.request({ id = 2, op = "call", tool = "slow" })

    local reply = engine.reply()
    equal(reply.id, 2, "id")
    contains(reply.error.message, "busy", "error")
end

function tests.unknown_tools_and_bad_requests_get_errors()
    local core, engine = support.new()
    core.tool({ name = "secret", omniscient = true, run = function() end })

    engine.request({ id = 1, op = "call", tool = "nope" })
    contains(engine.reply().error.message, "unknown tool", "missing tool")

    engine.request({ id = 2, op = "call", tool = "secret" })
    contains(engine.reply().error.message, "unknown tool", "omniscient tool in fair mode")

    core.on_line("{not json")
    contains(engine.reply().error.message, "can't parse", "bad JSON")

    engine.request({ op = "list" })
    contains(engine.reply().error.message, "integer id", "missing id")

    engine.request({ id = 3, op = "dance" })
    contains(engine.reply().error.message, "unknown op", "bad op")
end

-- A broken binding mustn't leave the bridge waiting for an answer.
function tests.a_request_that_fails_to_dispatch_still_gets_an_answer()
    local _, engine = support.new()
    fo.reload = function()
        error("bad argument #1 to 'reload'")
    end

    engine.request({ id = 9, op = "reload" })

    local reply = engine.reply()
    equal(reply.id, 9, "id")
    contains(reply.error.message, "bad argument", "error")
end

function tests.fail_reaches_the_agent_without_a_traceback()
    local core, engine = support.new()
    core.tool({ name = "picky", run = function() core.fail("tile 99999 is off the map") end })

    engine.request({ id = 1, op = "call", tool = "picky" })
    engine.frames()

    equal(engine.reply().error.message, "tile 99999 is off the map", "message")
end

function tests.bugs_reach_the_agent_with_a_traceback()
    local core, engine = support.new()
    core.tool({ name = "buggy", run = function() local t = nil; return t.field end })

    engine.request({ id = 1, op = "call", tool = "buggy" })
    engine.frames()

    local message = engine.reply().error.message
    contains(message, "attempt to index", "error")
    contains(message, "stack traceback", "traceback")
end

function tests.defer_runs_outside_the_coroutine_and_returns_results()
    local core, engine = support.new()
    local inside
    core.tool({
        name = "deferring",
        run = function()
            local a, b = core.defer(function(x)
                inside = coroutine.isyieldable()
                return x * 2, "ok"
            end, 21)
            return { data = { a = a, b = b } }
        end,
    })

    engine.request({ id = 1, op = "call", tool = "deferring" })
    engine.frames(3)

    equal(inside, false, "ran inside a coroutine")
    local data = json.decode(engine.reply().result.content[1].text)
    equal(data.a, 42, "first result")
    equal(data.b, "ok", "second result")
end

function tests.a_deferred_error_raises_in_the_request()
    local core, engine = support.new()
    core.tool({
        name = "deferring",
        run = function()
            core.defer(function() error("engine said no", 0) end)
        end,
    })

    engine.request({ id = 1, op = "call", tool = "deferring" })
    engine.frames(3)

    contains(engine.reply().error.message, "engine said no", "error")
end

-- A posted call that opens a screen blocks until the screen closes, while the
-- screen's own loop keeps calling tick. The request must be resumed from
-- those nested ticks and finish without waiting for the screen to close.
function tests.a_request_finishes_while_a_posted_screen_is_open()
    local core, engine = support.new()
    local screen_open = false

    core.tool({
        name = "open_screen",
        run = function()
            core.post(function()
                screen_open = true
                -- The screen's loop: it runs frames until the agent closes it.
                engine.frames(5)
                screen_open = false
            end)
            core.wait_until(function() return screen_open end)
            return "screen is open"
        end,
    })

    -- Frame 1 starts the request, which posts the call; frame 2 runs the call,
    -- and the screen's loop runs the frames that finish the request.
    engine.request({ id = 1, op = "call", tool = "open_screen" })
    engine.frames(2)

    -- Sent from inside the screen's loop, before the screen closed.
    local reply = engine.reply()
    equal(reply.result.content[1].text, "screen is open", "result")
    equal(screen_open, false, "screen closed afterwards")
end

-- If a binding called directly inside a request opens a screen, nested ticks
-- must not resume that request again.
function tests.nested_ticks_never_resume_a_running_request()
    local core, engine = support.new()
    local resumed = 0

    core.tool({
        name = "reentrant",
        run = function()
            resumed = resumed + 1
            engine.frames(3)
            return "done"
        end,
    })

    engine.request({ id = 1, op = "call", tool = "reentrant" })
    engine.frames()

    equal(resumed, 1, "times run")
    equal(engine.reply().result.content[1].text, "done", "result")
end

function tests.wait_until_gives_up_at_the_timeout()
    local core, engine = support.new()
    core.tool({
        name = "never",
        run = function()
            return { data = { came_true = core.wait_until(function() return false end, 100) } }
        end,
    })

    engine.request({ id = 1, op = "call", tool = "never" })
    engine.frames(10)

    equal(json.decode(engine.reply().result.content[1].text).came_true, false, "came true")
end

function tests.reload_is_handed_to_the_engine_unless_busy()
    local core, engine = support.new()
    core.tool({ name = "slow", run = function() core.wait_frames(10) end })

    engine.request({ id = 4, op = "reload" })
    equal(engine.reload_id, 4, "reload id")
    equal(#engine.replies(), 0, "Lua doesn't answer a reload itself")

    engine.reload_id = nil
    engine.request({ id = 5, op = "call", tool = "slow" })
    engine.frames()
    engine.request({ id = 6, op = "reload" })
    contains(engine.reply().error.message, "busy", "reload while busy")
    equal(engine.reload_id, nil, "reload id while busy")
end

function tests.a_disconnect_drops_the_running_request()
    local core, engine = support.new()
    core.tool({ name = "slow", run = function() core.wait_frames(2) return "late" end })

    engine.request({ id = 1, op = "call", tool = "slow" })
    engine.frames()
    core.on_disconnect()
    engine.frames(5)

    equal(#engine.replies(), 0, "replies after disconnect")

    engine.request({ id = 2, op = "call", tool = "slow" })
    engine.frames(3)
    equal(engine.reply().id, 2, "a new request runs")
end

function tests.results_can_carry_text_and_an_image()
    local core, engine = support.new()
    core.tool({ name = "look", run = function() return { text = "a cave", image = "iVBOR" } end })

    engine.request({ id = 1, op = "call", tool = "look" })
    engine.frames()

    local content = engine.reply().result.content
    equal(content[1].type, "text", "first part")
    equal(content[1].text, "a cave", "text")
    equal(content[2].type, "image", "second part")
    equal(content[2].mimeType, "image/png", "mime type")
end


-- show_status puts one tidy line in the window title, and an empty one clears it.
function tests.show_status_puts_one_line_in_the_window_title()
    local core, engine = support.new()
    local shown = {}
    fo.set_status = function(text)
        shown[#shown + 1] = text
    end
    require("tools.basic")(core)

    engine.request({ id = 1, op = "call", tool = "show_status", args = { text = "  walking into\nthe rats  " } })
    engine.frames(1)
    local reply = engine.reply()
    assert(reply.result, reply.error and reply.error.message)
    equal(shown[1], "walking into the rats", "shown")
    equal(json.decode(reply.result.content[1].text).status, "walking into the rats", "result")

    engine.request({ id = 2, op = "call", tool = "show_status", args = { text = "" } })
    engine.frames(1)
    engine.reply()
    equal(shown[2], "", "cleared")
end

return tests
