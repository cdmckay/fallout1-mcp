local sight = require("mcp.sight")
local state = require("mcp.state")

-- How long NPC turns and an attack's animations may take to play out.
local TURN_TIMEOUT_MS = 60000

-- Frames for the result to land in the views (messages, deaths, combat
-- ending) once the animations stop.
local SETTLE_FRAMES = 3

-- A fight that runs over several turns stops ending them after this long, so
-- the call comes back well inside the bridge's two minutes even at normal
-- speed, where the others' turns take seconds each.
local FIGHT_BUDGET_MS = 45000

-- More attacks than any fight with one target needs, should something keep
-- the loop going that shouldn't.
local MAX_ATTACKS = 50

return function(core)
    -- Waits until the player can act again, or the fight is over. Returns
    -- whether that happened in time.
    local function wait_for_player()
        return core.wait_until(function()
            local combat = fo.combat()
            return combat == nil or (combat.can_act and not combat.animating)
        end, TURN_TIMEOUT_MS)
    end

    local function finish(view_note)
        core.wait_frames(SETTLE_FRAMES)
        local view = state.view()
        view.note = view_note
        return { data = view }
    end

    -- Critter `id`, if the player can see it (mcp.sight). Fair play refuses
    -- an id the view doesn't list just as it refuses one that isn't there,
    -- so an attack can't give away a critter the player can't see.
    local function seen_critter(id)
        -- The game can end during the others' turns: the player dies.
        if fo.player() == nil then
            return nil
        end
        for _, critter in ipairs(sight.critters()) do
            if critter.id == id then
                return critter
            end
        end
        return nil
    end

    -- The living hostile critters the player can see, as a set of ids; with
    -- `fighting`, only those taking part in the fight, not those that
    -- haven't joined it.
    local function hostiles(fighting)
        local ids = {}
        for _, critter in ipairs(sight.critters()) do
            if critter.hostile and not critter.dead and (critter.fighting or not fighting) then
                ids[critter.id] = true
            end
        end
        return ids
    end

    -- Hexes to a critter as the game's range checks count them, so a melee
    -- attack reaches one at 1 even when it's a multi-hex critter.
    local function distance_to(critter)
        return fo.object_distance(critter.id)
    end

    -- The number of the player's turn in this fight, or nil outside one. It
    -- tells turns apart where AP can't: the game ends a turn with no AP left
    -- by itself, and the others' turns can play out before this looks again,
    -- so the next look can be at the player's next turn, AP refilled.
    local function turn_number()
        local combat = fo.combat()
        return combat ~= nil and combat.turn_number or nil
    end

    -- Waits for the player's turn after turn `number`, or the end of the
    -- fight. Returns whether that came in time.
    local function wait_for_turn_after(number)
        return core.wait_until(function()
            local combat = fo.combat()
            return combat == nil or (combat.turn_number ~= number and combat.can_act and not combat.animating)
        end, TURN_TIMEOUT_MS)
    end

    local function wait_until_still()
        core.wait_frames(2)
        core.wait_until(function()
            local combat = fo.combat()
            return combat == nil or not combat.animating
        end, TURN_TIMEOUT_MS)
    end

    -- Ends the player's turn as the end-turn button does (Space) and waits
    -- for their next one, or the end of the fight. Returns whether that came
    -- in time.
    local function pass_turn()
        local combat = fo.combat()
        local ready
        if combat ~= nil and combat.can_act then
            fo.inject(32)
            core.wait_until(function()
                return not fo.input_pending()
            end, 5000)
            ready = wait_for_turn_after(combat.turn_number)
        else
            ready = wait_for_player()
        end
        core.wait_frames(SETTLE_FRAMES)
        return ready
    end

    -- Whether the player's turn `number` is over, or about to be: the game
    -- ends a turn with no AP left by itself, a moment after the last action,
    -- and the others' turns may have played out since.
    local function turn_over(number)
        local combat = fo.combat()
        return combat ~= nil and not (combat.turn_number == number and combat.can_act and combat.ap + combat.free_move > 0)
    end

    -- If the player's turn `number` is over (turn_over), waits for their next
    -- turn (or the end of the fight), so nothing goes on as if the turn were
    -- still on. Returns whether the turn passed, and whether the next came in
    -- time.
    local function wait_out_spent_turn(number)
        if not turn_over(number) then
            return false, true
        end
        local ready = wait_for_turn_after(number)
        core.wait_frames(SETTLE_FRAMES)
        return true, ready
    end

    -- One attack on critter `id` during the player's turn `number`, walking
    -- up to it first if it's a melee attack and the critter is out of reach,
    -- keeping back the AP for the attack, as the game's Ctrl-move does.
    -- Returns what happened: "attacked", whether the player's turn came back
    -- in time, and whether the attack used the turn's last AP, so the game
    -- passed it (see wait_out_spent_turn); "moved" (closed in, and the fight
    -- or the target changed on the way); "short of AP" and whether it moved;
    -- or "can't attack", why, and whether it moved.
    local function attack_once(id, number)
        local combat = fo.combat()
        local target = seen_critter(id)
        local moved = false

        local melee = combat.attack ~= nil and combat.attack.range <= 1
        if target.why_not == "out of range" and melee then
            if not fo.approach(id, combat.attack.ap_cost) then
                return "short of AP", false
            end
            wait_until_still()
            moved = true

            combat = fo.combat()
            target = seen_critter(id)
            if combat == nil or target == nil or target.dead then
                return "moved"
            end
        end

        if target.why_not == "out of range" or target.why_not == "not enough AP" then
            return "short of AP", moved
        end
        if target.why_not ~= nil then
            return "can't attack", target.why_not, moved
        end

        local ok, why = fo.attack(id)
        if not ok then
            if why == "not enough AP" then
                return "short of AP", moved
            end
            return "can't attack", why or "the game refused", moved
        end

        -- Let the attack's animation start before waiting for it to end.
        -- With no AP left the game passes the turn, and the wait can run on
        -- through the others' turns to the player's next.
        core.wait_frames(2)
        local ready = wait_for_player()
        core.wait_frames(SETTLE_FRAMES)
        if ready then
            local passed
            passed, ready = wait_out_spent_turn(number)
            return "attacked", ready, passed
        end
        return "attacked", ready, turn_over(number)
    end

    -- Whether the attacks should stop here: the target is dead, or something
    -- happened that the agent should decide on. Says which in `fight`.
    local function should_stop(fight)
        local target = seen_critter(fight.target)
        if target ~= nil and target.dead then
            fight.target_dead = true
            return true
        end
        local combat = fo.combat()
        local player = fo.player()
        if combat == nil or player == nil then
            fight.stopped_by = "the fight ended"
            return true
        end
        if target == nil then
            fight.stopped_by = "lost sight of the target"
            return true
        end

        if player.hp < fight.start_hp and player.hp <= fight.min_hp then
            fight.stopped_by = "HP low"
            return true
        end

        local joined = {}
        for id in pairs(hostiles()) do
            if not fight.known[id] then
                joined[#joined + 1] = id
            end
        end
        if #joined > 0 then
            table.sort(joined)
            fight.joined = joined
            fight.stopped_by = "a critter joined"
            return true
        end

        local attack = combat.attack
        if attack ~= nil and attack.ammo_capacity ~= nil and attack.ammo == 0 then
            fight.stopped_by = "out of ammo"
            return true
        end

        return false
    end

    -- What a note says about how the attacks ended.
    local function explain(fight, view)
        local reason = fight.stopped_by
        if fight.target_dead then
            if fight.ended_turn_after then
                return view.combat == nil and "The target is dead, and the turn was ended; the fight is over." or "The target is dead, and the turn was ended; it's your turn again."
            end
            return "The target is dead."
        elseif reason == "the fight ended" then
            return "The fight is over."
        elseif reason == "lost sight of the target" then
            return "The target is out of sight."
        elseif reason == "HP low" then
            return ("Your HP is down to %d."):format(view.player.hp)
        elseif reason == "a critter joined" then
            return "Someone hostile came into the fight; see critters."
        elseif reason == "out of ammo" then
            return "Your weapon is out of ammo; reload to keep shooting."
        elseif reason == "out of AP" then
            if view.combat ~= nil and view.combat.ap == view.combat.max_ap then
                return "The attacks used all your AP, so your turn passed; this is your next one."
            end
            return "You don't have the AP for another attack; end_turn passes the turn."
        elseif reason == "out of reach" then
            return "A whole turn didn't get you any closer to the target."
        elseif reason == "can't attack" then
            return ("You can't attack the target: %s."):format(fight.why_not)
        elseif reason == "time limit" then
            return "The fight is taking a while, so this stopped before ending another turn; attack again to carry on."
        elseif reason == "still waiting" then
            return "Still waiting for your turn when the wait ran out; end_turn waits for it."
        end
        return nil
    end

    -- The result, once the attacks stop during `turn`, if there's one to go
    -- on; the last action may have used up its AP.
    local function done(fight, turn)
        core.wait_frames(SETTLE_FRAMES)
        if turn ~= nil and fight.stopped_by ~= "still waiting" and wait_out_spent_turn(turn.number) then
            fight.turns_ended = fight.turns_ended + 1
        end
        local view = state.view()
        local result = {
            target = fight.target,
            made = fight.made,
            turns_ended = fight.turns_ended,
            target_dead = fight.target_dead or false,
            stopped_by = fight.stopped_by,
            joined = fight.joined,
            why_not = fight.why_not,
        }
        view.attacks = result
        view.note = explain(fight, view)
        return { data = view }
    end

    core.tool({
        name = "attack",
        description = "Attacks a critter, by the id the state view gives it, with the selected attack, and keeps at it until it dies, waiting out each attack and the others' turns. When you're short of AP for another attack, it ends your turn and carries on from your next, so a fight with one critter is one call. It returns the state view, with how it went in `attacks`: attacks made, turns ended, whether the target died, and otherwise what stopped it (stopped_by): the fight ended, lost sight of the target, HP low, a critter joined (its ids in joined), out of ammo, out of AP (only with end_turn false), out of reach (a turn of walking got no closer), can't attack (why_not says why), time limit (attack again to carry on), or still waiting. Those stop it before ending a turn, so you keep the AP to act on them. Once the target is dead it ends the turn if no one else in sight is fighting, so the fight can end, or if you're short of AP for another attack; otherwise it leaves you the AP to pick the next target. A melee attack on a critter out of reach walks up to it first, keeping back the AP for the attack. Outside combat, attacking someone starts a fight. Keys: n cycles the attack mode, b swaps hands.",
        schema = core.schema({
            target = { type = "integer", description = "The critter's id, from the state view." },
            ["repeat"] = { type = "boolean", description = "Keep attacking until the target dies (the default). false attacks once." },
            end_turn = { type = "boolean", description = "End your turn when you're short of AP for another attack, and carry on from your next (the default). false stops instead, leaving you the AP that's left. With repeat false, true ends the turn after the one attack." },
            min_hp = { type = "integer", minimum = 0, description = "Stop if you're hurt and your HP is down to this or lower. Defaults to half your max HP." },
        }, { "target" }),
        run = function(args)
            if math.type(args.target) ~= "integer" then
                core.fail("target must be a critter's id from the state view")
            end
            if args.min_hp ~= nil and math.type(args.min_hp) ~= "integer" then
                core.fail("min_hp must be a whole number of hit points")
            end

            local player = fo.player()
            if player == nil then
                core.fail("there's no game in progress")
            end

            local target = seen_critter(args.target)
            if target == nil or target.dead then
                core.fail(("there's no living critter %d here"):format(args.target))
            end

            local keep_on = args["repeat"] ~= false
            local end_turn = args.end_turn ~= false
            local fight = {
                target = args.target,
                made = 0,
                turns_ended = 0,
                start_hp = player.hp,
                min_hp = args.min_hp or player.max_hp // 2,
                known = hostiles(),
            }
            fight.known[args.target] = true
            local started = fo.ticks()

            -- The turn the attacks are on: its number, its attacks so far,
            -- and whether it began during the call (fresh), with how far the
            -- target was then.
            local turn

            -- A new turn has begun: the last one ended, by the game or by
            -- end_turn.
            local function next_turn()
                fight.turns_ended = fight.turns_ended + 1
                local now = seen_critter(fight.target)
                turn = { number = turn_number(), attacks = 0, distance = now ~= nil and distance_to(now) or 0, fresh = true }
            end

            local combat = fo.combat()
            if combat == nil then
                -- This runs the whole fight's loop, so it has to run outside
                -- this request; the request then follows the fight from
                -- inside it. The opening attack is the fight's first move,
                -- made in the player's first turn, which it may use up.
                core.post(fo.start_fight, args.target)
                if not core.wait_until(function()
                    return fo.combat() ~= nil
                end, 5000) then
                    core.fail("the attack didn't start a fight")
                end
                fight.made = 1
                if not wait_for_player() then
                    fight.stopped_by = "still waiting"
                    return done(fight)
                end
                core.wait_frames(SETTLE_FRAMES)

                turn = { number = 1, attacks = 1, fresh = false }
                local passed, ready = wait_out_spent_turn(turn.number)
                if passed then
                    next_turn()
                    if not ready then
                        fight.stopped_by = "still waiting"
                        return done(fight)
                    end
                    if not end_turn then
                        if not should_stop(fight) then
                            fight.stopped_by = "out of AP"
                        end
                        return done(fight, turn)
                    end
                end
            elseif not combat.can_act then
                core.fail("it isn't your turn: use end_turn to wait for it")
            else
                turn = { number = combat.turn_number, attacks = 0, fresh = false }
            end

            local moved = false

            while true do
                if fight.made > 0 or fight.turns_ended > 0 or moved then
                    if should_stop(fight) then
                        break
                    end
                end

                if fight.made > 0 and not keep_on then
                    -- The one attack asked for. end_turn ends the turn after
                    -- it, unless it used the turn up and the game passed it.
                    if end_turn and turn.attacks > 0 then
                        local ready = pass_turn()
                        next_turn()
                        if not ready then
                            fight.stopped_by = "still waiting"
                        end
                    end
                    break
                end
                if fight.made >= MAX_ATTACKS then
                    fight.stopped_by = "time limit"
                    break
                end

                local outcome, detail, extra = attack_once(fight.target, turn.number)
                if outcome == "attacked" then
                    fight.made = fight.made + 1
                    turn.attacks = turn.attacks + 1
                    if extra then
                        -- That was the turn's last AP, and the game passed it.
                        next_turn()
                    end
                    if not detail then
                        fight.stopped_by = "still waiting"
                        break
                    end
                    if extra then
                        if not end_turn then
                            if not should_stop(fight) then
                                fight.stopped_by = "out of AP"
                            end
                            break
                        end
                        -- When the attacks use up each turn, the loop is
                        -- never short of AP, where the time is checked.
                        if fo.ticks() - started > FIGHT_BUDGET_MS then
                            if not should_stop(fight) then
                                fight.stopped_by = "time limit"
                            end
                            break
                        end
                    end
                elseif outcome == "moved" then
                    moved = true
                elseif outcome == "can't attack" then
                    moved = moved or extra
                    if fight.made == 0 and fight.turns_ended == 0 and not moved then
                        core.fail(("can't attack %d: %s"):format(fight.target, detail))
                    end
                    fight.stopped_by = "can't attack"
                    fight.why_not = detail
                    break
                else -- short of AP
                    moved = moved or detail
                    local nothing_yet = fight.made == 0 and fight.turns_ended == 0 and not moved
                    if not end_turn then
                        if nothing_yet then
                            core.fail(("can't attack %d: not enough AP"):format(fight.target))
                        end
                        fight.stopped_by = "out of AP"
                        break
                    end

                    -- A fresh turn that got neither an attack in nor any
                    -- closer won't do better next time.
                    local now = seen_critter(fight.target)
                    if turn.fresh and turn.attacks == 0 and now ~= nil and distance_to(now) >= turn.distance then
                        fight.stopped_by = "out of reach"
                        break
                    end
                    if not keep_on and fight.made == 0 and not nothing_yet then
                        -- One attack asked for, and the walk up used the turn.
                        fight.stopped_by = "out of AP"
                        break
                    end
                    if fo.ticks() - started > FIGHT_BUDGET_MS then
                        fight.stopped_by = "time limit"
                        break
                    end

                    local ready = pass_turn()
                    next_turn()
                    if not ready then
                        fight.stopped_by = "still waiting"
                        break
                    end
                    moved = true
                end
            end

            -- With the target dead, the turn ends if no one else in sight is
            -- fighting, which lets the game end the fight (anyone hostile who
            -- hasn't joined is then for the agent to deal with out of
            -- combat), or if there's no AP for another attack. Otherwise the
            -- AP left is the agent's.
            local now = fo.combat()
            if fight.target_dead and end_turn and now ~= nil and now.can_act then
                local short = now.attack == nil or now.ap < now.attack.ap_cost
                if short or next(hostiles(true)) == nil then
                    fight.ended_turn_after = true
                    local ready = pass_turn()
                    next_turn()
                    if not ready then
                        fight.stopped_by = "still waiting"
                    end
                end
            end

            return done(fight, turn)
        end,
    })

    core.tool({
        name = "end_turn",
        description = "Ends your turn in combat and waits until it's your turn again or the fight is over, then returns the state view; its messages say what the others did. If it isn't your turn, this just waits for it. Outside combat it changes nothing and just returns the view.",
        run = function()
            local combat = fo.combat()
            if combat == nil then
                -- A view that showed a fight can be a moment out of date: the
                -- last enemy may have just died.
                return finish("You're not in combat; the fight may have just ended.")
            end

            if combat.can_act then
                local ready = pass_turn()
                return finish(not ready and "Still waiting for your turn when the wait ran out." or nil)
            end

            local ready = wait_for_player()
            return finish(not ready and "Still waiting for your turn when the wait ran out." or nil)
        end,
    })
end
