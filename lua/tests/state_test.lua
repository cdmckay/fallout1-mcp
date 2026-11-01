local support = require("tests.support")

local equal = support.equal

local tests = {}

local function fresh_state()
    package.loaded["mcp.state"] = nil
    return require("mcp.state")
end

-- A fake game with the player on tile 100 and the given flags, exits,
-- critters, fight and on-screen tiles. Tiles are numbered so that distance is
-- just the difference, and everything lies to the west.
local function fake_game(options)
    options = options or {}
    local on_screen = options.on_screen or {}
    _G.fo = {}
    support.quiet_world()

    fo.flags = function()
        return options.flags or { in_game = true }
    end
    fo.player = function()
        if options.no_player then
            return nil
        end
        return { name = "Max Stone", hp = 30, max_hp = 30, tile = 100 }
    end
    fo.omniscient = function()
        return options.omniscient or false
    end
    fo.awareness = function()
        return options.awareness or false
    end
    fo.tile_center = function(tile)
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
    end
    fo.exits = function()
        return options.exits or {}
    end
    fo.critters = function()
        return options.critters or {}
    end
    fo.combat = function()
        return options.combat
    end
    fo.tile_direction = function()
        return 4
    end
    if options.messages then
        fo.messages = options.messages
    end
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

function tests.a_registered_screen_or_inventory_screen_is_in_front_of_the_map()
    local state = fresh_state()

    equal(state.mode({ in_game = true, screen = "pipboy" }), "pipboy", "Pip-Boy over the map")
    equal(state.mode({ in_game = true, combat = true, inventory_screen = "inventory" }), "inventory", "inventory in combat")
    equal(state.mode({ in_game = true, dialog = true, inventory_screen = "barter" }), "barter", "barter inside dialog")
    equal(state.mode({ in_game = true, screen = "save", inventory_screen = "inventory" }), "save", "registry first")
    equal(state.mode({ in_game = true, movie = true, screen = "pipboy" }), "movie", "a movie from the Pip-Boy")
    equal(state.mode({ character_select = true, screen = "character_editor" }), "character_editor", "editor over select")
end

function tests.every_screen_the_engine_names_has_a_hint()
    local state = fresh_state()
    local names = {
        "inventory", "use_item_on", "loot", "barter", "pipboy", "options", "preferences",
        "skilldex", "automap", "save", "load", "elevator", "help", "character", "character_editor",
        "town_map",
    }

    for _, name in ipairs(names) do
        fake_game({ flags = { in_game = true, screen = name }, no_player = true })
        local view = state.view()
        equal(view.mode, name, "mode")
        assert(not view.hint:find("doesn't know", 1, true), "no specific hint for " .. name)
    end
end

function tests.the_movie_hint_says_how_many_escapes_skip_it()
    local state = fresh_state()
    fake_game({ flags = { movie = true }, no_player = true })

    local view = state.view()

    support.contains(view.hint, "two escapes", "the logo and the intro")
    support.contains(view.hint, "briefing after choosing a character takes one", "the briefing")
end

function tests.character_select_shows_the_premade_on_screen()
    local state = fresh_state()
    fake_game({ flags = { character_select = true }, no_player = true })
    fo.premade = function()
        return { name = "Max Stone", traits = { "Bruiser", "Heavy Handed" } }
    end

    local view = state.view()

    equal(view.mode, "character_select", "mode")
    equal(view.premade.name, "Max Stone", "premade")
    equal(view.premade.traits[1], "Bruiser", "traits")
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

