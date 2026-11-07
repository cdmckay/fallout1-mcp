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

    -- The id of the item `item` names: an id, or a name as the inventory
    -- lists it, in any case. Fails unless exactly one item goes by that name.
    -- A stack's id changes each time one is taken from it, so the name is
    -- the easier way to use the next stimpak.
    local function resolve_item(item)
        if math.type(item) == "integer" then
            return item
        end
        if type(item) ~= "string" or item == "" then
            core.fail("item must be an item's id or its name, from the inventory tool")
        end
        if not fo.flags().in_game then
            core.fail("there's no game in progress")
        end

        local matches = {}
        for _, carried in ipairs(fo.inventory().items) do
            if carried.name:lower() == item:lower() then
                matches[#matches + 1] = carried
            end
        end

        if #matches == 0 then
            core.fail(("you're not carrying anything called %q"):format(item))
        end
        if #matches > 1 then
            local which = {}
            for i, carried in ipairs(matches) do
                which[i] = carried.slot and ("%d (%s)"):format(carried.id, carried.slot) or tostring(carried.id)
            end
            core.fail(("%d items are called %q, ids %s; give the id of the one you mean"):format(#matches, item, table.concat(which, ", ")))
        end
        return matches[1].id
    end

    local function check_hand(args)
        if args.hand ~= nil and args.hand ~= "left" and args.hand ~= "right" then
            core.fail('hand must be "left" or "right" (or left out, for the active hand)')
        end
    end

    local item_schema = {
        type = core.array({ "integer", "string" }),
        description = "The item's id, or its name, as the inventory tool lists them.",
    }

    local hand_schema = {
        type = "string",
        enum = { "left", "right" },
        description = "Which hand. Leave it out for the active hand.",
    }

    core.tool({
        name = "inventory",
        description = "Everything you carry: each item's id, name, type, quantity and weight, and which hand or armor slot it's in. For each weapon, so you can choose one without equipping it: its attacks (primary, then secondary if it has one), each with its damage range, range in hexes, the skill it uses and its AP cost, aimed too if it can be aimed, all with your perks and traits applied, as the interface bar gives them once it's in a hand; its minimum Strength (each point you're short costs 20% to hit); two_handed if it takes both hands; and the ammo loaded, its type and the capacity. `unarmed` is the same for a punch with an empty hand. Also the total weight and what you can carry, your caps, and which hand is active.",
        run = function()
            return { data = fo.inventory() }
        end,
    })

    core.tool({
        name = "equip",
        description = "Puts an item from your inventory to use: armor on your body, a weapon or anything else in a hand (the active hand unless you say). Name the item by its id or its name; a name two of your items share needs the id. No inventory screen needed. In combat this costs 4 AP, as opening the inventory does, and only on your turn. Returns the state view.",
        schema = core.schema({
            item = item_schema,
            hand = hand_schema,
        }, { "item" }),
        run = function(args)
            check_hand(args)
            return act(fo.equip, resolve_item(args.item), args.hand)
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
        description = "Uses an item from your inventory on yourself. So far that means drugs, such as stimpaks to heal; one at full health is wasted, as in the game. Name the item by its id or its name, such as \"Stimpak\"; a name two of your items share needs the id. A stack's id changes each time one is taken from it, so the name is the easy way to use the next one. In combat this costs 4 AP, as opening the inventory does. Returns the state view (its messages say what the item did) and `used`: how many are left and their id.",
        schema = core.schema({
            item = item_schema,
        }, { "item" }),
        run = function(args)
            local id = resolve_item(args.item)

            local before
            for _, item in ipairs(fo.inventory().items) do
                if item.id == id then
                    before = item
                end
            end

            local result = act(fo.use_item, id)

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
