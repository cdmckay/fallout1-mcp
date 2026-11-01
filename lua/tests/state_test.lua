local support = require("tests.support")

local equal = support.equal

local tests = {}

local function fresh_state()
    package.loaded["mcp.state"] = nil
    return require("mcp.state")
end

-- A fake game with the player on tile 100 and the given flags, exits and
-- on-screen tiles. Tiles are numbered so that distance is just the
-- difference, and every exit lies to the west.
local function fake_game(options)
    options = options or {}
    local on_screen = options.on_screen or {}
    _G.fo = {
        flags = function()
            return options.flags or { in_game = true }
        end,
        player = function()
            if options.no_player then
                return nil
            end
            return { name = "Max Stone", hp = 30, max_hp = 30, tile = 100 }
        end,
        omniscient = function()
            return options.omniscient or false
        end,
        tile_center = function(tile)
            if tile == 100 then
                if options.player_screen then
                    return table.unpack(options.player_screen)
                end
                return nil
            end
            local point = on_screen[tile]
            if point then
                return point[1], point[2]
            end
            return nil
        end,
        exits = function()
            return options.exits or {}
        end,
        tile_distance = function(a, b)
            return math.abs(a - b)
        end,
        tile_direction = function()
            return 4
        end,
        map_name = function(index)
            return index <= 0 and "the world map" or ("map " .. index)
        end,
    }
end

function tests.no_flags_is_an_unknown_screen()
    local state = fresh_state()
    equal(state.mode({}), "other", "mode")
end

function tests.each_flag_on_its_own_names_its_screen()
    local state = fresh_state()
    local cases = {
        movie = "movie",
        main_menu = "main_menu",
        character_select = "character_select",
        character_editor = "character_editor",
        world_map = "world_map",
        dialog = "dialog",
        combat = "combat",
        in_game = "map",
    }
    for flag, mode in pairs(cases) do
        equal(state.mode({ [flag] = true }), mode, flag)
    end
end

function tests.the_screen_in_front_wins()
    local state = fresh_state()

    equal(state.mode({ character_select = true, character_editor = true }), "character_editor", "editor over select")
    equal(state.mode({ in_game = true, combat = true }), "combat", "combat in a game")
    equal(state.mode({ in_game = true, combat = true, dialog = true }), "dialog", "dialog during combat")
    equal(state.mode({ in_game = true, world_map = true }), "world_map", "world map in a game")
    equal(state.mode({ in_game = true, movie = true }), "movie", "movie in a game")
end

function tests.the_view_has_a_hint_for_every_mode()
    local state = fresh_state()

    for _, flag in ipairs({ "movie", "main_menu", "character_select", "character_editor", "world_map", "dialog", "combat", "in_game", "none" }) do
        fake_game({ flags = { [flag] = true }, no_player = true })
        local view = state.view()
        assert(type(view.hint) == "string" and #view.hint > 0, "no hint for " .. view.mode)
    end
end

function tests.the_view_includes_the_player_and_where_they_are_on_screen()
    local state = fresh_state()
    fake_game({ player_screen = { 512, 300 } })

    local view = state.view()

    equal(view.mode, "map", "mode")
    equal(view.player.name, "Max Stone", "player")
    equal(view.player.screen.x, 512, "screen x")
    equal(view.player.screen.y, 300, "screen y")
end

function tests.an_off_screen_player_has_no_screen_position()
    local state = fresh_state()
    fake_game()

    equal(state.view().player.screen, nil, "screen")
end

function tests.fair_play_lists_exits_on_screen_or_seen_once_per_destination_nearest_first()
    local state = fresh_state()
    fake_game({
        exits = {
            -- The world map: three tiles of one grid, one of them on screen.
            { tile = 90, map = -1, seen = false },
            { tile = 80, map = -1, seen = false },
            { tile = 95, map = -1, seen = false },
            -- Another map, seen earlier but off screen now.
            { tile = 60, map = 7, seen = true },
            -- A third, never seen and off screen: a player wouldn't know it.
            { tile = 99, map = 9, seen = false },
        },
        on_screen = { [90] = { 300, 500 }, [80] = { 250, 520 } },
    })

    local exits = state.view().exits

    equal(#exits, 2, "exits listed")
    equal(exits[1].to, "the world map", "nearest first")
    equal(exits[1].tile, 90, "the nearest visible tile of that exit")
    equal(exits[1].distance, 10, "distance")
    equal(exits[1].direction, "w", "direction")
    equal(exits[1].screen.x, 300, "screen position")
    equal(exits[2].to, "map 7", "seen exit")
    equal(exits[2].screen, nil, "off screen")
end

function tests.omniscient_mode_lists_every_exit()
    local state = fresh_state()
    fake_game({
        omniscient = true,
        exits = { { tile = 99, map = 9, seen = false }, { tile = 60, map = 7, seen = false } },
    })

    local exits = state.view().exits

    equal(#exits, 2, "exits listed")
    equal(exits[1].to, "map 9", "nearest first")
end

function tests.exits_appear_only_while_exploring_or_fighting()
    local state = fresh_state()
    fake_game({ flags = { in_game = true, dialog = true }, exits = { { tile = 90, map = -1, seen = true } } })

    equal(state.view().exits, nil, "exits during dialog")
end

return tests
