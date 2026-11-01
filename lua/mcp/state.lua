-- The state view: which screen the agent is on, what it can do there, and
-- what a player would see from there: their character, the critters and exits
-- around them, a fight's turn and odds, and the message window's new lines.
-- See "Decision views" in docs/mcp-design.md.

local character = require("mcp.character")

local state = {}

-- Several of the engine's flags can be set at once: the editor opens over
-- character select, dialog and combat happen during a game, the world map
-- belongs to a game. After a movie and the main menu, the screen in front is
-- the innermost one the engine's screen registry names (Pip-Boy, options,
-- save, help, ...), then an open inventory-family screen (inventory, loot,
-- barter, ...), then the first of these flags that's set.
local SCREENS = {
    { flag = "character_editor", mode = "character_editor" },
    { flag = "character_select", mode = "character_select" },
    { flag = "world_map", mode = "world_map" },
    { flag = "dialog", mode = "dialog" },
    { flag = "combat", mode = "combat" },
    { flag = "in_game", mode = "map" },
}

-- What a player sees they can do on each screen, from the screen-by-screen
-- audit in docs/mcp-design.md. Keys work with `key`, codes with `press`.
local HINTS = {
    movie = "A movie is playing. Press escape to skip it. The intro is two movies in a row.",
    main_menu = "Main menu. Keys: n new game, l load game, i intro, c credits, e exit. (Escape here would quit the game, so key skips it.)",
    character_select = "Choosing a character; `premade` shows the one on screen. Keys: left and right browse the premade characters, t takes this one, m modifies it, c creates a new one, b goes back.",
    character_editor = "Character editor. Keys: return when done, escape to cancel.",
    character = "Character screen; `character` below is the sheet. raise_skill spends skill points here. Keys: return closes it keeping changes, escape closes it undoing them.",
    perk_choice = "Choosing a perk; `character.choice` lists the options. choose_perk takes one by name. Escape puts the perk off until the character screen next opens (in a follow-up question, escape gives the perk up).",
    world_map = "World map.",
    dialog = "In conversation. Keys 1 to 9 choose a reply.",
    combat = "In combat. attack a critter by id, or end_turn to pass. Keys: n cycles the attack mode, b swaps hands.",
    map = "Exploring the map.",
    inventory = "Inventory screen. You don't need it: the inventory, equip, unequip, reload and use_item tools work from the map. Escape closes it.",
    use_item_on = "Choosing an item to use on something; this still needs the mouse. Escape cancels.",
    loot = "Looting. Keys: A (capital) takes everything, escape closes. Taking single items isn't supported yet.",
    barter = "Bartering. Keys: m offers the deal on the table, t goes back to talking, escape leaves. Putting items on the table isn't supported yet.",
    pipboy = "Pip-Boy. Escape closes it. press codes: 500 status, 501 automaps, 502 archives, 504 alarm clock (to rest).",
    options = "Options. Keys: s save, l load, p preferences, d or escape done, e quit to the main menu.",
    preferences = "Preferences. Return keeps changes, escape cancels; changing a setting still needs the mouse.",
    skilldex = "Skilldex. Escape cancels; using a skill from here isn't supported yet.",
    automap = "Automap. Tab or escape closes it; s toggles the scanner, h and l the detail.",
    save = "Saving. Up and down pick a slot, return saves (then type a description and press return), escape cancels.",
    load = "Loading. Up and down pick a slot, return loads it, escape cancels.",
    elevator = "Elevator. press 500 for the first floor, 501 for the second, and so on; escape cancels.",
    help = "Help screen. Any key closes it.",
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

-- The exit tiles the player has seen on the current map, by destination, so
-- an exit stays listed once seen, as a player remembers where a path left
-- the map. Forgotten on leaving the map.
local known_exits = { map = nil, by_destination = {} }

-- Records the exits a player can see from here: in fair play those whose
-- tiles are on screen or have been seen; omniscient mode, all of them.
function state.see_exits(player)
    local map = player.map and player.map.file or nil
    if known_exits.map ~= map then
        known_exits = { map = map, by_destination = {} }
    end

    local omniscient = fo.omniscient()
    for _, exit in ipairs(fo.exits()) do
        if omniscient or exit.seen or fo.tile_center(exit.tile) ~= nil then
            local tiles = known_exits.by_destination[exit.map]
            if tiles == nil then
                tiles = {}
                known_exits.by_destination[exit.map] = tiles
            end
            tiles[exit.tile] = true
        end
    end
end

-- The ways off this map that the player knows of. Exit grids are invisible
-- in play, but a player sees where a path leaves the map and remembers it.
-- Each destination is listed once, at its nearest known tile, nearest first.
function state.exits(player)
    state.see_exits(player)

    local nearest = {}
    for destination, tiles in pairs(known_exits.by_destination) do
        for tile in pairs(tiles) do
            local distance = fo.tile_distance(player.tile, tile)
            local best = nearest[destination]
            if best == nil or distance < best.distance then
                nearest[destination] = { map = destination, tile = tile, distance = distance }
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
-- AP is only shown on the player's turn. Everyone's AP is 0 between their
-- turns, and the player gets max_ap back when theirs starts, so a 0 shown
-- during someone else's turn would only look like lost AP.
function state.combat()
    local combat = fo.combat()
    if combat == nil then
        return nil
    end

    local view = {
        your_turn = combat.can_act,
        turn = combat.turn,
        max_ap = combat.max_ap,
    }

    if combat.can_act then
        view.ap = combat.ap
        view.free_move_ap = combat.free_move > 0 and combat.free_move or nil
    end

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
    if flags.movie then
        return "movie"
    end
    if flags.main_menu then
        return "main_menu"
    end
    if flags.screen ~= nil then
        return flags.screen
    end
    if flags.inventory_screen ~= nil then
        return flags.inventory_screen
    end
    for _, screen in ipairs(SCREENS) do
        if flags[screen.flag] then
            return screen.mode
        end
    end
    return "other"
end

-- Whether the last view showed a fight. Every view goes to the agent, so a
-- fight going on that the last view didn't show is one the agent doesn't
-- know about yet, and a walk mustn't spend its AP.
local showed_fight = false

function state.showed_fight()
    return showed_fight
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
        hint = HINTS[mode] or HINTS.other,
        player = player,
    }

    if mode == "character_select" then
        view.premade = fo.premade()
    end

    if mode == "character" or mode == "perk_choice" then
        view.character = character.sheet()
    elseif player ~= nil then
        player.unspent = character.unspent()
    end

    if mode == "combat" then
        view.combat = state.combat()
        if view.combat ~= nil and not view.combat.your_turn then
            view.hint = ("In combat, and it's %s's turn. end_turn waits for yours; your AP refills to %d when it starts."):format(view.combat.turn or "someone else", view.combat.max_ap or 0)
        end
    end
    showed_fight = view.combat ~= nil

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
