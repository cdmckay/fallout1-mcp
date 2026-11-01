local state = require("mcp.state")

-- How long NPC turns and an attack's animations may take to play out.
local TURN_TIMEOUT_MS = 60000

-- Frames for the result to land in the views (messages, deaths, combat
-- ending) once the animations stop.
local SETTLE_FRAMES = 3

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

    local function find_critter(id)
        for _, critter in ipairs(fo.critters()) do
            if critter.id == id then
                return critter
            end
        end
        return nil
    end

    local function wait_until_still()
        core.wait_frames(2)
        core.wait_until(function()
            local combat = fo.combat()
            return combat == nil or not combat.animating
        end, TURN_TIMEOUT_MS)
    end

    core.tool({
        name = "attack",
        description = "Attacks a critter, by the id the state view gives it, with the selected attack, and waits until the attack and anything it sets off have played out. Returns the state view, whose messages say what happened. A melee attack on a critter out of reach walks up to it first, keeping back the AP for the attack. The combat view shows each critter's hit chance and whether it can be attacked now. Outside combat, attacking someone starts a fight. Keys: n cycles the attack mode, b swaps hands.",
        schema = core.schema({
            target = { type = "integer", description = "The critter's id, from the state view." },
        }, { "target" }),
        run = function(args)
            if math.type(args.target) ~= "integer" then
                core.fail("target must be a critter's id from the state view")
            end

            if fo.player() == nil then
                core.fail("there's no game in progress")
            end

            local combat = fo.combat()
            if combat == nil then
                -- This runs the whole fight's loop, so it has to run outside
                -- this request; the request then follows the fight from
                -- inside it.
                core.post(fo.start_fight, args.target)
                if not core.wait_until(function()
                    return fo.combat() ~= nil
                end, 5000) then
                    core.fail("the attack didn't start a fight")
                end
                local ready = wait_for_player()
                return finish(not ready and "Still waiting for your turn when the wait ran out." or nil)
            end

            if not combat.can_act then
                core.fail("it isn't your turn: use end_turn to wait for it")
            end

            local target = find_critter(args.target)
            if target == nil or target.dead then
                core.fail(("there's no living critter %d here"):format(args.target))
            end

            -- A melee attack out of reach walks up first, keeping back the
            -- AP the attack needs, as the game's Ctrl-move does.
            local melee = combat.attack ~= nil and combat.attack.range <= 1
            if target.why_not == "out of range" and melee then
                if not fo.approach(args.target, combat.attack.ap_cost) then
                    core.fail(("%s is out of reach and you don't have the AP to close in and attack"):format(target.name))
                end
                wait_until_still()

                combat = fo.combat()
                if combat == nil then
                    return finish()
                end
                target = find_critter(args.target)
                if target == nil or target.dead then
                    return finish("The target is gone.")
                end
                if target.why_not ~= nil then
                    return finish(("Moved toward %s, %d hexes away now, but can't attack yet: %s."):format(target.name, fo.tile_distance(fo.player().tile, target.tile), target.why_not))
                end
            end

            local ok, why = fo.attack(args.target)
            if not ok then
                core.fail(("can't attack %d: %s"):format(args.target, why or "the game refused"))
            end

            -- Let the attack's animation start before waiting for it to end.
            core.wait_frames(2)
            local ready = wait_for_player()
            return finish(not ready and "The attack was still playing out when the wait ran out." or nil)
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
                -- Space, as the end-turn button sends.
                fo.inject(32)
                core.wait_until(function()
                    return not fo.input_pending()
                end, 5000)
                -- The turn passes once the game has read the key.
                core.wait_until(function()
                    local now = fo.combat()
                    return now == nil or not now.can_act
                end, 5000)
            end

            local ready = wait_for_player()
            return finish(not ready and "Still waiting for your turn when the wait ran out." or nil)
        end,
    })
end
