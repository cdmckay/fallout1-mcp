-- The text map: one character per hex for the part of the map on screen, so
-- the agent can get its bearings and pick a way to walk without reading a
-- screenshot. Fair play draws only what a player can see (mcp.sight).
--
-- Each line of text is a row of hexes as they sit on screen. Rows are offset
-- half a hex from each other, so hexes take every other character and odd
-- columns sit half a row down. That keeps the screen's directions straight:
-- walk_to's e and w run along a line, two characters per hex; ne, se, sw and
-- nw go one line up or down and one character across; n and s go straight up
-- and down, a line per hex.
--
-- Floor is drawn only where the player can walk to, as the game's move
-- cursor tells a player who points at a hex, and walls and doors only where
-- they border it. In a cave that leaves the rock blank, since the rock is floor
-- art the player can't get onto, and the corridors stand out between their
-- walls.

local objects = require("mcp.objects")
local sight = require("mcp.sight")

local map = {}

map.LEGEND = "Text map of what's on screen, one character per hex: @ you, a-z critters (key below), # wall or rock face, + door, . floor you can walk to, > exit, * item, % body, = container, ! something to use (objects lists them all). Blank is out of sight or out of reach."
map.DIRECTIONS = "Directions as walk_to takes them: up is n. One hex e or w is 2 characters along the line; ne, se, sw and nw are 1 line up or down and 1 character across; n and s are 1 line straight up or down."

local LETTERS = "abcdefghijklmnopqrstuvwxyz"

-- Which object's mark shows when several share a hex. Doors are drawn with
-- the walls, where they border floor.
local RANK = { item = 1, scenery = 2, container = 3, body = 4 }

-- A hex's neighbours, in map columns and rows: e and w along the row, the
-- other four a row up or down and half a hex across.
local NEIGHBOURS = { { 2, 0 }, { -2, 0 }, { 1, -1 }, { -1, -1 }, { 1, 1 }, { -1, 1 } }

local function by_distance(a, b)
    if a.distance ~= b.distance then
        return a.distance < b.distance
    end
    return a.id < b.id
end

-- What to draw for a hex a player can see, critters aside. `borders` says
-- whether the hex is next to somewhere the player can walk.
local function ground(hex, omniscient, borders)
    if hex.exit then
        return ">"
    end
    if hex.terrain == "wall" then
        return borders and "#" or " "
    end
    if hex.terrain == "door" then
        return borders and "+" or " "
    end
    if hex.item_visible or (omniscient and hex.item) then
        return "*"
    end
    if hex.terrain == "floor" and hex.reachable then
        return "."
    end
    return " "
end

-- The map around `player` as text, and the key to its critter letters as
-- { letter, id, name }, nearest first. Returns nil when nothing on screen
-- can be drawn.
function map.draw(player)
    local omniscient = fo.omniscient()
    local hexes = fo.hexes()

    local on_map = {}
    local walkable = {}
    for _, hex in ipairs(hexes) do
        on_map[hex.tile] = true
        if hex.reachable then
            walkable[hex.y] = walkable[hex.y] or {}
            walkable[hex.y][hex.x] = true
        end
    end

    local function borders(hex)
        for _, step in ipairs(NEIGHBOURS) do
            local row = walkable[hex.y + step[2]]
            if row and row[hex.x + step[1]] then
                return true
            end
        end
        return false
    end

    -- Objects get their kind's mark, as the objects list has them, and the
    -- living get letters, nearest first as the critter list has them.
    local marks = {}
    local ranks = {}
    for _, object in ipairs(objects.list(player)) do
        local rank = RANK[object.kind]
        if rank ~= nil and on_map[object.tile] and rank > (ranks[object.tile] or 0) then
            marks[object.tile] = objects.SYMBOLS[object.kind]
            ranks[object.tile] = rank
        end
    end

    local living = {}
    for _, critter in ipairs(sight.critters()) do
        if on_map[critter.tile] and critter.tile ~= player.tile and not critter.dead then
            living[#living + 1] = {
                id = critter.id,
                name = critter.name,
                tile = critter.tile,
                distance = fo.object_distance(critter.id),
            }
        end
    end
    table.sort(living, by_distance)

    local key = {}
    for i, critter in ipairs(living) do
        local letter = i <= #LETTERS and LETTERS:sub(i, i) or "?"
        marks[critter.tile] = letter
        key[i] = { letter = letter, id = critter.id, name = critter.name }
    end

    -- The characters by row and column, and the box around what's drawn.
    local rows = {}
    local left, right, top, bottom
    for _, hex in ipairs(hexes) do
        local char = " "
        if hex.tile == player.tile then
            char = "@"
        elseif sight.sees(hex) then
            char = marks[hex.tile] or ground(hex, omniscient, borders(hex))
        end

        if char ~= " " then
            rows[hex.y] = rows[hex.y] or {}
            rows[hex.y][hex.x] = char
            left = math.min(left or hex.x, hex.x)
            right = math.max(right or hex.x, hex.x)
            top = math.min(top or hex.y, hex.y)
            bottom = math.max(bottom or hex.y, hex.y)
        end
    end

    if left == nil then
        return nil
    end

    local text = { map.LEGEND, map.DIRECTIONS }
    for _, entry in ipairs(key) do
        text[#text + 1] = ("%s: %s, id %d"):format(entry.letter, entry.name, entry.id)
    end
    text[#text + 1] = ""

    for y = top, bottom do
        local row = rows[y] or {}
        local chars = {}
        for x = left, right do
            chars[#chars + 1] = row[x] or " "
        end
        text[#text + 1] = (table.concat(chars):gsub("%s+$", ""))
    end

    return table.concat(text, "\n"), key
end

return map
