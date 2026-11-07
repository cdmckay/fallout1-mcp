local state = require("mcp.state")
local worldmap = require("mcp.worldmap")

-- The map's own button codes: a town in its list is 500 plus the town, the
-- town map's places are 514 on, and 512 switches between the two maps.
local TOWN_BUTTON = 500
local TOGGLE_BUTTON = 512
local PLACE_BUTTON = 514

-- How long the map may take to read a button or command code.
local READ_TIMEOUT_MS = 5000

-- How long the town map and world map take to swap, or a place's map to
-- load once the map is left.
local SCREEN_TIMEOUT_MS = 30000

-- How long a trip may take. Across the whole map, through mountains, is
-- about 80 seconds at normal speed. A longer one carries on after the tool
-- returns.
local TRIP_TIMEOUT_MS = 100000

-- Frames for the screen to settle once it has changed.
local SETTLE_FRAMES = 3

-- The game clock runs in tenths of a second.
local TICKS_PER_HOUR = 36000

return function(core)
    local function mode()
        return state.mode(fo.flags())
    end

    local function on_map_screen()
        local current = mode()
        return current == "world_map" or current == "town_map"
    end

    -- Waits until the screen in front has read the code just queued.
    local function await_read(queued, what)
        if not queued then
            core.fail("the game's input queue is full; try again in a moment")
        end
        if not core.wait_until(function()
            return not fo.input_pending()
        end, READ_TIMEOUT_MS) then
            core.fail(("the map didn't read %s"):format(what))
        end
        -- The loop acts on the code in the frame that reads it.
        core.wait_frames(1)
    end

    local function press(code, what)
        await_read(fo.inject(code), what)
    end

    -- Waits until the screen is no longer `from`, then for the next one to
    -- settle.
    local function await_leaving(from)
        if not core.wait_until(function()
            return mode() ~= from
        end, SCREEN_TIMEOUT_MS) then
            core.fail(("the %s didn't close"):format((from:gsub("_", " "))))
        end
        core.wait_frames(SETTLE_FRAMES)
    end

    -- From the town map, over to the world map.
    local function to_world_map()
        if mode() == "town_map" then
            press(TOGGLE_BUTTON, "the world map button")
            await_leaving("town_map")
        end
        if mode() ~= "world_map" then
            core.fail(("travel works from the world map, not from %s. Walk to an exit leading to the world map to get there."):format(mode()))
        end
    end

    local function hours_since(start)
        return math.floor((fo.game_time() - start) / TICKS_PER_HOUR * 10 + 0.5) / 10
    end

    -- Waits for a trip under way to end: the player stops on the world map,
    -- or the world map closes under them. Returns how it ended: "stopped",
    -- "left" (the map closed) or "still_travelling".
    local function await_trip()
        local ended = core.wait_until(function()
            if mode() ~= "world_map" then
                return true
            end
            local raw = fo.world_map()
            return raw == nil or not raw.moving
        end, TRIP_TIMEOUT_MS)

        if not ended then
            return "still_travelling"
        end
        if mode() ~= "world_map" then
            await_leaving("world_map")
            return "left"
        end
        core.wait_frames(SETTLE_FRAMES)
        return "stopped"
    end

    -- Why the world map closed while the player was travelling: an
    -- encounter, a timed event that set them down where they were, or one
    -- of the game's own events (a movie, the end of the game).
    local function interruption()
        local exit = fo.world_map_exit()
        if exit == "encounter" or exit == "special_encounter" then
            return exit, "An encounter stopped the trip; you're on its map now. Its exits lead back to the world map."
        end
        if exit ~= nil then
            return "interrupted", "Something happened on the way and stopped the trip; you're on the map where it happened."
        end
        return "interrupted", "Something happened on the way and stopped the trip; the view shows where that left you."
    end

    -- The state view with `extra` merged in.
    local function view(extra)
        local result = state.view()
        for key, value in pairs(extra or {}) do
            result[key] = value
        end
        return { data = result }
    end

    -- Sets off for `town` (a known place) or the point (x, y), in pixels,
    -- and waits for the trip to end. Returns the travel report and a note.
    local function go(town, x, y)
        local start = fo.game_time()
        local report = {}

        if town ~= nil then
            report.to = town.name
            press(TOWN_BUTTON + town.id, town.name .. "'s button")
        else
            report.to = worldmap.point(x, y)
            await_read(fo.world_map_travel(x, y), "the travel command")
        end

        local ended = await_trip()
        report.hours = hours_since(start)

        if ended == "still_travelling" then
            report.result = "still_travelling"
            return report, "The trip is still under way. travel to the same place again waits for it to end."
        end

        if ended == "left" then
            local result, note = interruption()
            report.result = result
            report.position, report.terrain = worldmap.last_position()
            return report, note
        end

        -- A town counts as reached in its square, as the map has it. The
        -- map's line-stepping can stop a pixel short of a point.
        local raw = fo.world_map()
        local arrived
        if town ~= nil then
            arrived = raw.town == town.id
        else
            arrived = math.abs(raw.x - x) <= 1 and math.abs(raw.y - y) <= 1
        end

        if arrived then
            report.result = "arrived"
            return report, nil
        end

        report.result = "blocked"
        return report, "The way is impassable (the sea, or mountains too steep to cross); the trip stopped short."
    end

    core.tool({
        name = "travel",
        description = "Travels across the world map, as clicking a town's button or a point on the map does, and waits until the trip ends: arrival, impassable ground, or something on the way (a random encounter puts you on its map). Give a place the world map view lists (`to`, by name), or a point (`x` and `y`, in map squares as the view gives positions: 28 across, 30 down, north up). Time passes on the way. Works from the world map or the town map. Returns the state view with `travel`: where to, the result (arrived, blocked, encounter, special_encounter, interrupted, still_travelling) and the hours it took; a trip something stopped on the way also says where on the world map it stopped (`position`, in squares) and the `terrain` there. enter then goes into the place you've arrived at.",
        schema = core.schema({
            to = { type = "string", description = 'A place the world map lists, e.g. "Vault 15".' },
            x = { type = "number", minimum = 0, maximum = worldmap.COLUMNS, description = "A point to travel to: squares from the map's west edge." },
            y = { type = "number", minimum = 0, maximum = worldmap.ROWS, description = "And squares from its north edge." },
        }),
        run = function(args)
            local by_name = args.to ~= nil
            local by_point = args.x ~= nil or args.y ~= nil
            if by_name == by_point then
                core.fail("give either `to`, a place's name, or `x` and `y`, a point")
            end

            local x, y
            if by_point then
                if type(args.x) ~= "number" or type(args.y) ~= "number" then
                    core.fail("a point needs both x and y, in map squares")
                end
                x = math.floor(args.x * worldmap.SQUARE)
                y = math.floor(args.y * worldmap.SQUARE)
                if x < 0 or x >= worldmap.COLUMNS * worldmap.SQUARE or y < 0 or y >= worldmap.ROWS * worldmap.SQUARE then
                    core.fail(("(%s, %s) isn't on the world map: x goes from 0 to %d and y from 0 to %d"):format(args.x, args.y, worldmap.COLUMNS, worldmap.ROWS))
                end
            elseif type(args.to) ~= "string" or args.to == "" then
                core.fail("to must be a place's name, as the world map lists it")
            end

            if not on_map_screen() then
                core.fail(("travel works from the world map, not from %s. Walk to an exit leading to the world map to get there."):format(mode()))
            end

            local raw = fo.world_map()
            local town
            if by_name then
                town = worldmap.find(raw, args.to)
                if town == nil then
                    core.fail(("you don't know of a place called %q; the world map lists %s"):format(args.to, worldmap.names(raw)))
                end
            end

            -- The town's button would take you straight in; enter does that.
            if town ~= nil and raw.town == town.id then
                return view({
                    travel = { to = town.name, result = "arrived", hours = 0 },
                    note = ("You're already at %s. enter goes in."):format(town.name),
                })
            end

            to_world_map()
            local report, note = go(town, x, y)
            return view({ travel = report, note = note })
        end,
    })

    -- On the town map, goes into the place called `name`, or the only one.
    -- Returns the place and its town, or nil and a note asking which.
    local function choose_place(name)
        local town_map = worldmap.town_map()
        if town_map == nil then
            core.fail("the town map isn't showing any places")
        end

        local index
        if name ~= nil then
            local wanted = name:lower()
            for i, place in ipairs(town_map.places) do
                if place:lower() == wanted then
                    index = i
                end
            end
            if index == nil then
                core.fail(("%s has no place called %q here; you can go into %s"):format(town_map.town, name, table.concat(town_map.places, ", ")))
            end
        elseif #town_map.places == 1 then
            index = 1
        else
            return nil, ("Which part of %s? enter with `place`, one of town_map.places."):format(town_map.town)
        end

        local place = town_map.places[index]
        press(PLACE_BUTTON + index - 1, place)
        await_leaving("town_map")
        return place, town_map.town
    end

    core.tool({
        name = "enter",
        description = "Goes into the place you're standing on from the world map, as clicking your marker does: a town, or the open ground around you. A town you've been to shows its town map first, with the parts of town you know; give `place` to pick one (one alone is picked for you). On the town map, enter takes the place named. Returns the state view, on the place's map once it's loaded.",
        schema = core.schema({
            place = { type = "string", description = "On a town map, the part of town to go into, as town_map.places lists it." },
        }),
        run = function(args)
            if args.place ~= nil and (type(args.place) ~= "string" or args.place == "") then
                core.fail("place must be a name, as town_map.places lists it")
            end

            if mode() == "world_map" then
                local raw = fo.world_map()
                if raw.moving then
                    core.fail("you're still travelling; travel to the same place again waits for the trip to end")
                end

                local here = raw.here
                await_read(fo.world_map_enter(), "the enter command")
                await_leaving("world_map")

                if mode() ~= "town_map" then
                    return view({ entered = here })
                end
            elseif mode() ~= "town_map" then
                core.fail(("enter works from the world map or a town map, not from %s"):format(mode()))
            end

            local place, town = choose_place(args.place)
            if place == nil then
                return view({ note = town })
            end

            -- A place in another town than the one you're at sets you off
            -- there instead.
            if mode() == "world_map" then
                local start = fo.game_time()
                local ended = await_trip()
                local report = { to = town, hours = hours_since(start) }
                local note
                if ended == "left" then
                    report.result, note = interruption()
                    report.position, report.terrain = worldmap.last_position()
                else
                    report.result = ended == "stopped" and "arrived" or ended
                    note = ("%s is in %s, so you set off there. enter again once you've arrived."):format(place, town)
                end
                return view({ travel = report, note = note })
            end

            return view({ entered = place })
        end,
    })
end
