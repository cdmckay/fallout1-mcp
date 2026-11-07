local state = require("mcp.state")

-- Resting goes through the Pip-Boy's alarm clock, as a player does it: p
-- opens the Pip-Boy, its button 504 opens the alarm clock, and the clock's
-- choices are event codes from 510, in the order it lists them
-- (PipboyRestDuration, src/game/pipboy.cc).
local PIPBOY_KEY = 112
local ESCAPE = 27
local ALARM_CLOCK = 504
local CHOICE = 510

-- The clock's choices, as offsets from CHOICE. Its hours go up to six.
local ONE_HOUR = 2
local MOST_HOURS = 6
local UNTIL = {
    morning = 8,
    noon = 9,
    evening = 10,
    midnight = 11,
    healed = 12,
}
local UNTIL_NAMES = "healed, morning, noon, evening or midnight"

-- The longest rest by hours; longer ones are several in a row, as a player
-- would pick the clock's six hours again.
local MAX_HOURS = 24

-- How long the Pip-Boy may take to read a key or button, and to open or
-- close.
local READ_TIMEOUT_MS = 5000
local SCREEN_TIMEOUT_MS = 10000

-- How long a rest may take. A day's rest takes the clock about 4 seconds
-- at normal speed, and resting until healed rests a day at a time; this
-- covers healing 200 HP at a healing rate of 1. A longer one carries on
-- after the tool returns.
local REST_TIMEOUT_MS = 300000

-- Frames for the screen to settle once it has changed.
local SETTLE_FRAMES = 3

-- The game clock runs in tenths of a second.
local TICKS_PER_HOUR = 36000

