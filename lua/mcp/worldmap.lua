-- The world map as the player sees it: where they are and what's there,
-- whether they're travelling, and the places the map's list names, with how
-- far away each is. The map is a grid of squares, 28 across and 30 down,
-- north up; positions and distances are in squares, as the map's fog of war
-- reveals it square by square. See "Decision views" in docs/mcp-design.md.

local worldmap = {}

-- The engine's positions are pixels, 50 to a square.
worldmap.SQUARE = 50
worldmap.COLUMNS = 28
worldmap.ROWS = 30

local COMPASS = { [0] = "e", "ne", "n", "nw", "w", "sw", "s", "se" }

local function round(value)
    return math.floor(value * 10 + 0.5) / 10
end

-- A pixel position, in squares to one decimal.
function worldmap.point(x, y)
    return { x = round(x / worldmap.SQUARE), y = round(y / worldmap.SQUARE) }
end

-- Squares from (x1, y1) to (x2, y2), in pixels, to one decimal.
function worldmap.distance(x1, y1, x2, y2)
    local dx, dy = x2 - x1, y2 - y1
    return round(math.sqrt(dx * dx + dy * dy) / worldmap.SQUARE)
end

-- The compass direction from (x1, y1) to (x2, y2), or nil when they're the
-- same point. y grows southward.
function worldmap.direction(x1, y1, x2, y2)
    local dx, dy = x2 - x1, y2 - y1
    if dx == 0 and dy == 0 then
        return nil
    end
    local octant = math.floor(math.atan(-dy, dx) / (math.pi / 4) + 0.5) % 8
    return COMPASS[octant]
end

-- Which square a pixel position is in, as column and row.
local function square(x, y)
    return x // worldmap.SQUARE, y // worldmap.SQUARE
end

local function same_square(x1, y1, x2, y2)
    local c1, r1 = square(x1, y1)
    local c2, r2 = square(x2, y2)
    return c1 == c2 and r1 == r2
end

-- The known place whose square a point is in, if any.
function worldmap.place_at(raw, x, y)
    for _, town in ipairs(raw.known) do
        if same_square(town.x, town.y, x, y) then
            return town
        end
    end
    return nil
end

-- The known place called `name`, ignoring case, if any.
function worldmap.find(raw, name)
    local wanted = name:lower()
    for _, town in ipairs(raw.known) do
        if town.name:lower() == wanted then
            return town
        end
    end
    return nil
end

function worldmap.names(raw)
    local names = {}
    for i, town in ipairs(raw.known) do
        names[i] = town.name
    end
    return table.concat(names, ", ")
end

-- The world map view, from fo.world_map(): nil when it isn't up.
--   here          what the player's marker says: a town's name, or the ground
--   terrain       desert, mountain, city or coast
--   position      where the player is, in squares
--   travelling_to where they're headed, while they're moving
--   can_enter     whether `enter` would go in here: they've stopped (on
--                 the town map, enter picks one of its places instead)
--   places        the places the map's list names, nearest first, each with
--                 its distance in squares and direction; `here` marks the
--                 one they're in
function worldmap.view(raw)
    raw = raw or fo.world_map()
    if raw == nil then
        return nil
    end

    local view = {
        here = raw.here,
        terrain = raw.terrain,
        position = worldmap.point(raw.x, raw.y),
    }

    if raw.moving and raw.target ~= nil then
        local to = worldmap.point(raw.target.x, raw.target.y)
        local place = worldmap.place_at(raw, raw.target.x, raw.target.y)
        to.place = place and place.name or nil
        view.travelling_to = to
    elseif raw.town_map == nil then
        view.can_enter = raw.can_enter
    end

    local places = {}
    for _, town in ipairs(raw.known) do
        local entry = {
            name = town.name,
            distance = worldmap.distance(raw.x, raw.y, town.x, town.y),
            direction = worldmap.direction(raw.x, raw.y, town.x, town.y),
            position = worldmap.point(town.x, town.y),
        }
        if raw.town == town.id then
            entry.here = true
            entry.distance = 0
            entry.direction = nil
        end
        places[#places + 1] = entry
    end
    table.sort(places, function(a, b)
        if a.distance ~= b.distance then
            return a.distance < b.distance
        end
        return a.name < b.name
    end)
    view.places = places

    return view
end

-- The town map view: the town shown and the places on it a player can go
-- into, or nil when it isn't up.
function worldmap.town_map(raw)
    raw = raw or fo.world_map()
    if raw == nil or raw.town_map == nil then
        return nil
    end
    return { town = raw.town_map.name, places = raw.town_map.places }
end

return worldmap
