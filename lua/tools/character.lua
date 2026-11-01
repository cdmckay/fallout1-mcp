local character = require("mcp.character")
local keys = require("mcp.keys")
local state = require("mcp.state")

-- How long the character screen, or its perk list, may take to open or close.
local SCREEN_TIMEOUT_MS = 5000

-- How long the screen may take to read one key. Each skill point plays the
-- screen's counter animation first.
local READ_TIMEOUT_MS = 5000

-- Frames for the screen to redraw once it has read the last key.
local SETTLE_FRAMES = 3

-- Skills stop at 200%; the screen won't raise one that's there.
local SKILL_MAX = 200

local OPEN_KEY = keys.code("c")
local DONE_KEY = keys.code("return")
local CANCEL_KEY = keys.code("escape")
local RAISE_KEY = keys.code("+")
local FIRST_KEY = keys.code("home")
local NEXT_KEY = keys.code("down")

return function(core)
    -- Whether one of these tools opened the character screen, and so should
    -- close it once the job is done. A screen the agent opened itself stays
    -- open for it to look over, keep (return) or undo (escape).
    local opened_by_tool = false

    local function mode()
        return state.mode(fo.flags())
    end

    local function screen_open()
        local current = mode()
        return current == "character" or current == "perk_choice"
    end

    -- Queues `code` for the screen in front and waits until it has read it.
    local function press(code, what)
        if not fo.inject(code) then
            core.fail("the game's input queue is full; try again in a moment")
        end
        if not core.wait_until(function()
            return not fo.input_pending()
        end, READ_TIMEOUT_MS) then
            core.fail(("the character screen didn't read %s"):format(what))
        end
    end

    local function open_screen()
        if screen_open() then
            return
        end

        -- Closed since a tool opened it (escape, say), so that's over.
        opened_by_tool = false

        local current = mode()
        if current ~= "map" and current ~= "combat" then
            core.fail(("the character screen opens from the map, not from %s"):format(current))
        end

        press(OPEN_KEY, "c")
        if not core.wait_until(screen_open, SCREEN_TIMEOUT_MS) then
            core.fail("the character screen didn't open; in combat it only opens on your turn")
        end
        opened_by_tool = true
        core.wait_frames(SETTLE_FRAMES)
    end

    -- Closes the screen, keeping what was spent, if one of these tools opened
    -- it.
    local function close_screen()
        if not opened_by_tool or mode() ~= "character" then
            return
        end

        press(DONE_KEY, "return")
        if not core.wait_until(function()
            return not fo.flags().character_editor
        end, SCREEN_TIMEOUT_MS) then
            core.fail("the character screen didn't close")
        end
        opened_by_tool = false
        core.wait_frames(SETTLE_FRAMES)
    end

    -- The state view with the character sheet, whatever screen it ends on.
    local function view(extra)
        local result = state.view()
        result.character = result.character or character.sheet()
        for key, value in pairs(extra or {}) do
            result[key] = value
        end
        return { data = result }
    end

    local function check_name(value, what)
        if type(value) ~= "string" or value == "" then
            core.fail(what .. " must be a name, as the character view lists it")
        end
    end

    core.tool({
        name = "character",
        description = "Your character sheet, as the character screen shows it: SPECIAL; hit points and conditions (poisoned, crippled limbs, ...); derived stats (armor class, action points, carry weight, melee damage, resistances, sequence, healing rate, critical chance); every skill's percentage, with tagged ones marked; traits with what they do; perks; level, XP and the XP for the next level. Also what's left to spend: skill_points (including those a level-up adds when the character screen next opens) and, when a perk is waiting, perk_to_choose with its options. raise_skill and choose_perk spend them. Works anywhere in a game; no screen needed.",
        run = function()
            local sheet = character.sheet()
            if sheet == nil then
                core.fail("there's no game in progress")
            end
            return { data = sheet }
        end,
    })

    core.tool({
        name = "raise_skill",
        description = "Spends skill points on a skill, as the character screen's + does: each point raises it 1%, or 2% when tagged, up to 200%. From the map (or on your turn in combat) it opens the character screen, raises the skill and closes the screen, keeping the change; on a character screen you opened yourself it leaves the screen open (return keeps changes, escape undoes them). A waiting perk is put off until the screen next opens; choose_perk takes it. Returns the state view with the character sheet, and `raised`.",
        schema = core.schema({
            skill = { type = "string", description = 'The skill\'s name, as the character view lists it, e.g. "Small Guns".' },
            points = { type = "integer", minimum = 1, maximum = 99, description = "How many skill points to spend on it." },
        }, { "skill", "points" }),
        run = function(args)
            check_name(args.skill, "skill")
            if math.type(args.points) ~= "integer" or args.points < 1 then
                core.fail("points must be a whole number, 1 or more")
            end

            local raw = fo.character()
            if raw == nil then
                core.fail("there's no game in progress")
            end

            local skill = character.find_skill(raw, args.skill)
            if skill == nil then
                core.fail(("there's no skill called %q; the skills are %s"):format(args.skill, character.names(raw.skills)))
            end
            if raw.skill_points < args.points then
                core.fail(("you have %d skill points to spend, not %d"):format(raw.skill_points, args.points))
            end
            if skill.percent >= SKILL_MAX then
                core.fail(("%s is already at %d%%, as high as it goes"):format(skill.name, skill.percent))
            end

            open_screen()

            -- Opening the screen after a level-up may pop up the perk list
            -- first; it comes back the next time the screen opens.
            local note
            if mode() == "perk_choice" then
                press(CANCEL_KEY, "escape")
                if not core.wait_until(function()
                    return mode() == "character"
                end, SCREEN_TIMEOUT_MS) then
                    core.fail("the perk list didn't close")
                end
                note = "A perk is waiting; it was put off until the character screen next opens. choose_perk takes it."
            end

            if not fo.select_skill(skill.id) then
                core.fail("the game's input queue is full; try again in a moment")
            end
            core.wait_until(function()
                return not fo.input_pending()
            end, READ_TIMEOUT_MS)
            if fo.character().selected_skill ~= skill.name then
                core.fail(("the character screen didn't select %s"):format(skill.name))
            end

            local before = skill.percent
            local spent = 0
            for _ = 1, args.points do
                local now = character.find_skill(fo.character(), skill.name)
                if now.percent >= SKILL_MAX or fo.character().skill_points == 0 then
                    break
                end
                press(RAISE_KEY, "+")
                spent = spent + 1
            end
            core.wait_frames(SETTLE_FRAMES)

            local after = character.find_skill(fo.character(), skill.name).percent
            close_screen()

            if spent < args.points then
                note = (note and note .. " " or "") .. ("Stopped after %d points: %s reached %d%%, as high as it goes."):format(spent, skill.name, after)
            end

            return view({
                raised = { skill = skill.name, from = before, to = after, points = spent },
                note = note,
            })
        end,
    })

    core.tool({
        name = "choose_perk",
        description = "Takes a perk when one is waiting (the character view's perk_to_choose lists them, every 3 levels or 4 with Skilled), as picking it from the perk list does. From the map (or on your turn in combat) it opens the character screen, picks the perk and closes the screen, keeping it. Tag! and Mutate! then ask a second question (a skill to tag; a trait to give up, then one to take): the view's character.choice lists the options, and choose_perk with one of their names answers it. Returns the state view with the character sheet.",
        schema = core.schema({
            name = { type = "string", description = "The perk's name as the view lists it; or, when character.choice asks a follow-up question, the skill or trait to pick." },
        }, { "name" }),
        run = function(args)
            check_name(args.name, "name")

            local raw = fo.character()
            if raw == nil then
                core.fail("there's no game in progress")
            end

            -- Check the name before opening anything.
            if raw.choice == nil then
                if not raw.perk_pending then
                    core.fail("there's no perk to choose; one comes every 3 levels (4 with the Skilled trait)")
                end
                if screen_open() then
                    core.fail("the perk list was put off; it opens again the next time the character screen opens. Close this screen (return keeps your changes, escape undoes them), then call choose_perk again.")
                end
                if character.find_option(raw.perk_options, args.name) == nil then
                    core.fail(("%q isn't on offer; the perks you can take are %s"):format(args.name, character.names(raw.perk_options)))
                end

                open_screen()
                if not core.wait_until(function()
                    return fo.character().choice ~= nil
                end, SCREEN_TIMEOUT_MS) then
                    core.fail("the perk list didn't open")
                end
                raw = fo.character()
            end

            local choice = raw.choice
            local index = character.find_option(choice.options, args.name)
            if index == nil then
                core.fail(("%q isn't one of the options; they are %s"):format(args.name, character.names(choice.options)))
            end
            local picked = choice.options[index].name

            -- The list's own keys: home goes to the top, down steps one.
            press(FIRST_KEY, "home")
            for _ = 2, index do
                press(NEXT_KEY, "down")
            end
            core.wait_frames(SETTLE_FRAMES)
            local moved = fo.character().choice
            if moved == nil or moved.selected ~= index then
                core.fail(("the perk list didn't move to %s"):format(picked))
            end

            local kind = choice.kind
            press(DONE_KEY, "return")

            -- Either the list closes, or a follow-up question replaces it.
            core.wait_until(function()
                local now = fo.character().choice
                return now == nil or now.kind ~= kind
            end, SCREEN_TIMEOUT_MS)
            core.wait_frames(SETTLE_FRAMES)

            if fo.character().choice == nil then
                close_screen()
            end

            return view({ chosen = picked })
        end,
    })

    core.tool({
        name = "give_xp",
        description = "Omniscient mode only, for testing: adds experience, as a quest reward does, levelling up if it's enough. Returns the state view with the character sheet.",
        omniscient = true,
        schema = core.schema({
            amount = { type = "integer", minimum = 1, maximum = 1000000, description = "How much experience to add." },
        }, { "amount" }),
        run = function(args)
            if not fo.omniscient() then
                core.fail("give_xp is for omniscient mode only")
            end
            if math.type(args.amount) ~= "integer" or args.amount < 1 then
                core.fail("amount must be a whole number, 1 or more")
            end
            if fo.character() == nil then
                core.fail("there's no game in progress")
            end

            fo.give_xp(args.amount)
            core.wait_frames(SETTLE_FRAMES)
            return view()
        end,
    })
end
