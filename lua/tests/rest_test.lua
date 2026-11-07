local json = require("lib.dkjson")
local support = require("tests.support")

local equal, contains = support.equal, support.contains

local tests = {}

local PIPBOY_KEY = 112
local ESCAPE = 27
local ALARM_CLOCK = 504
local CHOICE = 510

local TICKS_PER_HOUR = 36000

-- Frames a rest takes on the fake clock, each hour of it.
local FRAMES_PER_HOUR = 2

-- A fake Pip-Boy and alarm clock. Max Stone is on the map at 5 of 43 HP,
-- healing 2 HP every 3 hours of rest, as the real clock heals. Screens read
-- one injected code a frame, the way the real ones do; a rest takes
-- FRAMES_PER_HOUR frames an hour, with the Pip-Boy up. Options:
--   screen           "map" (default), "pipboy" or "combat"
--   hp               HP to start with
--   cannot_rest      the game refuses a rest here
--   interrupt_after  frames into a rest before something cuts it short and
--                    closes the Pip-Boy
--   omniscient       omniscient mode
local function setup(options)
    options = options or {}
    local core, engine = support.new({ omniscient = options.omniscient })

    local game = {
        screen = options.screen or "map",
        hp = options.hp or 5,
        max_hp = 43,
        healing_rate = 2,
        rested_minutes = 0,
        -- 7:21 in the morning.
        time = 7 * TICKS_PER_HOUR + 21 * 600,
        alarm_clock = false,
        rest = nil,
        interrupted = false,
        pending = nil,
        keys = {},
    }

    -- Hours until the clock next reads `hour`.
    local function hours_until(hour)
        local now = (game.time // TICKS_PER_HOUR) % 24
        local hours = (hour - now) % 24
        return hours == 0 and 24 or hours
    end

    -- The clock's choices, as offsets from CHOICE: hours to rest.
    local function hours_for(choice)
        if choice >= 2 and choice <= 7 then
            return choice - 1
        end
        if choice == 8 then
            return hours_until(6)
        elseif choice == 9 then
            return hours_until(12)
        elseif choice == 10 then
            return hours_until(18)
        elseif choice == 11 then
            return hours_until(0)
        elseif choice == 12 then
            return math.ceil((game.max_hp - game.hp) / game.healing_rate) * 3
        end
        return 0
    end

    local function read(code)
        game.keys[#game.keys + 1] = code
        if game.screen == "map" and code == PIPBOY_KEY then
            game.screen = "pipboy"
            game.alarm_clock = false
        elseif game.screen == "pipboy" then
            if code == ESCAPE then
                game.screen = "map"
            elseif code == ALARM_CLOCK then
                game.alarm_clock = true
            elseif game.alarm_clock and code >= CHOICE and code < CHOICE + 14 then
                local hours = hours_for(code - CHOICE)
                game.interrupted = false
                game.rest = { hours_left = hours, frames = 0 }
            end
        end
    end

    -- An hour of rest: the clock moves on, and every 3 hours heal.
    local function rest_an_hour()
        game.time = game.time + TICKS_PER_HOUR
        game.rested_minutes = game.rested_minutes + 60
        if game.rested_minutes >= 180 then
            game.rested_minutes = 0
            game.hp = math.min(game.max_hp, game.hp + game.healing_rate)
        end
        game.rest.hours_left = game.rest.hours_left - 1
    end

    local function rest_a_frame()
        local rest = game.rest
        rest.frames = rest.frames + 1
        if options.interrupt_after and rest.frames >= options.interrupt_after then
            game.rest = nil
            game.interrupted = true
            game.screen = "map"
            return
        end
        if rest.frames % FRAMES_PER_HOUR == 0 then
            rest_an_hour()
        end
        if rest.hours_left <= 0 then
            game.rest = nil
        end
    end

    fo.flags = function()
        local flags = { in_game = true }
        if game.screen == "pipboy" then
            flags.screen = "pipboy"
        elseif game.screen == "combat" then
            flags.combat = true
        end
        return flags
    end
    fo.player = function()
        return {
            name = "Max Stone",
            hp = game.hp,
            max_hp = game.max_hp,
            tile = 100,
            elevation = 0,
            map = { file = "V13ENT.MAP", name = "Vault 13" },
        }
    end
    fo.game_time = function()
        return game.time
    end
    fo.can_rest = function()
        return not options.cannot_rest
    end
    fo.resting = function()
        return game.rest ~= nil, game.interrupted
    end
    fo.hurt = function(hp, poison)
        game.hurt = { hp, poison }
        game.hp = math.max(1, game.hp - hp)
    end
    fo.inject = function(code)
        game.pending = code
        return true
    end
    fo.input_pending = function()
        return game.pending ~= nil
    end

    local frames = engine.frames
    engine.frames = function(n)
        for _ = 1, n or 1 do
            if game.rest ~= nil then
                rest_a_frame()
            elseif game.pending ~= nil then
                local code = game.pending
                game.pending = nil
                read(code)
            end
            frames(1)
        end
    end

    require("tools.rest")(core)

    -- Calls rest (or `tool`) and runs frames until it replies. Returns the
    -- view or nil and the error, and records whether a rest was still going
    -- when it replied.
    local function call(args, tool)
        engine.request({ id = 1, op = "call", tool = tool or "rest", args = args or {} })
        local replies
        for _ = 1, 2000 do
            engine.frames(1)
            replies = engine.replies()
            if #replies > 0 then
                break
            end
        end
        assert(#replies == 1, "no reply")
        game.resting_at_reply = game.rest ~= nil
        local reply = replies[1]
        if reply.error then
            return nil, reply.error.message
        end
        return (json.decode(reply.result.content[1].text))
    end

    return game, call
end

function tests.rest_opens_the_alarm_clock_rests_and_closes_the_pipboy()
    local game, call = setup()

    local view = call({ hours = 6 })

    equal(game.keys[1], PIPBOY_KEY, "p opens the Pip-Boy")
    equal(game.keys[2], ALARM_CLOCK, "then the alarm clock")
    equal(game.keys[3], CHOICE + 7, "its six hours")
    equal(game.keys[4], ESCAPE, "then escape closes it")
    equal(view.mode, "map", "back on the map")
    equal(view.rest.hours, 6, "hours rested")
    equal(view.rest.hp_gained, 4, "2 HP every 3 hours")
    equal(view.rest.result, "rested", "result")
    equal(view.player.hp, 9, "the view's HP")
    equal(view.note, nil, "no note")
end

function tests.rest_waits_until_the_clock_stops()
    local game, call = setup()

    call({ hours = 3 })

    equal(game.resting_at_reply, false, "replied once the rest was over")
end

function tests.more_than_six_hours_is_several_of_the_clock_s_rests()
    local game, call = setup()

    local view = call({ hours = 8 })

    equal(game.keys[3], CHOICE + 7, "six hours")
    equal(game.keys[4], CHOICE + 3, "then two")
    equal(view.rest.hours, 8, "hours rested")
end

function tests.rest_until_healed_picks_the_clock_s_choice_and_heals()
    local game, call = setup({ hp = 5 })

    local view = call({ ["until"] = "healed" })

    equal(game.keys[3], CHOICE + 12, "until healed")
    equal(view.rest.hp_gained, 38, "HP gained")
    equal(view.player.hp, 43, "healed")
    equal(view.rest.hours, 57, "19 rounds of 3 hours")
end

function tests.rest_until_a_time_of_day_picks_its_choice()
    local game, call = setup()

    local view = call({ ["until"] = "noon" })

    equal(game.keys[3], CHOICE + 9, "until noon")
    equal(view.rest.hours, 5, "from 7:21 to noon on the fake clock")
end

function tests.rest_from_the_pipboy_goes_straight_to_the_alarm_clock()
    local game, call = setup({ screen = "pipboy" })

    local view = call({ hours = 1 })

    equal(game.keys[1], ALARM_CLOCK, "the alarm clock")
    equal(game.keys[2], CHOICE + 2, "one hour")
    equal(view.mode, "map", "closed")
end

function tests.an_interrupted_rest_says_so()
    local game, call = setup({ interrupt_after = 7 })

    local view = call({ hours = 6 })

    equal(view.rest.result, "interrupted", "result")
    equal(view.rest.hours, 3, "three hours in")
    contains(view.note, "cut the rest short", "note")
    equal(#game.keys, 3, "the Pip-Boy closed itself, so no escape")
end

function tests.an_interrupted_long_rest_goes_no_further()
    local game, call = setup({ interrupt_after = 5 })

    local view = call({ hours = 12 })

    equal(view.rest.result, "interrupted", "result")
    equal(view.rest.hours, 2, "two hours in")
    equal(#game.keys, 3, "no second six hours")
end

function tests.rest_refuses_where_the_game_says_you_cannot_rest()
    local game, call = setup({ cannot_rest = true })

    local _, err = call({ hours = 6 })

    contains(err, "You cannot rest at this location!", "the game's words")
    equal(#game.keys, 0, "nothing pressed")
end

function tests.rest_refuses_in_combat()
    local game, call = setup({ screen = "combat" })

    local _, err = call({ hours = 6 })

    contains(err, "can't rest in combat", "error")
    equal(#game.keys, 0, "nothing pressed")
end

function tests.resting_until_healed_at_full_hp_refuses()
    local game, call = setup({ hp = 43 })

    local _, err = call({ ["until"] = "healed" })

    contains(err, "already at full HP (43 of 43)", "error")
    equal(#game.keys, 0, "nothing pressed")
end

function tests.rest_needs_hours_or_until()
    local _, call = setup()

    local _, neither = call({})
    local _, both = call({ hours = 2, ["until"] = "noon" })
    local _, too_long = call({ hours = 25 })
    local _, fraction = call({ hours = 2.5 })
    local _, unknown = call({ ["until"] = "dawn" })

    contains(neither, "either `hours` or `until`", "neither")
    contains(both, "either `hours` or `until`", "both")
    contains(too_long, "from 1 to 24", "too long")
    contains(fraction, "whole number", "a fraction")
    contains(unknown, "healed, morning, noon, evening or midnight", "an unknown time")
end

function tests.hurt_is_for_omniscient_mode_only()
    local _, fair = setup()
    local _, err = fair({ hp = 10 }, "hurt")
    contains(err, "unknown tool", "fair play")

    local game, omniscient = setup({ omniscient = true, hp = 43 })
    local view = omniscient({ hp = 10, poison = 4 }, "hurt")
    equal(game.hurt[1], 10, "hp")
    equal(game.hurt[2], 4, "poison")
    equal(view.player.hp, 33, "the view's HP")
end

function tests.the_pipboy_hint_names_the_rest_tool()
    setup({ screen = "pipboy" })

    local view = require("mcp.state").view()

    contains(view.hint, "rest rests", "names the tool")
end

return tests
