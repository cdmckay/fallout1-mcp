return function(core)
    core.tool({
        name = "ping",
        description = "Checks that the game is running and answering. Returns the frame count, whether the game window has focus (the game runs either way), whether this is fair or omniscient mode, and the game's speed (turbo, 1 for normal).",
        run = function()
            return {
                data = {
                    pong = true,
                    frame = core.frame(),
                    window_focused = fo.window_focused(),
                    access = core.access(),
                    turbo = fo.turbo(),
                },
            }
        end,
    })
end
