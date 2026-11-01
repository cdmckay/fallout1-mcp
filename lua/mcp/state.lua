-- The state view: which screen the agent is on, what it can do there, and
-- what a player would see from there: their character, the critters and exits
-- around them, a fight's turn and odds, and the message window's new lines.
-- See "Decision views" in docs/mcp-design.md.

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

-- What a player sees they can do on each screen.
local HINTS = {
    movie = "A movie is playing. Press escape to skip it.",
    main_menu = "Main menu. Keys: n new game, l load game, i intro, c credits, e exit.",
    character_select = "Choosing a character. Keys: left and right browse the premade characters, t takes this one, m modifies it, c creates a new one, b goes back.",
    character_editor = "Character editor. Keys: return when done, escape to cancel.",
    world_map = "World map.",
    dialog = "In conversation. Keys 1 to 9 choose a reply.",
    combat = "In combat. attack a critter by id, or end_turn to pass. Keys: n cycles the attack mode, b swaps hands.",
    map = "Exploring the map.",
    other = "A screen the state view doesn't know yet. Use look to see it.",
}

local DIRECTION_NAMES = { [0] = "ne", "e", "se", "sw", "w", "nw" }

local function by_distance(a, b)
    return a.distance < b.distance
end

local function screen_point(tile)
    local x, y = fo.tile_center(tile)
    if x == nil then
        return nil
    end
    return { x = x, y = y }
end

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
    table.sort(list, by_distance)

    for i, exit in ipairs(list) do
        list[i] = {
            to = fo.map_name(exit.map),
            tile = exit.tile,
            distance = exit.distance,
            direction = DIRECTION_NAMES[fo.tile_direction(player.tile, exit.tile)],
            screen = screen_point(exit.tile),
        }
    end

    return list
end

-- The living critters around the player, nearest first. In fair play that's
-- those drawn on screen, with health as the examine text gives it: a word, or
-- exact HP with the Awareness perk. Omniscient mode lists every critter on
-- the elevation with exact HP. In combat each also carries the player's odds
-- against it with the selected attack: the hit chance the game shows on
-- hover, and whether the attack is possible now.
function state.critters(player, in_combat)
    local omniscient = fo.omniscient()
    local exact_hp = omniscient or fo.awareness()
    local list = {}

    for _, critter in ipairs(fo.critters()) do
        local screen = screen_point(critter.tile)
        local visible = not critter.hidden and screen ~= nil

        if not critter.dead and (visible or omniscient) then
            local entry = {
                id = critter.id,
                name = critter.name,
                distance = fo.tile_distance(player.tile, critter.tile),
                direction = DIRECTION_NAMES[fo.tile_direction(player.tile, critter.tile)],
                health = critter.health,
                knocked_down = critter.knocked_down or nil,
                crippled = critter.crippled or nil,
                screen = screen,
            }

            if exact_hp then
                entry.hp = critter.hp
                entry.max_hp = critter.max_hp
            end

            if in_combat then
                entry.hostile = critter.hostile
                entry.hit_chance = critter.hit_chance
                entry.can_attack = critter.can_attack
                entry.why_not = critter.why_not
            end

            list[#list + 1] = entry
        end
    end

    table.sort(list, by_distance)
    return list
end

-- The fight from the player's side: whose turn, AP, and the selected attack.
function state.combat()
    local combat = fo.combat()
    if combat == nil then
        return nil
    end

    local view = {
        your_turn = combat.can_act,
        turn = combat.turn,
        ap = combat.ap,
        free_move_ap = combat.free_move > 0 and combat.free_move or nil,
    }

    if combat.attack ~= nil then
        view.attack = {
            weapon = combat.attack.weapon,
            mode = combat.attack.mode,
            ap_cost = combat.attack.ap_cost,
            aimed = combat.attack.aiming or nil,
            ammo = combat.attack.ammo,
            ammo_capacity = combat.attack.ammo_capacity,
        }
    end

    return view
end

-- The message window's lines the agent hasn't been given yet. Each view
-- hands over what's new, so every line reaches the agent once. A fresh Lua
-- state starts from the present rather than replaying history.
local message_cursor = nil

function state.new_messages()
    if message_cursor == nil then
        local _, latest = fo.messages(math.maxinteger)
        message_cursor = latest
    end

    local lines, latest = fo.messages(message_cursor)
    message_cursor = latest

    local texts = {}
    for i, line in ipairs(lines) do
        texts[i] = line.text
    end
    return texts
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
        player.screen = screen_point(player.tile)
    end

    local view = {
        mode = mode,
        hint = HINTS[mode],
        player = player,
    }

    if mode == "combat" then
        view.combat = state.combat()
    end

    if player ~= nil and (mode == "map" or mode == "combat") then
        view.equipped = fo.equipped()
        view.critters = state.critters(player, mode == "combat")
        view.exits = state.exits(player)
    end

    local messages = state.new_messages()
    if #messages > 0 then
        view.messages = messages
    end

    return view
end

return state
