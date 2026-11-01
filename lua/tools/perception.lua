local state = require("mcp.state")

return function(core)
    core.tool({
        name = "state",
        description = "What's happening now: which screen is up (mode), the keys that work there (hint), and, during a game, your character's HP, level, position, map and the date.",
        run = function()
            return { data = state.view() }
        end,
    })

    core.tool({
        name = "look",
        description = "A screenshot of the game as the player sees it, with the same state as the state tool. The image is the game's own resolution (1024x768 here), whatever the window's size.",
        run = function()
            local image, width, height = fo.screenshot()
            local view = state.view()
            view.screen = { width = width, height = height }
            return { data = view, image = image }
        end,
    })
end
