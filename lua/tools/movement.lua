local state = require("mcp.state")

-- Directions on the screen, as pixels per hex: a hex is 32 pixels across,
-- and rows step 12 pixels up or down, half a hex across.
local DIRECTIONS = {
    n = { 0, -12 },
    ne = { 16, -12 },
    e = { 32, 0 },
    se = { 16, 12 },
    s = { 0, 12 },
    sw = { -16, 12 },
    w = { -32, 0 },
    nw = { -16, -12 },
}

local DIRECTION_LIST = "n, ne, e, se, s, sw, w, nw"

local TILE_COUNT = 40000

-- A slow walking pace, so a long path finishes well inside the wait.
local MS_PER_HEX = 600
local MIN_TIMEOUT_MS = 3000

-- Frames for whatever the walk set off to start, such as an exit grid's
-- change of map, before the view is taken.
local SETTLE_FRAMES = 3

return function(core)
    local function is_integer(value)
        return math.type(value) == "integer"
    end

    -- The farthest spot up to `distance` hexes away in a screen direction that
    -- the player can actually reach, so a winding passage doesn't make the
    -- walk fail outright. Returns the tile and how many hexes out it is.
    local function farthest_toward(from, step, distance)
        local origin_x, origin_y = fo.tile_center(from)
        if origin_x == nil then
            -- The view has been panned away; bring it back to the player.
            fo.set_view_center(from, true)
            origin_x, origin_y = fo.tile_center(from)
            if origin_x == nil then
                core.fail("can't find the player on screen to walk from")
            end
        end

        for hexes = distance, 1, -1 do
            local tile = fo.tile_at(origin_x + step[1] * hexes, origin_y + step[2] * hexes)
            if tile ~= nil and tile ~= from and fo.path_length(tile) > 0 then
                return tile, hexes
            end
        end
        return nil
    end

    -- The destination, from exactly one of: a tile; a screen point; a
    -- direction and distance from where the player stands.
    local function destination(args, from)
        local forms = 0
        if args.tile ~= nil then
            forms = forms + 1
        end
        if args.x ~= nil or args.y ~= nil then
            forms = forms + 1
        end
        if args.direction ~= nil or args.distance ~= nil then
            forms = forms + 1
        end
        if forms ~= 1 then
            core.fail("give exactly one destination: tile; x and y; or direction and distance")
        end

        if args.tile ~= nil then
            if not is_integer(args.tile) or args.tile < 0 or args.tile >= TILE_COUNT then
                core.fail(("tile must be an integer from 0 to %d"):format(TILE_COUNT - 1))
            end
            return args.tile
        end

        if args.x ~= nil or args.y ~= nil then
            if not is_integer(args.x) or not is_integer(args.y) then
                core.fail("x and y must both be integers, in screenshot coordinates")
            end
            local tile = fo.tile_at(args.x, args.y)
            if tile == nil then
                core.fail(("(%d, %d) isn't on the map"):format(args.x, args.y))
            end
            return tile
        end

        local step = type(args.direction) == "string" and DIRECTIONS[args.direction:lower()] or nil
        if step == nil then
            core.fail("direction must be one of " .. DIRECTION_LIST .. " (directions on the screen)")
        end
        if not is_integer(args.distance) or args.distance < 1 or args.distance > 50 then
            core.fail("distance must be from 1 to 50 hexes")
        end

        local tile, hexes = farthest_toward(from, step, args.distance)
        if tile == nil then
            core.fail(("there's nowhere to go to the %s: it's blocked right away"):format(args.direction))
        end
        return tile, hexes
    end

    core.tool({
        name = "walk_to",
        description = "Walks (or runs) the player to a spot and waits until they stop, then returns the state view with where they ended up. Give the spot as a tile number (an exit's, say), as a point on the screenshot (x, y: like clicking the ground), or as a direction on the screen (n, ne, e, se, s, sw, w, nw) and a distance in hexes; a direction walk goes as far as it can that way, up to the distance, and says how far. Walking onto a map's edge or exit leaves the map. In combat the move spends AP and stops when they run out.",
        schema = core.schema({
            tile = { type = "integer", minimum = 0, maximum = TILE_COUNT - 1, description = "A tile number." },
            x = { type = "integer", description = "Screen x, in screenshot coordinates." },
            y = { type = "integer", description = "Screen y, in screenshot coordinates." },
            direction = { type = "string", enum = { "n", "ne", "e", "se", "s", "sw", "w", "nw" }, description = "A direction on the screen." },
            distance = { type = "integer", minimum = 1, maximum = 50, description = "Hexes to go that way, at most." },
            run = { type = "boolean", description = "Run instead of walking. Faster, but noisier." },
        }),
        run = function(args)
            local player = fo.player()
            if player == nil then
                core.fail("there's no game in progress")
            end

            local from = player.tile
            local to, hexes_that_way = destination(args, from)

            if to == from then
                local view = state.view()
                view.walk = { from = from, to = to, path_length = 0, arrived = true }
                return { data = view }
            end

            local length = fo.path_length(to)
            if length == 0 then
                core.fail(("there's no way from tile %d to tile %d: it's blocked or out of reach"):format(from, to))
            end

            local was_fighting = fo.combat() ~= nil

            if not fo.walk_to(to, args.run == true) then
                core.fail("the game didn't take the move")
            end

            local stopped = core.wait_until(function()
                return not fo.player_busy()
            end, math.max(MIN_TIMEOUT_MS, length * MS_PER_HEX))

            core.wait_frames(SETTLE_FRAMES)

            local view = state.view()
            local now = view.player and view.player.tile or nil
            view.walk = { from = from, to = to, path_length = length, arrived = now == to }
            if args.direction ~= nil then
                -- How far that way the player could go, up to what was asked.
                view.walk.hexes_that_way = hexes_that_way
            end

            if not was_fighting and view.combat ~= nil then
                -- Something saw the player and attacked; the engine stops the
                -- walk when a fight starts.
                view.walk.stopped_by = "a fight started"
                if not view.combat.your_turn then
                    view.note = ("A fight started and stopped the walk. It's %s's turn; end_turn waits for yours."):format(view.combat.turn or "someone else")
                else
                    view.note = "A fight started and stopped the walk. It's your turn."
                end
            elseif was_fighting and view.combat ~= nil and view.combat.your_turn and view.combat.ap == 0 then
                view.note = "The walk used all your AP for this turn. end_turn passes it."
            elseif not stopped then
                view.note = "The player was still moving when the wait ran out."
            end

            return { data = view }
        end,
    })
end