function tests.an_exit_once_seen_stays_listed_until_the_map_changes()
    local state = fresh_state()
    local on_screen = { [90] = { 300, 500 } }
    fake_game({ exits = { { tile = 90, map = -1, seen = false } }, on_screen = on_screen })
    local map = { file = "V13ENT.MAP" }
    fo.player = function()
        return { tile = 100, map = map }
    end

    equal(#state.view().exits, 1, "seen on screen")

    on_screen[90] = nil
    local exits = state.view().exits
    equal(#exits, 1, "still listed off screen")
    equal(exits[1].screen, nil, "but not on screen")

    map = { file = "VAULT13.MAP" }
    equal(#state.view().exits, 0, "forgotten on a new map")
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

local RAT = {
    id = 7,
    name = "Rat",
    tile = 95,
    hidden = false,
    visible = true,
    dead = false,
    hostile = true,
    hp = 4,
    max_hp = 9,
    health = "wounded",
    hit_chance = 87,
    can_attack = true,
}

local function critter(overrides)
    local c = {}
    for k, v in pairs(RAT) do
        c[k] = v
    end
    for k, v in pairs(overrides or {}) do
        c[k] = v
    end
    return c
end

function tests.fair_play_shows_critters_on_screen_with_a_health_word_not_hp()
    local state = fresh_state()
    fake_game({
        critters = {
            critter(),
            critter({ id = 8, tile = 60, visible = false }), -- off screen
            critter({ id = 9, tile = 96, hidden = true, visible = false }), -- hidden
            critter({ id = 10, tile = 97, dead = true }), -- dead
        },
        on_screen = { [95] = { 400, 300 }, [96] = { 410, 300 }, [97] = { 420, 300 } },
    })

    local critters = state.view().critters

    equal(#critters, 1, "critters listed")
    equal(critters[1].id, 7, "the rat on screen")
    equal(critters[1].health, "wounded", "health word")
    equal(critters[1].hp, nil, "exact hp")
    equal(critters[1].distance, 5, "distance")
    equal(critters[1].hit_chance, nil, "no odds outside combat")
    equal(critters[1].hostile, nil, "no hostility outside combat")
end

-- Play test 2: rats behind the cave's rock face were on screen, but not one
-- pixel of them showed. The engine says what a player can see; fair play
-- goes by that, not by where a critter's hex is.
function tests.fair_play_leaves_out_critters_on_screen_that_nothing_of_shows()
    local state = fresh_state()
    fake_game({
        critters = { critter(), critter({ id = 8, tile = 96, visible = false }) },
        on_screen = { [95] = { 400, 300 }, [96] = { 608, 286 } },
    })

    local critters = state.view().critters

    equal(#critters, 1, "critters listed")
    equal(critters[1].id, 7, "the rat in sight")

    state = fresh_state()
    fake_game({
        omniscient = true,
        critters = { critter(), critter({ id = 8, tile = 96, visible = false }) },
        on_screen = { [95] = { 400, 300 }, [96] = { 608, 286 } },
    })
    equal(#state.view().critters, 2, "omniscient mode lists both")
end

function tests.awareness_or_omniscience_shows_exact_hp()
    local state = fresh_state()
    fake_game({ awareness = true, critters = { critter() }, on_screen = { [95] = { 400, 300 } } })
    equal(state.view().critters[1].hp, 4, "hp with awareness")

    state = fresh_state()
    fake_game({ omniscient = true, critters = { critter({ tile = 60, visible = false }) } })
    local critters = state.view().critters
    equal(#critters, 1, "off-screen critter in omniscient mode")
    equal(critters[1].max_hp, 9, "max hp in omniscient mode")
end

function tests.combat_shows_the_turn_the_attack_and_the_odds_against_each_critter()
    local state = fresh_state()
    fake_game({
        flags = { in_game = true, combat = true },
        combat = {
            turn = "Max Stone",
            can_act = true,
            animating = false,
            ap = 6,
            free_move = 0,
            attack = { weapon = "unarmed", mode = "punch", ap_cost = 3, aiming = false },
        },
        critters = {
            critter({ id = 7, tile = 95 }),
            critter({ id = 8, tile = 98, hit_chance = 40, can_attack = false, why_not = "not enough AP" }),
        },
        on_screen = { [95] = { 400, 300 }, [98] = { 430, 300 } },
    })

    local view = state.view()

    equal(view.mode, "combat", "mode")
    equal(view.combat.your_turn, true, "your turn")
    equal(view.combat.ap, 6, "ap")
    equal(view.combat.free_move_ap, nil, "no free move")
    equal(view.combat.attack.mode, "punch", "attack mode")
    equal(view.combat.attack.ap_cost, 3, "attack cost")
    equal(view.critters[1].id, 8, "nearest first")
    equal(view.critters[1].can_attack, false, "can't attack")
    equal(view.critters[1].why_not, "not enough AP", "why not")
    equal(view.critters[2].hit_chance, 87, "hit chance")
    equal(view.critters[2].hostile, true, "hostile")
end

-- Everyone's AP is 0 between turns; showing it then only looks like lost AP.
function tests.ap_is_shown_only_on_your_turn_and_the_hint_says_whose_it_is()
    local state = fresh_state()
    fake_game({
        flags = { in_game = true, combat = true },
        combat = { turn = "Cave Rat", can_act = false, animating = false, ap = 0, max_ap = 6, free_move = 0 },
    })

    local view = state.view()

    equal(view.combat.your_turn, false, "your turn")
    equal(view.combat.ap, nil, "ap")
    equal(view.combat.max_ap, 6, "max ap")
    support.contains(view.hint, "Cave Rat's turn", "hint")
    support.contains(view.hint, "refills to 6", "hint")
end

function tests.each_message_reaches_the_agent_once()
    local state = fresh_state()
    local log = { { seq = 1, text = "old news" } }
    fake_game({
        messages = function(after)
            local lines = {}
            for _, line in ipairs(log) do
                if line.seq > after then
                    lines[#lines + 1] = line
                end
            end
            return lines, log[#log].seq
        end,
    })

    -- What was printed before the first view isn't replayed.
    equal(state.view().messages, nil, "first view")

    log[#log + 1] = { seq = 2, text = "You were hit for 4 hit points." }
    log[#log + 1] = { seq = 3, text = "You hit the Rat for 6 hit points." }
    local messages = state.view().messages
    equal(#messages, 2, "new lines")
    equal(messages[2], "You hit the Rat for 6 hit points.", "order")

    equal(state.view().messages, nil, "nothing new")
end

function tests.exits_appear_only_while_exploring_or_fighting()
    local state = fresh_state()
    fake_game({ flags = { in_game = true, dialog = true }, exits = { { tile = 90, map = -1, seen = true } } })

    equal(state.view().exits, nil, "exits during dialog")
end

return tests
