local json = require("lib.dkjson")
local support = require("tests.support")

local equal, contains = support.equal, support.contains

local tests = {}

-- The hexes around where a new game starts in the Vault 13 cave, as
-- fo.hexes gave them (V13ENT.MAP, tile 17690), one character per hex, set
-- out as on screen: odd columns half a row down. F is floor the player can
-- walk to, f floor they can't (the rock), W a wall, D the vault door, X an
-- exit grid and @ the player. The middle line is the player's row.
local CAVE = {
    "f f f f f f f W f f f f f f f f f f f",
    " f f f f f f f W W f f f f f f f f f ",
    "W f f f f f f f W W W W f f f f f f f",
    " W f f f f f X W W f f W f f f f f f ",
    "W W f f f X X W f f f f W f f f f f f",
    " W W f X X D W f f f f W W f f f f f ",
    "f W W W W W F W W W f f W f f f f f f",
    " f W f f f W F W W W W W f f f f f f ",
    "f f W f f W W F F W W F W f f f f f f",
    " f W W f W W F F F F F F W f f f f f ",
    "f W f W W W F F F F W F W W f f f f f",
    " W f f W W W F F F F F F W W W W W W ",
    "f W f f W F F F F @ F F W f W f W f W",
    " f W W W F F F F F F F F W f W W W W ",
    "f f W f W F F F F F F F F W W W F F F",
    " f f W f W F F F F F F F F F W F F F ",
    "f f f W f W F F F F F F F F F F F W F",
    " W W W W W W F F F F F F F F F W F F ",
    "W f f W f f W W W F F F F F F W W F F",
    " f W W f f f W f W F F F F F F W W F ",
    "W W W W f f W W W W F F F F F F F F F",
}
local PLAYER_ROW = 13
local PLAYER_COLUMN = 19

-- A fake tile number for the hex `x` half hexes right of the player and `y`
-- rows down.
local function tile(x, y)
    return (y + 50) * 200 + (x + 100)
end

