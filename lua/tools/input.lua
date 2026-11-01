local keys = require("mcp.keys")
local state = require("mcp.state")

-- Frames to let a screen react once it has read the input, so the view shows
-- the result: a new screen opening, a menu redrawing.
local SETTLE_FRAMES = 3

-- How long a screen may take to read an input. A screen mid-animation or
-- mid-fade doesn't read input until it's done.
local READ_TIMEOUT_MS = 5000

return function(core)
    -- Injects each code in turn, waiting until the game has read it before
    -- sending the next, so a sequence works across a change of screen.
    local ESCAPE = 27

    local function send(codes, labels)
        local unread = {}
        local skipped = false

        for i, code in ipairs(codes) do
            -- Escape skips a movie, but on the main menu it quits the game.
            -- The intro's movies end on the main menu, so a run of escapes
            -- meant for them must not carry on into it.
            if code == ESCAPE and state.mode(fo.flags()) == "main_menu" then
                skipped = true
                goto next
            end

            if not fo.inject(code) then
                core.fail("the game's input queue is full; try again in a moment")
            end

            local read = core.wait_until(function()
                return not fo.input_pending()
            end, READ_TIMEOUT_MS)

            if not read then
                unread[#unread + 1] = labels[i]
                break
            end

            core.wait_frames(SETTLE_FRAMES)

            ::next::
        end

        local view = state.view()
        if #unread > 0 then
            view.note = ("The screen hasn't read %s yet; it's queued and may still take effect. Check with state or look."):format(unread[1])
        elseif skipped then
            view.note = "Skipped escape on the main menu, where it would quit the game. To quit, press e."
        end
        return { data = view }
    end

    core.tool({
        name = "key",
        description = "Presses keys in order, as the player would, and returns the state view afterwards. Each key waits until the game has read it, so a sequence can cross a change of screen. Names: a single character (case matters: \"A\" and \"a\" differ), ctrl+<letter>, or escape, return, space, tab, backspace, insert, delete, home, end, page_up, page_down, up, down, left, right, f1 to f11. The state view's hint lists the keys each screen takes.",
        schema = core.schema({
            keys = {
                type = "array",
                items = { type = "string" },
                minItems = 1,
                maxItems = 20,
                description = "Keys to press, in order.",
            },
        }, { "keys" }),
        run = function(args)
            if type(args.keys) ~= "table" or #args.keys == 0 then
                core.fail("keys must be a non-empty list of key names")
            end

            -- Check every name before pressing anything.
            local codes = {}
            for i, name in ipairs(args.keys) do
                local code, err = keys.code(name)
                if code == nil then
                    core.fail(err)
                end
                codes[i] = code
            end

            return send(codes, args.keys)
        end,
    })

    core.tool({
        name = "press",
        description = "Presses on-screen buttons by event code, for buttons that have no key, and returns the state view afterwards. A screen's hint gives the codes where they're needed.",
        schema = core.schema({
            codes = {
                type = "array",
                items = { type = "integer" },
                minItems = 1,
                maxItems = 20,
                description = "Button event codes, in order.",
            },
        }, { "codes" }),
        run = function(args)
            if type(args.codes) ~= "table" or #args.codes == 0 then
                core.fail("codes must be a non-empty list of integers")
            end

            local labels = {}
            for i, code in ipairs(args.codes) do
                if math.type(code) ~= "integer" or code < 0 or code > 65535 then
                    core.fail(("button code %s isn't an integer from 0 to 65535"):format(tostring(code)))
                end
                labels[i] = "button " .. code
            end

            return send(args.codes, labels)
        end,
    })
end
