local json = require("lib.dkjson")
local support = require("tests.support")

local equal, contains = support.equal, support.contains

local tests = {}

local SELECT_SKILL = 0x7000
local KEYS = { c = 99, ["return"] = 13, escape = 27, plus = 43, home = 327, down = 336 }

-- A fake character screen. Max Stone has Bruiser, three tagged skills and
-- skill points to spend, and the screen reads one injected code a frame, the
-- way the real one does: c opens it (and the perk list first, when a perk is
-- waiting), + raises the selected skill, home and down move the perk list,
-- return picks or closes keeping changes, escape puts the list off or closes
-- undoing them.
local function setup(options)
    options = options or {}
    local core, engine = support.new({ omniscient = options.omniscient })

    local game = {
        open = options.open or false,
        skill_points = options.skill_points or 10,
        perk_pending = options.perk_pending or false,
        selected_skill = 0,
        choice = nil,
        perks = {},
        pending = nil,
        keys = {},
        skills = {
            { id = 0, name = "Small Guns", percent = 60, tagged = true },
            { id = 1, name = "Big Guns", percent = 10 },
            { id = 2, name = "Energy Weapons", percent = 10 },
            { id = 3, name = "Unarmed", percent = 198, tagged = true },
            { id = 4, name = "Lockpick", percent = 20 },
        },
        offer = {
            { id = 0, name = "Awareness", rank = 0, description = "See exact hit points." },
            { id = 1, name = "Bonus Move", rank = 0, description = "2 free action points to move." },
            { id = 2, name = "Tag!", rank = 0, description = "A fourth tag skill." },
        },
    }

    local function open_list()
        if game.perk_pending then
            game.choice = { kind = "perk", selected = 1, options = game.offer }
        end
    end
    if game.open then
        open_list()
    end

    local function read(code)
        game.keys[#game.keys + 1] = code
        if code == KEYS.c and not game.open then
            game.open = true
            game.saved = { skill_points = game.skill_points }
            open_list()
        elseif game.choice ~= nil then
            if code == KEYS.home then
                game.choice.selected = 1
            elseif code == KEYS.down then
                game.choice.selected = math.min(game.choice.selected + 1, #game.choice.options)
            elseif code == KEYS["return"] then
                local picked = game.choice.options[game.choice.selected]
                if game.choice.kind == "perk" then
                    game.perks[#game.perks + 1] = { id = picked.id, name = picked.name, rank = 1, description = picked.description }
                    game.perk_pending = false
                    game.choice = nil
                    if picked.name == "Tag!" then
                        game.choice = { kind = "tag_skill", selected = 1, options = { game.skills[2], game.skills[5] } }
                    end
                else
                    game.skills[picked.id + 1].tagged = true
                    game.choice = nil
                end
            elseif code == KEYS.escape then
                game.choice = nil
            end
        elseif game.open then
            if code >= SELECT_SKILL and code < SELECT_SKILL + #game.skills then
                game.selected_skill = code - SELECT_SKILL
            elseif code == KEYS.plus then
                local skill = game.skills[game.selected_skill + 1]
                game.skill_points = game.skill_points - 1
                skill.percent = skill.percent + (skill.tagged and 2 or 1)
            elseif code == KEYS["return"] then
                game.open = false
            elseif code == KEYS.escape then
                game.open = false
                game.skill_points = game.saved.skill_points
            end
        end
    end

    fo.flags = function()
        local flags = { in_game = true, character_editor = game.open }
        if game.open then
            flags.screen = game.choice ~= nil and "perk_choice" or "character"
        end
        return flags
    end
    fo.player = function()
        return { name = "Max Stone", tile = 100 }
    end
    fo.inject = function(code)
        game.pending = code
        return true
    end
    fo.input_pending = function()
        return game.pending ~= nil
    end
    fo.select_skill = function(id)
        game.pending = SELECT_SKILL + id
        return true
    end
    fo.give_xp = function(amount)
        game.xp = amount
        return amount
    end
    fo.character = function()
        local skills = {}
        for i, skill in ipairs(game.skills) do
            skills[i] = { id = skill.id, name = skill.name, percent = skill.percent, tagged = skill.tagged or false }
        end
        local raw = {
            name = "Max Stone",
            level = 3,
            xp = 3000,
            next_level_xp = 6000,
            hp = 30,
            max_hp = 33,
            screen_open = game.open,
            special = { strength = 10, agility = 6 },
            derived = { action_points = 6 },
            conditions = {},
            skills = skills,
            traits = { { id = 1, name = "Bruiser", description = "Your action points are lowered." } },
            perks = game.perks,
            skill_points = game.skill_points,
            perk_pending = game.perk_pending,
            selected_skill = game.open and game.skills[game.selected_skill + 1].name or nil,
            choice = game.choice,
        }
        if game.perk_pending and game.choice == nil then
            raw.perk_options = game.offer
        end
        return raw
    end

    local frames = engine.frames
    engine.frames = function(n)
        for _ = 1, n or 1 do
            if game.pending ~= nil then
                local code = game.pending
                game.pending = nil
                read(code)
            end
            frames(1)
        end
    end

    require("tools.character")(core)

    local function call(tool, args)
        engine.request({ id = 1, op = "call", tool = tool, args = args or {} })
        engine.frames(400)
        local reply = engine.reply()
        if reply.error then
            return nil, reply.error.message
        end
        local text = reply.result.content[1].text
        return (json.decode(text))
    end

    return game, call, engine
end

local function find(list, name)
    for _, item in ipairs(list) do
        if item.name == name then
            return item
        end
    end
    return nil
end

function tests.the_sheet_shows_skills_tags_and_what_traits_do()
    local _, call = setup()

    local sheet = call("character")

    equal(sheet.name, "Max Stone", "name")
    equal(sheet.derived.action_points, 6, "AP")
    equal(find(sheet.skills, "Small Guns").tagged, true, "tagged")
    equal(find(sheet.skills, "Big Guns").tagged, nil, "untagged")
    equal(sheet.traits[1].name, "Bruiser", "trait")
    contains(sheet.traits[1].effect, "-2 action points", "Bruiser's effect")
    equal(sheet.skill_points, 10, "skill points")
    equal(sheet.perk_to_choose, nil, "no perk waiting")
end

function tests.a_waiting_perk_comes_with_its_options()
    local _, call = setup({ perk_pending = true })

    local sheet = call("character")

    equal(#sheet.perk_to_choose.options, 3, "options")
    equal(sheet.perk_to_choose.options[1].name, "Awareness", "first option")
    contains(sheet.perk_to_choose.options[1].description, "hit points", "description")
end

function tests.raise_skill_opens_the_screen_raises_it_and_closes_it()
    local game, call = setup()

    local view = call("raise_skill", { skill = "lockpick", points = 4 })

    equal(game.open, false, "screen closed")
    equal(game.skill_points, 6, "points left")
    equal(game.skills[5].percent, 24, "Lockpick")
    equal(view.raised.skill, "Lockpick", "skill")
    equal(view.raised.from, 20, "from")
    equal(view.raised.to, 24, "to")
    equal(view.raised.points, 4, "points spent")
    equal(view.character.skill_points, 6, "sheet in the view")
    equal(game.keys[1], KEYS.c, "opened with c")
    equal(game.keys[2], SELECT_SKILL + 4, "selected Lockpick")
    equal(game.keys[#game.keys], KEYS["return"], "closed keeping changes")
end

function tests.a_tagged_skill_gains_two_percent_a_point()
    local game, call = setup()

    local view = call("raise_skill", { skill = "Small Guns", points = 3 })

    equal(game.skills[1].percent, 66, "Small Guns")
    equal(view.raised.points, 3, "points spent")
end

function tests.raise_skill_stops_at_the_cap()
    local game, call = setup()

    local view = call("raise_skill", { skill = "Unarmed", points = 5 })

    equal(game.skills[4].percent, 200, "Unarmed")
    equal(view.raised.points, 1, "points spent")
    equal(game.skill_points, 9, "points left")
    contains(view.note, "as high as it goes", "note")
end

function tests.raise_skill_checks_before_opening_anything()
    local game, call = setup()

    local _, too_many = call("raise_skill", { skill = "Lockpick", points = 11 })
    contains(too_many, "10 skill points", "too many points")

    local _, unknown = call("raise_skill", { skill = "Lock Pick", points = 1 })
    contains(unknown, "Lockpick", "unknown skill lists the skills")

    equal(#game.keys, 0, "keys pressed")
end

function tests.a_screen_the_agent_opened_stays_open()
    local game, call = setup({ open = true })

    local view = call("raise_skill", { skill = "Big Guns", points = 2 })

    equal(game.open, true, "still open")
    equal(game.skills[2].percent, 12, "Big Guns")
    equal(view.mode, "character", "mode")
    equal(view.character.selected_skill, "Big Guns", "selected")
end

function tests.raise_skill_puts_off_a_perk_list_that_pops_up()
    local game, call = setup({ perk_pending = true })

    local view = call("raise_skill", { skill = "Lockpick", points = 1 })

    equal(game.skills[5].percent, 21, "Lockpick")
    equal(game.perk_pending, true, "perk still waiting")
    equal(game.open, false, "screen closed")
    contains(view.note, "choose_perk", "note")
end

function tests.choose_perk_opens_the_list_picks_by_name_and_closes()
    local game, call = setup({ perk_pending = true })

    local view = call("choose_perk", { name = "bonus move" })

    equal(view.chosen, "Bonus Move", "chosen")
    equal(game.perks[1].name, "Bonus Move", "perk taken")
    equal(game.open, false, "screen closed")
    equal(view.character.perks[1].name, "Bonus Move", "sheet shows it")
    equal(view.character.perk_to_choose, nil, "nothing left to choose")
end

function tests.choose_perk_checks_before_opening_anything()
    local game, call = setup({ perk_pending = true })

    local _, err = call("choose_perk", { name = "Toughness" })

    contains(err, "Awareness, Bonus Move, Tag!", "lists the options")
    equal(#game.keys, 0, "keys pressed")

    local _, none = setup()
    local _, nothing = none("choose_perk", { name = "Awareness" })
    contains(nothing, "no perk to choose", "no perk waiting")
end

function tests.tag_asks_a_follow_up_that_choose_perk_answers()
    local game, call = setup({ perk_pending = true })

    local view = call("choose_perk", { name = "Tag!" })

    equal(view.mode, "perk_choice", "still choosing")
    equal(view.character.choice.kind, "tag_skill", "follow-up")
    equal(view.character.choice.options[2].name, "Lockpick", "option")
    equal(game.open, true, "screen open")

    view = call("choose_perk", { name = "Lockpick" })

    equal(game.skills[5].tagged, true, "Lockpick tagged")
    equal(game.open, false, "screen closed once done")
    equal(view.chosen, "Lockpick", "chosen")
end

function tests.the_state_view_says_what_there_is_to_spend()
    setup({ perk_pending = true })

    local map_view = require("mcp.state").view()
    equal(map_view.player.unspent.skill_points, 10, "skill points")
    equal(map_view.player.unspent.perk, true, "perk")
    equal(map_view.character, nil, "no sheet on the map")
end

function tests.the_character_screen_s_view_carries_the_sheet()
    setup({ open = true })

    local view = require("mcp.state").view()

    equal(view.mode, "character", "mode")
    equal(view.character.name, "Max Stone", "sheet")
    equal(view.player.unspent, nil, "the sheet says it instead")
end

function tests.give_xp_is_for_omniscient_mode_only()
    local _, fair = setup()
    local _, err = fair("give_xp", { amount = 1000 })
    contains(err, "unknown tool", "fair play")

    local game, omniscient = setup({ omniscient = true })
    local view = omniscient("give_xp", { amount = 1000 })
    equal(game.xp, 1000, "experience")
    equal(view.character.name, "Max Stone", "sheet")
end

return tests
