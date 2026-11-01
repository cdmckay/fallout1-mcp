local support = require("tests.support")

local equal = support.equal

local tests = {}

local function fresh_state()
    package.loaded["mcp.state"] = nil
    return require("mcp.state")
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
    local flags = {}
    _G.fo = {
        flags = function()
            return flags
        end,
        player = function()
            return nil
        end,
    }

    for _, flag in ipairs({ "movie", "main_menu", "character_select", "character_editor", "world_map", "dialog", "combat", "in_game", "none" }) do
        flags = { [flag] = true }
        local view = state.view()
        assert(type(view.hint) == "string" and #view.hint > 0, "no hint for " .. view.mode)
    end
end

function tests.the_view_includes_the_player_during_a_game()
    local state = fresh_state()
    _G.fo = {
        flags = function()
            return { in_game = true }
        end,
        player = function()
            return { name = "Max Stone", hp = 30, max_hp = 30, tile = 20100 }
        end,
    }

    local view = state.view()

    equal(view.mode, "map", "mode")
    equal(view.player.name, "Max Stone", "player")
end

return tests
