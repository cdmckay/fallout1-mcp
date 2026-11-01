local state = require("mcp.state")

-- Frames for the interface and messages to catch up once the player has
-- finished putting one thing away and taking another out.
local SETTLE_FRAMES = 3

local ANIMATION_TIMEOUT_MS = 5000

return function(core)
    -- Runs an inventory binding that returns true, or false and a reason;
    -- then waits out any animation it started and returns the view.
    local function act(binding, ...)
        local ok, why = binding(...)
        if not ok then
            core.fail(why or "the game refused")
        end

        core.wait_until(function()
            return not fo.player_busy()
        end, ANIMATION_TIMEOUT_MS)
        core.wait_frames(SETTLE_FRAMES)

        return { data = state.view() }
    end

    local function check_item(args)
        if math.type(args.item) ~= "integer" then
            core.fail("item must be an item's id from the inventory tool")
        end
    end

    local function check_hand(args)
        if args.hand ~= nil and args.hand ~= "left" and args.hand ~= "right" then
            core.fail('hand must be "left" or "right" (or left out, for the active hand)')
        end
    end

    local hand_schema = {
        type = "string",
        enum = { "left", "right" },
        description = "Which hand. Leave it out for the active hand.",
    }

    core.tool({
        name = "inventory",
        description = "Everything you carry: each item's id, name, type, quantity and weight; which hand or armor slot it's in; and for weapons the ammo loaded and its type. Also the total weight and what you can carry, your caps, and which hand is active.",
        run = function()
            return { data = fo.inventory() }
        end,
    })

    core.tool({
        name = "equip",
        description = "Puts an item from your inventory to use: armor on your body, a weapon or anything else in a hand (the active hand unless you say). No inventory screen needed. In combat this costs 4 AP, as opening the inventory does, and only on your turn. Returns the state view.",
        schema = core.schema({
            item = { type = "integer", description = "The item's id, from the inventory tool." },
            hand = hand_schema,
        }, { "item" }),
        run = function(args)
            check_item(args)
            check_hand(args)
            return act(fo.equip, args.item, args.hand)
        end,
    })

    core.tool({
        name = "unequip",
        description = "Empties a hand (the active hand unless you say); the item stays in your inventory. In combat this costs 4 AP, as opening the inventory does. Returns the state view.",
        schema = core.schema({ hand = hand_schema }),
        run = function(args)
            check_hand(args)
            return act(fo.unequip, args.hand)
        end,
    })

    core.tool({
        name = "reload",
        description = "Reloads the weapon in a hand (the active hand unless you say) from the ammo you carry, as the interface bar's reload does. In combat it costs the weapon's reload AP (usually 2). The combat view shows the selected weapon's ammo, and a critter's why_not says when you're out. Returns the state view.",
        schema = core.schema({ hand = hand_schema }),
        run = function(args)
            check_hand(args)
            return act(fo.reload_weapon, args.hand)
        end,
    })

    core.tool({
        name = "use_item",
        description = "Uses an item from your inventory on yourself. So far that means drugs, such as stimpaks to heal; one at full health is wasted, as in the game. In combat this costs 4 AP, as opening the inventory does. Returns the state view (its messages say what the item did) and `used`: how many are left and their id, which changes when one is taken from a stack.",
        schema = core.schema({
            item = { type = "integer", description = "The item's id, from the inventory tool." },
        }, { "item" }),
        run = function(args)
            check_item(args)

            local before
            for _, item in ipairs(fo.inventory().items) do
                if item.id == args.item then
                    before = item
                end
            end

            local result = act(fo.use_item, args.item)

            -- Taking one from a stack leaves the rest in a copy with a new
            -- id, so say where the rest went.
            if before ~= nil then
                local used = { name = before.name, remaining = 0 }
                for _, item in ipairs(fo.inventory().items) do
                    if item.name == before.name and item.type == before.type then
                        used.remaining = item.quantity
                        used.id = item.id
                    end
                end
                result.data.used = used
            end

            return result
        end,
    })
end
