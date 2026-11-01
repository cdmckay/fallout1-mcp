local json = require("lib.dkjson")
local support = require("tests.support")

local equal, contains = support.equal, support.contains

local tests = {}

-- Hexes in a row from the player, for fo.reachable: `count` hexes starting
-- `first` steps out, each `dx`, `dy` pixels on from the last, numbered from
-- `tile`. `start` is where the row begins on the screen, one step before
-- its first hex.
local function row(tile, count, dx, dy, start, first)
    start = start or { 0, 0 }
    first = first or 1
    local hexes = {}
    for i = 1, count do
        hexes[i] = { tile = tile + i - 1, steps = first + i - 1, x = start[1] + dx * i, y = start[2] + dy * i }
    end
    return hexes
end

local function join(...)
    local all = {}
    for _, list in ipairs({ ... }) do
        for _, hex in ipairs(list) do
            all[#all + 1] = hex
        end
    end
    return all
end

-- A fight's state as fo.combat gives it: on the player's turn with `ap`, or
-- on someone else's.
local function your_turn(ap)
    return { turn = "Max Stone", can_act = true, animating = false, ap = ap, max_ap = 6, free_move = 0 }
end

local function rats_turn()
    return { turn = "Cave Rat", can_act = false, animating = false, ap = 0, max_ap = 6, free_move = 0 }
end

-- A fake game with the player on tile 100. A walk keeps the player busy for
-- a few frames, then puts them on the destination, unless `stop_short` says
-- where they really stop. `game.fight` is the fight, if any; `game.turns`
-- hands the fight to the player after that many frames of someone else's
-- turn. `game.on_walk` and `game.on_arrive` run when a walk starts and ends,
-- `game.on_frame` every frame.
local function setup(options)
    options = options or {}
    local core, engine = support.new()
    local game = {
        tile = 100,
        map = "V13ENT.MAP",
        busy_frames = 0,
        walks = {},
        path_length = options.path_length or 7,
        past_critters = 0,
        blockers = {},
        reachable = {},
        exits = {},
        refusals = 0,
    }

    fo.flags = function()
        return { in_game = true, combat = game.fight ~= nil, world_map = game.world_map }
    end
    fo.player = function()
        return { name = "Max Stone", tile = game.tile, elevation = 0, map = { file = game.map, name = "Vault 13" } }
    end
    fo.combat = function()
        return game.fight
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
    fo.reachable = function(max_steps)
        game.reach = max_steps
        return game.reachable
    end
    fo.path_length = function(tile)
        if game.paths ~= nil and game.paths[tile] ~= nil then
            return game.paths[tile]
        end
        return game.path_length
    end
    fo.path_length_past_critters = function()
        return game.past_critters
    end
    fo.blocker = function(tile)
        return game.blockers[tile]
    end
    fo.walk_to = function(tile, run)
        if game.refusals > 0 then
            game.refusals = game.refusals - 1
            return false
        end
        game.walks[#game.walks + 1] = { tile = tile, run = run }
        game.busy_frames = options.busy_frames or 5
        game.destination = options.stop_short or tile
        if game.on_walk then
            game.on_walk()
        end
        return true
    end
    fo.player_busy = function()
        return game.busy_frames > 0
    end
    fo.exits = function()
        return game.exits
    end

    local frames = engine.frames
    engine.frames = function(n)
        for _ = 1, n or 1 do
            if game.busy_frames > 0 then
                game.busy_frames = game.busy_frames - 1
                if game.busy_frames == 0 then
                    game.tile = game.destination
                    if game.on_arrive then
                        game.on_arrive()
                    end
                end
            end
            if game.on_frame then
                game.on_frame()
            end
            if game.turns ~= nil and game.fight ~= nil and not game.fight.can_act then
                game.turns = game.turns - 1
                if game.turns <= 0 then
                    game.turns = nil
                    game.fight = your_turn(6)
                end
            end
            frames(1)
        end
    end

    require("tools.movement")(core)

    -- Calls walk_to and runs frames until it answers.
    local function walk(args)
        engine.request({ id = 1, op = "call", tool = "walk_to", args = args })
        for _ = 1, 10000 do
            engine.frames(1)
            local replies = engine.replies()
            if #replies > 0 then
                local reply = replies[1]
                if reply.error then
                    return nil, reply.error.message
                end
                return (json.decode(reply.result.content[1].text))
            end
        end
        error("walk_to never answered")
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
    equal(view.walk.stopped_by, nil, "stopped by")
    equal(view.player.tile, 250, "player tile")
end

function tests.a_screen_point_becomes_the_tile_under_it()
    local game, walk = setup()

    walk({ x = 3, y = 40 })

    equal(game.walks[1].tile, 340, "tile under the point")
end

function tests.run_is_passed_through()
    local game, walk = setup()

    walk({ tile = 250, run = true })

    equal(game.walks[1].run, true, "running")
end

-- Direction walks. On the screen east is 32 pixels a hex; a hex south-east
-- is 16 across and 12 down.

function tests.a_direction_walk_that_goes_the_whole_way_arrives()
    local game, walk = setup()
    game.reachable = row(201, 10, 32, 0)

    local view = walk({ direction = "E", distance = 4 })

    equal(game.walks[1].tile, 204, "four hexes east")
    equal(view.walk.hexes_that_way, 4, "hexes that way")
    equal(view.walk.arrived, true, "arrived")
    equal(view.walk.stopped_by, nil, "stopped by")
    equal(game.reach, 11, "searched twice the distance and a little")
end

function tests.a_direction_walk_follows_a_bend_as_far_as_it_goes()
    local game, walk = setup()
    -- Three hexes east, a step down to the south-east, then four more east,
    -- and a wall.
    game.reachable = join(row(201, 3, 32, 0), row(211, 1, 16, 12, { 96, 0 }, 4), row(221, 4, 32, 0, { 112, 12 }, 5))

    local view = walk({ direction = "e", distance = 10 })

    equal(game.walks[1].tile, 224, "the end of the bend")
    equal(view.walk.hexes_that_way, 8, "hexes that way")
    equal(view.walk.arrived, false, "arrived")
    equal(view.walk.stopped_by, "blocked", "stopped by")
    contains(view.note, "blocked after 8 hexes", "note")
end

function tests.a_direction_walk_doesnt_go_back_the_way_it_came()
    local game, walk = setup()
    game.reachable = join(
        row(201, 2, 32, 0),
        -- Further east, but only by a long way round.
        { { tile = 301, steps = 20, x = 192, y = 0 } },
        -- Further, but well off to the side.
        { { tile = 401, steps = 4, x = 96, y = -240 } }
    )

    local view = walk({ direction = "e", distance = 10 })

    equal(game.walks[1].tile, 202, "the furthest spot straight on")
    equal(view.walk.hexes_that_way, 2, "hexes that way")
    equal(view.walk.stopped_by, "blocked", "stopped by")
end

function tests.a_direction_walk_prefers_the_spot_nearest_the_line()
    local game, walk = setup()
    game.reachable = {
        { tile = 501, steps = 3, x = 96, y = 24 },
        { tile = 502, steps = 3, x = 96, y = 0 },
    }

    walk({ direction = "e", distance = 3 })

    equal(game.walks[1].tile, 502, "straight east")
end

function tests.a_direction_blocked_right_away_says_so_without_walking()
    local game, walk = setup()
    -- Only west is open.
    game.reachable = row(201, 5, -32, 0)

    local view = walk({ direction = "e", distance = 5 })

    equal(#game.walks, 0, "walks")
    equal(view.walk.arrived, false, "arrived")
    equal(view.walk.hexes_that_way, 0, "hexes that way")
    equal(view.walk.stopped_by, "blocked", "stopped by")
    contains(view.note, "blocked right away", "note")
end

function tests.a_direction_walk_says_who_is_in_the_way()
    local game, walk = setup()
    -- A rat on the third hex of a corridor east; nobody walks through it.
    local corridor = row(201, 3, 32, 0)
    corridor[3].critter = 77
    game.reachable = corridor
    fo.critters = function()
        return { { id = 77, name = "Cave Rat", tile = 203, hp = 6, max_hp = 6 } }
    end

    local view = walk({ direction = "e", distance = 8 })

    equal(game.walks[1].tile, 202, "up to the rat")
    equal(view.walk.stopped_by, "occupied", "stopped by")
    contains(view.note, "Cave Rat is in the way", "note")
end

function tests.a_direction_walk_names_nobody_the_player_cant_see()
    local game, walk = setup()
    local corridor = row(201, 3, 32, 0)
    corridor[3].critter = 77
    game.reachable = corridor

    local view = walk({ direction = "e", distance = 8 })

    equal(view.walk.stopped_by, "occupied", "stopped by")
    contains(view.note, "Someone is in the way", "note")
end

function tests.a_direction_walk_settles_for_a_spot_the_game_will_path_to()
    local game, walk = setup()
    game.reachable = row(201, 6, 32, 0)
    -- The game gives up on the furthest one.
    game.paths = { [206] = 0 }

    local view = walk({ direction = "e", distance = 6 })

    equal(game.walks[1].tile, 205, "the next best spot")
    equal(view.walk.hexes_that_way, 5, "hexes that way")
end

-- Walks to a spot.

function tests.no_way_there_is_out_of_path_and_nobody_moves()
    local game, walk = setup({ path_length = 0 })

    local view = walk({ tile = 250 })

    equal(#game.walks, 0, "walks")
    equal(view.walk.arrived, false, "arrived")
    equal(view.walk.stopped_by, "out of path", "stopped by")
    contains(view.note, "no way there", "note")
end

function tests.a_way_only_someone_blocks_is_occupied()
    local game, walk = setup({ path_length = 0 })
    game.past_critters = 9

    local view = walk({ tile = 250 })

    equal(#game.walks, 0, "walks")
    equal(view.walk.stopped_by, "occupied", "stopped by")
end

function tests.a_solid_spot_is_walked_up_to_and_blocked()
    local game, walk = setup({ stop_short = 180 })
    game.blockers[250] = { solid = true }

    local view = walk({ tile = 250 })

    equal(view.walk.arrived, false, "arrived")
    equal(view.player.tile, 180, "where the player stopped")
    equal(view.walk.stopped_by, "blocked", "stopped by")
    contains(view.note, "as close as the walk gets", "note")
end

function tests.someone_standing_on_the_spot_is_occupied()
    local game, walk = setup({ stop_short = 180 })
    game.blockers[250] = { critter = 77 }

    local view = walk({ tile = 250 })

    equal(view.walk.stopped_by, "occupied", "stopped by")
end

function tests.a_walk_cut_off_on_the_way_says_what_by()
    local game, walk = setup({ stop_short = 180 })
    game.on_arrive = function()
        -- From where the player stopped, there's no way on.
        game.path_length = 0
    end

    local view = walk({ tile = 250 })

    equal(view.walk.stopped_by, "blocked", "stopped by")
end

function tests.a_walk_someone_stepped_in_front_of_is_occupied()
    local game, walk = setup({ stop_short = 180 })
    game.on_arrive = function()
        game.path_length = 0
        game.past_critters = 4
    end

    local view = walk({ tile = 250 })

    equal(view.walk.stopped_by, "occupied", "stopped by")
end

function tests.a_walk_still_going_when_the_wait_runs_out_says_so()
    local _, walk = setup({ busy_frames = 100000 })

    local view = walk({ tile = 250 })

    equal(view.walk.arrived, false, "arrived")
    equal(view.walk.stopped_by, "still moving", "stopped by")
end

function tests.the_spot_already_stood_on_is_no_walk()
    local game, walk = setup()

    local view = walk({ tile = 100 })

    equal(#game.walks, 0, "walks")
    equal(view.walk.arrived, true, "arrived")
end

function tests.a_move_the_game_refuses_is_tried_again_once_the_player_is_free()
    local game, walk = setup()
    game.refusals = 1
    game.busy_frames = 3

    local view = walk({ tile = 250 })

    equal(#game.walks, 1, "walks")
    equal(view.walk.arrived, true, "arrived")
end

function tests.a_move_the_game_keeps_refusing_is_an_error()
    local game, walk = setup()
    game.refusals = 2

    local _, err = walk({ tile = 250 })

    contains(err, "didn't take the move", "error")
    equal(#game.walks, 0, "walks")
end

-- Leaving the map.

function tests.walking_onto_an_exit_arrives_and_leaves_the_map()
    local game, walk = setup()
    game.exits = { { tile = 250, map = 0, seen = true } }
    game.on_arrive = function()
        game.world_map = true
    end

    local view = walk({ tile = 250 })

    equal(view.walk.arrived, true, "arrived")
    equal(view.walk.left_map, true, "left the map")
    equal(view.walk.stopped_by, nil, "stopped by")
end

function tests.crossing_an_exit_on_the_way_says_so()
    local game, walk = setup()
    game.on_arrive = function()
        game.map = "V13ENT2.MAP"
        game.tile = 9000
    end

    local view = walk({ tile = 250 })

    equal(view.walk.arrived, false, "arrived")
    equal(view.walk.left_map, true, "left the map")
    equal(view.walk.stopped_by, "left the map", "stopped by")
end

-- Fights.

function tests.a_fight_that_stops_the_walk_returns_on_your_turn_with_full_ap()
    local game, walk = setup({ stop_short = 180 })
    game.on_walk = function()
        -- The rat goes first.
        game.fight = rats_turn()
        game.turns = 20
    end

    local view = walk({ tile = 250 })

    equal(view.walk.stopped_by, "a fight started", "stopped by")
    equal(view.walk.arrived, false, "arrived")
    equal(view.combat.your_turn, true, "your turn")
    equal(view.combat.ap, 6, "full AP")
    contains(view.note, "stopped the walk. It's your turn", "note")
    equal(#game.walks, 1, "walked")
end

function tests.a_fight_the_agent_hasnt_seen_stops_the_walk_before_it_starts()
    local game, walk = setup()
    -- It started between calls, and it's the player's turn.
    game.fight = your_turn(6)

    local view = walk({ direction = "e", distance = 20 })

    equal(#game.walks, 0, "walks")
    equal(view.walk.stopped_by, "a fight started", "stopped by")
    equal(view.walk.arrived, false, "arrived")
    equal(view.combat.ap, 6, "full AP")
    contains(view.note, "didn't walk", "note")
end

function tests.a_fight_the_agent_hasnt_seen_waits_for_your_turn()
    local game, walk = setup()
    game.fight = rats_turn()
    game.turns = 30

    local view = walk({ tile = 250 })

    equal(#game.walks, 0, "walks")
    equal(view.walk.stopped_by, "a fight started", "stopped by")
    equal(view.combat.your_turn, true, "your turn")
    equal(view.combat.ap, 6, "full AP")
end

function tests.a_fight_that_ends_before_your_turn_says_so()
    local game, walk = setup()
    game.on_walk = function()
        game.fight = rats_turn()
    end
    local frames = 0
    game.on_frame = function()
        -- The rats run off before the player's turn comes.
        frames = frames + 1
        if frames == 30 then
            game.fight = nil
        end
    end

    local view = walk({ tile = 250 })

    equal(view.walk.stopped_by, "a fight started", "stopped by")
    contains(view.note, "over already", "note")
end

-- In a fight the agent knows about, walking spends AP.
local function known_fight(game, ap)
    game.fight = your_turn(ap)
    require("mcp.state").view()
end

function tests.a_walk_in_a_known_fight_spends_ap()
    local game, walk = setup()
    known_fight(game, 6)
    game.on_arrive = function()
        game.fight = your_turn(2)
    end

    local view = walk({ tile = 250 })

    equal(#game.walks, 1, "walked")
    equal(view.walk.arrived, true, "arrived")
    equal(view.walk.stopped_by, nil, "stopped by")
    equal(view.combat.ap, 2, "AP left")
end

function tests.a_walk_that_runs_out_of_ap_waits_for_your_next_turn()
    local game, walk = setup({ stop_short = 180 })
    known_fight(game, 6)
    game.on_arrive = function()
        -- The AP ran out, and the game passed the turn on.
        game.fight = rats_turn()
        game.turns = 25
    end

    local view = walk({ tile = 250 })

    equal(view.walk.arrived, false, "arrived")
    equal(view.walk.stopped_by, "out of AP", "stopped by")
    equal(view.combat.your_turn, true, "your turn")
    equal(view.combat.ap, 6, "full AP")
    contains(view.note, "your turn passed", "note")
end

function tests.a_walk_on_someone_elses_turn_is_an_error()
    local game, walk = setup()
    known_fight(game, 6)
    game.fight = rats_turn()

    local _, err = walk({ tile = 250 })

    contains(err, "isn't your turn", "error")
    equal(#game.walks, 0, "walks")
end

function tests.a_walk_with_no_ap_left_says_so()
    local game, walk = setup()
    known_fight(game, 0)

    local view = walk({ tile = 250 })

    equal(#game.walks, 0, "walks")
    equal(view.walk.stopped_by, "out of AP", "stopped by")
end

-- Arguments.

function tests.walking_needs_the_map()
    local _, walk = setup()
    fo.flags = function()
        return { in_game = true, inventory_screen = "inventory" }
    end

    local _, err = walk({ tile = 250 })

    contains(err, "inventory screen is up", "error")
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
    contains(direction, "n, ne, e, se, s, sw, w, nw", "bad direction")

    local _, distance = walk({ direction = "e", distance = 0 })
    contains(distance, "1 to 50", "bad distance")

    local _, off = walk({ x = -5, y = 2 })
    contains(off, "isn't on the map", "off the map")
end

return tests
