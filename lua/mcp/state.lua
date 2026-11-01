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

local DIRECTION_NAMES = { [0] = "ne", "e", "se", "sw", "w", "nw" }

-- The ways off this map. Exit grids are invisible in play, but a player sees
-- where a path leaves the map, so in fair play an exit counts once its tile is
-- on screen or has been seen; omniscient mode lists them all. Each
-- destination is listed once, at its nearest tile, nearest first.
function state.exits(player)
    local omniscient = fo.omniscient()
    local nearest = {}

    for _, exit in ipairs(fo.exits()) do
        if omniscient or exit.seen or fo.tile_center(exit.tile) ~= nil then
            local distance = fo.tile_distance(player.tile, exit.tile)
            local best = nearest[exit.map]
            if best == nil or distance < best.distance then
                nearest[exit.map] = { map = exit.map, tile = exit.tile, distance = distance }
            end
        end
    end

    local list = {}
    for _, exit in pairs(nearest) do
        list[#list + 1] = exit
    end
    table.sort(list, function(a, b)
        return a.distance < b.distance
    end)

    for i, exit in ipairs(list) do
        local x, y = fo.tile_center(exit.tile)
        list[i] = {
            to = fo.map_name(exit.map),
            tile = exit.tile,
            distance = exit.distance,
            direction = DIRECTION_NAMES[fo.tile_direction(player.tile, exit.tile)],
            screen = x ~= nil and { x = x, y = y } or nil,
        }
    end

    return list
end

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
    local player = fo.player()

    -- Where the player is on the screenshot, to aim screen-point moves from.
    if player ~= nil and mode ~= "world_map" then
        local x, y = fo.tile_center(player.tile)
        if x ~= nil then
            player.screen = { x = x, y = y }
        end
    end

    local view = {
        mode = mode,
        hint = HINTS[mode],
        player = player,
    }

    if player ~= nil and (mode == "map" or mode == "combat") then
        view.exits = state.exits(player)
    end

    return view
end

return state
