local json = require("lib.dkjson")
local support = require("tests.support")

local equal, contains = support.equal, support.contains

local tests = {}

-- A fake game with the player on tile 100. A walk keeps the player busy for
-- a few frames, then puts them on the destination, unless `stop_short` says
-- where they really stop.
local function setup(options)
    options = options or {}
    local core, engine = support.new()
    local game = { tile = 100, busy_frames = 0, walks = {}, path_length = options.path_length or 7 }

    fo.flags = function()
        return { in_game = true }
    end
    fo.player = function()
        return { name = "Max Stone", tile = game.tile }
    end
    fo.tile_center = function()
        return 500, 400
    end
    fo.tile_at = function(x, y)
        if x < 0 then
            return nil
        end
        return x * 100 + y
    end
    fo.tile_toward = function(tile, rotation, distance)
        return tile + rotation * 1000 + distance
    end
    fo.path_length = function()
        return game.path_length
    end
    fo.walk_to = function(tile, run)
        game.walks[#game.walks + 1] = { tile = tile, run = run }
        game.busy_frames = 5
        game.destination = options.stop_short or tile
        return true
    end
    fo.player_busy = function()
        return game.busy_frames > 0
    end
    fo.exits = function()
        return {}
    end

    local frames = engine.frames
    engine.frames = function(n)
        for _ = 1, n or 1 do
            if game.busy_frames > 0 then
                game.busy_frames = game.busy_frames - 1
                if game.busy_frames == 0 then
                    game.tile = game.destination
                end
            end
            frames(1)
        end
    end

    require("tools.movement")(core)

    local function walk(args)
        engine.request({ id = 1, op = "call", tool = "walk_to", args = args })
        engine.frames(40)
        local reply = engine.reply()
        if reply.error then
            return nil, reply.error.message
        end
        return json.decode(reply.result.content[1].text)
    end

    return game, walk
end

function tests.walks_to_a_tile_and_reports_arriving()
    local game, walk = setup()

    local view = walk({ tile = 250 })

    equal(game.walks[1].tile, 250, "destination")
    equal(game.walks[1].run, false, "walking, not running")
    equal(view.walk.from, 100, "from")
    equal(view.walk.to, 250, "to")
    equal(view.walk.path_length, 7, "path length")
    equal(view.walk.arrived, true, "arrived")
    equal(view.player.tile, 250, "player tile")
end

function tests.a_screen_point_becomes_the_tile_under_it()
    local game, walk = setup()

    walk({ x = 3, y = 40 })

    equal(game.walks[1].tile, 340, "tile under the point")
end

function tests.a_direction_and_distance_count_from_the_player()
    local game, walk = setup()

    walk({ direction = "SW", distance = 4 })

    -- The fake numbers tile + rotation * 1000 + distance; SW is rotation 3.
    equal(game.walks[1].tile, 3104, "tile 4 hexes south-west")
end

function tests.run_is_passed_through()
    local game, walk = setup()

    walk({ tile = 250, run = true })

    equal(game.walks[1].run, true, "running")
end

function tests.stopping_short_is_reported()
    local _, walk = setup({ stop_short = 180 })

    local view = walk({ tile = 250 })

    equal(view.walk.arrived, false, "arrived")
    equal(view.player.tile, 180, "where the player stopped")
end

function tests.no_path_is_an_error_and_nobody_moves()
    local game, walk = setup({ path_length = 0 })

    local _, err = walk({ tile = 250 })

    contains(err, "no way", "error")
    equal(#game.walks, 0, "walks")
end

function tests.the_spot_already_stood_on_is_no_walk()
    local game, walk = setup()

    local view = walk({ tile = 100 })

    equal(#game.walks, 0, "walks")
    equal(view.walk.arrived, true, "arrived")
end

function tests.exactly_one_kind_of_destination_is_needed()
    local _, walk = setup()

    local _, none = walk({})
    contains(none, "exactly one destination", "nothing given")

    local _, both = walk({ tile = 5, x = 1, y = 2 })
    contains(both, "exactly one destination", "two given")

    local _, half = walk({ x = 1 })
    contains(half, "x and y", "only x")

    local _, direction = walk({ direction = "up", distance = 3 })
    contains(direction, "ne, e, se, sw, w, nw", "bad direction")

    local _, distance = walk({ direction = "e", distance = 0 })
    contains(distance, "1 to 200", "bad distance")

    local _, off = walk({ x = -5, y = 2 })
    contains(off, "isn't on the map", "off the map")
end

return tests
