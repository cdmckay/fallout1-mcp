local json = require("lib.dkjson")
local support = require("tests.support")

local equal, contains = support.equal, support.contains

local tests = {}

-- A fake map: the player on tile 100, the view centered on them. The world
-- map exit (tile 5000) and a rat (tile 6000) only come on screen when the view
-- is moved east, which the fake numbers 100 + 1 * 1000 + 14.
local EAST = 1114

local function setup()
    local core, engine = support.new()
    local view = { center = 100, moves = {} }

    fo.flags = function()
        return { in_game = true }
    end
    fo.player = function()
        return { name = "Max Stone", tile = 100, map = { file = "V13ENT.MAP" } }
    end
    fo.tile_toward = function(tile, rotation, distance)
        return tile + rotation * 1000 + distance
    end
    fo.view_center = function()
        return view.center
    end
    fo.set_view_center = function(tile, refresh)
        view.moves[#view.moves + 1] = { tile = tile, refresh = refresh }
        view.center = tile
        return true
    end
    fo.tile_center = function(tile)
        if view.center == EAST and (tile == 5000 or tile == 6000) then
            return 900, 300
        end
        return nil
    end
    fo.exits = function()
        return { { tile = 5000, map = -1, seen = false, visible = view.center == EAST, reachable = true } }
    end
    fo.critters = function()
        return { { id = 7, name = "Cave Rat", tile = 6000, hidden = false, visible = view.center == EAST, dead = false, health = "Unhurt" } }
    end

    require("tools.perception")(core)

    local function call(tool, args)
        engine.request({ id = 1, op = "call", tool = tool, args = args or {} })
        engine.frames(5)
        local reply = engine.reply()
        if reply.error then
            return nil, reply.error.message
        end
        return (json.decode(reply.result.content[1].text))
    end

    return view, call
end

function tests.survey_finds_an_exit_off_screen_and_remembers_it()
    local view, call = setup()

    local result = call("survey")

    equal(#result.survey.looked, 8, "directions looked")
    equal(result.exits[1].to, "the world map", "exit found")
    equal(result.exits[1].screen, nil, "off screen again")
    equal(result.spotted[1].name, "Cave Rat", "rat spotted")
    equal(view.center, 100, "view back on the player")

    -- Seen once, so it stays in the view after the survey.
    local later = call("state")
    equal(later.exits[1].to, "the world map", "still known")
end

function tests.survey_moves_the_view_unseen_and_redraws_only_at_the_end()
    local view, call = setup()

    call("survey")

    for i = 1, #view.moves - 1 do
        equal(view.moves[i].refresh, false, "no redraw while looking")
    end
    equal(view.moves[#view.moves].refresh, true, "redrawn when put back")
end

function tests.survey_needs_the_map()
    local _, call = setup()
    fo.flags = function()
        return { main_menu = true }
    end

    local _, err = call("survey")

    contains(err, "on the map", "error")
end

return tests
