local json = require("lib.dkjson")
local support = require("tests.support")

local equal, contains = support.equal, support.contains

local tests = {}

-- A fake fight with a rat (id 7) next to the player. The player has 8 AP and
-- a punch costs 3. Each attack lands, and the rat dies after `hits` of them.
-- Ending the turn hands it to the others for a few frames, which may hurt
-- the player or change the scene (`on_enemy_turn`), and back with full AP.
-- As in the game, a turn with no AP left ends by itself a moment later, or
-- with `turn_ends_at_once` as the last attack finishes, before the player's
-- side ever looks, as it does in the game when no one is waiting to join the
-- fight. The fight ends when a turn ends with no one hostile left fighting,
-- as the game ends it. Other critters are fighting unless they say otherwise.
local function setup(options)
    options = options or {}
    local core, engine = support.new({ omniscient = options.omniscient })
    local fight = {
        active = options.in_combat ~= false,
        turn_number = options.in_combat ~= false and 1 or 0,
        can_act = options.can_act ~= false,
        animating_frames = 0,
        enemy_frames = 0,
        enemy_turn_frames = options.enemy_turn_frames or 6,
        ap = options.ap or 8,
        hp = options.hp or 30,
        ammo = options.ammo,
        hits = 0,
        spent_frames = 0,
        attacks = {},
        started = {},
        approaches = {},
        rat = {
            id = 7,
            name = "Rat",
            tile = options.rat_in_reach == false and 105 or 101,
            visible = true,
            dead = false,
            hostile = true,
            far = options.rat_in_reach == false,
        },
        others = options.others or {},
    }

    local function critters()
        local list = { fight.rat }
        for _, other in ipairs(fight.others) do
            list[#list + 1] = other
        end
        return list
    end

    local function hostile_left()
        for _, critter in ipairs(critters()) do
            if critter.hostile and not critter.dead and critter.fighting ~= false then
                return true
            end
        end
        return false
    end

    fo.flags = function()
        if fight.game_over then
            return { main_menu = true }
        end
        return { in_game = true, combat = fight.active }
    end
    fo.player = function()
        if fight.game_over then
            return nil
        end
        return { name = "Max Stone", tile = 100, hp = fight.hp, max_hp = 30 }
    end
    fo.combat = function()
        if not fight.active or fight.game_over then
            return nil
        end
        local attack = { weapon = "unarmed", mode = "punch", ap_cost = 3, range = 1, aiming = false }
        if fight.ammo ~= nil then
            attack.weapon, attack.mode, attack.range = "10mm pistol", "primary", 20
            attack.ammo, attack.ammo_capacity = fight.ammo, 12
        end
        return {
            turn = fight.can_act and "Max Stone" or "Rat",
            turn_number = fight.turn_number,
            can_act = fight.can_act,
            animating = fight.animating_frames > 0,
            ap = fight.ap,
            max_ap = 8,
            free_move = 0,
            attack = attack,
        }
    end
    fo.critters = function()
        if fight.game_over then
            error("no game in progress")
        end
        local list = {}
        for _, critter in ipairs(critters()) do
            local entry = {}
            for k, v in pairs(critter) do
                entry[k] = v
            end
            entry.fighting = fight.active and critter.fighting ~= false
            if fight.active and not critter.dead then
                if critter.far then
                    entry.why_not = "out of range"
                elseif fight.ap < 3 then
                    entry.why_not = "not enough AP"
                end
                entry.can_attack = entry.why_not == nil
            end
            list[#list + 1] = entry
        end
        return list
    end
    fo.approach = function(id, reserve)
        fight.approaches[#fight.approaches + 1] = { id = id, reserve = reserve }
        if fight.ap - reserve <= 0 then
            return false
        end
        fight.animating_frames = 4
        if options.rat_too_far then
            fight.ap = reserve
        else
            fight.ap = fight.ap - 1
            fight.rat.far = false
            fight.rat.tile = 101
        end
        return true
    end

    local function hit(id)
        fight.attacks[#fight.attacks + 1] = id
        fight.ap = fight.ap - 3
        fight.animating_frames = 4
        if fight.ammo ~= nil then
            fight.ammo = fight.ammo - 1
        end
        fight.hits = fight.hits + 1
        if fight.hits >= (options.hits or 1) then
            fight.rat.dead = true
            fight.rat.hostile = false
        end
    end

    fo.attack = function(id)
        if options.refuse then
            return false, "out of range"
        end
        if fight.ap < 3 then
            return false, "not enough AP"
        end
        hit(id)
        return true
    end
    fo.start_fight = function(id)
        fight.started[#fight.started + 1] = id
        fight.active = true
        fight.turn_number = 1
        fight.can_act = true
        hit(id)
    end
    local queue = {}
    fo.inject = function(code)
        queue[#queue + 1] = code
        return true
    end
    fo.input_pending = function()
        return #queue > 0
    end

    local function end_turn()
        fight.can_act = false
        fight.spent_frames = 0
        if hostile_left() then
            fight.enemy_frames = fight.enemy_turn_frames
        else
            fight.active = false
        end
    end

    local frames = engine.frames
    engine.frames = function(n)
        for _ = 1, n or 1 do
            if #queue > 0 then
                local code = table.remove(queue, 1)
                if code == 32 and fight.can_act then
                    end_turn()
                end
            end
            if fight.animating_frames > 0 then
                fight.animating_frames = fight.animating_frames - 1
                if fight.animating_frames == 0 and options.turn_ends_at_once and fight.can_act and fight.ap <= 0 then
                    end_turn()
                end
            elseif fight.active and fight.can_act and fight.ap <= 0 then
                fight.spent_frames = fight.spent_frames + 1
                if fight.spent_frames >= 2 then
                    end_turn()
                end
            end
            if fight.enemy_frames > 0 then
                fight.enemy_frames = fight.enemy_frames - 1
                if fight.enemy_frames == 0 then
                    fight.hp = fight.hp - (options.enemy_damage or 0)
                    if options.on_enemy_turn then
                        options.on_enemy_turn(fight)
                    end
                    fight.turn_number = fight.turn_number + 1
                    fight.can_act = true
                    fight.ap = 8
                end
            end
            frames(1)
        end
    end

    require("tools.combat")(core)

    -- Calls a tool and runs frames until it replies.
    local function call(tool, args)
        engine.request({ id = 1, op = "call", tool = tool, args = args or {} })
        local replies = {}
        for _ = 1, 20000 do
            engine.frames(1)
            replies = engine.replies()
            if #replies > 0 then
                break
            end
        end
        assert(#replies == 1, ("expected one reply, got %d"):format(#replies))
        local reply = replies[1]
        if reply.error then
            return nil, reply.error.message
        end
        return (json.decode(reply.result.content[1].text))
    end

    return fight, call
end

-- Issue #19's measure: in play test 2 a rat that took three swings cost
-- about five calls.
function tests.a_fight_with_one_rat_is_one_call()
    local fight, call = setup({ hits = 3 })

    local view = call("attack", { target = 7 })

    equal(#fight.attacks, 3, "attacks")
    equal(view.attacks.made, 3, "attacks made")
    equal(view.attacks.target_dead, true, "the rat is dead")
    -- Two punches, out of AP, the rat's turn, the third punch, and the turn
    -- ended so the game can end the fight.
    equal(view.attacks.turns_ended, 2, "turns ended")
    equal(view.attacks.stopped_by, nil, "nothing stopped it")
    equal(view.mode, "map", "the fight is over")
    contains(view.note, "fight is over", "note")
end

function tests.attack_once_and_keep_the_turn()
    local fight, call = setup({ hits = 3 })

    local view = call("attack", { target = 7, ["repeat"] = false, end_turn = false })

    equal(#fight.attacks, 1, "attacks")
    equal(view.attacks.turns_ended, 0, "turns ended")
    equal(view.combat.ap, 5, "AP left")
    equal(view.combat.your_turn, true, "your turn")
end

function tests.attack_once_then_end_the_turn()
    local fight, call = setup({ hits = 3 })

    local view = call("attack", { target = 7, ["repeat"] = false })

    equal(#fight.attacks, 1, "attacks")
    equal(view.attacks.turns_ended, 1, "turns ended")
    equal(view.combat.ap, 8, "your next turn's AP")
end

function tests.without_end_turn_it_stops_out_of_AP()
    local fight, call = setup({ hits = 3 })

    local view = call("attack", { target = 7, end_turn = false })

    equal(#fight.attacks, 2, "attacks")
    equal(view.attacks.stopped_by, "out of AP", "stopped by")
    equal(view.attacks.turns_ended, 0, "turns ended")
    equal(view.combat.ap, 2, "AP left to spend")
end

-- Short of AP for an attack when asked, the turn ends and the attack comes
-- on the next.
function tests.short_of_AP_at_the_start_it_ends_the_turn_and_attacks_on_the_next()
    local fight, call = setup({ ap = 2, hits = 1 })

    local view = call("attack", { target = 7 })

    equal(#fight.attacks, 1, "attacks")
    equal(view.attacks.target_dead, true, "the rat is dead")
    equal(view.attacks.turns_ended, 2, "turns ended")

    local _, err = setup({ ap = 2 })
    local _, refused = err("attack", { target = 7, end_turn = false })
    contains(refused, "not enough AP", "without end_turn")
end

-- 6 AP is two punches and nothing left: the game passes the turn itself.
function tests.an_attack_that_uses_the_last_AP_waits_out_the_turn_the_game_passes()
    local fight, call = setup({ ap = 6, hits = 3 })

    local view = call("attack", { target = 7 })

    equal(#fight.attacks, 3, "attacks")
    equal(view.attacks.target_dead, true, "the rat is dead")
    equal(view.mode, "map", "the fight is over")

    fight, call = setup({ ap = 6, hits = 5, others = { { id = 9, name = "Rat", tile = 104, visible = true, dead = false, hostile = true, far = true } } })
    view = call("attack", { target = 7, end_turn = false })
    equal(#fight.attacks, 2, "attacks without end_turn")
    equal(view.attacks.turns_ended, 1, "the turn the game passed")
    equal(view.combat.your_turn, true, "the view is of the next turn")
    equal(view.combat.ap, 8, "with its AP")
    equal(view.attacks.stopped_by, "out of AP", "stopped by")

    -- A last punch that kills says so.
    fight, call = setup({ ap = 6, hits = 2, others = { { id = 9, name = "Rat", tile = 104, visible = true, dead = false, hostile = true, far = true } } })
    view = call("attack", { target = 7, end_turn = false })
    equal(view.attacks.target_dead, true, "the rat is dead")
    equal(view.attacks.stopped_by, nil, "nothing else stopped it")
end

-- Issue #32: in play test 4, with no one waiting to join the fight, the game
-- ended the turn as the last punch finished and played out the mole rats'
-- turns before the attack looked again. It took the player's next turn, AP
-- refilled, for the same one, and punched on into it.
function tests.a_turn_the_game_ends_before_the_player_could_act_is_counted()
    local fight, call = setup({ ap = 6, hits = 5, turn_ends_at_once = true })

    local view = call("attack", { target = 7, end_turn = false, min_hp = 0 })

    equal(#fight.attacks, 2, "no attack on the next turn")
    equal(view.attacks.turns_ended, 1, "the turn the game ended")
    equal(view.attacks.stopped_by, "out of AP", "stopped by")
    equal(view.combat.ap, 8, "the view is of the next turn")
    contains(view.note, "your turn passed", "note")

    -- One attack that uses the turn up ends it, and not the next one too.
    fight, call = setup({ ap = 3, hits = 5, turn_ends_at_once = true })
    view = call("attack", { target = 7, ["repeat"] = false, end_turn = false })
    equal(view.attacks.turns_ended, 1, "turns ended by the one attack")
    equal(view.attacks.stopped_by, "out of AP", "stopped by after one attack")

    fight, call = setup({ ap = 3, hits = 5, turn_ends_at_once = true })
    view = call("attack", { target = 7, ["repeat"] = false })
    equal(#fight.attacks, 1, "one attack")
    equal(view.attacks.turns_ended, 1, "with end_turn, still one turn ended")
    equal(fight.turn_number, 2, "the turn after the attack's is still on")
    equal(view.combat.ap, 8, "with its AP")

    -- Fighting on, each turn counts once: two punches, the rat's turn, then
    -- the third punch and the turn ended so the game can end the fight.
    fight, call = setup({ ap = 6, hits = 3, turn_ends_at_once = true })
    view = call("attack", { target = 7 })
    equal(#fight.attacks, 3, "attacks fighting on")
    equal(view.attacks.target_dead, true, "the rat is dead")
    equal(view.attacks.turns_ended, 2, "turns ended fighting on")
end

-- Opening a fight with an attack that uses the whole turn: the game passes it.
function tests.an_opening_attack_that_uses_the_turn_up_counts_it()
    local fight, call = setup({ in_combat = false, ap = 3, hits = 5, turn_ends_at_once = true })

    local view = call("attack", { target = 7, end_turn = false })

    equal(fight.started[1], 7, "fight started on the target")
    equal(view.attacks.made, 1, "the opening attack alone")
    equal(view.attacks.turns_ended, 1, "the turn the game ended")
    equal(view.attacks.stopped_by, "out of AP", "stopped by")
end

function tests.a_hostile_critter_coming_into_sight_stops_it_before_the_turn_ends()
    local known = { id = 9, name = "Rat", tile = 106, visible = true, dead = false, hostile = true, far = true }
    local fight, call = setup({
        hits = 10,
        others = { known },
        on_enemy_turn = function(fight)
            fight.others[#fight.others + 1] = { id = 8, name = "Rat", tile = 103, visible = true, dead = false, hostile = true }
        end,
    })

    local view = call("attack", { target = 7 })

    equal(view.attacks.stopped_by, "a critter joined", "stopped by")
    equal(#view.attacks.joined, 1, "joined")
    equal(view.attacks.joined[1], 8, "the new rat, not the one already in sight")
    equal(view.attacks.turns_ended, 1, "turns ended")
    equal(#fight.attacks, 2, "no attack on the new turn")
    equal(view.combat.ap, 8, "the turn's AP to act on it")
end

-- Fair play can't stop for what the player can't see.
function tests.a_critter_joining_out_of_sight_doesnt_stop_it()
    local _, call = setup({
        hits = 3,
        on_enemy_turn = function(fight)
            if #fight.others == 0 then
                fight.others[1] = { id = 8, name = "Rat", tile = 130, visible = false, dead = false, hostile = true, far = true }
            end
        end,
    })

    local view = call("attack", { target = 7 })

    equal(view.attacks.target_dead, true, "fought on")
    equal(view.attacks.stopped_by, nil, "stopped by")
end

-- Play test of #32: the mole rats killed the player during their turn, and
-- the call came back with an error rather than the view.
function tests.the_player_dying_in_the_others_turn_ends_the_call_with_the_view()
    local _, call = setup({
        ap = 6,
        hits = 10,
        turn_ends_at_once = true,
        on_enemy_turn = function(fight)
            fight.game_over = true
        end,
    })

    local view, err = call("attack", { target = 7, min_hp = 0 })

    equal(err, nil, "error")
    equal(view.attacks.stopped_by, "the fight ended", "stopped by")
    equal(view.mode, "main_menu", "mode")
end

function tests.HP_low_stops_it()
    local fight, call = setup({ hits = 10, enemy_damage = 10 })

    local view = call("attack", { target = 7 })

    -- 30 HP, then 20 (above half), then 10.
    equal(view.attacks.stopped_by, "HP low", "stopped by")
    equal(view.attacks.turns_ended, 2, "turns ended")
    equal(#fight.attacks, 4, "attacks")
    contains(view.note, "down to 10", "note")

    local _, careful = setup({ hits = 10, enemy_damage = 10 })
    view = careful("attack", { target = 7, min_hp = 25 })
    equal(view.attacks.stopped_by, "HP low", "with min_hp")
    equal(view.attacks.turns_ended, 1, "turns ended with min_hp")
end

-- Already hurt is the agent's call; getting hurt again isn't.
function tests.HP_low_counts_only_damage_taken_during_the_attacks()
    local _, call = setup({ hp = 12, hits = 3 })

    local view = call("attack", { target = 7 })

    equal(view.attacks.target_dead, true, "fought on")
end

function tests.out_of_ammo_stops_it_before_the_turn_ends()
    local fight, call = setup({ hits = 5, ammo = 2, ap = 8 })

    local view = call("attack", { target = 7 })

    equal(#fight.attacks, 2, "attacks")
    equal(view.attacks.stopped_by, "out of ammo", "stopped by")
    equal(view.attacks.turns_ended, 0, "turns ended")
end

function tests.losing_sight_of_the_target_stops_it()
    local _, call = setup({
        hits = 10,
        on_enemy_turn = function(fight)
            fight.rat.visible = false
        end,
    })

    local view = call("attack", { target = 7 })

    equal(view.attacks.stopped_by, "lost sight of the target", "stopped by")
end

function tests.the_target_dead_with_others_left_keeps_the_turn()
    local fight, call = setup({ others = { { id = 9, name = "Rat", tile = 104, visible = true, dead = false, hostile = true, far = true } } })

    local view = call("attack", { target = 7 })

    equal(view.attacks.target_dead, true, "the rat is dead")
    equal(view.attacks.turns_ended, 0, "turns ended")
    equal(view.combat.ap, 5, "AP for the next target")
    equal(fight.active, true, "still fighting")
end

-- A rat that hasn't joined the fight doesn't keep it going: ending the turn
-- ends the fight, and the rat is for later.
function tests.the_target_dead_with_no_one_else_fighting_ends_the_turn_and_the_fight()
    local fight, call = setup({ others = { { id = 9, name = "Rat", tile = 109, visible = true, dead = false, hostile = true, far = true, fighting = false } } })

    local view = call("attack", { target = 7 })

    equal(view.attacks.target_dead, true, "the rat is dead")
    equal(view.attacks.turns_ended, 1, "turns ended")
    equal(fight.active, false, "the fight is over")
    equal(view.mode, "map", "mode")
    equal(view.critters[1].id, 9, "the other rat")
    equal(view.critters[1].hostile, true, "still hostile")
end

-- Two AP buys no attack on anyone, so the turn goes.
function tests.the_target_dead_with_others_left_but_no_AP_for_them_ends_the_turn()
    local _, call = setup({ hits = 2, others = { { id = 9, name = "Rat", tile = 104, visible = true, dead = false, hostile = true, far = true } } })

    local view = call("attack", { target = 7 })

    equal(view.attacks.target_dead, true, "the rat is dead")
    equal(view.attacks.turns_ended, 1, "turns ended")
    equal(view.combat.ap, 8, "your next turn")
    contains(view.note, "your turn again", "note")
end

function tests.a_fight_that_takes_too_long_stops_before_ending_another_turn()
    -- Each of the others' turns takes 16 seconds.
    local _, call = setup({ hits = 100, enemy_turn_frames = 1000 })

    local view = call("attack", { target = 7 })

    equal(view.attacks.stopped_by, "time limit", "stopped by")
    equal(view.attacks.turns_ended, 3, "turns ended")
    equal(view.combat.your_turn, true, "your turn")
end

function tests.a_melee_attack_out_of_reach_walks_up_first_keeping_the_attack_ap()
    local fight, call = setup({ rat_in_reach = false })

    local view = call("attack", { target = 7 })

    equal(fight.approaches[1].id, 7, "approached the rat")
    equal(fight.approaches[1].reserve, 3, "kept the punch's AP")
    equal(fight.attacks[1], 7, "then attacked")
    equal(view.attacks.target_dead, true, "the rat is dead")
end

function tests.a_target_no_turn_of_walking_gets_closer_to_stops_it()
    local fight, call = setup({ rat_in_reach = false, rat_too_far = true })

    local view = call("attack", { target = 7 })

    -- The call's own turn, then a whole fresh one.
    equal(#fight.approaches, 2, "approached")
    equal(#fight.attacks, 0, "no attack")
    equal(view.attacks.stopped_by, "out of reach", "stopped by")
    equal(view.attacks.turns_ended, 1, "turns ended")
end

function tests.attack_needs_a_living_target()
    local fight, call = setup()
    fight.rat.dead = true

    local _, err = call("attack", { target = 7 })

    contains(err, "no living critter 7", "dead rat")

    local _, missing = call("attack", { target = 99 })
    contains(missing, "no living critter 99", "no such critter")
end

-- Fair play refuses a critter the view doesn't list as it refuses one that
-- isn't there, so attack can't be used to find what the player can't see.
function tests.fair_play_refuses_a_critter_out_of_sight()
    local hidden = { id = 8, name = "Rat", tile = 102, visible = false, dead = false, hostile = true }
    local fight, call = setup({ others = { hidden } })

    local _, err = call("attack", { target = 8 })

    contains(err, "no living critter 8", "refused")
    equal(#fight.attacks, 0, "no attack")

    fight, call = setup({ omniscient = true, others = { hidden } })
    local view = call("attack", { target = 8, ["repeat"] = false, end_turn = false })
    equal(fight.attacks[1], 8, "omniscient mode attacks it")
    equal(view.attacks.made, 1, "attacks made")
end

function tests.attack_says_why_the_game_refused()
    local _, call = setup({ refuse = true })

    local _, err = call("attack", { target = 7 })

    contains(err, "out of range", "reason")
end

function tests.attack_out_of_turn_points_to_end_turn()
    local fight, call = setup({ can_act = false })
    fight.enemy_frames = 100000

    local _, err = call("attack", { target = 7 })

    contains(err, "end_turn", "hint")
end

function tests.attack_needs_a_target_id()
    local _, call = setup()

    local _, err = call("attack", { target = "the rat" })

    contains(err, "id", "error")
end

function tests.attack_outside_combat_starts_the_fight_and_fights_on()
    local fight, call = setup({ in_combat = false, hits = 2 })

    local view = call("attack", { target = 7 })

    equal(fight.started[1], 7, "fight started on the target")
    equal(view.attacks.made, 2, "the opening attack and one more")
    equal(view.attacks.target_dead, true, "the rat is dead")
    equal(view.mode, "map", "the fight is over")
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

-- The fight can end between the agent's view and its end_turn.
function tests.end_turn_after_the_fight_ended_just_returns_the_view()
    local _, call = setup({ in_combat = false })

    local view, err = call("end_turn")

    equal(err, nil, "error")
    equal(view.mode, "map", "mode")
    contains(view.note, "not in combat", "note")
end

return tests
