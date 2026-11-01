-- The state view: which screen the agent is on, what it can do there, and
-- what a player would see of their character. See "Decision views" in
-- docs/mcp-design.md; this is the first, minimal form.

local state = {}

-- Several of the engine's flags can be set at once: the editor opens over
-- character select, dialog and combat happen during a game, the world map
-- belongs to a game. The first flag set, top to bottom, is the screen in front.
local SCREENS = {
    { flag = "movie", mode = "movie" },
    { flag = "main_menu", mode = "main_menu" },
    { flag = "character_editor", mode = "character_editor" },
    { flag = "character_select", mode = "character_select" },
    { flag = "world_map", mode = "world_map" },
    { flag = "dialog", mode = "dialog" },
    { flag = "combat", mode = "combat" },
    { flag = "in_game", mode = "map" },
}

-- What a player sees they can do on each screen, as the keys the game
-- accepts. Every one of these works with the `key` tool.
local HINTS = {
    movie = "A movie is playing. Press escape to skip it.",
    main_menu = "Main menu. Keys: n new game, l load game, i intro, c credits, e exit.",
    character_select = "Choosing a character. Keys: left and right browse the premade characters, t takes this one, m modifies it, c creates a new one, b goes back.",
    character_editor = "Character editor. Keys: return when done, escape to cancel.",
    world_map = "World map.",
    dialog = "In conversation. Keys 1 to 9 choose a reply.",
    combat = "In combat. Space ends your turn.",
    map = "Exploring the map.",
    other = "A screen the state view doesn't know yet. Use look to see it.",
}

function state.mode(flags)
    for _, screen in ipairs(SCREENS) do
        if flags[screen.flag] then
            return screen.mode
        end
    end
    return "other"
end

function state.view()
    local mode = state.mode(fo.flags())
    return {
        mode = mode,
        hint = HINTS[mode],
        player = fo.player(),
    }
end

return state
