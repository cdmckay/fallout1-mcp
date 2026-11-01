local json = require("lib.dkjson")
local keys = require("mcp.keys")
local support = require("tests.support")

local equal, contains = support.equal, support.contains

local tests = {}

function tests.characters_are_their_own_codes_case_and_all()
    equal(keys.code("n"), 110, "n")
    equal(keys.code("A"), 65, "A")
    equal(keys.code("1"), 49, "1")
    equal(keys.code(" "), 32, "space character")
end

function tests.named_keys_ignore_case_and_separators()
    equal(keys.code("escape"), 27, "escape")
    equal(keys.code("Return"), 13, "Return")
    equal(keys.code("enter"), 13, "enter")
    equal(keys.code("page up"), 329, "page up")
    equal(keys.code("Page-Down"), 337, "Page-Down")
    equal(keys.code("F1"), 315, "F1")
    equal(keys.code("f11"), 389, "f11")
end

function tests.ctrl_letters_are_one_to_twenty_six()
    equal(keys.code("ctrl+a"), 1, "ctrl+a")
    equal(keys.code("Ctrl+S"), 19, "Ctrl+S")
    equal(keys.code("ctrl+z"), 26, "ctrl+z")
end

function tests.bad_names_say_why()
    local code, err = keys.code("f12")
    equal(code, nil, "f12")
    contains(err, "look", "f12 reason")

    code, err = keys.code("hyperspace")
    equal(code, nil, "unknown")
    contains(err, "unknown key", "unknown reason")

    code, err = keys.code("")
    equal(code, nil, "empty")

    code, err = keys.code("\t")
    equal(code, nil, "control character")
end

-- A fake game that reads one queued code per frame, like get_input.
local function setup()
    local core, engine = support.new()
    local queue, read = {}, {}

    fo.inject = function(code)
        queue[#queue + 1] = code
        return true
    end
    fo.input_pending = function()
        return #queue > 0
    end
    fo.flags = function()
        return { main_menu = true }
    end
    fo.player = function()
        return nil
    end

    local frames = engine.frames
    engine.frames = function(n)
        for _ = 1, n or 1 do
            if #queue > 0 then
                read[#read + 1] = table.remove(queue, 1)
            end
            frames(1)
        end
    end

    require("tools.input")(core)
    return core, engine, read
end

local function result(engine)
    local reply = engine.reply()
    assert(reply.result, reply.error and reply.error.message)
    return json.decode(reply.result.content[1].text)
end

function tests.key_presses_each_key_once_it_is_read_and_returns_the_view()
    local _, engine, read = setup()

    engine.request({ id = 1, op = "call", tool = "key", args = { keys = { "n", "t" } } })
    engine.frames(30)

    equal(#read, 2, "keys read")
    equal(read[1], 110, "first key")
    equal(read[2], 116, "second key")
    equal(result(engine).mode, "main_menu", "view")
end

-- The intro's movies end on the main menu, where escape quits the game.
function tests.escape_on_the_main_menu_is_skipped_with_a_note()
    local _, engine, read = setup()

    engine.request({ id = 1, op = "call", tool = "key", args = { keys = { "escape", "n" } } })
    engine.frames(30)

    equal(#read, 1, "keys read")
    equal(read[1], 110, "only n reached the game")
    contains(result(engine).note, "would quit the game", "note")
end

function tests.escape_elsewhere_is_sent()
    local _, engine, read = setup()
    fo.flags = function()
        return { movie = true }
    end

    engine.request({ id = 1, op = "call", tool = "key", args = { keys = { "escape" } } })
    engine.frames(30)

    equal(read[1], 27, "escape reached the game")
end

function tests.key_checks_every_name_before_pressing_any()
    local _, engine, read = setup()

    engine.request({ id = 1, op = "call", tool = "key", args = { keys = { "n", "warp" } } })
    engine.frames(30)

    contains(engine.reply().error.message, "unknown key", "error")
    equal(#read, 0, "keys read")
end

function tests.a_key_the_screen_never_reads_is_reported()
    local core, engine = setup()

    -- A screen in the middle of an animation: frames pass, nothing reads input.
    engine.request({ id = 1, op = "call", tool = "key", args = { keys = { "n", "t" } } })
    for _ = 1, 400 do
        engine.now = engine.now + 16
        core.tick()
    end

    local view = result(engine)
    contains(view.note, "hasn't read n", "note")
end

function tests.press_sends_button_codes()
    local _, engine, read = setup()

    engine.request({ id = 1, op = "call", tool = "press", args = { codes = { 503, 518 } } })
    engine.frames(30)

    equal(read[1], 503, "first code")
    equal(read[2], 518, "second code")
end

function tests.press_rejects_codes_that_arent_integers()
    local _, engine = setup()

    engine.request({ id = 1, op = "call", tool = "press", args = { codes = { 1.5 } } })
    engine.frames(2)

    contains(engine.reply().error.message, "isn't an integer", "error")
end

return tests
