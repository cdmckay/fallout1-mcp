local map = require("mcp.map")
local state = require("mcp.state")

-- How much `look` brightens by default: caves and night are near-black on
-- screen, and a player would turn the brightness up.
local BRIGHT_GAMMA = 0.55

-- Where `survey` looks, as hex steps from the player: the six hex directions
-- plus straight up and down the screen (two steps each, alternating). Far
-- enough to see past the edge of the screen, and within how far the game
-- lets a player scroll the view from their character.
local SURVEY_REACH = 14
local SURVEY_SPOTS = {
    { name = "east", steps = { { 1, SURVEY_REACH } } },
    { name = "west", steps = { { 4, SURVEY_REACH } } },
    { name = "northeast", steps = { { 0, SURVEY_REACH } } },
    { name = "northwest", steps = { { 5, SURVEY_REACH } } },
    { name = "southeast", steps = { { 2, SURVEY_REACH } } },
    { name = "southwest", steps = { { 3, SURVEY_REACH } } },
    { name = "north", steps = { { 0, 8 }, { 5, 8 } } },
    { name = "south", steps = { { 2, 8 }, { 3, 8 } } },
}

return function(core)
    core.tool({
        name = "state",
        description = "What's happening now: which screen is up (mode), the keys that work there (hint), and, during a game, your character's HP, level, position, map and the date, the critters and exits you know of, what you're holding, and the message window's new lines.",
        run = function()
            return { data = state.view() }
        end,
    })

    core.tool({
        name = "look",
        description = "A screenshot of the game as the player sees it, with the same state as the state tool and, on the map, a text map: one character per hex for what's on screen, with a legend, a key to the critters' letters, and how its directions match walk_to's. The image is the game's own resolution (1024x768 here), whatever the window's size. It's brightened by default, as turning up the game's brightness would, so dark caves are readable; brighten: false gives the screen as it is, and screenshot: false leaves it out.",
        schema = core.schema({
            brighten = { type = "boolean", description = "Brighten the dark parts (default true)." },
            screenshot = { type = "boolean", description = "Include the screenshot (default true). The state and text map come either way." },
        }),
        run = function(args)
            local view = state.view()

            local text = nil
            if view.player ~= nil and (view.mode == "map" or view.mode == "combat") then
                text = map.draw(view.player)
            end

            if args.screenshot == false then
                return { data = view, text = text }
            end

            local gamma = args.brighten == false and 1.0 or BRIGHT_GAMMA
            local image, width, height = fo.screenshot(gamma)
            view.screen = { width = width, height = height }
            return { data = view, text = text, image = image }
        end,
    })

    core.tool({
        name = "survey",
        description = "Looks around without moving, as a player scrolls the view: in eight directions, about 14 hexes out, within the limits the game puts on scrolling. Exits seen are remembered and listed from then on. Returns the state view, plus `spotted`: the critters seen while looking, with distance and direction.",
        run = function()
            local player = fo.player()
            local mode = state.mode(fo.flags())
            if player == nil or (mode ~= "map" and mode ~= "combat") then
                core.fail("survey works while exploring or in combat, on the map")
            end

            local origin = fo.view_center()
            local looked = {}
            local spotted = {}

            for _, spot in ipairs(SURVEY_SPOTS) do
                local tile = player.tile
                for _, step in ipairs(spot.steps) do
                    tile = fo.tile_toward(tile, step[1], step[2])
                end

                -- Moved without redrawing, so whoever's watching sees no
                -- flicker; the view goes back at the end.
                if fo.set_view_center(tile, false) then
                    looked[#looked + 1] = spot.name
                    state.see_exits(player)
                    for _, critter in ipairs(state.critters(player, false)) do
                        spotted[critter.id] = critter
                    end
                end
            end

            fo.set_view_center(origin, true)

            local view = state.view()
            local list = {}
            for _, critter in pairs(spotted) do
                critter.screen = nil
                list[#list + 1] = critter
            end
            table.sort(list, function(a, b)
                return a.distance < b.distance
            end)
            view.spotted = list
            view.survey = { looked = looked }
            return { data = view }
        end,
    })
end
