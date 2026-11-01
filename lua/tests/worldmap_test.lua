local json = require("lib.dkjson")
local support = require("tests.support")

local equal, contains = support.equal, support.contains

local tests = {}

local TRAVEL_CODE = 0x7100
local ENTER_CODE = 0x7101
local TOGGLE = 512
local PLACE = 514

-- Pixels a trip covers each frame, and game time (tenths of a second) each
-- frame of it takes.
local STEP = 10
local TICKS_PER_FRAME = 3600

-- Where each town's button heads: the middle of its square.
local TOWNS = {
    { id = 0, name = "Vault 13", x = 825, y = 75, places = { "Cavern Entrance" } },
    { id = 1, name = "Vault 15", x = 1275, y = 75, places = { "Entrance", "Shacks" } },
    { id = 2, name = "Shady Sands", x = 1075, y = 75, places = { "West" } },
}

local function town_at(x, y)
    for _, town in ipairs(TOWNS) do
        if town.x // 50 == x // 50 and town.y // 50 == y // 50 then
            return town
        end
    end
    return nil
end

-- A fake world map and town map. The player starts at Vault 13 on the world
-- map, knowing Vault 13 and Vault 15. The maps read one injected code a
-- frame, the way the real ones do, and a trip moves STEP pixels a frame and
-- stops a pixel short of a point, as the real line-stepping does. Options:
--   at            {x, y} to start at
--   screen        "world_map" (default) or "town_map"
--   showing       the town the town map shows, if not the one the player's in
--   blocked_after frames before impassable ground stops a trip
--   encounter_after, exit
--                 frames before the world map closes under a trip, and how
--                 (fo.world_map_exit)
--   endless       the trip never gets anywhere
local function setup(options)
    options = options or {}
    local core, engine = support.new()

    local start = options.at or { TOWNS[1].x, TOWNS[1].y }
    local game = {
        screen = options.screen or "world_map",
        x = start[1],
        y = start[2],
        moving = false,
        known = { [0] = true, [1] = true },
        visited = { [0] = true, [1] = true },
        town_map = options.showing or town_at(start[1], start[2]),
        time = 0,
        trip_frames = 0,
        exit = nil,
        pending = nil,
        keys = {},
    }

    local function set_off(x, y, exact)
        game.target = { x = x, y = y, exact = exact }
        game.moving = true
        game.trip_frames = 0
    end

    local function open_map(name)
        game.screen = "map"
        game.entered = name
    end

    local function read(code)
        game.keys[#game.keys + 1] = code
        if game.screen == "world_map" then
            if code >= 500 and code < 512 and game.known[code - 500] then
                local town = TOWNS[code - 500 + 1]
                set_off(town.x, town.y, true)
            elseif code == TOGGLE then
                game.screen = "town_map"
                game.town_map = town_at(game.x, game.y) or TOWNS[1]
            elseif code == TRAVEL_CODE then
                set_off(game.travel_x, game.travel_y, false)
            elseif code == ENTER_CODE and not game.moving then
                local town = town_at(game.x, game.y)
                if town == nil then
                    open_map("Desert")
                elseif game.visited[town.id] then
                    game.screen = "town_map"
                    game.town_map = town
                else
                    open_map(town.places[1])
                end
            end
        elseif game.screen == "town_map" then
            local town = game.town_map
            if code == TOGGLE then
                game.screen = "world_map"
            elseif code >= PLACE and code < PLACE + #town.places then
                if town_at(game.x, game.y) == town then
                    open_map(town.places[code - PLACE + 1])
                else
                    game.screen = "world_map"
                    set_off(town.x, town.y, true)
                end
            end
        end
    end

    local function move()
        game.trip_frames = game.trip_frames + 1
        game.time = game.time + TICKS_PER_FRAME

        if options.encounter_after and game.trip_frames >= options.encounter_after then
            game.moving = false
            game.exit = options.exit or "encounter"
            open_map("Desert encounter")
            return
        end
        if options.blocked_after and game.trip_frames >= options.blocked_after then
            game.moving = false
            return
        end

        if options.endless then
            return
        end

        local target = game.target
        local step = STEP
        local dx, dy = target.x - game.x, target.y - game.y
        local distance = math.max(math.abs(dx), math.abs(dy))
        if distance <= step then
            game.x = target.x
            -- The real map can stop a pixel short of a point.
            game.y = target.exact and target.y or target.y - 1
            game.moving = false
            return
        end
        game.x = game.x + math.floor(dx * step / distance)
        game.y = game.y + math.floor(dy * step / distance)
    end

    fo.flags = function()
        local flags = { in_game = true, world_map = game.screen ~= "map" }
        if game.screen == "town_map" then
            flags.screen = "town_map"
        end
        return flags
    end
    fo.player = function()
        return {
            name = "Max Stone",
            tile = 20000,
            elevation = 0,
            map = { file = "", name = "Vault 13" },
            date = { year = 2161, month = 12, day = 5, time = "7:21" },
        }
    end
    fo.world_map = function()
        if game.screen == "map" then
            return nil
        end
        local town = town_at(game.x, game.y)
        local raw = {
            x = game.x,
            y = game.y,
            moving = game.moving,
            can_enter = not game.moving,
            terrain = town and "city" or "desert",
            here = town and town.name or "Desert",
            town = town and town.id or nil,
            known = {},
        }
        if game.moving then
            raw.target = { x = game.target.x, y = game.target.y }
        end
        for _, known in ipairs(TOWNS) do
            if game.known[known.id] then
                raw.known[#raw.known + 1] = { id = known.id, name = known.name, x = known.x, y = known.y }
            end
        end
        if game.screen == "town_map" then
            raw.town_map = { town = game.town_map.id, name = game.town_map.name, places = game.town_map.places }
        end
        return raw
    end
    fo.world_map_exit = function()
        return game.exit
    end
    fo.game_time = function()
        return game.time
    end
    fo.inject = function(code)
        game.pending = code
        return true
    end
    fo.input_pending = function()
        return game.pending ~= nil
    end
    fo.world_map_travel = function(x, y)
        game.travel_x, game.travel_y = x, y
        game.pending = TRAVEL_CODE
        return true
    end
    fo.world_map_enter = function()
        game.pending = ENTER_CODE
        return true
    end

    local frames = engine.frames
    engine.frames = function(n)
        for _ = 1, n or 1 do
            if game.pending ~= nil then
                local code = game.pending
                game.pending = nil
                read(code)
            elseif game.moving and game.screen == "world_map" then
                move()
            end
            frames(1)
        end
    end

    require("tools.worldmap")(core)

    -- Calls a tool and runs frames until it replies (at most `limit`).
    -- Returns the view or nil and the error, and records in game.replied_at
    -- whether the player was still moving when it replied.
    local function call(tool, args, limit)
        engine.request({ id = 1, op = "call", tool = tool, args = args or {} })
        local replies
        for _ = 1, limit or 2000 do
            engine.frames(1)
            replies = engine.replies()
            if #replies > 0 then
                break
            end
        end
        assert(#replies == 1, "no reply")
        game.moving_at_reply = game.moving
        local reply = replies[1]
        if reply.error then
            return nil, reply.error.message
        end
        return (json.decode(reply.result.content[1].text))
    end

    return game, call
end

local function find(list, name)
    for _, item in ipairs(list) do
        if item.name == name then
            return item
        end
    end
    return nil
end

-- The view

function tests.the_view_lists_known_places_nearest_first_with_distances()
    setup({ at = { 875, 75 } })
    local view = require("mcp.state").view()

    equal(view.mode, "world_map", "mode")
    equal(view.world_map.here, "Desert", "here")
    equal(view.world_map.position.x, 17.5, "x in squares")
    equal(view.world_map.position.y, 1.5, "y in squares")
    equal(view.world_map.can_enter, true, "can enter")
    equal(view.world_map.places[1].name, "Vault 13", "nearest first")
    equal(view.world_map.places[1].distance, 1, "a square away")
    equal(view.world_map.places[1].direction, "w", "to the west")
    equal(view.world_map.places[2].name, "Vault 15", "then Vault 15")
    equal(view.world_map.places[2].distance, 8, "eight squares away")
    equal(view.world_map.places[2].direction, "e", "to the east")
    equal(find(view.world_map.places, "Shady Sands"), nil, "only places the map names")
end

function tests.the_place_you_are_in_is_marked_here()
    setup()
    local view = require("mcp.state").view()

    local vault = find(view.world_map.places, "Vault 13")
    equal(vault.here, true, "here")
    equal(vault.distance, 0, "no distance")
    equal(vault.direction, nil, "no direction")
    equal(view.world_map.here, "Vault 13", "the marker's name")
end

function tests.directions_follow_the_compass_with_north_up()
    local worldmap = require("mcp.worldmap")

    equal(worldmap.direction(100, 100, 100, 50), "n", "north")
    equal(worldmap.direction(100, 100, 150, 50), "ne", "north-east")
    equal(worldmap.direction(100, 100, 100, 150), "s", "south")
    equal(worldmap.direction(100, 100, 50, 150), "sw", "south-west")
    equal(worldmap.direction(100, 100, 0, 110), "w", "west, a little south")
    equal(worldmap.direction(100, 100, 100, 100), nil, "nowhere")
end

function tests.a_trip_under_way_shows_where_it_heads()
    local game = setup()
    game.moving = true
    game.target = { x = 1275, y = 75 }

    local view = require("mcp.state").view()

    equal(view.world_map.travelling_to.x, 25.5, "x")
    equal(view.world_map.travelling_to.place, "Vault 15", "the place there")
    equal(view.world_map.can_enter, nil, "can't enter while moving")
end

function tests.on_the_world_map_the_player_is_on_no_map()
    setup()
    local view = require("mcp.state").view()

    equal(view.player.name, "Max Stone", "player")
    equal(view.player.map, nil, "no map")
    equal(view.player.tile, nil, "no tile")
    equal(view.player.elevation, nil, "no elevation")
    equal(view.player.date.day, 5, "the date stays")
end

function tests.the_world_map_hint_names_the_tools_and_keys()
    setup()
    local view = require("mcp.state").view()

    contains(view.hint, "travel", "travel")
    contains(view.hint, "enter", "enter")
    contains(view.hint, "arrows scroll", "keys")
    contains(view.hint, "press 512", "the town map's button")
end

function tests.the_town_map_lists_its_places()
    setup({ screen = "town_map", showing = TOWNS[2] })
    local view = require("mcp.state").view()

    equal(view.mode, "town_map", "mode")
    equal(view.town_map.town, "Vault 15", "town")
    equal(view.town_map.places[2], "Shacks", "places")
    equal(view.world_map.can_enter, nil, "enter picks a place here")
    contains(view.hint, "town_map.places", "hint")
    equal(view.world_map.here, "Vault 13", "where the player is")
end

-- travel

function tests.travel_to_a_place_presses_its_button_and_waits_for_arrival()
    local game, call = setup()

    local view = call("travel", { to = "vault 15" })

    equal(game.keys[1], 501, "Vault 15's button")
    equal(game.moving_at_reply, false, "replied once the trip was over")
    equal(view.travel.to, "Vault 15", "to")
    equal(view.travel.result, "arrived", "result")
    equal(view.travel.hours, 45 * TICKS_PER_FRAME / 36000, "hours on the road")
    equal(view.world_map.here, "Vault 15", "here")
    equal(view.note, nil, "no note")
end

function tests.travel_to_a_point_goes_there_in_squares()
    local game, call = setup()

    local view = call("travel", { x = 18, y = 3.5 })

    equal(game.keys[1], TRAVEL_CODE, "the travel code")
    equal(game.travel_x, 900, "x in pixels")
    equal(game.travel_y, 175, "y in pixels")
    equal(view.travel.result, "arrived", "a pixel short still arrives")
    equal(view.travel.to.x, 18, "to x")
    equal(view.travel.to.y, 3.5, "to y")
end

function tests.impassable_ground_stops_a_trip_short()
    local _, call = setup({ blocked_after = 5 })

    local view = call("travel", { x = 25, y = 10 })

    equal(view.travel.result, "blocked", "result")
    contains(view.note, "impassable", "note")
end

function tests.an_encounter_stops_a_trip_on_its_map()
    local _, call = setup({ encounter_after = 8 })

    local view = call("travel", { to = "Vault 15" })

    equal(view.mode, "map", "on the encounter's map")
    equal(view.travel.result, "encounter", "result")
    contains(view.note, "encounter", "note")
    equal(view.world_map, nil, "no world map")
end

function tests.an_event_on_the_way_is_an_interruption()
    local _, call = setup({ encounter_after = 3, exit = "terrain" })

    local view = call("travel", { to = "Vault 15" })

    equal(view.travel.result, "interrupted", "result")
end

function tests.a_long_trip_returns_while_still_under_way()
    local game, call = setup({ endless = true })

    local view = call("travel", { x = 1, y = 29 }, 20000)

    equal(view.travel.result, "still_travelling", "result")
    equal(game.moving, true, "still moving")
    contains(view.note, "travel to the same place again", "note")
end

function tests.travel_to_where_you_are_goes_nowhere()
    local game, call = setup()

    local view = call("travel", { to = "Vault 13" })

    equal(#game.keys, 0, "nothing pressed")
    equal(view.travel.result, "arrived", "result")
    contains(view.note, "enter goes in", "note")
end

function tests.travel_from_the_town_map_goes_to_the_world_map_first()
    local game, call = setup({ screen = "town_map", showing = TOWNS[2] })

    local view = call("travel", { to = "Vault 15" })

    equal(game.keys[1], TOGGLE, "the world map's button")
    equal(game.keys[2], 501, "then Vault 15's")
    equal(view.travel.result, "arrived", "result")
end

function tests.travel_only_goes_to_places_you_know()
    local game, call = setup()

    local _, err = call("travel", { to = "Shady Sands" })

    contains(err, "Vault 13, Vault 15", "lists the known places")
    equal(#game.keys, 0, "nothing pressed")
end

function tests.travel_needs_the_world_map()
    local game, call = setup()
    game.screen = "map"

    local _, err = call("travel", { to = "Vault 15" })

    contains(err, "from the world map, not from map", "error")
end

function tests.travel_needs_a_place_or_a_point()
    local _, call = setup()

    local _, both = call("travel", { to = "Vault 15", x = 3, y = 4 })
    local _, half = call("travel", { x = 3 })
    local _, off = call("travel", { x = 30, y = 4 })

    contains(both, "either", "both")
    contains(half, "both x and y", "half a point")
    contains(off, "isn't on the world map", "off the map")
end

-- enter

function tests.enter_on_open_ground_loads_its_map()
    local game, call = setup({ at = { 975, 275 } })

    local view = call("enter")

    equal(game.keys[1], ENTER_CODE, "the enter code")
    equal(view.mode, "map", "mode")
    equal(view.entered, "Desert", "entered")
end

function tests.enter_a_town_with_one_place_known_goes_straight_in()
    local game, call = setup()

    local view = call("enter")

    equal(game.keys[1], ENTER_CODE, "enter")
    equal(game.keys[2], PLACE, "its one place")
    equal(view.mode, "map", "mode")
    equal(view.entered, "Cavern Entrance", "entered")
end

function tests.enter_a_town_with_several_places_asks_which()
    local game, call = setup({ at = { 1275, 75 } })

    local view = call("enter")

    equal(#game.keys, 1, "only enter")
    equal(view.mode, "town_map", "mode")
    equal(view.town_map.places[1], "Entrance", "places")
    contains(view.note, "Which part of Vault 15", "note")
end

function tests.enter_picks_the_place_named()
    local game, call = setup({ at = { 1275, 75 } })

    local view = call("enter", { place = "shacks" })

    equal(game.keys[2], PLACE + 1, "Shacks' button")
    equal(view.entered, "Shacks", "entered")
end

function tests.enter_on_the_town_map_takes_the_place_named()
    local game, call = setup({ at = { 1275, 75 }, screen = "town_map" })

    local view = call("enter", { place = "Entrance" })

    equal(game.keys[1], PLACE, "Entrance's button")
    equal(view.entered, "Entrance", "entered")
end

function tests.a_place_in_another_town_sets_off_there()
    local game, call = setup({ screen = "town_map", showing = TOWNS[2] })

    local view = call("enter", { place = "Shacks" })

    equal(game.keys[1], PLACE + 1, "Shacks' button")
    equal(view.mode, "world_map", "back on the world map")
    equal(view.travel.to, "Vault 15", "to")
    equal(view.travel.result, "arrived", "result")
    contains(view.note, "enter again", "note")
end

function tests.enter_names_the_places_when_none_matches()
    local _, call = setup({ at = { 1275, 75 }, screen = "town_map" })

    local _, err = call("enter", { place = "Casino" })

    contains(err, "Entrance, Shacks", "places")
end

function tests.enter_waits_for_a_trip_to_end()
    local game, call = setup()
    game.moving = true
    game.target = { x = 1275, y = 75, exact = true }
    game.screen = "world_map"

    local _, err = call("enter")

    contains(err, "still travelling", "error")
end

return tests
