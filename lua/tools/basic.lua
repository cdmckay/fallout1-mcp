return function(core)
    core.tool({
        name = "ping",
        description = "Checks that the game is running and answering. Returns the frame count, whether the game window has focus (the game runs either way), whether this is fair or omniscient mode, the game's speed (turbo, 1 for normal), and whether god mode is on (god: your attacks always hit and kill, and you take no damage; for testing).",
        run = function()
            return {
                data = {
                    pong = true,
                    frame = core.frame(),
                    window_focused = fo.window_focused(),
                    access = core.access(),
                    turbo = fo.turbo(),
                    god = fo.god(),
                },
            }
        end,
    })

    core.tool({
        name = "show_status",
        description = "Shows a line in the game window's title saying what you're doing or checking right now, for whoever is watching the window. Say what they should look for, e.g. \"heading west for the cave exit\" or \"walking into the rats: the fight should start on my turn with 6 AP\". Update it when you move on to something else; an empty text clears it. It changes nothing in the game.",
        schema = core.schema({
            text = {
                type = "string",
                maxLength = 160,
                description = "What you're doing, and what the watcher should see.",
            },
        }, { "text" }),
        run = function(args)
            if type(args.text) ~= "string" then
                core.fail("text must be a string")
            end

            -- One line: a title can't show more.
            local text = args.text:gsub("%s+", " "):match("^%s*(.-)%s*$")
            fo.set_status(text)
            return { data = { status = text } }
        end,
    })
end
