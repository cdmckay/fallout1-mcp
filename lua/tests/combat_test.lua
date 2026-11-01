local json = require("lib.dkjson")
local support = require("tests.support")

local equal, contains = support.equal, support.contains

local tests = {}

-- A fake fight: the player's turn comes and goes as the test says. An attack
-- plays out over a few frames; ending the turn hands it to the rat for a few
-- frames and back.
local function setup(options)
    options = options or {}
    local core, engine = support.new()
    local fight = {
        active = options.in_combat ~= false,
        can_act = options.can_act ~= false,
        animating_frames = 0,
        enemy_frames = 0,
        attacks = {},
        started = {},
        approaches = {},
        rat = { id = 7, name = "Rat", tile = 101, dead = false, can_attack = true },
    }
    if options.rat_in_reach == false then
        fight.rat.can_attack = false
        fight.rat.why_not = "out of range"
    end

    fo.flags = function()
        return { in_game = true, combat = fight.active }
    end
    fo.player = function()
        return { name = "Max Stone", tile = 100 }
    end
    fo.combat = function()
        if not fight.active then
            return nil
        end
        return {
            turn = fight.can_act and "Max Stone" or "Rat",
            can_act = fight.can_act,
            animating = fight.animating_frames > 0,
            ap = 6,
            free_move = 0,
            attack = { weapon = "unarmed", mode = "punch", ap_cost = 3, range = 1, aiming = false },
        }
    end
    fo.critters = function()
        return { fight.rat }
    end
    fo.approach = function(id, reserve)
        fight.approaches[#fight.approaches + 1] = { id = id, reserve = reserve }
        fight.animating_frames = 4
        if not options.rat_too_far then
            fight.rat.can_attack = true
            fight.rat.why_not = nil
        end
        return true
    end
    fo.attack = function(id)
        if options.refuse then
            return false, "out of range"
        end
        fight.attacks[#fight.attacks + 1] = id
        fight.animating_frames = 4
        return true
    end
    fo.start_fight = function(id)
        fight.started[#fight.started + 1] = id
        fight.active = true
        fight.can_act = true
    end
    local queue = {}
    fo.inject = function(code)
        queue[#queue + 1] = code
        return true
    end
    fo.input_pending = function()
        return #queue > 0
    end

    local frames = engine.frames
    engine.frames = function(n)
        for _ = 1, n or 1 do
            if #queue > 0 then
                local code = table.remove(queue, 1)
                if code == 32 and fight.can_act then
                    fight.can_act = false
                    fight.enemy_frames = 6
                end
            end
            if fight.animating_frames > 0 then
                fight.animating_frames = fight.animating_frames - 1
            end
            if fight.enemy_frames > 0 then
                fight.enemy_frames = fight.enemy_frames - 1
                if fight.enemy_frames == 0 then
                    fight.can_act = true
                end
            end
            frames(1)
        end
    end

    require("tools.combat")(core)

    local function call(tool, args)
        engine.request({ id = 1, op = "call", tool = tool, args = args or {} })
        engine.frames(60)
        local reply = engine.reply()
        if reply.error then
            return nil, reply.error.message
        end
        return json.decode(reply.result.content[1].text)
    end

    return fight, call
end

function tests.attack_hits_the_target_and_waits_for_it_to_play_out()
    local fight, call = setup()

    local view = call("attack", { target = 7 })

    equal(fight.attacks[1], 7, "target")
    equal(fight.animating_frames, 0, "animation finished before the reply")
    equal(view.mode, "combat", "mode")
    equal(view.combat.your_turn, true, "your turn")
end

function tests.a_melee_attack_out_of_reach_walks_up_first_keeping_the_attack_ap()
    local fight, call = setup({ rat_in_reach = false })

    local view = call("attack", { target = 7 })

    equal(fight.approaches[1].id, 7, "approached the rat")
    equal(fight.approaches[1].reserve, 3, "kept the punch's AP")
    equal(fight.attacks[1], 7, "then attacked")
    equal(view.note, nil, "no note")
end

function tests.a_target_still_out_of_reach_after_closing_in_is_reported()
    local fight, call = setup({ rat_in_reach = false, rat_too_far = true })

    local view = call("attack", { target = 7 })

    equal(#fight.approaches, 1, "approached")
    equal(#fight.attacks, 0, "no attack")
    support.contains(view.note, "can't attack yet: out of range", "note")
end

function tests.attack_needs_a_living_target()
    local fight, call = setup()
    fight.rat.dead = true

    local _, err = call("attack", { target = 7 })

    contains(err, "no living critter 7", "dead rat")

    local _, missing = call("attack", { target = 99 })
    contains(missing, "no living critter 99", "no such critter")
end

function tests.attack_says_why_the_game_refused()
    local _, call = setup({ refuse = true })

    local _, err = call("attack", { target = 7 })

    contains(err, "out of range", "reason")
end

function tests.attack_out_of_turn_points_to_end_turn()
    local fight, call = setup({ can_act = false })
    fight.enemy_frames = 1000

    local _, err = call("attack", { target = 7 })

    contains(err, "end_turn", "hint")
end

function tests.attack_needs_a_target_id()
    local _, call = setup()

    local _, err = call("attack", { target = "the rat" })

    contains(err, "id", "error")
end

function tests.attack_outside_combat_starts_the_fight()
    local fight, call = setup({ in_combat = false })

    local view = call("attack", { target = 7 })

    equal(fight.started[1], 7, "fight started on the target")
    equal(view.mode, "combat", "mode")
end

function tests.end_turn_passes_and_waits_for_the_next_turn()
    local fight, call = setup()

    local view = call("end_turn")

    equal(fight.can_act, true, "your turn again")
    equal(view.combat.your_turn, true, "view")
end

function tests.end_turn_out_of_turn_just_waits()
    local fight, call = setup({ can_act = false })
    fight.enemy_frames = 10

    local view = call("end_turn")

    equal(view.combat.your_turn, true, "your turn")
end

function tests.end_turn_outside_combat_is_an_error()
    local _, call = setup({ in_combat = false })

    local _, err = call("end_turn")

    contains(err, "not in combat", "error")
end

return tests
