-- The things on the map a player can see and act on besides the living:
-- items on the ground, bodies, containers, doors and scenery that can be
-- used. Each comes with what can be done with it, named as the tools that do
-- it. Fair play lists what's on screen (mcp.sight), as for critters.
--
-- A lock can't be seen, only tried: fair play says a door or container is
-- locked once the player has found it so. Omniscient mode always says.

local sight = require("mcp.sight")

local objects = {}

-- Each kind's character on the text map, as its legend has it.
objects.SYMBOLS = { item = "*", body = "%", container = "=", door = "+", scenery = "!" }

-- What can be done with each kind, as tools. Anything can also be looked at.
local ACTIONS = {
    item = { "pick_up" },
    body = { "loot" },
    container = { "loot" },
    door = { "use" },
    scenery = { "use" },
}

local DIRECTION_NAMES = { [0] = "ne", "e", "se", "sw", "w", "nw" }

local function by_distance(a, b)
    if a.distance ~= b.distance then
        return a.distance < b.distance
    end
    return a.id < b.id
end

local function screen_point(tile)
    local x, y = fo.tile_center(tile)
    if x == nil then
        return nil
    end
    return { x = x, y = y }
end

-- The doors and containers the player has found locked on this map, by id.
-- Forgotten on leaving the map.
local known_locked = { map = nil, ids = {} }

local function remember_map(player)
    local map = player.map and player.map.file or nil
    if known_locked.map ~= map then
        known_locked = { map = map, ids = {} }
    end
end

-- Records what trying a door or container showed: locked, or not.
function objects.tried(player, id, locked)
    remember_map(player)
    known_locked.ids[id] = locked or nil
end

-- Every object a player can see, nearest first, as
-- { id, name, kind, tile, distance, direction, screen, actions } plus, for
-- an item, its type and any quantity (money, ammo); for a door or
-- container, whether it's open and, once known, locked; for scenery, what
-- it is when it takes you elsewhere (ladder up, stairs, ...).
function objects.list(player)
    remember_map(player)
    local omniscient = fo.omniscient()
    local list = {}

    for _, object in ipairs(fo.objects()) do
        if sight.sees(object) then
            local entry = {
                id = object.id,
                name = object.name,
                kind = object.kind,
                tile = object.tile,
                distance = fo.tile_distance(player.tile, object.tile),
                direction = DIRECTION_NAMES[fo.tile_direction(player.tile, object.tile)],
                screen = screen_point(object.tile),
                actions = ACTIONS[object.kind],
                type = object.kind ~= "container" and object.type or nil,
                quantity = object.quantity,
                open = object.open,
            }

            if object.open ~= nil and not object.open then
                if omniscient then
                    entry.locked = object.locked
                elseif known_locked.ids[object.id] then
                    -- Still locked, as far as the player knows, unless
                    -- someone has since opened it.
                    entry.locked = true
                end
            end

            list[#list + 1] = entry
        end
    end

    table.sort(list, by_distance)
    return list
end

-- The nearest `limit` objects, and how many more there are.
function objects.nearest(player, limit)
    local list = objects.list(player)
    local left_out = math.max(0, #list - limit)
    for i = #list, limit + 1, -1 do
        list[i] = nil
    end
    return list, left_out > 0 and left_out or nil
end

-- What the loot screen shows: what the other side holds, its weight, and
-- the player's weight and what they can carry. Nil unless it's open.
function objects.loot_view()
    local screen = fo.loot_screen()
    if screen == nil then
        return nil
    end

    return {
        from = screen.target,
        items = setmetatable(screen.items, { __jsontype = "array" }),
        items_weight = screen.target_weight,
        weight = screen.weight,
        capacity = screen.capacity,
    }
end

return objects