return function(core)
    local function mode()
        return state.mode(fo.flags())
    end

    -- Queues `code` and waits until the screen in front has read it.
    local function press(code, what)
        if not fo.inject(code) then
            core.fail("the game's input queue is full; try again in a moment")
        end
        if not core.wait_until(function()
            return not fo.input_pending()
        end, READ_TIMEOUT_MS) then
            core.fail(("the game didn't read %s"):format(what))
        end
        -- The screen acts on the code in the frame that reads it.
        core.wait_frames(1)
    end

    local function await_mode(predicate, what)
        if not core.wait_until(function()
            return predicate(mode())
        end, SCREEN_TIMEOUT_MS) then
            core.fail(what)
        end
        core.wait_frames(SETTLE_FRAMES)
    end

    -- The clock's choices that make up a rest of `hours`: six hours at a
    -- time, then what's left.
    local function by_hours(hours)
        local choices = {}
        while hours > 0 do
            local step = math.min(hours, MOST_HOURS)
            choices[#choices + 1] = ONE_HOUR + step - 1
            hours = hours - step
        end
        return choices
    end

    local function hours_since(start)
        return math.floor((fo.game_time() - start) / TICKS_PER_HOUR * 10 + 0.5) / 10
    end

    -- Rests through each of the clock's choices in turn, and returns how it
    -- ended: "rested", "interrupted" (something cut it short) or
    -- "still_resting".
    local function rest_through(choices)
        for _, choice in ipairs(choices) do
            -- Something that cuts a rest short closes the Pip-Boy.
            if mode() ~= "pipboy" then
                return "interrupted"
            end

            press(CHOICE + choice, "the alarm clock's choice")
            if not core.wait_until(function()
                return not fo.resting()
            end, REST_TIMEOUT_MS) then
                return "still_resting"
            end

            local _, cut_short = fo.resting()
            if cut_short then
                return "interrupted"
            end
        end
        return "rested"
    end

    core.tool({
        name = "rest",
        description = "Rests, as the Pip-Boy's alarm clock does, for a number of hours or until a time of day or until healed, and waits until the clock stops or something interrupts the rest. Time passes and HP comes back at your healing rate (every 3 hours). Works from the map or the Pip-Boy, not in combat, and the game refuses where it says \"You cannot rest at this location!\": outside the towns while anything alive on this level isn't on your side, and anywhere while someone you've hit is alive. Returns the state view, back on the map, with `rest`: the hours rested, the HP gained and the result (rested, interrupted, still_resting).",
        schema = core.schema({
            hours = { type = "integer", minimum = 1, maximum = MAX_HOURS, description = "Hours to rest." },
            ["until"] = {
                type = "string",
                enum = { "healed", "morning", "noon", "evening", "midnight" },
                description = "Or rest until healed (HP back to the maximum), or until morning (6:00), noon, evening (18:00) or midnight.",
            },
        }),
        run = function(args)
            local by_count = args.hours ~= nil
            local by_until = args["until"] ~= nil
            if by_count == by_until then
                core.fail(("give either `hours` or `until` (%s)"):format(UNTIL_NAMES))
            end

            local choices
            if by_count then
                if math.type(args.hours) ~= "integer" or args.hours < 1 or args.hours > MAX_HOURS then
                    core.fail(("hours must be a whole number from 1 to %d; until = \"healed\" rests as long as healing takes"):format(MAX_HOURS))
                end
                choices = by_hours(args.hours)
            else
                local choice = UNTIL[args["until"]]
                if choice == nil then
                    core.fail(("until must be %s"):format(UNTIL_NAMES))
                end
                choices = { choice }
            end

            local current = mode()
            if current == "combat" then
                core.fail("you can't rest in combat")
            end
            if current ~= "map" and current ~= "pipboy" then
                core.fail(("rest works from the map or the Pip-Boy, not from %s"):format((current:gsub("_", " "))))
            end
            if fo.resting() then
                core.fail("the alarm clock is still resting from before; state shows when it stops")
            end
            if not fo.can_rest() then
                core.fail("You cannot rest at this location! Outside the towns, that's while anything alive on this level isn't on your side; anywhere, while someone you've hit is alive.")
            end

            local before = fo.player()
            if args["until"] == "healed" and before.hp >= before.max_hp then
                core.fail(("you're already at full HP (%d of %d); rest with hours to pass the time"):format(before.hp, before.max_hp))
            end

            local start = fo.game_time()

            if current == "map" then
                press(PIPBOY_KEY, "p, the Pip-Boy's key")
                await_mode(function(now)
                    return now == "pipboy"
                end, "the Pip-Boy didn't open")
            end
            press(ALARM_CLOCK, "the alarm clock's button")

            local result = rest_through(choices)

            -- Back to the map, unless the rest is still going or something
            -- has already closed the Pip-Boy.
            if result ~= "still_resting" and mode() == "pipboy" then
                press(ESCAPE, "escape")
                await_mode(function(now)
                    return now ~= "pipboy"
                end, "the Pip-Boy didn't close")
            end

            local after = fo.player()
            local view = state.view()
            view.rest = {
                hours = hours_since(start),
                hp_gained = after.hp - before.hp,
                result = result,
            }
            if result == "interrupted" then
                view.note = "Something cut the rest short; the messages and the view say what."
            elseif result == "still_resting" then
                view.note = "The rest is still going in the Pip-Boy. state shows when the clock stops; escape stops it."
            end
            return { data = view }
        end,
    })

    core.tool({
        name = "hurt",
        description = "Omniscient mode only, for testing: takes HP from you, leaving at least 1, and poisons you if asked, as a bite does (less your poison resistance). God mode stops the HP loss, as it stops all damage. Returns the state view.",
        omniscient = true,
        schema = core.schema({
            hp = { type = "integer", minimum = 0, maximum = 1000, description = "HP to take." },
            poison = { type = "integer", minimum = 0, maximum = 100, description = "Poison to add." },
        }),
        run = function(args)
            if not fo.omniscient() then
                core.fail("hurt is for omniscient mode only")
            end
            local hp, poison = args.hp or 0, args.poison or 0
            if math.type(hp) ~= "integer" or hp < 0 or hp > 1000 then
                core.fail("hp must be a whole number from 0 to 1000")
            end
            if math.type(poison) ~= "integer" or poison < 0 or poison > 100 then
                core.fail("poison must be a whole number from 0 to 100")
            end
            if fo.player() == nil then
                core.fail("there's no game in progress")
            end

            fo.hurt(hp, poison)
            core.wait_frames(SETTLE_FRAMES)
            return { data = state.view() }
        end,
    })
end
