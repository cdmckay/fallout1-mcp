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

-- How long the player may stay busy finishing something else before a walk
-- gives up waiting to start.
local BUSY_TIMEOUT_MS = 2000

-- How long the others' turns may take, once a walk has run into a fight or
-- used up the player's turn.
local TURN_TIMEOUT_MS = 60000

-- Frames for whatever the walk set off to start, such as an exit grid's
-- change of map, before the view is taken.
local SETTLE_FRAMES = 3

-- A direction walk follows the way as far as it goes that way, round bends
-- and pillars, but doesn't go back the way it came to get further: the spot
-- it heads for lies within 45 degrees of the direction (give or take a hex
-- or two), and the path there is at most twice as long as the progress it
-- makes (give or take a few hexes).
local CONE_SLACK = 2
local DETOUR_FACTOR = 2
local DETOUR_SLACK = 3

-- The most steps fo.reachable searches.
local MAX_REACH = 120

-- The game gives up planning very long paths; how many of the best spots to
-- try before settling for a nearer one.
local PLAN_TRIES = 20

return function(core)
    local function is_integer(value)
        return math.type(value) == "integer"
    end

    -- How far a screen offset goes along a direction, in hexes, and how far
    -- it strays to the side, in the same unit.
    local function along(x, y, step)
        local length2 = step[1] * step[1] + step[2] * step[2]
        return (x * step[1] + y * step[2]) / length2, math.abs(x * step[2] - y * step[1]) / length2
    end

    -- Whether spot `a` is better to head for than `b`: further that way, then
    -- nearer the line, then a shorter walk.
    local function better(a, b)
        if a.hexes ~= b.hexes then
            return a.hexes > b.hexes
        end
        if a.aside ~= b.aside then
            return a.aside < b.aside
        end
        return a.steps < b.steps
    end

    -- Where a direction walk heads: of the spots the player can reach, the one
    -- that goes furthest that way, up to `distance` hexes. Returns { to, hexes,
    -- short_by, in_the_way, searched }: `to` is nil when the way is blocked
    -- right away; `short_by` says what stops it short of `distance` and
    -- `in_the_way` who, if someone does; `searched` has every hex searched,
    -- by tile, with its offset on the screen.
    local function farthest_toward(step, distance)
        local plan = { hexes = 0, searched = {} }
        local spots = {}
        local crowded = nil

        for _, hex in ipairs(fo.reachable(math.min(MAX_REACH, DETOUR_FACTOR * distance + DETOUR_SLACK))) do
            plan.searched[hex.tile] = hex

            local progress, aside = along(hex.x, hex.y, step)
            local hexes = math.floor(progress + 0.5)
            if hexes >= 1 and hexes <= distance and aside <= progress + CONE_SLACK and hex.steps <= DETOUR_FACTOR * progress + DETOUR_SLACK then
                local spot = { tile = hex.tile, hexes = hexes, aside = aside, steps = hex.steps, critter = hex.critter }
                if spot.critter == nil then
                    spots[#spots + 1] = spot
                elseif crowded == nil or better(spot, crowded) then
                    crowded = spot
                end
            end
        end

        table.sort(spots, better)
        for i = 1, math.min(#spots, PLAN_TRIES) do
            if fo.path_length(spots[i].tile) > 0 then
                plan.to = spots[i].tile
                plan.hexes = spots[i].hexes
                break
            end
        end

        if plan.hexes < distance then
            if crowded ~= nil and crowded.hexes > plan.hexes then
                plan.short_by = "occupied"
                plan.in_the_way = crowded.critter
            else
                plan.short_by = "blocked"
            end
        end
        return plan
    end

    -- The destination, from exactly one of: a tile; a screen point; a
    -- direction and distance from where the player stands. Returns { tile }
    -- or { direction, step, distance }.
    local function destination(args)
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
            return { tile = args.tile }
        end

        if args.x ~= nil or args.y ~= nil then
            if not is_integer(args.x) or not is_integer(args.y) then
                core.fail("x and y must both be integers, in screenshot coordinates")
            end
            local tile = fo.tile_at(args.x, args.y)
            if tile == nil then
                core.fail(("(%d, %d) isn't on the map"):format(args.x, args.y))
            end
            return { tile = tile }
        end

        local direction = type(args.direction) == "string" and args.direction:lower() or nil
        local step = direction and DIRECTIONS[direction] or nil
        if step == nil then
            core.fail("direction must be one of " .. DIRECTION_LIST .. " (directions on the screen)")
        end
        if not is_integer(args.distance) or args.distance < 1 or args.distance > 50 then
            core.fail("distance must be from 1 to 50 hexes")
        end
        return { direction = direction, step = step, distance = args.distance }
    end

    -- Why a walk that stopped before `to` did, as walk.stopped_by, and who
    -- was in the way if that's why: what stands on the spot, or else what's
    -- across the way from where the player is now.
    local function why_short(to)
        local blocker = fo.blocker(to)
        if blocker ~= nil then
            if blocker.critter ~= nil then
                return "occupied", blocker.critter
            end
            return "blocked"
        end
        -- A way that's clear again had someone in it who moved on.
        if fo.path_length(to) > 0 or fo.path_length_past_critters(to) > 0 then
            return "occupied"
        end
        return "blocked"
    end

    -- The name of critter `id`, if the view shows it: a note names only
    -- someone the player can see.
    local function seen_name(view, id)
        for _, critter in ipairs(view.critters or {}) do
            if critter.id == id then
                return critter.name
            end
        end
        return nil
    end

    -- What a note says about why the walk stopped where it did.
    local function explain(walk, view, in_the_way)
        local reason = walk.stopped_by
        if reason == "blocked" then
            if walk.hexes_that_way == 0 then
                return "The way is blocked right away in that direction."
            elseif walk.hexes_that_way ~= nil then
                return ("The way is blocked after %d hexes in that direction; this is as far as it goes."):format(walk.hexes_that_way)
            end
            return "Something solid is on that spot or across the way, so this is as close as the walk gets."
        elseif reason == "occupied" then
            local name = in_the_way ~= nil and seen_name(view, in_the_way) or nil
            return ("%s is in the way."):format(name or "Someone")
        elseif reason == "out of path" then
            return "The game finds no way there from here."
        elseif reason == "left the map" then
            return "The walk crossed an exit and left the map."
        elseif reason == "still moving" then
            return "The player was still moving when the wait ran out."
        end
        return nil
    end

    local function finish(walk, note, in_the_way)
        local view = state.view()
        view.walk = walk
        local why = explain(walk, view, in_the_way)
        if why ~= nil and note ~= nil then
            view.note = why .. " " .. note
        else
            view.note = why or note
        end
        return { data = view }
    end

    -- Waits until it's the player's turn and they can act, or the fight is
    -- over. Returns whether that happened in time.
    local function wait_for_turn()
        return core.wait_until(function()
            local combat = fo.combat()
            return combat == nil or (combat.can_act and not combat.animating)
        end, TURN_TIMEOUT_MS)
    end

    -- A fight stopped the walk, or was already on when it was asked for
    -- without the agent knowing. Either way the walk returns on the player's
    -- turn, with their AP for it: the game gives them their full AP when
    -- their turn starts, and nothing here spends it.
    local function fight_started(walk)
        walk.arrived = walk.arrived or false
        walk.stopped_by = "a fight started"
        local ready = wait_for_turn()
        core.wait_frames(SETTLE_FRAMES)

        local view = state.view()
        view.walk = walk
        -- A walk that never got going has no path length.
        local what = walk.path_length == nil and "A fight has started, so the player didn't walk." or "A fight started and stopped the walk."
        if view.combat == nil then
            view.note = what .. " It's over already."
        elseif not ready then
            view.note = what .. " It still wasn't your turn when the wait ran out; end_turn waits for it."
        else
            view.note = what .. " It's your turn."
        end
        return { data = view }
    end

    -- Waits out the rest of a turn the walk used up, then the others' turns.
    -- Returns a note saying so.
    local function pass_turn()
        core.wait_until(function()
            local combat = fo.combat()
            return combat == nil or not combat.can_act
        end, BUSY_TIMEOUT_MS)
        local ready = wait_for_turn()
        core.wait_frames(SETTLE_FRAMES)

        if fo.combat() == nil then
            return "The walk used the rest of your AP, and the fight ended."
        elseif not ready then
            return "The walk used the rest of your AP, so your turn passed. It still wasn't your turn again when the wait ran out; end_turn waits for it."
        end
        return "The walk used the rest of your AP, so your turn passed. It's your turn again."
    end

    local function exit_tiles()
        local tiles = {}
        for _, exit in ipairs(fo.exits()) do
            tiles[exit.tile] = true
        end
        return tiles
    end

    local function place(player)
        return player and ("%s:%d"):format(player.map and player.map.file or "?", player.elevation or 0) or nil
    end

    core.tool({
        name = "walk_to",
        description = "Walks (or runs) the player to a spot and waits until they stop, then returns the state view with how the walk went (walk). Give the spot as a tile number (an exit's, say), as a point on the screenshot (x, y: like clicking the ground), or as a direction on the screen (n, ne, e, se, s, sw, w, nw) and a distance in hexes. A direction walk follows the way round bends as far as it goes that way, up to the distance, and says how far that way the player got (hexes_that_way). A walk that falls short has arrived: false and says why in stopped_by: blocked (a wall, scenery or closed door), occupied (someone on the spot or in the way), out of path (the game finds no way there), a fight started (it then returns on your turn, with your AP), out of AP, left the map, or still moving. Walking onto an exit leaves the map. In combat the move spends AP; if it uses them all, your turn passes and this waits for the next.",
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
            local mode = state.mode(fo.flags())
            if mode ~= "map" and mode ~= "combat" then
                core.fail(("walking works on the map, and the %s screen is up"):format(mode))
            end

            local dest = destination(args)
            local from = player.tile
            local walk = { from = from, to = dest.tile }

            local fight = fo.combat()
            if fight ~= nil and not state.showed_fight() then
                -- It started since the agent last looked. Walking now would
                -- spend the turn, or not be possible at all.
                return fight_started(walk)
            end
            if fight ~= nil and not fight.can_act then
                core.fail("it isn't your turn: end_turn waits for it")
            end
            if fight ~= nil and fight.ap + fight.free_move <= 0 then
                walk.to = walk.to or from
                walk.path_length = 0
                walk.arrived = false
                walk.stopped_by = "out of AP"
                return finish(walk, "You have no AP left this turn; end_turn passes it.")
            end

            local plan = nil
            if dest.direction ~= nil then
                plan = farthest_toward(dest.step, dest.distance)
                walk.to = plan.to or from
                if plan.to == nil then
                    walk.path_length = 0
                    walk.arrived = false
                    walk.hexes_that_way = 0
                    walk.stopped_by = plan.short_by
                    return finish(walk, nil, plan.in_the_way)
                end
            end
            local to = walk.to

            if to == from then
                walk.path_length = 0
                walk.arrived = true
                return finish(walk)
            end

            local length = fo.path_length(to)
            if length == 0 then
                walk.path_length = 0
                walk.arrived = false
                walk.stopped_by = fo.path_length_past_critters(to) > 0 and "occupied" or "out of path"
                return finish(walk)
            end
            walk.path_length = length

            local exits = exit_tiles()
            local here = place(player)
            local run = args.run == true

            if not fo.walk_to(to, run) then
                -- Still finishing something else, such as the end of the
                -- last move: let it, and try once more.
                core.wait_until(function()
                    return not fo.player_busy()
                end, BUSY_TIMEOUT_MS)
                if fight == nil and fo.combat() ~= nil then
                    return fight_started(walk)
                end
                if not fo.walk_to(to, run) then
                    core.fail("the game didn't take the move: the player is still busy with something else")
                end
            end

            local stopped = core.wait_until(function()
                return not fo.player_busy()
            end, math.max(MIN_TIMEOUT_MS, length * MS_PER_HEX))

            core.wait_frames(SETTLE_FRAMES)

            local now = fo.player()
            if fight == nil and fo.combat() ~= nil then
                -- The game stops every walk when a fight starts.
                walk.arrived = now ~= nil and now.tile == to
                return fight_started(walk)
            end

            if now == nil or place(now) ~= here or fo.flags().world_map then
                walk.left_map = true
                walk.arrived = exits[to] == true
                if not walk.arrived then
                    walk.stopped_by = "left the map"
                end
                return finish(walk)
            end

            walk.arrived = now.tile == to
            if plan ~= nil then
                local reached = plan.searched[now.tile]
                if reached ~= nil then
                    walk.hexes_that_way = math.max(0, math.floor(along(reached.x, reached.y, dest.step) + 0.5))
                elseif now.tile == from then
                    walk.hexes_that_way = 0
                end
                walk.arrived = walk.arrived and plan.hexes >= dest.distance
            end

            fight = fo.combat()
            local turn_over = fight ~= nil and (not fight.can_act or fight.ap + fight.free_move <= 0)

            local in_the_way = nil
            if not walk.arrived then
                if turn_over and now.tile ~= to then
                    walk.stopped_by = "out of AP"
                elseif not stopped then
                    walk.stopped_by = "still moving"
                elseif now.tile == to then
                    -- A direction walk that went as far as it goes that way.
                    walk.stopped_by = plan.short_by
                    in_the_way = plan.in_the_way
                else
                    walk.stopped_by, in_the_way = why_short(to)
                end
            end

            local note = nil
            if turn_over then
                note = pass_turn()
            end
            return finish(walk, note, in_the_way)
        end,
    })
end
