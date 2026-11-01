local state = require("mcp.state")

-- Hex directions, as the engine numbers rotations.
local DIRECTIONS = { ne = 0, e = 1, se = 2, sw = 3, w = 4, nw = 5 }

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

        local rotation = type(args.direction) == "string" and DIRECTIONS[args.direction:lower()] or nil
        if rotation == nil then
            core.fail("direction must be one of ne, e, se, sw, w, nw")
        end
        if not is_integer(args.distance) or args.distance < 1 or args.distance > 200 then
            core.fail("distance must be from 1 to 200 hexes")
        end
        return fo.tile_toward(from, rotation, args.distance)
    end

    core.tool({
        name = "walk_to",
        description = "Walks (or runs) the player to a spot and waits until they stop, then returns the state view with where they ended up. Give the spot as a tile number, as a point on the screenshot (x, y: like clicking the ground), or as a direction (ne, e, se, sw, w, nw) and a distance in hexes. Walking onto a map's edge or exit leaves the map. In combat the move spends AP and stops when they run out.",
        schema = core.schema({
            tile = { type = "integer", minimum = 0, maximum = TILE_COUNT - 1, description = "A tile number." },
            x = { type = "integer", description = "Screen x, in screenshot coordinates." },
            y = { type = "integer", description = "Screen y, in screenshot coordinates." },
            direction = { type = "string", enum = { "ne", "e", "se", "sw", "w", "nw" } },
            distance = { type = "integer", minimum = 1, maximum = 200, description = "Hexes to go in that direction." },
            run = { type = "boolean", description = "Run instead of walking. Faster, but noisier." },
        }),
        run = function(args)
            local player = fo.player()
            if player == nil then
                core.fail("there's no game in progress")
            end

            local from = player.tile
            local to = destination(args, from)

            if to == from then
                local view = state.view()
                view.walk = { from = from, to = to, path_length = 0, arrived = true }
                return { data = view }
            end

            local length = fo.path_length(to)
            if length == 0 then
                core.fail(("there's no way from tile %d to tile %d: it's blocked or out of reach"):format(from, to))
            end

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
            if not stopped then
                view.note = "The player was still moving when the wait ran out."
            end
            return { data = view }
        end,
    })
end