local function hexes_from(patch)
    local hexes = {}
    for row, line in ipairs(patch) do
        for column = 1, #line do
            local code = line:sub(column, column)
            if code ~= " " then
                local x, y = column - PLAYER_COLUMN, row - PLAYER_ROW
                local hex = {
                    tile = tile(x, y),
                    x = x,
                    y = y,
                    visible = true,
                    terrain = "floor",
                    reachable = true,
                    exit = false,
                    item = false,
                    item_visible = false,
                }
                if code == "W" then
                    hex.terrain, hex.reachable = "wall", false
                elseif code == "D" then
                    hex.terrain, hex.reachable = "door", false
                elseif code == "f" then
                    hex.reachable = false
                elseif code == "X" then
                    hex.exit = true
                end
                hexes[#hexes + 1] = hex
            end
        end
    end
    return hexes
end

local function hex_distance(a, b)
    local ax, ay = a % 200, a // 200
    local bx, by = b % 200, b // 200
    local dx, dy = math.abs(ax - bx), math.abs(ay - by)
    return dy + math.max(0, (dx - dy) // 2)
end

local function rat(id, x, y, overrides)
    local critter = { id = id, name = "Cave Rat", tile = tile(x, y), visible = true, dead = false, hidden = false, health = "Unhurt" }
    for k, v in pairs(overrides or {}) do
        critter[k] = v
    end
    return critter
end

-- The cave with three rats in sight, one behind the rock face where a
-- player can't see it, a dead one, and two items, one of them hidden under
-- something drawn in front.
local function fake_cave(options)
    options = options or {}
    local core, engine = support.new({ omniscient = options.omniscient })

    local hexes = hexes_from(CAVE)
    for _, hex in ipairs(hexes) do
        if hex.tile == tile(-6, 2) then
            hex.item, hex.item_visible = true, true
        elseif hex.tile == tile(4, 4) then
            hex.item, hex.item_visible = true, false
        end
    end

    fo.flags = function()
        return { in_game = true }
    end
    fo.player = function()
        return { name = "Max Stone", hp = 43, max_hp = 43, tile = tile(0, 0), map = { file = "V13ENT.MAP", name = "Vault 13" } }
    end
    fo.hexes = function()
        return hexes
    end
    fo.critters = function()
        return {
            rat(423, -4, 4),
            rat(489, 6, 6),
            rat(560, -2, -4),
            rat(469, -10, 6, { visible = false }),
            rat(711, -2, 2, { dead = true }),
        }
    end
    fo.tile_distance = hex_distance
    fo.screenshot = function()
        return "PNG", 1024, 768
    end

    require("tools.perception")(core)
    return core, engine
end

local function look(engine, args)
    engine.request({ id = 1, op = "call", tool = "look", args = args or {} })
    engine.frames(2)
    local reply = engine.reply()
    assert(reply.result, reply.error and reply.error.message)
    return reply.result.content
end

local function map_lines(text)
    local lines = {}
    for line in (text .. "\n"):gmatch("(.-)\n") do
        lines[#lines + 1] = line
    end
    return lines
end

-- The map lines below the legend, directions and key.
local function drawn(text)
    local lines = map_lines(text)
    for i, line in ipairs(lines) do
        if line == "" then
            return table.concat(lines, "\n", i + 1)
        end
    end
    error("no blank line before the map in:\n" .. text)
end

function tests.the_cave_reads_as_corridors_between_walls()
    local _, engine = fake_cave()

    local content = look(engine)
    local text = content[2].text

    local expected = table.concat({
        "       > #",
        "    > > #",
        " > > + #",
        "# # # . #",
        "     # . # #   # #",
        "      # . b # # . #",
        "     # . . . . . . #",
        "    # . . . . # . #",
        "   # # . . . . . . #",
        "  # . . . . @ . . #",
        " # . . . . . . . . #     # # #",
        "  # . * . % . . . . # # # . . .",
        "   # . . . . . . . . . # . . .",
        "    # . a . . . . . . . . . # .",
        "     # . . . . . . . . . # . .",
        "      # # # . . . c . . # # . .",
        "           # . . . . . . # # .",
        "            # . . . . . . . . .",
    }, "\n")

    local actual = drawn(text)
    if actual ~= expected then
        error("map differs; got:\n" .. actual)
    end
end

function tests.the_key_names_each_critter_letter_by_id_nearest_first()
    local _, engine = fake_cave()

    local text = look(engine)[2].text

    -- 423 and 560 are both 4 hexes away; the lower id comes first.
    contains(text, "a: Cave Rat, id 423", "nearest rat")
    contains(text, "b: Cave Rat, id 560", "as near")
    contains(text, "c: Cave Rat, id 489", "farthest rat")
    equal(text:find("469", 1, true), nil, "the rat behind the rock")
end

function tests.the_legend_and_directions_come_first()
    local _, engine = fake_cave()

    local lines = map_lines(look(engine)[2].text)

    equal(lines[1], require("mcp.map").LEGEND, "legend")
    equal(lines[2], require("mcp.map").DIRECTIONS, "directions")
    contains(lines[2], "up is n", "walk_to's directions")
end

function tests.the_map_and_critter_list_agree_on_who_is_in_sight()
    local _, engine = fake_cave()

    local content = look(engine)
    local view = json.decode(content[1].text)
    local text = content[2].text

    local listed = {}
    for _, critter in ipairs(view.critters) do
        listed[critter.id] = true
        contains(text, ("id %d"):format(critter.id), "keyed on the map")
    end
    equal(listed[469], nil, "the hidden rat isn't listed")
    equal(#view.critters, 3, "living rats in sight")
end

local function count(text, char)
    local _, n = text:gsub(char, "")
    return n
end

function tests.omniscient_mode_draws_what_a_player_couldnt_see()
    local _, fair = fake_cave()
    local seen = drawn(look(fair)[2].text)

    local _, omniscient = fake_cave({ omniscient = true })
    local text = look(omniscient)[2].text
    local all = drawn(text)

    contains(text, "d: Cave Rat, id 469", "the rat behind the rock")
    equal(count(all, "d"), 1, "the rat behind the rock, drawn")
    equal(count(seen, "%*"), 1, "the item a player can see")
    equal(count(all, "%*"), 2, "and the one under the rock face")
end

function tests.hexes_under_a_roof_are_blank_in_fair_play()
    local _, engine = fake_cave()
    for _, hex in ipairs(fo.hexes()) do
        if hex.y < 0 then
            hex.visible = false
        end
    end

    local lines = map_lines(drawn(look(engine)[2].text))

    contains(lines[1], "@", "the player's row first")
end

function tests.screenshot_false_leaves_out_the_image()
    local _, engine = fake_cave()

    local with = look(engine)
    local without = look(engine, { screenshot = false })

    equal(#with, 3, "state, map and screenshot")
    equal(with[3].type, "image", "screenshot")
    equal(#without, 2, "state and map")
    equal(without[2].type, "text", "map")
end

function tests.no_map_off_the_map()
    local core, engine = support.new()
    fo.flags = function()
        return { main_menu = true }
    end
    fo.player = function()
        return nil
    end
    fo.screenshot = function()
        return "PNG", 1024, 768
    end
    require("tools.perception")(core)

    local content = look(engine)

    equal(#content, 2, "state and screenshot")
    equal(content[2].type, "image", "no map")
end

return tests
